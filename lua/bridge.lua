-- bridge.lua: mGBA scripting bridge for mcp-mgba
--
-- Exposes a newline-delimited JSON-RPC server on 127.0.0.1:8765.
-- Load via mGBA: Tools > Scripting... > Open Script (select this file).
--
-- The script folder must also contain json.lua. mGBA sets the Lua path to
-- the folder containing the loaded script, so require("json") works directly.
--
-- mGBA Lua API reference:
--   https://mgba.io/docs/scripting.html
-- Requires mGBA >= 0.10 for the scripting console.

local json   = require("json")
local socket = require("socket")

local HOST = "127.0.0.1"
local PORT = 8765

-- ── GBA key name → bitmask bit index (GBA keypad register layout) ───────────
local KEY_BIT = {
    A = 0, B = 1, Select = 2, Start = 3,
    Right = 4, Left = 5, Up = 6, Down = 7,
    R = 8, L = 9,
}

-- ── Server socket (non-blocking) ────────────────────────────────────────────
local server = assert(socket.tcp(), "socket.tcp() failed")
assert(server:bind(HOST, PORT),     "bind failed — is port " .. PORT .. " already in use?")
assert(server:listen(4),            "listen failed")
server:settimeout(0)

-- Active client connections: array of { sock, buf }
local clients = {}

-- Per-frame key-hold state
local hold_bits   = 0
local hold_frames = 0

console:log(string.format("[mcp-mgba] bridge listening on %s:%d", HOST, PORT))

-- ── Command dispatcher ───────────────────────────────────────────────────────
--
-- Each handler receives params (table, may be empty) and returns a result
-- value (any JSON-encodable type) or raises an error string.

local function cmd_ping()
    return "pong"
end

local function cmd_get_info()
    return {
        title = emu:getGameTitle(),
        code  = emu:getGameCode(),
        frame = emu:currentFrame(),
    }
end

-- ── Memory ───────────────────────────────────────────────────────────────────

local function cmd_read8(p)
    return emu:read8(assert(p.address, "address required"))
end

local function cmd_read16(p)
    return emu:read16(assert(p.address, "address required"))
end

local function cmd_read32(p)
    return emu:read32(assert(p.address, "address required"))
end

local function cmd_write8(p)
    emu:write8(assert(p.address, "address required"),
               assert(p.value,   "value required"))
    return true
end

local function cmd_write16(p)
    emu:write16(assert(p.address, "address required"),
                assert(p.value,   "value required"))
    return true
end

local function cmd_write32(p)
    emu:write32(assert(p.address, "address required"),
                assert(p.value,   "value required"))
    return true
end

-- Read a contiguous range and return as an array of byte values.
-- emu:readRange(addr, len) returns a Lua string of raw bytes.
local function cmd_read_range(p)
    local addr = assert(p.address, "address required")
    local len  = assert(p.length,  "length required")
    if len > 4096 then error("length exceeds 4096 byte limit") end
    local raw   = emu:readRange(addr, len)
    local bytes = {}
    for i = 1, #raw do bytes[i] = raw:byte(i) end
    return bytes
end

-- ── Input ────────────────────────────────────────────────────────────────────
--
-- mGBA scripting sets raw GBA keys via emu:setKeys(bitmask).
-- The bitmask follows the GBA KEYINPUT register (active-low hardware,
-- but the scripting API uses active-high — 1 = pressed).

local function keys_to_bits(keys_list)
    local bits = 0
    for _, name in ipairs(keys_list) do
        local bit = KEY_BIT[name]
        if not bit then error("unknown key: " .. tostring(name)) end
        bits = bits | (1 << bit)
    end
    return bits
end

-- Hold buttons for N frames (non-blocking; applied in the frame callback).
local function cmd_press_buttons(p)
    local keys   = assert(p.buttons, "buttons required")  -- e.g. {"A","Start"}
    local frames = p.frames or 1
    hold_bits   = keys_to_bits(keys)
    hold_frames = frames
    return true
end

