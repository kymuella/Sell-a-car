--[[
	CharacterVisibility -- hides a character completely while they sit in a car,
	so no arm, hat or hairdo pokes through the bodywork, and puts them back
	exactly as they were when they get out.

	It runs on the server, so every player sees the same thing. Every part, decal
	and effect in the character is hidden, including accessories that finish
	loading while they are seated, and each one's own value is kept in an
	attribute so showing them again restores it rather than guessing.
]]

local CharacterVisibility = {}

local TRANSPARENCY = "CarHiddenTransparency"
local ENABLED = "CarHiddenEnabled"

local watching: { [Model]: { RBXScriptConnection } } = {}

local function isEffect(instance: Instance): boolean
	return instance:IsA("ParticleEmitter")
		or instance:IsA("Trail")
		or instance:IsA("Beam")
		or instance:IsA("Fire")
		or instance:IsA("Smoke")
		or instance:IsA("Sparkles")
end

local function hideOne(instance: Instance)
	-- Decal covers Texture too.
	if instance:IsA("BasePart") or instance:IsA("Decal") then
		if instance:GetAttribute(TRANSPARENCY) == nil then
			instance:SetAttribute(TRANSPARENCY, instance.Transparency)
		end
		instance.Transparency = 1
	elseif isEffect(instance) then
		local effect = instance :: any
		if instance:GetAttribute(ENABLED) == nil then
			instance:SetAttribute(ENABLED, effect.Enabled)
		end
		effect.Enabled = false
	end
end

local function showOne(instance: Instance)
	local transparency = instance:GetAttribute(TRANSPARENCY)
	if typeof(transparency) == "number" and (instance:IsA("BasePart") or instance:IsA("Decal")) then
		instance.Transparency = transparency
	end
	local enabled = instance:GetAttribute(ENABLED)
	if typeof(enabled) == "boolean" and isEffect(instance) then
		(instance :: any).Enabled = enabled
	end
	instance:SetAttribute(TRANSPARENCY, nil)
	instance:SetAttribute(ENABLED, nil)
end

local function stopWatching(character: Model)
	local connections = watching[character]
	if connections then
		for _, connection in connections do
			connection:Disconnect()
		end
		watching[character] = nil
	end
end

function CharacterVisibility.hide(character: Instance?)
	if not (character and character:IsA("Model")) then
		return
	end

	for _, descendant in character:GetDescendants() do
		hideOne(descendant)
	end

	if not watching[character] then
		watching[character] = {
			character.DescendantAdded:Connect(hideOne),
			character.Destroying:Connect(function()
				stopWatching(character)
			end),
		}
	end
end

function CharacterVisibility.show(character: Instance?)
	if not (character and character:IsA("Model")) then
		return
	end

	stopWatching(character)
	for _, descendant in character:GetDescendants() do
		showOne(descendant)
	end
end

return CharacterVisibility
