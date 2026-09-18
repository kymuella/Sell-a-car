--[[
	GameUI -- Main Client UI Controller.
	Features:
	- Non-overlapping layout: Cash counter integrated into Left Navigation Dock (safe from Roblox topbar/chat/mic)
	- Robux-Only Shop: Developer Products (Cash Packs) & Gamepasses (2x Cash, VIP, Nitro).
	  The shop only asks for a Roblox purchase prompt -- what a player buys is
	  granted server-side, so nothing here can hand out cash or passes.
	- Garage with Dual Tabs: "MY CARS" (spawn/customize) & "DEALERSHIP" (buy cars with in-game Cash)
	- Cardex Compendium: Discovered cars vs blacked-out mystery silhouettes with direct Dealership links
	- Play Teleport: Cinematic fade transition to the driving area
	- Restoration Bay: delivered barn finds counting down through retrieval and recuperation
	- Trading: a full trade window -- who is in the server, both offers side by side,
	  and the two confirmations -- plus the on-screen prompt an incoming request
	  arrives on. TradingService owns every trade; this only shows it and asks.
	- Responsive design with smooth tweens and toast notifications
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local SharedFolder = ReplicatedStorage:WaitForChild("Shared")
local CarFolder = SharedFolder:WaitForChild("Car")
local CarCatalog = require(CarFolder.CarCatalog)
local Monetization = require(SharedFolder.Monetization)
local Trading = require(SharedFolder.Trading)

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local GameUI = {}

-- UI Color Palette & Design Tokens
local THEME = {
	BgModal = Color3.fromRGB(16, 19, 26),
	BgCard = Color3.fromRGB(24, 28, 38),
	BgCardHover = Color3.fromRGB(33, 38, 52),
	BgLocked = Color3.fromRGB(11, 13, 18),
	Stroke = Color3.fromRGB(255, 255, 255),
	StrokeTrans = 0.88,
	StrokeLocked = Color3.fromRGB(45, 48, 60),
	Accent = Color3.fromRGB(0, 160, 255),
	AccentHover = Color3.fromRGB(40, 185, 255),
	Gold = Color3.fromRGB(255, 204, 0),
	Green = Color3.fromRGB(46, 204, 113),
	Red = Color3.fromRGB(239, 68, 68),
	RobuxGreen = Color3.fromRGB(0, 180, 100),
	TextPrimary = Color3.fromRGB(245, 247, 250),
	TextSecondary = Color3.fromRGB(156, 163, 175),
	TextMuted = Color3.fromRGB(100, 107, 120),
}

local PAINT_PRESETS = {
	{ Name = "Miami Blue", Color = Color3.fromRGB(0, 122, 204) },
	{ Name = "Guards Red", Color = Color3.fromRGB(220, 38, 38) },
	{ Name = "Racing Yellow", Color = Color3.fromRGB(245, 185, 20) },
	{ Name = "Jet Black", Color = Color3.fromRGB(24, 24, 27) },
	{ Name = "Chalk White", Color = Color3.fromRGB(240, 242, 245) },
	{ Name = "Emerald Green", Color = Color3.fromRGB(22, 163, 74) },
	{ Name = "Cyber Violet", Color = Color3.fromRGB(147, 51, 234) },
	{ Name = "Sunset Orange", Color = Color3.fromRGB(234, 88, 12) },
}

-- Client State
local localData = {
	Cash = 0,
	OwnedCars = { ["Porsche"] = true },
	CardexDiscovered = { ["Porsche"] = true },
	SelectedCar = "Porsche",
	Paints = {},
	Has2xCash = false,
	IsVIP = false,
	HasNitro = false,
	Restorations = {},
	CarOrigins = {},
}

local selectedGarageCarId = "Porsche"
local selectedGaragePaint: Color3? = nil
local garageCurrentTab = "GARAGE" -- "GARAGE" or "DEALERSHIP"
local robuxShopCurrentTab = "CASH" -- "CASH" or "PASSES"
local cardexFilter = "ALL"

-- The trade we are in, as the server last described it, and the request waiting
-- to be answered. Both are nil most of the time.
local tradeSession: Trading.Session? = nil
local tradeInvite: any = nil

-- Remotes
local remotesFolder: Folder? = nil
local syncRemote: RemoteEvent? = nil
local buyRemote: RemoteFunction? = nil
local promptPurchaseRemote: RemoteEvent? = nil
local spawnRemote: RemoteFunction? = nil
local despawnRemote: RemoteFunction? = nil
local teleportRemote: RemoteFunction? = nil
local getDataRemote: RemoteFunction? = nil
local notifyRemote: RemoteEvent? = nil
local tradeRequestRemote: RemoteFunction? = nil
local tradeRespondRemote: RemoteFunction? = nil
local tradeActionRemote: RemoteFunction? = nil
local tradeInviteRemote: RemoteEvent? = nil
local tradeStateRemote: RemoteEvent? = nil

-- GUI References
local screenGui: ScreenGui
local dockCashLabel: TextLabel
local dockMultBadge: Frame
local dockCardexBadge: TextLabel
local modalContainer: Frame
local cardexModal: Frame
local shopModal: Frame
local garageModal: Frame
local currentModal: Frame? = nil
local fadeOverlay: Frame
local toastLabel: TextLabel
local toastFrame: Frame
local cardexCardContainer: ScrollingFrame
local cardexCountText: TextLabel
local cardexProgressBar: Frame
local shopContentContainer: ScrollingFrame
local garageBodyFrame: Frame
local tradeModal: Frame
local tradeBodyFrame: Frame
local tradeInviteFrame: Frame
local tradeInviteAvatar: ImageLabel
local tradeInviteName: TextLabel
local tradeInviteId: TextLabel
local tradeInviteTimer: TextLabel
local tradeInviteFill: Frame

-- Helper for creating GUI elements
local function make(className: string, props: { [string]: any }): any
	local inst = Instance.new(className)
	for k, v in props do
		if k ~= "Parent" then
			(inst :: any)[k] = v
		end
	end
	inst.Parent = props.Parent
	return inst
end

local function addCorner(parent: Instance, radius: number)
	return make("UICorner", { CornerRadius = UDim.new(0, radius), Parent = parent })
end

local function addStroke(parent: Instance, color: Color3, trans: number, thick: number?)
	return make("UIStroke", {
		Color = color,
		Transparency = trans,
		Thickness = thick or 1,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		Parent = parent,
	})
end

-- Animated Toast Notifications
local toastThread: thread? = nil
local function showToast(message: string, isError: boolean?)
	if toastThread then
		task.cancel(toastThread)
		toastThread = nil
	end

	toastLabel.Text = message
	toastLabel.TextColor3 = if isError then THEME.Red else THEME.TextPrimary
	toastFrame.BackgroundColor3 = if isError then Color3.fromRGB(45, 20, 20) else Color3.fromRGB(20, 25, 35)

	toastFrame.Visible = true
	toastFrame.Position = UDim2.new(0.5, 0, 0, -60)
	TweenService:Create(toastFrame, TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
		Position = UDim2.new(0.5, 0, 0, 24),
	}):Play()

	toastThread = task.delay(3.5, function()
		local tw = TweenService:Create(toastFrame, TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
			Position = UDim2.new(0.5, 0, 0, -60),
		})
		tw:Play()
		tw.Completed:Connect(function()
			toastFrame.Visible = false
		end)
	end)
end

-- Number formatting helper ($25,000)
local function formatCash(amount: number): string
	local formatted = tostring(amount)
	while true do
		local k
		formatted, k = string.gsub(formatted, "^(-?%d+)(%d%d%d)", "%1,%2")
		if k == 0 then
			break
		end
	end
	return "$" .. formatted
end

--[[
	One line saying who first owned a car, and how many times it has changed
	hands, from a PlayerData.CarOrigins record or a trade offer entry.
]]
local function originLine(origin: any): (string, Color3)
	if typeof(origin) ~= "table" or typeof(origin.OriginalUserId) ~= "number" then
		return "Original owner not recorded", THEME.TextMuted
	end

	local trades = if typeof(origin.Trades) == "number" then origin.Trades else 0
	local who = if typeof(origin.OriginalUserName) == "string" then origin.OriginalUserName else "someone"
	if origin.OriginalUserId == player.UserId then
		who = "you"
	end

	if trades == 0 then
		return string.format("⭐ Original owner: %s (ID %d)", who, origin.OriginalUserId), THEME.Gold
	end
	return string.format(
		"↔ Originally %s (ID %d) • %d trade%s",
		who,
		origin.OriginalUserId,
		trades,
		if trades == 1 then "" else "s"
	),
		THEME.Accent
end

local function updateHUD()
	if dockCashLabel then
		dockCashLabel.Text = formatCash(localData.Cash)
	end

	if dockMultBadge then
		dockMultBadge.Visible = localData.Has2xCash == true
	end

	if dockCardexBadge then
		local allCars = CarCatalog.getAll()
		local discovered = 0
		for _, car in allCars do
			if localData.CardexDiscovered[car.Id] then
				discovered += 1
			end
		end
		dockCardexBadge.Text = string.format("%d/%d", discovered, #allCars)
	end
end

-- Modal Management (Cardex, Shop, Garage)
local function closeModal()
	if not currentModal then
		return
	end
	local m = currentModal
	currentModal = nil

	local tw = TweenService:Create(m, TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
		Position = UDim2.new(0.5, 0, 0.53, 0),
		BackgroundTransparency = 1,
	})
	tw:Play()
	tw.Completed:Connect(function()
		m.Visible = false
	end)
end

local renderCardexContent: () -> ()
local renderRobuxShopContent: () -> ()
local renderGarageContent: () -> ()
local renderTradeContent: () -> ()

local function openModal(targetModal: Frame)
	if currentModal == targetModal then
		closeModal()
		return
	end

	if currentModal then
		currentModal.Visible = false
	end

	currentModal = targetModal
	targetModal.Visible = true
	targetModal.Position = UDim2.new(0.5, 0, 0.53, 0)
	targetModal.BackgroundTransparency = 0.5

	TweenService:Create(targetModal, TweenInfo.new(0.28, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
		Position = UDim2.new(0.5, 0, 0.5, 0),
		BackgroundTransparency = 0.05,
	}):Play()

	if targetModal == cardexModal then
		renderCardexContent()
	elseif targetModal == shopModal then
		renderRobuxShopContent()
	elseif targetModal == garageModal then
		renderGarageContent()
	elseif targetModal == tradeModal then
		renderTradeContent()
	end
end

-- Teleport to Playing Area with screen fade
local isTeleporting = false
local function doPlayTeleport()
	if isTeleporting then
		return
	end
	isTeleporting = true
	closeModal()

	fadeOverlay.Visible = true
	fadeOverlay.BackgroundTransparency = 1
	local fadeOut = TweenService:Create(fadeOverlay, TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		BackgroundTransparency = 0,
	})
	fadeOut:Play()
	fadeOut.Completed:Wait()

	if teleportRemote then
		local ok, msg = teleportRemote:InvokeServer()
		if ok then
			showToast("Teleported to Playing Area! 🏁", false)
		else
			showToast(msg or "Could not teleport", true)
		end
	end

	task.wait(0.3)

	local fadeIn = TweenService:Create(fadeOverlay, TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
		BackgroundTransparency = 1,
	})
	fadeIn:Play()
	fadeIn.Completed:Wait()
	fadeOverlay.Visible = false
	isTeleporting = false
end

