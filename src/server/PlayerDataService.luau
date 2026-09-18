--[[
	PlayerDataService -- Manages economy, inventory, cardex discovery,
	and remote request handlers for Shop, Garage, and Teleportation.

	Real-money purchases are not handled here: MonetizationService owns them and
	calls addCash / setPassOwned once MarketplaceService has confirmed a sale.

	Also the garage's restoration bay: a barn find delivered by BarnService
	becomes a restoration job, which goes through retrieval and then
	recuperation (CarConfig.Restoration) before the car is added to OwnedCars.

	Every car a player owns carries a CarOrigins record naming whoever first
	owned it. Buying, claiming or restoring a car writes that record; trading it
	hands the record over untouched but for a bumped trade count, so a car that
	has changed hands still says where it came from. swapCars is where two
	players' cars move, and TradingService is the only caller.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local SharedFolder = ReplicatedStorage:WaitForChild("Shared")
local CarFolder = SharedFolder:WaitForChild("Car")
local CarCatalog = require(CarFolder.CarCatalog)
local CarConfig = require(CarFolder.CarConfig)
local Trading = require(SharedFolder.Trading)
local CarService = require(script.Parent.CarService)

local RESTORATION = CarConfig.Restoration

local PlayerDataService = {}

-- A car in the restoration bay. Times are Workspace:GetServerTimeNow(), which
-- clients share, so the garage screen can count down without asking.
export type RestorationJob = {
	CarId: string,
	StartedAt: number,
	RetrievalSeconds: number,
	RecuperationSeconds: number,
}

-- Who first owned a car, and how many times it has changed hands since. Follows
-- the car through every trade; CarService.stampOwnership puts it on the model.
export type CarOrigin = {
	OriginalUserId: number,
	OriginalUserName: string,
	AcquiredAt: number,
	Trades: number,
}

export type PlayerData = {
	Cash: number,
	OwnedCars: { [string]: boolean },
	CardexDiscovered: { [string]: boolean },
	SelectedCar: string,
	Paints: { [string]: { R: number, G: number, B: number } },
	Has2xCash: boolean,
	IsVIP: boolean,
	HasNitro: boolean,
	Restorations: { RestorationJob },
	CarOrigins: { [string]: CarOrigin },
}

local sessionData: { [Player]: PlayerData } = {}
local remotesFolder: Folder
local syncRemote: RemoteEvent
local buyRemote: RemoteFunction
local spawnRemote: RemoteFunction
local despawnRemote: RemoteFunction
local teleportRemote: RemoteFunction
local getDataRemote: RemoteFunction
local notifyRemote: RemoteEvent

-- The only PlayerData fields a game pass may set, so a bad flag name cannot
-- write a new field onto someone's data.
local PASS_FLAGS: { [string]: boolean } = {
	Has2xCash = true,
	IsVIP = true,
	HasNitro = true,
}

local STARTING_CASH = 25000
local PLAYTIME_BONUS = 500
local PLAYTIME_INTERVAL = 60
local playerJoinIndex = 0

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
		Restorations = {},
		CarOrigins = {},
	}
end

--[[
	Names `player` the original user of `carId`, unless the car already carries
	someone's name -- a traded car keeps whoever first owned it, and that is what
	its nameplate shows for the rest of the car's life.
]]
local function recordOrigin(player: Player, data: PlayerData, carId: string)
	if data.CarOrigins[carId] then
		return
	end
	data.CarOrigins[carId] = {
		OriginalUserId = player.UserId,
		OriginalUserName = player.Name,
		AcquiredAt = Workspace:GetServerTimeNow(),
		Trades = 0,
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
	playerJoinIndex += 1
	local data = createDefaultData()
	sessionData[player] = data

	-- Give each player 2 tradeable cars with complementary sets so any two players can trade right away
	-- Set A: "ApexGT" (Apex GT3) & "Monaco74" (Monaco Classic 1974)
	-- Set B: "SpectreV10" (Spectre V10) & "PhantomEV" (Phantom Hyper EV)
	local tradeableSets = if playerJoinIndex % 2 == 1
		then { "ApexGT", "Monaco74" }
		else { "SpectreV10", "PhantomEV" }

	for _, carId in tradeableSets do
		local carEntry = CarCatalog.get(carId)
		if carEntry then
			data.OwnedCars[carId] = true
			data.CardexDiscovered[carId] = true
			data.Paints[carId] = {
				R = carEntry.DefaultColor.R,
				G = carEntry.DefaultColor.G,
				B = carEntry.DefaultColor.B,
			}
		end
	end

	-- Record provenance for all starting owned cars
	for carId in data.OwnedCars do
		recordOrigin(player, data, carId)
	end

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
	recordOrigin(player, data, carId)

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

	recordOrigin(player, data, carId)

	local ok, msg, car = CarService.spawnForPlayer(player, carId, paintColor)
	if car then
		local origin = data.CarOrigins[carId]
		CarService.stampOwnership(car, {
			OwnerUserId = player.UserId,
			OwnerName = player.DisplayName,
			OriginalUserId = origin.OriginalUserId,
			OriginalUserName = origin.OriginalUserName,
			Trades = origin.Trades,
		})
	end

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

--[[
	Pops a toast on `player`'s screen.
]]
function PlayerDataService.notify(player: Player, message: string, isError: boolean?)
	if notifyRemote then
		notifyRemote:FireClient(player, message, isError == true)
	end
end

--[[
	`player` has delivered the barn find `carId` to their garage. It goes into the
	restoration bay -- unless they already own it or already have one in there, in
	which case it is sold for scrap.
]]
function PlayerDataService.receiveBarnFind(player: Player, carId: string)
	local data = sessionData[player]
	local car = CarCatalog.get(carId)
	if not (data and car) then
		return
	end
	data.CardexDiscovered[carId] = true

	local alreadyRestoring = false
	for _, job in data.Restorations do
		if job.CarId == carId then
			alreadyRestoring = true
		end
	end

	if data.OwnedCars[carId] or alreadyRestoring then
		local scrap = math.max(RESTORATION.MinScrap, math.floor(car.Price * RESTORATION.ScrapShare))
		data.Cash += scrap
		updateLeaderstats(player, data.Cash)
		PlayerDataService.notify(
			player,
			string.format("You already have a %s -- sold this one for scrap: %s", car.DisplayName, "$" .. scrap)
		)
	else
		table.insert(data.Restorations, {
			CarId = carId,
			StartedAt = Workspace:GetServerTimeNow(),
			RetrievalSeconds = RESTORATION.Retrieval[car.Tier] or 30,
			RecuperationSeconds = RESTORATION.Recuperation[car.Tier] or 120,
		})
		PlayerDataService.notify(player, string.format("%s delivered! Retrieval has started in your garage.", car.DisplayName))
	end
	syncToClient(player)
end

-- Moves finished restorations into the player's owned cars.
local function finishRestorations()
	local now = Workspace:GetServerTimeNow()
	for player, data in sessionData do
		local changed = false
		for i = #data.Restorations, 1, -1 do
			local job = data.Restorations[i]
			if now >= job.StartedAt + job.RetrievalSeconds + job.RecuperationSeconds then
				table.remove(data.Restorations, i)
				data.OwnedCars[job.CarId] = true
				data.CardexDiscovered[job.CarId] = true
				-- They pulled it out of a barn, so the car starts its history here.
				recordOrigin(player, data, job.CarId)
				changed = true

				local car = CarCatalog.get(job.CarId)
				PlayerDataService.notify(
					player,
					string.format("%s is restored and ready to drive in your garage!", if car then car.DisplayName else job.CarId)
				)
			end
		end
		if changed and player.Parent then
			syncToClient(player)
		end
	end
end

--[[
	Who first owned `player`'s `carId`, if their data is loaded and they own it.
]]
function PlayerDataService.originOf(player: Player, carId: string): CarOrigin?
	local data = sessionData[player]
	return if data then data.CarOrigins[carId] else nil
end

--[[
	Why `owner` cannot hand `carId` to `receiver`, or nil if they can. Only
	TradingService asks, and it asks again through swapCars before anything moves.
]]
function PlayerDataService.offerProblem(owner: Player, receiver: Player, carId: any): string?
	local ownerData, receiverData = sessionData[owner], sessionData[receiver]
	if not (ownerData and receiverData) then
		return "Player data is not loaded"
	end
	if typeof(carId) ~= "string" then
		return "That vehicle is not in the catalog"
	end
	return Trading.offerProblem(
		CarCatalog.get(carId),
		owner.Name,
		ownerData.OwnedCars,
		receiver.Name,
		receiverData.OwnedCars
	)
end

-- Hands one car over: the origin record goes with it, one trade heavier, and so
-- does the paint, which belongs to the car rather than to whoever had it last.
local function handOver(from: Player, fromData: PlayerData, toData: PlayerData, carId: string)
	local origin = fromData.CarOrigins[carId]
	fromData.OwnedCars[carId] = nil
	fromData.CarOrigins[carId] = nil

	toData.OwnedCars[carId] = true
	toData.CardexDiscovered[carId] = true
	toData.CarOrigins[carId] = {
		OriginalUserId = if origin then origin.OriginalUserId else from.UserId,
		OriginalUserName = if origin then origin.OriginalUserName else from.Name,
		AcquiredAt = Workspace:GetServerTimeNow(),
		Trades = (if origin then origin.Trades else 0) + 1,
	}

	toData.Paints[carId] = fromData.Paints[carId]
	fromData.Paints[carId] = nil
end

-- Nobody is left selecting, or driving, a car they have just traded away.
local function releaseTradedAway(player: Player, data: PlayerData)
	if not data.OwnedCars[data.SelectedCar] then
		for _, car in CarCatalog.getAll() do
			if data.OwnedCars[car.Id] then
				data.SelectedCar = car.Id
				break
			end
		end
	end

	local spawned = CarService.spawnedCarIdFor(player)
	if spawned and not data.OwnedCars[spawned] then
		CarService.despawnForPlayer(player)
	end
end

--[[
	Swaps `aCars` for `bCars` between two players, or changes nothing at all.
	Every car is checked against Trading's rules first, so a trade that has gone
	stale since it was agreed -- a car restored, bought or traded away in the
	meantime -- fails whole and says which car spoiled it. TradingService is the
	only caller, and only once both players have confirmed.
]]
function PlayerDataService.swapCars(a: Player, aCars: { string }, b: Player, bCars: { string }): (boolean, string)
	local dataA, dataB = sessionData[a], sessionData[b]
	if not (dataA and dataB) then
		return false, "Player data is not loaded"
	end

	for _, side in { { from = a, cars = aCars, to = b }, { from = b, cars = bCars, to = a } } do
		local seen: { [string]: boolean } = {}
		for _, carId in side.cars do
			if typeof(carId) ~= "string" or seen[carId] then
				return false, "That trade is no longer valid"
			end
			seen[carId] = true
			local problem = PlayerDataService.offerProblem(side.from, side.to, carId)
			if problem then
				return false, problem
			end
		end
	end

	for _, carId in aCars do
		handOver(a, dataA, dataB, carId)
	end
	for _, carId in bCars do
		handOver(b, dataB, dataA, carId)
	end

	releaseTradedAway(a, dataA)
	releaseTradedAway(b, dataB)
	syncToClient(a)
	syncToClient(b)
	return true, "Trade complete"
end

--[[
	Adds `amount` to `player`'s cash. Returns false if their data is not loaded,
	which is the caller's cue that nothing was granted -- MonetizationService
	relies on that to hold a receipt open instead of consuming it.
]]
function PlayerDataService.addCash(player: Player, amount: number): boolean
	local data = sessionData[player]
	if not data or typeof(amount) ~= "number" then
		return false
	end

	data.Cash += amount
	updateLeaderstats(player, data.Cash)
	syncToClient(player)
	return true
end

--[[
	Mirrors Roblox-side game pass ownership onto `player`'s data. Only
	MonetizationService calls this, and only after MarketplaceService has
	confirmed ownership -- these flags are what the game reads for 2x cash,
	VIP and nitro, so nothing a client sends may reach them.
]]
function PlayerDataService.setPassOwned(player: Player, flag: string, owned: boolean): boolean
	local data = sessionData[player]
	if not data or not PASS_FLAGS[flag] then
		return false
	end

	local record = data :: any
	if record[flag] == owned then
		return true
	end

	record[flag] = owned
	syncToClient(player)
	return true
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

	notifyRemote = Instance.new("RemoteEvent")
	notifyRemote.Name = "Notify"
	notifyRemote.Parent = remotesFolder

	task.spawn(function()
		while true do
			task.wait(1)
			finishRestorations()
		end
	end)

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
