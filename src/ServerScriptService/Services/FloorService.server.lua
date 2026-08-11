--!strict
-- FloorService — deterministic seeded floor generation (GDD §4.3).
-- Owns hash(run_seed, floor_number, facility_variant) generation, the room
-- template library (6 slice templates), 6–9 room stitching, one-way
-- stairwells, elevator placement, Lumen Wells and artifact node placement.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Knit = require(ReplicatedStorage.Packages.Knit)

local FloorService = Knit.CreateService {
    Name = "FloorService",
    Client = {},
}

-- PLACEHOLDER seam for LumenService's floor-scaled drain (§4.2).
-- The seeded generator delegation (hash(run_seed, floor, variant)) replaces
-- this with the real current-floor lookup; until then the economy runs at
-- Floor 1 (passive 0.5 L/s).
local PLACEHOLDER_CURRENT_FLOOR = 1

function FloorService:GetCurrentFloor(): number
    return PLACEHOLDER_CURRENT_FLOOR
end

function FloorService:KnitStart()
    -- No mechanics in the scaffold: hook reserved for seed verification
    -- (sanity pass: reachability, stairwell/elevator, node counts).
end

return FloorService
