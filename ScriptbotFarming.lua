--[[
    ============================================================
      FPS BOOSTER v26.2 - Fullscreen Status Edition
      - FULLSCREEN PURE-BLACK STATUS UI (no window, no buttons)
      - No minimize / close / drag controls
      - Live status readout only + notification log
      - Per-game blacklist (auto-learned)
      - Distance-based part culling
      - Selective reapply (dirty-count aware)
      - Instance counter
      - Benchmark (on vs off delta)
      - Presets: MaxFPS / Balanced / Visual
      - Auto-reconnect / auto-join / player tracker
    ============================================================

    To hide/show the overlay from your executor console:
        getgenv().__FPS_BOOSTER_V26.setOverlay(false)   -- hide
        getgenv().__FPS_BOOSTER_V26.setOverlay(true)    -- show
        getgenv().__FPS_BOOSTER_V26.destroy()           -- unload
]]

-- ============================================================
--  CONFIG
-- ============================================================
local CFG = {
    ACTIVE_FPS          = 10,
    AFK_FPS             = 1,
    AFK_TIME            = 10,
    RAM_CLEAN_INTERVAL  = 60,
    RAM_CLEAN_ON_START  = true,
    REAPPLY_INTERVAL    = 300,
    REAPPLY_ON_START    = true,
    REAPPLY_DIRTY_MIN   = 250,

    STRIP_TEXTURES      = true,
    FLATTEN_MAT         = true,
    DISABLE_SHADOWS     = true,
    KILL_POSTFX         = true,
    KILL_PARTICLES      = true,
    DROP_QUALITY        = true,
    LOW_MESH            = true,
    KILL_VIEWPORTS      = true,
    KILL_HUMANOID       = true,
    MUTE_ALL_SOUNDS     = true,
    REAPPLY_ON_SPAWN    = true,
    BLACK_SCREEN        = true,      -- true = fully opaque black overlay
    CULLING             = true,
    CULL_DISTANCE       = 250,

    LOG_VERBOSE         = false,

    AUTO_EXECUTE_ENABLED = true,
    SCRIPT_FILE          = "fps_booster_v26.lua",
    SCRIPT_URL           = nil,

    AUTO_RECONNECT_ENABLED = true,
    RECONNECT_MAX_ATTEMPTS = 3,
    RECONNECT_DELAY        = 20,

    AUTO_JOIN_ENABLED      = true,
    BOOT_GRACE             = 30,
    GLOBAL_COOLDOWN        = 120,
    TARGET_COOLDOWN        = 300,
    MAX_ATTEMPTS_PER_HOUR  = 10,

    TRACK_USERNAME      = "errorishacker",
    TRACK_USER_ID       = 10386878024,
    TRACK_POLL_INTERVAL = 180,

    USE_ROPROXY         = true,
    PROXY_PRESENCE      = "https://presence.roproxy.com/v1/presence/users",
    PROXY_GAMES         = "https://games.roproxy.com/v1/games",
    DIRECT_PRESENCE     = "https://presence.roblox.com/v1/presence/users",
    DIRECT_GAMES        = "https://games.roblox.com/v1/games",

    JOBID_DISPLAY_LEN   = 22,

    KICK_WINDOW         = 20,
    BROKEN_GAMES_MAX    = 64,
}

-- ============================================================
--  SERVICES
-- ============================================================
local Players         = game:GetService("Players")
local RunService      = game:GetService("RunService")
local UserInputSvc    = game:GetService("UserInputService")
local Lighting        = game:GetService("Lighting")
local Workspace       = game:GetService("Workspace")
local StarterGui      = game:GetService("StarterGui")
local SoundService    = game:GetService("SoundService")
local HttpService     = game:GetService("HttpService")
local TeleportService = game:GetService("TeleportService")
local TweenService    = game:GetService("TweenService")

local player = Players.LocalPlayer
local PLAYER_GUI = player:WaitForChild("PlayerGui")
local START_TIME = tick()

local function log(...)
    if CFG.LOG_VERBOSE then print(...) end
end

-- ============================================================
--  PERSISTENT STATE
-- ============================================================
local STATE_FILE = "fps_booster_state.json"

local function loadState()
    if not isfile or not readfile or not isfile(STATE_FILE) then return {} end
    local ok, raw = pcall(readfile, STATE_FILE)
    if not ok or not raw then return {} end
    local ok2, data = pcall(function() return HttpService:JSONDecode(raw) end)
    if ok2 and type(data) == "table" then return data end
    return {}
end

local function saveState(data)
    if not writefile then return end
    pcall(function() writefile(STATE_FILE, HttpService:JSONEncode(data)) end)
end

local PERSIST = loadState()
PERSIST.lastTeleportAttempt = PERSIST.lastTeleportAttempt or 0
PERSIST.targets             = PERSIST.targets or {}
PERSIST.attemptsThisHour    = PERSIST.attemptsThisHour or 0
PERSIST.hourWindowStart     = PERSIST.hourWindowStart or 0
PERSIST.lastBootTime        = PERSIST.lastBootTime or 0
PERSIST.brokenGames         = PERSIST.brokenGames or {}
PERSIST.toggles             = PERSIST.toggles or {}
PERSIST.benchmark           = PERSIST.benchmark or nil

for k, v in pairs(PERSIST.toggles) do
    if CFG[k] ~= nil then CFG[k] = v end
end

local now = tick()
if now - PERSIST.hourWindowStart > 3600 then
    PERSIST.hourWindowStart  = now
    PERSIST.attemptsThisHour = 0
end

local bootGap = now - PERSIST.lastBootTime
PERSIST.lastBootTime = now
saveState(PERSIST)

