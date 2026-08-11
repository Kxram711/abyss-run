--!strict
-- RunService — run lifecycle and squad state (GDD §2/§3 core loop).
-- Owns the run state machine (lobby → drop-in → descent → extract/wipe),
-- the run seed (fresh per run), squad membership (2–4, host-owned), and
-- the per-floor difficulty multipliers that gate the other services.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Knit = require(ReplicatedStorage.Packages.Knit)

local RunService = Knit.CreateService {
	Name = "RunService",
	Client = {},
}

function RunService:KnitStart()
	-- No mechanics in the scaffold: hook reserved for run start/end
	-- transitions and squad assembly.
end

return RunService
