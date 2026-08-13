--!strict
-- AtmosphereConfig — shared lighting rig values + Lumen↔world mapping (GDD §9).
-- Single source of truth for the atmosphere pass:
--   * LightingService (server) applies the base rig at startup (authoritative
--     baseline; Lighting replicates server → client) and refreshes floor-aware
--     fog when the floor changes.
--   * AtmosphereController (client) applies the same base locally and then
--     maps fog/exposure live from the Lumen pool ("the screen closes in").
-- The fog curve lives here so both sides agree at every Lumen value.

local AtmosphereConfig = {
	-- GDD §9 baseline: near-zero ambient — "zero ambient light beyond 0.05".
	-- The player's beam is the key light; every world fixture should look like
	-- it *should* be off. Emissives stay reserved for signs/Well cores/Warden.
	Base = {
		Ambient = Color3.fromRGB(8, 8, 10), -- ~0.03 (GDD §9 hard cap 0.05)
		OutdoorsAmbient = Color3.fromRGB(8, 8, 10),
		Brightness = 0, -- no sun/moon (ClockTime 0): lights only
		ClockTime = 0,
		ColorShift_Top = Color3.fromRGB(14, 16, 13), -- sickly green-beige cast (Tier 1)
		ColorShift_Bottom = Color3.fromRGB(4, 4, 7), -- cold shadow bias
		FogColor = Color3.fromRGB(2, 2, 3), -- near-black fog (GDD §9)
		FogStart = 24, -- GDD §9 reference at full Lumen, Floor 1
		FogEnd = 80,
		ExposureCompensation = 0,
		GlobalShadows = true,
	},
	-- Mobile/accessibility perf gate (GDD §9): volumetric Atmosphere fog is a
	-- later addition behind this flag; the slice ships distance fog only.
	VolumetricFogEnabled = false,
}

-- Lumen → world mapping (GDD §9 "Lumen↔world mapping — implement this"):
--   100 = normal beam world; 40 = visible vignette closing in; 0 = Darkness
--   near-black (~3-stud radius). Deeper floors are denser ("Fog: ... denser on
--   deep floors"). Returns clamped, playable values: fog never fully seals
--   (FogEnd ≥ 14) and exposure never crushes the beam (≥ -1.4).
function AtmosphereConfig:FogForLumen(lumen: number, floor: number): { FogStart: number, FogEnd: number, ExposureCompensation: number }
	local t = 1 - math.clamp(lumen, 0, 100) / 100 -- 0 = full light, 1 = Darkness
	local tighten = math.min(8, math.max(0, floor - 1)) -- deep floors denser
	return {
		FogStart = math.max(4, 24 - 20 * t - tighten * 0.4),
		FogEnd = math.max(14, 80 - 64 * t - tighten),
		ExposureCompensation = -1.4 * t, -- exposure drops as the light dies
	}
end

return AtmosphereConfig
