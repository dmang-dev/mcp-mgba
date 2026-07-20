# lua/

Emulator-side scripts that run **inside mGBA** via Tools → Scripting → Load script.

## Files

- **`bridge.lua`** — opens a TCP server on `127.0.0.1:8765` and dispatches
  JSON-RPC commands from the `mcp-mgba` Node process. Wire format is
  newline-delimited JSON over the loopback socket. Routes typed
  `read8/16/32` calls through `readRange` internally to avoid a known mGBA
  pcall flakiness.
- **`json.lua`** — vendored pure-Lua JSON encoder/decoder. mGBA's bundled
  Lua has no stdlib JSON.

## Loading

In mGBA: **Tools → Scripting → File → Load script** → `bridge.lua`. Look for
the `frame callback registered — bridge is active` line in the console.

## Editing

No build step. Edit and reload via mGBA's `File → Load script`. Note that mGBA
doesn't fully tear down the previous instance on hot-reload — to apply changes
cleanly, quit mGBA, relaunch, load the ROM, then load `bridge.lua` once.
