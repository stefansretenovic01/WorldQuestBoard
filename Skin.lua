--[[
	World Quest Board - ElvUI skin
	When ElvUI is loaded, restyles the quest list, the map's "WQ" button and the
	statistics window with ElvUI's own skin helpers so they match an ElvUI-skinned
	world map.

	ElvUI 10.x (Legion) API used: the global engine table ElvUI = { E, L, V, P, G },
	E.initialized, E:GetModule("Skins") -> S:HandleButton / HandleCheckBox /
	HandleScrollBar / HandleCloseButton / HandleIcon, and the frame toolkit methods
	ElvUI adds to every widget (StripTextures, SetTemplate, CreateBackdrop).

	The skin follows ElvUI's own switches: it is skipped when ElvUI's Blizzard skins
	or its world map skin are disabled (/ec > Skins), or with /wqb skin. Skinned frames
	cannot be restored, so turning it off takes effect after /reload.
]]
local ADDON_NAME, ns = ...

local Skin = {}
ns.Skin = Skin

local ELVUI_MEDIA = "Interface\\AddOns\\ElvUI\\media\\textures\\"
local BLIZZARD_PLUS = "Interface\\Buttons\\UI-PlusButton-Up"
local BLIZZARD_MINUS = "Interface\\Buttons\\UI-MinusButton-Up"

-- Returns ElvUI's engine and skin module when the skin should be applied, else nil.
function Skin:GetElvUI()
	if ns.db and ns.db.elvuiSkin == false then
		return nil
	end
	local engine = _G.ElvUI
	local E = type(engine) == "table" and engine[1]
	if type(E) ~= "table" or not E.initialized or type(E.GetModule) ~= "function" then
		return nil
	end
	local blizzard = E.private and E.private.skins and E.private.skins.blizzard
	if blizzard and (blizzard.enable == false or blizzard.worldmap == false) then
		return nil
	end
	local ok, S = pcall(E.GetModule, E, "Skins")
	if not ok or type(S) ~= "table" then
		return nil
	end
	return E, S
end

function Skin:IsActive()
	return self.active == true
end

function Skin:GetExpandTextures()
	if self.active then
		return ELVUI_MEDIA .. "PlusButton", ELVUI_MEDIA .. "MinusButton"
	end
	return BLIZZARD_PLUS, BLIZZARD_MINUS
end

-- Runs a skinning step; a failure (e.g. a different ElvUI version) leaves the
-- Blizzard look in place instead of raising an error every time the map opens.
local function Try(label, func, ...)
	local ok, err = pcall(func, ...)
	if not ok then
		ns.Debug("ElvUI skin step '%s' failed: %s", label, tostring(err))
	end
	return ok
end

local function FlatHighlight(button)
	local highlight = button:GetHighlightTexture()
	if highlight then
		highlight:SetTexture(nil)
		highlight:SetColorTexture(1, 1, 1, 0.08)
		highlight:SetAllPoints()
	end
end

---------------------------------------------------------------------------
-- Quest list
---------------------------------------------------------------------------
-- Returns true when the skin was applied by this call.
function Skin:ApplyPanel(panel)
	if panel.skinApplied or not panel.frame then
		return false
	end
	local E, S = self:GetElvUI()
	if not E then
		return false
	end
	panel.skinApplied = true
	self.active = true

	local f = panel.frame
	Try("panel", function()
		f:StripTextures() -- title bar, borders and marble inset of BasicFrameTemplateWithInset
		f:SetTemplate("Transparent")
	end)
	Try("close button", S.HandleCloseButton, S, f.CloseButton, f)
	for _, button in ipairs({ panel.filterButton, panel.sortButton, panel.groupButton, panel.statsButton, panel.resetButton, panel.mapButton }) do
		Try("button", S.HandleButton, S, button)
	end
	for _, checkbox in pairs(panel.checkboxes) do
		Try("checkbox", S.HandleCheckBox, S, checkbox)
	end
	Try("checkbox", S.HandleCheckBox, S, panel.petCheckbox)
	Try("filter box", function()
		panel.filterBg:SetColorTexture(1, 1, 1, 0.04)
	end)
	Try("scroll bar", function()
		S:HandleScrollBar(panel.scroll.ScrollBar or _G[panel.scroll:GetName() .. "ScrollBar"])
	end)

	-- Rows and headers created before the skin was applied.
	for _, header in ipairs(panel.headers) do
		self:StyleHeader(header)
	end
	for _, row in ipairs(panel.rows) do
		self:StyleRow(row)
	end
	return true
end

function Skin:StyleHeader(header)
	if not self.active or header.skinApplied then
		return
	end
	header.skinApplied = true
	Try("header", function()
		header.background:SetColorTexture(1, 1, 1, 0.06)
		FlatHighlight(header)
		header.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	end)
end

function Skin:StyleRow(row)
	if not self.active or row.skinApplied then
		return
	end
	row.skinApplied = true
	local _, S = self:GetElvUI()
	Try("row", function()
		FlatHighlight(row)
		if S then
			-- 1px ElvUI border around the reward icon. The icon moves to row.backdrop (one
			-- frame level below the row), so the amount text on the row still draws above it.
			S:HandleIcon(row.icon, row)
		end
	end)
end

---------------------------------------------------------------------------
-- Statistics window
---------------------------------------------------------------------------
function Skin:ApplyStats(window)
	local f = window.frame
	if not f or f.skinApplied then
		return
	end
	local E, S = self:GetElvUI()
	if not E then
		return
	end
	f.skinApplied = true
	Try("stats frame", function()
		f:StripTextures()
		f:SetTemplate("Transparent")
	end)
	Try("stats close", S.HandleCloseButton, S, f.CloseButton, f)
	for _, button in ipairs({ f.resetButton, f.confirmYes, f.confirmNo }) do
		Try("stats button", S.HandleButton, S, button)
	end
	for _, key in ipairs({ "completed", "gold", "orderResources", "gear" }) do
		Try("stats icon", function()
			f[key].icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
		end)
	end
end
