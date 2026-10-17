--[[
	World Quest Board - Stats
	Per-character world quest statistics, stored in WorldQuestBoardStatsDB.chars
	under "Name-Realm" (the character GUID is kept to detect renames and re-used names).

	What Legion 7.3.5 exposes, and how each statistic is established:
	* Completion: QUEST_TURNED_IN(questID, xp, money) fires for world quests (the
	  objective tracker uses it the same way); WORLD_QUEST_COMPLETED_BY_SPELL(questID)
	  fires when an order hall ability completes one. A completion is counted when the
	  quest is a world quest (QuestUtils_IsQuestWorldQuest, or seen as one this session)
	  and not an emissary (IsQuestBounty). A quest disappearing from the map is never
	  treated as a completion. The same quest ID is only counted once per hour, which
	  absorbs duplicate events (world quests do not respawn within an hour).
	* Gold: the money argument of QUEST_TURNED_IN is the amount the server paid
	  (including the max-level XP conversion). If it is missing, the quest's listed
	  money is credited only when PLAYER_MONEY shows an increase of at least that
	  amount within a few seconds of the completion.
	* Order Resources: no event carries the amount. The quest's listed amount is
	  credited only when the Order Resources total rises by at least that amount
	  within a few seconds of the completion.
	* Gear: the item from the loot message ("You receive item: ...") matching the
	  quest's listed reward item is used, so Warforged/Titanforged upgrades count. If no
	  matching loot message arrives (e.g. the reward was mailed), the listed item level
	  is used and marked as such.
	Rewards that cannot be confirmed this way are not credited; the completion is
	still counted and the history entry is flagged "unconfirmed".
]]
local ADDON_NAME, ns = ...
local SafeCall = ns.SafeCall

local Stats = {}
ns.Stats = Stats

local STATS_VERSION = 1
local DEDUPE_SECONDS = 3600
local WINDOW_BEFORE = 3     -- seconds a reward may arrive before the completion event
local WINDOW_AFTER = 8      -- seconds a reward may arrive after the completion event
local LOG_KEEP_SECONDS = 30
local LOGIN_SETTLE_SECONDS = 10
local HISTORY_SIZE = 25

local moneyLog, currencyLog, lootLog = {}, {}, {}
local pending = {}
local lastMoney, lastOrderResources
local loginTime = 0

---------------------------------------------------------------------------
-- Saved data
---------------------------------------------------------------------------
local function NewCharRecord(guid)
	return {
		guid = guid,
		since = time(),
		completed = 0,
		gold = 0,
		orderResources = 0,
		unconfirmed = 0,
		bestGear = nil,
		recent = {},   -- questID -> time() of the last counted completion (dedupe)
		history = {},  -- newest first
	}
end