-- ============================================================
--  BROKEN-GAME LEARNER
-- ============================================================
local function markPlaceBroken(placeId, reason)
    if not placeId then return end
    placeId = tostring(placeId)
    PERSIST.brokenGames[placeId] = { reason = reason or "unknown", at = tick() }
    local count = 0
    for _ in pairs(PERSIST.brokenGames) do count = count + 1 end
    if count > CFG.BROKEN_GAMES_MAX then
        local oldestKey, oldestAt = nil, math.huge
        for k, v in pairs(PERSIST.brokenGames) do
            if (v.at or 0) < oldestAt then oldestAt = v.at or 0; oldestKey = k end
        end
        if oldestKey then PERSIST.brokenGames[oldestKey] = nil end
    end
    saveState(PERSIST)
    log("[Broken] Marked place", placeId, reason)
end

local function isPlaceBroken(placeId)
    if not placeId then return false end
    return PERSIST.brokenGames[tostring(placeId)] ~= nil
end

local CURRENT_PLACE_BROKEN = isPlaceBroken(game.PlaceId)
local lastReapplyAt = 0

-- ============================================================
--  CLEANUP
-- ============================================================
local function cleanupOldVersions()
    local killed = { guis = 0, globals = 0 }
    pcall(function()
        for _, guiName in ipairs({ "FpsBlackScreen", "FpsStatusHUD", "FpsBoosterUI" }) do
            local g = PLAYER_GUI:FindFirstChild(guiName)
            if g then g:Destroy(); killed.guis = killed.guis + 1 end
        end
    end)
    pcall(function()
        for k in pairs(_G) do
            if type(k) == "string" and k:find("FPS_BOOSTER") then
                _G[k] = nil; killed.globals = killed.globals + 1
            end
        end
    end)
    if killed.guis + killed.globals > 0 then
        print(("[FPS v26] Cleanup - GUIs:%d globals:%d"):format(killed.guis, killed.globals))
    end
end

pcall(cleanupOldVersions)

-- ============================================================
--  GUARD
-- ============================================================
if _G.__FPS_BOOSTER_V26 and _G.__FPS_BOOSTER_V26.reapply then
    pcall(_G.__FPS_BOOSTER_V26.reapply, "manual-rerun")
    return
end
_G.__FPS_BOOSTER_V26 = {}

-- ============================================================
--  FPS CAP
-- ============================================================
local capFn = setfpscap or set_fps_cap or _G.setfpscap or rawget(_G, "setfpscap")
local function setCap(n)
    if capFn then pcall(capFn, n); return true end
    return false
end

local httpRequest =
    (syn and syn.request) or (http and http.request) or http_request or
    request or (fluxus and fluxus.request) or (getgenv and getgenv().request)

-- ============================================================
--  AUTO-EXECUTE
-- ============================================================
local queueFn = queue_on_teleport or queueonteleport or _G.queue_on_teleport
local queuedThisSession = false

local function getSelfSource()
    if isfile and readfile and isfile(CFG.SCRIPT_FILE) then
        local ok, src = pcall(readfile, CFG.SCRIPT_FILE)
        if ok and type(src) == "string" and #src > 200 then return src end
    end
    if CFG.SCRIPT_URL and httpRequest then
        local ok, res = pcall(httpRequest, { Url = CFG.SCRIPT_URL, Method = "GET" })
        if ok and res and res.Body and #res.Body > 200 then
            if writefile then pcall(writefile, CFG.SCRIPT_FILE, res.Body) end
            return res.Body
        end
    end
    return nil
end

local function queueSelf(force)
    if not CFG.AUTO_EXECUTE_ENABLED then return end
    if queuedThisSession and not force then return end
    if not queueFn then return end
    local src = getSelfSource()
    if not src then return end
    local ok = pcall(queueFn, src)
    if ok then queuedThisSession = true end
end

queueSelf(false)

-- ============================================================
--  AUTO-RECONNECT
-- ============================================================
local lastTeleportTarget = { placeId = nil, jobId = nil, attempts = 0 }

pcall(function()
    TeleportService.TeleportInitFailed:Connect(function(plr, result, err)
        if plr ~= player then return end
        if tick() - lastReapplyAt < CFG.KICK_WINDOW and game.PlaceId > 0 then
            markPlaceBroken(game.PlaceId, "teleport-fail")
        end
        if not CFG.AUTO_RECONNECT_ENABLED then return end
        local t = lastTeleportTarget
        if not t.placeId then return end
        if t.attempts >= CFG.RECONNECT_MAX_ATTEMPTS then return end
        task.spawn(function()
            task.wait(CFG.RECONNECT_DELAY)
            if tick() - PERSIST.lastTeleportAttempt >= CFG.GLOBAL_COOLDOWN then
                t.attempts = t.attempts + 1
                PERSIST.lastTeleportAttempt = tick()
                PERSIST.attemptsThisHour = PERSIST.attemptsThisHour + 1
                saveState(PERSIST)
                queueSelf(true)
                pcall(function()
                    if t.jobId and t.jobId ~= "" then
                        TeleportService:TeleportToPlaceInstance(t.placeId, t.jobId, player)
                    else
                        TeleportService:Teleport(t.placeId, player)
                    end
                end)
            end
        end)
    end)
end)

-- ============================================================
--  RUNTIME STATE
-- ============================================================
local ENABLED        = true
local AFK_ACTIVE     = false
local MUTE_ON        = CFG.MUTE_ALL_SOUNDS
local blackScreenOn  = CFG.BLACK_SCREEN
local autoJoinOn     = CFG.AUTO_JOIN_ENABLED

local lastAutoJoinStatus = "idle"
local lastAutoJoinReason = ""

local lastSoundCount = 0
local lastFreedMB    = 0

local dirtyCount = 0

local counts = { parts = 0, sounds = 0, decals = 0, particles = 0, viewports = 0, guis = 0 }

-- ============================================================
--  PLAYER TRACKER
-- ============================================================
local track = {
    userId = CFG.TRACK_USER_ID, displayName = CFG.TRACK_USERNAME,
    online = false, inGame = false, inStudio = false, sameServer = false,
    sameUniverse = false, samePlace = false, sameJob = false,
    placeId = nil, jobId = nil, universeId = nil, gameName = nil,
    lastError = nil, lastUpdate = 0,
}

