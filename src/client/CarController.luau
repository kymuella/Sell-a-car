--[[
	CarController -- the drive script: reads the driver's input, runs the car's
	physics on it locally, and relays it to the server.

	Running the physics here is what makes the car feel immediate: CarService
	hands the driver network ownership of the car, so this client's simulation is
	the one that counts, and the forces CarPhysics writes take effect at once. The
	relay lets the server show everyone else which way the wheels are turned and
	when the brake lights are on.

	Seating is detected with Humanoid.Seated, the event Roblox fires on both ends
	when a character sits down. (Watching Humanoid.SeatPart for changes is the
	obvious alternative and is not reliable on the client.)

	Controls: W/S or the triggers to drive, A/D to steer, LeftShift or B for the
	handbrake, Space to hop out -- that last one is the default seat behaviour,
	left unbound on purpose.
]]

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local CarFolder = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Car")
local CarConfig = require(CarFolder.CarConfig)
local CarPhysics = require(CarFolder.CarPhysics)
local CarVisuals = require(script.Parent.CarVisuals)

local DRIVE = CarConfig.Driving
local SEND_INTERVAL = 1 / DRIVE.InputSendRate

local player = Players.LocalPlayer

local CarController = {}

-- Raw input, written by the action bindings.
local axes: { [string]: number } = {
	throttle = 0,
	brake = 0,
	steerLeft = 0,
	steerRight = 0,
	padThrottle = 0,
	padBrake = 0,
	padSteer = 0,
}
local handbrakeHeld = false

local state: CarPhysics.State? = nil
local stepConnection: RBXScriptConnection? = nil
local inputRemote: RemoteEvent? = nil
local sinceLastSend = 0
local announcedDriving = false

local KEY_ACTIONS = {
	{ name = "CarThrottle", field = "throttle", keys = { Enum.KeyCode.W, Enum.KeyCode.Up } },
	{ name = "CarBrake", field = "brake", keys = { Enum.KeyCode.S, Enum.KeyCode.Down } },
	{ name = "CarSteerLeft", field = "steerLeft", keys = { Enum.KeyCode.A, Enum.KeyCode.Left } },
	{ name = "CarSteerRight", field = "steerRight", keys = { Enum.KeyCode.D, Enum.KeyCode.Right } },
}

local PAD_ACTIONS = {
	{ name = "CarPadThrottle", field = "padThrottle", key = Enum.KeyCode.ButtonR2 },
	{ name = "CarPadBrake", field = "padBrake", key = Enum.KeyCode.ButtonL2 },
}

local PRIORITY = Enum.ContextActionPriority.High.Value

local function debugPrint(message: string, ...)
	if CarConfig.Debug then
		print(("[CarController] " .. message):format(...))
	end
end

local function resetInput()
	for key in axes do
		axes[key] = 0
	end
	handbrakeHeld = false
	announcedDriving = false
end

local function currentInput(): CarPhysics.Input
	local throttle = math.clamp(axes.throttle + axes.padThrottle - axes.brake - axes.padBrake, -1, 1)
	local steer = math.clamp(axes.steerRight - axes.steerLeft + axes.padSteer, -1, 1)
	return { throttle = throttle, steer = steer, handbrake = handbrakeHeld }
end

local function bindControls()
	for _, action in KEY_ACTIONS do
		ContextActionService:BindActionAtPriority(action.name, function(_, inputState)
			axes[action.field] = if inputState == Enum.UserInputState.Begin then 1 else 0
			return Enum.ContextActionResult.Sink
		end, false, PRIORITY, table.unpack(action.keys))
	end

	-- Triggers are analogue: their travel arrives on Position.Z.
	for _, action in PAD_ACTIONS do
		ContextActionService:BindActionAtPriority(action.name, function(_, inputState, object)
			axes[action.field] = if inputState == Enum.UserInputState.End then 0 else object.Position.Z
			return Enum.ContextActionResult.Sink
		end, false, PRIORITY, action.key)
	end

	ContextActionService:BindActionAtPriority("CarPadSteer", function(_, inputState, object)
		if inputState == Enum.UserInputState.End or inputState == Enum.UserInputState.Cancel then
			axes.padSteer = 0
		else
			local x = object.Position.X
			axes.padSteer = if math.abs(x) < DRIVE.GamepadDeadzone then 0 else x
		end
		return Enum.ContextActionResult.Sink
	end, false, PRIORITY, Enum.KeyCode.Thumbstick1)

	-- Not Space: that is how a seated character hops out, and it stays that way.
	ContextActionService:BindActionAtPriority("CarHandbrake", function(_, inputState)
		handbrakeHeld = inputState == Enum.UserInputState.Begin
		return Enum.ContextActionResult.Sink
	end, false, PRIORITY, Enum.KeyCode.LeftShift, Enum.KeyCode.ButtonB)
