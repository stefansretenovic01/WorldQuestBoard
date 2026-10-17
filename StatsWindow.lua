--[[
	World Quest Board - Statistics window
	Hidden by default; opened only with the "Statistics" button on the quest list or
	/wqb stats. Its open state is deliberately not restored on login or when the map
	opens; only its position is saved.

	The window uses strata FULLSCREEN_DIALOG so it stays visible above the fullscreen
	world map, and asks for reset confirmation inside the window: StaticPopup dialogs
	use strata DIALOG and would be hidden behind the fullscreen map.
]]
local ADDON_NAME, ns = ...
local SafeCall = ns.SafeCall

local StatsWindow = {}
ns.StatsWindow = StatsWindow

local WIDTH, HEIGHT = 340, 440
local RECENT_LINES = 6
local CONFIRM_TIMEOUT = 15

function StatsWindow:Init()
	-- Created lazily on first use so nothing is shown or allocated before it is wanted.
end

local function CreateStatRow(parent, anchor, icon, label)
	local row = CreateFrame("Frame", nil, parent)
	row:SetHeight(22)
	row:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -6)
	row:SetPoint("RIGHT", parent, "RIGHT", -14, 0)

	row.icon = row:CreateTexture(nil, "ARTWORK")
	row.icon:SetSize(20, 20)
	row.icon:SetPoint("LEFT")
	row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
	row.icon:SetTexture(icon)

	row.label = row:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	row.label:SetPoint("LEFT", row.icon, "RIGHT", 8, 0)
	row.label:SetText(label)

	row.value = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	row.value:SetPoint("RIGHT")
	row.value:SetJustifyH("RIGHT")
	return row
end