local function safeJsonDecode(body)
    local ok, data = pcall(function() return HttpService:JSONDecode(body) end)
    if ok then return data end
    return nil
end

local function shortJobId(id)
    if not id or id == "" then return "-" end
    if #id <= CFG.JOBID_DISPLAY_LEN then return id end
    return id:sub(1, CFG.JOBID_DISPLAY_LEN) .. "..."
end

local function pick(t, ...)
    for _, k in ipairs({...}) do
        local v = t[k]
        if v ~= nil and v ~= "" and v ~= 0 then return v end
    end
    return nil
end

local function tryRegexPlaceId(body)
    if type(body) ~= "string" then return nil end
    local id = body:match('"placeId"%s*:%s*(%d+)') or body:match('"rootPlaceId"%s*:%s*(%d+)')
    if id then return tonumber(id) end
    return nil
end

local function tryRegexJobId(body)
    if type(body) ~= "string" then return nil end
    local id = body:match('"gameId"%s*:%s*"([^"]+)"') or body:match('"jobId"%s*:%s*"([^"]+)"')
    if id and id ~= "" then return id end
    return nil
end

local function tryRegexUniverseId(body)
    if type(body) ~= "string" then return nil end
    local id = body:match('"universeId"%s*:%s*(%d+)')
    if id then return tonumber(id) end
    return nil
end

local function placeFromUniverse(universeId)
    if not universeId or not httpRequest then return nil end
    local url = CFG.USE_ROPROXY
        and (CFG.PROXY_GAMES .. "?universeIds=" .. tostring(universeId))
        or  (CFG.DIRECT_GAMES .. "?universeIds=" .. tostring(universeId))
    local ok, res = pcall(httpRequest, { Url = url, Method = "GET" })
    if not ok or not res or not res.Body then return nil end
    local data = safeJsonDecode(res.Body)
    if data and data.data and data.data[1] then
        local e = data.data[1]
        return e.rootPlaceId or e.placeId, e.name
    end
    return nil
end

local function findTrackedPlayer()
    local byName = Players:FindFirstChild(CFG.TRACK_USERNAME)
    if byName and byName.UserId == CFG.TRACK_USER_ID then return byName end
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr.UserId == CFG.TRACK_USER_ID then return plr end
    end
    return byName
end

local function refreshTrack()
    track.lastError = nil

    local inServer = findTrackedPlayer()
    if inServer then
        track.online = true; track.inGame = true; track.inStudio = false
        track.sameServer = true; track.sameUniverse = true
        track.samePlace = true; track.sameJob = true
        track.userId = inServer.UserId; track.displayName = inServer.DisplayName
        track.placeId = game.PlaceId; track.jobId = game.JobId
        track.universeId = game.GameId; track.gameName = game.Name
        track.lastUpdate = tick()
        return
    end
    track.sameServer = false

    if not httpRequest then
        track.lastError = "no http"; track.lastUpdate = tick(); return
    end

    local url = CFG.USE_ROPROXY and CFG.PROXY_PRESENCE or CFG.DIRECT_PRESENCE
    local ok, res = pcall(httpRequest, {
        Url = url, Method = "POST",
        Headers = { ["Content-Type"] = "application/json" },
        Body = HttpService:JSONEncode({ userIds = { CFG.TRACK_USER_ID } }),
    })
    if not ok or not res or not res.Body then
        track.lastError = "presence fail"; track.lastUpdate = tick(); return
    end
    if res.StatusCode and res.StatusCode >= 400 then
        track.lastError = "HTTP " .. tostring(res.StatusCode)
        track.lastUpdate = tick(); return
    end

    local body = res.Body
    local data = safeJsonDecode(body)
    if not data or not data.userPresences or not data.userPresences[1] then
        track.lastError = "bad presence"; track.lastUpdate = tick(); return
    end

    local p = data.userPresences[1]
    local pType = pick(p, "userPresenceType", "UserPresenceType") or 0

    track.online = pType > 0; track.inGame = (pType == 2); track.inStudio = (pType == 3)
    track.userId = pick(p, "userId", "UserId") or CFG.TRACK_USER_ID
    track.displayName = pick(p, "displayName", "DisplayName") or CFG.TRACK_USERNAME
    track.placeId = pick(p, "placeId", "rootPlaceId", "PlaceId", "RootPlaceId") or tryRegexPlaceId(body)
    track.jobId = pick(p, "gameId", "jobId", "GameId", "JobId") or tryRegexJobId(body)
    track.universeId = pick(p, "universeId", "UniverseId") or tryRegexUniverseId(body)
    track.gameName = pick(p, "lastLocation", "LastLocation", "gameName", "GameName")

    if track.inGame and not track.placeId and track.universeId then
        local pid, name = placeFromUniverse(track.universeId)
        if pid then track.placeId = pid end
        if name and not track.gameName then track.gameName = name end
    end

    track.sameUniverse = (track.universeId and game.GameId
        and tostring(track.universeId) == tostring(game.GameId))
    track.samePlace = (track.placeId and game.PlaceId
        and tonumber(track.placeId) == tonumber(game.PlaceId))
    track.sameJob = (track.jobId and game.JobId
        and tostring(track.jobId) == tostring(game.JobId))

    track.lastError = nil
    track.lastUpdate = tick()
end

-- ============================================================
--  AUTO-JOIN
-- ============================================================
local function canTeleport()
    if tick() - PERSIST.lastBootTime < CFG.BOOT_GRACE then
        return false, ("boot grace %ds"):format(math.ceil(CFG.BOOT_GRACE - (tick() - PERSIST.lastBootTime)))
    end
    local sinceGlobal = tick() - PERSIST.lastTeleportAttempt
    if sinceGlobal < CFG.GLOBAL_COOLDOWN then
        return false, ("global cd %ds"):format(math.ceil(CFG.GLOBAL_COOLDOWN - sinceGlobal))
    end
    if PERSIST.attemptsThisHour >= CFG.MAX_ATTEMPTS_PER_HOUR then
        return false, ("hourly cap %d"):format(CFG.MAX_ATTEMPTS_PER_HOUR)
    end
    local key = tostring(track.placeId) .. "|" .. tostring(track.jobId or "")
    local lastTarget = PERSIST.targets[key] or 0
    if tick() - lastTarget < CFG.TARGET_COOLDOWN then
        return false, ("target cd %ds"):format(math.ceil(CFG.TARGET_COOLDOWN - (tick() - lastTarget)))
    end
    return true, "ok"
