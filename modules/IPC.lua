-- IPC.lua
-- Asynchronous job queue between the CET mod and the companion program, using files.
-- CET has no HTTP or socket API, and its file access is limited to the mod folder,
-- so requests and responses are JSON files in ipc/.
--
--   Lua writes      ipc/req_<id>.json   (written as .tmp then renamed, so it is never read half-written)
--   Companion writes ipc/res_<id>.json   when the job is done
--   Companion writes ipc/heartbeat.json  every second while it runs
--
-- Nothing here blocks: send() returns at once and onUpdate() checks for answers a few times per second.

local json = require("json")

local IPC = {
    dir = "ipc/",
    pollInterval = 0.1,
    heartbeatMaxAge = 5,
    pending = {},       -- id -> { type, callback, elapsed, timeout }
    counter = 0,
    pollTimer = 0,
    heartbeatTimer = 0,
    companion = { online = false, info = nil }
}

function IPC.init(cfg)
    IPC.dir = cfg.dir or IPC.dir
    IPC.pollInterval = cfg.pollInterval or IPC.pollInterval
    IPC.heartbeatMaxAge = cfg.heartbeatMaxAge or IPC.heartbeatMaxAge
    IPC.readHeartbeat()
end

local function writeAtomic(path, text)
    local tmp = path .. ".tmp"
    local f = io.open(tmp, "w")
    if not f then
        return false, "cannot write " .. tmp .. " (does the ipc folder exist?)"
    end
    f:write(text)
    f:close()
    os.remove(path)
    local ok, err = os.rename(tmp, path)
    if not ok then
        return false, "rename failed: " .. tostring(err)
    end
    return true
end

local function readFile(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local text = f:read("*a")
    f:close()
    return text
end

-- Runs a callback without letting an error in it break the update loop.
local function safeCall(cb, ...)
    if not cb then return end
    local ok, err = pcall(cb, ...)
    if not ok then
        print("[CyberAIContext] IPC callback error: " .. tostring(err))
    end
end

--- Sends a job to the companion.
-- @param jobType string  "screenshot", "ocr", "gemini" or "tts"
-- @param payload table   job data (must be JSON-encodable)
-- @param timeout number  seconds before giving up
-- @param callback function(ok, result, err)
-- @return string|nil job id
function IPC.send(jobType, payload, timeout, callback)
    IPC.counter = IPC.counter + 1
    local id = string.format("%d_%d", os.time(), IPC.counter)

    local okEnc, text = pcall(json.encode, {
        id = id,
        type = jobType,
        payload = payload or {},
        created = os.time()
    })
    if not okEnc then
        safeCall(callback, false, nil, "JSON encode failed: " .. tostring(text))
        return nil
    end

    local okWrite, err = writeAtomic(IPC.dir .. "req_" .. id .. ".json", text)
    if not okWrite then
        safeCall(callback, false, nil, err)
        return nil
    end

    IPC.pending[id] = {
        type = jobType,
        callback = callback,
        elapsed = 0,
        timeout = timeout or 10
    }
    return id
end

--- Writes a JSON file in the ipc folder (not a job, just a file for other tools).
function IPC.writeFile(name, text)
    return writeAtomic(IPC.dir .. name, text)
end

function IPC.readHeartbeat()
    local text = readFile(IPC.dir .. "heartbeat.json")
    if not text then
        IPC.companion.online = false
        IPC.companion.info = nil
        return
    end
    local ok, data = pcall(json.decode, text)
    if ok and type(data) == "table" and type(data.time) == "number" then
        IPC.companion.info = data
        IPC.companion.online = (os.time() - data.time) <= IPC.heartbeatMaxAge
    else
        IPC.companion.online = false
    end
end

function IPC.isCompanionOnline()
    return IPC.companion.online
end

function IPC.pendingCount()
    local n = 0
    for _ in pairs(IPC.pending) do n = n + 1 end
    return n
end

function IPC.onUpdate(dt)
    IPC.heartbeatTimer = IPC.heartbeatTimer + dt
    if IPC.heartbeatTimer >= 1.0 then
        IPC.heartbeatTimer = 0
        IPC.readHeartbeat()
    end

    -- Timeouts are counted every frame, file checks only every pollInterval
    for id, job in pairs(IPC.pending) do
        job.elapsed = job.elapsed + dt
    end

    IPC.pollTimer = IPC.pollTimer + dt
    if IPC.pollTimer < IPC.pollInterval then return end
    IPC.pollTimer = 0

    -- Collect finished jobs first, then run callbacks (callbacks may send new jobs)
    local finished = {}
    for id, job in pairs(IPC.pending) do
        local resPath = IPC.dir .. "res_" .. id .. ".json"
        local text = readFile(resPath)
        if text then
            os.remove(resPath)
            local ok, data = pcall(json.decode, text)
            if ok and type(data) == "table" then
                if data.ok then
                    table.insert(finished, { id = id, job = job, ok = true, result = data.result })
                else
                    table.insert(finished, { id = id, job = job, ok = false, err = data.error or "unknown companion error" })
                end
            else
                table.insert(finished, { id = id, job = job, ok = false, err = "invalid response JSON" })
            end
        elseif job.elapsed >= job.timeout then
            -- Withdraw the request if the companion has not picked it up yet
            os.remove(IPC.dir .. "req_" .. id .. ".json")
            local why = IPC.companion.online and "timeout" or "timeout (companion offline?)"
            table.insert(finished, { id = id, job = job, ok = false, err = job.type .. " " .. why })
        end
    end

    for _, f in ipairs(finished) do
        IPC.pending[f.id] = nil
        safeCall(f.job.callback, f.ok, f.result, f.err)
    end
end

return IPC
