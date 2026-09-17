--[[
	GameUI -- Main Client UI Controller.
	Provides:
	- Navigation HUD Dock (Cardex, Shop, Garage, Play, Cash Pill)
	- Cardex Compendium (Obtained vs Blacked-Out Silhouette Locked Cars)
	- Dealership / Shop (Browse & Purchase vehicles)
	- Garage (Manage owned cars, custom paint palette, spawn/despawn)
	- Play (Cinematic screen-fade teleport to playing area)
	- Toast notification system
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local CarFolder = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Car")
local CarCatalog = require(CarFolder.CarCatalog)

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local GameUI = {}

-- UI Color Theme
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
}

local selectedGarageCarId = "Porsche"
local selectedGaragePaint: Color3? = nil

-- Remotes
local remotesFolder: Folder? = nil
local syncRemote: RemoteEvent? = nil
local buyRemote: RemoteFunction? = nil
local spawnRemote: RemoteFunction? = nil
local despawnRemote: RemoteFunction? = nil
local teleportRemote: RemoteFunction? = nil
local getDataRemote: RemoteFunction? = nil

-- GUI References
local screenGui: ScreenGui
local cashTextLabel: TextLabel
local cardexBadge: TextLabel
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
local cardexFilter = "ALL"
local shopCardContainer: ScrollingFrame
local garageListContainer: ScrollingFrame
local garageDetailContainer: Frame

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
	if cashTextLabel then
		cashTextLabel.Text = formatCash(localData.Cash)
	end

	if cardexBadge then
		local allCars = CarCatalog.getAll()
		local discovered = 0
		for _, car in allCars do
			if localData.CardexDiscovered[car.Id] then
				discovered += 1
			end
		end
		cardexBadge.Text = string.format("%d/%d", discovered, #allCars)
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
local renderShopContent: () -> ()
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
		renderShopContent()
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

	-- Fade to black
	fadeOverlay.Visible = true
	fadeOverlay.BackgroundTransparency = 1
	local fadeOut = TweenService:Create(fadeOverlay, TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		BackgroundTransparency = 0,
	})
	fadeOut:Play()
	fadeOut.Completed:Wait()

	-- Teleport request on server
	if teleportRemote then
		local ok, msg = teleportRemote:InvokeServer()
		if ok then
			showToast("Teleported to Playing Area! 🏁", false)
		else
			showToast(msg or "Could not teleport", true)
		end
	end

	task.wait(0.3)

	-- Fade back in
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

	local grid = make("UIGridLayout", {
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
			-- UNLOCKED CARD (Full details and vibrant styling)
			local topBar = make("Frame", {
				Size = UDim2.new(1, 0, 0, 5),
				BackgroundColor3 = car.AccentColor,
				BorderSizePixel = 0,
				Parent = card,
			})
			addCorner(topBar, 5)

			-- Tier Badge
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

			-- Obtained Checkmark Badge
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

			-- Vehicle Name
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

			-- Subtitle
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

			-- Stat bars container
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

			addStatRow(0, "Top Speed", string.format("%d studs/s", car.TopSpeed), car.TopSpeed / 200)
			addStatRow(28, "Acceleration", tostring(car.Acceleration), car.Acceleration / 140)
			addStatRow(56, "Cornering Grip", tostring(car.Grip), car.Grip / 15)

			-- Drivetrain tag
			make("TextLabel", {
				Position = UDim2.new(0, 12, 1, -32),
				Size = UDim2.new(1, -24, 0, 20),
				BackgroundTransparency = 1,
				FontFace = Font.fromEnum(Enum.Font.GothamMedium),
				Text = string.format("Powertrain: %s • Fully Discovered", car.DriveType),
				TextColor3 = THEME.TextMuted,
				TextSize = 10,
				TextXAlignment = Enum.TextXAlignment.Center,
				Parent = card,
			})
		else
			-- LOCKED CARD (Blacked-out silhouette styling!)
			local silhouetteBox = make("Frame", {
				Position = UDim2.new(0, 10, 0, 10),
				Size = UDim2.new(1, -20, 1, -20),
				BackgroundColor3 = Color3.fromRGB(7, 8, 11),
				BorderSizePixel = 0,
				Parent = card,
			})
			addCorner(silhouetteBox, 8)
			addStroke(silhouetteBox, Color3.fromRGB(30, 32, 42), 0.5)

			-- Lock icon in the middle
			local lockIcon = make("TextLabel", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.new(0.5, 0, 0.35, 0),
				Size = UDim2.new(0, 56, 0, 56),
				BackgroundTransparency = 1,
				FontFace = Font.fromEnum(Enum.Font.GothamBold),
				Text = "🔒",
				TextSize = 42,
				TextColor3 = THEME.TextMuted,
				Parent = silhouetteBox,
			})

			-- Mystery title
			make("TextLabel", {
				Position = UDim2.new(0, 8, 0, 118),
				Size = UDim2.new(1, -16, 0, 22),
				BackgroundTransparency = 1,
				FontFace = Font.fromEnum(Enum.Font.GothamBlack),
				Text = "??? [LOCKED]",
				TextColor3 = Color3.fromRGB(110, 115, 128),
				TextSize = 14,
				TextXAlignment = Enum.TextXAlignment.Center,
				Parent = silhouetteBox,
			})

			-- Tier hint
			make("TextLabel", {
				Position = UDim2.new(0, 8, 0, 142),
				Size = UDim2.new(1, -16, 0, 16),
				BackgroundTransparency = 1,
				FontFace = Font.fromEnum(Enum.Font.GothamMedium),
				Text = string.format("Unknown %s Class", car.Tier),
				TextColor3 = Color3.fromRGB(70, 75, 88),
				TextSize = 11,
				TextXAlignment = Enum.TextXAlignment.Center,
				Parent = silhouetteBox,
			})

			-- Obscured specs
			make("TextLabel", {
				Position = UDim2.new(0, 8, 0, 164),
				Size = UDim2.new(1, -16, 0, 16),
				BackgroundTransparency = 1,
				FontFace = Font.fromEnum(Enum.Font.GothamMedium),
				Text = "Speed: ??? • Grip: ???",
				TextColor3 = Color3.fromRGB(55, 60, 72),
				TextSize = 10,
				TextXAlignment = Enum.TextXAlignment.Center,
				Parent = silhouetteBox,
			})

			-- Shortcut to find in Shop
			local shopBtn = make("TextButton", {
				Position = UDim2.new(0.1, 0, 1, -34),
				Size = UDim2.new(0.8, 0, 0, 26),
				BackgroundColor3 = Color3.fromRGB(24, 28, 38),
				FontFace = Font.fromEnum(Enum.Font.GothamBold),
				Text = "Find in Shop →",
				TextColor3 = THEME.Accent,
				TextSize = 11,
				BorderSizePixel = 0,
				Parent = silhouetteBox,
			})
			addCorner(shopBtn, 5)
			addStroke(shopBtn, THEME.Accent, 0.7)

			shopBtn.MouseButton1Click:Connect(function()
				openModal(shopModal)
			end)
		end
	end
end

-- Shop Content Renderer
function renderShopContent()
	if not shopCardContainer then
		return
	end
	shopCardContainer:ClearAllChildren()

	local allCars = CarCatalog.getAll()
	make("UIGridLayout", {
		CellSize = UDim2.new(0, 240, 0, 270),
		CellPadding = UDim2.new(0, 14, 0, 14),
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = shopCardContainer,
	})

	for i, car in allCars do
		local isOwned = localData.OwnedCars[car.Id] == true
		local canAfford = localData.Cash >= car.Price

		local card = make("Frame", {
			Name = car.Id,
			BackgroundColor3 = THEME.BgCard,
			BorderSizePixel = 0,
			LayoutOrder = i,
			Parent = shopCardContainer,
		})
		addCorner(card, 10)
		addStroke(card, THEME.Stroke, THEME.StrokeTrans)

		-- Top accent stripe
		local bar = make("Frame", {
			Size = UDim2.new(1, 0, 0, 4),
			BackgroundColor3 = car.AccentColor,
			BorderSizePixel = 0,
			Parent = card,
		})
		addCorner(bar, 4)

		-- Tier tag
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

		-- Price tag
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

		-- Vehicle Name
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

		-- Description snippet
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

		-- Specs list
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

		specLine(6, "Top Speed", string.format("%d studs/s", car.TopSpeed))
		specLine(30, "Acceleration", tostring(car.Acceleration))
		specLine(54, "Cornering Grip", tostring(car.Grip))
		specLine(78, "Drive Type", car.DriveType)

		-- Buy Action Button
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
			actionBtn.Text = "OWNED ✓"
			actionBtn.TextColor3 = THEME.Green
			actionBtn.MouseButton1Click:Connect(function()
				selectedGarageCarId = car.Id
				openModal(garageModal)
			end)
		elseif canAfford then
			actionBtn.BackgroundColor3 = THEME.Accent
			actionBtn.Text = if car.Price == 0 then "CLAIM FREE" else "PURCHASE"
			actionBtn.TextColor3 = Color3.fromRGB(255, 255, 255)

			actionBtn.MouseButton1Click:Connect(function()
				if buyRemote then
					actionBtn.Text = "Purchasing..."
					local ok, msg = buyRemote:InvokeServer(car.Id)
					if ok then
						showToast("🎉 " .. msg, false)
						renderShopContent()
						updateHUD()
					else
						showToast(msg or "Purchase failed", true)
						renderShopContent()
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

-- Garage Content Renderer
function renderGarageContent()
	if not garageListContainer or not garageDetailContainer then
		return
	end
	garageListContainer:ClearAllChildren()
	garageDetailContainer:ClearAllChildren()

	local allCars = CarCatalog.getAll()
	local ownedList = {}
	for _, car in allCars do
		if localData.OwnedCars[car.Id] then
			table.insert(ownedList, car)
		end
	end

	if #ownedList == 0 then
		make("TextLabel", {
			Size = UDim2.new(1, 0, 1, 0),
			BackgroundTransparency = 1,
			FontFace = Font.fromEnum(Enum.Font.GothamBold),
			Text = "No vehicles in your garage yet!
Visit the Shop to acquire vehicles.",
			TextColor3 = THEME.TextSecondary,
			TextSize = 14,
			Parent = garageListContainer,
		})
		return
	end

	-- Verify selected car is owned
	if not localData.OwnedCars[selectedGarageCarId] then
		selectedGarageCarId = ownedList[1].Id
	end

	local listLayout = make("UIListLayout", {
		Padding = UDim.new(0, 10),
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = garageListContainer,
	})

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
			Parent = garageListContainer,
		})
		addCorner(item, 8)
		addStroke(item, if isSelected then THEME.Accent else THEME.Stroke, if isSelected then 0.2 else THEME.StrokeTrans, if isSelected then 2 else 1)

		-- Left color indicator
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
			Text = string.format("%s Class • %d studs/s", car.Tier, car.TopSpeed),
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

	-- RIGHT DETAIL PANEL FOR SELECTED CAR
	local currentCar = CarCatalog.get(selectedGarageCarId) or ownedList[1]
	if not selectedGaragePaint then
		selectedGaragePaint = currentCar.DefaultColor
	end

	-- Title
	make("TextLabel", {
		Position = UDim2.new(0, 16, 0, 16),
		Size = UDim2.new(1, -32, 0, 24),
		BackgroundTransparency = 1,
		FontFace = Font.fromEnum(Enum.Font.GothamBlack),
		Text = currentCar.DisplayName,
		TextColor3 = THEME.TextPrimary,
		TextSize = 18,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = garageDetailContainer,
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
		Parent = garageDetailContainer,
	})

	-- Detailed Specs Grid
	local specBox = make("Frame", {
		Position = UDim2.new(0, 16, 0, 68),
		Size = UDim2.new(1, -32, 0, 90),
		BackgroundColor3 = Color3.fromRGB(18, 22, 30),
		BorderSizePixel = 0,
		Parent = garageDetailContainer,
	})
	addCorner(specBox, 8)
	addStroke(specBox, THEME.Stroke, THEME.StrokeTrans)

	local function addBoxSpec(col: number, row: number, name: string, val: string)
		local x = col == 1 and 16 or 0.52
		local y = row == 1 and 12 or 50
		make("TextLabel", {
			Position = UDim2.new(x, 0, 0, y),
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
			Position = UDim2.new(x, 0, 0, y + 16),
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

	addBoxSpec(1, 1, "Top Speed", string.format("%d studs/s", currentCar.TopSpeed))
	addBoxSpec(2, 1, "Acceleration", tostring(currentCar.Acceleration))
	addBoxSpec(1, 2, "Cornering Grip", tostring(currentCar.Grip))
	addBoxSpec(2, 2, "Drivetrain", currentCar.DriveType)

	-- Paint Customizer Header
	make("TextLabel", {
		Position = UDim2.new(0, 16, 0, 172),
		Size = UDim2.new(1, -32, 0, 18),
		BackgroundTransparency = 1,
		FontFace = Font.fromEnum(Enum.Font.GothamBold),
		Text = "CUSTOMIZE PAINT COLOR",
		TextColor3 = THEME.TextSecondary,
		TextSize = 12,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = garageDetailContainer,
	})

	-- Swatch palette
	local swatchesFrame = make("Frame", {
		Position = UDim2.new(0, 16, 0, 196),
		Size = UDim2.new(1, -32, 0, 48),
		BackgroundTransparency = 1,
		Parent = garageDetailContainer,
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
			Size = UDim2.new(0, 36, 0, 36),
			BackgroundColor3 = preset.Color,
			BorderSizePixel = 0,
			Text = "",
			Parent = swatchesFrame,
		})
		addCorner(swatch, 18)
		local swatchStroke = addStroke(swatch, if isCurrentColor then Color3.fromRGB(255, 255, 255) else Color3.fromRGB(0, 0, 0), if isCurrentColor then 0 else 0.5, if isCurrentColor then 3 else 1)

		swatch.MouseButton1Click:Connect(function()
			selectedGaragePaint = preset.Color
			renderGarageContent()
		end)
	end

	-- Action Buttons: SPAWN & DESPAWN
	local spawnBtn = make("TextButton", {
		Position = UDim2.new(0, 16, 1, -50),
		Size = UDim2.new(0.68, -20, 0, 38),
		BackgroundColor3 = THEME.Accent,
		FontFace = Font.fromEnum(Enum.Font.GothamBold),
		Text = "🚗 SPAWN VEHICLE",
		TextColor3 = Color3.fromRGB(255, 255, 255),
		TextSize = 13,
		BorderSizePixel = 0,
		Parent = garageDetailContainer,
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
		Position = UDim2.new(0.68, 4, 1, -50),
		Size = UDim2.new(0.32, -20, 0, 38),
		BackgroundColor3 = Color3.fromRGB(42, 46, 58),
		FontFace = Font.fromEnum(Enum.Font.GothamBold),
		Text = "🗑️ STORE",
		TextColor3 = THEME.TextSecondary,
		TextSize = 12,
		BorderSizePixel = 0,
		Parent = garageDetailContainer,
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
end

-- Build the Full Screen GUI
local function buildInterface()
	screenGui = make("ScreenGui", {
		Name = "MainGameGui",
		ResetOnSpawn = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		IgnoreGuiInset = true,
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
		Size = UDim2.new(0, 340, 0, 42),
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

	-- TOP CASH PILL
	local cashPill = make("Frame", {
		Name = "CashPill",
		Position = UDim2.new(0, 24, 0, 24),
		Size = UDim2.new(0, 165, 0, 42),
		BackgroundColor3 = THEME.BgCard,
		BorderSizePixel = 0,
		ZIndex = 10,
		Parent = screenGui,
	})
	addCorner(cashPill, 21)
	addStroke(cashPill, THEME.Stroke, THEME.StrokeTrans)

	local coinIcon = make("TextLabel", {
		Position = UDim2.new(0, 12, 0.5, -12),
		Size = UDim2.new(0, 24, 0, 24),
		BackgroundTransparency = 1,
		FontFace = Font.fromEnum(Enum.Font.GothamBlack),
		Text = "💵",
		TextSize = 18,
		Parent = cashPill,
	})

	cashTextLabel = make("TextLabel", {
		Position = UDim2.new(0, 42, 0, 0),
		Size = UDim2.new(1, -52, 1, 0),
		BackgroundTransparency = 1,
		FontFace = Font.fromEnum(Enum.Font.GothamBlack),
		Text = "$0",
		TextColor3 = THEME.Gold,
		TextSize = 15,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = cashPill,
	})

	-- LEFT NAVIGATION DOCK
	local navDock = make("Frame", {
		Name = "NavDock",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 24, 0.5, 0),
		Size = UDim2.new(0, 140, 0, 260),
		BackgroundColor3 = THEME.BgModal,
		BackgroundTransparency = 0.15,
		BorderSizePixel = 0,
		ZIndex = 10,
		Parent = screenGui,
	})
	addCorner(navDock, 14)
	addStroke(navDock, THEME.Stroke, THEME.StrokeTrans)

	local navList = make("UIListLayout", {
		Padding = UDim.new(0, 8),
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		Parent = navDock,
	})

	local function makeNavButton(name: string, label: string, icon: string, isPrimary: boolean?): (TextButton, TextLabel?)
		local btn = make("TextButton", {
			Name = name,
			Size = UDim2.new(0, 120, 0, 46),
			BackgroundColor3 = if isPrimary then THEME.Accent else THEME.BgCard,
			BorderSizePixel = 0,
			Text = "",
			AutoButtonColor = true,
			Parent = navDock,
		})
		addCorner(btn, 10)
		addStroke(btn, if isPrimary then THEME.Accent else THEME.Stroke, if isPrimary then 0.3 else THEME.StrokeTrans)

		-- Icon
		make("TextLabel", {
			Position = UDim2.new(0, 10, 0.5, -12),
			Size = UDim2.new(0, 24, 0, 24),
			BackgroundTransparency = 1,
			FontFace = Font.fromEnum(Enum.Font.GothamBold),
			Text = icon,
			TextSize = 18,
			Parent = btn,
		})

		-- Label
		make("TextLabel", {
			Position = UDim2.new(0, 38, 0, 0),
			Size = UDim2.new(1, -44, 1, 0),
			BackgroundTransparency = 1,
			FontFace = Font.fromEnum(Enum.Font.GothamBold),
			Text = label,
			TextColor3 = if isPrimary then Color3.fromRGB(255, 255, 255) else THEME.TextPrimary,
			TextSize = 13,
			TextXAlignment = Enum.TextXAlignment.Left,
			Parent = btn,
		})

		local badge: TextLabel? = nil
		if name == "CardexBtn" then
			badge = make("TextLabel", {
				AnchorPoint = Vector2.new(1, 0.5),
				Position = UDim2.new(1, -8, 0.5, 0),
				Size = UDim2.new(0, 28, 0, 18),
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

	local cardexBtn, badge = makeNavButton("CardexBtn", "CARDEX", "🗂️")
	cardexBadge = badge
	local shopBtn = makeNavButton("ShopBtn", "SHOP", "🛍️")
	local garageBtn = makeNavButton("GarageBtn", "GARAGE", "🚘")
	local playBtn = makeNavButton("PlayBtn", "PLAY", "▶", true)

	cardexBtn.MouseButton1Click:Connect(function()
		openModal(cardexModal)
	end)
	shopBtn.MouseButton1Click:Connect(function()
		openModal(shopModal)
	end)
	garageBtn.MouseButton1Click:Connect(function()
		openModal(garageModal)
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
			Size = UDim2.new(0, 840, 0, 520),
			BackgroundColor3 = THEME.BgModal,
			BackgroundTransparency = 0.05,
			BorderSizePixel = 0,
			Visible = false,
			ZIndex = 25,
			Parent = modalContainer,
		})
		addCorner(modal, 14)
		addStroke(modal, THEME.Stroke, THEME.StrokeTrans, 1.5)

		-- Header
		make("TextLabel", {
			Position = UDim2.new(0, 24, 0, 18),
			Size = UDim2.new(0, 400, 0, 24),
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
			Size = UDim2.new(0, 400, 0, 16),
			BackgroundTransparency = 1,
			FontFace = Font.fromEnum(Enum.Font.GothamMedium),
			Text = subtitle,
			TextColor3 = THEME.TextSecondary,
			TextSize = 12,
			TextXAlignment = Enum.TextXAlignment.Left,
			Parent = modal,
		})

		-- Close Button
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

	-- 1. BUILD CARDEX MODAL
	cardexModal = makeBaseModal("CardexModal", "CARDEX VEHICLE COMPENDIUM", "All vehicles discovered and yet to be acquired in the world")

	-- Progress Bar Header Container
	local progressContainer = make("Frame", {
		Position = UDim2.new(0, 24, 0, 72),
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

	-- Filter Buttons (ALL, OBTAINED, LOCKED)
	local filterRow = make("Frame", {
		Position = UDim2.new(0, 24, 0, 114),
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
			Size = UDim2.new(0, 100, 1, 0),
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

	-- Scrolling Grid for Cardex
	cardexCardContainer = make("ScrollingFrame", {
		Position = UDim2.new(0, 24, 0, 150),
		Size = UDim2.new(1, -48, 1, -165),
		BackgroundTransparency = 1,
		ScrollBarThickness = 6,
		ScrollBarImageColor3 = Color3.fromRGB(60, 68, 86),
		BorderSizePixel = 0,
		Parent = cardexModal,
	})

	-- 2. BUILD SHOP MODAL
	shopModal = makeBaseModal("ShopModal", "VEHICLE DEALERSHIP", "Browse and purchase showroom cars with your earned cash")

	shopCardContainer = make("ScrollingFrame", {
		Position = UDim2.new(0, 24, 0, 80),
		Size = UDim2.new(1, -48, 1, -95),
		BackgroundTransparency = 1,
		ScrollBarThickness = 6,
		ScrollBarImageColor3 = Color3.fromRGB(60, 68, 86),
		BorderSizePixel = 0,
		Parent = shopModal,
	})

	-- 3. BUILD GARAGE MODAL
	garageModal = makeBaseModal("GarageModal", "MY GARAGE", "Inspect, customize paint, and spawn your vehicles into the world")

	garageListContainer = make("ScrollingFrame", {
		Position = UDim2.new(0, 24, 0, 80),
		Size = UDim2.new(0.35, 0, 1, -95),
		BackgroundTransparency = 1,
		ScrollBarThickness = 5,
		ScrollBarImageColor3 = Color3.fromRGB(60, 68, 86),
		BorderSizePixel = 0,
		Parent = garageModal,
	})

	garageDetailContainer = make("Frame", {
		Position = UDim2.new(0.38, 0, 0, 80),
		Size = UDim2.new(0.62, -24, 1, -95),
		BackgroundColor3 = THEME.BgCard,
		BorderSizePixel = 0,
		Parent = garageModal,
	})
	addCorner(garageDetailContainer, 10)
	addStroke(garageDetailContainer, THEME.Stroke, THEME.StrokeTrans)

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
	spawnRemote = remotesFolder:WaitForChild("SpawnCar", 5) :: RemoteFunction
	despawnRemote = remotesFolder:WaitForChild("DespawnCar", 5) :: RemoteFunction
	teleportRemote = remotesFolder:WaitForChild("TeleportToPlay", 5) :: RemoteFunction

	if syncRemote then
		syncRemote.OnClientEvent:Connect(function(data)
			if typeof(data) == "table" then
				localData = data
				updateHUD()
				if currentModal == cardexModal then
					renderCardexContent()
				elseif currentModal == shopModal then
					renderShopContent()
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
	connectRemotes()
	updateHUD()
end

return GameUI