end

local function unbindControls()
	for _, action in KEY_ACTIONS do
		ContextActionService:UnbindAction(action.name)
	end
	for _, action in PAD_ACTIONS do
		ContextActionService:UnbindAction(action.name)
	end
	ContextActionService:UnbindAction("CarPadSteer")
	ContextActionService:UnbindAction("CarHandbrake")
end

local function send(input: CarPhysics.Input)
	if inputRemote then
		inputRemote:FireServer(input)
	end
end

local function step(deltaTime: number)
	local active = state
	if not active then
		return
	end

	local input = currentInput()
	CarPhysics.apply(active, input, deltaTime)

	if not announcedDriving and (math.abs(input.throttle) > 0.05 or math.abs(input.steer) > 0.05) then
		announcedDriving = true
		debugPrint("input reaching the car: throttle %.2f, steer %.2f", input.throttle, input.steer)
	end

	-- The server needs the input too, but not at physics rate.
	sinceLastSend += deltaTime
	if sinceLastSend >= SEND_INTERVAL then
		sinceLastSend = 0
		send(input)
	end
end

local function detach()
	if stepConnection then
		stepConnection:Disconnect()
		stepConnection = nil
	end

	local active = state
	if active then
		-- Stop pushing the car along, in case we still own it on the way out.
		CarPhysics.park(active)
		debugPrint("stopped driving %s", active.car.Name)
	end

	unbindControls()
	resetInput()
	send(CarPhysics.idleInput())

	state = nil
	CarVisuals.setLocalState(nil)
end

local function attach(car: Model)
	detach()

	local collected = CarPhysics.collect(car)
	if not collected then
		warn(("CarController: %s was not built by CarModel (no chassis forces)"):format(car:GetFullName()))
		return
	end

	state = collected
	sinceLastSend = 0
	bindControls()
	stepConnection = RunService.PreSimulation:Connect(step)
	CarVisuals.setLocalState(collected)

	debugPrint("driving %s -- %d wheels, %.1f stud wheelbase", car.Name, #collected.wheels, collected.wheelbase)
end

local function seatChanged(seat: BasePart?)
	if seat and seat:GetAttribute("IsDriverSeat") then
		local car = seat.Parent
		if car and car:IsA("Model") and car:GetAttribute("DriveableCar") then
			attach(car)
			return
		end
		debugPrint("sat in a driver seat whose parent is not a car model")
	end
	detach()
end

-- A car with a roof has nowhere to hop out to. Stand the character beside their
-- side of the car instead, at the spot CarModel marked on the seat.
-- This is the client's job because the character is the client's to move: a
-- teleport from the server loses the race with the seat weld coming apart here.
local function stepOut(seat: BasePart, humanoid: Humanoid)
	local offset = seat:GetAttribute("ExitOffset")
	local character = humanoid.Parent
	if typeof(offset) ~= "Vector3" or humanoid.Health <= 0 or not (character and character:IsA("Model")) then
		return
	end

	local position = seat.CFrame:PointToWorldSpace(offset)
	local forward = seat.CFrame.LookVector * Vector3.new(1, 0, 1)
	if forward.Magnitude < 0.1 then
		forward = Vector3.new(0, 0, -1) -- the car is on its nose or tail
	end
	character:PivotTo(CFrame.lookAt(position, position + forward.Unit))
end

local function watchHumanoid(humanoid: Humanoid)
	-- Seated passes no seat when we get up, so remember which one we were in.
	local currentSeat: BasePart? = humanoid.SeatPart

	humanoid.Seated:Connect(function(active: boolean, seat: BasePart?)
		local previous = currentSeat
		currentSeat = if active then seat else nil
		if not active and previous then
			stepOut(previous, humanoid)
		end
		seatChanged(currentSeat)
	end)
	humanoid.Died:Connect(detach)

	-- Covers the case where we are already seated when this runs.
	seatChanged(currentSeat)
end

function CarController.start()
	inputRemote = ReplicatedStorage:WaitForChild("CarInput", 30) :: RemoteEvent
	if not inputRemote then
		warn("CarController: ReplicatedStorage.CarInput never appeared; is CarService running?")
	end

	local function characterAdded(character: Model)
		local humanoid = character:WaitForChild("Humanoid", 10)
		if humanoid and humanoid:IsA("Humanoid") then
			watchHumanoid(humanoid)
		end
	end

	player.CharacterAdded:Connect(characterAdded)
	player.CharacterRemoving:Connect(detach)

	if player.Character then
		characterAdded(player.Character)
	end

	debugPrint("ready -- walk up to a car and press E")
end

return CarController
