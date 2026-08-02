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
import { launchPreview } from './openPreview.ts';

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
      // Opening an already-existing displayable path is a local, idempotent,
      // read-only side effect. These hints keep rich Codex clients from asking
      // a second generic MCP confirmation after WristDeck's own validation.
      annotations: {
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false,
      },
    },
    {
      name: 'launch_preview',
      description:
        'Start one package.json script as a persistent local preview, wait until ' +
        'the page really responds, and open it in the Mac browser. Use this for ' +
        'web apps that need a server instead of running a long-lived npm command ' +
        'through the shell. The project must be local, and the URL must be an ' +
        'http://localhost or http://127.0.0.1 URL with an explicit port.',
      inputSchema: {
        type: 'object',
        properties: {
          projectPath: {
            type: 'string',
            description: 'Absolute path to the project containing package.json.',
          },
          url: {
            type: 'string',
            description: 'Loopback HTTP URL the preview will serve, including its port.',
          },
          script: {
            type: 'string',
            description: 'package.json script to start. Defaults to dev; start is often better for a built app.',
          },
          expectedText: {
            type: 'string',
            description: 'Optional short text that must appear in the returned HTML before the preview opens.',
          },
        },
        required: ['projectPath', 'url'],
        additionalProperties: false,
      },
      // This starts package code and opens a browser, so rich clients should
      // present a confirmation. WristDeck maps that confirmation to the Watch.
      annotations: {
        readOnlyHint: false,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false,
      },
    },
  ],
}));

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  if (request.params.name === 'open_path') {
    const result = await openPath((request.params.arguments ?? {}).path);
    return {
      content: [{ type: 'text', text: result.message }],
      isError: !result.ok,
    };
  }
  if (request.params.name === 'launch_preview') {
    const args = request.params.arguments ?? {};
    const result = await launchPreview({
      projectPath: args.projectPath,
      url: args.url,
      script: args.script,
      expectedText: args.expectedText,
    });
    return {
      content: [{ type: 'text', text: result.message }],
      isError: !result.ok,
    };
  }
  {
    return {
      content: [{ type: 'text', text: `Unknown tool: ${request.params.name}` }],
      isError: true,
    };
  }
});

await server.connect(new StdioServerTransport());
