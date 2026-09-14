--[[
	CarModel -- builds the car out of parts and constraints.

	The car is generated from code rather than shipped as a .rbxm so that every
	dimension and colour stays readable and diffable in git. Offsets below are in
	car space (see CarConfig): origin at axle height in the middle of the car, +Y
	up, -Z forward.

	How it drives, physically:
	  * rear wheels hang off the chassis on a HingeConstraint motor
	  * front wheels hang off a steering knuckle, which itself hangs off the
	    chassis on a second hinge running vertically, driven as a servo
	  * there is no suspension -- the wheels are hinged straight to the frame,
	    which is far more stable than a spring setup and needs no tuning
]]

local CarConfig = require(script.Parent.CarConfig)

local DIM = CarConfig.Dimensions
local LOOK = CarConfig.Appearance
local PHYS = CarConfig.Physics
local DRIVE = CarConfig.Driving

-- Attachment positions are given in their part's local space, so anything
-- measured in car space needs the chassis' own offset taken back off it.
local CHASSIS_OFFSET = Vector3.new(0, DIM.BodyHeight, 0)

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
	Lamp: string?, -- "Head" or "Tail": gets a light, and CarService switches it on
}

-- Everything welded to the chassis. The beltline the bodywork lands on is y = 2,
-- and the cockpit is left open at the top so a seated character's head clears the
-- car instead of poking through a roof.
local BODYWORK: { PartProps } = {
	{
		Name = "Ballast",
		Size = Vector3.new(4.6, 0.8, 8),
		Offset = Vector3.new(0, -0.1, 0),
		Transparency = 1,
		Massless = false,
		Density = PHYS.BallastDensity,
	},

	-- Upper bodywork
	{ Name = "Hood", Size = Vector3.new(5.8, 0.8, 4.6), Offset = Vector3.new(0, 1.6, -4.5) },
	{ Name = "Trunk", Size = Vector3.new(5.8, 0.8, 3.4), Offset = Vector3.new(0, 1.6, 5.1) },
	{ Name = "SillLeft", Size = Vector3.new(0.9, 0.8, 5.6), Offset = Vector3.new(-2.55, 1.6, 0.6) },
	{ Name = "SillRight", Size = Vector3.new(0.9, 0.8, 5.6), Offset = Vector3.new(2.55, 1.6, 0.6) },

	-- Cockpit
	{ Name = "Dashboard", Size = Vector3.new(4.2, 0.8, 0.7), Offset = Vector3.new(0, 1.6, -1.95), Color = LOOK.TrimColor },
	{ Name = "Bulkhead", Size = Vector3.new(4.2, 0.8, 0.6), Offset = Vector3.new(0, 1.6, 3.1), Color = LOOK.TrimColor },
	{ Name = "CockpitFloor", Size = Vector3.new(4.2, 0.2, 4.4), Offset = Vector3.new(0, 1.3, 0.6), Color = LOOK.TrimColor },
	{
		Name = "Windshield",
		Size = Vector3.new(5.2, 2.4, 0.2),
		Offset = Vector3.new(0, 3.08, -1.8),
		Rotation = CFrame.Angles(math.rad(25), 0, 0), -- rakes the top edge backwards
		Color = LOOK.GlassColor,
		Material = Enum.Material.Glass,
		Transparency = LOOK.GlassTransparency,
		Reflectance = 0.15,
	},
	{
		Name = "RollBar",
		Size = Vector3.new(4.4, 0.35, 0.35),
		Offset = Vector3.new(0, 3.2, 3.25),
		Color = LOOK.TrimColor,
		Material = Enum.Material.Metal,
	},
	{
		Name = "RollBarLeft",
		Size = Vector3.new(0.35, 1.2, 0.35),
		Offset = Vector3.new(-2, 2.6, 3.25),
		Color = LOOK.TrimColor,
		Material = Enum.Material.Metal,
	},
	{
		Name = "RollBarRight",
		Size = Vector3.new(0.35, 1.2, 0.35),
		Offset = Vector3.new(2, 2.6, 3.25),
		Color = LOOK.TrimColor,
		Material = Enum.Material.Metal,
	},

	-- Nose and tail
	{ Name = "FrontBumper", Size = Vector3.new(6.2, 0.9, 0.8), Offset = Vector3.new(0, 0.45, -7.2), Color = LOOK.TrimColor },
	{ Name = "RearBumper", Size = Vector3.new(6.2, 0.9, 0.8), Offset = Vector3.new(0, 0.45, 7.2), Color = LOOK.TrimColor },
	{
		Name = "Grille",
		Size = Vector3.new(3.4, 0.55, 0.3),
		Offset = Vector3.new(0, 1.15, -7.05),
		Color = LOOK.TrimColor,
		Material = Enum.Material.DiamondPlate,
	},
	{
		Name = "HeadlightLeft",
		Size = Vector3.new(1.3, 0.55, 0.3),
		Offset = Vector3.new(-2.05, 1.15, -7.05),
		Color = LOOK.HeadlightColor,
		Lamp = "Head",
	},
	{
		Name = "HeadlightRight",
		Size = Vector3.new(1.3, 0.55, 0.3),
		Offset = Vector3.new(2.05, 1.15, -7.05),
		Color = LOOK.HeadlightColor,
		Lamp = "Head",
	},
	{
		Name = "TaillightLeft",
		Size = Vector3.new(1.4, 0.5, 0.3),
		Offset = Vector3.new(-2, 1.15, 7.05),
		Color = LOOK.TaillightColor,
		Lamp = "Tail",
	},
	{
		Name = "TaillightRight",
		Size = Vector3.new(1.4, 0.5, 0.3),
		Offset = Vector3.new(2, 1.15, 7.05),
		Color = LOOK.TaillightColor,
		Lamp = "Tail",
	},

	-- Details
	{ Name = "MirrorLeft", Size = Vector3.new(0.4, 0.5, 1), Offset = Vector3.new(-3.15, 2.45, -1.6), Color = LOOK.TrimColor },
	{ Name = "MirrorRight", Size = Vector3.new(0.4, 0.5, 1), Offset = Vector3.new(3.15, 2.45, -1.6), Color = LOOK.TrimColor },
	{ Name = "SpoilerBlade", Size = Vector3.new(4.6, 0.25, 1.2), Offset = Vector3.new(0, 2.75, 6.3) },
	{ Name = "SpoilerStandLeft", Size = Vector3.new(0.4, 0.8, 0.4), Offset = Vector3.new(-1.8, 2.35, 6.3), Color = LOOK.TrimColor },
	{ Name = "SpoilerStandRight", Size = Vector3.new(0.4, 0.8, 0.4), Offset = Vector3.new(1.8, 2.35, 6.3), Color = LOOK.TrimColor },
	{
		Name = "ExhaustLeft",
		Size = Vector3.new(0.9, 0.45, 0.45),
		Offset = Vector3.new(-1.3, -0.25, 7.35),
		Rotation = CFrame.Angles(0, math.pi / 2, 0), -- lays the cylinder along Z
		Shape = Enum.PartType.Cylinder,
		Color = LOOK.RimColor,
		Material = Enum.Material.Metal,
	},
	{
		Name = "ExhaustRight",
		Size = Vector3.new(0.9, 0.45, 0.45),
		Offset = Vector3.new(1.3, -0.25, 7.35),
		Rotation = CFrame.Angles(0, math.pi / 2, 0),
		Shape = Enum.PartType.Cylinder,
		Color = LOOK.RimColor,
		Material = Enum.Material.Metal,
	},
}

