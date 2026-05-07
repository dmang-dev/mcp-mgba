# mcp-mgba

MCP server that bridges Claude (or any MCP client) to the [mGBA](https://mgba.io) Game Boy Advance emulator via its Lua scripting API.

## Architecture

```
Claude / MCP client
       │  stdio (JSON-RPC 2.0)
  mcp-mgba (Node.js)
       │  TCP :8765 (newline-delimited JSON)
  mGBA emulator
       └─ lua/bridge.lua  ← Lua script running inside mGBA
```

The Lua bridge runs inside mGBA's scripting engine and polls for connections on every VBlank frame (~60 Hz). The Node.js server speaks to it over a loopback TCP socket.

## Setup

### 1. mGBA

Download mGBA ≥ 0.10 from <https://mgba.io/downloads.html>.

- Load your ROM: **File > Open…**
- Open the scripting console: **Tools > Scripting…**
- Click **Open Script** and select `lua/bridge.lua` from this repo.

You should see in the console:

```
[mcp-mgba] bridge listening on 127.0.0.1:8765
[mcp-mgba] frame callback registered — bridge is active
```

### 2. MCP server

```powershell
npm install
npm run build
node dist/index.js          # connect to default 127.0.0.1:8765
```

Environment variables:

| Variable    | Default       | Purpose                     |
|-------------|---------------|-----------------------------|
| `MGBA_HOST` | `127.0.0.1`   | Bridge host                 |
| `MGBA_PORT` | `8765`        | Bridge port                 |

### 3. Register with Claude Desktop

Add to `claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "mgba": {
      "command": "node",
      "args": ["I:/mcp-mgba/dist/index.js"]
    }
  }
}
```

## Available tools

| Tool | Description |
|------|-------------|
| `mgba_ping` | Verify bridge connectivity |
| `mgba_get_info` | Game title, code, frame count |
| `mgba_read8/16/32` | Read memory at address |
| `mgba_write8/16/32` | Write to RAM |
| `mgba_read_range` | Read up to 4096 bytes as a byte array |
| `mgba_press_buttons` | Hold GBA buttons for N frames |
| `mgba_advance_frames` | Step emulation N frames |
| `mgba_pause` / `mgba_unpause` | Pause/resume |
| `mgba_reset` | Reset the loaded ROM |
| `mgba_screenshot` | Save a PNG of the current display |

### GBA button names

`A`, `B`, `Select`, `Start`, `Right`, `Left`, `Up`, `Down`, `R`, `L`

### GBA address space

| Range | Region |
|-------|--------|
| `0x02000000` | EWRAM (256 KiB) |
| `0x03000000` | IWRAM (32 KiB) |
| `0x04000000` | IO registers |
| `0x05000000` | Palette RAM |
| `0x06000000` | VRAM |
| `0x07000000` | OAM |
| `0x08000000` | ROM (read-only) |

## totp-gba notes

This server was built alongside the sibling [`totp-gba`](../totp-gba) ROM.
The ROM's software RTC lives in IWRAM — use `mgba_read32` on the IWRAM region
to find `s_vbl_counter` and `s_base_epoch`. With `mgba_write32` you can
inject a new epoch to fast-forward or rewind the TOTP clock without
recompiling.

## Development

```powershell
npm run dev      # tsc --watch
```

The Lua side (`lua/`) needs no build step — edit and reload the script in
mGBA's scripting console.
