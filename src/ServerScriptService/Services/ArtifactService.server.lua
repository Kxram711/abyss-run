--!strict
-- ArtifactService — loot definitions, rarity, spawn, carry, and reward math
-- (GDD §4.4). Server-authoritative.
--
-- SCOPE (slice, §7):
--   * All 5 slice artifacts (Fuse Coils → The Bell) with the GDD's exact base
--     values and lore lines. Rarity IS the value — no stat rolls (§4.4).
--   * Deterministic per-floor spawns: node count (3–5, slice: all nodes real),
--     room picks, placement, and rarity rolls all flow from SeededRandom seeded
--     with the floor's FloorSeed (hash(run_seed, floor, facility_variant)) —
--     same run seed => same loot layout, every run.
--   * Rarity odds by floor from the GDD §4.4 table (rows at F1/F3/F5/F8/F12/
--     F15; floors between rows are linearly interpolated; beyond F15 clamps to
--     the F15 row). The slice has no Epic artifact, so an Epic roll re-rolls
--     (the Epic mass redistributes over the available rarities).
--   * Pickup by touch (no GUI this pass) into the SQUAD carry inventory.
--     The Bell occupies the special slot (§4.4); everything else uses the
--     regular slots (5, v1 target).
--   * Reward math — the exact §4.4/§4.7 formula:
--       Filaments = Σ(base values) × (1 + 0.25 × squad_alive_bonus)
--                   × (1 + 0.10 × floor_objectives_completed)
--     plus Loner's Ledger (§4.7: solo +10%).
--
-- Knit Comm surface (server -> client; NO GUI this pass):
--   ArtifactPickedUp(entry)      one artifact just joined the carry
--   CarryChanged(snapshot)       full carry snapshot on every change
--   RPC GetCarry()               current carry snapshot (late joiners / HUD)
--   RPC GetCatalog()             the 5 slice artifacts (loot screen / Archive)
--   Property Carry               carry snapshot (Observe for HUD bindings)

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Knit = require(ReplicatedStorage.Packages.Knit)
local SeededRandom = require(ReplicatedStorage.Shared.SeededRandom)
local RoomTemplates = require(script.Parent.Parent.Modules.RoomTemplates)

