// Live regression coverage for the Codex app-server adapter.
//
// Proves the two behaviors the automation SDK could not provide:
// 1. Files and streamed progress survive the watch bridge path.
// 2. A sandbox escape is parked on the watch and only runs after approval.
import { mkdirSync, readFileSync, rmSync } from 'node:fs';

const env = readFileSync(new URL('../.env', import.meta.url), 'utf8');
const TOKEN = env.match(/WRISTDECK_TOKEN=(\S+)/)[1];
const BASE = 'http://127.0.0.1:8787';
const H = { Authorization: `Bearer ${TOKEN}`, 'Content-Type': 'application/json' };

let failures = 0;
function check(name, condition, detail = '') {
  console.log(`${condition ? 'PASS' : 'FAIL'}  ${name}${detail ? `  (${detail})` : ''}`);
  if (!condition) failures++;
}

async function run(text, cwd, approve = false, sessionId = '') {
  const path = sessionId ? `/sessions/codex/${sessionId}/message` : '/sessions/codex/new';
  const started = await fetch(`${BASE}${path}`, {
    method: 'POST', headers: H, body: JSON.stringify({ text, ...(sessionId ? {} : { cwd }) }),
  });
  const startBody = await started.json();
  if (started.status !== 202) throw new Error(`start failed ${started.status}: ${JSON.stringify(startBody)}`);

  const events = [];
  let cursor = 0;
  const deadline = Date.now() + 300_000;
  while (Date.now() < deadline) {
    const response = await fetch(`${BASE}/turns/${startBody.turnId}/events?cursor=${cursor}`, { headers: H });
    const poll = await response.json();
    events.push(...(poll.events ?? []));
    cursor = poll.nextCursor ?? cursor;
    if (approve && poll.pending?.length) {
      for (const pending of poll.pending) {
        await fetch(`${BASE}/turns/${startBody.turnId}/approvals/${pending.approvalId}`, {
          method: 'POST', headers: H, body: JSON.stringify({ decision: 'allow' }),
        });
      }
    }
    if (poll.done) return { turnId: startBody.turnId, events };
  }
  throw new Error('Codex test turn timed out');
}

const cwd = '/tmp/wristdeck-codex-appserver';
rmSync(cwd, { recursive: true, force: true });
mkdirSync(cwd, { recursive: true });

console.log('--- streamed file turn ---');
let result = await run(
  'Create index.html containing the exact visible phrase APP SERVER WORKS. Use no dependencies and do not start a development server. Open the finished file with open_path, then reply DONE.',
  cwd,
  true,
);
let done = result.events.find((event) => event.type === 'done');
check('reported a persisted Codex session', result.events.some((event) => event.type === 'session' && event.agent === 'codex'));
check('reported the actual model', result.events.some((event) => event.type === 'model' && event.name));
check('showed startup/progress', result.events.some((event) => event.type === 'status'));
check('completed instead of crashing', Boolean(done), result.events.at(-1)?.message ?? '');
check('created the requested artifact', readFileSync(`${cwd}/index.html`, 'utf8').includes('APP SERVER WORKS'));

const activity = await (await fetch(`${BASE}/activity`, { headers: H })).json();
const finished = activity.recent?.find((item) => item.turnId === result.turnId);
check('recorded the touched file for Done/Open', finished?.touched?.includes(`${cwd}/index.html`), JSON.stringify(finished?.touched ?? []));

console.log('\n--- persisted session resume ---');
const sessionId = result.events.find((event) => event.type === 'session')?.sessionId;
result = await run(
  'Read index.html and reply with only the exact visible phrase it contains. Make no changes and use no network.',
  cwd,
  false,
  sessionId,
);
done = result.events.find((event) => event.type === 'done');
check('resumed the same Codex thread', result.events.some((event) => event.type === 'session' && event.sessionId === sessionId), sessionId);
check('resume retained project context', /APP SERVER WORKS/.test(done?.fullText ?? ''), (done?.fullText ?? '').slice(0, 100));

console.log('\n--- approval round trip ---');
result = await run(
  'Run curl -I https://example.com and report its HTTP status. If the sandbox requires network permission, request it once and wait for the user. Do not use another network target.',
  cwd,
  true,
);
done = result.events.find((event) => event.type === 'done');
check('Codex asked on the watch', result.events.some((event) => event.type === 'approval'));
check('watch approval was delivered', result.events.some((event) => event.type === 'approval_resolved' && event.decision === 'allow'));
check('approved action completed', /200|HTTP/i.test(done?.fullText ?? ''), (done?.fullText ?? '').slice(0, 100));

console.log('\n--- abort cleanup ---');
const abortStart = await fetch(`${BASE}/sessions/codex/new`, {
  method: 'POST', headers: H,
  body: JSON.stringify({ cwd, text: 'Run the shell command sleep 60, then reply done.' }),
});
const abortBody = await abortStart.json();
check('abort test started', abortStart.status === 202, JSON.stringify(abortBody));
let abortCursor = 0;
let sawRunning = false;
const abortDeadline = Date.now() + 90_000;
while (Date.now() < abortDeadline && !sawRunning) {
  const poll = await (await fetch(`${BASE}/turns/${abortBody.turnId}/events?cursor=${abortCursor}`, { headers: H })).json();
  abortCursor = poll.nextCursor ?? abortCursor;
  sawRunning = poll.events?.some((event) => event.type === 'status' && /sleep 60/.test(event.label ?? '')) ?? false;
  if (poll.done) break;
}
await fetch(`${BASE}/turns/${abortBody.turnId}/abort`, { method: 'POST', headers: H });
const aborted = await (await fetch(`${BASE}/turns/${abortBody.turnId}/events?cursor=0`, { headers: H })).json();
check('abort reached a running Codex command', sawRunning);
check('abort finished the watch turn', aborted.done && aborted.events?.some((event) => event.type === 'error' && /Stopped/.test(event.message ?? '')));

console.log(failures === 0 ? '\nALL PASS' : `\n${failures} FAILURES`);
process.exit(failures === 0 ? 0 : 1);
