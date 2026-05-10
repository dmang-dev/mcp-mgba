# Game Boy / GBC compatibility findings

Findings from a real GB-targeted MCP session against the
[totp-gb](https://github.com/totp-gb) project (a TOTP authenticator
for DMG/CGB/SGB). The bridge was reachable and most read paths
worked; three specific pain points blocked unattended end-to-end
testing on GB ROMs and would help to fix.

This is a sibling-project report; nothing in this repo needs
to ship for this MCP server's primary use case (GBA homebrew
testing). But if GB/GBC support is in scope, here's what we hit.

---

## 1. `emu:write8` does not trigger MBC commands on GB

### Symptom

A GB ROM with an MBC3 cartridge (battery-backed SRAM at `0xA000`)
needs a "RAM enable" command — write `0x0A` to any address in
`0x0000`–`0x1FFF`. From Lua / MCP we tried:

```text
mgba_write8(0x0000, 0x0A)   -> "Wrote 10 (0xA) -> 0x0"
mgba_write8(0xA000, 0xDE)   -> "Wrote 222 (0xDE) -> 0xA000"
mgba_read8 (0xA000)         -> 222 (0xDE)            (looks ok)
mgba_read8 (0xA00A)         -> 222 (0xDE)            (every read returns last write)
```

Every read of disabled SRAM returns the value of the **last
write to anywhere**, which is the classic "open-bus echo"
behaviour of a real DMG when SRAM is disabled. So the read
back of `0xDE` was a coincidence, not real persistence — the
write to `0x0000` did **not** trigger MBC RAM enable.

### Root cause guess

`emu:write8` in mGBA's Lua API is the **debug-direct** memory
write — it bypasses the bus model, including the cartridge MBC
state machine. So writes to ROM region `0x0000`–`0x7FFF` are
no-ops (ROM is read-only at the bus level), and writes to
`0xA000`–`0xBFFF` go to whatever underlying SRAM buffer mGBA
allocates regardless of MBC enable state.

For ARM platforms (GBA) this never bites because there's no
MBC; the cart-RAM region is just SRAM, mapped 1:1.

### What would help

Expose a `mgba_bus_write8` (or `mgba_mbc_write8`) command that
goes through `core->busWrite8`, so MBC register writes are
honoured. Or a higher-level `mgba_sram_seed(offset, bytes[])`
helper that wraps the enable / write / disable sequence for
MBC1/3/5 cartridges.

### Workaround we used

