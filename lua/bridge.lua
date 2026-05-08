-- bridge.lua: mGBA scripting bridge for mcp-mgba
--
-- Exposes a newline-delimited JSON-RPC server on 127.0.0.1:8765.
-- Load via mGBA: Tools > Scripting... > Open Script (select this file).
--
-- json.lua must live in the same folder as this file.
-- socket is a pre-registered global in mGBA's Lua environment.
--
-- mGBA socket API (discovered via metatable probe):
--   bind, listen, accept, connect, send, receive, hasdata, poll, _hook
--
-- Requires mGBA >= 0.10.

local json = require("json")

local HOST = "127.0.0.1"
local PORT = 8765

-- ── GBA key name → bitmask bit index ────────────────────────────────────────
local KEY_BIT = {
    A = 0, B = 1, Select = 2, Start = 3,
    Right = 4, Left = 5, Up = 6, Down = 7,
    R = 8, L = 9,
}

-- ── Per-frame key-hold state ─────────────────────────────────────────────────
local hold_bits   = 0
local hold_frames = 0

-- ── Command handlers ─────────────────────────────────────────────────────────

local function cmd_ping()     return "pong" end
local function cmd_get_info()
    return { title = emu:getGameTitle(), code = emu:getGameCode(), frame = emu:currentFrame() }
end

-- emu:read8/16/32 are flaky when called repeatedly via pcall from the frame
-- callback ("invoking failed" intermittently). emu:readRange is reliable, so
-- we route the typed reads through it and decode little-endian on the Lua side.
local function cmd_read8(p)
    local raw = emu:readRange(assert(p.address, "address required"), 1)
    return raw:byte(1)
end
local function cmd_read16(p)
    local raw = emu:readRange(assert(p.address, "address required"), 2)
    return raw:byte(1) | (raw:byte(2) << 8)
end
local function cmd_read32(p)
    local raw = emu:readRange(assert(p.address, "address required"), 4)
    return raw:byte(1) | (raw:byte(2) << 8) | (raw:byte(3) << 16) | (raw:byte(4) << 24)
end

-- emu:writeN — like emu:readN — intermittently throws "invoking failed" when
-- pcall'd from a frame callback. Retry up to a few times before giving up.
local function retry_call(fn, ...)
    local attempts = 8
    local last_err
    for _ = 1, attempts do
        local ok, err = pcall(fn, ...)
        if ok then return true end
        last_err = err
    end
    error(last_err)
end

local function cmd_write8(p)
    local addr = assert(p.address, "address required")
    local val  = assert(p.value,   "value required")
    retry_call(function() emu:write8(addr, val) end)
    return true
end
local function cmd_write16(p)
    local addr = assert(p.address, "address required")
    local val  = assert(p.value,   "value required")
    retry_call(function() emu:write16(addr, val) end)
    return true
end
local function cmd_write32(p)
    local addr = assert(p.address, "address required")
    local val  = assert(p.value,   "value required")
    retry_call(function() emu:write32(addr, val) end)
    return true
end

local function cmd_read_range(p)
    local addr = assert(p.address, "address required")
    local len  = assert(p.length,  "length required")
    if len > 4096 then error("length exceeds 4096 byte limit") end
    local raw   = emu:readRange(addr, len)
    local bytes = {}
    for i = 1, #raw do bytes[i] = raw:byte(i) end
    return bytes
end

local function cmd_press_buttons(p)
    local keys = assert(p.buttons, "buttons required")
    local bits = 0
    for _, name in ipairs(keys) do
        local b = KEY_BIT[name]
        if not b then error("unknown key: " .. tostring(name)) end
        bits = bits | (1 << b)
    end
    hold_bits   = bits
    hold_frames = p.frames or 1
    return true
end

local function cmd_advance_frames(p)
    local n = p.count or 1
    for _ = 1, n do emu:frameAdvance() end
    return emu:currentFrame()
end

local function cmd_pause()   emu:pause();   return true end
local function cmd_unpause() emu:unpause(); return true end
local function cmd_reset()   emu:reset();   return true end

local function cmd_screenshot(p)
    local path = p.path or (os.tmpname() .. ".png")
    -- mGBA's emu:screenshot takes the destination path directly and writes
    -- the PNG itself; it does not return an image object.
    emu:screenshot(path)
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
    if not cmd.method then
        return nil, { code = -32600, message = "missing method field" }
    end
    local handler = HANDLERS[cmd.method]
    if not handler then
        return nil, { code = -32601, message = "unknown method: " .. cmd.method }
    end
    local ok, result = pcall(handler, cmd.params or {})
    if not ok then
        return nil, { code = -32603, message = tostring(result) }
    end
    return result, nil
end

-- ── Process one client's buffer — call after appending new data ──────────────

local function process_buffer(c)
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
                response = { id = nil, error = { code = -32700, message = "parse error" } }
            end
            c.sock:send(json.encode(response) .. "\n")
        end
    end
end

-- ── Server socket ────────────────────────────────────────────────────────────

local server = assert(socket.tcp(), "socket.tcp() failed")
assert(server:bind(HOST, PORT), "bind failed — port " .. PORT .. " may already be in use")
assert(server:listen(),         "listen failed")

-- Active client table: array of { sock, buf }
local clients = {}

-- ── Per-frame callback ───────────────────────────────────────────────────────

callbacks:add("frame", function()

    -- Key hold
    if hold_frames > 0 then
        emu:setKeys(hold_bits)
        hold_frames = hold_frames - 1
        if hold_frames == 0 then emu:setKeys(0) end
    end

    -- poll() flushes the socket's internal event queue. Without it, accept()
    -- and hasdata() see stale state and never observe new I/O.
    server:poll()
    local client = server:accept()
    if client then
        console:log("[mcp-mgba] client connected")
        table.insert(clients, { sock = client, buf = "" })
    end

    -- Service existing clients
    local i = 1
    while i <= #clients do
        local c = clients[i]
        c.sock:poll()
        if c.sock:hasdata() then
            -- mGBA's receive(maxBytes) reads up to maxBytes — non-blocking
            -- when guarded by hasdata(). Wrap in pcall so any internal error
            -- doesn't spam the console every frame.
            local ok, data = pcall(function() return c.sock:receive(4096) end)
            if ok and data and #data > 0 then
                c.buf = c.buf .. data
                process_buffer(c)
                i = i + 1
            elseif ok and data == nil then
                console:log("[mcp-mgba] client disconnected")
                table.remove(clients, i)
            else
                console:log("[mcp-mgba] receive error: " .. tostring(data))
                table.remove(clients, i)
            end
        else
            i = i + 1
        end
    end
end)

console:log(string.format("[mcp-mgba] bridge listening on %s:%d", HOST, PORT))
console:log("[mcp-mgba] frame callback registered — bridge is active")
