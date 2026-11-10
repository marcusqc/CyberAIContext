-- CyberAIContext 2.0 - CET mod
-- Capture hotkey (bind it in CET > Bindings) ->
--   game telemetry (read here) + screenshot and OCR (companion) -> one JSON -> ImGui window
-- Then the player types a question in the window ->
--   question + JSON + screenshot sent to the AI (companion) -> answer shown and spoken
-- Every step is asynchronous: the game thread never waits for the companion.

local Config = require("config")
local IPC = require("modules/IPC")
local ScreenshotManager = require("modules/ScreenshotManager")
local OCRManager = require("modules/OCRManager")
local MCPManager = require("modules/MCPManager")
local ContextBuilder = require("modules/ContextBuilder")
local GeminiBridge = require("modules/GeminiBridge")
local OverlayUI = require("modules/OverlayUI")
local TTSManager = require("modules/TTSManager")
local QuestionInput = require("modules/QuestionInput")

local Mod = {
    ready = false,
    -- IDLE: nothing captured yet / READY: capture done, waiting for a question
    -- HIDING, SCREENSHOT, OCR: capture running / ASKING: waiting for the AI / ERROR
    pipeline = "IDLE",
    job = nil,
    hideFrames = 0,
    hideTimer = 0
}

local BUSY = { HIDING = true, SCREENSHOT = true, OCR = true, ASKING = true }

local function log(level, msg) OverlayUI.log(level, msg) end

local function elapsedMs(since)
    return math.floor((OverlayUI.now - since) * 1000)
end

local function trim(s)
    return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Step 5: AI answer ---------------------------------------------------------
local function onAnswer(ok, response, err)
    local job = Mod.job
    local question = job.pendingQuestion
    job.pendingQuestion = nil
    if ok and type(response) == "table" then
        response.question = question
        job.ai = response
        job.aiError = nil
        table.insert(job.history, { question = question or "", answer = response.recommendation or "" })
        OverlayUI.setAIResponse(response)
        log("OK", string.format("Reponse IA recue (%d ms)", elapsedMs(job.askTime)))
        if Config.tts.autoSpeak and response.speakableSummary then
            TTSManager.enqueueSpeech(response.speakableSummary, { interrupt = true })
        end
    else
        job.aiError = tostring(err)
        log("WARN", "IA : " .. job.aiError)
    end
    Mod.pipeline = "READY"  -- another question about the same capture is possible
    OverlayUI.open()        -- restart the auto-hide delay so the answer can be read
end

