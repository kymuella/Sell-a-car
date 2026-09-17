--[[
	CarPhysics -- arcade raycast car physics, the same for every car.

	Each step it writes three kinds of force onto the chassis CarModel built:

	  * a spring per wheel. A ray is cast down from the top of the wheel's travel;
	    how far the wheel is pushed up gives a spring force, and how fast the body
	    is moving gives a damper force. Stiffness is set from the car's own mass
	    and SuspensionFrequency, so every car settles at the ride height it was
	    modelled with and bounces at the same rate, whatever it weighs.
	  * traction, applied at the centre of mass: throttle and brakes along the
	    ground, and grip taking out a share of any sideways slide. Pushing at the
	    centre of mass means cornering never rolls the car -- the arcade part.
	  * a steering torque that chases the rotation a car of this wheelbase would
	    have at this speed and lock, and damps rocking on the springs. In the air
	    it levels the car instead, so it lands on its wheels.

	Everything is an acceleration scaled by mass, so the stats in CarConfig mean
	the same thing on a kart and a truck.

	Whoever simulates the car runs this: the driver's client while someone
	drives (CarController), the server while it is parked (CarService). Only one
	side writes at a time -- two writers would fight over the replicated forces.
]]

local CarConfig = require(script.Parent.CarConfig)
local CarModel = require(script.Parent.CarModel)

local PHYS = CarConfig.Physics
local DRIVE = CarConfig.Driving

local CarPhysics = {}

export type Input = {
	throttle: number, -- -1 full reverse .. 1 full throttle
	steer: number, -- -1 full left .. 1 full right
	handbrake: boolean,
	hold: boolean?, -- parked: brake hard and grip fully
}

export type Wheel = {
	mount: Attachment,
	spring: VectorForce,
	radius: number,
	travel: number,
	steers: boolean,
	driven: boolean,
}

export type State = {
	car: Model,
	chassis: BasePart,
	wheels: { Wheel },
	traction: VectorForce,
	steering: Torque,
	stats: CarModel.Stats,
	wheelbase: number,
	drivenCount: number,
	rayParams: RaycastParams,
	throttle: number, -- smoothed, follows input.throttle
	steer: number, -- smoothed, follows input.steer
	braking: boolean, -- brake lights
	handbrake: boolean,
}

function CarPhysics.idleInput(): Input
	return { throttle = 0, steer = 0, handbrake = false }
end

function CarPhysics.parkedInput(): Input
	return { throttle = 0, steer = 0, handbrake = false, hold = true }
end

--[[
	Reads a client-supplied input table into a trusted one. Never skip this on
	the server: throttle and steer arrive from a player and could be anything.
]]
function CarPhysics.sanitizeInput(raw: any): Input
	if typeof(raw) ~= "table" then
		return CarPhysics.idleInput()
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
	The suspension numbers both the physics and the wheel visuals need, from a
	car's stats: spring stiffness per unit of mass, damping per unit of mass, and
	the spring's free length beyond the top of the travel.
]]
function CarPhysics.springOf(stats: CarModel.Stats, travel: number): (number, number, number)
	local omega = 2 * math.pi * stats.SuspensionFrequency
	local stiffness = omega * omega
	local damping = 2 * stats.SuspensionDamping * omega
	-- A spring this stiff sags g / omega^2 under its share of the car, so a free
	-- length of travel + sag puts the wheel exactly where it was modelled.
	local sag = workspace.Gravity / stiffness
	return stiffness, damping, travel + sag
end

