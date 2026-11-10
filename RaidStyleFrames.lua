-- Uses Blizzard's own CompactUnitFrame, so it looks and follows settings exactly like the raid frames.
-- WoW Forever has secret values (health, auras): our frames run Blizzard's code tainted, and tainted code
-- can't compare secrets. Classic Era (1.15) has issecretvalue but no secret health, so key off the version.
local hasSecrets = select(4, GetBuildInfo()) >= 16000

-- Forever: some units (e.g. a marked enemy, or enemies in an instance) report identity and class as secrets.
-- Blizzard's health color tests them (UnitIsUnit, RAID_CLASS_COLORS[class]), which throws in our tainted frames.
-- On a throw, color by reaction instead (hostile/neutral/friendly); the bar's C API takes secrets.
local function safeColor(f)
	if not hasSecrets then return CompactUnitFrame_UpdateHealthColor(f) end
	if not pcall(CompactUnitFrame_UpdateHealthColor, f) then
		f.healthBar:SetStatusBarColor(UnitSelectionColor(f.unit))
	end
end
-- Health is set before the color throws, so only the color needs redoing
local function safeHealth(f)
	if not hasSecrets then return CompactUnitFrame_UpdateHealth(f) end
	if not pcall(CompactUnitFrame_UpdateHealth, f) then safeColor(f) end
end
-- UpdateAll's steps after health: a throw in the health color aborts all of them.
-- ponytail: mirrors Blizzard's CompactUnitFrame_UpdateAll; re-check if it changes
local AFTER_HEALTH = { "UpdateMaxPower", "UpdatePower", "UpdatePowerColor", "UpdateAggroHighlight", "UpdateAggroFlash",
	"UpdateHealthBorder", "UpdateInRange", "UpdateDistance", "UpdateStatusText", "UpdateHealPrediction", "UpdateRoleIcon",
	"UpdateReadyCheck", "UpdateCenterStatusIcon", "UpdatePlayerLevelDiff", "UpdateWidgetSet", "UpdateLevel" }
local function safeUpdateAll(f)
	if not hasSecrets then return CompactUnitFrame_UpdateAll(f) end
	if pcall(CompactUnitFrame_UpdateAll, f) or not UnitExists(f.displayedUnit) then return end
	pcall(CompactUnitFrame_UpdateMaxHealth, f)
	safeHealth(f)
	for _, name in ipairs(AFTER_HEALTH) do
		local fn = _G["CompactUnitFrame_" .. name]
		if fn then pcall(fn, f) end
	end
end
local update -- defined below; Blizzard's event handler falls back to it

local hidden = CreateFrame("Frame")
hidden:Hide()

-- The raid-group template adds itself to parent.memberUnitFrames, so give it our own parent instead of UIParent
local holder = CreateFrame("Frame", nil, UIParent)
holder:SetAllPoints()

local function create(name, x, y, template)
	local f = CreateFrame("Button", name, holder, template)
	f.groupType = CompactRaidGroupTypeEnum.Party -- size/border/aura layout come from Edit Mode's Party Frames settings
	-- Flat bars: the raid fill textures are shaded at the edges; health/power colors still tint the plain texture
	f.healthBar:SetStatusBarTexture("Interface\\Buttons\\WHITE8x8")
	f.powerBar:SetStatusBarTexture("Interface\\Buttons\\WHITE8x8")
	f.powerBar.background:SetColorTexture(0, 0, 0, 0.8)
	f.background:SetTexture("Interface\\Buttons\\WHITE8x8") -- still tinted by the raid "background color" setting
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

	-- Blizzard's update sets attributes on this secure frame, blocked in combat from our tainted code.
	-- Only the unit changes what it does, so PLAYER_REGEN_ENABLED catches up. Don't wrap Show/Hide this
	-- way: RegisterUnitWatch's secure driver calls them through the frame
	local updatePrivateAuras = f.UpdatePrivateAuras
	f.UpdatePrivateAuras = function(...)
		if not InCombatLockdown() then return updatePrivateAuras(...) end
	end

	if hasSecrets then
		-- Blizzard's own event and OnUpdate handlers on this frame hit the same secrets (see safeColor)
		local onEvent = f:GetScript("OnEvent")
		if onEvent then
			f:SetScript("OnEvent", function(self, ...)
				if not pcall(onEvent, self, ...) then update(self) end
			end)
		end
		-- A custom OnUpdate replaces CompactUnitFrame_OnUpdate (see CompactUnitFrame_CheckNeedsUpdate).
		-- ponytail: it then stays registered every frame instead of only when dirty; cheap for 3 frames
		f.OnUpdate = function(self, elapsed)
			if not pcall(CompactUnitFrame_OnUpdate, self, elapsed) then
				self.healthDirty = false -- health was set before the color threw; don't retry it every frame
				safeColor(self)
				pcall(CompactUnitFrame_OnUpdate, self, elapsed) -- the rest of it
			end
		end
		CompactUnitFrame_CheckNeedsUpdate(f)
	end
	return f
