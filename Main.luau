--[[
    PURPLETEST
    Single-file Roblox ESP / Aimbot / Anti-Cheat Test Hub
    Executor environment
]]

if not Drawing then
    warn("[PurpleTest] Drawing API unavailable.")
    return
end

local Players          = game:GetService("Players")
local RunService       = game:GetService("RunService")
local Workspace        = game:GetService("Workspace")
local UserInputService = game:GetService("UserInputService")
local GuiService       = game:GetService("GuiService")

local LocalPlayer = Players.LocalPlayer
local Camera      = Workspace.CurrentCamera

local ENV = (getgenv and getgenv()) or _G

if ENV.PurpleTestCleanup then
    pcall(ENV.PurpleTestCleanup)
end

local IS_TOUCH = UserInputService.TouchEnabled

local Config = {
    ESP = true,
    Boxes = true,
    Names = true,
    Health = true,
    Distance = true,
    Tracers = false,
    TeamCheck = false,
    MaxDistance = 1500,
    Accent = Color3.fromRGB(139, 92, 246),

    -- Aimbot
    Aimbot     = true,
    AimKey     = Enum.UserInputType.MouseButton2,
    AimFOV     = IS_TOUCH and 160 or 120,
    AimSmooth  = 4,
    AimMaxDist = 800,
    AimPart    = "Head",
    AimVisible = true,
    AimTeamChk = false,
    FOVColor   = Color3.fromRGB(139, 92, 246),
}

local Objects     = {}
local Connections = {}
local Alive       = true
local AimActive   = false

-- -------- shared params (reused; avoids per-frame allocation) -----------
local RayParams = RaycastParams.new()
RayParams.FilterType  = Enum.RaycastFilterType.Exclude
RayParams.IgnoreWater = true
RayParams.FilterDescendantsInstances = {}

local _rayFilter = {}          -- reused list for filter instances

local function GetInset()
    return GuiService:GetGuiInset()   -- Vector2 TopLeft
end

-- -------- drawing helpers (idempotent; never throw) ---------------------
local function NewDrawing(class, props)
    local obj = Drawing.new(class)
    if props then
        for k, v in pairs(props) do obj[k] = v end
    end
    return obj
end

local function SafeRemove(obj)
    if not obj then return end
    pcall(function() obj.Visible = false end)
    pcall(function() obj:Remove() end)
end

local function Hide(data)
    for _, obj in pairs(data) do
        pcall(function() obj.Visible = false end)
    end
end

-- -------- FOV circle ----------------------------------------------------
local FovCircle = NewDrawing("Circle", {
    Thickness = IS_TOUCH and 2 or 1,
    NumSides  = 64,
    Radius    = Config.AimFOV,
    Filled    = false,
    Color     = Config.FOVColor,
    Visible   = false,
})

-- -------- ESP -----------------------------------------------------------
local function CreateESP(player)
    if player == LocalPlayer then return end
    if Objects[player] then return end
    Objects[player] = {
        Box = NewDrawing("Square", {
            Thickness = 1.5, Color = Config.Accent, Filled = false, Visible = false,
        }),
        Name = NewDrawing("Text", {
            Size = 14, Center = true, Outline = true,
            Color = Color3.new(1, 1, 1), Visible = false,
        }),
        Health = NewDrawing("Line", {
            Thickness = 3, Color = Color3.fromRGB(70, 220, 120), Visible = false,
        }),
        Distance = NewDrawing("Text", {
            Size = 13, Center = true, Outline = true,
            Color = Color3.fromRGB(210, 210, 210), Visible = false,
        }),
        Tracer = NewDrawing("Line", {
            Thickness = 1, Color = Config.Accent, Visible = false,
        }),
    }
end

local function RemoveESP(player)
    local data = Objects[player]
    if not data then return end
    for _, obj in pairs(data) do SafeRemove(obj) end
    Objects[player] = nil
end

