--[[
	World Quest Board - Core
	Target client: World of Warcraft Legion 7.3.5 (build 26972, interface 70300).

	Owns the addon namespace, a small event dispatcher, the account-wide
	interface settings (WorldQuestBoardDB) and the slash commands.
	Per-character statistics are kept separately in Stats.lua
	(WorldQuestBoardStatsDB) so the two can never overwrite each other.
]]
local ADDON_NAME, ns = ...

ns.ADDON_NAME = ADDON_NAME
ns.VERSION = GetAddOnMetadata(ADDON_NAME, "Version") or "?"

local CHAT_PREFIX = "|cff33ccffWorld Quest Board|r: "

---------------------------------------------------------------------------
-- Reward categories. CATEGORY_ORDER is both the display order and the
-- priority used when a quest offers several kinds of reward.
---------------------------------------------------------------------------
ns.CATEGORY_ORDER = { "gear", "ap", "orderres", "gold", "materials", "rep", "other", "unknown" }

ns.CATEGORIES = {
	gear      = { label = "Gear & Equipment",       short = "Gear",            icon = "Interface\\Icons\\INV_Chest_Chain_05" },
	ap        = { label = "Artifact Power",         short = "Artifact Power",  icon = "Interface\\Icons\\INV_Misc_Book_09" },
	orderres  = { label = "Order Resources",        short = "Order Resources", icon = "Interface\\Icons\\INV_Misc_Coin_17" },
	gold      = { label = "Gold",                   short = "Gold",            icon = "Interface\\Icons\\INV_Misc_Coin_01" },
	materials = { label = "Crafting & Professions", short = "Crafting",        icon = "Interface\\Icons\\Trade_Engineering" },
	rep       = { label = "Reputation",             short = "Reputation",      icon = "Interface\\Icons\\Achievement_Reputation_01" },
	other     = { label = "Other Rewards",          short = "Other",           icon = "Interface\\Icons\\INV_Misc_Bag_10" },
	unknown   = { label = "Reward Data Pending",    short = "No data yet",     icon = "Interface\\Icons\\INV_Misc_QuestionMark" },
}

ns.SORT_ORDER = { "time", "zone", "reward", "name" }
ns.SORT_LABELS = { time = "Time left", zone = "Zone", reward = "Reward", name = "Name" }

---------------------------------------------------------------------------
-- Utilities
---------------------------------------------------------------------------
function ns.Print(fmt, ...)
	local msg = (select("#", ...) > 0) and fmt:format(...) or tostring(fmt)
	DEFAULT_CHAT_FRAME:AddMessage(CHAT_PREFIX .. msg)
end

-- Verbose messages, enabled with /wqb log. Used to verify stats attribution in game.
function ns.Debug(fmt, ...)
	if ns.db and ns.db.debug then
		ns.Print("|cff999999" .. ((select("#", ...) > 0) and fmt:format(...) or tostring(fmt)) .. "|r")
	end
end

local function ReturnIfOK(ok, ...)
	if ok then
		return ...
	end
	return nil
end

-- Calls a client API that may be missing or misbehave on a private server.
-- Returns the API's results, or nil if the function is missing or raised an error.
function ns.SafeCall(func, ...)
	if type(func) ~= "function" then
		return nil
	end
	return ReturnIfOK(pcall(func, ...))
end

function ns.FormatNumber(value)
	value = math.floor((tonumber(value) or 0) + 0.5)
	if BreakUpLargeNumbers then
		return BreakUpLargeNumbers(value)
	end
	return tostring(value)
end

function ns.AbbreviateNumber(value)
	value = tonumber(value) or 0
	if value >= 1e9 then
		return (("%.1fB"):format(value / 1e9):gsub("%.0B", "B"))
	elseif value >= 1e6 then
		return (("%.1fM"):format(value / 1e6):gsub("%.0M", "M"))
	elseif value >= 1e4 then
		return ("%dK"):format(math.floor(value / 1e3))
	end
	return tostring(math.floor(value + 0.5))
end

-- Full number below one million, abbreviated above ("6.2B Artifact Power").
function ns.FormatAmount(value)
	if (tonumber(value) or 0) >= 1e6 then
		return ns.AbbreviateNumber(value)
	end
	return ns.FormatNumber(value)
end

function ns.FormatMoney(copper)
	copper = math.floor(tonumber(copper) or 0)
	if GetMoneyString then
		return GetMoneyString(copper, true)
	end
	return ("%dg %ds %dc"):format(math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100)
end