local WHEELS = {
	{ Name = "FrontLeft", Side = -1, End = -1, Steers = true },
	{ Name = "FrontRight", Side = 1, End = -1, Steers = true },
	{ Name = "RearLeft", Side = -1, End = 1, Steers = false },
	{ Name = "RearRight", Side = 1, End = 1, Steers = false },
}

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
		light.Range = 14
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
	prompt.MaxActivationDistance = 14
	prompt.RequiresLineOfSight = false
	prompt.Parent = seat
end

local function buildWheel(base: CFrame, chassis: BasePart, layout, parent: Instance)
	local wheelPosition = Vector3.new(layout.Side * DIM.TrackWidth, 0, layout.End * DIM.Wheelbase)

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
	}, base, corner)
	wheel.CustomPhysicalProperties = PhysicalProperties.new(
		PHYS.WheelDensity,
		PHYS.WheelFriction,
		PHYS.WheelElasticity,
		PHYS.WheelFrictionWeight,
		PHYS.WheelElasticityWeight
	)

	-- A touch wider than the tyre, so it reads as a hubcap from either side.
	local rim = newPart({
		Name = "Rim",
		Size = Vector3.new(DIM.WheelWidth + 0.08, DIM.WheelRadius * 1.25, DIM.WheelRadius * 1.25),
		Offset = wheelPosition,
		Shape = Enum.PartType.Cylinder,
		Color = LOOK.RimColor,
		Material = Enum.Material.Metal,
	}, base, corner)
	weld(wheel, rim)

	-- Rear wheels hang off the chassis; front wheels hang off a knuckle that
	-- turns, so their spin axis turns with the steering.
	local mount: BasePart = chassis
	local mountPosition = wheelPosition - CHASSIS_OFFSET

	if layout.Steers then
		-- Deliberately not a tiny part: a light body wedged between the heavy
		-- chassis and a driven wheel is what makes hinge cars jitter.
		local knuckle = newPart({
			Name = "SteerKnuckle",
			Size = Vector3.new(1.2, 1.2, 1.2),
			Offset = wheelPosition,
			Transparency = 1,
			Massless = false,
			Density = PHYS.HubDensity,
		}, base, corner)

		local steerHinge = Instance.new("HingeConstraint")
		steerHinge.Name = "SteerHinge"
		steerHinge.Attachment0 = newAttachment(chassis, "Steer" .. layout.Name, wheelPosition - CHASSIS_OFFSET, STEER_AXIS)
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
	driveHinge.MotorMaxTorque = 0 -- CarController sets this every frame
	driveHinge.AngularVelocity = 0
	driveHinge:SetAttribute("Driven", DRIVE.AllWheelDrive or not layout.Steers)
	driveHinge.Parent = wheel
