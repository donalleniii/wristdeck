// Start a local npm preview independently of a Codex app-server turn, wait
// until it is genuinely reachable, then open it on the Mac.
//
// A server launched by Codex's normal command tool belongs to that app-server
// process and is torn down when the watch turn finishes. This capability is
// deliberately narrow: one named package.json script, one loopback HTTP URL,
// and a project under the user's home or temporary directory.
import { closeSync, openSync } from 'node:fs';
import { readFile, realpath, stat } from 'node:fs/promises';
import { homedir, tmpdir } from 'node:os';
import { isAbsolute, relative, resolve, sep } from 'node:path';
import { execFile, spawn, type ChildProcess } from 'node:child_process';
import { promisify } from 'node:util';

const execFileAsync = promisify(execFile);
const SCRIPT_NAME = /^[a-zA-Z0-9:_-]{1,64}$/;
const MAX_PACKAGE_BYTES = 1_000_000;
const MAX_EXPECTED_TEXT = 160;

export interface LaunchPreviewInput {
  projectPath: unknown;
  url: unknown;
  script?: unknown;
  expectedText?: unknown;
}

export interface LaunchPreviewResult {
  ok: boolean;
  message: string;
  url?: string;
  pid?: number;
  reused?: boolean;
}

export interface LaunchPreviewRuntime {
  startupTimeoutMs?: number;
  openUrl?: (url: string) => Promise<void>;
}

interface ProbeResult {
  reachable: boolean;
  matches: boolean;
}

export async function launchPreview(
  input: LaunchPreviewInput,
  runtime: LaunchPreviewRuntime = {},
): Promise<LaunchPreviewResult> {
  const projectResult = await validateProject(input.projectPath, input.script);
  if (!projectResult.ok) return projectResult;
  const urlResult = validateUrl(input.url);
  if (!urlResult.ok) return urlResult;
  const expectedResult = validateExpectedText(input.expectedText);
  if (!expectedResult.ok) return expectedResult;

  const { projectPath, script } = projectResult;
  const url = urlResult.url;
  const expectedText = expectedResult.expectedText;
  const openUrl = runtime.openUrl ?? openLocalUrl;

  const existing = await probe(url, expectedText);
  if (existing.reachable && !existing.matches) {
    return {
      ok: false,
      message: `launch_preview: another page is already using ${url}, but it does not match the requested preview.`,
    };
  }
  if (existing.matches) {
    try {
      await openUrl(url);
      return { ok: true, message: `Opened the existing preview at ${url}.`, url, reused: true };
    } catch (error) {
      return { ok: false, message: `launch_preview: the page is ready, but the browser could not open: ${errorText(error)}` };
    }
  }

  const logPath = resolve(projectPath, '.wristdeck-preview.log');
  let logFd: number;
  try {
    logFd = openSync(logPath, 'a', 0o600);
  } catch (error) {
    return { ok: false, message: `launch_preview: cannot create ${logPath}: ${errorText(error)}` };
  }

  let child: ChildProcess;
  try {
    const parsed = new URL(url);
    child = spawn('/usr/bin/env', ['npm', 'run', script], {
      cwd: projectPath,
      detached: true,
      stdio: ['ignore', logFd, logFd],
      env: {
        ...process.env,
        BROWSER: 'none',
        HOST: parsed.hostname,
        PORT: parsed.port,
        WRISTDECK_PREVIEW: '1',
      },
    });
    await new Promise<void>((resolveSpawn, rejectSpawn) => {
      child.once('spawn', resolveSpawn);
      child.once('error', rejectSpawn);
    });
  } catch (error) {
    closeSync(logFd);
    return { ok: false, message: `launch_preview: could not start npm run ${script}: ${errorText(error)}` };
  }
  closeSync(logFd);

  const pid = child.pid;
  child.unref();
  const ready = await waitForReady(
    url,
    expectedText,
    child,
    runtime.startupTimeoutMs ?? 45_000,
  );
  if (!ready.matches) {
    stopProcessGroup(child);
    const reason = ready.reachable
      ? 'the server answered, but the page did not match the expected result'
      : 'the server did not become reachable';
    return {
      ok: false,
      message: `launch_preview: ${reason}. See ${logPath}`,
    };
  }

  try {
    await openUrl(url);
  } catch (error) {
    // Keep the now-working preview alive even if Launch Services has a
    // transient problem; the user can still use the returned URL.
    return {
      ok: false,
      message: `launch_preview: the preview is running at ${url}, but the browser could not open: ${errorText(error)}`,
      url,
      pid,
    };
  }

  return {
    ok: true,
    message: `Preview is running and opened at ${url}. It will remain available after this Codex turn ends.`,
    url,
    pid,
  };
}

type ProjectValidation =
  | { ok: true; projectPath: string; script: string }
  | { ok: false; message: string };

