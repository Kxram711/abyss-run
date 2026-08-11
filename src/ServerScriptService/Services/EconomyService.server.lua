--!strict
-- EconomyService — Filaments and permanent unlocks (GDD §4.6).
-- Owns the per-account Filaments bank (credited only on extraction), the
-- gear/floor-gate/cosmetic unlock catalog, carry-between-runs rules, and
-- DataStore persistence for player profiles.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Knit = require(ReplicatedStorage.Packages.Knit)

local EconomyService = Knit.CreateService {
	Name = "EconomyService",
	Client = {},
}

function EconomyService:KnitStart()
	-- No mechanics in the scaffold: hook reserved for profile load/save
	-- and unlock validation.
end

return EconomyService
