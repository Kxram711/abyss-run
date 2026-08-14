--!strict
-- LumenService — the shared squad Lumen pool (GDD §4.2).
-- SERVER-AUTHORITATIVE: clients never own the pool. Every Lumen change flows
-- through this service (passive drain tick, flashlight tax, Wells, Cells,
-- revive spends) and is broadcast to clients through the Comm surface below:
--
--   RPCs (client -> server):
--     SetFlashlight(on: boolean) -> boolean   toggle beam; false in Darkness
--     ConsumeCell() -> "success" | "no_cells" consume a Lumen Cell (+25)
--
--   Signals (server -> client):
--     LumenChanged      (lumen: number)          pool value on every change
--     DarknessChanged   (inDarkness: boolean)    true = entered Darkness, false = recovered
--     CellCountChanged  (count: number)          per-player cell count on change
--     FlashlightChanged (on: boolean)            per-player beam force-sync (e.g. dies in Darkness)
--
--   Properties (server -> client):
--     Lumen    current pool value (also syncs late joiners)
--     Config   shared tuning table (flicker threshold etc.)
--
-- The HUD/UI binds LumenChanged/DarknessChanged later (UI/UX delegation);
-- the LumenController consumes them with logs for now.

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Knit = require(ReplicatedStorage.Packages.Knit)

-- Tuning knobs (GDD §4.2). Values marked "(v1 target)" are starting points
-- to be validated by playtests; the structural rules above them are build spec.
local CONFIG = {
    MaxLumen = 100, -- pool cap, 0-100 (GDD §4.2)
    PassiveDrainFloor1 = 0.5, -- L/s on Floor 1 (v1 target)
    DrainMultiplierPerFloor = 1.12, -- x1.12 per floor deeper (v1 target)
    FlashlightDrainPerPlayer = 0.3, -- extra L/s per active beam (v1 target)
    SprintDrainPerPlayer = 0.4, -- extra L/s per sprinting player (GDD §4.2 v1 target)
    WellRecharge = 40, -- Lumen per Well use (v1 target)
    CellRecharge = 25, -- Lumen per Lumen Cell (v1 target)
    ReviveCost = 30, -- Lumen from the pool to revive a teammate (v1 target)
    StarterCells = 1, -- debug starter loadout so the slice is testable
    -- Cell capacity (GDD §4.1: max 3 bought pre-run; §4.6 gear modifies it).
    BaseCellSlots = 3,
    RationPackExtraSlots = 1, -- Ration Pack: +1 consumable slot (3 -> 4)
    LongCellExtraSlots = 2, -- Long-Cell Carrier: 3 -> 5
    FlickerThreshold = 10, -- client beams flicker below this pool value (v1 target)
    TickInterval = 0.5, -- economy tick in seconds
}

local LumenService = Knit.CreateService {
    Name = "LumenService",
    Client = {
        -- Client-visible remote surface (see header). RPC methods are attached
        -- after the service is constructed (they need the service reference).
        LumenChanged = Knit.CreateSignal(),
        DarknessChanged = Knit.CreateSignal(),
        CellCountChanged = Knit.CreateSignal(),
        FlashlightChanged = Knit.CreateSignal(),
        Lumen = Knit.CreateProperty(100),
        Config = Knit.CreateProperty(nil),
    },
}

-- ---------------------------------------------------------------------------
-- Client-callable RPCs (self = Client table; Knit injects the calling Player
-- as the first argument, e.g. `svc:SetFlashlight(true)` -> (player, true))
-- ---------------------------------------------------------------------------

function LumenService.Client:SetFlashlight(player: Player, on: boolean)
    return LumenService:SetFlashlightForPlayer(player, on)
end

function LumenService.Client:ConsumeCell(player: Player)
    return LumenService:ConsumeCellForPlayer(player)
end

-- ---------------------------------------------------------------------------
-- Service lifecycle
-- ---------------------------------------------------------------------------