function StatsWindow:Create()
	if self.frame then
		return self.frame
	end
	local f = CreateFrame("Frame", "WorldQuestBoardStatsFrame", UIParent, "BasicFrameTemplateWithInset")
	self.frame = f
	f:Hide()
	f:SetSize(WIDTH, HEIGHT)
	f:SetFrameStrata("FULLSCREEN_DIALOG")
	f:SetToplevel(true)
	f:SetClampedToScreen(true)
	f:SetMovable(true)
	f:EnableMouse(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", function(frame)
		frame:StopMovingOrSizing()
		frame:SetUserPlaced(false)
		local point, _, relativePoint, x, y = frame:GetPoint(1)
		ns.db.statsWindow.point = { point = point, relativePoint = relativePoint, x = math.floor(x + 0.5), y = math.floor(y + 0.5) }
	end)
	f:SetScript("OnShow", function() StatsWindow:Update() end)
	f:SetScript("OnHide", function() StatsWindow:CancelReset() end)
	f.TitleText:SetText("World Quest Statistics")
	-- Escape closes the window like other panels.
	table.insert(UISpecialFrames, "WorldQuestBoardStatsFrame")

	f.character = f:CreateFontString(nil, "ARTWORK", "GameFontHighlightLarge")
	f.character:SetPoint("TOPLEFT", 14, -32)
	f.character:SetPoint("RIGHT", -14, 0)
	f.character:SetJustifyH("LEFT")

	f.since = f:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	f.since:SetPoint("TOPLEFT", f.character, "BOTTOMLEFT", 0, -3)

	f.completed = CreateStatRow(f, f.since, "Interface\\Icons\\INV_Misc_Map_01", "World quests completed")
	f.gold = CreateStatRow(f, f.completed, "Interface\\Icons\\INV_Misc_Coin_01", "Gold earned")
	f.orderResources = CreateStatRow(f, f.gold, ns.CATEGORIES.orderres.icon, "Order Resources earned")
	f.gear = CreateStatRow(f, f.orderResources, ns.CATEGORIES.gear.icon, "Highest item level gear")

	-- Item of the best gear reward; hover for the item tooltip.
	local itemButton = CreateFrame("Button", nil, f)
	itemButton:SetHeight(16)
	itemButton:SetPoint("TOPLEFT", f.gear, "BOTTOMLEFT", 28, -2)
	itemButton:SetPoint("RIGHT", f, "RIGHT", -14, 0)
	itemButton.text = itemButton:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	itemButton.text:SetAllPoints()
	itemButton.text:SetJustifyH("LEFT")
	itemButton.text:SetWordWrap(false)
	itemButton:SetScript("OnEnter", function(self)
		if self.link then
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetHyperlink(self.link)
			GameTooltip:Show()
		end
	end)
	itemButton:SetScript("OnLeave", function() GameTooltip:Hide() end)
	f.itemButton = itemButton

	local recentTitle = f:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	recentTitle:SetPoint("TOPLEFT", f.gear, "BOTTOMLEFT", 0, -26)
	recentTitle:SetText("Recent completions")

	f.recent = {}
	local previous = recentTitle
	for i = 1, RECENT_LINES do
		local line = f:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
		line:SetPoint("TOPLEFT", previous, "BOTTOMLEFT", 0, (i == 1) and -4 or -2)
		line:SetPoint("RIGHT", f, "RIGHT", -14, 0)
		line:SetJustifyH("LEFT")
		line:SetWordWrap(false)
		f.recent[i] = line
		previous = line
	end

	f.note = f:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	f.note:SetPoint("BOTTOMLEFT", 14, 40)
	f.note:SetPoint("RIGHT", -14, 0)
	f.note:SetJustifyH("LEFT")
	f.note:SetSpacing(2)

	local resetButton = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	resetButton:SetSize(130, 22)
	resetButton:SetPoint("BOTTOMLEFT", 12, 10)
	resetButton:SetText("Reset statistics...")
	resetButton:SetScript("OnClick", function() StatsWindow:AskReset() end)
	f.resetButton = resetButton

	-- Inline confirmation (replaces the reset button while active).
	local confirm = CreateFrame("Frame", nil, f)
	confirm:SetPoint("BOTTOMLEFT", 8, 6)
	confirm:SetPoint("BOTTOMRIGHT", -8, 6)
	confirm:SetHeight(58)
	confirm:EnableMouse(true)
	confirm:Hide()
	local confirmBg = confirm:CreateTexture(nil, "BACKGROUND")
	confirmBg:SetAllPoints()
	confirmBg:SetColorTexture(0.25, 0, 0, 0.85)
	confirm.text = confirm:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	confirm.text:SetPoint("TOPLEFT", 6, -6)
	confirm.text:SetPoint("RIGHT", -6, 0)
	confirm.text:SetJustifyH("LEFT")
	local yes = CreateFrame("Button", nil, confirm, "UIPanelButtonTemplate")
	yes:SetSize(110, 22)
	yes:SetPoint("BOTTOMLEFT", 4, 4)
	yes:SetText("Yes, reset")
	yes:SetScript("OnClick", function()
		StatsWindow:CancelReset()
		ns.Stats:ResetCurrent()
	end)
	local no = CreateFrame("Button", nil, confirm, "UIPanelButtonTemplate")
	no:SetSize(90, 22)
	no:SetPoint("LEFT", yes, "RIGHT", 6, 0)
	no:SetText(CANCEL or "Cancel")
	no:SetScript("OnClick", function() StatsWindow:CancelReset() end)
	f.confirm = confirm
	f.confirmYes, f.confirmNo = yes, no

	self:RestorePosition()
	ns.Skin:ApplyStats(self)
	return f
end

function StatsWindow:RestorePosition()
	local f = self.frame
	if not f then
		return
	end
	f:ClearAllPoints()
	local anchor = ns.db and ns.db.statsWindow.point
	if anchor then
		f:SetPoint(anchor.point, UIParent, anchor.relativePoint, anchor.x, anchor.y)
	else
		f:SetPoint("CENTER", UIParent, "CENTER", 0, 60)
	end
end

function StatsWindow:Show()
	self:Create():Show()
end

function StatsWindow:Toggle()
	local f = self:Create()
	f:SetShown(not f:IsShown())
end

