// Does the wristdeck-tools stdio server actually start and list its tool?
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const child = spawn(process.execPath, [fileURLToPath(new URL('../src/tools/mcpServer.ts', import.meta.url))], {
  stdio: ['pipe', 'pipe', 'pipe'],
});

let out = '';
let err = '';
child.stdout.on('data', (d) => { out += d.toString(); });
child.stderr.on('data', (d) => { err += d.toString(); });

const send = (msg) => child.stdin.write(JSON.stringify(msg) + '\n');

send({ jsonrpc: '2.0', id: 1, method: 'initialize', params: {
  protocolVersion: '2024-11-05',
  capabilities: {},
  clientInfo: { name: 'probe', version: '1.0' },
}});

setTimeout(() => {
  send({ jsonrpc: '2.0', method: 'notifications/initialized', params: {} });
  send({ jsonrpc: '2.0', id: 2, method: 'tools/list', params: {} });
}, 700);

setTimeout(() => {
  child.kill();
  console.log('--- STDOUT ---');
  console.log(out.trim() || '(empty)');
  console.log('--- STDERR ---');
  console.log(err.trim() || '(empty)');
  const listed = /open_path/.test(out);
  console.log(`\n${listed ? 'PASS: server started and listed open_path' : 'FAIL: open_path not listed'}`);
  process.exit(listed ? 0 : 1);
}, 2500);
