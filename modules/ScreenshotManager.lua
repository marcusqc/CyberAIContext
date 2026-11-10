-- ScreenshotManager.lua
-- Asks the companion to capture the game window. CET cannot take screenshots itself.
-- The image is saved by the companion in captures/ (inside the mod folder).

local IPC = require("modules/IPC")

local ScreenshotManager = {
    config = nil
}

function ScreenshotManager.init(cfg)
    ScreenshotManager.config = cfg
end

--- @param jobId string  pipeline job id, used for the file name
--- @param callback function(ok, meta, err)  meta = { file, path, width, height, source }
function ScreenshotManager.captureAsync(jobId, callback)
    if not ScreenshotManager.config.enabled then
        callback(false, nil, "screenshot disabled in config")
        return
    end
    IPC.send("screenshot", { name = "capture_" .. jobId }, ScreenshotManager.config.timeout, callback)
end

return ScreenshotManager
