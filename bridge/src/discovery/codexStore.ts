// Enumerates Codex sessions from ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl.
// Line 1 is session_meta (payload.session_id, payload.cwd); label comes from
// ~/.codex/session_index.jsonl (thread_name) or the first user_message event.
import { createReadStream } from 'node:fs';
import { open, readdir, readFile, stat } from 'node:fs/promises';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { createInterface } from 'node:readline';
import type { SessionSummary } from './types.ts';

const SESSIONS_DIR = join(homedir(), '.codex', 'sessions');
const INDEX_PATH = join(homedir(), '.codex', 'session_index.jsonl');
const HEAD_BYTES = 64 * 1024;

const cache = new Map<string, { mtimeMs: number; size: number; value: SessionSummary }>();

export async function listCodexSessions(): Promise<SessionSummary[]> {
  const files = await collectRolloutFiles();
  const index = await loadIndexLabels();
  const bySession = new Map<string, { mtimeMs: number; value: SessionSummary }>();

  for (const path of files) {
    try {
      const st = await stat(path);
      const cached = cache.get(path);
      let value: SessionSummary;
      if (cached && cached.mtimeMs === st.mtimeMs && cached.size === st.size) {
        value = cached.value;
      } else {
        const parsed = await summarizeRollout(path, st.mtimeMs);
        if (!parsed) continue;
        value = parsed;
        cache.set(path, { mtimeMs: st.mtimeMs, size: st.size, value });
      }
      const indexLabel = index.get(value.id);
      if (indexLabel) value = { ...value, label: indexLabel };
      // Resume can create a second rollout with the same id; newest file wins.
      const prev = bySession.get(value.id);
      if (!prev || st.mtimeMs > prev.mtimeMs) bySession.set(value.id, { mtimeMs: st.mtimeMs, value });
    } catch {
      // skip unreadable rollout
    }
  }

  const out = [...bySession.values()].map((e) => e.value);
  out.sort((a, b) => b.lastActivity - a.lastActivity);
  return out;
}

async function collectRolloutFiles(): Promise<string[]> {
  const files: string[] = [];
  let years: string[];
  try {
    years = await readdir(SESSIONS_DIR);
  } catch {
    return files;
  }
  for (const y of years) {
    let months: string[] = [];
    try {
      months = await readdir(join(SESSIONS_DIR, y));
    } catch {
      continue;
    }
    for (const m of months) {
      let days: string[] = [];
      try {
        days = await readdir(join(SESSIONS_DIR, y, m));
      } catch {
        continue;
      }
      for (const d of days) {
        try {
          for (const f of await readdir(join(SESSIONS_DIR, y, m, d))) {
            if (f.startsWith('rollout-') && f.endsWith('.jsonl')) {
              files.push(join(SESSIONS_DIR, y, m, d, f));
            }
          }
        } catch {
          // not a directory
        }
      }
    }
  }
  return files;
}

/** session_index.jsonl is append-only with duplicate ids; last write wins. Label cache only. */
async function loadIndexLabels(): Promise<Map<string, string>> {
  const map = new Map<string, string>();
  try {
    const text = await readFile(INDEX_PATH, 'utf8');
    for (const line of text.split('\n')) {
      if (!line) continue;
      try {
        const rec = JSON.parse(line);
        if (typeof rec.id === 'string' && typeof rec.thread_name === 'string' && rec.thread_name.trim()) {
          map.set(rec.id, rec.thread_name.trim());
        }
      } catch {
        // skip bad line
      }
    }
  } catch {
    // index is optional
  }
  return map;
}

async function summarizeRollout(path: string, mtimeMs: number): Promise<SessionSummary | null> {
  const headLines = await readHeadLines(path, HEAD_BYTES);
  let sessionId = '';
  let cwd = '';
  let userMessage = '';

  for (const line of headLines) {
    let rec: any;
    try {
      rec = JSON.parse(line);
    } catch {
      continue;
    }
    if (rec.type === 'session_meta' && rec.payload) {
      if (typeof rec.payload.session_id === 'string') sessionId = rec.payload.session_id;
      if (typeof rec.payload.cwd === 'string') cwd = rec.payload.cwd;
    } else if (
      !userMessage &&
      rec.type === 'event_msg' &&
      rec.payload?.type === 'user_message' &&
      typeof rec.payload.message === 'string'
    ) {
      userMessage = rec.payload.message;
    }
    if (sessionId && cwd && userMessage) break;
  }

  if (!sessionId) return null;
  const label = clean(userMessage) || labelFromCwd(cwd) || sessionId.slice(0, 8);
  const lastActivity = (await readLastTimestamp(path)) ?? mtimeMs;
  return { agent: 'codex', id: sessionId, label, cwd, lastActivity };
}

function clean(text: string): string {
  const t = text.replace(/\s+/g, ' ').trim();
  if (!t || t.startsWith('<')) return '';
  return t.length > 80 ? `${t.slice(0, 77)}...` : t;
}

/** Codex Desktop uses ~/Documents/Codex/<date>/<slug-of-first-prompt> as cwd; the slug is a usable label. */
function labelFromCwd(cwd: string): string {
  const base = cwd.split('/').filter(Boolean).pop() ?? '';
  return /^[a-z0-9-]{4,}$/.test(base) ? base.replace(/-/g, ' ') : '';
}

async function readLastTimestamp(path: string): Promise<number | null> {
  try {
    const st = await stat(path);
    const start = Math.max(0, st.size - 16 * 1024);
    const fh = await open(path, 'r');
    try {
      const buf = Buffer.alloc(st.size - start);
      await fh.read(buf, 0, buf.length, start);
      const lines = buf.toString('utf8').split('\n').filter((l) => l.length > 0);
      for (let i = lines.length - 1; i >= 0; i--) {
        try {
          const rec = JSON.parse(lines[i]);
          if (typeof rec.timestamp === 'string') {
            const t = Date.parse(rec.timestamp);
            if (!Number.isNaN(t)) return t;
          }
        } catch {
          // partial line
        }
      }
      return null;
    } finally {
      await fh.close();
    }
  } catch {
    return null;
  }
}

// re-export for tests
export { readHeadLines as _readHeadLines };

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
