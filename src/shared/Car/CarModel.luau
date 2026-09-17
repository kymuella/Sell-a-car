--[[
	CarModel -- builds a drivable car from any template in ServerStorage.CarModels.

	A template is a Model laid out like this, and needs nothing else:

	  * Its pivot is car space: -Z forward, +Y up. The origin can be anywhere; a
	    sensible spot is between the axles at axle height.
	  * Wheels are parts named Wheel<F|R><L|R>, with a number after that for any
	    extra axles and _<piece> after that for multi-part wheels: WheelFL,
	    WheelRL2, WheelFR_Tyre. Every part of one wheel shares the name before the
	    underscore, and axles run along X. A wheel's biggest part -- its tyre --
	    sets where the wheel is and its radius. Front wheels steer. Parts named
	    ..._Caliper, or with a Spin attribute of false, steer but do not roll.
	  * A part named DriverSeat marks where the driver sits, and parts named
	    PassengerSeat... mark the other seats. Each becomes a real seat of the
	    same size and look.
	  * Everything else is bodywork. A part with a Paint attribute of true takes
	    the template's PaintColor attribute, if it has one. A part with a Lamp
	    attribute of "Head" or "Tail" is a light, lit while someone drives.
	  * Attributes on the Model override CarConfig.DefaultStats for this car.

	What gets built is kept simple for the physics. The whole car is one
	invisible box -- the Chassis, sized to the bodywork -- carrying a spring force
	per wheel, a traction force and a steering torque, which CarPhysics sets. The
	meshes are welded on, massless, and never collide. The wheels are not physical
	at all: each hangs off the chassis on Motor6Ds that CarVisuals animates on
	every client, so a car can have any number of wheels, of any size, at no cost
	to the physics.
]]

local ServerStorage = game:GetService("ServerStorage")

local CarConfig = require(script.Parent.CarConfig)
local CarCatalog = require(script.Parent.CarCatalog)

local PHYS = CarConfig.Physics

local CarModel = {}

export type Stats = typeof(CarConfig.DefaultStats)

type WheelPiece = { part: BasePart, spins: boolean }
type WheelInfo = {
	key: string,
	pieces: { WheelPiece },
	centre: Vector3, -- car space
	diameter: number,
}

local function findTemplate(carName: string): Model
	local folder = ServerStorage:FindFirstChild(CarConfig.TemplateFolder)
	if not folder then
		error(("CarModel: ServerStorage.%s does not exist"):format(CarConfig.TemplateFolder), 3)
	end
	local template = folder:FindFirstChild(carName)
	if template and template:IsA("Model") then
		return template
	end
	-- Fallback to default car template or first available template if car model is not yet imported
	local fallback = folder:FindFirstChild(CarConfig.DefaultCar)
	if fallback and fallback:IsA("Model") then
		return fallback
	end
	for _, child in folder:GetChildren() do
		if child:IsA("Model") then
			return child
		end
	end
	error(("CarModel: there is no car template ServerStorage.%s.%s"):format(CarConfig.TemplateFolder, carName), 3)
end

--[[
	A car's stats: the attributes on `source` -- a template, or a car it built --
	falling back to CarConfig.DefaultStats.
]]
function CarModel.statsOf(source: Instance): Stats
	local stats = table.clone(CarConfig.DefaultStats)
	for key, default in CarConfig.DefaultStats do
		local value = source:GetAttribute(key)
		if value ~= nil and typeof(value) == typeof(default) then
			stats[key] = value
		end
	end
	if stats.DisplayName == "" then
		stats.DisplayName = source.Name
	end
	return stats
end

-- "WheelFR_Tyre" -> "FR", "Tyre"; "WheelRL2" -> "RL2", nil; anything else -> nil.
local function parseWheelName(name: string): (string?, string?)
	local key, rest = string.match(name, "^Wheel([FR][LR]%d*)(.*)$")
	if not key then
		return nil, nil
	end
	if rest == "" then
		return key, nil
	end
	local piece = string.match(rest, "^_(.+)$")
	if not piece then
		return nil, nil
	end
	return key, piece
