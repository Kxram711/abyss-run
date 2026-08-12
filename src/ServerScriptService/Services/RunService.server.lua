--!strict
-- RunService — run lifecycle and squad state (GDD §3.2/§4.7).
-- Owns the run state machine:
--
--   lobby ──StartRun──▶ in-run ──extract (elevator pad)──▶ extracted
--                              └────wipe (squad lost / future HP)────▶ wiped
--   extracted/wiped ──StartRun──▶ in-run (run it back, §3.2)
--
--   * StartRun(fresh_seed): reseeds FloorService (rebuilds Floor 1), resets
--     the Lumen pool + Wells, clears the carry, and triggers entity/artifact
--     floor sync so spawns start immediately (not on the monitor tick).
--   * Squad = whoever is in the server this pass (friend lobby is a later
--     delegation). Squad is snapshotted at StartRun; members lost mid-run
--     (disconnect) reduce the squad-alive bonus. If every squad member is
--     lost, the run is a wipe (GDD §4.7: lose run loot only — permanent
--     unlocks/banked Filaments are never touched).
--
-- Knit Comm surface (server -> client; NO GUI this pass):
--   RunStateChanged(state, payload?)   "lobby" | "in-run" | "extracted" |
--       "wiped" — payload carries results (reward breakdown / wipe reason)
--   Property RunState                  current state string
--   Property RunInfo                   { RunId, Seed, Floor, SquadSize,
--       SquadAlive, SquadLost, Squad } snapshot (Observe for lobby/HUD)
--   RPC StartRun(seed?)                starts a fresh run (anyone this pass)
--   RPC GetRunState()                  current RunInfo

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Knit = require(ReplicatedStorage.Packages.Knit)

local LOBBY = "lobby"
local IN_RUN = "in-run"
local EXTRACTED = "extracted"
local WIPED = "wiped"

local RunService = Knit.CreateService {
    Name = "RunService",
    Client = {
        RunStateChanged = Knit.CreateSignal(), -- (state: string, payload: any?)
        RunState = Knit.CreateProperty(LOBBY),
        RunInfo = Knit.CreateProperty(nil), -- { RunId, Seed, Floor, SquadSize, SquadAlive, SquadLost, Squad }
    },
}

-- ---------------------------------------------------------------------------
-- Client-callable RPCs (Knit injects the calling Player as first arg)
-- ---------------------------------------------------------------------------

function RunService.Client:StartRun(player: Player, seed: number?)
    return RunService:StartRun(seed)
end

function RunService.Client:GetRunState(player: Player)
    return RunService:_BuildRunInfo()
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

function RunService:KnitStart()
    self.State = LOBBY
    self.RunId = 0
    self.Seed = 0
    self.Squad = {} -- { Player } snapshot at run start (squad = server players this pass)
    self.SquadLost = {} -- [Player] -> true (left the server mid-run)
    self.SquadAliveCount = 0
    self.FloorService = Knit.GetService("FloorService")
    self.LumenService = Knit.GetService("LumenService")
    self.ArtifactService = Knit.GetService("ArtifactService")
    self.EntityService = Knit.GetService("EntityService")

    Players.PlayerRemoving:Connect(function(player)
        self:_OnPlayerLeaving(player)
    end)

    self:_PublishState(LOBBY)
    print("[RunService] idle — lobby. StartRun() to drop the squad.")
end

-- ---------------------------------------------------------------------------
-- Run lifecycle
-- ---------------------------------------------------------------------------

