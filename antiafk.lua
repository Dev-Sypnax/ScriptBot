-- Services
local VirtualInputManager = game:GetService("VirtualInputManager")
local RunService = game:GetService("RunService")

-- Config
local KEY = Enum.KeyCode.W
local INTERVAL = 60      -- seconds between presses
local HOLD_TIME = 0.5    -- how long to hold the key (in seconds)

local function pressW()
    -- Press key down
    VirtualInputManager:SendKeyEvent(true, KEY, false, game)
    
    -- Hold for a moment so the character actually moves
    task.wait(HOLD_TIME)
    
    -- Release key
    VirtualInputManager:SendKeyEvent(false, KEY, false, game)
    
    print("[AutoWalk] Pressed W at", os.date("%H:%M:%S"))
end

-- Main loop
task.spawn(function()
    while true do
        pressW()
        task.wait(INTERVAL - HOLD_TIME)
    end
end)
