import { randomUUID } from 'node:crypto';
import type {
  ActivityItem,
  Agent,
  ApprovalDecision,
  FinishedItem,
  PendingApproval,
  PollResult,
  WristEvent,
  WristEventBody,
} from './events.ts';
import { CONFIG } from './config.ts';

function firstLine(text: string): string {
  const line = (text ?? '').split('\n').map((l) => l.trim()).find((l) => l.length > 0) ?? '';
  return line.length > 90 ? `${line.slice(0, 87)}...` : line;
}

export class BusyError extends Error {
  turnId: string;
  constructor(turnId: string) {
    super('turn_in_flight');
    this.turnId = turnId;
  }
}

export class CapacityError extends Error {
  constructor() {
    super('too_many_turns');
  }
}

interface Waiter {
  cursor: number;
  resolve: (r: PollResult) => void;
  timer: NodeJS.Timeout;
}

interface ApprovalRecord {
  info: PendingApproval;
  timer: NodeJS.Timeout;
  resolve: (decision: ApprovalDecision) => void;
  decision?: ApprovalDecision;
}

export interface Turn {
  id: string;
  agent: Agent;
  sessionKey: string;
  events: WristEvent[];
  done: boolean;
  createdAt: number;
  /** Where the work happened, so a finished turn can be opened. */
  cwd: string;
  /** Files the turn edited or opened, newest last. Powers "show me the thing". */
  touched: string[];
  finishedAt?: number;
  outcome?: 'done' | 'error';
  summaryText?: string;
  abort: AbortController;
  waiters: Waiter[];
  approvals: Map<string, ApprovalRecord>;
  /**
   * Absolute time the turn is considered hung. EXTENDED (never paused) when an
   * approval settles, so a missed bookkeeping step kills the turn late rather
   * than making it immortal. Pausing would fail open; this fails closed.
   */
  zombieDeadline: number;
  zombieTimer: NodeJS.Timeout;
}

export type SettleOutcome = 'settled' | 'already' | 'unknown';

export class TurnStore {
  private turns = new Map<string, Turn>();
  private activeBySession = new Map<string, string>();

  create(agent: Agent, sessionKey: string, cwd = ''): Turn {
    const existing = this.activeBySession.get(sessionKey);
    if (existing) throw new BusyError(existing);
    let running = 0;
    for (const t of this.turns.values()) if (!t.done) running++;
    if (running >= CONFIG.maxConcurrentTurns) throw new CapacityError();

    const turn: Turn = {
      id: randomUUID(),
      agent,
      sessionKey,
      events: [],
      done: false,
      createdAt: Date.now(),
      cwd,
      touched: [],
      abort: new AbortController(),
      waiters: [],
      approvals: new Map(),
      zombieDeadline: Date.now() + CONFIG.turnTimeoutMs,
      zombieTimer: setTimeout(() => this.onZombie(turn.id), CONFIG.turnTimeoutMs),
    };
    this.turns.set(turn.id, turn);
    this.activeBySession.set(sessionKey, turn.id);
    return turn;
  }

  /** Re-arms the hang timer against the (possibly extended) deadline. */
  private onZombie(turnId: string): void {
    const turn = this.turns.get(turnId);
    if (!turn || turn.done) return;
    const remaining = turn.zombieDeadline - Date.now();
    if (remaining > 0) {
      turn.zombieTimer = setTimeout(() => this.onZombie(turnId), remaining);
      return;
    }
    turn.abort.abort();
    this.finish(turnId, {
      type: 'error',
      message: `turn timed out after ${Math.round(CONFIG.turnTimeoutMs / 60000)} minutes`,
    });
  }

  /**
   * Parks an action until a human decides. Resolves with the decision.
   * Every resolution path funnels through settleApproval, so the promise can
   * never be resolved twice or left dangling.
   */
  requestApproval(turnId: string, info: Omit<PendingApproval, 'approvalId' | 'createdAt' | 'expiresAt'>): Promise<ApprovalDecision> {
    const turn = this.turns.get(turnId);
    if (!turn || turn.done) return Promise.resolve('deny');
    if (turn.approvals.size >= CONFIG.maxPendingApprovals) {
      return Promise.resolve('deny');
    }

    const approvalId = randomUUID();
    const now = Date.now();
    const full: PendingApproval = {
      ...info,
      approvalId,
      createdAt: now,
      expiresAt: now + CONFIG.approvalTimeoutMs,
    };

    return new Promise<ApprovalDecision>((resolve) => {
      const record: ApprovalRecord = {
        info: full,
        resolve,
        // Unconditional and non-pausable: this is the load-bearing safety
        // property. Every client-side failure mode ends here.
        timer: setTimeout(
          () => this.settleApproval(turnId, approvalId, 'timeout'),
          CONFIG.approvalTimeoutMs,
        ),
      };
      turn.approvals.set(approvalId, record);
      this.push(turnId, { type: 'approval', approval: full });
    });
  }