-- Cardex Content Renderer
function renderCardexContent()
	if not cardexCardContainer then
		return
	end
	cardexCardContainer:ClearAllChildren()

	local allCars = CarCatalog.getAll()
	local discoveredCount = 0
	for _, car in allCars do
		if localData.CardexDiscovered[car.Id] then
			discoveredCount += 1
		end
	end

	if cardexCountText then
		local pct = math.round((discoveredCount / #allCars) * 100)
		cardexCountText.Text = string.format("COLLECTION: %d / %d UNLOCKED (%d%%)", discoveredCount, #allCars, pct)
	end

	if cardexProgressBar then
		local frac = math.clamp(discoveredCount / #allCars, 0, 1)
		TweenService:Create(cardexProgressBar, TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Size = UDim2.new(frac, 0, 1, 0),
		}):Play()
	end

	make("UIGridLayout", {
		CellSize = UDim2.new(0, 240, 0, 260),
		CellPadding = UDim2.new(0, 14, 0, 14),
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = cardexCardContainer,
	})

	for i, car in allCars do
		local isUnlocked = localData.CardexDiscovered[car.Id] == true

		if cardexFilter == "OBTAINED" and not isUnlocked then
			continue
		elseif cardexFilter == "LOCKED" and isUnlocked then
			continue
		end

		local card = make("Frame", {
			Name = car.Id,
			BackgroundColor3 = if isUnlocked then THEME.BgCard else THEME.BgLocked,
			BorderSizePixel = 0,
			LayoutOrder = i,
			Parent = cardexCardContainer,
		})
		addCorner(card, 10)
		addStroke(card, if isUnlocked then THEME.Stroke else THEME.StrokeLocked, if isUnlocked then THEME.StrokeTrans else 0.4)

		if isUnlocked then
			-- UNLOCKED CARD
			local topBar = make("Frame", {
				Size = UDim2.new(1, 0, 0, 5),
				BackgroundColor3 = car.AccentColor,
				BorderSizePixel = 0,
				Parent = card,
			})
			addCorner(topBar, 5)

			local tierBadge = make("TextLabel", {
				Position = UDim2.new(0, 12, 0, 12),
				Size = UDim2.new(0, 70, 0, 20),
				BackgroundColor3 = Color3.fromRGB(35, 42, 58),
				FontFace = Font.fromEnum(Enum.Font.GothamBold),
				Text = string.upper(car.Tier),
				TextColor3 = car.AccentColor,
				TextSize = 11,
				Parent = card,
			})
			addCorner(tierBadge, 4)

			local statusBadge = make("TextLabel", {
				Position = UDim2.new(1, -95, 0, 12),
				Size = UDim2.new(0, 83, 0, 20),
				BackgroundColor3 = Color3.fromRGB(20, 48, 32),
				FontFace = Font.fromEnum(Enum.Font.GothamBold),
				Text = "✓ OBTAINED",
				TextColor3 = THEME.Green,
				TextSize = 11,
				Parent = card,
			})
			addCorner(statusBadge, 4)

			make("TextLabel", {
				Position = UDim2.new(0, 12, 0, 38),
				Size = UDim2.new(1, -24, 0, 24),
				BackgroundTransparency = 1,
				FontFace = Font.fromEnum(Enum.Font.GothamBold),
				Text = car.DisplayName,
				TextColor3 = THEME.TextPrimary,
				TextSize = 15,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextTruncate = Enum.TextTruncate.AtEnd,
				Parent = card,
			})

			make("TextLabel", {
				Position = UDim2.new(0, 12, 0, 62),
				Size = UDim2.new(1, -24, 0, 16),
				BackgroundTransparency = 1,
				FontFace = Font.fromEnum(Enum.Font.GothamMedium),
				Text = car.Subtitle,
				TextColor3 = THEME.TextSecondary,
				TextSize = 11,
				TextXAlignment = Enum.TextXAlignment.Left,
				Parent = card,
			})

			local statsBox = make("Frame", {
				Position = UDim2.new(0, 12, 0, 86),
				Size = UDim2.new(1, -24, 0, 105),
				BackgroundTransparency = 1,
				Parent = card,
			})

			local function addStatRow(yPos: number, name: string, valueStr: string, frac: number)
				make("TextLabel", {
					Position = UDim2.new(0, 0, 0, yPos),
					Size = UDim2.new(0.5, 0, 0, 16),
					BackgroundTransparency = 1,
					FontFace = Font.fromEnum(Enum.Font.GothamBold),
					Text = name,
					TextColor3 = THEME.TextSecondary,
					TextSize = 11,
					TextXAlignment = Enum.TextXAlignment.Left,
					Parent = statsBox,
				})
				make("TextLabel", {
					Position = UDim2.new(0.5, 0, 0, yPos),
					Size = UDim2.new(0.5, 0, 0, 16),
					BackgroundTransparency = 1,
					FontFace = Font.fromEnum(Enum.Font.GothamBold),
					Text = valueStr,
					TextColor3 = THEME.TextPrimary,
					TextSize = 11,
					TextXAlignment = Enum.TextXAlignment.Right,
					Parent = statsBox,
				})
				local track = make("Frame", {
					Position = UDim2.new(0, 0, 0, yPos + 18),
					Size = UDim2.new(1, 0, 0, 5),
					BackgroundColor3 = Color3.fromRGB(38, 44, 58),
					BorderSizePixel = 0,
					Parent = statsBox,
				})
				addCorner(track, 3)
				local fill = make("Frame", {
					Size = UDim2.new(math.clamp(frac, 0, 1), 0, 1, 0),
					BackgroundColor3 = car.AccentColor,
					BorderSizePixel = 0,
					Parent = track,
				})
				addCorner(fill, 3)
			end

			addStatRow(0, "Top Speed", string.format("%d MPH", math.round(car.TopSpeed * 2)), (car.TopSpeed * 2) / 200)
			addStatRow(28, "Acceleration", tostring(car.Acceleration), car.Acceleration / 70)
			addStatRow(56, "Cornering Grip", tostring(car.Grip), car.Grip / 15)

			make("TextLabel", {
				Position = UDim2.new(0, 12, 1, -32),
				Size = UDim2.new(1, -24, 0, 20),
				BackgroundTransparency = 1,
				FontFace = Font.fromEnum(Enum.Font.GothamMedium),
				Text = string.format("Powertrain: %s • Discovered", car.DriveType),
				TextColor3 = THEME.TextMuted,
				TextSize = 10,
				TextXAlignment = Enum.TextXAlignment.Center,
				Parent = card,
			})
		else
			-- LOCKED BLACKED-OUT SILHOUETTE
			local silhouetteBox = make("Frame", {
				Position = UDim2.new(0, 10, 0, 10),
				Size = UDim2.new(1, -20, 1, -20),
				BackgroundColor3 = Color3.fromRGB(7, 8, 11),
				BorderSizePixel = 0,
				Parent = card,
			})
			addCorner(silhouetteBox, 8)
			addStroke(silhouetteBox, Color3.fromRGB(30, 32, 42), 0.5)

			make("TextLabel", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.new(0.5, 0, 0.34, 0),
				Size = UDim2.new(0, 56, 0, 56),
				BackgroundTransparency = 1,
				FontFace = Font.fromEnum(Enum.Font.GothamBold),
				Text = "🔒",
				TextSize = 42,
				TextColor3 = THEME.TextMuted,
				Parent = silhouetteBox,
			})

			make("TextLabel", {
				Position = UDim2.new(0, 8, 0, 114),
				Size = UDim2.new(1, -16, 0, 22),
				BackgroundTransparency = 1,
				FontFace = Font.fromEnum(Enum.Font.GothamBlack),
				Text = "??? [LOCKED]",
				TextColor3 = Color3.fromRGB(110, 115, 128),
				TextSize = 14,
				TextXAlignment = Enum.TextXAlignment.Center,
				Parent = silhouetteBox,
			})

			make("TextLabel", {
				Position = UDim2.new(0, 8, 0, 138),
				Size = UDim2.new(1, -16, 0, 16),
				BackgroundTransparency = 1,
				FontFace = Font.fromEnum(Enum.Font.GothamMedium),
				Text = string.format("Unknown %s Class", car.Tier),
				TextColor3 = Color3.fromRGB(70, 75, 88),
				TextSize = 11,
				TextXAlignment = Enum.TextXAlignment.Center,
				Parent = silhouetteBox,
			})

			make("TextLabel", {
				Position = UDim2.new(0, 8, 0, 158),
				Size = UDim2.new(1, -16, 0, 16),
				BackgroundTransparency = 1,
				FontFace = Font.fromEnum(Enum.Font.GothamMedium),
				Text = "Speed: ??? • Grip: ???",
				TextColor3 = Color3.fromRGB(55, 60, 72),
				TextSize = 10,
				TextXAlignment = Enum.TextXAlignment.Center,
				Parent = silhouetteBox,
			})

			-- Shortcut to Dealership in Garage
			local dealBtn = make("TextButton", {
				Position = UDim2.new(0.1, 0, 1, -34),
				Size = UDim2.new(0.8, 0, 0, 26),
				BackgroundColor3 = Color3.fromRGB(24, 28, 38),
				FontFace = Font.fromEnum(Enum.Font.GothamBold),
				Text = "Buy in Dealership →",
				TextColor3 = THEME.Gold,
				TextSize = 11,
				BorderSizePixel = 0,
				Parent = silhouetteBox,
			})
			addCorner(dealBtn, 5)
			addStroke(dealBtn, THEME.Gold, 0.7)

			dealBtn.MouseButton1Click:Connect(function()
				garageCurrentTab = "DEALERSHIP"
				selectedGarageCarId = car.Id
				openModal(garageModal)
			end)
		end
	end
end

-- Robux prices are set on the Roblox listing, so the number in Monetization is
-- just what we show until the real one arrives.
local priceCache: { [number]: number } = {}

--[[
	Puts `item`'s price on its buy button, or marks the card unavailable while
	the item still has a placeholder id.
]]
local function showPrice(button: TextButton, item: any, infoType: Enum.InfoType)
	local assetId = Monetization.assetIdOf(item)

	if not Monetization.isConfigured(assetId) then
		button.Text = "UNAVAILABLE"
		button.BackgroundColor3 = THEME.BgCardHover
		button.TextColor3 = THEME.TextMuted
		return
	end

	button.Text = string.format("R$ %d", priceCache[assetId] or item.Robux)
	if priceCache[assetId] then
		return
	end

	task.spawn(function()
		local ok, info = pcall(function()
			return MarketplaceService:GetProductInfo(assetId, infoType)
		end)
		if ok and typeof(info) == "table" and typeof(info.PriceInRobux) == "number" then
			priceCache[assetId] = info.PriceInRobux
			if button.Parent then
				button.Text = string.format("R$ %d", info.PriceInRobux)
			end
		end
	end)
end

--[[
	Asks the server to open Roblox's purchase dialog. Whatever the player buys is
	granted from the MarketplaceService receipt on the server, never from here,
	so the shop just waits for the data sync to come back.
]]
local function requestPurchase(item: any)
	if not Monetization.isConfigured(Monetization.assetIdOf(item)) then
		showToast(string.format("%s is not on sale yet.", item.Name), true)
		return
	end

	if promptPurchaseRemote then
		promptPurchaseRemote:FireServer(item.Key)
	end
end

-- Robux-Only Shop Content Renderer
function renderRobuxShopContent()
	if not shopContentContainer then
		return
	end
	shopContentContainer:ClearAllChildren()

	make("UIGridLayout", {
		CellSize = UDim2.new(0, 240, 0, 240),
		CellPadding = UDim2.new(0, 14, 0, 14),
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = shopContentContainer,
	})

	if robuxShopCurrentTab == "CASH" then
		for i, item in Monetization.Products do
			local card = make("Frame", {
				Name = item.Key,
				BackgroundColor3 = THEME.BgCard,
				BorderSizePixel = 0,
				LayoutOrder = i,
				Parent = shopContentContainer,
			})
			addCorner(card, 10)
			addStroke(card, THEME.Stroke, THEME.StrokeTrans)

			local topBar = make("Frame", {
				Size = UDim2.new(1, 0, 0, 4),
				BackgroundColor3 = THEME.Gold,
				BorderSizePixel = 0,
				Parent = card,
			})
			addCorner(topBar, 4)

			make("TextLabel", {
				Position = UDim2.new(0, 12, 0, 12),
				Size = UDim2.new(0, 36, 0, 36),
				BackgroundTransparency = 1,
				FontFace = Font.fromEnum(Enum.Font.GothamBlack),
				Text = item.Icon,
				TextSize = 28,
				Parent = card,
			})

			make("TextLabel", {
				Position = UDim2.new(0, 56, 0, 12),
				Size = UDim2.new(1, -68, 0, 20),
				BackgroundTransparency = 1,
				FontFace = Font.fromEnum(Enum.Font.GothamBold),
				Text = item.Name,
				TextColor3 = THEME.TextPrimary,
				TextSize = 14,
				TextXAlignment = Enum.TextXAlignment.Left,
				Parent = card,
			})

			make("TextLabel", {
				Position = UDim2.new(0, 56, 0, 32),
				Size = UDim2.new(1, -68, 0, 16),
				BackgroundTransparency = 1,
				FontFace = Font.fromEnum(Enum.Font.GothamBlack),
				Text = "+" .. formatCash(item.Cash),
				TextColor3 = THEME.Gold,
				TextSize = 13,
				TextXAlignment = Enum.TextXAlignment.Left,
				Parent = card,
			})

			make("TextLabel", {
				Position = UDim2.new(0, 12, 0, 72),
				Size = UDim2.new(1, -24, 0, 50),
				BackgroundTransparency = 1,
				FontFace = Font.fromEnum(Enum.Font.GothamMedium),
				Text = item.Desc,
				TextColor3 = THEME.TextSecondary,
				TextSize = 11,
				TextWrapped = true,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextYAlignment = Enum.TextYAlignment.Top,
				Parent = card,
			})

			local buyBtn = make("TextButton", {
				Position = UDim2.new(0, 12, 1, -44),
				Size = UDim2.new(1, -24, 0, 32),
				BackgroundColor3 = THEME.RobuxGreen,
				FontFace = Font.fromEnum(Enum.Font.GothamBold),
				TextColor3 = Color3.fromRGB(255, 255, 255),
				TextSize = 13,
				BorderSizePixel = 0,
				Parent = card,
			})
			addCorner(buyBtn, 6)
			showPrice(buyBtn, item, Enum.InfoType.Product)

			buyBtn.MouseButton1Click:Connect(function()
				requestPurchase(item)
			end)
		end
	else
		for i, item in Monetization.Passes do
			-- Set server-side from UserOwnsGamePassAsync, never by this client.
			local isOwned = (localData :: any)[item.Flag] == true

			local card = make("Frame", {
				Name = item.Key,
				BackgroundColor3 = THEME.BgCard,
				BorderSizePixel = 0,
				LayoutOrder = i,
				Parent = shopContentContainer,
			})
			addCorner(card, 10)
			addStroke(card, THEME.Stroke, THEME.StrokeTrans)

			local topBar = make("Frame", {
				Size = UDim2.new(1, 0, 0, 4),
				BackgroundColor3 = THEME.Accent,
				BorderSizePixel = 0,
				Parent = card,
			})
			addCorner(topBar, 4)

			make("TextLabel", {
				Position = UDim2.new(0, 12, 0, 12),
				Size = UDim2.new(0, 36, 0, 36),
				BackgroundTransparency = 1,
				FontFace = Font.fromEnum(Enum.Font.GothamBlack),
				Text = item.Icon,
				TextSize = 28,
				Parent = card,
			})

			make("TextLabel", {
				Position = UDim2.new(0, 56, 0, 12),
				Size = UDim2.new(1, -68, 0, 20),
				BackgroundTransparency = 1,
				FontFace = Font.fromEnum(Enum.Font.GothamBold),
				Text = item.Name,
				TextColor3 = THEME.TextPrimary,
				TextSize = 13,
				TextXAlignment = Enum.TextXAlignment.Left,
				Parent = card,
			})

			make("TextLabel", {
				Position = UDim2.new(0, 56, 0, 32),
				Size = UDim2.new(1, -68, 0, 16),
				BackgroundTransparency = 1,
				FontFace = Font.fromEnum(Enum.Font.GothamBold),
				Text = if isOwned then "ACTIVE" else "GAMEPASS",
				TextColor3 = if isOwned then THEME.Green else THEME.Accent,
				TextSize = 11,
				TextXAlignment = Enum.TextXAlignment.Left,
				Parent = card,
			})

			make("TextLabel", {
				Position = UDim2.new(0, 12, 0, 72),
				Size = UDim2.new(1, -24, 0, 50),
				BackgroundTransparency = 1,
				FontFace = Font.fromEnum(Enum.Font.GothamMedium),
				Text = item.Desc,
				TextColor3 = THEME.TextSecondary,
				TextSize = 11,
				TextWrapped = true,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextYAlignment = Enum.TextYAlignment.Top,
				Parent = card,
			})

			local buyBtn = make("TextButton", {
				Position = UDim2.new(0, 12, 1, -44),
				Size = UDim2.new(1, -24, 0, 32),
				FontFace = Font.fromEnum(Enum.Font.GothamBold),
				TextSize = 13,
				BorderSizePixel = 0,
				Parent = card,
			})
			addCorner(buyBtn, 6)

			if isOwned then
				buyBtn.BackgroundColor3 = Color3.fromRGB(28, 48, 38)
				buyBtn.Text = "OWNED ✓"
				buyBtn.TextColor3 = THEME.Green
				buyBtn.AutoButtonColor = false
			else
				buyBtn.BackgroundColor3 = THEME.RobuxGreen
				buyBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
				showPrice(buyBtn, item, Enum.InfoType.GamePass)

				buyBtn.MouseButton1Click:Connect(function()
					requestPurchase(item)
				end)
			end
		end
	end
end

-- Restoration Bay: barn finds being restored, drawn at the top of the garage list
local restorationBars: { { job: any, fill: Frame, status: TextLabel } } = {}

-- Which phase a restoration job is in, how far through it (0-1), and seconds left in it.
local function restorationProgress(job): (string, number, number)
	local elapsed = Workspace:GetServerTimeNow() - job.StartedAt
	if elapsed < job.RetrievalSeconds then
		return "RETRIEVAL", elapsed / job.RetrievalSeconds, job.RetrievalSeconds - elapsed
	end
	local rebuild = elapsed - job.RetrievalSeconds
	return "RECUPERATION",
		math.clamp(rebuild / job.RecuperationSeconds, 0, 1),
		math.max(job.RecuperationSeconds - rebuild, 0)
end

local function updateRestorationBars()
	for _, bar in restorationBars do
		if bar.fill.Parent then
			local phase, progress, left = restorationProgress(bar.job)
			local seconds = math.ceil(left)
			bar.fill.Size = UDim2.fromScale(progress, 1)
			bar.fill.BackgroundColor3 = if phase == "RETRIEVAL" then THEME.Gold else THEME.Accent
			bar.status.Text = string.format("%s • %d:%02d left", phase, seconds // 60, seconds % 60)
		end
	end
end

local function renderRestorationBay(container: Instance): number
	table.clear(restorationBars)
	local jobs = localData.Restorations or {}
	if #jobs == 0 then
		return 0
	end

	make("TextLabel", {
		Size = UDim2.new(1, 0, 0, 20),
		BackgroundTransparency = 1,
		FontFace = Font.fromEnum(Enum.Font.GothamBold),
		Text = "🔧 RESTORATION BAY",
		TextColor3 = THEME.Gold,
		TextSize = 12,
		TextXAlignment = Enum.TextXAlignment.Left,
		LayoutOrder = -1000,
		Parent = container,
	})

	for i, job in jobs do
		local car = CarCatalog.get(job.CarId)
		local card = make("Frame", {
			Size = UDim2.new(1, 0, 0, 64),
			BackgroundColor3 = THEME.BgCard,
			BorderSizePixel = 0,
			LayoutOrder = -1000 + i,
			Parent = container,
		})
		addCorner(card, 8)
		addStroke(card, THEME.Gold, 0.6)

		make("TextLabel", {
			Position = UDim2.new(0, 12, 0, 8),
			Size = UDim2.new(1, -24, 0, 18),
			BackgroundTransparency = 1,
			FontFace = Font.fromEnum(Enum.Font.GothamBold),
			Text = if car then car.DisplayName else job.CarId,
			TextColor3 = THEME.TextPrimary,
			TextSize = 13,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Parent = card,
		})

		local status = make("TextLabel", {
			Position = UDim2.new(0, 12, 0, 26),
			Size = UDim2.new(1, -24, 0, 14),
			BackgroundTransparency = 1,
			FontFace = Font.fromEnum(Enum.Font.GothamMedium),
			Text = "",
			TextColor3 = THEME.TextSecondary,
			TextSize = 11,
			TextXAlignment = Enum.TextXAlignment.Left,
			Parent = card,
		})

		local track = make("Frame", {
			Position = UDim2.new(0, 12, 0, 46),
			Size = UDim2.new(1, -24, 0, 8),
			BackgroundColor3 = Color3.fromRGB(42, 46, 58),
			BorderSizePixel = 0,
			Parent = card,
		})
		addCorner(track, 4)
		local fill = make("Frame", {
			Size = UDim2.fromScale(0, 1),
			BackgroundColor3 = THEME.Gold,
			BorderSizePixel = 0,
			Parent = track,
		})
		addCorner(fill, 4)

		table.insert(restorationBars, { job = job, fill = fill, status = status })
	end

	updateRestorationBars()
	return #jobs
end

-- Garage & In-Game Dealership Content Renderer
function renderGarageContent()
	if not garageBodyFrame then
		return
	end
	garageBodyFrame:ClearAllChildren()

	local allCars = CarCatalog.getAll()

	if garageCurrentTab == "GARAGE" then
		-- TAB 1: MY CARS (Spawn, customize, view owned cars)
		local ownedList = {}
		for _, car in allCars do
			if localData.OwnedCars[car.Id] then
				table.insert(ownedList, car)
			end
		end

		local listContainer = make("ScrollingFrame", {
			Size = UDim2.new(0.35, 0, 1, 0),
			BackgroundTransparency = 1,
			ScrollBarThickness = 5,
			ScrollBarImageColor3 = Color3.fromRGB(60, 68, 86),
			BorderSizePixel = 0,
			Parent = garageBodyFrame,
		})

		local detailContainer = make("Frame", {
			Position = UDim2.new(0.38, 0, 0, 0),
			Size = UDim2.new(0.62, 0, 1, 0),
			BackgroundColor3 = THEME.BgCard,
			BorderSizePixel = 0,
			Parent = garageBodyFrame,
		})
		addCorner(detailContainer, 10)
		addStroke(detailContainer, THEME.Stroke, THEME.StrokeTrans)

		make("UIListLayout", {
			Padding = UDim.new(0, 10),
			SortOrder = Enum.SortOrder.LayoutOrder,
			Parent = listContainer,
		})
		local restoringCount = renderRestorationBay(listContainer)

		if #ownedList == 0 then
			make("TextLabel", {
				Size = UDim2.new(1, 0, 0, 60),
				BackgroundTransparency = 1,
				FontFace = Font.fromEnum(Enum.Font.GothamBold),
				Text = "No vehicles in your garage!\nVisit the Dealership tab to buy cars.",
				TextColor3 = THEME.TextSecondary,
				TextSize = 13,
				LayoutOrder = 1,
				Parent = listContainer,
			})
			if restoringCount > 0 then
				make("TextLabel", {
					Size = UDim2.new(1, 0, 1, 0),
					BackgroundTransparency = 1,
					FontFace = Font.fromEnum(Enum.Font.GothamBold),
					Text = "Your barn finds are being restored.\nThey'll be ready to drive when their bars fill.",
					TextColor3 = THEME.TextSecondary,
					TextSize = 13,
					Parent = detailContainer,
				})
			end
			return
		end

		if not localData.OwnedCars[selectedGarageCarId] then
			selectedGarageCarId = ownedList[1].Id
		end

		for i, car in ownedList do
			local isSelected = car.Id == selectedGarageCarId
			local item = make("TextButton", {
				Name = car.Id,
				Size = UDim2.new(1, 0, 0, 60),
				BackgroundColor3 = if isSelected then THEME.BgCardHover else THEME.BgCard,
				BorderSizePixel = 0,
				Text = "",
				AutoButtonColor = false,
				LayoutOrder = i,
				Parent = listContainer,
			})
			addCorner(item, 8)
			addStroke(item, if isSelected then THEME.Accent else THEME.Stroke, if isSelected then 0.2 else THEME.StrokeTrans, if isSelected then 2 else 1)

			local ind = make("Frame", {
				Position = UDim2.new(0, 6, 0.5, -18),
				Size = UDim2.new(0, 6, 0, 36),
				BackgroundColor3 = car.AccentColor,
				BorderSizePixel = 0,
				Parent = item,
			})
			addCorner(ind, 3)

			make("TextLabel", {
				Position = UDim2.new(0, 20, 0, 12),
				Size = UDim2.new(1, -30, 0, 20),
				BackgroundTransparency = 1,
				FontFace = Font.fromEnum(Enum.Font.GothamBold),
				Text = car.DisplayName,
				TextColor3 = if isSelected then THEME.TextPrimary else THEME.TextSecondary,
				TextSize = 13,
				TextXAlignment = Enum.TextXAlignment.Left,
				Parent = item,
			})

			make("TextLabel", {
				Position = UDim2.new(0, 20, 0, 32),
				Size = UDim2.new(1, -30, 0, 16),
				BackgroundTransparency = 1,
				FontFace = Font.fromEnum(Enum.Font.GothamMedium),
				Text = string.format("%s Class • %d MPH", car.Tier, math.round(car.TopSpeed * 2)),
				TextColor3 = THEME.TextMuted,
				TextSize = 11,
				TextXAlignment = Enum.TextXAlignment.Left,
				Parent = item,
			})

			item.MouseButton1Click:Connect(function()
				selectedGarageCarId = car.Id
				renderGarageContent()
			end)
		end

		-- Right detail panel for selected vehicle
		local currentCar = CarCatalog.get(selectedGarageCarId) or ownedList[1]
		if not selectedGaragePaint then
			selectedGaragePaint = currentCar.DefaultColor
		end

		make("TextLabel", {
			Position = UDim2.new(0, 16, 0, 16),
			Size = UDim2.new(1, -32, 0, 24),
			BackgroundTransparency = 1,
			FontFace = Font.fromEnum(Enum.Font.GothamBlack),
			Text = currentCar.DisplayName,
			TextColor3 = THEME.TextPrimary,
			TextSize = 18,
			TextXAlignment = Enum.TextXAlignment.Left,
			Parent = detailContainer,
		})

		make("TextLabel", {
			Position = UDim2.new(0, 16, 0, 42),
			Size = UDim2.new(1, -32, 0, 16),
			BackgroundTransparency = 1,
			FontFace = Font.fromEnum(Enum.Font.GothamMedium),
			Text = currentCar.Subtitle,
			TextColor3 = currentCar.AccentColor,
			TextSize = 12,
			TextXAlignment = Enum.TextXAlignment.Left,
			Parent = detailContainer,
		})

		-- The car's papers: the same line its nameplate carries in the world.
		local ownershipText, ownershipColor = originLine((localData.CarOrigins or {})[currentCar.Id])
		make("TextLabel", {
			Position = UDim2.new(0, 16, 0, 60),
			Size = UDim2.new(1, -32, 0, 14),
			BackgroundTransparency = 1,
			FontFace = Font.fromEnum(Enum.Font.GothamMedium),
			Text = ownershipText,
			TextColor3 = ownershipColor,
			TextSize = 11,
			TextTruncate = Enum.TextTruncate.AtEnd,
			TextXAlignment = Enum.TextXAlignment.Left,
			Parent = detailContainer,
		})

		local specBox = make("Frame", {
			Position = UDim2.new(0, 16, 0, 78),
			Size = UDim2.new(1, -32, 0, 84),
			BackgroundColor3 = Color3.fromRGB(18, 22, 30),
			BorderSizePixel = 0,
			Parent = detailContainer,
		})
		addCorner(specBox, 8)
		addStroke(specBox, THEME.Stroke, THEME.StrokeTrans)

		local function addBoxSpec(col: number, row: number, name: string, val: string)
			-- column 1 sits 16 px in from the left; column 2 starts at 52% across
			local xScale, xOffset = if col == 1 then 0 else 0.52, if col == 1 then 16 else 0
			local y = row == 1 and 12 or 50
			make("TextLabel", {
				Position = UDim2.new(xScale, xOffset, 0, y),
				Size = UDim2.new(0.45, 0, 0, 14),
				BackgroundTransparency = 1,
				FontFace = Font.fromEnum(Enum.Font.GothamMedium),
				Text = name,
				TextColor3 = THEME.TextMuted,
				TextSize = 11,
				TextXAlignment = Enum.TextXAlignment.Left,
				Parent = specBox,
			})
			make("TextLabel", {
				Position = UDim2.new(xScale, xOffset, 0, y + 16),
				Size = UDim2.new(0.45, 0, 0, 16),
				BackgroundTransparency = 1,
				FontFace = Font.fromEnum(Enum.Font.GothamBold),
				Text = val,
				TextColor3 = THEME.TextPrimary,
				TextSize = 13,
				TextXAlignment = Enum.TextXAlignment.Left,
				Parent = specBox,
			})
		end

		addBoxSpec(1, 1, "Top Speed", string.format("%d MPH", math.round(currentCar.TopSpeed * 2)))
		addBoxSpec(2, 1, "Acceleration", tostring(currentCar.Acceleration))
		addBoxSpec(1, 2, "Cornering Grip", tostring(currentCar.Grip))
		addBoxSpec(2, 2, "Drivetrain", currentCar.DriveType)

		make("TextLabel", {
			Position = UDim2.new(0, 16, 0, 168),
			Size = UDim2.new(1, -32, 0, 18),
			BackgroundTransparency = 1,
			FontFace = Font.fromEnum(Enum.Font.GothamBold),
			Text = "CUSTOMIZE PAINT COLOR",
			TextColor3 = THEME.TextSecondary,
			TextSize = 12,
			TextXAlignment = Enum.TextXAlignment.Left,
			Parent = detailContainer,
		})

		local swatchesFrame = make("Frame", {
			Position = UDim2.new(0, 16, 0, 192),
			Size = UDim2.new(1, -32, 0, 48),
			BackgroundTransparency = 1,
			Parent = detailContainer,
		})
		make("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			HorizontalAlignment = Enum.HorizontalAlignment.Left,
			Padding = UDim.new(0, 10),
			Parent = swatchesFrame,
		})

		for _, preset in PAINT_PRESETS do
			local isCurrentColor = selectedGaragePaint == preset.Color
			local swatch = make("TextButton", {
				Size = UDim2.new(0, 34, 0, 34),
				BackgroundColor3 = preset.Color,
				BorderSizePixel = 0,
				Text = "",
				Parent = swatchesFrame,
			})
			addCorner(swatch, 17)
			addStroke(swatch, if isCurrentColor then Color3.fromRGB(255, 255, 255) else Color3.fromRGB(0, 0, 0), if isCurrentColor then 0 else 0.5, if isCurrentColor then 3 else 1)

			swatch.MouseButton1Click:Connect(function()
				selectedGaragePaint = preset.Color
				renderGarageContent()
			end)
		end

		local spawnBtn = make("TextButton", {
			Position = UDim2.new(0, 16, 1, -48),
			Size = UDim2.new(0.68, -20, 0, 36),
			BackgroundColor3 = THEME.Accent,
			FontFace = Font.fromEnum(Enum.Font.GothamBold),
			Text = "🚗 SPAWN VEHICLE",
			TextColor3 = Color3.fromRGB(255, 255, 255),
			TextSize = 13,
			BorderSizePixel = 0,
			Parent = detailContainer,
		})
		addCorner(spawnBtn, 8)

		spawnBtn.MouseButton1Click:Connect(function()
			if spawnRemote then
				spawnBtn.Text = "Spawning..."
				local ok, msg = spawnRemote:InvokeServer(currentCar.Id, selectedGaragePaint)
				if ok then
					showToast("🚗 " .. msg, false)
					closeModal()
				else
					showToast(msg or "Failed to spawn vehicle", true)
				end
				spawnBtn.Text = "🚗 SPAWN VEHICLE"
			end
		end)

		local despawnBtn = make("TextButton", {
			Position = UDim2.new(0.68, 4, 1, -48),
			Size = UDim2.new(0.32, -20, 0, 36),
			BackgroundColor3 = Color3.fromRGB(42, 46, 58),
			FontFace = Font.fromEnum(Enum.Font.GothamBold),
			Text = "🗑️ STORE",
			TextColor3 = THEME.TextSecondary,
			TextSize = 12,
			BorderSizePixel = 0,
			Parent = detailContainer,
		})
		addCorner(despawnBtn, 8)

		despawnBtn.MouseButton1Click:Connect(function()
			if despawnRemote then
				local ok, msg = despawnRemote:InvokeServer()
				if ok then
					showToast("Stored vehicle in garage", false)
				else
					showToast(msg or "No vehicle to store", true)
				end
			end
		end)
	else
		-- TAB 2: DEALERSHIP (Buy cars with in-game Cash)
		local dealScroll = make("ScrollingFrame", {
			Size = UDim2.new(1, 0, 1, 0),
			BackgroundTransparency = 1,
			ScrollBarThickness = 6,
			ScrollBarImageColor3 = Color3.fromRGB(60, 68, 86),
			BorderSizePixel = 0,
			Parent = garageBodyFrame,
		})

		make("UIGridLayout", {
			CellSize = UDim2.new(0, 240, 0, 270),
			CellPadding = UDim2.new(0, 14, 0, 14),
			SortOrder = Enum.SortOrder.LayoutOrder,
			Parent = dealScroll,
		})

		for i, car in allCars do
			local isOwned = localData.OwnedCars[car.Id] == true
			local canAfford = localData.Cash >= car.Price

			local card = make("Frame", {
				Name = car.Id,
				BackgroundColor3 = THEME.BgCard,
				BorderSizePixel = 0,
				LayoutOrder = i,
				Parent = dealScroll,
			})
			addCorner(card, 10)
			addStroke(card, THEME.Stroke, THEME.StrokeTrans)

			local bar = make("Frame", {
				Size = UDim2.new(1, 0, 0, 4),
				BackgroundColor3 = car.AccentColor,
				BorderSizePixel = 0,
				Parent = card,
			})
			addCorner(bar, 4)

			local tier = make("TextLabel", {
				Position = UDim2.new(0, 12, 0, 12),
				Size = UDim2.new(0, 68, 0, 18),
				BackgroundColor3 = Color3.fromRGB(35, 42, 58),
				FontFace = Font.fromEnum(Enum.Font.GothamBold),
				Text = string.upper(car.Tier),
				TextColor3 = car.AccentColor,
				TextSize = 10,
				Parent = card,
			})
			addCorner(tier, 4)

			make("TextLabel", {
				Position = UDim2.new(1, -115, 0, 12),
				Size = UDim2.new(0, 103, 0, 18),
				BackgroundTransparency = 1,
				FontFace = Font.fromEnum(Enum.Font.GothamBlack),
				Text = if car.Price == 0 then "FREE" else formatCash(car.Price),
				TextColor3 = THEME.Gold,
				TextSize = 13,
				TextXAlignment = Enum.TextXAlignment.Right,
				Parent = card,
			})

			make("TextLabel", {
				Position = UDim2.new(0, 12, 0, 36),
				Size = UDim2.new(1, -24, 0, 22),
				BackgroundTransparency = 1,
				FontFace = Font.fromEnum(Enum.Font.GothamBold),
				Text = car.DisplayName,
				TextColor3 = THEME.TextPrimary,
				TextSize = 14,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextTruncate = Enum.TextTruncate.AtEnd,
				Parent = card,
			})

			make("TextLabel", {
				Position = UDim2.new(0, 12, 0, 60),
				Size = UDim2.new(1, -24, 0, 32),
				BackgroundTransparency = 1,
				FontFace = Font.fromEnum(Enum.Font.GothamMedium),
				Text = car.Description,
				TextColor3 = THEME.TextSecondary,
				TextSize = 10,
				TextWrapped = true,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextYAlignment = Enum.TextYAlignment.Top,
				Parent = card,
			})

			local specs = make("Frame", {
				Position = UDim2.new(0, 12, 0, 100),
				Size = UDim2.new(1, -24, 0, 110),
				BackgroundColor3 = Color3.fromRGB(18, 21, 28),
				BorderSizePixel = 0,
				Parent = card,
			})
			addCorner(specs, 6)

			local function specLine(y: number, label: string, val: string)
				make("TextLabel", {
					Position = UDim2.new(0, 8, 0, y),
					Size = UDim2.new(0.5, -8, 0, 20),
					BackgroundTransparency = 1,
					FontFace = Font.fromEnum(Enum.Font.GothamMedium),
					Text = label,
					TextColor3 = THEME.TextSecondary,
					TextSize = 11,
					TextXAlignment = Enum.TextXAlignment.Left,
					Parent = specs,
				})
				make("TextLabel", {
					Position = UDim2.new(0.5, 0, 0, y),
					Size = UDim2.new(0.5, -8, 0, 20),
					BackgroundTransparency = 1,
					FontFace = Font.fromEnum(Enum.Font.GothamBold),
					Text = val,
					TextColor3 = THEME.TextPrimary,
					TextSize = 11,
					TextXAlignment = Enum.TextXAlignment.Right,
					Parent = specs,
				})
			end

			specLine(6, "Top Speed", string.format("%d MPH", math.round(car.TopSpeed * 2)))
			specLine(30, "Acceleration", tostring(car.Acceleration))
			specLine(54, "Cornering Grip", tostring(car.Grip))
			specLine(78, "Drive Type", car.DriveType)

			local actionBtn = make("TextButton", {
				Position = UDim2.new(0, 12, 1, -40),
				Size = UDim2.new(1, -24, 0, 30),
				FontFace = Font.fromEnum(Enum.Font.GothamBold),
				TextSize = 12,
				BorderSizePixel = 0,
				Parent = card,
			})
			addCorner(actionBtn, 6)

			if isOwned then
				actionBtn.BackgroundColor3 = Color3.fromRGB(28, 48, 38)
				actionBtn.Text = "OWNED ✓ (SELECT)"
				actionBtn.TextColor3 = THEME.Green
				actionBtn.MouseButton1Click:Connect(function()
					selectedGarageCarId = car.Id
					garageCurrentTab = "GARAGE"
					renderGarageContent()
				end)
			elseif canAfford then
				actionBtn.BackgroundColor3 = THEME.Accent
				actionBtn.Text = if car.Price == 0 then "CLAIM FREE" else "PURCHASE FOR CASH"
				actionBtn.TextColor3 = Color3.fromRGB(255, 255, 255)

				actionBtn.MouseButton1Click:Connect(function()
					if buyRemote then
						actionBtn.Text = "Purchasing..."
						local ok, msg = buyRemote:InvokeServer(car.Id)
						if ok then
							showToast("🎉 " .. msg, false)
							selectedGarageCarId = car.Id
							renderGarageContent()
							updateHUD()
						else
							showToast(msg or "Purchase failed", true)
							renderGarageContent()
						end
					end
				end)
			else
				actionBtn.BackgroundColor3 = Color3.fromRGB(38, 40, 48)
				actionBtn.Text = string.format("NEED %s MORE", formatCash(car.Price - localData.Cash))
				actionBtn.TextColor3 = THEME.TextMuted
				actionBtn.AutoButtonColor = false
			end
		end
	end
end

-- Trading: the trade window, and the prompt an incoming request arrives on.

-- Everything asked of TradingService goes through here and comes back as
-- (ok, message). A refusal is worth a toast; a change that worked shows itself
-- in the panel a moment later, so only the decisive ones say so.
local function tradeAction(action: string, carId: string?)
	if not tradeActionRemote then
		return
	end
	local ok, message = tradeActionRemote:InvokeServer(action, carId)
	if not ok then
		showToast(if typeof(message) == "string" then message else "That did not work", true)
	elseif (action == "confirm" or action == "cancel") and typeof(message) == "string" then
		showToast(message, false)
	end
end

local function offerValue(offer: { Trading.OfferedCar }): number
	local total = 0
	for _, entry in offer do
		local car = CarCatalog.get(entry.CarId)
		if car then
			total += car.Price
		end
	end
	return total
end

-- Who a side of the trade is, player id included: the same identity the
-- nameplate on their cars carries.
local function identityStrip(parent: Frame, side: Trading.Side)
	local avatar = make("ImageLabel", {
		Position = UDim2.new(0, 14, 0, 40),
		Size = UDim2.new(0, 30, 0, 30),
		BackgroundColor3 = THEME.BgLocked,
		BorderSizePixel = 0,
		Image = string.format("rbxthumb://type=AvatarHeadShot&id=%d&w=48&h=48", side.UserId),
		Parent = parent,
	})
	addCorner(avatar, 15)

	make("TextLabel", {
		Position = UDim2.new(0, 52, 0, 40),
		Size = UDim2.new(1, -66, 0, 16),
		BackgroundTransparency = 1,
		FontFace = Font.fromEnum(Enum.Font.GothamBold),
		Text = side.DisplayName,
		TextColor3 = THEME.TextPrimary,
		TextSize = 12,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = parent,
	})

	make("TextLabel", {
		Position = UDim2.new(0, 52, 0, 56),
		Size = UDim2.new(1, -66, 0, 14),
		BackgroundTransparency = 1,
		FontFace = Font.fromEnum(Enum.Font.GothamMedium),
		Text = string.format("@%s • PLAYER ID %d", side.Name, side.UserId),
		TextColor3 = THEME.TextMuted,
		TextSize = 10,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = parent,
	})
end

-- A car on the table. `onRemove` makes the card clickable to take it back; the
-- other side passes nil, so theirs only reads.
local function tradeOfferCard(parent: Instance, entry: Trading.OfferedCar, order: number, onRemove: (() -> ())?)
	local car = CarCatalog.get(entry.CarId)
	local accent = if car then car.AccentColor else THEME.TextMuted
	local nameInset = if onRemove then 62 else 30

	local card = make("TextButton", {
		Size = UDim2.new(1, -4, 0, 58),
		BackgroundColor3 = THEME.BgCardHover,
		BorderSizePixel = 0,
		Text = "",
		AutoButtonColor = onRemove ~= nil,
		LayoutOrder = order,
		Parent = parent,
	})
	addCorner(card, 8)
	addStroke(card, accent, 0.5)

	local stripe = make("Frame", {
		Position = UDim2.new(0, 7, 0.5, -19),
		Size = UDim2.new(0, 5, 0, 38),
		BackgroundColor3 = accent,
		BorderSizePixel = 0,
		Parent = card,
	})
	addCorner(stripe, 3)

	make("TextLabel", {
		Position = UDim2.new(0, 20, 0, 7),
		Size = UDim2.new(1, -nameInset, 0, 16),
		BackgroundTransparency = 1,
		FontFace = Font.fromEnum(Enum.Font.GothamBold),
		Text = if car then car.DisplayName else entry.CarId,
		TextColor3 = THEME.TextPrimary,
		TextSize = 12,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = card,
	})

	make("TextLabel", {
		Position = UDim2.new(0, 20, 0, 24),
		Size = UDim2.new(1, -nameInset, 0, 14),
		BackgroundTransparency = 1,
		FontFace = Font.fromEnum(Enum.Font.GothamMedium),
		Text = if car
			then string.format("%s • %d MPH • %s", car.Tier, math.round(car.TopSpeed * 2), formatCash(car.Price))
			else "Unknown vehicle",
		TextColor3 = THEME.TextSecondary,
		TextSize = 10,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = card,
	})

	local historyText, historyColor = originLine(entry)
	make("TextLabel", {
		Position = UDim2.new(0, 20, 0, 39),
		Size = UDim2.new(1, -nameInset, 0, 14),
		BackgroundTransparency = 1,
		FontFace = Font.fromEnum(Enum.Font.GothamMedium),
		Text = historyText,
		TextColor3 = historyColor,
		TextSize = 10,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = card,
	})

	if onRemove then
		local remove = make("TextButton", {
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -8, 0.5, 0),
			Size = UDim2.new(0, 34, 0, 28),
			BackgroundColor3 = Color3.fromRGB(48, 24, 26),
			FontFace = Font.fromEnum(Enum.Font.GothamBold),
			Text = "✕",
			TextColor3 = THEME.Red,
			TextSize = 13,
			BorderSizePixel = 0,
			Parent = card,
		})
		addCorner(remove, 6)
		remove.MouseButton1Click:Connect(onRemove)
		card.MouseButton1Click:Connect(onRemove)
	end
end

-- One of your cars you have not put up yet.
local function tradeGarageRow(parent: Instance, car: CarCatalog.CarEntry, order: number)
	local row = make("TextButton", {
		Size = UDim2.new(1, -4, 0, 42),
		BackgroundColor3 = THEME.BgLocked,
		BorderSizePixel = 0,
		Text = "",
		LayoutOrder = order,
		Parent = parent,
	})
	addCorner(row, 6)
	addStroke(row, THEME.Stroke, THEME.StrokeTrans)

	local dot = make("Frame", {
		Position = UDim2.new(0, 10, 0.5, -6),
		Size = UDim2.new(0, 12, 0, 12),
		BackgroundColor3 = car.AccentColor,
		BorderSizePixel = 0,
		Parent = row,
	})
	addCorner(dot, 6)

	make("TextLabel", {
		Position = UDim2.new(0, 30, 0, 5),
		Size = UDim2.new(1, -110, 0, 16),
		BackgroundTransparency = 1,
		FontFace = Font.fromEnum(Enum.Font.GothamBold),
		Text = car.DisplayName,
		TextColor3 = THEME.TextPrimary,
		TextSize = 12,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = row,
	})

	make("TextLabel", {
		Position = UDim2.new(0, 30, 0, 21),
		Size = UDim2.new(1, -110, 0, 14),
		BackgroundTransparency = 1,
		FontFace = Font.fromEnum(Enum.Font.GothamMedium),
		Text = string.format("%s • %s", car.Tier, formatCash(car.Price)),
		TextColor3 = THEME.TextMuted,
		TextSize = 10,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = row,
	})

	local add = make("TextButton", {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -8, 0.5, 0),
		Size = UDim2.new(0, 72, 0, 26),
		BackgroundColor3 = THEME.Accent,
		FontFace = Font.fromEnum(Enum.Font.GothamBold),
		Text = "＋ OFFER",
		TextColor3 = Color3.fromRGB(255, 255, 255),
		TextSize = 10,
		BorderSizePixel = 0,
		Parent = row,
	})
	addCorner(add, 6)

	local function offer()
		tradeAction("offer", car.Id)
	end
	add.MouseButton1Click:Connect(offer)
	row.MouseButton1Click:Connect(offer)
