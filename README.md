# mcp-mgba

[![npm version](https://img.shields.io/npm/v/mcp-mgba.svg)](https://www.npmjs.com/package/mcp-mgba)
[![npm downloads](https://img.shields.io/npm/dm/mcp-mgba.svg)](https://www.npmjs.com/package/mcp-mgba)
[![CI](https://github.com/dmang-dev/mcp-mgba/actions/workflows/ci.yml/badge.svg)](https://github.com/dmang-dev/mcp-mgba/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/npm/l/mcp-mgba.svg)](LICENSE)
[![Snyk](https://snyk.io/test/npm/mcp-mgba/badge.svg)](https://snyk.io/test/npm/mcp-mgba)
[![Socket](https://img.shields.io/badge/Socket-security-2F7BFF?logo=socket)](https://socket.dev/npm/package/mcp-mgba)
[![Bundlephobia](https://img.shields.io/badge/bundlephobia-size-FF6B81)](https://bundlephobia.com/package/mcp-mgba)
[![npmgraph](https://img.shields.io/badge/npmgraph-dependencies-2496ED)](https://npmgraph.js.org/?q=mcp-mgba)

An [MCP](https://modelcontextprotocol.io) server that exposes the [mGBA](https://mgba.io) Game Boy Advance emulator to any MCP-compatible client (Claude Desktop, Claude Code, etc.).

Lets your model **read and write GBA memory, inject button presses, take screenshots, and step the emulator** — all through a clean tool interface.

![demo](docs/demo.gif)

*Claude driving an in-development homebrew side-scroller through `mgba_press_buttons` — Start to begin, A to confirm New Game, then Right to walk and A to jump. Each frame is captured via `mgba_screenshot`.*

## How it works

```
+------------------+    stdio     +------------------+   TCP :8765   +------------------+
|   MCP client     |   JSON-RPC   |     mcp-mgba     |  newline JSON |  mGBA emulator   |
| (Claude / etc.)  | ===========> |     (Node.js)    | ============> |    bridge.lua    |
+------------------+              +------------------+               +------------------+
```

Two pieces:
- **`lua/bridge.lua`** — runs *inside* mGBA's scripting engine, opens a loopback TCP server on port 8765
- **`dist/index.js`** — Node.js MCP server, talks to the Lua bridge over TCP, exposes tools over stdio

## Requirements

- [mGBA](https://mgba.io/downloads.html) **0.10 or newer** (with Lua scripting)
- **Node.js 22+** (for the MCP server)

## Install

### Option A — install from npm (recommended)

```bash
npm install -g mcp-mgba
```

Puts `mcp-mgba` on your `PATH`. Verify with `mcp-mgba --help` (it'll print a startup line and wait for stdio — `Ctrl+C` to exit).

### Option B — `npx` (no install)

```bash
npx -y mcp-mgba
```

Run on demand. Good for trying it out without committing to a global install.

### Option C — clone and develop

```bash
git clone https://github.com/dmang-dev/mcp-mgba
cd mcp-mgba
npm install        # also runs the build via the `prepare` hook
```

Then reference the absolute path to `dist/index.js` when registering, or `npm install -g .` to symlink the bin globally.

## Set up the mGBA bridge

1. Launch mGBA and load any GBA ROM.
2. Open **Tools > Scripting…**
3. Click **File > Load script** and select `lua/bridge.lua` from this repo.

You should see in the scripting console:
```
[mcp-mgba] bridge listening on 127.0.0.1:8765
[mcp-mgba] frame callback registered — bridge is active
```

If you see a `bind failed` error, the previous instance's socket is still held — quit and relaunch mGBA.

## Register with your MCP client

### Claude Code (CLI)

```bash
claude mcp add mgba --scope user mcp-mgba
```

(if you used Option B without global install, replace `mcp-mgba` with `node /absolute/path/to/dist/index.js`)

Verify:
```bash
claude mcp list
# mgba: mcp-mgba - ✓ Connected
```

### Claude Desktop

Edit `claude_desktop_config.json`:

| Platform | Path |
|---|---|
| macOS    | `~/Library/Application Support/Claude/claude_desktop_config.json` |
| Windows  | `%APPDATA%\Claude\claude_desktop_config.json` |
| Linux    | `~/.config/Claude/claude_desktop_config.json` |

Add (assuming Option A — globally installed):
```json
{
  "mcpServers": {
    "mgba": {
      "command": "mcp-mgba"
    }
  }
}
```

Or with explicit Node + path (Option B):
```json
{
  "mcpServers": {
    "mgba": {
      "command": "node",
      "args": ["/absolute/path/to/mcp-mgba/dist/index.js"]
    }
  }
}
```

Restart Claude Desktop after editing.

### Other MCP clients

The server speaks standard MCP over stdio. Run `mcp-mgba` (or `node dist/index.js`) and connect any MCP client to its stdio.

## Configuration

| Env var     | Default       | Purpose                |
|-------------|---------------|------------------------|
| `MGBA_HOST` | `127.0.0.1`   | Bridge host to dial    |
| `MGBA_PORT` | `8765`        | Bridge port to dial    |

## Tools

| Tool | Description |
|------|-------------|
| `mgba_ping` | Verify bridge connectivity (returns `pong`) |
| `mgba_get_info` | Game title, code, frame count |
| `mgba_read8` / `mgba_read16` / `mgba_read32` | Read memory at an address |
| `mgba_write8` / `mgba_write16` / `mgba_write32` | Write to RAM |
| `mgba_read_range` | Read up to 4096 bytes as a byte array |
| `mgba_write_range` | Write up to 4096 bytes from a byte array |
| `mgba_press_buttons` | Queue a button press (FIFO; consecutive calls produce distinct events) |
| `mgba_advance_frames` | Step the emulator N frames |
| `mgba_pause` / `mgba_unpause` | Pause / resume emulation |
| `mgba_reset` | Reset the loaded ROM |
| `mgba_screenshot` | Save a PNG of the current display |
| `mgba_save_state` / `mgba_load_state` | Save/load emulator state to a slot or path |

See [`docs/RECIPES.md`](docs/RECIPES.md) for end-to-end examples (RAM hunting, snapshot-experiment-restore, side-scroller automation, etc.).

### GBA button names

`A`, `B`, `Select`, `Start`, `Right`, `Left`, `Up`, `Down`, `R`, `L`

### GBA address space (cheat sheet)

| Range          | Region                        |
|----------------|-------------------------------|
| `0x02000000`   | EWRAM (256 KiB, general)      |
| `0x03000000`   | IWRAM (32 KiB, fast)          |
| `0x04000000`   | I/O registers                 |
| `0x05000000`   | Palette RAM                   |
| `0x06000000`   | VRAM                          |
| `0x07000000`   | OAM                           |
| `0x08000000`   | ROM (read-only)               |

## Troubleshooting

| Symptom | Cause / Fix |
|---|---|
| `Cannot reach mGBA bridge at 127.0.0.1:8765` | mGBA isn't running, or `bridge.lua` isn't loaded — open Tools > Scripting and load it |
| `bind failed — port 8765 may already be in use` | A previous mGBA instance still holds the socket; quit and relaunch mGBA |
| Tool calls hang | The bridge script may have errored out silently after a hot-reload — check the mGBA scripting console |
| Tools missing in Claude after install | Restart your MCP client; Claude only enumerates servers on startup |
| Tool calls return data shaped like an old version after editing `bridge.lua` and choosing **Load Script** again | mGBA doesn't fully tear down a previous script when you reload. The new script's `bind()` may succeed but the old frame callback keeps serving requests. **Fix:** quit mGBA entirely, relaunch, load the ROM, then load `bridge.lua` once. Check the console for the `frame callback registered` line — there should be exactly one. |
| `attempt to index a nil value (global 'emu')` at script load | mGBA's `emu` global only exists once a ROM is loaded. Load any ROM first, *then* load `bridge.lua`. (Or load the script first; capability detection will defer until a ROM is loaded.) |
| `emu:foo not available on this mGBA build` for `pause`, `unpause`, `frameAdvance`, etc. | This particular build of mGBA doesn't expose that method. The bridge feature-detects on the first frame; check `mgba_get_info` for the full capabilities map. For `frameAdvance`, the bridge falls back to `runFrame` then `step` automatically. |
| `read8/16/32` returns "invoking failed" intermittently | Known mGBA Lua quirk — the typed read methods are flaky via pcall from the frame callback. The bridge already routes `read8/16/32` through the more reliable `readRange` internally; if you still see this on a write, the retry loop usually clears it within a few attempts. |
| Multiple `press_buttons` calls don't seem to register as distinct events | Older `mgba_press_buttons` (≤0.1.0) had this bug; v0.2.0+ uses a FIFO queue. Make sure you've upgraded with `npm install -g mcp-mgba` and restarted your MCP client. |

## Development

```bash
npm install
npm run dev      # tsc --watch — autobuilds on src/ changes
```

The Lua side (`lua/bridge.lua` and `lua/json.lua`) needs no build step. Edit and reload via mGBA's `File > Load script`.

## Debugging with the MCP Inspector

Browse and call this server's tools interactively with the [MCP Inspector](https://github.com/modelcontextprotocol/inspector):

```bash
npm run inspector
```

Build first if you've edited `src/` since your last `npm install` (`npm run build`, or keep `npm run dev` running). Override the bridge address with `MGBA_HOST` / `MGBA_PORT` (default `127.0.0.1:8765`). `tools/list` works even without mGBA connected; *calling* a tool needs mGBA open with `lua/bridge.lua` loaded.

## License

[MIT](LICENSE)
