--[[
	CarModel -- builds the car out of parts and constraints.

	Every offset here is derived from the real-world measurements in CarConfig
	rather than typed in by hand, so the car stays a correctly proportioned
	scale model if you change a dimension. Car space: origin at wheel-axle
	height in the middle of the car, +Y up, -Z forward.

	How it drives, physically:
	  * rear wheels hang off the body on a HingeConstraint motor
	  * front wheels hang off a steering knuckle, which itself hangs off the
	    body on a second hinge running vertically, driven as a servo
	  * there is no suspension -- the wheels are hinged straight to the frame,
	    which is far more stable than a spring setup and needs no tuning

	The wheels sit tucked under the bodywork, which means wheel and body parts
	overlap in space. They are in separate physics assemblies (a hinge is not a
	weld), so without the collision groups set up below the solver would spend
	every frame trying to shove the wheels out of the body and the car would
	refuse to move.
]]

local PhysicsService = game:GetService("PhysicsService")
local RunService = game:GetService("RunService")

local CarConfig = require(script.Parent.CarConfig)

local DIM = CarConfig.Dimensions
local LOOK = CarConfig.Appearance
local PHYS = CarConfig.Physics
local DRIVE = CarConfig.Driving
local studs = CarConfig.studs

local BODY_GROUP = "CarBody"
local WHEEL_GROUP = "CarWheel"

-- Everything below is car space, derived from the metre figures in CarConfig.
local GROUND = -DIM.WheelRadius
local HALF_WIDTH = DIM.Width / 2
local HALF_LENGTH = DIM.Length / 2
local HALF_TRACK = DIM.TrackWidth / 2
local AXLE_Z = DIM.Wheelbase / 2

local BODY_BOTTOM = GROUND + DIM.GroundClearance
local FLOOR_Y = GROUND + DIM.FloorHeight
local SEAT_Y = GROUND + DIM.SeatHeight
local COWL_Y = GROUND + DIM.CowlHeight
local BELT_Y = GROUND + DIM.BeltHeight
local SCREEN_Y = GROUND + DIM.ScreenHeight

local CABIN_FRONT = DIM.CabinFront
local CABIN_REAR = DIM.CabinRear
local CABIN_LENGTH = CABIN_REAR - CABIN_FRONT
local CABIN_MID_Z = (CABIN_FRONT + CABIN_REAR) / 2
local INTERIOR_WIDTH = DIM.Width - DIM.SillWidth * 2
local SILL_HEIGHT = BELT_Y - BODY_BOTTOM
local FLOOR_THICKNESS = studs(0.175)

-- The windscreen is raked 30 degrees back off vertical, like a sports car's.
local SCREEN_RAKE = math.rad(30)
local SCREEN_RISE = SCREEN_Y - COWL_Y
local SCREEN_RUN = SCREEN_RISE * math.tan(SCREEN_RAKE)
local SCREEN_LENGTH = SCREEN_RISE / math.cos(SCREEN_RAKE)

-- A hinge turns about its attachments' X axis.
local AXLE_AXIS = CFrame.identity -- X stays on car +X: the axis wheels spin about
local STEER_AXIS = CFrame.Angles(0, 0, math.pi / 2) -- X rotated onto car +Y: the axis the knuckles turn about

local CarModel = {}

type PartProps = {
	Name: string,
	Size: Vector3,
	Offset: Vector3,
	Rotation: CFrame?,
	Shape: Enum.PartType?,
	Color: Color3?,
	Material: Enum.Material?,
	Transparency: number?,
	Reflectance: number?,
	CanCollide: boolean?,
	Massless: boolean?,
	Density: number?,
	CollisionGroup: string?,
	Lamp: string?, -- "Head" or "Tail": gets a light, which CarService switches on
}

local WHEELS = {
	{ Name = "FrontLeft", Side = -1, End = -1, Steers = true },
	{ Name = "FrontRight", Side = 1, End = -1, Steers = true },
	{ Name = "RearLeft", Side = -1, End = 1, Steers = false },
	{ Name = "RearRight", Side = 1, End = 1, Steers = false },
}

local collisionGroupsReady = false

