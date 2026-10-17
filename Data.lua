--[[
	World Quest Board - Data
	Finds the Legion zones, scans the active world quests, reads their rewards
	and assigns every quest one reward category.

	Legion 7.3.5 behaviour this module relies on (verified against the 7.3.5 FrameXML):
	* C_TaskQuest.GetQuestsForPlayerByMapID(mapAreaID) returns the tasks of any zone,
	  not only of the map being displayed (Blizzard's WorldMapBountyBoard queries
	  every zone this way). Entries look like { questId, x, y, numObjectives, inProgress }.
	* The result also contains bonus objectives. QuestUtils_IsQuestWorldQuest filters
	  them, but GetQuestTagInfo (and so that test) only works once HaveQuestData is true.
	* Reward data arrives asynchronously: when HaveQuestRewardData is false we call
	  C_TaskQuest.RequestPreloadRewardData, and QUEST_LOG_UPDATE fires once it lands.
	* The item level and artifact power amount of a reward are not exposed by any API;
	  they only appear in the reward tooltip (GameTooltip:SetQuestLogItem("reward", i, questID)).
	* Reputation amounts are not exposed at all; only the quest's faction is.
]]
local ADDON_NAME, ns = ...
local SafeCall = ns.SafeCall

local Data = {}
ns.Data = Data

local ORDER_RESOURCES_ID = 1220
ns.ORDER_RESOURCES_ID = ORDER_RESOURCES_ID

local REWARD_CACHE_SECONDS = 30 * 60
local MAX_READ_ATTEMPTS = 6 -- incomplete reward reads (item info/tooltip not cached yet) are retried this often

-- Item class constants (with the 7.x numeric values as fallback)
local CLASS_WEAPON = LE_ITEM_CLASS_WEAPON or 2
local CLASS_GEM = LE_ITEM_CLASS_GEM or 3
local CLASS_ARMOR = LE_ITEM_CLASS_ARMOR or 4
local CLASS_TRADEGOODS = LE_ITEM_CLASS_TRADEGOODS or 7
local CLASS_RECIPE = LE_ITEM_CLASS_RECIPE or 9
local GEM_ARTIFACT_RELIC = LE_ITEM_GEM_ARTIFACTRELIC or 11

local AP_LABEL = ARTIFACT_POWER or "Artifact Power"

Data.quests = {}        -- array of quest records from the last scan
Data.byID = {}          -- questID -> quest record from the last scan
Data.known = {}         -- questID -> { title } for every world quest seen this session (used by Stats)
Data.waitingItems = {}  -- itemID -> true while GetItemInfo has no data yet
Data.scanInfo = {}      -- diagnostics of the last scan
Data.lastScan = nil     -- time() of the last scan

local rewardCache = {}  -- questID -> reward table
local readAttempts = {} -- questID -> number of incomplete reads

---------------------------------------------------------------------------
-- Zones
---------------------------------------------------------------------------
-- Continent index (for GetMapZones) and continent map area ID (for emissaries).
local LEGION_CONTINENTS = {
	{ index = WORLDMAP_BROKEN_ISLES_ID or 8, mapID = 1007 }, -- Broken Isles
	{ index = WORLDMAP_ARGUS_ID or 9, mapID = 1184 },        -- Argus
}

-- 7.x map area IDs, queried in addition to whatever GetMapZones reports so that
-- zones missing from the continent list (e.g. Eye of Azshara) are still covered.
local FALLBACK_ZONES = {
	1015, -- Azsuna
	1018, -- Val'sharah
	1024, -- Highmountain
	1017, -- Stormheim
	1033, -- Suramar
	1096, -- Eye of Azshara
	1021, -- Broken Shore
	1014, -- Dalaran
	1135, -- Krokuun
	1170, -- Mac'Aree
	1171, -- Antoran Wastes
}

local zoneList