end

-- The axis-aligned bounds, in car space, of a part placed at `cf` in car space.
local function boundsOf(cf: CFrame, size: Vector3): (Vector3, Vector3)
	local half = size / 2
	local x, y, z = cf.XVector, cf.YVector, cf.ZVector
	local extent = Vector3.new(
		math.abs(x.X) * half.X + math.abs(y.X) * half.Y + math.abs(z.X) * half.Z,
		math.abs(x.Y) * half.X + math.abs(y.Y) * half.Y + math.abs(z.Y) * half.Z,
		math.abs(x.Z) * half.X + math.abs(y.Z) * half.Y + math.abs(z.Z) * half.Z
	)
	return cf.Position - extent, cf.Position + extent
end

local function newFolder(name: string, parent: Instance): Folder
	local folder = Instance.new("Folder")
	folder.Name = name
	folder.Parent = parent
	return folder
end

local function weld(anchor: BasePart, part: BasePart)
	local joint = Instance.new("WeldConstraint")
	joint.Name = "Weld"
	joint.Part0 = anchor
	joint.Part1 = part
	joint.Parent = part
end

-- Turns a template part into a passenger on the chassis: along for the ride,
-- weightless, and invisible to physics and raycasts.
local function carry(part: BasePart, cf: CFrame, parent: Instance)
	part.Anchored = false
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.Massless = true
	part.CFrame = cf
	part.Parent = parent
end

-- An invisible, weightless part for the wheel joints to move.
local function jointPart(name: string, cf: CFrame, parent: Instance): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = Vector3.one * 0.2
	part.Transparency = 1
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.Massless = true
	part.CastShadow = false
	part.CFrame = cf
	part.Parent = parent
	return part
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
	-- Dark until someone is driving; CarService owns the switch.
	if kind == "Head" then
		local light = Instance.new("SpotLight")
		light.Name = "Lamp"
		-- Imported meshes are not all oriented like the car, so aim by direction.
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

local function addEnterPrompt(seat: BasePart, actionText: string, carName: string)
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "EnterPrompt"
	prompt.ActionText = actionText
	prompt.ObjectText = carName
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.GamepadKeyCode = Enum.KeyCode.ButtonX
	prompt.HoldDuration = 0.15
	prompt.MaxActivationDistance = 12
	prompt.RequiresLineOfSight = false
	prompt.Parent = seat
end

type SeatContext = {
	base: CFrame,
	car: Model,
	chassis: BasePart,
	displayName: string,
	hitboxCentre: Vector3,
	halfWidth: number,
	groundY: number,
}

local function buildSeat(ctx: SeatContext, name: string, cf: CFrame, look: BasePart?, isDriver: boolean)
	local seat: BasePart = if isDriver then Instance.new("VehicleSeat") else Instance.new("Seat")
	seat.Name = name
	seat.Size = if look then look.Size else Vector3.new(2, 0.5, 2)
	seat.CFrame = ctx.base * cf
	if look then
		seat.Color = look.Color
		seat.Material = look.Material
		seat.Transparency = look.Transparency
		seat.Reflectance = look.Reflectance
	else
		seat.Transparency = 1
	end
	seat.CanCollide = false
	-- No sitting down by touch: the prompt is the way in, and otherwise anyone
	-- getting out brushes another seat on the way and is pulled into it.
	seat.CanTouch = false
	seat.Massless = true
	seat.TopSurface = Enum.SurfaceType.Smooth
	seat.BottomSurface = Enum.SurfaceType.Smooth

	-- Nobody can hop straight up out of a car with a roof: CarController stands
	-- whoever gets out here instead, beside their side of the car, in seat space.
	local side = if cf.X < ctx.hitboxCentre.X then -1 else 1
	local exit = Vector3.new(ctx.hitboxCentre.X + side * (ctx.halfWidth + 2.5), ctx.groundY + 3, cf.Z)
	seat:SetAttribute("ExitOffset", cf:PointToObjectSpace(exit))

	if isDriver then
		-- The legacy VehicleSeat drivetrain is unused: CarPhysics does the work.
		local vehicleSeat = seat :: VehicleSeat
		vehicleSeat.MaxSpeed = 0
		vehicleSeat.Torque = 0
		vehicleSeat.TurnSpeed = 0
		vehicleSeat.HeadsUpDisplay = false
		seat:SetAttribute("IsDriverSeat", true)
	end

	seat.Parent = ctx.car
	weld(ctx.chassis, seat)
	addEnterPrompt(seat, if isDriver then "Drive" else "Ride", ctx.displayName)
