-- Uses Blizzard's own CompactUnitFrame, so it looks and follows settings exactly like the raid frames.
-- WoW Forever has secret values (health, auras): our frames run Blizzard's code tainted, and tainted code
-- can't compare secrets. Classic Era (1.15) has issecretvalue but no secret health, so key off the version.
local hasSecrets = select(4, GetBuildInfo()) >= 16000
local hidden = CreateFrame("Frame")
hidden:Hide()

-- The raid-group template adds itself to parent.memberUnitFrames, so give it our own parent instead of UIParent
local holder = CreateFrame("Frame", nil, UIParent)
holder:SetAllPoints()

local function create(name, x, y, template)
	local f = CreateFrame("Button", name, holder, template)
	f.groupType = CompactRaidGroupTypeEnum.Raid -- size/border come from the raid frame settings
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
			if f.unit and UnitExists(f.unit) then CompactUnitFrame_UpdateHealthColor(f) end
		end
	end)
end
for _, cvar in ipairs({ "raidFramesDisplayClassColor", "raidFramesHealthBarColor", "raidFramesHealthBarColorBG" }) do
	CVarCallbackRegistry:RegisterCallback(cvar, recolor, cvar) -- owner per cvar: one owner can only hold one callback per event
end

-- Buff and debuff rows, placed inside, below or above the frame (Blizzard's aura layout is fixed inside)
local MAX_AURAS, GAP = 8, 3
local function addRow(f, key, filter)
	local row = CreateFrame("Frame", nil, f)
	row:SetFrameLevel(f:GetFrameLevel() + 5) -- over the health bar when inside
	row.key, row.filter, row.max = key, filter, MAX_AURAS
	for i = 1, MAX_AURAS do
		local b = CreateFrame("Frame", nil, row)
		b.border = b:CreateTexture(nil, "BACKGROUND")
		b.border:SetPoint("TOPLEFT", -1, 1)
		b.border:SetPoint("BOTTOMRIGHT", 1, -1)
		b.border:SetColorTexture(0, 0, 0) -- debuffs get tinted per type
		b.icon = b:CreateTexture(nil, "ARTWORK")
		b.icon:SetAllPoints()
		b.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
		b.count = b:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
		b.count:SetPoint("BOTTOMRIGHT", 2, -1)
		b:EnableMouse(true)
		b:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
			GameTooltip:SetUnitAura(f.unit, self.index, filter)
		end)
		b:SetScript("OnLeave", GameTooltip_Hide)
		b:Hide()
		row[i] = b
	end
	f.auraRows = f.auraRows or {}
	table.insert(f.auraRows, row)
end

local function updateAuras(f)
	for _, row in ipairs(f.auraRows) do
		for i, b in ipairs(row) do
			-- pcall: Forever throws (instead of returning secrets) for units whose auras addons may not read, like enemies
			local ok, aura = i <= row.max and f.unit and pcall(C_UnitAuras.GetAuraDataByIndex, f.unit, i, row.filter)
			aura = ok and aura
			if aura then
				b.index = i
				b.icon:SetTexture(aura.icon)
				if hasSecrets then -- secret-safe: returns "" below 2 stacks
					b.count:SetText(C_UnitAuras.GetAuraApplicationDisplayCount(f.unit, aura.auraInstanceID))
				else
					b.count:SetText(aura.applications > 1 and aura.applications or "")
				end
				if row.filter == "HARMFUL" then
					-- ponytail: black border when the type is secret; C_UnitAuras.GetAuraDispelTypeColor + a color curve if that matters
					AuraUtil.SetAuraBorderColor(b.border, not (hasSecrets and issecretvalue(aura.dispelName)) and aura.dispelName or nil) -- same colors as Blizzard's target debuffs
				end
				b:Show()
			else
				b:Hide()
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
			for i, b in ipairs(row) do
				b:SetSize(size, size)
				b:SetPoint("TOPLEFT", row, "TOPLEFT", (i - 1) * (size + gap), 0)
			end
		end
	end
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
	if event == "PLAYER_TARGET_CHANGED" then
		if target.unit == "target" then
			CompactUnitFrame_UpdateAll(target)
			target:UpdatePrivateAuras(true) -- aura display only listens to UNIT_AURA, so rebuild it for the new target
			updateAuras(target)
			updateLevel()
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
	self:RegisterUnitEvent("UNIT_LEVEL", "player", "target") -- player too: the color is relative to your level
	refresh()
end)