function LumenService:KnitStart()
    self.LumenValue = CONFIG.MaxLumen
    self.InDarkness = false
    self.FlashlightsOn = {} -- [Player] -> boolean
    self.Cells = {} -- [Player] -> number
    self.Sprinting = {} -- [Player] -> boolean (movement pass reports sprint; seam live for Sprint Regulator)
    self.UsedWells = {} -- [BasePart] -> true (one use per Well, GDD §4.2)
    self.ActivePlayerCount = 0
    self.FloorService = Knit.GetService("FloorService")
    self.EconomyService = Knit.GetService("EconomyService") -- gear seams (§4.6)

    -- Push shared tuning to clients (single source of truth for v1 targets).
    self.Client.Config:Set({
        FlickerThreshold = CONFIG.FlickerThreshold,
        MaxLumen = CONFIG.MaxLumen,
    })

    -- Player lifecycle. The pool resets to full when the FIRST player joins an
    -- idle server: each run starts with shared 100 Lumen (GDD §3.2).
    for _, player in Players:GetPlayers() do
        self:OnPlayerJoined(player)
    end
    Players.PlayerAdded:Connect(function(player)
        self:OnPlayerJoined(player)
    end)
    Players.PlayerRemoving:Connect(function(player)
        self:OnPlayerLeaving(player)
    end)

    -- Register the placeholder Well(s) already placed in the scene.
    self:RegisterWellsInWorkspace()

    -- Economy tick loop (drain only; regen is action-based, never passive).
    task.spawn(function()
        self:TickLoop()
    end)
end

function LumenService:OnPlayerJoined(player: Player)
    local wasEmpty = self.ActivePlayerCount == 0
    self.ActivePlayerCount += 1
    self.Cells[player] = CONFIG.StarterCells -- debug starter loadout (slice)
    self.FlashlightsOn[player] = false

    if wasEmpty then
        self:SetLumen(CONFIG.MaxLumen)
    end
end

function LumenService:OnPlayerLeaving(player: Player)
    self.ActivePlayerCount = math.max(0, self.ActivePlayerCount - 1)
    self.Cells[player] = nil
    self.FlashlightsOn[player] = nil
end

-- ---------------------------------------------------------------------------
-- Drain tick
-- ---------------------------------------------------------------------------

function LumenService:TickLoop()
    while true do
        task.wait(CONFIG.TickInterval)
        if self.ActivePlayerCount == 0 then
            continue -- idle server: the pool waits for the next run
        end
        local drain = self:GetTotalDrainPerSecond() * CONFIG.TickInterval
        self:SetLumen(self.LumenValue - drain)
    end
end

-- Passive drain compounds per floor: base x 1.12^(floor-1) (GDD §4.2).
function LumenService:GetPassiveDrainPerSecond(): number
    local floor = self.FloorService:GetCurrentFloor()
    return CONFIG.PassiveDrainFloor1 * (CONFIG.DrainMultiplierPerFloor ^ (floor - 1))
end

function LumenService:GetTotalDrainPerSecond(): number
    local drain = self:GetPassiveDrainPerSecond()
    for _, on in pairs(self.FlashlightsOn) do
        if on then
            drain += CONFIG.FlashlightDrainPerPlayer
        end
    end
    -- Sprint tax (GDD §4.2): +0.4 L/s per sprinting player. The movement pass
    -- reports sprint state into self.Sprinting; until then the seam is live but
    -- empty (Sprint Regulator's 0.4 -> 0.3 read is still testable via
    -- GetSprintDrainPerSecond).
    for player, sprinting in pairs(self.Sprinting) do
        if sprinting then
            drain += self:GetSprintDrainPerSecond(player)
        end
    end
    return drain
end

--- Sprint Lumen tax per player (GDD §4.2 v1 target: +0.4 L/s). Sprint
--- Regulator (GDD §4.6) cuts it to 0.3 L/s for owners.
function LumenService:GetSprintDrainPerSecond(player: Player): number
    local drain = CONFIG.SprintDrainPerPlayer
    if self.EconomyService ~= nil and self.EconomyService:HasUpgrade(player, "sprint_regulator") then
        drain = 0.3
    end
    return drain