end

-- CompactRaidGroupUnitFrameTemplate = the raid frame with buffs/debuffs (6 buffs, 5 debuffs, same filters as raid)
local player = create("RaidStylePlayerFrame", -250, -150, "CompactRaidGroupUnitFrameTemplate")
local target = create("RaidStyleTargetFrame", 250, -150, "CompactRaidGroupUnitFrameTemplate")
-- ponytail: no auras on target of target, the game sends no aura events for "targettarget"
local tot = create("RaidStyleTargetTargetFrame", 420, -150, "CompactUnitFrameTemplate")
local watched = { [target] = "target", [tot] = "targettarget" }

-- Pulsing yellow glow while resting, like the Blizzard player frame we hide. Raid aggro glow, desaturated and tinted
-- to Blizzard's rest color (PlayerFrame_UpdateStatus)
local restGlow = player:CreateTexture(nil, "OVERLAY")
restGlow:SetAtlas("RaidFrame-AgroFrame")
restGlow:SetAllPoints()
restGlow:SetDesaturated(true)
restGlow:SetVertexColor(1.0, 0.88, 0.25)
restGlow:Hide()
local pulse = restGlow:CreateAnimationGroup()
pulse:SetLooping("BOUNCE")
local fade = pulse:CreateAnimation("Alpha")
fade:SetFromAlpha(1)
fade:SetToAlpha(0.15)
fade:SetDuration(0.5)
local function updateResting()
	local resting = IsResting()
	restGlow:SetShown(resting)
	if resting then pulse:Play() else pulse:Stop() end
end

