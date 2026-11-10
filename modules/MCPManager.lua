-- MCPManager.lua
-- Reads the game state directly through CET (player, world, quest, target).
-- Despite the name kept from the original design, this is not an MCP client:
-- it is the in-game telemetry that the MCP server (CETBridge) can also expose.
--
-- Rules:
--   * every read is in its own pcall, so one broken API does not lose the rest
--   * a value that cannot be read is left out (nil), never replaced by made-up data
--   * the reason is stored in telemetry.errors so it shows up in the JSON
-- All reads are cheap engine queries; collect() runs in well under a millisecond.

local MCPManager = {
    config = nil
}

function MCPManager.init(cfg)
    MCPManager.config = cfg
end

local function round(v, digits)
    local m = 10 ^ (digits or 0)
    return math.floor(v * m + 0.5) / m
end

local function locText(key)
    if not key or key == "" then return nil end
    local ok, txt = pcall(GetLocalizedText, key)
    if ok and txt and txt ~= "" then return txt end
    return key
end

local atan2 = math.atan2 or math.atan  -- LuaJIT / Lua 5.4

-- World axes: +x east, +y north (matches the in-game map)
local COMPASS = { "N", "NE", "E", "SE", "S", "SO", "O", "NO" }
local RELATIVE = { "devant", "devant-droite", "droite", "derriere-droite",
                   "derriere", "derriere-gauche", "gauche", "devant-gauche" }

--- Bearing in degrees (0 = north, 90 = east) of a direction vector.
local function bearing(dx, dy)
    local deg = math.deg(atan2(dx, dy))
    return (deg + 360) % 360
end

local function sector(deg, names)
    return names[math.floor(((deg + 22.5) % 360) / 45) + 1]
end

-- Ammo types (TweakDB id -> English name shown in game)
local AMMO = {
    { id = "Ammo.HandgunAmmo", key = "handgun" },
    { id = "Ammo.RifleAmmo", key = "heavy" },          -- "Heavy Ammo" in game
    { id = "Ammo.ShotgunAmmo", key = "shotgun" },
    { id = "Ammo.SniperRifleAmmo", key = "sniper" }
}

local function itemName(itemID)
    local name = nil
    pcall(function()
        local record = TweakDB:GetRecord(itemID:GetTDBID())
        if record then
            name = Game.GetLocalizedTextByKey(record:DisplayName())
        end
    end)
    if name == nil or name == "" then
        pcall(function() name = TDBID.ToStringDEBUG(itemID.tdbid) end)
    end
    return name
end

