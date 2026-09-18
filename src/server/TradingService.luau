--[[
	TradingService -- players swapping cars, and the only place a car changes
	hands between two people.

	A trade is a short conversation the server runs from end to end. One player
	invites another; the invite sits on that player's screen for
	Trading.InviteSeconds and then lapses. Accepting opens a session: each side
	puts cars up, and once both have confirmed, the cars move.

	Nothing a client sends is trusted with more than naming a car. Every offer is
	checked against that player's own data when it is made, and again -- whole --
	the instant before anything moves: PlayerDataService.swapCars performs the
	entire trade or none of it. The classic swap-at-the-last-moment trick is
	answered by resetting both confirmations whenever either offer changes, so
	nobody can confirm one trade and settle another.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local SharedFolder = ReplicatedStorage:WaitForChild("Shared")
local CarCatalog = require(SharedFolder:WaitForChild("Car"):WaitForChild("CarCatalog"))
local Trading = require(SharedFolder:WaitForChild("Trading"))
local PlayerDataService = require(script.Parent.PlayerDataService)

local TradingService = {}

type Side = {
	player: Player,
	offer: { string },
	confirmed: boolean,
}

type Session = {
	id: string,
	a: Side,
	b: Side,
}

type Invite = {
	from: Player,
	expiresAt: number,
}

-- Both players of a session are keyed to it, so either one can be found from
-- whichever of them sends the next message.
local sessions: { [Player]: Session } = {}
-- Keyed by the player being invited: one pending invite each, so an invite
-- cannot be buried under the next one.
local invites: { [Player]: Invite } = {}
local lastRequestAt: { [Player]: number } = {}
local nextTradeId = 0

local inviteRemote: RemoteEvent
local stateRemote: RemoteEvent
local requestRemote: RemoteFunction
local respondRemote: RemoteFunction
local actionRemote: RemoteFunction

local function carName(carId: string): string
	local car = CarCatalog.get(carId)
	return if car then car.DisplayName else carId
end

local function offerNames(offer: { string }): string
	if #offer == 0 then
		return "nothing"
	end
	local names = {}
	for _, carId in offer do
		table.insert(names, carName(carId))
	end
	return table.concat(names, ", ")
end

-- That player's own side first, then the other one.
local function sidesFor(session: Session, player: Player): (Side, Side)
	if session.a.player == player then
		return session.a, session.b
	end
	return session.b, session.a
end

local function snapshotSide(side: Side): Trading.Side
	local offer: { Trading.OfferedCar } = {}
	for _, carId in side.offer do
		local origin = PlayerDataService.originOf(side.player, carId)
		table.insert(offer, {
			CarId = carId,
			OriginalUserId = if origin then origin.OriginalUserId else side.player.UserId,
			OriginalUserName = if origin then origin.OriginalUserName else side.player.Name,
			Trades = if origin then origin.Trades else 0,
		})
	end
	return {
		UserId = side.player.UserId,
		Name = side.player.Name,
		DisplayName = side.player.DisplayName,
		Offer = offer,
		Confirmed = side.confirmed,
	}
end

-- Each client is sent the trade from its own point of view, so the UI never has
-- to work out which half of it belongs to whom.
local function pushState(session: Session)
	local a, b = snapshotSide(session.a), snapshotSide(session.b)
	if session.a.player.Parent then
		stateRemote:FireClient(session.a.player, { TradeId = session.id, You = a, Them = b })
	end
	if session.b.player.Parent then
		stateRemote:FireClient(session.b.player, { TradeId = session.id, You = b, Them = a })
	end
end

-- Ends the session for both players. `reason` is why it ended without a trade; a
-- completed trade passes nil, because settle reports itself.
local function closeSession(session: Session, reason: string?)
	sessions[session.a.player] = nil
	sessions[session.b.player] = nil
	for _, side in { session.a, session.b } do
		if side.player.Parent then
			stateRemote:FireClient(side.player, nil)
			if reason then
				PlayerDataService.notify(side.player, reason, true)
			end
		end
	end
end

-- Any change to either offer puts both players back to unconfirmed, so what
-- someone confirms is always the offer they were looking at.
local function reopen(session: Session)
	session.a.confirmed = false
	session.b.confirmed = false
end

local function withdrawInvite(target: Player)
	invites[target] = nil
	if target.Parent then
		inviteRemote:FireClient(target, nil)
	end
end

-- Both players have confirmed, so the cars move -- all of them or none of them.
local function settle(session: Session)
	local a, b = session.a, session.b
	local gaveA, gaveB = offerNames(a.offer), offerNames(b.offer)

	local ok, message = PlayerDataService.swapCars(a.player, a.offer, b.player, b.offer)
	if not ok then
		-- Something changed underneath the trade. Both sides look again.
		reopen(session)
		pushState(session)
		for _, side in { a, b } do
			PlayerDataService.notify(side.player, "Trade failed -- " .. message, true)
		end
		return
	end

	closeSession(session, nil)
	if a.player.Parent then
		PlayerDataService.notify(a.player, string.format("Trade complete! You gave %s and received %s.", gaveA, gaveB))
	end
	if b.player.Parent then
		PlayerDataService.notify(b.player, string.format("Trade complete! You gave %s and received %s.", gaveB, gaveA))
	end
end

local function onRequest(player: Player, targetUserId: any): (boolean, string)
	if typeof(targetUserId) ~= "number" then
		return false, "Invalid player"
	end

	local target = Players:GetPlayerByUserId(targetUserId)
	if not target or not target.Parent then
		return false, "That player has left the game"
	end
	if target == player then
		return false, "You cannot trade with yourself"
	end
	if sessions[player] then
		return false, "You are already in a trade"
	end
	if sessions[target] then
		return false, string.format("%s is already trading with someone", target.DisplayName)
	end

	local now = Workspace:GetServerTimeNow()
	local last = lastRequestAt[player]
	if last and now - last < Trading.RequestCooldown then
		return false, "Slow down -- wait a moment before inviting again"
	end

	if invites[target] then
		return false, string.format("%s already has a trade request open", target.DisplayName)
	end
	for invited, invite in invites do
		if invite.from == player then
			return false, string.format("You are still waiting on %s to answer", invited.DisplayName)
		end
	end

	lastRequestAt[player] = now
	local invite: Invite = { from = player, expiresAt = now + Trading.InviteSeconds }
	invites[target] = invite

	inviteRemote:FireClient(target, {
		FromUserId = player.UserId,
		FromName = player.Name,
		FromDisplayName = player.DisplayName,
		ExpiresAt = invite.expiresAt,
		Seconds = Trading.InviteSeconds,
	})

	task.delay(Trading.InviteSeconds, function()
		if invites[target] ~= invite then
			return -- already answered, so this one is no longer on the table
		end
		withdrawInvite(target)
		if player.Parent then
			PlayerDataService.notify(
				player,
				string.format("%s did not answer your trade request", target.DisplayName),
				true
			)
		end
	end)

	return true, string.format("Trade request sent to %s", target.DisplayName)
end

local function onRespond(player: Player, accept: any): (boolean, string)
	local invite = invites[player]
	if not invite then
		return false, "That trade request has expired"
	end

	local from = invite.from
	invites[player] = nil

	if accept ~= true then
		if from.Parent then
			PlayerDataService.notify(from, string.format("%s declined your trade request", player.DisplayName), true)
		end
		return true, "Trade request declined"
	end

	if not from.Parent then
		return false, "That player has left the game"
	end
	if sessions[player] or sessions[from] then
		return false, "One of you is already in a trade"
	end

	nextTradeId += 1
	local session: Session = {
		id = string.format("T%d", nextTradeId),
		a = { player = from, offer = {}, confirmed = false },
		b = { player = player, offer = {}, confirmed = false },
	}
	sessions[from] = session
	sessions[player] = session
	pushState(session)

	PlayerDataService.notify(from, string.format("%s accepted your trade request!", player.DisplayName))
	return true, string.format("Trading with %s", from.DisplayName)
end

local function onAction(player: Player, action: any, carId: any): (boolean, string)
	local session = sessions[player]
	if not session then
		return false, "You are not in a trade"
	end
	local mine, theirs = sidesFor(session, player)

	if action == "offer" then
		local problem = PlayerDataService.offerProblem(player, theirs.player, carId)
		if problem then
			return false, problem
		end
		if #mine.offer >= Trading.MaxOffer then
			return false, string.format("You can only offer %d vehicles at a time", Trading.MaxOffer)
		end
		if table.find(mine.offer, carId) then
			return false, "That vehicle is already on the table"
		end
		table.insert(mine.offer, carId)
		reopen(session)
		pushState(session)
		return true, carName(carId) .. " added to your offer"
	elseif action == "withdraw" then
		local at = if typeof(carId) == "string" then table.find(mine.offer, carId) else nil
		if not at then
			return false, "That vehicle is not in your offer"
		end
		table.remove(mine.offer, at)
		reopen(session)
		pushState(session)
		return true, carName(carId) .. " taken back"
	elseif action == "confirm" then
		if #mine.offer == 0 and #theirs.offer == 0 then
			return false, "Put a vehicle on the table first"
		end
		if mine.confirmed then
			return true, "Already confirmed"
		end
		mine.confirmed = true
		if theirs.confirmed then
			settle(session)
			return true, "Trade settled"
		end
		pushState(session)
		return true, string.format("Confirmed -- waiting on %s", theirs.player.DisplayName)
	elseif action == "unconfirm" then
		mine.confirmed = false
		pushState(session)
		return true, "Confirmation withdrawn"
	elseif action == "cancel" then
		closeSession(session, string.format("%s called off the trade", player.DisplayName))
		return true, "Trade cancelled"
	end

	return false, "Unknown trade action"
end

local function onPlayerRemoving(player: Player)
	lastRequestAt[player] = nil

	local session = sessions[player]
	if session then
		closeSession(session, string.format("%s left -- the trade was called off", player.DisplayName))
	end

	invites[player] = nil
	for target, invite in invites do
		if invite.from == player then
			withdrawInvite(target)
		end
	end
end

local function bindCharacterTradePrompt(targetPlayer: Player, character: Model)
	local hrp = character:WaitForChild("HumanoidRootPart", 5)
	if not (hrp and hrp:IsA("BasePart")) then
		return
	end

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "TradePrompt"
	prompt.ActionText = "Trade"
	prompt.ObjectText = targetPlayer.DisplayName
	prompt.KeyboardKeyCode = Enum.KeyCode.T
	prompt.GamepadKeyCode = Enum.KeyCode.ButtonY
	prompt.HoldDuration = 0.4
	prompt.MaxActivationDistance = 14
	prompt.RequiresLineOfSight = false
	prompt.Parent = hrp

	prompt.Triggered:Connect(function(requester: Player)
		if requester == targetPlayer then
			return
		end
		local ok, message = onRequest(requester, targetPlayer.UserId)
		PlayerDataService.notify(requester, message, not ok)
	end)
end

local function onPlayerAdded(player: Player)
	if player.Character then
		task.spawn(bindCharacterTradePrompt, player, player.Character)
	end
	player.CharacterAdded:Connect(function(char)
		bindCharacterTradePrompt(player, char)
	end)
end

function TradingService.start()
	local remotesFolder = ReplicatedStorage:WaitForChild("GameRemotes")

	inviteRemote = Instance.new("RemoteEvent")
	inviteRemote.Name = "TradeInvite"
	inviteRemote.Parent = remotesFolder

	stateRemote = Instance.new("RemoteEvent")
	stateRemote.Name = "TradeState"
	stateRemote.Parent = remotesFolder

	requestRemote = Instance.new("RemoteFunction")
	requestRemote.Name = "TradeRequest"
	requestRemote.OnServerInvoke = onRequest
	requestRemote.Parent = remotesFolder

	respondRemote = Instance.new("RemoteFunction")
	respondRemote.Name = "TradeRespond"
	respondRemote.OnServerInvoke = onRespond
	respondRemote.Parent = remotesFolder

	actionRemote = Instance.new("RemoteFunction")
	actionRemote.Name = "TradeAction"
	actionRemote.OnServerInvoke = onAction
	actionRemote.Parent = remotesFolder

	Players.PlayerAdded:Connect(onPlayerAdded)
	for _, player in Players:GetPlayers() do
		task.spawn(onPlayerAdded, player)
	end

	Players.PlayerRemoving:Connect(onPlayerRemoving)
end

return TradingService