end

local function emptyNote(parent: Instance, text: string, order: number)
	make("TextLabel", {
		Size = UDim2.new(1, -4, 0, 54),
		BackgroundTransparency = 1,
		FontFace = Font.fromEnum(Enum.Font.GothamMedium),
		Text = text,
		TextColor3 = THEME.TextMuted,
		TextSize = 11,
		TextWrapped = true,
		LayoutOrder = order,
		Parent = parent,
	})
end

-- No trade open: everyone else in the server, and a button to invite them.
local function renderTraderPicker()
	make("TextLabel", {
		Size = UDim2.new(1, 0, 0, 18),
		BackgroundTransparency = 1,
		FontFace = Font.fromEnum(Enum.Font.GothamBold),
		Text = "PLAYERS IN THIS SERVER",
		TextColor3 = THEME.TextSecondary,
		TextSize = 12,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = tradeBodyFrame,
	})

	make("TextLabel", {
		Position = UDim2.new(0, 0, 0, 20),
		Size = UDim2.new(1, 0, 0, 32),
		BackgroundTransparency = 1,
		FontFace = Font.fromEnum(Enum.Font.GothamMedium),
		Text = string.format(
			"Invite someone to open a trade window. Each side can put up to %d vehicles on the table, and both have to confirm before anything moves. Starter vehicles cannot be traded, and neither of you can receive a car you already own.",
			Trading.MaxOffer
		),
		TextColor3 = THEME.TextMuted,
		TextSize = 11,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		Parent = tradeBodyFrame,
	})

	local list = make("ScrollingFrame", {
		Position = UDim2.new(0, 0, 0, 62),
		Size = UDim2.new(1, 0, 1, -62),
		BackgroundTransparency = 1,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 6,
		ScrollBarImageColor3 = Color3.fromRGB(60, 68, 86),
		BorderSizePixel = 0,
		Parent = tradeBodyFrame,
	})
	make("UIListLayout", {
		Padding = UDim.new(0, 8),
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = list,
	})

	local others = {}
	for _, other in Players:GetPlayers() do
		if other ~= player then
			table.insert(others, other)
		end
	end

	if #others == 0 then
		emptyNote(list, "Nobody else is in this server yet.\nTrading needs a second player.", 1)
		return
	end

	for i, other in others do
		local row = make("Frame", {
			Size = UDim2.new(1, -4, 0, 62),
			BackgroundColor3 = THEME.BgCard,
			BorderSizePixel = 0,
			LayoutOrder = i,
			Parent = list,
		})
		addCorner(row, 8)
		addStroke(row, THEME.Stroke, THEME.StrokeTrans)

		local avatar = make("ImageLabel", {
			Position = UDim2.new(0, 12, 0.5, -20),
			Size = UDim2.new(0, 40, 0, 40),
			BackgroundColor3 = THEME.BgLocked,
			BorderSizePixel = 0,
			Image = string.format("rbxthumb://type=AvatarHeadShot&id=%d&w=48&h=48", other.UserId),
			Parent = row,
		})
		addCorner(avatar, 20)

		make("TextLabel", {
			Position = UDim2.new(0, 62, 0, 12),
			Size = UDim2.new(1, -200, 0, 18),
			BackgroundTransparency = 1,
			FontFace = Font.fromEnum(Enum.Font.GothamBold),
			Text = other.DisplayName,
			TextColor3 = THEME.TextPrimary,
			TextSize = 13,
			TextTruncate = Enum.TextTruncate.AtEnd,
			TextXAlignment = Enum.TextXAlignment.Left,
			Parent = row,
		})

		make("TextLabel", {
			Position = UDim2.new(0, 62, 0, 32),
			Size = UDim2.new(1, -200, 0, 16),
			BackgroundTransparency = 1,
			FontFace = Font.fromEnum(Enum.Font.GothamMedium),
			Text = string.format("@%s • PLAYER ID %d", other.Name, other.UserId),
			TextColor3 = THEME.TextMuted,
			TextSize = 11,
			TextTruncate = Enum.TextTruncate.AtEnd,
			TextXAlignment = Enum.TextXAlignment.Left,
			Parent = row,
		})

		local invite = make("TextButton", {
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -12, 0.5, 0),
			Size = UDim2.new(0, 128, 0, 32),
			BackgroundColor3 = THEME.Accent,
			FontFace = Font.fromEnum(Enum.Font.GothamBold),
			Text = "🤝 INVITE TO TRADE",
			TextColor3 = Color3.fromRGB(255, 255, 255),
			TextSize = 11,
			BorderSizePixel = 0,
			Parent = row,
		})
		addCorner(invite, 6)

		invite.MouseButton1Click:Connect(function()
			if not tradeRequestRemote then
				return
			end
			invite.Text = "SENDING..."
			local ok, message = tradeRequestRemote:InvokeServer(other.UserId)
			showToast(if typeof(message) == "string" then message else "Trade request sent", not ok)
			invite.Text = "🤝 INVITE TO TRADE"
		end)
	end
