--!strict
-- EntityService — threat entities for LIGHTS OUT (GDD §4.5): the Wanderer
-- and The Warden. Server-authoritative AI; primitives-only visuals.
--
-- SCOPE (slice, §7):
--   * WANDERER: patrol -> investigate (alert cue) -> chase -> attack chain,
--     light-sensitive — a focused beam staggers it (2.5s) and drains +1.5 L/s
--     from the shared pool while focused (GDD §4.5: stagger-only via focused
--     beam; light is the only weapon).
--   * WARDEN: fixed patrol route per floor, slow inexorable approach (10
--     stud/s, never sprints), gaze punish (3s continuous LOS within 20 studs
--     -> -30 Lumen, once per floor, then it relocates), light-off sense
--     +50% ("it sees you better in the dark"). Cannot be damaged/staggered.
--   * DETERMINISM: every spawn/behavior roll flows from SeededRandom
--     instances seeded with the floor seed (FloorService's FloorSeed
--     attribute = hash(run_seed, floor, facility_variant)) — same run seed,
--     same spawn layout, every run.
--   * SPAWN PACING (GDD §4.5): the floor's budget arrives staggered over the
--     first ~60-90s, not all at once. NOTE: GDD wants the first Wanderer to
--     wait until the squad has seen a Lumen Well; LumenService exposes no
--     Well-seen event yet, so this pass uses CONFIG.Spawn.FirstWandererDelay
--     (v1 target) — wiring to a Well-seen signal is a later delegation.
--   * CLEANUP: entities are parented to the floor folder, so FloorService's
--     rebuild destroys the models; this service also stops their brains and
--     fires despawn signals when the floor folder is replaced (covers both
--     AdvanceFloor and StartRun).
--   * DAMAGE: no HP system in the slice. Wanderer attacks spend Lumen per
--     GDD §4.5 (-8). The Darkness-mode HP payload (20) is carried on the
--     ThreatHit signal for the future health delegation (flagged to Lead Dev).
--   * SIGHTLING: NOT implemented (GDD §7 — audio-only teaser in the slice).
--     Seam: _SightlingTeaserSeam() below.
--
-- Knit Comm surface (server -> client; NO GUI this pass):
--   EntitySpawned(entityId, kind, floor)
--   EntityStateChanged(entityId, kind, state, payload?)   patrol / investigate
--       (alert cue) / chase / attack / stagger / gaze / relocate ...
--   EntityDespawned(entityId, kind, reason)
--   ThreatHit(entityId, kind, player, lumenDamage, hpDamage)   hpDamage is the
--       GDD Darkness-mode payload (20) fired for the future health system
--   WardenGaze(player, flickerSeconds)   client VFX cue (visibility cut 40%,
--       GDD §4.5) — applied by a later client delegation

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Knit = require(ReplicatedStorage.Packages.Knit)
local SeededRandom = require(ReplicatedStorage.Shared.SeededRandom)
local RoomTemplates = require(script.Parent.Parent.Modules.RoomTemplates)

-- Tuning knobs (GDD §4.5 slice table). Values marked "(v1 target)" are
-- starting points for playtest validation; the structural rules are spec.
local CONFIG = {
    Wanderer = {
        WalkSpeed = 8, -- GDD §4.5
        ChaseSpeed = 18, -- slower than sprint (26), faster than walk (16)
        SightRange = 30, -- sight cone range (studs)
        SightConeHalfAngle = 60, -- 120-degree sight cone
        BeamSenseRange = 25, -- light-sense: your beam is visible from farther than you are
        NoiseRangeWalk = 15, -- walk noise radius (crouch 6 not implemented server-side yet)
        NoiseRangeSprint = 30, -- sprint noise radius (sprint system not in slice)
        AttackRange = 3.5, -- (v1 target) reach of the attack
        AttackWindup = 1.5, -- s of windup before the hit (GDD §4.5)
        AttackLumenDamage = 8, -- -8 Lumen per hit (GDD §4.2/§4.5)
        AttackHpDamageInDarkness = 20, -- GDD §4.2: threats hit HP directly in Darkness (no HP system in slice; carried on ThreatHit)
        AttackCooldown = 3, -- s between attacks (v1 target)
        ChaseDropTimeout = 10, -- s without sight before the chase drops (GDD §4.5)
        InvestigateTimeout = 8, -- s at the last-known spot before returning to patrol (v1 target)
        StaggerFocusTime = 1.0, -- s of continuous beam focus to stagger (GDD §4.5)
        StaggerDuration = 2.5, -- s the Wanderer is frozen (GDD §4.5)
        BeamFocusDrain = 1.5, -- +L/s drained from the pool while focusing (GDD §4.5)
        BeamFocusConeHalfAngle = 30, -- (v1 target) the beam must be this tight on the entity
    },
    Warden = {
        WalkSpeed = 10, -- never sprints — "it walks like it has all night" (GDD §4.5)
        SenseRange = 20, -- base detection/gaze range in studs (GDD §4.5)
        LightOffSenseMultiplier = 1.5, -- light-off sense +50% (GDD §4.1/§4.5)
        GazeHoldTime = 3.0, -- s of continuous LOS within range (GDD §4.5)
        GazeLumenCost = 30, -- -30 Lumen (GDD §4.2)
        GazeFlickerSeconds = 5, -- 5s light-flicker blindness (client VFX later)
        MemorySeconds = 6, -- keeps advancing toward the last-known spot after LOS breaks (v1 target)
    },
    Spawn = {
        FirstWandererDelay = 30, -- s after the floor builds (v1 target; Well-seen wiring deferred, see header)
        WandererSpawnSpread = 45, -- s across which the rest of the budget arrives (GDD §4.5: budget over 60-90s)
        WardenDelay = 45, -- s after the floor builds (v1 target)
        TickInterval = 0.2, -- AI tick (5/s)
        MonitorInterval = 0.5, -- floor-change monitor tick
        RoomMargin = 3, -- studs from room walls when picking spawn/waypoint points
        SightlingTeaserEnabled = false, -- NOT implemented (GDD §7); see _SightlingTeaserSeam
    },
}

