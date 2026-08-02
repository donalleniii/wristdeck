// Regression test for the bug that made "approve on the watch" do nothing.
//
// The hook returned `{continue: true}` on allow, which only means "this hook
// does not object". With canUseTool removed, nothing then GRANTED permission, so
// Bash allowlist entries, MCP tools, and every user-approved action were refused.
// It survived earlier testing because file writes are auto-approved by
// permissionMode 'acceptEdits', and those were all the tests exercised.
//
// So this test never checks a file write. It checks that permitted things RUN.
import { readFileSync, mkdirSync, rmSync } from 'node:fs';
import { execFileSync } from 'node:child_process';

const env = readFileSync(new URL('../.env', import.meta.url), 'utf8');
const TOKEN = env.match(/WRISTDECK_TOKEN=(\S+)/)[1];
const BASE = 'http://127.0.0.1:8787';
const H = { Authorization: `Bearer ${TOKEN}`, 'Content-Type': 'application/json' };

let fail = 0;
const check = (name, cond, extra = '') => {
  console.log(`${cond ? 'PASS' : 'FAIL'}  ${name}${extra ? `  (${extra})` : ''}`);
  if (!cond) fail++;
};

async function runTurn(body, { approve = false, maxMs = 240000 } = {}) {
  const r = await fetch(`${BASE}/sessions/claude/new`, {
    method: 'POST', headers: H, body: JSON.stringify(body),
  });
  const { turnId } = await r.json();
  const events = [];
  let cursor = 0;
  const deadline = Date.now() + maxMs;
  while (Date.now() < deadline) {
    const p = await (await fetch(`${BASE}/turns/${turnId}/events?cursor=${cursor}`, { headers: H })).json();
    events.push(...p.events);
    cursor = p.nextCursor;
    if (approve && p.pending?.length) {
      const a = p.pending[0];
      await fetch(`${BASE}/turns/${turnId}/approvals/${a.approvalId}`, {
        method: 'POST', headers: H, body: JSON.stringify({ decision: 'allow' }),
      });
    }
    if (p.done) break;
  }
  return { turnId, events };
}

// 1. An allowlisted Bash command must actually execute.
const gitDir = '/tmp/wristdeck-permtest';
rmSync(gitDir, { recursive: true, force: true });
mkdirSync(gitDir, { recursive: true });
execFileSync('/usr/bin/git', ['init', '-q'], { cwd: gitDir });

console.log('--- allowlisted Bash must RUN ---');
let out = await runTurn({
  cwd: gitDir,
  text: 'Run `git status` with the Bash tool and paste its raw output verbatim. Do not use any other tool.',
});
let done = out.events.find((e) => e.type === 'done');
let denied = out.events.filter((e) => e.type === 'denied');
check('git status was not denied', denied.length === 0, denied.map((d) => d.detail).join('|'));
check('agent saw real git output', /branch|commit|nothing to commit|No commits/i.test(done?.fullText ?? ''), (done?.fullText ?? '').slice(0, 90));

// 2. An approved ASK action must actually execute. `git push` in a repo with no
// remote is safe: if permission works it RUNS and fails on the missing remote,
// which is a completely different signal from being refused by policy.
console.log('\n--- approved ASK action must RUN ---');
out = await runTurn({
  cwd: gitDir,
  text: 'Run `git push` with the Bash tool. Report the exact error it returns.',
}, { approve: true });
done = out.events.find((e) => e.type === 'done');
const sawApproval = out.events.some((e) => e.type === 'approval');
const resolvedAllow = out.events.some((e) => e.type === 'approval_resolved' && e.decision === 'allow');
check('it asked for approval', sawApproval);
check('approval recorded as allowed', resolvedAllow);
const text = done?.fullText ?? '';
const actuallyRan = /no configured push destination|does not appear to be a git repository|no upstream|remote/i.test(text);
const wasBlocked = /policy|not permitted|blocked|declined/i.test(text);
check('command actually executed (hit git, not policy)', actuallyRan && !wasBlocked, text.slice(0, 110));

console.log(fail === 0 ? '\nALL PASS' : `\n${fail} FAILURES`);
process.exit(fail === 0 ? 0 : 1);