  /** The ONLY place an approval resolves. Compare-and-set. */
  settleApproval(turnId: string, approvalId: string, decision: ApprovalDecision): SettleOutcome {
    const turn = this.turns.get(turnId);
    if (!turn) return 'unknown';
    const record = turn.approvals.get(approvalId);
    if (!record) return 'unknown';
    if (record.decision !== undefined) return 'already';

    record.decision = decision;
    clearTimeout(record.timer);
    // Credit the human's thinking time back to the hang budget.
    turn.zombieDeadline += Date.now() - record.info.createdAt;
    // Deliberately NOT deleted: the settled record is what lets a retrying
    // watch be told "yes, that worked" instead of "unknown approval", and what
    // distinguishes a duplicate tap from a conflicting one. pendingOf() filters
    // on decision === undefined, and turn eviction reaps these.
    // push(), not a bare mutation: this is what wakes parked long-polls, so the
    // card clears on the wrist immediately instead of up to 25s later.
    this.push(turnId, { type: 'approval_resolved', approvalId, decision });
    record.resolve(decision);
    return 'settled';
  }

  approvalDecision(turnId: string, approvalId: string): ApprovalDecision | undefined {
    return this.turns.get(turnId)?.approvals.get(approvalId)?.decision;
  }

  get(turnId: string): Turn | undefined {
    return this.turns.get(turnId);
  }

  abortTurn(turnId: string): boolean {
    const turn = this.turns.get(turnId);
    if (!turn || turn.done) return false;
    turn.abort.abort();
    this.finish(turnId, { type: 'error', message: 'Stopped from the watch.' });
    return true;
  }

  /** Aborts everything; used on SIGTERM so no agent child is left parked. */
  abortAll(): void {
    for (const turn of [...this.turns.values()]) {
      if (!turn.done) {
        turn.abort.abort();
        this.finish(turn.id, { type: 'error', message: 'Bridge shutting down.' });
      }
    }
  }

  /** Records a file the turn edited or opened, so it can be surfaced later. */
  noteTouched(turnId: string, path: string): void {
    const turn = this.turns.get(turnId);
    if (!turn || !path) return;
    const existing = turn.touched.indexOf(path);
    if (existing !== -1) turn.touched.splice(existing, 1);
    turn.touched.push(path);
    if (turn.touched.length > 12) turn.touched.shift();
  }

  /** Recently finished turns, for the notch indicator's "Done" state. */
  recent(withinMs = 10 * 60_000): FinishedItem[] {
    const cutoff = Date.now() - withinMs;
    const out: FinishedItem[] = [];
    for (const turn of this.turns.values()) {
      if (!turn.done || !turn.finishedAt || turn.finishedAt < cutoff) continue;
      out.push({
        turnId: turn.id,
        agent: turn.agent,
        outcome: turn.outcome ?? 'done',
        summary: turn.summaryText ?? '',
        cwd: turn.cwd,
        touched: turn.touched,
        finishedAt: turn.finishedAt,
        durationMs: turn.finishedAt - turn.createdAt,
      });
    }
    return out.sort((a, b) => b.finishedAt - a.finishedAt).slice(0, 5);
  }

  /** Snapshot of in-flight work, for the Mac notch indicator. */
  activity(): ActivityItem[] {
    const out: ActivityItem[] = [];
    for (const turn of this.turns.values()) {
      if (turn.done) continue;
      let status = 'Working';
      let lastText = '';
      for (let i = turn.events.length - 1; i >= 0; i--) {
        const e = turn.events[i];
        if (!status.startsWith('Working') && lastText) break;
        if (e.type === 'status' && status === 'Working') status = e.label;
        if (e.type === 'text' && !lastText) lastText = e.chunk;
      }
      out.push({
        turnId: turn.id,
        agent: turn.agent,
        sessionId: turn.sessionKey.split(':').slice(1).join(':'),
        status,
        startedAt: turn.createdAt,
        elapsedMs: Date.now() - turn.createdAt,
        // Surfaced so the watch's Alerts screen has real content rather than
        // an invented notification backend.
        pending: this.pendingOf(turn),
      });
    }
    return out.sort((a, b) => a.startedAt - b.startedAt);
  }

