--[[
	CarService -- spawns the cars and hands control of one to whoever sits in it.

	Control is shared deliberately. The driver's client gets network ownership of
	the car's parts and drives them locally, so the car answers the keyboard with
	no round trip; it also relays its input up here, and this service runs the
	same CarDrive maths on it. That second path is what makes the car work if
	ownership has not transferred yet, and keeps the constraint values the server
	replicates to other players in step with what the driver is doing.

	Everything that has to be authoritative stays here: seating, the lights,
	holding an empty car still, and putting a flipped one back on its wheels.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local CarFolder = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Car")
local CarConfig = require(CarFolder.CarConfig)
local CarDrive = require(CarFolder.CarDrive)
local CarModel = require(CarFolder.CarModel)

local RESET = CarConfig.Reset

local GROUND_PROBE_ABOVE = 10
local GROUND_PROBE_DEPTH = 200

local CarService = {}

type Entry = {
	car: Model,
	state: CarDrive.State,
	seat: any, -- the VehicleSeat; typed loosely so Sit/Occupant need no casts
	driver: Player?,
	input: CarDrive.Input,
	flippedFor: number,
}

local entries: { Entry } = {}
local inputRemote: RemoteEvent

local function debugPrint(message: string, ...)
	if CarConfig.Debug then
		print(("[CarService] " .. message):format(...))
	end
end

local function forEachPart(car: Model, apply: (BasePart) -> ())
	for _, descendant in car:GetDescendants() do
		if descendant:IsA("BasePart") then
			apply(descendant)
		end
	end
end

local function setNetworkOwner(car: Model, owner: Player?): number
	local count = 0
	forEachPart(car, function(part)
		if part.Anchored then
			return
		end
		local ok = pcall(function()
			if owner then
				part:SetNetworkOwner(owner)
			else
				part:SetNetworkOwnershipAuto()
			end
		end)
		if ok then
			count += 1
		end
	end)
	return count
end

local function setLights(car: Model, on: boolean)
	forEachPart(car, function(part)
		if part:GetAttribute("Lamp") == nil then
			return
		end
		part.Material = if on then Enum.Material.Neon else Enum.Material.SmoothPlastic
		local lamp = part:FindFirstChildWhichIsA("Light")
		if lamp then
			lamp.Enabled = on
		end
	end)
end

local function findEntry(car: Model): Entry?
	for _, entry in entries do
		if entry.car == car then
			return entry
		end
	end
	return nil
end

local function entryForDriver(player: Player): Entry?
	for _, entry in entries do
		if entry.driver == player then
			return entry
		end
	end
	return nil
end

local function resetCar(entry: Entry)
	local pivot = entry.car:GetAttribute("SpawnPivot")
	if typeof(pivot) ~= "CFrame" then
		return
	end

	entry.car:PivotTo(pivot)
	forEachPart(entry.car, function(part)
		part.AssemblyLinearVelocity = Vector3.zero
		part.AssemblyAngularVelocity = Vector3.zero
	end)
	CarDrive.park(entry.state)
	debugPrint("reset %s to its spawn", entry.car.Name)
end

local function onOccupantChanged(entry: Entry)
	local occupant = entry.seat.Occupant
	local prompt = entry.seat:FindFirstChildOfClass("ProximityPrompt")
	if prompt then
		prompt.Enabled = occupant == nil
	end

	local driver = occupant and Players:GetPlayerFromCharacter(occupant.Parent)
	entry.driver = driver
	entry.input = CarDrive.idleInput()

	if driver then
		local owned = setNetworkOwner(entry.car, driver)
		setLights(entry.car, true)
		debugPrint("%s is driving; network ownership of %d parts handed over", driver.Name, owned)
	else
		setNetworkOwner(entry.car, nil)
		CarDrive.park(entry.state)
		setLights(entry.car, false)
		debugPrint("%s is empty again", entry.car.Name)
	end
end

local function bindSeat(entry: Entry, seat: any)
	local prompt = seat:FindFirstChildOfClass("ProximityPrompt")
	local isDriverSeat = seat:GetAttribute("IsDriverSeat") == true

	if prompt then
		prompt.Triggered:Connect(function(player: Player)
			local character = player.Character
			local humanoid = character and character:FindFirstChildOfClass("Humanoid")
			if not humanoid or humanoid.Health <= 0 or humanoid.SeatPart then
				return
			end
			seat:Sit(humanoid)
		end)
	end

	if isDriverSeat then
		seat:GetPropertyChangedSignal("Occupant"):Connect(function()
			onOccupantChanged(entry)
		end)
	else
		seat:GetPropertyChangedSignal("Occupant"):Connect(function()
			if prompt then
				prompt.Enabled = seat.Occupant == nil
			end
		end)
	end
end

local function carContainer(): Folder
	local existing = Workspace:FindFirstChild("Cars")
	if existing and existing:IsA("Folder") then
		return existing
	end

	local folder = Instance.new("Folder")
	folder.Name = "Cars"
	folder.Parent = Workspace
	return folder
end

-- Drops a spawn point onto whatever floor is under it, so a car never starts
-- with its wheels inside the map. The ray starts only a little above the point,
-- which keeps it beneath any roof over the spawn, and passes through parts a car
-- would fall through (the dealership's display pads, for one).
local function restOnGround(origin: CFrame): CFrame
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { carContainer() }
	params.RespectCanCollide = true

	local from = origin.Position + Vector3.new(0, GROUND_PROBE_ABOVE, 0)
	local hit = Workspace:Raycast(from, Vector3.new(0, -GROUND_PROBE_DEPTH, 0), params)
	if not hit then
		return origin
	end
	return origin.Rotation + hit.Position + Vector3.new(0, CarConfig.Dimensions.WheelRadius + 0.2, 0)
end

-- Cars left in Workspace.Cars from Studio (see placeInStudio) are stand-ins
-- marking where cars go. Takes them out and returns where each one stood.
local function takeStandIns(): { CFrame }
	local origins = {}
	for _, standIn in carContainer():GetChildren() do
		if standIn:IsA("Model") and standIn:GetAttribute("DriveableCar") and standIn.PrimaryPart then
			table.insert(origins, CarModel.originOf(standIn))
			standIn:Destroy()
		end
	end
	return origins
end

local function defaultSpawns(): { CFrame }
	local origins = {}
	for _, spawn in CarConfig.Spawns do
		table.insert(origins, restOnGround(spawn))
	end
	return origins
end

--[[
	Builds a car at `pivot` (its car-space origin) and wires up its seats.
]]
function CarService.spawnCar(pivot: CFrame): Model?
	local car = CarModel.build(pivot)
	car.Parent = carContainer()
	car:SetAttribute("SpawnPivot", car:GetPivot())

	local state = CarDrive.collect(car)
	local driverSeat = car:FindFirstChild("DriverSeat")

	if not state or not driverSeat then
		warn("CarService: built a car with no drivable constraints or no driver seat")
		car:Destroy()
		return nil
	end

	local entry: Entry = {
		car = car,
		state = state,
		seat = driverSeat,
		driver = nil,
		input = CarDrive.idleInput(),
		flippedFor = 0,
	}
	table.insert(entries, entry)

	for _, descendant in car:GetDescendants() do
		if descendant:IsA("VehicleSeat") or descendant:IsA("Seat") then
			bindSeat(entry, descendant)
		end
	end

	CarDrive.park(state)
	setLights(car, false)

	return car
end

local function onInputReceived(player: Player, raw: any)
	local entry = entryForDriver(player)
	if not entry then
		return -- not driving anything, so nothing to steer
	end
	entry.input = CarDrive.sanitizeInput(raw)
end

-- Applies the relayed input, and recovers cars that are stuck or lost.
local function step(deltaTime: number)
	for _, entry in entries do
		local chassis = entry.car.PrimaryPart
		if not chassis then
			continue
		end

		if entry.driver then
			CarDrive.apply(entry.state, entry.input, deltaTime)
			entry.flippedFor = 0
			continue
		end

		if chassis.Position.Y < RESET.MinHeight then
			resetCar(entry)
			entry.flippedFor = 0
		elseif chassis.CFrame.UpVector.Y < RESET.FlippedUpThreshold then
			entry.flippedFor += deltaTime
			if entry.flippedFor >= RESET.FlippedSeconds then
				resetCar(entry)
				entry.flippedFor = 0
			end
		else
			entry.flippedFor = 0
		end
	end
end

function CarService.start()
	inputRemote = Instance.new("RemoteEvent")
	inputRemote.Name = "CarInput"
	inputRemote.Parent = ReplicatedStorage
	inputRemote.OnServerEvent:Connect(onInputReceived)

	local origins = takeStandIns()
	if #origins == 0 then
		origins = defaultSpawns()
	end
	for _, origin in origins do
		CarService.spawnCar(origin)
	end

	Players.PlayerRemoving:Connect(function(player)
		local entry = entryForDriver(player)
		if entry then
			entry.driver = nil
			entry.input = CarDrive.idleInput()
			CarDrive.park(entry.state)
			setLights(entry.car, false)
		end
	end)

	RunService.PreSimulation:Connect(step)

	debugPrint("%d cars spawned -- %s", #entries, CarModel.describe())
end

--[[
	For Studio's command bar in edit mode, so the cars show while you build:

		require(game.ServerScriptService.Server.CarService).placeInStudio()

	Puts anchored stand-ins for the cars in Workspace.Cars: at CarConfig.Spawns
	the first time, and after that rebuilt wherever they stand, so run it again
	after changing CarConfig or the meshes. Drag a stand-in to move where its car
	spawns, duplicate one for another car, or delete one. When the game starts,
	each stand-in is swapped for a working car in the same spot.
]]
function CarService.placeInStudio()
	local origins = takeStandIns()
	if #origins == 0 then
		origins = defaultSpawns()
	end

	for _, origin in origins do
		local car = CarModel.build(origin)
		for _, descendant in car:GetDescendants() do
			if descendant:IsA("BasePart") then
				descendant.Anchored = true
			end
		end
		car.Parent = carContainer()
	end
end

return CarService
