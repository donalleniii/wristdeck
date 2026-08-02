// Verifies the persistent turn ledger. Two phases around a bridge restart,
// because restart survival IS the feature:
//   node test/history-test.mjs write    -> runs stub turns, checks /history + file
//   (restart the bridge)
//   node test/history-test.mjs verify   -> rows survived; /open falls back to ledger
import { readFileSync, writeFileSync, mkdtempSync } from 'node:fs';
import { homedir, tmpdir } from 'node:os';
import { join } from 'node:path';

const env = readFileSync(new URL('../.env', import.meta.url), 'utf8');
const TOKEN = env.match(/WRISTDECK_TOKEN=(\S+)/)[1];
const BASE = 'http://127.0.0.1:8787';
const H = { Authorization: `Bearer ${TOKEN}`, 'Content-Type': 'application/json' };
const STATE = join(tmpdir(), 'wristdeck-history-test.json');
const LEDGER = join(homedir(), '.wristdeck', 'history.jsonl');

let fail = 0;
const check = (name, cond, extra = '') => {
  console.log(`${cond ? 'PASS' : 'FAIL'}  ${name}${extra ? `  (${extra})` : ''}`);
  if (!cond) fail++;
};

async function runTurn(text, cwd) {
  const res = await fetch(`${BASE}/sessions/stub/new`, {
    method: 'POST', headers: H, body: JSON.stringify({ text, cwd }),
  });
  const { turnId } = await res.json();
  for (let i = 0; i < 30; i++) {
    const p = await (await fetch(`${BASE}/turns/${turnId}/events?cursor=0`, { headers: H })).json();
    if (p.done) return turnId;
    await new Promise((r) => setTimeout(r, 500));
  }
  throw new Error(`turn ${turnId} never finished`);
}

const history = async (limit = 50) =>
  (await (await fetch(`${BASE}/history?limit=${limit}`, { headers: H })).json()).turns;

const phase = process.argv[2] ?? 'write';

if (phase === 'write') {
  const scratch = mkdtempSync(join(tmpdir(), 'wristdeck-history-'));
  const okId = await runTurn('history probe echo', scratch);
  const failId = await runTurn('fail', scratch);

  const turns = await history();
  const ok = turns.find((t) => t.turnId === okId);
  const bad = turns.find((t) => t.turnId === failId);

  check('echo turn in /history', Boolean(ok));
  if (ok) {
    check('prompt recorded', ok.prompt === 'history probe echo', ok.prompt);
    check('summary recorded', ok.summary.includes('history probe echo'), ok.summary);
    check('outcome done', ok.outcome === 'done');
    check('cwd recorded', ok.cwd === scratch, ok.cwd);
    check('duration recorded', ok.durationMs >= 0, `${ok.durationMs}ms`);
    check('hasShot field present', typeof ok.hasShot === 'boolean');
  }
  check('failed turn in /history', Boolean(bad));
  if (bad) check('outcome error', bad.outcome === 'error', bad.summary);
  check('newest first', turns[0]?.turnId === failId);

  const onDisk = readFileSync(LEDGER, 'utf8');
  check('ledger file has echo turn', onDisk.includes(okId));
  check('ledger file has failed turn', onDisk.includes(failId));

  writeFileSync(STATE, JSON.stringify({ okId, failId, scratch }));
  console.log(fail === 0
    ? '\nWRITE PHASE PASS. Restart the bridge, then run: node test/history-test.mjs verify'
    : `\n${fail} FAILURES`);
} else {
  const { okId, failId, scratch } = JSON.parse(readFileSync(STATE, 'utf8'));

  const act = await (await fetch(`${BASE}/activity`, { headers: H })).json();
  check('memory store forgot the turn (restart happened)',
    !(act.recent ?? []).some((r) => r.turnId === okId));

  const turns = await history();
  check('echo turn survived restart', turns.some((t) => t.turnId === okId));
  check('failed turn survived restart', turns.some((t) => t.turnId === failId));

  // The fallback: the turn is gone from memory, so this can only work if
  // /open consulted the ledger. Opens one Finder window of the scratch dir.
  const open = await (await fetch(`${BASE}/turns/${okId}/open`, { method: 'POST', headers: H })).json();
  check('/open falls back to ledger', open.ok === true, open.message ?? JSON.stringify(open));
  check('opened the recorded cwd', open.target === scratch, open.target);

  console.log(fail === 0 ? '\nALL PASS' : `\n${fail} FAILURES`);
}
process.exit(fail === 0 ? 0 : 1);