--- Starts a fresh run. Accepts an explicit seed (shared seed runs later) or
--- rolls a fresh one. Returns { Started, Reason?, RunId?, Seed? }.
function RunService:StartRun(seed: number?): any
    if self.State == IN_RUN then
        return { Started = false, Reason = "run_in_progress" }
    end

    self.Seed = seed or math.random(1, 2147483647)
    self.RunId += 1

    -- Rebuild the world from Floor 1 (places rooms + stairwell + Lumen Well).
    self.FloorService:StartRun(self.Seed)
    -- Fresh shared pool + fresh Wells (GDD §3.2 step 2).
    self.LumenService:ResetForRun()
    -- The run's loot starts empty; new nodes spawn deterministically.
    self.ArtifactService:ClearCarry()
    self.ArtifactService:EnsureFloorSynced()
    self.EntityService:EnsureFloorSynced()

    -- Squad snapshot: whoever is in the server this pass (friend lobby later).
    self.Squad = {}
    self.SquadLost = {}
    for _, player in Players:GetPlayers() do
        table.insert(self.Squad, player)
    end
    self.SquadAliveCount = #self.Squad

    self.State = IN_RUN
    self:_PublishState(IN_RUN, self:_BuildRunInfo())
    print(("[RunService] RUN #%d started (seed %d) — floor 1, squad of %d."):format(self.RunId, self.Seed, #self.Squad))
    return { Started = true, RunId = self.RunId, Seed = self.Seed }
end

--- Terminal transition: extraction (called by ExtractionService after banking).
--- Payload is the full loot-screen results (GDD §4.4 math reveal).
function RunService:FinishRunExtracted(results: any)
    if self.State ~= IN_RUN then
        return
    end
    self.State = EXTRACTED
    self:_PublishState(EXTRACTED, results)
    print(("[RunService] RUN #%d extracted — %dF banked."):format(self.RunId, results.BankedFilaments or 0))
end

--- Terminal transition: wipe (squad lost / future HP system). Loses the run
--- loot only — banked Filaments, gear, unlocks are never touched (§4.7).
function RunService:WipeRun(reason: string)
    if self.State ~= IN_RUN then
        return
    end
    local lost = self.ArtifactService:GetCarrySnapshot()
    self.ArtifactService:ClearCarry()
    self.State = WIPED
    self:_PublishState(WIPED, {
        Reason = reason,
        FloorReached = self.FloorService:GetCurrentFloor(),
        LostArtifacts = lost,
    })
    print(("[RunService] RUN #%d WIPED (%s) — carried loot lost, bank is safe."):format(self.RunId, reason))
end

-- ---------------------------------------------------------------------------
-- Read accessors (other services / later delegations)
-- ---------------------------------------------------------------------------

function RunService:GetRunState(): string
    return self.State
end

function RunService:IsRunActive(): boolean
    return self.State == IN_RUN
end

function RunService:GetSquad(): { Player }
    return self.Squad
end

function RunService:GetSquadAliveCount(): number
    return self.SquadAliveCount
end

-- ---------------------------------------------------------------------------
-- Squad loss handling (GDD §4.7 squad-alive bonus / wipe)
-- ---------------------------------------------------------------------------

function RunService:_OnPlayerLeaving(player: Player)
    if self.State ~= IN_RUN then
        return
    end
    if self.SquadLost[player] then
        return
    end
    local inSquad = false
    for _, member in ipairs(self.Squad) do
        if member == player then
            inSquad = true
            break
        end
    end
    if not inSquad then
        return
    end

    self.SquadLost[player] = true
    self.SquadAliveCount = math.max(0, self.SquadAliveCount - 1)
    print(("[RunService] %s lost mid-run (squad alive %d/%d)."):format(player.Name, self.SquadAliveCount, #self.Squad))

    local remaining = 0
    for _, member in ipairs(self.Squad) do
        if not self.SquadLost[member] then
            remaining += 1
        end
    end
    if remaining == 0 then
        self:WipeRun("squad_lost")
    else
        self:_PublishState(IN_RUN, self:_BuildRunInfo())
    end
end

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

function RunService:_BuildRunInfo(): any
    local squadNames: { string } = {}
    for _, member in ipairs(self.Squad) do
        table.insert(squadNames, member.Name)
    end
    return {
        State = self.State,
        RunId = self.RunId,
        Seed = self.Seed,
        Floor = self.FloorService:GetCurrentFloor(),
        SquadSize = #self.Squad,
        SquadAlive = self.SquadAliveCount,
        SquadLost = #self.Squad - self.SquadAliveCount,
        Squad = squadNames,
    }
end

function RunService:_PublishState(state: string, payload: any?)
    self.Client.RunStateChanged:FireAll(state, payload)
    self.Client.RunState:Set(state)
    self.Client.RunInfo:Set(self:_BuildRunInfo())
end

return RunService
