--[[
    ============================================================
      FPS BOOSTER v26.2 - Premium Edition
      - Full-screen black overlay ON by default at execute
      - Anti-AFK (VirtualUser Idled hook) so Roblox never idle-kicks
      - Premium tabbed UI (Dashboard / Settings / Diagnostics)
      - No keybinds; everything auto-starts and is UI-driven
      - Per-game blacklist (auto-learned)
      - Distance-based part culling
      - Selective reapply (dirty-count aware)
      - FPS / RAM / Ping sparklines
      - Instance counter
      - Benchmark (on vs off delta)
      - Presets: MaxFPS / Balanced / Visual
      - Toast notifications
      - Draggable HUD + floating toggle button
    ============================================================
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
    BLACK_SCREEN        = true,   -- ★ full-screen black ON by default
    CULLING             = true,
    CULL_DISTANCE       = 250,
    ANTI_AFK            = true,   -- ★ stops Roblox 20-min idle kick / rejoin
    ANTI_AFK_INTERVAL   = 60,     -- seconds between simulated inputs

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
local VirtualUser     = game:GetService("VirtualUser")

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

-- Force black screen on for this boot regardless of saved toggle
CFG.BLACK_SCREEN = true

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
local antiAfkOn      = CFG.ANTI_AFK

local lastAutoJoinStatus = "idle"
local lastAutoJoinReason = ""

local lastSoundCount = 0
local lastFreedMB    = 0

local dirtyCount = 0
local antiAfkCount = 0

local counts = { parts = 0, sounds = 0, decals = 0, particles = 0, viewports = 0, guis = 0 }

local HIST_LEN = 60
local fpsHistory, ramHistory, pingHistory = {}, {}, {}
local function pushHistory(t, v)
    table.insert(t, v)
    if #t > HIST_LEN then table.remove(t, 1) end
end

-- ============================================================
--  ANTI-AFK
--  Simulates a virtual key so Roblox's 20-min idle kick never fires.
--  This is what stops the "rejoining" behaviour.
-- ============================================================
local function setupAntiAFK()
    -- Primary: hook the Idled signal - fires right before the kick
    pcall(function()
        player.Idled:Connect(function()
            if not antiAfkOn then return end
            pcall(function()
                VirtualUser:CaptureController()
                VirtualUser:ClickButton2(Vector2.new())
            end)
            antiAfkCount = antiAfkCount + 1
            log("[Anti-AFK] Idled signal caught - simulated input")
        end)
    end)

    -- Secondary: periodic drift so the AFK timer never accumulates
    task.spawn(function()
        while true do
            task.wait(CFG.ANTI_AFK_INTERVAL)
            if antiAfkOn then
                pcall(function()
                    VirtualUser:CaptureController()
                    VirtualUser:ClickButton2(Vector2.new())
                end)
                -- also nudge a harmless key so we look active
                pcall(function()
                    VirtualUser:SetKeyDown(" ")
                    VirtualUser:SetKeyUp(" ")
                end)
                antiAfkCount = antiAfkCount + 1
                log("[Anti-AFK] Periodic simulated input")
            end
        end
    end)
end

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

local UI  -- forward decl

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
--  UI  -  PREMIUM THEME
-- ============================================================
UI = { guis = {} }

UI.isOurGui = function(obj)
    for _, g in ipairs(UI.guis) do
        if obj == g or obj:IsDescendantOf(g) then return true end
    end
    return false
end

local Theme = {
    bg0     = Color3.fromRGB(10, 10, 16),
    bg1     = Color3.fromRGB(18, 18, 26),
    bg2     = Color3.fromRGB(24, 24, 34),
    bg3     = Color3.fromRGB(32, 32, 44),
    stroke  = Color3.fromRGB(48, 48, 66),
    text    = Color3.fromRGB(230, 230, 240),
    textDim = Color3.fromRGB(140, 140, 165),
    accentA = Color3.fromRGB(150, 90, 255),
    accentB = Color3.fromRGB(80, 200, 255),
    success = Color3.fromRGB(60, 220, 130),
    warning = Color3.fromRGB(255, 180, 60),
    danger  = Color3.fromRGB(255, 80, 100),
}

local function new(class, props, children)
    local inst = Instance.new(class)
    for k, v in pairs(props or {}) do inst[k] = v end
    for _, c in ipairs(children or {}) do c.Parent = inst end
    return inst
end

local function corner(parent, r)
    return new("UICorner", { CornerRadius = UDim.new(0, r or 8), Parent = parent })
end

local function stroke(parent, color, thickness, transparency)
    return new("UIStroke", {
        Color = color or Theme.stroke,
        Thickness = thickness or 1,
        Transparency = transparency or 0,
        ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
        Parent = parent,
    })
end

local function gradient(parent, a, b, rot)
    return new("UIGradient", {
        Color = ColorSequence.new {
            ColorSequenceKeypoint.new(0, a or Theme.accentA),
            ColorSequenceKeypoint.new(1, b or Theme.accentB),
        },
        Rotation = rot or 0,
        Parent = parent,
    })
end

local function padding(parent, t, r, b, l)
    return new("UIPadding", {
        PaddingTop = UDim.new(0, t or 0),
        PaddingRight = UDim.new(0, r or 0),
        PaddingBottom = UDim.new(0, b or 0),
        PaddingLeft = UDim.new(0, l or 0),
        Parent = parent,
    })
end

-- ---- Notification toasts ----
local notifContainer

local function notify(title, text, kind)
    if not notifContainer then return end
    local color = Theme.accentA
    if kind == "success" then color = Theme.success
    elseif kind == "warn" then color = Theme.warning
    elseif kind == "danger" then color = Theme.danger
    end

    local frame = new("Frame", {
        Size = UDim2.new(0, 300, 0, 62),
        BackgroundColor3 = Theme.bg2,
        BorderSizePixel = 0,
        Position = UDim2.new(1, 320, 0, 0),
        Parent = notifContainer,
    })
    corner(frame, 10)
    stroke(frame, color, 1, 0.4)

    local accent = new("Frame", {
        Size = UDim2.new(0, 3, 1, -16),
        Position = UDim2.new(0, 6, 0, 8),
        BackgroundColor3 = color,
        BorderSizePixel = 0,
        Parent = frame,
    })
    corner(accent, 2)

    new("TextLabel", {
        Size = UDim2.new(1, -22, 0, 20),
        Position = UDim2.new(0, 16, 0, 8),
        BackgroundTransparency = 1,
        Text = title,
        TextColor3 = Theme.text,
        Font = Enum.Font.GothamBold,
        TextSize = 13,
        TextXAlignment = Enum.TextXAlignment.Left,
        Parent = frame,
    })
    new("TextLabel", {
        Size = UDim2.new(1, -22, 1, -30),
        Position = UDim2.new(0, 16, 0, 26),
        BackgroundTransparency = 1,
        Text = text,
        TextColor3 = Theme.textDim,
        Font = Enum.Font.Gotham,
        TextSize = 11,
        TextWrapped = true,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Top,
        Parent = frame,
    })

    for _, child in ipairs(notifContainer:GetChildren()) do
        if child:IsA("Frame") and child ~= frame then
            TweenService:Create(child, TweenInfo.new(0.25), {
                Position = child.Position + UDim2.new(0, 0, 0, 70),
            }):Play()
        end
    end

    TweenService:Create(frame, TweenInfo.new(0.35, Enum.EasingStyle.Quart, Enum.EasingDirection.Out), {
        Position = UDim2.new(1, -316, 0, 0),
    }):Play()

    task.delay(4.5, function()
        local t = TweenService:Create(frame, TweenInfo.new(0.25), {
            Position = UDim2.new(1, 320, 0, 0),
        })
        t:Play()
        t.Completed:Connect(function() frame:Destroy() end)
    end)
end

-- ---- Sparkline widget ----
local function makeSparkline(parent, title, color, maxValue)
    local wrap = new("Frame", {
        Size = UDim2.new(0.5, -6, 0, 88),
        BackgroundColor3 = Theme.bg2,
        BorderSizePixel = 0,
        Parent = parent,
    })
    corner(wrap, 10); stroke(wrap, Theme.stroke, 1, 0.6)

    new("TextLabel", {
        Size = UDim2.new(1, -16, 0, 18),
        Position = UDim2.new(0, 10, 0, 8),
        BackgroundTransparency = 1,
        Text = title,
        TextColor3 = Theme.textDim,
        Font = Enum.Font.GothamMedium,
        TextSize = 11,
        TextXAlignment = Enum.TextXAlignment.Left,
        Parent = wrap,
    })

    local valueLbl = new("TextLabel", {
        Size = UDim2.new(1, -16, 0, 20),
        Position = UDim2.new(0, 10, 0, 24),
        BackgroundTransparency = 1,
        Text = "0",
        TextColor3 = Theme.text,
        Font = Enum.Font.GothamBold,
        TextSize = 15,
        TextXAlignment = Enum.TextXAlignment.Left,
        Parent = wrap,
    })

    local chart = new("Frame", {
        Size = UDim2.new(1, -20, 0, 32),
        Position = UDim2.new(0, 10, 1, -40),
        BackgroundTransparency = 1,
        ClipsDescendants = true,
        Parent = wrap,
    })

    local bars = {}
    for i = 1, HIST_LEN do
        local bar = new("Frame", {
            Size = UDim2.new(1/HIST_LEN - 0.003, 0, 0, 0),
            Position = UDim2.new((i-1)/HIST_LEN, 0, 1, 0),
            AnchorPoint = Vector2.new(0, 1),
            BackgroundColor3 = color,
            BorderSizePixel = 0,
            Parent = chart,
        })
        bars[i] = bar
    end

    local function setValue(v)
        valueLbl.Text = tostring(v)
        local history = pingHistory
        if title:find("FPS") then
            history = fpsHistory
        elseif title:find("RAM") then
            history = ramHistory
        end
        for i = 1, HIST_LEN do
            local val = history[i] or 0
            local h = math.clamp(val / (maxValue or 100), 0, 1)
            bars[i].Size = UDim2.new(1/HIST_LEN - 0.003, 0, h, 0)
        end
    end

    return { wrap = wrap, setValue = setValue }
end

-- ---- Toggle switch ----
local function makeToggle(parent, label, getter, setter)
    local row = new("Frame", {
        Size = UDim2.new(1, 0, 0, 34),
        BackgroundTransparency = 1,
        Parent = parent,
    })
    new("TextLabel", {
        Size = UDim2.new(1, -70, 1, 0),
        BackgroundTransparency = 1,
        Text = label,
        TextColor3 = Theme.text,
        Font = Enum.Font.Gotham,
        TextSize = 12,
        TextXAlignment = Enum.TextXAlignment.Left,
        Parent = row,
    })
    local track = new("Frame", {
        Size = UDim2.new(0, 44, 0, 22),
        Position = UDim2.new(1, -50, 0.5, -11),
        BackgroundColor3 = getter() and Theme.accentA or Theme.bg3,
        BorderSizePixel = 0,
        Parent = row,
    })
    corner(track, 11)
    local knob = new("Frame", {
        Size = UDim2.new(0, 16, 0, 16),
        Position = getter() and UDim2.new(1, -20, 0.5, -8) or UDim2.new(0, 4, 0.5, -8),
        BackgroundColor3 = Color3.new(1, 1, 1),
        BorderSizePixel = 0,
        Parent = track,
    })
    corner(knob, 8)

    local btn = new("TextButton", {
        Size = UDim2.new(1, 0, 1, 0),
        BackgroundTransparency = 1,
        Text = "",
        Parent = row,
    })
    btn.MouseButton1Click:Connect(function()
        local newVal = not getter()
        setter(newVal)
        TweenService:Create(track, TweenInfo.new(0.2), {
            BackgroundColor3 = newVal and Theme.accentA or Theme.bg3,
        }):Play()
        TweenService:Create(knob, TweenInfo.new(0.2), {
            Position = newVal and UDim2.new(1, -20, 0.5, -8) or UDim2.new(0, 4, 0.5, -8),
        }):Play()
    end)

    return row
end

-- ---- Slider ----
local function makeSlider(parent, label, min, max, getter, setter)
    local row = new("Frame", {
        Size = UDim2.new(1, 0, 0, 46),
        BackgroundTransparency = 1,
        Parent = parent,
    })
    new("TextLabel", {
        Size = UDim2.new(0.5, 0, 0, 18),
        BackgroundTransparency = 1,
        Text = label,
        TextColor3 = Theme.text,
        Font = Enum.Font.Gotham,
        TextSize = 12,
        TextXAlignment = Enum.TextXAlignment.Left,
        Parent = row,
    })
    local valLbl = new("TextLabel", {
        Size = UDim2.new(0.5, 0, 0, 18),
        Position = UDim2.new(0.5, 0, 0, 0),
        BackgroundTransparency = 1,
        Text = tostring(getter()),
        TextColor3 = Theme.accentB,
        Font = Enum.Font.GothamBold,
        TextSize = 12,
        TextXAlignment = Enum.TextXAlignment.Right,
        Parent = row,
    })
    local bar = new("Frame", {
        Size = UDim2.new(1, 0, 0, 6),
        Position = UDim2.new(0, 0, 0, 28),
        BackgroundColor3 = Theme.bg3,
        BorderSizePixel = 0,
        Parent = row,
    })
    corner(bar, 3)
    local fill = new("Frame", {
        Size = UDim2.new((getter() - min) / (max - min), 0, 1, 0),
        BackgroundColor3 = Theme.accentA,
        BorderSizePixel = 0,
        Parent = bar,
    })
    corner(fill, 3)

    local function updateFromX(x)
        local rel = math.clamp((x - bar.AbsolutePosition.X) / bar.AbsoluteSize.X, 0, 1)
        local value = math.floor(min + rel * (max - min) + 0.5)
        valLbl.Text = tostring(value)
        fill.Size = UDim2.new((value - min) / (max - min), 0, 1, 0)
        setter(value)
    end

    local dragging = false
    bar.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            updateFromX(input.Position.X)
        end
    end)
    UserInputSvc.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
            or input.UserInputType == Enum.UserInputType.Touch) then
            updateFromX(input.Position.X)
        end
    end)
    UserInputSvc.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging = false
            PERSIST.toggles = PERSIST.toggles or {}
            saveState(PERSIST)
        end
    end)

    return row