end

local function recordAttempt()
    PERSIST.lastTeleportAttempt = tick()
    PERSIST.attemptsThisHour = PERSIST.attemptsThisHour + 1
    local key = tostring(track.placeId) .. "|" .. tostring(track.jobId or "")
    PERSIST.targets[key] = tick()
    saveState(PERSIST)
end

local function tryAutoJoin()
    if not autoJoinOn then lastAutoJoinStatus = "paused"; return end
    if track.sameServer then lastAutoJoinStatus = "already with them"; return end
    if track.sameUniverse and track.inGame then lastAutoJoinStatus = "same universe"; return end
    if track.samePlace then lastAutoJoinStatus = "same place"; return end
    if not track.inGame then lastAutoJoinStatus = "not in game"; return end
    if not track.placeId then lastAutoJoinStatus = "no placeId (hidden)"; return end

    local ok, reason = canTeleport()
    if not ok then
        lastAutoJoinStatus = "blocked"
        lastAutoJoinReason = reason
        return
    end

    recordAttempt()

    if track.jobId and track.jobId ~= "" then
        lastAutoJoinStatus = "teleporting (exact)"
        lastAutoJoinReason = ""
        queueSelf(true)
        lastTeleportTarget = { placeId = track.placeId, jobId = track.jobId, attempts = 0 }
        local success, err = pcall(function()
            TeleportService:TeleportToPlaceInstance(track.placeId, track.jobId, player)
        end)
        if success then lastAutoJoinStatus = "joined exact server"
        else lastAutoJoinStatus = "exact failed"; lastAutoJoinReason = tostring(err) end
        return
    end

    if track.placeId == game.PlaceId then
        lastAutoJoinStatus = "same place (no jobId)"; return
    end

    lastAutoJoinStatus = "teleporting (random)"
    lastAutoJoinReason = ""
    queueSelf(true)
    lastTeleportTarget = { placeId = track.placeId, jobId = nil, attempts = 0 }
    local success, err = pcall(function() TeleportService:Teleport(track.placeId, player) end)
    if success then lastAutoJoinStatus = "teleport sent"
    else lastAutoJoinStatus = "teleport failed"; lastAutoJoinReason = tostring(err) end
end

-- ============================================================
--  SOUND
-- ============================================================
local function setMasterVolume(vol)
    pcall(function() SoundService.AmbientReverb = Enum.ReverbType.NoReverb end)
    pcall(function() SoundService.Volume = vol end)
    for _, obj in ipairs(SoundService:GetDescendants()) do
        if obj:IsA("SoundGroup") then pcall(function() obj.Volume = vol end) end
    end
end

local function muteSound(s)
    pcall(function() s.Volume = 0; s.Playing = false; s.Looped = false; s:Stop() end)
end

local function muteAllSounds(reason)
    if not MUTE_ON then return end
    local count = 0
    setMasterVolume(0)
    local roots = { Workspace, SoundService, Lighting,
        PLAYER_GUI, player:FindFirstChild("PlayerScripts"),
        StarterGui, game:GetService("ReplicatedStorage"), game:GetService("ReplicatedFirst") }
    for _, root in ipairs(roots) do
        if root then
            for _, obj in ipairs(root:GetDescendants()) do
                if obj:IsA("Sound") then muteSound(obj); count = count + 1
                elseif obj:IsA("SoundEffect") then pcall(function() obj.Enabled = false end) end
            end
        end
    end
    if math.abs(count - lastSoundCount) > 50 then
        lastSoundCount = count
        log(("[Sound] Muted %d (%s)"):format(count, reason or "auto"))
    end
end

local function hookSoundService()
    SoundService.DescendantAdded:Connect(function(obj)
        if not MUTE_ON then return end
        task.defer(function()
            if obj:IsA("Sound") then muteSound(obj)
            elseif obj:IsA("SoundGroup") then pcall(function() obj.Volume = 0 end) end
        end)
    end)
    game.DescendantAdded:Connect(function(obj)
        if not MUTE_ON then return end
        if obj:IsA("Sound") then task.defer(function() muteSound(obj) end) end
    end)
    task.spawn(function()
        while true do
            task.wait(2)
            if MUTE_ON then pcall(function() SoundService.Volume = 0 end) end
        end
    end)
end

-- ============================================================
--  CORE STRIP
-- ============================================================
local function dropQuality()
    if not CFG.DROP_QUALITY then return end
    pcall(function() settings().Rendering.QualityLevel = Enum.QualityLevel.Level01 end)
end

local function applyLowMesh()
    if not CFG.LOW_MESH then return end
    pcall(function() settings().Rendering.MeshPartDetailLevel = Enum.MeshPartDetailLevel.Level01 end)
    for _, t in ipairs(Workspace:GetDescendants()) do
        if t:IsA("Terrain") then pcall(function() t.Decoration = false end) end
    end
end

local function killLighting()
    if not CFG.KILL_POSTFX then return end
    for _, obj in ipairs(Lighting:GetDescendants()) do
        pcall(function()
            if obj:IsA("PostEffect") then obj.Enabled = false
            elseif obj:IsA("Atmosphere") or obj:IsA("Clouds") or obj:IsA("Sky") then
                obj.Parent = nil
            end
        end)
    end
    pcall(function()
        Lighting.GlobalShadows = false
        Lighting.FogEnd = 0
        Lighting.Brightness = 0
        Lighting.EnvironmentDiffuseScale = 0
        Lighting.EnvironmentSpecularScale = 0
        Lighting.OutdoorAmbient = Color3.new(0,0,0)
    end)
