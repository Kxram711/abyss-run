--!strict
-- LIGHTS OUT — server entrypoint.
-- Requires every Knit service module (so each registers itself via
-- Knit.CreateService) before starting the Knit runtime.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Knit = require(ReplicatedStorage.Packages.Knit)

require(script.Parent.Services.LumenService)
require(script.Parent.Services.FloorService)
require(script.Parent.Services.EntityService)
require(script.Parent.Services.ArtifactService)
require(script.Parent.Services.ExtractionService)
require(script.Parent.Services.RunService)
require(script.Parent.Services.EconomyService)

Knit.Start():catch(warn)
