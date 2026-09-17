--[[
	GameUI -- Main Client UI Controller.
	Features:
	- Non-overlapping layout: Cash counter integrated into Left Navigation Dock (safe from Roblox topbar/chat/mic)
	- Robux-Only Shop: Developer Products (Cash Packs) & Gamepasses (2x Cash, VIP, Nitro)
	- Garage with Dual Tabs: "MY CARS" (spawn/customize) & "DEALERSHIP" (buy cars with in-game Cash)
	- Cardex Compendium: Discovered cars vs blacked-out mystery silhouettes with direct Dealership links
	- Play Teleport: Cinematic fade transition to the driving area
	- Restoration Bay: delivered barn finds counting down through retrieval and recuperation
	- Responsive design with smooth tweens and toast notifications
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local CarFolder = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Car")
local CarCatalog = require(CarFolder.CarCatalog)

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

local ROBUX_ITEMS = {
	CashPacks = {
		{ Id = "cash_small", Name = "Small Cash Stash", Cash = 50000, Robux = 49, Icon = "💵", Desc = "Quick boost to start your collection" },
		{ Id = "cash_medium", Name = "High Roller Bag", Cash = 200000, Robux = 149, Icon = "💼", Desc = "Instantly afford top sport supercars" },
		{ Id = "cash_large", Name = "Billionaire Vault", Cash = 1000000, Robux = 499, Icon = "🏦", Desc = "Unlimited luxury and full garage freedom" },
	},
	Passes = {
		{ Id = "pass_2xcash", Name = "2x Cash Multiplier", Robux = 249, Icon = "⚡", Desc = "Permanently double all playtime and driving income" },
		{ Id = "pass_vip", Name = "VIP Elite Pass", Robux = 399, Icon = "👑", Desc = "Golden drift smoke, VIP title, and garage perks" },
		{ Id = "pass_nitro", Name = "Nitro Turbo Boost", Robux = 199, Icon = "🚀", Desc = "Adds instant rocket nitrous boost to every car" },
	}
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
}

local selectedGarageCarId = "Porsche"
local selectedGaragePaint: Color3? = nil
local garageCurrentTab = "GARAGE" -- "GARAGE" or "DEALERSHIP"
local robuxShopCurrentTab = "CASH" -- "CASH" or "PASSES"
local cardexFilter = "ALL"

-- Remotes
local remotesFolder: Folder? = nil
local syncRemote: RemoteEvent? = nil
local buyRemote: RemoteFunction? = nil
local buyRobuxRemote: RemoteFunction? = nil
local spawnRemote: RemoteFunction? = nil
local despawnRemote: RemoteFunction? = nil
local teleportRemote: RemoteFunction? = nil
local getDataRemote: RemoteFunction? = nil
local notifyRemote: RemoteEvent? = nil

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
		for i, item in ROBUX_ITEMS.CashPacks do
			local card = make("Frame", {
				Name = item.Id,
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
				Text = string.format("R$ %d", item.Robux),
				TextColor3 = Color3.fromRGB(255, 255, 255),
				TextSize = 13,
				BorderSizePixel = 0,
				Parent = card,
			})
			addCorner(buyBtn, 6)

			buyBtn.MouseButton1Click:Connect(function()
				if buyRobuxRemote then
					buyBtn.Text = "Processing..."
					local ok, msg = buyRobuxRemote:InvokeServer(item.Id)
					if ok then
						showToast("🎉 " .. msg, false)
						updateHUD()
					else
						showToast(msg or "Purchase failed", true)
					end
					buyBtn.Text = string.format("R$ %d", item.Robux)
				end
			end)
		end
	else
		for i, item in ROBUX_ITEMS.Passes do
			local isOwned = (item.Id == "pass_2xcash" and localData.Has2xCash)
				or (item.Id == "pass_vip" and localData.IsVIP)
				or (item.Id == "pass_nitro" and localData.HasNitro)

			local card = make("Frame", {
				Name = item.Id,
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
				buyBtn.Text = string.format("R$ %d", item.Robux)
				buyBtn.TextColor3 = Color3.fromRGB(255, 255, 255)

				buyBtn.MouseButton1Click:Connect(function()
					if buyRobuxRemote then
						buyBtn.Text = "Processing..."
						local ok, msg = buyRobuxRemote:InvokeServer(item.Id)
						if ok then
							showToast("🎉 " .. msg, false)
							renderRobuxShopContent()
							updateHUD()
						else
							showToast(msg or "Purchase failed", true)
							buyBtn.Text = string.format("R$ %d", item.Robux)
						end
					end
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

		local specBox = make("Frame", {
			Position = UDim2.new(0, 16, 0, 68),
			Size = UDim2.new(1, -32, 0, 88),
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
		Size = UDim2.new(0, 150, 0, 310),
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
	local shopBtn = makeNavButton(5, "ShopBtn", "ROBUX SHOP", "🛍️")
	local playBtn = makeNavButton(6, "PlayBtn", "PLAY", "▶", true)

	cardexBtn.MouseButton1Click:Connect(function()
		openModal(cardexModal)
	end)
	garageBtn.MouseButton1Click:Connect(function()
		garageCurrentTab = "GARAGE"
		openModal(garageModal)
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
	buyRobuxRemote = remotesFolder:WaitForChild("BuyRobuxProduct", 5) :: RemoteFunction
	spawnRemote = remotesFolder:WaitForChild("SpawnCar", 5) :: RemoteFunction
	despawnRemote = remotesFolder:WaitForChild("DespawnCar", 5) :: RemoteFunction
	teleportRemote = remotesFolder:WaitForChild("TeleportToPlay", 5) :: RemoteFunction
	notifyRemote = remotesFolder:WaitForChild("Notify", 5) :: RemoteEvent

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

	-- Keep the restoration bars counting down while the garage is open.
	local sinceBarUpdate = 0
	RunService.Heartbeat:Connect(function(deltaTime)
		sinceBarUpdate += deltaTime
		if sinceBarUpdate >= 0.25 then
			sinceBarUpdate = 0
			if currentModal == garageModal then
				updateRestorationBars()
			end
		end
	end)

	connectRemotes()
	updateHUD()
end

return GameUI
