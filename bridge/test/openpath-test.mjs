// Security suite for open_path. The dangerous cases matter most: `open` executes
// by file association, and agents can write files, so a permissive open is ACE.
import { openPath } from '../src/tools/openPath.ts';
import { mkdtempSync, writeFileSync, mkdirSync, symlinkSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const dir = mkdtempSync(join(tmpdir(), 'wd-openpath-'));
const safeTxt = join(dir, 'notes.txt');
writeFileSync(safeTxt, 'hello');
const evilCommand = join(dir, 'payload.command');
writeFileSync(evilCommand, '#!/bin/sh\necho pwned\n');
const evilApp = join(dir, 'Evil.app');
mkdirSync(evilApp);
const evilShell = join(dir, 'run.sh');
writeFileSync(evilShell, 'echo pwned');
const symlinkToCommand = join(dir, 'innocent.txt-link');
symlinkSync(evilCommand, symlinkToCommand);

let fail = 0;
const check = async (label, path, wantOk) => {
  const r = await openPath(path);
  const ok = r.ok === wantOk;
  if (!ok) fail++;
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${wantOk ? 'allow' : 'deny '}  ${label}  -> ${r.message.slice(0, 78)}`);
};

// must be refused
await check('.command (executes)', evilCommand, false);
await check('.app bundle', evilApp, false);
await check('.sh script', evilShell, false);
await check('symlink pointing at .command', symlinkToCommand, false);
await check('https URL', 'https://example.com', false);
await check('file:// URL', 'file:///etc/passwd', false);
await check('custom scheme', 'x-evil://boom', false);
await check('nonexistent path', join(dir, 'nope.txt'), false);
await check('empty string', '', false);
await check('non-string', 42, false);

// must be allowed (these actually open windows, so keep them to the temp dir)
await check('plain .txt', safeTxt, true);
await check('a real directory', dir, true);

console.log(fail === 0 ? '\nALL PASS' : `\n${fail} FAILURES`);
process.exit(fail === 0 ? 0 : 1);
