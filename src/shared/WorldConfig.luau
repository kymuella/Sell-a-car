--[[
	WorldConfig -- Central parameters and layout specifications for the procedural world.
	Layout:
	- Crescent of player garages at the start/beginning of the run (Z: -200 to 250)
	- Driveway merges from the crescent directly into the collective 4-lane highway
	- The highway progresses LINEARLY forward from the garages (Z: 250 to 4600), NOT bisecting
	- Biomes progress sequentially along the highway:
	  Crescent Hub -> Autumn Redwood Valley -> Red Rock Desert -> Alpine Forest -> Glacial Tundra Summit
]]

local WorldConfig = {}

-- Overall world boundaries (studs) - Linear progression along +Z
WorldConfig.WorldBounds = {
	MinX = -800,
	MaxX = 800,
	MinZ = -250,
	MaxZ = 4800,
	GroundY = 0,
}

-- Highway specifications - Starts at crescent driveway merge and progresses linearly
WorldConfig.Highway = {
	StartZ = 250,   -- Begins right where crescent driveway merges
	EndZ = 4600,    -- Linear terminus at mountain summit
	RoadY = 0.5,
	Width = 72,     -- 4 lanes (14 each) + 2 shoulders (8 each)
	LaneWidth = 14,
	NumLanes = 4,
	ShoulderWidth = 8,
	AsphaltColor = Color3.fromRGB(38, 40, 46),
	ShoulderColor = Color3.fromRGB(52, 54, 60),
	CenterlineColor = Color3.fromRGB(245, 195, 20), -- Double solid yellow
	LaneDividerColor = Color3.fromRGB(235, 238, 242), -- Dashed white
	GuardrailColor = Color3.fromRGB(160, 168, 178),
	StreetlightInterval = 140,
	StreetlightHeight = 32,
	SignGantryInterval = 600,
}

-- Crescent Garage Hub specifications
WorldConfig.Crescent = {
	Center = Vector3.new(0, 0, 40),
	Radius = 90,
	NumGarages = 6,
	MergeZ = 250,
	GarageWidth = 20,
	GarageDepth = 26,
	GarageHeight = 15,
}

-- Scale factors for environmental elements (oversized for high-speed arcade driving)
WorldConfig.EnvironmentScale = {
	TreeHeightMin = 36,
	TreeHeightMax = 62,
	TreeTrunkRadius = 3.2,
	BoulderSizeMin = 16,
	BoulderSizeMax = 38,
	CanyonCliffHeight = 85,
	MountainWallHeight = 120,
}

-- Linear Biome progression along the highway (+Z axis)
WorldConfig.Biomes = {
	CrescentHub = {
		Name = "Crescent Garages & Dealership Hub",
		MinZ = -250,
		MaxZ = 300,
		GroundColor = Color3.fromRGB(72, 76, 84),
		GroundMaterial = Enum.Material.Concrete,
		FoliageType = "PlazaPlanter",
		PropType = "PlazaLamp",
		RockColor = Color3.fromRGB(80, 85, 95),
		GarageDropOff = Vector3.new(85, 1, 140),
	},
	AutumnValley = {
		Name = "Autumn Redwood Valley",
		MinZ = 300,
		MaxZ = 1400,
		GroundColor = Color3.fromRGB(142, 98, 48),
		GroundMaterial = Enum.Material.Ground,
		FoliageType = "AutumnRedwood",
		PropType = "FallenLog",
		RockColor = Color3.fromRGB(98, 86, 74),
		BarnSpot = Vector3.new(165, 1, 850),
		BarnHeading = -90,
		CarReward = "Porsche",
	},
	DesertCanyon = {
		Name = "Red Rock Desert Canyon",
		MinZ = 1400,
		MaxZ = 2500,
		GroundColor = Color3.fromRGB(195, 128, 82),
		GroundMaterial = Enum.Material.Sand,
		FoliageType = "SaguaroCactus",
		PropType = "SandstoneMesa",
		RockColor = Color3.fromRGB(165, 85, 52),
		BarnSpot = Vector3.new(-170, 1, 1950),
		BarnHeading = 90,
		CarReward = "Porsche",
	},
	AlpineForest = {
		Name = "Alpine Pine Forest",
		MinZ = 2500,
		MaxZ = 3600,
		GroundColor = Color3.fromRGB(58, 92, 45),
		GroundMaterial = Enum.Material.Grass,
		FoliageType = "AlpinePine",
		PropType = "GraniteCrag",
		RockColor = Color3.fromRGB(85, 90, 96),
		BarnSpot = Vector3.new(170, 1, 3050),
		BarnHeading = -90,
		CarReward = "Porsche",
	},
	GlacialTundra = {
		Name = "Glacial Tundra Summit",
		MinZ = 3600,
		MaxZ = 4750,
		GroundColor = Color3.fromRGB(230, 240, 248),
		GroundMaterial = Enum.Material.Snow,
		FoliageType = "SnowPine",
		PropType = "FrostSpire",
		RockColor = Color3.fromRGB(175, 190, 205),
		BarnSpot = Vector3.new(-165, 1, 4150),
		BarnHeading = 90,
		CarReward = "Porsche",
	},
}

-- Highway Obstacle Definitions
WorldConfig.ObstacleTypes = {
	JerseyBarricade = {
		Weight = 30,
		Length = 24,
		Width = 4,
		Height = 5.5,
		Color = Color3.fromRGB(220, 120, 25),
		HasBlinkers = true,
		Label = "ROAD CLOSED",
	},
	CargoCrates = {
		Weight = 25,
		Length = 16,
		Width = 14,
		Height = 8,
		Color = Color3.fromRGB(140, 95, 55),
		HasBlinkers = false,
		Label = "CARGO",
	},
	WreckedChassis = {
		Weight = 20,
		Length = 20,
		Width = 9,
		Height = 5,
		Color = Color3.fromRGB(85, 48, 36),
		HasBlinkers = true,
		Label = "HAZARD",
	},
	TireChicane = {
		Weight = 25,
		Length = 18,
		Width = 6,
		Height = 4.5,
		Color = Color3.fromRGB(28, 28, 30),
		HasBlinkers = false,
		Label = "IMPACT WALL",
	},
}

-- Obstacle spacing along straight highway
WorldConfig.ObstacleIntervalMin = 180
WorldConfig.ObstacleIntervalMax = 260

return WorldConfig
