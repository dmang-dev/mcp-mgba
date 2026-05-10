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

-- ── Key name → bitmask bit index ────────────────────────────────────────────
-- The same map covers GBA and GB/GBC: mGBA's setKeys uses platform-appropriate
-- bits, ignoring keys that don't apply (e.g. R/L on DMG). Names match the
-- convention used elsewhere in mGBA scripting.
local KEY_BIT = {
    A = 0, B = 1, Select = 2, Start = 3,
    Right = 4, Left = 5, Up = 6, Down = 7,
    R = 8, L = 9,
}

-- ── Capability detection (deferred until first frame) ──────────────────────
-- The `emu` global only exists once a ROM is loaded; probing it at script-load
-- time crashes when mGBA is sitting on a blank screen. We defer detection to
-- the first frame callback (which only fires once a ROM is running) and cache
-- the result.
local CAPS              -- nil until detected
local advance_one       -- nil until detected; resolves to a function

local function detect_caps()
    local function has(name) return type(emu[name]) == "function" end
    CAPS = {
        pause          = has("pause"),
        unpause        = has("unpause"),
        frameAdvance   = has("frameAdvance"),
        runFrame       = has("runFrame"),       -- alternative name on some builds
        step           = has("step"),           -- alternative name on some builds
        reset          = has("reset"),
        screenshot     = has("screenshot"),
        setKeys        = has("setKeys"),
        saveStateSlot  = has("saveStateSlot"),
        loadStateSlot  = has("loadStateSlot"),
        saveStateFile  = has("saveStateFile"),
        loadStateFile  = has("loadStateFile"),
        readRange      = has("readRange"),
        getGameTitle   = has("getGameTitle"),
        getGameCode    = has("getGameCode"),
        currentFrame   = has("currentFrame"),
        platform       = has("platform"),
    }
    if     CAPS.frameAdvance then advance_one = function() emu:frameAdvance() end
    elseif CAPS.runFrame     then advance_one = function() emu:runFrame()    end
    elseif CAPS.step         then advance_one = function() emu:step()        end
    end
    -- Log what we found (or didn't) once.
    local missing = {}
    for k, v in pairs(CAPS) do if not v then table.insert(missing, k) end end
    if #missing == 0 then
        console:log("[mcp-mgba] all known emu methods present")
    else
        table.sort(missing)
        console:log("[mcp-mgba] missing emu methods: " .. table.concat(missing, ", "))
    end
end

-- Cap-guarded helper for handlers — ensures CAPS is populated and the named
-- method exists before the handler tries to use it.
local function require_cap(name)
    if not CAPS then error("no ROM loaded — capabilities not yet detected") end
    if not CAPS[name] then error("emu:" .. name .. " not available on this mGBA build") end
end

-- ── Press-button queue ──────────────────────────────────────────────────────
-- Each record describes one keypress: hold for `hold` frames, then release
-- for `release` frames (so consecutive presses of the same button generate
-- distinct edges that ROMs see as separate events). Records are pulled FIFO.
local press_queue = {}
local active                   -- { bits, hold_remaining, release_remaining }

-- ── Command handlers ────────────────────────────────────────────────────────

local function cmd_ping() return "pong" end

local function cmd_get_info()
    if not CAPS then return { rom_loaded = false } end
    return {
        rom_loaded   = true,
        title        = CAPS.getGameTitle and emu:getGameTitle() or nil,
        code         = CAPS.getGameCode  and emu:getGameCode()  or nil,
        frame        = CAPS.currentFrame and emu:currentFrame() or nil,
        platform     = CAPS.platform     and emu:platform()     or nil,
        capabilities = CAPS,
    }
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
--
-- IMPORTANT: emu:writeN is debug-direct memory access. It bypasses the bus
-- model, including any cartridge MBC state machine. On Game Boy, that means:
--   * Writes to ROM region (0x0000-0x7FFF) are no-ops — they don't trigger
--     MBC bank switches or RAM-enable.
--   * Writes to SRAM region (0xA000-0xBFFF) hit the underlying buffer
--     regardless of MBC enable state.
-- For seeding cartridge SRAM on GB, prefer save_state / load_state with a
-- pre-prepared state file, or have the ROM seed itself at boot.
local function retry_call(fn, ...)
    local last_err
    for _ = 1, 8 do
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

-- Append one press to the queue. `hold` = frames to hold; `release` = frames
-- to leave keys cleared after, so consecutive presses generate edges.
local function cmd_press_buttons(p)
    require_cap("setKeys")
    local keys = assert(p.buttons, "buttons required")
    local bits = 0
    for _, name in ipairs(keys) do
        local b = KEY_BIT[name]
        if not b then error("unknown key: " .. tostring(name)) end
        bits = bits | (1 << b)
    end
    table.insert(press_queue, {
        bits    = bits,
        hold    = p.frames         or 1,
        release = p.release_frames or 1,
    })
    return { queued = true, queue_size = #press_queue + (active and 1 or 0) }
end

local function cmd_advance_frames(p)
    if not CAPS or not advance_one then error("frame-advance API not available on this mGBA build") end
    local n = p.count or 1
    for _ = 1, n do advance_one() end
    return CAPS.currentFrame and emu:currentFrame() or nil
end

local function cmd_pause()    require_cap("pause");      emu:pause();   return true end
local function cmd_unpause()  require_cap("unpause");    emu:unpause(); return true end
local function cmd_reset()    require_cap("reset");      emu:reset();   return true end

local function cmd_screenshot(p)
    require_cap("screenshot")
    local path = p.path or (os.tmpname() .. ".png")
    emu:screenshot(path)
    return path
end

-- Save / load state. Prefers slot-based API (numeric slot, mGBA-managed file),
-- falls back to file-based API for builds that only expose that.
local function cmd_save_state(p)
    if not CAPS then error("no ROM loaded — capabilities not yet detected") end
    if p.path and CAPS.saveStateFile then
        emu:saveStateFile(p.path); return { path = p.path }
    end
    if CAPS.saveStateSlot then
        local slot = assert(p.slot, "slot required (0-9)")
        emu:saveStateSlot(slot); return { slot = slot }
    end
    error("no save-state API available on this mGBA build")
end
local function cmd_load_state(p)
    if not CAPS then error("no ROM loaded — capabilities not yet detected") end
    if p.path and CAPS.loadStateFile then
        emu:loadStateFile(p.path); return { path = p.path }
    end
    if CAPS.loadStateSlot then
        local slot = assert(p.slot, "slot required (0-9)")
        emu:loadStateSlot(slot); return { slot = slot }
    end
    error("no load-state API available on this mGBA build")
end

-- ── Dispatch table ──────────────────────────────────────────────────────────

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
    save_state     = cmd_save_state,
    load_state     = cmd_load_state,
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

-- ── Process one client's buffer — call after appending new data ─────────────

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

-- ── Server socket ───────────────────────────────────────────────────────────

local server = assert(socket.tcp(), "socket.tcp() failed")
assert(server:bind(HOST, PORT), "bind failed — port " .. PORT .. " may already be in use")
assert(server:listen(),         "listen failed")

local clients = {}

-- ── Per-frame callback ──────────────────────────────────────────────────────

callbacks:add("frame", function()

    -- First-frame: probe emu capabilities. We can only do this once a ROM is
    -- running (emu global doesn't exist until then).
    if not CAPS then detect_caps() end

    -- Drive the press queue: each record holds for N frames, releases for M,
    -- then we move to the next record. This guarantees edges between presses,
    -- so ROMs that detect input via edge-trigger see distinct events.
    if active then
        if active.hold_remaining > 0 then
            emu:setKeys(active.bits)
            active.hold_remaining = active.hold_remaining - 1
        elseif active.release_remaining > 0 then
            emu:setKeys(0)
            active.release_remaining = active.release_remaining - 1
        else
            active = nil
        end
    end
    if not active and #press_queue > 0 then
        local rec = table.remove(press_queue, 1)
        active = { bits = rec.bits, hold_remaining = rec.hold, release_remaining = rec.release }
        emu:setKeys(active.bits)
        active.hold_remaining = active.hold_remaining - 1
    end

    -- poll() flushes the socket's internal event queue. Without it, accept()
    -- and hasdata() see stale state and never observe new I/O.
    server:poll()
    local client = server:accept()
    if client then
        console:log("[mcp-mgba] client connected")
        table.insert(clients, { sock = client, buf = "" })
    end

    local i = 1
    while i <= #clients do
        local c = clients[i]
        c.sock:poll()
        if c.sock:hasdata() then
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
console:log("[mcp-mgba] frame callback registered — capabilities will be probed on first frame")
