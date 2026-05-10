# mcp-mgba recipes

Practical examples of driving an mGBA emulator through Claude (or any MCP client). Each recipe is self-contained — copy-paste the prompt at the top of a Claude conversation with `mcp-mgba` registered, and Claude will work through the tool calls.

> Prerequisites: mGBA running, ROM loaded, `bridge.lua` loaded via Tools > Scripting. Test with `mgba_ping` first.

---

## 1. Find the address of a counter you can see on screen

> "I'm running my homebrew RPG. The HP counter on screen reads 100. I want to find which IWRAM address holds it. Walk into a fight, take some damage so HP is now 87, and find the address."

The pattern Claude follows: read a window of IWRAM (e.g. 4096 bytes at `0x03000000`) before and after a known change, then diff for u16/u32 values that went `100 → 87`. With `mgba_read_range` returning byte arrays directly, this fits in 2 tool calls and a quick byte-by-byte scan.

```
1. mgba_read_range(address=0x03000000, length=4096)   # snapshot A (HP=100)
2. <user takes damage>
3. mgba_read_range(address=0x03000000, length=4096)   # snapshot B (HP=87)
4. <Claude diffs A vs B for any u16/u32 that changed 100 → 87>
```

For values outside IWRAM, broaden to `0x02000000` (EWRAM, 256 KiB — needs 64 read_range calls). Game Boy ROMs: scan `0xC000` (WRAM, 8 KiB) and `0xA000` (SRAM, 8 KiB).

---

## 2. Inject a value into a known address

> "The clock variable in my totp-gba ROM is at IWRAM 0x03000148. Set it to epoch 4070908801 (year 2099) so I can see how the TOTP code rolls."

```
mgba_write32(address=0x03000148, value=4070908801)
```

For Game Boy MBC-cartridge SRAM, **don't use** `mgba_write*` to seed save data — those bypass the bus model and won't trigger MBC RAM-enable. Use `mgba_load_state` with a pre-prepared state file instead (see recipe #6).

---

## 3. Verify a memory write actually landed

> "I just wrote 0xDEADBEEF to address X. Read it back and confirm."

```
mgba_write32(address=X, value=3735928559)
mgba_read32(address=X)
```

`mgba_read_range` is more reliable than typed reads (`read32` is intermittently flaky via pcall — see CHANGELOG). For high-confidence verification, use:

```
mgba_read_range(address=X, length=4)
```

and decode little-endian from the bytes.

---

## 4. Drive a side-scroller's character

> "Press Right for half a second, jump (A), then press Right again for half a second."

`mgba_press_buttons` queues each press independently so they fire as **distinct edge events** (not one continuous hold). At 60 fps, 30 frames ≈ half a second:

```
mgba_press_buttons(buttons=["Right"], frames=30)
mgba_press_buttons(buttons=["A"],     frames=4)
mgba_press_buttons(buttons=["Right"], frames=30)
```

Each call returns immediately with the new queue size. Subsequent screenshots will show the result of the queued sequence.

---

## 5. Take a series of screenshots over time

> "Take 6 screenshots, one every second, of the current scene."

```
for i in 1..6:
  mgba_screenshot(path="/tmp/frame_${i}.png")
  <wait 1 second of real time before next call>
```

(MCP doesn't give Claude a sleep tool directly, but the model can intersperse other tool calls or just describe the timing for you to execute. A future recipe will use `mgba_advance_frames` to make this deterministic.)

---

## 6. Snapshot, scribble, restore

> "Save the current state to slot 9, then experiment freely (write to memory, press buttons), then restore."

```
mgba_save_state(slot=9)
# experiment freely — read/write/press anything
mgba_load_state(slot=9)   # back to the snapshot
```

This is the cleanest pattern for "non-destructive exploration" of game state.

---

## 7. Discover what mGBA build supports

> "What can this build of mGBA actually do?"

```
mgba_get_info
```

Returns `capabilities` — a map of `{methodName: bool}` for every optional emu method. Some builds lack `pause`/`unpause`/`frameAdvance`; the bridge falls back to `runFrame` or `step` automatically for frame-advance, but the other tools error explicitly with a clear "not available on this mGBA build" message.

---

## 8. Quick sanity-check the bridge before doing anything

```
mgba_ping        # should return "pong"
mgba_get_info    # confirms ROM loaded, shows capabilities
```

If `ping` fails: emulator's not running, bridge.lua isn't loaded, or the bridge crashed.
If `ping` works but `get_info.rom_loaded` is `false`: load a ROM in mGBA.

---

## Tips for Claude (or other LLMs) using these tools

- **Always start with `mgba_get_info`.** The capabilities map tells you which tools will work, and you can pick fallback strategies.
- **Use `mgba_read_range` for typed reads when reliability matters.** The single-value `read8/16/32` are intermittently flaky on some mGBA builds (see CHANGELOG); `read_range` is rock-solid.
- **Queue button presses, don't hold then release manually.** The press queue handles edge events correctly so each call = one logical button press.
- **For RAM hunting, two snapshots + diff beats incremental reads.** It's easier to spot the 1 changed `u16` in 4096 bytes than to ask "did this address change" 4096 times.
