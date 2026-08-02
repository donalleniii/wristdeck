import type { SessionSummary } from './types.ts';
import { listClaudeSessions } from './claudeStore.ts';
import { listCodexSessions } from './codexStore.ts';

export type { SessionSummary } from './types.ts';

export async function listAllSessions(): Promise<SessionSummary[]> {
  const [claude, codex] = await Promise.all([listClaudeSessions(), listCodexSessions()]);
  return [...claude, ...codex].sort((a, b) => b.lastActivity - a.lastActivity);
}

export async function findSession(agent: string, id: string): Promise<SessionSummary | undefined> {
  const all = await listAllSessions();
  return all.find((s) => s.agent === agent && s.id === id);
}
