--[[
	CarModel -- builds the car: invisible physics parts and constraints, dressed
	in the Porsche meshes.

	The meshes come from ServerStorage.CarModels.Porsche, imported from
	blender models/porsche/export/Porsche.fbx (export_porsche.py beside it made
	that file). The template is the car at life size in car space: its pivot is
	the origin, at wheel-axle height midway between the axles, +Y up, -Z forward.
	Every build clones it, scales it to CarConfig.Scale, and welds each piece to
	the part it rides on -- the body, a wheel, or a steering knuckle.

	The physics is derived from the measurements in CarConfig, which were taken
	off the same model, so the hinges sit exactly inside the wheel meshes:
	  * the body is a few invisible boxes, roughly the shape of the car
	  * rear wheels hang off the body on a HingeConstraint motor
	  * front wheels hang off a steering knuckle, which itself hangs off the
	    body on a second hinge running vertically, driven as a servo
	  * there is no suspension -- the wheels are hinged straight to the frame,
	    which is far more stable than a spring setup and needs no tuning
	  * the meshes are massless and never collide; they are only the look

	The wheels sit tucked under the bodywork, which means wheel and body parts
	overlap in space. They are in separate physics assemblies (a hinge is not a
	weld), so without the collision groups set up below the solver would spend
	every frame trying to shove the wheels out of the body and the car would
	refuse to move.
]]

local PhysicsService = game:GetService("PhysicsService")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")

local CarConfig = require(script.Parent.CarConfig)

local DIM = CarConfig.Dimensions
local LOOK = CarConfig.Appearance
local PHYS = CarConfig.Physics
local DRIVE = CarConfig.Driving
local scaled = CarConfig.scaled

local BODY_GROUP = "CarBody"
local WHEEL_GROUP = "CarWheel"

-- Everything below is car space, derived from the measurements in CarConfig.
local GROUND = -DIM.WheelRadius
local HALF_WIDTH = DIM.Width / 2
local HALF_TRACK = DIM.TrackWidth / 2
local AXLE_Z = DIM.Wheelbase / 2

local BODY_BOTTOM = GROUND + DIM.GroundClearance
local FLOOR_Y = GROUND + DIM.FloorHeight
local SEAT_Y = GROUND + DIM.SeatHeight
local NOSE_TOP = GROUND + DIM.NoseHeight
local BELT_Y = GROUND + DIM.BeltHeight
local DECK_TOP = GROUND + DIM.DeckHeight
local ROOF_Y = GROUND + DIM.RoofHeight

local CABIN_LENGTH = DIM.CabinRear - DIM.CabinFront
local CABIN_MID_Z = (DIM.CabinFront + DIM.CabinRear) / 2
local INTERIOR_WIDTH = DIM.Width - DIM.SillWidth * 2
local FLOOR_THICKNESS = scaled(0.12)
local ROOF_THICKNESS = scaled(0.1)

-- Where the floor pan, the PrimaryPart, sits in car space.
local CHASSIS_OFFSET = Vector3.new(0, FLOOR_Y - FLOOR_THICKNESS / 2, CABIN_MID_Z)

-- A hinge turns about its attachments' X axis.
local AXLE_AXIS = CFrame.identity -- X stays on car +X: the axis wheels spin about
local STEER_AXIS = CFrame.Angles(0, 0, math.pi / 2) -- X rotated onto car +Y: the axis the knuckles turn about

local CarModel = {}

type PartProps = {
	Name: string,
	Size: Vector3,
	Offset: Vector3,
	Shape: Enum.PartType?,
	Color: Color3?,
	Material: Enum.Material?,
	Transparency: number?,
	CanCollide: boolean?,
	Massless: boolean?,
	Density: number?,
	CollisionGroup: string?,
}

type MeshLook = {
	Color: Color3,
	Material: Enum.Material?,
	Transparency: number?,
	Reflectance: number?,
	Lamp: string?, -- "Head" or "Tail": gets a light, which CarService switches on
}

type Corner = {
	folder: Folder,
	wheel: BasePart, -- spins
	mount: BasePart, -- does not spin: the knuckle on a steered wheel, else the body
}

local WHEELS = {
	{ Name = "FrontLeft", Key = "FL", Side = -1, End = -1, Steers = true },
	{ Name = "FrontRight", Key = "FR", Side = 1, End = -1, Steers = true },
	{ Name = "RearLeft", Key = "RL", Side = -1, End = 1, Steers = false },
	{ Name = "RearRight", Key = "RR", Side = 1, End = 1, Steers = false },
}