end

local function killViewports(root)
    if not CFG.KILL_VIEWPORTS or not root then return end
    for _, obj in ipairs(root:GetDescendants()) do
        if obj:IsA("ViewportFrame") then pcall(function() obj:Destroy() end) end
    end
end

local function killHumanoid(char)
    if not CFG.KILL_HUMANOID or not char then return end
    for _, obj in ipairs(char:GetDescendants()) do
        pcall(function()
            if obj:IsA("Animator") then obj:Destroy()
            elseif obj:IsA("Humanoid") then obj.EvaluateStateMachine = false end
        end)
    end
end

local UI  -- forward declaration (UI table is defined below)

local function processInstance(obj)
    if not obj or not obj.Parent then return end
    if UI and UI.isOurGui and UI.isOurGui(obj) then return end
    pcall(function()
        if MUTE_ON and obj:IsA("Sound") then muteSound(obj) end
        if CFG.STRIP_TEXTURES then
            if obj:IsA("Decal") or obj:IsA("Texture") then
                obj.Texture = ""; obj.Transparency = 1
            elseif obj:IsA("MeshPart") then
                obj.TextureID = ""
            elseif obj:IsA("SurfaceAppearance") then
                obj:Destroy()
            elseif obj:IsA("ImageLabel") or obj:IsA("ImageButton") then
                obj.Image = ""; obj.ImageTransparency = 1
            end
        end
        if obj:IsA("BasePart") then
            if CFG.FLATTEN_MAT then
                obj.Material = Enum.Material.SmoothPlastic
                obj.Reflectance = 0
            end
            if CFG.DISABLE_SHADOWS then obj.CastShadow = false end
        end
        if CFG.KILL_PARTICLES then
            if obj:IsA("ParticleEmitter") or obj:IsA("Beam") or obj:IsA("Trail")
                or obj:IsA("Fire") or obj:IsA("Smoke") or obj:IsA("Sparkles") then
                obj.Enabled = false
            end
        end
        if CFG.KILL_VIEWPORTS and obj:IsA("ViewportFrame") then obj:Destroy() end
        if obj:IsA("Explosion") then obj:Destroy() end
    end)
end

local function processRoot(root)
    if not root then return end
    for _, obj in ipairs(root:GetDescendants()) do processInstance(obj) end
end

local function reapply(reason)
    if CURRENT_PLACE_BROKEN and reason ~= "manual-force" then
        log("[Reapply] Skipping - place marked broken")
        return
    end
    lastReapplyAt = tick()
    dropQuality(); applyLowMesh(); killLighting()
    killViewports(Workspace)
    pcall(function() killViewports(StarterGui) end)
    pcall(function() killViewports(PLAYER_GUI) end)
    if player.Character then killHumanoid(player.Character) end
    for _, obj in ipairs(Workspace:GetDescendants()) do
        if obj:IsA("Humanoid") then pcall(function() obj.EvaluateStateMachine = false end) end
    end
    processRoot(Workspace)
    pcall(function() processRoot(StarterGui) end)
    pcall(function() processRoot(PLAYER_GUI) end)
    if MUTE_ON then muteAllSounds(reason) end
    dirtyCount = 0
end

-- ============================================================
--  RAM CLEANER
-- ============================================================
local function getMemoryMB()
    local ok, mb = pcall(function() return math.floor(collectgarbage("count") / 1024) end)
    return ok and mb or 0
end
local lastFreed = 0

local function cleanRAM(reason)
    local before = getMemoryMB()
    pcall(collectgarbage, "collect"); pcall(collectgarbage, "collect")
    for _, obj in ipairs(Workspace:GetDescendants()) do
        pcall(function()
            if obj:IsA("Sound") and not obj.Playing and (obj.TimeLength or 0) > 0
                and obj.TimePosition >= obj.TimeLength then
                obj:Destroy()
            end
        end)
    end
    pcall(collectgarbage, "collect")
    local after = getMemoryMB()
    lastFreed = math.max(0, before - after)
    if lastFreed >= 1 or reason == "manual" then
        log(("[RAM] %s - %d MB -> %d MB (freed %d MB)"):format(reason or "auto", before, after, lastFreed))
    end
end

-- ============================================================
--  DISTANCE CULLING
-- ============================================================
local cullCache = {}
local lastCullRefresh = 0

local function startCulling()
    RunService.Heartbeat:Connect(function()
        if not CFG.CULLING then return end
        local now2 = tick()
        if now2 - lastCullRefresh > 0.5 then
            lastCullRefresh = now2
            cullCache = {}
            for _, obj in ipairs(Workspace:GetDescendants()) do
                if obj:IsA("BasePart") then table.insert(cullCache, obj) end
            end
        end
        local cam = Workspace.CurrentCamera
        if not cam then return end
        local camPos = cam.CFrame.Position
        local localChar = player.Character
        for _, part in ipairs(cullCache) do
            if part.Parent then
                if localChar and part:IsDescendantOf(localChar) then
                    -- keep local char visible
                else
                    local d = (part.Position - camPos).Magnitude
                    part.LocalTransparencyModifier = d > CFG.CULL_DISTANCE and 1 or 0
                end
            end
        end
    end)
end

-- ============================================================
--  INSTANCE COUNTER
-- ============================================================
local function refreshCounts()
    local c = { parts = 0, sounds = 0, decals = 0, particles = 0, viewports = 0, guis = 0 }
    for _, obj in ipairs(Workspace:GetDescendants()) do
        if obj:IsA("BasePart") then c.parts = c.parts + 1
        elseif obj:IsA("Sound") then c.sounds = c.sounds + 1
        elseif obj:IsA("Decal") or obj:IsA("Texture") then c.decals = c.decals + 1
        elseif obj:IsA("ParticleEmitter") then c.particles = c.particles + 1
        elseif obj:IsA("ViewportFrame") then c.viewports = c.viewports + 1
        elseif obj:IsA("ScreenGui") or obj:IsA("BillboardGui") then c.guis = c.guis + 1 end
    end
    counts = c
