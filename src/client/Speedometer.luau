--[[
	Speedometer -- the NFS-style speed dial. It shows only while you are sitting
	in a car, driving or riding along, and hides the moment you are back on foot.

	The speed is the car's own, read off its chassis, in km/h through the same
	studs-per-metre conversion CarConfig uses. The dial is sized to the car you get
	into, from its TopSpeed stat. Gear and RPM are for show -- the physics has no
	gears -- and come from a ratio table over the dial.

	Seating is detected with Humanoid.Seated, for the same reason as in
	CarController: watching Humanoid.SeatPart is not reliable on the client.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local CarConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Car"):WaitForChild("CarConfig"))

local MPH_PER_STUDS_PER_SECOND = 2.0

-- The top of the dial for a car that tops out at `topSpeed` studs/s: its top
-- speed in MPH rounded up to the next 20 with headroom so top speed lands near redline.
local function dialMaxFor(topSpeed: number): number
	local maxMph = topSpeed * MPH_PER_STUDS_PER_SECOND
	return math.max(math.ceil((maxMph * 1.15) / 20) * 20, 40)
end

local CONFIG = {
	Unit = "MPH",
	Sweep = 260, -- degrees of arc
	StartAngle = 140, -- 0 = 3 o'clock, increases clockwise
	SegmentCount = 130, -- resolution of the glowing progress arc
	TickCount = 40, -- 40 minor, every 5th is major
	RedlineFrac = 0.85,
	GearTops = { 0.19, 0.32, 0.46, 0.62, 0.80, 1.00 },
	ReverseSpeed = CarConfig.Driving.BrakeSpeedThreshold, -- studs/s backwards before it shows R

	-- The rev counter: an arc around the outside of the dial, over the same sweep.
	RpmMax = 8000,
	RpmRedline = 7000, -- the whole arc turns red above this
	RpmLimiterFrac = 0.78, -- where the limiter mark sits on the arc
	RpmSegmentCount = 110,
}

local COLOR = {
	Ground = Color3.fromRGB(10, 9, 8),
	Ink = Color3.fromRGB(243, 242, 242),
	Accent = Color3.fromRGB(236, 48, 19),
	Muted = Color3.fromRGB(138, 132, 130),
	Dim = Color3.fromRGB(74, 70, 69),
	Rule = Color3.fromRGB(42, 39, 37),
}

local Speedometer = {}

local gui: ScreenGui
local needle: Frame
local segments: { Frame } = {}
local segmentFrac: { number } = {}
local speedText: TextLabel
local gearText: TextLabel
local rpmSegments: { Frame } = {}
local rpmSegmentFrac: { number } = {}
local rpmRedlined = false
local numerals: { { label: TextLabel, frac: number } } = {}
local dialMax = dialMaxFor(CarConfig.DefaultStats.TopSpeed)

local car: Model? = nil
local renderConnection: RBXScriptConnection? = nil
local shown = 0
local shownRpm = 900

-- The dial was drawn in Archivo, which is not one of Roblox's built-in fonts.
-- Upload a copy and put its "rbxassetid://..." family here to use it; until then
-- it is Gotham, the nearest built-in.
local FONT_FAMILY = Font.fromEnum(Enum.Font.GothamBlack).Family

local function new(class: string, props: { [string]: any }): any
	local inst = Instance.new(class)
	for k, v in props do
		if k ~= "Parent" then
			(inst :: any)[k] = v
		end
	end
	inst.Parent = props.Parent
	return inst
end

local function radialBar(
	parent: Instance,
	angleDeg: number,
	radius: number,
	length: number,
	thickness: number,
	color: Color3,
	transparency: number,
	z: number
): Frame
	-- a thin bar whose *outer* edge sits at `radius` (fraction of half-width), rotated around the dial centre
	local rad = math.rad(angleDeg)
	local mid = radius - length * 0.5
	return new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5 + math.cos(rad) * mid * 0.5, 0.5 + math.sin(rad) * mid * 0.5),
		Size = UDim2.fromScale(length * 0.5, thickness),
		Rotation = angleDeg,
		BackgroundColor3 = color,
		BackgroundTransparency = transparency,
		BorderSizePixel = 0,
		ZIndex = z,
		Parent = parent,
	})
end