async function validateProject(rawPath: unknown, rawScript: unknown): Promise<ProjectValidation> {
  if (typeof rawPath !== 'string' || !rawPath.trim()) {
    return { ok: false, message: 'launch_preview: projectPath is required.' };
  }
  const input = rawPath.trim();
  if (!isAbsolute(input)) {
    return { ok: false, message: 'launch_preview: projectPath must be absolute.' };
  }

  let projectPath: string;
  try {
    projectPath = await realpath(input);
    if (!(await stat(projectPath)).isDirectory()) throw new Error('not a directory');
  } catch {
    return { ok: false, message: `launch_preview: no such project directory: ${input}` };
  }

  const allowedRoots = await Promise.all([homedir(), tmpdir()].map(async (root) => {
    try { return await realpath(root); } catch { return resolve(root); }
  }));
  if (!allowedRoots.some((root) => isWithin(root, projectPath))) {
    return { ok: false, message: 'launch_preview: the project must be under your home or temporary folder.' };
  }

  const script = rawScript == null ? 'dev' : String(rawScript).trim();
  if (!SCRIPT_NAME.test(script)) {
    return { ok: false, message: 'launch_preview: script must be a simple package.json script name.' };
  }

  const packagePath = resolve(projectPath, 'package.json');
  try {
    const packageStat = await stat(packagePath);
    if (!packageStat.isFile() || packageStat.size > MAX_PACKAGE_BYTES) throw new Error('invalid package.json');
    const pkg = JSON.parse(await readFile(packagePath, 'utf8')) as { scripts?: Record<string, unknown> };
    if (typeof pkg.scripts?.[script] !== 'string') {
      return { ok: false, message: `launch_preview: package.json has no "${script}" script.` };
    }
  } catch (error) {
    if (error instanceof SyntaxError) {
      return { ok: false, message: `launch_preview: ${packagePath} is not valid JSON.` };
    }
    return { ok: false, message: `launch_preview: cannot read ${packagePath}.` };
  }

  return { ok: true, projectPath, script };
}

type UrlValidation = { ok: true; url: string } | { ok: false; message: string };

function validateUrl(rawUrl: unknown): UrlValidation {
  if (typeof rawUrl !== 'string' || !rawUrl.trim()) {
    return { ok: false, message: 'launch_preview: a loopback http URL is required.' };
  }
  let parsed: URL;
  try {
    parsed = new URL(rawUrl.trim());
  } catch {
    return { ok: false, message: 'launch_preview: URL is invalid.' };
  }
  const loopback = parsed.hostname === 'localhost' || parsed.hostname === '127.0.0.1' || parsed.hostname === '[::1]';
  const port = Number(parsed.port || '80');
  if (parsed.protocol !== 'http:' || !loopback || parsed.username || parsed.password) {
    return { ok: false, message: 'launch_preview: only plain HTTP localhost URLs are permitted.' };
  }
  if (!Number.isInteger(port) || port < 1024 || port > 65_535) {
    return { ok: false, message: 'launch_preview: use an explicit localhost port from 1024 through 65535.' };
  }
  parsed.hash = '';
  return { ok: true, url: parsed.toString() };
}

type ExpectedValidation =
  | { ok: true; expectedText: string }
  | { ok: false; message: string };

function validateExpectedText(raw: unknown): ExpectedValidation {
  if (raw == null) return { ok: true, expectedText: '' };
  if (typeof raw !== 'string' || !raw.trim() || raw.length > MAX_EXPECTED_TEXT || /[\r\n\0]/.test(raw)) {
    return { ok: false, message: `launch_preview: expectedText must be 1-${MAX_EXPECTED_TEXT} characters on one line.` };
  }
  return { ok: true, expectedText: raw.trim() };
}

async function waitForReady(
  url: string,
  expectedText: string,
  child: ChildProcess,
  timeoutMs: number,
): Promise<ProbeResult> {
  const deadline = Date.now() + timeoutMs;
  let last: ProbeResult = { reachable: false, matches: false };
  while (Date.now() < deadline) {
    last = await probe(url, expectedText);
    if (last.matches) return last;
    if (child.exitCode != null || child.signalCode != null) return last;
    await new Promise((resolveDelay) => setTimeout(resolveDelay, 400));
  }
  return last;
}

async function probe(url: string, expectedText: string): Promise<ProbeResult> {
  try {
    const response = await fetch(url, { signal: AbortSignal.timeout(1_500) });
    const reachable = response.status >= 200 && response.status < 500;
    if (!reachable) return { reachable: false, matches: false };
    if (!expectedText) return { reachable: true, matches: true };
    const body = await response.text();
    return {
      reachable: true,
      matches: body.toLocaleLowerCase().includes(expectedText.toLocaleLowerCase()),
    };
  } catch {
    return { reachable: false, matches: false };
  }
}

async function openLocalUrl(url: string): Promise<void> {
  // No shell and a URL already restricted to loopback HTTP above.
  await execFileAsync('/usr/bin/open', [url], { timeout: 15_000 });
}

function stopProcessGroup(child: ChildProcess): void {
  if (!child.pid) return;
  try {
    process.kill(-child.pid, 'SIGTERM');
  } catch {
    try { child.kill('SIGTERM'); } catch { /* already gone */ }
  }
}

function isWithin(root: string, candidate: string): boolean {
  const rel = relative(root, candidate);
  return rel === '' || rel !== '..' && !rel.startsWith(`..${sep}`) && !isAbsolute(rel);
}

function errorText(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