--[[
	Gathers a car's forces and wheels into a state table. Returns nil if the
	model is not a car CarModel built.
]]
function CarPhysics.collect(car: Model): State?
	local chassis = car.PrimaryPart
	local traction = chassis and chassis:FindFirstChild("Traction")
	local steering = chassis and chassis:FindFirstChild("Steering")
	if not (chassis and traction and traction:IsA("VectorForce") and steering and steering:IsA("Torque")) then
		return nil
	end

	local wheels: { Wheel } = {}
	local frontZ, rearZ = math.huge, -math.huge
	local drivenCount = 0
	for _, child in chassis:GetChildren() do
		local spring = child:FindFirstChild("Spring")
		if child:IsA("Attachment") and spring and spring:IsA("VectorForce") then
			local wheel: Wheel = {
				mount = child,
				spring = spring,
				radius = child:GetAttribute("Radius") or 1,
				travel = child:GetAttribute("Travel") or 0.3,
				steers = child:GetAttribute("Steers") == true,
				driven = child:GetAttribute("Driven") == true,
			}
			table.insert(wheels, wheel)
			frontZ = math.min(frontZ, child.Position.Z)
			rearZ = math.max(rearZ, child.Position.Z)
			if wheel.driven then
				drivenCount += 1
			end
		end
	end
	if #wheels == 0 then
		return nil
	end

	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = { car }
	rayParams.RespectCanCollide = true -- drive on what a car would stand on, not decorations

	return {
		car = car,
		chassis = chassis,
		wheels = wheels,
		traction = traction,
		steering = steering,
		stats = CarModel.statsOf(car),
		wheelbase = math.max(rearZ - frontZ, 1),
		drivenCount = math.max(drivenCount, 1),
		rayParams = rayParams,
		throttle = 0,
		steer = 0,
		braking = false,
		handbrake = false,
	}
end

--[[
	Forward speed in studs/second: negative means the car is rolling backwards.
]]
function CarPhysics.forwardSpeed(state: State): number
	return state.chassis.AssemblyLinearVelocity:Dot(state.chassis.CFrame.LookVector)
end

-- The acceleration that slows `speed` towards zero at `rate` without passing it.
local function slowing(speed: number, rate: number, deltaTime: number): number
	return -math.sign(speed) * math.min(rate, math.abs(speed) / deltaTime)
end

-- Moment of inertia of the chassis box about its own axes. The chassis is the
-- only part with mass, so this is close enough for a controller.
local function inertiaOf(chassis: BasePart, mass: number): Vector3
	local s = chassis.Size
	return Vector3.new(
		mass * (s.Y * s.Y + s.Z * s.Z) / 12,
		mass * (s.X * s.X + s.Z * s.Z) / 12,
		mass * (s.X * s.X + s.Y * s.Y) / 12
	)
end

