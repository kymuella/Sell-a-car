--[[
	CarConfig -- every number that describes how the car looks and drives.

	Sizes are written in METRES and converted to studs, so the car is a scale
	model of a real one rather than a guess. The conversion is anchored on the
	player: an R6 Roblox character stands 5 studs tall and reads as a ~1.75 m
	person, so one metre is 5 / 1.75 = 2.857 studs. Every dimension below is a
	real measurement off a mid-size two-seat sports car, which is what makes it
	look right standing next to a character:

	  overall 4.70 x 1.85 m, 2.80 m wheelbase, 0.68 m wheels
	  door tops at 1.05 m -- chest height on a 1.75 m person
	  screen top at 1.25 m -- shoulder height
	  seat cushion at 0.50 m off the ground

	Roblox characters are proportionally about 50% wider than real people (2
	studs across the shoulders where 1.3 would be true to life), so at honest
	scale two of them only just fit side by side. The car is open-topped for the
	same reason: a seated character's head sits where a real one would not.

	Geometry is in "car space": the origin is at wheel-axle height in the middle
	of the car, +Y is up and -Z is forward (the chassis part's LookVector).
]]

local HUMAN_HEIGHT_STUDS = 5 -- an R6 character
local HUMAN_HEIGHT_METRES = 1.75

local STUDS_PER_METRE = HUMAN_HEIGHT_STUDS / HUMAN_HEIGHT_METRES

local function studs(metres: number): number
	return metres * STUDS_PER_METRE
end

local CarConfig = {}

CarConfig.ModelName = "Roadster"

-- Prints what the drive script is doing to the Output window. Turn off once the
-- car is behaving.
CarConfig.Debug = true

CarConfig.StudsPerMetre = STUDS_PER_METRE
CarConfig.studs = studs

CarConfig.Dimensions = {
	Length = studs(4.7),
	Width = studs(1.85),
	Wheelbase = studs(2.8),
	TrackWidth = studs(1.58), -- centre to centre of the wheels

	-- Heights, all measured off the ground.
	GroundClearance = studs(0.14),
	FloorHeight = studs(0.35), -- cabin floor
	SeatHeight = studs(0.5), -- seat cushion
	CowlHeight = studs(0.95), -- top of the bonnet
	BeltHeight = studs(1.05), -- door tops / window line
	ScreenHeight = studs(1.25), -- top of the windscreen

	-- Where the cabin sits along the car.
	CabinFront = studs(-0.56), -- the windscreen base, on the cowl
	CabinRear = studs(0.7), -- the bulkhead behind the seats

	SillWidth = studs(0.12),
	WheelRadius = studs(0.34), -- 0.68 m diameter
	WheelWidth = studs(0.225),
	SeatOffset = studs(0.4), -- how far each seat sits off the centreline
}

CarConfig.Appearance = {
	BodyColor = Color3.fromRGB(178, 42, 38),
	TrimColor = Color3.fromRGB(27, 30, 34),
	GlassColor = Color3.fromRGB(162, 196, 214),
	GlassTransparency = 0.62,
	TyreColor = Color3.fromRGB(24, 24, 26),
	RimColor = Color3.fromRGB(178, 181, 186),
	HeadlightColor = Color3.fromRGB(255, 246, 214),
	TaillightColor = Color3.fromRGB(216, 32, 32),
}

CarConfig.Physics = {
	BodyDensity = 1,

	-- Hidden mass slung low in the frame. It puts the centre of gravity about
	-- 0.4 m off the ground, which is roughly where a real car's sits, and is
	-- what stops this one rolling over in a corner.
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

	-- Hinge motor torques, per wheel. The tyres break traction somewhere above
	-- 23000 at this mass, so DriveTorque is deliberately under it and
	-- BrakeTorque deliberately near it.
	DriveTorque = 7000,
	BrakeTorque = 20000,
	HandbrakeTorque = 30000,
	CoastTorque = 800, -- engine braking when you lift off
	MotorMaxAcceleration = 400, -- rad/s^2; high, so torque stays the limit

	AllWheelDrive = true, -- false drives the rear wheels only

	MaxSteerAngle = 34, -- degrees of lock (hinge angles are in degrees)
	SteerTorque = 30000,
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
