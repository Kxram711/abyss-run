--!strict
-- ExtractionService — extract-or-push risk calls and banking (GDD §4.7).
-- Owns elevator warm-up (10s hold with converging threats, F1 = free exit),
-- the extract decision points, loot banking on extraction, and wipe
-- consequences (lose run loot + spent consumables; permanent progress safe).
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Knit = require(ReplicatedStorage.Packages.Knit)

local ExtractionService = Knit.CreateService {
	Name = "ExtractionService",
	Client = {},
}

function ExtractionService:KnitStart()
	-- No mechanics in the scaffold: hook reserved for the elevator warm-up
	-- state machine and reward banking on extract.
end

return ExtractionService