local function build()
	local fontBlack = Font.new(FONT_FAMILY, Enum.FontWeight.Heavy)
	local fontBold = Font.new(FONT_FAMILY, Enum.FontWeight.Bold)

	local function label(parent: Instance, props: { [string]: any }): TextLabel
		local t = new("TextLabel", {
			BackgroundTransparency = 1,
			FontFace = fontBold,
			TextColor3 = COLOR.Ink,
			TextXAlignment = Enum.TextXAlignment.Left,
			Parent = parent,
		})
		for k, v in props do
			(t :: any)[k] = v
		end
		return t
	end

	gui = new("ScreenGui", {
		Name = "SpeedometerHUD",
		Enabled = false, -- until you get in a car
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		Parent = Players.LocalPlayer:WaitForChild("PlayerGui"),
	})

	-- square dial container, bottom-right; the margin leaves room for the rev arc,
	-- which reaches a little outside the square
	local dial = new("Frame", {
		Name = "Dial",
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -40, 1, -40),
		Size = UDim2.fromScale(0.34, 0.34),
		BackgroundTransparency = 1,
		Parent = gui,
	})
	new("UIAspectRatioConstraint", { AspectRatio = 1, Parent = dial })

	-- track + redline band + progress segments
	for i = 0, CONFIG.SegmentCount - 1 do
		local frac = (i + 0.5) / CONFIG.SegmentCount
		local angle = CONFIG.StartAngle + frac * CONFIG.Sweep
		local track = radialBar(dial, angle, 0.98, 0.055, 0.008, COLOR.Rule, 0, 1)
		track.Name = "Track"
		local seg = radialBar(dial, angle, 0.98, 0.055, 0.02, COLOR.Accent, 1, 2)
		seg.Name = "Seg"
		segments[#segments + 1] = seg
		segmentFrac[#segmentFrac + 1] = frac
	end

	-- ticks and numerals
	for i = 0, CONFIG.TickCount do
		local frac = i / CONFIG.TickCount
		local angle = CONFIG.StartAngle + frac * CONFIG.Sweep
		local major = i % 5 == 0
		local red = frac >= CONFIG.RedlineFrac
		local color = red and COLOR.Accent or (major and COLOR.Ink or COLOR.Dim)
		radialBar(dial, angle, 0.93, major and 0.13 or 0.06, major and 0.013 or 0.007, color, 0, 3)

		if major then
			local rad = math.rad(angle)
			local r = 0.71
			local n = label(dial, {
				Name = "Numeral" .. i,
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5 + math.cos(rad) * r * 0.5, 0.5 + math.sin(rad) * r * 0.5),
				Size = UDim2.fromScale(0.16, 0.09),
				FontFace = fontBlack,
				Text = tostring(math.round(frac * dialMax)),
				TextScaled = true,
				TextColor3 = red and COLOR.Accent or COLOR.Ink,
				TextXAlignment = Enum.TextXAlignment.Center,
				ZIndex = 4,
			})
			new("UITextSizeConstraint", { MaxTextSize = 22, Parent = n })
			table.insert(numerals, { label = n, frac = frac })
		end
	end

	needle = radialBar(dial, CONFIG.StartAngle, 1.02, 0.22, 0.012, COLOR.Ink, 0, 6)
	needle.Name = "Needle"

	-- centre readout
	local readout = new("Frame", {
		Name = "Readout",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.57),
		Size = UDim2.fromScale(0.7, 0.44),
		BackgroundTransparency = 1,
		ZIndex = 5,
		Parent = dial,
	})
	new("UIListLayout", {
		SortOrder = Enum.SortOrder.LayoutOrder, -- speed, unit, gear; the default sorts by name
		FillDirection = Enum.FillDirection.Vertical,
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		Padding = UDim.new(0, 2),
		Parent = readout,
	})

	speedText = label(readout, {
		Name = "Speed",
		Size = UDim2.fromScale(1, 0.58),
		FontFace = fontBlack,
		Text = "0",
		TextScaled = true,
		TextXAlignment = Enum.TextXAlignment.Center,
		LayoutOrder = 1,
	})

	label(readout, {
		Name = "Unit",
		Size = UDim2.fromScale(1, 0.13),
		Text = CONFIG.Unit,
		TextScaled = true,
		TextColor3 = COLOR.Muted,
		TextXAlignment = Enum.TextXAlignment.Center,
		LayoutOrder = 2,
	})

	gearText = label(readout, {
		Name = "Gear",
		Size = UDim2.fromScale(1, 0.2),
		FontFace = fontBlack,
		Text = "GEAR 1",
		TextScaled = true,
		TextColor3 = COLOR.Accent,
		TextXAlignment = Enum.TextXAlignment.Center,
		LayoutOrder = 3,
	})

	-- rev counter: a track and a fill arc on the outer ring, clear of the needle tip
	local rpm = new("Folder", { Name = "RPM", Parent = dial })
	for i = 0, CONFIG.RpmSegmentCount - 1 do
		local frac = (i + 0.5) / CONFIG.RpmSegmentCount
		local angle = CONFIG.StartAngle + frac * CONFIG.Sweep
		local track = radialBar(rpm, angle, 1.12, 0.05, 0.012, COLOR.Rule, 0, 1)
		track.Name = "Track"
		local seg = radialBar(rpm, angle, 1.12, 0.05, 0.028, COLOR.Ink, 1, 2)
		seg.Name = "Seg"
		rpmSegments[#rpmSegments + 1] = seg
		rpmSegmentFrac[#rpmSegmentFrac + 1] = frac
	end
	local limiter = radialBar(
		rpm,
		CONFIG.StartAngle + CONFIG.RpmLimiterFrac * CONFIG.Sweep,
		1.15,
		0.11,
		0.008,
		COLOR.Accent,
		0,
		3
	)
	limiter.Name = "Limiter"
end

local hide: () -> ()

-- Ground speed in MPH, and whether the car is rolling backwards.
local function carSpeed(chassis: BasePart): (number, boolean)
	local velocity = chassis.AssemblyLinearVelocity
	local speed = Vector3.new(velocity.X, 0, velocity.Z).Magnitude * MPH_PER_STUDS_PER_SECOND
	local reversing = velocity:Dot(chassis.CFrame.LookVector) < -CONFIG.ReverseSpeed
	return speed, reversing
end

local function render(dt: number)
	local chassis = car and car.PrimaryPart
	if not chassis then
		hide() -- the car is gone, e.g. it fell out of the world
		return
	end

	local speed, reversing = carSpeed(chassis)
	local target = math.clamp(speed, 0, dialMax)
	shown += (target - shown) * math.min(1, dt * 7) -- needle damping

	local frac = shown / dialMax
	needle.Rotation = CONFIG.StartAngle + frac * CONFIG.Sweep
	local rad = math.rad(needle.Rotation)
	local mid = 1.02 - 0.22 * 0.5
	needle.Position = UDim2.fromScale(0.5 + math.cos(rad) * mid * 0.5, 0.5 + math.sin(rad) * mid * 0.5)

	for i, seg in segments do
		seg.BackgroundTransparency = segmentFrac[i] <= frac and 0 or 1
	end

	-- gear + rpm from the ratio table; reverse revs through first gear's range
	local gear, lo = #CONFIG.GearTops, 0
	for g, top in CONFIG.GearTops do
		if frac < top then
			gear = g
			lo = g == 1 and 0 or CONFIG.GearTops[g - 1]
			break
		end
	end
	local gearFrac = (frac - lo) / math.max(0.0001, CONFIG.GearTops[gear] - lo)
	if reversing then
		gearFrac = math.min(frac / CONFIG.GearTops[1], 1)
	end
	local rpm = math.clamp(1300 + gearFrac * 6500, 820, CONFIG.RpmMax)
	shownRpm += (rpm - shownRpm) * math.min(1, dt * 9)

	speedText.Text = tostring(math.round(shown))
	gearText.Text = if reversing then "GEAR R" else "GEAR " .. gear

	local rpmFrac = shownRpm / CONFIG.RpmMax
	for i, seg in rpmSegments do
		seg.BackgroundTransparency = rpmSegmentFrac[i] <= rpmFrac and 0 or 1
	end
	local redlined = shownRpm > CONFIG.RpmRedline
	if redlined ~= rpmRedlined then
		rpmRedlined = redlined
		for _, seg in rpmSegments do
			seg.BackgroundColor3 = if redlined then COLOR.Accent else COLOR.Ink
		end
	end
end

function hide()
	car = nil
	if renderConnection then
		renderConnection:Disconnect()
		renderConnection = nil
	end
	gui.Enabled = false
end

local function show(newCar: Model)
	car = newCar

	local topSpeed = newCar:GetAttribute("TopSpeed")
	dialMax = dialMaxFor(if typeof(topSpeed) == "number" then topSpeed else CarConfig.DefaultStats.TopSpeed)
	for _, numeral in numerals do
		numeral.label.Text = tostring(math.round(numeral.frac * dialMax))
	end

	-- sweep up from rest every time you get in
	shown = 0
	shownRpm = 900
	gui.Enabled = true
	if not renderConnection then
		renderConnection = RunService.RenderStepped:Connect(render)
	end
	render(0) -- no stale frame from the last ride
end

local function seatChanged(seat: BasePart?)
	local model = seat and seat.Parent
	if model and model:IsA("Model") and model:GetAttribute("DriveableCar") then
		show(model)
	else
		hide()
	end
end

local function watchHumanoid(humanoid: Humanoid)
	humanoid.Seated:Connect(function(active: boolean, seat: BasePart?)
		seatChanged(if active then seat else nil)
	end)
	humanoid.Died:Connect(hide)

	-- Covers the case where we are already seated when this runs.
	seatChanged(humanoid.SeatPart)
end

function Speedometer.start()
	build()

	local player = Players.LocalPlayer

	local function characterAdded(character: Model)
		local humanoid = character:WaitForChild("Humanoid", 10)
		if humanoid and humanoid:IsA("Humanoid") then
			watchHumanoid(humanoid)
		end
	end

	player.CharacterAdded:Connect(characterAdded)
	player.CharacterRemoving:Connect(hide)

	if player.Character then
		task.spawn(characterAdded, player.Character)
	end
end

return Speedometer
