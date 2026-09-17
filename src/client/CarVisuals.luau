--[[
	CarVisuals -- moves every car's wheels and brake lights, on every client.

	The wheels are not part of the physics (see CarModel), so each client animates
	them itself from what it can see: a ray per wheel for the suspension, the
	car's speed for the roll, and its steering for the lock. Motor6D.Transform is
	local to this client, which is exactly right -- everyone animates their own
	copy, and nothing needs replicating but the car's motion.

	Steering and braking come from the car's SteerInput and Braking attributes,
	which CarService sets from the driver's relayed input. The driver's own
	client uses its local input instead (setLocalState), so their wheels answer
	immediately rather than a network round trip later.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local CarFolder = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Car")
local CarConfig = require(CarFolder.CarConfig)
local CarModel = require(CarFolder.CarModel)
local CarPhysics = require(CarFolder.CarPhysics)

local PHYS = CarConfig.Physics

local VISIBLE_RANGE = 500 -- studs from the camera; further cars keep their last pose
local WHEEL_SMOOTHING = 25 -- per second: how quickly a wheel follows its ray
local BRAKE_LIGHT_BRIGHTNESS = 6
local IDLE_LIGHT_BRIGHTNESS = 1.2

local CarVisuals = {}

type WheelVisual = {
	mount: Attachment,
	suspension: Motor6D,
	spin: Motor6D,
	radius: number,
	travel: number,
	freeLength: number,
	steers: boolean,
	driven: boolean,
	height: number, -- how far above its modelled position the wheel is drawn
	angle: number, -- roll
	smokeAttachment: Attachment,
	smokeEmitter: ParticleEmitter,
}

type CarVisual = {
	car: Model,
	chassis: BasePart,
	stats: CarModel.Stats,
	wheels: { WheelVisual },
	tailLamps: { Light },
	rayParams: RaycastParams,
	braking: boolean?,
	drifting: boolean?,
}

local tracked: { [Model]: CarVisual | false } = {}
local localState: CarPhysics.State? = nil

local function collect(car: Model): CarVisual?
	local chassis = car.PrimaryPart
	local wheelsFolder = car:FindFirstChild("Wheels")
	if not (chassis and wheelsFolder) then
		return nil
	end

	local stats = CarModel.statsOf(car)
	local wheels: { WheelVisual } = {}
	for _, mount in chassis:GetChildren() do
		if not (mount:IsA("Attachment") and mount:GetAttribute("Radius")) then
			continue
		end
		local folder = wheelsFolder:FindFirstChild(mount.Name)
		local hub = folder and folder:FindFirstChild("Hub")
		local spinner = folder and folder:FindFirstChild("Spinner")
		local suspension = hub and hub:FindFirstChild("Suspension")
		local spin = spinner and spinner:FindFirstChild("Spin")
		if not (suspension and suspension:IsA("Motor6D") and spin and spin:IsA("Motor6D")) then
			continue
		end

		local travel = mount:GetAttribute("Travel") or 0
		local _, _, freeLength = CarPhysics.springOf(stats, travel)
		local radius = mount:GetAttribute("Radius") or 1.5

		local smokeAtt = Instance.new("Attachment")
		smokeAtt.Name = "SmokeAttachment"
		smokeAtt.Position = mount.Position + Vector3.new(0, -travel - radius, 0)
		smokeAtt.Parent = chassis

		local emitter = Instance.new("ParticleEmitter")
		emitter.Name = "DriftSmoke"
		emitter.Texture = "rbxasset://textures/particles/smoke_main.dds"
		emitter.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(240, 240, 245)),
			ColorSequenceKeypoint.new(0.4, Color3.fromRGB(225, 225, 230)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(190, 190, 200)),
		})
		emitter.Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.6),
			NumberSequenceKeypoint.new(0.2, 1.8),
			NumberSequenceKeypoint.new(0.6, 3.4),
			NumberSequenceKeypoint.new(1, 4.8),
		})
		emitter.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.6),
			NumberSequenceKeypoint.new(0.15, 0.25),
			NumberSequenceKeypoint.new(0.7, 0.65),
			NumberSequenceKeypoint.new(1, 1),
		})
		emitter.Lifetime = NumberRange.new(0.6, 1.2)
		emitter.Rate = 0
		emitter.Speed = NumberRange.new(2, 6)
		emitter.SpreadAngle = Vector2.new(30, 30)
		emitter.Drag = 3.5
		emitter.Acceleration = Vector3.new(0, 2.8, 0)
		emitter.RotSpeed = NumberRange.new(-50, 50)
		emitter.Rotation = NumberRange.new(0, 360)
		emitter.LightEmission = 0.15
		emitter.LightInfluence = 0
		emitter.EmissionDirection = Enum.NormalId.Top
		emitter.Enabled = true
		emitter.Parent = smokeAtt

		table.insert(wheels, {
			mount = mount,
			suspension = suspension,
			spin = spin,
			radius = radius,
			travel = travel,
			freeLength = freeLength,
			steers = mount:GetAttribute("Steers") == true,
			driven = mount:GetAttribute("Driven") == true,
			height = 0,
			angle = 0,
			smokeAttachment = smokeAtt,
			smokeEmitter = emitter,
		})
	end
	if #wheels == 0 then
		return nil
	end

	local tailLamps: { Light } = {}
	for _, descendant in car:GetDescendants() do
		if descendant:IsA("Light") then
			local lens = descendant.Parent
			if lens and lens:GetAttribute("Lamp") == "Tail" then
				table.insert(tailLamps, descendant)
			end
		end
	end

	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = { car }
	rayParams.RespectCanCollide = true

	return {
		car = car,
		chassis = chassis,
		stats = stats,
		wheels = wheels,
		tailLamps = tailLamps,
		rayParams = rayParams,
		braking = nil,
	}
