--!strict
-- ExtractionService — extract-or-push risk calls and banking (GDD §4.7).
-- Server-authoritative decision points, primitives only (no GUI this pass):
--
--   * STAIRWELL (FloorService's "StairwellDown", marked one-way DOWN): touch =
--     PUSH DOWN — AdvanceFloor() seals the floor above and gambles the run on
--     the next floor (§3.2 step 4 / §4.7). Per-run state resets the way the
--     GDD says: the floor rebuild destroys entities/artifacts/nodes (their
--     services resync), and Lumen Wells reset (fresh wells, one use each).
--   * EXTRACTION PAD ("ElevatorGate"): this pass places a primitive pad next
--     to the stairs in the stairwell room as the elevator stand-in. Touch =
--     EXTRACT — compute the §4.4 reward, bank Filaments per squad member
--     (co-op: every squad member banks the run reward, v1 target), end the
--     run as extracted.
--
-- DEFERRED (flagged for the lead, NOT this pass): the GDD's 10s elevator
-- warm-up with doubled spawn budget + converging threats (§4.7) — that needs
-- an EntityService spawn-budget hook and is out of this delegation's scope
-- ("no entity behavior changes"). F1's "free exit" is therefore the same
-- instant extract as every other floor for now.
--
-- Knit Comm surface (server -> client; NO GUI this pass):
--   FloorAdvanced(floor)         a player pushed down (floor-screen preview later)
--   ExtractionCompleted(results) the full loot-screen results (math reveal)

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Knit = require(ReplicatedStorage.Packages.Knit)

local CONFIG = {
    MonitorInterval = 0.5, -- floor-interaction wiring tick
    PadSize = Vector3.new(7, 1.5, 5),
    PadOffset = Vector3.new(0, 0, 9), -- beside the stairs, inside the stairwell room
    PadColor = Color3.fromRGB(64, 148, 160),
    PadLightColor = Color3.fromRGB(120, 230, 245),
    PadLightRange = 12,
}

local ExtractionService = Knit.CreateService {
    Name = "ExtractionService",
    Client = {
        FloorAdvanced = Knit.CreateSignal(), -- (floor: number)
        ExtractionCompleted = Knit.CreateSignal(), -- (results: any)
    },
}

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

function ExtractionService:KnitStart()
    self.FloorService = Knit.GetService("FloorService")
    self.RunService = Knit.GetService("RunService")
    self.ArtifactService = Knit.GetService("ArtifactService")
    self.EntityService = Knit.GetService("EntityService")
    self.LumenService = Knit.GetService("LumenService")
    self.EconomyService = Knit.GetService("EconomyService")

    -- Weak tables: keys are floor parts destroyed on every floor rebuild.
    self.WiredStairs = setmetatable({}, { __mode = "k" })
    self.WiredPads = setmetatable({}, { __mode = "k" })

    task.spawn(function()
        self:_MonitorLoop()
    end)
end

-- Wires the current floor's stairwell (PUSH) and places+wires the extraction
-- pad (EXTRACT). The floor folder is replaced on StartRun/AdvanceFloor, so
-- each new floor folder gets fresh wiring and a fresh pad.
function ExtractionService:_MonitorLoop()
    while true do
        task.wait(CONFIG.MonitorInterval)
        local floorsFolder = Workspace:FindFirstChild("Floors")
        local floorFolder = floorsFolder and floorsFolder:FindFirstChildOfClass("Folder") or nil
        if floorFolder == nil then
            continue
        end
        local floorNumber = floorFolder:GetAttribute("FloorNumber") or 1

        local stairs = floorFolder:FindFirstChild("StairwellDown", true)
        if stairs ~= nil and not self.WiredStairs[stairs] then
            self.WiredStairs[stairs] = true
            stairs.Touched:Connect(function(hit: BasePart)
                self:_OnStairTouched(stairs, hit)
            end)
        end

        local pad = floorFolder:FindFirstChild("ElevatorGate", true)
        if pad == nil then
            pad = self:_PlaceExtractionPad(floorFolder, floorNumber)
        end
        if pad ~= nil and not self.WiredPads[pad] then
            self.WiredPads[pad] = true
            pad.Touched:Connect(function(hit: BasePart)
                self:_OnPadTouched(pad, hit)
            end)
        end
    end
end

-- ---------------------------------------------------------------------------
-- World construction (elevator stand-in, primitives only)
-- ---------------------------------------------------------------------------

function ExtractionService:_PlaceExtractionPad(floorFolder: Folder, floor: number): BasePart?
    local stairs = floorFolder:FindFirstChild("StairwellDown", true)
    local pad = Instance.new("Part")
    pad.Name = "ElevatorGate"
    pad.Size = CONFIG.PadSize
    if stairs ~= nil then
        pad.Position = stairs.Position + CONFIG.PadOffset
    else
        pad.Position = Vector3.new(0, 0.75, 0) -- fallback; stairs are guaranteed by FloorService
    end
    pad.Anchored = true
    pad.CanCollide = true
    pad.Color = CONFIG.PadColor
    pad.Material = Enum.Material.Metal
    pad:SetAttribute("ExtractionPad", true)
    pad:SetAttribute("Floor", floor)

    local light = Instance.new("PointLight")
    light.Name = "PadLight"
    light.Color = CONFIG.PadLightColor
    light.Brightness = 1.4
    light.Range = CONFIG.PadLightRange
    light.Shadows = false
    light.Parent = pad

    if stairs ~= nil and stairs.Parent ~= nil then
        pad.Parent = stairs.Parent -- the stairwell room model: destroyed on rebuild
    else
        pad.Parent = floorFolder
    end
    return pad
end

-- ---------------------------------------------------------------------------
-- Touch decision points
-- ---------------------------------------------------------------------------

function ExtractionService:_PlayerFromHit(hit: BasePart): Player?
    return Players:GetPlayerFromCharacter(hit.Parent)
end

function ExtractionService:_OnStairTouched(stairs: BasePart, hit: BasePart)
    local player = self:_PlayerFromHit(hit)
    if not player then
        return
    end
    if stairs:GetAttribute("Used") then
        return -- sealed behind (§4.7: stairs are one-way)
    end
    stairs:SetAttribute("Used", true)
    local ok, reason = self:PushDown(player)
    if not ok then
        stairs:SetAttribute("Used", false)
    end
end

function ExtractionService:_OnPadTouched(pad: BasePart, hit: BasePart)
    local player = self:_PlayerFromHit(hit)
    if not player then
        return
    end
    if pad:GetAttribute("Used") then
        return
    end
    pad:SetAttribute("Used", true)
    local ok, _ = self:Extract(player)
    if not ok then
        pad:SetAttribute("Used", false)
    end
end

--- PUSH DOWN: descend one floor, committing the run (§3.2 step 4). Per-run
--- state resets the way the GDD says: the FloorService rebuild destroys the
--- old floor's entities/artifact nodes/wells, the Lumen Wells reset (fresh
--- parts, one use each), and Entity/Artifact services resync immediately.
function ExtractionService:PushDown(player: Player): (boolean, string?)
    if not self.RunService:IsRunActive() then
        return false, "not_in_run"
    end
    local newFloor = self.FloorService:AdvanceFloor()
    self.LumenService:ResetWells() -- new floor = fresh Wells
    self.ArtifactService:EnsureFloorSynced()
    self.EntityService:EnsureFloorSynced()
    self.Client.FloorAdvanced:FireAll(newFloor)
    print(("[ExtractionService] %s pushed down the stairs — now on floor %d."):format(player.Name, newFloor))
    return true, nil