-- Primitives-only visuals (GDD §9): dark concrete shapes; the ONLY emissive
-- material in the entity roster is the Warden's eyes (GDD §9's explicit
-- exception). The Wanderer's eyes are pale plastic — it reads in the dark
-- without violating the emissive budget.
local ENTITY_VISUALS = {
    Wanderer = {
        TorsoSize = Vector3.new(2.4, 2.8, 1.3),
        TorsoCenterY = 1.4, -- root sits at the stand point; torso center is +Y
        HeadSize = Vector3.new(1.4, 1.3, 1.4),
        HeadCenterY = 3.6,
        EyeSize = Vector3.new(0.26, 0.26, 0.12),
        EyeColor = Color3.fromRGB(96, 100, 108),
        EyeMaterial = Enum.Material.Plastic,
        BodyColor = Color3.fromRGB(13, 13, 16),
        BodyMaterial = Enum.Material.Concrete,
    },
    Warden = {
        TorsoSize = Vector3.new(3.4, 4.6, 1.8),
        TorsoCenterY = 2.3,
        HeadSize = Vector3.new(1.8, 1.7, 1.8),
        HeadCenterY = 5.4,
        EyeSize = Vector3.new(0.32, 0.32, 0.16),
        EyeColor = Color3.fromRGB(255, 226, 205),
        EyeMaterial = Enum.Material.Neon, -- GDD §9 exception: the Warden's eyes
        BodyColor = Color3.fromRGB(10, 10, 13),
        BodyMaterial = Enum.Material.Concrete,
    },
}

type RoomInfo = {
    Name: string,
    Role: string,
    Origin: Vector3,
    Size: Vector3,
    Template: any, -- RoomTemplates.RoomTemplate
}

type FloorState = {
    FloorNumber: number,
    FloorSeed: number,
    Folder: Folder,
    Rng: any, -- SeededRandom (floor-seeded, deterministic)
    Rooms: { RoomInfo },
    WandererBudget: number,
    SpawnPlan: { any }, -- { Kind, Room, Delay, LocalPos }
    WardenRoute: { Vector3 },
}

type Entity = {
    Id: number,
    Kind: string,
    Model: Model,
    Root: BasePart,
    FloorState: FloorState,
    Rng: any, -- SeededRandom (per-entity, deterministic)
    State: string,
    Facing: Vector3,
    Active: boolean,
    TargetPosition: Vector3,
    LastKnownPosition: Vector3?,
    CurrentRoomIndex: number,
    FocusTime: number,
    StaggerRemaining: number,
    PreStaggerState: string,
    AttackCooldown: number,
    WindupRemaining: number,
    AttackTarget: Player?,
    ChaseTimeout: number,
    InvestigateTimeout: number,
    StuckTime: number,
    Route: { Vector3 },
    RouteIndex: number,
    GazeTarget: Player?,
    GazeAccum: number,
    GazeUsed: boolean,
    ApproachRemaining: number,
}

local EntityService = Knit.CreateService {
    Name = "EntityService",
    Client = {
        EntitySpawned = Knit.CreateSignal(), -- (entityId, kind, floor)
        EntityStateChanged = Knit.CreateSignal(), -- (entityId, kind, state, payload?)
        EntityDespawned = Knit.CreateSignal(), -- (entityId, kind, reason)
        ThreatHit = Knit.CreateSignal(), -- (entityId, kind, player, lumenDamage, hpDamage)
        WardenGaze = Knit.CreateSignal(), -- (player, flickerSeconds)
    },
}

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

function EntityService:KnitStart()
    self.LumenService = Knit.GetService("LumenService")
    self.FloorService = Knit.GetService("FloorService")
    self.Entities = {} -- [entityId] -> Entity
    self.NextEntityId = 1
    self.ActiveFloor = nil :: FloorState?
    self.CurrentFloorFolder = nil :: Folder?

    task.spawn(function()
        self:_MonitorLoop()
    end)
    task.spawn(function()
        self:_TickLoop()
    end)
end

-- The floor monitor is the single source of truth for "the floor changed":
-- FloorService replaces the floor folder on StartRun/AdvanceFloor, so a new
-- folder instance (or a missing one) means cleanup + reschedule. Entities are
-- parented to the floor folder, so a rebuild already destroys their models;
-- this loop stops their brains and emits despawn signals.
function EntityService:_MonitorLoop()
    while true do
        task.wait(CONFIG.Spawn.MonitorInterval)
        self:EnsureFloorSynced()
    end
end

--- Public hook: the run/floor lifecycle calls this right after a rebuild so
--- spawns start immediately instead of waiting on the monitor tick. Mirrors
--- the monitor's logic exactly — no behavior change (spawn pacing is unchanged).
function EntityService:EnsureFloorSynced()
    local floorsFolder = Workspace:FindFirstChild("Floors")
    local floorFolder = floorsFolder and floorsFolder:FindFirstChildOfClass("Folder") or nil
    if floorFolder == nil then
        if self.ActiveFloor ~= nil then
            self:_CleanupAll("floor_gone")
        end
        return
    end
    if floorFolder ~= self.CurrentFloorFolder then
        self:_OnFloorChanged(floorFolder)
    end