end

--[[
	Builds the car `carName` with its car-space origin on `base`. The model comes
	back unparented, with PrimaryPart set to the chassis, so car:PivotTo() moves
	it.
]]
function CarModel.build(carName: string, base: CFrame, customPaint: Color3?): Model
	local template = findTemplate(carName)
	local stats = CarModel.statsOf(template)

	local catalog = CarCatalog.get(carName)
	if catalog then
		stats.DisplayName = catalog.DisplayName
		stats.TopSpeed = catalog.TopSpeed
		stats.Acceleration = catalog.Acceleration
		stats.Grip = catalog.Grip
		stats.DriveType = catalog.DriveType
	end

	local skin = template:Clone()
	-- Joints the template came with would tie wheels to bodywork.
	for _, descendant in skin:GetDescendants() do
		if descendant:IsA("JointInstance") or descendant:IsA("WeldConstraint") then
			descendant:Destroy()
		end
	end
	if stats.Scale ~= 1 then
		skin:ScaleTo(skin:GetScale() * stats.Scale)
	end

	-- Read everything in car space before moving anything: moving parts can move
	-- a Model's pivot.
	local pivot = skin:GetPivot()
	local placed: { [BasePart]: CFrame } = {}
	local wheels: { [string]: WheelInfo } = {}
	local wheelKeys: { string } = {}
	local seatMarkers: { BasePart } = {}
	local bodyParts: { BasePart } = {}
	local bodyMin, bodyMax = Vector3.one * math.huge, Vector3.one * -math.huge

	for _, part in skin:GetDescendants() do
		if not part:IsA("BasePart") then
			continue
		end
		local cf = pivot:ToObjectSpace(part.CFrame)
		placed[part] = cf
		local lo, hi = boundsOf(cf, part.Size)

		local key, piece = parseWheelName(part.Name)
		if key then
			local wheel = wheels[key]
			if not wheel then
				wheel = { key = key, pieces = {}, centre = cf.Position, diameter = 0 }
				wheels[key] = wheel
				table.insert(wheelKeys, key)
			end
			local isCaliper = piece ~= nil and string.match(piece, "Caliper$") ~= nil
			table.insert(wheel.pieces, { part = part, spins = not isCaliper and part:GetAttribute("Spin") ~= false })

			local extent = hi - lo
			local diameter = math.max(extent.Y, extent.Z)
			if diameter > wheel.diameter then
				wheel.diameter = diameter
				wheel.centre = (lo + hi) / 2
			end
		elseif part.Name == "DriverSeat" or string.match(part.Name, "^PassengerSeat") then
			table.insert(seatMarkers, part)
		else
			table.insert(bodyParts, part)
			bodyMin = bodyMin:Min(lo)
			bodyMax = bodyMax:Max(hi)
		end
	end

	if #wheelKeys == 0 then
		error(("CarModel: %s has no wheels -- name them WheelFL, WheelFR, WheelRL, WheelRR"):format(carName), 2)
	end
	if #bodyParts == 0 then
		error(("CarModel: %s has no bodywork"):format(carName), 2)
	end
	table.sort(wheelKeys)

	local radiusSum, axleSum, groundY = 0, 0, math.huge
	for _, key in wheelKeys do
		local wheel = wheels[key]
		radiusSum += wheel.diameter / 2
		axleSum += wheel.centre.Y
		groundY = math.min(groundY, wheel.centre.Y - wheel.diameter / 2)
	end
	local radius = radiusSum / #wheelKeys
	local axleY = axleSum / #wheelKeys

	-- The hitbox: the bodywork's bounds, trimmed, floored above the ground.
	local floorY = axleY - radius * PHYS.HitboxFloor
	local topY = math.max(bodyMax.Y, floorY + radius)
	local hitboxSize = Vector3.new(
		math.max((bodyMax.X - bodyMin.X) * PHYS.HitboxWidth, 1),
		topY - floorY,
		math.max((bodyMax.Z - bodyMin.Z) * PHYS.HitboxLength, 1)
	)
	local hitboxCentre = Vector3.new((bodyMin.X + bodyMax.X) / 2, (floorY + topY) / 2, (bodyMin.Z + bodyMax.Z) / 2)

	local car = Instance.new("Model")
	car.Name = stats.DisplayName

	local chassis = Instance.new("Part")
	chassis.Name = "Chassis"
	chassis.Size = hitboxSize
	chassis.CFrame = base * CFrame.new(hitboxCentre)
	chassis.Transparency = 1
	chassis.CastShadow = false
	chassis.CanCollide = true
	chassis.TopSurface = Enum.SurfaceType.Smooth
	chassis.BottomSurface = Enum.SurfaceType.Smooth
	chassis.CustomPhysicalProperties = PhysicalProperties.new(PHYS.HitboxDensity, PHYS.HitboxFriction, 0, 1, 1)
	chassis.Parent = car
	car.PrimaryPart = chassis

	-- Where CarPhysics pushes the car along and turns it.
	local centre = Instance.new("Attachment")
	centre.Name = "Centre"
	centre.Parent = chassis

	local traction = Instance.new("VectorForce")
	traction.Name = "Traction"
	traction.Attachment0 = centre
	traction.RelativeTo = Enum.ActuatorRelativeTo.World
	traction.ApplyAtCenterOfMass = true
	traction.Force = Vector3.zero
	traction.Visible = false
	traction.Parent = chassis

	local steering = Instance.new("Torque")
	steering.Name = "Steering"
	steering.Attachment0 = centre
	steering.RelativeTo = Enum.ActuatorRelativeTo.World
	steering.Torque = Vector3.zero
	steering.Parent = chassis

	local bodywork = newFolder("Bodywork", car)
	local paint = customPaint or (catalog and catalog.DefaultColor) or template:GetAttribute("PaintColor")
	for _, part in bodyParts do
		carry(part, base * placed[part], bodywork)
		if part:GetAttribute("Paint") == true and typeof(paint) == "Color3" then
			part.Color = paint
		end
		weld(chassis, part)

		local lamp = part:GetAttribute("Lamp")
		if lamp == "Head" or lamp == "Tail" then
			addLamp(part, lamp, base.LookVector)
		end
	end

	local wheelsFolder = newFolder("Wheels", car)
	for _, key in wheelKeys do
		local wheel = wheels[key]
		local wheelRadius = wheel.diameter / 2
		local steers = string.sub(key, 1, 1) == "F"
		local driven = stats.DriveType == "AWD"
			or (stats.DriveType == "RWD" and not steers)
			or (stats.DriveType == "FWD" and steers)
		local travel = wheelRadius * stats.SuspensionTravel
		local inChassis = wheel.centre - hitboxCentre

		-- The spring pushes up through the top of the wheel's travel.
		local mount = Instance.new("Attachment")
		mount.Name = "Wheel" .. key
		mount.Position = inChassis + Vector3.new(0, travel, 0)
		mount:SetAttribute("Radius", wheelRadius)
		mount:SetAttribute("Travel", travel)
		mount:SetAttribute("Steers", steers)
		mount:SetAttribute("Driven", driven)
		mount.Parent = chassis

		local spring = Instance.new("VectorForce")
		spring.Name = "Spring"
		spring.Attachment0 = mount
		spring.RelativeTo = Enum.ActuatorRelativeTo.World
		spring.Force = Vector3.zero
		spring.Visible = false
		spring.Parent = mount

		-- Hub: rides the suspension and steers. Spinner: rolls, on the hub.
		local folder = newFolder("Wheel" .. key, wheelsFolder)
		local at = base * CFrame.new(wheel.centre)

		local hub = jointPart("Hub", at, folder)
		local suspension = Instance.new("Motor6D")
		suspension.Name = "Suspension"
		suspension.Part0 = chassis
		suspension.Part1 = hub
		suspension.C0 = CFrame.new(inChassis)
		suspension.Parent = hub

		local spinner = jointPart("Spinner", at, folder)
		local spin = Instance.new("Motor6D")
		spin.Name = "Spin"
		spin.Part0 = hub
		spin.Part1 = spinner
		spin.Parent = spinner

		for _, piece in wheel.pieces do
			carry(piece.part, base * placed[piece.part], folder)
			weld(if piece.spins then spinner else hub, piece.part)
		end
	end

	local seatContext: SeatContext = {
		base = base,
		car = car,
		chassis = chassis,
		displayName = stats.DisplayName,
		hitboxCentre = hitboxCentre,
		halfWidth = hitboxSize.X / 2,
		groundY = groundY,
	}
	local haveDriver = false
	for _, marker in seatMarkers do
		local isDriver = marker.Name == "DriverSeat" and not haveDriver
		haveDriver = haveDriver or isDriver
		buildSeat(seatContext, if isDriver then "DriverSeat" else marker.Name, placed[marker], marker, isDriver)
	end
	if not haveDriver then
		warn(("CarModel: %s has no DriverSeat marker; guessing where the driver sits"):format(carName))
		local guess = CFrame.new(hitboxCentre.X - hitboxSize.X * 0.2, axleY + radius * 0.5, hitboxCentre.Z)
		buildSeat(seatContext, "DriverSeat", guess, nil, true)
	end

	for key, value in stats do
		car:SetAttribute(key, value)
	end
	car:SetAttribute("CarId", carName)
	if paint and typeof(paint) == "Color3" then
		car:SetAttribute("PaintColor", paint)
	end
	car:SetAttribute("CarTemplate", carName)
	car:SetAttribute("OriginOffset", hitboxCentre) -- the chassis, in car space
	car:SetAttribute("GroundOffset", -groundY) -- how far the origin sits above the bottoms of the wheels
	car:SetAttribute("DriveableCar", true)

	skin:Destroy()
	return car
end

--[[
	The car-space origin of a car made by build, wherever it has been moved to
	since -- the `base` that would build it again in the same spot.
]]
function CarModel.originOf(car: Model): CFrame
	local offset = car:GetAttribute("OriginOffset")
	assert(car.PrimaryPart and typeof(offset) == "Vector3", "CarModel.originOf: not a car CarModel built")
	return car.PrimaryPart.CFrame * CFrame.new(-offset)
end

--[[
	One line about a built car, for the Output window.
]]
function CarModel.describe(car: Model): string
	local chassis = car.PrimaryPart
	local wheelCount = 0
	for _, child in (car:FindFirstChild("Wheels") or car):GetChildren() do
		if child:IsA("Folder") then
			wheelCount += 1
		end
	end
	return ("%s: %.1f x %.1f x %.1f studs, %d wheels, mass %.0f, top speed %d studs/s"):format(
		car.Name,
		chassis and chassis.Size.X or 0,
		chassis and chassis.Size.Y or 0,
		chassis and chassis.Size.Z or 0,
		wheelCount,
		chassis and chassis:GetMass() or 0,
		car:GetAttribute("TopSpeed") or 0
	)
end

return CarModel
