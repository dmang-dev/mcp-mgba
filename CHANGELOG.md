# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.3.3] - 2026-06-11

Release-plumbing only. No functional change from 0.3.2 — this version exists
solely to exercise the new publishing path.

### Changed

- **Published via npm Trusted Publishing (OIDC)** through a new GitHub
  Actions release workflow, so the package now carries a provenance
  attestation. No source, dependency, or behavior changes.

## [0.3.2] - 2026-06-11

### Changed

- **BREAKING: minimum Node version raised from >=18 to >=22.** Node 18 (EOL
  April 2025) and 20 (EOL April 2026) are no longer supported; only active
  LTS lines are. CI matrix now tests Node 22 + 24, and workflow actions
  bumped to `actions/checkout@v5` / `actions/setup-node@v5` (the v4 actions'
  Node 20 runtime is deprecated by GitHub as of June 2026).
- **Docker base image moved to Debian 13 trixie** (`node:22-trixie-slim`).
  The previous `node:22-slim` is bookworm (Debian 12), whose `zlib1g` carries
  an unpatched integer-overflow CVE; trixie ships the patched zlib while
  staying on Node 22 LTS.
- **`mgba_screenshot` description trimmed** for TDQS conciseness.
- **README badges added** for Socket, Snyk, Bundlephobia, and npmgraph.

### Security

- **Transitive dependencies bumped to clear npm audit advisories.**
  Lockfile-only bump within existing semver ranges: `hono` to >=4.12.21
  (GHSA-xrhx-7g5j-rcj5, GHSA-3hrh-pfw6-9m5x, GHSA-f577-qrjj-4474,
  GHSA-2gcr-mfcq-wcc3) and, where present, `qs` to >=6.15.2
  (GHSA-q8mj-m7cp-5q26). Both arrive via `@modelcontextprotocol/sdk`'s
  HTTP-transport deps, which this stdio server does not use at runtime.
  `npm audit` now reports 0 vulnerabilities.

## [0.3.1] - 2026-05-15

Tool description quality pass — written to Glama's Tool Definition Quality
Score (TDQS) rubric so every tool maximizes Purpose Clarity, Usage
Guidelines, Behavioral Transparency, Parameter Semantics, Conciseness,
and Contextual Completeness.

### Changed

- **Every tool description rewritten to the PURPOSE / USAGE / BEHAVIOR /
  RETURNS template** — explicit error conditions, explicit
  when-to-use-this-vs-sibling guidance (e.g. read8 vs read16 vs
  read_range), explicit destructive-behavior notes for state-mutating
  tools (`mgba_reset`, `mgba_load_state`, `mgba_write*`,
  `mgba_screenshot` overwrite, etc.), and explicit return-value shape.
- **Every parameter now has a description** that adds context beyond
  the JSON Schema (GBA address-space landmarks, alignment, MBC bypass
  reminders on writes, slot-vs-path tradeoffs on savestates).
- **MBC caveat surfaced inline** on every write tool's address
  parameter description, not just the body — direct memory writes
  bypass cartridge bus model, prefer `mgba_load_state` for cart-SRAM
  seeding.
- **read32 resilience documented** — bridge transparently routes
  through `readRange(addr, 4)` and reassembles little-endian to work
  around mGBA's intermittent typed-read flakiness via pcall.

## [0.3.0] - 2026-05-10

Polish pass focused on bulk operations and robustness.

### Added

- **`mgba_write_range`** — bulk write counterpart to `mgba_read_range`.
  Up to 4096 bytes from a JSON byte array in one tool call. Useful for
  seeding SRAM, patching code blocks, installing cheat tables.
  Underlying writes use the same retry shielding as the typed
  `mgba_write*` tools.
- **`docs/RECIPES.md`** — cookbook of common workflows (RAM hunting,
  snapshot-experiment-restore, side-scroller automation, etc.) with
  copy-paste tool-call sequences.

### Changed

- **README troubleshooting section** expanded to cover the four
  most-common gotchas (script-reload-doesn't-clean, capability
  errors, intermittent invoking-failed, press queue not yet on the
  installed version).

## [0.2.0] - 2026-05-09

Game Boy / GBC compatibility pass. Driven by a real-world report
from a sibling project that hit three concrete pain points trying to
use mcp-mgba against a GB ROM (see `docs/GB-COMPAT-FINDINGS.md`).

### Added

- **`mgba_save_state` / `mgba_load_state`** — slot-based (0-9) or
  path-based emulator-state I/O. Cleanest way to seed Game Boy
  cartridge SRAM without fighting MBC.
- **Capabilities map in `mgba_get_info`** — `capabilities` field
  reports which optional emu methods (pause, frameAdvance, etc.)
  this build of mGBA exposes. `platform` and `rom_loaded` flags
  also added.
- **GB / GBC address-space cheat sheet** in `mgba_read*` and
  `mgba_write*` tool descriptions, alongside the GBA map.
- **MBC caveat** explicitly noted in every `mgba_write*` description:
  writes are debug-direct, bypass the cartridge bus model, do not
  trigger MBC commands.
- **`release_frames`** parameter on `mgba_press_buttons`.

### Changed

- **`mgba_press_buttons` now uses a FIFO queue.** Consecutive calls
  no longer overwrite each other — each press holds for its own
  `frames`, then releases for `release_frames`, before the next
  queued press fires. ROMs that detect input via edge-trigger now
  see distinct events. Return value changed from `true` to
  `{queued: true, queue_size: N}`.
- **Capability detection is deferred to the first frame** rather
  than running at script-load time. This avoids crashing when the
  bridge is loaded before a ROM is.
- **Pause / unpause / frame-advance / screenshot / reset / setKeys
  / save_state / load_state** all now check the capabilities map
  before calling the underlying emu method, returning a clean
  `"emu:foo not available on this mGBA build"` error when the
  method isn't exposed.
- **Frame-advance fallback chain:** prefers `emu:frameAdvance`,
  falls back to `emu:runFrame`, then `emu:step`. Builds that have
  any of the three will get working `mgba_advance_frames`.

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

[Unreleased]: https://github.com/dmang-dev/mcp-mgba/compare/v0.3.3...HEAD
[0.3.3]: https://github.com/dmang-dev/mcp-mgba/releases/tag/v0.3.3
[0.3.2]: https://github.com/dmang-dev/mcp-mgba/releases/tag/v0.3.2
[0.3.1]: https://github.com/dmang-dev/mcp-mgba/releases/tag/v0.3.1
[0.3.0]: https://github.com/dmang-dev/mcp-mgba/releases/tag/v0.3.0
[0.2.0]: https://github.com/dmang-dev/mcp-mgba/releases/tag/v0.2.0
[0.1.0]: https://github.com/dmang-dev/mcp-mgba/releases/tag/v0.1.0
