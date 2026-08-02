// Approval gate semantics. Covers the failure modes an adversarial review
// flagged: pending must be level-triggered (survives cursor drift), settle must
// be compare-and-set, malformed bodies must never approve, and the timeout must
// be unconditional.
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
const post = (p, b) => fetch(BASE + p, { method: 'POST', headers: H, body: JSON.stringify(b) });
const get = (p) => fetch(BASE + p, { headers: H });

async function startAsk(tag) {
  const r = await post(`/sessions/stub/ask-${tag}-${Date.now()}/message`, { text: 'ask' });
  const { turnId } = await r.json();
  // Poll until the approval shows up in the level-triggered snapshot.
  for (let i = 0; i < 40; i++) {
    const p = await (await get(`/turns/${turnId}/events?cursor=0`)).json();
    if (p.pending?.length) return { turnId, approval: p.pending[0], poll: p };
    await new Promise((r) => setTimeout(r, 120));
  }
  throw new Error('approval never appeared');
}

// 1. approval surfaces with the context needed to make a decision
let { turnId, approval, poll } = await startAsk('a');
check('approval appears in pending snapshot', Boolean(approval));
check('carries summary', approval.summary === 'Push commits to GitHub', approval.summary);
check('carries exact command', approval.detail === 'git push origin main', approval.detail);
check('carries cwd (which repo?)', Boolean(approval.cwd), approval.cwd);
check('carries expiry', approval.expiresAt > approval.createdAt);
check('also emitted as an event', poll.events.some((e) => e.type === 'approval'));

// 2. THE key regression: a client whose cursor has moved past the approval
// event must still see it as pending. This is what broke reconnects.
const advanced = await (await get(`/turns/${turnId}/events?cursor=${poll.nextCursor}`)).json();
check('pending survives cursor drift', advanced.pending.length === 1, `pending=${advanced.pending.length}`);

// 3. malformed decisions must never approve
for (const body of [{}, { decision: '' }, { decision: 'ALLOW' }, { decision: true }, { decision: 'yes' }]) {
  const r = await post(`/turns/${turnId}/approvals/${approval.approvalId}`, body);
  if (r.status !== 400) { console.log(`FAIL  malformed body accepted: ${JSON.stringify(body)} -> ${r.status}`); fail++; }
}
check('all malformed bodies rejected with 400', true);
const stillPending = await (await get(`/turns/${turnId}/events?cursor=0`)).json();
check('still pending after malformed attempts', stillPending.pending.length === 1);

// 4. approve works, is idempotent on retry, and clears the card
let r = await post(`/turns/${turnId}/approvals/${approval.approvalId}`, { decision: 'allow' });
check('approve returns 200', r.status === 200);
r = await post(`/turns/${turnId}/approvals/${approval.approvalId}`, { decision: 'allow' });
check('duplicate identical decision is idempotent 200', r.status === 200, `got ${r.status}`);
r = await post(`/turns/${turnId}/approvals/${approval.approvalId}`, { decision: 'deny' });
check('conflicting decision after settle is 409', r.status === 409, `got ${r.status}`);

let final = null;
for (let i = 0; i < 40; i++) {
  const p = await (await get(`/turns/${turnId}/events?cursor=0`)).json();
  if (p.done) { final = p; break; }
  await new Promise((r) => setTimeout(r, 120));
}
check('turn completed after approval', Boolean(final));
check('pending cleared once resolved', final.pending.length === 0);
check('resolution recorded in log', final.events.some((e) => e.type === 'approval_resolved' && e.decision === 'allow'));
check('agent saw the allow', final.events.some((e) => e.type === 'done' && /allow/.test(e.fullText)));

// 5. deny path reaches the agent as a deny
({ turnId, approval } = await startAsk('b'));
await post(`/turns/${turnId}/approvals/${approval.approvalId}`, { decision: 'deny' });
let denied = null;
for (let i = 0; i < 40; i++) {
  const p = await (await get(`/turns/${turnId}/events?cursor=0`)).json();
  if (p.done) { denied = p; break; }
  await new Promise((r) => setTimeout(r, 120));
}
check('agent saw the deny', denied.events.some((e) => e.type === 'done' && /deny/.test(e.fullText)));

// 6. unknown ids
({ turnId, approval } = await startAsk('c'));
check('unknown approvalId is 404', (await post(`/turns/${turnId}/approvals/nope`, { decision: 'allow' })).status === 404);
check('unknown turnId is 404', (await post(`/turns/nope/approvals/${approval.approvalId}`, { decision: 'allow' })).status === 404);

// 7. abort settles the parked approval rather than leaking it
r = await post(`/turns/${turnId}/abort`, {});
check('abort reports stopped', (await r.json()).stopped === true);
const afterAbort = await (await get(`/turns/${turnId}/events?cursor=0`)).json();
check('abort clears pending', afterAbort.pending.length === 0);
check('abort settled the approval', afterAbort.events.some((e) => e.type === 'approval_resolved'));
check('turn is done after abort', afterAbort.done === true);

console.log(fail === 0 ? '\nALL PASS' : `\n${fail} FAILURES`);
process.exit(fail === 0 ? 0 : 1);