end

-- A trade in progress: both offers, both confirmations, and what the swap is worth.
local function renderTradeSession(session: Trading.Session)
	local you, them = session.You, session.Them
	local BAR_HEIGHT = 46

	local function panel(xScale: number): Frame
		local frame = make("Frame", {
			Position = UDim2.new(xScale, 0, 0, 0),
			Size = UDim2.new(0.49, 0, 1, -(BAR_HEIGHT + 10)),
			BackgroundColor3 = THEME.BgCard,
			BorderSizePixel = 0,
			Parent = tradeBodyFrame,
		})
		addCorner(frame, 10)
		addStroke(frame, THEME.Stroke, THEME.StrokeTrans)
		return frame
	end

	local function panelHeader(parent: Frame, title: string, confirmed: boolean)
		make("TextLabel", {
			Position = UDim2.new(0, 14, 0, 14),
			Size = UDim2.new(1, -130, 0, 18),
			BackgroundTransparency = 1,
			FontFace = Font.fromEnum(Enum.Font.GothamBlack),
			Text = title,
			TextColor3 = THEME.TextPrimary,
			TextSize = 13,
			TextTruncate = Enum.TextTruncate.AtEnd,
			TextXAlignment = Enum.TextXAlignment.Left,
			Parent = parent,
		})

		local pill = make("Frame", {
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -14, 0, 13),
			Size = UDim2.new(0, 106, 0, 20),
			BackgroundColor3 = if confirmed then Color3.fromRGB(20, 48, 34) else Color3.fromRGB(30, 33, 42),
			BorderSizePixel = 0,
			Parent = parent,
		})
		addCorner(pill, 6)
		addStroke(pill, if confirmed then THEME.Green else THEME.StrokeLocked, 0.35)

		make("TextLabel", {
			Size = UDim2.new(1, 0, 1, 0),
			BackgroundTransparency = 1,
			FontFace = Font.fromEnum(Enum.Font.GothamBold),
			Text = if confirmed then "✓ CONFIRMED" else "NOT CONFIRMED",
			TextColor3 = if confirmed then THEME.Green else THEME.TextMuted,
			TextSize = 10,
			Parent = pill,
		})
	end

	local function offerList(parent: Frame): ScrollingFrame
		local scroll = make("ScrollingFrame", {
			Position = UDim2.new(0, 14, 0, 78),
			Size = UDim2.new(1, -28, 0, 150),
			BackgroundColor3 = THEME.BgLocked,
			BorderSizePixel = 0,
			CanvasSize = UDim2.new(),
			AutomaticCanvasSize = Enum.AutomaticSize.Y,
			ScrollBarThickness = 5,
			ScrollBarImageColor3 = Color3.fromRGB(60, 68, 86),
			Parent = parent,
		})
		addCorner(scroll, 8)
		make("UIPadding", {
			PaddingTop = UDim.new(0, 8),
			PaddingBottom = UDim.new(0, 8),
			PaddingLeft = UDim.new(0, 8),
			PaddingRight = UDim.new(0, 8),
			Parent = scroll,
		})
		make("UIListLayout", {
			Padding = UDim.new(0, 8),
			SortOrder = Enum.SortOrder.LayoutOrder,
			Parent = scroll,
		})
		return scroll
	end

	local function sectionLabel(parent: Frame, text: string)
		make("TextLabel", {
			Position = UDim2.new(0, 14, 0, 236),
			Size = UDim2.new(1, -28, 0, 16),
			BackgroundTransparency = 1,
			FontFace = Font.fromEnum(Enum.Font.GothamBold),
			Text = text,
			TextColor3 = THEME.TextSecondary,
			TextSize = 11,
			TextXAlignment = Enum.TextXAlignment.Left,
			Parent = parent,
		})
	end

	-- YOUR SIDE
	local yourPanel = panel(0)
	panelHeader(yourPanel, string.format("YOUR OFFER  %d/%d", #you.Offer, Trading.MaxOffer), you.Confirmed)
	identityStrip(yourPanel, you)

	local yourOffer = offerList(yourPanel)
	if #you.Offer == 0 then
		emptyNote(yourOffer, "Nothing on the table yet.\nPick a vehicle from your garage below.", 1)
	end
	for i, entry in you.Offer do
		tradeOfferCard(yourOffer, entry, i, function()
			tradeAction("withdraw", entry.CarId)
		end)
	end

	sectionLabel(yourPanel, "ADD FROM YOUR GARAGE")
	local picker = make("ScrollingFrame", {
		Position = UDim2.new(0, 14, 0, 256),
		Size = UDim2.new(1, -28, 1, -270),
		BackgroundTransparency = 1,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 5,
		ScrollBarImageColor3 = Color3.fromRGB(60, 68, 86),
		BorderSizePixel = 0,
		Parent = yourPanel,
	})
	make("UIListLayout", {
		Padding = UDim.new(0, 6),
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = picker,
	})

	local onTable: { [string]: boolean } = {}
	for _, entry in you.Offer do
		onTable[entry.CarId] = true
	end

	local addable = 0
	for i, car in CarCatalog.getAll() do
		if localData.OwnedCars[car.Id] and Trading.isTradeable(car) and not onTable[car.Id] then
			addable += 1
			tradeGarageRow(picker, car, i)
		end
	end
	if addable == 0 then
		emptyNote(picker, "Nothing left to offer. Starter vehicles cannot be traded.", 1)
	end

	-- THEIR SIDE
	local theirPanel = panel(0.51)
	panelHeader(theirPanel, string.format("THEIR OFFER  %d/%d", #them.Offer, Trading.MaxOffer), them.Confirmed)
	identityStrip(theirPanel, them)

	local theirOffer = offerList(theirPanel)
	if #them.Offer == 0 then
		emptyNote(theirOffer, string.format("%s has not offered anything yet.", them.DisplayName), 1)
	end
	for i, entry in them.Offer do
		tradeOfferCard(theirOffer, entry, i, nil)
	end

	sectionLabel(theirPanel, "TRADE SUMMARY")
	local summary = make("Frame", {
		Position = UDim2.new(0, 14, 0, 256),
		Size = UDim2.new(1, -28, 1, -270),
		BackgroundColor3 = THEME.BgLocked,
		BorderSizePixel = 0,
		Parent = theirPanel,
	})
	addCorner(summary, 8)
	addStroke(summary, THEME.Stroke, THEME.StrokeTrans)

	local function summaryRow(y: number, label: string, value: string, color: Color3)
		make("TextLabel", {
			Position = UDim2.new(0, 12, 0, y),
			Size = UDim2.new(0.5, -12, 0, 16),
			BackgroundTransparency = 1,
			FontFace = Font.fromEnum(Enum.Font.GothamMedium),
			Text = label,
			TextColor3 = THEME.TextSecondary,
			TextSize = 11,
			TextXAlignment = Enum.TextXAlignment.Left,
			Parent = summary,
		})
		make("TextLabel", {
			Position = UDim2.new(0.5, 0, 0, y),
			Size = UDim2.new(0.5, -12, 0, 16),
			BackgroundTransparency = 1,
			FontFace = Font.fromEnum(Enum.Font.GothamBold),
			Text = value,
			TextColor3 = color,
			TextSize = 11,
			TextXAlignment = Enum.TextXAlignment.Right,
			Parent = summary,
		})
	end

	local giving, getting = offerValue(you.Offer), offerValue(them.Offer)
	summaryRow(10, "You give", string.format("%d vehicle(s) • %s", #you.Offer, formatCash(giving)), THEME.TextPrimary)
	summaryRow(30, "You receive", string.format("%d vehicle(s) • %s", #them.Offer, formatCash(getting)), THEME.TextPrimary)

	local net = getting - giving
	summaryRow(
		50,
		"Value swing",
		(if net >= 0 then "+" else "-") .. formatCash(math.abs(net)),
		if net >= 0 then THEME.Green else THEME.Red
	)

	make("TextLabel", {
		Position = UDim2.new(0, 12, 0, 74),
		Size = UDim2.new(1, -24, 1, -84),
		BackgroundTransparency = 1,
		FontFace = Font.fromEnum(Enum.Font.GothamMedium),
		Text = "Changing either offer clears both confirmations, so what you confirm is always what you are looking at. Paint and ownership history travel with each car.",
		TextColor3 = THEME.TextMuted,
		TextSize = 10,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		Parent = summary,
	})

	-- ACTION BAR
	local bar = make("Frame", {
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 0, 1, 0),
		Size = UDim2.new(1, 0, 0, BAR_HEIGHT),
		BackgroundTransparency = 1,
		Parent = tradeBodyFrame,
	})

	local status, statusColor
	if you.Confirmed and them.Confirmed then
		status, statusColor = "Both sides confirmed -- settling the trade...", THEME.Green
	elseif you.Confirmed then
		status, statusColor = string.format("You have confirmed. Waiting on %s.", them.DisplayName), THEME.Gold
	elseif them.Confirmed then
		status, statusColor = string.format("%s has confirmed -- your move.", them.DisplayName), THEME.Green
	else
		status, statusColor = "Neither side has confirmed yet.", THEME.TextSecondary
	end

	make("TextLabel", {
		Size = UDim2.new(1, -350, 1, 0),
		BackgroundTransparency = 1,
		FontFace = Font.fromEnum(Enum.Font.GothamBold),
		Text = status,
		TextColor3 = statusColor,
		TextSize = 12,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = bar,
	})

	local confirmBtn = make("TextButton", {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -140, 0.5, 0),
		Size = UDim2.new(0, 200, 0, 36),
		BackgroundColor3 = if you.Confirmed then Color3.fromRGB(58, 48, 12) else THEME.Green,
		FontFace = Font.fromEnum(Enum.Font.GothamBold),
		Text = if you.Confirmed then "✓ CONFIRMED (UNDO)" else "✓ CONFIRM TRADE",
		TextColor3 = if you.Confirmed then THEME.Gold else Color3.fromRGB(255, 255, 255),
		TextSize = 12,
		BorderSizePixel = 0,
		Parent = bar,
	})
	addCorner(confirmBtn, 8)

	confirmBtn.MouseButton1Click:Connect(function()
		tradeAction(if you.Confirmed then "unconfirm" else "confirm", nil)
	end)

	local cancelBtn = make("TextButton", {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, 0, 0.5, 0),
		Size = UDim2.new(0, 130, 0, 36),
		BackgroundColor3 = Color3.fromRGB(48, 24, 26),
		FontFace = Font.fromEnum(Enum.Font.GothamBold),
		Text = "✕ CALL OFF",
		TextColor3 = THEME.Red,
		TextSize = 12,
		BorderSizePixel = 0,
		Parent = bar,
	})
	addCorner(cancelBtn, 8)

	cancelBtn.MouseButton1Click:Connect(function()
		tradeAction("cancel", nil)
	end)
end

function renderTradeContent()
	if not tradeBodyFrame then
		return
	end
	tradeBodyFrame:ClearAllChildren()

	if tradeSession then
		renderTradeSession(tradeSession)
	else
		renderTraderPicker()
	end
end

-- The incoming-request prompt, and its countdown. tradeInvite is what the server
-- sent; it lapses on its own when the clock runs out, exactly as it does there.
local function updateTradeInvitePrompt()
	if not (tradeInviteFrame and tradeInvite) then
		return
	end

	local left = tradeInvite.ExpiresAt - Workspace:GetServerTimeNow()
	if left <= 0 then
		tradeInvite = nil
		tradeInviteFrame.Visible = false
		return
	end

	tradeInviteTimer.Text = string.format("%ds", math.ceil(left))
	tradeInviteFill.Size = UDim2.fromScale(math.clamp(left / math.max(tradeInvite.Seconds or 1, 1), 0, 1), 1)
end

local function showTradeInvite(invite: any)
	tradeInvite = invite
	if not tradeInviteFrame then
		return
	end

	if not invite then
		tradeInviteFrame.Visible = false
		return
	end

	tradeInviteAvatar.Image = string.format("rbxthumb://type=AvatarHeadShot&id=%d&w=100&h=100", invite.FromUserId)
	tradeInviteName.Text = invite.FromDisplayName
	tradeInviteId.Text = string.format("@%s • PLAYER ID %d", invite.FromName, invite.FromUserId)
	updateTradeInvitePrompt()

	tradeInviteFrame.Visible = true
	tradeInviteFrame.Position = UDim2.new(0.5, 0, 0, -180)
	TweenService:Create(tradeInviteFrame, TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
		Position = UDim2.new(0.5, 0, 0, 76),
	}):Play()
end

local function answerTradeInvite(accept: boolean)
	if not tradeInvite then
		return
	end
	showTradeInvite(nil)

	if not tradeRespondRemote then
		return
	end
	local ok, message = tradeRespondRemote:InvokeServer(accept)
	if not ok then
		showToast(if typeof(message) == "string" then message else "That request is gone", true)
	elseif not accept then
		showToast("Trade request declined", false)
	end
end

-- Build the Full Screen GUI
local function buildInterface()
	screenGui = make("ScreenGui", {
		Name = "MainGameGui",
		ResetOnSpawn = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		IgnoreGuiInset = false, -- Respect Roblox TopBar insets!
		Parent = playerGui,
	})

	-- Screen Fade Overlay for Teleport
	fadeOverlay = make("Frame", {
		Name = "FadeOverlay",
		Size = UDim2.new(1, 0, 1, 0),
		BackgroundColor3 = Color3.fromRGB(0, 0, 0),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Visible = false,
		ZIndex = 100,
		Parent = screenGui,
	})

	-- Toast Notification Frame
	toastFrame = make("Frame", {
		Name = "Toast",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, -60),
		Size = UDim2.new(0, 360, 0, 44),
		BackgroundColor3 = Color3.fromRGB(20, 25, 35),
		BorderSizePixel = 0,
		Visible = false,
		ZIndex = 90,
		Parent = screenGui,
	})
	addCorner(toastFrame, 8)
	addStroke(toastFrame, THEME.Stroke, 0.7)

	toastLabel = make("TextLabel", {
		Size = UDim2.new(1, -20, 1, 0),
		Position = UDim2.new(0, 10, 0, 0),
		BackgroundTransparency = 1,
		FontFace = Font.fromEnum(Enum.Font.GothamBold),
		Text = "Notification",
		TextColor3 = THEME.TextPrimary,
		TextSize = 13,
		TextXAlignment = Enum.TextXAlignment.Center,
		Parent = toastFrame,
	})

	-- LEFT NAVIGATION DOCK (Non-overlapping, vertically centered on left)
	local navDock = make("Frame", {
		Name = "NavDock",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 20, 0.5, 0),
		Size = UDim2.new(0, 150, 0, 360),
		BackgroundColor3 = THEME.BgModal,
		BackgroundTransparency = 0.12,
		BorderSizePixel = 0,
		ZIndex = 10,
		Parent = screenGui,
	})
	addCorner(navDock, 14)
	addStroke(navDock, THEME.Stroke, THEME.StrokeTrans)

	local navList = make("UIListLayout", {
		Padding = UDim.new(0, 6),
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		Parent = navDock,
	})

	-- CASH DISPLAY AT THE TOP OF THE DOCK
	local cashCard = make("Frame", {
		Name = "DockCashHeader",
		Size = UDim2.new(0, 134, 0, 52),
		BackgroundColor3 = THEME.BgCard,
		BorderSizePixel = 0,
		LayoutOrder = 1,
		Parent = navDock,
	})
	addCorner(cashCard, 10)
	addStroke(cashCard, THEME.Gold, 0.6)

	make("TextLabel", {
		Position = UDim2.new(0, 8, 0, 6),
		Size = UDim2.new(1, -16, 0, 14),
		BackgroundTransparency = 1,
		FontFace = Font.fromEnum(Enum.Font.GothamBold),
		Text = "BALANCE",
		TextColor3 = THEME.TextMuted,
		TextSize = 9,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = cashCard,
	})

	dockCashLabel = make("TextLabel", {
		Position = UDim2.new(0, 8, 0, 20),
		Size = UDim2.new(1, -16, 0, 22),
		BackgroundTransparency = 1,
		FontFace = Font.fromEnum(Enum.Font.GothamBlack),
		Text = "$0",
		TextColor3 = THEME.Gold,
		TextSize = 15,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = cashCard,
	})

	dockMultBadge = make("Frame", {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -6, 0, 6),
		Size = UDim2.new(0, 38, 0, 16),
		BackgroundColor3 = Color3.fromRGB(50, 42, 10),
		BorderSizePixel = 0,
		Visible = false,
		Parent = cashCard,
	})
	addCorner(dockMultBadge, 4)
	addStroke(dockMultBadge, THEME.Gold, 0.4)

	make("TextLabel", {
		Size = UDim2.new(1, 0, 1, 0),
		BackgroundTransparency = 1,
		FontFace = Font.fromEnum(Enum.Font.GothamBold),
		Text = "⚡ 2X",
		TextColor3 = THEME.Gold,
		TextSize = 10,
		Parent = dockMultBadge,
	})

	-- Divider line
	local div = make("Frame", {
		Size = UDim2.new(0, 134, 0, 1),
		BackgroundColor3 = Color3.fromRGB(45, 50, 65),
		BorderSizePixel = 0,
		LayoutOrder = 2,
		Parent = navDock,
	})

	local function makeNavButton(order: number, name: string, label: string, icon: string, isPrimary: boolean?): (TextButton, TextLabel?)
		local btn = make("TextButton", {
			Name = name,
			Size = UDim2.new(0, 134, 0, 44),
			BackgroundColor3 = if isPrimary then THEME.Accent else THEME.BgCard,
			BorderSizePixel = 0,
			Text = "",
			AutoButtonColor = true,
			LayoutOrder = order,
			Parent = navDock,
		})
		addCorner(btn, 10)
		addStroke(btn, if isPrimary then THEME.Accent else THEME.Stroke, if isPrimary then 0.3 else THEME.StrokeTrans)

		make("TextLabel", {
			Position = UDim2.new(0, 10, 0.5, -11),
			Size = UDim2.new(0, 22, 0, 22),
			BackgroundTransparency = 1,
			FontFace = Font.fromEnum(Enum.Font.GothamBold),
			Text = icon,
			TextSize = 16,
			Parent = btn,
		})

		make("TextLabel", {
			Position = UDim2.new(0, 36, 0, 0),
			Size = UDim2.new(1, -42, 1, 0),
			BackgroundTransparency = 1,
			FontFace = Font.fromEnum(Enum.Font.GothamBold),
			Text = label,
			TextColor3 = if isPrimary then Color3.fromRGB(255, 255, 255) else THEME.TextPrimary,
			TextSize = 12,
			TextXAlignment = Enum.TextXAlignment.Left,
			Parent = btn,
		})

		local badge: TextLabel? = nil
		if name == "CardexBtn" then
			badge = make("TextLabel", {
				AnchorPoint = Vector2.new(1, 0.5),
				Position = UDim2.new(1, -6, 0.5, 0),
				Size = UDim2.new(0, 26, 0, 18),
				BackgroundColor3 = Color3.fromRGB(35, 42, 58),
				FontFace = Font.fromEnum(Enum.Font.GothamBold),
				Text = "1/5",
				TextColor3 = THEME.Accent,
				TextSize = 10,
				Parent = btn,
			})
			addCorner(badge, 4)
		end

		return btn, badge
	end

	local cardexBtn, cBadge = makeNavButton(3, "CardexBtn", "CARDEX", "🗂️")
	dockCardexBadge = cBadge
	local garageBtn = makeNavButton(4, "GarageBtn", "GARAGE", "🚘")
	local tradeBtn = makeNavButton(5, "TradeBtn", "TRADE", "🤝")
	local shopBtn = makeNavButton(6, "ShopBtn", "ROBUX SHOP", "🛍️")
	local playBtn = makeNavButton(7, "PlayBtn", "PLAY", "▶", true)

	cardexBtn.MouseButton1Click:Connect(function()
		openModal(cardexModal)
	end)
	garageBtn.MouseButton1Click:Connect(function()
		garageCurrentTab = "GARAGE"
		openModal(garageModal)
	end)
	tradeBtn.MouseButton1Click:Connect(function()
		openModal(tradeModal)
	end)
	shopBtn.MouseButton1Click:Connect(function()
		openModal(shopModal)
	end)
	playBtn.MouseButton1Click:Connect(function()
		doPlayTeleport()
	end)

	-- MODAL CONTAINER
	modalContainer = make("Frame", {
		Name = "ModalContainer",
		Size = UDim2.new(1, 0, 1, 0),
		BackgroundTransparency = 1,
		ZIndex = 20,
		Parent = screenGui,
	})

	local function makeBaseModal(name: string, title: string, subtitle: string): (Frame, TextButton)
		local modal = make("Frame", {
			Name = name,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(0.5, 0, 0.5, 0),
			Size = UDim2.new(0, 860, 0, 520),
			BackgroundColor3 = THEME.BgModal,
			BackgroundTransparency = 0.05,
			BorderSizePixel = 0,
			Visible = false,
			ZIndex = 25,
			Parent = modalContainer,
		})
		addCorner(modal, 14)
		addStroke(modal, THEME.Stroke, THEME.StrokeTrans, 1.5)

		make("TextLabel", {
			Position = UDim2.new(0, 24, 0, 18),
			Size = UDim2.new(0, 450, 0, 24),
			BackgroundTransparency = 1,
			FontFace = Font.fromEnum(Enum.Font.GothamBlack),
			Text = title,
			TextColor3 = THEME.TextPrimary,
			TextSize = 20,
			TextXAlignment = Enum.TextXAlignment.Left,
			Parent = modal,
		})

		make("TextLabel", {
			Position = UDim2.new(0, 24, 0, 44),
			Size = UDim2.new(0, 450, 0, 16),
			BackgroundTransparency = 1,
			FontFace = Font.fromEnum(Enum.Font.GothamMedium),
			Text = subtitle,
			TextColor3 = THEME.TextSecondary,
			TextSize = 12,
			TextXAlignment = Enum.TextXAlignment.Left,
			Parent = modal,
		})

		local closeBtn = make("TextButton", {
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -20, 0, 18),
			Size = UDim2.new(0, 32, 0, 32),
			BackgroundColor3 = Color3.fromRGB(28, 32, 42),
			FontFace = Font.fromEnum(Enum.Font.GothamBold),
			Text = "✕",
			TextColor3 = THEME.TextSecondary,
			TextSize = 15,
			BorderSizePixel = 0,
			Parent = modal,
		})
		addCorner(closeBtn, 8)
		closeBtn.MouseButton1Click:Connect(closeModal)

		return modal, closeBtn
	end

	-- 1. CARDEX MODAL
	cardexModal = makeBaseModal("CardexModal", "CARDEX VEHICLE COMPENDIUM", "All vehicles discovered and yet to be acquired in the world")

	local progressContainer = make("Frame", {
		Position = UDim2.new(0, 24, 0, 70),
		Size = UDim2.new(1, -48, 0, 32),
		BackgroundColor3 = Color3.fromRGB(22, 26, 36),
		BorderSizePixel = 0,
		Parent = cardexModal,
	})
	addCorner(progressContainer, 8)

	cardexCountText = make("TextLabel", {
		Position = UDim2.new(0, 14, 0, 0),
		Size = UDim2.new(0.5, 0, 1, 0),
		BackgroundTransparency = 1,
		FontFace = Font.fromEnum(Enum.Font.GothamBold),
		Text = "COLLECTION: 1 / 5 UNLOCKED (20%)",
		TextColor3 = THEME.Accent,
		TextSize = 12,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = progressContainer,
	})

	local track = make("Frame", {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -14, 0.5, 0),
		Size = UDim2.new(0.42, 0, 0, 10),
		BackgroundColor3 = Color3.fromRGB(36, 42, 58),
		BorderSizePixel = 0,
		Parent = progressContainer,
	})
	addCorner(track, 5)

	cardexProgressBar = make("Frame", {
		Size = UDim2.new(0.2, 0, 1, 0),
		BackgroundColor3 = THEME.Accent,
		BorderSizePixel = 0,
		Parent = track,
	})
	addCorner(cardexProgressBar, 5)

	local filterRow = make("Frame", {
		Position = UDim2.new(0, 24, 0, 112),
		Size = UDim2.new(1, -48, 0, 28),
		BackgroundTransparency = 1,
		Parent = cardexModal,
	})
	make("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		Padding = UDim.new(0, 8),
		Parent = filterRow,
	})

	local filterButtons = {}
	local function addFilterChip(key: string, label: string)
		local chip = make("TextButton", {
			Size = UDim2.new(0, 110, 1, 0),
			BackgroundColor3 = if cardexFilter == key then THEME.Accent else THEME.BgCard,
			FontFace = Font.fromEnum(Enum.Font.GothamBold),
			Text = label,
			TextColor3 = if cardexFilter == key then Color3.fromRGB(255, 255, 255) else THEME.TextSecondary,
			TextSize = 11,
			BorderSizePixel = 0,
			Parent = filterRow,
		})
		addCorner(chip, 6)
		filterButtons[key] = chip

		chip.MouseButton1Click:Connect(function()
			cardexFilter = key
			for k, btn in filterButtons do
				btn.BackgroundColor3 = if k == key then THEME.Accent else THEME.BgCard
				btn.TextColor3 = if k == key then Color3.fromRGB(255, 255, 255) else THEME.TextSecondary
			end
			renderCardexContent()
		end)
	end

	addFilterChip("ALL", "ALL VEHICLES")
	addFilterChip("OBTAINED", "OBTAINED ✓")
	addFilterChip("LOCKED", "LOCKED 🔒")

	cardexCardContainer = make("ScrollingFrame", {
		Position = UDim2.new(0, 24, 0, 148),
		Size = UDim2.new(1, -48, 1, -162),
		BackgroundTransparency = 1,
		ScrollBarThickness = 6,
		ScrollBarImageColor3 = Color3.fromRGB(60, 68, 86),
		BorderSizePixel = 0,
		Parent = cardexModal,
	})

	-- 2. ROBUX SHOP MODAL (ONLY ROBUX ITEMS)
	shopModal = makeBaseModal("ShopModal", "PREMIUM ROBUX STORE", "Acquire currency packs, gamepasses, and permanent multipliers")

	local shopTabRow = make("Frame", {
		Position = UDim2.new(0, 24, 0, 70),
		Size = UDim2.new(1, -48, 0, 32),
		BackgroundTransparency = 1,
		Parent = shopModal,
	})
	make("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		Padding = UDim.new(0, 8),
		Parent = shopTabRow,
	})

	local shopTabBtns = {}
	local function addShopTab(tabKey: string, label: string)
		local tBtn = make("TextButton", {
			Size = UDim2.new(0, 140, 1, 0),
			BackgroundColor3 = if robuxShopCurrentTab == tabKey then THEME.RobuxGreen else THEME.BgCard,
			FontFace = Font.fromEnum(Enum.Font.GothamBold),
			Text = label,
			TextColor3 = if robuxShopCurrentTab == tabKey then Color3.fromRGB(255, 255, 255) else THEME.TextSecondary,
			TextSize = 12,
			BorderSizePixel = 0,
			Parent = shopTabRow,
		})
		addCorner(tBtn, 6)
		shopTabBtns[tabKey] = tBtn

		tBtn.MouseButton1Click:Connect(function()
			robuxShopCurrentTab = tabKey
			for k, b in shopTabBtns do
				b.BackgroundColor3 = if k == tabKey then THEME.RobuxGreen else THEME.BgCard
				b.TextColor3 = if k == tabKey then Color3.fromRGB(255, 255, 255) else THEME.TextSecondary
			end
			renderRobuxShopContent()
		end)
	end

	addShopTab("CASH", "💵 CASH PACKS")
	addShopTab("PASSES", "⚡ GAMEPASSES & PERKS")

	shopContentContainer = make("ScrollingFrame", {
		Position = UDim2.new(0, 24, 0, 114),
		Size = UDim2.new(1, -48, 1, -130),
		BackgroundTransparency = 1,
		ScrollBarThickness = 6,
		ScrollBarImageColor3 = Color3.fromRGB(60, 68, 86),
		BorderSizePixel = 0,
		Parent = shopModal,
	})

	-- 3. GARAGE MODAL (WITH DUAL TABS: MY CARS & IN-GAME DEALERSHIP)
	garageModal = makeBaseModal("GarageModal", "GARAGE & SHOWROOM", "Manage owned vehicles, repaint, or purchase new models with Cash")

	local garageTabRow = make("Frame", {
		Position = UDim2.new(0, 24, 0, 70),
		Size = UDim2.new(1, -48, 0, 32),
		BackgroundTransparency = 1,
		Parent = garageModal,
	})
	make("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		Padding = UDim.new(0, 8),
		Parent = garageTabRow,
	})

	local garageTabBtns = {}
	local function addGarageTab(tabKey: string, label: string)
		local gBtn = make("TextButton", {
			Size = UDim2.new(0, 140, 1, 0),
			BackgroundColor3 = if garageCurrentTab == tabKey then THEME.Accent else THEME.BgCard,
			FontFace = Font.fromEnum(Enum.Font.GothamBold),
			Text = label,
			TextColor3 = if garageCurrentTab == tabKey then Color3.fromRGB(255, 255, 255) else THEME.TextSecondary,
			TextSize = 12,
			BorderSizePixel = 0,
			Parent = garageTabRow,
		})
		addCorner(gBtn, 6)
		garageTabBtns[tabKey] = gBtn

		gBtn.MouseButton1Click:Connect(function()
			garageCurrentTab = tabKey
			for k, b in garageTabBtns do
				b.BackgroundColor3 = if k == tabKey then THEME.Accent else THEME.BgCard
				b.TextColor3 = if k == tabKey then Color3.fromRGB(255, 255, 255) else THEME.TextSecondary
			end
			renderGarageContent()
		end)
	end

	addGarageTab("GARAGE", "🚘 MY VEHICLES")
	addGarageTab("DEALERSHIP", "🏪 DEALERSHIP (CASH)")

	garageBodyFrame = make("Frame", {
		Position = UDim2.new(0, 24, 0, 114),
		Size = UDim2.new(1, -48, 1, -130),
		BackgroundTransparency = 1,
		Parent = garageModal,
	})

	-- 4. TRADE MODAL (player list, or the open trade with both offers side by side)
	tradeModal = makeBaseModal(
		"TradeModal",
		"VEHICLE TRADING FLOOR",
		"Swap cars with another player -- every vehicle keeps the name of whoever first owned it"
	)
	-- Wider and taller than the others: two offer panels and an action bar.
	tradeModal.Size = UDim2.new(0, 900, 0, 580)

	tradeBodyFrame = make("Frame", {
		Position = UDim2.new(0, 24, 0, 78),
		Size = UDim2.new(1, -48, 1, -94),
		BackgroundTransparency = 1,
		Parent = tradeModal,
	})

	-- THE INCOMING REQUEST PROMPT. Above the modals, since answering it is what
	-- opens one, and it has a clock running.
	tradeInviteFrame = make("Frame", {
		Name = "TradeInvitePrompt",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, -180),
		Size = UDim2.new(0, 400, 0, 150),
		BackgroundColor3 = THEME.BgModal,
		BackgroundTransparency = 0.05,
		BorderSizePixel = 0,
		Visible = false,
		ZIndex = 70,
		Parent = screenGui,
	})
	addCorner(tradeInviteFrame, 12)
	addStroke(tradeInviteFrame, THEME.Accent, 0.3, 1.5)

	make("TextLabel", {
		Position = UDim2.new(0, 16, 0, 12),
		Size = UDim2.new(1, -80, 0, 16),
		BackgroundTransparency = 1,
		FontFace = Font.fromEnum(Enum.Font.GothamBlack),
		Text = "🤝 INCOMING TRADE REQUEST",
		TextColor3 = THEME.Accent,
		TextSize = 12,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = tradeInviteFrame,
	})

	tradeInviteTimer = make("TextLabel", {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -16, 0, 12),
		Size = UDim2.new(0, 48, 0, 16),
		BackgroundTransparency = 1,
		FontFace = Font.fromEnum(Enum.Font.GothamBold),
		Text = "30s",
		TextColor3 = THEME.Gold,
		TextSize = 12,
		TextXAlignment = Enum.TextXAlignment.Right,
		Parent = tradeInviteFrame,
	})

	tradeInviteAvatar = make("ImageLabel", {
		Position = UDim2.new(0, 16, 0, 38),
		Size = UDim2.new(0, 52, 0, 52),
		BackgroundColor3 = THEME.BgLocked,
		BorderSizePixel = 0,
		Parent = tradeInviteFrame,
	})
	addCorner(tradeInviteAvatar, 26)

	tradeInviteName = make("TextLabel", {
		Position = UDim2.new(0, 80, 0, 42),
		Size = UDim2.new(1, -96, 0, 20),
		BackgroundTransparency = 1,
		FontFace = Font.fromEnum(Enum.Font.GothamBold),
		Text = "",
		TextColor3 = THEME.TextPrimary,
		TextSize = 15,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = tradeInviteFrame,
	})

	tradeInviteId = make("TextLabel", {
		Position = UDim2.new(0, 80, 0, 64),
		Size = UDim2.new(1, -96, 0, 16),
		BackgroundTransparency = 1,
		FontFace = Font.fromEnum(Enum.Font.GothamMedium),
		Text = "",
		TextColor3 = THEME.TextMuted,
		TextSize = 11,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = tradeInviteFrame,
	})

	local inviteTrack = make("Frame", {
		Position = UDim2.new(0, 16, 0, 98),
		Size = UDim2.new(1, -32, 0, 6),
		BackgroundColor3 = Color3.fromRGB(36, 42, 58),
		BorderSizePixel = 0,
		Parent = tradeInviteFrame,
	})
	addCorner(inviteTrack, 3)

	tradeInviteFill = make("Frame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = THEME.Accent,
		BorderSizePixel = 0,
		Parent = inviteTrack,
	})
	addCorner(tradeInviteFill, 3)

	local acceptBtn = make("TextButton", {
		Position = UDim2.new(0, 16, 0, 112),
		Size = UDim2.new(0.62, -20, 0, 30),
		BackgroundColor3 = THEME.Green,
		FontFace = Font.fromEnum(Enum.Font.GothamBold),
		Text = "✓ OPEN TRADE WINDOW",
		TextColor3 = Color3.fromRGB(255, 255, 255),
		TextSize = 12,
		BorderSizePixel = 0,
		Parent = tradeInviteFrame,
	})
	addCorner(acceptBtn, 6)

	local declineBtn = make("TextButton", {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -16, 0, 112),
		Size = UDim2.new(0.38, -12, 0, 30),
		BackgroundColor3 = Color3.fromRGB(42, 46, 58),
		FontFace = Font.fromEnum(Enum.Font.GothamBold),
		Text = "DECLINE",
		TextColor3 = THEME.TextSecondary,
		TextSize = 12,
		BorderSizePixel = 0,
		Parent = tradeInviteFrame,
	})
	addCorner(declineBtn, 6)

	acceptBtn.MouseButton1Click:Connect(function()
		answerTradeInvite(true)
	end)
	declineBtn.MouseButton1Click:Connect(function()
		answerTradeInvite(false)
	end)

	-- Hotkeys: Escape to close modals, M to toggle menu
	UserInputService.InputBegan:Connect(function(input, processed)
		if processed then
			return
		end
		if input.KeyCode == Enum.KeyCode.Escape then
			closeModal()
		elseif input.KeyCode == Enum.KeyCode.M then
			if currentModal then
				closeModal()
			else
				openModal(cardexModal)
			end
		end
	end)