end

function EntityService:_OnFloorChanged(floorFolder: Folder)
    self:_CleanupAll("floor_changed")

    local floor = floorFolder:GetAttribute("FloorNumber") or 1
    local floorSeed = floorFolder:GetAttribute("FloorSeed") or 0
    local difficulty = self.FloorService:GetFloorDifficulty(floor)
    local squadSize = #Players:GetPlayers() -- GDD §4.5: budget = 2 + squad_size, +1 every 3 floors
    local rng = SeededRandom.new(floorSeed)

    local state: FloorState = {
        FloorNumber = floor,
        FloorSeed = floorSeed,
        Folder = floorFolder,
        Rng = rng,
        Rooms = self:_CollectRooms(floorFolder),
        WandererBudget = difficulty.ThreatBudget + squadSize,
        SpawnPlan = {},
        WardenRoute = {},
    }
    -- Fixed patrol route for the Warden: the room line, out and back.
    for _, room in ipairs(state.Rooms) do
        table.insert(state.WardenRoute, self:_RoomCenter(room))
    end

    self.ActiveFloor = state
    self.CurrentFloorFolder = floorFolder
    self:_BuildSpawnPlan(state)

    task.spawn(function()
        self:_RunFloorSpawns(state)
    end)
end

-- ---------------------------------------------------------------------------
-- Spawn planning (deterministic: all rolls come from the floor-seeded RNG)
-- ---------------------------------------------------------------------------

