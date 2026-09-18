--[[
	Monetization -- the one table of Robux items in the game.

	Nothing here grants anything. The server looks a purchase up in these tables
	only after MarketplaceService tells it a real purchase happened, and the
	client reads the display fields to draw the shop cards.

	!! ASSET IDS ARE PLACEHOLDERS !!
	Every ProductId / GamePassId below is 0, which means "not configured yet".
	Create the developer products and game passes for this experience on the
	Creator Dashboard (Monetization -> Developer Products / Passes) and paste the
	real ids in below. Until an id is filled in, its shop card reads UNAVAILABLE,
	the server refuses to prompt for it, and nothing can be bought or granted --
	so the placeholders are safe to ship, just not sellable.

	Robux is the price shown before the real one is fetched from the listing;
	the Roblox listing is what actually charges, so this is display only.
]]

local Monetization = {}

-- An id of 0 means the item has not been created on the Creator Dashboard yet.
local UNCONFIGURED = 0

-- Developer products: one-off buys, granted in MarketplaceService.ProcessReceipt.
export type Product = {
	Key: string,
	ProductId: number,
	Cash: number,
	Name: string,
	Robux: number,
	Icon: string,
	Desc: string,
}

-- Game passes: permanent, owned Roblox-side. Flag is the PlayerData field the
-- rest of the game reads; the server mirrors ownership onto it.
export type Pass = {
	Key: string,
	GamePassId: number,
	Flag: string,
	Name: string,
	Robux: number,
	Icon: string,
	Desc: string,
}

local products: { Product } = {
	{
		Key = "cash_small",
		ProductId = UNCONFIGURED, -- TODO: real developer product id
		Cash = 50000,
		Name = "Small Cash Stash",
		Robux = 49,
		Icon = "💵",
		Desc = "Quick boost to start your collection",
	},
	{
		Key = "cash_medium",
		ProductId = UNCONFIGURED, -- TODO: real developer product id
		Cash = 200000,
		Name = "High Roller Bag",
		Robux = 149,
		Icon = "💼",
		Desc = "Instantly afford top sport supercars",
	},
	{
		Key = "cash_large",
		ProductId = UNCONFIGURED, -- TODO: real developer product id
		Cash = 1000000,
		Name = "Billionaire Vault",
		Robux = 499,
		Icon = "🏦",
		Desc = "Unlimited luxury and full garage freedom",
	},
}

local passes: { Pass } = {
	{
		Key = "pass_2xcash",
		GamePassId = UNCONFIGURED, -- TODO: real game pass id
		Flag = "Has2xCash",
		Name = "2x Cash Multiplier",
		Robux = 249,
		Icon = "⚡",
		Desc = "Permanently double all playtime and driving income",
	},
	{
		Key = "pass_vip",
		GamePassId = UNCONFIGURED, -- TODO: real game pass id
		Flag = "IsVIP",
		Name = "VIP Elite Pass",
		Robux = 399,
		Icon = "👑",
		Desc = "Golden drift smoke, VIP title, and garage perks",
	},
	{
		Key = "pass_nitro",
		GamePassId = UNCONFIGURED, -- TODO: real game pass id
		Flag = "HasNitro",
		Name = "Nitro Turbo Boost",
		Robux = 199,
		Icon = "🚀",
		Desc = "Adds instant rocket nitrous boost to every car",
	},
}

Monetization.Products = products
Monetization.Passes = passes

--[[
	Whether `id` is a real asset id rather than a leftover placeholder.
]]
function Monetization.isConfigured(id: any): boolean
	return typeof(id) == "number" and id > UNCONFIGURED
end

--[[
	The asset id a shop entry prompts for, whichever kind it is.
]]
function Monetization.assetIdOf(item: any): number
	if typeof(item) ~= "table" then
		return UNCONFIGURED
	end
	return item.ProductId or item.GamePassId or UNCONFIGURED
end

function Monetization.getProduct(key: any): Product?
	for _, product in products do
		if product.Key == key then
			return product
		end
	end
	return nil
end

function Monetization.getProductById(productId: any): Product?
	for _, product in products do
		if Monetization.isConfigured(product.ProductId) and product.ProductId == productId then
			return product
		end
	end
	return nil
end

function Monetization.getPass(key: any): Pass?
	for _, pass in passes do
		if pass.Key == key then
			return pass
		end
	end
	return nil
end

function Monetization.getPassById(gamePassId: any): Pass?
	for _, pass in passes do
		if Monetization.isConfigured(pass.GamePassId) and pass.GamePassId == gamePassId then
			return pass
		end
	end
	return nil
end

return Monetization
