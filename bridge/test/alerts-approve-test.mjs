// Verifies the "approve from anywhere" path: a parked approval must show up in
// /activity (which drives the Alerts screen and the notification banner), and
// answering it from there must actually release the agent.
import { readFileSync } from 'node:fs';

const env = readFileSync(new URL('../.env', import.meta.url), 'utf8');
const TOKEN = env.match(/WRISTDECK_TOKEN=(\S+)/)[1];
const BASE = 'http://127.0.0.1:8787';
const H = { Authorization: `Bearer ${TOKEN}`, 'Content-Type': 'application/json' };

let fail = 0;
const check = (name, cond, extra = '') => {
  console.log(`${cond ? 'PASS' : 'FAIL'}  ${name}${extra ? `  (${extra})` : ''}`);
  if (!cond) fail++;
};

// Park an approval, then look at it ONLY through /activity, the way the Alerts
// screen does. Never touch the turn's own event stream.
const r = await fetch(`${BASE}/sessions/stub/alerts-${Date.now()}/message`, {
  method: 'POST', headers: H, body: JSON.stringify({ text: 'ask' }),
});
const { turnId } = await r.json();

let seen = null;
for (let i = 0; i < 40; i++) {
  const act = await (await fetch(`${BASE}/activity`, { headers: H })).json();
  const item = act.active.find((a) => a.turnId === turnId);
  if (item?.pending?.length) { seen = item; break; }
  await new Promise((res) => setTimeout(res, 120));
}

check('approval visible via /activity', Boolean(seen));
const approval = seen?.pending?.[0];
check('carries what you are deciding', approval?.summary === 'Push commits to GitHub', approval?.summary);
check('carries the exact command', approval?.detail === 'git push origin main', approval?.detail);
check('carries the folder', Boolean(approval?.cwd), approval?.cwd);

// Answer it the way the Alerts card does.
const post = await fetch(`${BASE}/turns/${turnId}/approvals/${approval.approvalId}`, {
  method: 'POST', headers: H, body: JSON.stringify({ decision: 'allow' }),
});
check('decision accepted', post.status === 200, `HTTP ${post.status}`);

// The agent must actually be released.
let done = null;
for (let i = 0; i < 40; i++) {
  const p = await (await fetch(`${BASE}/turns/${turnId}/events?cursor=0`, { headers: H })).json();
  if (p.done) { done = p; break; }
  await new Promise((res) => setTimeout(res, 150));
}
check('turn completed after deciding', Boolean(done));
check('agent received the allow', done?.events.some((e) => e.type === 'done' && /allow/.test(e.fullText)));

// And it must disappear from the alert feed.
const after = await (await fetch(`${BASE}/activity`, { headers: H })).json();
check('cleared from /activity', !after.active.some((a) => a.turnId === turnId));

console.log(fail === 0 ? '\nALL PASS' : `\n${fail} FAILURES`);
process.exit(fail === 0 ? 0 : 1);