function EntityService:_BuildSpawnPlan(state: FloorState)
    local rng = state.Rng
    -- Wanderers never materialize in the spawn lobby.
    local candidates: { RoomInfo } = {}
    for _, room in ipairs(state.Rooms) do
        if room.Role ~= "spawn" then
            table.insert(candidates, room)
        end
    end
    if #candidates == 0 then
        candidates = state.Rooms
    end

    for i = 1, state.WandererBudget do
        local room = candidates[rng:NextInt(1, #candidates)]
        local delay = CONFIG.Spawn.FirstWandererDelay
        if i > 1 then
            -- Stagger the rest of the budget across the first ~60-90s (GDD §4.5).
            local t = (i - 1) / math.max(1, state.WandererBudget - 1)
            delay = CONFIG.Spawn.FirstWandererDelay + CONFIG.Spawn.WandererSpawnSpread * t
        end
        table.insert(state.SpawnPlan, {
            Kind = "Wanderer",
            Room = room,
            Delay = delay,
            LocalPos = self:_RandomRoomPoint(rng, room),
        })
    end

    -- Warden presence per FloorService config (GDD §4.5: 100% F4-5 slice,
    -- 50% other F4+, 0 below F4). Appears far from spawn (stairwell side).
    local wardenWanted = rng:Next() < self.FloorService:GetFloorDifficulty(state.FloorNumber).WardenPresenceChance
    if wardenWanted then
        local farRoom = state.Rooms[#state.Rooms]
        if farRoom == nil then
            farRoom = state.Rooms[1]
        end
        table.insert(state.SpawnPlan, {
            Kind = "Warden",
            Room = farRoom,
            Delay = CONFIG.Spawn.WardenDelay,
            LocalPos = self:_RoomCenter(farRoom),
        })
    end

    table.sort(state.SpawnPlan, function(a, b)
        return a.Delay < b.Delay
    end)
end

function EntityService:_RunFloorSpawns(state: FloorState)
    local start = tick()
    for _, item in ipairs(state.SpawnPlan) do
        local elapsed = tick() - start
        while elapsed < item.Delay do
            task.wait(0.5)
            if state ~= self.ActiveFloor then
                return -- floor changed (advance / run restart): abort this plan
            end
            elapsed = tick() - start
        end
        if state ~= self.ActiveFloor then
            return
        end
        self:_SpawnEntity(item.Kind, state, item)
    end
end

function EntityService:_SpawnEntity(kind: string, state: FloorState, plan: any)
    local id = self.NextEntityId
    self.NextEntityId += 1

    local model = self:_BuildModel(kind)
    model.Name = ("%s_%d"):format(kind, id)
    model.Parent = state.Folder

    local visual = ENTITY_VISUALS[kind]
    local root = model.PrimaryPart :: BasePart
    local standPos = plan.LocalPos :: Vector3
    local torsoPos = standPos + Vector3.new(0, visual.TorsoCenterY, 0)
    local facing = Vector3.new(1, 0, 0)
    root.CFrame = CFrame.lookAt(torsoPos, torsoPos + facing)

    local entity: Entity = {
        Id = id,
        Kind = kind,
        Model = model,
        Root = root,
        FloorState = state,
        Rng = SeededRandom.new(SeededRandom.hash(("entity:%d:%d"):format(state.FloorSeed, id))),
        State = "PATROL",
        Facing = facing,
        Active = true,
        TargetPosition = standPos,
        LastKnownPosition = nil,
        CurrentRoomIndex = self:_RoomIndexAt(state, standPos),
        FocusTime = 0,
        StaggerRemaining = 0,
        PreStaggerState = "PATROL",
        AttackCooldown = 0,
        WindupRemaining = 0,
        AttackTarget = nil,
        ChaseTimeout = 0,
        InvestigateTimeout = 0,
        StuckTime = 0,
        Route = state.WardenRoute,
        RouteIndex = 1,
        GazeTarget = nil,
        GazeAccum = 0,
        GazeUsed = false,
        ApproachRemaining = 0,
    }

    if kind == "Warden" then
        -- Spawns at the far room; its fixed route walks it back toward spawn.
        entity.RouteIndex = #entity.Route
        local nextWp = entity.Route[1]
        if nextWp ~= nil then
            local d = nextWp - root.Position
            if d.Magnitude > 0.1 then
                entity.Facing = Vector3.new(d.X, 0, d.Z).Unit
                root.CFrame = CFrame.lookAt(root.Position, root.Position + entity.Facing)
            end
        end
    else
        self:_PickPatrolWaypoint(entity)
    end

    self.Entities[id] = entity
    self.Client.EntitySpawned:Fire(id, kind, state.FloorNumber)
    print(("[EntityService] %s #%d spawned on floor %d (%.0f, %.0f)"):format(kind, id, state.FloorNumber, standPos.X, standPos.Z))
end

-- ---------------------------------------------------------------------------
-- AI tick
-- ---------------------------------------------------------------------------

function EntityService:_TickLoop()
    while true do
        task.wait(CONFIG.Spawn.TickInterval)
        if self.ActiveFloor == nil then
            continue
        end
        local dt = CONFIG.Spawn.TickInterval
        for _, entity in pairs(self.Entities) do
            if entity.Active and entity.FloorState == self.ActiveFloor then
                -- Floor rebuild may have destroyed the model mid-tick; the
                -- monitor cleanup will emit the despawn signal.
                if entity.Root.Parent == nil then
                    entity.Active = false
                else
                    self:_TickEntity(entity, dt)
                end
            end
        end
        self:_SightlingTeaserSeam(dt)
    end
end

function EntityService:_TickEntity(entity: Entity, dt: number)
    if entity.Kind == "Warden" then
        self:_TickWarden(entity, dt)
    else
        self:_TickWanderer(entity, dt)
    end
end

-- ---------------------------------------------------------------------------
-- Wanderer: patrol -> investigate (alert cue) -> chase -> attack (GDD §4.5)
-- ---------------------------------------------------------------------------

function EntityService:_TickWanderer(entity: Entity, dt: number)
    local cfg = CONFIG.Wanderer

    -- Stagger (beam focus): frozen, top priority.
    if entity.StaggerRemaining > 0 then
        entity.StaggerRemaining -= dt
        if entity.StaggerRemaining <= 0 then
            self:_SetState(entity, entity.PreStaggerState)
        end
        return
    end

    -- Light interaction: a focused beam staggers the Wanderer and drains
    -- +1.5 L/s from the pool (GDD §4.5 — light is the only weapon).
    local focusedPlayer = self:_FindFocusedPlayer(entity)
    if focusedPlayer ~= nil then
        entity.FocusTime += dt
        if self.LumenService:GetLumenValue() > 0 then
            self.LumenService:SetLumen(self.LumenService:GetLumenValue() - cfg.BeamFocusDrain * dt)
        end
        if entity.FocusTime >= cfg.StaggerFocusTime then
            entity.PreStaggerState = entity.State
            entity.FocusTime = 0
            entity.StaggerRemaining = cfg.StaggerDuration
            self:_SetState(entity, "STAGGER")
            return
        end
    else
        entity.FocusTime = math.max(0, entity.FocusTime - dt * 1.5) -- focus decays when the beam leaves
    end

    entity.AttackCooldown = math.max(0, entity.AttackCooldown - dt)

    -- Detection: sight cone / light-sense / noise (GDD §4.5 detection model).
    local player, reason, pos, seen = self:_DetectWanderer(entity)
    if player ~= nil then
        entity.LastKnownPosition = pos
    end

    if entity.State == "PATROL" then
        if seen then
            self:_SetState(entity, "CHASE")
        elseif player ~= nil then
            entity.InvestigateTimeout = cfg.InvestigateTimeout
            self:_SetState(entity, "INVESTIGATE") -- alert cue (client audio hook later)
        else
            if self:_MoveToward(entity, entity.TargetPosition, cfg.WalkSpeed, dt) then
                self:_PickPatrolWaypoint(entity)
            end
        end
    elseif entity.State == "INVESTIGATE" then
        if seen then
            self:_SetState(entity, "CHASE")
        else
            entity.InvestigateTimeout -= dt
            if entity.InvestigateTimeout <= 0 then
                self:_SetState(entity, "PATROL")
            elseif self:_MoveToward(entity, entity.LastKnownPosition or entity.TargetPosition, cfg.WalkSpeed, dt) then
                self:_SetState(entity, "PATROL")
            end
        end
    elseif entity.State == "CHASE" then
        if seen then
            entity.ChaseTimeout = cfg.ChaseDropTimeout
            if entity.AttackCooldown <= 0 and (pos - entity.Root.Position).Magnitude <= cfg.AttackRange then
                entity.AttackTarget = player
                entity.WindupRemaining = cfg.AttackWindup
                self:_SetState(entity, "ATTACK")
            else
                self:_MoveToward(entity, pos, cfg.ChaseSpeed, dt)
            end
        else
            entity.ChaseTimeout -= dt
            if entity.ChaseTimeout <= 0 then
                -- Chase drops after 10s without sight (GDD §4.5).
                entity.InvestigateTimeout = cfg.InvestigateTimeout
                self:_SetState(entity, "INVESTIGATE")
            else
                self:_MoveToward(entity, entity.LastKnownPosition or entity.TargetPosition, cfg.WalkSpeed * 0.7, dt)
            end
        end
    elseif entity.State == "ATTACK" then
        entity.WindupRemaining -= dt
        if entity.WindupRemaining <= 0 then
            local target = entity.AttackTarget
            if target ~= nil and target.Character ~= nil then
                local hroot = target.Character:FindFirstChild("HumanoidRootPart")
                if hroot ~= nil and (hroot.Position - entity.Root.Position).Magnitude <= cfg.AttackRange + 3 then
                    self:_ApplyThreatDamage(entity, target, cfg.AttackLumenDamage)
                end
            end
            entity.AttackCooldown = cfg.AttackCooldown
            self:_SetState(entity, "CHASE")
        end
    end
end

-- Returns the player whose beam is currently focused on the entity (cone +
-- LOS + range), nearest first, or nil. Wanderer-only in practice.
function EntityService:_FindFocusedPlayer(entity: Entity): Player?
    local cfg = CONFIG.Wanderer
    local best: Player? = nil
    local bestDist = math.huge
    for _, player in ipairs(Players:GetPlayers()) do
        if not self.LumenService:GetFlashlightOn(player) then
            continue
        end
        local char = player.Character
        if char == nil then
            continue
        end
        local head = char:FindFirstChild("Head")
        if head == nil then
            continue
        end
        if self:_BeamOnEntity(head, entity.Root.Position, cfg.BeamSenseRange, cfg.BeamFocusConeHalfAngle, entity) then
            local d = (head.Position - entity.Root.Position).Magnitude
            if d < bestDist then
                bestDist = d
                best = player
            end
        end
    end
    return best
end

-- Wanderer detection (GDD §4.5): sight cone 30 / noise 15-30 / light-sense 25.
-- Returns (player, reason, position, hasSight). Best-scoring player wins.
function EntityService:_DetectWanderer(entity: Entity): (Player?, string?, Vector3?, boolean)
    local cfg = CONFIG.Wanderer
    local bestScore = 0
    local bestPlayer: Player? = nil
    local bestReason: string? = nil
    local bestPos: Vector3? = nil
    local bestSeen = false
    local entityPos = entity.Root.Position

    for _, player in ipairs(Players:GetPlayers()) do
        local char = player.Character
        if char == nil then
            continue
        end
        local hroot = char:FindFirstChild("HumanoidRootPart")
        if hroot == nil then
            continue
        end
        local targetPos = hroot.Position
        local delta = targetPos - entityPos
        local dist = delta.Magnitude
        local dir = dist > 0.01 and delta.Unit or entity.Facing
        local angle = math.acos(math.clamp(dir:Dot(entity.Facing), -1, 1))

        -- Sight (cone)
        if dist <= cfg.SightRange and angle <= math.rad(cfg.SightConeHalfAngle)
            and self:_HasLOS(entityPos, targetPos, entity) then
            local score = cfg.SightRange - dist
            if score > bestScore then
                bestScore, bestPlayer, bestReason, bestPos, bestSeen = score, player, "sight", targetPos, true
            end
        end
        -- Light-sense: a lit player is visible from farther than they are.
        if self.LumenService:GetFlashlightOn(player) and dist <= cfg.BeamSenseRange
            and self:_HasLOS(entityPos, targetPos, entity) then
            local score = cfg.BeamSenseRange - dist
            if score > bestScore then
                bestScore, bestPlayer, bestReason, bestPos, bestSeen = score, player, "light", targetPos, false
            end
        end
        -- Noise (movement-derived; crouch 6 is not implemented server-side yet)
        local speed = self:_PlayerSpeed(char)
        local noiseRange = 0
        if speed >= 20 then
            noiseRange = cfg.NoiseRangeSprint
        elseif speed > 0.5 then
            noiseRange = cfg.NoiseRangeWalk
        end
        if noiseRange > 0 and dist <= noiseRange and self:_HasLOS(entityPos, targetPos, entity) then
            local score = noiseRange - dist
            if score > bestScore then
                bestScore, bestPlayer, bestReason, bestPos, bestSeen = score, player, "noise", targetPos, false
            end
        end
    end

    if bestPlayer ~= nil then
        return bestPlayer, bestReason, bestPos, bestSeen
    end
    return nil, nil, nil, false
end

-- ---------------------------------------------------------------------------
-- Warden: fixed patrol route, slow inexorable approach, gaze punish (GDD §4.5)
-- ---------------------------------------------------------------------------

function EntityService:_TickWarden(entity: Entity, dt: number)
    local cfg = CONFIG.Warden

    -- Detection: a pressure sense (LOS + range; omnidirectional). Light-off
    -- targets are sensed from +50% further (GDD §4.1/§4.5).
    local targetPlayer, targetPos = self:_DetectWarden(entity)
    if targetPlayer ~= nil then
        entity.LastKnownPosition = targetPos
        entity.ApproachRemaining = cfg.MemorySeconds
        if entity.State ~= "APPROACH" then
            self:_SetState(entity, "APPROACH")
        end
    else
        entity.ApproachRemaining = math.max(0, entity.ApproachRemaining - dt)
        if entity.State == "APPROACH" and entity.ApproachRemaining <= 0 then
            self:_SetState(entity, "PATROL")
        end
    end

    if entity.State == "APPROACH" then
        -- Inexorable: walks at 10 stud/s at the last-known spot, never faster.
        self:_MoveToward(entity, targetPos or entity.LastKnownPosition or entity.TargetPosition, cfg.WalkSpeed, dt)
    elseif entity.State == "PATROL" then
        local wp = entity.Route[entity.RouteIndex]
        if wp ~= nil then
            if self:_MoveToward(entity, wp, cfg.WalkSpeed, dt) then
                entity.RouteIndex += 1
                if entity.RouteIndex > #entity.Route then
                    entity.RouteIndex = 1
                end
            end
        end
    end

    -- Gaze: 3s of continuous LOS within 20 studs -> -30 Lumen + flicker cue.
    -- Once per floor, then the Warden relocates (GDD §4.5).
    if not entity.GazeUsed then
        local gazePlayer = self:_GazeCandidate(entity)
        if gazePlayer ~= nil then
            if entity.GazeTarget ~= gazePlayer then
                entity.GazeTarget = gazePlayer
                entity.GazeAccum = 0
            end
            entity.GazeAccum += dt
            if entity.GazeAccum >= cfg.GazeHoldTime then
                self:_FireGaze(entity, gazePlayer)
            end
        else
            entity.GazeTarget = nil
            entity.GazeAccum = 0
        end
    end
end

-- Pressure sense: any player within range (light-off x1.5) with LOS.
function EntityService:_DetectWarden(entity: Entity): (Player?, Vector3?)
    local cfg = CONFIG.Warden
    local bestDist = math.huge
    local bestPlayer: Player? = nil
    local bestPos: Vector3? = nil
    local entityPos = entity.Root.Position

    for _, player in ipairs(Players:GetPlayers()) do
        local char = player.Character
        if char == nil then
            continue
        end
        local hroot = char:FindFirstChild("HumanoidRootPart")
        if hroot == nil then
            continue
        end
        local pos = hroot.Position
        local dist = (pos - entityPos).Magnitude
        local beamOn = self.LumenService:GetFlashlightOn(player)
        local range = cfg.SenseRange * (beamOn and 1 or cfg.LightOffSenseMultiplier)
        if dist <= range and dist < bestDist and self:_HasLOS(entityPos, pos, entity) then
            bestDist = dist
            bestPlayer = player
            bestPos = pos
        end
    end
    return bestPlayer, bestPos
end

-- Nearest player with continuous gaze eligibility (LOS within GazeRange).
function EntityService:_GazeCandidate(entity: Entity): Player?
    local cfg = CONFIG.Warden
    local best: Player? = nil
    local bestDist = math.huge
    local entityPos = entity.Root.Position + Vector3.new(0, 1.5, 0) -- from its head height

    for _, player in ipairs(Players:GetPlayers()) do
        local char = player.Character
        if char == nil then
            continue
        end
        local hroot = char:FindFirstChild("HumanoidRootPart")
        if hroot == nil then
            continue
        end
        local pos = hroot.Position
        local dist = (pos - entityPos).Magnitude
        if dist <= cfg.SenseRange and dist < bestDist and self:_HasLOS(entityPos, pos, entity) then
            bestDist = dist
            best = player
        end
    end
    return best
end

function EntityService:_FireGaze(entity: Entity, player: Player)
    local cfg = CONFIG.Warden
    self.LumenService:SetLumen(self.LumenService:GetLumenValue() - cfg.GazeLumenCost)
    self.Client.WardenGaze:FireAll(player, cfg.GazeFlickerSeconds)
    self:_SetState(entity, "GAZE", { Target = player.Name })
    entity.GazeUsed = true

    -- Relocate: teleport to a far room and resume the patrol route (GDD §4.5).
    local room = self:_PickFarRoom(entity)
    local pos = self:_RandomRoomPoint(entity.Rng, room)
    local visual = ENTITY_VISUALS[entity.Kind]
    local torsoPos = pos + Vector3.new(0, visual.TorsoCenterY, 0)
    entity.Root.CFrame = CFrame.lookAt(torsoPos, torsoPos + entity.Facing)
    self:_SetState(entity, "PATROL")
    self.Client.EntityStateChanged:FireAll(entity.Id, entity.Kind, "RELOCATED", { Room = room.Name })
    print(("[EntityService] Warden #%d gaze hit %s (-%d Lumen); relocated to %s"):format(entity.Id, player.Name, cfg.GazeLumenCost, room.Name))
end

function EntityService:_PickFarRoom(entity: Entity): RoomInfo
    local state = entity.FloorState
    local current = self:_RoomIndexAt(state, entity.Root.Position)
    local candidates: { RoomInfo } = {}
    for i, room in ipairs(state.Rooms) do
        if math.abs(i - current) >= 2 then
            table.insert(candidates, room)
        end
    end
    if #candidates == 0 then
        candidates = state.Rooms
    end
    return candidates[entity.Rng:NextInt(1, #candidates)]
end

-- ---------------------------------------------------------------------------
-- Damage / shared signals
-- ---------------------------------------------------------------------------

-- GDD §4.2: while the pool is above 0, threat attacks subtract Lumen, never
-- HP. In Darkness they hit HP (20) — no HP system exists in the slice, so the
-- HP payload rides the ThreatHit signal for the future health delegation.
function EntityService:_ApplyThreatDamage(entity: Entity, player: Player, lumenDamage: number)
    local lumen = self.LumenService:GetLumenValue()
    if lumen > 0 then
        self.LumenService:SetLumen(lumen - lumenDamage)
    end
    local inDarkness = self.LumenService:IsInDarkness()
    local hpDamage = inDarkness and CONFIG.Wanderer.AttackHpDamageInDarkness or 0
    self.Client.ThreatHit:FireAll(entity.Id, entity.Kind, player, lumenDamage, hpDamage)
    print(("[EntityService] %s #%d hit %s: -%d Lumen%s"):format(
        entity.Kind, entity.Id, player.Name, lumenDamage,
        hpDamage > 0 and (" / -%d HP (darkness, deferred)"):format(hpDamage) or ""
    ))
end

function EntityService:_SetState(entity: Entity, state: string, payload: any?)
    if entity.State == state then
        return
    end
    entity.State = state
    self.Client.EntityStateChanged:FireAll(entity.Id, entity.Kind, state, payload)
end

function EntityService:_CleanupAll(reason: string)
    for id, entity in pairs(self.Entities) do
        entity.Active = false
        if entity.Model and entity.Model.Parent ~= nil then
            entity.Model:Destroy()
        end
        self.Client.EntityDespawned:Fire(id, entity.Kind, reason)
    end
    self.Entities = {}
    self.ActiveFloor = nil
    self.CurrentFloorFolder = nil
end

-- ---------------------------------------------------------------------------
-- Movement (primitive pathing: straight-line + room-connector aware, no
-- navmesh — GDD §4.5 allows this for the slice)
-- ---------------------------------------------------------------------------

-- Advances the entity toward targetPos on the floor plane. Returns true when
-- the waypoint is reached (or the entity is boxed in for too long).
-- Wall handling: a short forward probe; when blocked, tries rotated headings
-- (wall-slide). No navmesh dependency.
function EntityService:_MoveToward(entity: Entity, targetPos: Vector3, speed: number, dt: number): boolean
    local root = entity.Root
    local origin = root.Position
    local delta = Vector3.new(targetPos.X - origin.X, 0, targetPos.Z - origin.Z)
    local dist = delta.Magnitude
    if dist < 0.75 then
        return true
    end
    local dir = delta / dist
    local params = self:_RayParams(entity)
    local probeY = origin.Y + 1.0
    local probeDist = math.min(speed * dt, 4) + 1.2
    local originY = Vector3.new(origin.X, probeY, origin.Z)

    local heading = dir
    if Workspace:Raycast(originY, dir * probeDist, params) ~= nil then
        local found = false
        for _, angleDeg in ipairs({ 35, -35, 70, -70, 110, -110 }) do
            local alt = CFrame.Angles(0, math.rad(angleDeg), 0) * dir
            if Workspace:Raycast(originY, alt * probeDist, params) == nil then
                heading = alt
                found = true
                break
            end
        end
        if not found then
            entity.StuckTime += dt
            if entity.StuckTime > 2 then
                entity.StuckTime = 0
                return true -- give up on this waypoint; caller re-rolls
            end
            return false
        end
    end
    entity.StuckTime = 0

    local move = math.min(speed * dt, 4)
    local nextPos = origin + heading * move
    entity.Facing = heading
    root.CFrame = CFrame.lookAt(nextPos, nextPos + heading)
    return false
end

-- Room-connector-aware patrol waypoint: stay in the current room or step to a
-- neighbor through a door slot (rooms are laid out in a line; the room graph
-- is derived from each template's DoorSlots so grid connectivity later slots
-- in without changes here).
function EntityService:_PickPatrolWaypoint(entity: Entity)
    local state = entity.FloorState
    local index = self:_RoomIndexAt(state, entity.Root.Position)
    entity.CurrentRoomIndex = index
    local room = state.Rooms[index]

    if entity.Rng:Next() < 0.55 then
        entity.TargetPosition = self:_RandomRoomPoint(entity.Rng, room)
    else
        local neighbors = self:_Neighbors(state, index)
        if #neighbors > 0 then
            entity.TargetPosition = self:_RandomRoomPoint(entity.Rng, neighbors[entity.Rng:NextInt(1, #neighbors)])
        else
            entity.TargetPosition = self:_RandomRoomPoint(entity.Rng, room)
        end
    end
end

function EntityService:_Neighbors(state: FloorState, index: number): { RoomInfo }
    local out: { RoomInfo } = {}
    local room = state.Rooms[index]
    if room == nil then
        return out
    end
    local hasEast, hasWest = false, false
    for _, slot in ipairs(room.Template.DoorSlots) do
        if slot.Side == "east" then
            hasEast = true
        elseif slot.Side == "west" then
            hasWest = true
        end
    end
    if hasEast and index + 1 <= #state.Rooms then
        table.insert(out, state.Rooms[index + 1])
    end
    if hasWest and index - 1 >= 1 then
        table.insert(out, state.Rooms[index - 1])
    end
    return out
end

-- ---------------------------------------------------------------------------
-- Geometry / room helpers
-- ---------------------------------------------------------------------------

function EntityService:_CollectRooms(floorFolder: Folder): { RoomInfo }
    local rooms: { RoomInfo } = {}
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

function EntityService:_RoomIndexAt(state: FloorState, pos: Vector3): number
    for i, room in ipairs(state.Rooms) do
        if pos.X >= room.Origin.X and pos.X <= room.Origin.X + room.Size.X
            and pos.Z >= room.Origin.Z and pos.Z <= room.Origin.Z + room.Size.Z then
            return i
        end
    end
    return 1
end

function EntityService:_RoomCenter(room: RoomInfo): Vector3
    return Vector3.new(room.Origin.X + room.Size.X / 2, 1.0, room.Origin.Z + room.Size.Z / 2)
end

-- Uniform random interior point for a room (world coords, stand height),
-- inset from the walls so entities don't materialize inside them.
function EntityService:_RandomRoomPoint(rng: any, room: RoomInfo): Vector3
    local margin = CONFIG.Spawn.RoomMargin
    local x = room.Origin.X + margin + rng:Next() * math.max(1, room.Size.X - margin * 2)
    local z = room.Origin.Z + margin + rng:Next() * math.max(1, room.Size.Z - margin * 2)
    return Vector3.new(x, 1.0, z)
end

-- ---------------------------------------------------------------------------
-- Sight / LOS helpers
-- ---------------------------------------------------------------------------

function EntityService:_HasLOS(from: Vector3, to: Vector3, entity: Entity?): boolean
    local params = self:_RayParams(entity)
    local result = Workspace:Raycast(from, to - from, params)
    -- Only world geometry blocks sight; hits on the entity's own model are fine.
    if result == nil then
        return true
    end
    return entity ~= nil and result.Instance:IsDescendantOf(entity.Model)
end

-- Is the player's beam actually on the entity (cone + LOS + range)?
function EntityService:_BeamOnEntity(head: BasePart, entityPos: Vector3, maxRange: number, coneHalfDeg: number, entity: Entity): boolean
    local look = head.CFrame.LookVector
    local beamOrigin = head.Position + look * 1.5
    local toEntity = entityPos - beamOrigin
    local dist = toEntity.Magnitude
    if dist > maxRange then
        return false
    end
    local angle = math.acos(math.clamp(toEntity.Unit:Dot(look), -1, 1))
    return angle <= math.rad(coneHalfDeg) and self:_HasLOS(beamOrigin, entityPos, entity)
end

-- Raycast params: exclude the entity's own model and all player characters so
-- sight/light/patrol probes read through bodies but not walls.
function EntityService:_RayParams(entity: Entity?): RaycastParams
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    local filter: { any } = {}
    if entity ~= nil and entity.Model ~= nil then
        table.insert(filter, entity.Model)
    end
    for _, player in ipairs(Players:GetPlayers()) do
        if player.Character ~= nil then
            table.insert(filter, player.Character)
        end
    end
    params.FilterDescendantsInstances = filter
    return params
end

function EntityService:_PlayerSpeed(char: Model): number
    local hum = char:FindFirstChildOfClass("Humanoid")
    if hum == nil then
        return 0
    end
    -- MoveDirection is a unit vector (0..1 magnitude); walk speed scales it.
    return hum.WalkSpeed * hum.MoveDirection.Magnitude
end

-- ---------------------------------------------------------------------------
-- Sightling teaser seam (GDD §7) — NOT IMPLEMENTED, audio-only in the slice.
-- ---------------------------------------------------------------------------
-- The slice ships the Sightling as an audio-only tease: whispers when the
-- squad is in Darkness (no entity, no damage, no signals). The audio
-- delegation should hook here when it lands — this stub keeps the seam
-- discoverable so it is not re-invented.
function EntityService:_SightlingTeaserSeam(dt: number)
    if not CONFIG.Spawn.SightlingTeaserEnabled then
        return
    end
    -- FUTURE: when self.LumenService:IsInDarkness() and a player is present,
    -- fire an audio-only whisper cue (panning both channels, GDD §9) from a
    -- dark room; no Sightling entity, no damage, no state changes.
end

-- ---------------------------------------------------------------------------
-- Read accessors (for later delegations: extraction warm-up, events, tests)
-- ---------------------------------------------------------------------------

function EntityService:GetActiveFloor(): number?
    if self.ActiveFloor == nil then
        return nil
    end
    return self.ActiveFloor.FloorNumber
end

-- Lightweight live snapshot for other systems (no references to internals).
function EntityService:GetEntities(): { { Id: number, Kind: string, State: string, Floor: number, Position: Vector3 } }
    local out = {}
    for _, entity in pairs(self.Entities) do
        if entity.Active and entity.Root.Parent ~= nil then
            table.insert(out, {
                Id = entity.Id,
                Kind = entity.Kind,
                State = entity.State,
                Floor = entity.FloorState.FloorNumber,
                Position = entity.Root.Position,
            })
        end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- Model construction (primitives only; no marketplace assets)
-- ---------------------------------------------------------------------------

function EntityService:_BuildModel(kind: string): Model
    local v = ENTITY_VISUALS[kind]
    local model = Instance.new("Model")
    model:SetAttribute("Kind", kind)

    local function makePart(name: string, size: Vector3, color: Color3, material: Enum.Material): Part
        local part = Instance.new("Part")
        part.Name = name
        part.Size = size
        part.Color = color
        part.Material = material
        part.Anchored = true
        part.CanCollide = false
        part.CanQuery = false
        part.CastShadow = true
        part.TopSurface = Enum.SurfaceType.Smooth
        part.BottomSurface = Enum.SurfaceType.Smooth
        return part
    end

    local torso = makePart("Torso", v.TorsoSize, v.BodyColor, v.BodyMaterial)
    local head = makePart("Head", v.HeadSize, v.BodyColor, v.BodyMaterial)
    head.CFrame = CFrame.new(0, v.HeadCenterY - v.TorsoCenterY, 0)

    local eyeZ = -(v.HeadSize.Z / 2 + 0.02) -- slightly proud of the front face
    local eyeL = makePart("EyeL", v.EyeSize, v.EyeColor, v.EyeMaterial)
    local eyeR = makePart("EyeR", v.EyeSize, v.EyeColor, v.EyeMaterial)
    eyeL.CFrame = CFrame.new(-v.HeadSize.X * 0.28, v.HeadSize.Y * 0.1, eyeZ)
    eyeR.CFrame = CFrame.new(v.HeadSize.X * 0.28, v.HeadSize.Y * 0.1, eyeZ)

    -- Weld chain: moving the (anchored) torso carries the welded parts.
    local function weld(parent: BasePart, child: BasePart)
        local w = Instance.new("WeldConstraint")
        w.Part0 = parent
        w.Part1 = child
        w.Parent = child
    end
    weld(torso, head)
    weld(head, eyeL)
    weld(head, eyeR)

    model.PrimaryPart = torso
    torso.Parent = model
    head.Parent = model
    eyeL.Parent = model
    eyeR.Parent = model
    return model
end

return EntityService