-- Formats a duration in minutes as "45m", "5h 20m" or "2d 4h".
function ns.FormatMinutes(minutes)
	minutes = math.max(0, math.floor(minutes))
	if minutes < 60 then
		return ("%dm"):format(minutes)
	elseif minutes < 1440 then
		return ("%dh %02dm"):format(math.floor(minutes / 60), minutes % 60)
	end
	return ("%dd %dh"):format(math.floor(minutes / 1440), math.floor((minutes % 1440) / 60))
end

-- Coalesces a burst of calls into a single call `delay` seconds after the first one.
function ns.CreateThrottle(delay, func)
	local scheduled = false
	local function Run()
		scheduled = false
		func()
	end
	return function()
		if not scheduled then
			scheduled = true
			C_Timer.After(delay, Run)
		end
	end
end

---------------------------------------------------------------------------
-- Event dispatcher
---------------------------------------------------------------------------
local eventFrame = CreateFrame("Frame")
local handlers = {}

eventFrame:SetScript("OnEvent", function(_, event, ...)
	local list = handlers[event]
	if not list then
		return
	end
	for i = 1, #list do
		-- One failing handler must not prevent the others from running.
		local ok, err = pcall(list[i], event, ...)
		if not ok then
			geterrorhandler()(err)
		end
	end
end)

-- Registers handler(event, ...) for an event. Returns false if the client does
-- not know the event (RegisterEvent raises an error for unknown events).
function ns.RegisterEvent(event, handler)
	if not handlers[event] then
		if not pcall(eventFrame.RegisterEvent, eventFrame, event) then
			return false
		end
		handlers[event] = {}
	end
	table.insert(handlers[event], handler)
	return true
end

---------------------------------------------------------------------------
-- Interface settings (account-wide)
---------------------------------------------------------------------------
local SETTINGS_VERSION = 1

local VALID_POINTS = {
	TOPLEFT = true, TOP = true, TOPRIGHT = true, LEFT = true, CENTER = true,
	RIGHT = true, BOTTOMLEFT = true, BOTTOM = true, BOTTOMRIGHT = true,
}

local function DeepCopy(value)
	if type(value) ~= "table" then
		return value
	end
	local copy = {}
	for k, v in pairs(value) do
		copy[k] = DeepCopy(v)
	end
	return copy
end

local function DefaultSettings()
	local filters = {}
	for _, key in ipairs(ns.CATEGORY_ORDER) do
		filters[key] = true
	end
	return {
		version = SETTINGS_VERSION,
		filters = filters,
		collapsed = {}, -- [category key or "zone:<mapID>"] = true
		sort = "time",
		groupBy = "category", -- "category" or "zone"
		showPetBattles = true,
		panel = {
			shown = true,
			showFilters = true,
			locked = false,
			-- [mode] = { x, y }: panel TOPLEFT relative to the map border's TOPRIGHT,
			-- stored separately for the "windowed" and "fullscreen" map modes.
			offsets = {},
		},
		statsWindow = {
			-- point = { point, relativePoint, x, y } relative to UIParent (nil = default)
		},
		elvuiSkin = true, -- use ElvUI's look when ElvUI is loaded
		debug = false,
	}
end

-- Fills in missing keys and replaces values whose type does not match the default.
local function MergeDefaults(target, defaults)
	for key, default in pairs(defaults) do
		if type(target[key]) ~= type(default) then
			target[key] = DeepCopy(default)
		elseif type(default) == "table" then
			MergeDefaults(target[key], default)
		end
	end
end

local function IsSaneNumber(value, limit)
	return type(value) == "number" and value == value and math.abs(value) <= limit
end

local function IsValidOffset(offset)
	return type(offset) == "table" and IsSaneNumber(offset.x, 5000) and IsSaneNumber(offset.y, 5000)
end

local function IsValidAnchor(anchor)
	return type(anchor) == "table" and VALID_POINTS[anchor.point] and VALID_POINTS[anchor.relativePoint]
		and IsSaneNumber(anchor.x, 10000) and IsSaneNumber(anchor.y, 10000)
end

function ns.InitSettings()
	local db = WorldQuestBoardDB
	if type(db) ~= "table" then
		db = {}
	end
	-- Migrations for future settings versions go here (keyed on db.version).
	MergeDefaults(db, DefaultSettings())

	for key in pairs(db.filters) do
		if not ns.CATEGORIES[key] then
			db.filters[key] = nil
		end
	end
	for key, value in pairs(db.collapsed) do
		local validKey = type(key) == "string" and (ns.CATEGORIES[key] or key:match("^zone:%d+$"))
		if not validKey or value ~= true then
			db.collapsed[key] = nil
		end
	end
	if not ns.SORT_LABELS[db.sort] then
		db.sort = "time"
	end
	if db.groupBy ~= "category" and db.groupBy ~= "zone" then
		db.groupBy = "category"
	end
	for mode, offset in pairs(db.panel.offsets) do
		if (mode ~= "windowed" and mode ~= "fullscreen") or not IsValidOffset(offset) then
			db.panel.offsets[mode] = nil
		end
	end
	if db.statsWindow.point ~= nil and not IsValidAnchor(db.statsWindow.point) then
		db.statsWindow.point = nil
	end

	db.version = SETTINGS_VERSION
	WorldQuestBoardDB = db
	ns.db = db
