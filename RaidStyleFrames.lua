-- Uses Blizzard's own CompactUnitFrame, so it looks and follows settings exactly like the raid frames.
local hidden = CreateFrame("Frame")
hidden:Hide()

local function create(name, x, y)
	local f = CreateFrame("Button", name, UIParent, "CompactUnitFrameTemplate")
	f.groupType = CompactRaidGroupTypeEnum.Raid -- size/border come from the raid frame settings
	f:SetPoint("CENTER", UIParent, "CENTER", x, y) -- default spot; ignored once user-placed
	f:SetMovable(true)
	f:SetClampedToScreen(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", function(self)
		if (IsShiftKeyDown() or EditModeManagerFrame:IsEditModeActive()) and not InCombatLockdown() then self:StartMoving() end
	end)
	f:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		self:SetUserPlaced(true) -- ponytail: client layout cache saves position, no SavedVariables needed
	end)

	-- Blue highlight while in Edit Mode, like Blizzard's movable frames
	f.editHighlight = f:CreateTexture(nil, "OVERLAY")
	f.editHighlight:SetAllPoints()
	f.editHighlight:SetColorTexture(0.2, 0.6, 1, 0.35)
	f.editHighlight:Hide()
	return f
end

local player = create("RaidStylePlayerFrame", -250, -150)
local target = create("RaidStyleTargetFrame", 250, -150)

-- Target: color NPCs by reaction (red/yellow/green) instead of their class
local targetOptions = CopyTable(DefaultCompactUnitFrameOptions)
targetOptions.allowClassColorsForNPCs = false
targetOptions.colorHealthBySelection = true
-- No re-layout on every update: it calls SetSize, which is blocked in combat on addon frames
targetOptions.updateAllSetupFunc = nil
local function targetSetup(frame)
	DefaultCompactUnitFrameSetup(frame)
	CompactUnitFrame_SetOptionTable(frame, targetOptions)
end

local function setup()
	CompactUnitFrame_SetUpFrame(player, DefaultCompactUnitFrameSetup)
	CompactUnitFrame_SetUnit(player, "player")
	player:Show()
	PlayerFrame:UnregisterAllEvents()
	PlayerFrame:SetParent(hidden)

	CompactUnitFrame_SetUpFrame(target, targetSetup)
	CompactUnitFrame_SetUnit(target, "target")
	RegisterUnitWatch(target) -- secure show/hide when a target exists
	TargetFrame:UnregisterAllEvents()
	TargetFrame:SetParent(hidden)
	if ComboFrame then -- keep rogue/druid combo points, they lived on the old target frame
		ComboFrame:SetParent(target)
		ComboFrame:ClearAllPoints()
		ComboFrame:SetPoint("BOTTOMRIGHT", target, "TOPRIGHT", 0, 2)
	end
end

EventRegistry:RegisterCallback("EditMode.Enter", function()
	player.editHighlight:Show()
	target.editHighlight:Show()
	-- preview yourself in the target frame so it can be moved without a target
	UnregisterUnitWatch(target)
	CompactUnitFrame_SetUnit(target, "player")
	target:Show()
end, player)
EventRegistry:RegisterCallback("EditMode.Exit", function()
	player.editHighlight:Hide()
	target.editHighlight:Hide()
	CompactUnitFrame_SetUnit(target, "target")
	RegisterUnitWatch(target)
end, player)

local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:SetScript("OnEvent", function(self, event)
	if event == "PLAYER_TARGET_CHANGED" then
		if target.unit == "target" then CompactUnitFrame_UpdateAll(target) end
		return
	end
	if InCombatLockdown() then -- /reload mid-combat: protected frames can't change yet
		self:RegisterEvent("PLAYER_REGEN_ENABLED")
		return
	end
	self:UnregisterAllEvents()
	setup()
	self:RegisterEvent("PLAYER_TARGET_CHANGED") -- compact frames don't refresh on a new target by themselves
end)
