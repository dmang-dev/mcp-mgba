# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-05-07

Initial public release.

### Added

- **Lua bridge (`lua/bridge.lua`)** that runs inside mGBA's scripting engine
  and serves newline-delimited JSON-RPC over a loopback TCP socket on
  port 8765.
- **Pure-Lua JSON encode/decode (`lua/json.lua`)** with no external deps,
  for use in mGBA's scripting environment which lacks LuaSocket and
  doesn't expose `dkjson` etc.
- **Node.js MCP server (`dist/index.js`)** that translates MCP tool calls
  into JSON-RPC over the bridge, with lazy reconnect so bridge reloads
  don't require restarting the MCP host.
- **15 MCP tools**: `mgba_ping`, `mgba_get_info`, `mgba_read8/16/32`,
  `mgba_write8/16/32`, `mgba_read_range`, `mgba_press_buttons`,
  `mgba_advance_frames`, `mgba_pause`, `mgba_unpause`, `mgba_reset`,
  `mgba_screenshot`.
- **Cross-platform install paths**: `npm install -g mcp-mgba`,
  `npx -y mcp-mgba`, or clone-and-build.
- **GitHub Actions CI** building on Node 18/20/22 across
  Linux/macOS/Windows.

### Worked around (mGBA scripting API quirks)

- mGBA sockets need `socket:poll()` called every frame as a side-effect to
  flush the internal event queue — without it, `accept()` and `hasdata()`
  always see stale state.
- `socket:receive()` requires an explicit max-bytes argument, otherwise
  errors with "invoking failed".
- `emu:read8/16/32` and `emu:write8/16/32` are intermittently flaky when
  called via `pcall` from a frame callback. Reads now go through
  `emu:readRange` (reliable), and writes use a retry loop.
- `emu:screenshot(path)` writes a PNG directly — does not return an image
  object as some other emulator scripting APIs do.

[Unreleased]: https://github.com/dmang-dev/mcp-mgba/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/dmang-dev/mcp-mgba/releases/tag/v0.1.0