-- Own option tables with no re-layout on every update: the default re-layout calls SetSize,
-- which is blocked in combat on addon frames, and would put the in-frame debuffs back
local function makeSetup(options)
	-- Read through to Blizzard's live raid options (filled from CVars like "Display Class Colors" after load),
	-- a copy made now would miss them
	setmetatable(options, { __index = function(_, k)
		local v = DefaultCompactUnitFrameOptions[k]
		-- "perc" and "losthealth" do math on secret health; fall back to the plain number
		if hasSecrets and k == "healthText" and (v == "perc" or v == "losthealth") then return "health" end
		return v
	end })
	options.updateAllSetupFunc = false -- false, not nil, so it doesn't fall through to Blizzard's
	options.fadeOutOfRange = false -- UnitInRange is secret on Forever, and only works for group members anyway
	-- The target highlight tests UnitIsUnit(unit, "target"), secret on Forever. Our target frame is always the target anyway
	if hasSecrets then options.displaySelectionHighlight = false end
	return function(frame)
		DefaultCompactUnitFrameSetup(frame)
		frame.updateAllSetupFunc = nil -- Forever keeps the re-layout on the frame (Era on the option table above)
		CompactUnitFrame_SetOptionTable(frame, options)
		-- Always show power: the raid "Display Power Bars" setting (per character, off by default) shouldn't hide it here.
		-- ponytail: mirrors DefaultCompactUnitFrameSetup's power bar layout; re-check if Blizzard changes it
		if frame.powerBar and not frame.powerBar:IsShown() then
			local border = EditModeManagerFrame:ShouldRaidFrameDisplayBorder(frame.groupType)
			frame.powerBar:GetStatusBarTexture():SetDrawLayer("BORDER")
			frame.powerBar:SetPoint("TOPLEFT", frame.healthBar, "BOTTOMLEFT", 0, border and -2 or 0)
			frame.powerBar:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -1, 1)
			frame.powerBar:Show()
			frame.powerBarUsedHeight = 8
			frame.healthBar:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -1, 9)
			frame.TempMaxHealthLoss:SetShouldAdjustHealthBarAnchor(-1, 9)
			frame:SetPowerBarUsedHeight(8) -- buffs sit above the power bar
			frame:UpdatePrivateAuras(true)
		end
		if hasSecrets then
			-- Heal prediction compares secret health before checking any option; "max 0" makes it bail out early.
			-- ponytail: no incoming-heal/absorb overlay on Forever; would need UnitHealPredictionCalculator to add back
			frame.healthBar.GetMinMaxValues = function() return 0, 0 end
			-- Bailing early also skips Blizzard's hiding of the heal/absorb textures, which are shown by default:
			-- the over-absorb glows sit on both ends of the health bar
			for _, key in ipairs({ "myHealPrediction", "otherHealPrediction", "totalAbsorb", "totalAbsorbOverlay", "TotalAbsorbLeftShadow",
				"overAbsorbGlow", "myHealAbsorb", "myHealAbsorbOverlay", "myHealAbsorbLeftShadow", "myHealAbsorbRightShadow", "overHealAbsorbGlow" }) do
				if frame[key] then frame[key]:Hide() end
			end
		end
		-- auras go in our own rows instead, so they can be placed inside/below/above
		CompactUnitFrame_SetMaxDebuffs(frame, 0)
		CompactUnitFrame_SetMaxBuffs(frame, 0)
	end
end
local playerSetup = makeSetup({})
-- Target: raid coloring (class or custom color for friends, red for anything else), but never class-color NPCs
local targetSetup = makeSetup({ allowClassColorsForNPCs = false })

-- Recolor when "Display Class Colors" or its color pickers change; next frame so Blizzard has updated its options first
local function recolor()
	C_Timer.After(0, function()
		for _, f in ipairs({ player, target, tot }) do
			if f.unit and UnitExists(f.unit) then safeColor(f) end
		end
	end)
end
for _, cvar in ipairs({ "raidFramesDisplayClassColor", "raidFramesHealthBarColor", "raidFramesHealthBarColorBG" }) do
	CVarCallbackRegistry:RegisterCallback(cvar, recolor, cvar) -- owner per cvar: one owner can only hold one callback per event
end