--- Sends the last capture to the AI with a question (nil or "" = general analysis).
--- @return boolean sent
function Mod.ask(question)
    if not Mod.ready then return false end
    if BUSY[Mod.pipeline] then
        log("WARN", "Attends la fin de l'etape en cours (" .. Mod.pipeline .. ")")
        return false
    end
    local job = Mod.job
    if not job or not job.context then
        log("WARN", "Fais d'abord une capture (raccourci Capture AI Context)")
        return false
    end
    if not Config.gemini.enabled then
        log("WARN", "IA desactivee dans config.lua")
        return false
    end
    if not IPC.isCompanionOnline() then
        log("WARN", "Companion hors ligne : lance companion/start_companion.bat")
        return false
    end

    question = trim(question)
    if question == "" then question = nil end
    job.pendingQuestion = question
    job.askTime = OverlayUI.now
    Mod.pipeline = "ASKING"
    log("INFO", question and ("Question : " .. question) or "Analyse generale demandee")

    -- Earlier exchanges about this capture, so follow-up questions make sense
    local history = {}
    local n = Config.gemini.historySize or 0
    for i = math.max(1, #job.history - n + 1), #job.history do
        table.insert(history, job.history[i])
    end

    GeminiBridge.sendContextAsync(job.context.json, job.screenshot and job.screenshot.file,
        onAnswer, question, history)
    return true
end

-- Step 4: build the JSON, show it, send it on --------------------------------
local function buildContext()
    local job = Mod.job
    local errors = {}
    if job.telemetryError then errors.telemetry = job.telemetryError end
    if job.screenshotError then errors.screenshot = job.screenshotError end
    if job.ocrError then errors.ocr = job.ocrError end

    local ctx = ContextBuilder.build({
        jobId = job.id,
        trigger = job.trigger,
        telemetry = job.telemetry,
        screenshot = job.screenshot,
        ocr = job.ocr,
        errors = errors
    })
    job.context = ctx
    OverlayUI.setContext(ctx.json)
    OverlayUI.open()
    log("OK", string.format("JSON pret (%d octets, priorite %s, %d ms)", #ctx.json, ctx.priority, elapsedMs(job.startTime)))

    if Config.saveLastContext then
        IPC.writeFile("last_context.json", ctx.json)
    end

    Mod.pipeline = "READY"
    if job.queuedQuestion then
        -- A voice/text question arrived before the capture was finished
        local q = job.queuedQuestion
        job.queuedQuestion = nil
        Mod.ask(q)
    elseif job.inputState then
        -- Still listening or typing: the question will be sent when it arrives
    elseif Config.gemini.askOnCapture then
        Mod.ask(nil)
    else
        OverlayUI.focusQuestion()
    end
end

--- A question came from the voice or the text box: send it now, or as soon as the capture is ready.
local function deliverQuestion(job, text)
    if job ~= Mod.job then return end  -- a newer capture replaced this one
    job.inputState = nil
    text = trim(text)
    if text == "" then
        log("WARN", job.input == "voice" and "Rien entendu" or "Question annulee")
        return
    end
    if Mod.pipeline == "READY" and job.context then
        Mod.ask(text)
    else
        job.queuedQuestion = text
    end
end

-- Step 3: OCR result -------------------------------------------------------
local function onOCR(ok, result, err)
    if ok then
        Mod.job.ocr = result
        log("INFO", string.format("OCR : %d lignes (%s)", result.blocks and #result.blocks or 0, result.engine or "?"))
    else
        Mod.job.ocrError = tostring(err)
        log("WARN", "OCR : " .. Mod.job.ocrError)
    end
    buildContext()
end

-- Step 2: screenshot result --------------------------------------------------
local function runAfterScreenshot(job)
    local fn = job.afterScreenshot
    job.afterScreenshot = nil
    if fn then fn(job) end
end

local function onScreenshot(ok, meta, err)
    OverlayUI.setHidden(false)
    runAfterScreenshot(Mod.job)
    if ok then
        Mod.job.screenshot = meta
        log("INFO", string.format("Capture : %s (%dx%d)", meta.file, meta.width or 0, meta.height or 0))
        Mod.pipeline = "OCR"
        OCRManager.processImageAsync(meta.file, onOCR)
    else
        Mod.job.screenshotError = tostring(err)
        log("WARN", "Capture : " .. Mod.job.screenshotError)
        buildContext()
    end
end

local function sendScreenshot()
    Mod.pipeline = "SCREENSHOT"
    ScreenshotManager.captureAsync(Mod.job.id, onScreenshot)
end

-- Step 1: hotkey --------------------------------------------------------------
--- Starts a capture. @return boolean started
--- @param input string|nil  "voice" or "text": a question will come from that input
function Mod.trigger(source, input)
    if not Mod.ready then return false end
    if BUSY[Mod.pipeline] then
        log("WARN", "Capture deja en cours (" .. Mod.pipeline .. ")")
        return false
    end

    Mod.job = {
        id = os.date("%Y%m%d_%H%M%S"),
        trigger = source,
        startTime = OverlayUI.now,
        history = {},   -- questions and answers about this capture
        input = input,
        inputState = input and (input == "voice" and "listening" or "typing") or nil,
        afterScreenshot = Mod.nextAfterScreenshot  -- e.g. open the text box
    }
    Mod.nextAfterScreenshot = nil
    OverlayUI.setAIResponse(nil)
    log("INFO", "Capture lancee (" .. source .. ")")

    -- Telemetry is read right now, so it matches the moment of the screenshot
    local ok, tel, err = pcall(MCPManager.collect)
    if ok and tel then
        Mod.job.telemetry = tel
    else
        Mod.job.telemetryError = tostring(ok and err or tel)
        log("WARN", "Telemetrie : " .. Mod.job.telemetryError)
    end

    if not IPC.isCompanionOnline() then
        Mod.job.screenshotError = "companion offline"
        log("WARN", "Companion hors ligne : JSON avec la telemetrie seulement")
        Mod.job.inputState = nil  -- no voice or text box without the companion
        buildContext()
        OverlayUI.open()
        return true
    end

    if not Config.screenshot.enabled then
        runAfterScreenshot(Mod.job)
        buildContext()
    elseif Config.ui.hideDuringCapture then
        -- Hide our window for a few frames so it is not in the screenshot (or the OCR).
        -- Done even if the window is closed: open() below would show it during the capture.
        OverlayUI.setHidden(true)
        Mod.hideFrames = Config.screenshot.hideOverlayFrames
        Mod.hideTimer = 0
        Mod.pipeline = "HIDING"
    else
        sendScreenshot()
    end
    OverlayUI.open()
    return true
end

local function speak(text)
    TTSManager.enqueueSpeech(text, { interrupt = true })
end

-- Push-to-talk: key down = capture + start recording, key up = stop + transcribe + ask
local ptt = { active = false, job = nil, downAt = 0 }

local function pushToTalk(down)
    if not Mod.ready then return end
    if down then
        if ptt.active then return end
        if not IPC.isCompanionOnline() then
            log("WARN", "Companion hors ligne : pas de micro")
            OverlayUI.open()
            return
        end
        if not Mod.trigger("voice", "voice") then return end
        ptt.active, ptt.job, ptt.downAt = true, Mod.job, OverlayUI.now
        TTSManager.clear()
        local job = ptt.job
        QuestionInput.startVoice(function(ok, _, err)
            if not ok and job == Mod.job then
                job.inputState = nil
                log("WARN", "Micro : " .. tostring(err))
            end
        end)
    else
        if not ptt.active then return end
        ptt.active = false
        local job = ptt.job
        if job.inputState == "listening" then job.inputState = "transcribing" end
        QuestionInput.stopVoice(function(ok, result, err)
            if not ok then
                if job == Mod.job then job.inputState = nil end
                log("WARN", "Micro : " .. tostring(err))
                return
            end
            if result.text and result.text ~= "" then
                log("INFO", string.format("Entendu (%.1f s) : %s", result.seconds or 0, result.text))
            end
            deliverQuestion(job, result.text)
        end)
    end
end

-- Text box over the game: capture first (box not in the screenshot), then ask
local function textPopup()
    if not Mod.ready then return end
    if not IPC.isCompanionOnline() then
        log("WARN", "Companion hors ligne : pas de boite de texte")
        OverlayUI.open()
        return
    end
    local function openBox(job)
        QuestionInput.askText(Config.questions.popupTimeout, function(ok, result, err)
            if not ok then
                if job == Mod.job then job.inputState = nil end
                log("WARN", "Boite de texte : " .. tostring(err))
                return
            end
            deliverQuestion(job, result.text)
        end)
    end
    -- Set before trigger(): the box opens once the screenshot is taken, so it is not in it
    Mod.nextAfterScreenshot = openBox
    if not Mod.trigger("text_box", "text") then
        Mod.nextAfterScreenshot = nil
    end
end

-- CET events -------------------------------------------------------------------
registerForEvent("onInit", function()
    local ok, err = pcall(function()
        IPC.init(Config.ipc)
        ScreenshotManager.init(Config.screenshot)
        OCRManager.init(Config.ocr)
        MCPManager.init(Config.telemetry)
        ContextBuilder.init(Config)
        GeminiBridge.init(Config.gemini)
        TTSManager.init(Config.tts)
        OverlayUI.init(Config.ui, { onTrigger = Mod.trigger, onSpeak = speak, onAsk = Mod.ask })
    end)
    if not ok then
        print("[CyberAIContext] Init failed: " .. tostring(err))
        return
    end
    Mod.ready = true
    log("INFO", "Pret. Companion " .. (IPC.isCompanionOnline() and "en ligne" or "hors ligne") ..
        ". Raccourcis : CET > Bindings > CyberAIContext.")
end)

-- Suggested keys: F1 voice, F2 text box, F3 capture only. Avoid Ctrl+<game key>:
-- CET also fires on the plain key, so the game sees it too (Ctrl+F5 = quicksave).
registerInput("push_to_talk", "Question vocale (maintenir pour parler)", pushToTalk)

registerHotkey("ask_text_popup", "Question par boite de texte", function()
    textPopup()
end)

registerHotkey("capture_ai_context", "Capture seule (question dans la console CET)", function()
    Mod.trigger("hotkey")
end)

registerHotkey("toggle_ai_window", "Show/Hide AI Context window", function()
    OverlayUI.toggle()
end)

registerForEvent("onUpdate", function(dt)
    if not Mod.ready then return end
    OverlayUI.tick(dt)
    local ok, err = pcall(function()
        if Mod.pipeline == "HIDING" then
            -- Wait until our window has really disappeared from the rendered frames
            Mod.hideFrames = Mod.hideFrames - 1
            Mod.hideTimer = Mod.hideTimer + dt
            if Mod.hideFrames <= 0 or Mod.hideTimer > 0.5 then
                sendScreenshot()
            end
        end
        IPC.onUpdate(dt)
        TTSManager.onUpdate(dt)
    end)
    if not ok then
        OverlayUI.setHidden(false)
        Mod.pipeline = "ERROR"
        log("ERROR", "onUpdate : " .. tostring(err))
    end
end)

registerForEvent("onDraw", function()
    if not Mod.ready then return end
    OverlayUI.draw({
        pipeline = Mod.pipeline,
        busy = BUSY[Mod.pipeline] == true,
        job = Mod.job,
        inputState = Mod.job and Mod.job.inputState,
        companionOnline = IPC.isCompanionOnline(),
        tts = TTSManager.getState()
    })
end)

registerForEvent("onOverlayOpen", function() OverlayUI.setOverlayActive(true) end)
registerForEvent("onOverlayClose", function() OverlayUI.setOverlayActive(false) end)

-- Small public API for other mods: GetMod("CyberAIContext").trigger("other_mod")
return {
    trigger = function(source) Mod.trigger(source or "api") end,
    ask = function(question) return Mod.ask(question) end,
    getLastContext = function() return Mod.job and Mod.job.context and Mod.job.context.json or nil end,
    -- Current pipeline state and the last results/errors (for other mods and remote debugging)
    getStatus = function()
        local j = Mod.job or {}
        return {
            pipeline = Mod.pipeline,
            companionOnline = IPC.isCompanionOnline(),
            jobId = j.id,
            answer = j.ai,
            history = j.history,
            errors = { screenshot = j.screenshotError, ocr = j.ocrError, ai = j.aiError, telemetry = j.telemetryError },
            tts = TTSManager.getState()
        }
    end,
    speak = speak
}