local function UpdateESP(player, data)
    if not Config.ESP then Hide(data); return end

    local character = player.Character
    if not character then Hide(data); return end
    local humanoid = character:FindFirstChildOfClass("Humanoid")
    local root     = character:FindFirstChild("HumanoidRootPart")
    if not humanoid or not root or humanoid.Health <= 0 then Hide(data); return end

    if Config.TeamCheck and player.Team == LocalPlayer.Team then Hide(data); return end

    local distance = (root.Position - Camera.CFrame.Position).Magnitude
    if distance > Config.MaxDistance then Hide(data); return end

    local head = character:FindFirstChild("Head")
    local top  = head and (head.Position + Vector3.new(0, 0.5, 0))
                       or (root.Position + Vector3.new(0, 3, 0))
    local bottom = root.Position - Vector3.new(0, 3, 0)

    local topPos, topOn = Camera:WorldToViewportPoint(top)
    local botPos, botOn = Camera:WorldToViewportPoint(bottom)
    if not topOn or not botOn then Hide(data); return end

    local height = math.abs(botPos.Y - topPos.Y)
    local width  = height * 0.55
    local x      = topPos.X - width / 2
    local y      = topPos.Y

    data.Box.Size     = Vector2.new(width, height)
    data.Box.Position = Vector2.new(x, y)
    data.Box.Color    = Config.Accent
    data.Box.Visible  = Config.Boxes

    data.Name.Text     = player.Name
    data.Name.Position = Vector2.new(topPos.X, y - 17)
    data.Name.Visible  = Config.Names

    local hp = math.clamp(humanoid.Health / math.max(humanoid.MaxHealth, 1), 0, 1)
    data.Health.From  = Vector2.new(x - 5, botPos.Y)
    data.Health.To    = Vector2.new(x - 5, botPos.Y - height * hp)
    data.Health.Color = Color3.fromRGB(255 * (1 - hp), 255 * hp, 70)
    data.Health.Visible = Config.Health

    data.Distance.Text     = string.format("%d studs", distance)
    data.Distance.Position = Vector2.new(botPos.X, botPos.Y + 3)
    data.Distance.Visible  = Config.Distance

    data.Tracer.From    = Vector2.new(Camera.ViewportSize.X / 2, Camera.ViewportSize.Y)
    data.Tracer.To      = Vector2.new(botPos.X, botPos.Y)
    data.Tracer.Visible = Config.Tracers
end

-- -------- aimbot --------------------------------------------------------
local HAS_MOUSEMOVEREL = type(mousemoverel) == "function"
local HAS_MOUSEMOVEABS = type(mousemoveabs) == "function"

if Config.Aimbot and not HAS_MOUSEMOVEREL and not HAS_MOUSEMOVEABS then
    warn("[PurpleTest] No mouse-move API available; aimbot cannot move cursor.")
end

local function ApplyAim(dx, dy, absX, absY)
    if HAS_MOUSEMOVEREL then
        pcall(mousemoverel, dx, dy)
    elseif HAS_MOUSEMOVEABS then
        pcall(mousemoveabs, absX, absY)
    end
end

local function FindTarget()
    local vpSize   = Camera.ViewportSize
    local center   = vpSize / 2
    local camPos   = Camera.CFrame.Position
    local localChar = LocalPlayer.Character
    local best, bestScore, bestVP = nil, math.huge, nil

    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer then
            local char = player.Character
            if char then
                local hum = char:FindFirstChildOfClass("Humanoid")
                if hum and hum.Health > 0 then
                    local skip = Config.AimTeamChk and (player.Team == LocalPlayer.Team)
                    if not skip then
                        local aimPart = char:FindFirstChild(Config.AimPart)
                                       or char:FindFirstChild("Head")
                        if aimPart then
                            local worldPos = aimPart.Position
                            local wdist    = (camPos - worldPos).Magnitude
                            if wdist <= Config.AimMaxDist then
                                local sp, onScreen = Camera:WorldToViewportPoint(worldPos)
                                if onScreen and sp.Z > 0 then
                                    local s2    = Vector2.new(sp.X, sp.Y)
                                    local sdist = (s2 - center).Magnitude
                                    if sdist <= Config.AimFOV and sdist < bestScore then
                                        local visible = true
                                        if Config.AimVisible then
                                            _rayFilter[1] = char
                                            _rayFilter[2] = localChar
                                            RayParams.FilterDescendantsInstances = _rayFilter
                                            local hit = Workspace:Raycast(camPos, worldPos - camPos, RayParams)
                                            visible = (hit == nil) or hit.Instance:IsDescendantOf(char)
                                        end
                                        if visible then
                                            bestScore = sdist
                                            best      = aimPart
                                            bestVP    = s2
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    return best, bestVP
end

