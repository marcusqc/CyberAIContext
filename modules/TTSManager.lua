-- TTSManager.lua
-- Speech queue. Lines are sent to the companion one at a time; the next one starts
-- when the companion reports the previous one finished.
-- The voice engine lives in the companion (Windows SAPI for now), so another engine
-- can be added there without changing this file.

local IPC = require("modules/IPC")

local TTSManager = {
    config = nil,
    queue = {},
    current = nil,      -- line being spoken
    lastError = nil
}

function TTSManager.init(cfg)
    TTSManager.config = cfg
end

--- Adds a line to the queue.
--- @param text string
--- @param opts table|nil { voice, rate, volume, interrupt }  interrupt = put at the front
function TTSManager.enqueueSpeech(text, opts)
    if not TTSManager.config.enabled then return end
    if type(text) ~= "string" or text == "" then return end
    opts = opts or {}
    local item = {
        text = text,
        voice = opts.voice or TTSManager.config.voice,
        rate = opts.rate or TTSManager.config.rate,
        volume = opts.volume or TTSManager.config.volume
    }
    if opts.interrupt then
        table.insert(TTSManager.queue, 1, item)
    else
        table.insert(TTSManager.queue, item)
    end
end

function TTSManager.clear()
    TTSManager.queue = {}
end

function TTSManager.onUpdate(dt)
    if TTSManager.current or #TTSManager.queue == 0 then return end

    local item = table.remove(TTSManager.queue, 1)
    TTSManager.current = item
    IPC.send("tts", item, TTSManager.config.timeout, function(ok, _, err)
        TTSManager.current = nil
        if not ok then
            TTSManager.lastError = err
            print("[CyberAIContext] TTS failed: " .. tostring(err))
        end
    end)
end

function TTSManager.getState()
    return {
        speaking = TTSManager.current ~= nil,
        queued = #TTSManager.queue,
        text = TTSManager.current and TTSManager.current.text or "",
        lastError = TTSManager.lastError
    }
end

return TTSManager
