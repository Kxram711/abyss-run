--!strict
-- AtmosphereController — client-side atmosphere (GDD §9 "screen closes in").
--
--   * Applies the shared base Lighting rig locally at startup — belt and
--     braces on top of LightingService's authoritative baseline (client
--     changes to Lighting are local-only, so this never fights the server).
--   * Lumen-mapped darkening: reads the Lumen pool (LumenService.Lumen, with
--     the current floor from RunService/ExtractionService) and maps the
--     world's fog + exposure through the shared AtmosphereConfig curve. This
--     is the WORLD-SPACE complement to RunHudController's screen vignette:
--       100 = normal beam world; 40 = visible tightening; 0 = Darkness
--       near-black (~3-stud radius). Clamped playable at every value.
--
-- NOT this controller's job: Warden gaze stutter (FlashlightController owns
-- the beam; LightingService stutters the room lights), audio (AudioController),
-- the HUD vignette (RunHudController). World light changes here are applied
-- on Lumen events only (the pool ticks at 0.5s) — no per-frame work.

local Players = game:GetService("Players")
local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Knit = require(ReplicatedStorage.Packages.Knit)
local AtmosphereConfig = require(ReplicatedStorage.Shared.AtmosphereConfig)

local AtmosphereController = Knit.CreateController {
	Name = "AtmosphereController",
	Lumen = 100.0,
	Floor = 1,
}

local function Log(msg: string)
	print("[AtmosphereController]", msg)
end

function AtmosphereController:KnitStart()
	local lumenService = Knit.GetService("LumenService")
	local runService = Knit.GetService("RunService")
	local extractionService = Knit.GetService("ExtractionService")

	-- Base rig applied locally (same values the server broadcasts; harmless
	-- redundancy that guarantees the mood even before/without server sync).
	self:_ApplyBaseLighting()

	-- Pool value → world mapping. Observe covers late joins; Changed covers
	-- live ticks (drain 0.5s, flashlight tax, Wells, Cells, gaze hits).
	lumenService.Lumen:Observe(function(value: number)
		self.Lumen = value
		self:_ApplyLumenMapping()
	end)
	lumenService.LumenChanged:Connect(function(value: number)
		self.Lumen = value
		self:_ApplyLumenMapping()
	end)

	-- Current floor: feeds the "denser on deep floors" fog component (GDD §9).
	runService.RunInfo:Observe(function(info: any)
		if type(info) == "table" and type(info.Floor) == "number" then
			self.Floor = info.Floor
			self:_ApplyLumenMapping()
		end
	end)
	extractionService.FloorAdvanced:Connect(function(floor: number)
		self.Floor = floor
		self:_ApplyLumenMapping()
	end)

	Log(("Started for %s"):format(Players.LocalPlayer.Name))
end

function AtmosphereController:_ApplyBaseLighting()
	local base = AtmosphereConfig.Base
	Lighting.Ambient = base.Ambient
	Lighting.OutdoorAmbient = base.OutdoorsAmbient
	Lighting.Brightness = base.Brightness
	Lighting.ClockTime = base.ClockTime
	Lighting.ColorShift_Top = base.ColorShift_Top
	Lighting.ColorShift_Bottom = base.ColorShift_Bottom
	Lighting.FogColor = base.FogColor
	Lighting.GlobalShadows = base.GlobalShadows
	-- FogStart/FogEnd/ExposureCompensation are owned by _ApplyLumenMapping.
end

--- The "screen closes in": fog tightens and exposure drops as the shared
--- Lumen pool falls (GDD §9). Same curve as the server's base refresh, so
--- the two agree at every Lumen value.
function AtmosphereController:_ApplyLumenMapping()
	local fog = AtmosphereConfig:FogForLumen(self.Lumen, self.Floor)
	Lighting.FogStart = fog.FogStart
	Lighting.FogEnd = fog.FogEnd
	Lighting.ExposureCompensation = fog.ExposureCompensation
end

return AtmosphereController
