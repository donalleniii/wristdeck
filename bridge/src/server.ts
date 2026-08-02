import { homedir } from 'node:os';
import express from 'express';
import { CONFIG } from './config.ts';
import { requireAuth } from './auth.ts';
import { BusyError, CapacityError, TurnStore } from './turns.ts';
import type { Turn } from './turns.ts';
import type { Agent, WristEventBody } from './events.ts';
import type { AgentAdapter, TurnRequest } from './adapters/types.ts';
import { StubAdapter } from './adapters/stub.ts';
import { ClaudeAdapter } from './adapters/claude.ts';
import { CodexAdapter } from './adapters/codex.ts';
import { findSession, listAllSessions } from './discovery/index.ts';
import { summarizeForSpeech } from './summarize.ts';
import { openPath } from './tools/openPath.ts';
import { hasShot, pruneShots, saveShot, shotPath } from './screenshot.ts';
import { catalog, defaultModel, setDefaultModel } from './models.ts';
import { advertise } from './bonjour.ts';

const app = express();
app.use(express.json({ limit: '256kb' }));
app.use(requireAuth);

const store = new TurnStore();

/// Runtime-togglable from the watch, so this is changeable without editing .env.
const settings = { autoOpen: CONFIG.autoOpenOnFinish };
const adapters: Partial<Record<Agent, AgentAdapter>> = {
  claude: new ClaudeAdapter(),
  codex: new CodexAdapter(),
  stub: new StubAdapter(),
};

function runDetached(turn: Turn, baseReq: TurnRequest, summarize: boolean): void {
  const adapter = adapters[baseReq.agent]!;
  const sink = { push: (body: WristEventBody): void => store.push(turn.id, body) };
  const req: TurnRequest = {
    ...baseReq,
    turnId: turn.id,
    requestApproval: (turnId, info) => store.requestApproval(turnId, info),
    noteTouched: (path) => store.noteTouched(turn.id, path),
  };
  void (async () => {
    const outcome = await adapter.runTurn(req, sink, turn.abort.signal);
    if (summarize && outcome.fullText.length >= 280) {
      try {
        const summary = await summarizeForSpeech(outcome.fullText);
        if (summary) store.push(turn.id, { type: 'summary', text: summary });
      } catch (err) {
        console.warn('[summarize] failed (non-fatal):', err);
      }
    }
    store.finish(turn.id, {
      type: 'done',
      fullText: outcome.fullText,
      numTurns: outcome.numTurns,
      costUsd: outcome.costUsd,
    });
    await autoOpenResult(turn.id);
    await captureProof(turn.id);
  })().catch((err: unknown) => {
    const message = err instanceof Error ? err.message : String(err);
    console.error(`[turn ${turn.id}] failed:`, message);
    store.finish(turn.id, { type: 'error', message });
  });
}

/**
 * Opens what a finished turn produced, so walking back to the Mac shows the
 * result rather than a "Done" you have to decode from memory.
 *
 * Only fires when the turn actually touched a file: a pure question ("what does
 * this module do?") should not throw a window at you. openPath does the
 * validation, so a turn cannot talk this into launching something executable.
 */
async function autoOpenResult(turnId: string): Promise<void> {
  if (!settings.autoOpen) return;
  const turn = store.get(turnId);
  const target = turn?.touched.at(-1);
  if (!target) return;
  try {
    const result = await openPath(target);
    console.log(`[auto-open] ${result.ok ? 'opened' : 'skipped'} ${target}: ${result.message}`);
  } catch (err) {
    console.warn('[auto-open] failed (non-fatal):', err);
  }
}

/**
 * Proof-of-work screenshots are captured by the Mac notch app, NOT here.
 *
 * The bridge runs under launchd, and macOS denies it Screen Recording
 * ("could not create image from display") because that permission is granted
 * per-binary. Granting it would mean handing a bare `node` broad screen access.
 * WristDeckNotch.app is a real bundle in the user's GUI session, so macOS
 * prompts for it normally and the grant is scoped to that app. It watches
 * /activity, captures when a turn finishes, and uploads here.
 */
async function captureProof(_turnId: string): Promise<void> {
  await pruneShots(store.recent().map((r) => r.turnId));
}