-- How each piece of the mesh template is dressed, by part name. Wheel pieces are
-- named Wheel<corner>_<piece> and looked up by the piece.
local MESH_LOOKS: { [string]: MeshLook } = {
	BodyLeft = { Color = LOOK.BodyColor, Reflectance = LOOK.PaintReflectance },
	BodyRight = { Color = LOOK.BodyColor, Reflectance = LOOK.PaintReflectance },
	Trim = { Color = LOOK.TrimColor },
	Chrome = { Color = LOOK.ChromeColor, Material = Enum.Material.Metal },
	Windows = {
		Color = LOOK.GlassColor,
		Material = Enum.Material.Glass,
		Transparency = LOOK.GlassTransparency,
		Reflectance = 0.15,
	},
	LampGlass = { Color = LOOK.LampGlassColor, Material = Enum.Material.Glass, Transparency = 0.55 },
	HeadlightLeft = { Color = LOOK.HeadlightColor, Lamp = "Head" },
	HeadlightRight = { Color = LOOK.HeadlightColor, Lamp = "Head" },
	TaillightLeft = { Color = LOOK.TaillightColor, Lamp = "Tail" },
	TaillightRight = { Color = LOOK.TaillightColor, Lamp = "Tail" },
	Plates = { Color = LOOK.PlateColor },
	Tyre = { Color = LOOK.TyreColor },
	Rim = { Color = LOOK.RimColor, Material = Enum.Material.Metal },
	Caliper = { Color = LOOK.CaliperColor },
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

local function findMeshTemplate(): Model
	local folder = ServerStorage:FindFirstChild("CarModels")
	local template = folder and folder:FindFirstChild(CarConfig.MeshTemplate)
	if not (template and template:IsA("Model")) then
		error(
			("CarModel: ServerStorage.CarModels.%s is missing. Import "):format(CarConfig.MeshTemplate)
				.. "blender models/porsche/export/Porsche.fbx into Studio and move it there."
		)
	end
	return template
end

local function newPart(props: PartProps, base: CFrame, parent: Instance): Part
	local part = Instance.new("Part")
	part.Name = props.Name
	part.Size = props.Size
	part.Shape = props.Shape or Enum.PartType.Block
	part.Color = props.Color or LOOK.TrimColor
	part.Material = props.Material or Enum.Material.SmoothPlastic
	part.Transparency = props.Transparency or 0
	part.CanCollide = if props.CanCollide == nil then false else props.CanCollide
	part.Massless = if props.Massless == nil then true else props.Massless
	part.CollisionGroup = props.CollisionGroup or BODY_GROUP
	part.CastShadow = part.Transparency < 1
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.CFrame = base * CFrame.new(props.Offset)

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

-- The face of `part` pointing most nearly along `direction`.
local function faceToward(part: BasePart, direction: Vector3): Enum.NormalId
	local best, bestDot = Enum.NormalId.Front, -math.huge
	for _, normalId in Enum.NormalId:GetEnumItems() do
		local dot = part.CFrame:VectorToWorldSpace(Vector3.fromNormalId(normalId)):Dot(direction)
		if dot > bestDot then
			best, bestDot = normalId, dot
		end
	end
	return best
end

local function addLamp(lens: BasePart, kind: string, forward: Vector3)
	lens:SetAttribute("Lamp", kind)

	-- Dark until someone is driving; CarService owns the switch.
	if kind == "Head" then
		local light = Instance.new("SpotLight")
		light.Name = "Lamp"
		-- The imported meshes are not all oriented like the car, so aim by direction.
		light.Face = faceToward(lens, forward)
		light.Angle = 75
		light.Range = 60
		light.Brightness = 3
		light.Color = lens.Color
		light.Shadows = true
		light.Enabled = false
		light.Parent = lens
	else
		local light = Instance.new("PointLight")
		light.Name = "Lamp"
		light.Range = 12
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

local function buildWheel(base: CFrame, chassis: BasePart, chassisOffset: Vector3, layout, parent: Instance): Corner
	local wheelPosition = Vector3.new(layout.Side * HALF_TRACK, 0, layout.End * AXLE_Z)

	local folder = Instance.new("Folder")
	folder.Name = layout.Name
	folder.Parent = parent

	-- The physics wheel: a plain cylinder the tyre mesh is welded over.
	local wheel = newPart({
		Name = "Wheel",
		Size = Vector3.new(DIM.WheelWidth, DIM.WheelRadius * 2, DIM.WheelRadius * 2),
		Offset = wheelPosition,
		Shape = Enum.PartType.Cylinder, -- a cylinder part rolls on its X axis
		Transparency = 1,
		CanCollide = true,
		Massless = false,
		CollisionGroup = WHEEL_GROUP,
	}, base, folder)
	wheel.CustomPhysicalProperties = PhysicalProperties.new(
		PHYS.WheelDensity,
		PHYS.WheelFriction,
		PHYS.WheelElasticity,
		PHYS.WheelFrictionWeight,
		PHYS.WheelElasticityWeight
	)

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
		}, base, folder)

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

	return { folder = folder, wheel = wheel, mount = mount }