end

-- ============================================================
--  UI  -  FULLSCREEN BLACK STATUS OVERLAY
--  (no title bar, no buttons, no dragging, no minimize)
-- ============================================================
UI = { guis = {} }

UI.isOurGui = function(obj)
    for _, g in ipairs(UI.guis) do
        if obj == g or obj:IsDescendantOf(g) then return true end
    end
    return false
end

local Theme = {
    text    = Color3.fromRGB(235, 235, 245),
    textDim = Color3.fromRGB(150, 150, 175),
    accent  = Color3.fromRGB(120, 200, 255),
    good    = Color3.fromRGB(90, 230, 150),
    warn    = Color3.fromRGB(255, 190, 80),
    bad     = Color3.fromRGB(255, 100, 110),
}

local function new(class, props, children)
    local inst = Instance.new(class)
    for k, v in pairs(props or {}) do inst[k] = v end
    for _, c in ipairs(children or {}) do c.Parent = inst end
    return inst
end

-- ---- Notification log (replaces toasts) ----
local LOG_MAX = 6
UI.logLines = {}

local function notify(title, text, kind)
    local line = ("[%s] %s"):format(tostring(title), tostring(text))
    table.insert(UI.logLines, 1, line)
    while #UI.logLines > LOG_MAX do table.remove(UI.logLines) end
    if UI.logLabel then
        UI.logLabel.Text = table.concat(UI.logLines, "\n")
    end
    print("[FPS v26] " .. line)
end

-- ---- Presets (kept as API, no buttons) ----
local function setPreset(name)
    local presets = {
        MaxFPS = {
            STRIP_TEXTURES = true, FLATTEN_MAT = true, DISABLE_SHADOWS = true,
            KILL_POSTFX = true, KILL_PARTICLES = true, DROP_QUALITY = true,
            LOW_MESH = true, KILL_VIEWPORTS = true, KILL_HUMANOID = true,
            CULLING = true, CULL_DISTANCE = 200, ACTIVE_FPS = 10,
        },
        Balanced = {
            STRIP_TEXTURES = true, FLATTEN_MAT = true, DISABLE_SHADOWS = true,
            KILL_POSTFX = true, KILL_PARTICLES = true, DROP_QUALITY = true,
            LOW_MESH = false, KILL_VIEWPORTS = true, KILL_HUMANOID = false,
            CULLING = true, CULL_DISTANCE = 350, ACTIVE_FPS = 30,
        },
        Visual = {
            STRIP_TEXTURES = false, FLATTEN_MAT = false, DISABLE_SHADOWS = false,
            KILL_POSTFX = false, KILL_PARTICLES = false, DROP_QUALITY = false,
            LOW_MESH = false, KILL_VIEWPORTS = false, KILL_HUMANOID = false,
            CULLING = false, CULL_DISTANCE = 1000, ACTIVE_FPS = 60,
        },
    }
    local p = presets[name]
    if not p then return end
    for k, v in pairs(p) do CFG[k] = v end
    PERSIST.toggles = PERSIST.toggles or {}
    for k, v in pairs(p) do PERSIST.toggles[k] = v end
    saveState(PERSIST)
    if ENABLED and not AFK_ACTIVE then setCap(CFG.ACTIVE_FPS) end
    notify("Preset", name .. " applied")
end

local function buildUI()
    local gui = new("ScreenGui", {
        Name = "FpsBoosterUI",
        ResetOnSpawn = false,
        IgnoreGuiInset = true,
        DisplayOrder = 2147483647,
        ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
        Parent = PLAYER_GUI,
    })
    table.insert(UI.guis, gui)

    -- Fullscreen black surface
    local root = new("Frame", {
        Name = "Overlay",
        Size = UDim2.new(1, 0, 1, 0),
        Position = UDim2.new(0, 0, 0, 0),
        BackgroundColor3 = Color3.new(0, 0, 0),
        BackgroundTransparency = blackScreenOn and 0 or 0.25,
        BorderSizePixel = 0,
        Active = false,
        ClipsDescendants = true,
        Parent = gui,
    })
    UI.root = root

    -- Main status readout
    UI.statusLabel = new("TextLabel", {
        Name = "Status",
        Size = UDim2.new(1, -48, 1, -190),
        Position = UDim2.new(0, 24, 0, 24),
        BackgroundTransparency = 1,
        Text = "Booting...",
        TextColor3 = Theme.text,
        Font = Enum.Font.Code,
        TextSize = 15,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Top,
        TextWrapped = true,
        RichText = false,
        Parent = root,
    })

    -- Notification log at the bottom
    UI.logLabel = new("TextLabel", {
        Name = "Log",
        Size = UDim2.new(1, -48, 0, 130),
        Position = UDim2.new(0, 24, 1, -154),
        BackgroundTransparency = 1,
        Text = "",
        TextColor3 = Theme.textDim,
        Font = Enum.Font.Code,
        TextSize = 12,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Bottom,
        TextWrapped = true,
        Parent = root,
    })

    -- Thin accent line separating status and log
    new("Frame", {
        Size = UDim2.new(1, -48, 0, 1),
        Position = UDim2.new(0, 24, 1, -162),
        BackgroundColor3 = Theme.accent,
        BackgroundTransparency = 0.7,
        BorderSizePixel = 0,
        Parent = root,
    })
end

local function setOverlayVisible(v)
    if UI.root then UI.root.Visible = v and true or false end
end

local function applyOverlayStyle()
    if UI.root then
        UI.root.BackgroundTransparency = blackScreenOn and 0 or 0.25
    end
end

buildUI()

-- ============================================================
--  HUD UPDATER
-- ============================================================
local fpsCounter = 0
local lastFpsTick = tick()
local currentFPS = 0

