-- ContextBuilder.lua
-- Puts telemetry, screenshot info and OCR text together in one JSON document.
-- Uses json.lua (rxi), which produces valid JSON (proper escaping, arrays vs objects).

local json = require("json")

local ContextBuilder = {
    version = "2.0.0"
}

function ContextBuilder.init(cfg)
    ContextBuilder.version = cfg.version or ContextBuilder.version
end

local function priorityOf(tel, ocr)
    local p = tel and tel.player or {}
    local hp = p.health and p.health.percent
    if p.inCombat and hp and hp < 30 then return "critical" end
    if p.inCombat then return "high" end
    if ocr and ocr.blocks and #ocr.blocks > 0 then return "medium" end
    return "low"
end

local function summaryOf(tel, ocr)
    if not tel then return "No game telemetry (player not loaded)." end
    local p, w, q = tel.player or {}, tel.world or {}, tel.quest or {}
    if w.mainMenu then return "Main menu: no save loaded." end
    local parts = {}
    table.insert(parts, "V in " .. (w.district or "unknown district"))
    if w.time then table.insert(parts, "at " .. w.time) end
    if p.health then table.insert(parts, string.format("health %d%%", p.health.percent)) end
    table.insert(parts, p.inCombat and "in combat" or "not in combat")
    if p.vehicle then table.insert(parts, "driving " .. p.vehicle) end
    if q.title then table.insert(parts, "quest: " .. q.title) end
    if q.objective then table.insert(parts, "objective: " .. q.objective) end
    if tel.target and tel.target.name then table.insert(parts, "looking at " .. tel.target.name) end
    if ocr and ocr.blocks then table.insert(parts, #ocr.blocks .. " text lines on screen") end
    return table.concat(parts, ", ") .. "."
end

--- @param params table { jobId, trigger, screenshot, ocr, telemetry, errors }
--- @return table { data = table, json = string, summary = string, priority = string }
function ContextBuilder.build(params)
    local tel = params.telemetry
    local ocr = params.ocr
    local summary = summaryOf(tel, ocr)
    local priority = priorityOf(tel, ocr)

    local data = {
        schema = "cyberai-context/2",
        modVersion = ContextBuilder.version,
        jobId = params.jobId,
        trigger = params.trigger,
        timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        telemetry = tel,
        screenshot = params.screenshot,
        ocr = ocr,
        summary = summary,
        priority = priority,
        errors = (params.errors and next(params.errors)) and params.errors or nil
    }

    local ok, text = pcall(json.encode, data)
    if not ok then
        text = json.encode({ schema = "cyberai-context/2", jobId = params.jobId, error = "encode failed: " .. tostring(text) })
    end

    return { data = data, json = text, summary = summary, priority = priority }
end

--- Indented copy of a JSON string for display (json.lua only writes compact JSON).
function ContextBuilder.pretty(text)
    local out, indent, inString, escaped = {}, 0, false, false
    for i = 1, #text do
        local c = text:sub(i, i)
        if inString then
            table.insert(out, c)
            if escaped then escaped = false
            elseif c == "\\" then escaped = true
            elseif c == '"' then inString = false end
        elseif c == '"' then
            inString = true
            table.insert(out, c)
        elseif c == "{" or c == "[" then
            indent = indent + 1
            table.insert(out, c .. "\n" .. string.rep("  ", indent))
        elseif c == "}" or c == "]" then
            indent = indent - 1
            table.insert(out, "\n" .. string.rep("  ", indent) .. c)
        elseif c == "," then
            table.insert(out, ",\n" .. string.rep("  ", indent))
        elseif c == ":" then
            table.insert(out, ": ")
        else
            table.insert(out, c)
        end
    end
    return table.concat(out)
end

return ContextBuilder