function StatsWindow:AskReset()
	local f = self:Create()
	local stats = ns.Stats
	if not stats.char then
		return
	end
	f.confirm.text:SetText(("Reset all world quest statistics for |cffffd100%s|r?\nThis cannot be undone."):format(stats.charKey or "?"))
	f.confirm:Show()
	f.resetButton:Hide()
	local token = {}
	self.confirmToken = token
	C_Timer.After(CONFIRM_TIMEOUT, function()
		if StatsWindow.confirmToken == token then
			StatsWindow:CancelReset()
		end
	end)
end

function StatsWindow:CancelReset()
	local f = self.frame
	self.confirmToken = nil
	if f then
		f.confirm:Hide()
		f.resetButton:Show()
	end
end

local function RecentLine(entry)
	local parts = {}
	if entry.gold and entry.gold > 0 then
		parts[#parts + 1] = ns.FormatMoney(entry.gold)
	end
	if entry.orderResources and entry.orderResources > 0 then
		parts[#parts + 1] = ns.FormatNumber(entry.orderResources) .. " OR"
	end
	if entry.ilvl then
		parts[#parts + 1] = "ilvl " .. entry.ilvl
	end
	if entry.unconfirmed then
		parts[#parts + 1] = "|cffff9900rewards unconfirmed|r"
	end
	local rewards = (#parts > 0) and ("  |cff9d9d9d" .. table.concat(parts, ", ") .. "|r") or ""
	return date("%m/%d %H:%M", entry.t) .. "  " .. (entry.title or ("Quest #" .. tostring(entry.questID))) .. rewards
end

function StatsWindow:Update()
	local f = self.frame
	if not (f and f:IsShown()) then
		return
	end
	local stats = ns.Stats
	local char = stats.char
	f.orderResources.icon:SetTexture(ns.GetOrderResourcesIcon())

	if not char then
		f.character:SetText("Statistics unavailable")
		f.since:SetText("The character could not be identified.")
		for _, key in ipairs({ "completed", "gold", "orderResources", "gear" }) do
			f[key].value:SetText("-")
		end
		f.itemButton.text:SetText("")
		f.itemButton.link = nil
		f.resetButton:Disable()
		return
	end
	f.resetButton:Enable()

	f.character:SetText(stats.charKey)
	f.since:SetText("Tracking since " .. date("%Y-%m-%d %H:%M", char.since))
	f.completed.value:SetText(ns.FormatNumber(char.completed))
	f.gold.value:SetText(ns.FormatMoney(char.gold))
	f.orderResources.value:SetText(ns.FormatNumber(char.orderResources))

	local best = char.bestGear
	if best then
		f.gear.value:SetText("ilvl " .. best.ilvl)
		local name = best.link or best.name or "?"
		local suffix = best.source == "listed" and " |cff9d9d9d(listed item level)|r" or ""
		f.itemButton.text:SetText(name .. suffix .. (best.questTitle and ("  |cff9d9d9d- " .. best.questTitle .. "|r") or ""))
		f.itemButton.link = best.link
		f.gear.icon:SetTexture((best.link and SafeCall(GetItemIcon, best.link)) or ns.CATEGORIES.gear.icon)
	else
		f.gear.value:SetText("none yet")
		f.itemButton.text:SetText("")
		f.itemButton.link = nil
		f.gear.icon:SetTexture(ns.CATEGORIES.gear.icon)
	end

	for i, line in ipairs(f.recent) do
		local entry = char.history[i]
		if entry then
			line:SetText(RecentLine(entry))
		elseif i == 1 then
			line:SetText("|cff9d9d9dNone recorded yet.|r")
		else
			line:SetText("")
		end
	end

	local note = "Only completions seen while this addon is loaded are counted. Gold and Order Resources are credited only when the gain is confirmed."
	if char.unconfirmed > 0 then
		note = note .. ("\n|cffff9900%d completion(s) had rewards that could not be confirmed.|r"):format(char.unconfirmed)
	end
	f.note:SetText(note)
end