local function SanitizeChar(rec)
	if type(rec) ~= "table" then
		return nil
	end
	for _, key in ipairs({ "completed", "gold", "orderResources", "unconfirmed" }) do
		local value = rec[key]
		if type(value) ~= "number" or value ~= value or value < 0 or value == math.huge then
			rec[key] = 0
		end
	end
	if type(rec.since) ~= "number" then
		rec.since = time()
	end
	if type(rec.recent) ~= "table" then
		rec.recent = {}
	end
	for questID, stamp in pairs(rec.recent) do
		if type(questID) ~= "number" or type(stamp) ~= "number" then
			rec.recent[questID] = nil
		end
	end
	local history = {}
	if type(rec.history) == "table" then
		for _, entry in ipairs(rec.history) do
			if type(entry) == "table" and type(entry.t) == "number" and #history < HISTORY_SIZE then
				history[#history + 1] = entry
			end
		end
	end
	rec.history = history
	local gear = rec.bestGear
	if gear ~= nil and (type(gear) ~= "table" or type(gear.ilvl) ~= "number") then
		rec.bestGear = nil
	end
	return rec
end

function Stats:InitDB()
	local db = WorldQuestBoardStatsDB
	if type(db) ~= "table" then
		db = {}
	end
	if type(db.chars) ~= "table" then
		db.chars = {}
	end
	for key, rec in pairs(db.chars) do
		if type(key) ~= "string" then
			db.chars[key] = nil
		else
			db.chars[key] = SanitizeChar(rec)
		end
	end
	db.version = STATS_VERSION
	WorldQuestBoardStatsDB = db
	self.db = db
end

function Stats:GetCharacterKey()
	local name = UnitName("player")
	if not name or name == "" or name == UNKNOWNOBJECT then
		return nil
	end
	return name .. "-" .. (GetRealmName() or "?")
end

local function GetOrderResources()
	local _, amount = SafeCall(GetCurrencyInfo, ns.ORDER_RESOURCES_ID)
	return tonumber(amount)
end

function Stats:OnLogin()
	if not self.db then
		self:InitDB()
	end
	local key = self:GetCharacterKey()
	if not key then
		return -- statistics stay disabled rather than being stored under a wrong key
	end
	local guid = UnitGUID("player")
	local chars = self.db.chars
	local rec = chars[key]
	if rec and rec.guid and guid and rec.guid ~= guid then
		-- Same name and realm, different character (deleted and re-created): keep the old data aside.
		chars[key .. " (" .. rec.guid .. ")"] = rec
		rec = nil
	end
	if not rec and guid then
		-- Renamed character: take over the record stored under the old name.
		for otherKey, other in pairs(chars) do
			if otherKey ~= key and other.guid == guid then
				rec = other
				chars[otherKey] = nil
				break
			end
		end
	end
	rec = rec or NewCharRecord(guid)
	rec.guid = rec.guid or guid
	chars[key] = rec
	self.char, self.charKey = rec, key

	local now = time()
	for questID, stamp in pairs(rec.recent) do
		if now - stamp > 86400 then
			rec.recent[questID] = nil
		end
	end

	loginTime = GetTime()
	lastMoney = GetMoney()
	lastOrderResources = GetOrderResources()
end

function Stats:WasCompletedRecently(questID)
	local stamp = self.char and self.char.recent[questID]
	return stamp ~= nil and (time() - stamp) < DEDUPE_SECONDS
end

---------------------------------------------------------------------------
-- Change listeners (the statistics window)
---------------------------------------------------------------------------
function Stats:NotifyChanged()
	if ns.StatsWindow and ns.StatsWindow.Update then
		ns.StatsWindow:Update()
	end
end

---------------------------------------------------------------------------
-- Observed gains
---------------------------------------------------------------------------
local function Prune(log, now)
	while log[1] and now - log[1].t > LOG_KEEP_SECONDS do
		table.remove(log, 1)
	end
end

local function PushGain(log, amount)
	local now = GetTime()
	Prune(log, now)
	log[#log + 1] = { t = now, remaining = amount }
end

-- Consumes `amount` from a gain observed within the window around `startedAt`.
local function ClaimGain(log, startedAt, amount)
	for _, entry in ipairs(log) do
		if entry.remaining >= amount and entry.t >= startedAt - WINDOW_BEFORE and entry.t <= startedAt + WINDOW_AFTER then
			entry.remaining = entry.remaining - amount
			return true
		end
	end
	return false
end

local function ClaimLoot(startedAt, itemID)
	for _, entry in ipairs(lootLog) do
		if not entry.claimed and entry.itemID == itemID
			and entry.t >= startedAt - WINDOW_BEFORE and entry.t <= startedAt + WINDOW_AFTER then
			entry.claimed = true
			return entry
		end
	end
	return nil
end

-- Prefixes of the "You receive item/loot: %s" messages, built from GlobalStrings so
-- that only the player's own loot matches (locale independent).
local LOOT_PREFIXES = {}
for _, format in ipairs({ LOOT_ITEM_PUSHED_SELF, LOOT_ITEM_PUSHED_SELF_MULTIPLE, LOOT_ITEM_SELF, LOOT_ITEM_SELF_MULTIPLE }) do
	if type(format) == "string" then
		local prefix = format:match("^(.-)%%")
		if prefix and prefix ~= "" then
			LOOT_PREFIXES[#LOOT_PREFIXES + 1] = prefix
		end
	end
end
if #LOOT_PREFIXES == 0 then
	LOOT_PREFIXES = { "You receive item: ", "You receive loot: " }
end

local function IsOwnLootMessage(message)
	for _, prefix in ipairs(LOOT_PREFIXES) do
		if message:sub(1, #prefix) == prefix then
			return true
		end
	end
	return false
end
Stats.IsOwnLootMessage = IsOwnLootMessage

local function Settled()
	return GetTime() - loginTime >= LOGIN_SETTLE_SECONDS
end

ns.RegisterEvent("PLAYER_MONEY", function()
	local money = GetMoney()
	if lastMoney and money > lastMoney and Settled() then
		PushGain(moneyLog, money - lastMoney)
	end
	lastMoney = money
	Stats:Resolve()
end)

ns.RegisterEvent("CURRENCY_DISPLAY_UPDATE", function()
	local amount = GetOrderResources()
	if not amount then
		return
	end
	-- Shortly after login the currency list may still be loading (0 -> real total);
	-- that jump is a baseline, not a gain.
	if lastOrderResources and amount > lastOrderResources and Settled() then
		PushGain(currencyLog, amount - lastOrderResources)
	end
	lastOrderResources = amount
	Stats:Resolve()
end)

ns.RegisterEvent("CHAT_MSG_LOOT", function(_, message)
	if type(message) ~= "string" or not IsOwnLootMessage(message) then
		return
	end
	local link = message:match("|c%x+|Hitem:.-|h.-|h|r")
	local itemID = link and tonumber(link:match("|Hitem:(%d+)"))
	if itemID then
		local now = GetTime()
		Prune(lootLog, now)
		lootLog[#lootLog + 1] = { t = now, itemID = itemID, link = link }
		Stats:Resolve()
	end
end)

---------------------------------------------------------------------------
-- Completions
---------------------------------------------------------------------------
local function ExpectedRewards(questID)
	local rewards = ns.Data:ReadRewards(questID) or ns.Data:GetCachedRewards(questID)
	local expected = { money = 0, orderResources = 0 }
	if rewards then
		expected.known = true
		expected.money = rewards.money or 0
		for _, currency in ipairs(rewards.currencies) do
			if currency.id == ns.ORDER_RESOURCES_ID then
				expected.orderResources = expected.orderResources + (currency.amount or 0)
			end
		end
		for _, item in ipairs(rewards.items) do
			if item.isGear and item.itemID then
				expected.gear = { itemID = item.itemID, ilvl = item.ilvl, name = item.name, quality = item.quality }
				break
			end
		end
	end
	return expected
end

local function FindPending(questID)
	for _, rec in ipairs(pending) do
		if rec.questID == questID then
			return rec
		end
	end
	return nil
end

function Stats:IsCountableWorldQuest(questID)
	if IsQuestBounty and SafeCall(IsQuestBounty, questID) then
		return false
	end
	return ns.Data.known[questID] ~= nil or ns.Data.IsWorldQuest(questID)
end

function Stats:CreditGold(rec, amount, how)
	self.char.gold = self.char.gold + amount
	rec.entry.gold = (rec.entry.gold or 0) + amount
	rec.needGold = nil
	ns.Debug("+%s gold from %s (%s)", ns.FormatMoney(amount), rec.entry.title or rec.questID, how)
end

function Stats:CreditOrderResources(rec, amount)
	self.char.orderResources = self.char.orderResources + amount
	rec.entry.orderResources = (rec.entry.orderResources or 0) + amount
	rec.needOrderResources = nil
	ns.Debug("+%d Order Resources from %s", amount, rec.entry.title or rec.questID)
end

-- link: the received item (preferred); listed: the quest's reward listing (fallback)
function Stats:CreditGear(rec, link, listed, source)
	rec.needGear = nil
	local ilvl, name, quality
	if link then
		ilvl = ns.Data:GetItemLevelFromLink(link)
		name, _, quality = GetItemInfo(link)
	end
	if not ilvl and listed and listed.ilvl then
		ilvl, source = listed.ilvl, (link and "received, listed item level" or "listed")
	end
	if not ilvl then
		ns.Debug("Gear reward of %s could not be measured; not recorded.", rec.entry.title or rec.questID)
		return
	end
	name = name or (listed and listed.name)
	quality = quality or (listed and listed.quality)
	link = link or (listed and select(2, GetItemInfo(listed.itemID)))
	rec.entry.ilvl, rec.entry.item = ilvl, link or name

	local best = self.char.bestGear
	if not best or ilvl > best.ilvl then
		self.char.bestGear = {
			ilvl = ilvl, link = link, name = name, quality = quality, source = source,
			questID = rec.questID, questTitle = rec.entry.title, t = time(),
		}
		ns.Debug("New highest item level from a world quest: %d (%s)", ilvl, source)
	end
end

function Stats:OnQuestCompleted(questID, source, money)
	if not self.char or type(questID) ~= "number" or not self:IsCountableWorldQuest(questID) then
		return
	end
	money = tonumber(money)

	if self:WasCompletedRecently(questID) then
		-- Second event for the same completion (e.g. turn-in after completion by spell):
		-- never counted twice, but it may carry the gold amount the first one lacked.
		local rec = FindPending(questID)
		if rec and money and money > 0 and not rec.goldFromEvent then
			if rec.needGold then
				self:CreditGold(rec, money, "turn-in event")
			end
			rec.goldFromEvent = money
			self:NotifyChanged()
		end
		return
	end

	local char = self.char
	char.recent[questID] = time()
	char.completed = char.completed + 1

	local known = ns.Data.known[questID]
	local title = (known and known.title) or SafeCall(C_TaskQuest.GetQuestInfoByQuestID, questID)
	local entry = { t = time(), questID = questID, title = title, source = source }
	table.insert(char.history, 1, entry)
	while #char.history > HISTORY_SIZE do
		table.remove(char.history)
	end

	local expected = ExpectedRewards(questID)
	local rec = { questID = questID, startedAt = GetTime(), entry = entry }
	if money and money > 0 then
		self:CreditGold(rec, money, "turn-in event")
		rec.goldFromEvent = money
	elseif expected.money > 0 then
		rec.needGold = expected.money
	end
	if expected.orderResources > 0 then
		rec.needOrderResources = expected.orderResources
	end
	if expected.gear then
		rec.needGear = expected.gear
	end
	if not expected.known then
		entry.rewardsUnknown = true
	end
	ns.Debug("World quest completed: %s (%s)", title or questID, source)

	pending[#pending + 1] = rec
	self:Resolve()
	C_Timer.After(WINDOW_AFTER + 0.5, function() Stats:Resolve() end)
	self:NotifyChanged()
end

-- Matches pending completions with observed gains; finalises them after the window.
function Stats:Resolve()
	if #pending == 0 or not self.char then
		return
	end
	local now = GetTime()
	local changed = false
	for i = #pending, 1, -1 do
		local rec = pending[i]
		if rec.goldFromEvent and not rec.goldAbsorbed then
			-- Remove the event-reported gold from the observed gains so that no other
			-- pending completion can claim the same money.
			rec.goldAbsorbed = ClaimGain(moneyLog, rec.startedAt, rec.goldFromEvent)
		end
		if rec.needGold and ClaimGain(moneyLog, rec.startedAt, rec.needGold) then
			self:CreditGold(rec, rec.needGold, "money change")
			changed = true
		end
		if rec.needOrderResources and ClaimGain(currencyLog, rec.startedAt, rec.needOrderResources) then
			self:CreditOrderResources(rec, rec.needOrderResources)
			changed = true
		end
		if rec.needGear then
			local loot = ClaimLoot(rec.startedAt, rec.needGear.itemID)
			if loot then
				self:CreditGear(rec, loot.link, rec.needGear, "received")
				changed = true
			end
		end
		if now - rec.startedAt > WINDOW_AFTER then
			if rec.needGear then
				self:CreditGear(rec, nil, rec.needGear, "listed")
				changed = true
			end
			if rec.needGold or rec.needOrderResources then
				rec.entry.unconfirmed = true
				self.char.unconfirmed = self.char.unconfirmed + 1
				ns.Debug("Rewards of %s could not be confirmed and were not credited.", rec.entry.title or rec.questID)
				changed = true
			end
			table.remove(pending, i)
		end
	end
	if changed then
		self:NotifyChanged()
	end
end

ns.RegisterEvent("QUEST_TURNED_IN", function(_, questID, _, money)
	Stats:OnQuestCompleted(questID, "turn-in", money)
end)

ns.RegisterEvent("WORLD_QUEST_COMPLETED_BY_SPELL", function(_, questID)
	Stats:OnQuestCompleted(questID, "spell", nil)
end)

---------------------------------------------------------------------------
-- Reset
---------------------------------------------------------------------------
function Stats:ResetCurrent()
	if not (self.db and self.charKey) then
		return false
	end
	local old = self.char
	local rec = NewCharRecord(old and old.guid or UnitGUID("player"))
	-- Keep the dedupe list so a quest completed seconds ago is not counted again.
	rec.recent = old and old.recent or {}
	self.db.chars[self.charKey] = rec
	self.char = rec
	wipe(pending)
	ns.Print("Statistics reset for %s.", self.charKey)
	self:NotifyChanged()
	return true
end
