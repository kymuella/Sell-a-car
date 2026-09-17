--[[
	CarConfig -- the settings every car shares, and the defaults each car's own
	stats fall back to.

	Cars are data, not code. Each one is a Model in ServerStorage.CarModels (see
	CarModel for how a template is laid out), and its handling comes from
	attributes on that Model, named as in DefaultStats below. A template that sets
	none of them drives exactly like DefaultStats, so give a car only the stats
	that make it different.

	Units are studs and seconds. The speedometer turns studs into metres with
	StudsPerMetre, which is anchored on the player: an R6 character stands 5 studs
	tall and reads as a ~1.75 m person.
]]

local CarConfig = {}

-- Prints what the car scripts are doing to the Output window. Turn off once the
-- cars are behaving.
CarConfig.Debug = true

CarConfig.StudsPerMetre = 5 / 1.75

-- Where the car templates live, in ServerStorage.
CarConfig.TemplateFolder = "CarModels"

-- The car a spawn builds when it does not name one.
CarConfig.DefaultCar = "Porsche"

CarConfig.DefaultStats = {
	DisplayName = "", -- shown on the enter prompt; empty uses the template's name
	Scale = 1, -- built this many times the template's size

	-- Studs per second. 120 reads as about 150 km/h on the speedometer.
	TopSpeed = 120,
	ReverseSpeed = 31,

	-- Studs per second per second. These are what the car does whatever it
	-- weighs: every force is scaled by the car's mass.
	Acceleration = 70, -- full throttle, easing off over the last quarter to TopSpeed
	BrakeDecel = 140,
	HandbrakeDecel = 40, -- gentle, so a handbrake turn keeps its speed
	CoastDecel = 10, -- lifting off

	SteerAngle = 32, -- degrees of front-wheel lock at a standstill
	SteerSpeedFalloff = 0.65, -- fraction of that lock given up at TopSpeed

	-- How much sideways slide is taken out each second. High is planted, low is
	-- drifty.
	Grip = 10,
	DriftGrip = 1.8, -- while the handbrake is held
	DriftSteerBoost = 1.35, -- extra rotation while drifting

	DriveType = "AWD", -- AWD, RWD or FWD: which wheels have to be on the ground to accelerate

	-- Suspension: how fast it bounces (Hz), how much of each bounce is damped
	-- out (0 never settles, 1 does not overshoot), and how far a wheel can push
	-- up into the body, as a fraction of its radius.
	SuspensionFrequency = 2.4,
	SuspensionDamping = 0.55,
	SuspensionTravel = 0.35,
}

CarConfig.Physics = {
	-- The hitbox is one invisible box: the body's bounding box, trimmed a little
	-- so mirrors and bumper corners do not snag, with its floor this many wheel
	-- radii below the axles -- high enough to clear the ground with the
	-- suspension fully compressed.
	HitboxWidth = 0.94,
	HitboxLength = 0.96,
	HitboxFloor = 0.3,
	HitboxDensity = 0.7,
	HitboxFriction = 0.3, -- for scraping along walls and landing on the roof

	-- How far past its spring's free length a wheel still reaches for the
	-- ground, in radii, so it keeps contact over small dips.
	SuspensionDroop = 0.2,

	-- Per second: how hard the body chases the rotation the steering asks for,
	-- and how quickly it stops rocking on its springs.
	YawResponse = 8,
	RollPitchDamping = 4,

	-- In the air, how strongly the car levels itself to land on its wheels.
	AirLevelStiffness = 6,
	AirLevelDamping = 3,
}

CarConfig.Driving = {
	InvertSteering = false,

	-- Input smoothing, as a rate: higher reaches the input faster.
	ThrottleResponse = 4,
	SteerResponse = 8,

	BrakeSpeedThreshold = 2, -- studs/s: slower than this, throttle reverses instead of braking
	GamepadDeadzone = 0.15,
	InputSendRate = 20, -- times/second the driver relays input to the server
}

-- Where cars go when Workspace.Cars has no stand-ins placed in Studio (see
-- CarService.placeInStudio). Each CFrame is a car-space origin; it is dropped
-- onto the floor under it, so the height only has to be roughly right. These
-- are the middle two display pads in the dealership.
CarConfig.Spawns = {
	{ Car = "Porsche", CFrame = CFrame.new(-15, 2, 80) },
	{ Car = "Porsche", CFrame = CFrame.new(15, 2, 80) },
}

CarConfig.Reset = {
	FlippedUpThreshold = 0.2, -- UpVector.Y below this counts as flipped
	FlippedSeconds = 3, -- how long an empty car may lie flipped before a reset
	MinHeight = -50, -- fell off the world
}

-- Target CFrame for the main driving / playing area
CarConfig.PlayingArea = CFrame.new(0, 3, 130)

return CarConfig
