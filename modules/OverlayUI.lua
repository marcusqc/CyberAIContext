-- OverlayUI.lua
-- ImGui debug window: pipeline status, companion status, telemetry, OCR text,
-- the unified JSON, Gemini's answer and an event log.
-- Drawn from onDraw. Clicks only work while the CET overlay is open: CET does not
-- send the mouse to ImGui otherwise.
--
-- Visibility:
--   * closed at start
--   * a capture opens it; without the CET overlay it hides itself after ui.autoHideSeconds
--   * with the CET overlay open it stays until "Fermer" (or the toggle hotkey)

local ContextBuilder = require("modules/ContextBuilder")

local OverlayUI = {
    config = nil,
    isOpen = false,
    now = 0,                    -- seconds since start, from onUpdate (os.clock is CPU time, not real time)
    showUntil = 0,              -- auto-hide time while the CET overlay is closed
    overlayActive = false,
    hidden = false,             -- true while a screenshot is being taken
    onTrigger = nil,            -- set by init.lua: starts a capture
    onSpeak = nil,              -- set by init.lua: speaks a text
    onAsk = nil,                -- set by init.lua: sends a question about the last capture
    question = "",              -- text being typed
    focusPending = false,       -- put the keyboard in the question box next time it is drawn
    contextJson = nil,
    contextPretty = nil,
    aiResponse = nil,
    logs = {},
    maxLogs = 40,
    copiedUntil = 0
}

local COLORS = {
    ERROR = { 1.0, 0.3, 0.3, 1 },
    WARN = { 1.0, 0.8, 0.1, 1 },
    OK = { 0.3, 1.0, 0.4, 1 },
    INFO = { 0.0, 0.9, 1.0, 1 }
}

function OverlayUI.init(cfg, handlers)
    OverlayUI.config = cfg
    OverlayUI.isOpen = cfg.startOpen
    OverlayUI.onTrigger = handlers.onTrigger
    OverlayUI.onSpeak = handlers.onSpeak
    OverlayUI.onAsk = handlers.onAsk
end

function OverlayUI.focusQuestion() OverlayUI.focusPending = true end

function OverlayUI.tick(dt) OverlayUI.now = OverlayUI.now + dt end

--- Opens the window and (re)starts the auto-hide delay.
function OverlayUI.open()
    OverlayUI.isOpen = true
    OverlayUI.showUntil = OverlayUI.now + (OverlayUI.config.autoHideSeconds or 0)
end

function OverlayUI.close() OverlayUI.isOpen = false end

function OverlayUI.toggle()
    if OverlayUI.isOpen then OverlayUI.close() else OverlayUI.open() end
end
function OverlayUI.setHidden(v) OverlayUI.hidden = v end
function OverlayUI.setOverlayActive(v) OverlayUI.overlayActive = v end
function OverlayUI.setAIResponse(r) OverlayUI.aiResponse = r end

function OverlayUI.setContext(jsonText)
    OverlayUI.contextJson = jsonText
    OverlayUI.contextPretty = jsonText and ContextBuilder.pretty(jsonText) or nil
end

function OverlayUI.log(level, msg)
    table.insert(OverlayUI.logs, 1, { time = os.date("%H:%M:%S"), level = level, message = tostring(msg) })
    if #OverlayUI.logs > OverlayUI.maxLogs then
        table.remove(OverlayUI.logs)
    end
    print(string.format("[CyberAIContext] [%s] %s", level, tostring(msg)))
end

local function colored(c, text)
    ImGui.TextColored(c[1], c[2], c[3], c[4], text)
end

local STATE_TEXT = {
    IDLE = "pas de capture", READY = "pret", HIDING = "capture...", SCREENSHOT = "capture...",
    OCR = "lecture du texte...", ASKING = "l'IA reflechit...", ERROR = "erreur"
}

