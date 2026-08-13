--!strict
-- LIGHTS OUT — client entrypoint.
-- Requires every Knit controller module (so each registers itself via
-- Knit.CreateController) before starting the Knit runtime.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Knit = require(ReplicatedStorage.Packages.Knit)

require(script.Parent.Controllers.LumenController)
require(script.Parent.Controllers.FlashlightController)
require(script.Parent.Controllers.RunHudController)
require(script.Parent.Controllers.AtmosphereController)
require(script.Parent.Controllers.AudioController)

Knit.Start():catch(warn)