end

local function buildSeat(base: CFrame, chassis: BasePart, car: Model, isDriver: boolean)
	local side = if isDriver then -1 else 1 -- the driver sits on the left
	local cushion = scaled(0.12)

	local seat: BasePart = if isDriver then Instance.new("VehicleSeat") else Instance.new("Seat")
	seat.Name = if isDriver then "DriverSeat" else "PassengerSeat"
	seat.Size = Vector3.new(scaled(0.48), cushion, scaled(0.49))
	seat.CFrame = base * CFrame.new(side * DIM.SeatOffset, SEAT_Y - cushion / 2, DIM.SeatZ)
	seat.Color = LOOK.TrimColor
	seat.Material = Enum.Material.Fabric
	seat.CanCollide = false
	-- No sitting down by touch: the prompt is the way in, and otherwise anyone
	-- getting out brushes the other seat on the way and is pulled into it.
	seat.CanTouch = false
	seat.Massless = true
	seat.CollisionGroup = BODY_GROUP
	seat.TopSurface = Enum.SurfaceType.Smooth
	seat.BottomSurface = Enum.SurfaceType.Smooth

	-- The roof is closed, so nobody can hop straight up out of it: CarController
	-- stands whoever gets out here instead, beside their door, in seat space.
	seat:SetAttribute(
		"ExitOffset",
		Vector3.new(side * (HALF_WIDTH + 2.5) - side * DIM.SeatOffset, GROUND + 3 - (SEAT_Y - cushion / 2), 0)
	)

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