end

--- EXTRACT: end the run, compute the §4.4 reward, bank it, and hand the
--- results to RunService for the terminal state transition + loot screen.
--- Any squad member touching the pad extracts the whole squad (shared carry).
function ExtractionService:Extract(player: Player): (boolean, string?, any?)
    if not self.RunService:IsRunActive() then
        return false, "not_in_run"
    end
    local floor = self.FloorService:GetCurrentFloor()
    local carry = self.ArtifactService:GetCarrySnapshot()
    local squad = self.RunService:GetSquad()
    local alive = self.RunService:GetSquadAliveCount()

    -- GDD §4.7: +25% if the whole squad extracts alive (0% if anyone was lost
    -- or left behind). Solo play gets Loner's Ledger (+10%).
    local squadAliveBonus = (#squad > 0 and alive >= #squad) and 1 or 0
    local lonerBonus = (#squad == 1) and 1 or 0
    local objectives = self.ArtifactService:GetObjectivesCompleted(floor)
    local reward = self.ArtifactService:ComputeRunReward(carry, squadAliveBonus, objectives, lonerBonus)

    -- Co-op banking: every squad member still present banks the run reward
    -- (v1 target — flagged to the lead; alternative is splitting the pot).
    local bankedTo: { any } = {}
    for _, member in ipairs(squad) do
        if member.Parent == Players then
            local balance = self.EconomyService:BankFilaments(member, reward.Total)
            table.insert(bankedTo, { Name = member.Name, Filaments = balance })
        end
    end

    local results = {
        FloorReached = floor,
        Artifacts = carry.Artifacts,
        SpecialSlot = carry.SpecialSlot,
        Breakdown = reward,
        BankedFilaments = reward.Total,
        SquadAlive = squadAliveBonus == 1,
        SquadSize = #squad,
        SquadAliveCount = alive,
        BankedTo = bankedTo,
    }

    self.RunService:FinishRunExtracted(results)
    self.ArtifactService:ClearCarry()
    self.Client.ExtractionCompleted:FireAll(results)
    print(("[ExtractionService] %s extracted on floor %d — %dF banked (%d artifact(s))."):format(
        player.Name, floor, reward.Total, #carry.Artifacts + (carry.SpecialSlot ~= nil and 1 or 0)
    ))
    return true, nil, results
end

return ExtractionService
