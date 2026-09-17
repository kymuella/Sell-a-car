--[[
	CarService -- spawns the cars and hands control of one to whoever sits in it.

	Whoever drives a car simulates it: the driver's client gets network ownership
	and runs CarPhysics on its own input, so the car answers the keyboard with no
	round trip. An empty car belongs to the server, which runs CarPhysics to hold
	it parked on its springs. Only one side writes a car's forces at a time --
	two writers would fight over the replicated values.

	The driver also relays its input here. The server does not drive with it; it
	turns it into the SteerInput, Braking and Handbrake attributes, which every
	other client's CarVisuals reads to turn that car's wheels and light its brake
	lamps.

	Everything that has to be authoritative stays here too: seating (and hiding
	whoever sits down, so nothing of them pokes through the bodywork), the lights,
	and putting a flipped or lost car back where it spawned.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local CarFolder = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Car")
local CarConfig = require(CarFolder.CarConfig)
local CarModel = require(CarFolder.CarModel)
local CarPhysics = require(CarFolder.CarPhysics)
local CharacterVisibility = require(script.Parent.CharacterVisibility)

local RESET = CarConfig.Reset
local DRIVE = CarConfig.Driving

local GROUND_PROBE_ABOVE = 10
local GROUND_PROBE_DEPTH = 200
local STEER_STEP = 0.05 -- relayed steering is rounded to this, so a steady hand replicates nothing

local CarService = {}

type Entry = {
	car: Model,
	state: CarPhysics.State,
	seat: any, -- the VehicleSeat; typed loosely so Sit/Occupant need no casts
	driver: Player?,
	input: CarPhysics.Input,
	flippedFor: number,
}

type Placement = {
	car: string, -- template name
	origin: CFrame, -- car-space origin
	snap: boolean, -- drop onto the floor underneath first
	customPaint: Color3?,
	condition: string?, -- nil for restored; see CarConfig.Conditions
	barnFind: boolean?, -- a stand-in for BarnService's car, not one to spawn here
}

local entries: { Entry } = {}
local inputRemote: RemoteEvent
local parked = CarPhysics.parkedInput()

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

-- nil hands the car to the server, which is who simulates an empty car.
local function setNetworkOwner(car: Model, owner: Player?)
	local chassis = car.PrimaryPart
	if chassis and not chassis.Anchored then
		pcall(chassis.SetNetworkOwner, chassis, owner)
	end
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

-- Publishes what the driver is doing, for everyone else's CarVisuals.
local function showInput(entry: Entry, input: CarPhysics.Input)
	local car = entry.car
	local forwardSpeed = CarPhysics.forwardSpeed(entry.state)
	local threshold = DRIVE.BrakeSpeedThreshold
	local braking = input.handbrake
		or (input.throttle > 0.05 and forwardSpeed < -threshold)
		or (input.throttle < -0.05 and forwardSpeed > threshold)

	car:SetAttribute("SteerInput", math.round(input.steer / STEER_STEP) * STEER_STEP)
	car:SetAttribute("Braking", braking)
	car:SetAttribute("Handbrake", input.handbrake)
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
	CarPhysics.park(entry.state)
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
	entry.input = CarPhysics.idleInput()

	if driver then
		setNetworkOwner(entry.car, driver)
		setLights(entry.car, true)
		debugPrint("%s is driving %s", driver.Name, entry.car.Name)
	else
		CarPhysics.park(entry.state)
		setNetworkOwner(entry.car, nil)
		setLights(entry.car, false)
		debugPrint("%s is empty again", entry.car.Name)
	end
	showInput(entry, entry.input)
end

local function bindSeat(entry: Entry, seat: any)
	local prompt = seat:FindFirstChildOfClass("ProximityPrompt")
	local isDriverSeat = seat:GetAttribute("IsDriverSeat") == true
	local occupant: Humanoid? = nil

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

	seat:GetPropertyChangedSignal("Occupant"):Connect(function()
		-- Riders vanish while seated, so no arm or hat pokes through the car.
		local previous = occupant
		occupant = seat.Occupant
		if previous and previous ~= occupant then
			CharacterVisibility.show(previous.Parent)
		end
		if occupant then
			CharacterVisibility.hide(occupant.Parent)
		end

		if isDriverSeat then
			onOccupantChanged(entry)
		elseif prompt then
			prompt.Enabled = occupant == nil
		end
	end)
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

-- Moves a car-space origin down onto whatever floor is under it, so the wheels
-- (`groundOffset` below the origin) just touch it. The ray starts only a little
-- above the point, which keeps it beneath any roof over the spawn, and passes
-- through parts a car would fall through (the dealership's display pads, for one).
local function restOnGround(origin: CFrame, groundOffset: number): CFrame
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { carContainer() }
	params.RespectCanCollide = true

	local from = origin.Position + Vector3.new(0, GROUND_PROBE_ABOVE, 0)
	local hit = Workspace:Raycast(from, Vector3.new(0, -GROUND_PROBE_DEPTH, 0), params)
	if not hit then
		return origin
	end
	return origin.Rotation + hit.Position + Vector3.new(0, groundOffset + 0.2, 0)
end

local function build(placement: Placement): Model
	local car = CarModel.build(placement.car, placement.origin, placement.customPaint, placement.condition)
	if placement.snap then
		local rested = restOnGround(placement.origin, car:GetAttribute("GroundOffset") or 0)
		car:PivotTo(CFrame.new(rested.Position - placement.origin.Position) * car:GetPivot())
	end
	return car
end

-- Cars left in Workspace.Cars from Studio (see placeInStudio) are stand-ins
-- marking where cars go. Takes them out and returns what each one was, and where.
local function takeStandIns(): { Placement }
	local placements: { Placement } = {}
	for _, standIn in carContainer():GetChildren() do
		if not (standIn:IsA("Model") and standIn:GetAttribute("DriveableCar") and standIn.PrimaryPart) then
			continue
		end
		local carName = standIn:GetAttribute("CarTemplate")
		local condition = standIn:GetAttribute("Condition")
		local ok, origin = pcall(CarModel.originOf, standIn)
		table.insert(placements, {
			car = if typeof(carName) == "string" then carName else CarConfig.DefaultCar,
			origin = if ok then origin else standIn:GetPivot(),
			snap = not ok,
			condition = if typeof(condition) == "string" and condition ~= "Restored" then condition else nil,
			barnFind = standIn:GetAttribute("BarnFind") == true,
		})
		standIn:Destroy()
	end
	return placements
end

local function defaultSpawns(): { Placement }
	local placements: { Placement } = {}
	for _, spawn in CarConfig.Spawns do
		table.insert(placements, { car = spawn.Car or CarConfig.DefaultCar, origin = spawn.CFrame, snap = true })
	end
	return placements
end

--[[
	Builds the car `carName` at `origin` (its car-space origin), dropped onto the
	floor unless `snapToGround` is false, in `condition` (nil for restored), and
	wires up its seats.
]]
function CarService.spawnCar(
	carName: string,
	origin: CFrame,
	snapToGround: boolean?,
	customPaint: Color3?,
	condition: string?
): Model?
	local ok, result = pcall(build, {
		car = carName,
		origin = origin,
		snap = snapToGround ~= false,
		customPaint = customPaint,
		condition = condition,
	})
	if not ok then
		warn(("CarService: could not build %s: %s"):format(carName, tostring(result)))
		return nil
	end

	local car: Model = result
	car.Parent = carContainer()
	car:SetAttribute("SpawnPivot", car:GetPivot())

	local state = CarPhysics.collect(car)
	local driverSeat = car:FindFirstChild("DriverSeat")
	if not state or not driverSeat then
		warn(("CarService: %s was built without its forces or a driver seat"):format(carName))
		car:Destroy()
		return nil
	end

	local entry: Entry = {
		car = car,
		state = state,
		seat = driverSeat,
		driver = nil,
		input = CarPhysics.idleInput(),
		flippedFor = 0,
	}
	table.insert(entries, entry)

	for _, descendant in car:GetDescendants() do
		if descendant:IsA("VehicleSeat") or descendant:IsA("Seat") then
			bindSeat(entry, descendant)
		end
	end

	setNetworkOwner(car, nil)
	setLights(car, false)
	showInput(entry, entry.input)
	return car
end

local function onInputReceived(player: Player, raw: any)
	local entry = entryForDriver(player)
	if not entry then
		return -- not driving anything, so nothing to show
	end
	entry.input = CarPhysics.sanitizeInput(raw)
	showInput(entry, entry.input)
end

-- Holds empty cars on their springs, and recovers cars that are stuck or lost.
local function step(deltaTime: number)
	for _, entry in entries do
		local chassis = entry.car.PrimaryPart
		if not chassis or not entry.car.Parent then
			continue
		end

		if entry.driver then
			-- The driver's client simulates this car.
			entry.flippedFor = 0
			continue
		end

		CarPhysics.apply(entry.state, parked, deltaTime)

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

	local placements = takeStandIns()
	if #placements == 0 then
		placements = defaultSpawns()
	end
	for _, placement in placements do
		-- Barn finds are BarnService's to spawn; their stand-ins only show where.
		if not placement.barnFind then
			CarService.spawnCar(placement.car, placement.origin, placement.snap, nil, placement.condition)
		end
	end

	Players.PlayerRemoving:Connect(function(player)
		local entry = entryForDriver(player)
		if entry then
			entry.driver = nil
			entry.input = CarPhysics.idleInput()
			CarPhysics.park(entry.state)
			setNetworkOwner(entry.car, nil)
			setLights(entry.car, false)
			showInput(entry, entry.input)
		end
		CarService.despawnForPlayer(player)
	end)

	RunService.PreSimulation:Connect(step)

	debugPrint("%d cars spawned", #entries)
	for _, entry in entries do
		debugPrint("  %s", CarModel.describe(entry.car))
	end
end

local function placeStandIn(placement: Placement): Model
	local car = build(placement)
	forEachPart(car, function(part)
		part.Anchored = true
	end)
	if placement.barnFind then
		car:SetAttribute("BarnFind", true)
	end
	car.Parent = carContainer()
	return car
end

--[[
	Takes a car out of the game. Anyone still in it is unseated -- their client
	stands them beside it -- and shown again, then the car is destroyed.
]]
function CarService.removeCar(car: Model)
	for i = #entries, 1, -1 do
		if entries[i].car == car then
			table.remove(entries, i)
		end
	end

	for _, seat in car:GetDescendants() do
		if (seat:IsA("Seat") or seat:IsA("VehicleSeat")) and seat.Occupant then
			CharacterVisibility.show(seat.Occupant.Parent)
			local weld = seat:FindFirstChild("SeatWeld")
			if weld then
				weld:Destroy()
			end
		end
	end

	-- A moment for the riders' clients to see their seat weld go and step out.
	task.delay(0.1, function()
		if car.Parent then
			car:Destroy()
		end
	end)
end

--[[
	The player driving `car`, if anyone is.
]]
function CarService.driverOf(car: Model): Player?
	for _, entry in entries do
		if entry.car == car then
			return entry.driver
		end
	end
	return nil
end

--[[
	For Studio's command bar in edit mode, so the cars show while you build:

		require(game.ServerScriptService.Server.CarService).placeInStudio()

	Puts anchored stand-ins for the cars in Workspace.Cars: at CarConfig.Spawns
	the first time, and after that rebuilt wherever they stand, as whichever car
	each one is -- so run it again after changing CarConfig or a template. Drag a
	stand-in to move where its car spawns, or delete one. When the game starts,
	each stand-in is swapped for a working car in the same spot.
]]
function CarService.placeInStudio()
	local placements = takeStandIns()
	if #placements == 0 then
		placements = defaultSpawns()
	end
	for _, placement in placements do
		placeStandIn(placement)
	end
end

--[[
	For Studio's command bar: adds a stand-in for the car `carName` (a template in
	ServerStorage.CarModels) on the ground where the camera is looking, facing
	away from the camera, in `condition` (nil for restored).

		require(game.ServerScriptService.Server.CarService).addToStudio("Porsche")
		require(game.ServerScriptService.Server.CarService).addToStudio("Porsche", "Rusted")
]]
function CarService.addToStudio(carName: string, condition: string?): Model
	local camera = Workspace.CurrentCamera
	local focus = if camera then camera.Focus.Position else Vector3.zero
	local look = if camera then camera.CFrame.LookVector * Vector3.new(1, 0, 1) else Vector3.zero
	if look.Magnitude < 0.01 then
		look = Vector3.new(0, 0, -1)
	end
	return placeStandIn({
		car = carName,
		origin = CFrame.lookAt(focus, focus + look.Unit),
		snap = true,
		condition = condition,
	})
end

--[[
	For BarnService.placeInStudio: a stand-in for a barn's car at `origin`.
]]
function CarService.placeBarnStandIn(carName: string, origin: CFrame): Model
	return placeStandIn({ car = carName, origin = origin, snap = true, condition = "Rusted", barnFind = true })
end

local playerCars: { [Player]: Model } = {}

function CarService.despawnForPlayer(player: Player): boolean
	local car = playerCars[player]
	if car then
		playerCars[player] = nil
		CarService.removeCar(car)
		return true
	end
	return false
end

function CarService.spawnForPlayer(player: Player, carId: string, customPaint: Color3?): (boolean, string, Model?)
	CarService.despawnForPlayer(player)

	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	local spawnCFrame: CFrame

	if hrp and hrp:IsA("BasePart") then
		local look = hrp.CFrame.LookVector
		local flatLook = Vector3.new(look.X, 0, look.Z)
		if flatLook.Magnitude > 0.01 then
			flatLook = flatLook.Unit
		else
			flatLook = Vector3.new(0, 0, -1)
		end
		local spawnPos = hrp.Position + flatLook * 16 + Vector3.new(0, 2, 0)
		spawnCFrame = CFrame.lookAt(spawnPos, spawnPos + flatLook)
	else
		local defaultSpawn = CarConfig.Spawns[1]
		spawnCFrame = defaultSpawn and defaultSpawn.CFrame or CFrame.new(0, 2, 40)
	end

	local car = CarService.spawnCar(carId, spawnCFrame, true, customPaint)
	if not car then
		return false, "Failed to build car", nil
	end

	car:SetAttribute("OwnerUserId", player.UserId)
	playerCars[player] = car

	return true, "Car spawned!", car
end

function CarService.teleportPlayerToPlay(player: Player): boolean
	local targetCF = CarConfig.PlayingArea or CFrame.new(0, 3, 130)
	local char = player.Character
	if not char then
		return false
	end

	local entry = entryForDriver(player)
	if entry and entry.car and entry.car.PrimaryPart then
		local rested = restOnGround(targetCF, entry.car:GetAttribute("GroundOffset") or 0)
		-- `rested` is the car-space origin; the car's pivot is its chassis.
		entry.car:PivotTo(rested * CFrame.new(entry.car:GetAttribute("OriginOffset") or Vector3.zero))
		forEachPart(entry.car, function(part)
			part.AssemblyLinearVelocity = Vector3.zero
			part.AssemblyAngularVelocity = Vector3.zero
		end)
		return true
	end

	local hrp = char:FindFirstChild("HumanoidRootPart")
	if hrp and hrp:IsA("BasePart") then
		hrp.CFrame = targetCF + Vector3.new(0, 3, 0)
		hrp.AssemblyLinearVelocity = Vector3.zero
		return true
	end

	return false
end

return CarService
