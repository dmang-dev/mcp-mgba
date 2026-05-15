# What I learned building MCP servers for mGBA, PCSX2, and RetroArch

*Three protocols, three different surprises, and a working architecture pattern I'd reuse on any chunky existing software.*

I spent a couple of evenings building three MCP servers — one each for the mGBA, PCSX2, and RetroArch emulators — so I could let Claude read game memory, inject button presses, take screenshots, and automate save-state experiments. By the end I had `npm install -g`-able packages for each, and three pretty different stories about how the bridges came together.

This is what I learned.

## The pitch (in case you're MCP-curious)

[Model Context Protocol](https://modelcontextprotocol.io) is Anthropic's spec for letting language models call tools provided by separate "servers." A server speaks JSON-RPC over stdio (or HTTP), exposes a list of tools with input schemas, and the model can invoke them. Claude Desktop and Claude Code both support it; the wire format isn't Claude-specific — any MCP-aware client works.

Emulators are a great target because they're already running locally with rich state, and most expose some kind of scripting or remote-control interface for ROM hackers, TASers, and cheat engineers. With an MCP bridge in front of one, you can ask Claude to "find the player's HP address by walking into a fight and watching what changes," or "inject a year-2099 epoch into IWRAM and screenshot what the TOTP authenticator displays."

That second one isn't hypothetical — that's the working test for [`totp-gba`](https://github.com/dmang-dev), my own homebrew GBA TOTP authenticator. The first thing I built mcp-mgba for was driving its UI from Claude.

## mcp-mgba: the long way around

The plan was clean. mGBA has a Lua scripting console; I'd write a Lua bridge that opens a TCP socket inside mGBA, and a TypeScript MCP server that talks to it over loopback.

```
+----------------+    stdio     +------------------+   TCP :8765   +------------------+
|   MCP client   |   JSON-RPC   |     mcp-mgba     |  newline JSON |  mGBA emulator   |
| (Claude / etc) | -----------> |     (Node.js)    | ------------> |    bridge.lua    |
+----------------+              +------------------+               +------------------+
```

How hard could that be? mGBA is open source, the scripting API is documented, LuaSocket exists. Three hours, tops.

It took six.

### The Lua environment isn't what you think

First miss: `require("socket")` failed. mGBA doesn't ship with LuaSocket in its embedded Lua environment. There's a `socket` global already exposed, but it's not LuaSocket — it's mGBA's own thing. Different methods, different conventions, no docs page anywhere I could find.

OK, fine, work with what's there. I started writing the bridge using LuaSocket-shaped calls and got hit with this:

```
[ERROR] I:/mcp-mgba/lua/bridge.lua:30:
attempt to call a nil value (method 'settimeout')
```

So `settimeout` doesn't exist either. Now I was guessing. After a few more iterations the script loaded but the bridge accepted TCP connections and never replied to anything.

The breakthrough was a metatable probe in the scripting console:

```lua
local s = socket.tcp()
local mt = getmetatable(s)
for k, v in pairs(mt.__index) do
  console:log(tostring(k))
end
```

Which printed:

```
_hook
listen
bind
receive
poll
hasdata
accept
send
connect
```

Nine methods, no docs anywhere I could find for them. The names `accept`/`bind`/`listen`/`send`/`receive` were familiar enough; `hasdata` and `poll` were the interesting ones.

### `poll()` is the magic incantation

After more probing it turned out:

- `accept()` is non-blocking — returns nil if no connection is waiting. Good.
- `receive()` requires an **explicit max-bytes argument** or it errors with `"invoking failed"`. Bare `receive()` like LuaSocket? Nope.
- `hasdata()` tells you if there's data buffered to read.
- And **`poll()` is a side-effect call that flushes the socket's internal event queue.** Without calling it, `accept()` and `hasdata()` always see stale state. The bridge would receive TCP connections (TCP itself is OS-level), but mGBA's scripting layer never noticed unless you `poll()` first.

This was the single hardest gotcha. You won't find `poll()` referenced in any mGBA documentation I could locate. The only way I figured out it was *the* required call was process of elimination after the metatable probe.

The fix is two lines in the frame callback:

```lua
callbacks:add("frame", function()
  server:poll()                  -- the magic incantation
  local client = server:accept()
  if client then ... end

  for _, c in ipairs(clients) do
    c.sock:poll()                -- also here, for each client
    if c.sock:hasdata() then
      local data = c.sock:receive(4096)
      ...
    end
  end
end)
```

After that, the bridge worked. The smoke test came back showing the GBA's boot ARM branch instruction at ROM address `0x08000000`:

```
read32 0x08000000 -> 0xea00002e   (ARM unconditional branch)
```

I'd been chasing that for hours. It came back instantly.

### The bonus gotchas: read32 is flaky, button presses race

Two more bugs surfaced once I was actually using the bridge:

**`emu:read8/16/32` are intermittently flaky** when called via `pcall` from the frame callback. Same `"invoking failed"` error as the unsized `receive()`. `emu:readRange(addr, n)` is rock-solid, though, so the typed reads now go through `readRange` and decode little-endian on the Lua side:

```lua
local function cmd_read32(p)
  local raw = emu:readRange(assert(p.address), 4)
  return raw:byte(1) | (raw:byte(2) << 8) | (raw:byte(3) << 16) | (raw:byte(4) << 24)
end
```

**`mgba_press_buttons` calls overwrite each other** if they arrive within ~1 frame. Original code:

```lua
local function cmd_press_buttons(p)
  hold_bits   = compute_bits(p.buttons)
  hold_frames = p.frames or 1
end
```

Three "press Right" calls in a row over loopback TCP take ~3ms total, well within one frame. The frame callback applies `hold_bits`/`hold_frames` once, the ROM sees one continuous hold instead of three distinct edge events.

Fix: a FIFO queue with explicit hold + release frames per record. The frame callback drains one record at a time, leaving the keys cleared during the release window so consecutive presses register as separate events.

### The result

```
> Press A on the totp-gba authenticator screen,
  then take a screenshot.

[mgba_press_buttons {"buttons":["A"], "frames":10}]
[mgba_screenshot {"path":"/tmp/after-press.png"}]
```

![Claude driving SAMPLE GAME via mcp-mgba](https://github.com/dmang-dev/mcp-mgba/raw/main/docs/demo.gif)

Six hours from "this should be easy" to "Claude is playing a side-scroller through my MCP server."

## mcp-pine: the wrong kind of easy

After mcp-mgba I figured anything that had a documented protocol would be smoother. PCSX2 and a handful of other PlayStation-family emulators have a built-in IPC protocol called [PINE](https://github.com/GovanifY/pine) — TCP loopback on Windows, Unix domain sockets on Linux/macOS, well-documented opcode table, length-prefixed binary frames. The whole thing is in a 200-line spec.

Two hours. End-to-end smoke test on the first try:

```
read32 0x00100000 -> 0x27BDFFE0  (MIPS addiu sp, sp, -32)
read32 0x00100004 -> 0x3C020011  (MIPS lui v0, 0x11)
read32 0x00100008 -> 0xFFBF0010  (MIPS sd ra, 0x10(sp))
```

That's a textbook MIPS R5900 (PS2 EE) function prologue. PINE was returning real PCSX2 game code from EE main RAM. Clean.

I shipped v0.1.0 the same evening. PCSX2 doesn't expose game-pad input or screenshot via PINE — the protocol is strictly memory + savestate + game metadata — but for cheat hunting and savestate-driven analysis, that's plenty.

### Then I tried to add a bulk read

PINE has no native bulk-read command. Each `READ_CORE_MEMORY` is one address, returns one value. To read 4 KiB I'd need ~512 round-trips at 8 bytes each (using `read64`), or 4096 at 1 byte. That sounded slow until I realized: it's all loopback TCP. Each round-trip is microseconds. I could pipeline — fire all the requests, await all the replies — and a 4 KiB read would take maybe 5ms.

I wrote it that way. Tested at 16 bytes from an unaligned offset. Worked. 32 bytes. Failed:

```
FAIL: Attempt to access memory outside buffer bounds
```

Buffer bounds error inside Node's Buffer reads. I instrumented and found we'd sent **7 PINE requests but received only 6 replies**. PCSX2 had silently dropped one. From then on every reply was off-by-one — a 4-byte READ_CORE_MEMORY response getting decoded as the 8-byte payload of a READ64 it didn't belong to, hence the buffer overrun.

I narrowed it down: 8 in-flight `read64`s pipeline cleanly. 10 hang. Somewhere between 6 and 10 mixed-width requests, PCSX2's PINE server stops keeping up and starts losing them.

That alone wouldn't be too bad — pipeline conservatively, leave headroom. The real lesson came when I tried to recover.

### PCSX2's PINE wedges silently

After the over-pipelining test, **even single-call `pine_ping` started timing out**. Disconnect, reconnect, fresh socket — still timing out. I'd corrupted PCSX2's reply pipeline somehow. Once a single reply gets dropped, PCSX2's queue is permanently desynced and every future request goes into the void. The only recovery is to fully restart the emulator.

That gave me three design changes:

1. **Add a 10-second timeout to every PINE call.** Without one, the bridge would hang forever on a dropped reply. With one, the call rejects cleanly with `"PINE call timed out — peer may have dropped the reply"` and the user knows to restart PCSX2.

2. **Make `pine_read_range` fully serial by default.** No pipelining at all. Loopback TCP is fast enough that this turns out to be a non-issue: I measured **52ms for a full 4096-byte read** on PCSX2 v2.6.3, less than two emulated frames. The pessimistic ~500ms estimate I had in mind was off by 10×.

3. **Document the wedge condition prominently** in the README's troubleshooting section. Anyone else who hits "even a fresh `pine_ping` times out" should know exactly what happened and that the fix is an emulator restart.

The takeaway: **trust nothing about how a real server handles your stress patterns, no matter how clean the protocol spec looks.** PINE is a perfectly good wire format. PCSX2's *implementation* of PINE has a fragile request queue. Those two are different things, and you only learn the second by trying.

## mcp-retroarch: when the third one just works

By the time I got to RetroArch I had a mental model. Build the wire-protocol client (small, dumb), write the MCP tool layer (friendly, schema'd), expect a surprise.

RetroArch's [Network Control Interface](https://docs.libretro.com/development/retroarch/network-control-interface/) is a text-based UDP protocol on port 55355. You send `"READ_CORE_MEMORY 0x0000 16\n"` as a UDP datagram, you get back `"READ_CORE_MEMORY 0x0000 d3 00 00 ea ..."` as another datagram. Strip the prefix, parse the hex, done.

I wrote it the same evening. First-shot smoke test:

```
=== version ===
  1.22.2

=== status ===
  { state: 'paused', system: 'game_boy_advance',
    game: 'totp-gba-test', crc32: '15b64471' }

=== read 16 bytes via memory map at 0x0000 ===
  d3 00 00 ea  e1 00 00 ea  0c 00 00 ea  df 00 00 ea
```

Those bytes are GBA interrupt vectors — each `ea` is the ARM "branch unconditional" opcode, four pointers to handlers for reset / undefined / SWI / etc. RetroArch was happily serving real BIOS-mapped boot code on the first request.

No surprises. No spelunking. End-to-end working in maybe 90 minutes.

### Why this one was painless

In hindsight, RetroArch had three things going for it:

- **Text protocol.** I could test individual commands with `nc -u`. Couldn't with PINE (binary), couldn't easily with mGBA (custom Lua bridge). When the wire format is `"COMMAND args\n"`, debugging takes seconds.
- **Two memory APIs with built-in graceful degradation.** RetroArch exposes both `READ_CORE_MEMORY` (system memory map) and `READ_CORE_RAM` (CHEEVOS achievement-style addresses). If a libretro core doesn't define a memory map, the CHEEVOS path usually still works. I shipped both as separate tools (`retroarch_read_memory` and `retroarch_read_ram`) and documented the fallback strategy.
- **The "tap into RetroArch hotkeys" model.** Pause, frame-advance, reset, screenshot all work because they're literally the same keypresses RetroArch responds to from the keyboard. Reuses well-tested code paths.

The one wart: the NCI doesn't expose game-pad input. Only menu navigation and emulator hotkeys. There's a separate "Remote RetroPad" libretro core on UDP port 55400+ that does, but it requires loading that specific core (you can't drive a normal emulation core through it). I documented this as a known limitation and moved on.

## Patterns I'd reuse

Across the three servers, a few patterns paid off enough that I'd reach for them again:

### Probe APIs at runtime when docs are absent

The metatable probe that unblocked mcp-mgba is generally useful. When you're handed an unfamiliar Lua object — or a Python module from a plugin host, or a JS object from a browser sandbox — list its methods first, then write code:

```lua
for k, v in pairs(getmetatable(obj).__index) do console:log(tostring(k)) end
```

```javascript
// In a sandboxed JS environment
console.log(Object.getOwnPropertyNames(Object.getPrototypeOf(obj)));
```

```python
# For a Python object
print([m for m in dir(obj) if not m.startswith('_')])
```

This single trick saved me hours on mGBA. I should have run it on day one.

### Layer the wire protocol behind a small, dumb client

Every one of these servers ended up with the same shape:

```
src/<protocol>.ts   - wire format, one method per protocol command, nothing else
src/tools.ts        - MCP tool definitions, friendly arg validation, hex formatting
src/index.ts        - stdio transport, env-var config, lazy reconnect
```

Keeping the protocol client free of MCP concerns meant I could test it with a 30-line `node -e` script. Adding a new tool is a one-file change in `tools.ts`.

### Feature-detect, don't assume

A user from a sibling project filed a [bug report against mcp-mgba](https://github.com/dmang-dev/mcp-mgba/blob/main/docs/GB-COMPAT-FINDINGS.md) saying that `mgba_pause` returned a cryptic `"attempt to call a nil value (method 'pause')"` error on his build. Turned out his mGBA didn't expose `emu:pause` at all — it was a stripped or older build.

The fix was to feature-detect on the first frame:

```lua
local function detect_caps()
  local function has(name) return type(emu[name]) == "function" end
  CAPS = {
    pause        = has("pause"),
    unpause      = has("unpause"),
    frameAdvance = has("frameAdvance"),
    runFrame     = has("runFrame"),       -- alternative on some builds
    step         = has("step"),           -- alternative on some builds
    -- ...
  }
end
```

And surface what's available in the `get_info` tool's response, so an LLM can branch:

```json
{
  "title": "totp-gba", "code": "AGB-",
  "capabilities": {
    "pause": false, "frameAdvance": false,
    "runFrame": true, "step": true,
    "saveStateSlot": true, "screenshot": true
  }
}
```

Instead of `mgba_advance_frames` failing silently, it picks `runFrame` then `step` as fallbacks. Instead of `mgba_pause` returning a stack trace, it returns `"emu:pause not available on this mGBA build"`.

### Honest scope sections

Every README has a "what this can and cannot do" table near the top. For mcp-pine that's literally:

> ❌ **No game-pad input.** No screenshot. No pause/frame-advance/reset.
>
> ✅ Memory r/w. Save/load state. Game metadata.

This sets expectations cleanly. People who needed input wouldn't waste time installing it; people who wanted RAM hunting know exactly what they're getting.

### Recipes cookbooks

For each server I wrote a `docs/RECIPES.md` with 7-8 copy-paste workflows: "Find the address of a counter you can see on screen," "Snapshot, experiment, restore," "Decode a struct from memory." Each is a self-contained prompt + tool-call sequence.

This made an enormous difference for actual usability. Listing what tools exist isn't enough — you need to show what to *do* with them. The cookbooks let people start solving real problems in their first session.

### Track gotchas in commit messages and CHANGELOGs

Every weird thing I learned ended up in either a code comment, a commit message, or the CHANGELOG. A year from now when someone hits "PCSX2's PINE wedges after pipelining," I want them to find the answer in 30 seconds, not rediscover it.

## What I'd build next

A few obvious extensions, ranked by leverage:

- **`mcp-bizhawk`** — multi-system (NES/SNES/GB/GBC/GBA/Genesis/N64) with the strongest TAS community. Lua bridge needed since BizHawk's Lua doesn't have native sockets, but the Lua API is well-documented.
- **Investigate Remote Retropad for input on RetroArch.** The undocumented wire format on UDP 55400 is a bit of an exploration project, but unlocking input on a multi-system bridge would be a big upgrade.
- **Shared `mcp-emulator-base` package.** Once a fourth server emerges, the 80% common scaffolding (stdio transport, tool registration, lazy-reconnect, hex formatters) is worth extracting. Three is too few; four might be the threshold.

## Wrapping up

Three emulators, three protocols, three different surprises:

| Server | Protocol | The Lesson |
|---|---|---|
| **[mcp-mgba](https://github.com/dmang-dev/mcp-mgba)** | TCP + custom Lua bridge | Probe APIs at runtime when docs are absent. `poll()` is the magic incantation. |
| **[mcp-pine](https://github.com/dmang-dev/mcp-pine)** | TCP/Unix sock + binary opcode | A clean spec doesn't mean a robust implementation. Ship serial, document the wedge case. |
| **[mcp-retroarch](https://github.com/dmang-dev/mcp-retroarch)** | UDP + text commands | Sometimes you do everything you've learned and the third one just works. Enjoy it. |

All three are MIT, npm-installable today:

```bash
npm install -g mcp-mgba
npm install -g mcp-pine
npm install -g mcp-retroarch
```

Source on GitHub at [github.com/dmang-dev](https://github.com/dmang-dev).

The biggest thing I'd tell someone starting an MCP server project around chunky existing software: **the wire protocol is the easy part.** Getting the docs right, the error messages right, the recipes right, the scope honest — that's where the actual user experience lives.

If you build an emulator MCP server (or any MCP server, really), I'd love to see it. Drop a link.
