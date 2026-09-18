--[[
	WorldService -- Procedural generation for world biomes, oversized environmental foliage,
	long straight highways, and randomly generated obstacle courses.

	Key Features:
	- Distinct biomes: Central Motors Plaza, Red Rock Desert, Alpine Pine Forest,
	  Autumn Redwood Valley, and Glacial Tundra.
	- Oversized environmental props (trees 40-65 studs tall, colossal boulders, towering canyon walls).
	- Straight 4-lane highway corridor extending over 4,400 studs with double yellow centerlines,
	  dashed white lane dividers, steel guardrails, overhead sign gantries, and streetlights.
	- Randomly generated highway obstacles (construction Jersey barriers with flashing beacons,
	  spilled cargo crates, stalled vehicle wrecks, and tire chicane walls) with evasion lanes.
	- Integrated rustic barns tagged `BarnSpot` and central restoration garage tagged `GarageDropOff`.
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local SharedFolder = ReplicatedStorage:WaitForChild("Shared")
local WorldConfig = require(SharedFolder:WaitForChild("WorldConfig"))

local BARN_SPOT_TAG = "BarnSpot"
local DROP_OFF_TAG = "GarageDropOff"

local WorldService = {}

local rng = Random.new(1337) -- Deterministic seed for balanced, replayable world generation

-- Container for all generated world geometry
local function getWorldFolder(): Folder
	local existing = Workspace:FindFirstChild("Map")
	if existing and existing:IsA("Folder") then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = "Map"
	folder.Parent = Workspace
	return folder
end

local function makePart(props: { [string]: any }): Part
	local part = Instance.new("Part")
	part.Anchored = true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	for k, v in props do
		if k ~= "Parent" then
			(part :: any)[k] = v
		end
	end
	part.Parent = props.Parent
	return part
end

-- ============================================================================
-- 1. TERRAIN & BIOME GROUND SLABS
-- ============================================================================

local function generateBiomeTerrain(mapFolder: Folder)
	local terrainFolder = Instance.new("Folder")
	terrainFolder.Name = "BiomeTerrain"
	terrainFolder.Parent = mapFolder

	local bounds = WorldConfig.WorldBounds
	local totalWidth = bounds.MaxX - bounds.MinX

	for biomeKey, biome in WorldConfig.Biomes do
		local biomeLength = biome.MaxZ - biome.MinZ
		local centerZ = (biome.MinZ + biome.MaxZ) / 2

		-- Left terrain plate
		makePart({
			Name = biomeKey .. "_Ground_West",
			Size = Vector3.new(totalWidth / 2 - 40, 4, biomeLength),
			CFrame = CFrame.new(-totalWidth / 4 - 20, bounds.GroundY - 2, centerZ),
			Color = biome.GroundColor,
			Material = biome.GroundMaterial,
			Parent = terrainFolder,
		})

		-- Right terrain plate
		makePart({
			Name = biomeKey .. "_Ground_East",
			Size = Vector3.new(totalWidth / 2 - 40, 4, biomeLength),
			CFrame = CFrame.new(totalWidth / 4 + 20, bounds.GroundY - 2, centerZ),
			Color = biome.GroundColor,
			Material = biome.GroundMaterial,
			Parent = terrainFolder,
		})

		-- Rolling hill mounds in the background for natural depth
		for i = 1, 4 do
			local hillX = (if i % 2 == 0 then 1 else -1) * rng:NextNumber(220, 450)
			local hillZ = biome.MinZ + rng:NextNumber(40, biomeLength - 40)
			local hillRadius = rng:NextNumber(60, 110)
			local hillHeight = rng:NextNumber(20, 45)

			local mound = makePart({
				Name = "Mound_" .. biomeKey,
				Shape = Enum.PartType.Cylinder,
				Size = Vector3.new(hillHeight, hillRadius * 2, hillRadius * 2),
				CFrame = CFrame.new(hillX, bounds.GroundY + hillHeight / 2 - 4, hillZ) * CFrame.Angles(0, 0, math.rad(90)),
				Color = biome.GroundColor,
				Material = biome.GroundMaterial,
				Parent = terrainFolder,
			})
		end
	end

	-- Mountain Perimeter Walls (Keeps vehicles enclosed and creates majestic horizon)
	local wallHeight = WorldConfig.EnvironmentScale.MountainWallHeight
	local totalLength = bounds.MaxZ - bounds.MinZ

	-- West mountain wall
	makePart({
		Name = "PerimeterWall_West",
		Size = Vector3.new(80, wallHeight, totalLength),
		CFrame = CFrame.new(bounds.MinX + 40, bounds.GroundY + wallHeight / 2 - 2, 0),
		Color = Color3.fromRGB(72, 76, 84),
		Material = Enum.Material.Slate,
		Parent = terrainFolder,
	})

	-- East mountain wall
	makePart({
		Name = "PerimeterWall_East",
		Size = Vector3.new(80, wallHeight, totalLength),
		CFrame = CFrame.new(bounds.MaxX - 40, bounds.GroundY + wallHeight / 2 - 2, 0),
		Color = Color3.fromRGB(72, 76, 84),
		Material = Enum.Material.Slate,
		Parent = terrainFolder,
	})

	-- North mountain wall
	makePart({
		Name = "PerimeterWall_North",
		Size = Vector3.new(totalWidth, wallHeight, 80),
		CFrame = CFrame.new(0, bounds.GroundY + wallHeight / 2 - 2, bounds.MaxZ - 40),
		Color = Color3.fromRGB(68, 72, 80),
		Material = Enum.Material.Slate,
		Parent = terrainFolder,
	})

	-- South mountain wall
	makePart({
		Name = "PerimeterWall_South",
		Size = Vector3.new(totalWidth, wallHeight, 80),
		CFrame = CFrame.new(0, bounds.GroundY + wallHeight / 2 - 2, bounds.MinZ + 40),
		Color = Color3.fromRGB(68, 72, 80),
		Material = Enum.Material.Slate,
		Parent = terrainFolder,
	})
end

-- ============================================================================
-- 2. OVERSIZED ENVIRONMENTAL ELEMENTS & FOLIAGE
-- ============================================================================

local function makeGiantPineTree(position: Vector3, parent: Instance, isSnowy: boolean?)
	local trunkHeight = rng:NextNumber(18, 26)
	local trunkRadius = WorldConfig.EnvironmentScale.TreeTrunkRadius
	local trunk = makePart({
		Name = "PineTrunk",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(trunkHeight, trunkRadius * 2, trunkRadius * 2),
		CFrame = CFrame.new(position + Vector3.new(0, trunkHeight / 2, 0)) * CFrame.Angles(0, 0, math.rad(90)),
		Color = Color3.fromRGB(86, 54, 34),
		Material = Enum.Material.Wood,
		Parent = parent,
	})

	local foliageColor = if isSnowy then Color3.fromRGB(220, 235, 245) else Color3.fromRGB(34, 78, 42)
	local tiers = 4
	local baseWidth = rng:NextNumber(28, 38)

	for i = 1, tiers do
		local width = baseWidth * (1 - (i - 1) * 0.22)
		local tierHeight = rng:NextNumber(12, 16)
		local yOffset = trunkHeight * 0.6 + (i - 1) * (tierHeight * 0.75)

		makePart({
			Name = "PineCanopy",
			Size = Vector3.new(width, tierHeight, width),
			CFrame = CFrame.new(position + Vector3.new(0, yOffset + tierHeight / 2, 0)) * CFrame.Angles(0, math.rad(rng:NextNumber(0, 45)), 0),
			Color = foliageColor,
			Material = if isSnowy then Enum.Material.Snow else Enum.Material.Grass,
			Parent = parent,
		})
	end
end

local function makeGiantRedwoodTree(position: Vector3, parent: Instance)
	local trunkHeight = rng:NextNumber(26, 36)
	local trunkRadius = 4.2
	makePart({
		Name = "RedwoodTrunk",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(trunkHeight, trunkRadius * 2, trunkRadius * 2),
		CFrame = CFrame.new(position + Vector3.new(0, trunkHeight / 2, 0)) * CFrame.Angles(0, 0, math.rad(90)),
		Color = Color3.fromRGB(115, 62, 38),
		Material = Enum.Material.Wood,
		Parent = parent,
	})

	-- Massive layered autumn canopy
	local canopySpread = rng:NextNumber(36, 50)
	local canopyHeight = rng:NextNumber(22, 30)
	local autumnColors = {
		Color3.fromRGB(204, 102, 24),
		Color3.fromRGB(225, 142, 32),
		Color3.fromRGB(184, 68, 20),
	}
	local color = autumnColors[rng:NextInteger(1, #autumnColors)]

	makePart({
		Name = "RedwoodCanopy",
		Size = Vector3.new(canopySpread, canopyHeight, canopySpread),
		CFrame = CFrame.new(position + Vector3.new(0, trunkHeight + canopyHeight / 2 - 4, 0)) * CFrame.Angles(0, math.rad(rng:NextNumber(0, 60)), 0),
		Color = color,
		Material = Enum.Material.Grass,
		Parent = parent,
	})
end

local function makeGiantSaguaroCactus(position: Vector3, parent: Instance)
	local height = rng:NextNumber(32, 46)
	local radius = 3.2
	local cactusColor = Color3.fromRGB(58, 120, 65)

	-- Main trunk
	makePart({
		Name = "CactusTrunk",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(height, radius * 2, radius * 2),
		CFrame = CFrame.new(position + Vector3.new(0, height / 2, 0)) * CFrame.Angles(0, 0, math.rad(90)),
		Color = cactusColor,
		Material = Enum.Material.SmoothPlastic,
		Parent = parent,
	})

	-- Left arm
	local leftArmY = height * 0.45
	makePart({
		Name = "CactusArmH_L",
		Size = Vector3.new(12, radius * 1.8, radius * 1.8),
		CFrame = CFrame.new(position + Vector3.new(-7, leftArmY, 0)),
		Color = cactusColor,
		Material = Enum.Material.SmoothPlastic,
		Parent = parent,
	})
	makePart({
		Name = "CactusArmV_L",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(16, radius * 1.8, radius * 1.8),
		CFrame = CFrame.new(position + Vector3.new(-12, leftArmY + 8, 0)) * CFrame.Angles(0, 0, math.rad(90)),
		Color = cactusColor,
		Material = Enum.Material.SmoothPlastic,
		Parent = parent,
	})

	-- Right arm
	local rightArmY = height * 0.6
	makePart({
		Name = "CactusArmH_R",
		Size = Vector3.new(12, radius * 1.8, radius * 1.8),
		CFrame = CFrame.new(position + Vector3.new(7, rightArmY, 0)),
		Color = cactusColor,
		Material = Enum.Material.SmoothPlastic,
		Parent = parent,
	})
	makePart({
		Name = "CactusArmV_R",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(16, radius * 1.8, radius * 1.8),
		CFrame = CFrame.new(position + Vector3.new(12, rightArmY + 8, 0)) * CFrame.Angles(0, 0, math.rad(90)),
		Color = cactusColor,
		Material = Enum.Material.SmoothPlastic,
		Parent = parent,
	})
end

local function makeGiantBoulder(position: Vector3, parent: Instance, color: Color3, sizeScale: number?)
	local scale = sizeScale or 1
	local size = Vector3.new(
		rng:NextNumber(16, 32) * scale,
		rng:NextNumber(14, 28) * scale,
		rng:NextNumber(16, 32) * scale
	)
	makePart({
		Name = "GiantBoulder",
		Size = size,
		CFrame = CFrame.new(position + Vector3.new(0, size.Y / 2 - 2, 0)) * CFrame.Angles(
			math.rad(rng:NextNumber(-15, 15)),
			math.rad(rng:NextNumber(0, 360)),
			math.rad(rng:NextNumber(-15, 15))
		),
		Color = color,
		Material = Enum.Material.Rock,
		Parent = parent,
	})
end

local function makeFrostSpire(position: Vector3, parent: Instance)
	local height = rng:NextNumber(30, 52)
	local width = rng:NextNumber(10, 18)
	makePart({
		Name = "FrostSpire",
		Size = Vector3.new(width, height, width),
		CFrame = CFrame.new(position + Vector3.new(0, height / 2, 0)) * CFrame.Angles(
			math.rad(rng:NextNumber(-8, 8)),
			math.rad(rng:NextNumber(0, 180)),
			math.rad(rng:NextNumber(-8, 8))
		),
		Color = Color3.fromRGB(180, 225, 245),
		Material = Enum.Material.Ice,
		Transparency = 0.15,
		Parent = parent,
	})
end

local function generateBiomeFoliage(mapFolder: Folder)
	local foliageFolder = Instance.new("Folder")
	foliageFolder.Name = "OversizedFoliage"
	foliageFolder.Parent = mapFolder

	for biomeKey, biome in WorldConfig.Biomes do
		if biomeKey == "CentralHub" then
			continue
		end

		local count = 28 -- Number of giant environmental props per biome
		for _ = 1, count do
			-- Distribute outside the highway corridor (|X| >= 65)
			local side = if rng:NextNumber() > 0.5 then 1 else -1
			local propX = side * rng:NextNumber(70, 360)
			local propZ = rng:NextNumber(biome.MinZ + 30, biome.MaxZ - 30)
			local pos = Vector3.new(propX, WorldConfig.WorldBounds.GroundY, propZ)

			if biome.FoliageType == "AlpinePine" then
				makeGiantPineTree(pos, foliageFolder, false)
				if rng:NextNumber() > 0.4 then
					makeGiantBoulder(pos + Vector3.new(rng:NextNumber(-25, 25), 0, rng:NextNumber(-25, 25)), foliageFolder, biome.RockColor, 1.2)
				end
			elseif biome.FoliageType == "SnowPine" then
				makeGiantPineTree(pos, foliageFolder, true)
				if rng:NextNumber() > 0.4 then
					makeFrostSpire(pos + Vector3.new(rng:NextNumber(-20, 20), 0, rng:NextNumber(-20, 20)), foliageFolder)
				end
			elseif biome.FoliageType == "AutumnRedwood" then
				makeGiantRedwoodTree(pos, foliageFolder)
				if rng:NextNumber() > 0.5 then
					makeGiantBoulder(pos + Vector3.new(rng:NextNumber(-25, 25), 0, rng:NextNumber(-25, 25)), foliageFolder, biome.RockColor, 1.3)
				end
			elseif biome.FoliageType == "SaguaroCactus" then
				makeGiantSaguaroCactus(pos, foliageFolder)
				if rng:NextNumber() > 0.3 then
					makeGiantBoulder(pos + Vector3.new(rng:NextNumber(-30, 30), 0, rng:NextNumber(-30, 30)), foliageFolder, biome.RockColor, 1.5)
				end
			end
		end
	end
end

-- ============================================================================
-- 3. STRAIGHT HIGHWAY SYSTEM WITH INFRASTRUCTURE
-- ============================================================================

local function generateStraightHighway(mapFolder: Folder)
	local hwFolder = Instance.new("Folder")
	hwFolder.Name = "StraightHighway"
	hwFolder.Parent = mapFolder

	local hw = WorldConfig.Highway
	local roadLength = hw.EndZ - hw.StartZ
	local centerZ = (hw.StartZ + hw.EndZ) / 2
	local roadY = hw.RoadY

	-- Main 4-Lane Asphalt Roadbed
	local asphalt = makePart({
		Name = "HighwayAsphalt",
		Size = Vector3.new(hw.LaneWidth * hw.NumLanes, 1, roadLength),
		CFrame = CFrame.new(0, roadY, centerZ),
		Color = hw.AsphaltColor,
		Material = Enum.Material.Concrete,
		Parent = hwFolder,
	})

	-- Left and Right Shoulders
	local shoulderOffset = (hw.LaneWidth * hw.NumLanes) / 2 + hw.ShoulderWidth / 2
	makePart({
		Name = "Shoulder_West",
		Size = Vector3.new(hw.ShoulderWidth, 1.1, roadLength),
		CFrame = CFrame.new(-shoulderOffset, roadY + 0.05, centerZ),
		Color = hw.ShoulderColor,
		Material = Enum.Material.Pavement,
		Parent = hwFolder,
	})
	makePart({
		Name = "Shoulder_East",
		Size = Vector3.new(hw.ShoulderWidth, 1.1, roadLength),
		CFrame = CFrame.new(shoulderOffset, roadY + 0.05, centerZ),
		Color = hw.ShoulderColor,
		Material = Enum.Material.Pavement,
		Parent = hwFolder,
	})

	-- Double Solid Yellow Centerline
	makePart({
		Name = "Centerline_Left",
		Size = Vector3.new(0.8, 0.05, roadLength),
		CFrame = CFrame.new(-0.6, roadY + 0.52, centerZ),
		Color = hw.CenterlineColor,
		Material = Enum.Material.Neon,
		Parent = hwFolder,
	})
	makePart({
		Name = "Centerline_Right",
		Size = Vector3.new(0.8, 0.05, roadLength),
		CFrame = CFrame.new(0.6, roadY + 0.52, centerZ),
		Color = hw.CenterlineColor,
		Material = Enum.Material.Neon,
		Parent = hwFolder,
	})

	-- Outer Fog Lines (White)
	local fogLineOffset = (hw.LaneWidth * hw.NumLanes) / 2
	makePart({
		Name = "FogLine_West",
		Size = Vector3.new(0.8, 0.05, roadLength),
		CFrame = CFrame.new(-fogLineOffset, roadY + 0.52, centerZ),
		Color = hw.LaneDividerColor,
		Material = Enum.Material.SmoothPlastic,
		Parent = hwFolder,
	})
	makePart({
		Name = "FogLine_East",
		Size = Vector3.new(0.8, 0.05, roadLength),
		CFrame = CFrame.new(fogLineOffset, roadY + 0.52, centerZ),
		Color = hw.LaneDividerColor,
		Material = Enum.Material.SmoothPlastic,
		Parent = hwFolder,
	})

	-- Dashed White Lane Dividers
	local dashLength = 14
	local dashGap = 16
	local step = dashLength + dashGap
	local dividerOffsets = { -hw.LaneWidth, hw.LaneWidth }

	for _, xOff in dividerOffsets do
		local z = hw.StartZ + dashLength / 2
		while z < hw.EndZ do
			makePart({
				Name = "LaneDash",
				Size = Vector3.new(0.8, 0.05, dashLength),
				CFrame = CFrame.new(xOff, roadY + 0.52, z),
				Color = hw.LaneDividerColor,
				Material = Enum.Material.SmoothPlastic,
				Parent = hwFolder,
			})
			z += step
		end
	end

	-- Outer Steel Guardrails (Collidable to keep players safely on the roadway)
	local guardrailOffset = hw.Width / 2 + 1
	local railSegmentLength = 200
	local numRailSegments = math.ceil(roadLength / railSegmentLength)

	for i = 1, numRailSegments do
		local segZ = hw.StartZ + (i - 0.5) * railSegmentLength
		-- West Guardrail
		makePart({
			Name = "Guardrail_West",
			Size = Vector3.new(1.4, 3.5, railSegmentLength),
			CFrame = CFrame.new(-guardrailOffset, roadY + 2.25, segZ),
			Color = hw.GuardrailColor,
			Material = Enum.Material.Metal,
			Parent = hwFolder,
		})
		-- East Guardrail
		makePart({
			Name = "Guardrail_East",
			Size = Vector3.new(1.4, 3.5, railSegmentLength),
			CFrame = CFrame.new(guardrailOffset, roadY + 2.25, segZ),
			Color = hw.GuardrailColor,
			Material = Enum.Material.Metal,
			Parent = hwFolder,
		})
	end

	-- Highway Streetlights
	local lightZ = hw.StartZ + 60
	while lightZ < hw.EndZ do
		-- Alternate left and right side
		local side = if (math.floor(lightZ / hw.StreetlightInterval) % 2 == 0) then -1 else 1
		local poleX = side * (hw.Width / 2 + 3)

		local pole = makePart({
			Name = "HighwayLightPole",
			Size = Vector3.new(1.6, hw.StreetlightHeight, 1.6),
			CFrame = CFrame.new(poleX, roadY + hw.StreetlightHeight / 2, lightZ),
			Color = Color3.fromRGB(60, 64, 72),
			Material = Enum.Material.Metal,
			Parent = hwFolder,
		})

		-- Cantilever arm extending towards road
		makePart({
			Name = "LightArm",
			Size = Vector3.new(14, 1.2, 1.2),
			CFrame = CFrame.new(poleX - side * 7, roadY + hw.StreetlightHeight - 0.6, lightZ),
			Color = Color3.fromRGB(60, 64, 72),
			Material = Enum.Material.Metal,
			Parent = hwFolder,
		})

		-- Luminaire fixture with PointLight
		local fixture = makePart({
			Name = "Luminaire",
			Size = Vector3.new(3, 1, 2),
			CFrame = CFrame.new(poleX - side * 13, roadY + hw.StreetlightHeight - 1.2, lightZ),
			Color = Color3.fromRGB(255, 245, 210),
			Material = Enum.Material.Neon,
			Parent = hwFolder,
		})

		local light = Instance.new("PointLight")
		light.Brightness = 2.5
		light.Range = 60
		light.Color = Color3.fromRGB(255, 240, 200)
		light.Parent = fixture

		lightZ += hw.StreetlightInterval
	end

	-- Overhead Highway Sign Gantries
	local gantryZ = hw.StartZ + 250
	local gantrySigns = {
		"❄️ GLACIER PASS - NORTH TERMINUS",
		"🍁 AUTUMN REDWOOD VALLEY - SCENIC OVERLOOK",
		"🏎️ CENTRAL MOTORS - RESTORATION GARAGE & SPAWNS",
		"🏜️ RED ROCK DESERT - HIGHWAY 66 EXPRESS",
		"🌲 ALPINE PASS - MOUNTAIN SUMMIT",
	}
	local signIdx = 1

	while gantryZ < hw.EndZ do
		local gantryHeight = 22
		-- Support towers
		makePart({
			Name = "GantryTower_W",
			Size = Vector3.new(2.4, gantryHeight, 2.4),
			CFrame = CFrame.new(-hw.Width / 2 - 2, roadY + gantryHeight / 2, gantryZ),
			Color = Color3.fromRGB(50, 54, 62),
			Material = Enum.Material.Metal,
			Parent = hwFolder,
		})
		makePart({
			Name = "GantryTower_E",
			Size = Vector3.new(2.4, gantryHeight, 2.4),
			CFrame = CFrame.new(hw.Width / 2 + 2, roadY + gantryHeight / 2, gantryZ),
			Color = Color3.fromRGB(50, 54, 62),
			Material = Enum.Material.Metal,
			Parent = hwFolder,
		})

		-- Overhead span
		makePart({
			Name = "GantryBeam",
			Size = Vector3.new(hw.Width + 4, 3, 2.4),
			CFrame = CFrame.new(0, roadY + gantryHeight - 1.5, gantryZ),
			Color = Color3.fromRGB(50, 54, 62),
			Material = Enum.Material.Metal,
			Parent = hwFolder,
		})

		-- Sign Board
		local signText = gantrySigns[((signIdx - 1) % #gantrySigns) + 1]
		local signBoard = makePart({
			Name = "HighwaySignBoard",
			Size = Vector3.new(46, 7, 1),
			CFrame = CFrame.new(0, roadY + gantryHeight - 4, gantryZ),
			Color = Color3.fromRGB(18, 90, 48),
			Material = Enum.Material.SmoothPlastic,
			Parent = hwFolder,
		})

		local sGui = Instance.new("SurfaceGui")
		sGui.Name = "SignGui"
		sGui.Face = Enum.NormalId.Back
		sGui.CanvasSize = Vector2.new(800, 120)
		sGui.LightInfluence = 0.2
		sGui.Parent = signBoard

		local label = Instance.new("TextLabel")
		label.Size = UDim2.fromScale(1, 1)
		label.BackgroundTransparency = 1
		label.FontFace = Font.fromEnum(Enum.Font.GothamBlack)
		label.Text = signText
		label.TextColor3 = Color3.fromRGB(255, 255, 255)
		label.TextSize = 34
		label.TextScaled = true
		label.Parent = sGui

		signIdx += 1
		gantryZ += hw.SignGantryInterval
	end
end

-- ============================================================================
-- 4. RANDOMLY GENERATED HIGHWAY OBSTACLES (SLALOM & DODGING COURSES)
-- ============================================================================

local function spawnObstacleJerseyBarricade(parent: Instance, cframe: CFrame)
	local barrier = makePart({
		Name = "JerseyBarricade",
		Size = Vector3.new(18, 5, 3.5),
		CFrame = cframe * CFrame.new(0, 2.5, 0),
		Color = Color3.fromRGB(225, 120, 30),
		Material = Enum.Material.Concrete,
		Parent = parent,
	})

	-- Reflective caution stripes
	local stripe = makePart({
		Name = "CautionStripe",
		Size = Vector3.new(18.2, 1.2, 3.6),
		CFrame = barrier.CFrame,
		Color = Color3.fromRGB(245, 245, 245),
		Material = Enum.Material.SmoothPlastic,
		Parent = parent,
	})

	-- Flashing amber beacon light on top
	local beacon = makePart({
		Name = "HazardBeacon",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(1.8, 1.8, 1.8),
		CFrame = barrier.CFrame * CFrame.new(0, 3.2, 0) * CFrame.Angles(0, 0, math.rad(90)),
		Color = Color3.fromRGB(255, 160, 0),
		Material = Enum.Material.Neon,
		Parent = parent,
	})
	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(255, 160, 0)
	light.Range = 24
	light.Brightness = 3
	light.Parent = beacon
end

local function spawnObstacleCargoCrates(parent: Instance, cframe: CFrame)
	-- Stack of wooden shipping crates
	makePart({
		Name = "CargoCrate_Large",
		Size = Vector3.new(10, 8, 10),
		CFrame = cframe * CFrame.new(0, 4, 0),
		Color = Color3.fromRGB(140, 95, 55),
		Material = Enum.Material.Wood,
		Parent = parent,
	})

	makePart({
		Name = "CargoCrate_Small",
		Size = Vector3.new(6, 6, 6),
		CFrame = cframe * CFrame.new(5, 3, 2),
		Color = Color3.fromRGB(160, 110, 65),
		Material = Enum.Material.Wood,
		Parent = parent,
	})
end

local function spawnObstacleWreckedChassis(parent: Instance, cframe: CFrame)
	local chassis = makePart({
		Name = "WreckedChassis",
		Size = Vector3.new(8, 4.5, 16),
		CFrame = cframe * CFrame.new(0, 2.25, 0) * CFrame.Angles(0, math.rad(rng:NextNumber(-25, 25)), 0),
		Color = Color3.fromRGB(68, 38, 28),
		Material = Enum.Material.CorrodedMetal,
		Parent = parent,
	})

	-- Road hazard flare
	local flare = makePart({
		Name = "RoadFlare",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(1.2, 0.8, 0.8),
		CFrame = cframe * CFrame.new(7, 0.4, 4) * CFrame.Angles(0, 0, math.rad(90)),
		Color = Color3.fromRGB(255, 60, 30),
		Material = Enum.Material.Neon,
		Parent = parent,
	})
	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(255, 60, 30)
	light.Range = 28
	light.Brightness = 3.5
	light.Parent = flare
end

local function spawnObstacleTireWall(parent: Instance, cframe: CFrame)
	local wall = makePart({
		Name = "TireChicaneWall",
		Size = Vector3.new(16, 4.5, 5),
		CFrame = cframe * CFrame.new(0, 2.25, 0),
		Color = Color3.fromRGB(30, 32, 35),
		Material = Enum.Material.SmoothPlastic,
		Parent = parent,
	})

	-- High-visibility yellow impact bumper
	makePart({
		Name = "TireBumper",
		Size = Vector3.new(16.2, 1.4, 5.2),
		CFrame = wall.CFrame,
		Color = Color3.fromRGB(255, 204, 0),
		Material = Enum.Material.Neon,
		Parent = parent,
	})
end

local function generateHighwayObstacles(mapFolder: Folder)
	local obstacleFolder = Instance.new("Folder")
	obstacleFolder.Name = "HighwayObstacles"
	obstacleFolder.Parent = mapFolder

	local hw = WorldConfig.Highway
	-- Lane centers: Lane 1 (-21), Lane 2 (-7), Lane 3 (+7), Lane 4 (+21)
	local laneCenters = { -21, -7, 7, 21 }

	local currentZ = hw.StartZ + 160
	while currentZ < hw.EndZ - 160 do
		-- Keep central plaza (Z: -250 to 250) clear for clean spawns and showroom access
		if math.abs(currentZ) > 280 then
			-- Pick 1 or 2 lanes to block, leaving at least 2 clear lanes for driving
			local blockedLaneIdx = rng:NextInteger(1, #laneCenters)
			local targetX = laneCenters[blockedLaneIdx]

			local obstacleRoll = rng:NextInteger(1, 4)
			local cf = CFrame.new(targetX, hw.RoadY, currentZ)

			if obstacleRoll == 1 then
				spawnObstacleJerseyBarricade(obstacleFolder, cf)
			elseif obstacleRoll == 2 then
				spawnObstacleCargoCrates(obstacleFolder, cf)
			elseif obstacleRoll == 3 then
				spawnObstacleWreckedChassis(obstacleFolder, cf)
			else
				spawnObstacleTireWall(obstacleFolder, cf)
			end
		end

		currentZ += rng:NextNumber(WorldConfig.ObstacleIntervalMin, WorldConfig.ObstacleIntervalMax)
	end
end

-- ============================================================================
-- 5. BARNS & CENTRAL RESTORATION GARAGE (TAGGED FOR GAMEPLAY)
-- ============================================================================

local function buildRusticBarn(position: Vector3, headingDeg: number, carId: string, parent: Instance)
	local barnModel = Instance.new("Model")
	barnModel.Name = "RusticBarn_" .. carId
	barnModel.Parent = parent

	local barnCF = CFrame.new(position) * CFrame.Angles(0, math.rad(headingDeg), 0)
	local width, length, height = 36, 48, 24

	-- Barn Foundation / Floor
	makePart({
		Name = "BarnFloor",
		Size = Vector3.new(width, 1, length),
		CFrame = barnCF * CFrame.new(0, 0.5, 0),
		Color = Color3.fromRGB(65, 48, 36),
		Material = Enum.Material.WoodPlanks,
		Parent = barnModel,
	})

	-- Back Wall
	makePart({
		Name = "BackWall",
		Size = Vector3.new(width, height, 2),
		CFrame = barnCF * CFrame.new(0, height / 2 + 1, -length / 2 + 1),
		Color = Color3.fromRGB(120, 42, 34),
		Material = Enum.Material.WoodPlanks,
		Parent = barnModel,
	})

	-- Left Wall
	makePart({
		Name = "LeftWall",
		Size = Vector3.new(2, height, length),
		CFrame = barnCF * CFrame.new(-width / 2 + 1, height / 2 + 1, 0),
		Color = Color3.fromRGB(120, 42, 34),
		Material = Enum.Material.WoodPlanks,
		Parent = barnModel,
	})

	-- Right Wall
	makePart({
		Name = "RightWall",
		Size = Vector3.new(2, height, length),
		CFrame = barnCF * CFrame.new(width / 2 - 1, height / 2 + 1, 0),
		Color = Color3.fromRGB(120, 42, 34),
		Material = Enum.Material.WoodPlanks,
		Parent = barnModel,
	})

	-- Front Doorway Pillars
	makePart({
		Name = "FrontLeftPillar",
		Size = Vector3.new(10, height, 2),
		CFrame = barnCF * CFrame.new(-width / 2 + 5, height / 2 + 1, length / 2 - 1),
		Color = Color3.fromRGB(120, 42, 34),
		Material = Enum.Material.WoodPlanks,
		Parent = barnModel,
	})
	makePart({
		Name = "FrontRightPillar",
		Size = Vector3.new(10, height, 2),
		CFrame = barnCF * CFrame.new(width / 2 - 5, height / 2 + 1, length / 2 - 1),
		Color = Color3.fromRGB(120, 42, 34),
		Material = Enum.Material.WoodPlanks,
		Parent = barnModel,
	})

	-- Barn Roof (A-Frame Peak)
	local roofSlope = 16
	makePart({
		Name = "RoofLeft",
		Size = Vector3.new(width / 2 + 3, 2, length + 4),
		CFrame = barnCF * CFrame.new(-width / 4, height + 4, 0) * CFrame.Angles(0, 0, math.rad(-25)),
		Color = Color3.fromRGB(55, 30, 25),
		Material = Enum.Material.CorrodedMetal,
		Parent = barnModel,
	})
	makePart({
		Name = "RoofRight",
		Size = Vector3.new(width / 2 + 3, 2, length + 4),
		CFrame = barnCF * CFrame.new(width / 4, height + 4, 0) * CFrame.Angles(0, 0, math.rad(25)),
		Color = Color3.fromRGB(55, 30, 25),
		Material = Enum.Material.CorrodedMetal,
		Parent = barnModel,
	})

	-- Interior Barn Spot for the Barn Find Vehicle
	local spot = makePart({
		Name = "BarnSpot",
		Size = Vector3.new(12, 1, 20),
		CFrame = barnCF * CFrame.new(0, 0.6, 0),
		Color = Color3.fromRGB(180, 110, 40),
		Material = Enum.Material.CorrodedMetal,
		CanCollide = false,
		Transparency = 0.5,
		Parent = barnModel,
	})
	spot:SetAttribute("Car", carId)
	CollectionService:AddTag(spot, BARN_SPOT_TAG)

	-- Access dirt driveway connecting back towards the highway
	local roadDir = -math.sign(position.X)
	makePart({
		Name = "BarnDriveway",
		Size = Vector3.new(18, 0.4, 70),
		CFrame = CFrame.new(position.X + roadDir * 35, 0.2, position.Z),
		Color = Color3.fromRGB(95, 78, 62),
		Material = Enum.Material.Ground,
		Parent = barnModel,
	})
end

local function buildCentralDealershipAndGarage(mapFolder: Folder)
	local hubFolder = Instance.new("Folder")
	hubFolder.Name = "CentralPlaza"
	hubFolder.Parent = mapFolder

	-- Main Plaza Esplanade
	makePart({
		Name = "PlazaEsplanade",
		Size = Vector3.new(180, 1.2, 160),
		CFrame = CFrame.new(0, 0.6, 60),
		Color = Color3.fromRGB(48, 52, 60),
		Material = Enum.Material.Concrete,
		Parent = hubFolder,
	})

	-- Dealership Showroom Pavilion
	local showCF = CFrame.new(0, 1, 0)
	makePart({
		Name = "ShowroomFloor",
		Size = Vector3.new(80, 2, 60),
		CFrame = showCF * CFrame.new(0, 1, 0),
		Color = Color3.fromRGB(240, 242, 245),
		Material = Enum.Material.SmoothPlastic,
		Parent = hubFolder,
	})
	makePart({
		Name = "ShowroomGlassRoof",
		Size = Vector3.new(84, 1.5, 64),
		CFrame = showCF * CFrame.new(0, 20, 0),
		Color = Color3.fromRGB(140, 200, 240),
		Material = Enum.Material.Glass,
		Transparency = 0.5,
		Parent = hubFolder,
	})

	-- Showroom Neon Header
	local header = makePart({
		Name = "DealershipSign",
		Size = Vector3.new(48, 5, 2),
		CFrame = showCF * CFrame.new(0, 22.5, 30),
		Color = Color3.fromRGB(0, 160, 255),
		Material = Enum.Material.Neon,
		Parent = hubFolder,
	})
	local hGui = Instance.new("SurfaceGui")
	hGui.Name = "HeaderGui"
	hGui.Face = Enum.NormalId.Front
	hGui.CanvasSize = Vector2.new(600, 80)
	hGui.Parent = header
	local hLabel = Instance.new("TextLabel")
	hLabel.Size = UDim2.fromScale(1, 1)
	hLabel.BackgroundTransparency = 1
	hLabel.FontFace = Font.fromEnum(Enum.Font.GothamBlack)
	hLabel.Text = "★ CENTRAL MOTORS DEALERSHIP ★"
	hLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	hLabel.TextSize = 26
	hLabel.Parent = hGui

	-- Restoration Garage Workshop Building
	local garageCF = CFrame.new(90, 1, 50)
	makePart({
		Name = "GarageBuilding",
		Size = Vector3.new(50, 20, 60),
		CFrame = garageCF * CFrame.new(0, 10, 0),
		Color = Color3.fromRGB(65, 70, 80),
		Material = Enum.Material.Concrete,
		Parent = hubFolder,
	})

	-- Restoration Garage Sign
	local gSign = makePart({
		Name = "GarageSign",
		Size = Vector3.new(34, 4, 1.5),
		CFrame = garageCF * CFrame.new(0, 22, -29),
		Color = Color3.fromRGB(255, 140, 0),
		Material = Enum.Material.Neon,
		Parent = hubFolder,
	})
	local gGui = Instance.new("SurfaceGui")
	gGui.Name = "GarageGui"
	gGui.Face = Enum.NormalId.Back
	gGui.CanvasSize = Vector2.new(600, 80)
	gGui.Parent = gSign
	local gLabel = Instance.new("TextLabel")
	gLabel.Size = UDim2.fromScale(1, 1)
	gLabel.BackgroundTransparency = 1
	gLabel.FontFace = Font.fromEnum(Enum.Font.GothamBlack)
	gLabel.Text = "RESTORATION WORKSHOP & DROP-OFF"
	gLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	gLabel.TextSize = 24
	gLabel.Parent = gGui

	-- Drop-Off Zone Pad (Tagged `GarageDropOff` for BarnService)
	local dropOffPad = makePart({
		Name = "GarageDropOffZone",
		Size = Vector3.new(24, 0.4, 28),
		CFrame = CFrame.new(90, 1.2, 10),
		Color = Color3.fromRGB(255, 140, 0),
		Material = Enum.Material.Neon,
		CanCollide = false,
		Parent = hubFolder,
	})
	CollectionService:AddTag(dropOffPad, DROP_OFF_TAG)

	-- Visual drop-off chevron floor stripes
	for s = -10, 10, 5 do
		makePart({
			Name = "DropOffStripe",
			Size = Vector3.new(20, 0.1, 2),
			CFrame = CFrame.new(90, 1.45, 10 + s) * CFrame.Angles(0, math.rad(25), 0),
			Color = Color3.fromRGB(25, 25, 25),
			Material = Enum.Material.SmoothPlastic,
			CanCollide = false,
			Parent = hubFolder,
		})
	end
end

-- ============================================================================
-- MAIN WORLD BUILD ENTRY POINT
-- ============================================================================

function WorldService.start()
	local mapFolder = getWorldFolder()
	mapFolder:ClearAllChildren()

	generateBiomeTerrain(mapFolder)
	generateStraightHighway(mapFolder)
	generateHighwayObstacles(mapFolder)
	generateBiomeFoliage(mapFolder)
	buildCentralDealershipAndGarage(mapFolder)

	-- Build barns in the 4 outer biomes
	for biomeKey, biome in WorldConfig.Biomes do
		if biome.BarnSpot then
			buildRusticBarn(biome.BarnSpot, biome.BarnHeading or 0, biome.CarReward or "Porsche", mapFolder)
		end
	end

	print("[WorldService] Expansive procedural world generated with 5 biomes, straight highways, obstacles, and barns.")
end

return WorldService