-- ── Emulator control ─────────────────────────────────────────────────────────

local function cmd_advance_frames(p)
    local n = p.count or 1
    for _ = 1, n do emu:frameAdvance() end
    return emu:currentFrame()
end

local function cmd_pause()
    emu:pause()
    return true
end

local function cmd_unpause()
    emu:unpause()
    return true
end

local function cmd_reset()
    emu:reset()
    return true
end

-- ── Screenshot ───────────────────────────────────────────────────────────────
--
-- emu:screenshot() returns an image object; call :save(path) on it.
-- Defaults to the system temp folder so the MCP server can read it back.

local function cmd_screenshot(p)
    local path = p.path
    if not path then
        -- os.tmpname() gives a safe unique name; append .png
        path = os.tmpname():gsub("[^/\\%.%w]", "_") .. ".png"
    end
    local img = emu:screenshot()
    img:save(path)
    return path
end

-- ── Dispatch table ───────────────────────────────────────────────────────────

local HANDLERS = {
    ping           = cmd_ping,
    get_info       = cmd_get_info,
    read8          = cmd_read8,
    read16         = cmd_read16,
    read32         = cmd_read32,
    write8         = cmd_write8,
    write16        = cmd_write16,
    write32        = cmd_write32,
    read_range     = cmd_read_range,
    press_buttons  = cmd_press_buttons,
    advance_frames = cmd_advance_frames,
    pause          = cmd_pause,
    unpause        = cmd_unpause,
    reset          = cmd_reset,
    screenshot     = cmd_screenshot,
}

local function dispatch(cmd)
    local method = cmd.method
    if not method then
        return nil, { code = -32600, message = "missing method field" }
    end
    local handler = HANDLERS[method]
    if not handler then
        return nil, { code = -32601, message = "unknown method: " .. method }
    end
    local ok, result = pcall(handler, cmd.params or {})
    if not ok then
        return nil, { code = -32603, message = tostring(result) }
    end
    return result, nil
end

-- ── Per-frame callback ───────────────────────────────────────────────────────

callbacks:add("frame", function()

    -- Apply any pending key hold
    if hold_frames > 0 then
        emu:setKeys(hold_bits)
        hold_frames = hold_frames - 1
        if hold_frames == 0 then
            emu:setKeys(0)
        end
    end

    -- Accept incoming connections
    local client = server:accept()
    if client then
        client:settimeout(0)
        table.insert(clients, { sock = client, buf = "" })
        console:log("[mcp-mgba] client connected")
    end

    -- Service each connected client
    local i = 1
    while i <= #clients do
        local c    = clients[i]
        local data, err = c.sock:receive(4096)

        if data then
            c.buf = c.buf .. data

            -- Process all complete newline-terminated messages in the buffer
            while true do
                local nl = c.buf:find("\n", 1, true)
                if not nl then break end

                local line = c.buf:sub(1, nl - 1)
                c.buf      = c.buf:sub(nl + 1)

                if #line > 0 then
                    local parse_ok, cmd = pcall(json.decode, line)

                    local response
                    if parse_ok and type(cmd) == "table" then
                        local result, rpc_err = dispatch(cmd)
                        if rpc_err then
                            response = { id = cmd.id, error = rpc_err }
                        else
                            response = { id = cmd.id, result = result }
                        end
                    else
                        response = {
                            id    = nil,
                            error = { code = -32700, message = "parse error" },
                        }
                    end

                    local encoded = json.encode(response) .. "\n"
                    local send_ok, send_err = c.sock:send(encoded)
                    if not send_ok then
                        console:log("[mcp-mgba] send error: " .. tostring(send_err))
                    end
                end
            end

            i = i + 1

        elseif err == "closed" then
            console:log("[mcp-mgba] client disconnected")
            table.remove(clients, i)
            -- don't increment i; next element slid into position i

        else
            -- "timeout" or other transient error — skip this frame
            i = i + 1
        end
    end
end)

console:log("[mcp-mgba] frame callback registered — bridge is active")