local function AimStep()
    if not Alive or not Config.Aimbot or not AimActive then return end
    if not HAS_MOUSEMOVEREL and not HAS_MOUSEMOVEABS then return end

    local _, targetVP = FindTarget()
    if not targetVP then return end

    local inset = GetInset()
    local mouseVP = UserInputService:GetMouseLocation() - inset
    local delta = targetVP - mouseVP

    local smooth = math.max(1, Config.AimSmooth)
    local mv = delta / smooth
    if math.abs(mv.X) < 1 and math.abs(mv.Y) < 1 then return end

    -- absolute screen coords for mousemoveabs path
    local absX = targetVP.X + inset.X
    local absY = targetVP.Y + inset.Y

    ApplyAim(math.floor(mv.X), math.floor(mv.Y),
             math.floor(absX), math.floor(absY))
end

-- -------- player setup --------------------------------------------------
for _, player in ipairs(Players:GetPlayers()) do
    CreateESP(player)
end

Connections[#Connections + 1] = Players.PlayerAdded:Connect(CreateESP)
Connections[#Connections + 1] = Players.PlayerRemoving:Connect(RemoveESP)

-- -------- render loop ---------------------------------------------------
Connections[#Connections + 1] = RunService.RenderStepped:Connect(function()
    if not Alive then return end
    Camera = Workspace.CurrentCamera
    if not Camera then return end

    for player, data in pairs(Objects) do
        pcall(UpdateESP, player, data)
    end

    if Config.Aimbot then
        FovCircle.Visible   = true
        FovCircle.Position  = Camera.ViewportSize / 2
        FovCircle.Radius    = Config.AimFOV
        FovCircle.Color     = Config.FOVColor
        FovCircle.Thickness = IS_TOUCH and 2 or 1
    else
        FovCircle.Visible = false
    end

    pcall(AimStep)
end)

-- -------- input (pc) ----------------------------------------------------
if not IS_TOUCH then
    Connections[#Connections + 1] = UserInputService.InputBegan:Connect(function(input, gpe)
        if gpe then return end
        if input.UserInputType == Config.AimKey then AimActive = true end
        if input.KeyCode == Enum.KeyCode.F1 then Config.ESP = not Config.ESP end
        if input.KeyCode == Enum.KeyCode.F2 then Config.Aimbot = not Config.Aimbot end
        if input.KeyCode == Enum.KeyCode.Equals then Config.AimFOV = math.min(500, Config.AimFOV + 10) end
        if input.KeyCode == Enum.KeyCode.Minus then Config.AimFOV = math.max(20, Config.AimFOV - 10) end
    end)
    Connections[#Connections + 1] = UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Config.AimKey then AimActive = false end
    end)
end

-- -------- UI ------------------------------------------------------------
local gui = Instance.new("ScreenGui")
gui.Name = "PurpleTest"
gui.ResetOnSpawn = false
gui.Parent = game:GetService("CoreGui")

local vpSize = Camera.ViewportSize
local frameH = math.clamp(vpSize.Y * 0.85, 320, 540)

local frame = Instance.new("Frame")
frame.Size = UDim2.fromOffset(240, frameH)
frame.Position = UDim2.new(0, 30, 0.15, 0)
frame.BackgroundColor3 = Color3.fromRGB(13, 9, 20)
frame.BorderSizePixel = 0
frame.Active = true
frame.Parent = gui

Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 10)

local stroke = Instance.new("UIStroke")
stroke.Color = Config.Accent
stroke.Transparency = 0.35
stroke.Parent = frame

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, 0, 0, 42)
title.BackgroundTransparency = 1
title.Text = "PURPLETEST"
title.TextColor3 = Config.Accent
title.Font = Enum.Font.GothamBold
title.TextSize = 17
title.Parent = frame

