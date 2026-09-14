--[[
	CarController -- the drive script: turns the driver's input into motor and
	steering values on the car's constraints.

	This runs on the driver's client on purpose. CarService hands the driver
	network ownership of the car's parts, so the constraint values set here are
	simulated locally and the resulting motion replicates out to everyone else.
	That is what makes the car feel immediate rather than laggy.

	Controls: W/S or the triggers to drive, A/D to steer, LeftShift or B for the
	handbrake, Space to hop out (the default seat behaviour, left alone on
	purpose).
]]

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local CarConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Car"):WaitForChild("CarConfig"))

local DRIVE = CarConfig.Driving

-- Wheel speeds are angular: studs/second over the radius gives radians/second.
local MAX_FORWARD_SPIN = DRIVE.MaxSpeed / CarConfig.Dimensions.WheelRadius
local MAX_REVERSE_SPIN = DRIVE.MaxReverseSpeed / CarConfig.Dimensions.WheelRadius

local BRAKE_LIGHT_BRIGHTNESS = 6
local IDLE_LIGHT_BRIGHTNESS = 1.2

local player = Players.LocalPlayer

local CarController = {}

-- Raw input, written by the action bindings. Held as one keyed table because the
-- bindings are generated from the tables below.
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

-- Eased input, what actually reaches the constraints.
local smoothed = { throttle = 0, steer = 0 }

local car: Model? = nil
local chassis: BasePart? = nil
local driveHinges: { HingeConstraint } = {}
local steerHinges: { HingeConstraint } = {}
local tailLamps: { Light } = {}
local brakeLightsLit = false
local stepConnection: RBXScriptConnection? = nil

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

local function resetInput()
	for key in axes do
		axes[key] = 0
	end
	handbrakeHeld = false
	smoothed.throttle = 0
	smoothed.steer = 0
end

