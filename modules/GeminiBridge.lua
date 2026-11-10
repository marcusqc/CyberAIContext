-- GeminiBridge.lua
-- Sends the context JSON (and optionally the screenshot) to Gemini through the companion.
-- The API key stays in the companion; it never goes into the game folder's Lua files.

local IPC = require("modules/IPC")

local GeminiBridge = {
    config = nil
}

function GeminiBridge.init(cfg)
    GeminiBridge.config = cfg
end

--- @param contextJson string  JSON text from ContextBuilder
--- @param imageFile string|nil  screenshot file name, or nil
--- @param callback function(ok, response, err)
---        response = { recommendation, speakableSummary, suggestedTactics = {...}, model, ms }
--- @param question string|nil  the player's question; nil = general analysis
--- @param history table|nil  earlier { question, answer } pairs about the same capture
function GeminiBridge.sendContextAsync(contextJson, imageFile, callback, question, history)
    if not GeminiBridge.config.enabled then
        callback(false, nil, "AI disabled in config")
        return
    end
    local payload = { context = contextJson }
    if question and question ~= "" then
        payload.question = question
    end
    if history and #history > 0 then
        payload.history = history
    end
    if GeminiBridge.config.sendImage and imageFile then
        payload.image = imageFile
    end
    IPC.send("gemini", payload, GeminiBridge.config.timeout, callback)
end

return GeminiBridge
