// Verifies the notch "Done" contract: after a turn finishes, /activity.recent
// must carry a summary and a real path to open.
import { readFileSync } from 'node:fs';

const env = readFileSync(new URL('../.env', import.meta.url), 'utf8');
const TOKEN = env.match(/WRISTDECK_TOKEN=(\S+)/)[1];
const BASE = 'http://127.0.0.1:8787';
const H = { Authorization: `Bearer ${TOKEN}`, 'Content-Type': 'application/json' };
const turnId = process.argv[2];

// Wait for the turn to finish.
for (let i = 0; i < 90; i++) {
  const p = await (await fetch(`${BASE}/turns/${turnId}/events?cursor=0`, { headers: H })).json();
  if (p.done) break;
  await new Promise((r) => setTimeout(r, 1000));
}

const act = await (await fetch(`${BASE}/activity`, { headers: H })).json();
const done = (act.recent ?? []).find((r) => r.turnId === turnId);

let fail = 0;
const check = (name, cond, extra = '') => {
  console.log(`${cond ? 'PASS' : 'FAIL'}  ${name}${extra ? `  (${extra})` : ''}`);
  if (!cond) fail++;
};

check('turn appears in recent', Boolean(done));
if (done) {
  check('outcome is done', done.outcome === 'done', done.outcome);
  check('has a human summary', done.summary.length > 0, done.summary.slice(0, 70));
  check('recorded a touched file', done.touched.length > 0, done.touched.join(', '));
  check('touched path is the file it wrote', done.touched.some((p) => p.endsWith('note.txt')));
  check('knows its folder', done.cwd.length > 0, done.cwd);
  check('duration recorded', done.durationMs > 0, `${Math.round(done.durationMs / 1000)}s`);

  // The click-through: does opening actually resolve to that file?
  const open = await (await fetch(`${BASE}/turns/${turnId}/open`, { method: 'POST', headers: H })).json();
  check('POST /open succeeds', open.ok === true, open.message ?? '');
  check('opened the file it wrote', String(open.target).endsWith('note.txt'), open.target);
}

console.log(fail === 0 ? '\nALL PASS' : `\n${fail} FAILURES`);
process.exit(fail === 0 ? 0 : 1);