local function ensureCollisionGroups(): boolean
	if collisionGroupsReady then
		return true
	end
	if not RunService:IsServer() then
		return false
	end

	local ok, err = pcall(function()
		local registered = {}
		for _, group in PhysicsService:GetRegisteredCollisionGroups() do
			registered[group.name] = true
		end
		if not registered[BODY_GROUP] then
			PhysicsService:RegisterCollisionGroup(BODY_GROUP)
		end
		if not registered[WHEEL_GROUP] then
			PhysicsService:RegisterCollisionGroup(WHEEL_GROUP)
		end
		-- The one relationship that matters: a car's bodywork must ignore wheels.
		PhysicsService:CollisionGroupSetCollidable(BODY_GROUP, WHEEL_GROUP, false)
	end)

	if not ok then
		warn(("CarModel: could not set up collision groups (%s). The wheels are "):format(tostring(err))
			.. "tucked under the bodywork, so without them the car will not drive.")
		return false
	end

	collisionGroupsReady = true
	return true
end

local function newPart(props: PartProps, base: CFrame, parent: Instance): Part
	local part = Instance.new("Part")
	part.Name = props.Name
	part.Size = props.Size
	part.Shape = props.Shape or Enum.PartType.Block
	part.Color = props.Color or LOOK.BodyColor
	part.Material = props.Material or Enum.Material.SmoothPlastic
	part.Transparency = props.Transparency or 0
	part.Reflectance = props.Reflectance or 0
	part.CanCollide = if props.CanCollide == nil then false else props.CanCollide
	part.Massless = if props.Massless == nil then true else props.Massless
	part.CollisionGroup = props.CollisionGroup or BODY_GROUP
	part.CastShadow = part.Transparency < 1
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.CFrame = base * CFrame.new(props.Offset) * (props.Rotation or CFrame.identity)

	if props.Density then
		part.CustomPhysicalProperties = PhysicalProperties.new(props.Density, 0.3, 0.5, 1, 1)
	end

	part.Parent = parent
	return part
end

local function weld(anchor: BasePart, part: BasePart)
	local joint = Instance.new("WeldConstraint")
	joint.Name = "Weld"
	joint.Part0 = anchor
	joint.Part1 = part
	joint.Parent = part
end

local function newAttachment(part: BasePart, name: string, position: Vector3, axis: CFrame): Attachment
	local attachment = Instance.new("Attachment")
	attachment.Name = name
	attachment.CFrame = CFrame.new(position) * axis
	attachment.Parent = part
	return attachment
end

local function addLamp(lens: Part, kind: string)
	lens:SetAttribute("Lamp", kind)

	-- Dark until someone is driving; CarService owns the switch.
	if kind == "Head" then
		local light = Instance.new("SpotLight")
		light.Name = "Lamp"
		light.Face = Enum.NormalId.Front -- the lens is unrotated, so this is car-forward
		light.Angle = 75
		light.Range = 50
		light.Brightness = 3
		light.Color = lens.Color
		light.Shadows = true
		light.Enabled = false
		light.Parent = lens
	else
		local light = Instance.new("PointLight")
		light.Name = "Lamp"
		light.Range = 10
		light.Brightness = 1.2
		light.Color = lens.Color
		light.Enabled = false
		light.Parent = lens
	end
end

local function addEnterPrompt(seat: BasePart, actionText: string)
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "EnterPrompt"
	prompt.ActionText = actionText
	prompt.ObjectText = CarConfig.ModelName
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.GamepadKeyCode = Enum.KeyCode.ButtonX
	prompt.HoldDuration = 0.15
	prompt.MaxActivationDistance = 12
	prompt.RequiresLineOfSight = false
	prompt.Parent = seat
end

