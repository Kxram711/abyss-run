--!strict
-- RunHudController — LIGHTS OUT client HUD (GDD §7.1 UI/UX, §9 tone brief).
--
-- Renders the in-run surface with engine primitives only (Frame / TextLabel /
-- ImageLabel / UIGradient / UIStroke / UICorner — no marketplace assets):
--
--   CORE THREE
--     1. Lumen meter      shared pool 0–100 bar (center-bottom); low-light
--                         pulse below Config.FlickerThreshold; full-screen
--                         Darkness vignette on DarknessChanged(true).
--     2. Carry slots      5 regular slots + The Bell's special slot, fed by
--                         CarryChanged / Carry property; rarity-colored
--                         artifact-name toast on ArtifactPickedUp.
--     3. Run state        floor indicator + lobby/in-run/extracted/wiped from
--                         RunStateChanged / RunInfo / FloorAdvanced.
--
--   FOLLOW-UPS (same file, later commits)
--     4. Threat cues      red damage flash (ThreatHit), Warden flicker overlay
--                         (WardenGaze flickerSeconds), investigate cue
--                         (EntityStateChanged).
--     5. Loot screen      reward breakdown on extract, minimal wipe screen.
--
-- Tone (GDD §9): dark, desaturated, dread over gore. Panels are near-black
-- with thin steel strokes; the only saturated elements are rarity colors and
-- danger cues. Mobile-first: bottom-center meters clear the thumb zone,
-- top-bar inset is respected (IgnoreGuiInset = false).
--
-- PERFORMANCE: no per-frame allocations. All widgets are built once and
-- mutated in place; text updates happen only on server events (economy ticks
-- ~2/s); the only steady loops are the low-light pulse and Warden flicker,
-- each gated off when inactive.
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Knit = require(ReplicatedStorage.Packages.Knit)

-- ---------------------------------------------------------------------------
-- Style constants (GDD §9 palette: concrete dark, sickly green, teal, amber)
-- ---------------------------------------------------------------------------
local PANEL_BG = Color3.fromRGB(9, 11, 13)
local STROKE = Color3.fromRGB(140, 150, 145)
local TEXT = Color3.fromRGB(205, 210, 205)
local DIM = Color3.fromRGB(128, 134, 128)
local AMBER = Color3.fromRGB(206, 172, 96)
local RED = Color3.fromRGB(192, 62, 50)
local PALE_GREEN = Color3.fromRGB(150, 200, 160)
local LUMEN_TOP = Color3.fromRGB(168, 210, 180)
local LUMEN_BOTTOM = Color3.fromRGB(56, 108, 92)
local BLACK = Color3.fromRGB(0, 0, 0)

-- GDD §4.4 rarity tiers -> HUD accent colors (desaturated, colorblind-safe via
-- glyphs + brightness as well as hue).
local RARITY_COLORS = {
    Common = Color3.fromRGB(148, 152, 156),
    Uncommon = Color3.fromRGB(96, 186, 128),
    Rare = Color3.fromRGB(86, 142, 226),
    Epic = Color3.fromRGB(168, 104, 224),
    Mythic = Color3.fromRGB(228, 160, 62),
}

local FONT_HEAD = Enum.Font.GothamBlack
local FONT_MONO = Enum.Font.RobotoMono
local FONT_BODY = Enum.Font.SourceSans

local function Log(msg: string)
    print("[RunHud]", msg)
end

local function New(className: string, props: { [string]: any }, parent: Instance?): Instance
    local inst = Instance.new(className)
    for key, value in props do
        inst[key] = value
    end
    inst.Parent = parent
    return inst
end

local function Panel(parent: Instance, size: UDim2, pos: UDim2, anchor: Vector2): Frame
    return New("Frame", {
        Size = size,
        Position = pos,
        AnchorPoint = anchor,
        BackgroundColor3 = PANEL_BG,
        BackgroundTransparency = 0.45,
        BorderSizePixel = 0,
    }, parent) :: Frame
end

local function Stroke(target: Instance, color: Color3, transparency: number, thickness: number)
    New("UIStroke", {
        Color = color,
        Transparency = transparency,
        Thickness = thickness,
    }, target)
end

local function Label(parent: Instance, text: string, size: UDim2, pos: UDim2, font: Enum.Font, textSize: number, color: Color3, alignmentX: Enum.TextXAlignment): TextLabel
    return New("TextLabel", {
        Text = text,
        Size = size,
        Position = pos,
        BackgroundTransparency = 1,
        Font = font,
        TextSize = textSize,
        TextColor3 = color,
        TextXAlignment = alignmentX,
        TextYAlignment = Enum.TextYAlignment.Center,
        RichText = false,
    }, parent) :: TextLabel
end

local RunHudController = Knit.CreateController {
    Name = "RunHudController",

    -- Runtime refs / state (declared here to stay --!strict-clean; the sealed
    -- controller table rejects late field assignment).
    UI = {} :: any,
    Player = nil :: Player?,
    RunState = "lobby",
    Floor = 1,
    MaxLumen = 100,
    FlickerThreshold = 10,
    InDarkness = false,
    LowLightActive = false,
    LowLightLoopId = 0,
    FlickerLoopId = 0,
    ToastTween = nil :: Tween?,
    CueTween = nil :: Tween?,
    FlashTween = nil :: Tween?,
    RegularSlots = {} :: { any },
    SpecialSlotUI = nil :: any,
    -- Lobby / host-gating state (GDD §2/§3.2).
    Host = nil :: any?, -- { UserId, Name } from RunService.Host
    SquadNames = {} :: { string },
    RunService = nil :: any?,
}

