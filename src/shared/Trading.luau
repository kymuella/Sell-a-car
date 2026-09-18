--[[
	Trading -- the rules both sides of a car trade agree on.

	Nothing here moves a car. TradingService owns every trade and re-checks each
	of these rules against its own copy of both players' data the moment before
	anything changes hands; the client reads them only so a button can grey out
	before the server has to say no.

	A traded car keeps the name of whoever first owned it: PlayerData.CarOrigins
	records that, the origin travels with the car, and the nameplate on a spawned
	car shows it (see CarService.stampOwnership).
]]

local Trading = {}

-- How many cars one player may put up in a single trade.
Trading.MaxOffer = 4

-- How long an invite stays on the other player's screen.
Trading.InviteSeconds = 30

-- Least time between one player's invites, so nobody can be spammed with them.
Trading.RequestCooldown = 3

-- A car on the table, with the origin that travels with it.
export type OfferedCar = {
	CarId: string,
	OriginalUserId: number,
	OriginalUserName: string,
	Trades: number,
}

export type Side = {
	UserId: number,
	Name: string,
	DisplayName: string,
	Offer: { OfferedCar },
	Confirmed: boolean,
}

-- What a client is told about the trade it is in. `You` is always that client's
-- own side, so the UI never has to work out which half is whose.
export type Session = {
	TradeId: string,
	You: Side,
	Them: Side,
}

--[[
	Whether `car` (a CarCatalog entry) may change hands at all. The starter car is
	free and every player is given one, so there is nothing to gain by trading it
	and nobody can be talked out of their last vehicle.
]]
function Trading.isTradeable(car: any): boolean
	return typeof(car) == "table" and typeof(car.Price) == "number" and car.Price > 0
end

--[[
	Why `car` cannot pass from one player to the other, or nil if it can. The two
	OwnedCars maps say what each side holds; both players are named in whatever
	comes back, because both of them are shown it.
]]
function Trading.offerProblem(
	car: any,
	ownerName: string,
	ownerCars: { [string]: boolean },
	receiverName: string,
	receiverCars: { [string]: boolean }
): string?
	if not car then
		return "That vehicle is not in the catalog"
	end
	if not Trading.isTradeable(car) then
		return car.DisplayName .. " is a starter vehicle and cannot be traded"
	end
	if not ownerCars[car.Id] then
		return string.format("%s no longer owns the %s", ownerName, car.DisplayName)
	end
	if receiverCars[car.Id] then
		return string.format("%s already owns a %s", receiverName, car.DisplayName)
	end
	return nil
end

return Trading
