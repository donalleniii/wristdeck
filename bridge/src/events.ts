export type Agent = 'claude' | 'codex' | 'stub';

export type ApprovalDecision = 'allow' | 'deny' | 'timeout';

/** An action parked waiting for a tap on the watch. */
export interface PendingApproval {
  approvalId: string;
  tool: string;
  /** One-line human rendering, e.g. "Push to origin/main". */
  summary: string;
  /** Raw command or compact tool input. Shown verbatim; never normalized. */
  detail: string;
  /** Which folder this acts on. "Push" is meaningless without it. */
  cwd: string;
  /** Why it needs a tap: 'publishes', 'spends', 'irreversible'. */
  risk: string;
  costHint?: string;
  createdAt: number;
  expiresAt: number;
}

export type WristEventBody =
  | { type: 'session'; agent: Agent; sessionId: string }
  | { type: 'status'; label: string }
  | { type: 'model'; name: string }
  | { type: 'text'; chunk: string }
  | { type: 'denied'; tool: string; detail: string }
  | { type: 'approval'; approval: PendingApproval }
  | { type: 'approval_resolved'; approvalId: string; decision: ApprovalDecision }
  | { type: 'summary'; text: string }
  | { type: 'done'; fullText: string; numTurns?: number; costUsd?: number }
  | { type: 'error'; message: string };

export type WristEvent = WristEventBody & { seq: number; ts: number };

/** One in-flight turn, as shown by the Mac notch indicator. */
export interface ActivityItem {
  turnId: string;
  agent: Agent;
  sessionId: string;
  status: string;
  startedAt: number;
  elapsedMs: number;
  pending: PendingApproval[];
}

/** A turn that just finished, for the Mac notch indicator's "Done" state. */
export interface FinishedItem {
  turnId: string;
  agent: Agent;
  outcome: 'done' | 'error';
  summary: string;
  cwd: string;
  /** Files it edited or opened, newest last. Clicking "Done" opens the last one. */
  touched: string[];
  finishedAt: number;
  durationMs: number;
}

export interface PollResult {
  events: WristEvent[];
  nextCursor: number;
  done: boolean;
  /**
   * Level-triggered snapshot, recomputed on every response. The event log is
   * edge-triggered and cannot answer "is something still waiting?": a client
   * whose cursor already passed the approval event would never see it again,
   * and a client replaying from 0 would re-show resolved ones. The watch
   * renders its approval card from THIS, never from the events.
   */
  pending: PendingApproval[];
}
