// Three-tier policy for watch-driven turns: ALLOW / ASK / DENY.
//
//   ALLOW  read-only shell, file tools, validated capabilities
//   ASK    public, irreversible, or costs money -> parks for a tap on the watch
//   DENY   everything else, terminal default
//
// Enforcement runs as a PreToolUse HOOK rather than canUseTool, because
// settings.json allow-rules auto-approve before canUseTool is ever consulted.
// Don's settings.local.json contains `Bash(swift -e ' *)`, which would execute
// arbitrary code without ever reaching us. Hooks fire regardless of allow-rules,
// so enforcement survives loading settings (which we must do to get MCP
// connectors like Higgsfield).
import type { TurnSink } from './adapters/types.ts';
import { OPEN_PATH_TOOL_CLAUDE } from './tools/mcpConfig.ts';

export type Tier = 'allow' | 'ask' | 'deny';

const ALLOW_TOOLS = new Set([
  OPEN_PATH_TOOL_CLAUDE,
  'Read', 'Edit', 'Write', 'MultiEdit', 'NotebookEdit',
  'Glob', 'Grep', 'TodoWrite', 'Task', 'WebFetch', 'WebSearch',
  'BashOutput', 'ToolSearch', 'ExitPlanMode', 'NotebookRead',
]);

const SAFE_BASH: RegExp[] = [
  /^ls(\s|$)/, /^pwd$/, /^cat\s/, /^head\s/, /^tail\s/, /^wc\s/,
  /^echo\s/, /^which\s/, /^file\s/, /^stat\s/,
  // Local, reversible git. Editing files is already allowed, so recording a
  // commit is no greater power. Publishing is a separate tier.
  /^git (status|diff|log|show|branch|add|commit|stash|remote|rev-parse)(\s|$)/,
];

/** Publishes, spends money, or cannot be undone. Checked BEFORE the allow list. */
const ASK_BASH: { pattern: RegExp; summary: (cmd: string) => string; risk: string }[] = [
  { pattern: /^git\s+(-C\s+\S+\s+|--git-dir=\S+\s+)*push/, summary: () => 'Push commits to GitHub', risk: 'publishes' },
  { pattern: /^gh\s+pr\s+create/, summary: () => 'Open a pull request', risk: 'publishes' },
  { pattern: /^gh\s+pr\s+merge/, summary: () => 'Merge a pull request', risk: 'irreversible' },
  { pattern: /^gh\s+repo\s+create/, summary: () => 'Create a GitHub repository', risk: 'publishes' },
  { pattern: /^gh\s+release\s+create/, summary: () => 'Publish a release', risk: 'publishes' },
  { pattern: /^gh\s+issue\s+create/, summary: () => 'Open a public issue', risk: 'publishes' },
  { pattern: /^gh\s+gist\s+create/, summary: () => 'Publish a gist', risk: 'publishes' },
  { pattern: /^vercel\s+(deploy|--prod)/, summary: () => 'Deploy the site', risk: 'publishes' },
  { pattern: /^npm\s+publish/, summary: () => 'Publish to npm', risk: 'publishes' },
];