local function bindControls()
	for _, action in KEY_ACTIONS do
		ContextActionService:BindActionAtPriority(action.name, function(_, state)
			axes[action.field] = if state == Enum.UserInputState.Begin then 1 else 0
			return Enum.ContextActionResult.Sink
		end, false, PRIORITY, table.unpack(action.keys))
	end

	-- Triggers are analogue: their travel arrives on Position.Z.
	for _, action in PAD_ACTIONS do
		ContextActionService:BindActionAtPriority(action.name, function(_, state, object)
			axes[action.field] = if state == Enum.UserInputState.End then 0 else object.Position.Z
			return Enum.ContextActionResult.Sink
		end, false, PRIORITY, action.key)
	end

	ContextActionService:BindActionAtPriority("CarPadSteer", function(_, state, object)
		if state == Enum.UserInputState.End or state == Enum.UserInputState.Cancel then
			axes.padSteer = 0
		else
			local x = object.Position.X
			axes.padSteer = if math.abs(x) < DRIVE.GamepadDeadzone then 0 else x
		end
		return Enum.ContextActionResult.Sink
	end, false, PRIORITY, Enum.KeyCode.Thumbstick1)

	-- Not Space: that is how a seated character hops out, and it stays that way.
	ContextActionService:BindActionAtPriority("CarHandbrake", function(_, state)
		handbrakeHeld = state == Enum.UserInputState.Begin
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

local function setBrakeLights(lit: boolean)
	if lit == brakeLightsLit then
		return
	end
	brakeLightsLit = lit

	-- Brightness only. Whether the lamps are lit at all belongs to the server, and
	-- anything changed here is visible to this client alone.
	for _, lamp in tailLamps do
		lamp.Brightness = if lit then BRAKE_LIGHT_BRIGHTNESS else IDLE_LIGHT_BRIGHTNESS
	end
end

local function applyToWheels(spin: number, drivenTorque: number, freeTorque: number)
	for _, hinge in driveHinges do
		hinge.AngularVelocity = spin
		hinge.MotorMaxTorque = if hinge:GetAttribute("Driven") then drivenTorque else freeTorque
	end
end

local function update(deltaTime: number)
	local body = chassis
	if not body then
		return
	end

	local throttleInput = math.clamp(axes.throttle + axes.padThrottle - axes.brake - axes.padBrake, -1, 1)
	local steerInput = math.clamp(axes.steerRight - axes.steerLeft + axes.padSteer, -1, 1)
	if DRIVE.InvertSteering then
		steerInput = -steerInput
	end

	-- Ease both inputs so the tyres are never asked for instant full lock or full
	-- throttle, which is what makes a constraint car snap sideways.
	smoothed.throttle += (throttleInput - smoothed.throttle) * math.min(deltaTime * DRIVE.ThrottleResponse, 1)
	smoothed.steer += (steerInput - smoothed.steer) * math.min(deltaTime * DRIVE.SteerResponse, 1)

	local forwardSpeed = body.AssemblyLinearVelocity:Dot(body.CFrame.LookVector)

	-- Steering gives up lock as the car speeds up, so high-speed inputs do not
	-- tip it over.
	local speedRatio = math.clamp(math.abs(forwardSpeed) / DRIVE.MaxSpeed, 0, 1)
	local steerLock = DRIVE.MaxSteerAngle * (1 - DRIVE.SteerSpeedFalloff * speedRatio)
	for _, hinge in steerHinges do
		-- Hinge angles are in degrees, and a positive angle about +Y points the
		-- wheels left, hence the negation.
		hinge.TargetAngle = -smoothed.steer * steerLock
	end

	-- Asking for the opposite of the way the car is already moving is a brake,
	-- not a gear change. Below the threshold it becomes one.
	local braking = (throttleInput > 0.05 and forwardSpeed < -DRIVE.BrakeSpeedThreshold)
		or (throttleInput < -0.05 and forwardSpeed > DRIVE.BrakeSpeedThreshold)

	if handbrakeHeld then
		applyToWheels(0, DRIVE.HandbrakeTorque, DRIVE.HandbrakeTorque)
	elseif braking then
		applyToWheels(0, DRIVE.BrakeTorque, DRIVE.BrakeTorque)
	elseif math.abs(throttleInput) > 0.05 then
		-- Forward is a negative spin: about a wheel's +X axis the contact patch
		-- travels towards +Z, which pushes the car along its -Z LookVector. Wheels
		-- that are not driven get no torque at all, so they roll free.
		local top = if smoothed.throttle >= 0 then MAX_FORWARD_SPIN else MAX_REVERSE_SPIN
		applyToWheels(-smoothed.throttle * top, DRIVE.DriveTorque, 0)
	else
		applyToWheels(0, DRIVE.CoastTorque, DRIVE.CoastTorque)
	end

	setBrakeLights(braking or handbrakeHeld)
end

local function detach()
	if stepConnection then
		stepConnection:Disconnect()
		stepConnection = nil
	end

	-- Leave the car parked, in case we still own its parts on the way out.
	if car then
		applyToWheels(0, DRIVE.BrakeTorque, DRIVE.BrakeTorque)
		for _, hinge in steerHinges do
			hinge.TargetAngle = 0
		end
	end

	unbindControls()
	resetInput()

	car = nil
	chassis = nil
	driveHinges = {}
	steerHinges = {}
	tailLamps = {}
	brakeLightsLit = false
end

local function attach(model: Model)
	detach()

	local root = model.PrimaryPart
	if not root then
		warn(("%s has no PrimaryPart, cannot drive it"):format(model:GetFullName()))
		return
	end

	car = model
	chassis = root

	for _, descendant in model:GetDescendants() do
		if descendant:IsA("HingeConstraint") then
			if descendant.Name == "DriveHinge" then
				table.insert(driveHinges, descendant)
			elseif descendant.Name == "SteerHinge" then
				table.insert(steerHinges, descendant)
			end
		elseif descendant:IsA("Light") then
			local lens = descendant.Parent
			if lens and lens:GetAttribute("Lamp") == "Tail" then
				table.insert(tailLamps, descendant)
			end
		end
	end

	bindControls()
	stepConnection = RunService.PreSimulation:Connect(update)
end

local function watchHumanoid(humanoid: Humanoid)
	local function seatChanged()
		local seat = humanoid.SeatPart
		if seat and seat:GetAttribute("IsDriverSeat") then
			local model = seat.Parent
			if model and model:IsA("Model") and model:GetAttribute("DriveableCar") then
				attach(model)
				return
			end
		end
		detach()
	end

	humanoid:GetPropertyChangedSignal("SeatPart"):Connect(seatChanged)
	humanoid.Died:Connect(detach)
	seatChanged()
end

function CarController.start()
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
end

return CarController