Added a `TEST_SEED_ON_BOOT` `#ifdef` branch in `storage_init` that
re-seeds SRAM (via the running app's own MBC-aware code path) at
every boot. The MCP harness then only has to load the seeded ROM
and read state, never write SRAM.

---

## 2. `emu:pause` / `emu:unpause` / `emu:frameAdvance` are nil

### Symptom

```text
mgba_pause          -> RPC error: attempt to call a nil value (method 'pause')
mgba_advance_frames -> RPC error: attempt to call a nil value (method 'frameAdvance')
```

Tested against an mGBA build that's reachable as a bridge host —
exact version unknown (a `mgba_version` info field would help).
`emu:reset`, `emu:read8/16/32`, `emu:write8/16/32`, `emu:readRange`,
`emu:setKeys`, `emu:screenshot`, `emu:getGameTitle`, `emu:getGameCode`,
and `emu:currentFrame` all worked; only the pause / step methods
were missing.

### Impact

Without `frameAdvance`, the bridge can't pace operations atomically.
Every MCP call's network latency overlaps with emulation, so:

- Multi-byte SRAM seeds run into MBC state changes mid-batch.
- Sequenced button presses race the frame callback (see #3).
- Screenshots can't be taken at a deterministic emulator state.

### What would help

The bridge currently has the methods on a hard `assert`-via-call
path. Wrap them in a feature-detect at startup:

```lua
local has_pause   = type(emu.pause)        == "function"
local has_advance = type(emu.frameAdvance) == "function"
                 or type(emu.runFrame)     == "function"
                 or type(emu.step)         == "function"

local function safe_advance(n)
    if emu.frameAdvance then for _=1,n do emu:frameAdvance() end
    elseif emu.runFrame then for _=1,n do emu:runFrame()    end
    elseif emu.step     then for _=1,n do emu:step()        end
    else error("frame-advance API not available in this mGBA")
    end
end
```

And surface the available methods in the result of `mgba_get_info`
so MCP clients can see what's actually supported.

---

## 3. `mgba_press_buttons` consecutive calls overwrite each other

### Symptom

Pressing **Right** three times in a row to bump a counter from
1970 to 1973:

```text
mgba_press_buttons(["Right"], frames=2)   -> queued
mgba_press_buttons(["Right"], frames=2)   -> queued (overwrites)
mgba_press_buttons(["Right"], frames=2)   -> queued (overwrites)
# screen shows: counter advanced to 1971  (one increment, not three)
```

### Root cause

`cmd_press_buttons` in `bridge.lua` sets `hold_bits` /
`hold_frames` and returns immediately. The frame callback
applies them on the next vblank. If three MCP calls arrive
within ~1 frame (~16 ms — easily achieved over loopback TCP),
the second and third calls **replace** the queued state before
the first press has been observed by the running ROM.

The result on screen is one continuous press, which the ROM's
edge-trigger input handling registers as a single key event.

### What would help

A few options, ranked:

1. **Implicit pacing**: `cmd_press_buttons` blocks until
   `hold_frames == 0` before returning. Forces serialisation.
   Requires either coroutines or a small busy-wait against the
   frame callback. Easiest to implement once `frameAdvance` is
   available.
2. **Press queue**: convert `hold_bits/hold_frames` to a FIFO of
   `{bits, frames}` records. Each frame consumes from the head,
   release-to-zero between records. Multiple presses chain
   correctly; ordering is preserved.
3. **Explicit `wait` parameter**: `mgba_press_buttons` grows a
   `release_frames` field (default 1). The frame callback drains
   `frames` of held + `release_frames` of released before
   accepting the next call. New callers opt into pacing without
   breaking old behaviour.

Option 2 is the cleanest. Option 3 is the smallest change.

---

## Useful additions for GB-aware MCP work

If the GB use case ever becomes a priority:

- **Platform-specific address-space help.** The `read8` tool
  description currently lists GBA regions only. A GB section
  in the same docstring (`0x0000` ROM bank0, `0x4000` banked,
  `0x8000` VRAM, `0xA000` SRAM, `0xC000` WRAM, `0xFE00` OAM,
  `0xFF00` IO, `0xFF80` HRAM) would catch users out less.
- **Cartridge / save-RAM helpers.** A `mgba_get_cart_info` that
  returns ROM size, MBC type, SRAM size, has-RTC flag would
  be valuable for any homebrew GB / GBC tool.
- **Save state IO.** `mgba_save_state(slot)` /
  `mgba_load_state(slot)` round out the toolset and let MCP
  bypass the MBC-ignorant `emu:write8` problem entirely — you
  load a state with the SRAM you want, no need to poke MBC.
- **mGBA version in `mgba_get_info`.** Already covered in #2;
  belongs here too.

---

## Workarounds in the dependent project

For posterity if you want to look at how we routed around these:

- **Seed via a `#ifdef TEST_SEED_ON_BOOT` test build.** The ROM
  itself populates SRAM at boot; MCP just loads, screenshots,
  and reads. Commit `398aa2e` in `totp-gb`.
- **Visual-only verification** for the dynamic state. Screenshot
  capture works fine (`mgba_screenshot`); cross-checking the
  displayed 6-digit TOTP against a precomputed window-sequence
  table gave a usable PASS/FAIL signal even without SRAM access.
- **Single-step button presses.** Held the button for many
  frames and accepted slow-motion navigation, instead of fast
  scripted sequences.

Happy to PR any of these fixes if it'd help. Reach out via
the `totp-gb` repo and we'll coordinate.
