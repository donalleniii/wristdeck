// Persistent turn ledger. The in-memory TurnStore forgets on restart and evicts
// at 20 turns; this file is what makes "what happened while I was away" a
// question with an answer. One JSON line per finished turn, newest last, in
// ~/.wristdeck/history.jsonl, deliberately OUTSIDE the repo so it can never be
// committed (the repo is public) and survives reinstalls of the project.
import { appendFile, mkdir, readFile, rename, writeFile } from 'node:fs/promises';
import { homedir } from 'node:os';
import { join } from 'node:path';
import type { Agent } from './events.ts';

export const DATA_DIR = join(homedir(), '.wristdeck');
const HISTORY_PATH = join(DATA_DIR, 'history.jsonl');

/** Compact at startup so the file stays readable-in-one-gulp forever. */
const COMPACT_ABOVE = 2000;
const COMPACT_TO = 1000;

/** Everything the history UIs need; prompts are truncated before they get here. */
export interface HistoryEntry {
  turnId: string;
  agent: Agent;
  /** What was asked, so a row is recognizable days later. */
  prompt: string;
  summary: string;
  outcome: 'done' | 'error';
  cwd: string;
  touched: string[];
  createdAt: number;
  finishedAt: number;
  durationMs: number;
  numTurns?: number;
  costUsd?: number;
}

async function ensureDir(): Promise<void> {
  await mkdir(DATA_DIR, { recursive: true, mode: 0o700 });
}

/** Serializes writes so two near-simultaneous finishes cannot interleave lines. */
let writeQueue: Promise<void> = Promise.resolve();

export function appendHistory(entry: HistoryEntry): Promise<void> {
  writeQueue = writeQueue
    .then(async () => {
      await ensureDir();
      await appendFile(HISTORY_PATH, `${JSON.stringify(entry)}\n`, { mode: 0o600 });
    })
    .catch((err) => {
      console.warn('[history] append failed (non-fatal):', err);
    });
  return writeQueue;
}

async function readAll(): Promise<HistoryEntry[]> {
  let text: string;
  try {
    text = await readFile(HISTORY_PATH, 'utf8');
  } catch {
    return [];
  }
  const out: HistoryEntry[] = [];
  for (const line of text.split('\n')) {
    if (!line.trim()) continue;
    // A torn line (crash mid-append) is dropped, not fatal.
    try {
      const parsed = JSON.parse(line) as HistoryEntry;
      if (parsed && typeof parsed.turnId === 'string') out.push(parsed);
    } catch {
      // skip
    }
  }
  return out;
}

/** Newest first. */
export async function readHistory(limit: number): Promise<HistoryEntry[]> {
  const all = await readAll();
  return all.slice(-Math.max(1, limit)).reverse();
}

export async function findHistoryEntry(turnId: string): Promise<HistoryEntry | undefined> {
  const all = await readAll();
  for (let i = all.length - 1; i >= 0; i--) {
    if (all[i].turnId === turnId) return all[i];
  }
  return undefined;
}

/**
 * Startup-only compaction: trims the ledger to the newest COMPACT_TO entries
 * once it grows past COMPACT_ABOVE. Write-to-temp-then-rename so a crash mid
 * compaction leaves the old file intact rather than a truncated one.
 */
export async function compactHistory(): Promise<void> {
  const all = await readAll();
  if (all.length <= COMPACT_ABOVE) return;
  const keep = all.slice(-COMPACT_TO);
  const tmp = `${HISTORY_PATH}.tmp`;
  await ensureDir();
  await writeFile(tmp, keep.map((e) => JSON.stringify(e)).join('\n') + '\n', { mode: 0o600 });
  await rename(tmp, HISTORY_PATH);
  console.log(`[history] compacted ${all.length} -> ${keep.length} entries`);
}
