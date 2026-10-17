--[[
	World Quest Board - Panel
	The quest list shown beside the world map.

	Legion 7.3.5 world map notes (from the 7.3.5 FrameXML):
	* WorldMapFrame has two modes. Windowed: parent UIParent, strata HIGH, border
	  702x534 (992 wide with the quest log). Fullscreen: no parent, strata FULLSCREEN,
	  covers the screen, border 1022x766 centred at the top. The panel is a child of
	  WorldMapFrame (so it opens/closes and scales with the map) and is re-anchored to
	  WorldMapFrame.BorderFrame whenever the mode changes (WorldMap_ToggleSizeUp/Down).
	* In fullscreen mode there is usually no room beside the map, so by default the
	  panel overlays the right edge of the map instead. Its strata is one step above
	  the map's so world quest pins (frame level up to ~1500) cannot cover it.
	* Quest pins live in WorldMapPOIFrame, sized like the visible map; a position is
	  (x * width, -y * height) from its TOPLEFT. Our highlight marker uses the same
	  frame, so it follows map zoom/pan.
	* Blizzard's own WorldMapPing_StartPingQuest(questID) pings a quest pin; we call it
	  in addition to drawing our marker (the pin may be hidden by Blizzard's map filters).
	* Tracking uses the raw AddWorldQuestWatch/RemoveWorldQuestWatch API. The objective
	  tracker refreshes itself from QUEST_WATCH_LIST_CHANGED, so no Blizzard tracker
	  function is called from addon code (avoids tainting the tracker).
]]
local ADDON_NAME, ns = ...
local SafeCall = ns.SafeCall
local Data = ns.Data

local Panel = {}
ns.Panel = Panel

local PANEL_WIDTH = 330
local TOOLBAR_TOP = -28
local FILTER_ROWS = 5 -- 4 rows of reward types + the pet battle toggle
local FILTER_ROW_HEIGHT = 20
local FILTER_BOX_HEIGHT = FILTER_ROWS * FILTER_ROW_HEIGHT + 28
local HEADER_HEIGHT = 20
local ROW_HEIGHT = 32
local ICON_SIZE = 26
local TEXT_LEFT = 8 + ICON_SIZE + 8  -- left edge of the row text
local RIGHT_COLUMN_MAX = 86           -- time / zone column
local ZONE_GROUP_ICON = "Interface\\Icons\\INV_Misc_Map_01"
local PET_BATTLE_ICON = "Interface\\Icons\\Tracking_WildPet"
local DOCK_GAP = 2
local FULLSCREEN_OVERLAY_TOP = -66
local FULLSCREEN_HEIGHT_REDUCTION = 100
local MARKER_SECONDS = 10
local REFRESH_INTERVAL = 60
local PENDING_RETRY_DELAY = 2
local PENDING_RETRY_LIMIT = 6

local NEXT_STRATA = {
	BACKGROUND = "LOW", LOW = "MEDIUM", MEDIUM = "HIGH", HIGH = "DIALOG",
	DIALOG = "FULLSCREEN", FULLSCREEN = "FULLSCREEN_DIALOG",
	FULLSCREEN_DIALOG = "FULLSCREEN_DIALOG", TOOLTIP = "TOOLTIP",
}

local TYPE_TAGS = {}
if LE_QUEST_TAG_TYPE_PVP then TYPE_TAGS[LE_QUEST_TAG_TYPE_PVP] = "PvP" end
if LE_QUEST_TAG_TYPE_PET_BATTLE then TYPE_TAGS[LE_QUEST_TAG_TYPE_PET_BATTLE] = "Pet Battle" end
if LE_QUEST_TAG_TYPE_PROFESSION then TYPE_TAGS[LE_QUEST_TAG_TYPE_PROFESSION] = "Profession" end
if LE_QUEST_TAG_TYPE_DUNGEON then TYPE_TAGS[LE_QUEST_TAG_TYPE_DUNGEON] = "Dungeon" end
if LE_QUEST_TAG_TYPE_RAID then TYPE_TAGS[LE_QUEST_TAG_TYPE_RAID] = "Raid" end
if LE_QUEST_TAG_TYPE_INVASION then TYPE_TAGS[LE_QUEST_TAG_TYPE_INVASION] = "Invasion" end

local CHECKMARK = "|TInterface\\RaidFrame\\ReadyCheck-Ready:12:12|t"
local GOLD_ICON = "|TInterface\\MoneyFrame\\UI-GoldIcon:0:0:2:0|t"
local CRITICAL_MINUTES = WORLD_QUESTS_TIME_CRITICAL_MINUTES or 15

local function GetMapMode()
	if WorldMapFrame_InWindowedMode and WorldMapFrame_InWindowedMode() then
		return "windowed"
	end
	return "fullscreen"
end

local function PlayClickSound()
	if SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON then
		PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
	end
end

---------------------------------------------------------------------------
-- Sorting
---------------------------------------------------------------------------
local function ByTime(a, b)
	local ta, tb = a.expiresAt or math.huge, b.expiresAt or math.huge
	if ta ~= tb then
		return ta < tb
	end
	return a.questID < b.questID
end

local SORTERS = {
	time = ByTime,
	zone = function(a, b)
		if a.zoneName ~= b.zoneName then
			return (a.zoneName or "") < (b.zoneName or "")
		end
		return ByTime(a, b)
	end,
	reward = function(a, b)
		local va, vb = a.mainAmount or -1, b.mainAmount or -1
		if va ~= vb then
			return va > vb
		end
		return ByTime(a, b)
	end,
	name = function(a, b)
		if a.title ~= b.title then
			return (a.title or "") < (b.title or "")
		end
		return a.questID < b.questID
	end,
}

local function Comparator(mode)
	local sorter = SORTERS[mode] or ByTime
	return function(a, b)
		if a.completed ~= b.completed then
			return not a.completed -- completed quests sink to the bottom of their category
		end
		return sorter(a, b)
	end
end

---------------------------------------------------------------------------
-- Widgets
---------------------------------------------------------------------------
local function CreateSmallButton(parent, width, text)
	local button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
	button:SetSize(width, 20)
	button:SetNormalFontObject("GameFontNormalSmall")
	button:SetHighlightFontObject("GameFontHighlightSmall")
	button:SetDisabledFontObject("GameFontDisableSmall")
	button:SetText(text)
	return button
end

local function SetSimpleTooltip(frame, title, text)
	frame:SetScript("OnEnter", function(self)
		local tip = WorldMapTooltip or GameTooltip
		tip:SetOwner(self, "ANCHOR_TOP")
		tip:SetText(title)
		if text then
			tip:AddLine(text, 1, 1, 1, true)
		end
		tip:Show()
	end)
	frame:SetScript("OnLeave", function()
		(WorldMapTooltip or GameTooltip):Hide()
	end)
end

local function CreateHeader(parent)
	local header = CreateFrame("Button", nil, parent)
	header:SetHeight(HEADER_HEIGHT)

	header.background = header:CreateTexture(nil, "BACKGROUND")
	header.background:SetAllPoints()
	header.background:SetColorTexture(0, 0, 0, 0.45)

	header.expand = header:CreateTexture(nil, "ARTWORK")
	header.expand:SetSize(14, 14)
	header.expand:SetPoint("LEFT", 3, 0)

	header.icon = header:CreateTexture(nil, "ARTWORK")
	header.icon:SetSize(16, 16)
	header.icon:SetPoint("LEFT", header.expand, "RIGHT", 4, 0)
	header.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

	header.count = header:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	header.count:SetPoint("RIGHT", -6, 0)

	header.total = header:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	header.total:SetPoint("RIGHT", header.count, "LEFT", -8, 0)

	header.label = header:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	header.label:SetPoint("LEFT", header.icon, "RIGHT", 6, 0)
	header.label:SetPoint("RIGHT", header.total, "LEFT", -6, 0)
	header.label:SetJustifyH("LEFT")
	header.label:SetWordWrap(false)

	header:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
	header:SetScript("OnClick", function(self)
		Panel:ToggleGroup(self.groupKey)
	end)
	return header
end

local function CreateRow(parent)
	local row = CreateFrame("Button", nil, parent)
	row:SetHeight(ROW_HEIGHT)
	row:RegisterForClicks("LeftButtonUp")

	row.selected = row:CreateTexture(nil, "BACKGROUND")
	row.selected:SetAllPoints()
	row.selected:SetColorTexture(1, 0.82, 0, 0.15)
	row.selected:Hide()

	-- Thin left edge in the quest's rarity colour (rare and epic world quests only).
	row.rarity = row:CreateTexture(nil, "ARTWORK")
	row.rarity:SetWidth(2)
	row.rarity:SetPoint("TOPLEFT", 1, -3)
	row.rarity:SetPoint("BOTTOMLEFT", 1, 3)

	row.icon = row:CreateTexture(nil, "ARTWORK")
	row.icon:SetSize(ICON_SIZE, ICON_SIZE)
	row.icon:SetPoint("LEFT", 8, 0)
	row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

	-- Amount shown on the icon: item level, reward amount or stack size.
	row.iconText = row:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
	row.iconText:SetPoint("BOTTOMRIGHT", row.icon, "BOTTOMRIGHT", 3, -2)

	-- Right column: time left, with the zone underneath.
	row.time = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	row.time:SetJustifyH("RIGHT")
	row.time:SetWordWrap(false)
	row.zone = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	row.zone:SetJustifyH("RIGHT")
	row.zone:SetWordWrap(false)

	row.bounty = row:CreateTexture(nil, "ARTWORK")
	row.bounty:SetSize(14, 14)

	-- Left column: what the quest rewards, plus an optional line of tags.
	row.text = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	row.text:SetJustifyH("LEFT")
	row.text:SetWordWrap(false)
	row.tags = row:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	row.tags:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", TEXT_LEFT, 4)
	row.tags:SetJustifyH("LEFT")
	row.tags:SetWordWrap(false)

	row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
	row:SetScript("OnClick", function(self, button)
		Panel:OnRowClick(self, button)
	end)
	row:SetScript("OnEnter", function(self)
		Panel:ShowQuestTooltip(self)
	end)
	row:SetScript("OnLeave", function()
		Panel:HideTooltip()
	end)
	-- WorldMapTooltip calls owner:UpdateTooltip() every 0.2 s; rebuild only when the
	-- compare key (Shift) changes, so holding Shift shows the equipped-item comparison.
	row.UpdateTooltip = function(self)
		local compare = (IsModifiedClick("COMPAREITEMS") or GetCVarBool("alwaysCompareItems")) and true or false
		if Panel.tooltipOwner == self and compare ~= Panel.tooltipCompare then
			Panel:ShowQuestTooltip(self)
		end
	end
	return row
end

---------------------------------------------------------------------------
-- Construction
---------------------------------------------------------------------------
function Panel:Init()
	if self.frame or not (WorldMapFrame and WorldMapFrame.BorderFrame) then
		return
	end
	self:CreatePanel()
	self:CreateMapButton()
	self:CreateMarker()
	ns.Skin:ApplyPanel(self) -- ElvUI is normally initialised already (OptionalDeps); else on first map open

	WorldMapFrame:HookScript("OnShow", function() Panel:OnMapShow() end)
	WorldMapFrame:HookScript("OnHide", function() Panel:OnMapHide() end)
	if WorldMap_ToggleSizeUp then
		hooksecurefunc("WorldMap_ToggleSizeUp", function() Panel:Reanchor() end)
	end
	if WorldMap_ToggleSizeDown then
		hooksecurefunc("WorldMap_ToggleSizeDown", function() Panel:Reanchor() end)
	end

	local requestRefresh = ns.CreateThrottle(1, function() Panel:Refresh() end)
	self.requestRefresh = requestRefresh
	self.requestRender = ns.CreateThrottle(0.2, function() Panel:Render() end)

	ns.RegisterEvent("QUEST_LOG_UPDATE", function() Panel:RequestRefresh() end)
	ns.RegisterEvent("GET_ITEM_INFO_RECEIVED", function(_, itemID)
		if itemID and Data.waitingItems[itemID] then
			Data.waitingItems[itemID] = nil
			Panel:RequestRefresh()
		end
	end)
	for _, event in ipairs({ "QUEST_WATCH_LIST_CHANGED", "SUPER_TRACKED_QUEST_CHANGED", "QUEST_TURNED_IN",
		"WORLD_QUEST_COMPLETED_BY_SPELL", "QUEST_ACCEPTED", "QUEST_REMOVED" }) do
		ns.RegisterEvent(event, function() Panel:RequestRefresh() end)
	end
	ns.RegisterEvent("WORLD_MAP_UPDATE", function()
		if WorldMapFrame:IsShown() then
			Panel:UpdateMarker()
			Panel:RequestRender() -- highlights quests of the zone being viewed
		end
	end)
	ns.RegisterEvent("PLAYER_ENTERING_WORLD", function() Panel.dirty = true end)

	if WorldMapFrame:IsShown() then
		self:OnMapShow()
	end
end

function Panel:CreatePanel()
	local f = CreateFrame("Frame", "WorldQuestBoardPanel", WorldMapFrame, "BasicFrameTemplateWithInset")
	self.frame = f
	f:Hide()
	f:SetSize(PANEL_WIDTH, 534)
	f:SetToplevel(true)
	f:SetClampedToScreen(true)
	f:SetMovable(true)
	f:EnableMouse(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", function(frame)
		if not ns.db.panel.locked then
			frame:StartMoving()
		end
	end)
	f:SetScript("OnDragStop", function(frame)
		frame:StopMovingOrSizing()
		frame:SetUserPlaced(false) -- position is stored in our own settings, not layout-local.txt
		Panel:SaveOffset()
		Panel:Reanchor()
	end)
	f:SetScript("OnShow", function() Panel:Refresh() end)
	f:SetScript("OnHide", function() Panel:HideTooltip() end)

	f.TitleText:SetText("World Quests")
	f.CloseButton:SetScript("OnClick", function() Panel:SetUserShown(false) end)

	-- Toolbar
	local filterButton = CreateSmallButton(f, 54, "Filters")
	filterButton:SetPoint("TOPLEFT", 8, TOOLBAR_TOP)
	self.filterButton = filterButton
	filterButton:SetScript("OnClick", function()
		ns.db.panel.showFilters = not ns.db.panel.showFilters
		Panel:LayoutContent()
	end)
	SetSimpleTooltip(filterButton, "Reward filters", "Show or hide the reward type filters.")

	local sortButton = CreateSmallButton(f, 98, "")
	sortButton:SetPoint("LEFT", filterButton, "RIGHT", 4, 0)
	sortButton:SetScript("OnClick", function() Panel:CycleSort() end)
	SetSimpleTooltip(sortButton, "Sort order", "Click to cycle: time left, zone, reward amount, name.")
	self.sortButton = sortButton

	local groupButton = CreateSmallButton(f, 98, "")
	groupButton:SetPoint("LEFT", sortButton, "RIGHT", 4, 0)
	groupButton:SetScript("OnClick", function() Panel:ToggleGroupBy() end)
	SetSimpleTooltip(groupButton, "Group by", "Click to switch between grouping by reward category and by zone.")
	self.groupButton = groupButton

	local statsButton = CreateSmallButton(f, 50, "Stats")
	statsButton:SetPoint("TOPRIGHT", -8, TOOLBAR_TOP)
	statsButton:SetScript("OnClick", function() ns.StatsWindow:Toggle() end)
	SetSimpleTooltip(statsButton, "World quest statistics", "Open or close this character's world quest statistics.")
	self.statsButton = statsButton

	-- Filters
	local filterBox = CreateFrame("Frame", nil, f)
	filterBox:SetPoint("TOPLEFT", 8, TOOLBAR_TOP - 24)
	filterBox:SetPoint("TOPRIGHT", -8, TOOLBAR_TOP - 24)
	filterBox:SetHeight(FILTER_BOX_HEIGHT)
	self.filterBox = filterBox

	local filterBg = filterBox:CreateTexture(nil, "BACKGROUND")
	filterBg:SetAllPoints()
	filterBg:SetColorTexture(0, 0, 0, 0.3)
	self.filterBg = filterBg

	self.checkboxes = {}
	local columnWidth = (PANEL_WIDTH - 16) / 2
	local function CreateFilterCheckbox(column, line)
		local cb = CreateFrame("CheckButton", nil, filterBox, "UICheckButtonTemplate")
		cb:SetSize(22, 22)
		cb:SetPoint("TOPLEFT", column * columnWidth + 2, -2 - line * FILTER_ROW_HEIGHT)
		cb:SetHitRectInsets(0, -(columnWidth - 26), 0, 0) -- label is clickable too
		cb.icon = cb:CreateTexture(nil, "ARTWORK")
		cb.icon:SetSize(14, 14)
		cb.icon:SetPoint("LEFT", cb, "RIGHT", 0, 0)
		cb.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
		cb.text:ClearAllPoints()
		cb.text:SetPoint("LEFT", cb.icon, "RIGHT", 4, 0)
		cb.text:SetFontObject("GameFontHighlightSmall")
		return cb
	end

	for index, key in ipairs(ns.CATEGORY_ORDER) do
		local cb = CreateFilterCheckbox((index - 1) % 2, math.floor((index - 1) / 2))
		cb:RegisterForClicks("LeftButtonUp", "RightButtonUp")
		cb.category = key
		cb:SetScript("OnClick", function(self, button)
			if button == "RightButton" then
				for _, other in ipairs(ns.CATEGORY_ORDER) do
					ns.db.filters[other] = (other == self.category)
				end
			else
				ns.db.filters[self.category] = self:GetChecked() and true or false
			end
			PlayClickSound()
			Panel:Render()
		end)
		cb:SetScript("OnEnter", function(self)
			local tip = WorldMapTooltip or GameTooltip
			tip:SetOwner(self, "ANCHOR_TOP")
			tip:SetText(ns.CATEGORIES[self.category].label)
			tip:AddLine("Left-click: show/hide this reward type.", 1, 1, 1)
			tip:AddLine("Right-click: show only this reward type.", 1, 1, 1)
			tip:Show()
		end)
		cb:SetScript("OnLeave", function() (WorldMapTooltip or GameTooltip):Hide() end)
		self.checkboxes[key] = cb
	end

	-- Quest-type toggle, independent of the reward type.
	local petCheckbox = CreateFilterCheckbox(0, math.ceil(#ns.CATEGORY_ORDER / 2))
	petCheckbox:RegisterForClicks("LeftButtonUp")
	petCheckbox.icon:SetTexture(PET_BATTLE_ICON)
	petCheckbox:SetScript("OnClick", function(self)
		ns.db.showPetBattles = self:GetChecked() and true or false
		PlayClickSound()
		Panel:Render()
	end)
	SetSimpleTooltip(petCheckbox, "Pet battle world quests", "Show or hide pet battle world quests, whatever their reward.")
	self.petCheckbox = petCheckbox

	local resetButton = CreateSmallButton(filterBox, 90, "Reset filters")
	resetButton:SetPoint("BOTTOMLEFT", 4, 4)
	self.resetButton = resetButton
	resetButton:SetScript("OnClick", function()
		ns.ResetFilters()
		PlayClickSound()
		Panel:Render()
	end)
	SetSimpleTooltip(resetButton, "Reset filters", "Show all reward types and pet battles again.")

	local hint = filterBox:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	hint:SetPoint("LEFT", resetButton, "RIGHT", 6, 0)
	hint:SetPoint("RIGHT", -4, 0)
	hint:SetJustifyH("RIGHT")
	hint:SetText("Right-click: only this")

	-- Quest list
	local scroll = CreateFrame("ScrollFrame", "WorldQuestBoardScrollFrame", f, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("BOTTOMRIGHT", -28, 24)
	self.scroll = scroll

	local content = CreateFrame("Frame", nil, scroll)
	content:SetSize(PANEL_WIDTH - 40, 1)
	scroll:SetScrollChild(content)
	scroll:HookScript("OnSizeChanged", function(_, width)
		content:SetWidth(width)
	end)
	self.content = content

	content.empty = content:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	content.empty:SetPoint("TOPLEFT", 8, -12)
	content.empty:SetPoint("RIGHT", -8, 0)
	content.empty:SetJustifyH("LEFT")
	content.empty:SetSpacing(2)

	self.footer = f:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	self.footer:SetPoint("BOTTOMLEFT", 10, 8)
	self.footer:SetPoint("BOTTOMRIGHT", -10, 8)
	self.footer:SetJustifyH("LEFT")
	self.footer:SetWordWrap(false)

	self.headers, self.rows = {}, {}
	self:LayoutContent()
end

-- Small "WQ" button in the map's title bar; always available to bring the panel back.
function Panel:CreateMapButton()
	local border = WorldMapFrame.BorderFrame
	local button = CreateSmallButton(border, 34, "WQ")
	if border.MaximizeMinimizeFrame then
		button:SetPoint("RIGHT", border.MaximizeMinimizeFrame, "LEFT", 2, 0)
	else
		button:SetPoint("TOPRIGHT", border, "TOPRIGHT", -60, -2)
	end
	button:SetFrameLevel(border:GetFrameLevel() + 20)
	button:SetScript("OnClick", function()
		Panel:SetUserShown(not ns.db.panel.shown)
	end)
	SetSimpleTooltip(button, "World Quest Board", "Show or hide the world quest list.")
	self.mapButton = button
end

-- Pulsing ring drawn on the map at a quest's position.
function Panel:CreateMarker()
	local parent = WorldMapPOIFrame or WorldMapButton
	if not parent then
		return
	end
	local marker = CreateFrame("Frame", nil, parent)
	marker:SetSize(40, 40)
	marker:EnableMouse(false)
	marker:SetFrameLevel(parent:GetFrameLevel() + 1300) -- above world quest pins (+1200)
	marker:Hide()

	local ring = marker:CreateTexture(nil, "OVERLAY")
	ring:SetPoint("CENTER")
	ring:SetTexture("Interface\\Minimap\\UI-Minimap-Ping-Expand")
	ring:SetBlendMode("ADD")
	ring:SetVertexColor(1, 0.82, 0.1)
	marker.ring = ring

	local ring2 = marker:CreateTexture(nil, "OVERLAY")
	ring2:SetPoint("CENTER")
	ring2:SetSize(30, 30)
	ring2:SetTexture("Interface\\Minimap\\UI-Minimap-Ping-Expand")
	ring2:SetBlendMode("ADD")
	ring2:SetVertexColor(1, 1, 1, 0.8)

	marker:SetScript("OnUpdate", function(frame, elapsed)
		frame.elapsed = (frame.elapsed or 0) + elapsed
		if frame.elapsed > MARKER_SECONDS then
			frame:Hide()
			return
		end
		local phase = (frame.elapsed % 1.2) / 1.2
		local size = 20 + 50 * phase
		frame.ring:SetSize(size, size)
		frame.ring:SetAlpha(1 - phase)
	end)
	self.marker = marker
end

---------------------------------------------------------------------------
-- Placement and visibility
---------------------------------------------------------------------------
function Panel:SaveOffset()
	local f, border = self.frame, WorldMapFrame.BorderFrame
	local left, top = f:GetLeft(), f:GetTop()
	local right, borderTop = border:GetRight(), border:GetTop()
	if left and top and right and borderTop then
		ns.db.panel.offsets[GetMapMode()] = {
			x = math.floor(left - right + 0.5),
			y = math.floor(top - borderTop + 0.5),
		}
	end
end

function Panel:Reanchor()
	local f = self.frame
	if not f then
		return
	end
	local border = WorldMapFrame.BorderFrame
	local mode = GetMapMode()
	local offset = ns.db.panel.offsets[mode]
	local borderHeight = border:GetHeight() or 534

	f:SetFrameStrata(NEXT_STRATA[WorldMapFrame:GetFrameStrata()] or "DIALOG")
	f:ClearAllPoints()
	if mode == "windowed" then
		f:SetHeight(borderHeight)
	else
		f:SetHeight(borderHeight - FULLSCREEN_HEIGHT_REDUCTION)
	end

	if offset then
		f:SetPoint("TOPLEFT", border, "TOPRIGHT", offset.x, offset.y)
	else
		local room = (WorldMapFrame:GetRight() or 0) - (border:GetRight() or 0)
		if mode == "fullscreen" and room < PANEL_WIDTH + DOCK_GAP then
			f:SetPoint("TOPRIGHT", border, "TOPRIGHT", -8, FULLSCREEN_OVERLAY_TOP)
		else
			f:SetPoint("TOPLEFT", border, "TOPRIGHT", DOCK_GAP, mode == "fullscreen" and FULLSCREEN_OVERLAY_TOP or 0)
		end
	end
end

function Panel:LayoutContent()
	if not self.frame then
		return
	end
	local showFilters = ns.db.panel.showFilters
	self.filterBox:SetShown(showFilters)
	self.scroll:ClearAllPoints()
	if showFilters then
		self.scroll:SetPoint("TOPLEFT", self.filterBox, "BOTTOMLEFT", 0, -6)
	else
		self.scroll:SetPoint("TOPLEFT", 8, TOOLBAR_TOP - 26)
	end
	self.scroll:SetPoint("BOTTOMRIGHT", -28, 24)
end

function Panel:IsActive()
	return self.frame and self.frame:IsVisible()
end

function Panel:SetUserShown(shown)
	ns.db.panel.shown = shown and true or false
	self:ApplyVisibility()
end

function Panel:ApplyVisibility()
	if not self.frame then
		return
	end
	local show = ns.db.panel.shown and WorldMapFrame:IsShown()
	if show then
		self:Reanchor()
	end
	self.frame:SetShown(show)
end

function Panel:OnMapShow()
	self.pendingRetries = 0
	if ns.Skin:ApplyPanel(self) then
		self:Render() -- rows drawn before the skin existed get ElvUI expand icons
	end
	self:Reanchor()
	self:ApplyVisibility()
	-- The panel's own OnShow normally refreshed already; refresh here if it did not.
	if self:IsActive() and (self.dirty or not self.lastRefresh or GetTime() - self.lastRefresh > 0.5) then
		self:Refresh()
	end
	if not self.ticker then
		self.ticker = C_Timer.NewTicker(REFRESH_INTERVAL, function()
			if Panel:IsActive() then
				Panel:Refresh()
			end
		end)
	end
end

function Panel:OnMapHide()
	if self.ticker then
		self.ticker:Cancel()
		self.ticker = nil
	end
	if self.marker then
		self.marker:Hide()
	end
	self.focusQuestID = nil
end

---------------------------------------------------------------------------
-- Refresh and rendering
---------------------------------------------------------------------------
function Panel:RequestRefresh()
	if self:IsActive() then
		self.requestRefresh()
	else
		self.dirty = true
	end
end

function Panel:RequestRender()
	if self:IsActive() then
		self.requestRender()
	end
end

function Panel:Refresh()
	if not self:IsActive() then
		self.dirty = true
		return
	end
	self.dirty = false
	self.lastRefresh = GetTime()
	Data:Scan()
	self:Render()

	-- Conservative retry while the server is still sending quest/reward/item data.
	-- QUEST_LOG_UPDATE normally covers this; the retry is a bounded fallback.
	if Data:HasPendingData() and (self.pendingRetries or 0) < PENDING_RETRY_LIMIT then
		self.pendingRetries = (self.pendingRetries or 0) + 1
		C_Timer.After(PENDING_RETRY_DELAY, function() Panel:RequestRefresh() end)
	end
end

function Panel:ToggleGroup(key)
	if not key then
		return
	end
	ns.db.collapsed[key] = (not ns.db.collapsed[key]) or nil
	PlayClickSound()
	self:Render()
end

function Panel:ToggleGroupBy()
	ns.db.groupBy = (ns.db.groupBy == "zone") and "category" or "zone"
	PlayClickSound()
	self:Render()
end

function Panel:CycleSort()
	local order = ns.SORT_ORDER
	local index = 1
	for i, mode in ipairs(order) do
		if mode == ns.db.sort then
			index = i
		end
	end
	ns.db.sort = order[index % #order + 1]
	PlayClickSound()
	self:Render()
end

function Panel:AcquireHeader(index)
	local header = self.headers[index]
	if not header then
		header = CreateHeader(self.content)
		self.headers[index] = header
		ns.Skin:StyleHeader(header)
	end
	return header
end

function Panel:AcquireRow(index)
	local row = self.rows[index]
	if not row then
		row = CreateRow(self.content)
		self.rows[index] = row
		ns.Skin:StyleRow(row)
	end
	return row
end

local function TimeLeftText(q, now)
	if not q.expiresAt then
		return "|cff808080--|r"
	end
	local minutes = (q.expiresAt - now) / 60
	if minutes <= 0 then
		return "|cff808080expired|r"
	end
	local text = ns.FormatMinutes(minutes)
	if minutes <= CRITICAL_MINUTES then
		return "|cffff2020" .. text .. "|r"
	elseif minutes <= 180 then
		return "|cffff9900" .. text .. "|r"
	end
	return text
end

local function CategoryOf(q)
	return ns.CATEGORIES[q.category] and q.category or "other"
end

local function IsPetBattle(q)
	return LE_QUEST_TAG_TYPE_PET_BATTLE ~= nil and q.worldQuestType == LE_QUEST_TAG_TYPE_PET_BATTLE
end

-- Quest-type toggles (currently: pet battles), applied before reward-type filters.
local function PassesTypeFilters(q)
	return ns.db.showPetBattles or not IsPetBattle(q)
end

-- Builds the visible groups: one per reward category, or one per zone.
-- Quests hidden by the reward-type filters or the pet battle toggle are left out in both modes.
function Panel:BuildGroups()
	local db = ns.db
	local groups, byKey = {}, {}
	if db.groupBy == "zone" then
		for _, q in ipairs(Data.quests) do
			if db.filters[CategoryOf(q)] and PassesTypeFilters(q) then
				local key = "zone:" .. tostring(q.zoneID or 0)
				local group = byKey[key]
				if not group then
					group = { key = key, label = q.zoneName or "?", icon = ZONE_GROUP_ICON, quests = {} }
					byKey[key] = group
					groups[#groups + 1] = group
				end
				group.quests[#group.quests + 1] = q
			end
		end
		table.sort(groups, function(a, b) return a.label < b.label end)
	else
		for _, key in ipairs(ns.CATEGORY_ORDER) do
			if db.filters[key] then
				local group = { key = key, category = key, label = ns.CATEGORIES[key].label, icon = ns.GetCategoryIcon(key), quests = {}, total = 0 }
				byKey[key] = group
				groups[#groups + 1] = group
			end
		end
		for _, q in ipairs(Data.quests) do
			local group = PassesTypeFilters(q) and byKey[CategoryOf(q)]
			if group then
				group.quests[#group.quests + 1] = q
				if q.mainAmount and not q.completed then
					group.total = group.total + q.mainAmount
				end
			end
		end
	end
	local visible = {}
	for _, group in ipairs(groups) do
		if #group.quests > 0 then
			visible[#visible + 1] = group
		end
	end
	return visible
end

function Panel:SetupHeader(header, group)
	header.groupKey = group.key
	local plus, minus = ns.Skin:GetExpandTextures()
	header.expand:SetTexture(ns.db.collapsed[group.key] and plus or minus)
	header.icon:SetTexture(group.icon)
	header.label:SetText(group.label)
	header.count:SetText(#group.quests)
	local totalText = ""
	local total = group.total
	if total and total > 0 then
		if group.category == "gold" then
			totalText = ns.FormatNumber(math.floor(total / 10000)) .. GOLD_ICON
		elseif group.category == "orderres" then
			totalText = ns.FormatNumber(total)
		elseif group.category == "ap" then
			totalText = ns.AbbreviateNumber(total)
		end
	end
	header.total:SetText(totalText)
	header:Show()
end

local function TagsText(q)
	local tags = {}
	if q.completed then
		tags[#tags + 1] = "|cff20ff20Completed|r"
	elseif q.inProgress then
		tags[#tags + 1] = "|cff20ff20In progress|r"
	end
	local typeTag = q.worldQuestType and TYPE_TAGS[q.worldQuestType]
	if q.isElite then
		typeTag = typeTag and ("Elite " .. typeTag) or "Elite"
	end
	if typeTag then
		tags[#tags + 1] = typeTag
	end
	return #tags > 0 and table.concat(tags, ", ") or nil
end

function Panel:SetupRow(row, q, now, currentMapID, showZone)
	row.quest = q
	row.icon:SetTexture(q.icon or ns.CATEGORIES.unknown.icon)
	row.iconText:SetText(q.iconText or "")

	local rarityColor = q.rarity ~= LE_WORLD_QUEST_QUALITY_COMMON and WORLD_QUEST_QUALITY_COLORS and WORLD_QUEST_QUALITY_COLORS[q.rarity]
	if rarityColor then
		row.rarity:SetColorTexture(rarityColor.r, rarityColor.g, rarityColor.b, 0.9)
		row.rarity:Show()
	else
		row.rarity:Hide()
	end

	-- Right column: time left, zone underneath (the zone is the header when grouping by zone).
	row.time:SetText(TimeLeftText(q, now))
	row.time:SetWidth(RIGHT_COLUMN_MAX)
	row.time:ClearAllPoints()
	row.zone:ClearAllPoints()
	local rightWidth = row.time:GetStringWidth() or 0
	if showZone then
		row.time:SetPoint("TOPRIGHT", row, "TOPRIGHT", -6, -4)
		row.zone:SetWidth(RIGHT_COLUMN_MAX)
		row.zone:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -6, 4)
		row.zone:SetText(q.zoneName or "?")
		if q.zoneID == currentMapID then
			row.zone:SetTextColor(1, 1, 1)
		else
			row.zone:SetTextColor(0.62, 0.62, 0.62)
		end
		row.zone:Show()
		rightWidth = math.max(rightWidth, row.zone:GetStringWidth() or 0)
	else
		row.time:SetPoint("RIGHT", row, "RIGHT", -6, 0)
		row.zone:Hide()
	end
	local used = 6 + math.min(rightWidth, RIGHT_COLUMN_MAX) + 6

	local bounty = q.bounties and q.bounties[1]
	row.bounty:ClearAllPoints()
	if bounty and bounty.icon then
		row.bounty:SetTexture(bounty.icon)
		row.bounty:SetPoint("RIGHT", row, "RIGHT", -used, 0)
		row.bounty:Show()
		used = used + 14 + 4
	else
		row.bounty:Hide()
	end

	-- Left column: reward description, optional tag line below it.
	local text = q.rewardText or ""
	if q.tracked then
		text = CHECKMARK .. " " .. text
	end
	row.text:SetText(text)
	local width = math.max(40, (self.content:GetWidth() or PANEL_WIDTH) - TEXT_LEFT - used)
	row.text:SetWidth(width)
	row.tags:SetWidth(width)
	row.text:ClearAllPoints()
	local tags = TagsText(q)
	if tags then
		row.text:SetPoint("TOPLEFT", row, "TOPLEFT", TEXT_LEFT, -4)
		row.tags:SetText(tags)
		row.tags:Show()
	else
		row.text:SetPoint("LEFT", row, "LEFT", TEXT_LEFT, 0)
		row.tags:Hide()
	end

	row:SetAlpha(q.completed and 0.5 or 1)
	row.selected:SetShown(self.focusQuestID == q.questID)
	row:Show()
end

function Panel:Render()
	local f = self.frame
	if not (f and f:IsShown()) then
		return
	end
	local db = ns.db
	local now = time()
	local currentMapID = SafeCall(GetCurrentMapAreaID)
	local showZone = db.groupBy ~= "zone"

	local comparator = Comparator(db.sort)
	local content = self.content
	local y, headerCount, rowCount, shown = 4, 0, 0, 0
	for _, group in ipairs(self:BuildGroups()) do
		table.sort(group.quests, comparator)
		headerCount = headerCount + 1
		local header = self:AcquireHeader(headerCount)
		header:ClearAllPoints()
		header:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -y)
		header:SetPoint("RIGHT", content, "RIGHT", 0, 0)
		self:SetupHeader(header, group)
		y = y + HEADER_HEIGHT + 2
		if not db.collapsed[group.key] then
			for _, q in ipairs(group.quests) do
				rowCount = rowCount + 1
				local row = self:AcquireRow(rowCount)
				row:ClearAllPoints()
				row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -y)
				row:SetPoint("RIGHT", content, "RIGHT", 0, 0)
				self:SetupRow(row, q, now, currentMapID, showZone)
				y = y + ROW_HEIGHT
			end
		end
		y = y + 6
		shown = shown + #group.quests
	end
	for i = headerCount + 1, #self.headers do
		self.headers[i]:Hide()
	end
	for i = rowCount + 1, #self.rows do
		self.rows[i]:Hide()
		self.rows[i].quest = nil
	end

	if #Data.quests == 0 then
		content.empty:SetText("No world quests reported by the client.\n\n"
			.. "World quests require level 110 and the \"Uniting the Isles\" quest. "
			.. "If quests are visible on the map but not here, type |cffffd100/wqb scan|r.")
		content.empty:Show()
		y = math.max(y, 120)
	elseif shown == 0 then
		content.empty:SetText("All " .. #Data.quests .. " quests are hidden by the current filters.\nUse \"Reset filters\" to show everything.")
		content.empty:Show()
		y = math.max(y, 60)
	else
		content.empty:Hide()
	end
	content:SetHeight(math.max(y, 1))

	-- Filter labels show how many quests each reward type has (not counting hidden pet
	-- battles), and how many pet battle quests there are.
	local counts, petBattles = {}, 0
	for _, q in ipairs(Data.quests) do
		if IsPetBattle(q) then
			petBattles = petBattles + 1
		end
		if PassesTypeFilters(q) then
			local key = CategoryOf(q)
			counts[key] = (counts[key] or 0) + 1
		end
	end
	for key, cb in pairs(self.checkboxes) do
		cb:SetChecked(db.filters[key])
		cb.icon:SetTexture(ns.GetCategoryIcon(key))
		cb.text:SetText(ns.CATEGORIES[key].short .. " |cff9d9d9d(" .. (counts[key] or 0) .. ")|r")
	end
	self.petCheckbox:SetChecked(db.showPetBattles)
	self.petCheckbox.text:SetText("Pet battles |cff9d9d9d(" .. petBattles .. ")|r")

	f.TitleText:SetText(("World Quests (%d/%d)"):format(shown, #Data.quests))
	self.sortButton:SetText("Sort: " .. ns.SORT_LABELS[db.sort])
	self.groupButton:SetText("Group: " .. (db.groupBy == "zone" and "Zone" or "Category"))

	local info = Data.scanInfo
	local waiting = (info.noQuestData or 0) + (info.noRewardData or 0)
	local footer = "Updated " .. date("%H:%M", Data.lastScan or now)
	if waiting > 0 then
		footer = footer .. "  |cffff9900" .. waiting .. " waiting for server data|r"
	end
	if db.panel.locked then
		footer = footer .. "  (locked)"
	end
	self.footer:SetText(footer)
end

---------------------------------------------------------------------------
-- Tooltip
---------------------------------------------------------------------------
local function AddOwnRewardLines(tip, rewards)
	tip:AddLine(" ")
	tip:AddLine(REWARDS or "Rewards", NORMAL_FONT_COLOR.r, NORMAL_FONT_COLOR.g, NORMAL_FONT_COLOR.b)
	if rewards.artifactXP > 0 then
		tip:AddLine(ns.FormatAmount(rewards.artifactXP) .. " " .. (ARTIFACT_POWER or "Artifact Power"), 1, 1, 1)
	end
	for _, currency in ipairs(rewards.currencies) do
		tip:AddLine(ns.FormatNumber(currency.amount) .. " " .. (currency.name or "?"), 1, 1, 1)
	end
	for _, item in ipairs(rewards.items) do
		local text = (item.quantity > 1 and (item.quantity .. "x ") or "") .. (item.name or "?")
		if item.ilvl then
			text = text .. " (ilvl " .. item.ilvl .. ")"
		elseif item.apAmount then
			text = text .. " (" .. ns.FormatAmount(item.apAmount) .. " " .. (ARTIFACT_POWER or "Artifact Power") .. ")"
		end
		tip:AddLine(text, 1, 1, 1)
	end
	if rewards.honor > 0 then
		tip:AddLine(ns.FormatNumber(rewards.honor) .. " " .. (HONOR or "Honor"), 1, 1, 1)
	end
	if rewards.money > 0 then
		tip:AddLine(ns.FormatMoney(rewards.money), 1, 1, 1)
	end
end

function Panel:ShowQuestTooltip(row)
	local q = row.quest
	if not q then
		return
	end
	local tip = WorldMapTooltip or GameTooltip
	tip:SetOwner(row, "ANCHOR_NONE")
	tip:ClearAllPoints()
	-- Open towards the map (the side away from the screen edge).
	local panelCenter = self.frame:GetCenter() or 0
	local mapCenter = WorldMapFrame:GetCenter() or 0
	if panelCenter >= mapCenter then
		tip:SetPoint("TOPRIGHT", row, "TOPLEFT", -8, 0)
	else
		tip:SetPoint("TOPLEFT", row, "TOPRIGHT", 8, 0)
	end

	local color = WORLD_QUEST_QUALITY_COLORS and WORLD_QUEST_QUALITY_COLORS[q.rarity] or NORMAL_FONT_COLOR
	tip:SetText(q.title or ("Unknown quest #" .. q.questID), color.r, color.g, color.b)
	if q.tagName then
		tip:AddLine(q.tagName, 0.8, 0.8, 0.8)
	end
	tip:AddLine(q.zoneName or "?", 0.4, 0.733, 1.0)
	if q.factionName then
		if q.factionCapped then
			tip:AddLine(q.factionName .. " (reputation capped)", GRAY_FONT_COLOR.r, GRAY_FONT_COLOR.g, GRAY_FONT_COLOR.b)
		else
			tip:AddLine(q.factionName, 1, 1, 1)
		end
	end

	if q.expiresAt then
		local minutes = (q.expiresAt - time()) / 60
		local timeText = minutes > 0 and ns.FormatMinutes(minutes) or "expired"
		local timeColor = (minutes <= CRITICAL_MINUTES) and RED_FONT_COLOR or NORMAL_FONT_COLOR
		tip:AddLine((BONUS_OBJECTIVE_TIME_LEFT or "Time Left: %s"):format(timeText), timeColor.r, timeColor.g, timeColor.b)
	else
		tip:AddLine("Time left: not reported by the client", GRAY_FONT_COLOR.r, GRAY_FONT_COLOR.g, GRAY_FONT_COLOR.b)
	end

	if q.completed then
		tip:AddLine("Completed", 0.1, 1, 0.1)
	elseif q.inProgress then
		tip:AddLine("In progress", 0.1, 1, 0.1)
	end
	if q.tracked then
		tip:AddLine("Tracked in the objective tracker", 0.1, 1, 0.1)
	end
	if q.bounties then
		for _, bounty in ipairs(q.bounties) do
			tip:AddLine("Counts toward emissary: " .. (bounty.factionName or "?"), 1, 0.82, 0)
		end
	end

	for i = 1, q.numObjectives or 0 do
		local text, _, finished = SafeCall(GetQuestObjectiveInfo, q.questID, i, false)
		if text and text ~= "" then
			local c = finished and GRAY_FONT_COLOR or HIGHLIGHT_FONT_COLOR
			tip:AddLine((QUEST_DASH or "- ") .. text, c.r, c.g, c.b, true)
		end
	end
	local percent = SafeCall(C_TaskQuest.GetQuestProgressBarInfo, q.questID)
	if type(percent) == "number" then
		tip:AddLine(("Progress: %d%%"):format(percent), 1, 1, 1)
	end

	tip:AddLine("Click: show on map   Shift-click: track/untrack", 0.6, 0.6, 0.6)
	if TomTom and TomTom.AddMFWaypoint then
		tip:AddLine("Ctrl-click: TomTom waypoint", 0.6, 0.6, 0.6)
	end
	if q.category == "gear" then
		tip:AddLine("Hold Shift to compare with your equipped item", 0.6, 0.6, 0.6)
	end

	-- Rewards come last: Blizzard's item preview is anchored to the bottom of the tooltip.
	-- GameTooltip_AddQuestRewardsToTooltip also shows the equipped-item comparison while
	-- the compare key (Shift) is held; row.UpdateTooltip rebuilds when that key changes.
	self.tooltipCompare = (IsModifiedClick("COMPAREITEMS") or GetCVarBool("alwaysCompareItems")) and true or false
	local addedBlizzardRewards = false
	if q.rewards and GameTooltip_AddQuestRewardsToTooltip and tip.ItemTooltip and SafeCall(HaveQuestRewardData, q.questID) then
		addedBlizzardRewards = pcall(GameTooltip_AddQuestRewardsToTooltip, tip, q.questID)
	end
	if not addedBlizzardRewards then
		if q.rewards then
			AddOwnRewardLines(tip, q.rewards)
		else
			tip:AddLine(" ")
			tip:AddLine(RETRIEVING_DATA or "Retrieving data", RED_FONT_COLOR.r, RED_FONT_COLOR.g, RED_FONT_COLOR.b)
		end
	end
	tip:Show()
	tip.recalculatePadding = true
	self.tooltipOwner = row
end

function Panel:HideTooltip()
	local tip = WorldMapTooltip or GameTooltip
	if self.tooltipOwner and tip:GetOwner() == self.tooltipOwner then
		tip:Hide()
	end
	self.tooltipOwner = nil
end

---------------------------------------------------------------------------
-- Interaction
---------------------------------------------------------------------------
function Panel:OnRowClick(row, button)
	local q = row.quest
	if not q then
		return
	end
	if IsModifiedClick("CHATLINK") and ChatEdit_TryInsertQuestLinkForQuestID
		and ChatEdit_TryInsertQuestLinkForQuestID(q.questID) then
		return -- linked into an open chat edit box
	end
	if IsShiftKeyDown() then
		self:ToggleTracking(q)
	elseif IsControlKeyDown() then
		self:AddWaypoint(q)
	else
		self:FocusQuest(q)
	end
end

function Panel:ToggleTracking(q)
	local questID = q.questID
	if not AddWorldQuestWatch then
		return
	end
	-- Watch changes make the objective tracker re-layout its secure quest item buttons;
	-- doing that from addon code in combat could trigger "action blocked" errors.
	if InCombatLockdown and InCombatLockdown() then
		ns.Print("Tracking cannot be changed during combat.")
		return
	end
	local watched = SafeCall(IsWorldQuestHardWatched, questID)
		or (SafeCall(IsWorldQuestWatched, questID) and SafeCall(GetSuperTrackedQuestID) == questID)
	if watched then
		SafeCall(RemoveWorldQuestWatch, questID)
	elseif SafeCall(AddWorldQuestWatch, questID, true) then
		if (SafeCall(GetSuperTrackedQuestID) or 0) == 0 then
			SafeCall(SetSuperTrackedQuestID, questID)
		end
	end
	PlayClickSound()
	self:RequestRefresh()
end

function Panel:AddWaypoint(q)
	if not (TomTom and TomTom.AddMFWaypoint) then
		ns.Print("Ctrl-click adds a TomTom waypoint, but TomTom is not loaded.")
		return
	end
	if not (q.zoneID and q.x and q.y and (q.x > 0 or q.y > 0)) then
		ns.Print("The client did not report a map position for this quest.")
		return
	end
	local title = q.title or ("World quest #" .. q.questID)
	TomTom:AddMFWaypoint(q.zoneID, nil, q.x, q.y, { title = title })
	ns.Print("TomTom waypoint added: %s (%s %.1f, %.1f)", title, q.zoneName or "?", q.x * 100, q.y * 100)
end

-- Switches the world map to the quest's zone and highlights its position.
function Panel:FocusQuest(q)
	if not WorldMapFrame:IsShown() then
		return
	end
	self.focusQuestID = q.questID
	if q.zoneID and SafeCall(GetCurrentMapAreaID) ~= q.zoneID then
		SafeCall(SetMapByID, q.zoneID)
	end
	if self.marker then
		self.marker.elapsed = 0
	end
	self:UpdateMarker()
	PlayClickSound()
	-- Blizzard rebuilds its pins after the map change; ping the pin once they exist.
	C_Timer.After(0.1, function()
		if Panel.focusQuestID == q.questID and WorldMapPing_StartPingQuest then
			SafeCall(WorldMapPing_StartPingQuest, q.questID)
		end
		Panel:UpdateMarker()
	end)
	self:Render()
end

function Panel:UpdateMarker()
	local marker = self.marker
	if not marker then
		return
	end
	local questID = self.focusQuestID
	if not questID or not WorldMapFrame:IsShown() or (marker.elapsed or 0) > MARKER_SECONDS then
		marker:Hide()
		return
	end
	local q = Data.byID[questID]
	local mapID = SafeCall(GetCurrentMapAreaID)
	local x, y
	if q and mapID == q.zoneID then
		x, y = q.x, q.y
	elseif C_TaskQuest.GetQuestLocation then
		-- Also works on the continent map when the quest is visible there.
		x, y = SafeCall(C_TaskQuest.GetQuestLocation, questID, mapID)
	end
	x, y = tonumber(x), tonumber(y)
	if not x or not y or (x == 0 and y == 0) then
		marker:Hide()
		return
	end
	local parent = marker:GetParent()
	marker:ClearAllPoints()
	marker:SetPoint("CENTER", parent, "TOPLEFT", x * parent:GetWidth(), -y * parent:GetHeight())
	marker:Show()
end