-- Buff and debuff rows, placed inside, below or above the frame (Blizzard's aura layout is fixed inside)
local MAX_AURAS, GAP = 8, 3
local function iconParts(b)
	local border = b:CreateTexture(nil, "BACKGROUND")
	border:SetPoint("TOPLEFT", -1, 1)
	border:SetPoint("BOTTOMRIGHT", 1, -1)
	border:SetColorTexture(0, 0, 0) -- debuffs get tinted per type
	local icon = b:CreateTexture(nil, "ARTWORK")
	icon:SetAllPoints()
	icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	local count = b:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
	count:SetPoint("BOTTOMRIGHT", 2, -1)
	return border, icon, count
end

local AURA_GROUP = "auras"
local function addRow(f, key, filter)
	local row = CreateFrame("Frame", nil, f)
	row:SetFrameLevel(f:GetFrameLevel() + 5) -- over the health bar when inside
	row.key, row.filter, row.max = key, filter, MAX_AURAS
	if hasSecrets then
		-- Forever: in combat, addons can't read auras at all (every C_UnitAuras read throws while tainted).
		-- This container is Blizzard's addon-facing way around that: secure code reads them and fills our buttons
		row.container = CreateFrame("AuraContainer", nil, row, "CustomAuraContainerTemplate")
		row.container:SetPoint("TOPLEFT")
		row.container:AddAuraGroup(AURA_GROUP, filter, {
			maxFrameCount = MAX_AURAS,
			initializeFrame = function(b)
				local size = row.size or 22
				b:SetSize(size, size)
				local border, icon, count = iconParts(b)
				b:SetIcon(icon)
				b:SetApplicationCount(count)
				-- Same 1px rectangle as border, drawn above it and tinted per type by the game
				local dispel = b:CreateTexture(nil, "BORDER")
				dispel:SetAllPoints(border)
				dispel:SetTexture("Interface\\Buttons\\WHITE8x8")
				b:AddDispelTypeTexture(dispel, { style = Enum.CustomAuraButtonDispelTypeTextureStyle.PreserveAsset })
			end,
		})
		row.container:SetEnabled(true)
	else
		for i = 1, MAX_AURAS do
			local b = CreateFrame("Frame", nil, row)
			b.border, b.icon, b.count = iconParts(b)
			b:EnableMouse(true)
			b:SetScript("OnEnter", function(self)
				GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
				GameTooltip:SetUnitAura(f.unit, self.index, filter)
			end)
			b:SetScript("OnLeave", GameTooltip_Hide)
			b:Hide()
			row[i] = b
		end
	end
	f.auraRows = f.auraRows or {}
	table.insert(f.auraRows, row)
end

local function updateAuras(f)
	for _, row in ipairs(f.auraRows) do
		if row.container then -- keeps itself current on UNIT_AURA, this covers unit changes
			if f.unit then
				row.container:SetUnit(f.unit)
				row.container:UpdateAllAuras()
			end
		else
			for i, b in ipairs(row) do
				local aura = i <= row.max and f.unit and C_UnitAuras.GetAuraDataByIndex(f.unit, i, row.filter)
				if aura then
					b.index = i
					b.icon:SetTexture(aura.icon)
					b.count:SetText(aura.applications > 1 and aura.applications or "")
					if row.filter == "HARMFUL" then
						AuraUtil.SetAuraBorderColor(b.border, aura.dispelName) -- same colors as Blizzard's target debuffs
					end
					b:Show()
				else
					b:Hide()
				end
			end
		end
	end
end

-- Rows sharing a position stack as separate lines: buffs nearest the frame, then debuffs
local function layout(f)
	local lines = { inside = 0, below = 0, above = 0 }
	for _, row in ipairs(f.auraRows) do
		local pos = RaidStyleFramesDB[row.key .. "Pos"]
		row:SetShown(RaidStyleFramesDB[row.key])
		if row:IsShown() then
			local n = lines[pos]
			lines[pos] = n + 1
			local size, gap = RaidStyleFramesDB.iconSize, GAP
			row.max = MAX_AURAS
			row:ClearAllPoints()
			if pos == "inside" then -- as many as fit across
				size, gap = RaidStyleFramesDB.iconSizeInside, 1
				row.max = min(MAX_AURAS, floor((f:GetWidth() - 6 + gap) / (size + gap)))
				row:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 3, 2 + (f.powerBarUsedHeight or 0) + n * (size + gap))
			elseif pos == "above" then
				row:SetPoint("BOTTOMLEFT", f, "TOPLEFT", 1, gap + n * (size + gap))
			else
				row:SetPoint("TOPLEFT", f, "BOTTOMLEFT", 1, -gap - n * (size + gap))
			end
			row:SetSize(1, size)
			row.size = size
			if row.container then
				row.container:SetAuraGroupMaxFrameCount(AURA_GROUP, row.max)
				row.container:SetAuraGroupLayout(AURA_GROUP, { elementSpacing = gap, elementWidth = size, elementHeight = size })
				-- ponytail: the buttons are locked in combat; an icon size changed mid-fight applies on the next refresh
				if not InCombatLockdown() then
					for i = 1, row.container:GetAuraGroupFrameCount(AURA_GROUP) do
						row.container:GetAuraGroupFrame(AURA_GROUP, i):SetSize(size, size)
					end
				end
			end
			for i, b in ipairs(row) do
				b:SetSize(size, size)
				b:SetPoint("TOPLEFT", row, "TOPLEFT", (i - 1) * (size + gap), 0)
			end
		end
	end
