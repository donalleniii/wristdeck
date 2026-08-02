// Single source of truth for how wristdeck-tools is launched, so the Claude
// adapter and the Codex config writer can never drift apart.
import { fileURLToPath } from 'node:url';

export const WRISTDECK_MCP_NAME = 'wristdeck-tools';

/** Absolute path to the stdio server entrypoint. */
export const WRISTDECK_MCP_SCRIPT = fileURLToPath(new URL('./mcpServer.ts', import.meta.url));

/** Node 26 runs TypeScript directly, so no build step is involved. */
export const WRISTDECK_MCP_COMMAND = process.execPath;

/** Shape the Claude Agent SDK expects for Options.mcpServers. */
export const WRISTDECK_MCP = {
  [WRISTDECK_MCP_NAME]: {
    type: 'stdio' as const,
    command: WRISTDECK_MCP_COMMAND,
    args: [WRISTDECK_MCP_SCRIPT],
  },
};

/** Tool names as each agent surfaces them, for policy classification. */
export const OPEN_PATH_TOOL_CLAUDE = `mcp__${WRISTDECK_MCP_NAME}__open_path`;
