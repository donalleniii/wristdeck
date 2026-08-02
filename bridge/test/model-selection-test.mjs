// Model selection must actually take effect, not just render a label.
// The turn is asked to run on Haiku and we assert the bridge reports Haiku back,
// because a picker that changes a chip but not the run is worse than none.
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

const catalog = await (await fetch(`${BASE}/models`, { headers: H })).json();
check('claude offers multiple models', (catalog.claude?.options ?? []).length >= 3,
  (catalog.claude?.options ?? []).map((o) => o.id).join(','));
check('codex reports its configured model', Boolean(catalog.codex?.current), catalog.codex?.current);

check('rejects an unknown model', (await fetch(`${BASE}/models`, {
  method: 'POST', headers: H, body: JSON.stringify({ agent: 'claude', model: 'not-a-model' }),
})).status === 400);

const set = await fetch(`${BASE}/models`, {
  method: 'POST', headers: H, body: JSON.stringify({ agent: 'claude', model: 'haiku' }),
});
check('accepts a real model', set.status === 200);
check('default now reports haiku', (await set.json()).claude.current === 'haiku');

// Now prove a turn actually RUNS on the requested model.
async function modelUsedFor(requested) {
  const r = await fetch(`${BASE}/sessions/claude/new`, {
    method: 'POST', headers: H,
    body: JSON.stringify({ cwd: '/tmp', text: 'Reply with the single word: ok. Use no tools.', model: requested }),
  });
  const { turnId } = await r.json();
  let cursor = 0, seen = null;
  const deadline = Date.now() + 180000;
  while (Date.now() < deadline) {
    const p = await (await fetch(`${BASE}/turns/${turnId}/events?cursor=${cursor}`, { headers: H })).json();
    for (const e of p.events) if (e.type === 'model') seen = e.name;
    cursor = p.nextCursor;
    if (p.done) break;
  }
  return seen;
}

const haiku = await modelUsedFor('haiku');
check('turn requested as haiku ran on haiku', /haiku/i.test(haiku ?? ''), haiku ?? 'no model event');

const opus = await modelUsedFor('opus');
check('turn requested as opus ran on opus', /opus/i.test(opus ?? ''), opus ?? 'no model event');
check('the two turns used different models', haiku !== opus, `${haiku} vs ${opus}`);

// Leave the default somewhere sensible.
await fetch(`${BASE}/models`, {
  method: 'POST', headers: H, body: JSON.stringify({ agent: 'claude', model: 'sonnet' }),
});

console.log(fail === 0 ? '\nALL PASS' : `\n${fail} FAILURES`);
process.exit(fail === 0 ? 0 : 1);