end

-- Raid target marker (skull, cross...) straddling the top edge, like Blizzard's target frame.
-- Own frame so it draws over the health bar
local marker = CreateFrame("Frame", nil, target)
marker:SetFrameLevel(target:GetFrameLevel() + 6)
marker:SetSize(18, 18)
marker:SetPoint("CENTER", target, "TOP", 0, 0)
marker.icon = marker:CreateTexture(nil, "OVERLAY")
marker.icon:SetAllPoints()
marker.icon:SetTexture("Interface\\TargetingFrame\\UI-RaidTargetingIcons")
local function updateMarker()
	local index = UnitExists(target.unit) and GetRaidTargetIndex(target.unit)
	-- Forever: a marked target's index is secret and can't be tested (no marker is plain nil),
	-- but the sprite sheet takes secrets, so a secret just means "marked"
	local isSecret = hasSecrets and issecretvalue(index)
	if isSecret or index then SetRaidTargetIconTexture(marker.icon, index) end
	marker:SetShown(isSecret or index and true or false)
end

-- Target level in the top-right corner, colored like Blizzard's target frame
target.level = target:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
target.level:SetPoint("TOPRIGHT", -3, -3)
local function updateLevel()
	local unit, text = target.unit
	target.level:SetShown(RaidStyleFramesDB.level and UnitExists(unit))
	if target.level:IsShown() then
		local level = UnitLevel(unit)
		local elite = UnitClassification(unit)
		local color = UNIT_LEVEL_NON_ATTACKABLE
		if UnitCanAttack("player", unit) then color = GetCreatureDifficultyColor(level > 0 and level or 999) end
		text = (level > 0 and level or "??") .. ((elite == "elite" or elite == "rareelite" or elite == "worldboss") and "+" or "")
		target.level:SetText(text)
		target.level:SetTextColor(color.r, color.g, color.b)
	end
	-- Keep the name clear of it (only the default layout anchors the name to the right edge)
	if EditModeManagerFrame:GetRaidFrameAuraOrganizationType(target.groupType) == Enum.RaidAuraOrganizationType.Legacy then
		if target.level:IsShown() then
			target.name:SetPoint("TOPRIGHT", target.level, "TOPLEFT", -2, 0)
		else
			target.name:SetPoint("TOPRIGHT", -3, -3)
		end
	end
	updateMarker() -- same refresh points: target change, edit mode, options
end

local function refresh()
	for _, f in ipairs({ player, target }) do
		layout(f)
		updateAuras(f)
	end
	updateLevel()
end

for _, f in ipairs({ player, target }) do
	addRow(f, "buffs", "HELPFUL")
	addRow(f, "debuffs", "HARMFUL")
end

-- UpdateAll calls Show/Hide, blocked in combat on these secure frames ("Interface action failed because of an AddOn").
-- RegisterUnitWatch handles visibility anyway, so in combat refresh only what shows the unit's state
function update(f)
	if not InCombatLockdown() then
		safeUpdateAll(f)
	elseif UnitExists(f.displayedUnit) then
		CompactUnitFrame_UpdateMaxHealth(f)
		safeHealth(f) -- also updates the name and health color
		CompactUnitFrame_UpdateMaxPower(f)
		CompactUnitFrame_UpdatePower(f)
		CompactUnitFrame_UpdatePowerColor(f)
		CompactUnitFrame_UpdateStatusText(f)
		CompactUnitFrame_UpdateCenterStatusIcon(f)
	end
end

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
	-- "targettarget" has no events; poll like CompactUnitFrame_SetUpdateAllOnUpdate, but combat-safe
	CreateFrame("Frame"):SetScript("OnUpdate", function() update(tot) end)

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
	updateAuras(target)
	updateLevel()