end

function ns.ResetFilters()
	for _, key in ipairs(ns.CATEGORY_ORDER) do
		ns.db.filters[key] = true
	end
	ns.db.showPetBattles = true
end

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------
local function PrintHelp()
	ns.Print("v%s - commands:", ns.VERSION)
	local lines = {
		"/wqb - show or hide the quest list on the world map",
		"/wqb stats - open or close the statistics window",
		"/wqb resetstats - reset this character's statistics (asks for confirmation)",
		"/wqb reset filters | position | all - restore default filters, panel position or all interface settings",
		"/wqb lock | unlock - lock or unlock dragging of the quest list",
		"/wqb skin - turn the ElvUI look on or off (needs /reload)",
		"/wqb scan - print what the client currently reports (diagnostics)",
		"/wqb aptip - print the raw reward tooltip text of a few Artifact Power quests",
		"/wqb log - toggle detailed statistics messages in chat",
	}
	for _, line in ipairs(lines) do
		DEFAULT_CHAT_FRAME:AddMessage("   " .. line)
	end
end

local function HandleSlash(input)
	local cmd, rest = (input or ""):lower():match("^%s*(%S*)%s*(.-)%s*$")
	if cmd == "" or cmd == "toggle" then
		ns.Panel:SetUserShown(not ns.db.panel.shown)
		if not (WorldMapFrame and WorldMapFrame:IsShown()) then
			ns.Print("Quest list %s. It appears beside the world map (M).", ns.db.panel.shown and "enabled" or "disabled")
		end
	elseif cmd == "show" or cmd == "hide" then
		ns.Panel:SetUserShown(cmd == "show")
	elseif cmd == "stats" then
		ns.StatsWindow:Toggle()
	elseif cmd == "resetstats" then
		ns.StatsWindow:Show()
		ns.StatsWindow:AskReset()
	elseif cmd == "reset" then
		if rest == "filters" then
			ns.ResetFilters()
			ns.Print("Filters reset.")
		elseif rest == "position" then
			wipe(ns.db.panel.offsets)
			ns.db.statsWindow.point = nil
			ns.StatsWindow:RestorePosition()
			ns.Print("Window positions reset.")
		elseif rest == "all" then
			WorldQuestBoardDB = nil
			ns.InitSettings()
			ns.StatsWindow:RestorePosition()
			ns.Print("All interface settings reset (statistics are not affected).")
		else
			ns.Print("Usage: /wqb reset filters | position | all")
			return
		end
		ns.Panel:Reanchor()
		ns.Panel:Refresh()
	elseif cmd == "lock" or cmd == "unlock" then
		ns.db.panel.locked = (cmd == "lock")
		ns.Print("Quest list %s.", ns.db.panel.locked and "locked" or "unlocked")
	elseif cmd == "skin" then
		ns.db.elvuiSkin = not ns.db.elvuiSkin
		ns.Print("ElvUI look %s. Type /reload to apply.", ns.db.elvuiSkin and "enabled" or "disabled")
	elseif cmd == "scan" or cmd == "debug" then
		ns.Data:PrintDiagnostics()
	elseif cmd == "aptip" then
		ns.Data:PrintRewardTooltips("ap", 3)
	elseif cmd == "log" then
		ns.db.debug = not ns.db.debug
		ns.Print("Detailed statistics messages %s.", ns.db.debug and "enabled" or "disabled")
	else
		PrintHelp()
	end
end

SLASH_WORLDQUESTBOARD1 = "/wqb"
SLASH_WORLDQUESTBOARD2 = "/worldquestboard"
SlashCmdList["WORLDQUESTBOARD"] = HandleSlash

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------
ns.RegisterEvent("ADDON_LOADED", function(_, name)
	if name == ADDON_NAME then
		ns.InitSettings()
		ns.Stats:InitDB()
	end
end)

ns.RegisterEvent("PLAYER_LOGIN", function()
	ns.Stats:OnLogin()
	ns.Panel:Init()
	ns.StatsWindow:Init()
end)
