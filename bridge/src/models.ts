// Which model each agent runs, and what you are allowed to switch to.
//
// The list lives here rather than in the watch app so adding a model is a
// one-file change on the Mac, with no rebuild-and-reinstall cycle.
import { readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import type { Agent } from './events.ts';

export interface ModelOption {
  /** Passed to the SDK. */
  id: string;
  /** Shown on the watch. */
  label: string;
  /** One short line on why you would pick it. */
  note: string;
}

/// Aliases the Agent SDK accepts directly.
const CLAUDE_MODELS: ModelOption[] = [
  { id: 'opus', label: 'Opus', note: 'Most capable, slowest' },
  { id: 'sonnet', label: 'Sonnet', note: 'Balanced' },
  { id: 'haiku', label: 'Haiku', note: 'Fastest, lightest' },
];

/// Codex takes any model string; read the user's configured default so the UI
/// reports the truth instead of a guess. Add more by editing ~/.codex/config.toml.
function codexModels(): ModelOption[] {
  let configured = 'gpt-5.6-sol';
  try {
    const toml = readFileSync(join(homedir(), '.codex', 'config.toml'), 'utf8');
    const match = toml.match(/^\s*model\s*=\s*"([^"]+)"/m);
    if (match) configured = match[1];
  } catch {
    // fall back to the documented default
  }
  return [{ id: configured, label: configured, note: 'From your Codex config' }];
}

export function optionsFor(agent: Agent): ModelOption[] {
  if (agent === 'codex') return codexModels();
  if (agent === 'claude') return CLAUDE_MODELS;
  return [];
}

/// Per-agent default, changeable at runtime from the watch.
const defaults: Record<string, string> = {
  claude: 'sonnet',
  codex: codexModels()[0].id,
};

export function defaultModel(agent: Agent): string {
  return defaults[agent] ?? '';
}

export function setDefaultModel(agent: Agent, id: string): boolean {
  if (!optionsFor(agent).some((option) => option.id === id)) return false;
  defaults[agent] = id;
  return true;
}

export function catalog(): Record<string, { options: ModelOption[]; current: string }> {
  return {
    claude: { options: optionsFor('claude'), current: defaultModel('claude') },
    codex: { options: optionsFor('codex'), current: defaultModel('codex') },
  };
}