end, player)
EventRegistry:RegisterCallback("EditMode.Exit", function()
	player.editHighlight:Hide()
	for f, unit in pairs(watched) do
		f.editHighlight:Hide()
		CompactUnitFrame_SetUnit(f, unit)
		RegisterUnitWatch(f)
	end
	updateAuras(target)
	updateLevel()
end, player)

-- Options in Esc > Options > AddOns
local function createOptions()
	RaidStyleFramesDB = RaidStyleFramesDB or {}
	local category = Settings.RegisterVerticalLayoutCategory("Raid Style Frames")
	local function add(key, varType, name, default, tooltip, options)
		if RaidStyleFramesDB[key] == nil then RaidStyleFramesDB[key] = default end
		local setting = Settings.RegisterAddOnSetting(category, "RaidStyleFrames_" .. key, key, RaidStyleFramesDB, varType, name, default)
		setting:SetValueChangedCallback(refresh)
		if varType == "number" then
			Settings.CreateSlider(category, setting, options, tooltip)
		elseif options then
			Settings.CreateDropdown(category, setting, options, tooltip)
		else
			Settings.CreateCheckbox(category, setting, tooltip)
		end
	end
	local function positions()
		local c = Settings.CreateControlTextContainer()
		c:Add("inside", "Inside")
		c:Add("below", "Below")
		c:Add("above", "Above")
		return c:GetData()
	end
	add("buffs", "boolean", "Show buffs", true, "Buff icons on the player and target frames.")
	add("buffsPos", "string", "Buff position", "inside", "Where buffs go. Sharing a position with debuffs puts them on separate lines.", positions)
	add("debuffs", "boolean", "Show debuffs", true, "Debuff icons on the player and target frames.")
	add("debuffsPos", "string", "Debuff position", "below", "Where debuffs go. Sharing a position with buffs puts them on separate lines.", positions)
	local function sizes(min, max)
		local o = Settings.CreateSliderOptions(min, max, 1)
		o:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right)
		return o
	end
	add("level", "boolean", "Show target level", true, "Level on the target frame, colored by difficulty. \"+\" means elite.")
	add("iconSizeInside", "number", "Icon size (inside)", 11, "Size of buffs/debuffs placed inside the frame.", sizes(8, 30))
	add("iconSize", "number", "Icon size (outside)", 22, "Size of buffs/debuffs placed below or above the frame.", sizes(12, 48))
	Settings.RegisterAddOnCategory(category)
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:SetScript("OnEvent", function(self, event, unit)
	if event == "PLAYER_LOGIN" then createOptions() end
	if event == "UNIT_AURA" then
		updateAuras(player)
		updateAuras(target)
		return
	end
	if event == "UNIT_LEVEL" then
		updateLevel()
		return
	end
	if event == "RAID_TARGET_UPDATE" then
		updateMarker()
		return
	end
	if event == "PLAYER_UPDATE_RESTING" then
		updateResting()
		return
	end
	if event == "PLAYER_TARGET_CHANGED" then
		if target.unit == "target" then
			update(target)
			target:UpdatePrivateAuras(true) -- aura display only listens to UNIT_AURA, so rebuild it for the new target
			updateAuras(target)
			updateLevel()
		end
		return
	end
	if event == "PLAYER_REGEN_ENABLED" and target.unit then -- set up already: catch up on what combat skipped
		target:UpdatePrivateAuras(true)
		return
	end
	if InCombatLockdown() then -- /reload mid-combat: protected frames can't change yet
		self:RegisterEvent("PLAYER_REGEN_ENABLED")
		return
	end
	self:UnregisterAllEvents()
	setup()
	self:RegisterEvent("PLAYER_TARGET_CHANGED") -- compact frames don't refresh on a new target by themselves
	if not hasSecrets then self:RegisterUnitEvent("UNIT_AURA", "player", "target") end
	self:RegisterUnitEvent("UNIT_LEVEL", "player", "target") -- player too: the color is relative to your level
	self:RegisterEvent("RAID_TARGET_UPDATE")
	self:RegisterEvent("PLAYER_UPDATE_RESTING")
	self:RegisterEvent("PLAYER_REGEN_ENABLED")
	refresh()
	updateResting()
end)
