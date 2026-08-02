import assert from 'node:assert/strict';
import { createServer } from 'node:net';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import test from 'node:test';
import { launchPreview } from '../src/tools/openPreview.ts';

async function unusedPort() {
  const server = createServer();
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolve);
  });
  const address = server.address();
  const port = typeof address === 'object' && address ? address.port : 0;
  await new Promise((resolve) => server.close(resolve));
  return port;
}

test('launch_preview keeps a verified npm preview alive after returning', async () => {
  const project = await mkdtemp(join(tmpdir(), 'wristdeck-preview-'));
  const port = await unusedPort();
  const url = `http://127.0.0.1:${port}/`;
  let pid;
  let openedUrl = '';

  try {
    await writeFile(join(project, 'package.json'), JSON.stringify({
      private: true,
      scripts: { dev: 'node server.mjs' },
    }));
    await writeFile(join(project, 'server.mjs'), [
      "import { createServer } from 'node:http';",
      "const port = Number(process.env.PORT);",
      "const host = process.env.HOST || '127.0.0.1';",
      "createServer((_req, res) => {",
      "  res.writeHead(200, { 'content-type': 'text/html' });",
      "  res.end('<title>WristDeck Preview Test</title>PREVIEW_READY');",
      "}).listen(port, host);",
    ].join('\n'));

    const result = await launchPreview({
      projectPath: project,
      url,
      expectedText: 'PREVIEW_READY',
    }, {
      startupTimeoutMs: 15_000,
      openUrl: async (target) => { openedUrl = target; },
    });

    assert.equal(result.ok, true, result.message);
    assert.equal(openedUrl, url);
    assert.equal(typeof result.pid, 'number');
    pid = result.pid;

    // The launchPreview call and its spawning MCP process are both done. The
    // detached preview must still answer, which is the WristDeck regression.
    const response = await fetch(url);
    assert.equal(response.status, 200);
    assert.match(await response.text(), /PREVIEW_READY/);
  } finally {
    if (pid) {
      try { process.kill(-pid, 'SIGTERM'); } catch { /* already stopped */ }
    }
    await rm(project, { recursive: true, force: true });
  }
});

test('launch_preview refuses non-loopback URLs', async () => {
  const project = await mkdtemp(join(tmpdir(), 'wristdeck-preview-invalid-'));
  try {
    await writeFile(join(project, 'package.json'), JSON.stringify({ scripts: { dev: 'node server.mjs' } }));
    const result = await launchPreview({
      projectPath: project,
      url: 'https://example.com/',
    });
    assert.equal(result.ok, false);
    assert.match(result.message, /loopback|localhost/i);
  } finally {
    await rm(project, { recursive: true, force: true });
  }
});
