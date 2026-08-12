--!strict
-- RoomTemplates — primitive room template data for the seeded floor generator
-- (GDD §4.3). Data only: FloorService instantiates these into the Workspace.
--
-- Visual style modeled on the retired PlaceholderRoom: dark concrete, dim
-- lighting. Tier 1 "Upper Facility" identity per GDD: staff offices, break
-- rooms, sickly green light. Door slots are connector metadata — grid
-- connectivity is a later pass; this pass lays the rooms out in a line.
--
-- Positions are LOCAL to the room's west-south corner at Y = 0 (the top of
-- the floor slab). Six templates: one spawn room, one stairwell room, four
-- standard rooms.

export type DoorSlot = {
	Side: "north" | "south" | "east" | "west",
	Offset: number, -- studs from the wall centre along the wall (0 = centre)
	Width: number, -- door opening width in studs
}

export type RoomProp = {
	Name: string,
	Size: Vector3,
	Position: Vector3, -- local to room origin (Y = 0 sits on the slab top)
	Color: Color3,
	Material: Enum.Material,
}

export type RoomLight = {
	Name: string,
	Position: Vector3, -- local to room origin
	Color: Color3,
	Brightness: number,
	Range: number,
}

export type RoomTemplate = {
	Name: string,
	Role: "spawn" | "stairwell" | "standard",
	Size: Vector3, -- X width, Y height, Z depth
	DoorSlots: { DoorSlot },
	SpawnPoints: { Vector3 }, -- local offsets; only the spawn room instantiates these
	Props: { RoomProp },
	Lights: { RoomLight },
	FloorColor: Color3,
	WallColor: Color3,
}

local WALL_HEIGHT = 16 -- all templates share the placeholder's 16-stud height