end

-- Network Sync Listener
local function connectRemotes()
	remotesFolder = ReplicatedStorage:WaitForChild("GameRemotes", 10)
	if not remotesFolder then
		warn("GameUI: GameRemotes folder not found")
		return
	end

	syncRemote = remotesFolder:WaitForChild("PlayerDataSync", 5) :: RemoteEvent
	getDataRemote = remotesFolder:WaitForChild("GetPlayerData", 5) :: RemoteFunction
	buyRemote = remotesFolder:WaitForChild("BuyCar", 5) :: RemoteFunction
	promptPurchaseRemote = remotesFolder:WaitForChild("RequestPurchasePrompt", 5) :: RemoteEvent
	spawnRemote = remotesFolder:WaitForChild("SpawnCar", 5) :: RemoteFunction
	despawnRemote = remotesFolder:WaitForChild("DespawnCar", 5) :: RemoteFunction
	teleportRemote = remotesFolder:WaitForChild("TeleportToPlay", 5) :: RemoteFunction
	notifyRemote = remotesFolder:WaitForChild("Notify", 5) :: RemoteEvent
	tradeRequestRemote = remotesFolder:WaitForChild("TradeRequest", 5) :: RemoteFunction
	tradeRespondRemote = remotesFolder:WaitForChild("TradeRespond", 5) :: RemoteFunction
	tradeActionRemote = remotesFolder:WaitForChild("TradeAction", 5) :: RemoteFunction
	tradeInviteRemote = remotesFolder:WaitForChild("TradeInvite", 5) :: RemoteEvent
	tradeStateRemote = remotesFolder:WaitForChild("TradeState", 5) :: RemoteEvent

	if tradeInviteRemote then
		tradeInviteRemote.OnClientEvent:Connect(function(invite)
			-- nil withdraws the prompt: answered elsewhere, lapsed, or they left.
			if typeof(invite) == "table" and typeof(invite.FromUserId) == "number" then
				showTradeInvite(invite)
			else
				showTradeInvite(nil)
			end
		end)
	end

	if tradeStateRemote then
		tradeStateRemote.OnClientEvent:Connect(function(state)
			tradeSession = if typeof(state) == "table" then state else nil

			if tradeSession and currentModal ~= tradeModal then
				-- A trade has just opened, so put it in front of them.
				showTradeInvite(nil)
				openModal(tradeModal)
			elseif currentModal == tradeModal then
				renderTradeContent()
			end
		end)
	end

	if notifyRemote then
		notifyRemote.OnClientEvent:Connect(function(message, isError)
			if typeof(message) == "string" then
				showToast(message, isError == true)
			end
		end)
	end

	if syncRemote then
		syncRemote.OnClientEvent:Connect(function(data)
			if typeof(data) == "table" then
				localData = data
				updateHUD()
				if currentModal == cardexModal then
					renderCardexContent()
				elseif currentModal == shopModal then
					renderRobuxShopContent()
				elseif currentModal == garageModal then
					renderGarageContent()
				elseif currentModal == tradeModal then
					-- What is left to offer has changed with the garage.
					renderTradeContent()
				end
			end
		end)
	end

	if getDataRemote then
		task.spawn(function()
			local data = getDataRemote:InvokeServer()
			if typeof(data) == "table" then
				localData = data
				updateHUD()
			end
		end)
	end
