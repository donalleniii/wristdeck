import { basename } from 'node:path';
import { query } from '@anthropic-ai/claude-agent-sdk';
import type { AgentAdapter, TurnOutcome, TurnRequest, TurnSink } from './types.ts';
import { makeWristHook } from '../hook.ts';
import { WRISTDECK_MCP } from '../tools/mcpConfig.ts';

export class ClaudeAdapter implements AgentAdapter {
  async runTurn(req: TurnRequest, sink: TurnSink, signal: AbortSignal): Promise<TurnOutcome> {
    const abortController = new AbortController();
    const onAbort = (): void => abortController.abort();
    if (signal.aborted) abortController.abort();
    else signal.addEventListener('abort', onAbort, { once: true });

    let fullText = '';
    let lastSessionId = req.sessionId ?? '';
    try {
      const q = query({
        prompt: req.text,
        options: {
          ...(req.sessionId ? { resume: req.sessionId, forkSession: false } : {}),
          ...(req.cwd ? { cwd: req.cwd } : {}),
          permissionMode: 'acceptEdits',
          ...(req.model ? { model: req.model } : {}),
          includePartialMessages: true,
          // 'user' loads claude.ai MCP connectors (Higgsfield, Vercel, Drive).
          // It ALSO loads settings permission allow-rules, which bypass
          // canUseTool entirely, which is exactly why enforcement moved to the
          // PreToolUse hook below. Do not "simplify" this back to canUseTool.
          settingSources: ['user'],
          hooks: {
            PreToolUse: [{ hooks: [makeWristHook({
              turnId: req.turnId ?? '',
              cwd: req.cwd ?? '',
              sink,
              requestApproval: req.requestApproval ?? (async () => 'deny'),
            })] }],
          },
          systemPrompt: { type: 'preset', preset: 'claude_code' },
          mcpServers: WRISTDECK_MCP, // open_path, shared with Codex
          maxTurns: 40,
          abortController,
        },
      });

      for await (const msg of q) {
        if (msg.type === 'system' && msg.subtype === 'init') {
          if (msg.session_id !== lastSessionId) {
            lastSessionId = msg.session_id;
            sink.push({ type: 'session', agent: 'claude', sessionId: msg.session_id });
          }
          // Report the model the SDK actually resolved, not what we asked for.
          if (typeof msg.model === 'string' && msg.model) {
            sink.push({ type: 'model', name: msg.model });
          }
        } else if (msg.type === 'stream_event') {
          if (msg.parent_tool_use_id) continue; // subagent chatter
          const ev = msg.event as any;
          if (ev.type === 'content_block_delta' && ev.delta?.type === 'text_delta') {
            fullText += ev.delta.text;
            sink.push({ type: 'text', chunk: ev.delta.text });
          } else if (ev.type === 'content_block_start' && ev.content_block?.type === 'tool_use') {
            sink.push({ type: 'status', label: statusFor(ev.content_block.name, undefined) });
          }
        } else if (msg.type === 'assistant') {
          for (const block of (msg.message.content ?? []) as any[]) {
            if (block.type === 'tool_use') {
              sink.push({ type: 'status', label: statusFor(block.name, block.input) });
              const touched = touchedPath(block.name, block.input);
              if (touched) req.noteTouched?.(touched);
            }
          }
        } else if (msg.type === 'result') {
          if (msg.session_id && msg.session_id !== lastSessionId) {
            sink.push({ type: 'session', agent: 'claude', sessionId: msg.session_id });
          }
          if (msg.subtype === 'success') {
            return {
              fullText: msg.result || fullText,
              numTurns: msg.num_turns,
              costUsd: msg.total_cost_usd,
            };
          }
          throw new Error(`claude turn ended: ${msg.subtype}`);
        }
      }
      return { fullText };
    } finally {
      signal.removeEventListener('abort', onAbort);
    }
  }
}

/// What did this tool call act on? Used so "Done" on the Mac can open the thing.
function touchedPath(name: string, input: Record<string, unknown> | undefined): string | null {
  if (!input) return null;
  if (name.endsWith('__open_path') && typeof input.path === 'string') return input.path;
  const writeTools = ['Edit', 'Write', 'MultiEdit', 'NotebookEdit'];
  if (writeTools.includes(name) && typeof input.file_path === 'string') return input.file_path;
  return null;
}

function statusFor(name: string, input: Record<string, unknown> | undefined): string {
  const filePath = typeof input?.file_path === 'string' ? (input.file_path as string) : '';
  const file = filePath ? basename(filePath) : '';
  switch (name) {
    case 'Edit':
    case 'Write':
    case 'MultiEdit':
    case 'NotebookEdit':
      return file ? `Editing ${file}` : 'Editing files';
    case 'Read':
      return file ? `Reading ${file}` : 'Reading files';
    case 'Glob':
    case 'Grep':
      return 'Searching code';
    case 'Bash': {
      const cmd = typeof input?.command === 'string' ? (input.command as string).slice(0, 40) : '';
      return cmd ? `Running ${cmd}` : 'Running a command';
    }
    case 'Task':
      return 'Delegating to a subagent';
    case 'WebFetch':
    case 'WebSearch':
      return 'Searching the web';
    case 'TodoWrite':
      return 'Updating the plan';
    default:
      return `Using ${name}`;
  }
}