local RoomTemplates: { RoomTemplate } = {
	-- Spawn lobby — the run always starts here (opens the line).
	{
		Name = "SpawnLobby",
		Role = "spawn",
		Size = Vector3.new(50, WALL_HEIGHT, 36),
		DoorSlots = {
			{ Side = "east", Offset = 0, Width = 8 },
		},
		SpawnPoints = {
			Vector3.new(10, 1.5, -9),
			Vector3.new(10, 1.5, 9),
			Vector3.new(14, 1.5, -4),
			Vector3.new(14, 1.5, 4),
		},
		Props = {
			{
				Name = "CrateA",
				Size = Vector3.new(2, 2, 2),
				Position = Vector3.new(30, 1.5, 10),
				Color = Color3.fromRGB(46, 43, 36),
				Material = Enum.Material.WoodPlanks,
			},
			{
				Name = "CrateB",
				Size = Vector3.new(2, 2, 2),
				Position = Vector3.new(30, 1.5, -10),
				Color = Color3.fromRGB(46, 43, 36),
				Material = Enum.Material.WoodPlanks,
			},
		},
		Lights = {
			{
				Name = "LobbyCeilingLight",
				Position = Vector3.new(25, 13, 0),
				Color = Color3.fromRGB(205, 215, 220),
				Brightness = 2,
				Range = 28,
			},
		},
		FloorColor = Color3.fromRGB(33, 33, 36),
		WallColor = Color3.fromRGB(26, 26, 28),
	},
	-- Hallway — narrow connector room.
	{
		Name = "Hallway",
		Role = "standard",
		Size = Vector3.new(24, WALL_HEIGHT, 12),
		DoorSlots = {
			{ Side = "east", Offset = 0, Width = 8 },
			{ Side = "west", Offset = 0, Width = 8 },
		},
		SpawnPoints = {},
		Props = {},
		Lights = {
			{
				Name = "HallLightA",
				Position = Vector3.new(6, 13, 0),
				Color = Color3.fromRGB(185, 195, 205),
				Brightness = 1.2,
				Range = 14,
			},
			{
				Name = "HallLightB",
				Position = Vector3.new(18, 13, 0),
				Color = Color3.fromRGB(185, 195, 205),
				Brightness = 1.2,
				Range = 14,
			},
		},
		FloorColor = Color3.fromRGB(30, 30, 33),
		WallColor = Color3.fromRGB(25, 25, 27),
	},
	-- Office — staff desks and a dim work light.
	{
		Name = "Office",
		Role = "standard",
		Size = Vector3.new(40, WALL_HEIGHT, 32),
		DoorSlots = {
			{ Side = "east", Offset = 0, Width = 8 },
			{ Side = "west", Offset = 0, Width = 8 },
		},
		SpawnPoints = {
			Vector3.new(20, 1.5, 0), -- data only — reserved for future use
		},
		Props = {
			{
				Name = "DeskA",
				Size = Vector3.new(6, 2, 3),
				Position = Vector3.new(10, 1.5, -8),
				Color = Color3.fromRGB(40, 36, 30),
				Material = Enum.Material.WoodPlanks,
			},
			{
				Name = "DeskB",
				Size = Vector3.new(6, 2, 3),
				Position = Vector3.new(10, 1.5, 8),
				Color = Color3.fromRGB(40, 36, 30),
				Material = Enum.Material.WoodPlanks,
			},
			{
				Name = "FilingCabinet",
				Size = Vector3.new(2, 3, 2),
				Position = Vector3.new(30, 2, -12),
				Color = Color3.fromRGB(30, 32, 36),
				Material = Enum.Material.Metal,
			},
		},
		Lights = {
			{
				Name = "OfficeLightA",
				Position = Vector3.new(12, 13, 0),
				Color = Color3.fromRGB(200, 205, 210),
				Brightness = 1.8,
				Range = 20,
			},
			{
				Name = "OfficeLightB",
				Position = Vector3.new(28, 13, 0),
				Color = Color3.fromRGB(200, 205, 210),
				Brightness = 1.8,
				Range = 20,
			},
		},
		FloorColor = Color3.fromRGB(32, 32, 34),
		WallColor = Color3.fromRGB(25, 25, 27),
	},
	-- Break room — sickly green light (Tier 1 identity).
	{
		Name = "BreakRoom",
		Role = "standard",
		Size = Vector3.new(32, WALL_HEIGHT, 26),
		DoorSlots = {
			{ Side = "east", Offset = 0, Width = 8 },
			{ Side = "west", Offset = 0, Width = 8 },
		},
		SpawnPoints = {},
		Props = {
			{
				Name = "Table",
				Size = Vector3.new(8, 1, 3),
				Position = Vector3.new(10, 1, 0),
				Color = Color3.fromRGB(45, 40, 34),
				Material = Enum.Material.WoodPlanks,
			},
			{
				Name = "Crate",
				Size = Vector3.new(2, 2, 2),
				Position = Vector3.new(24, 1.5, 8),
				Color = Color3.fromRGB(46, 43, 36),
				Material = Enum.Material.WoodPlanks,
			},
		},
		Lights = {
			{
				Name = "BreakRoomLight",
				Position = Vector3.new(16, 13, 0),
				Color = Color3.fromRGB(140, 215, 150),
				Brightness = 1.6,
				Range = 18,
			},
		},
		FloorColor = Color3.fromRGB(31, 34, 31),
		WallColor = Color3.fromRGB(24, 27, 24),
	},
	-- Lab room — teal-green work light.
	{
		Name = "LabRoom",
		Role = "standard",
		Size = Vector3.new(44, WALL_HEIGHT, 34),
		DoorSlots = {
			{ Side = "east", Offset = 0, Width = 8 },
			{ Side = "west", Offset = 0, Width = 8 },
		},
		SpawnPoints = {},
		Props = {
			{
				Name = "ConsoleA",
				Size = Vector3.new(4, 3, 2),
				Position = Vector3.new(10, 2, -10),
				Color = Color3.fromRGB(28, 32, 38),
				Material = Enum.Material.Metal,
			},
			{
				Name = "ConsoleB",
				Size = Vector3.new(4, 3, 2),
				Position = Vector3.new(10, 2, 10),
				Color = Color3.fromRGB(28, 32, 38),
				Material = Enum.Material.Metal,
			},
			{
				Name = "Crate",
				Size = Vector3.new(2, 2, 2),
				Position = Vector3.new(34, 1.5, 0),
				Color = Color3.fromRGB(46, 43, 36),
				Material = Enum.Material.WoodPlanks,
			},
		},
		Lights = {
			{
				Name = "LabLightA",
				Position = Vector3.new(12, 13, 0),
				Color = Color3.fromRGB(110, 230, 200),
				Brightness = 1.8,
				Range = 22,
			},
			{
				Name = "LabLightB",
				Position = Vector3.new(32, 13, 0),
				Color = Color3.fromRGB(110, 230, 200),
				Brightness = 1.8,
				Range = 22,
			},
		},
		FloorColor = Color3.fromRGB(30, 33, 34),
		WallColor = Color3.fromRGB(24, 26, 27),
	},
	-- Generator bay — amber service light; the floor's stairwell sits at its
	-- far (east) end, so this room always closes the line.
	{
		Name = "GeneratorBay",
		Role = "stairwell",
		Size = Vector3.new(48, WALL_HEIGHT, 40),
		DoorSlots = {
			{ Side = "west", Offset = 0, Width = 8 },
		},
		SpawnPoints = {},
		Props = {
			{
				Name = "Generator",
				Size = Vector3.new(6, 5, 4),
				Position = Vector3.new(14, 3, 0),
				Color = Color3.fromRGB(28, 30, 32),
				Material = Enum.Material.Metal,
			},
			{
				Name = "FuelTank",
				Size = Vector3.new(3, 5, 3),
				Position = Vector3.new(14, 3, -12),
				Color = Color3.fromRGB(38, 34, 26),
				Material = Enum.Material.Metal,
			},
		},
		Lights = {
			{
				Name = "GenBayLight",
				Position = Vector3.new(10, 13, 0),
				Color = Color3.fromRGB(255, 180, 90),
				Brightness = 2,
				Range = 24,
			},
		},
		FloorColor = Color3.fromRGB(34, 32, 30),
		WallColor = Color3.fromRGB(26, 25, 24),
	},
}

return RoomTemplates
