--!strict
-- LightingService — server-side atmosphere rig for LIGHTS OUT (GDD §9).
--
-- THE RIG (this pass):
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
-- WORLD-SPACE VFX (next pass, still this module): Warden gaze light stutter,
-- entity presence pulse, Darkness light drop, Lumen Well breathing. The
-- monitor loop below already exists so the VFX tick slots straight in.
--
-- Design notes:
--   * One 0.1s tick loop + a 0.5s floor monitor; the light list is rebuilt
--     ONLY when the floor folder changes (every light dies with a rebuild).
--   * Reads floor state from the floor folder attributes and LumenService
--     directly (both are server-side), so no other service needs changes.

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
	self._FloorFolder = nil -- last seen Workspace.Floors child (Folder)
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
--- refreshes the base fog for that floor. The VFX pass extends this with the
--- room-light/Well list rebuild. Cheap: one FindFirstChildOfClass per check.
function LightingService:_RescanFloor()
	local floorsFolder = Workspace:FindFirstChild("Floors")
	local folder = floorsFolder and floorsFolder:FindFirstChildOfClass("Folder") or nil
	if folder == self._FloorFolder then
		return
	end
	self._FloorFolder = folder
	if folder == nil then
		return
	end
	local floor = folder:GetAttribute("FloorNumber") or 1
	local fog = AtmosphereConfig:FogForLumen(100, floor)
	Lighting.FogStart = fog.FogStart
	Lighting.FogEnd = fog.FogEnd
	print(("[LightingService] Floor %d base fog: %.0f → %.0f"):format(floor, fog.FogStart, fog.FogEnd))
end

return LightingService
