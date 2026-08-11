--!strict
-- ArtifactService — loot definitions, rarity, and reward math (GDD §4.4).
-- Owns the 5 slice artifacts (Fuse Coils → The Bell), the rarity table by
-- floor depth, and the exact extraction reward formula:
--   Filaments_banked = Σ(base values) × (1 + 0.25 × squad_alive_bonus)
--                     × (1 + 0.10 × floor_objectives_completed)
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Knit = require(ReplicatedStorage.Packages.Knit)

local ArtifactService = Knit.CreateService {
	Name = "ArtifactService",
	Client = {},
}

function ArtifactService:KnitStart()
	-- No mechanics in the scaffold: hook reserved for artifact node spawn
	-- math and the loot-screen reward breakdown.
end

return ArtifactService
