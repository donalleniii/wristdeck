import { basename, resolve } from 'node:path';
import { Codex } from '@openai/codex-sdk';
import type { AgentAdapter, TurnOutcome, TurnRequest, TurnSink } from './types.ts';

// Codex has no system-prompt option, so capability guidance is prepended to the
// turn. Without this it pattern-matches "open a file" to shell `open`, which its
// sandbox kills: observed one turn burn 141s on `open -a`, `qlmanage`, and
// `osascript`, crashing TextEdit, while the working tool sat unused.
const PREAMBLE =
  '[WristDeck context, not from the user]\n' +
  'You are running headless on a Mac, driven from an Apple Watch. Your sandbox ' +
  'has NO network access and cannot launch Mac applications.\n' +
  'To show the user a file or folder, call the wristdeck-tools `open_path` tool ' +
  'with the path. Never use shell `open`, `open -a`, `qlmanage`, or `osascript` ' +
  'for this: they fail in the sandbox and can crash the app you are targeting.\n' +
  'If a shell command fails on a sandbox restriction, do not hunt for a ' +
  'workaround. Say plainly what was blocked and finish.\n' +
  '--- user message follows ---\n';

export class CodexAdapter implements AgentAdapter {
  // No `env` option here on purpose: passing env stops process.env inheritance
  // and breaks ~/.codex/auth.json resolution.
  private codex = new Codex();

  async runTurn(req: TurnRequest, sink: TurnSink, signal: AbortSignal): Promise<TurnOutcome> {
    const opts = {
      ...(req.cwd ? { workingDirectory: req.cwd } : {}),
      ...(req.model ? { model: req.model } : {}),
      sandboxMode: 'workspace-write' as const,
      skipGitRepoCheck: true,
      approvalPolicy: 'never' as const,
    };
    const thread = req.sessionId
      ? this.codex.resumeThread(req.sessionId, opts)
      : this.codex.startThread(opts);

    const { events } = await thread.runStreamed(PREAMBLE + req.text, { signal });
    const texts: string[] = [];

    for await (const ev of events as AsyncGenerator<any>) {
      switch (ev.type) {
        case 'thread.started':
          if (typeof ev.thread_id === 'string' && ev.thread_id) {
            sink.push({ type: 'session', agent: 'codex', sessionId: ev.thread_id });
          }
          sink.push({ type: 'model', name: req.model ?? 'default' });
          break;
        case 'turn.started':
          // Codex can take ~10s before its first real item. Without this the
          // watch sits on a bare "Working…" and reads as hung.
          sink.push({ type: 'status', label: 'Starting Codex' });
          break;
        case 'item.started': {
          const item = ev.item;
          if (item?.type === 'command_execution') {
            sink.push({ type: 'status', label: `Running ${String(item.command ?? '').slice(0, 40)}` });
          } else if (item?.type === 'file_change') {
            const changes = Array.isArray(item.changes) ? item.changes : [];
            const n = changes.length || 1;
            // Record the PATHS, not just the count. Without this, auto-open,
            // the notch "Done" click-through, and proof-of-work all had nothing
            // to point at for Codex, so they silently did nothing while the
            // Claude path worked fine.
            for (const change of changes) {
              if (typeof change?.path === 'string' && change.path) {
                req.noteTouched?.(resolve(req.cwd ?? '', change.path));
              }
            }
            const name = changes.length === 1 && typeof changes[0]?.path === 'string'
              ? basename(changes[0].path)
              : `${n} file${n === 1 ? '' : 's'}`;
            sink.push({ type: 'status', label: `Editing ${name}` });
          } else if (item?.type === 'reasoning') {
            sink.push({ type: 'status', label: 'Thinking' });
          } else if (item?.type === 'todo_list') {
            sink.push({ type: 'status', label: 'Planning' });
          } else if (item?.type === 'web_search') {
            sink.push({ type: 'status', label: 'Searching the web' });
          } else if (item?.type === 'mcp_tool_call') {
            sink.push({ type: 'status', label: `Using ${String(item.tool ?? 'a tool')}` });
          }
          break;
        }
        case 'item.completed': {
          const item = ev.item;
          if (item?.type === 'agent_message' && typeof item.text === 'string' && item.text) {
            texts.push(item.text);
            sink.push({ type: 'text', chunk: item.text });
          } else if (item?.type === 'command_execution' && typeof item.exit_code === 'number' && item.exit_code !== 0) {
            // Plain-English on the wrist: "Command failed (exit 137)" means nothing
            // to a person, and sandbox kills are the common case here.
            const blocked = item.exit_code === 137 || item.exit_code === 134;
            sink.push({
              type: 'status',
              label: blocked ? 'Blocked by the sandbox' : `Command failed (exit ${item.exit_code})`,
            });
          } else if (item?.type === 'error' && typeof item.message === 'string') {
            sink.push({ type: 'status', label: `Error: ${item.message.slice(0, 60)}` });
          }
          break;
        }
        case 'turn.completed':
          return { fullText: texts.join('\n\n') };
        case 'turn.failed':
          throw new Error(ev.error?.message ?? 'codex turn failed');
        case 'error':
          throw new Error(typeof ev.message === 'string' ? ev.message : 'codex stream error');
        default:
          break;
      }
    }
    return { fullText: texts.join('\n\n') };
  }
}