-- Clones the mesh template onto the car and welds every piece to what carries it.
local function dress(base: CFrame, car: Model, chassis: BasePart, corners: { [string]: Corner })
	local skin = findMeshTemplate():Clone()
	skin:ScaleTo(CarConfig.Scale)
	local pivot = skin:GetPivot()

	local bodywork = Instance.new("Folder")
	bodywork.Name = "Bodywork"
	bodywork.Parent = car

	for _, mesh in skin:GetChildren() do
		if not mesh:IsA("MeshPart") then
			continue
		end

		local cornerKey, piece = string.match(mesh.Name, "^Wheel(%u%u)_(%a+)$")
		local look = MESH_LOOKS[piece or mesh.Name]
		local corner = cornerKey and corners[cornerKey]
		if not look or (cornerKey and not corner) then
			warn(("CarModel: no idea how to dress mesh %q, leaving it off"):format(mesh.Name))
			continue
		end

		mesh.CFrame = base * pivot:ToObjectSpace(mesh.CFrame)
		mesh.Anchored = false
		mesh.CanCollide = false
		mesh.CanTouch = false
		mesh.Massless = true
		mesh.Color = look.Color
		mesh.Material = look.Material or Enum.Material.SmoothPlastic
		mesh.Transparency = look.Transparency or 0
		mesh.Reflectance = look.Reflectance or 0

		if corner then
			mesh.CollisionGroup = WHEEL_GROUP
			mesh.Parent = corner.folder
			-- The caliper stays put (or steers) while the tyre and rim spin.
			weld(if piece == "Caliper" then corner.mount else corner.wheel, mesh)
		else
			mesh.CollisionGroup = BODY_GROUP
			mesh.Parent = bodywork
			weld(chassis, mesh)
			if look.Lamp then
				addLamp(mesh, look.Lamp, base.LookVector)
			end
		end
	end

	skin:Destroy()
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
	local chassis = newPart({
		Name = "Chassis",
		Size = Vector3.new(INTERIOR_WIDTH, FLOOR_THICKNESS, CABIN_LENGTH),
		Offset = CHASSIS_OFFSET,
		Transparency = 1,
		CanCollide = true,
		Massless = false,
		Density = PHYS.BodyDensity,
	}, base, car)
	car.PrimaryPart = chassis

	-- The shape the car collides with: an open tub under a roof panel, all
	-- welded into one assembly with the floor pan.
	local hitbox = Instance.new("Folder")
	hitbox.Name = "Hitbox"
	hitbox.Parent = car

	local sillMidY = (BODY_BOTTOM + BELT_Y) / 2
	local noseLength = DIM.CabinFront - DIM.Front
	local tailLength = DIM.Rear - DIM.CabinRear
	local roofLength = DIM.RoofRear - DIM.RoofFront

	local boxes: { PartProps } = {
		{
			Name = "Nose",
			Size = Vector3.new(DIM.Width, NOSE_TOP - BODY_BOTTOM, noseLength),
			Offset = Vector3.new(0, (BODY_BOTTOM + NOSE_TOP) / 2, DIM.Front + noseLength / 2),
		},
		{
			Name = "Tail",
			Size = Vector3.new(DIM.Width, DECK_TOP - BODY_BOTTOM, tailLength),
			Offset = Vector3.new(0, (BODY_BOTTOM + DECK_TOP) / 2, DIM.CabinRear + tailLength / 2),
		},
		{
			Name = "SillLeft",
			Size = Vector3.new(DIM.SillWidth, BELT_Y - BODY_BOTTOM, CABIN_LENGTH),
			Offset = Vector3.new(-(HALF_WIDTH - DIM.SillWidth / 2), sillMidY, CABIN_MID_Z),
		},
		{
			Name = "SillRight",
			Size = Vector3.new(DIM.SillWidth, BELT_Y - BODY_BOTTOM, CABIN_LENGTH),
			Offset = Vector3.new(HALF_WIDTH - DIM.SillWidth / 2, sillMidY, CABIN_MID_Z),
		},
		{
			Name = "Roof",
			Size = Vector3.new(DIM.RoofWidth, ROOF_THICKNESS, roofLength),
			Offset = Vector3.new(0, ROOF_Y - ROOF_THICKNESS / 2, DIM.RoofFront + roofLength / 2),
		},
	}

	for _, props in boxes do
		props.Transparency = 1
		props.CanCollide = true
		props.Massless = false
		props.Density = PHYS.BodyDensity
		weld(chassis, newPart(props, base, hitbox))
	end

	-- Hidden mass, slung as low as the floor allows.
	local ballastHeight = scaled(0.1)
	weld(
		chassis,
		newPart({
			Name = "Ballast",
			Size = Vector3.new(INTERIOR_WIDTH * 0.8, ballastHeight, DIM.Wheelbase * 0.875),
			Offset = Vector3.new(0, BODY_BOTTOM + ballastHeight / 2, 0),
			Transparency = 1,
			Massless = false,
			Density = PHYS.BallastDensity,
		}, base, hitbox)
	)

	local wheels = Instance.new("Folder")
	wheels.Name = "Wheels"
	wheels.Parent = car

	local corners: { [string]: Corner } = {}
	for _, layout in WHEELS do
		corners[layout.Key] = buildWheel(base, chassis, CHASSIS_OFFSET, layout, wheels)
	end

	buildSeat(base, chassis, car, true)
	buildSeat(base, chassis, car, false)

	dress(base, car, chassis, corners)

	car:SetAttribute("DriveableCar", true)
	return car
end

--[[
	The car-space origin of a car made by build, wherever it has been moved to
	since -- the `base` that would build it again in the same spot.
]]
function CarModel.originOf(car: Model): CFrame
	assert(car.PrimaryPart, "CarModel.originOf: the car has no PrimaryPart")
	return car.PrimaryPart.CFrame * CFrame.new(-CHASSIS_OFFSET)
end

--[[
	The car's key dimensions, for checking the proportions are honest.
]]
function CarModel.describe(): string
	local perMetre = CarConfig.StudsPerMetre * CarConfig.Scale
	return string.format(
		"%s at %.2fx life size: %.2f x %.2f m, %.2f m wheelbase, %.2f m wheels, roof %.2f m "
			.. "(%.1f x %.1f studs)",
		CarConfig.ModelName,
		CarConfig.Scale,
		(DIM.Rear - DIM.Front) / perMetre,
		DIM.Width / perMetre,
		DIM.Wheelbase / perMetre,
		DIM.WheelRadius * 2 / perMetre,
		DIM.RoofHeight / perMetre,
		DIM.Rear - DIM.Front,
		DIM.Width
	)
end

return CarModel