end

-- ---------------------------------------------------------------------------
-- Pool mutation (single funnel — every change goes through SetLumen)
-- ---------------------------------------------------------------------------

function LumenService:SetLumen(value: number)
    local newValue = math.clamp(value, 0, CONFIG.MaxLumen)
    if newValue == self.LumenValue then
        return
    end
    self.LumenValue = newValue
    self.Client.LumenChanged:FireAll(newValue)
    self.Client.Lumen:Set(newValue)
    if newValue <= 0 and not self.InDarkness then
        self:EnterDarkness()
    elseif newValue > 0 and self.InDarkness then
        self:ExitDarkness()
    end
end

function LumenService:AddLumen(amount: number)
    if amount <= 0 then
        return
    end
    self:SetLumen(self.LumenValue + amount)
end

-- ---------------------------------------------------------------------------
-- Darkness failure state (GDD §4.2): NOT instant death — recoverable.
-- Pool at 0 -> beams die + vignette cue; any recharge ends it.
-- ---------------------------------------------------------------------------

function LumenService:EnterDarkness()
    self.InDarkness = true
    print("[LumenService] DARKNESS — pool hit 0. Recharge to recover.")
    self.Client.DarknessChanged:FireAll(true)
    -- All flashlights die (GDD §4.2). Beams stay off until the player re-toggles.
    for player, on in pairs(self.FlashlightsOn) do
        if on then
            self.FlashlightsOn[player] = false
            self.Client.FlashlightChanged:Fire(player, false)
        end
    end
end

function LumenService:ExitDarkness()
    self.InDarkness = false
    print("[LumenService] LIGHT RECOVERED — pool above 0.")
    self.Client.DarknessChanged:FireAll(false)
end

-- ---------------------------------------------------------------------------
-- Run lifecycle resets (GDD §3.2/§4.7)
-- ---------------------------------------------------------------------------

-- RunService calls this at StartRun: the squad drops with a full shared pool
-- and fresh Wells (GDD §3.2 step 2). Clearing UsedWells also drops references
-- to the previous floor's destroyed Well parts.
function LumenService:ResetForRun()
    self.UsedWells = {}
    self:SetLumen(CONFIG.MaxLumen)
    print("[LumenService] Run reset — pool restored to 100, Wells refreshed.")
end

-- Floor advance: the new floor's Wells are fresh parts (one use each). The
-- pool carries through a run — the drain is the pressure (GDD §4.3/§4.7).
function LumenService:ResetWells()
    self.UsedWells = {}
end

-- ---------------------------------------------------------------------------
-- Recharge sources (action-based only; no passive regen, GDD §4.2)
-- ---------------------------------------------------------------------------

-- Server API: a Lumen Well grants +40 Lumen (v1 target). Used by the Well
-- touch handler (below) and later by the floor generator/entity delegations.
-- Returns true if the recharge applied.
function LumenService:RechargeFromWell(player: Player): boolean
    if not self:IsValidPlayer(player) then
        return false
    end
    self:AddLumen(CONFIG.WellRecharge)
    print(("[LumenService] %s drained a Lumen Well (+%d)."):format(player.Name, CONFIG.WellRecharge))
    return true
end

-- Server API: consume a Lumen Cell for +25 (v1 target). Client calls via RPC.
-- Returns "success" | "no_cells".
function LumenService:ConsumeCellForPlayer(player: Player): string
    if not self:IsValidPlayer(player) or (self.Cells[player] or 0) <= 0 then
        return "no_cells"
    end
    self.Cells[player] -= 1
    self.Client.CellCountChanged:Fire(player, self.Cells[player])
    self:AddLumen(CONFIG.CellRecharge)
    print(("[LumenService] %s consumed a Lumen Cell (+%d)."):format(player.Name, CONFIG.CellRecharge))
    return "success"
end

