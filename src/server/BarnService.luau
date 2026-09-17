--[[
	BarnService -- barn finds: rusted cars left in barns for players to steal.

	Every part tagged BarnSpot (CollectionService) is where a barn keeps a car: its
	CFrame is the car's car-space origin, facing out of the barn door. The service
	keeps a Rusted car at each spot -- the spot's Car attribute if it has one,
	otherwise a catalog car picked by CarConfig.Barns.TierWeights.

	Anyone can take a barn find. Driving it into a part tagged GarageDropOff
	delivers it: the car is removed, it goes into the driver's restoration bay
	(PlayerDataService.receiveBarnFind), and after RespawnSeconds the barn has
	another car. A barn find left empty away from its barn for AbandonSeconds is
	towed back.
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local CarFolder = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Car")
local CarCatalog = require(CarFolder.CarCatalog)
local CarConfig = require(CarFolder.CarConfig)
local CarService = require(script.Parent.CarService)
local PlayerDataService = require(script.Parent.PlayerDataService)

local BARNS = CarConfig.Barns
local SPOT_TAG = "BarnSpot"
local DROP_OFF_TAG = "GarageDropOff"
local CHECK_INTERVAL = 0.25

local BarnService = {}

type Barn = {
	spot: BasePart,
	car: Model?,
	respawnAt: number?, -- os.clock() when an empty barn gets its next car
	awaySince: number?, -- os.clock() when its empty car was first seen away from the barn
}

local barns: { [BasePart]: Barn } = {}
local rng = Random.new()

local function debugPrint(message: string, ...)
	if CarConfig.Debug then
		print(("[BarnService] " .. message):format(...))
	end
end

-- A catalog car for a spot: the one it names, or one of a tier picked by weight.
local function pickCar(spot: BasePart): string
	local named = spot:GetAttribute("Car")
	if typeof(named) == "string" and CarCatalog.get(named) then
		return named
	end

	local byTier: { [string]: { string } } = {}
	for _, car in CarCatalog.getAll() do
		byTier[car.Tier] = byTier[car.Tier] or {}
		table.insert(byTier[car.Tier], car.Id)
	end

	local total = 0
	for tier, weight in BARNS.TierWeights do
		if byTier[tier] then
			total += weight
		end
	end
	local roll = rng:NextNumber() * total
	for tier, weight in BARNS.TierWeights do
		local cars = byTier[tier]
		if cars then
			roll -= weight
			if roll <= 0 then
				return cars[rng:NextInteger(1, #cars)]
			end
		end
	end
	return CarCatalog.getDefault().Id
end

local function addLabel(car: Model)
	local chassis = car.PrimaryPart
	if not chassis then
		return
	end

	local label = Instance.new("BillboardGui")
	label.Name = "BarnFindLabel"
	label.Size = UDim2.fromOffset(240, 58)
	label.StudsOffsetWorldSpace = Vector3.new(0, chassis.Size.Y / 2 + 3, 0)
	label.MaxDistance = 90
	label.LightInfluence = 0
	label.Parent = chassis

	local title = Instance.new("TextLabel")
	title.Size = UDim2.new(1, 0, 0.5, 0)
	title.BackgroundTransparency = 1
	title.FontFace = Font.fromEnum(Enum.Font.GothamBlack)
	title.Text = "BARN FIND"
	title.TextColor3 = Color3.fromRGB(255, 176, 64)
	title.TextScaled = true
	title.TextStrokeTransparency = 0.4
	title.Parent = label

	local subtitle = Instance.new("TextLabel")
	subtitle.Position = UDim2.fromScale(0, 0.5)
	subtitle.Size = UDim2.new(1, 0, 0.5, 0)
	subtitle.BackgroundTransparency = 1
	subtitle.FontFace = Font.fromEnum(Enum.Font.GothamBold)
	subtitle.Text = car.Name .. " -- steal it, bring it to your garage"
	subtitle.TextColor3 = Color3.fromRGB(240, 240, 240)
	subtitle.TextScaled = true
	subtitle.TextStrokeTransparency = 0.4
	subtitle.Parent = label
end

local function stock(barn: Barn)
	barn.respawnAt = nil
	barn.awaySince = nil

	local carId = pickCar(barn.spot)
	local car = CarService.spawnCar(carId, barn.spot.CFrame, true, nil, "Rusted")
	if not car then
		-- Try again later rather than every check.
		barn.respawnAt = os.clock() + BARNS.RespawnSeconds
		return
	end

	car:SetAttribute("BarnFind", true)
	addLabel(car)
	barn.car = car
	debugPrint("%s is waiting in %s", car.Name, barn.spot:GetFullName())
end

local function inDropOff(position: Vector3): boolean
	for _, zone in CollectionService:GetTagged(DROP_OFF_TAG) do
		if zone:IsA("BasePart") then
			local offset = zone.CFrame:PointToObjectSpace(position)
			local half = zone.Size / 2
			if math.abs(offset.X) <= half.X and math.abs(offset.Y) <= half.Y and math.abs(offset.Z) <= half.Z then
				return true
			end
		end
	end
	return false
end

local function deliver(barn: Barn, car: Model, driver: Player)
	local carId = car:GetAttribute("CarId")
	barn.car = nil
	barn.respawnAt = os.clock() + BARNS.RespawnSeconds

	CarService.removeCar(car)
	if typeof(carId) == "string" then
		PlayerDataService.receiveBarnFind(driver, carId)
	end
	debugPrint("%s delivered %s", driver.Name, car.Name)
end

local function check()
	local now = os.clock()
	for _, barn in barns do
		local car = barn.car

		if not car then
			if barn.respawnAt and now >= barn.respawnAt then
				stock(barn)
			end
			continue
		end

		local chassis = car.PrimaryPart
		if not (car.Parent and chassis) then
			-- Gone some other way (destroyed, removed by a script): restock later.
			barn.car = nil
			barn.respawnAt = now + BARNS.RespawnSeconds
			continue
		end

		local driver = CarService.driverOf(car)
		if driver then
			barn.awaySince = nil
			if inDropOff(chassis.Position) then
				deliver(barn, car, driver)
			end
		elseif (chassis.Position - barn.spot.Position).Magnitude > BARNS.AbandonDistance then
			barn.awaySince = barn.awaySince or now
			if now - barn.awaySince >= BARNS.AbandonSeconds then
				debugPrint("towing abandoned %s back to its barn", car.Name)
				barn.car = nil
				CarService.removeCar(car)
				stock(barn)
			end
		else
			barn.awaySince = nil
		end
	end
end

local function addSpot(spot: Instance)
	if not spot:IsA("BasePart") or barns[spot] then
		return
	end
	local barn: Barn = { spot = spot, car = nil, respawnAt = nil, awaySince = nil }
	barns[spot] = barn
	stock(barn)
end

function BarnService.start()
	for _, spot in CollectionService:GetTagged(SPOT_TAG) do
		addSpot(spot)
	end
	CollectionService:GetInstanceAddedSignal(SPOT_TAG):Connect(addSpot)

	local sinceCheck = 0
	RunService.Heartbeat:Connect(function(deltaTime)
		sinceCheck += deltaTime
		if sinceCheck >= CHECK_INTERVAL then
			sinceCheck = 0
			check()
		end
	end)

	debugPrint("%d barns, %d drop-offs", #CollectionService:GetTagged(SPOT_TAG), #CollectionService:GetTagged(DROP_OFF_TAG))
end

--[[
	For Studio's command bar in edit mode: puts a rusted stand-in in every barn
	that does not have one, so the barns show their cars while you build.

		require(game.ServerScriptService.Server.BarnService).placeInStudio()

	(The stand-ins only show what a barn looks like stocked; when the game starts
	each barn gets its own car.)
]]
function BarnService.placeInStudio()
	local cars = workspace:FindFirstChild("Cars")
	for _, spot in CollectionService:GetTagged(SPOT_TAG) do
		if not spot:IsA("BasePart") then
			continue
		end
		local stocked = false
		for _, standIn in (if cars then cars:GetChildren() else {}) do
			local chassis = standIn:IsA("Model") and standIn.PrimaryPart
			if standIn:GetAttribute("BarnFind") and chassis and (chassis.Position - spot.Position).Magnitude < 12 then
				stocked = true
			end
		end
		if not stocked then
			CarService.placeBarnStandIn(pickCar(spot), spot.CFrame)
		end
	end
end

return BarnService