local function buildWheel(base: CFrame, chassis: BasePart, chassisOffset: Vector3, layout, parent: Instance)
	local wheelPosition = Vector3.new(layout.Side * HALF_TRACK, 0, layout.End * AXLE_Z)

	local corner = Instance.new("Folder")
	corner.Name = layout.Name
	corner.Parent = parent

	local wheel = newPart({
		Name = "Wheel",
		Size = Vector3.new(DIM.WheelWidth, DIM.WheelRadius * 2, DIM.WheelRadius * 2),
		Offset = wheelPosition,
		Shape = Enum.PartType.Cylinder, -- a cylinder part rolls on its X axis
		Color = LOOK.TyreColor,
		CanCollide = true,
		Massless = false,
		CollisionGroup = WHEEL_GROUP,
	}, base, corner)
	wheel.CustomPhysicalProperties = PhysicalProperties.new(
		PHYS.WheelDensity,
		PHYS.WheelFriction,
		PHYS.WheelElasticity,
		PHYS.WheelFrictionWeight,
		PHYS.WheelElasticityWeight
	)

	-- A touch wider than the tyre, so it reads as a wheel face from either side.
	local rim = newPart({
		Name = "Rim",
		Size = Vector3.new(DIM.WheelWidth + 0.06, DIM.WheelRadius * 1.3, DIM.WheelRadius * 1.3),
		Offset = wheelPosition,
		Shape = Enum.PartType.Cylinder,
		Color = LOOK.RimColor,
		Material = Enum.Material.Metal,
		CollisionGroup = WHEEL_GROUP,
	}, base, corner)
	weld(wheel, rim)

	-- Rear wheels hang off the body; front wheels hang off a knuckle that
	-- turns, so their spin axis turns with the steering.
	local mount: BasePart = chassis
	local mountPosition = wheelPosition - chassisOffset

	if layout.Steers then
		-- Deliberately not a tiny part: a light body wedged between the heavy
		-- chassis and a driven wheel is what makes hinge cars jitter.
		local knuckle = newPart({
			Name = "SteerKnuckle",
			Size = Vector3.new(0.8, 0.8, 0.8),
			Offset = wheelPosition,
			Transparency = 1,
			Massless = false,
			Density = PHYS.KnuckleDensity,
			CollisionGroup = WHEEL_GROUP,
		}, base, corner)

		local steerHinge = Instance.new("HingeConstraint")
		steerHinge.Name = "SteerHinge"
		steerHinge.Attachment0 = newAttachment(chassis, "Steer" .. layout.Name, wheelPosition - chassisOffset, STEER_AXIS)
		steerHinge.Attachment1 = newAttachment(knuckle, "Steer", Vector3.zero, STEER_AXIS)
		steerHinge.ActuatorType = Enum.ActuatorType.Servo
		steerHinge.ServoMaxTorque = DRIVE.SteerTorque
		steerHinge.AngularSpeed = DRIVE.SteerSpeed
		steerHinge.TargetAngle = 0
		steerHinge.Parent = knuckle

		mount = knuckle
		mountPosition = Vector3.zero
	end

	local driveHinge = Instance.new("HingeConstraint")
	driveHinge.Name = "DriveHinge"
	driveHinge.Attachment0 = newAttachment(mount, "Axle" .. layout.Name, mountPosition, AXLE_AXIS)
	driveHinge.Attachment1 = newAttachment(wheel, "Axle", Vector3.zero, AXLE_AXIS)
	driveHinge.ActuatorType = Enum.ActuatorType.Motor
	driveHinge.MotorMaxAcceleration = DRIVE.MotorMaxAcceleration
	driveHinge.MotorMaxTorque = 0 -- the drive scripts set this every frame
	driveHinge.AngularVelocity = 0
	driveHinge:SetAttribute("Driven", DRIVE.AllWheelDrive or not layout.Steers)
	driveHinge.Parent = wheel
end

local function buildSeat(base: CFrame, chassis: BasePart, car: Model, isDriver: boolean)
	local sideways = if isDriver then -DIM.SeatOffset else DIM.SeatOffset -- the driver sits on the left
	local cushion = studs(0.12)

	local seat: BasePart = if isDriver then Instance.new("VehicleSeat") else Instance.new("Seat")
	seat.Name = if isDriver then "DriverSeat" else "PassengerSeat"
	seat.Size = Vector3.new(studs(0.52), cushion, studs(0.49))
	seat.CFrame = base * CFrame.new(sideways, SEAT_Y - cushion / 2, CABIN_MID_Z + studs(0.02))
	seat.Color = LOOK.TrimColor
	seat.Material = Enum.Material.Fabric
	seat.CanCollide = false
	seat.Massless = true
	seat.CollisionGroup = BODY_GROUP
	seat.TopSurface = Enum.SurfaceType.Smooth
	seat.BottomSurface = Enum.SurfaceType.Smooth

	if isDriver then
		-- The legacy VehicleSeat drivetrain is unused: the constraints do the work.
		local vehicleSeat = seat :: VehicleSeat
		vehicleSeat.MaxSpeed = 0
		vehicleSeat.Torque = 0
		vehicleSeat.TurnSpeed = 0
		vehicleSeat.HeadsUpDisplay = false
		seat:SetAttribute("IsDriverSeat", true)
	end

	seat.Parent = car
	weld(chassis, seat)
	addEnterPrompt(seat, if isDriver then "Drive" else "Ride")
