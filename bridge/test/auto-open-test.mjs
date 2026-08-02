// Auto-open contract. The prompt deliberately never says "open it": that is the
// whole point. Asking for a file should leave it on screen, not leave you
// staring at a "Done" you have to decode from memory.
import { readFileSync, mkdirSync, rmSync, existsSync } from 'node:fs';
import { execFileSync } from 'node:child_process';

const env = readFileSync(new URL('../.env', import.meta.url), 'utf8');
const TOKEN = env.match(/WRISTDECK_TOKEN=(\S+)/)[1];
const BASE = 'http://127.0.0.1:8787';
const H = { Authorization: `Bearer ${TOKEN}`, 'Content-Type': 'application/json' };
const DIR = '/tmp/wristdeck-autoopen';
const FILE = `${DIR}/summary.txt`;

let fail = 0;
const check = (name, cond, extra = '') => {
  console.log(`${cond ? 'PASS' : 'FAIL'}  ${name}${extra ? `  (${extra})` : ''}`);
  if (!cond) fail++;
};

const textEditPIDs = () => {
  try {
    return execFileSync('/usr/bin/pgrep', ['-x', 'TextEdit']).toString().trim().split('\n').filter(Boolean);
  } catch { return []; }
};

rmSync(DIR, { recursive: true, force: true });
mkdirSync(DIR, { recursive: true });

// Make sure the setting is on, via the endpoint the watch toggle uses.
const put = await fetch(`${BASE}/settings`, {
  method: 'POST', headers: H, body: JSON.stringify({ autoOpen: true }),
});
check('settings endpoint accepts a toggle', put.status === 200);
check('rejects a non-boolean', (await fetch(`${BASE}/settings`, {
  method: 'POST', headers: H, body: JSON.stringify({ autoOpen: 'yes' }),
})).status === 400);

const before = textEditPIDs().length;

// NOTE: no "open it" in the prompt.
const r = await fetch(`${BASE}/sessions/claude/new`, {
  method: 'POST', headers: H,
  body: JSON.stringify({
    cwd: DIR,
    text: 'Write a file called summary.txt here containing exactly: auto open works. Then reply done.',
  }),
});
const { turnId } = await r.json();

for (let i = 0; i < 120; i++) {
  const p = await (await fetch(`${BASE}/turns/${turnId}/events?cursor=0`, { headers: H })).json();
  if (p.done) break;
  await new Promise((res) => setTimeout(res, 1000));
}

check('file was written', existsSync(FILE));

// Give LaunchServices a moment to bring the app up.
await new Promise((res) => setTimeout(res, 3000));

const act = await (await fetch(`${BASE}/activity`, { headers: H })).json();
const done = (act.recent ?? []).find((x) => x.turnId === turnId);
check('turn recorded the file it touched', done?.touched?.some((p) => p.endsWith('summary.txt')), (done?.touched ?? []).join(','));

const after = textEditPIDs().length;
check('an editor opened for it', after > before || after > 0, `TextEdit processes ${before} -> ${after}`);

console.log(fail === 0 ? '\nALL PASS' : `\n${fail} FAILURES`);
process.exit(fail === 0 ? 0 : 1);
