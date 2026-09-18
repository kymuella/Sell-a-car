--[[
	MonetizationService -- every Robux purchase in the game passes through here,
	and nothing is granted without MarketplaceService saying a sale happened.

	Cash packs are developer products. The client can only ask for a prompt;
	Roblox runs the purchase and hands the server a receipt, and the cash is
	added inside ProcessReceipt, which reports PurchaseGranted only after
	PlayerDataService has actually recorded the grant.

	2x cash, VIP and nitro are game passes. Ownership is asked of
	MarketplaceService when a player joins and again when a purchase prompt
	finishes, then mirrored onto their data flags. Passes therefore survive
	rejoining and server hops on their own -- Roblox stores that ownership.

	The RequestPurchasePrompt remote opens Roblox's purchase dialog and does
	nothing else, so firing it by hand buys a player a prompt and no more.
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SharedFolder = ReplicatedStorage:WaitForChild("Shared")
local Monetization = require(SharedFolder.Monetization)
local PlayerDataService = require(script.Parent.PlayerDataService)

local PROMPT_COOLDOWN = 0.5

local MonetizationService = {}

-- Receipts already granted in this server. Player data is session-only, so this
-- is as far as receipt de-duplication can go; see the note at the top of start().
local handledPurchases: { [string]: boolean } = {}
local lastPromptAt: { [Player]: number } = {}

local function formatCash(amount: number): string
	local formatted = tostring(amount)
	while true do
		local replaced
		formatted, replaced = string.gsub(formatted, "^(-?%d+)(%d%d%d)", "%1,%2")
		if replaced == 0 then
			break
		end
	end
	return "$" .. formatted
end

--[[
	Roblox handing us a completed developer product purchase. Returning anything
	other than PurchaseGranted leaves the receipt open, so Roblox brings it back
	later -- which is what we want whenever we cannot grant the cash right now.
]]
local function processReceipt(receiptInfo: any): Enum.ProductPurchaseDecision
	local player = Players:GetPlayerByUserId(receiptInfo.PlayerId)
	if not player then
		-- They left mid-purchase: hold the receipt until they are back.
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	if handledPurchases[receiptInfo.PurchaseId] then
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end

	local product = Monetization.getProductById(receiptInfo.ProductId)
	if not product then
		warn(
			string.format(
				"MonetizationService: receipt for ProductId %s has no entry in Monetization.Products -- holding it",
				tostring(receiptInfo.ProductId)
			)
		)
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	if not PlayerDataService.addCash(player, product.Cash) then
		-- Data is not loaded yet; hold the receipt rather than eat the purchase.
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	handledPurchases[receiptInfo.PurchaseId] = true
	PlayerDataService.notify(player, string.format("%s delivered -- %s added!", product.Name, formatCash(product.Cash)))
	return Enum.ProductPurchaseDecision.PurchaseGranted
end

--[[
	Asks Roblox whether `player` owns `pass` and writes the answer to their data.
]]
local function refreshPass(player: Player, pass: Monetization.Pass)
	if not Monetization.isConfigured(pass.GamePassId) then
		return
	end

	local ok, owned = pcall(function()
		return MarketplaceService:UserOwnsGamePassAsync(player.UserId, pass.GamePassId)
	end)

	if ok then
		PlayerDataService.setPassOwned(player, pass.Flag, owned == true)
	else
		warn(string.format("MonetizationService: ownership check for %s failed: %s", pass.Key, tostring(owned)))
	end
end

local function refreshAllPasses(player: Player)
	for _, pass in Monetization.Passes do
		refreshPass(player, pass)
	end
end

local function onPlayerAdded(player: Player)
	task.spawn(function()
		-- PlayerDataService sets its data up on the same signal, ahead of us.
		refreshAllPasses(player)
	end)
end

local function onPlayerRemoving(player: Player)
	lastPromptAt[player] = nil
end

--[[
	A prompt finished. On a purchase we set the flag straight from the signal
	rather than re-asking, because UserOwnsGamePassAsync caches per server and
	would still be answering "no" for a few minutes.
]]
local function onGamePassPurchaseFinished(player: Player, gamePassId: number, wasPurchased: boolean)
	if not wasPurchased then
		return
	end

	local pass = Monetization.getPassById(gamePassId)
	if not pass then
		return
	end

	PlayerDataService.setPassOwned(player, pass.Flag, true)
	PlayerDataService.notify(player, string.format("%s unlocked!", pass.Name))
end

--[[
	The client asking for a purchase dialog. All this can do is open one: the
	grant happens in ProcessReceipt or on the pass signal above.
]]
local function onPromptRequested(player: Player, key: any)
	if typeof(key) ~= "string" then
		return
	end

	local now = os.clock()
	if now - (lastPromptAt[player] or 0) < PROMPT_COOLDOWN then
		return
	end
	lastPromptAt[player] = now

	local product = Monetization.getProduct(key)
	local pass = if product then nil else Monetization.getPass(key)
	local item: any = product or pass
	if not item then
		return
	end

	if not Monetization.isConfigured(Monetization.assetIdOf(item)) then
		PlayerDataService.notify(player, string.format("%s is not on sale yet.", item.Name), true)
		return
	end

	local ok, err = pcall(function()
		if product then
			MarketplaceService:PromptProductPurchase(player, product.ProductId)
		else
			MarketplaceService:PromptGamePassPurchase(player, (pass :: any).GamePassId)
		end
	end)

	if not ok then
		warn(string.format("MonetizationService: could not prompt %s for %s: %s", player.Name, key, tostring(err)))
		PlayerDataService.notify(player, "Could not open the purchase window. Try again in a moment.", true)
	end
end

function MonetizationService.start()
	-- Heads up: player data is session-only (no DataStore), so purchased Cash is
	-- lost on rejoin and handledPurchases resets with the server. Passes are
	-- unaffected -- Roblox owns that record. Persisting cash and the granted
	-- PurchaseIds needs a DataStore before this goes live.
	local remotesFolder = ReplicatedStorage:WaitForChild("GameRemotes")

	local promptRemote = Instance.new("RemoteEvent")
	promptRemote.Name = "RequestPurchasePrompt"
	promptRemote.Parent = remotesFolder
	promptRemote.OnServerEvent:Connect(onPromptRequested)

	MarketplaceService.ProcessReceipt = processReceipt
	MarketplaceService.PromptGamePassPurchaseFinished:Connect(onGamePassPurchaseFinished)

	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)

	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end
end

return MonetizationService
