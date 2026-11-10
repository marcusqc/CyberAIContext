-- CyberAIContext - configuration (Lua side)
-- The companion program has its own settings in companion/companion_config.json

local Config = {
    version = "2.0.0",

    ipc = {
        dir = "ipc/",               -- relative to the mod folder (CET sandbox)
        pollInterval = 0.1,         -- seconds between checks for responses
        heartbeatMaxAge = 5         -- companion considered offline after N seconds without heartbeat
    },

    screenshot = {
        enabled = true,
        hideOverlayFrames = 2,      -- frames to wait with our window hidden before capturing
        timeout = 5
    },

    ocr = {
        enabled = true,
        timeout = 20                -- the first OCR call can be slow (model loading)
    },

    telemetry = {
        includeTarget = true,
        includeEquipment = true,
        includeQuest = true,
        includeAmmo = true,
        nearbyPlaces = 10           -- closest discovered fast travel points sent to the AI (0 = none)
    },

    gemini = {
        enabled = true,
        sendImage = true,           -- send the screenshot to the AI along with the JSON
        askOnCapture = false,       -- true = ask for a general analysis right after each capture
                                    -- false = wait for a question typed in the window
        historySize = 4,            -- previous questions/answers about the same capture sent along
        timeout = 120               -- free models can be slow, and the companion may retry once
    },

    questions = {
        popupTimeout = 120,         -- seconds before the text box closes by itself
        minVoiceSeconds = 0.3       -- shorter key presses are ignored
    },

    tts = {
        enabled = true,
        autoSpeak = true,           -- speak Gemini's short summary automatically
        voice = "Steffan",          -- part of a Windows voice name ("Steffan", "Claude"...); empty = first French voice
        rate = 1.0,
        volume = 0.9,
        timeout = 60
    },

    ui = {
        startOpen = false,              -- window closed until the first capture
        showWhenOverlayClosed = true,   -- show results in-game after a capture (not clickable without the CET overlay)
        autoHideSeconds = 30,           -- without the CET overlay, hide the window N seconds after the last result
        hideDuringCapture = true,
        width = 640,
        height = 560
    },

    saveLastContext = true          -- also write ipc/last_context.json for external tools
}

return Config
