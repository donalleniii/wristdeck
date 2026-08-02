// One-shot Haiku summary for TTS, via the Agent SDK so it reuses the existing
// Claude Code login. No tools, no settings, single turn.
import { query } from '@anthropic-ai/claude-agent-sdk';

export async function summarizeForSpeech(fullText: string): Promise<string | null> {
  const q = query({
    prompt:
      'Summarize this coding-agent reply in 1 to 3 short spoken sentences. ' +
      'Plain words only: no markdown, no code, no file paths unless essential.\n\n' +
      fullText.slice(0, 8000),
    options: {
      model: 'haiku',
      maxTurns: 1,
      settingSources: [],
      systemPrompt: 'You summarize text for text-to-speech on a smartwatch. Reply with only the summary.',
      allowedTools: [],
      canUseTool: async () => ({ behavior: 'deny', message: 'no tools' }),
    },
  });
  for await (const msg of q) {
    if (msg.type === 'result') {
      return msg.subtype === 'success' ? msg.result : null;
    }
  }
  return null;
}
