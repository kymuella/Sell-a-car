--[[
	WorldService -- Manages world validation, dynamic plot assignment queries,
	and ensures permanent map geometry under Workspace.Map is ready for gameplay.

	Permanent geometry (GarageDistrict, Roads, Stages, Gates, Barns, RestorationGarage)
	lives statically in Workspace.Map inside Roblox Studio Edit Mode.
	Runtime procedural generation has been retired so Studio Edit Mode is the single
	source of truth for physical world geometry.
]]

local Workspace = game:GetService("Workspace")

local WorldService = {}

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

--[[
	Find a plot model under Workspace.Map.GarageDistrict.Plots by number (1..12) or string ID ("Plot_01").
]]
function WorldService.getPlot(plotIdOrNum: string | number): Model?
	local mapFolder = getWorldFolder()
	local gd = mapFolder:FindFirstChild("GarageDistrict")
	local plotsFolder = gd and gd:FindFirstChild("Plots")
	if not plotsFolder then
		return nil
	end

	local targetName = if typeof(plotIdOrNum) == "number"
		then string.format("Plot_%02d", plotIdOrNum)
		else plotIdOrNum

	return plotsFolder:FindFirstChild(targetName) :: Model?
end

--[[
	Returns all plot models currently in Workspace.Map.GarageDistrict.Plots.
]]
function WorldService.getAllPlots(): { Model }
	local mapFolder = getWorldFolder()
	local gd = mapFolder:FindFirstChild("GarageDistrict")
	local plotsFolder = gd and gd:FindFirstChild("Plots")
	if not plotsFolder then
		return {}
	end

	local list = {}
	for _, child in plotsFolder:GetChildren() do
		if child:IsA("Model") then
			table.insert(list, child)
		end
	end
	return list
end

function WorldService.start()
	local mapFolder = getWorldFolder()

	-- Clean up legacy baseplate to prevent z-fighting with permanent ground
	local legacyBaseplate = Workspace:FindFirstChild("Baseplate")
	if legacyBaseplate and legacyBaseplate:IsA("BasePart") then
		legacyBaseplate.Transparency = 1
		legacyBaseplate.CanCollide = false
	end

	-- Verify permanent GarageDistrict in Workspace.Map
	local garageDistrict = mapFolder:FindFirstChild("GarageDistrict")
	if garageDistrict then
		local plotsFolder = garageDistrict:FindFirstChild("Plots")
		local plotCount = plotsFolder and #plotsFolder:GetChildren() or 0
		print(string.format("[WorldService] Permanent GarageDistrict verified in Workspace.Map with %d plots.", plotCount))
	else
		warn("[WorldService] Warning: Workspace.Map.GarageDistrict not found!")
	end

	-- Verify permanent RestorationGarage in Workspace.Map
	local restGarage = mapFolder:FindFirstChild("RestorationGarage")
	if restGarage then
		print("[WorldService] Permanent RestorationGarage verified in Workspace.Map.")
	end

	-- Runtime procedural generation of permanent geometry is permanently disabled.
	-- Geometry is authored and maintained in Studio Edit Mode under Workspace.Map.
	print("[WorldService] World geometry loaded from permanent Studio Workspace.Map. Runtime generation disabled.")
end

return WorldService
