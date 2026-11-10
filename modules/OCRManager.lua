-- OCRManager.lua
-- Asks the companion to read the text in a screenshot (Tesseract or RapidOCR on its side).

local IPC = require("modules/IPC")

local OCRManager = {
    config = nil
}

function OCRManager.init(cfg)
    OCRManager.config = cfg
end

--- @param imageFile string  file name returned by ScreenshotManager (inside captures/)
--- @param callback function(ok, result, err)  result = { engine, text, blocks = { {text, confidence, box} }, ms }
function OCRManager.processImageAsync(imageFile, callback)
    if not OCRManager.config.enabled then
        callback(false, nil, "OCR disabled in config")
        return
    end
    IPC.send("ocr", { file = imageFile }, OCRManager.config.timeout, callback)
end

return OCRManager