function parseAgent(raw: string): Agent | null {
  return raw === 'claude' || raw === 'codex' || raw === 'stub' ? raw : null;
}

function startTurn(
  res: express.Response,
  agent: Agent,
  sessionKey: string,
  req: TurnRequest,
  summarize: boolean,
): void {
  try {
    const turn = store.create(agent, sessionKey, req.cwd ?? '');
    runDetached(turn, req, summarize);
    res.status(202).json({ turnId: turn.id });
  } catch (err) {
    if (err instanceof BusyError) {
      res.status(409).json({ error: 'turn_in_flight', turnId: err.turnId });
    } else if (err instanceof CapacityError) {
      res.status(503).json({ error: 'too_many_turns' });
    } else {
      throw err;
    }
  }
}

app.get('/health', (_req, res) => {
  res.json({ ok: true, version: CONFIG.version, agents: { claude: true, codex: true } });
});

// Powers the Mac notch indicator: what is the watch making this machine do right now?
/// What each agent can run, and what it will run by default.
app.get('/models', (_req, res) => {
  res.json(catalog());
});

app.post('/models', (req, res) => {
  const { agent, model } = (req.body ?? {}) as { agent?: string; model?: string };
  const parsed = parseAgent(String(agent ?? ''));
  if (!parsed || typeof model !== 'string') {
    res.status(400).json({ error: 'agent_and_model_required' });
    return;
  }
  if (!setDefaultModel(parsed, model)) {
    res.status(400).json({ error: 'unknown_model_for_agent' });
    return;
  }
  console.log(`[models] ${parsed} default -> ${model}`);
  res.json(catalog());
});

app.get('/settings', (_req, res) => {
  res.json({ autoOpen: settings.autoOpen });
});

app.post('/settings', (req, res) => {
  const value = (req.body ?? {}).autoOpen;
  if (typeof value !== 'boolean') {
    res.status(400).json({ error: 'autoOpen_must_be_boolean' });
    return;
  }
  settings.autoOpen = value;
  console.log(`[settings] autoOpen=${value}`);
  res.json({ autoOpen: settings.autoOpen });
});

app.get('/activity', async (_req, res) => {
  const recent = store.recent();
  const withProof = await Promise.all(
    recent.map(async (item) => ({ ...item, hasShot: await hasShot(item.turnId) })),
  );
  res.json({ active: store.activity(), recent: withProof });
});

/// The Mac notch app uploads proof-of-work here (raw PNG body).
app.post('/turns/:turnId/shot', express.raw({ type: 'image/png', limit: '4mb' }), async (req, res) => {
  const body = req.body as Buffer | undefined;
  if (!Buffer.isBuffer(body) || body.length < 1024) {
    res.status(400).json({ error: 'expected_png_body' });
    return;
  }
  await saveShot(req.params.turnId, body);
  res.json({ ok: true, bytes: body.length });
});

/// Proof of work: the screen as it looked when the turn finished.
app.get('/turns/:turnId/shot', async (req, res) => {
  if (!(await hasShot(req.params.turnId))) {
    res.status(404).json({ error: 'no_shot' });
    return;
  }
  res.sendFile(shotPath(req.params.turnId));
});

/// Opens what a finished turn produced, so clicking "Done" on the Mac lands
/// somewhere useful. Reuses the validated open_path capability.
app.post('/turns/:turnId/open', async (req, res) => {
  const turn = store.get(req.params.turnId);
  if (!turn) {
    res.status(404).json({ error: 'unknown_turn' });
    return;
  }
  const target = turn.touched.at(-1) ?? turn.cwd;
  if (!target) {
    res.status(404).json({ error: 'nothing_to_open' });
    return;
  }
  const result = await openPath(target);
  res.status(result.ok ? 200 : 400).json({ target, ...result });
});

app.get('/sessions', async (_req, res) => {
  const sessions = await listAllSessions();
  res.json({ sessions });
});