end

local function setBrakeLights(visual: CarVisual, lit: boolean)
	if visual.braking == lit then
		return
	end
	visual.braking = lit
	for _, lamp in visual.tailLamps do
		lamp.Brightness = if lit then BRAKE_LIGHT_BRIGHTNESS else IDLE_LIGHT_BRIGHTNESS
	end
end

local function animate(visual: CarVisual, dt: number)
	local chassis = visual.chassis
	local stats = visual.stats
	local cf = chassis.CFrame
	local up = cf.UpVector
	local vel = chassis.AssemblyLinearVelocity
	local forwardSpeed = vel:Dot(cf.LookVector)
	local lateralSpeed = math.abs(vel:Dot(cf.RightVector))

	local steer, braking, handbrake
	local driven = localState
	if driven and driven.car == visual.car then
		steer, braking, handbrake = driven.steer, driven.braking, driven.handbrake
	else
		steer = visual.car:GetAttribute("SteerInput") or 0
		braking = visual.car:GetAttribute("Braking") == true
		handbrake = visual.car:GetAttribute("Handbrake") == true
	end
	if CarConfig.Driving.InvertSteering then
		steer = -steer
	end

	local speedRatio = math.clamp(math.abs(forwardSpeed) / stats.TopSpeed, 0, 1)
	local lock = math.rad(stats.SteerAngle) * (1 - stats.SteerSpeedFalloff * speedRatio)
	local follow = math.min(1, dt * WHEEL_SMOOTHING)

	local isDrifting = (lateralSpeed > 4.5)
		or (handbrake and math.abs(forwardSpeed) > 4.0)
		or (braking and math.abs(forwardSpeed) > 10.0)

	local driftIntensity = math.clamp((lateralSpeed - 3.5) / 8, 0, 1)
	if handbrake and math.abs(forwardSpeed) > 4 then
		driftIntensity = math.max(driftIntensity, 0.85)
	elseif braking and math.abs(forwardSpeed) > 10 then
		driftIntensity = math.max(driftIntensity, 0.6)
	end

	local justStartedDrifting = isDrifting and not visual.drifting
	visual.drifting = isDrifting

	for _, wheel in visual.wheels do
		local reach = wheel.freeLength + wheel.radius * (1 + PHYS.SuspensionDroop)
		local hit = Workspace:Raycast(wheel.mount.WorldPosition, up * -reach, visual.rayParams)
		local drop = if hit then hit.Distance - wheel.radius else reach - wheel.radius
		local target = wheel.travel - math.max(drop, 0)
		wheel.height += (target - wheel.height) * follow

		-- Rear wheels lock under the handbrake; everything else rolls with the car.
		if not (handbrake and not wheel.steers) then
			wheel.angle = (wheel.angle - forwardSpeed / wheel.radius * dt) % (2 * math.pi)
		end

		local yaw = if wheel.steers then -steer * lock else 0
		wheel.suspension.Transform = CFrame.new(0, wheel.height, 0) * CFrame.Angles(0, yaw, 0)
		wheel.spin.Transform = CFrame.Angles(wheel.angle, 0, 0)

		-- Dynamic drift smoke / tire clouds
		local isOnGround = hit ~= nil
		if wheel.smokeAttachment then
			wheel.smokeAttachment.Position = wheel.mount.Position + Vector3.new(0, wheel.height - wheel.travel - wheel.radius, 0)
		end
		if wheel.smokeEmitter then
			local emitsForWheel = isOnGround and isDrifting and (not wheel.steers or lateralSpeed > 7.0)
			if emitsForWheel then
				if justStartedDrifting and not wheel.steers then
					wheel.smokeEmitter:Emit(4)
				end
				wheel.smokeEmitter.Rate = math.clamp(math.round(48 * driftIntensity), 16, 56)
			else
				wheel.smokeEmitter.Rate = 0
			end
		end
	end

	setBrakeLights(visual, braking)
end

local function step(dt: number)
	local camera = Workspace.CurrentCamera
	local eye = camera and camera.CFrame.Position or Vector3.zero

	for car, visual in tracked do
		if not car.Parent then
			tracked[car] = nil
			continue
		end
		if visual == false then
			-- Not ready when it arrived (still streaming in): try again.
			tracked[car] = collect(car) or false
			continue
		end
		if (visual.chassis.Position - eye).Magnitude <= VISIBLE_RANGE then
			animate(visual, dt)
		end
	end
end

local function track(car: Instance)
	if car:IsA("Model") and car:GetAttribute("DriveableCar") then
		tracked[car] = collect(car) or false
	end
end

--[[
	Tells the visuals which car this client is driving, so its wheels follow
	local input. Pass nil on getting out.
]]
function CarVisuals.setLocalState(state: CarPhysics.State?)
	localState = state
end

function CarVisuals.start()
	RunService.PreRender:Connect(step)

	-- In the background: the server makes Workspace.Cars, and nothing else on
	-- this client should wait for it.
	task.spawn(function()
		local cars = Workspace:WaitForChild("Cars")
		cars.ChildAdded:Connect(track)
		cars.ChildRemoved:Connect(function(car)
			tracked[car :: Model] = nil
		end)
		for _, car in cars:GetChildren() do
			track(car)
		end
	end)
end

return CarVisuals
