--!strict
-- LightingService — server-side atmosphere rig for LIGHTS OUT (GDD §9).
--
-- THE RIG:
--   * Applies the shared base Lighting config at startup — near-zero ambient,
--     near-black fog: "the facility ate its own light". Server-authoritative:
--     Lighting replicates server → client, so every client gets the baseline
--     before its own AtmosphereController takes over the Lumen-mapped curve.
--   * Refreshes floor-aware base fog whenever the floor folder is replaced
--     (FloorService rebuilds on StartRun/AdvanceFloor) via the shared
--     AtmosphereConfig curve at full Lumen (100) — deeper floors are denser
--     (GDD §9). The client's AtmosphereController re-maps the SAME curve live
--     from the Lumen pool; client Lighting changes are local-only, so the two
--     never fight.
--
-- WORLD-SPACE VFX (primitives only; complements RunHudController's screen
-- effects — no duplication):
--   * WardenGaze flicker: when an entity enters GAZE, stutter EVERY room light
--     on the floor for ~1.6s — the light-bulb-fail the Warden's stare causes
--     (GDD §4.5 "5s light-flicker blindness"; §9 "light-bulb-fail stutter").
--     Capped to match the HUD overlay's 1.6s. Squad-wide.
--   * Entity presence: on CHASE/INVESTIGATE, a slow dim-pulse on lights near
--     the entity ("the facility knows"). Cheap: no per-frame allocations —
--     one cached light list, arithmetic only in the tick.
--   * Darkness sting: while the pool is at 0, all room lights surge down to
--     embers; they surge back on recovery (GDD §4.2/§9). Darkness is polled
--     from LumenService (0.1s cadence = imperceptible latency), so LumenService
--     needs no changes.
--   * Lumen Well breathing: the Well's CoreLight gently pulses until the Well
--     is depleted (LumenService:DepleteWell sets the Depleted attribute and
--     Brightness 0 — the pulse respects that and hands the light over).
--
-- Events come in through an EntityService state listener (registered below):
-- the Comm RemoteSignal is client-only, so a server listener is the clean seam.
-- All animation runs in ONE 0.1s tick loop over a cached light list, rebuilt
-- only when the floor folder is replaced. No per-frame allocations.

local Workspace = game:GetService("Workspace")
local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Knit = require(ReplicatedStorage.Packages.Knit)
local AtmosphereConfig = require(ReplicatedStorage.Shared.AtmosphereConfig)

local TICK = 0.1 -- VFX animation tick (10/s)
local MONITOR_INTERVAL = 0.5 -- floor rebuild check cadence

local LightingService = Knit.CreateService {
    Name = "LightingService",
    Client = {},
}

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

function LightingService:KnitStart()
    self.FloorService = Knit.GetService("FloorService")
    self.LumenService = Knit.GetService("LumenService")
    self._FloorFolder = nil -- last seen Workspace.Floors child (Folder)
    self._Lights = {} -- { Light: PointLight, Base: number, Current: number, Position: Vector3 }
    self._Wells = {} -- { Well: BasePart, Core: PointLight?, Base: number }
    self._Presence = {} -- [entityId] -> { Pos: Vector3, Until: number }
    self._GazeUntil = 0 -- os.clock() until the gaze stutter ends

    -- Server-side seam for entity state transitions (see header). EntityService
    -- is not KnitStart-ed yet at this point; the listener setter only writes a
    -- field, so registration order is safe either way.
    local entityService = Knit.GetService("EntityService")
    if entityService ~= nil and entityService.SetStateListener ~= nil then
        entityService:SetStateListener(function(entity: any, state: string, _payload: any?)
            self:_OnEntityState(entity, state)
        end)
    end

    self:_ApplyBaseLighting()
    self:_RescanFloor()

    task.spawn(function()
        self:_Loop()
    end)
    print("[LightingService] Atmosphere rig applied — near-zero ambient, near-black fog.")
end

function LightingService:_Loop()
    local monitorAccum = 0
    while true do
        task.wait(TICK)
        monitorAccum += TICK
        if monitorAccum >= MONITOR_INTERVAL then
            monitorAccum = 0
            self:_RescanFloor()
        end
        self:_TickLights()
        self:_TickWells()
    end
end

-- ---------------------------------------------------------------------------
-- Entity state listener (VFX triggers)
-- ---------------------------------------------------------------------------

--- WardenGaze flicker + entity presence pulse. Triggered from the server-side
--- listener EntityService calls on every state transition.
function LightingService:_OnEntityState(entity: any, state: string)
    if state == "GAZE" then
        -- Warden's stare: the floor's lights fail for ~1.6s (HUD overlay cap).
        self._GazeUntil = os.clock() + AtmosphereConfig.Flicker.GazeDuration
        return
    end
    if state == "CHASE" or state == "INVESTIGATE" then
        local root = entity.Root
        if root ~= nil then
            self._Presence[entity.Id] = {
                Pos = root.Position,
                Until = os.clock() + AtmosphereConfig.Presence.Duration,
            }
        end
    end
end

-- ---------------------------------------------------------------------------
-- Base rig + floor-aware fog
-- ---------------------------------------------------------------------------

