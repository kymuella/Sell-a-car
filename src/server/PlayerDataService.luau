--[[
	PlayerDataService -- Manages economy, inventory, cardex discovery,
	and remote request handlers for Shop, Garage, and Teleportation.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CarFolder = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Car")
local CarCatalog = require(CarFolder.CarCatalog)
local CarService = require(script.Parent.CarService)

local PlayerDataService = {}

export type PlayerData = {
	Cash: number,
	OwnedCars: { [string]: boolean },
	CardexDiscovered: { [string]: boolean },
	SelectedCar: string,
	Paints: { [string]: { R: number, G: number, B: number } },
	Has2xCash: boolean,
	IsVIP: boolean,
	HasNitro: boolean,
}

local sessionData: { [Player]: PlayerData } = {}
local remotesFolder: Folder
local syncRemote: RemoteEvent
local buyRemote: RemoteFunction
local buyRobuxRemote: RemoteFunction
local spawnRemote: RemoteFunction
local despawnRemote: RemoteFunction
local teleportRemote: RemoteFunction
local getDataRemote: RemoteFunction

local STARTING_CASH = 25000
local PLAYTIME_BONUS = 500
local PLAYTIME_INTERVAL = 60

local function createDefaultData(): PlayerData
	local defaultCar = CarCatalog.getDefault()
	return {
		Cash = STARTING_CASH,
		OwnedCars = {
			[defaultCar.Id] = true,
		},
		CardexDiscovered = {
			[defaultCar.Id] = true,
		},
		SelectedCar = defaultCar.Id,
		Paints = {},
		Has2xCash = false,
		IsVIP = false,
		HasNitro = false,
	}
end

local function syncToClient(player: Player)
	local data = sessionData[player]
	if data and syncRemote then
		syncRemote:FireClient(player, data)
	end
end

local function updateLeaderstats(player: Player, cash: number)
	local stats = player:FindFirstChild("leaderstats")
	if stats then
		local cashVal = stats:FindFirstChild("Cash")
		if cashVal and cashVal:IsA("IntValue") then
			cashVal.Value = cash
		end
	end
end

local function setupPlayer(player: Player)
	local data = createDefaultData()
	sessionData[player] = data

	-- Setup Roblox standard leaderboard stats
	local leaderstats = Instance.new("Folder")
	leaderstats.Name = "leaderstats"
	leaderstats.Parent = player

	local cash = Instance.new("IntValue")
	cash.Name = "Cash"
	cash.Value = data.Cash
	cash.Parent = leaderstats

	task.delay(0.5, function()
		if player.Parent then
			syncToClient(player)
		end
	end)
end

local function onPlayerRemoving(player: Player)
	sessionData[player] = nil
end

local function onGetPlayerData(player: Player): PlayerData?
	return sessionData[player]
end

local function onBuyCar(player: Player, carId: any): (boolean, string)
	if typeof(carId) ~= "string" then
		return false, "Invalid car selection"
	end

	local car = CarCatalog.get(carId)
	if not car then
		return false, "Vehicle not found in catalog"
	end

	local data = sessionData[player]
	if not data then
		return false, "Player data not loaded"
	end

	if data.OwnedCars[carId] then
		return false, "You already own this vehicle!"
	end

	if data.Cash < car.Price then
		return false, string.format("Insufficient funds! You need $%d more.", car.Price - data.Cash)
	end

	-- Deduct cash and grant car
	data.Cash -= car.Price
	data.OwnedCars[carId] = true
	data.CardexDiscovered[carId] = true
	data.SelectedCar = carId

	updateLeaderstats(player, data.Cash)
	syncToClient(player)

	return true, string.format("Purchased %s for $%d!", car.DisplayName, car.Price)
end

local function onSpawnCar(player: Player, carId: any, customPaint: any): (boolean, string)
	if typeof(carId) ~= "string" then
		return false, "Invalid vehicle"
	end

	local data = sessionData[player]
	if not data then
		return false, "Player data not loaded"
	end

	if not data.OwnedCars[carId] then
		return false, "You do not own this vehicle yet!"
	end

	data.SelectedCar = carId

	local paintColor: Color3? = nil
	if typeof(customPaint) == "Color3" then
		paintColor = customPaint
		data.Paints[carId] = { R = customPaint.R, G = customPaint.G, B = customPaint.B }
	elseif data.Paints[carId] then
		local p = data.Paints[carId]
		paintColor = Color3.new(p.R, p.G, p.B)
	end

	local ok, msg = CarService.spawnForPlayer(player, carId, paintColor)
	syncToClient(player)
	return ok, msg
end

local function onDespawnCar(player: Player): (boolean, string)
	local ok = CarService.despawnForPlayer(player)
	if ok then
		return true, "Vehicle stored in garage"
	else
		return false, "No active vehicle to despawn"
	end
end

local function onTeleportToPlay(player: Player): (boolean, string)
	local ok = CarService.teleportPlayerToPlay(player)
	if ok then
		return true, "Teleported to Playing Area!"
	else
		return false, "Could not teleport right now"
	end
end

local function onBuyRobuxProduct(player: Player, productId: any): (boolean, string)
	local data = sessionData[player]
	if not data then
		return false, "Player data not loaded"
	end

	if productId == "cash_small" then
		data.Cash += 50000
		updateLeaderstats(player, data.Cash)
		syncToClient(player)
		return true, "Acquired +$50,000 Cash!"
	elseif productId == "cash_medium" then
		data.Cash += 200000
		updateLeaderstats(player, data.Cash)
		syncToClient(player)
		return true, "Acquired +$200,000 Cash!"
	elseif productId == "cash_large" then
		data.Cash += 1000000
		updateLeaderstats(player, data.Cash)
		syncToClient(player)
		return true, "Acquired +$1,000,000 Cash!"
	elseif productId == "pass_2xcash" then
		if data.Has2xCash then
			return false, "You already own the 2x Cash Multiplier!"
		end
		data.Has2xCash = true
		syncToClient(player)
		return true, "Unlocked 2x Cash Multiplier!"
	elseif productId == "pass_vip" then
		if data.IsVIP then
			return false, "You already own the VIP Pass!"
		end
		data.IsVIP = true
		syncToClient(player)
		return true, "Unlocked VIP Pass!"
	elseif productId == "pass_nitro" then
		if data.HasNitro then
			return false, "You already own the Nitro Boost Pass!"
		end
		data.HasNitro = true
		syncToClient(player)
		return true, "Unlocked Nitro Boost!"
	else
		return false, "Unknown product"
	end
end

function PlayerDataService.start()
	-- Create Remote network folder in ReplicatedStorage
	remotesFolder = Instance.new("Folder")
	remotesFolder.Name = "GameRemotes"
	remotesFolder.Parent = ReplicatedStorage

	syncRemote = Instance.new("RemoteEvent")
	syncRemote.Name = "PlayerDataSync"
	syncRemote.Parent = remotesFolder

	getDataRemote = Instance.new("RemoteFunction")
	getDataRemote.Name = "GetPlayerData"
	getDataRemote.OnServerInvoke = onGetPlayerData
	getDataRemote.Parent = remotesFolder

	buyRemote = Instance.new("RemoteFunction")
	buyRemote.Name = "BuyCar"
	buyRemote.OnServerInvoke = onBuyCar
	buyRemote.Parent = remotesFolder

	buyRobuxRemote = Instance.new("RemoteFunction")
	buyRobuxRemote.Name = "BuyRobuxProduct"
	buyRobuxRemote.OnServerInvoke = onBuyRobuxProduct
	buyRobuxRemote.Parent = remotesFolder

	spawnRemote = Instance.new("RemoteFunction")
	spawnRemote.Name = "SpawnCar"
	spawnRemote.OnServerInvoke = onSpawnCar
	spawnRemote.Parent = remotesFolder

	despawnRemote = Instance.new("RemoteFunction")
	despawnRemote.Name = "DespawnCar"
	despawnRemote.OnServerInvoke = onDespawnCar
	despawnRemote.Parent = remotesFolder

	teleportRemote = Instance.new("RemoteFunction")
	teleportRemote.Name = "TeleportToPlay"
	teleportRemote.OnServerInvoke = onTeleportToPlay
	teleportRemote.Parent = remotesFolder

	Players.PlayerAdded:Connect(setupPlayer)
	Players.PlayerRemoving:Connect(onPlayerRemoving)

	for _, player in Players:GetPlayers() do
		task.spawn(setupPlayer, player)
	end

	-- Passive playtime bonus loop with multiplier support
	task.spawn(function()
		while true do
			task.wait(PLAYTIME_INTERVAL)
			for player, data in sessionData do
				if player.Parent then
					local mult = if data.Has2xCash then 2 else 1
					data.Cash += PLAYTIME_BONUS * mult
					updateLeaderstats(player, data.Cash)
					syncToClient(player)
				end
			end
		end
	end)
end

return PlayerDataService