function Data:GetZones()
	if zoneList then
		return zoneList
	end
	local list, seen = {}, {}
	local continents = { SafeCall(GetMapContinents) } -- mapID, name, mapID, name, ...
	for _, continent in ipairs(LEGION_CONTINENTS) do
		local mapID = continents[continent.index * 2 - 1]
		if type(mapID) == "number" and mapID > 0 then
			continent.mapID = mapID
		end
		local zones = { SafeCall(GetMapZones, continent.index) } -- mapID, name, mapID, name, ...
		for i = 1, #zones, 2 do
			local zoneID = zones[i]
			if type(zoneID) == "number" and not seen[zoneID] then
				seen[zoneID] = true
				list[#list + 1] = { id = zoneID, name = zones[i + 1] }
			end
		end
	end
	for _, zoneID in ipairs(FALLBACK_ZONES) do
		if not seen[zoneID] then
			seen[zoneID] = true
			list[#list + 1] = { id = zoneID }
		end
	end
	for _, zone in ipairs(list) do
		zone.name = SafeCall(GetMapNameByID, zone.id) or zone.name or ("Map " .. zone.id)
	end
	zoneList = list
	return list
end

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------
local function IsWorldQuest(questID)
	if QuestUtils_IsQuestWorldQuest then
		return SafeCall(QuestUtils_IsQuestWorldQuest, questID) and true or false
	end
	local _, _, worldQuestType = SafeCall(GetQuestTagInfo, questID)
	return worldQuestType ~= nil
end
Data.IsWorldQuest = IsWorldQuest

local function Colorize(text, quality)
	local color = quality and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality]
	if text and color and color.hex then
		return color.hex .. text .. "|r"
	end
	return text
end

function ns.GetOrderResourcesIcon()
	local _, _, texture = SafeCall(GetCurrencyInfo, ORDER_RESOURCES_ID)
	return texture or ns.CATEGORIES.orderres.icon
end

function ns.GetArtifactIcon()
	if C_ArtifactUI and C_ArtifactUI.GetEquippedArtifactInfo then
		local _, _, _, icon = SafeCall(C_ArtifactUI.GetEquippedArtifactInfo)
		if icon then
			return icon
		end
	end
	return ns.CATEGORIES.ap.icon
end

function ns.GetCategoryIcon(key)
	if key == "orderres" then
		return ns.GetOrderResourcesIcon()
	elseif key == "ap" then
		return ns.GetArtifactIcon()
	end
	return ns.CATEGORIES[key] and ns.CATEGORIES[key].icon or ns.CATEGORIES.other.icon
end

---------------------------------------------------------------------------
-- Tooltip scanning (item level, artifact power amount, reputation tokens)
---------------------------------------------------------------------------
local scanTip

local function PrepareScanTooltip()
	if not scanTip then
		scanTip = CreateFrame("GameTooltip", "WorldQuestBoardScanTooltip", nil, "GameTooltipTemplate")
	end
	scanTip:SetOwner(WorldFrame, "ANCHOR_NONE")
	scanTip:ClearLines()
	return scanTip
end

local function CollectLines(tip)
	local lines = {}
	local name = tip:GetName()
	for i = 1, tip:NumLines() or 0 do
		local fontString = _G[name .. "TextLeft" .. i]
		local text = fontString and fontString:GetText()
		if text and text ~= "" then
			lines[#lines + 1] = text
		end
	end
	tip:Hide()
	return lines
end

local function ScanRewardTooltip(index, questID)
	local tip = PrepareScanTooltip()
	if not pcall(tip.SetQuestLogItem, tip, "reward", index, questID) then
		tip:Hide()
		return {}
	end
	return CollectLines(tip)
end

local function ScanLinkTooltip(link)
	local tip = PrepareScanTooltip()
	if not pcall(tip.SetHyperlink, tip, link) then
		tip:Hide()
		return {}
	end
	return CollectLines(tip)
end

-- Converts a GlobalStrings format ("Item Level %d") into a Lua pattern.
local function FormatToPattern(fmt)
	fmt = fmt:gsub("%%%d%$", "%%")                         -- "%1$s" -> "%s"
	fmt = fmt:gsub("([%^%$%(%)%.%[%]%*%+%-%?])", "%%%1")   -- escape magic characters
	fmt = fmt:gsub("%%s", "(.+)")
	fmt = fmt:gsub("%%d", "(%%d+)")
	return fmt
end

local ITEM_LEVEL_PATTERN = "^" .. FormatToPattern(ITEM_LEVEL or "Item Level %d")
local AP_TEXT = AP_LABEL:lower()
local REPUTATION_TEXT = (REPUTATION or "Reputation"):lower()
local GROUP_SEPARATOR = LARGE_NUMBER_SEPERATOR or ","
local DECIMAL_SEPARATOR = DECIMAL_SEPERATOR or "."

-- Words and abbreviations that may follow a number in tooltip text, e.g.
-- "2.5 million", "6 billion", "96M". English forms plus the client's own strings.
local MULTIPLIERS = {}
local function AddMultiplier(word, factor)
	if type(word) == "string" then
		word = word:lower():gsub("^%s+", ""):gsub("%s+$", "")
		if word:find("^%a+$") then
			MULTIPLIERS[word] = factor
		end
	end
end
for word, factor in pairs({ thousand = 1e3, million = 1e6, billion = 1e9, trillion = 1e12, k = 1e3, m = 1e6, b = 1e9 }) do
	AddMultiplier(word, factor)
end
AddMultiplier(FIRST_NUMBER, 1e3)
AddMultiplier(SECOND_NUMBER, 1e6)
AddMultiplier(THIRD_NUMBER, 1e9)
AddMultiplier(FOURTH_NUMBER, 1e12)
AddMultiplier(FIRST_NUMBER_CAP_NO_SPACE, 1e3)
AddMultiplier(SECOND_NUMBER_CAP_NO_SPACE, 1e6)
AddMultiplier(THIRD_NUMBER_CAP_NO_SPACE, 1e9)

local function EscapePattern(text)
	return (text:gsub("(%p)", "%%%1"))
end

-- Removes colour codes and turns non-breaking spaces into spaces, so that a number
-- and its "million"/"billion" word are adjacent in plain text.
local function CleanText(text)
	text = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("\194\160", " ")
	return text
end

-- "1,250" -> 1250, "2.5" followed by " million" -> 2500000, "96" followed by "M" -> 96000000
local function ParseLocalizedNumber(numberText, following)
	if GROUP_SEPARATOR ~= "" then
		numberText = numberText:gsub(EscapePattern(GROUP_SEPARATOR), "")
	end
	if DECIMAL_SEPARATOR ~= "." then
		numberText = numberText:gsub(EscapePattern(DECIMAL_SEPARATOR), ".")
	end
	local value = tonumber(numberText)
	if not value then
		return nil
	end
	local word = (following or ""):match("^%s*(%a+)")
	local factor = word and MULTIPLIERS[word:lower()]
	if factor then
		value = value * factor
	end
	return math.floor(value + 0.5)
end

local function ParseItemLevel(lines)
	for i = 1, math.min(#lines, 8) do
		local value = CleanText(lines[i]):match(ITEM_LEVEL_PATTERN)
		if value then
			return tonumber(value)
		end
	end
	return nil
end

-- Returns the amount from a line such as "Use: Grants 2.5 million Artifact Power ...".
local function ParseArtifactPower(lines)
	for i = 2, #lines do
		local line = CleanText(lines[i])
		local lower = line:lower()
		if lower:find(AP_TEXT, 1, true) or lower:find("artifact power", 1, true) then
			local numberText, following = line:match("(%d[%d%.,]*)(.*)")
			if numberText then
				local value = ParseLocalizedNumber(numberText, following)
				if value and value > 0 then
					return value
				end
			end
		end
	end
	return nil
end

local function MentionsReputation(lines)
	for i = 2, #lines do
		if lines[i]:lower():find(REPUTATION_TEXT, 1, true) then
			return true
		end
	end
	return false
end

-- Exposed for tests and for Stats (actual item level of a received item link).
Data.ParseItemLevel = ParseItemLevel
Data.ParseArtifactPower = ParseArtifactPower
Data.ParseLocalizedNumber = ParseLocalizedNumber

function Data:GetItemLevelFromLink(link)
	if type(link) ~= "string" then
		return nil
	end
	local level = ParseItemLevel(ScanLinkTooltip(link))
	if not level and GetDetailedItemLevelInfo then
		level = SafeCall(GetDetailedItemLevelInfo, link)
	end
	return tonumber(level)
end

---------------------------------------------------------------------------
-- Rewards
---------------------------------------------------------------------------
local RELIC_TYPE_PATTERN = "^" .. FormatToPattern(RELIC_TOOLTIP_TYPE or "%s Artifact Relic") .. "$"

-- "Fire" from the "Fire Artifact Relic" tooltip line.
local function ParseRelicType(lines)
	for i = 2, math.min(#lines, 8) do
		local relicType = CleanText(lines[i]):match(RELIC_TYPE_PATTERN)
		if relicType then
			return relicType
		end
	end
	return nil
end

-- Slot name shown for gear rewards: "Hands", "Two-Hand", "Fire Relic", ...
local function GearSlotText(item, classID, equipLoc, lines)
	if classID == CLASS_GEM then
		local relicType = ParseRelicType(lines)
		return relicType and (relicType .. " Relic") or "Artifact Relic"
	end
	local slot = type(equipLoc) == "string" and equipLoc ~= "" and _G[equipLoc]
	if type(slot) == "string" and slot ~= "" then
		return slot
	end
	return item.name
end

local function DescribeItem(item, classID, subclassID, baseLevel, equipLoc, questID)
	item.classID, item.subclassID = classID, subclassID
	item.isGear = classID == CLASS_WEAPON or classID == CLASS_ARMOR
		or (classID == CLASS_GEM and subclassID == GEM_ARTIFACT_RELIC)
	item.isProfession = classID == CLASS_TRADEGOODS or classID == CLASS_RECIPE
	if IsArtifactPowerItem then
		item.isAP = SafeCall(IsArtifactPowerItem, item.itemID) and true or false
	end

	local lines = ScanRewardTooltip(item.index, questID)
	if item.isGear then
		item.slotText = GearSlotText(item, classID, equipLoc, lines)
	end
	if #lines == 0 then
		item.needsRetry = true
		item.baseLevel = item.isGear and baseLevel or nil
		return
	end

	if item.isGear then
		item.ilvl = ParseItemLevel(lines)
		if not item.ilvl then
			item.needsRetry = true
			item.baseLevel = baseLevel
		end
		return
	end

	local amount = ParseArtifactPower(lines)
	if amount then
		item.isAP = true -- "Grants N Artifact Power" in the tooltip (also covers a missing/wrong API)
	end
	if item.isAP then
		item.apAmount = amount
		item.needsRetry = (amount == nil)
	elseif not item.isProfession then
		item.isRepToken = MentionsReputation(lines)
	end
end

-- Reads the rewards of a quest directly from the client. Returns nil when the
-- client has no reward data yet (and asks the server for it).
function Data:ReadRewards(questID)
	if not SafeCall(HaveQuestRewardData, questID) then
		SafeCall(C_TaskQuest.RequestPreloadRewardData, questID)
		return nil
	end

	local rewards = {
		questID = questID,
		readAt = time(),
		money = tonumber(SafeCall(GetQuestLogRewardMoney, questID)) or 0,
		artifactXP = 0,
		honor = tonumber(SafeCall(GetQuestLogRewardHonor, questID)) or 0,
		currencies = {},
		items = {},
	}
	local artifactXP, artifactCategory = SafeCall(GetQuestLogRewardArtifactXP, questID)
	rewards.artifactXP = tonumber(artifactXP) or 0
	rewards.artifactCategory = artifactCategory

	local orderResourcesName = SafeCall(GetCurrencyInfo, ORDER_RESOURCES_ID)
	for i = 1, tonumber(SafeCall(GetNumQuestLogRewardCurrencies, questID)) or 0 do
		local name, texture, amount, currencyID = SafeCall(GetQuestLogRewardCurrencyInfo, i, questID)
		if not currencyID and name and name == orderResourcesName then
			currencyID = ORDER_RESOURCES_ID -- older return signature without the currency ID
		end
		if name or currencyID then
			rewards.currencies[#rewards.currencies + 1] = {
				id = currencyID, name = name, texture = texture, amount = tonumber(amount) or 0,
			}
		end
	end

	for i = 1, tonumber(SafeCall(GetNumQuestLogRewards, questID)) or 0 do
		local name, texture, quantity, quality, _, itemID = SafeCall(GetQuestLogRewardInfo, i, questID)
		local item = {
			index = i, itemID = itemID, name = name, texture = texture,
			quantity = tonumber(quantity) or 1, quality = quality,
		}
		rewards.items[#rewards.items + 1] = item
		if not (itemID and name) then
			rewards.incomplete = true
			rewards.unclassified = true
		else
			local _, _, _, baseLevel, _, _, _, _, equipLoc, _, _, classID, subclassID = GetItemInfo(itemID)
			if not classID then
				self.waitingItems[itemID] = true
				rewards.incomplete = true
				rewards.unclassified = true
			else
				DescribeItem(item, classID, subclassID, baseLevel, equipLoc, questID)
				if item.needsRetry then
					rewards.incomplete = true
				end
			end
		end
	end
	return rewards
end

-- Cached reward read. Incomplete reads are retried a few times, then accepted as final.
function Data:GetRewards(questID)
	local cached = rewardCache[questID]
	local fresh = cached and (time() - cached.readAt) < REWARD_CACHE_SECONDS
	if fresh and (not cached.incomplete or cached.final) then
		return cached
	end
	local rewards = self:ReadRewards(questID)
	if not rewards then
		return cached -- keep the last known data while the client has none
	end
	if rewards.incomplete then
		readAttempts[questID] = (readAttempts[questID] or 0) + 1
		rewards.final = readAttempts[questID] >= MAX_READ_ATTEMPTS
	else
		readAttempts[questID] = nil
	end
	rewardCache[questID] = rewards
	return rewards
end

function Data:GetCachedRewards(questID)
	return rewardCache[questID]
end

---------------------------------------------------------------------------
-- Classification: one category per quest, from its actual rewards
---------------------------------------------------------------------------
function Data:Classify(q)
	local rewards = q.rewards
	q.mainAmount, q.iconText = nil, nil

	if not rewards or (rewards.unclassified and not rewards.final) then
		q.category = "unknown"
		q.icon = ns.CATEGORIES.unknown.icon
		q.rewardText = rewards and "Loading item data..." or "Waiting for reward data from the server"
		return
	end

	local gear, ap, rep, profession, otherItem
	for _, item in ipairs(rewards.items) do
		if item.isGear then
			gear = gear or item
		elseif item.isAP then
			ap = ap or item
		elseif item.isRepToken then
			rep = rep or item
		elseif item.isProfession then
			profession = profession or item
		elseif item.name then
			otherItem = otherItem or item
		end
	end
	local orderResources, otherCurrency
	for _, currency in ipairs(rewards.currencies) do
		if currency.id == ORDER_RESOURCES_ID then
			orderResources = orderResources or currency
		else
			otherCurrency = otherCurrency or currency
		end
	end

	-- The row text says what the reward is; the amount (item level, quantity, currency
	-- or gold amount) is drawn on the reward icon instead (q.iconText).
	local function ItemName(item)
		return Colorize(item.name, item.quality) or "?"
	end
	local function Quantity(item)
		return (item.quantity or 1) > 1 and tostring(item.quantity) or nil
	end

	if gear then
		q.category, q.icon = "gear", gear.texture
		q.mainAmount = gear.ilvl
		q.iconText = gear.ilvl and tostring(gear.ilvl)
		q.rewardText = Colorize(gear.slotText or gear.name or "?", gear.quality)
	elseif ap or rewards.artifactXP > 0 then
		local amount
		if ap and ap.apAmount then
			amount = ap.apAmount * (ap.quantity or 1)
		elseif rewards.artifactXP > 0 then
			amount = rewards.artifactXP
		end
		q.category = "ap"
		q.icon = (ap and ap.texture) or ns.GetArtifactIcon()
		q.mainAmount = amount
		q.iconText = amount and ns.AbbreviateNumber(amount)
		q.rewardText = AP_LABEL
	elseif orderResources then
		q.category, q.icon = "orderres", orderResources.texture or ns.GetOrderResourcesIcon()
		q.mainAmount = orderResources.amount
		q.iconText = ns.AbbreviateNumber(orderResources.amount)
		q.rewardText = orderResources.name or ns.CATEGORIES.orderres.label
	elseif rep then
		q.category, q.icon = "rep", rep.texture
		q.iconText = Quantity(rep)
		q.rewardText = ItemName(rep)
	elseif profession then
		q.category, q.icon = "materials", profession.texture
		q.mainAmount = profession.quantity
		q.iconText = Quantity(profession)
		q.rewardText = ItemName(profession)
	elseif rewards.money > 0 then
		q.category, q.icon = "gold", ns.CATEGORIES.gold.icon
		q.mainAmount = rewards.money
		if rewards.money >= 10000 then
			q.iconText = ns.AbbreviateNumber(math.floor(rewards.money / 10000)) .. "g"
		else
			q.iconText = math.floor(rewards.money / 100) .. "s"
		end
		q.rewardText = ns.CATEGORIES.gold.label
	elseif otherCurrency then
		q.category, q.icon = "other", otherCurrency.texture
		q.mainAmount = otherCurrency.amount
		q.iconText = ns.AbbreviateNumber(otherCurrency.amount)
		q.rewardText = otherCurrency.name or "?"
	elseif otherItem then
		q.category, q.icon = "other", otherItem.texture
		q.iconText = Quantity(otherItem)
		q.rewardText = ItemName(otherItem)
	elseif rewards.honor > 0 then
		q.category, q.icon = "other", "Interface\\Icons\\Achievement_LegionPVPTier4"
		q.mainAmount = rewards.honor
		q.iconText = ns.AbbreviateNumber(rewards.honor)
		q.rewardText = HONOR or "Honor"
	elseif q.factionName then
		-- No item, currency or money: the quest's only reward is reputation (amount not exposed).
		q.category, q.icon = "rep", ns.CATEGORIES.rep.icon
		q.rewardText = (REPUTATION or "Reputation") .. ": " .. q.factionName
	else
		q.category, q.icon = "other", ns.CATEGORIES.other.icon
		q.rewardText = "No reward listed"
	end
	q.icon = q.icon or ns.GetCategoryIcon(q.category)
end

---------------------------------------------------------------------------
-- Emissaries (bounties)
---------------------------------------------------------------------------
function Data:GetBounties()
	self:GetZones() -- resolves the continent map IDs
	local list, seen = {}, {}
	for _, continent in ipairs(LEGION_CONTINENTS) do
		local bounties = SafeCall(GetQuestBountyInfoForMapID, continent.mapID)
		if type(bounties) == "table" then
			for _, bounty in ipairs(bounties) do
				if type(bounty) == "table" and bounty.questID and not seen[bounty.questID] then
					seen[bounty.questID] = true
					list[#list + 1] = {
						questID = bounty.questID,
						icon = bounty.icon,
						factionID = bounty.factionID,
						factionName = bounty.factionID and SafeCall(GetFactionInfoByID, bounty.factionID) or nil,
						completed = SafeCall(IsQuestComplete, bounty.questID) and true or false,
					}
				end
			end
		end
	end
	return list
end

---------------------------------------------------------------------------
-- Scanning
---------------------------------------------------------------------------
function Data:BuildQuest(questID, task, zone, now, bounties)
	local title, factionID, capped = SafeCall(C_TaskQuest.GetQuestInfoByQuestID, questID)
	local tagID, tagName, worldQuestType, rarity, isElite, tradeskillLineIndex = SafeCall(GetQuestTagInfo, questID)
	local _, canonicalZone = SafeCall(C_TaskQuest.GetQuestZoneID, questID)
	local minutes = tonumber(SafeCall(C_TaskQuest.GetQuestTimeLeftMinutes, questID))

	local q = {
		questID = questID,
		title = title,
		factionID = factionID,
		factionCapped = capped and true or false,
		factionName = factionID and SafeCall(GetFactionInfoByID, factionID) or nil,
		tagID = tagID,
		tagName = tagName,
		worldQuestType = worldQuestType,
		rarity = rarity,
		isElite = isElite and true or false,
		tradeskillLineIndex = tradeskillLineIndex,
		zoneID = zone.id,
		zoneName = zone.name,
		canonicalZone = canonicalZone,
		x = tonumber(task.x),
		y = tonumber(task.y),
		numObjectives = tonumber(task.numObjectives) or 0,
		inProgress = task.inProgress and true or false,
	}
	if minutes and minutes > 0 then
		q.minutesLeft = minutes
		q.expiresAt = now + minutes * 60
	end

	q.completed = (SafeCall(IsQuestFlaggedCompleted, questID) and true)
		or (ns.Stats and ns.Stats:WasCompletedRecently(questID)) or false
	q.tracked = (SafeCall(IsWorldQuestHardWatched, questID) or SafeCall(IsWorldQuestWatched, questID)) and true or false
	q.superTracked = SafeCall(GetSuperTrackedQuestID) == questID

	for _, bounty in ipairs(bounties) do
		if not bounty.completed and SafeCall(IsQuestCriteriaForBounty, questID, bounty.questID) then
			q.bounties = q.bounties or {}
			q.bounties[#q.bounties + 1] = bounty
		end
	end

	q.rewards = self:GetRewards(questID)
	self:Classify(q)
	return q
end

function Data:Scan()
	local now = time()
	local zones = self:GetZones()
	local bounties = self:GetBounties()
	local quests, byID, skipped = {}, {}, {}
	local info = { zones = #zones, zonesWithTasks = 0, taskEntries = 0, noQuestData = 0, notWorldQuest = 0, noRewardData = 0 }

	for _, zone in ipairs(zones) do
		local tasks = SafeCall(C_TaskQuest.GetQuestsForPlayerByMapID, zone.id)
		if type(tasks) == "table" and #tasks > 0 then
			info.zonesWithTasks = info.zonesWithTasks + 1
			for _, task in ipairs(tasks) do
				local questID = type(task) == "table" and (task.questId or task.questID)
				if type(questID) == "number" then
					info.taskEntries = info.taskEntries + 1
					local existing = byID[questID]
					if existing then
						-- Same quest reported by several maps: keep the zone the quest belongs to.
						if existing.canonicalZone == zone.id and existing.zoneID ~= zone.id then
							existing.zoneID, existing.zoneName = zone.id, zone.name
							existing.x, existing.y = tonumber(task.x), tonumber(task.y)
						end
					elseif not skipped[questID] then
						if not SafeCall(HaveQuestData, questID) then
							skipped[questID] = true
							info.noQuestData = info.noQuestData + 1
						elseif not IsWorldQuest(questID) then
							skipped[questID] = true
							info.notWorldQuest = info.notWorldQuest + 1
						else
							local q = self:BuildQuest(questID, task, zone, now, bounties)
							byID[questID] = q
							quests[#quests + 1] = q
						end
					end
				end
			end
		end
	end

	for _, q in ipairs(quests) do
		if not q.rewards then
			info.noRewardData = info.noRewardData + 1
		end
		self.known[q.questID] = { title = q.title }
	end

	self.quests, self.byID = quests, byID
	self.scanInfo = info
	self.lastScan = now
	return quests
end

-- True while some quests still wait for quest data, reward data or item data.
function Data:HasPendingData()
	local info = self.scanInfo
	if (info.noQuestData or 0) > 0 or (info.noRewardData or 0) > 0 then
		return true
	end
	for _, q in ipairs(self.quests) do
		if q.rewards and q.rewards.incomplete and not q.rewards.final then
			return true
		end
	end
	return false
end

-- Remembers world quests the player picks up, so that a later completion can be
-- recognised and its rewards are known even if the map was never opened.
ns.RegisterEvent("QUEST_ACCEPTED", function(_, _, questID)
	if type(questID) == "number" and SafeCall(HaveQuestData, questID) and IsWorldQuest(questID) then
		Data.known[questID] = { title = SafeCall(C_TaskQuest.GetQuestInfoByQuestID, questID) }
		Data:GetRewards(questID)
	end
end)

---------------------------------------------------------------------------
-- Diagnostics (/wqb scan, /wqb aptip)
---------------------------------------------------------------------------
-- Prints the raw reward tooltip lines of up to `limit` quests of a category, with
-- escape codes made visible, so tooltip parsing can be checked on this client.
function Data:PrintRewardTooltips(category, limit)
	if #self.quests == 0 then
		self:Scan()
	end
	local printed = 0
	for _, q in ipairs(self.quests) do
		if printed >= limit then
			break
		end
		if q.category == category and q.rewards and #q.rewards.items > 0 then
			printed = printed + 1
			local item = q.rewards.items[1]
			ns.Print("%s (#%d): %s - parsed amount: %s", q.title or "?", q.questID, item.name or "?", tostring(item.apAmount or item.ilvl or "none"))
			for n, line in ipairs(ScanRewardTooltip(item.index, q.questID)) do
				local visible = line:gsub("|", "||"):gsub("\194\160", "<nbsp>")
				DEFAULT_CHAT_FRAME:AddMessage(("   %d: %s"):format(n, visible))
			end
		end
	end
	if printed == 0 then
		ns.Print("No %s quests with an item reward are listed right now (open the map first).", ns.CATEGORIES[category].label)
	end
end

function Data:PrintDiagnostics()
	self:Scan()
	local info = self.scanInfo
	ns.Print("Scan: %d zones queried, %d returned tasks, %d task entries.", info.zones, info.zonesWithTasks, info.taskEntries)
	ns.Print("World quests: %d listed, %d without reward data yet; %d tasks without quest data; %d bonus objectives ignored.",
		#self.quests, info.noRewardData, info.noQuestData, info.notWorldQuest)
	local counts = {}
	for _, q in ipairs(self.quests) do
		counts[q.category] = (counts[q.category] or 0) + 1
	end
	local parts = {}
	for _, key in ipairs(ns.CATEGORY_ORDER) do
		if counts[key] then
			parts[#parts + 1] = ns.CATEGORIES[key].short .. " " .. counts[key]
		end
	end
	ns.Print("Categories: %s", #parts > 0 and table.concat(parts, ", ") or "none")

	local apis = {
		"C_TaskQuest.GetQuestsForPlayerByMapID", "C_TaskQuest.GetQuestTimeLeftMinutes", "C_TaskQuest.RequestPreloadRewardData",
		"QuestUtils_IsQuestWorldQuest", "HaveQuestRewardData", "IsArtifactPowerItem", "GetQuestBountyInfoForMapID",
		"GetDetailedItemLevelInfo", "AddWorldQuestWatch", "WorldMapPing_StartPingQuest",
	}
	local missing = {}
	for _, path in ipairs(apis) do
		local value = _G
		for part in path:gmatch("[^%.]+") do
			value = type(value) == "table" and value[part] or nil
		end
		if type(value) ~= "function" then
			missing[#missing + 1] = path
		end
	end
	ns.Print("Missing client APIs: %s", #missing > 0 and table.concat(missing, ", ") or "none")
end