end

--[[
	Builds a car whose car-space origin lands on `base`. The model comes back
	unparented with PrimaryPart set to the chassis, so car:PivotTo() moves it.
]]
function CarModel.build(base: CFrame): Model
	ensureCollisionGroups()

	local car = Instance.new("Model")
	car.Name = CarConfig.ModelName

	-- The floor pan. Central and low, so it makes a good PrimaryPart: its
	-- LookVector is the car's forward and its CFrame is the model's pivot.
	local chassisOffset = Vector3.new(0, FLOOR_Y - FLOOR_THICKNESS / 2, CABIN_MID_Z)
	local chassis = newPart({
		Name = "Chassis",
		Size = Vector3.new(INTERIOR_WIDTH, FLOOR_THICKNESS, CABIN_LENGTH),
		Offset = chassisOffset,
		Color = LOOK.TrimColor,
		CanCollide = true,
		Massless = false,
		Density = PHYS.BodyDensity,
	}, base, car)
	car.PrimaryPart = chassis

	local bodywork = Instance.new("Folder")
	bodywork.Name = "Bodywork"
	bodywork.Parent = car

	local tailTop = COWL_Y + studs(0.05)
	local sillMidY = (BODY_BOTTOM + BELT_Y) / 2
	local noseLength = CABIN_FRONT + HALF_LENGTH
	local tailLength = HALF_LENGTH - CABIN_REAR

	local parts: { PartProps } = {
		-- Structure: collides, welded into one assembly with the floor pan.
		{
			Name = "Nose",
			Size = Vector3.new(DIM.Width, COWL_Y - BODY_BOTTOM, noseLength),
			Offset = Vector3.new(0, (BODY_BOTTOM + COWL_Y) / 2, CABIN_FRONT - noseLength / 2),
			CanCollide = true,
			Massless = false,
			Density = PHYS.BodyDensity,
		},
		{
			Name = "Tail",
			Size = Vector3.new(DIM.Width, tailTop - BODY_BOTTOM, tailLength),
			Offset = Vector3.new(0, (BODY_BOTTOM + tailTop) / 2, CABIN_REAR + tailLength / 2),
			CanCollide = true,
			Massless = false,
			Density = PHYS.BodyDensity,
		},
		{
			Name = "SillLeft",
			Size = Vector3.new(DIM.SillWidth, SILL_HEIGHT, CABIN_LENGTH),
			Offset = Vector3.new(-(HALF_WIDTH - DIM.SillWidth / 2), sillMidY, CABIN_MID_Z),
			CanCollide = true,
			Massless = false,
			Density = PHYS.BodyDensity,
		},
		{
			Name = "SillRight",
			Size = Vector3.new(DIM.SillWidth, SILL_HEIGHT, CABIN_LENGTH),
			Offset = Vector3.new(HALF_WIDTH - DIM.SillWidth / 2, sillMidY, CABIN_MID_Z),
			CanCollide = true,
			Massless = false,
			Density = PHYS.BodyDensity,
		},
		{
			Name = "Bulkhead",
			Size = Vector3.new(DIM.Width, SILL_HEIGHT, studs(0.14)),
			Offset = Vector3.new(0, sillMidY, CABIN_REAR - studs(0.07)),
			CanCollide = true,
			Massless = false,
			Density = PHYS.BodyDensity,
		},

		-- Hidden mass, slung as low as the floor allows.
		{
			Name = "Ballast",
			Size = Vector3.new(DIM.Width - 0.8, studs(0.21), DIM.Wheelbase * 0.875),
			Offset = Vector3.new(0, BODY_BOTTOM + studs(0.105), CABIN_MID_Z),
			Transparency = 1,
			Massless = false,
			Density = PHYS.BallastDensity,
		},

		-- Cockpit
		{
			Name = "Dashboard",
			Size = Vector3.new(INTERIOR_WIDTH, studs(0.35), studs(0.175)),
			Offset = Vector3.new(0, COWL_Y - studs(0.175), CABIN_FRONT + studs(0.09)),
			Color = LOOK.TrimColor,
		},
		{
			Name = "Windshield",
			Size = Vector3.new(INTERIOR_WIDTH, SCREEN_LENGTH, studs(0.035)),
			Offset = Vector3.new(0, (COWL_Y + SCREEN_Y) / 2, CABIN_FRONT + SCREEN_RUN / 2),
			Rotation = CFrame.Angles(SCREEN_RAKE, 0, 0), -- rakes the top edge backwards
			Color = LOOK.GlassColor,
			Material = Enum.Material.Glass,
			Transparency = LOOK.GlassTransparency,
			Reflectance = 0.12,
		},
		{
			Name = "RollBarLeft",
			Size = Vector3.new(studs(0.09), SCREEN_Y - BELT_Y, studs(0.09)),
			Offset = Vector3.new(-DIM.SeatOffset * 1.3, (BELT_Y + SCREEN_Y) / 2, CABIN_REAR - studs(0.07)),
			Color = LOOK.TrimColor,
			Material = Enum.Material.Metal,
		},
		{
			Name = "RollBarRight",
			Size = Vector3.new(studs(0.09), SCREEN_Y - BELT_Y, studs(0.09)),
			Offset = Vector3.new(DIM.SeatOffset * 1.3, (BELT_Y + SCREEN_Y) / 2, CABIN_REAR - studs(0.07)),
			Color = LOOK.TrimColor,
			Material = Enum.Material.Metal,
		},
		{
			Name = "RollBarTop",
			Size = Vector3.new(DIM.SeatOffset * 2.6 + studs(0.09), studs(0.09), studs(0.09)),
			Offset = Vector3.new(0, SCREEN_Y, CABIN_REAR - studs(0.07)),
			Color = LOOK.TrimColor,
			Material = Enum.Material.Metal,
		},
		{
			Name = "SeatBackLeft",
			Size = Vector3.new(studs(0.5), studs(0.45), studs(0.1)),
			Offset = Vector3.new(-DIM.SeatOffset, SEAT_Y + studs(0.225), CABIN_REAR - studs(0.2)),
			Color = LOOK.TrimColor,
			Material = Enum.Material.Fabric,
		},
		{
			Name = "SeatBackRight",
			Size = Vector3.new(studs(0.5), studs(0.45), studs(0.1)),
			Offset = Vector3.new(DIM.SeatOffset, SEAT_Y + studs(0.225), CABIN_REAR - studs(0.2)),
			Color = LOOK.TrimColor,
			Material = Enum.Material.Fabric,
		},

		-- Nose and tail details
		{
			Name = "FrontBumper",
			Size = Vector3.new(DIM.Width + studs(0.035), studs(0.3), studs(0.14)),
			Offset = Vector3.new(0, GROUND + studs(0.5), -(HALF_LENGTH + studs(0.05))),
			Color = LOOK.TrimColor,
		},
		{
			Name = "RearBumper",
			Size = Vector3.new(DIM.Width + studs(0.035), studs(0.3), studs(0.14)),
			Offset = Vector3.new(0, GROUND + studs(0.5), HALF_LENGTH + studs(0.05)),
			Color = LOOK.TrimColor,
		},
		{
			Name = "Grille",
			Size = Vector3.new(studs(0.98), studs(0.17), studs(0.07)),
			Offset = Vector3.new(0, GROUND + studs(0.62), -(HALF_LENGTH + studs(0.02))),
			Color = LOOK.TrimColor,
			Material = Enum.Material.DiamondPlate,
		},
		{
			Name = "HeadlightLeft",
			Size = Vector3.new(studs(0.35), studs(0.14), studs(0.07)),
			Offset = Vector3.new(-studs(0.61), GROUND + studs(0.66), -(HALF_LENGTH + studs(0.02))),
			Color = LOOK.HeadlightColor,
			Lamp = "Head",
		},
		{
			Name = "HeadlightRight",
			Size = Vector3.new(studs(0.35), studs(0.14), studs(0.07)),
			Offset = Vector3.new(studs(0.61), GROUND + studs(0.66), -(HALF_LENGTH + studs(0.02))),
			Color = LOOK.HeadlightColor,
			Lamp = "Head",
		},
		{
			Name = "TaillightLeft",
			Size = Vector3.new(studs(0.385), studs(0.12), studs(0.07)),
			Offset = Vector3.new(-studs(0.63), GROUND + studs(0.78), HALF_LENGTH + studs(0.02)),
			Color = LOOK.TaillightColor,
			Lamp = "Tail",
		},
		{
			Name = "TaillightRight",
			Size = Vector3.new(studs(0.385), studs(0.12), studs(0.07)),
			Offset = Vector3.new(studs(0.63), GROUND + studs(0.78), HALF_LENGTH + studs(0.02)),
			Color = LOOK.TaillightColor,
			Lamp = "Tail",
		},
		{
			Name = "MirrorLeft",
			Size = Vector3.new(studs(0.105), studs(0.1), studs(0.19)),
			Offset = Vector3.new(-(HALF_WIDTH + studs(0.056)), BELT_Y + studs(0.035), CABIN_FRONT + studs(0.05)),
			Color = LOOK.TrimColor,
		},
		{
			Name = "MirrorRight",
			Size = Vector3.new(studs(0.105), studs(0.1), studs(0.19)),
			Offset = Vector3.new(HALF_WIDTH + studs(0.056), BELT_Y + studs(0.035), CABIN_FRONT + studs(0.05)),
			Color = LOOK.TrimColor,
		},
		{
			Name = "ExhaustLeft",
			Size = Vector3.new(studs(0.175), studs(0.088), studs(0.088)),
			Offset = Vector3.new(-studs(0.455), BODY_BOTTOM - studs(0.02), HALF_LENGTH + studs(0.05)),
			Rotation = CFrame.Angles(0, math.pi / 2, 0), -- lays the cylinder along Z
			Shape = Enum.PartType.Cylinder,
			Color = LOOK.RimColor,
			Material = Enum.Material.Metal,
		},
		{
			Name = "ExhaustRight",
			Size = Vector3.new(studs(0.175), studs(0.088), studs(0.088)),
			Offset = Vector3.new(studs(0.455), BODY_BOTTOM - studs(0.02), HALF_LENGTH + studs(0.05)),
			Rotation = CFrame.Angles(0, math.pi / 2, 0),
			Shape = Enum.PartType.Cylinder,
			Color = LOOK.RimColor,
			Material = Enum.Material.Metal,
		},
	}

	for _, props in parts do
		local part = newPart(props, base, bodywork)
		weld(chassis, part)
		if props.Lamp then
			addLamp(part, props.Lamp)
		end
	end

	local wheels = Instance.new("Folder")
	wheels.Name = "Wheels"
	wheels.Parent = car

	for _, layout in WHEELS do
		buildWheel(base, chassis, chassisOffset, layout, wheels)
	end

	buildSeat(base, chassis, car, true)
	buildSeat(base, chassis, car, false)

	car:SetAttribute("DriveableCar", true)
	return car
end

--[[
	The car's key dimensions in metres, for checking the proportions are honest.
]]
function CarModel.describe(): string
	local perMetre = CarConfig.StudsPerMetre
	return string.format(
		"%s: %.2f x %.2f m, %.2f m wheelbase, %.2f m wheels, screen top %.2f m "
			.. "(a %.2f m person is %d studs)",
		CarConfig.ModelName,
		DIM.Length / perMetre,
		DIM.Width / perMetre,
		DIM.Wheelbase / perMetre,
		DIM.WheelRadius * 2 / perMetre,
		DIM.ScreenHeight / perMetre,
		1.75,
		5
	)
end

return CarModel
