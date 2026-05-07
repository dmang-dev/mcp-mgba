import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
  Tool,
} from "@modelcontextprotocol/sdk/types.js";
import type { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { MgbaClient } from "./mgba.js";

// GBA memory map landmarks (useful in tool descriptions)
const GBA_REGIONS = `
GBA address space:
  0x02000000  EWRAM  (256 KiB, general-purpose)
  0x03000000  IWRAM  (32 KiB, fast stack/variables)
  0x04000000  IO registers
  0x05000000  Palette RAM (1 KiB)
  0x06000000  VRAM (96 KiB)
  0x07000000  OAM (1 KiB)
  0x08000000  ROM (up to 32 MiB, read-only)`.trim();

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
    description: "Get the currently-loaded game title, game code (e.g. AGBE), and frame count.",
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
    description: "Write a single byte value to a GBA memory address. Only works on RAM regions (EWRAM, IWRAM). Writing to ROM has no effect.",
    inputSchema: {
      type: "object",
      required: ["address", "value"],
      properties: {
        address: { type: "integer", description: "GBA RAM address" },
        value:   { type: "integer", minimum: 0, maximum: 255, description: "Byte value (0–255)" },
      },
    },
  },
  {
    name: "mgba_write16",
    description: "Write a 16-bit value to a GBA memory address (little-endian). Address must be 2-byte aligned.",
    inputSchema: {
      type: "object",
      required: ["address", "value"],
      properties: {
        address: { type: "integer", description: "GBA RAM address (2-byte aligned)" },
        value:   { type: "integer", minimum: 0, maximum: 65535, description: "16-bit value (0–65535)" },
      },
    },
  },
  {
    name: "mgba_write32",
    description: "Write a 32-bit value to a GBA memory address (little-endian). Address must be 4-byte aligned.",
    inputSchema: {
      type: "object",
      required: ["address", "value"],
      properties: {
        address: { type: "integer", description: "GBA RAM address (4-byte aligned)" },
        value:   { type: "integer", minimum: 0, description: "32-bit value" },
      },
    },
  },
  {
    name: "mgba_read_range",
    description: "Read a contiguous range of bytes from GBA memory and return them as an array of integers. Maximum 4096 bytes per call.",
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
    name: "mgba_press_buttons",
    description: `Press one or more GBA buttons for a given number of frames. Valid button names: ${VALID_KEYS.join(", ")}.`,
    inputSchema: {
      type: "object",
      required: ["buttons"],
      properties: {
        buttons: {
          type: "array",
          items: { type: "string", enum: VALID_KEYS },
          description: "List of button names to hold simultaneously",
        },
        frames: {
          type: "integer",
          minimum: 1,
          default: 1,
          description: "Number of frames to hold the buttons (at 60 fps; default 1)",
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
    description: "Take a screenshot of the current GBA display and save it to a file. Returns the saved file path.",
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
        const r = await mgba.call<{ title: string; code: string; frame: number }>("get_info");
        return ok(`Title: ${r.title}\nCode:  ${r.code}\nFrame: ${r.frame}`);
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

      case "mgba_press_buttons": {
        await mgba.call("press_buttons", { buttons: p.buttons, frames: p.frames ?? 1 });
        const keys = (p.buttons as string[]).join("+");
        return ok(`Pressed ${keys} for ${p.frames ?? 1} frame(s)`);
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

      default:
        throw new Error(`Unknown tool: ${name}`);
    }
  });
}