-- Server API for the (later) revive system: spends 30 Lumen from the pool.
-- Returns true only if the pool could afford it; callers must not grant a
-- revive on false. The revive system itself is a separate delegation.
function LumenService:SpendLumenForRevive(): boolean
    if self.LumenValue < CONFIG.ReviveCost then
        return false
    end
    self:SetLumen(self.LumenValue - CONFIG.ReviveCost)
    print(("[LumenService] Revive spent -%d Lumen."):format(CONFIG.ReviveCost))
    return true
end

-- ---------------------------------------------------------------------------
-- Flashlight (server side of the economy)
-- ---------------------------------------------------------------------------

-- Toggle a player's beam. Returns true when the server applied the state.
-- Rejected (false) when trying to switch ON while the squad is in Darkness —
-- beams are dead in Darkness (GDD §4.2).
function LumenService:SetFlashlightForPlayer(player: Player, on: boolean): boolean
    if not self:IsValidPlayer(player) then
        return false
    end
    on = on == true
    if on and self.InDarkness then
        return false
    end
    if self.FlashlightsOn[player] == on then
        return true -- idempotent: no spurious events
    end
    self.FlashlightsOn[player] = on
    self.Client.FlashlightChanged:Fire(player, on)
    return true
end

-- ---------------------------------------------------------------------------
-- Lumen Wells (world interactables)
-- ---------------------------------------------------------------------------

-- Public seam for the floor generator: call this when a Well is spawned so
-- touches recharge the pool. One use per Well (GDD §4.2).
-- NOTE (slice): the GDD's 5s channel is deferred — the touch grants the
-- recharge instantly for this step (pick-up-touch trigger per delegation).
function LumenService:RegisterWell(wellPart: BasePart)
    if self.UsedWells[wellPart] ~= nil then
        return
    end
    wellPart.Touched:Connect(function(hit: BasePart)
        if self.UsedWells[wellPart] then
            return
        end
        local player = Players:GetPlayerFromCharacter(hit.Parent)
        if not player then
            return
        end
        self.UsedWells[wellPart] = true
        if self:RechargeFromWell(player) then
            self:DepleteWell(wellPart)
        else
            self.UsedWells[wellPart] = nil
        end
    end)
end

-- Auto-register any Well parts placed in the placeholder scene.
function LumenService:RegisterWellsInWorkspace()
    for _, part in Workspace:GetDescendants() do
        if part:IsA("BasePart") and part.Name == "LumenWell" then
            self:RegisterWell(part)
        end
    end
end

function LumenService:DepleteWell(wellPart: BasePart)
    wellPart:SetAttribute("Depleted", true)
    local coreLight = wellPart:FindFirstChild("CoreLight")
    if coreLight and coreLight:IsA("PointLight") then
        coreLight.Brightness = 0
    end
    wellPart.Color = Color3.fromRGB(69, 69, 76)
end

-- ---------------------------------------------------------------------------
-- Read accessors (for other services / later delegations)
-- ---------------------------------------------------------------------------

function LumenService:GetLumenValue(): number
    return self.LumenValue
end

function LumenService:IsInDarkness(): boolean
    return self.InDarkness
end

function LumenService:GetFlashlightOn(player: Player): boolean
    return self.FlashlightsOn[player] == true
end

function LumenService:GetCellCount(player: Player): number
    return self.Cells[player] or 0
end

--- Max Lumen Cells a player can carry (GDD §4.1: 3 bought pre-run; §4.6 gear:
--- Ration Pack +1 slot, Long-Cell Carrier 3 -> 5). Enforced at pre-run buy
--- time (a later delegation) — the pre-run buy will clamp to this.
function LumenService:GetMaxCells(player: Player): number
    local max = CONFIG.BaseCellSlots
    if self.EconomyService ~= nil then
        if self.EconomyService:HasUpgrade(player, "ration_pack") then
            max += CONFIG.RationPackExtraSlots
        end
        if self.EconomyService:HasUpgrade(player, "long_cell_carrier") then
            max += CONFIG.LongCellExtraSlots
        end
    end
    return max
end

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

function LumenService:IsValidPlayer(player: Player): boolean
    return typeof(player) == "Instance" and player:IsA("Player") and player.Parent == Players
end

return LumenService
