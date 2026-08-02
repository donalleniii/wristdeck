// PreToolUse enforcement.
//
// Why a hook instead of canUseTool: we now pass settingSources: ['user'] so
// claude.ai MCP connectors (Higgsfield, Vercel, Drive) load. Settings
// permission allow-rules are applied BEFORE canUseTool, so an entry like
// `Bash(swift -e ' *)` would execute arbitrary code without the policy ever
// running. PreToolUse hooks fire regardless of allow-rules, so this is the only
// placement where enforcement actually holds.
import type { HookJSONOutput } from '@anthropic-ai/claude-agent-sdk';
import {
  askDeniedMessage,
  askTimedOutMessage,
  classify,
  denyMessage,
  type PolicyContext,
} from './policy.ts';

export function makeWristHook(ctx: PolicyContext) {
  return async (input: Record<string, unknown>): Promise<HookJSONOutput> => {
    const toolName = String(input.tool_name ?? '');
    const toolInput = (input.tool_input ?? {}) as Record<string, unknown>;
    const verdict = classify(toolName, toolInput);

    // MUST say permissionDecision: 'allow', not merely continue. `continue: true`
    // only means "this hook does not object"; the SDK then falls through to its
    // normal permission flow, and since the hook migration removed canUseTool
    // there is no approver left, so the call is refused. File edits masked this
    // because permissionMode 'acceptEdits' auto-approves them, which is exactly
    // why it survived testing: Bash allowlist entries, MCP tools, and every
    // user-approved ASK action were silently being denied.
    if (verdict.tier === 'allow') {
      return {
        continue: true,
        hookSpecificOutput: {
          hookEventName: 'PreToolUse',
          permissionDecision: 'allow',
          permissionDecisionReason: 'WristDeck policy: permitted from the watch.',
        },
      };
    }

    if (verdict.tier === 'deny') {
      ctx.sink.push({ type: 'denied', tool: toolName, detail: verdict.detail });
      return {
        continue: true,
        hookSpecificOutput: {
          hookEventName: 'PreToolUse',
          permissionDecision: 'deny',
          permissionDecisionReason:
            toolName === 'Bash'
              ? denyMessage(verdict.detail)
              : `WristDeck policy: ${toolName} is not permitted from the watch. ` +
                `Report what you needed it for in your final reply.`,
        },
      };
    }

    // ASK: park until the watch answers.
    const decision = await ctx.requestApproval(ctx.turnId, {
      tool: toolName,
      summary: verdict.summary,
      detail: verdict.detail,
      cwd: ctx.cwd,
      risk: verdict.risk,
      costHint: verdict.costHint,
    });

    if (decision === 'allow') {
      return {
        continue: true,
        hookSpecificOutput: {
          hookEventName: 'PreToolUse',
          permissionDecision: 'allow',
          permissionDecisionReason: 'Approved by the user on their watch.',
        },
      };
    }

    ctx.sink.push({ type: 'denied', tool: toolName, detail: verdict.detail });
    if (decision === 'timeout') {
      // Nobody is watching. Ending the turn beats looping on unattended work.
      return {
        continue: false,
        stopReason: 'No approval from the watch; stopping.',
        hookSpecificOutput: {
          hookEventName: 'PreToolUse',
          permissionDecision: 'deny',
          permissionDecisionReason: askTimedOutMessage(verdict.summary),
        },
      };
    }
    // A considered "no": let the turn continue so the agent can explain itself.
    return {
      continue: true,
      hookSpecificOutput: {
        hookEventName: 'PreToolUse',
        permissionDecision: 'deny',
        permissionDecisionReason: askDeniedMessage(verdict.summary, verdict.detail),
      },
    };
  };
}
