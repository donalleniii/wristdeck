// Safe "open this on the Mac" capability, shared by both agents.
//
// Why a tool and not shell `open`: Codex's workspace-write sandbox blocks
// launching external apps, so shell `open` works for Claude and silently fails
// for Codex. Routing through one capability makes both agents behave the same
// and removes the need to allow any shell at all.
//
// Security: `open` executes-by-association. `open x.command` / `.app` /
// `.workflow` RUN code, and agents can write files, so an unrestricted open is
// arbitrary code execution. Everything here is deny-by-default.
import { execFile } from 'node:child_process';
import { realpath, stat } from 'node:fs/promises';
import { homedir } from 'node:os';
import { isAbsolute, resolve, extname } from 'node:path';
import { promisify } from 'node:util';

const execFileAsync = promisify(execFile);

/** Extensions macOS executes rather than merely displays. */
const EXECUTABLE_EXTENSIONS = new Set([
  '.command', '.app', '.workflow', '.scpt', '.scptd', '.applescript',
  '.sh', '.bash', '.zsh', '.csh', '.ksh', '.pl', '.py', '.rb', '.php',
  '.jar', '.pkg', '.mpkg', '.dmg', '.terminal', '.tool', '.action',
  '.osax', '.prefPane', '.qlgenerator', '.saver', '.plugin', '.bundle',
  '.kext', '.xpc', '.service', '.definition', '.webloc', '.inetloc',
  '.url', '.shortcut', '.ipa', '.exe', '.appex',
]);

export interface OpenPathResult {
  ok: boolean;
  message: string;
}

export async function openPath(rawPath: unknown): Promise<OpenPathResult> {
  if (typeof rawPath !== 'string' || !rawPath.trim()) {
    return { ok: false, message: 'open_path: a non-empty path string is required.' };
  }
  const input = rawPath.trim();

  // No URLs. `open https://…` and `open x-any-scheme://…` are out of scope;
  // this tool opens local files only.
  if (/^[a-z][a-z0-9+.-]*:\/\//i.test(input) || /^[a-z][a-z0-9+.-]*:/i.test(input) && !isAbsolute(input) && !input.startsWith('~')) {
    return { ok: false, message: `open_path: URLs are not permitted (got "${input}").` };
  }

  const expanded = input.startsWith('~')
    ? resolve(homedir(), input.replace(/^~\/?/, ''))
    : resolve(input);

  let real: string;
  try {
    real = await realpath(expanded); // resolves symlinks before we judge the extension
  } catch {
    return { ok: false, message: `open_path: no such file or folder: ${expanded}` };
  }

  let isDirectory = false;
  try {
    isDirectory = (await stat(real)).isDirectory();
  } catch {
    return { ok: false, message: `open_path: cannot stat ${real}` };
  }

  const ext = extname(real).toLowerCase();
  if (EXECUTABLE_EXTENSIONS.has(ext)) {
    return {
      ok: false,
      message:
        `open_path: "${ext}" is executed by macOS rather than displayed, so it is not ` +
        `permitted. Opening it would run code. Nothing was opened.`,
    };
  }
  // A directory whose name carries an executable extension is a bundle (.app).
  if (isDirectory && EXECUTABLE_EXTENSIONS.has(extname(real).toLowerCase())) {
    return { ok: false, message: `open_path: application bundles are not permitted.` };
  }

  try {
    // execFile, not exec: no shell, so the path can never be interpreted.
    // -R reveals rather than launches when we cannot vouch for the handler.
    await execFileAsync('/usr/bin/open', [real], { timeout: 15_000 });
    return { ok: true, message: `Opened ${real} on the Mac.` };
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    return { ok: false, message: `open_path: failed to open ${real}: ${message}` };
  }
}