end

-- ---- Main window ----
local mainWindow, pageContainer
local pageFrames = {}
local tabButtons = {}
local activeTab = "Dashboard"

local function setTab(name)
    activeTab = name
    for n, frame in pairs(pageFrames) do
        frame.Visible = (n == name)
    end
    for n, btn in pairs(tabButtons) do
        local isActive = (n == name)
        TweenService:Create(btn, TweenInfo.new(0.2), {
            BackgroundColor3 = isActive and Theme.bg3 or Theme.bg1,
            TextColor3 = isActive and Theme.text or Theme.textDim,
        }):Play()
        local ind = btn:FindFirstChild("Indicator")
        if ind then ind.Visible = isActive end
    end
end

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
    notify("Preset", name .. " applied", "success")
end

local function buildUI()
    -- Main UI gui
    local gui = new("ScreenGui", {
        Name = "FpsBoosterUI",
        ResetOnSpawn = false,
        IgnoreGuiInset = true,
        DisplayOrder = 2147483647,
        ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
        Parent = PLAYER_GUI,
    })
    table.insert(UI.guis, gui)

    -- Full-screen black overlay gui (highest display order so it covers everything else)
    local bsGui = new("ScreenGui", {
        Name = "FpsBlackScreen",
        ResetOnSpawn = false,
        IgnoreGuiInset = true,
        DisplayOrder = 2147483646,   -- just below our UI so the panel is still clickable
        Parent = PLAYER_GUI,
    })
    table.insert(UI.guis, bsGui)
    local bsFrame = new("Frame", {
        Size = UDim2.new(1, 8, 1, 8),
        Position = UDim2.new(0, -4, 0, -4),
        BackgroundColor3 = Color3.new(0, 0, 0),
        BorderSizePixel = 0,
        Visible = blackScreenOn,
        ZIndex = 1,
        Parent = bsGui,
    })
    UI.blackFrame = bsFrame

    -- Toast container
    notifContainer = new("Frame", {
        Name = "Notifications",
        AnchorPoint = Vector2.new(1, 0),
        Position = UDim2.new(1, -16, 0, 16),
        Size = UDim2.new(0, 300, 1, -32),
        BackgroundTransparency = 1,
        Parent = gui,
    })
    new("UIListLayout", {
        Padding = UDim.new(0, 8),
        SortOrder = Enum.SortOrder.LayoutOrder,
        HorizontalAlignment = Enum.HorizontalAlignment.Right,
        Parent = notifContainer,
    })

    -- Floating toggle button
    local toggleBtn = new("TextButton", {
        Name = "ToggleBtn",
        Size = UDim2.new(0, 54, 0, 54),
        Position = UDim2.new(1, -74, 1, -74),
        BackgroundColor3 = Theme.bg2,
        Text = "FPS",
        TextColor3 = Theme.accentB,
        Font = Enum.Font.GothamBold,
        TextSize = 15,
        AutoButtonColor = false,
        Parent = gui,
    })
    corner(toggleBtn, 27)
    stroke(toggleBtn, Theme.accentB, 1, 0.3)

    -- Main window
    mainWindow = new("Frame", {
        Name = "MainWindow",
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.new(0.5, 0, 0.5, 0),
        Size = UDim2.new(0, 620, 0, 460),
        BackgroundColor3 = Theme.bg1,
        BorderSizePixel = 0,
        Visible = true,
        Parent = gui,
    })
    corner(mainWindow, 14)
    stroke(mainWindow, Theme.accentA, 1, 0.55)

    toggleBtn.MouseButton1Click:Connect(function()
        mainWindow.Visible = not mainWindow.Visible
    end)

    -- Header
    local header = new("Frame", {
        Size = UDim2.new(1, 0, 0, 46),
        BackgroundColor3 = Theme.bg0,
        BorderSizePixel = 0,
        Parent = mainWindow,
    })
    corner(header, 14)
    new("Frame", {
        Size = UDim2.new(1, 0, 0, 14),
        Position = UDim2.new(0, 0, 1, -14),
        BackgroundColor3 = Theme.bg0,
        BorderSizePixel = 0,
        Parent = header,
    })

    new("TextLabel", {
        Size = UDim2.new(1, -120, 1, 0),
        Position = UDim2.new(0, 44, 0, 0),
        BackgroundTransparency = 1,
        Text = "FPS Booster  |  v26 Premium",
        TextColor3 = Theme.text,
        Font = Enum.Font.GothamBold,
        TextSize = 14,
        TextXAlignment = Enum.TextXAlignment.Left,
        Parent = header,
    })

    local logo = new("Frame", {
        Size = UDim2.new(0, 26, 0, 26),
        Position = UDim2.new(0, 12, 0.5, -13),
        BackgroundColor3 = Theme.accentA,
        BorderSizePixel = 0,
        Parent = header,
    })
    corner(logo, 8)
    gradient(logo, Theme.accentA, Theme.accentB, 45)
    new("TextLabel", {
        Size = UDim2.new(1, 0, 1, 0),
        BackgroundTransparency = 1,
        Text = "F",
        TextColor3 = Color3.new(1, 1, 1),
        Font = Enum.Font.GothamBold,
        TextSize = 15,
        Parent = logo,
    })

    local closeBtn = new("TextButton", {
        Size = UDim2.new(0, 28, 0, 28),
        Position = UDim2.new(1, -36, 0.5, -14),
        BackgroundColor3 = Theme.bg2,
        Text = "x",
        TextColor3 = Theme.textDim,
        Font = Enum.Font.GothamBold,
        TextSize = 18,
        AutoButtonColor = false,
        Parent = header,
    })
    corner(closeBtn, 8)
    closeBtn.MouseButton1Click:Connect(function()
        mainWindow.Visible = false
    end)

    -- Drag
    local dragging, dragStart, startPos
    header.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPos = mainWindow.Position
        end
    end)
    header.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
            or input.UserInputType == Enum.UserInputType.Touch) then
            local delta = input.Position - dragStart
            mainWindow.Position = UDim2.new(
                startPos.X.Scale, startPos.X.Offset + delta.X,
                startPos.Y.Scale, startPos.Y.Offset + delta.Y)
        end
    end)
    UserInputSvc.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end)

    -- Tab bar
    local tabBar = new("Frame", {
        Size = UDim2.new(1, 0, 0, 40),
        Position = UDim2.new(0, 0, 0, 46),
        BackgroundColor3 = Theme.bg0,
        BorderSizePixel = 0,
        Parent = mainWindow,
    })
    new("UIListLayout", {
        FillDirection = Enum.FillDirection.Horizontal,
        Padding = UDim.new(0, 0),
        SortOrder = Enum.SortOrder.LayoutOrder,
        Parent = tabBar,
    })

    local function makeTab(name)
        local btn = new("TextButton", {
            Size = UDim2.new(1/3, 0, 1, 0),
            BackgroundColor3 = Theme.bg1,
            Text = name,
            TextColor3 = Theme.textDim,
            Font = Enum.Font.GothamMedium,
            TextSize = 12,
            AutoButtonColor = false,
            Parent = tabBar,
        })
        local ind = new("Frame", {
            Name = "Indicator",
            Size = UDim2.new(1, -24, 0, 2),
            Position = UDim2.new(0, 12, 1, -2),
            BackgroundColor3 = Theme.accentB,
            BorderSizePixel = 0,
            Visible = false,
            Parent = btn,
        })
        corner(ind, 1)
        btn.MouseButton1Click:Connect(function() setTab(name) end)
        tabButtons[name] = btn
    end

    makeTab("Dashboard")
    makeTab("Settings")
    makeTab("Diagnostics")

    pageContainer = new("Frame", {
        Size = UDim2.new(1, -24, 1, -110),
        Position = UDim2.new(0, 12, 0, 98),
        BackgroundTransparency = 1,
        Parent = mainWindow,
    })

    -- ============================================
    -- DASHBOARD
    -- ============================================
    local dash = new("ScrollingFrame", {
        Size = UDim2.new(1, 0, 1, 0),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        ScrollBarThickness = 4,
        ScrollBarImageColor3 = Theme.accentA,
        CanvasSize = UDim2.new(0, 0, 0, 0),
        AutomaticCanvasSize = Enum.AutomaticSize.Y,
        Parent = pageContainer,
    })
    new("UIListLayout", {
        Padding = UDim.new(0, 10),
        SortOrder = Enum.SortOrder.LayoutOrder,
        Parent = dash,
    })
    padding(dash, 0, 6, 0, 0)
    pageFrames.Dashboard = dash

    local sparkRow = new("Frame", {
        Size = UDim2.new(1, 0, 0, 88),
        BackgroundTransparency = 1,
        Parent = dash,
    })
    new("UIListLayout", {
        FillDirection = Enum.FillDirection.Horizontal,
        Padding = UDim.new(0, 12),
        SortOrder = Enum.SortOrder.LayoutOrder,
        Parent = sparkRow,
    })

    UI.fpsSpark = makeSparkline(sparkRow, "FPS", Theme.accentA, 60)
    UI.ramSpark = makeSparkline(sparkRow, "RAM (MB)", Theme.accentB, 2000)

    local pingRow = new("Frame", {
        Size = UDim2.new(1, 0, 0, 88),
        BackgroundTransparency = 1,
        Parent = dash,
    })
    UI.pingSpark = makeSparkline(pingRow, "PING (ms)", Theme.warning, 300)
    UI.pingSpark.wrap.Size = UDim2.new(1, 0, 1, 0)

    -- Presets
    local presetsRow = new("Frame", {
        Size = UDim2.new(1, 0, 0, 76),
        BackgroundColor3 = Theme.bg2,
        BorderSizePixel = 0,
        Parent = dash,
    })
    corner(presetsRow, 10); stroke(presetsRow, Theme.stroke, 1, 0.6)
    new("TextLabel", {
        Size = UDim2.new(1, -20, 0, 22),
        Position = UDim2.new(0, 12, 0, 8),
        BackgroundTransparency = 1,
        Text = "Presets",
        TextColor3 = Theme.textDim,
        Font = Enum.Font.GothamMedium,
        TextSize = 11,
        TextXAlignment = Enum.TextXAlignment.Left,
        Parent = presetsRow,
    })
    local presetBtnRow = new("Frame", {
        Size = UDim2.new(1, -20, 0, 34),
        Position = UDim2.new(0, 10, 0, 34),
        BackgroundTransparency = 1,
        Parent = presetsRow,
    })
    new("UIListLayout", {
        FillDirection = Enum.FillDirection.Horizontal,
        Padding = UDim.new(0, 8),
        Parent = presetBtnRow,
    })

    local function makePresetBtn(label, gradientA, gradientB, onClick)
        local btn = new("TextButton", {
            Size = UDim2.new(1/3, -6, 1, 0),
            BackgroundColor3 = Theme.bg3,
            Text = label,
            TextColor3 = Color3.new(1, 1, 1),
            Font = Enum.Font.GothamBold,
            TextSize = 12,
            AutoButtonColor = false,
            Parent = presetBtnRow,
        })
        corner(btn, 8)
        gradient(btn, gradientA, gradientB, 45)
        btn.MouseButton1Click:Connect(onClick)
    end

    makePresetBtn("Max FPS", Color3.fromRGB(255,80,100), Color3.fromRGB(150,90,255),
        function() setPreset("MaxFPS") end)
    makePresetBtn("Balanced", Color3.fromRGB(150,90,255), Color3.fromRGB(80,200,255),
        function() setPreset("Balanced") end)
    makePresetBtn("Visual", Color3.fromRGB(80,200,255), Color3.fromRGB(60,220,130),
        function() setPreset("Visual") end)

    -- Quick Actions
    local actionsRow = new("Frame", {
        Size = UDim2.new(1, 0, 0, 76),
        BackgroundColor3 = Theme.bg2,
        BorderSizePixel = 0,
        Parent = dash,
    })
    corner(actionsRow, 10); stroke(actionsRow, Theme.stroke, 1, 0.6)
    new("TextLabel", {
        Size = UDim2.new(1, -20, 0, 22),
        Position = UDim2.new(0, 12, 0, 8),
        BackgroundTransparency = 1,
        Text = "Quick Actions",
        TextColor3 = Theme.textDim,
        Font = Enum.Font.GothamMedium,
        TextSize = 11,
        TextXAlignment = Enum.TextXAlignment.Left,
        Parent = actionsRow,
    })
    local actionBtnRow = new("Frame", {
        Size = UDim2.new(1, -20, 0, 34),
        Position = UDim2.new(0, 10, 0, 34),
        BackgroundTransparency = 1,
        Parent = actionsRow,
    })
    new("UIListLayout", {
        FillDirection = Enum.FillDirection.Horizontal,
        Padding = UDim.new(0, 8),
        Parent = actionBtnRow,
    })

    local function makeActionBtn(label, color, onClick)
        local btn = new("TextButton", {
            Size = UDim2.new(0.25, -6, 1, 0),
            BackgroundColor3 = Theme.bg3,
            Text = label,
            TextColor3 = Theme.text,
            Font = Enum.Font.GothamMedium,
            TextSize = 11,
            AutoButtonColor = false,
            Parent = actionBtnRow,
        })
        corner(btn, 8); stroke(btn, color, 1, 0.5)
        btn.MouseButton1Click:Connect(onClick)
    end

    makeActionBtn("Clean RAM", Theme.accentB, function()
        cleanRAM("manual")
        notify("RAM", ("Cleaned - freed %d MB"):format(lastFreed), "success")
    end)
    makeActionBtn("Reapply", Theme.accentA, function()
        reapply("manual")
        notify("Reapply", "Stripping reapplied", "success")
    end)
    makeActionBtn("Black", Theme.textDim, function()
        blackScreenOn = not blackScreenOn
        if UI.blackFrame then UI.blackFrame.Visible = blackScreenOn end
        notify("Black Screen", blackScreenOn and "ON" or "OFF", "info")
    end)
    makeActionBtn("Mute", Theme.warning, function()
        MUTE_ON = not MUTE_ON
        if MUTE_ON then muteAllSounds("manual-on") else setMasterVolume(0.5) end
        notify("Sound", MUTE_ON and "Muted" or "Unmuted", "info")
    end)

    -- Status box
    local statusBox = new("Frame", {
        Size = UDim2.new(1, 0, 0, 200),
        BackgroundColor3 = Theme.bg2,
        BorderSizePixel = 0,
        Parent = dash,
    })
    corner(statusBox, 10); stroke(statusBox, Theme.stroke, 1, 0.6)
    UI.statusLabel = new("TextLabel", {
        Size = UDim2.new(1, -24, 1, -16),
        Position = UDim2.new(0, 12, 0, 8),
        BackgroundTransparency = 1,
        Text = "Booting...",
        TextColor3 = Theme.text,
        Font = Enum.Font.Code,
        TextSize = 12,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Top,
        TextWrapped = true,
        Parent = statusBox,
    })

    -- ============================================
    -- SETTINGS
    -- ============================================
    local settings = new("ScrollingFrame", {
        Size = UDim2.new(1, 0, 1, 0),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        ScrollBarThickness = 4,
        ScrollBarImageColor3 = Theme.accentA,
        AutomaticCanvasSize = Enum.AutomaticSize.Y,
        CanvasSize = UDim2.new(0, 0, 0, 0),
        Visible = false,
        Parent = pageContainer,
    })
    new("UIListLayout", {
        Padding = UDim.new(0, 8),
        SortOrder = Enum.SortOrder.LayoutOrder,
        Parent = settings,
    })
    padding(settings, 0, 6, 0, 0)
    pageFrames.Settings = settings

    local function sectionHeader(title)
        new("TextLabel", {
            Size = UDim2.new(1, 0, 0, 22),
            BackgroundTransparency = 1,
            Text = title,
            TextColor3 = Theme.accentB,
            Font = Enum.Font.GothamBold,
            TextSize = 11,
            TextXAlignment = Enum.TextXAlignment.Left,
            Parent = settings,
        })
    end

    local function toggleRow(key, label)
        makeToggle(settings, label,
            function() return CFG[key] end,
            function(v)
                CFG[key] = v
                PERSIST.toggles = PERSIST.toggles or {}
                PERSIST.toggles[key] = v
                saveState(PERSIST)
                if key == "MUTE_ALL_SOUNDS" then
                    MUTE_ON = v
                    if MUTE_ON then muteAllSounds("toggle-on") else setMasterVolume(0.5) end
                elseif key == "BLACK_SCREEN" then
                    blackScreenOn = v
                    if UI.blackFrame then UI.blackFrame.Visible = v end
                elseif key == "ANTI_AFK" then
                    antiAfkOn = v
                end
            end)
    end

    sectionHeader("Visual Stripping")
    toggleRow("STRIP_TEXTURES", "Strip textures & decals")
    toggleRow("FLATTEN_MAT", "Flatten materials")
    toggleRow("DISABLE_SHADOWS", "Disable shadows")
    toggleRow("KILL_POSTFX", "Kill post-processing / atmosphere")
    toggleRow("KILL_PARTICLES", "Kill particles / beams / trails")
    toggleRow("DROP_QUALITY", "Force quality level 1")
    toggleRow("LOW_MESH", "Low mesh detail")

    sectionHeader("Performance")
    toggleRow("KILL_VIEWPORTS", "Destroy viewport frames")
    toggleRow("KILL_HUMANOID", "Disable Animator / Humanoid state")
    toggleRow("CULLING", "Distance culling")
    toggleRow("REAPPLY_ON_SPAWN", "Reapply on respawn")

    sectionHeader("Anti-Kick")
    toggleRow("ANTI_AFK", "Anti-AFK (prevents Roblox idle kick)")

    sectionHeader("Audio")
    toggleRow("MUTE_ALL_SOUNDS", "Mute all sounds")

    sectionHeader("Sliders")
    makeSlider(settings, "Active FPS cap", 1, 60,
        function() return CFG.ACTIVE_FPS end,
        function(v) CFG.ACTIVE_FPS = v; if ENABLED and not AFK_ACTIVE then setCap(v) end end)
    makeSlider(settings, "AFK FPS cap", 1, 30,
        function() return CFG.AFK_FPS end,
        function(v) CFG.AFK_FPS = v end)
    makeSlider(settings, "AFK timeout (s)", 3, 120,
        function() return CFG.AFK_TIME end,
        function(v) CFG.AFK_TIME = v end)
    makeSlider(settings, "Cull distance (studs)", 50, 1000,
        function() return CFG.CULL_DISTANCE end,
        function(v) CFG.CULL_DISTANCE = v end)
    makeSlider(settings, "RAM clean interval (s)", 15, 600,
        function() return CFG.RAM_CLEAN_INTERVAL end,
        function(v) CFG.RAM_CLEAN_INTERVAL = v end)
    makeSlider(settings, "Reapply interval (s)", 60, 900,
        function() return CFG.REAPPLY_INTERVAL end,
        function(v) CFG.REAPPLY_INTERVAL = v end)
    makeSlider(settings, "Anti-AFK interval (s)", 15, 300,
        function() return CFG.ANTI_AFK_INTERVAL end,
        function(v) CFG.ANTI_AFK_INTERVAL = v end)

    -- ============================================
    -- DIAGNOSTICS
    -- ============================================
    local diag = new("ScrollingFrame", {
        Size = UDim2.new(1, 0, 1, 0),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        ScrollBarThickness = 4,
        ScrollBarImageColor3 = Theme.accentA,
        AutomaticCanvasSize = Enum.AutomaticSize.Y,
        CanvasSize = UDim2.new(0, 0, 0, 0),
        Visible = false,
        Parent = pageContainer,
    })
    new("UIListLayout", {
        Padding = UDim.new(0, 10),
        SortOrder = Enum.SortOrder.LayoutOrder,
        Parent = diag,
    })
    padding(diag, 0, 6, 0, 0)
    pageFrames.Diagnostics = diag

    local instBox = new("Frame", {
        Size = UDim2.new(1, 0, 0, 132),
        BackgroundColor3 = Theme.bg2,
        BorderSizePixel = 0,
        Parent = diag,
    })
    corner(instBox, 10); stroke(instBox, Theme.stroke, 1, 0.6)
    new("TextLabel", {
        Size = UDim2.new(1, -20, 0, 22),
        Position = UDim2.new(0, 12, 0, 8),
        BackgroundTransparency = 1,
        Text = "Instance Counts",
        TextColor3 = Theme.textDim,
        Font = Enum.Font.GothamMedium,
        TextSize = 11,
        TextXAlignment = Enum.TextXAlignment.Left,
        Parent = instBox,
    })
    UI.instGrid = new("Frame", {
        Size = UDim2.new(1, -20, 1, -40),
        Position = UDim2.new(0, 10, 0, 34),
        BackgroundTransparency = 1,
        Parent = instBox,
    })
    new("UIGridLayout", {
        CellSize = UDim2.new(1/3, -6, 0, 32),
        CellPadding = UDim2.new(0, 6, 0, 6),
        Parent = UI.instGrid,
    })
    UI.instLabels = {}
    for _, name in ipairs({ "parts", "sounds", "decals", "particles", "viewports", "guis" }) do
        local lbl = new("TextLabel", {
            BackgroundColor3 = Theme.bg3,
            Text = name .. ": 0",
            TextColor3 = Theme.text,
            Font = Enum.Font.Code,
            TextSize = 11,
            Parent = UI.instGrid,
        })
        corner(lbl, 6)
        UI.instLabels[name] = lbl
    end

    -- Benchmark
    local benchBox = new("Frame", {
        Size = UDim2.new(1, 0, 0, 150),
        BackgroundColor3 = Theme.bg2,
        BorderSizePixel = 0,
        Parent = diag,
    })
    corner(benchBox, 10); stroke(benchBox, Theme.stroke, 1, 0.6)
    new("TextLabel", {
        Size = UDim2.new(1, -20, 0, 22),
        Position = UDim2.new(0, 12, 0, 8),
        BackgroundTransparency = 1,
        Text = "Benchmark (10s on / 10s off)",
        TextColor3 = Theme.textDim,
        Font = Enum.Font.GothamMedium,
        TextSize = 11,
        TextXAlignment = Enum.TextXAlignment.Left,
        Parent = benchBox,
    })

    local benchInitial = "No benchmark yet."
    if PERSIST.benchmark then
        local bo = PERSIST.benchmark.off or 0
        local bn = PERSIST.benchmark.on or 0
        benchInitial = string.format("Last: baseline %d FPS -> boosted %d FPS (+%d)", bo, bn, bn - bo)
    end

    UI.benchLabel = new("TextLabel", {
        Size = UDim2.new(1, -20, 1, -80),
        Position = UDim2.new(0, 12, 0, 34),
        BackgroundTransparency = 1,
        Text = benchInitial,
        TextColor3 = Theme.text,
        Font = Enum.Font.Code,
        TextSize = 11,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Top,
        TextWrapped = true,
        Parent = benchBox,
    })

    local benchBtn = new("TextButton", {
        Size = UDim2.new(1, -20, 0, 34),
        Position = UDim2.new(0, 10, 1, -42),
        BackgroundColor3 = Theme.accentA,
        Text = "Run Benchmark",
        TextColor3 = Color3.new(1, 1, 1),
        Font = Enum.Font.GothamBold,
        TextSize = 12,
        AutoButtonColor = false,
        Parent = benchBox,
    })
    corner(benchBtn, 8)
    gradient(benchBtn, Theme.accentA, Theme.accentB, 45)

    local benchmarking = false
    benchBtn.MouseButton1Click:Connect(function()
        if benchmarking then return end
        benchmarking = true
        notify("Benchmark", "Measuring baseline (10s)...", "info")

        local snapshot = {}
        for k, v in pairs(CFG) do
            if type(v) == "boolean" then snapshot[k] = v end
        end

        for k in pairs(snapshot) do
            if k:match("^STRIP_") or k:match("^KILL_") or k:match("^FLATTEN_")
                or k == "DROP_QUALITY" or k == "LOW_MESH" or k == "DISABLE_SHADOWS"
                or k == "MUTE_ALL_SOUNDS" or k == "CULLING" then
                CFG[k] = false
            end
        end

        local f0, t0 = 0, tick()
        local connOff = RunService.RenderStepped:Connect(function() f0 = f0 + 1 end)
        task.wait(10)
        connOff:Disconnect()
        local offFPS = math.floor(f0 / (tick() - t0))

        notify("Benchmark", "Measuring boosted (10s)...", "info")

        for k, v in pairs(snapshot) do CFG[k] = v end

        local f1, t1 = 0, tick()
        local connOn = RunService.RenderStepped:Connect(function() f1 = f1 + 1 end)
        task.wait(10)
        connOn:Disconnect()
        local onFPS = math.floor(f1 / (tick() - t1))

        PERSIST.benchmark = { on = onFPS, off = offFPS, at = tick() }
        saveState(PERSIST)

        UI.benchLabel.Text = string.format(
            "Last: baseline %d FPS -> boosted %d FPS (+%d)",
            offFPS, onFPS, onFPS - offFPS)
        notify("Benchmark",
            ("Baseline %d -> Boosted %d FPS"):format(offFPS, onFPS),
            onFPS > offFPS and "success" or "warn")
        benchmarking = false

        reapply("benchmark-restore")
    end)

    -- Broken games
    local brokenBox = new("Frame", {
        Size = UDim2.new(1, 0, 0, 130),
        BackgroundColor3 = Theme.bg2,
        BorderSizePixel = 0,
        Parent = diag,
    })
    corner(brokenBox, 10); stroke(brokenBox, Theme.stroke, 1, 0.6)
    new("TextLabel", {
        Size = UDim2.new(1, -20, 0, 22),
        Position = UDim2.new(0, 12, 0, 8),
        BackgroundTransparency = 1,
        Text = "Broken Games (auto-learned)",
        TextColor3 = Theme.textDim,
        Font = Enum.Font.GothamMedium,
        TextSize = 11,
        TextXAlignment = Enum.TextXAlignment.Left,
        Parent = brokenBox,
    })
    UI.brokenLabel = new("TextLabel", {
        Size = UDim2.new(1, -20, 1, -56),
        Position = UDim2.new(0, 12, 0, 34),
        BackgroundTransparency = 1,
        Text = "None",
        TextColor3 = Theme.text,
        Font = Enum.Font.Code,
        TextSize = 11,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Top,
        TextWrapped = true,
        Parent = brokenBox,
    })
    local clearBroken = new("TextButton", {
        Size = UDim2.new(1, -20, 0, 28),
        Position = UDim2.new(0, 10, 1, -36),
        BackgroundColor3 = Theme.bg3,
        Text = "Clear Broken Games List",
        TextColor3 = Theme.text,
        Font = Enum.Font.GothamMedium,
        TextSize = 11,
        AutoButtonColor = false,
        Parent = brokenBox,
    })
    corner(clearBroken, 6); stroke(clearBroken, Theme.warning, 1, 0.5)
    clearBroken.MouseButton1Click:Connect(function()
        PERSIST.brokenGames = {}
        saveState(PERSIST)
        CURRENT_PLACE_BROKEN = false
        notify("Broken Games", "List cleared", "success")
    end)

    -- Anti-AFK stats
    local afkBox = new("Frame", {
        Size = UDim2.new(1, 0, 0, 90),
        BackgroundColor3 = Theme.bg2,
        BorderSizePixel = 0,
        Parent = diag,
    })
    corner(afkBox, 10); stroke(afkBox, Theme.stroke, 1, 0.6)
    new("TextLabel", {
        Size = UDim2.new(1, -20, 0, 22),
        Position = UDim2.new(0, 12, 0, 8),
        BackgroundTransparency = 1,
        Text = "Anti-AFK",
        TextColor3 = Theme.textDim,
        Font = Enum.Font.GothamMedium,
        TextSize = 11,
        TextXAlignment = Enum.TextXAlignment.Left,
        Parent = afkBox,
    })
    UI.afkLabel = new("TextLabel", {
        Size = UDim2.new(1, -20, 1, -34),
        Position = UDim2.new(0, 12, 0, 34),
        BackgroundTransparency = 1,
        Text = "Simulations fired: 0",
        TextColor3 = Theme.text,
        Font = Enum.Font.Code,
        TextSize = 12,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Top,
        TextWrapped = true,
        Parent = afkBox,
    })

    setTab("Dashboard")
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
        return string.format("Track  : %s  [SAME SERVER]", track.displayName)
    end
    if not track.online and track.lastError then
        return string.format("Track  : %s  [%s]", CFG.TRACK_USERNAME, track.lastError)
    end
    if track.inGame then
        return string.format("Track  : %s  [IN GAME]", track.displayName)
    end
    if track.inStudio then
        return string.format("Track  : %s  [STUDIO]", track.displayName)
    end
    if track.online then
        return string.format("Track  : %s  [ONLINE]", track.displayName)
    end
    return string.format("Track  : %s  [OFFLINE]", track.displayName)
