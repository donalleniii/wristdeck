import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { randomBytes } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const bridgeRoot = dirname(dirname(fileURLToPath(import.meta.url)));
export const ENV_PATH = join(bridgeRoot, '.env');

function loadEnvFile(): Record<string, string> {
  if (!existsSync(ENV_PATH)) {
    const token = randomBytes(32).toString('hex');
    writeFileSync(ENV_PATH, `WRISTDECK_TOKEN=${token}\nPORT=8787\n`, { mode: 0o600 });
    console.log(`[config] created ${ENV_PATH} with a fresh token`);
  }
  const out: Record<string, string> = {};
  for (const line of readFileSync(ENV_PATH, 'utf8').split('\n')) {
    const m = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*?)\s*$/);
    if (m) out[m[1]] = m[2];
  }
  return out;
}

const fileEnv = loadEnvFile();
const env = (key: string): string | undefined => process.env[key] ?? fileEnv[key];

// If the bridge is started from inside a Claude Code session (e.g. during
// development), inherited CLAUDE_*/ANTHROPIC_* vars would poison the agent
// child processes' auth resolution. Scrub them; keep only deliberate opt-ins.
const KEEP = new Set(['CLAUDE_CODE_OAUTH_TOKEN', 'ANTHROPIC_API_KEY']);
for (const key of Object.keys(process.env)) {
  if (/^(CLAUDECODE|CLAUDE_|ANTHROPIC_)/.test(key) && !KEEP.has(key)) {
    delete process.env[key];
  }
}
// Values from .env (like CLAUDE_CODE_OAUTH_TOKEN) flow to agent children.
for (const key of KEEP) {
  if (!process.env[key] && fileEnv[key]) process.env[key] = fileEnv[key];
}

const token = env('WRISTDECK_TOKEN');
if (!token || token.length < 16) {
  throw new Error(`WRISTDECK_TOKEN missing or too short in ${ENV_PATH}`);
}

export const CONFIG = {
  port: Number(env('PORT') ?? 8787),
  token,
  pollHoldMs: Number(env('WRISTDECK_POLL_HOLD_MS') ?? 25_000),
  turnTimeoutMs: Number(env('WRISTDECK_TURN_TIMEOUT_MS') ?? 900_000),
  maxTurnsBuffered: 20,
  maxConcurrentTurns: 4,
  // Unconditional and non-pausable: with maxConcurrentTurns at 4, turns parked
  // forever on an absent human would wedge the bridge. This is the backstop for
  // every client-side failure mode, so it must never depend on the watch.
  // 10 min, not 5: watchOS background refresh can take a while to wake the app
  // and fire the "needs approval" notification, so a 5 min window expired
  // before the user was ever told. Still bounded, still unconditional.
  approvalTimeoutMs: Number(env('WRISTDECK_APPROVAL_TIMEOUT_MS') ?? 600_000),
  // A 44mm screen cannot show a queue of cards, and a runaway agent should not
  // be able to spam one.
  maxPendingApprovals: 3,
  // When a watch-driven turn finishes having touched a file, open it on the Mac
  // so the result is waiting when you walk back. Without this you return to a
  // "Done" with nothing on screen and have to remember what you asked for.
  autoOpenOnFinish: (env('WRISTDECK_AUTO_OPEN') ?? 'true') !== 'false',
  version: '0.1.0',
} as const;
