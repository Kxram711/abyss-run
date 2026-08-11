--!strict
-- RunHudController — run-state HUD surface (GDD §7.1 UI/UX).
-- Placeholder seam for the in-run HUD (Lumen bar, HP, artifact slots, cell
-- count), floor-screen drain-rate preview, and extract/push prompts.
-- UI screens themselves are owned by the UI/UX delegation; this controller
-- is where their data bindings will live.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Knit = require(ReplicatedStorage.Packages.Knit)

local RunHudController = Knit.CreateController {
	Name = "RunHudController",
}

function RunHudController:KnitStart()
	-- No mechanics in the scaffold: hook reserved for HUD screen wiring.
end

return RunHudController
