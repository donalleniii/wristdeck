import type { Agent, WristEventBody } from '../events.ts';

export interface TurnRequest {
  agent: Agent;
  sessionId?: string;
  cwd?: string;
  text: string;
  /** Model to run this turn with; falls back to the agent's default. */
  model?: string;
  /** Set by the server so the policy hook can park actions for a watch tap. */
  turnId?: string;
  /** Records a file this turn edited or opened, for the Mac "Done" click-through. */
  noteTouched?: (path: string) => void;
  requestApproval?: (
    turnId: string,
    info: { tool: string; summary: string; detail: string; cwd: string; risk: string; costHint?: string },
  ) => Promise<'allow' | 'deny' | 'timeout'>;
}

export interface TurnSink {
  push(body: WristEventBody): void;
}

export interface TurnOutcome {
  fullText: string;
  numTurns?: number;
  costUsd?: number;
}

export interface AgentAdapter {
  runTurn(req: TurnRequest, sink: TurnSink, signal: AbortSignal): Promise<TurnOutcome>;
}
