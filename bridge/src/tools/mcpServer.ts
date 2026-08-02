#!/usr/bin/env node
// wristdeck-tools: a tiny stdio MCP server giving BOTH agents the same
// capabilities without any shell access.
//
// Claude reaches it via Options.mcpServers; Codex via [mcp_servers.wristdeck-tools]
// in ~/.codex/config.toml. One implementation, identical behavior, which is the
// point: shell `open` worked for Claude and silently failed inside Codex's sandbox.
//
// Uses the low-level Server API with raw JSON Schema on purpose, to avoid
// coupling to whichever zod major the MCP SDK expects.
import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from '@modelcontextprotocol/sdk/types.js';
import { openPath } from './openPath.ts';

const server = new Server(
  { name: 'wristdeck-tools', version: '0.1.0' },
  { capabilities: { tools: {} } },
);

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [
    {
      name: 'open_path',
      description:
        "Open a file or folder on the user's Mac so they can see it, the same as " +
        'double-clicking it in Finder. Use this instead of a shell `open` command. ' +
        'Only opens local paths that already exist. Refuses URLs and any file type ' +
        'macOS would execute rather than display.',
      inputSchema: {
        type: 'object',
        properties: {
          path: {
            type: 'string',
            description: 'Absolute path (or ~-relative) to an existing file or folder.',
          },
        },
        required: ['path'],
        additionalProperties: false,
      },
    },
  ],
}));

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  if (request.params.name !== 'open_path') {
    return {
      content: [{ type: 'text', text: `Unknown tool: ${request.params.name}` }],
      isError: true,
    };
  }
  const result = await openPath((request.params.arguments ?? {}).path);
  return {
    content: [{ type: 'text', text: result.message }],
    isError: !result.ok,
  };
});

await server.connect(new StdioServerTransport());