local function drawStatus(state)
    local busy = state.busy
    local c = state.pipeline == "ERROR" and COLORS.ERROR or (busy and COLORS.WARN or COLORS.OK)
    colored(COLORS.INFO, "Etat :")
    ImGui.SameLine()
    colored(c, STATE_TEXT[state.pipeline] or state.pipeline)
    ImGui.SameLine()
    colored(COLORS.INFO, "  Companion :")
    ImGui.SameLine()
    if state.companionOnline then
        colored(COLORS.OK, "en ligne")
    else
        colored(COLORS.ERROR, "hors ligne")
    end
    ImGui.SameLine()
    if ImGui.Button("Fermer") then
        OverlayUI.close()
    end
    -- No capture button: it can only be clicked with the CET console open,
    -- and the console would then be in the screenshot.

    if state.inputState == "listening" then
        colored(COLORS.ERROR, "(o) J'ecoute... relache la touche pour envoyer")
    elseif state.inputState == "transcribing" then
        colored(COLORS.WARN, "Transcription de ta question...")
    elseif state.inputState == "typing" then
        colored(COLORS.WARN, "Ecris ta question dans la boite au-dessus du jeu (Entree / Echap)")
    end
    if not OverlayUI.overlayActive then
        local left = math.max(0, math.ceil(OverlayUI.showUntil - OverlayUI.now))
        ImGui.TextDisabled(string.format("Se ferme dans %d s. Console CET ouverte = fenetre cliquable.", left))
    end
end

local function drawTelemetry(job)
    local tel = job and job.telemetry
    if not tel then
        ImGui.TextDisabled(job and job.telemetryError or "Pas encore de capture.")
        return
    end
    local p, w, q, tg = tel.player or {}, tel.world or {}, tel.quest or {}, tel.target
    ImGui.Text(string.format("Quartier : %s   Heure : %s   Meteo : %s",
        w.district or "?", w.time or "?", w.weather or "?"))
    ImGui.Text(string.format("Sante : %s   Niveau : %s   Combat : %s",
        p.health and (p.health.current .. "/" .. p.health.max .. " (" .. p.health.percent .. "%)") or "?",
        p.level or "?", p.inCombat and "OUI" or "non"))
    if p.weapon or p.vehicle then
        ImGui.Text(string.format("Arme : %s   Vehicule : %s", p.weapon or "-", p.vehicle or "-"))
    end
    if q.title or q.objective then
        ImGui.TextWrapped("Quete : " .. (q.title or "?") .. " - " .. (q.objective or ""))
    end
    if tg then
        ImGui.Text(string.format("Cible : %s (%s m, %s)", tg.name or tg.class or "?", tg.distance or "?", tg.attitude or "?"))
    end
    if tel.errors then
        local n = 0
        for _ in pairs(tel.errors) do n = n + 1 end
        colored(COLORS.WARN, n .. " champ(s) illisible(s) - voir errors dans le JSON")
    end
end