--- Applies the GDD §9 baseline. Runs once at startup; the per-floor fog
--- refresh keeps the base curve's floor component current.
function LightingService:_ApplyBaseLighting()
    local base = AtmosphereConfig.Base
    Lighting.Ambient = base.Ambient
    Lighting.OutdoorAmbient = base.OutdoorsAmbient
    Lighting.Brightness = base.Brightness
    Lighting.ClockTime = base.ClockTime
    Lighting.ColorShift_Top = base.ColorShift_Top
    Lighting.ColorShift_Bottom = base.ColorShift_Bottom
    Lighting.FogColor = base.FogColor
    Lighting.FogStart = base.FogStart
    Lighting.FogEnd = base.FogEnd
    Lighting.ExposureCompensation = base.ExposureCompensation
    Lighting.GlobalShadows = base.GlobalShadows
end

--- Detects a floor rebuild (new folder instance = StartRun/AdvanceFloor) and
--- refreshes base fog + the cached light/Well lists for the new floor. The old
--- floor's parts are destroyed by FloorService, so stale entries die here.
function LightingService:_RescanFloor()
    local floorsFolder = Workspace:FindFirstChild("Floors")
    local folder = floorsFolder and floorsFolder:FindFirstChildOfClass("Folder") or nil
    if folder == self._FloorFolder then
        return
    end
    self._FloorFolder = folder
    self._Presence = {} -- entities are rebuilt per floor; pulses don't carry over
    self._GazeUntil = 0
    self._Lights = {}
    self._Wells = {}
    if folder == nil then
        return
    end

    local floor = folder:GetAttribute("FloorNumber") or 1
    local fog = AtmosphereConfig:FogForLumen(100, floor)
    Lighting.FogStart = fog.FogStart
    Lighting.FogEnd = fog.FogEnd

    -- Cache every room point light (LightAnchor parts + the stairwell marker).
    -- Well cores are excluded here — the Well breathing loop owns those.
    for _, desc in folder:GetDescendants() do
        if desc:IsA("PointLight") then
            local parent = desc.Parent
            if parent ~= nil and parent:IsA("BasePart") and parent.Name ~= "LumenWell" then
                table.insert(self._Lights, {
                    Light = desc,
                    Base = desc.Brightness,
                    Current = desc.Brightness,
                    Position = parent.Position,
                })
            end
        elseif desc:IsA("BasePart") and desc.Name == "LumenWell" then
            local core = desc:FindFirstChild("CoreLight")
            local coreLight = if core ~= nil and core:IsA("PointLight") then core else nil
            table.insert(self._Wells, {
                Well = desc,
                Core = coreLight,
                Base = if coreLight ~= nil then coreLight.Brightness else 0,
            })
        end
    end
    print(("[LightingService] Floor %d: %d room lights, %d Wells cached."):format(floor, #self._Lights, #self._Wells))
end

-- ---------------------------------------------------------------------------
-- VFX tick (all room-light animation in one pass, 10/s)
-- ---------------------------------------------------------------------------

function LightingService:_TickLights()
    local now = os.clock()
    local cfg = AtmosphereConfig
    local inDarkness = self.LumenService:IsInDarkness()
    local gazeActive = now < self._GazeUntil
    local lights = self._Lights

    for i = 1, #lights do
        local entry = lights[i]
        local target = 1

        -- Warden gaze: irregular light-bulb-fail stutter (per-tick RNG only —
        -- no tables, no allocations).
        if gazeActive then
            if math.random() < cfg.Flicker.GazeOnChance then
                target = 1
            else
                target = math.random() * cfg.Flicker.GazeMaxCut
            end
        end

        -- Darkness: everything drops to embers (GDD §4.2 — the light is gone).
        if inDarkness then
            target = math.min(target, cfg.Darkness.LightMultiplier)
        end

        -- Entity presence: slow dim-pulse on lights near the entity.
        for _, pulse in pairs(self._Presence) do
            if now < pulse.Until then
                local d = (entry.Position - pulse.Pos).Magnitude
                if d < cfg.Presence.Radius then
                    local falloff = 1 - math.clamp(d / cfg.Presence.Radius, 0, 1)
                    local wave = 0.5 + 0.5 * math.sin(now * cfg.Presence.PulseRate)
                    -- Sine dip: full brightness at the wave peak, dimmed toward
                    -- MinMultiplier at the trough; stronger near the entity.
                    local pulseMult = 1 - (1 - cfg.Presence.MinMultiplier) * falloff * (1 - wave)
                    if pulseMult < target then
                        target = pulseMult
                    end
                end
            end
        end

        -- Smooth toward target: fast into dark (surge-out), gentle back (restore).
        local current = entry.Current
        local rate = if target < current then cfg.Darkness.SurgeInRate else cfg.Darkness.SurgeOutRate
        local next = current + (target - current) * rate
        if math.abs(next - current) > 0.001 then
            entry.Current = next
            entry.Light.Brightness = entry.Base * next
        end
    end

    -- Prune expired presence pulses (after the loop — never mid-iteration).
    for id, pulse in pairs(self._Presence) do
        if now >= pulse.Until then
            self._Presence[id] = nil
        end
    end
end

--- Lumen Well breathing: gentle pulse on the CoreLight until depleted, then
--- hand the light to LumenService's deplete (Brightness stays 0).
function LightingService:_TickWells()
    local now = os.clock()
    local cfg = AtmosphereConfig.Well
    for i = 1, #self._Wells do
        local entry = self._Wells[i]
        local core = entry.Core
        if core == nil then
            continue
        end
        if entry.Well:GetAttribute("Depleted") == true then
            if core.Brightness ~= 0 then
                core.Brightness = 0
            end
            continue
        end
        local wave = 0.5 + 0.5 * math.sin(now * cfg.PulseRate)
        core.Brightness = entry.Base * (cfg.PulseMin + (cfg.PulseMax - cfg.PulseMin) * wave)
    end
end

return LightingService