app.post('/sessions/:agent/new', async (req, res) => {
  const agent = parseAgent(req.params.agent);
  if (!agent) {
    res.status(400).json({ error: 'unknown_agent' });
    return;
  }
  const { text, cwd, summarize, model } = (req.body ?? {}) as
    { text?: string; cwd?: string; summarize?: boolean; model?: string };
  if (typeof text !== 'string' || !text.trim()) {
    res.status(400).json({ error: 'text_required' });
    return;
  }
  const workDir = typeof cwd === 'string' && cwd.trim() ? cwd : homedir();
  const placeholderKey = `${agent}:new:${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
  startTurn(
    res, agent, placeholderKey,
    { agent, cwd: workDir, text, model: model || defaultModel(agent) },
    Boolean(summarize),
  );
});

app.post('/sessions/:agent/:id/message', async (req, res) => {
  const agent = parseAgent(req.params.agent);
  if (!agent) {
    res.status(400).json({ error: 'unknown_agent' });
    return;
  }
  const { text, summarize, model } = (req.body ?? {}) as
    { text?: string; summarize?: boolean; model?: string };
  if (typeof text !== 'string' || !text.trim()) {
    res.status(400).json({ error: 'text_required' });
    return;
  }
  const sessionId = req.params.id;
  const known = agent === 'stub' ? undefined : await findSession(agent, sessionId);
  if (agent !== 'stub' && !known) {
    res.status(404).json({ error: 'unknown_session' });
    return;
  }
  startTurn(
    res,
    agent,
    `${agent}:${sessionId}`,
    { agent, sessionId, cwd: known?.cwd, text, model: model || defaultModel(agent) },
    Boolean(summarize),
  );
});

// Answer a parked approval. Fails closed: anything that is not the literal
// string 'allow' or 'deny' is a 400, and the allow branch exists in exactly
// one place, so a forgotten case can only ever deny.
app.post('/turns/:turnId/approvals/:approvalId', (req, res) => {
  const decision = (req.body ?? {}).decision;
  if (decision !== 'allow' && decision !== 'deny') {
    res.status(400).json({ error: 'decision_must_be_allow_or_deny' });
    return;
  }
  const { turnId, approvalId } = req.params;
  const turn = store.get(turnId);
  if (!turn) {
    res.status(404).json({ error: 'unknown_turn' });
    return;
  }

  // Idempotency is checked BEFORE turn state: if the watch's tap was recorded,
  // a retry should be told it succeeded even though the turn has since finished.
  const already = store.approvalDecision(turnId, approvalId);
  if (already !== undefined) {
    if (already === decision) {
      res.json({ approvalId, decision: already, decidedBy: 'user', repeated: true });
    } else {
      res.status(409).json({ error: 'already_decided', decision: already });
    }
    return;
  }

  if (turn.done) {
    res.status(410).json({ error: 'turn_finished' });
    return;
  }

  const outcome = store.settleApproval(turnId, approvalId, decision);
  if (outcome === 'settled') {
    res.json({ approvalId, decision, decidedBy: 'user' });
    return;
  }
  res.status(404).json({ error: 'unknown_approval' });
});

app.post('/turns/:turnId/abort', (req, res) => {
  res.json({ stopped: store.abortTurn(req.params.turnId) });
});

app.get('/turns/:turnId/events', async (req, res) => {
  const cursor = Number(req.query.cursor ?? 0);
  const pending = store.poll(req.params.turnId, Number.isFinite(cursor) ? cursor : 0);
  if (!pending) {
    res.status(404).json({ error: 'unknown_turn' });
    return;
  }
  res.json(await pending);
});

// 0.0.0.0 so the watch can reach us over local Wi-Fi too; every route is token-authed.
const server = app.listen(CONFIG.port, '0.0.0.0', () => {
  console.log(`[wristdeck] bridge listening on http://0.0.0.0:${CONFIG.port}`);
  advertise();
});

// Without this, a restart orphans any turn parked on an approval and leaves its
// agent child blocked forever on a question nobody will answer.
for (const signal of ['SIGTERM', 'SIGINT'] as const) {
  process.on(signal, () => {
    console.log(`[wristdeck] ${signal}: aborting live turns`);
    store.abortAll();
    server.close(() => process.exit(0));
    setTimeout(() => process.exit(0), 2000).unref();
  });
}