--- Collects the telemetry now (call on the main thread, inside onUpdate or a hotkey).
--- @return table telemetry, or nil and an error message when no player is loaded
function MCPManager.collect()
    local player = Game.GetPlayer()
    if not player then
        return nil, "no player (main menu or loading screen)"
    end

    local cfg = MCPManager.config
    local errors = {}
    local function try(field, fn)
        local ok, err = pcall(fn)
        if not ok then errors[field] = tostring(err) end
    end

    local t = { player = {}, world = {} }
    local playerID = player:GetEntityID()
    local playerPos = nil

    -- Player ---------------------------------------------------------------
    try("position", function()
        playerPos = player:GetWorldPosition()
        t.player.position = { x = round(playerPos.x, 2), y = round(playerPos.y, 2), z = round(playerPos.z, 2) }
    end)

    try("health", function()
        local pools = Game.GetStatPoolsSystem()
        local current = pools:GetStatPoolValue(playerID, gamedataStatPoolType.Health, false)
        local pct = pools:GetStatPoolValue(playerID, gamedataStatPoolType.Health, true)
        local max = Game.GetStatsSystem():GetStatValue(playerID, gamedataStatType.Health)
        t.player.health = { current = math.floor(current), max = math.floor(max), percent = math.floor(pct) }
    end)

    try("level", function()
        local stats = Game.GetStatsSystem()
        t.player.level = math.floor(stats:GetStatValue(playerID, gamedataStatType.Level))
        t.player.streetCred = math.floor(stats:GetStatValue(playerID, gamedataStatType.StreetCred))
    end)

    try("combat", function()
        local defs = GetAllBlackboardDefs().PlayerStateMachine
        local bb = Game.GetBlackboardSystem():GetLocalInstanced(playerID, defs)
        -- gamePSMCombat: 0 Default, 1 InCombat, 2 OutOfCombat, 3 Stealth
        local state = bb:GetInt(defs.Combat)
        t.player.inCombat = (state == 1)
        t.player.stealth = (state == 3)
    end)

    try("vehicle", function()
        local vehicle = Game.GetMountedVehicle(player)
        if vehicle then
            t.player.vehicle = vehicle:GetDisplayName()
        end
    end)

    if cfg.includeEquipment then
        try("weapon", function()
            local item = Game.GetTransactionSystem():GetItemInSlot(player, TweakDBID.new("AttachmentSlots.WeaponRight"))
            if item then
                t.player.weapon = itemName(item:GetItemID())
            end
        end)
    end

    -- World ----------------------------------------------------------------
    try("time", function()
        local gameTime = Game.GetTimeSystem():GetGameTime()
        t.world.time = string.format("%02d:%02d", GameTime.Hours(gameTime), GameTime.Minutes(gameTime))
    end)

    try("preGame", function()
        -- true in the main menu (a placeholder player exists there, with no district or quest)
        t.world.mainMenu = Game.GetSystemRequestsHandler():IsPreGame()
    end)

    try("weather", function()
        -- GetWeatherState() returns a worldWeatherState object; its name is a CName
        t.world.weather = NameToString(Game.GetWeatherSystem():GetWeatherState().name)
    end)

    try("zone", function()
        -- gamePSMZones: 0 Default, 1 Public, 2 Safe, 3 Restricted, 4 Dangerous
        local names = { [0] = "Default", [1] = "Public", [2] = "Safe", [3] = "Restricted", [4] = "Dangerous" }
        local defs = GetAllBlackboardDefs().PlayerStateMachine
        local z = Game.GetBlackboardSystem():GetLocalInstanced(playerID, defs):GetInt(defs.Zones)
        t.world.securityZone = names[z] or tostring(z)
    end)

    try("district", function()
        local prevention = Game.GetScriptableSystemsContainer():Get("PreventionSystem")
        local district = prevention.districtManager:GetCurrentDistrict()
        if district then
            t.world.district = locText(district:GetDistrictRecord():LocalizedName())
        end
    end)

    try("sceneTier", function()
        local defs = GetAllBlackboardDefs().PlayerStateMachine
        local bb = Game.GetBlackboardSystem():GetLocalInstanced(playerID, defs)
        t.world.sceneTier = bb:GetInt(defs.SceneTier)  -- 1 = full gameplay ... 5 = cinematic
    end)

    -- Tracked quest --------------------------------------------------------
    if cfg.includeQuest then
        try("quest", function()
            local journal = Game.GetJournalManager()
            local objective = journal:GetTrackedEntry()
            if not objective then return end
            local quest = { objective = locText(objective:GetDescription()) }
            -- objective -> phase -> quest
            local phase = journal:GetParentEntry(objective)
            local questEntry = phase and journal:GetParentEntry(phase)
            if questEntry then
                quest.title = locText(questEntry:GetTitle(journal))
                quest.id = questEntry:GetId()
            end
            t.quest = quest
        end)
    end

    -- Entity under the crosshair -------------------------------------------
    if cfg.includeTarget then
        try("target", function()
            local target = Game.GetTargetingSystem():GetLookAtObject(player)
            if not target then return end
            local info = { class = NameToString(target:GetClassName()) }
            pcall(function() info.name = target:GetDisplayName() end)
            pcall(function() info.isNPC = target:IsNPC() end)
            pcall(function() info.isDead = target:IsDead() end)
            pcall(function()
                local pos = target:GetWorldPosition()
                if playerPos then
                    info.distance = round(Vector4.Distance(playerPos, pos), 1)
                end
            end)
            pcall(function()
                -- EAIAttitude: 0 Friendly, 1 Neutral, 2 Hostile
                local names = { [0] = "Friendly", [1] = "Neutral", [2] = "Hostile" }
                local a = target:GetAttitudeTowards(player)
                info.attitude = names[tonumber(EnumInt(a))] or tostring(a)
            end)
            t.target = info
        end)
    end

    -- Direction V is facing ------------------------------------------------
    local facingDeg = nil
    try("facing", function()
        local f = player:GetWorldForward()
        facingDeg = bearing(f.x, f.y)
        t.player.facing = sector(facingDeg, COMPASS)
    end)

    -- Ammo ------------------------------------------------------------------
    if cfg.includeAmmo then
        try("ammo", function()
            local ts = Game.GetTransactionSystem()
            local ammo = {}
            for _, a in ipairs(AMMO) do
                ammo[a.key] = ts:GetItemQuantity(player, ItemID.FromTDBID(TweakDBID.new(a.id)))
            end
            t.player.ammo = ammo
        end)
    end

    -- Nearby places: discovered fast travel points, closest first ---------
    -- Gives the AI real positions to answer "is X far / which way".
    local n = cfg.nearbyPlaces or 0
    if n > 0 and playerPos then
        try("places", function()
            local fts = Game.GetScriptableSystemsContainer():Get("FastTravelSystem")
            local mappins = Game.GetMappinSystem()
            local list = {}
            for _, pt in ipairs(fts:GetFastTravelPoints()) do
                pcall(function()
                    local pos = mappins:GetMappin(pt.mappinID):GetWorldPosition()
                    local dx, dy = pos.x - playerPos.x, pos.y - playerPos.y
                    local deg = bearing(dx, dy)
                    local place = {
                        name = pt:GetPointDisplayName(),
                        district = pt:GetDistrictDisplayName(),
                        distance = math.floor(math.sqrt(dx * dx + dy * dy) + 0.5),
                        direction = sector(deg, COMPASS)
                    }
                    if facingDeg then
                        place.relative = sector((deg - facingDeg + 360) % 360, RELATIVE)
                    end
                    pcall(function()
                        place.name = GetLocalizedText(place.name)
                        place.district = GetLocalizedText(place.district)
                    end)
                    table.insert(list, place)
                end)
            end
            table.sort(list, function(a, b) return a.distance < b.distance end)
            while #list > n do table.remove(list) end
            if #list > 0 then t.places = list end
        end)
    end

    if next(errors) then
        t.errors = errors
    end
    return t
end

return MCPManager
