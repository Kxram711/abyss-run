--!strict
-- LumenService — the shared squad Lumen pool (GDD §4.2).
-- Owns the 0–100 squad-wide light economy: passive drain (0.5 L/s on
-- Floor 1, ×1.12/floor), sprint tax, light-off toggle, Wells/Cells regen,
-- and the Darkness failure state. Lumen is armor/visibility/weapon in one.
-- Future client surface: LumenChanged + DarknessChanged signals (seams only).
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Knit = require(ReplicatedStorage.Packages.Knit)

local LumenService = Knit.CreateService {
	Name = "LumenService",
	Client = {},
}

function LumenService:KnitStart()
	-- No mechanics in the scaffold: hook reserved for the Lumen tick loop
	-- (drain/regen/Darkness transitions) wired in the gameplay slice.
end

return LumenService
