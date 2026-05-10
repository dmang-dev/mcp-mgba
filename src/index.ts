#!/usr/bin/env node
import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { MgbaClient } from "./mgba.js";
import { registerTools } from "./tools.js";

const HOST = process.env.MGBA_HOST ?? "127.0.0.1";
const PORT = parseInt(process.env.MGBA_PORT ?? "8765", 10);

async function main() {
  const mgba = new MgbaClient(HOST, PORT);

  // Connect eagerly — if mGBA isn't running the server still starts, but
  // each tool call will return a clear "not connected" error rather than
  // crashing the MCP host.
  try {
    await mgba.connect();
    process.stderr.write(`[mcp-mgba] connected to mGBA bridge at ${HOST}:${PORT}\n`);
  } catch (err) {
    process.stderr.write(
      `[mcp-mgba] WARNING: could not connect to mGBA bridge (${HOST}:${PORT}): ${err}\n` +
      `           Start mGBA, load a ROM, then open Tools > Scripting and run lua/bridge.lua.\n`,
    );
  }

  const server = new Server(
    { name: "mcp-mgba", version: "0.3.0" },
    { capabilities: { tools: {} } },
  );

  registerTools(server, mgba);

  const transport = new StdioServerTransport();
  await server.connect(transport);
  process.stderr.write("[mcp-mgba] MCP server ready (stdio)\n");
}

main().catch((err) => {
  process.stderr.write(`[mcp-mgba] fatal: ${err}\n`);
  process.exit(1);
});
