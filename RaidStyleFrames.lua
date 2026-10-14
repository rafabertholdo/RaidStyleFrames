-- Uses Blizzard's own CompactUnitFrame, so it looks and follows settings exactly like the raid frames.
local hidden = CreateFrame("Frame")
hidden:Hide()

-- The raid-group template adds itself to parent.memberUnitFrames, so give it our own parent instead of UIParent
local holder = CreateFrame("Frame", nil, UIParent)
holder:SetAllPoints()

local function create(name, x, y, template)
	local f = CreateFrame("Button", name, holder, template)
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

-- CompactRaidGroupUnitFrameTemplate = the raid frame with buffs/debuffs (6 buffs, 5 debuffs, same filters as raid)
local player = create("RaidStylePlayerFrame", -250, -150, "CompactRaidGroupUnitFrameTemplate")
local target = create("RaidStyleTargetFrame", 250, -150, "CompactRaidGroupUnitFrameTemplate")
-- ponytail: no auras on target of target, the game sends no aura events for "targettarget"
local tot = create("RaidStyleTargetTargetFrame", 420, -150, "CompactUnitFrameTemplate")
local watched = { [target] = "target", [tot] = "targettarget" }

-- Own option tables with no re-layout on every update: the default re-layout calls SetSize,
-- which is blocked in combat on addon frames, and would put the in-frame debuffs back
local function makeSetup(options)
	options.updateAllSetupFunc = nil
	return function(frame)
		DefaultCompactUnitFrameSetup(frame)
		CompactUnitFrame_SetOptionTable(frame, options)
		CompactUnitFrame_SetMaxDebuffs(frame, 0) -- debuffs go in our row below the frame instead
	end
end
local playerSetup = makeSetup(CopyTable(DefaultCompactUnitFrameOptions))
-- Target: color NPCs by reaction (red/yellow/green) instead of their class
local targetOptions = CopyTable(DefaultCompactUnitFrameOptions)
targetOptions.allowClassColorsForNPCs = false
targetOptions.colorHealthBySelection = true
local targetSetup = makeSetup(targetOptions)

-- Debuff row below the frame (Blizzard's aura layout is fixed inside the frame)
local MAX_DEBUFFS, ICON = 8, 22
local function addDebuffRow(f)
	f.debuffs = {}
	for i = 1, MAX_DEBUFFS do
		local b = CreateFrame("Frame", nil, f)
		b:SetSize(ICON, ICON)
		b:SetPoint("TOPLEFT", f, "BOTTOMLEFT", (i - 1) * (ICON + 3) + 1, -3)
		b.border = b:CreateTexture(nil, "BACKGROUND")
		b.border:SetPoint("TOPLEFT", -1, 1)
		b.border:SetPoint("BOTTOMRIGHT", 1, -1)
		b.border:SetColorTexture(1, 1, 1) -- tinted per debuff type
		b.icon = b:CreateTexture(nil, "ARTWORK")
		b.icon:SetAllPoints()
		b.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
		b.cd = CreateFrame("Cooldown", nil, b, "CooldownFrameTemplate")
		b.cd:SetAllPoints()
		b.cd:SetHideCountdownNumbers(true) -- swipe only, numbers cover the tiny icons
		b.count = b.cd:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall") -- on the cooldown so the swipe doesn't cover it
		b.count:SetPoint("BOTTOMRIGHT", 2, -1)
		b:EnableMouse(true)
		b:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
			GameTooltip:SetUnitDebuff(f.unit, self.index)
		end)
		b:SetScript("OnLeave", GameTooltip_Hide)
		b:Hide()
		f.debuffs[i] = b
	end
end

local function updateDebuffs(f)
	for i, b in ipairs(f.debuffs) do
		local aura = f.unit and C_UnitAuras.GetAuraDataByIndex(f.unit, i, "HARMFUL")
		if aura then
			b.index = i
			b.icon:SetTexture(aura.icon)
			b.count:SetText(aura.applications > 1 and aura.applications or "")
			AuraUtil.SetAuraBorderColor(b.border, aura.dispelName) -- same colors as Blizzard's target debuffs
			CooldownFrame_Set(b.cd, aura.expirationTime - aura.duration, aura.duration, aura.duration > 0, true)
			b:Show()
		else
			b:Hide()
		end
	end
end
addDebuffRow(player)
addDebuffRow(target)

local function setup()
	CompactUnitFrame_SetUpFrame(player, playerSetup)
	CompactUnitFrame_SetUnit(player, "player")
	player:Show()
	PlayerFrame:UnregisterAllEvents()
	PlayerFrame:SetParent(hidden)

	for f, unit in pairs(watched) do
		CompactUnitFrame_SetUpFrame(f, targetSetup)
		CompactUnitFrame_SetUnit(f, unit)
		RegisterUnitWatch(f) -- secure show/hide when the unit exists
	end
	-- "targettarget" has no events; Blizzard's own fix for this is polling UpdateAll
	CompactUnitFrame_SetUpdateAllOnUpdate(tot, true)

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
	-- preview yourself in the target frames so they can be moved without a target
	for f in pairs(watched) do
		f.editHighlight:Show()
		UnregisterUnitWatch(f)
		CompactUnitFrame_SetUnit(f, "player")
		f:Show()
	end
	updateDebuffs(target)
end, player)
EventRegistry:RegisterCallback("EditMode.Exit", function()
	player.editHighlight:Hide()
	for f, unit in pairs(watched) do
		f.editHighlight:Hide()
		CompactUnitFrame_SetUnit(f, unit)
		RegisterUnitWatch(f)
	end
	updateDebuffs(target)
end, player)

local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:SetScript("OnEvent", function(self, event, unit)
	if event == "UNIT_AURA" then
		updateDebuffs(player)
		updateDebuffs(target)
		return
	end
	if event == "PLAYER_TARGET_CHANGED" then
		if target.unit == "target" then
			CompactUnitFrame_UpdateAll(target)
			target:UpdatePrivateAuras(true) -- aura display only listens to UNIT_AURA, so rebuild it for the new target
			updateDebuffs(target)
		end
		return
	end
	if InCombatLockdown() then -- /reload mid-combat: protected frames can't change yet
		self:RegisterEvent("PLAYER_REGEN_ENABLED")
		return
	end
	self:UnregisterAllEvents()
	setup()
	self:RegisterEvent("PLAYER_TARGET_CHANGED") -- compact frames don't refresh on a new target by themselves
	self:RegisterUnitEvent("UNIT_AURA", "player", "target")
	updateDebuffs(player)
	updateDebuffs(target)
end)