end

local function buildSeat(base: CFrame, chassis: BasePart, car: Model, isDriver: boolean)
	local sideways = if isDriver then -1.3 else 1.3 -- the driver sits on the left

	local seat: BasePart = if isDriver then Instance.new("VehicleSeat") else Instance.new("Seat")
	seat.Name = if isDriver then "DriverSeat" else "PassengerSeat"
	seat.Size = Vector3.new(2, 1, 2)
	seat.CFrame = base * CFrame.new(sideways, 1.9, 0.6)
	seat.Color = LOOK.TrimColor
	seat.Material = Enum.Material.Fabric
	seat.CanCollide = false
	seat.Massless = true
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
	local car = Instance.new("Model")
	car.Name = CarConfig.ModelName

	local chassis = newPart({
		Name = "Chassis",
		Size = DIM.BodySize,
		Offset = CHASSIS_OFFSET,
		CanCollide = true,
		Massless = false,
		Density = PHYS.BodyDensity,
	}, base, car)
	car.PrimaryPart = chassis

	local bodywork = Instance.new("Folder")
	bodywork.Name = "Bodywork"
	bodywork.Parent = car

	for _, props in BODYWORK do
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
		buildWheel(base, chassis, layout, wheels)
	end

	buildSeat(base, chassis, car, true)
	buildSeat(base, chassis, car, false)

	car:SetAttribute("DriveableCar", true)
	return car
end

return CarModel