-- drag handle (transparent button over the title bar; reliable on pc + touch)
local dragHandle = Instance.new("TextButton")
dragHandle.Size = UDim2.new(1, 0, 0, 42)
dragHandle.Position = UDim2.fromOffset(0, 0)
dragHandle.BackgroundTransparency = 1
dragHandle.Text = ""
dragHandle.Parent = frame

local dragging, dragStart, startPos

dragHandle.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1
    or input.UserInputType == Enum.UserInputType.Touch then
        dragging  = true
        dragStart = input.Position
        startPos  = frame.Position
    end
end)

Connections[#Connections + 1] = UserInputService.InputChanged:Connect(function(input)
    if not dragging then return end
    if input.UserInputType == Enum.UserInputType.MouseMovement
    or input.UserInputType == Enum.UserInputType.Touch then
        local d = input.Position - dragStart
        frame.Position = UDim2.new(
            startPos.X.Scale, startPos.X.Offset + d.X,
            startPos.Y.Scale, startPos.Y.Offset + d.Y
        )
    end
end)

Connections[#Connections + 1] = UserInputService.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1
    or input.UserInputType == Enum.UserInputType.Touch then
        dragging = false
    end
end)

-- scrolling list
local scroll = Instance.new("ScrollingFrame")
scroll.Size = UDim2.new(1, -20, 1, -96)
scroll.Position = UDim2.fromOffset(10, 48)
scroll.BackgroundTransparency = 1
scroll.BorderSizePixel = 0
scroll.ScrollBarThickness = 4
scroll.ScrollBarImageColor3 = Config.Accent
scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
scroll.ScrollingDirection = Enum.ScrollingDirection.Y
scroll.Parent = frame

local y    = 0
local step = 35

local function AddToggle(label, key)
    local button = Instance.new("TextButton")
    button.Size = UDim2.new(1, -4, 0, 32)
    button.Position = UDim2.fromOffset(0, y)
    button.BackgroundColor3 = Color3.fromRGB(26, 19, 38)
    button.TextColor3 = Color3.new(1, 1, 1)
    button.Font = Enum.Font.Gotham
    button.TextSize = 13
    button.TextXAlignment = Enum.TextXAlignment.Left
    button.Parent = scroll
    Instance.new("UICorner", button).CornerRadius = UDim.new(0, 6)

    local pad = Instance.new("UIPadding")
    pad.PaddingLeft = UDim.new(0, 8)
    pad.Parent = button

    local function Refresh()
        button.Text = label .. ": " .. (Config[key] and "ON" or "OFF")
        button.TextColor3 = Config[key] and Config.Accent or Color3.fromRGB(180, 180, 180)
    end
    Refresh()

    button.MouseButton1Click:Connect(function()
        Config[key] = not Config[key]
        Refresh()
    end)

    y = y + step
end

local function AddRow(labelText, key, minV, maxV, stepV)
    local lbl = Instance.new("TextLabel")
    lbl.Size = UDim2.fromOffset(90, 30)
    lbl.Position = UDim2.fromOffset(0, y)
    lbl.BackgroundTransparency = 1
    lbl.Text = labelText
    lbl.TextColor3 = Color3.fromRGB(200, 200, 200)
    lbl.Font = Enum.Font.Gotham
    lbl.TextSize = 13
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.Parent = scroll

    local minus = Instance.new("TextButton")
    minus.Size = UDim2.fromOffset(28, 28)
    minus.Position = UDim2.fromOffset(100, y + 1)
    minus.BackgroundColor3 = Color3.fromRGB(26, 19, 38)
    minus.TextColor3 = Color3.new(1, 1, 1)
    minus.Text = "-"
    minus.Font = Enum.Font.GothamBold
    minus.TextSize = 14
    minus.Parent = scroll
    Instance.new("UICorner", minus).CornerRadius = UDim.new(0, 6)

    local valueLbl = Instance.new("TextLabel")
    valueLbl.Size = UDim2.fromOffset(44, 30)
    valueLbl.Position = UDim2.fromOffset(134, y)
    valueLbl.BackgroundTransparency = 1
    valueLbl.Text = tostring(Config[key])
    valueLbl.TextColor3 = Config.Accent
    valueLbl.Font = Enum.Font.GothamBold
    valueLbl.TextSize = 13
    valueLbl.Parent = scroll

    local plus = Instance.new("TextButton")
    plus.Size = UDim2.fromOffset(28, 28)
    plus.Position = UDim2.fromOffset(184, y + 1)
    plus.BackgroundColor3 = Color3.fromRGB(26, 19, 38)
    plus.TextColor3 = Color3.new(1, 1, 1)
    plus.Text = "+"
    plus.Font = Enum.Font.GothamBold
    plus.TextSize = 14
    plus.Parent = scroll
    Instance.new("UICorner", plus).CornerRadius = UDim.new(0, 6)

    minus.MouseButton1Click:Connect(function()
        Config[key] = math.max(minV, Config[key] - stepV)
        valueLbl.Text = tostring(Config[key])
    end)
    plus.MouseButton1Click:Connect(function()
        Config[key] = math.min(maxV, Config[key] + stepV)
        valueLbl.Text = tostring(Config[key])
    end)

    y = y + step