local function formatUptime(sec)
    sec = math.floor(sec)
    local h = math.floor(sec / 3600)
    local m = math.floor((sec % 3600) / 60)
    local s = sec % 60
    return string.format("%02d:%02d:%02d", h, m, s)
end

local function getPing()
    local ok, p = pcall(function() return player:GetNetworkPing() end)
    if ok and type(p) == "number" then return math.floor(p * 1000) end
    return -1
end

local function trackerStatusLine()
    if track.sameServer then
        return string.format("Track   : %s  [SAME SERVER]", track.displayName)
    end
    if not track.online and track.lastError then
        return string.format("Track   : %s  [%s]", CFG.TRACK_USERNAME, track.lastError)
    end
    if track.inGame then
        return string.format("Track   : %s  [IN GAME]", track.displayName)
    end
    if track.inStudio then
        return string.format("Track   : %s  [STUDIO]", track.displayName)
    end
    if track.online then
        return string.format("Track   : %s  [ONLINE]", track.displayName)
    end
    return string.format("Track   : %s  [OFFLINE]", track.displayName)
end

local function trackerGameLine()
    if track.sameServer then
        return string.format("Game    : %s  (you're here)", track.gameName or "this game")
    end
    if track.inGame then
        if track.gameName and track.gameName ~= "" then
            return string.format("Game    : %s", track.gameName)
        end
        if track.placeId then return string.format("Game    : (placeId %d)", track.placeId) end
        return "Game    : (hidden)"
    end
    return "Game    : -"
end

local function trackerJobLine()
    local jid = shortJobId(track.jobId)
    if track.sameServer then return string.format("Server  : %s  [this server]", jid) end
    if track.inGame and track.jobId and track.jobId ~= "" then
        return string.format("Server  : %s", jid)
    end
    return "Server  : -"
end

local function autoJoinLine()
    local state = autoJoinOn and "ON" or "OFF"
    local txt = string.format("AutoJoin: %s  (%s)", state, lastAutoJoinStatus)
    if lastAutoJoinReason ~= "" then txt = txt .. "  " .. lastAutoJoinReason end
    return txt
end

local function attemptCounterLine()
    return string.format("Attempts: %d/%d this hour",
        PERSIST.attemptsThisHour, CFG.MAX_ATTEMPTS_PER_HOUR)
end

local function trackerNextCheckLine()
    if track.lastUpdate == 0 then return "Next    : checking..." end
    local remaining = math.max(0, (track.lastUpdate + CFG.TRACK_POLL_INTERVAL) - tick())
    return string.format("Next    : %ds", math.floor(remaining))
end

local function buildStatusText(ram, ping)
    local uptime = formatUptime(tick() - START_TIME)
    local state = "ON"
    if AFK_ACTIVE then state = "AFK"
    elseif not ENABLED then state = "OFF"
    end

    local sep = "------------------------------------------------------------"

    local brokenList = {}
    for pid, info in pairs(PERSIST.brokenGames) do
        table.insert(brokenList, ("%s (%s)"):format(pid, info.reason or "?"))
        if #brokenList >= 3 then break end
    end
    local brokenText = #brokenList > 0 and table.concat(brokenList, ", ") or "none"

    return table.concat({
        "============================================================",
        "  FPS BOOSTER  v26  -  FULLSCREEN STATUS",
        "============================================================",
        "",
        ("State   : %s        FPS : %d        Ping : %d ms"):format(state, currentFPS, ping),
        ("Uptime  : %s        RAM : %d MB"):format(uptime, ram),
        ("Mute    : %s        Black: %s        Broken place: %s"):format(
            MUTE_ON and "ON" or "OFF",
            blackScreenOn and "ON" or "OFF",
            CURRENT_PLACE_BROKEN and "YES" or "no"),
        ("Culling : %s (%d studs)   Dirty: %d"):format(
            CFG.CULLING and "ON" or "OFF", CFG.CULL_DISTANCE, dirtyCount),
        "",
        sep,
        trackerStatusLine(),
        trackerGameLine(),
        trackerJobLine(),
        autoJoinLine(),
        attemptCounterLine(),
        trackerNextCheckLine(),
        sep,
        ("Parts: %d   Sounds: %d   Decals: %d"):format(
            counts.parts or 0, counts.sounds or 0, counts.decals or 0),
        ("Particles: %d   Viewports: %d   GUIs: %d"):format(
            counts.particles or 0, counts.viewports or 0, counts.guis or 0),
        sep,
        ("Broken places learned: %s"):format(brokenText),
    }, "\n")
end

-- ============================================================
--  LOOPS
-- ============================================================
local function setupLoops()
    RunService.RenderStepped:Connect(function()
        fpsCounter = fpsCounter + 1
        local now2 = tick()
        if now2 - lastFpsTick >= 1 then
            currentFPS = fpsCounter
            fpsCounter = 0
            lastFpsTick = now2

            local ram = getMemoryMB()
            local ping = getPing()

            if UI.statusLabel then
                UI.statusLabel.Text = buildStatusText(ram, ping)
                local col = Theme.text
                if AFK_ACTIVE then col = Theme.warn
                elseif not ENABLED then col = Theme.bad end
                UI.statusLabel.TextColor3 = col
            end
        end
    end)

    task.spawn(function()
        while true do
            task.wait(5)
            pcall(refreshCounts)
        end
    end)

    if CFG.RAM_CLEAN_ON_START then
        task.defer(function() task.wait(3); cleanRAM("startup") end)
    end
    task.spawn(function()
        while true do
            task.wait(CFG.RAM_CLEAN_INTERVAL)
            cleanRAM("auto")
        end
    end)

    if CFG.REAPPLY_ON_START then
        task.defer(function() task.wait(5); reapply("startup") end)
    end
    task.spawn(function()
        while true do
            task.wait(CFG.REAPPLY_INTERVAL)
            if dirtyCount >= CFG.REAPPLY_DIRTY_MIN then
                reapply("timer-dirty")
            end
        end
    end)

    task.spawn(function()
        task.wait(2)
        while true do
            pcall(refreshTrack)
            pcall(tryAutoJoin)
            task.wait(CFG.TRACK_POLL_INTERVAL)
        end
    end)
