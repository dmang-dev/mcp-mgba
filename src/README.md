# src/

TypeScript source for the `mcp-mgba` MCP server (Node.js). Compiled into
`../dist/` by `tsc` — that's what the published `mcp-mgba` bin runs.

## Files

- **`index.ts`** — stdio MCP entrypoint. Reads `MGBA_HOST` / `MGBA_PORT`,
  eager-connects to the Lua bridge, registers tools, then awaits MCP requests
  on stdio. If the bridge isn't reachable at startup the server still launches
  and surfaces a clear error per tool call.
- **`mgba.ts`** — TCP client to `lua/bridge.lua`. Owns the socket, frames JSON
  requests, matches responses by id, surfaces RPC errors as exceptions.
- **`tools.ts`** — registers every MCP tool against the SDK server. Holds the
  per-platform memory-region cheat sheets (GBA / GB / GBC) that are baked
  into tool descriptions.

## Build

```bash
npm run dev      # tsc --watch — autobuild on edits
npm run build    # one-shot
```

Output goes to `../dist/index.js` (marked executable via the build script).