end

AddToggle("ESP",        "ESP")
AddToggle("Boxes",      "Boxes")
AddToggle("Names",      "Names")
AddToggle("Health",     "Health")
AddToggle("Distance",   "Distance")
AddToggle("Tracers",    "Tracers")
AddToggle("Team Check", "TeamCheck")
AddToggle("Aimbot",     "Aimbot")
AddToggle("Aim Vis",    "AimVisible")
AddToggle("Aim Team",   "AimTeamChk")
AddRow("FOV",    "AimFOV",    20, 500, 10)
AddRow("Smooth", "AimSmooth", 1,  30,  1)

-- mobile AIM button (hold-to-aim, reliable press/release)
if IS_TOUCH then
    local fireBtn = Instance.new("TextButton")
    fireBtn.Size = UDim2.fromOffset(64, 64)
    fireBtn.Position = UDim2.new(1, -90, 1, -180)
    fireBtn.BackgroundColor3 = Color3.fromRGB(60, 30, 75)
    fireBtn.TextColor3 = Color3.new(1, 1, 1)
    fireBtn.Text = "AIM"
    fireBtn.Font = Enum.Font.GothamBold
    fireBtn.TextSize = 14
    fireBtn.Parent = gui
    Instance.new("UICorner", fireBtn).CornerRadius = UDim.new(1, 0)

    local fireStroke = Instance.new("UIStroke")
    fireStroke.Color = Config.Accent
    fireStroke.Thickness = 2
    fireStroke.Parent = fireBtn

    fireBtn.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
            AimActive = true
            fireBtn.BackgroundColor3 = Config.Accent
        end
    end)
    fireBtn.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
            AimActive = false
            fireBtn.BackgroundColor3 = Color3.fromRGB(60, 30, 75)
        end
    end)
end

-- unload
local unload = Instance.new("TextButton")
unload.Size = UDim2.new(1, -20, 0, 30)
unload.Position = UDim2.new(0, 10, 1, -38)
unload.BackgroundColor3 = Color3.fromRGB(75, 30, 45)
unload.Text = "UNLOAD"
unload.TextColor3 = Color3.new(1, 1, 1)
unload.Font = Enum.Font.GothamBold
unload.TextSize = 12
unload.Parent = frame
Instance.new("UICorner", unload).CornerRadius = UDim.new(0, 6)

-- -------- cleanup -------------------------------------------------------
local function Cleanup()
    if not Alive then return end
    Alive = false

    for _, c in ipairs(Connections) do
        pcall(function() c:Disconnect() end)
    end
    Connections = {}

    for player in pairs(Objects) do
        RemoveESP(player)
    end
    Objects = {}

    SafeRemove(FovCircle)
    pcall(function() gui:Destroy() end)

    if ENV.PurpleTestCleanup == Cleanup then
        ENV.PurpleTestCleanup = nil
    end
end

unload.MouseButton1Click:Connect(Cleanup)

ENV.PurpleTestCleanup = Cleanup

print("[PurpleTest] Loaded successfully.")