-- ---------------------------------------------------------------------------
-- GUI build (core three + shared scaffolding)
-- ---------------------------------------------------------------------------
function RunHudController:_BuildGui()
    local ui = self.UI
    ui.Root = New("ScreenGui", {
        Name = "RunHud",
        ResetOnSpawn = false,
        IgnoreGuiInset = false, -- respect mobile top/bottom bars
        DisplayOrder = 2,
    }, Players.LocalPlayer:WaitForChild("PlayerGui")) :: ScreenGui

    -- Darkness vignette (behind the HUD so meters stay readable — GDD §4.2:
    -- "screen vignette closes to near-black"; HUD is the same UI as the world).
    ui.Vignette = New("Frame", {
        Name = "DarknessVignette",
        Size = UDim2.fromScale(1, 1),
        BackgroundTransparency = 1,
        Visible = false,
        ZIndex = 1,
    }, ui.Root) :: Frame
    ui.DarkWash = New("Frame", {
        Size = UDim2.fromScale(1, 1),
        BackgroundColor3 = BLACK,
        BackgroundTransparency = 0.82,
        BorderSizePixel = 0,
    }, ui.Vignette) :: Frame
    -- Edge depth (top + bottom gradients) so it reads as a vignette, not a flat wash.
    local topFade = New("Frame", {
        Size = UDim2.fromScale(1, 0.22),
        BackgroundTransparency = 1,
    }, ui.Vignette) :: Frame
    local topGrad = New("UIGradient", {
        Rotation = 90, -- top -> bottom
        Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(1, 1) }),
    }, topFade) :: UIGradient
    topGrad.Color = ColorSequence.new(BLACK, BLACK)
    local bottomFade = New("Frame", {
        Size = UDim2.fromScale(1, 0.22),
        Position = UDim2.fromScale(0, 0.78),
        BackgroundTransparency = 1,
    }, ui.Vignette) :: Frame
    local bottomGrad = New("UIGradient", {
        Rotation = 90,
        Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(1, 0) }),
    }, bottomFade) :: UIGradient
    bottomGrad.Color = ColorSequence.new(BLACK, BLACK)
    ui.DarkTitle = Label(ui.Vignette, "THE LIGHT IS GONE", UDim2.fromScale(0.92, 0.1), UDim2.fromScale(0.5, 0.4), FONT_HEAD, 26, RED, Enum.TextXAlignment.Center) :: TextLabel
    ui.DarkTitle.AnchorPoint = Vector2.new(0.5, 0.5)
    ui.DarkSub = Label(ui.Vignette, "RECHARGE — A LUMEN CELL OR A WELL BRINGS IT BACK", UDim2.fromScale(0.92, 0.06), UDim2.fromScale(0.5, 0.5), FONT_BODY, 15, DIM, Enum.TextXAlignment.Center) :: TextLabel
    ui.DarkSub.AnchorPoint = Vector2.new(0.5, 0.5)

    -- Main HUD surface.
    ui.Main = New("Frame", {
        Name = "MainHud",
        Size = UDim2.fromScale(1, 1),
        BackgroundTransparency = 1,
    }, ui.Root) :: Frame

    -- Floor panel (top-center): floor number + run state.
    ui.FloorPanel = Panel(ui.Main, UDim2.fromOffset(150, 78), UDim2.new(0.5, 0, 0, 14), Vector2.new(0.5, 0))
    Stroke(ui.FloorPanel, STROKE, 0.78, 1)
    New("UICorner", { CornerRadius = UDim.new(0, 8) }, ui.FloorPanel)
    ui.FloorCaption = Label(ui.FloorPanel, "FLOOR", UDim2.fromScale(1, 0.18), UDim2.fromScale(0, 0.1), FONT_BODY, 12, DIM, Enum.TextXAlignment.Center) :: TextLabel
    ui.FloorNumber = Label(ui.FloorPanel, "—", UDim2.fromScale(1, 0.46), UDim2.fromScale(0, 0.22), FONT_HEAD, 32, TEXT, Enum.TextXAlignment.Center) :: TextLabel
    ui.RunStateLabel = Label(ui.FloorPanel, "LOBBY", UDim2.fromScale(1, 0.2), UDim2.fromScale(0, 0.74), FONT_BODY, 12, AMBER, Enum.TextXAlignment.Center) :: TextLabel

    -- Banked Filaments (top-right): visible in lobby AND in run (GDD §3.2/§5).
    ui.FilamentsPanel = Panel(ui.Main, UDim2.fromOffset(132, 32), UDim2.new(1, -12, 0, 14), Vector2.new(1, 0))
    Stroke(ui.FilamentsPanel, STROKE, 0.82, 1)
    New("UICorner", { CornerRadius = UDim.new(0, 8) }, ui.FilamentsPanel)
    ui.FilamentsLabel = Label(ui.FilamentsPanel, "F 0", UDim2.fromScale(1, 1), UDim2.fromScale(0, 0), FONT_MONO, 17, TEXT, Enum.TextXAlignment.Center) :: TextLabel

    -- Artifact pickup toast (below the floor panel; reused instance).
    ui.ToastLabel = Label(ui.Main, "", UDim2.new(0.92, 0, 0, 30), UDim2.new(0.5, 0, 0, 106), FONT_HEAD, 17, TEXT, Enum.TextXAlignment.Center) :: TextLabel
    ui.ToastLabel.AnchorPoint = Vector2.new(0.5, 0)
    ui.ToastLabel.Visible = false
    ui.ToastLabel.TextTransparency = 1

    -- Threat overlays (follow-up #4). Sibling order = render order: these sit
    -- above MainHud so the damage flash / flicker tint the whole screen.
    ui.DamageFlash = New("Frame", {
        Name = "DamageFlash",
        Size = UDim2.fromScale(1, 1),
        BackgroundColor3 = Color3.fromRGB(140, 24, 20),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        Visible = false,
    }, ui.Root) :: Frame
    ui.WardenFlickerFrame = New("Frame", {
        Name = "WardenFlicker",
        Size = UDim2.fromScale(1, 1),
        BackgroundColor3 = BLACK,
        BorderSizePixel = 0,
        Visible = false,
    }, ui.Root) :: Frame
    ui.ThreatCue = Label(ui.Main, "", UDim2.new(0.92, 0, 0, 28), UDim2.new(0.5, 0, 0, 140), FONT_HEAD, 15, AMBER, Enum.TextXAlignment.Center) :: TextLabel
    ui.ThreatCue.AnchorPoint = Vector2.new(0.5, 0)
    ui.ThreatCue.Visible = false
    ui.ThreatCue.TextTransparency = 1

    -- Carry row (bottom-center, above the thumb zone): 5 regular slots + special.
    ui.CarryRow = Panel(ui.Main, UDim2.fromOffset(246, 60), UDim2.new(0.5, 0, 1, -82), Vector2.new(0.5, 1))
    ui.CarryRow.BackgroundTransparency = 1
    ui.CarryCaption = Label(ui.CarryRow, "SQUAD CARRY 0/5", UDim2.fromOffset(246, 14), UDim2.fromOffset(0, 0), FONT_BODY, 10, DIM, Enum.TextXAlignment.Center) :: TextLabel
    local slots: { any } = {}
    for i = 1, 5 do
        local slot = Panel(ui.CarryRow, UDim2.fromOffset(34, 34), UDim2.fromOffset((i - 1) * 40, 20), Vector2.new(0, 0))
        slot.BackgroundTransparency = 0.7
        Stroke(slot, STROKE, 0.85, 1)
        New("UICorner", { CornerRadius = UDim.new(0, 5) }, slot)
        local glyph = Label(slot, "", UDim2.fromScale(1, 1), UDim2.fromScale(0, 0), FONT_HEAD, 19, DIM, Enum.TextXAlignment.Center) :: TextLabel
        table.insert(slots, { Frame = slot, Glyph = glyph })
    end
    ui.RegularSlots = slots
    -- The Bell's special slot (larger, separated, gold when filled).
    local special = Panel(ui.CarryRow, UDim2.fromOffset(42, 42), UDim2.fromOffset(204, 18), Vector2.new(0, 0))
    special.BackgroundTransparency = 0.7
    Stroke(special, STROKE, 0.85, 2)
    New("UICorner", { CornerRadius = UDim.new(0, 6) }, special)
    ui.SpecialSlotUI = {
        Frame = special,
        Glyph = Label(special, "", UDim2.fromScale(1, 1), UDim2.fromScale(0, 0), FONT_HEAD, 24, DIM, Enum.TextXAlignment.Center) :: TextLabel,
    }

    -- Lumen meter (center-bottom): track + gradient fill + low-light pulse.
    ui.LumenBar = Panel(ui.Main, UDim2.fromOffset(250, 52), UDim2.new(0.5, 0, 1, -18), Vector2.new(0.5, 1))
    ui.LumenBar.BackgroundTransparency = 1
    ui.LumenCaption = Label(ui.LumenBar, "LUMEN", UDim2.new(1, -70, 0, 14), UDim2.fromOffset(8, 2), FONT_BODY, 10, DIM, Enum.TextXAlignment.Left) :: TextLabel
    ui.LumenValue = Label(ui.LumenBar, "100/100", UDim2.fromOffset(70, 16), UDim2.new(1, -8, 0, 2), FONT_MONO, 14, TEXT, Enum.TextXAlignment.Right) :: TextLabel
    ui.LumenValue.AnchorPoint = Vector2.new(1, 0)
    ui.LumenTrack = New("Frame", {
        Name = "LumenTrack",
        Size = UDim2.fromOffset(250, 20),
        Position = UDim2.fromOffset(0, 26),
        BackgroundColor3 = Color3.fromRGB(12, 14, 16),
        BackgroundTransparency = 0.55,
        BorderSizePixel = 0,
    }, ui.LumenBar) :: Frame
    Stroke(ui.LumenTrack, STROKE, 0.72, 1)
    New("UICorner", { CornerRadius = UDim.new(0, 4) }, ui.LumenTrack)
    ui.LumenFill = New("Frame", {
        Name = "LumenFill",
        Size = UDim2.fromScale(1, 1),
        BackgroundColor3 = LUMEN_BOTTOM,
        BorderSizePixel = 0,
    }, ui.LumenTrack) :: Frame
    local fillGrad = New("UIGradient", { Rotation = 90 }, ui.LumenFill) :: UIGradient
    fillGrad.Color = ColorSequence.new(LUMEN_TOP, LUMEN_BOTTOM)
    New("UICorner", { CornerRadius = UDim.new(0, 4) }, ui.LumenFill)
    ui.LowLightPulse = New("Frame", {
        Name = "LowLightPulse",
        Size = UDim2.fromScale(1, 1),
        BackgroundColor3 = RED,
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
    }, ui.LumenTrack) :: Frame
    New("UICorner", { CornerRadius = UDim.new(0, 4) }, ui.LowLightPulse)

    -- Loot screen container (populated on run end; empty + hidden until then).
    ui.LootScreen = New("Frame", {
        Name = "LootScreen",
        Size = UDim2.fromScale(1, 1),
        BackgroundColor3 = Color3.fromRGB(5, 6, 8),
        BackgroundTransparency = 0.04,
        BorderSizePixel = 0,
        Visible = false,
    }, ui.Root) :: Frame
    ui.LootTitle = Label(ui.LootScreen, "", UDim2.fromScale(0.92, 0.09), UDim2.fromScale(0.5, 0.13), FONT_HEAD, 30, TEXT, Enum.TextXAlignment.Center) :: TextLabel
    ui.LootTitle.AnchorPoint = Vector2.new(0.5, 0)
    ui.LootSubtitle = Label(ui.LootScreen, "", UDim2.fromScale(0.92, 0.05), UDim2.fromScale(0.5, 0.23), FONT_BODY, 15, DIM, Enum.TextXAlignment.Center) :: TextLabel
    ui.LootSubtitle.AnchorPoint = Vector2.new(0.5, 0)
    ui.LootRows = New("Frame", {
        Size = UDim2.new(0.8, 0, 0, 132),
        Position = UDim2.new(0.5, 0, 0.33, 0),
        AnchorPoint = Vector2.new(0.5, 0),
        BackgroundTransparency = 1,
    }, ui.LootScreen) :: Frame
    ui.LootMath = New("Frame", {
        Size = UDim2.new(0.8, 0, 0, 60),
        Position = UDim2.new(0.5, 0, 0.56, 0),
        AnchorPoint = Vector2.new(0.5, 0),
        BackgroundTransparency = 1,
    }, ui.LootScreen) :: Frame
    ui.LootTotal = Label(ui.LootScreen, "", UDim2.fromScale(0.92, 0.08), UDim2.fromScale(0.5, 0.7), FONT_MONO, 32, PALE_GREEN, Enum.TextXAlignment.Center) :: TextLabel
    ui.LootTotal.AnchorPoint = Vector2.new(0.5, 0)
    ui.LootHint = Label(ui.LootScreen, "", UDim2.fromScale(0.92, 0.05), UDim2.fromScale(0.5, 0.86), FONT_BODY, 14, DIM, Enum.TextXAlignment.Center) :: TextLabel
    ui.LootHint.AnchorPoint = Vector2.new(0.5, 0)

    -- Lobby / start bar (host gating, GDD §2/§3.2). Bottom-center strip shown
    -- whenever a run is NOT active (lobby + after extract/wipe = "run it back").
    -- Sits above the loot screen (later sibling) so the host can start without
    -- console. In-run the bar hides — the dark doesn't want a menu.
    ui.LobbyBar = Panel(ui.Root, UDim2.fromOffset(580, 46), UDim2.new(0.5, 0, 1, -14), Vector2.new(0.5, 1))
    ui.LobbyBar.ZIndex = 4
    ui.LobbyBar.Visible = false
    Stroke(ui.LobbyBar, STROKE, 0.75, 1)
    New("UICorner", { CornerRadius = UDim.new(0, 6) }, ui.LobbyBar)
    ui.LobbyHost = Label(ui.LobbyBar, "WAITING FOR HOST", UDim2.new(0.32, 0, 1, 0), UDim2.fromOffset(12, 0), FONT_MONO, 13, DIM, Enum.TextXAlignment.Left) :: TextLabel
    ui.LobbySquad = Label(ui.LobbyBar, "SQUAD —", UDim2.new(0.36, 0, 1, 0), UDim2.new(0.33, 0, 0, 0), FONT_BODY, 12, TEXT, Enum.TextXAlignment.Center) :: TextLabel
    ui.StartButton = New("TextButton", {
        Name = "StartRunButton",
        Size = UDim2.new(0.3, 0, 1, 0),
        Position = UDim2.new(0.7, 0, 0, 0),
        AnchorPoint = Vector2.new(0, 0),
        BackgroundColor3 = Color3.fromRGB(30, 26, 18),
        BackgroundTransparency = 0.1,
        BorderSizePixel = 0,
        Text = "START RUN",
        Font = FONT_HEAD,
        TextSize = 15,
        TextColor3 = AMBER,
        Visible = false,
    }, ui.LobbyBar) :: TextButton
    Stroke(ui.StartButton, AMBER, 0.5, 1)
    New("UICorner", { CornerRadius = UDim.new(0, 6) }, ui.StartButton)
    ui.StartButton.Activated:Connect(function()
        self:RequestStartRun()
    end)
    ui.WaitingHint = Label(ui.LobbyBar, "WAITING FOR HOST TO START", UDim2.new(0.3, 0, 1, 0), UDim2.new(0.7, 0, 0, 0), FONT_BODY, 12, DIM, Enum.TextXAlignment.Center) :: TextLabel

    Log("HUD built")
end

-- ---------------------------------------------------------------------------
-- Lumen meter (core 1)
-- ---------------------------------------------------------------------------
function RunHudController:SetLumen(value: number)
    local clamped = math.clamp(value, 0, self.MaxLumen)
    local ratio = self.MaxLumen > 0 and clamped / self.MaxLumen or 0
    self.UI.LumenFill.Size = UDim2.fromScale(ratio, 1)
    self.UI.LumenValue.Text = ("%d/%d"):format(math.round(clamped), self.MaxLumen)
    -- GDD §4.2/§9: the universal "light is dying" cue — the pool bar pulses
    -- below the server's flicker threshold.
    self:SetLowLight(clamped < self.FlickerThreshold)
end

function RunHudController:SetLowLight(active: boolean)
    if active == self.LowLightActive then
        return
    end
    self.LowLightActive = active
    self.LowLightLoopId += 1
    if active then
        local id = self.LowLightLoopId
        task.spawn(function()
            self:LowLightPulseLoop(id)
        end)
    end
end

-- Steady red pulse over the Lumen track while the pool is critically low.
-- One task.wait(0.04) loop, gated off when the pool recovers — no tweens,
-- no per-frame allocations.
function RunHudController:LowLightPulseLoop(id: number)
    local pulse = self.UI.LowLightPulse :: Frame
    pulse.BackgroundTransparency = 0.4
    while self.LowLightActive and self.LowLightLoopId == id do
        local t = (os.clock() % 1.1) / 1.1
        local opacity = 0.35 + 0.3 * math.sin(t * math.pi * 2)
        pulse.BackgroundTransparency = 1 - opacity
        task.wait(0.04)
    end
    pulse.BackgroundTransparency = 1
end

-- ---------------------------------------------------------------------------
-- Darkness vignette (core 1)
-- ---------------------------------------------------------------------------
function RunHudController:SetDarkness(inDarkness: boolean)
    self.InDarkness = inDarkness
    self.UI.Vignette.Visible = inDarkness
    if inDarkness then
        Log("DARKNESS — vignette closed in")
    end
end

-- ---------------------------------------------------------------------------
-- Carry slots (core 2)
-- ---------------------------------------------------------------------------
local function EntryGlyph(entry: any): string
    if type(entry) ~= "table" then
        return ""
    end
    local name = entry.Name
    if type(name) ~= "string" then
        return ""
    end
    return string.sub(name, 1, 1)
end

function RunHudController:_PaintSlot(slot: any, entry: any)
    local filled = type(entry) == "table"
    local color = filled and (RARITY_COLORS[entry.Rarity] or RARITY_COLORS.Common) or STROKE
    slot.Frame.BackgroundTransparency = filled and 0.86 or 0.72
    slot.Glyph.Text = filled and EntryGlyph(entry) or ""
    slot.Glyph.TextColor3 = filled and color or DIM
    -- Stroke color/alpha switches on the stroke instance itself.
    local stroke = slot.Frame:FindFirstChildOfClass("UIStroke")
    if stroke then
        stroke.Color = color
        stroke.Transparency = filled and 0.2 or 0.85
    end
end

function RunHudController:SetCarry(snapshot: any)
    if type(snapshot) ~= "table" then
        return
    end
    local artifacts: { any } = snapshot.Artifacts or {}
    for i, slot in ipairs(self.RegularSlots) do
        self:_PaintSlot(slot, artifacts[i])
    end
    self:_PaintSlot(self.SpecialSlotUI, snapshot.SpecialSlot)
    local used = #artifacts
    self.UI.CarryCaption.Text = ("SQUAD CARRY %d/%d"):format(used, #self.RegularSlots)
end

-- ---------------------------------------------------------------------------
-- Pickup toast (core 2)
-- ---------------------------------------------------------------------------
function RunHudController:ShowArtifactToast(entry: any)
    if type(entry) ~= "table" then
        return
    end
    local toast = self.UI.ToastLabel :: TextLabel
    local color = RARITY_COLORS[entry.Rarity] or RARITY_COLORS.Common
    toast.Text = ("%s  ·  %dF"):format(entry.Name, entry.BaseValue or 0)
    toast.TextColor3 = color
    toast.TextTransparency = 0
    toast.Visible = true
    if self.ToastTween then
        self.ToastTween:Cancel()
    end
    -- Hold 1.5s, fade out over 0.45s. `played` guard: a canceled tween must
    -- not hide a toast that was just re-shown.
    self.ToastTween = TweenService:Create(toast, TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, 0, false, 1.5), { TextTransparency = 1 })
    self.ToastTween.Completed:Connect(function(played: boolean)
        if played then
            toast.Visible = false
        end
    end)
    self.ToastTween:Play()
end

-- ---------------------------------------------------------------------------
-- Run state + floor indicator (core 3)
-- ---------------------------------------------------------------------------
function RunHudController:SetFloor(floor: number)
    self.Floor = floor
    self.UI.FloorNumber.Text = tostring(floor)
end

function RunHudController:SetRunState(state: string, payload: any?)
    self.RunState = state
    -- The in-run payload IS the RunInfo table (has Floor) — read it immediately
    -- so the floor number doesn't sit at "—" until the property lands.
    if type(payload) == "table" and type(payload.Floor) == "number" then
        self:SetFloor(payload.Floor)
    end
    local inRun = state == "in-run"
    self.UI.CarryRow.Visible = inRun
    self.UI.LumenBar.Visible = inRun
    -- Lobby/start bar: visible whenever a run is NOT active, so the host can
    -- start a fresh run AND run it back after extract/wipe (§3.2).
    self.UI.LobbyBar.Visible = not inRun
    self.UI.RunStateLabel.Text = string.upper(state):gsub("%-", " ")
    if state == "lobby" then
        self.UI.FloorNumber.Text = "—"
        self.UI.RunStateLabel.TextColor3 = DIM
        self.UI.LootScreen.Visible = false
    elseif state == "in-run" then
        self.UI.RunStateLabel.TextColor3 = AMBER
        self.UI.LootScreen.Visible = false
    elseif state == "extracted" then
        self.UI.RunStateLabel.TextColor3 = PALE_GREEN
        self:ShowLootScreen(payload)
    elseif state == "wiped" then
        self.UI.RunStateLabel.TextColor3 = RED
        self:ShowWipeScreen(payload)
    end
    Log(("Run state -> %s"):format(state))
end

-- ---------------------------------------------------------------------------
-- Lobby / host gating (GDD §2/§3.2)
-- ---------------------------------------------------------------------------
-- The START RUN button belongs to the host (first player in the server). When
-- the server has no host or the local player isn't it, show the waiting state.
function RunHudController:UpdateLobby()
    local ui = self.UI
    local host = self.Host
    if type(host) ~= "table" then
        ui.LobbyHost.Text = "WAITING FOR HOST"
        ui.LobbyHost.TextColor3 = DIM
        ui.StartButton.Visible = false
        ui.WaitingHint.Visible = true
        ui.WaitingHint.Text = "WAITING FOR HOST TO START"
    else
        ui.LobbyHost.Text = ("HOST  %s"):format(tostring(host.Name))
        ui.LobbyHost.TextColor3 = AMBER
        local isHost = self.Player ~= nil and host.UserId == self.Player.UserId
        ui.StartButton.Visible = isHost
        ui.WaitingHint.Visible = not isHost
        ui.WaitingHint.Text = isHost and "YOU QUEUE THE RUN" or "WAITING FOR HOST TO START"
    end
    local names = self.SquadNames
    ui.LobbySquad.Text = #names > 0 and ("SQUAD  %s"):format(table.concat(names, " · ")) or "SQUAD  —"
end

--- Host clicks START RUN → RunService.StartRun RPC (server re-validates host).
function RunHudController:RequestStartRun()
    local runService = self.RunService
    if runService == nil then
        return
    end
    runService:StartRun():andThen(function(result: any)
        if type(result) == "table" and not result.Started then
            Log(("StartRun rejected: %s"):format(tostring(result.Reason)))
            -- e.g. another player grabbed host, or a run is somehow active —
            -- the next host event re-renders the bar.
        end
    end):catch(function(err: any)
        warn("[RunHudController] StartRun failed:", err)
    end)
end

-- ---------------------------------------------------------------------------
-- Threat cues (follow-up #4)
-- ---------------------------------------------------------------------------
-- Brief red full-screen flash when the LOCAL player takes a threat hit
-- (GDD §4.5: Wanderer hits Lumen first; flash reads even at low health states).
function RunHudController:DamageFlash()
    local flash = self.UI.DamageFlash :: Frame
    if self.FlashTween then
        self.FlashTween:Cancel()
    end
    flash.Visible = true
    flash.BackgroundTransparency = 0.45
    self.FlashTween = TweenService:Create(flash, TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { BackgroundTransparency = 1 })
    self.FlashTween.Completed:Connect(function(played: boolean)
        if played then
            flash.Visible = false
        end
    end)
    self.FlashTween:Play()
end

-- Warden gaze: light-bulb-fail stutter (GDD §4.5/§9) — short irregular black
-- drops over the whole screen, capped so it's a scare, not a 5s blackout.
function RunHudController:WardenFlicker(flickerSeconds: number)
    local frame = self.UI.WardenFlickerFrame :: Frame
    self.FlickerLoopId += 1
    local id = self.FlickerLoopId
    task.spawn(function()
        local t0 = os.clock()
        local on = true
        local Rng = Random.new()
        while os.clock() - t0 < math.min(flickerSeconds, 1.6) and self.FlickerLoopId == id do
            on = not on
            frame.Visible = on
            task.wait(on and 0.05 or 0.03 + Rng:NextNumber() * 0.06)
        end
        frame.Visible = false
    end)
end

-- Subtle alert cue when an entity picks up the squad's trail.
function RunHudController:ShowThreatCue(text: string)
    local cue = self.UI.ThreatCue :: TextLabel
    cue.Text = text
    cue.TextTransparency = 0
    cue.Visible = true
    if self.CueTween then
        self.CueTween:Cancel()
    end
    self.CueTween = TweenService:Create(cue, TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, 0, false, 1.1), { TextTransparency = 1 })
    self.CueTween.Completed:Connect(function(played: boolean)
        if played then
            cue.Visible = false
        end
    end)
    self.CueTween:Play()
end

-- ---------------------------------------------------------------------------
-- Loot / wipe screens (follow-up #5)
-- ---------------------------------------------------------------------------
local function RowLabel(parent: Instance, text: string, color: Color3, xAlign: Enum.TextXAlignment, widthScale: number): TextLabel
    return Label(parent, text, UDim2.new(widthScale, 0, 1, 0), UDim2.fromOffset(12, 0), FONT_BODY, 16, color, xAlign)
end

function RunHudController:_ClearLoot()
    self.UI.LootRows:ClearAllChildren()
    self.UI.LootMath:ClearAllChildren()
end

-- Extraction results (GDD §4.4 math reveal + §4.7): artifact list with rarity
-- colors, multiplier breakdown, total banked, run-it-back hint.
function RunHudController:ShowLootScreen(results: any)
    if type(results) ~= "table" then
        return
    end
    self:_ClearLoot()
    local screen = self.UI.LootScreen
    local bd = results.Breakdown or {}
    local artifacts: { any } = {}
    for _, entry in ipairs(results.Artifacts or {}) do
        table.insert(artifacts, entry)
    end
    if results.SpecialSlot ~= nil then
        table.insert(artifacts, results.SpecialSlot)
    end
    self.UI.LootTitle.Text = "EXTRACTED"
    self.UI.LootTitle.TextColor3 = PALE_GREEN
    self.UI.LootSubtitle.Text = ("FLOOR %d  ·  %s"):format(
        results.FloorReached or 0,
        results.SquadAlive and "THE WHOLE SQUAD MADE IT OUT" or "SOMEONE WAS LEFT IN THE DARK"
    )
    for i, entry in ipairs(artifacts) do
        local row = New("Frame", {
            Size = UDim2.new(1, 0, 0, 24),
            Position = UDim2.fromOffset(0, (i - 1) * 25),
            BackgroundTransparency = 1,
        }, self.UI.LootRows) :: Frame
        local color = RARITY_COLORS[entry.Rarity] or RARITY_COLORS.Common
        RowLabel(row, entry.Name, color, Enum.TextXAlignment.Left, 0.78)
        RowLabel(row, ("+%dF"):format(entry.BaseValue or 0), DIM, Enum.TextXAlignment.Right, 0.22)
    end
    if #artifacts == 0 then
        RowLabel(self.UI.LootRows, "NOTHING CARRIED", DIM, Enum.TextXAlignment.Left, 1)
    end
    local lines: { string } = {}
    table.insert(lines, ("BASE  ·  %dF"):format(bd.BaseSum or 0))
    if (bd.AliveMultiplier or 1) > 1 then
        table.insert(lines, ("SQUAD ALIVE  ·  ×%.2f"):format(bd.AliveMultiplier))
    end
    if (bd.ObjectiveMultiplier or 1) > 1 then
        table.insert(lines, ("OBJECTIVES (%d)  ·  ×%.2f"):format(bd.ObjectivesCompleted or 0, bd.ObjectiveMultiplier))
    end
    if (bd.LonerMultiplier or 1) > 1 then
        table.insert(lines, ("LONER'S LEDGER  ·  ×%.2f"):format(bd.LonerMultiplier))
    end
    for i, line in ipairs(lines) do
        RowLabel(self.UI.LootMath, line, DIM, Enum.TextXAlignment.Left, 1)
    end
    self.UI.LootTotal.TextColor3 = PALE_GREEN
    self.UI.LootTotal.Text = ("%d F  BANKED"):format(results.BankedFilaments or 0)
    self.UI.LootHint.Text = "RUN IT BACK — THE BANK KEEPS THIS FOREVER"
    screen.Visible = true
    Log(("Loot screen: %dF banked (%d artifact(s))"):format(results.BankedFilaments or 0, #artifacts))
end

-- Wipe (GDD §4.7): run loot lost, bank safe, immediate re-queue framing.
function RunHudController:ShowWipeScreen(payload: any)
    if type(payload) ~= "table" then
        return
    end
    self:_ClearLoot()
    local lost = payload.LostArtifacts or {}
    local artifacts: { any } = lost.Artifacts or {}
    local count = #artifacts + (lost.SpecialSlot ~= nil and 1 or 0)
    self.UI.LootTitle.Text = "THE DARK GOT ITS TAKE"
    self.UI.LootTitle.TextColor3 = RED
    self.UI.LootSubtitle.Text = ("FLOOR %d  ·  %s"):format(payload.FloorReached or 0, tostring(payload.Reason or "squad lost"))
    if count == 0 then
        RowLabel(self.UI.LootRows, "NOTHING CARRIED — THE DARK GOT NOTHING EITHER", DIM, Enum.TextXAlignment.Left, 1)
    else
        local names: { string } = {}
        for _, entry in ipairs(artifacts) do
            table.insert(names, entry.Name)
        end
        if lost.SpecialSlot ~= nil then
            table.insert(names, lost.SpecialSlot.Name)
        end
        RowLabel(self.UI.LootRows, ("LOST  ·  %s"):format(table.concat(names, ", ")), RED, Enum.TextXAlignment.Left, 1)
    end
    self.UI.LootTotal.TextColor3 = TEXT
    self.UI.LootTotal.Text = "BANK IS SAFE"
    self.UI.LootHint.Text = "FILAMENTS AND UNLOCKS ARE KEPT — RUN IT BACK"
    self.UI.LootScreen.Visible = true
    Log(("Wipe screen: %s"):format(tostring(payload.Reason)))
end

-- ---------------------------------------------------------------------------
-- Filaments (bank balance, top-right)
-- ---------------------------------------------------------------------------
function RunHudController:SetFilaments(balance: number)
    self.UI.FilamentsLabel.Text = ("F %s"):format(tostring(math.floor(balance)))
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------
function RunHudController:KnitStart()
    self.Player = Players.LocalPlayer
    self:_BuildGui()

    local lumenService = Knit.GetService("LumenService")
    local runService = Knit.GetService("RunService")
    self.RunService = runService
    local artifactService = Knit.GetService("ArtifactService")
    local extractionService = Knit.GetService("ExtractionService")
    local entityService = Knit.GetService("EntityService")
    local economyService = Knit.GetService("EconomyService")

    -- Server-pushed tuning (single source of truth for v1 targets).
    lumenService.Config:Observe(function(config: any)
        if type(config) ~= "table" then
            return
        end
        if type(config.FlickerThreshold) == "number" then
            self.FlickerThreshold = config.FlickerThreshold
        end
        if type(config.MaxLumen) == "number" then
            self.MaxLumen = config.MaxLumen
        end
    end)

    -- Lumen pool (Observe covers late joins; Changed covers live ticks).
    lumenService.Lumen:Observe(function(value: number)
        self:SetLumen(value)
    end)
    lumenService.LumenChanged:Connect(function(value: number)
        self:SetLumen(value)
    end)

    -- Darkness failure state.
    lumenService.DarknessChanged:Connect(function(inDarkness: boolean)
        self:SetDarkness(inDarkness)
    end)

    -- Carry slots (Observe = initial empty snapshot; Changed = live updates).
    artifactService.Carry:Observe(function(snapshot: any)
        self:SetCarry(snapshot)
    end)
    artifactService.CarryChanged:Connect(function(snapshot: any)
        self:SetCarry(snapshot)
    end)
    artifactService.ArtifactPickedUp:Connect(function(entry: any)
        self:ShowArtifactToast(entry)
    end)

    -- Run lifecycle + floor indicator.
    runService.RunState:Observe(function(state: string)
        self:SetRunState(state, nil)
    end)
    runService.RunStateChanged:Connect(function(state: string, payload: any?)
        self:SetRunState(state, payload)
    end)
    runService.RunInfo:Observe(function(info: any)
        if type(info) ~= "table" then
            return
        end
        if type(info.Floor) == "number" then
            self:SetFloor(info.Floor)
        end
        -- Lobby bar: squad list + host changes ride along in RunInfo too.
        if type(info.Squad) == "table" then
            self.SquadNames = info.Squad
        end
        if type(info.Host) == "table" then
            self.Host = info.Host
        end
        self:UpdateLobby()
    end)
    -- Host changes (dedicated surface — fires on promotion/clear, incl. when
    -- the current host leaves and the next player takes over).
    runService.Host:Observe(function(host: any?)
        self.Host = host
        self:UpdateLobby()
    end)
    runService.HostChanged:Connect(function(host: any?)
        self.Host = host
        self:UpdateLobby()
    end)
    extractionService.FloorAdvanced:Connect(function(floor: number)
        self:SetFloor(floor)
    end)

    -- Threat cues (follow-up #4). ThreatHit/WardenGaze carry the attacked
    -- player as an arg — only react for the local player.
    entityService.ThreatHit:Connect(function(_entityId: number, _kind: string, player: Player, _lumenDamage: number, _hpDamage: number)
        if player == self.Player then
            self:DamageFlash()
        end
    end)
    entityService.WardenGaze:Connect(function(player: Player, flickerSeconds: number)
        if player == self.Player then
            self:WardenFlicker(flickerSeconds)
        end
    end)
    entityService.EntityStateChanged:Connect(function(_entityId: number, kind: string, state: string, _payload: any?)
        if state == "INVESTIGATE" then
            self:ShowThreatCue("IT HEARD YOU")
        elseif state == "CHASE" then
            self:ShowThreatCue(kind == "Warden" and "THE WARDEN SEES YOU" or "IT SEES YOU")
        end
    end)

    -- Bank balance (initial fetch + live updates).
    economyService:GetFilaments():andThen(function(balance: number)
        self:SetFilaments(balance)
    end):catch(function(err: any)
        warn("[RunHudController] GetFilaments failed:", err)
    end)
    economyService.FilamentsChanged:Connect(function(balance: number)
        self:SetFilaments(balance)
    end)

    Log(("Started for %s"):format(self.Player.Name))
end

return RunHudController