end

function GameUI.start()
	buildInterface()

	-- Keep the restoration bars, and any trade invite's clock, counting down.
	local sinceBarUpdate = 0
	RunService.Heartbeat:Connect(function(deltaTime)
		sinceBarUpdate += deltaTime
		if sinceBarUpdate >= 0.25 then
			sinceBarUpdate = 0
			if currentModal == garageModal then
				updateRestorationBars()
			end
			if tradeInvite then
				updateTradeInvitePrompt()
			end
		end
	end)

	-- The trader list is only right while those players are still here.
	local function refreshTraderList()
		if currentModal == tradeModal and not tradeSession then
			renderTradeContent()
		end
	end
	Players.PlayerAdded:Connect(refreshTraderList)
	Players.PlayerRemoving:Connect(refreshTraderList)

	-- Hide trade prompt on own character
	local function disableOwnPrompt(char: Model)
		local hrp = char:WaitForChild("HumanoidRootPart", 5)
		if hrp then
			local prompt = hrp:WaitForChild("TradePrompt", 3)
			if prompt and prompt:IsA("ProximityPrompt") then
				prompt.Enabled = false
			end
		end
	end
	if player.Character then
		task.spawn(disableOwnPrompt, player.Character)
	end
	player.CharacterAdded:Connect(disableOwnPrompt)

	connectRemotes()
	updateHUD()
end

return GameUI
