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

	-- Studs per second. 60 studs/s calibrated to 120 MPH on the speedometer.
	TopSpeed = 60,
	ReverseSpeed = 15,

	-- Studs per second per second. These are what the car does whatever it
	-- weighs: every force is scaled by the car's mass.
	Acceleration = 36, -- full throttle, easing off over the last quarter to TopSpeed
	BrakeDecel = 70,
	HandbrakeDecel = 16, -- gentle, so a handbrake turn keeps its speed
	CoastDecel = 5, -- lifting off

	SteerAngle = 32, -- degrees of front-wheel lock at a standstill
	SteerSpeedFalloff = 0.65, -- fraction of that lock given up at TopSpeed

	-- How much sideways slide is taken out each second. High is planted, low is
	-- drifty.
	Grip = 10,
	DriftGrip = 2.5, -- while the handbrake is held
	DriftSteerBoost = 1.15, -- extra rotation while drifting
	-- The share of the slide grip takes out that goes back into forward speed, so
	-- corners and drifts carry their momentum instead of scrubbing it off.
	SlideSpeedKept = 0.75,

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

--[[
	The conditions a car can be built in, besides "Restored" -- the car as its
	template made it. Each is derived from the template when the car is built,
	so any of the game's cars can turn up in any condition without a second model.
]]
CarConfig.Conditions = {
	Rusted = {
		NamePrefix = "Rusted ",
		EnterAction = "Steal", -- the driver's-seat prompt

		-- Multipliers on the car's stats: it runs, but barely.
		Stats = {
			TopSpeed = 0.55,
			ReverseSpeed = 0.7,
			Acceleration = 0.45,
			Grip = 0.8,
			SteerAngle = 0.85,
		},

		-- Sits this many wheel radii lower, on tired springs and soft tyres.
		RideDrop = 0.22,

		-- Paintwork and bare metal corrode to one of these; everything else fades
		-- and takes on grime.
		RustColors = {
			Color3.fromRGB(96, 44, 22),
			Color3.fromRGB(78, 36, 20),
			Color3.fromRGB(112, 56, 28),
		},
		GrimeColor = Color3.fromRGB(62, 54, 42),
		GlassTransparency = 0.45, -- windows too dirty to see through clearly
	},
}

--[[
	Barn finds: rusted cars waiting in barns (parts tagged BarnSpot) for someone
	to steal them and drive them into a garage drop-off (parts tagged
	GarageDropOff). See BarnService.
]]
CarConfig.Barns = {
	RespawnSeconds = 90, -- after a barn's car is delivered, until the next one turns up
	AbandonSeconds = 120, -- an empty barn find away from its barn this long is towed back
	AbandonDistance = 40, -- studs from its barn before an empty car counts as away

	-- How often each catalog tier turns up. A BarnSpot with a Car attribute always
	-- has that car instead.
	TierWeights = {
		Starter = 30,
		Classic = 25,
		Sport = 25,
		Super = 15,
		Hyper = 5,
	},
}

--[[
	What happens to a barn find once it is delivered: first retrieval (unloading
	and stripping it down), then recuperation (the rebuild), and then the car is
	yours. Seconds per phase, by catalog tier.
]]
CarConfig.Restoration = {
	Retrieval = { Starter = 20, Classic = 30, Sport = 30, Super = 45, Hyper = 60 },
	Recuperation = { Starter = 60, Classic = 150, Sport = 120, Super = 240, Hyper = 360 },

	-- Delivering a car you already own, or already have in the garage, sells it
	-- for scrap instead: this share of its price, but never less than MinScrap.
	ScrapShare = 0.1,
	MinScrap = 1000,
}

return CarConfig
