--[[
	CarDrive -- turns driver input into motor and steering values on a car's
	constraints.

	This lives in shared because BOTH ends run it, from the same input:

	  * the driver's client runs it every physics step on its own input, so the
	    car responds immediately instead of waiting a round trip. The client
	    owns the car's parts (CarService hands ownership over), so its local
	    constraint values are the ones its simulation uses.
	  * the server runs it on the input the driver relays up, so the car still
	    drives if simulation ownership has not transferred yet, and so the
	    values it replicates to everyone else agree with what the driver did.

	Both ends computing the same thing from the same input is the point: there is
	one copy of the maths, so the two cannot drift apart.
]]

local CarConfig = require(script.Parent.CarConfig)

local DRIVE = CarConfig.Driving

-- Wheel speeds are angular: studs/second over the radius gives radians/second.
local MAX_FORWARD_SPIN = DRIVE.MaxSpeed / CarConfig.Dimensions.WheelRadius
local MAX_REVERSE_SPIN = DRIVE.MaxReverseSpeed / CarConfig.Dimensions.WheelRadius

local BRAKE_LIGHT_BRIGHTNESS = 6
local IDLE_LIGHT_BRIGHTNESS = 1.2

local CarDrive = {}

export type Input = {
	throttle: number, -- -1 full reverse .. 1 full throttle
	steer: number, -- -1 full left .. 1 full right
	handbrake: boolean,
}

export type State = {
	car: Model,
	chassis: BasePart,
	driveHinges: { HingeConstraint },
	steerHinges: { HingeConstraint },
	tailLamps: { Light },
	throttle: number, -- smoothed, follows input.throttle
	steer: number, -- smoothed, follows input.steer
	braking: boolean,
}

function CarDrive.idleInput(): Input
	return { throttle = 0, steer = 0, handbrake = false }
end

--[[
	Reads a client-supplied input table into a trusted one. Never skip this on
	the server: throttle and steer arrive from a player and could be anything.
]]
function CarDrive.sanitizeInput(raw: any): Input
	if typeof(raw) ~= "table" then
		return CarDrive.idleInput()
	end

	local throttle = tonumber(raw.throttle) or 0
	local steer = tonumber(raw.steer) or 0

	-- NaN fails every comparison, so clamp() would let it through.
	if throttle ~= throttle then
		throttle = 0
	end
	if steer ~= steer then
		steer = 0
	end

	return {
		throttle = math.clamp(throttle, -1, 1),
		steer = math.clamp(steer, -1, 1),
		handbrake = raw.handbrake == true,
	}
end

--[[
	Gathers the constraints and lamps of `car` into a state table. Returns nil if
	the model is not a car this module can drive.
]]
function CarDrive.collect(car: Model): State?
	local chassis = car.PrimaryPart
	if not chassis then
		return nil
	end

	local state: State = {
		car = car,
		chassis = chassis,
		driveHinges = {},
		steerHinges = {},
		tailLamps = {},
		throttle = 0,
		steer = 0,
		braking = false,
	}

	for _, descendant in car:GetDescendants() do
		if descendant:IsA("HingeConstraint") then
			if descendant.Name == "DriveHinge" then
				table.insert(state.driveHinges, descendant)
			elseif descendant.Name == "SteerHinge" then
				table.insert(state.steerHinges, descendant)
			end
		elseif descendant:IsA("Light") then
			local lens = descendant.Parent
			if lens and lens:GetAttribute("Lamp") == "Tail" then
				table.insert(state.tailLamps, descendant)
			end
		end
	end

	if #state.driveHinges == 0 then
		return nil
	end

	return state
end

--[[
	Forward speed in studs/second: negative means the car is rolling backwards.
]]
function CarDrive.forwardSpeed(state: State): number
	return state.chassis.AssemblyLinearVelocity:Dot(state.chassis.CFrame.LookVector)
end

local function applyWheels(state: State, spin: number, drivenTorque: number, freeTorque: number)
	for _, hinge in state.driveHinges do
		hinge.AngularVelocity = spin
		hinge.MotorMaxTorque = if hinge:GetAttribute("Driven") then drivenTorque else freeTorque
	end
end

local function setBrakeLights(state: State, lit: boolean)
	if lit == state.braking then
		return
	end
	state.braking = lit

	for _, lamp in state.tailLamps do
		lamp.Brightness = if lit then BRAKE_LIGHT_BRIGHTNESS else IDLE_LIGHT_BRIGHTNESS
	end
end

--[[
	Writes one step of `input` into the car's constraints.
]]
function CarDrive.apply(state: State, input: Input, deltaTime: number)
	-- Ease both inputs so the tyres are never asked for instant full lock or
	-- full throttle, which is what makes a constraint car snap sideways.
	state.throttle += (input.throttle - state.throttle) * math.min(deltaTime * DRIVE.ThrottleResponse, 1)
	state.steer += (input.steer - state.steer) * math.min(deltaTime * DRIVE.SteerResponse, 1)

	local steerInput = if DRIVE.InvertSteering then -state.steer else state.steer
	local forwardSpeed = CarDrive.forwardSpeed(state)

	-- Steering gives up lock as the car speeds up, so a fast input does not
	-- tip the car over.
	local speedRatio = math.clamp(math.abs(forwardSpeed) / DRIVE.MaxSpeed, 0, 1)
	local steerLock = DRIVE.MaxSteerAngle * (1 - DRIVE.SteerSpeedFalloff * speedRatio)
	for _, hinge in state.steerHinges do
		-- Hinge angles are in degrees, and a positive angle about +Y points the
		-- wheels left, hence the negation.
		hinge.TargetAngle = -steerInput * steerLock
	end

	-- Asking for the opposite of the way the car is already moving is a brake,
	-- not a gear change. Below the threshold it becomes one.
	local braking = (input.throttle > 0.05 and forwardSpeed < -DRIVE.BrakeSpeedThreshold)
		or (input.throttle < -0.05 and forwardSpeed > DRIVE.BrakeSpeedThreshold)

	if input.handbrake then
		applyWheels(state, 0, DRIVE.HandbrakeTorque, DRIVE.HandbrakeTorque)
	elseif braking then
		applyWheels(state, 0, DRIVE.BrakeTorque, DRIVE.BrakeTorque)
	elseif math.abs(input.throttle) > 0.05 then
		-- Forward is a NEGATIVE spin: about a wheel's +X axis the contact patch
		-- travels towards +Z, which pushes the car along its -Z LookVector.
		-- Wheels that are not driven get no torque at all, so they roll free.
		local top = if state.throttle >= 0 then MAX_FORWARD_SPIN else MAX_REVERSE_SPIN
		applyWheels(state, -state.throttle * top, DRIVE.DriveTorque, 0)
	else
		applyWheels(state, 0, DRIVE.CoastTorque, DRIVE.CoastTorque)
	end

	setBrakeLights(state, braking or input.handbrake)
end

--[[
	Straightens the wheels and holds the car still. This is the state an empty
	car sits in, so nobody comes back to find it has rolled down a hill.
]]
function CarDrive.park(state: State)
	state.throttle = 0
	state.steer = 0
	applyWheels(state, 0, DRIVE.BrakeTorque, DRIVE.BrakeTorque)
	for _, hinge in state.steerHinges do
		hinge.TargetAngle = 0
	end
	setBrakeLights(state, false)
end

return CarDrive
