--[[
	BarnFindHUD -- while you sit in a barn find, shows what you have stolen and
	how far it is to a garage drop-off, and marks the nearest drop-off with a
	waypoint you can see through walls. It goes away when you get out, or when
	the car is delivered.

	Barn finds carry a BarnFind attribute (BarnService); drop-offs are parts
	tagged GarageDropOff. Seating is detected with Humanoid.Seated, for the same
	reason as in CarController.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local DROP_OFF_TAG = "GarageDropOff"
local UPDATE_INTERVAL = 0.2
local ACCENT = Color3.fromRGB(255, 176, 64)

local BarnFindHUD = {}

local player = Players.LocalPlayer

local gui: ScreenGui
local titleLabel: TextLabel
local distanceLabel: TextLabel
local waypoint: BillboardGui
local waypointDistance: TextLabel

local car: Model? = nil
local updateConnection: RBXScriptConnection? = nil

local function new(className: string, props: { [string]: any }): any
	local instance = Instance.new(className)
	for key, value in props do
		if key ~= "Parent" then
			(instance :: any)[key] = value
		end
	end
	instance.Parent = props.Parent
	return instance
end

local function build()
	local playerGui = player:WaitForChild("PlayerGui")

	gui = new("ScreenGui", {
		Name = "BarnFindHUD",
		Enabled = false,
		ResetOnSpawn = false,
		Parent = playerGui,
	})

	local banner = new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 84),
		Size = UDim2.fromOffset(420, 58),
		BackgroundColor3 = Color3.fromRGB(20, 18, 16),
		BackgroundTransparency = 0.15,
		BorderSizePixel = 0,
		Parent = gui,
	})
	new("UICorner", { CornerRadius = UDim.new(0, 10), Parent = banner })
	new("UIStroke", { Color = ACCENT, Transparency = 0.3, Thickness = 1.5, Parent = banner })

	titleLabel = new("TextLabel", {
		Position = UDim2.fromOffset(16, 8),
		Size = UDim2.new(1, -32, 0, 22),
		BackgroundTransparency = 1,
		FontFace = Font.fromEnum(Enum.Font.GothamBlack),
		Text = "",
		TextColor3 = ACCENT,
		TextSize = 17,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = banner,
	})

	distanceLabel = new("TextLabel", {
		Position = UDim2.fromOffset(16, 31),
		Size = UDim2.new(1, -32, 0, 18),
		BackgroundTransparency = 1,
		FontFace = Font.fromEnum(Enum.Font.GothamMedium),
		Text = "",
		TextColor3 = Color3.fromRGB(230, 230, 230),
		TextSize = 13,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = banner,
	})

	waypoint = new("BillboardGui", {
		Name = "GarageWaypoint",
		Size = UDim2.fromOffset(170, 56),
		AlwaysOnTop = true,
		LightInfluence = 0,
		Enabled = false,
		Parent = playerGui,
	})
	new("TextLabel", {
		Size = UDim2.new(1, 0, 0.55, 0),
		BackgroundTransparency = 1,
		FontFace = Font.fromEnum(Enum.Font.GothamBlack),
		Text = "YOUR GARAGE",
		TextColor3 = ACCENT,
		TextScaled = true,
		TextStrokeTransparency = 0.3,
		Parent = waypoint,
	})
	waypointDistance = new("TextLabel", {
		Position = UDim2.fromScale(0, 0.55),
		Size = UDim2.new(1, 0, 0.45, 0),
		BackgroundTransparency = 1,
		FontFace = Font.fromEnum(Enum.Font.GothamBold),
		Text = "",
		TextColor3 = Color3.fromRGB(255, 255, 255),
		TextScaled = true,
		TextStrokeTransparency = 0.3,
		Parent = waypoint,
	})
end

local function nearestDropOff(from: Vector3): (BasePart?, number)
	local best, bestDistance = nil, math.huge
	for _, zone in CollectionService:GetTagged(DROP_OFF_TAG) do
		if zone:IsA("BasePart") then
			local distance = (zone.Position - from).Magnitude
			if distance < bestDistance then
				best, bestDistance = zone, distance
			end
		end
	end
	return best, bestDistance
end

local function update()
	local chassis = car and car.Parent and car.PrimaryPart
	if not chassis then
		BarnFindHUD.hide()
		return
	end

	local zone, distance = nearestDropOff(chassis.Position)
	if zone then
		distanceLabel.Text = ("Drive it into your garage's drop-off -- %d studs"):format(math.round(distance))
		waypoint.Adornee = zone
		waypoint.Enabled = true
		waypointDistance.Text = ("%d studs"):format(math.round(distance))
	else
		distanceLabel.Text = "Drive it back to your garage"
		waypoint.Enabled = false
	end
end

function BarnFindHUD.hide()
	car = nil
	if updateConnection then
		updateConnection:Disconnect()
		updateConnection = nil
	end
	gui.Enabled = false
	waypoint.Enabled = false
end

local function show(barnFind: Model)
	car = barnFind
	titleLabel.Text = "STOLEN: " .. barnFind.Name
	gui.Enabled = true
	update()

	if not updateConnection then
		local sinceUpdate = 0
		updateConnection = RunService.Heartbeat:Connect(function(deltaTime)
			sinceUpdate += deltaTime
			if sinceUpdate >= UPDATE_INTERVAL then
				sinceUpdate = 0
				update()
			end
		end)
	end
end

local function seatChanged(seat: BasePart?)
	local model = seat and seat.Parent
	if model and model:IsA("Model") and model:GetAttribute("BarnFind") then
		show(model)
	else
		BarnFindHUD.hide()
	end
end

local function watchHumanoid(humanoid: Humanoid)
	humanoid.Seated:Connect(function(active: boolean, seat: BasePart?)
		seatChanged(if active then seat else nil)
	end)
	humanoid.Died:Connect(BarnFindHUD.hide)
	seatChanged(humanoid.SeatPart)
end

function BarnFindHUD.start()
	build()

	local function characterAdded(character: Model)
		local humanoid = character:WaitForChild("Humanoid", 10)
		if humanoid and humanoid:IsA("Humanoid") then
			watchHumanoid(humanoid)
		end
	end

	player.CharacterAdded:Connect(characterAdded)
	player.CharacterRemoving:Connect(BarnFindHUD.hide)
	if player.Character then
		task.spawn(characterAdded, player.Character)
	end
end

return BarnFindHUD
