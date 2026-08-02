// Proof of work: after a watch-driven turn finishes, grab the screen so the
// watch can show what actually happened. Pairs with auto-open, which puts the
// result on screen a moment earlier.
//
// NOTE: macOS requires Screen Recording permission for the process calling
// `screencapture`. The bridge runs under launchd, so that permission has to be
// granted to whatever binary launchd starts (node). Until it is, captures come
// back either empty or as a desktop-picture-only image; captureScreen() reports
// which so the caller can degrade instead of shipping a black rectangle.
import { execFile } from 'node:child_process';
import { mkdir, rm, stat } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { promisify } from 'node:util';

const execFileAsync = promisify(execFile);
const SHOT_DIR = join(tmpdir(), 'wristdeck-shots');

/** Watch screens are small; a wide capture only needs to survive downscaling. */
const TARGET_WIDTH = 420;

export function shotPath(turnId: string): string {
  return join(SHOT_DIR, `${turnId}.png`);
}

export interface ShotResult {
  ok: boolean;
  path?: string;
  message: string;
}

/** Stores a PNG uploaded by the Mac notch app. */
export async function saveShot(turnId: string, png: Buffer): Promise<void> {
  await mkdir(SHOT_DIR, { recursive: true });
  const { writeFile } = await import('node:fs/promises');
  await writeFile(shotPath(turnId), png);
}

export async function captureScreen(turnId: string): Promise<ShotResult> {
  await mkdir(SHOT_DIR, { recursive: true });
  const path = shotPath(turnId);
  try {
    // -x silences the shutter sound, -o omits window shadows, -C excludes the
    // cursor. Main display only: a multi-display grab is unreadable on a watch.
    await execFileAsync('/usr/sbin/screencapture', ['-x', '-o', '-C', '-D', '1', path], {
      timeout: 12_000,
    });
    const info = await stat(path);
    if (info.size < 1024) {
      await rm(path, { force: true });
      return { ok: false, message: 'capture was empty (Screen Recording permission?)' };
    }
    // Downscale in place so the watch is not pulling a 6MB retina PNG over LTE.
    await execFileAsync('/usr/bin/sips', ['-Z', String(TARGET_WIDTH), path], { timeout: 12_000 });
    return { ok: true, path, message: 'captured' };
  } catch (err) {
    await rm(path, { force: true }).catch(() => undefined);
    const message = err instanceof Error ? err.message : String(err);
    return { ok: false, message };
  }
}

export async function hasShot(turnId: string): Promise<boolean> {
  try {
    return (await stat(shotPath(turnId))).size > 0;
  } catch {
    return false;
  }
}

/** Keeps the shot directory from growing without bound. */
export async function pruneShots(keepTurnIds: string[]): Promise<void> {
  try {
    const { readdir } = await import('node:fs/promises');
    const keep = new Set(keepTurnIds.map((id) => `${id}.png`));
    for (const name of await readdir(SHOT_DIR)) {
      if (!keep.has(name)) await rm(join(SHOT_DIR, name), { force: true });
    }
  } catch {
    // directory may not exist yet
  }
}