-- Tuning knobs. Values marked "(v1 target)" are starting points for playtest
-- validation; the structural rules above them are GDD spec, and the artifact
-- values / odds rows are the GDD's exact numbers (§4.4).
local CONFIG = {
    Artifacts = {
        -- GDD §4.4 slice list (exact values + lore).
        FuseCoils = { Name = "Fuse Coils", Rarity = "Common", BaseValue = 50, Lore = "The facility ran on stolen light.", Special = false },
        TestVials = { Name = "Test Vials", Rarity = "Uncommon", BaseValue = 150, Lore = "Specimens 1–247. All empty.", Special = false },
        StaffDataTapes = { Name = "Staff Data Tapes", Rarity = "Uncommon", BaseValue = 150, Lore = "Dr. Voss's last log is 9 hours long. It's mostly breathing.", Special = false },
        ContainmentCell = { Name = "Containment Cell (empty)", Rarity = "Rare", BaseValue = 450, Lore = "Labeled 'THE BELL'S BOX'. It rings when no one is near.", Special = false },
        TheBell = { Name = "The Bell", Rarity = "Mythic", BaseValue = 3500, Lore = "You cannot carry it and be quiet.", Special = true },
    },
    -- GDD §4.4 rarity odds by floor (percent). Floors between rows are
    -- linearly interpolated; floors below 1 clamp to F1, above 15 to F15.
    RarityOddsByFloor = {
        [1] = { Common = 60, Uncommon = 35, Rare = 5, Epic = 0, Mythic = 0 },
        [3] = { Common = 40, Uncommon = 40, Rare = 18, Epic = 2, Mythic = 0 },
        [5] = { Common = 25, Uncommon = 35, Rare = 30, Epic = 9, Mythic = 1 },
        [8] = { Common = 15, Uncommon = 30, Rare = 35, Epic = 17, Mythic = 3 },
        [12] = { Common = 8, Uncommon = 22, Rare = 35, Epic = 27, Mythic = 8 },
        [15] = { Common = 5, Uncommon = 15, Rare = 30, Epic = 32, Mythic = 18 },
    },
    -- GDD §4.4: 5–7 artifact nodes per floor, 3–5 real (junk nodes are full
    -- game). Slice: all nodes real => 3–5 nodes.
    NodeCountMin = 3,
    NodeCountMax = 5,
    NodeMargin = 3, -- studs from room walls when placing a node (v1 target)
    NodeCenterY = 1.2, -- stand height above the slab (slab top is Y = 0.5)
    CarryRegularSlots = 5, -- squad carry slots (v1 target; HUD shows these §7.1)
    CarrySpecialSlots = 1, -- The Bell's special slot (GDD §4.4)
    -- GDD §4.7 reward math (exact).
    RewardSquadAliveMultiplier = 0.25, -- +25% whole squad extracts alive
    RewardObjectiveMultiplier = 0.10, -- +10% per floor objective completed
    LonerLedgerMultiplier = 0.10, -- §4.7: solo play +10% (Loner's Ledger)
    MonitorInterval = 0.5, -- floor-change monitor tick (matches EntityService)
    RarityColors = {
        Common = Color3.fromRGB(168, 178, 188),
        Uncommon = Color3.fromRGB(96, 216, 160),
        Rare = Color3.fromRGB(150, 120, 255),
        Epic = Color3.fromRGB(255, 140, 70),
        Mythic = Color3.fromRGB(255, 210, 90),
    },
}

local RARITY_ORDER = { "Common", "Uncommon", "Rare", "Epic", "Mythic" }
local ODDS_FLOORS = { 1, 3, 5, 8, 12, 15 } -- table rows, ascending

local ArtifactService = Knit.CreateService {
    Name = "ArtifactService",
    Client = {
        ArtifactPickedUp = Knit.CreateSignal(), -- (entry)
        CarryChanged = Knit.CreateSignal(), -- (snapshot) fired on every carry change
        Carry = Knit.CreateProperty(nil), -- snapshot (Observe for HUD bindings)
    },
}

-- ---------------------------------------------------------------------------
-- Client-callable RPCs (Knit injects the calling Player as first arg)
-- ---------------------------------------------------------------------------

function ArtifactService.Client:GetCarry(player: Player)
    return ArtifactService:GetCarrySnapshot()
end

function ArtifactService.Client:GetCatalog(player: Player)
    return ArtifactService:GetCatalog()
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

function ArtifactService:KnitStart()
    self.RunService = Knit.GetService("RunService")
    self.Carry = {} -- regular slots: { CarryEntry }
    self.SpecialSlot = nil :: any? -- The Bell's special slot
    self.NextCarryId = 1
    self.CurrentFloorFolder = nil :: Folder?
    self.Nodes = {} -- { BasePart } on the current floor (for bookkeeping)

    self:_PublishCarry() -- HUD/late-joiners see a real (empty) snapshot immediately

    task.spawn(function()
        self:_MonitorLoop()
    end)
end

-- The floor monitor mirrors EntityService: FloorService replaces the floor
-- folder on StartRun/AdvanceFloor, so a new folder instance means: despawn the
-- old nodes (their parts are destroyed with the rebuild anyway) and spawn the
-- new floor's loot deterministically.
function ArtifactService:_MonitorLoop()
    while true do
        task.wait(CONFIG.MonitorInterval)
        self:EnsureFloorSynced()
    end
end

--- Public hook: run/floor lifecycle calls this right after a rebuild so loot
--- spawns immediately instead of waiting on the monitor tick.
function ArtifactService:EnsureFloorSynced()
    local floorsFolder = Workspace:FindFirstChild("Floors")
    local floorFolder = floorsFolder and floorsFolder:FindFirstChildOfClass("Folder") or nil
    if floorFolder == nil then
        if self.CurrentFloorFolder ~= nil then
            self.Nodes = {}
            self.CurrentFloorFolder = nil
        end
        return
    end
    if floorFolder == self.CurrentFloorFolder then
        return
    end
    self.Nodes = {}
    self.CurrentFloorFolder = floorFolder
    local floor = floorFolder:GetAttribute("FloorNumber") or 1
    local floorSeed = floorFolder:GetAttribute("FloorSeed") or 0
    self:_SpawnFloorNodes(floorFolder, floor, SeededRandom.new(floorSeed))
end

-- ---------------------------------------------------------------------------
-- Node spawning (deterministic: every roll from the floor-seeded RNG)
-- ---------------------------------------------------------------------------

function ArtifactService:_SpawnFloorNodes(floorFolder: Folder, floor: number, rng: any)
    local rooms = self:_CollectRooms(floorFolder)
    local candidates: { any } = {}
    for _, room in ipairs(rooms) do
        if room.Role ~= "spawn" then
            table.insert(candidates, room)
        end
    end
    if #candidates == 0 then
        candidates = rooms
    end

    local count = rng:NextInt(CONFIG.NodeCountMin, CONFIG.NodeCountMax)
    rng:Shuffle(candidates) -- distinct rooms, deterministic order
    local placed = 0
    for _, room in ipairs(candidates) do
        if placed >= count then
            break
        end
        local pos = self:_NodePosition(rng, room)
        local rarity = self:_RollRarity(rng, floor)
        local artifact = self:_ArtifactForRarity(rng, rarity)
        if artifact ~= nil then
            self:_SpawnNode(floorFolder, room, pos, artifact, floor)
            placed += 1
        end
    end
    print(("[ArtifactService] floor %d: %d artifact node(s) placed."):format(floor, placed))
end

function ArtifactService:_CollectRooms(floorFolder: Folder): { any }
    local rooms: { any } = {}
    for _, child in ipairs(floorFolder:GetChildren()) do
        if not child:IsA("Model") or not child.Name:match("^Room_") then
            continue
        end
        local templateName = child:GetAttribute("Template")
        local originX = child:GetAttribute("OriginX") or 0
        local originZ = child:GetAttribute("OriginZ") or 0
        local template: any = nil
        for _, t in ipairs(RoomTemplates) do
            if t.Name == templateName then
                template = t
                break
            end
        end
        if template ~= nil then
            table.insert(rooms, {
                Name = template.Name,
                Role = template.Role,
                Origin = Vector3.new(originX, 0, originZ),
                Size = template.Size,
                Template = template,
            })
        end
    end
    table.sort(rooms, function(a, b)
        return a.Origin.X < b.Origin.X
    end)
    return rooms
end

-- Deterministic interior point for a node (world coords), inset from walls.
function ArtifactService:_NodePosition(rng: any, room: any): Vector3
    local x = CONFIG.NodeMargin + rng:Next() * (room.Size.X - 2 * CONFIG.NodeMargin)
    local z = CONFIG.NodeMargin + rng:Next() * (room.Size.Z - 2 * CONFIG.NodeMargin)
    return Vector3.new(room.Origin.X + x, CONFIG.NodeCenterY, room.Origin.Z + z)
end

-- GDD §4.4 odds per floor: interpolate between the table rows.
function ArtifactService:GetRarityOdds(floor: number): { [string]: number }
    local f = math.clamp(floor, ODDS_FLOORS[1], ODDS_FLOORS[#ODDS_FLOORS])
    for i = 1, #ODDS_FLOORS do
        local rowFloor = ODDS_FLOORS[i]
        if f <= rowFloor then
            if f == rowFloor then
                return self:_CopyOdds(CONFIG.RarityOddsByFloor[rowFloor])
            end
            -- f sits between ODDS_FLOORS[i-1] and rowFloor: interpolate.
            local prevFloor = ODDS_FLOORS[math.max(1, i - 1)]
            local prev = CONFIG.RarityOddsByFloor[prevFloor]
            local curr = CONFIG.RarityOddsByFloor[rowFloor]
            local t = (f - prevFloor) / (rowFloor - prevFloor)
            local out = {}
            for _, rarity in ipairs(RARITY_ORDER) do
                out[rarity] = prev[rarity] + (curr[rarity] - prev[rarity]) * t
            end
            return out
        end
    end
    return self:_CopyOdds(CONFIG.RarityOddsByFloor[ODDS_FLOORS[#ODDS_FLOORS]])
end

function ArtifactService:_CopyOdds(odds: { [string]: number }): { [string]: number }
    local out = {}
    for k, v in pairs(odds) do
        out[k] = v
    end
    return out
end

-- Deterministic rarity roll for a floor. An Epic roll re-rolls: the slice has
-- no Epic artifact (§4.4 slice list), so the Epic mass redistributes over the
-- available rarities (ratios among them stay GDD-faithful).
function ArtifactService:_RollRarity(rng: any, floor: number): string
    local odds = self:GetRarityOdds(floor)
    for _ = 1, 10 do
        local roll = rng:Next() * 100
        local cumulative = 0
        for _, rarity in ipairs(RARITY_ORDER) do
            cumulative += odds[rarity]
            if roll < cumulative then
                if self:_HasArtifactOfRarity(rarity) then
                    return rarity
                end
                break -- unavailable rarity (Epic in the slice): re-roll
            end
        end
    end
    return "Common" -- deterministic fallback; unreachable with the slice tables
end

function ArtifactService:_HasArtifactOfRarity(rarity: string): boolean
    for _, def in pairs(CONFIG.Artifacts) do
        if def.Rarity == rarity then
            return true
        end
    end
    return false
end

function ArtifactService:_ArtifactForRarity(rng: any, rarity: string): any?
    local candidates: { any } = {}
    for _, def in pairs(CONFIG.Artifacts) do
        if def.Rarity == rarity then
            table.insert(candidates, def)
        end
    end
    if #candidates == 0 then
        return nil
    end
    return candidates[rng:NextInt(1, #candidates)]
end

--- Spawns one glowing artifact node (primitives only). Touch = pickup.
function ArtifactService:_SpawnNode(floorFolder: Folder, room: any, position: Vector3, artifact: any, floor: number)
    local part = Instance.new("Part")
    part.Name = "ArtifactNode"
    part.Size = Vector3.new(1, 1, 1)
    part.Position = position
    part.Anchored = true
    part.CanCollide = false -- touch trigger (same pattern as Lumen Wells)
    part.Material = Enum.Material.Neon
    part.Color = CONFIG.RarityColors[artifact.Rarity] or CONFIG.RarityColors.Common
    part:SetAttribute("ArtifactName", artifact.Name)
    part:SetAttribute("Rarity", artifact.Rarity)
    part:SetAttribute("BaseValue", artifact.BaseValue)
    part:SetAttribute("Floor", floor)

    local light = Instance.new("PointLight")
    light.Name = "NodeLight"
    light.Color = part.Color
    light.Brightness = 1
    light.Range = 9
    light.Shadows = false
    light.Parent = part

    part.Touched:Connect(function(hit: BasePart)
        self:_OnNodeTouched(part, artifact, hit)
    end)

    local roomModel = floorFolder:FindFirstChild("Room_" .. room.Name)
    if roomModel ~= nil then
        part.Parent = roomModel -- destroyed with the floor rebuild
    else
        part.Parent = floorFolder
    end
    table.insert(self.Nodes, part)
end

function ArtifactService:_OnNodeTouched(node: BasePart, artifact: any, hit: BasePart)
    local player = Players:GetPlayerFromCharacter(hit.Parent)
    if not player then
        return
    end
    if self.RunService:GetRunState() ~= "in-run" then
        return -- no looting outside a run
    end
    if node:GetAttribute("PickedUp") then
        return
    end
    local entry = self:AddToCarry(artifact)
    if entry == nil then
        return -- carry is full (the node stays for the squad to decide)
    end
    node:SetAttribute("PickedUp", true)
    node:Destroy()
    print(("[ArtifactService] %s picked up %s (%s, %dF)."):format(player.Name, entry.Name, entry.Rarity, entry.BaseValue))
end

-- ---------------------------------------------------------------------------
-- Squad carry inventory (shared; HUD reads it via Comm)
-- ---------------------------------------------------------------------------

function ArtifactService:_MakeCarryEntry(artifact: any, special: boolean): any
    local entry = {
        Id = self.NextCarryId,
        Name = artifact.Name,
        Rarity = artifact.Rarity,
        BaseValue = artifact.BaseValue,
        Lore = artifact.Lore,
        Special = special,
    }
    self.NextCarryId += 1
    return entry
end

--- Adds an artifact to the squad carry. Returns the entry on success, nil if
--- the relevant slots are full (node stays in the world).
function ArtifactService:AddToCarry(artifact: any): any?
    if artifact.Special then
        if self.SpecialSlot ~= nil then
            return nil
        end
        local entry = self:_MakeCarryEntry(artifact, true)
        self.SpecialSlot = entry
        self:_PublishCarry()
        self.Client.ArtifactPickedUp:FireAll(entry) -- squad-wide pickup toast (HUD)
        return entry
    end
    if #self.Carry >= CONFIG.CarryRegularSlots then
        return nil
    end
    local entry = self:_MakeCarryEntry(artifact, false)
    table.insert(self.Carry, entry)
    self:_PublishCarry()
    self.Client.ArtifactPickedUp:FireAll(entry) -- squad-wide pickup toast (HUD)
    return entry
end

--- Full snapshot of the squad carry (serializable — no Player refs).
function ArtifactService:GetCarrySnapshot(): any
    local total = 0
    for _, e in ipairs(self.Carry) do
        total += e.BaseValue
    end
    local specialEntry = self.SpecialSlot
    if specialEntry ~= nil then
        total += specialEntry.BaseValue
    end
    return {
        Artifacts = self.Carry,
        SpecialSlot = specialEntry,
        RegularSlotsUsed = #self.Carry,
        RegularSlotsMax = CONFIG.CarryRegularSlots,
        TotalValue = total,
    }
end

--- Clears the carry (run start / extract / wipe — GDD §3.2/§4.7).
function ArtifactService:ClearCarry()
    self.Carry = {}
    self.SpecialSlot = nil
    self:_PublishCarry()
end

function ArtifactService:_PublishCarry()
    local snapshot = self:GetCarrySnapshot()
    self.Client.CarryChanged:FireAll(snapshot)
    self.Client.Carry:Set(snapshot)
end

--- The 5 slice artifacts (loot screen / Archive later).
function ArtifactService:GetCatalog(): { any }
    local out = {}
    for _, def in pairs(CONFIG.Artifacts) do
        table.insert(out, {
            Name = def.Name,
            Rarity = def.Rarity,
            BaseValue = def.BaseValue,
            Lore = def.Lore,
            Special = def.Special,
        })
    end
    table.sort(out, function(a, b)
        return a.BaseValue < b.BaseValue
    end)
    return out
end

-- ---------------------------------------------------------------------------
-- Reward math — the exact GDD §4.4/§4.7 formula
-- ---------------------------------------------------------------------------

--- Floor objectives completed. SLICE: 0 — the generator objective (floors 3–5)
--- is a later delegation; the multiplier seam is live so the formula is exact.
function ArtifactService:GetObjectivesCompleted(floor: number): number
    return 0
end

--- Filaments = Σ(base values) × (1 + 0.25 × squad_alive_bonus)
---               × (1 + 0.10 × floor_objectives_completed) × (1 + 0.10 × loner)
--- Inputs: carry snapshot, squad_alive_bonus (0|1), objectives (0..n), loner
--- (0|1 — Loner's Ledger §4.7). Returns the full breakdown for the loot screen
--- reveal (item-by-item values, each multiplier, and the floored total).
function ArtifactService:ComputeRunReward(
    snapshot: any,
    squadAliveBonus: number,
    objectivesCompleted: number,
    lonerBonus: number
): any
    local baseSum = 0
    for _, e in ipairs(snapshot.Artifacts) do
        baseSum += e.BaseValue
    end
    if snapshot.SpecialSlot ~= nil then
        baseSum += snapshot.SpecialSlot.BaseValue
    end

    local aliveApplied = squadAliveBonus > 0 and 1 or 0
    local lonerApplied = lonerBonus > 0 and 1 or 0
    local aliveMultiplier = 1 + CONFIG.RewardSquadAliveMultiplier * aliveApplied
    local objectiveMultiplier = 1 + CONFIG.RewardObjectiveMultiplier * objectivesCompleted
    local lonerMultiplier = 1 + CONFIG.LonerLedgerMultiplier * lonerApplied
    local total = baseSum * aliveMultiplier * objectiveMultiplier * lonerMultiplier

    return {
        Artifacts = snapshot.Artifacts,
        SpecialSlot = snapshot.SpecialSlot,
        BaseSum = baseSum,
        SquadAliveBonus = aliveApplied,
        AliveMultiplier = aliveMultiplier,
        ObjectivesCompleted = objectivesCompleted,
        ObjectiveMultiplier = objectiveMultiplier,
        LonerBonus = lonerApplied,
        LonerMultiplier = lonerMultiplier,
        Total = math.floor(total + 0.001), -- Filaments are integers
    }
end

return ArtifactService