end

local function trackerGameLine()
    if track.sameServer then
        return string.format("Game   : %s  (you're here)", track.gameName or "this game")
    end
    if track.inGame then
        if track.gameName and track.gameName ~= "" then
            return string.format("Game   : %s", track.gameName)
        end
        if track.placeId then return string.format("Game   : (placeId %d)", track.placeId) end
        return "Game   : (hidden)"
    end
    return "Game   : -"
end

local function trackerJobLine()
    local jid = shortJobId(track.jobId)
    if track.sameServer then return string.format("Server : %s  [this server]", jid) end
    if track.inGame and track.jobId and track.jobId ~= "" then
        return string.format("Server : %s", jid)
    end
    return "Server : -"
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
    if track.lastUpdate == 0 then return "Next   : checking..." end
    local remaining = math.max(0, (track.lastUpdate + CFG.TRACK_POLL_INTERVAL) - tick())
    return string.format("Next   : %ds", math.floor(remaining))
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
            pushHistory(fpsHistory, currentFPS)
            pushHistory(ramHistory, ram)
            pushHistory(pingHistory, ping)

            if UI.fpsSpark then UI.fpsSpark.setValue(currentFPS) end
            if UI.ramSpark then UI.ramSpark.setValue(ram) end
            if UI.pingSpark then UI.pingSpark.setValue(ping) end

            if UI.statusLabel then
                local uptime = formatUptime(tick() - START_TIME)
                local state = "ON"
                if AFK_ACTIVE then state = "AFK"
                elseif not ENABLED then state = "OFF"
                end
                local mut = MUTE_ON and "ON" or "OFF"
                local bs = blackScreenOn and "ON" or "OFF"
                local anti = antiAfkOn and "ON" or "OFF"
                local sep = "----------------------------------------------"
                UI.statusLabel.Text = table.concat({
                    ("Uptime : %s     FPS: %d [%s]     Ping: %d ms"):format(uptime, currentFPS, state, ping),
                    ("RAM    : %d MB   Mute: %s   Black: %s"):format(ram, mut, bs),
                    ("AntiAFK: %s  (fired %d)   Broken place: %s"):format(
                        anti, antiAfkCount, CURRENT_PLACE_BROKEN and "YES" or "no"),
                    sep,
                    trackerStatusLine(),
                    trackerGameLine(),
                    trackerJobLine(),
                    autoJoinLine(),
                    attemptCounterLine(),
                    trackerNextCheckLine(),
                }, "\n")
            end
        end
    end)

    task.spawn(function()
        while true do
            task.wait(5)
            pcall(function()
                refreshCounts()
                if UI.instLabels then
                    for name, lbl in pairs(UI.instLabels) do
                        lbl.Text = name .. ": " .. tostring(counts[name] or 0)
                    end
                end
                if UI.brokenLabel then
                    local list = {}
                    for pid, info in pairs(PERSIST.brokenGames) do
                        table.insert(list, ("  %s (%s)"):format(pid, info.reason or "?"))
                    end
                    UI.brokenLabel.Text = #list > 0 and table.concat(list, "\n") or "None"
                end
                if UI.afkLabel then
                    UI.afkLabel.Text = string.format(
                        "Status: %s\nSimulations fired: %d",
                        antiAfkOn and "ACTIVE" or "OFF", antiAfkCount)
                end
            end)
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
--  ACTIVITY / AFK (this is the FPS-lowering AFK, separate from anti-AFK)
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
setupAntiAFK()       -- ★ start anti-AFK before anything else
setupAFK()
setupSpawnAndDirty()
hookSoundService()
startCulling()
setupLoops()

-- Force black screen fully on at boot and re-assert its visibility
blackScreenOn = true
if UI.blackFrame then UI.blackFrame.Visible = true end

reapply("boot")
setCap(CFG.ACTIVE_FPS)

task.delay(5, function() queueSelf(false) end)

task.defer(function()
    task.wait(2)
    notify("FPS Booster v26", "Premium edition loaded", "success")
    if CURRENT_PLACE_BROKEN then
        notify("Warning", "This place is marked broken - stripping skipped", "warn")
    end
    print("[FPS Booster v26 Premium] Ready.")
    print("  Black screen:", blackScreenOn)
    print("  Anti-AFK:", antiAfkOn)
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
_G.__FPS_BOOSTER_V26.reapply   = reapply
_G.__FPS_BOOSTER_V26.cleanRAM  = cleanRAM
_G.__FPS_BOOSTER_V26.muteAll   = muteAllSounds
_G.__FPS_BOOSTER_V26.track     = track
_G.__FPS_BOOSTER_V26.refresh   = refreshTrack
_G.__FPS_BOOSTER_V26.autoJoin  = tryAutoJoin
_G.__FPS_BOOSTER_V26.queueSelf = queueSelf
_G.__FPS_BOOSTER_V26.cfg       = CFG
_G.__FPS_BOOSTER_V26.ui        = UI
_G.__FPS_BOOSTER_V26.notify    = notify
_G.__FPS_BOOSTER_V26.blackOff  = function()
    blackScreenOn = false
    if UI.blackFrame then UI.blackFrame.Visible = false end
end
_G.__FPS_BOOSTER_V26.blackOn   = function()
    blackScreenOn = true
    if UI.blackFrame then UI.blackFrame.Visible = true end
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
