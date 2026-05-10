import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
  Tool,
} from "@modelcontextprotocol/sdk/types.js";
import type { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { MgbaClient } from "./mgba.js";

// Address-space cheat sheets (used in tool descriptions). The bridge works on
// any platform mGBA supports; users running GB/GBC ROMs need a different map.
const GBA_REGIONS = `
GBA address space:
  0x02000000  EWRAM  (256 KiB, general-purpose)
  0x03000000  IWRAM  (32 KiB, fast stack/variables)
  0x04000000  IO registers
  0x05000000  Palette RAM (1 KiB)
  0x06000000  VRAM (96 KiB)
  0x07000000  OAM (1 KiB)
  0x08000000  ROM (up to 32 MiB, read-only)

Game Boy / GBC address space (when running a GB/GBC ROM):
  0x0000      ROM bank 0 (16 KiB, read-only on bus; writes here trigger MBC commands but mgba_write* bypasses the bus)
  0x4000      ROM banked (switchable)
  0x8000      VRAM (8 KiB)
  0xA000      Cartridge SRAM (8 KiB) — disabled by default on MBC1/3/5 carts
  0xC000      WRAM (8 KiB; CGB has banked extension to 0xD000)
  0xFE00      OAM (160 B)
  0xFF00      I/O registers
  0xFF80      HRAM (127 B)`.trim();

// MBC caveat — important enough to repeat on every write tool
const MBC_CAVEAT =
  "NOTE: writes use mGBA's debug-direct memory access, which bypasses the cartridge bus model. " +
  "On Game Boy with an MBC cartridge, this means writes to ROM region (0x0000-0x7FFF) won't trigger " +
  "MBC bank-switch / RAM-enable commands, and writes to SRAM (0xA000-0xBFFF) hit the underlying buffer " +
  "regardless of MBC enable state. To seed cartridge SRAM cleanly, use mgba_save_state / mgba_load_state " +
  "with a pre-prepared state file.";

const VALID_KEYS = ["A", "B", "Select", "Start", "Right", "Left", "Up", "Down", "R", "L"];

// ── Tool definitions ─────────────────────────────────────────────────────────

const TOOLS: Tool[] = [
  {
    name: "mgba_ping",
    description: "Check connectivity to the mGBA bridge. Returns 'pong' if the emulator is running and the Lua bridge is loaded.",
    inputSchema: { type: "object", properties: {} },
  },
  {
    name: "mgba_get_info",
    description: "Get the currently-loaded game title, game code (e.g. AGBE), platform identifier, current frame count, and a `capabilities` object listing which optional emu methods this build of mGBA supports (pause, frameAdvance, saveStateSlot, etc.). Use the capabilities map to feature-detect before calling tools that depend on optional methods.",
    inputSchema: { type: "object", properties: {} },
  },
  {
    name: "mgba_read8",
    description: `Read a single unsigned byte (u8) from a GBA memory address.\n\n${GBA_REGIONS}`,
    inputSchema: {
      type: "object",
      required: ["address"],
      properties: {
        address: {
          type: "integer",
          description: "GBA memory address (decimal or hex — use 0x prefix in JSON strings, or pass as decimal integer)",
        },
      },
    },
  },
  {
    name: "mgba_read16",
    description: "Read an unsigned 16-bit little-endian value from a GBA memory address. Address should be 2-byte aligned.",
    inputSchema: {
      type: "object",
      required: ["address"],
      properties: {
        address: { type: "integer", description: "GBA memory address (must be 2-byte aligned)" },
      },
    },
  },
  {
    name: "mgba_read32",
    description: "Read an unsigned 32-bit little-endian value from a GBA memory address. Address should be 4-byte aligned.",
    inputSchema: {
      type: "object",
      required: ["address"],
      properties: {
        address: { type: "integer", description: "GBA memory address (must be 4-byte aligned)" },
      },
    },
  },
  {
    name: "mgba_write8",
    description: `Write a single byte value to a memory address. Only works on RAM regions; writes to ROM are no-ops.\n\n${MBC_CAVEAT}`,
    inputSchema: {
      type: "object",
      required: ["address", "value"],
      properties: {
        address: { type: "integer", description: "RAM address" },
        value:   { type: "integer", minimum: 0, maximum: 255, description: "Byte value (0-255)" },
      },
    },
  },
  {
    name: "mgba_write16",
    description: `Write a 16-bit value (little-endian) to a memory address. Address must be 2-byte aligned.\n\n${MBC_CAVEAT}`,
    inputSchema: {
      type: "object",
      required: ["address", "value"],
      properties: {
        address: { type: "integer", description: "RAM address (2-byte aligned)" },
        value:   { type: "integer", minimum: 0, maximum: 65535, description: "16-bit value (0-65535)" },
      },
    },
  },
  {
    name: "mgba_write32",
    description: `Write a 32-bit value (little-endian) to a memory address. Address must be 4-byte aligned.\n\n${MBC_CAVEAT}`,
    inputSchema: {
      type: "object",
      required: ["address", "value"],
      properties: {
        address: { type: "integer", description: "RAM address (4-byte aligned)" },
        value:   { type: "integer", minimum: 0, description: "32-bit value" },
      },
    },
  },
  {
    name: "mgba_read_range",
    description: "Read a contiguous range of bytes from emulated memory and return them as an array of integers. Maximum 4096 bytes per call.",
    inputSchema: {
      type: "object",
      required: ["address", "length"],
      properties: {
        address: { type: "integer", description: "Start address" },
        length:  { type: "integer", minimum: 1, maximum: 4096, description: "Number of bytes to read" },
      },
    },
  },
  {
    name: "mgba_write_range",
    description: `Write a contiguous range of bytes to emulated RAM in one call. Useful for seeding SRAM, patching code blocks, or installing cheats. Maximum 4096 bytes per call.\n\n${MBC_CAVEAT}`,
    inputSchema: {
      type: "object",
      required: ["address", "bytes"],
      properties: {
        address: { type: "integer", description: "Start address" },
        bytes: {
          type: "array",
          items: { type: "integer", minimum: 0, maximum: 255 },
          minItems: 1,
          maxItems: 4096,
          description: "Array of byte values (0-255). Length cannot exceed 4096.",
        },
      },
    },
  },
  {
    name: "mgba_press_buttons",
    description: `Queue a button-press: hold the given buttons for \`frames\` frames, then release for \`release_frames\` frames before the next queued press starts. Each call appends to the queue rather than overwriting, so consecutive calls produce distinct edge events that ROMs see as separate presses (rather than one continuous hold). Returns immediately; the press fires asynchronously on the emulator's frame callback. Valid button names: ${VALID_KEYS.join(", ")}.`,
    inputSchema: {
      type: "object",
      required: ["buttons"],
      properties: {
        buttons: {
          type: "array",
          items: { type: "string", enum: VALID_KEYS },
          description: "List of button names to hold simultaneously for this press",
        },
        frames: {
          type: "integer",
          minimum: 1,
          default: 1,
          description: "Frames to hold the buttons (at 60 fps; default 1)",
        },
        release_frames: {
          type: "integer",
          minimum: 1,
          default: 1,
          description: "Frames to release keys after the hold, before the next queued press fires (default 1). Increase if a ROM debounces input.",
        },
      },
    },
  },
  {
    name: "mgba_advance_frames",
    description: "Advance emulation by N frames without returning to the event loop. Useful for precise timing in tests.",
    inputSchema: {
      type: "object",
      properties: {
        count: { type: "integer", minimum: 1, default: 1, description: "Number of frames to advance (default 1)" },
      },
    },
  },
  {
    name: "mgba_pause",
    description: "Pause emulation.",
    inputSchema: { type: "object", properties: {} },
  },
  {
    name: "mgba_unpause",
    description: "Resume emulation after a pause.",
    inputSchema: { type: "object", properties: {} },
  },
  {
    name: "mgba_reset",
    description: "Reset the currently-loaded ROM (equivalent to pressing the GBA reset button).",
    inputSchema: { type: "object", properties: {} },
  },
  {
    name: "mgba_screenshot",
    description: "Take a screenshot of the current display and save it to a file. Returns the saved file path.",
    inputSchema: {
      type: "object",
      properties: {
        path: {
          type: "string",
          description: "Absolute file path to save the PNG (optional — defaults to a temp file)",
        },
      },
    },
  },
  {
    name: "mgba_save_state",
    description: "Save the current emulator state. Pass either `slot` (0-9, mGBA-managed slot file) or `path` (absolute file path; only works on builds that expose the file API). Useful for capturing checkpoints to load later — and as a clean way to seed cartridge SRAM on Game Boy without fighting the MBC.",
    inputSchema: {
      type: "object",
      properties: {
        slot: { type: "integer", minimum: 0, maximum: 9, description: "Save state slot (0-9)" },
        path: { type: "string", description: "Absolute file path (alternative to slot)" },
      },
    },
  },
  {
    name: "mgba_load_state",
    description: "Load a previously-saved emulator state. Pass either `slot` (0-9) or `path` (absolute file path). The state must come from the same ROM and a compatible mGBA version.",
    inputSchema: {
      type: "object",
      properties: {
        slot: { type: "integer", minimum: 0, maximum: 9, description: "Save state slot (0-9)" },
        path: { type: "string", description: "Absolute file path (alternative to slot)" },
      },
    },
  },
];

// ── Helpers ──────────────────────────────────────────────────────────────────

function ok(text: string) {
  return { content: [{ type: "text" as const, text }] };
}

function formatHex(n: unknown): string {
  if (typeof n !== "number") return String(n);
  return `${n} (0x${n.toString(16).toUpperCase()})`;
}

// ── Registration ─────────────────────────────────────────────────────────────

export function registerTools(server: Server, mgba: MgbaClient): void {
  server.setRequestHandler(ListToolsRequestSchema, async () => ({ tools: TOOLS }));

  server.setRequestHandler(CallToolRequestSchema, async (req) => {
    const { name, arguments: args = {} } = req.params;
    const p = args as Record<string, unknown>;

    switch (name) {
      case "mgba_ping": {
        const r = await mgba.call<string>("ping");
        return ok(r);
      }

      case "mgba_get_info": {
        const r = await mgba.call<{
          title?: string;
          code?: string;
          frame?: number;
          platform?: number | string;
          capabilities?: Record<string, boolean>;
        }>("get_info");
        const lines = [
          `Title:    ${r.title ?? "(unavailable)"}`,
          `Code:     ${r.code ?? "(unavailable)"}`,
          `Platform: ${r.platform ?? "(unavailable)"}`,
          `Frame:    ${r.frame ?? "(unavailable)"}`,
        ];
        if (r.capabilities) {
          const present = Object.entries(r.capabilities).filter(([, v]) => v).map(([k]) => k);
          const missing = Object.entries(r.capabilities).filter(([, v]) => !v).map(([k]) => k);
          lines.push("");
          lines.push(`Capabilities present: ${present.length ? present.join(", ") : "(none)"}`);
          if (missing.length) lines.push(`Missing on this build: ${missing.join(", ")}`);
        }
        return ok(lines.join("\n"));
      }

      case "mgba_read8": {
        const v = await mgba.call<number>("read8", { address: p.address });
        return ok(`0x${(p.address as number).toString(16).toUpperCase()}: ${formatHex(v)}`);
      }

      case "mgba_read16": {
        const v = await mgba.call<number>("read16", { address: p.address });
        return ok(`0x${(p.address as number).toString(16).toUpperCase()}: ${formatHex(v)}`);
      }

      case "mgba_read32": {
        const v = await mgba.call<number>("read32", { address: p.address });
        return ok(`0x${(p.address as number).toString(16).toUpperCase()}: ${formatHex(v)}`);
      }

      case "mgba_write8": {
        await mgba.call("write8", { address: p.address, value: p.value });
        return ok(`Wrote ${formatHex(p.value)} → 0x${(p.address as number).toString(16).toUpperCase()}`);
      }

      case "mgba_write16": {
        await mgba.call("write16", { address: p.address, value: p.value });
        return ok(`Wrote ${formatHex(p.value)} → 0x${(p.address as number).toString(16).toUpperCase()}`);
      }

      case "mgba_write32": {
        await mgba.call("write32", { address: p.address, value: p.value });
        return ok(`Wrote ${formatHex(p.value)} → 0x${(p.address as number).toString(16).toUpperCase()}`);
      }

      case "mgba_read_range": {
        const bytes = await mgba.call<number[]>("read_range", {
          address: p.address,
          length:  p.length,
        });
        const hex = bytes
          .map((b) => b.toString(16).padStart(2, "0").toUpperCase())
          .join(" ");
        const addr = (p.address as number).toString(16).toUpperCase();
        return ok(`0x${addr} [${bytes.length} bytes]:\n${hex}`);
      }

      case "mgba_write_range": {
        const r = await mgba.call<{ written: number }>("write_range", {
          address: p.address,
          bytes:   p.bytes,
        });
        const addr = (p.address as number).toString(16).toUpperCase();
        return ok(`Wrote ${r.written} bytes → 0x${addr}`);
      }

      case "mgba_press_buttons": {
        const r = await mgba.call<{ queued: boolean; queue_size: number }>("press_buttons", {
          buttons:        p.buttons,
          frames:         p.frames         ?? 1,
          release_frames: p.release_frames ?? 1,
        });
        const keys = (p.buttons as string[]).join("+");
        return ok(
          `Queued press: ${keys} ` +
          `(hold ${p.frames ?? 1}f, release ${p.release_frames ?? 1}f). ` +
          `Queue size: ${r.queue_size}`,
        );
      }

      case "mgba_advance_frames": {
        const frame = await mgba.call<number>("advance_frames", { count: p.count ?? 1 });
        return ok(`Advanced ${p.count ?? 1} frame(s). Current frame: ${frame}`);
      }

      case "mgba_pause": {
        await mgba.call("pause");
        return ok("Emulation paused");
      }

      case "mgba_unpause": {
        await mgba.call("unpause");
        return ok("Emulation resumed");
      }

      case "mgba_reset": {
        await mgba.call("reset");
        return ok("ROM reset");
      }

      case "mgba_screenshot": {
        const path = await mgba.call<string>("screenshot", p.path ? { path: p.path } : {});
        return ok(`Screenshot saved: ${path}`);
      }

      case "mgba_save_state": {
        if (p.slot === undefined && p.path === undefined) {
          throw new Error("provide either `slot` (0-9) or `path`");
        }
        const r = await mgba.call<{ slot?: number; path?: string }>("save_state", {
          ...(p.slot !== undefined ? { slot: p.slot } : {}),
          ...(p.path !== undefined ? { path: p.path } : {}),
        });
        return ok(r.path ? `Saved state to ${r.path}` : `Saved state to slot ${r.slot}`);
      }

      case "mgba_load_state": {
        if (p.slot === undefined && p.path === undefined) {
          throw new Error("provide either `slot` (0-9) or `path`");
        }
        const r = await mgba.call<{ slot?: number; path?: string }>("load_state", {
          ...(p.slot !== undefined ? { slot: p.slot } : {}),
          ...(p.path !== undefined ? { path: p.path } : {}),
        });
        return ok(r.path ? `Loaded state from ${r.path}` : `Loaded state from slot ${r.slot}`);
      }

      default:
        throw new Error(`Unknown tool: ${name}`);
    }
  });
}
