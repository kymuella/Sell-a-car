--[[
	CarConfig -- every number that describes how the demo car looks and drives.

	Geometry is written in "car space": the origin sits at wheel-axle height in
	the middle of the car, +Y is up and -Z is forward (the chassis part's
	LookVector). CarModel builds from these values and CarController drives with
	them, so tuning happens here and nowhere else.
]]

local CarConfig = {}

CarConfig.ModelName = "Roadster"

CarConfig.Dimensions = {
	-- The chassis slab. It is the only part of the bodywork that collides, which
	-- keeps the physics cheap and stops cosmetic parts from snagging on things.
	BodySize = Vector3.new(6, 1.6, 14),
	BodyHeight = 0.4, -- height of the chassis centre above the axles

	WheelRadius = 1.6,
	WheelWidth = 1.2,
	TrackWidth = 3.1, -- sideways offset of each wheel from the centreline
	Wheelbase = 4.6, -- forward/back offset of each axle from the centre
}

CarConfig.Appearance = {
	BodyColor = Color3.fromRGB(196, 40, 28),
	TrimColor = Color3.fromRGB(27, 42, 53),
	GlassColor = Color3.fromRGB(154, 197, 219),
	GlassTransparency = 0.6,
	TyreColor = Color3.fromRGB(23, 23, 23),
	RimColor = Color3.fromRGB(180, 182, 185),
	HeadlightColor = Color3.fromRGB(255, 246, 214),
	TaillightColor = Color3.fromRGB(255, 45, 45),
}

CarConfig.Physics = {
	BodyDensity = 1,

	-- Hidden mass slung low in the frame. A centre of gravity below the axles is
	-- what keeps the car from rolling over in fast corners.
	BallastDensity = 8,

	HubDensity = 25, -- the steering knuckles are their own little bodies, and want real mass
	WheelDensity = 2.5,
	WheelFriction = 1.8, -- friction maxes out at 2
	WheelFrictionWeight = 20, -- ...and this makes the tyre win over road materials
	WheelElasticity = 0.1,
	WheelElasticityWeight = 1,
}

CarConfig.Driving = {
	MaxSpeed = 110, -- studs/second the drive wheels will spin up to
	MaxReverseSpeed = 40,

	-- Hinge motor torques, applied per wheel.
	DriveTorque = 12000,
	BrakeTorque = 20000,
	HandbrakeTorque = 45000,
	CoastTorque = 1200, -- engine braking when you let off the throttle
	MotorMaxAcceleration = 90, -- rad/s^2 the motor may change wheel speed by

	AllWheelDrive = true, -- false drives the rear wheels only

	MaxSteerAngle = 34, -- degrees of lock (hinge angles are in degrees)
	SteerTorque = 60000,
	SteerSpeed = 6, -- rad/s the steering servo tracks its target at
	SteerSpeedFalloff = 0.6, -- fraction of lock given up at MaxSpeed
	InvertSteering = false,

	-- Input smoothing, as a rate: higher reaches the input faster.
	ThrottleResponse = 4,
	SteerResponse = 8,

	BrakeSpeedThreshold = 2, -- studs/s below which throttle reverses instead of brakes
	GamepadDeadzone = 0.15,
}

local RIDE_HEIGHT = CarConfig.Dimensions.WheelRadius + 0.25

-- Where CarService puts a car on startup, as the car-space origin.
CarConfig.Spawns = {
	CFrame.new(-12, RIDE_HEIGHT, 0),
	CFrame.new(12, RIDE_HEIGHT, 0),
}

CarConfig.Reset = {
	FlippedUpThreshold = 0.2, -- chassis UpVector.Y below this counts as flipped
	FlippedSeconds = 3, -- how long an empty car may lie flipped before a reset
	MinHeight = -50, -- fell off the world
}

return CarConfig