  push(turnId: string, body: WristEventBody): void {
    const turn = this.turns.get(turnId);
    if (!turn || turn.done) return;
    // A session event can re-key the turn (resume forked, or a new session got its id).
    if (body.type === 'session') {
      const newKey = `${body.agent}:${body.sessionId}`;
      if (newKey !== turn.sessionKey) {
        if (this.activeBySession.get(turn.sessionKey) === turn.id) {
          this.activeBySession.delete(turn.sessionKey);
        }
        turn.sessionKey = newKey;
        this.activeBySession.set(newKey, turn.id);
      }
    }
    turn.events.push({ ...body, seq: turn.events.length, ts: Date.now() });
    this.flush(turn);
  }

  finish(turnId: string, terminal: Extract<WristEventBody, { type: 'done' } | { type: 'error' }>): void {
    const turn = this.turns.get(turnId);
    if (!turn || turn.done) return;
    // Settle pending approvals BEFORE marking done: push() early-returns on a
    // done turn, so resolutions emitted after this point vanish from the log
    // and leave the agent's parked promise dangling.
    for (const approvalId of [...turn.approvals.keys()]) {
      this.settleApproval(turnId, approvalId, 'deny');
    }
    turn.events.push({ ...terminal, seq: turn.events.length, ts: Date.now() });
    turn.done = true;
    turn.finishedAt = Date.now();
    turn.outcome = terminal.type === 'done' ? 'done' : 'error';
    turn.summaryText = terminal.type === 'done'
      ? (turn.events.find((e) => e.type === 'summary') as { text?: string } | undefined)?.text
        ?? firstLine(terminal.fullText)
      : terminal.message;
    clearTimeout(turn.zombieTimer);
    if (this.activeBySession.get(turn.sessionKey) === turn.id) {
      this.activeBySession.delete(turn.sessionKey);
    }
    this.flush(turn);
    this.evict();
  }

  /** Returns null for an unknown turn (bridge restarted or evicted). */
  poll(turnId: string, cursor: number): Promise<PollResult> | null {
    const turn = this.turns.get(turnId);
    if (!turn) return null;
    const from = Math.max(0, Math.min(cursor, turn.events.length));
    if (turn.events.length > from || turn.done) {
      return Promise.resolve(this.result(turn, from));
    }
    return new Promise((resolve) => {
      const waiter: Waiter = {
        cursor: from,
        resolve,
        timer: setTimeout(() => {
          turn.waiters = turn.waiters.filter((w) => w !== waiter);
          // Still send the pending snapshot on an empty hold: a client that
          // missed the approval event recovers on the next quiet poll.
          resolve({ events: [], nextCursor: from, done: false, pending: this.pendingOf(turn) });
        }, CONFIG.pollHoldMs),
      };
      turn.waiters.push(waiter);
    });
  }

  private pendingOf(turn: Turn): PendingApproval[] {
    const out: PendingApproval[] = [];
    for (const record of turn.approvals.values()) {
      if (record.decision === undefined) out.push(record.info);
    }
    return out.sort((a, b) => a.createdAt - b.createdAt);
  }

  private result(turn: Turn, from: number): PollResult {
    return {
      events: turn.events.slice(from),
      nextCursor: turn.events.length,
      done: turn.done,
      pending: this.pendingOf(turn),
    };
  }

  private flush(turn: Turn): void {
    if (turn.waiters.length === 0) return;
    const ready = turn.waiters.filter((w) => turn.events.length > w.cursor || turn.done);
    turn.waiters = turn.waiters.filter((w) => !ready.includes(w));
    for (const w of ready) {
      clearTimeout(w.timer);
      w.resolve(this.result(turn, w.cursor));
    }
  }

  private evict(): void {
    if (this.turns.size <= CONFIG.maxTurnsBuffered) return;
    for (const [id, t] of this.turns) {
      if (this.turns.size <= CONFIG.maxTurnsBuffered) break;
      if (t.done) this.turns.delete(id);
    }
  }
}
