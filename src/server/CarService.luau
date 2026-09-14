--[[
	CarService -- spawns the cars and hands control of one to whoever sits in it.

	The driving itself happens on the driver's client (see CarController): this
	service gives them network ownership of the car's parts so their input moves
	the car without a round trip to the server. What stays here is everything that
	has to be authoritative -- seating people, the lights, parking an empty car,
	and putting a flipped one back on its wheels.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local CarFolder = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Car")
local CarConfig = require(CarFolder.CarConfig)
local CarModel = require(CarFolder.CarModel)

local RESET = CarConfig.Reset

local CarService = {}

local cars: { Model } = {}

local function forEachPart(car: Model, apply: (BasePart) -> ())
	for _, descendant in car:GetDescendants() do
		if descendant:IsA("BasePart") then
			apply(descendant)
		end
	end
end

local function isSeat(instance: Instance): boolean
	return instance:IsA("VehicleSeat") or instance:IsA("Seat")
end

local function setNetworkOwner(car: Model, owner: Player?)
	forEachPart(car, function(part)
		if part.Anchored then
			return
		end
		if owner then
			part:SetNetworkOwner(owner)
		else
			part:SetNetworkOwnershipAuto()
		end
	end)
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

-- Straightens the wheels and holds the car still. Also the state an empty car
-- sits in, so nobody comes back to find it has rolled down a hill.
local function park(car: Model)
	for _, descendant in car:GetDescendants() do
		if not descendant:IsA("HingeConstraint") then
			continue
		end
		if descendant.Name == "DriveHinge" then
			descendant.AngularVelocity = 0
			descendant.MotorMaxTorque = CarConfig.Driving.BrakeTorque
		elseif descendant.Name == "SteerHinge" then
			descendant.TargetAngle = 0
		end
	end
end

local function isOccupied(car: Model): boolean
	for _, descendant in car:GetDescendants() do
		-- Checked inline rather than through isSeat() so that Occupant narrows.
		if descendant:IsA("VehicleSeat") or descendant:IsA("Seat") then
			if descendant.Occupant then
				return true
			end
		end
	end
	return false
end

local function resetCar(car: Model)
	local pivot = car:GetAttribute("SpawnPivot")
	if typeof(pivot) ~= "CFrame" then
		return
	end

	car:PivotTo(pivot)
	forEachPart(car, function(part)
		part.AssemblyLinearVelocity = Vector3.zero
		part.AssemblyAngularVelocity = Vector3.zero
	end)
	park(car)
end

local function bindSeat(car: Model, seat: any)
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

	seat:GetPropertyChangedSignal("Occupant"):Connect(function()
		local occupant = seat.Occupant

		-- No prompt on a seat that is already taken.
		if prompt then
			prompt.Enabled = occupant == nil
		end

		if not isDriverSeat then
			return
		end

		local driver = occupant and Players:GetPlayerFromCharacter(occupant.Parent)
		if driver then
			setNetworkOwner(car, driver)
			setLights(car, true)
		else
			setNetworkOwner(car, nil)
			park(car)
			setLights(car, false)
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

--[[
	Builds a car at `pivot` (its car-space origin) and wires up its seats.
]]
function CarService.spawnCar(pivot: CFrame): Model
	local car = CarModel.build(pivot)
	car.Parent = carContainer()
	car:SetAttribute("SpawnPivot", car:GetPivot())

	for _, descendant in car:GetDescendants() do
		if isSeat(descendant) then
			bindSeat(car, descendant)
		end
	end

	park(car)
	setLights(car, false)
	table.insert(cars, car)

	return car
end

-- An empty car that has landed on its roof or fallen off the world goes back to
-- where it started, so the place cannot be left without a driveable car in it.
local function watchForStuckCars()
	local flippedFor: { [Model]: number } = {}

	while true do
		local elapsed = task.wait(1)

		for _, car in cars do
			local chassis = car.PrimaryPart
			if not chassis or isOccupied(car) then
				flippedFor[car] = 0
				continue
			end

			if chassis.Position.Y < RESET.MinHeight then
				resetCar(car)
				flippedFor[car] = 0
			elseif chassis.CFrame.UpVector.Y < RESET.FlippedUpThreshold then
				local total = (flippedFor[car] or 0) + elapsed
				flippedFor[car] = total
				if total >= RESET.FlippedSeconds then
					resetCar(car)
					flippedFor[car] = 0
				end
			else
				flippedFor[car] = 0
			end
		end
	end
end

function CarService.start()
	for _, pivot in CarConfig.Spawns do
		CarService.spawnCar(pivot)
	end

	task.spawn(watchForStuckCars)
end

return CarService
