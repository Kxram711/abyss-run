--!strict
-- FloorService — deterministic seeded floor generation (GDD §4.3), pass 1.
--
-- State: CurrentFloor starts at 1. StartRun(seed) reseeds + resets to Floor 1
-- and rebuilds; AdvanceFloor() increments + rebuilds; GetCurrentFloor()
-- returns the real state (LumenService's floor-scaled drain reads it).
--
-- Generation (first-pass simplified — no grid connectivity yet):
--   * 6 primitive room templates (Modules/RoomTemplates), one of each per
--     floor, laid out as a deterministic line along +X with 8-stud connector
--     gaps; the spawn room opens the line, the generator bay closes it.
--   * Deterministic per-floor seed: hash(run_seed, floor, facility_variant).
--     Same run seed => same layout on every floor, every run.
--   * One stairwell part per floor, marked one-way DOWN (extraction/descent
--     logic is a later delegation).
--   * GetFloorDifficulty(floor) exposes v1-target difficulty config for the
--     entity delegation (threat budget, Warden presence, drain multiplier).
--   * NO entities, NO artifacts, NO extraction logic, NO HUD this pass.
--
-- The retired static PlaceholderRoom is gone: the Workspace is now built
-- entirely at runtime under a Workspace.Floors folder (Floor_<n> per floor).
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local Knit = require(ReplicatedStorage.Packages.Knit)
local SeededRandom = require(ReplicatedStorage.Shared.SeededRandom)
local RoomTemplates = require(script.Parent.Parent.Modules.RoomTemplates)

local WALL_THICKNESS = 1
local CEILING_COLOR = Color3.fromRGB(20, 20, 23)
local DOOR_GAP = 8 -- studs between rooms in the line layout
local DEFAULT_RUN_SEED = 1 -- world boots on deterministic Floor 1 until RunService starts a real run
local FACILITY_VARIANT = 1 -- GDD §4.3 re-roll target; fixed this pass

local FloorService = Knit.CreateService {
	Name = "FloorService",
	Client = {},
	CurrentFloor = 1,
	RunSeed = DEFAULT_RUN_SEED,
	FacilityVariant = FACILITY_VARIANT,
	FloorsFolder = nil, -- Workspace.Floors, created in KnitStart
}

--- Reseeds the run and resets to Floor 1, rebuilding the world.
function FloorService:StartRun(seed: number)
	self.RunSeed = math.floor(seed)
	self.FacilityVariant = FACILITY_VARIANT
	self.CurrentFloor = 1
	self:_BuildFloor(self.CurrentFloor)
end

--- Descends to the next floor and rebuilds the world.
function FloorService:AdvanceFloor(): number
	self.CurrentFloor += 1
	self:_BuildFloor(self.CurrentFloor)
	return self.CurrentFloor
end

--- Real current floor (not a placeholder).
function FloorService:GetCurrentFloor(): number
	return self.CurrentFloor
end

--- Per-floor difficulty config, v1 targets (GDD §4.2/§4.5). The entity
--- delegation consumes this when placing threats on a floor.
function FloorService:GetFloorDifficulty(floor: number)
	return {
		Floor = floor,
		LumenDrainMultiplier = 1.12 ^ (floor - 1), -- §4.2: ×1.12 per floor deeper
		ThreatBudget = 2 + math.floor((floor - 1) / 3), -- §4.5: base 2 (squad_size added by entity delegation), +1 every 3 floors
		WardenPresenceChance = if floor >= 4 and floor <= 5 then 1.0 -- §4.5: slice guarantee F4–F5
			elseif floor >= 10 then 1.0
			elseif floor >= 4 then 0.5
			else 0.0,
		EntityDensity = 0.6 + 0.05 * (floor - 1), -- (v1 target) placeholder: threats per 100 sq-studs; tuning left to entity delegation
	}
end

function FloorService:KnitStart()
	self.FloorsFolder = Instance.new("Folder")
	self.FloorsFolder.Name = "Floors"
	self.FloorsFolder.Parent = Workspace
	-- Boot on a deterministic Floor 1 so the world is never empty. The run
	-- lifecycle (RunService) will call StartRun with a fresh seed when a run
	-- begins (future delegation).
	self:StartRun(DEFAULT_RUN_SEED)
end

--- Per-floor seed: same run seed + floor + variant => same layout, always.
function FloorService:_FloorSeed(floor: number): number
	return SeededRandom.hash(string.format("%d:%d:%d", self.RunSeed, floor, self.FacilityVariant))
end

function FloorService:_BuildFloor(floor: number)
	if self.FloorsFolder == nil then
		return -- not started yet
	end
	-- Replace the previous floor wholesale (the floor is fresh every run).
	for _, child in ipairs(self.FloorsFolder:GetChildren()) do
		child:Destroy()
	end

	local rng = SeededRandom.new(self:_FloorSeed(floor))
	local floorFolder = Instance.new("Folder")
	floorFolder.Name = "Floor_" .. tostring(floor)
	floorFolder.Parent = self.FloorsFolder
	floorFolder:SetAttribute("FloorNumber", floor)
	floorFolder:SetAttribute("RunSeed", self.RunSeed)
	floorFolder:SetAttribute("FloorSeed", self:_FloorSeed(floor))
	floorFolder:SetAttribute("FacilityVariant", self.FacilityVariant)

	-- Deterministic room order: the spawn room opens the line, the generator
	-- bay (stairwell) closes it; the four middle templates are shuffled.
	local spawnTemplate: RoomTemplates.RoomTemplate? = nil
	local stairwellTemplate: RoomTemplates.RoomTemplate? = nil
	local middle: { RoomTemplates.RoomTemplate } = {}
	for _, template in ipairs(RoomTemplates) do
		if template.Role == "spawn" then
			spawnTemplate = template
		elseif template.Role == "stairwell" then
			stairwellTemplate = template
		else
			table.insert(middle, template)
		end
	end
	assert(spawnTemplate ~= nil and stairwellTemplate ~= nil, "RoomTemplates must define one spawn room and one stairwell room")

	local roomOrder: { RoomTemplates.RoomTemplate } = { spawnTemplate }
	rng:Shuffle(middle)
	for _, template in ipairs(middle) do
		table.insert(roomOrder, template)
	end
	table.insert(roomOrder, stairwellTemplate)

	-- Line layout along +X with DOOR_GAP connector gaps.
	local cursorX = 0
	local origins: { Vector3 } = {}
	for _, template in ipairs(roomOrder) do
		local origin = Vector3.new(cursorX, 0, 0)
		table.insert(origins, origin)
		self:_InstantiateRoom(floorFolder, template, origin)
		cursorX += template.Size.X + DOOR_GAP
	end

	-- One-way-down stairwell in the closing room (generator bay).
	self:_InstantiateStairwell(floorFolder, stairwellTemplate, origins[#origins], floor)
end

--- Instantiates one template room: slab, ceiling, walled sides with door-slot
--- gaps, spawn locations (spawn room only), props, and dim lighting.
function FloorService:_InstantiateRoom(floorFolder: Folder, template: RoomTemplates.RoomTemplate, origin: Vector3)
	local size = template.Size
	local height = size.Y

	local room = Instance.new("Model")
	room.Name = "Room_" .. template.Name
	room.Parent = floorFolder
	room:SetAttribute("Template", template.Name)
	room:SetAttribute("OriginX", origin.X)
	room:SetAttribute("OriginZ", origin.Z)

	local centerX = origin.X + size.X / 2
	local centerZ = origin.Z + size.Z / 2

	-- Floor slab (top at Y = 0.5, matching the old PlaceholderRoom).
	local floorPart = self:_MakePart("Floor", Vector3.new(size.X, 1, size.Z), Vector3.new(centerX, 0, centerZ), template.FloorColor, Enum.Material.Concrete)
	floorPart.Parent = room

	-- Ceiling.
	local ceiling = self:_MakePart("Ceiling", Vector3.new(size.X, 1, size.Z), Vector3.new(centerX, height, centerZ), CEILING_COLOR, Enum.Material.Concrete)
	ceiling.Parent = room

	-- Sides, split into segments around door slots so connector gaps read as
	-- openings (primitives only; grid connectivity is a later pass).
	local sideDefs = {
		{ Side = "north", Size = Vector3.new(size.X, height, WALL_THICKNESS), Pos = Vector3.new(centerX, height / 2, origin.Z + size.Z) },
		{ Side = "south", Size = Vector3.new(size.X, height, WALL_THICKNESS), Pos = Vector3.new(centerX, height / 2, origin.Z) },
		{ Side = "east", Size = Vector3.new(WALL_THICKNESS, height, size.Z), Pos = Vector3.new(origin.X + size.X, height / 2, centerZ) },
		{ Side = "west", Size = Vector3.new(WALL_THICKNESS, height, size.Z), Pos = Vector3.new(origin.X, height / 2, centerZ) },
	}
	for _, def in ipairs(sideDefs) do
		self:_BuildWall(room, def.Side, def.Size, def.Pos, template.DoorSlots, template.WallColor)
	end

	-- Spawn locations (spawn room only).
	if template.Role == "spawn" then
		for i, point in ipairs(template.SpawnPoints) do
			local spawn = Instance.new("SpawnLocation")
			spawn.Name = "FacilitySpawn_" .. tostring(i)
			spawn.Position = origin + point
			spawn.Anchored = true
			spawn.Neutral = true
			spawn.Duration = 0
			spawn.Parent = room
		end
	end

	-- Props (crates, desks, generator…).
	for _, prop in ipairs(template.Props) do
		local part = self:_MakePart(prop.Name, prop.Size, origin + prop.Position, prop.Color, prop.Material)
		part.Parent = room
	end

	-- Dim lighting: PointLight on an invisible anchored anchor part.
	for _, light in ipairs(template.Lights) do
		local anchor = Instance.new("Part")
		anchor.Name = "LightAnchor_" .. light.Name
		anchor.Size = Vector3.new(0.5, 0.5, 0.5)
		anchor.Position = origin + light.Position
		anchor.Anchored = true
		anchor.CanCollide = false
		anchor.Transparency = 1
		local pointLight = Instance.new("PointLight")
		pointLight.Name = light.Name
		pointLight.Color = light.Color
		pointLight.Brightness = light.Brightness
		pointLight.Range = light.Range
		pointLight.Shadows = false
		pointLight.Parent = anchor
		anchor.Parent = room
	end
end

--- Builds one wall side, splitting it into segments around any door slot on
--- that side (a solid wall with a centered gap; two segments per slot).
function FloorService:_BuildWall(
	room: Model,
	side: string,
	size: Vector3,
	position: Vector3,
	doorSlots: { RoomTemplates.DoorSlot },
	wallColor: Color3
)
	local slot: RoomTemplates.DoorSlot? = nil
	for _, candidate in ipairs(doorSlots) do
		if candidate.Side == side then
			slot = candidate
			break
		end
	end
	if slot == nil then
		local wall = self:_MakePart("Wall_" .. side, size, position, wallColor, Enum.Material.Concrete)
		wall.Parent = room
		return
	end

	-- Split along the wall's long axis (X for north/south, Z for east/west).
	local isXAxis = side == "north" or side == "south"
	local half = (isXAxis and size.X or size.Z) / 2
	local gapHalf = slot.Width / 2
	local ranges = {
		{ -half, slot.Offset - gapHalf },
		{ slot.Offset + gapHalf, half },
	}
	for i, range in ipairs(ranges) do
		local from, to = range[1], range[2]
		local length = to - from
		if length > 0.5 then
			local center = (from + to) / 2
			local segPos: Vector3
			local segSize: Vector3
			if isXAxis then
				segPos = position + Vector3.new(center, 0, 0)
				segSize = Vector3.new(length, size.Y, size.Z)
			else
				segPos = position + Vector3.new(0, 0, center)
				segSize = Vector3.new(size.X, size.Y, length)
			end
			local wall = self:_MakePart("Wall_" .. side .. "_" .. (i == 1 and "A" or "B"), segSize, segPos, wallColor, Enum.Material.Concrete)
			wall.Parent = room
		end
	end
end

--- One stairwell part per floor, near the far end of the closing room.
--- Marked one-way DOWN; extraction/descent logic is a later delegation.
function FloorService:_InstantiateStairwell(floorFolder: Folder, template: RoomTemplates.RoomTemplate, origin: Vector3, floor: number)
	local room = floorFolder:FindFirstChild("Room_" .. template.Name)
	if room == nil then
		return
	end

	local stairs = Instance.new("Part")
	stairs.Name = "StairwellDown"
	stairs.Size = Vector3.new(8, 1.5, 12)
	stairs.Position = origin + Vector3.new(template.Size.X - 8, 0.75, 0)
	stairs.Anchored = true
	stairs.CanCollide = true
	stairs.Color = Color3.fromRGB(14, 14, 16)
	stairs.Material = Enum.Material.Concrete
	stairs:SetAttribute("StairwellDirection", "down") -- one-way: players may only descend
	stairs:SetAttribute("TargetFloor", floor + 1)
	stairs.Parent = room

	-- Dim green marker so the way down reads at a glance (no functionality).
	local anchor = Instance.new("Part")
	anchor.Name = "StairwellLightAnchor"
	anchor.Size = Vector3.new(0.5, 0.5, 0.5)
	anchor.Position = stairs.Position + Vector3.new(0, 4, 0)
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.Transparency = 1
	local light = Instance.new("PointLight")
	light.Name = "StairwellLight"
	light.Color = Color3.fromRGB(80, 255, 160)
	light.Brightness = 1
	light.Range = 10
	light.Shadows = false
	light.Parent = anchor
	anchor.Parent = room
end

--- Anchored, collidable, smooth primitive part factory.
function FloorService:_MakePart(name: string, size: Vector3, position: Vector3, color: Color3, material: Enum.Material): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.Position = position
	part.Anchored = true
	part.CanCollide = true
	part.Color = color
	part.Material = material
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	return part
end

return FloorService