const SHELL_META = /[;&|`$<>\\]|\n/;

/** MCP servers whose read-only tools are free and safe to run unattended. */
const MCP_FREE_TOOLS = new Set([
  'balance', 'models_explore', 'list_voices', 'show_generations', 'show_medias',
  'job_status', 'job_display', 'show_plans_and_credits', 'list_websites',
  'transactions', 'presets_show', 'show_characters', 'list_workspaces',
  'get_workflow_instructions', 'apps_search', 'apps_describe',
]);

/** MCP tools that spend real money or publish. */
const MCP_ASK_PATTERNS = /^(generate_|create_voice|deploy_|publish_|upscale_|dubbing|video_|outpaint_|reframe|motion_control|explainer_video|animate_|buy_|tiktok_publish|shorts_studio_create|personal_clipper_create)/;

export interface Classification {
  tier: Tier;
  summary: string;
  detail: string;
  risk: string;
  costHint?: string;
}

/** Pure, unit-testable. No I/O, no sink, no SDK types. */
export function classify(toolName: string, input: Record<string, unknown>): Classification {
  if (toolName === 'Bash') {
    const cmd = String(input.command ?? '').trim();
    const detail = cmd;

    // Metacharacters are banned in EVERY tier, so `git push && rm -rf` cannot
    // exist and the ASK patterns below only ever see one plain command.
    if (SHELL_META.test(cmd)) {
      return { tier: 'deny', summary: 'Shell command', detail, risk: 'chained command' };
    }
    for (const rule of ASK_BASH) {
      if (rule.pattern.test(cmd)) {
        return { tier: 'ask', summary: rule.summary(cmd), detail, risk: rule.risk };
      }
    }
    if (SAFE_BASH.some((r) => r.test(cmd))) {
      return { tier: 'allow', summary: 'Read-only command', detail, risk: '' };
    }
    return { tier: 'deny', summary: 'Shell command', detail, risk: 'not permitted' };
  }

  // MCP tools arrive as one flat string; parse structurally rather than
  // regexing the whole name, so `mcp__evil__generate_image_safe` cannot
  // near-miss its way into a match.
  const mcp = /^mcp__(.+?)__(.+)$/.exec(toolName);
  if (mcp) {
    const [, server, tool] = mcp;
    if (toolName === OPEN_PATH_TOOL_CLAUDE) {
      return { tier: 'allow', summary: 'Open a file', detail: String(input.path ?? ''), risk: '' };
    }
    const detail = compactInput(input);
    if (MCP_FREE_TOOLS.has(tool)) {
      return { tier: 'allow', summary: `${tool} (read-only)`, detail, risk: '' };
    }
    if (MCP_ASK_PATTERNS.test(tool)) {
      return {
        tier: 'ask',
        summary: `${humanize(tool)} via ${server.replace(/^claude_ai_/, '')}`,
        detail,
        risk: 'spends credits',
        costHint: 'uses your account credits',
      };
    }
    // Unknown MCP tool: ask rather than deny, since these are connectors the
    // user deliberately attached, but never run one unattended.
    return { tier: 'ask', summary: `${humanize(tool)} via ${server.replace(/^claude_ai_/, '')}`, detail, risk: 'external service' };
  }

  if (ALLOW_TOOLS.has(toolName)) {
    return { tier: 'allow', summary: toolName, detail: '', risk: '' };
  }
  return { tier: 'deny', summary: toolName, detail: compactInput(input), risk: 'not permitted' };
}

function humanize(tool: string): string {
  return tool.replace(/_/g, ' ').replace(/^\w/, (c) => c.toUpperCase());
}

function compactInput(input: Record<string, unknown>): string {
  const text = JSON.stringify(input ?? {});
  return text.length > 160 ? `${text.slice(0, 157)}...` : text;
}

/** Shown when a command simply is not permitted. Teaches the allowed shapes. */
export function denyMessage(cmd: string): string {
  return (
    `WristDeck policy: that command was not run.\n` +
    `Permitted from the watch, as ONE plain command with no chaining ` +
    `(&&, ;, |), no redirects (>), and no substitution ($(), \`\`):\n` +
    `  ls, pwd, cat, head, tail, wc, echo, which, file, stat\n` +
    `  git status|diff|log|show|branch|add|commit|stash|remote\n` +
    `To open a file or folder on the Mac, call the open_path tool instead of a ` +
    `shell command.\n` +
    `Publishing actions (git push, gh pr create, vercel deploy) are allowed but ` +
    `require the user to tap Approve on their watch; just run them normally and ` +
    `you will be asked.\n` +
    `If part of your goal fits the above, do it now as a separate single ` +
    `command. Otherwise continue with file tools, and state in your final reply ` +
    `exactly what you would have run and why.` +
    (cmd ? `\n(refused: ${cmd})` : '')
  );
}

/**
 * Shown when the human looked at the action and said no. Deliberately NOT the
 * message above: that one invites reformulation, which is the opposite of what
 * a considered "no" means.
 */
export function askDeniedMessage(summary: string, detail: string): string {
  return (
    `The user was shown this action on their watch and DECLINED it:\n` +
    `  ${summary}\n  ${detail}\n` +
    `Do not retry it, and do not attempt an equivalent by another route. ` +
    `Continue with whatever else you can do, then state plainly in your final ` +
    `reply what remains undone because of this.`
  );
}

/** Shown when nobody answered. The user is absent, so stop the turn. */
export function askTimedOutMessage(summary: string): string {
  return (
    `No response from the user's watch for this action, so it was not run:\n` +
    `  ${summary}\n` +
    `The user is away. Stop here rather than continuing unattended.`
  );
}

export interface PolicyContext {
  turnId: string;
  cwd: string;
  sink: TurnSink;
  requestApproval: (
    turnId: string,
    info: { tool: string; summary: string; detail: string; cwd: string; risk: string; costHint?: string },
  ) => Promise<'allow' | 'deny' | 'timeout'>;
}
