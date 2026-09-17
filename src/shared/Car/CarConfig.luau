--[[
	CarConfig -- every number that describes how the car looks and drives.

	The car is a Porsche 911 (991). Its meshes are imported from
	blender models/porsche/export/Porsche.fbx and kept in
	ServerStorage.CarModels.Porsche; the physics underneath is built from the
	measurements below, which were taken off that same model, so the hinges line
	up with the wheels.

	Sizes are written in METRES and converted to studs. The conversion is
	anchored on the player: an R6 Roblox character stands 5 studs tall and reads
	as a ~1.75 m person, so one metre is 5 / 1.75 = 2.857 studs. The real car:

	  overall 4.39 x 1.81 m, 2.45 m wheelbase, 0.66 m wheels
	  roof at 1.26 m, door tops at 0.86 m

	At honest scale a seated Roblox character's head goes through that roof:
	characters sit about 1.3 m tall where a person sits about 0.9 m. So the whole
	car is built Scale times life size -- meshes and physics alike -- which is the
	smallest it can be with a closed roof over the driver.

	Geometry is in "car space": the origin is at wheel-axle height midway between
	the axles, +Y is up and -Z is forward (the chassis part's LookVector).
]]

local HUMAN_HEIGHT_STUDS = 5 -- an R6 character
local HUMAN_HEIGHT_METRES = 1.75

local STUDS_PER_METRE = HUMAN_HEIGHT_STUDS / HUMAN_HEIGHT_METRES

local SCALE = 1.4

local function studs(metres: number): number
	return metres * STUDS_PER_METRE
end

-- A measurement off the car, at the size the car is built.
local function scaled(metres: number): number
	return studs(metres) * SCALE
end

local CarConfig = {}

CarConfig.ModelName = "Porsche 911"

-- The imported meshes, in ServerStorage.CarModels.
CarConfig.MeshTemplate = "Porsche"

-- Prints what the drive script is doing to the Output window. Turn off once the
-- car is behaving.
CarConfig.Debug = true

CarConfig.StudsPerMetre = STUDS_PER_METRE
CarConfig.Scale = SCALE
CarConfig.studs = studs
CarConfig.scaled = scaled

CarConfig.Dimensions = {
	Width = scaled(1.81), -- body, not counting the mirrors
	Wheelbase = scaled(2.45),
	TrackWidth = scaled(1.5), -- centre to centre of the wheels

	-- Along the car, from the middle of the wheelbase (+ is rearward).
	Front = scaled(-2.22), -- tip of the front bumper
	Rear = scaled(2.17), -- tip of the rear bumper
	CabinFront = scaled(-0.9), -- the windscreen base
	CabinRear = scaled(1.0), -- behind the rear seats, under the back window
	RoofFront = scaled(-0.14), -- top of the windscreen
	RoofRear = scaled(0.97), -- top of the back window
	SeatZ = scaled(0.12), -- middle of the seat cushions

	-- Heights, all measured off the ground.
	GroundClearance = scaled(0.1),
	FloorHeight = scaled(0.16), -- cabin floor
	SeatHeight = scaled(0.28), -- seat cushion
	NoseHeight = scaled(0.72), -- the bonnet, roughly: it slopes 0.64-0.81 m
	BeltHeight = scaled(0.86), -- door tops / window line
	DeckHeight = scaled(0.84), -- the engine lid
	RoofHeight = scaled(1.26),

	RoofWidth = scaled(1.1),
	SillWidth = scaled(0.1),
	WheelRadius = scaled(0.33),
	WheelWidth = scaled(0.28),
	SeatOffset = scaled(0.31), -- how far each seat sits off the centreline
}

CarConfig.Appearance = {
	BodyColor = Color3.fromRGB(178, 42, 38),
	PaintReflectance = 0.08,
	TrimColor = Color3.fromRGB(27, 30, 34),
	ChromeColor = Color3.fromRGB(170, 173, 178),
	GlassColor = Color3.fromRGB(38, 46, 54),
	GlassTransparency = 0.35,
	LampGlassColor = Color3.fromRGB(232, 236, 240),
	TyreColor = Color3.fromRGB(24, 24, 26),
	RimColor = Color3.fromRGB(178, 181, 186),
	CaliperColor = Color3.fromRGB(196, 28, 32),
	PlateColor = Color3.fromRGB(236, 236, 230),
	HeadlightColor = Color3.fromRGB(255, 246, 214),
	TaillightColor = Color3.fromRGB(216, 32, 32),
}

CarConfig.Physics = {
	BodyDensity = 1,

	-- Hidden mass slung low in the frame. It puts the centre of gravity about
	-- 0.35 m off the ground at life size, which is roughly where a real 911's
	-- sits, and is what stops this one rolling over in a corner.
	BallastDensity = 5,

	KnuckleDensity = 25, -- a light steering knuckle makes hinge cars jitter
	WheelDensity = 2.5,
	WheelFriction = 1.8, -- friction maxes out at 2
	WheelFrictionWeight = 20, -- ...and this makes the tyre win over road materials
	WheelElasticity = 0.1,
	WheelElasticityWeight = 1,
}

CarConfig.Driving = {
	MaxSpeed = studs(42), -- 42 m/s, about 150 km/h
	MaxReverseSpeed = studs(11),

	-- Hinge motor torques, per wheel. At this size and mass, DriveTorque reaches
	-- MaxSpeed in under 2 s without wheelspin, and BrakeTorque stops the car
	-- from MaxSpeed in about a second without locking the wheels. Torque has to
	-- grow with mass times wheel radius, so retune these if you change Scale.
	DriveTorque = 15000,
	BrakeTorque = 42000,
	HandbrakeTorque = 63000,
	CoastTorque = 1700, -- engine braking when you lift off
	MotorMaxAcceleration = 400, -- rad/s^2; high, so torque stays the limit

	AllWheelDrive = true, -- false drives the rear wheels only

	MaxSteerAngle = 34, -- degrees of lock (hinge angles are in degrees)
	SteerTorque = 60000,
	SteerSpeed = 8, -- rad/s the steering servo tracks its target at
	SteerSpeedFalloff = 0.6, -- fraction of lock given up at MaxSpeed
	InvertSteering = false,

	-- Input smoothing, as a rate: higher reaches the input faster.
	ThrottleResponse = 4,
	SteerResponse = 8,

	BrakeSpeedThreshold = studs(0.7), -- below this, throttle reverses instead of braking
	GamepadDeadzone = 0.15,
	InputSendRate = 20, -- times/second the driver relays input to the server
}

local RIDE_HEIGHT = CarConfig.Dimensions.WheelRadius + 0.2

-- Where CarService puts a car on startup, as the car-space origin.
CarConfig.Spawns = {
	CFrame.new(-8, RIDE_HEIGHT, 0),
	CFrame.new(8, RIDE_HEIGHT, 0),
}

CarConfig.Reset = {
	FlippedUpThreshold = 0.2, -- chassis UpVector.Y below this counts as flipped
	FlippedSeconds = 3, -- how long an empty car may lie flipped before a reset
	MinHeight = -50, -- fell off the world
}

return CarConfig