local function drawOCR(job)
    local ocr = job and job.ocr
    if ocr then
        ImGui.TextDisabled(string.format("%s - %d lignes - %d ms", ocr.engine or "?", ocr.blocks and #ocr.blocks or 0, ocr.ms or 0))
        ImGui.TextWrapped(ocr.text ~= "" and ocr.text or "(aucun texte detecte)")
    else
        ImGui.TextDisabled(job and job.ocrError or "Pas encore d'OCR.")
    end
end

local function drawJSON()
    if not OverlayUI.contextPretty then
        ImGui.TextDisabled("Le JSON apparait ici apres une capture.")
        return
    end
    if ImGui.Button("Copier le JSON") then
        local ok = pcall(ImGui.SetClipboardText, OverlayUI.contextJson)
        OverlayUI.log(ok and "OK" or "WARN", ok and "JSON copie" or "presse-papiers indisponible - voir ipc/last_context.json")
        OverlayUI.copiedUntil = OverlayUI.now + 2
    end
    if OverlayUI.now < OverlayUI.copiedUntil then
        ImGui.SameLine()
        colored(COLORS.OK, "Copie !")
    end
    local text = OverlayUI.contextPretty
    ImGui.InputTextMultiline("##context_json", text, #text + 1, -1, 200, ImGuiInputTextFlags.ReadOnly)
end

local function sendQuestion(text)
    if OverlayUI.onAsk and OverlayUI.onAsk(text) then
        OverlayUI.question = ""
    end
end

local function drawQuestion(state)
    local job = state.job
    if not job or not job.context then
        ImGui.TextWrapped("Maintiens la touche \"Question vocale\" et parle, ou appuie sur \"Question par boite de texte\".")
        ImGui.TextWrapped("Ou : \"Capture seule\", puis ouvre la console CET et ecris ta question ici.")
        return
    end
    if not OverlayUI.overlayActive and not job.input then
        ImGui.TextDisabled("Question ecrite ici : ouvre la console CET. Sinon touche vocale ou boite de texte.")
    end

    -- Put the keyboard in the box right after a capture, once the console is open
    if OverlayUI.focusPending and OverlayUI.overlayActive then
        ImGui.SetKeyboardFocusHere()
        OverlayUI.focusPending = false
    end
    ImGui.PushItemWidth(-90)
    local text, enter = ImGui.InputText("##question", OverlayUI.question, 512, ImGuiInputTextFlags.EnterReturnsTrue)
    ImGui.PopItemWidth()
    if type(text) == "string" then OverlayUI.question = text end
    ImGui.SameLine()
    local clicked = ImGui.Button(state.busy and "Patiente" or "Envoyer")
    if (enter or clicked) and not state.busy then
        sendQuestion(OverlayUI.question)
    end
    if ImGui.Button("Analyse sans question") and not state.busy then
        sendQuestion("")
    end
    ImGui.SameLine()
    ImGui.TextDisabled("Entree = envoyer. Les questions suivantes gardent la meme capture.")
end

local function drawAI(job, tts, asking)
    local r = OverlayUI.aiResponse
    if asking then
        colored(COLORS.WARN, "L'IA reflechit...")
    elseif job and job.aiError then
        colored(COLORS.WARN, "IA : " .. job.aiError)
    end
    if not r then
        if not asking then ImGui.TextDisabled("Pas encore de reponse.") end
        return
    end
    if r.question and r.question ~= "" then
        colored(COLORS.INFO, "Question :")
        ImGui.SameLine()
        ImGui.TextWrapped(r.question)
    end
    colored(COLORS.WARN, "Reponse :")
    ImGui.TextWrapped(r.recommendation or "")
    if r.suggestedTactics and #r.suggestedTactics > 0 then
        for _, tactic in ipairs(r.suggestedTactics) do
            ImGui.BulletText(tostring(tactic))
        end
    end
    ImGui.Spacing()
    colored(COLORS.INFO, "A dire (TTS) :")
    ImGui.TextWrapped(r.speakableSummary or "")
    if ImGui.Button("Lire a voix haute") and OverlayUI.onSpeak then
        OverlayUI.onSpeak(r.speakableSummary)
    end
    ImGui.SameLine()
    if tts.speaking then
        colored(COLORS.OK, "lecture... (" .. tts.queued .. " en attente)")
    elseif tts.lastError then
        colored(COLORS.WARN, "TTS : " .. tts.lastError)
    end
    ImGui.TextDisabled(string.format("%s - %d ms", r.model or "?", r.ms or 0))
end

local function drawLog()
    if ImGui.Button("Vider") then OverlayUI.logs = {} end
    ImGui.BeginChild("cyberai_log", -1, 120, true)
    for _, e in ipairs(OverlayUI.logs) do
        colored(COLORS[e.level] or COLORS.INFO, string.format("[%s] %s", e.time, e.message))
    end
    ImGui.EndChild()
end

--- @param state table { pipeline, job, companionOnline, tts }
function OverlayUI.draw(state)
    if not OverlayUI.isOpen or OverlayUI.hidden then return end
    if not OverlayUI.overlayActive then
        if not OverlayUI.config.showWhenOverlayClosed then return end
        if OverlayUI.now > OverlayUI.showUntil then return end
    end

    ImGui.SetNextWindowSize(OverlayUI.config.width, OverlayUI.config.height, ImGuiCond.FirstUseEver)
    -- No title-bar X: it cannot be clicked while the CET overlay is closed, and CET's
    -- Begin(name, open) variant handles End() differently. The "Fermer" button replaces it.
    if ImGui.Begin("CyberAI Context") then
        drawStatus(state)
        ImGui.Separator()
        drawQuestion(state)
        ImGui.Separator()
        drawAI(state.job, state.tts, state.pipeline == "ASKING")
        ImGui.Separator()
        if ImGui.CollapsingHeader("Telemetrie du jeu") then
            drawTelemetry(state.job)
        end
        if ImGui.CollapsingHeader("Texte a l'ecran (OCR)") then
            drawOCR(state.job)
        end
        if ImGui.CollapsingHeader("JSON unifie") then
            drawJSON()
        end
        if ImGui.CollapsingHeader("Journal") then
            drawLog()
        end
    end
    ImGui.End()
end

return OverlayUI
