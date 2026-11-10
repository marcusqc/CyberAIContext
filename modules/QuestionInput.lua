-- QuestionInput.lua
-- Ways to ask a question without the CET console (CET only gives the keyboard to
-- its windows while the console is open):
--   * voice: push-to-talk, the companion records the microphone and transcribes it
--   * text box: the companion shows a small input box over the game

local IPC = require("modules/IPC")

local QuestionInput = {
    recording = false
}

--- Starts recording the microphone.
--- @param callback function(ok, info, err)
function QuestionInput.startVoice(callback)
    QuestionInput.recording = true
    IPC.send("record_start", {}, 5, function(ok, info, err)
        if not ok then QuestionInput.recording = false end
        callback(ok, info, err)
    end)
end

--- Stops recording; the callback gets the transcribed text.
--- @param callback function(ok, result, err)  result = { text, seconds, ms }
function QuestionInput.stopVoice(callback)
    QuestionInput.recording = false
    -- Transcription takes a few seconds on the GPU, much more on a busy CPU
    IPC.send("record_stop", {}, 120, callback)
end

--- Shows the text box over the game.
--- @param timeout number seconds before it closes by itself
--- @param callback function(ok, result, err)  result = { text, cancelled }
function QuestionInput.askText(timeout, callback)
    IPC.send("text_prompt", { timeout = timeout }, timeout + 10, callback)
end

return QuestionInput
