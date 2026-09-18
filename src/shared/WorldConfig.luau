--[[
	WorldConfig -- Central parameters and layout specifications for the procedural world,
	biome sectors, straight highway corridor, oversized environmental foliage, and obstacle courses.
]]

local WorldConfig = {}

-- Overall world boundaries (studs)
WorldConfig.WorldBounds = {
	MinX = -800,
	MaxX = 800,
	MinZ = -2300,
	MaxZ = 2300,
	GroundY = 0,
}

-- Highway specifications
WorldConfig.Highway = {
	StartZ = -2250,
	EndZ = 2250,
	RoadY = 0.5,
	Width = 72, -- Total width including shoulders
	LaneWidth = 14,
	NumLanes = 4, -- 2 forward, 2 reverse
	ShoulderWidth = 8,
	AsphaltColor = Color3.fromRGB(38, 40, 46),
	ShoulderColor = Color3.fromRGB(52, 54, 60),
	CenterlineColor = Color3.fromRGB(245, 195, 20), -- Double solid yellow
	LaneDividerColor = Color3.fromRGB(235, 238, 242), -- Dashed white
	GuardrailColor = Color3.fromRGB(160, 168, 178),
	StreetlightInterval = 140,
	StreetlightHeight = 32,
	SignGantryInterval = 500,
}

-- Scale factors for environmental elements (oversized for high-speed arcade driving)
WorldConfig.EnvironmentScale = {
	TreeHeightMin = 36,
	TreeHeightMax = 62,
	TreeTrunkRadius = 3.2,
	BoulderSizeMin = 16,
	BoulderSizeMax = 38,
	CanyonCliffHeight = 85,
	MountainWallHeight = 110,
}

-- Biome sector layout along the highway (Z-axis)
WorldConfig.Biomes = {
	GlacialTundra = {
		Name = "Glacial Tundra",
		MinZ = -2300,
		MaxZ = -1300,
		GroundColor = Color3.fromRGB(230, 240, 248),
		GroundMaterial = Enum.Material.Snow,
		FoliageType = "SnowPine",
		PropType = "FrostSpire",
		RockColor = Color3.fromRGB(175, 190, 205),
		BarnSpot = Vector3.new(-160, 1, -1800),
		BarnHeading = 90,
		CarReward = "Porsche",
	},
	AutumnValley = {
		Name = "Autumn Redwood Valley",
		MinZ = -1300,
		MaxZ = -300,
		GroundColor = Color3.fromRGB(142, 98, 48),
		GroundMaterial = Enum.Material.Ground,
		FoliageType = "AutumnRedwood",
		PropType = "FallenLog",
		RockColor = Color3.fromRGB(98, 86, 74),
		BarnSpot = Vector3.new(160, 1, -800),
		BarnHeading = -90,
		CarReward = "Porsche",
	},
	CentralHub = {
		Name = "Central Motors Plaza",
		MinZ = -300,
		MaxZ = 300,
		GroundColor = Color3.fromRGB(72, 75, 82),
		GroundMaterial = Enum.Material.Concrete,
		FoliageType = "PlazaPlanter",
		PropType = "PlazaLamp",
		RockColor = Color3.fromRGB(80, 85, 95),
		ShowroomCenter = Vector3.new(0, 1, 0),
		GarageDropOff = Vector3.new(90, 1, 40),
		Spawns = {
			Vector3.new(-25, 2, 80),
			Vector3.new(25, 2, 80),
			Vector3.new(-25, 2, 120),
			Vector3.new(25, 2, 120),
		},
	},
	DesertCanyon = {
		Name = "Red Rock Desert",
		MinZ = 300,
		MaxZ = 1300,
		GroundColor = Color3.fromRGB(195, 128, 82),
		GroundMaterial = Enum.Material.Sand,
		FoliageType = "SaguaroCactus",
		PropType = "SandstoneMesa",
		RockColor = Color3.fromRGB(165, 85, 52),
		BarnSpot = Vector3.new(-170, 1, 800),
		BarnHeading = 90,
		CarReward = "Porsche",
	},
	AlpineForest = {
		Name = "Alpine Pine Forest",
		MinZ = 1300,
		MaxZ = 2300,
		GroundColor = Color3.fromRGB(58, 92, 45),
		GroundMaterial = Enum.Material.Grass,
		FoliageType = "AlpinePine",
		PropType = "GraniteCrag",
		RockColor = Color3.fromRGB(85, 90, 96),
		BarnSpot = Vector3.new(170, 1, 1800),
		BarnHeading = -90,
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
WorldConfig.ObstacleIntervalMax = 250

return WorldConfig