--[[
	Writes one step of `input` into the car's forces.
]]
function CarPhysics.apply(state: State, input: Input, deltaTime: number)
	-- A long frame would overshoot every rate below.
	local dt = math.clamp(deltaTime, 1 / 240, 1 / 30)
	local stats = state.stats
	local chassis = state.chassis

	-- Ease the inputs so the tyres are never asked for instant full lock or
	-- full throttle, which is what makes a car snap sideways.
	state.throttle += (input.throttle - state.throttle) * math.min(dt * DRIVE.ThrottleResponse, 1)
	state.steer += (input.steer - state.steer) * math.min(dt * DRIVE.SteerResponse, 1)
	state.handbrake = input.handbrake

	local cf = chassis.CFrame
	local up = cf.UpVector
	local mass = chassis.AssemblyMass
	local wheelMass = mass / #state.wheels

	-- Suspension.
	local grounded, drivenGrounded = 0, 0
	local normalSum = Vector3.zero
	local maxSpringForce = wheelMass * workspace.Gravity * 6
	for _, wheel in state.wheels do
		local stiffness, damping, freeLength = CarPhysics.springOf(stats, wheel.travel)
		local reach = freeLength + wheel.radius * (1 + PHYS.SuspensionDroop)
		local top = wheel.mount.WorldPosition
		local hit = workspace:Raycast(top, up * -reach, state.rayParams)

		if hit then
			grounded += 1
			normalSum += hit.Normal
			if wheel.driven then
				drivenGrounded += 1
			end

			local drop = hit.Distance - wheel.radius -- wheel centre below the top of its travel
			local extending = chassis:GetVelocityAtPosition(top):Dot(up)
			local force = (stiffness * (freeLength - drop) - damping * extending) * wheelMass
			wheel.spring.Force = up * math.clamp(force, 0, maxSpringForce)
		else
			wheel.spring.Force = Vector3.zero
		end
	end

	local angularVelocity = chassis.AssemblyAngularVelocity
	local inertia = inertiaOf(chassis, mass)
	local rockInertia = (inertia.X + inertia.Z) / 2
	local yawRate = angularVelocity:Dot(up)
	local rocking = angularVelocity - up * yawRate

	if grounded == 0 then
		state.traction.Force = Vector3.zero
		state.braking = input.handbrake
		-- Level out towards world up, to land on the wheels.
		local tilt = up:Cross(Vector3.yAxis)
		state.steering.Torque = (tilt * PHYS.AirLevelStiffness - angularVelocity * PHYS.AirLevelDamping) * rockInertia
		return
	end

	local onGround = grounded / #state.wheels
	local normal = normalSum.Unit
	local forward = (cf.LookVector - normal * cf.LookVector:Dot(normal)).Unit
	local right = (cf.RightVector - normal * cf.RightVector:Dot(normal)).Unit
	local velocity = chassis.AssemblyLinearVelocity
	local forwardSpeed = velocity:Dot(forward)
	local sideSpeed = velocity:Dot(right)

	-- Along the car. Asking for the opposite of the way it is already moving is
	-- a brake, not a gear change; below the threshold it becomes one.
	local threshold = DRIVE.BrakeSpeedThreshold
	local opposing = (input.throttle > 0.05 and forwardSpeed < -threshold)
		or (input.throttle < -0.05 and forwardSpeed > threshold)

	local accel
	if input.hold then
		accel = slowing(forwardSpeed, stats.BrakeDecel, dt)
	elseif input.handbrake then
		accel = slowing(forwardSpeed, stats.HandbrakeDecel, dt)
	elseif opposing then
		accel = slowing(forwardSpeed, stats.BrakeDecel, dt)
	elseif math.abs(state.throttle) > 0.05 then
		local limit = if state.throttle > 0 then stats.TopSpeed else stats.ReverseSpeed
		local direction = math.sign(state.throttle)
		-- Full pull until the last quarter of the speed range, then easing to none.
		local headroom = math.clamp((limit - forwardSpeed * direction) / (limit * 0.25), 0, 1)
		accel = direction * stats.Acceleration * math.abs(state.throttle) * headroom
		accel *= drivenGrounded / state.drivenCount
	else
		accel = slowing(forwardSpeed, stats.CoastDecel, dt)
	end
	state.braking = opposing or input.handbrake

	-- Across the car: take out a share of the slide each second.
	local grip = if input.handbrake then stats.DriftGrip else stats.Grip
	local sideAccel = -sideSpeed * (1 - math.exp(-grip * dt)) / dt

	state.traction.Force = (forward * accel + right * sideAccel) * mass * onGround

	-- Steering: the yaw rate a car with this wheelbase would turn at, at this
	-- speed and lock. Positive yaw about +Y turns left, hence the minus.
	local steer = if DRIVE.InvertSteering then -state.steer else state.steer
	local speedRatio = math.clamp(math.abs(forwardSpeed) / stats.TopSpeed, 0, 1)
	local lock = math.rad(stats.SteerAngle) * (1 - stats.SteerSpeedFalloff * speedRatio)
	local targetYaw = -(forwardSpeed / state.wheelbase) * math.tan(steer * lock)
	if input.handbrake then
		targetYaw *= stats.DriftSteerBoost
	end

	local yawTorque = up * (targetYaw - yawRate) * PHYS.YawResponse * inertia.Y
	local rockTorque = rocking * -PHYS.RollPitchDamping * rockInertia
	state.steering.Torque = (yawTorque + rockTorque) * onGround
end

--[[
	Clears the smoothed input and the drive forces, leaving the springs as they
	are so the car does not drop while whoever simulates it next takes over.
]]
function CarPhysics.park(state: State)
	state.throttle = 0
	state.steer = 0
	state.braking = false
	state.handbrake = false
	state.traction.Force = Vector3.zero
	state.steering.Torque = Vector3.zero
end

return CarPhysics
