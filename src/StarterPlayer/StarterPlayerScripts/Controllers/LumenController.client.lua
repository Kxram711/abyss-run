--!strict
-- LumenController — client mirror of the shared Lumen pool (GDD §9).
-- Will bind LumenService's LumenChanged/DarknessChanged to the HUD bar and
-- the lumen↔world brightness mapping (100 = normal beam world, 0 = Darkness
-- near-black vignette). HUD binding deferred to the UI delegation.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Knit = require(ReplicatedStorage.Packages.Knit)

local LumenController = Knit.CreateController {
	Name = "LumenController",
}

function LumenController:KnitStart()
	-- No mechanics in the scaffold: hook reserved for subscribing to the
	-- Lumen service and driving HUD/world presentation.
end

return LumenController
