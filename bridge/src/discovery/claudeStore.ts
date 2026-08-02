// Enumerates Claude Code sessions from ~/.claude/projects without ever reading
// whole files (they reach 121 MB). Labels come from flat single-line records:
// custom-title > ai-title > last-prompt > first user message.
import { createReadStream } from 'node:fs';
import { open, readdir, stat } from 'node:fs/promises';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { createInterface } from 'node:readline';
import type { SessionSummary } from './types.ts';

const PROJECTS_DIR = join(homedir(), '.claude', 'projects');
const HEAD_BYTES = 64 * 1024;
const TAIL_BYTES = 256 * 1024;

const cache = new Map<string, { mtimeMs: number; size: number; value: SessionSummary }>();

export async function listClaudeSessions(): Promise<SessionSummary[]> {
  let dirs: string[];
  try {
    dirs = await readdir(PROJECTS_DIR);
  } catch {
    return [];
  }
  const out: SessionSummary[] = [];
  for (const dir of dirs) {
    const dirPath = join(PROJECTS_DIR, dir);
    let files: string[];
    try {
      files = (await readdir(dirPath)).filter((f) => f.endsWith('.jsonl'));
    } catch {
      continue;
    }
    for (const file of files) {
      const path = join(dirPath, file);
      try {
        const st = await stat(path);
        const cached = cache.get(path);
        if (cached && cached.mtimeMs === st.mtimeMs && cached.size === st.size) {
          out.push(cached.value);
          continue;
        }
        const value = await summarizeSession(path, file.slice(0, -'.jsonl'.length), dir, st.mtimeMs, st.size);
        cache.set(path, { mtimeMs: st.mtimeMs, size: st.size, value });
        out.push(value);
      } catch {
        // unreadable or vanished mid-scan; skip
      }
    }
  }
  out.sort((a, b) => b.lastActivity - a.lastActivity);
  return out;
}

async function summarizeSession(
  path: string,
  sessionId: string,
  projectDir: string,
  mtimeMs: number,
  size: number,
): Promise<SessionSummary> {
  const headLines = await readHeadLines(path, HEAD_BYTES);
  const tailLines = size > HEAD_BYTES ? await readTailLines(path, TAIL_BYTES, size) : [];

  let cwd = '';
  let customTitle = '';
  let aiTitle = '';
  let lastPrompt = '';
  let firstUserText = '';

  const scan = (line: string): void => {
    let rec: any;
    try {
      rec = JSON.parse(line);
    } catch {
      return;
    }
    if (!cwd && typeof rec.cwd === 'string') cwd = rec.cwd;
    if (rec.type === 'custom-title' && typeof rec.customTitle === 'string') customTitle = rec.customTitle;
    if (rec.type === 'ai-title' && typeof rec.aiTitle === 'string') aiTitle = rec.aiTitle;
    if (rec.type === 'last-prompt' && typeof rec.lastPrompt === 'string') lastPrompt = rec.lastPrompt;
    if (
      !firstUserText &&
      rec.type === 'user' &&
      rec.isSidechain !== true &&
      rec.message?.role === 'user'
    ) {
      firstUserText = extractText(rec.message.content);
    }
  };

  for (const line of headLines) scan(line);
  for (const line of tailLines) scan(line);

  const label = clean(customTitle) || clean(aiTitle) || clean(lastPrompt) || clean(firstUserText) || sessionId.slice(0, 8);
  return {
    agent: 'claude',
    id: sessionId,
    label,
    cwd: cwd || decodeProjectDir(projectDir),
    lastActivity: mtimeMs,
  };
}

function extractText(content: unknown): string {
  if (typeof content === 'string') return content;
  if (Array.isArray(content)) {
    for (const block of content) {
      if (block?.type === 'text' && typeof block.text === 'string') return block.text;
    }
  }
  return '';
}

function clean(text: string): string {
  const t = text.replace(/\s+/g, ' ').trim();
  if (!t || t.startsWith('<')) return ''; // skip system-injected wrappers
  return t.length > 80 ? `${t.slice(0, 77)}...` : t;
}

/** Lossy inverse of Claude's cwd-to-dirname mapping; only a fallback. */
function decodeProjectDir(dir: string): string {
  return dir.replace(/-/g, '/');
}

async function readHeadLines(path: string, maxBytes: number): Promise<string[]> {
  return new Promise((resolve, reject) => {
    const lines: string[] = [];
    const stream = createReadStream(path, { start: 0, end: maxBytes - 1, encoding: 'utf8' });
    const rl = createInterface({ input: stream, crlfDelay: Infinity });
    rl.on('line', (l) => lines.push(l));
    rl.on('close', () => resolve(lines));
    stream.on('error', reject);
  });
}

async function readTailLines(path: string, maxBytes: number, size: number): Promise<string[]> {
  const start = Math.max(0, size - maxBytes);
  const fh = await open(path, 'r');
  try {
    const buf = Buffer.alloc(size - start);
    await fh.read(buf, 0, buf.length, start);
    const lines = buf.toString('utf8').split('\n');
    if (start > 0) lines.shift(); // first line is almost certainly partial
    return lines.filter((l) => l.length > 0);
  } finally {
    await fh.close();
  }
}
