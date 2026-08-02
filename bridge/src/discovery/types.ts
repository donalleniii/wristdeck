export interface SessionSummary {
  agent: 'claude' | 'codex';
  id: string;
  label: string;
  cwd: string;
  lastActivity: number;
}