end

-- ============================================================
--  ACTIVITY / AFK
-- ============================================================
local function setupAFK()
    local lastActivity = tick()
    local function markActivity()
        lastActivity = tick()
        if AFK_ACTIVE then
            AFK_ACTIVE = false
            if ENABLED then setCap(CFG.ACTIVE_FPS) end
        end
    end
    UserInputSvc.InputBegan:Connect(function(input, gpe)
        if gpe then return end
        if input.UserInputType == Enum.UserInputType.Keyboard
            or input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.MouseButton2
            or input.UserInputType == Enum.UserInputType.Touch then
            markActivity()
        end
    end)
    UserInputSvc.InputChanged:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseMovement then markActivity() end
    end)
    RunService.Heartbeat:Connect(function()
        local char = player.Character
        if not char then return end
        local hum = char:FindFirstChildOfClass("Humanoid")
        if hum and hum.MoveDirection.Magnitude > 0 then markActivity() end
        local root = char:FindFirstChild("HumanoidRootPart")
        if root then
            if not root:GetAttribute("LastPos") then
                root:SetAttribute("LastPos", root.Position)
            else
                local lastP = root:GetAttribute("LastPos")
                if (root.Position - lastP).Magnitude > 0.5 then
                    markActivity()
                    root:SetAttribute("LastPos", root.Position)
                end
            end
        end
    end)
    task.spawn(function()
        while true do
            task.wait(1)
            if ENABLED and not AFK_ACTIVE and (tick() - lastActivity) >= CFG.AFK_TIME then
                AFK_ACTIVE = true
                setCap(CFG.AFK_FPS)
            end
        end
    end)
end

-- ============================================================
--  SPAWN HOOK + DIRTY COUNTING
-- ============================================================
local function setupSpawnAndDirty()
    local queue, draining = {}, false
    local function drain()
        if draining then return end
        draining = true
        task.spawn(function()
            while #queue > 0 do
                processInstance(table.remove(queue, 1))
                task.wait()
            end
            draining = false
        end)
    end

    Workspace.DescendantAdded:Connect(function(obj)
        dirtyCount = dirtyCount + 1
        if CFG.REAPPLY_ON_SPAWN then
            table.insert(queue, obj)
            drain()
        end
    end)

    PLAYER_GUI.DescendantAdded:Connect(function(obj)
        if UI.isOurGui(obj) then return end
        dirtyCount = dirtyCount + 1
    end)

    player.CharacterAdded:Connect(function(char)
        task.wait(0.5)
        killHumanoid(char)
        processRoot(char)
        if MUTE_ON then muteAllSounds("respawn") end
    end)
end

-- ============================================================
--  KICK DETECTION
-- ============================================================
pcall(function()
    Players.PlayerRemoving:Connect(function(plr)
        if plr ~= player then return end
        if tick() - lastReapplyAt < CFG.KICK_WINDOW and game.PlaceId > 0 then
            markPlaceBroken(game.PlaceId, "quick-leave")
        end
    end)
end)

-- ============================================================
--  BOOT
-- ============================================================
setupAFK()
setupSpawnAndDirty()
hookSoundService()
startCulling()
setupLoops()

reapply("boot")
setCap(CFG.ACTIVE_FPS)

task.delay(5, function() queueSelf(false) end)

task.defer(function()
    task.wait(2)
    notify("FPS Booster v26", "Fullscreen status edition loaded")
    if CURRENT_PLACE_BROKEN then
        notify("Warning", "This place is marked broken - stripping skipped")
    end
    print("[FPS Booster v26 Fullscreen] Ready.")
    print("  Place broken:", CURRENT_PLACE_BROKEN)
    print("  AutoJoin:", autoJoinOn and "ON" or "OFF")
    print("  Max attempts/hour:", CFG.MAX_ATTEMPTS_PER_HOUR,
        "| used:", PERSIST.attemptsThisHour)
    pcall(refreshTrack)
    pcall(refreshCounts)
end)

-- ============================================================
--  PUBLIC API
-- ============================================================
_G.__FPS_BOOSTER_V26.reapply     = reapply
_G.__FPS_BOOSTER_V26.cleanRAM    = cleanRAM
_G.__FPS_BOOSTER_V26.muteAll     = muteAllSounds
_G.__FPS_BOOSTER_V26.track       = track
_G.__FPS_BOOSTER_V26.refresh     = refreshTrack
_G.__FPS_BOOSTER_V26.autoJoin    = tryAutoJoin
_G.__FPS_BOOSTER_V26.queueSelf   = queueSelf
_G.__FPS_BOOSTER_V26.cfg         = CFG
_G.__FPS_BOOSTER_V26.ui          = UI
_G.__FPS_BOOSTER_V26.notify      = notify
_G.__FPS_BOOSTER_V26.setPreset   = setPreset
_G.__FPS_BOOSTER_V26.setOverlay  = setOverlayVisible

_G.__FPS_BOOSTER_V26.setBlack = function(v)
    blackScreenOn = v and true or false
    CFG.BLACK_SCREEN = blackScreenOn
    applyOverlayStyle()
end

_G.__FPS_BOOSTER_V26.destroy = function()
    for _, g in ipairs(UI.guis) do pcall(function() g:Destroy() end) end
    pcall(setCap, 0)
    _G.__FPS_BOOSTER_V26 = nil
    print("[FPS v26] Destroyed")
end

_G.__FPS_BOOSTER_V26.resetSpam = function()
    PERSIST.lastTeleportAttempt = 0
    PERSIST.targets = {}
    PERSIST.attemptsThisHour = 0
    saveState(PERSIST)
    print("[FPS v26] Spam state reset")
end
