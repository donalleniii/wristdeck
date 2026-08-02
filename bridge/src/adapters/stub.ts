// Test-only adapter: exercises the turn pipeline without spawning a real agent.
// text commands: "sleep:<ms>" waits before replying; "fail" throws;
// "touch:<path>" writes that file and records it as touched (exercises
// auto-open, proof, history and artifacts); anything else echoes.
import { writeFile } from 'node:fs/promises';
import { setTimeout as delay } from 'node:timers/promises';
import type { AgentAdapter, TurnOutcome, TurnRequest, TurnSink } from './types.ts';

export class StubAdapter implements AgentAdapter {
  async runTurn(req: TurnRequest, sink: TurnSink, signal: AbortSignal): Promise<TurnOutcome> {
    sink.push({ type: 'session', agent: 'stub', sessionId: req.sessionId ?? 'stub-session' });
    sink.push({ type: 'status', label: 'Thinking' });
    const m = req.text.match(/^sleep:(\d+)$/);
    if (m) await delay(Number(m[1]), undefined, { signal });
    if (req.text === 'fail') throw new Error('stub failure requested');

    const touch = req.text.match(/^touch:(.+)$/);
    if (touch) {
      const target = touch[1].trim();
      await writeFile(target, `WristDeck stub artifact, written ${new Date().toISOString()}\n`);
      req.noteTouched?.(target);
      const reply = `wrote ${target}`;
      sink.push({ type: 'text', chunk: reply });
      return { fullText: reply, numTurns: 1 };
    }

    // Exercises the approval gate end to end without spending anything.
    if (req.text.startsWith('ask')) {
      const decision = await req.requestApproval!(req.turnId!, {
        tool: 'Bash',
        summary: 'Push commits to GitHub',
        detail: 'git push origin main',
        cwd: req.cwd ?? '/tmp/demo',
        risk: 'publishes',
      });
      const reply = `approval decision: ${decision}`;
      sink.push({ type: 'text', chunk: reply });
      return { fullText: reply, numTurns: 1 };
    }
    const reply = `echo: ${req.text}`;
    sink.push({ type: 'text', chunk: reply });
    return { fullText: reply, numTurns: 1 };
  }
}
