# World Quest Board

A Legion world quest list beside the world map, grouped and filtered by reward, plus per-character world quest statistics.

Built for the **Legion 7.3.5 client (build 26972, interface 70300)** used by Tauri's Legion realms. It does not work on the current retail client, and it isn't intended to.

## Installation

1. Close the game, or log out to the character screen.
2. Copy the `WorldQuestBoard` folder into
   `C:\Games\TauriWoW\Tauri Launcher\Legion\Interface\AddOns\`
   so that `AddOns\WorldQuestBoard\WorldQuestBoard.toc` exists.
3. Start the game. On the character screen, open **AddOns** and make sure **World Quest Board** is enabled. If the client reports the addon as out of date, tick **Load out of date AddOns**.
4. Log in with a level 110 character that has world quests unlocked ("Uniting the Isles").

## Using it

Open the world map (`M`). The **World Quests** panel appears beside it:

- **Windowed map:** the panel is docked to the right edge of the map.
- **Fullscreen map:** there is usually no room beside the map, so the panel overlays the right edge of the map. Drag it anywhere you like by its title bar.

Each row shows:

- **Icon:** the reward icon. The amount is printed on it: item level for gear, Artifact Power, Order Resources, gold or other currency amount, or stack size.
- **Left text:** what the reward is, in a larger font:
  - Gear shows the slot it goes in (e.g. "Hands", "Two-Hand", "Holy Relic") in the item's quality colour.
  - Artifact Power, Order Resources, Gold and Honor show only their name; the amount is on the icon.
  - Other items and currencies show their name.
- **Second line (only when relevant):** "In progress", "Completed", and quest types such as Elite, Dungeon, Pet Battle or PvP.
- **Right side:** time left, with the zone underneath. The zone is shown in white when it is the map you are viewing. When grouping by zone, the zone is the group header instead.
- **Other markers:** a coloured left edge marks rare (blue) and epic (purple) world quests. An emissary icon appears when the quest counts toward an emissary, and a check mark when the quest is tracked.

The quest name is shown in the tooltip.

| Action | Result |
| --- | --- |
| Click a group header | Collapse or expand that group |
| Hover a gear quest and hold **Shift** | Compare the reward with your equipped item |
| Click a quest | Switch the map to the quest's zone and highlight its position (pulsing ring plus Blizzard's own pin ping) |
| Shift-click a quest | Track or untrack it in the objective tracker. If a chat box is open, the quest link is inserted instead |
| Ctrl-click a quest | Add a TomTom waypoint (only if TomTom is installed) |
| Hover a quest | Tooltip with name, type, zone, faction, time left, status, emissary, objectives, full rewards and category |
| **Filters** button | Show or hide the reward-type checkboxes |
| Checkbox, left-click | Show or hide that reward type. Several types can be on at once |
| Checkbox, right-click | Show only that reward type |
| **Pet battles** checkbox | Show or hide pet battle world quests, whatever their reward. Works together with the reward-type filters |
| **Reset filters** | Show all reward types and pet battles again |
| **Sort** button | Cycle the sort order: time left, zone, reward amount, quest name |
| **Group** button | Switch between grouping by reward category and by zone. Reward filters apply in both modes |
| **Stats** button | Open or close the statistics window |
| **WQ** button in the map's title bar | Show or hide the panel |

### ElvUI

When ElvUI is installed, the panel, the **WQ** map button and the statistics window use ElvUI's own skin: flat transparent backdrop, ElvUI buttons, checkboxes, scroll bar and close button, and bordered reward icons. This matches an ElvUI-skinned world map.

- **When the skin is skipped:** ElvUI's Blizzard skins or its World Map skin are turned off in `/ec` → Skins.
- **Turning it off:** type `/wqb skin`, then `/reload`. Skinned frames can't be switched back while the game is running.

### Reward categories

Each quest goes into exactly one category, chosen from its actual reward data. When a quest has more than one kind of reward, the first matching category in this order wins:

1. **Gear & Equipment**: weapons, armor and artifact relics. The item level is read from the reward tooltip.
2. **Artifact Power**: AP tokens (amount read from the token's tooltip) or direct artifact XP.
3. **Order Resources**: currency 1220.
4. **Gold**
5. **Crafting & Professions**: trade goods and recipes.
6. **Reputation**: reputation tokens, or quests whose only reward is reputation.
7. **Other Rewards**: other currencies (Nethershards, Veiled Argunite, …), other items and honor.
8. **Reward Data Pending**: the client has not received the quest's reward data yet. These quests move to their real category once the data arrives.

Category headers show the number of quests. The gold, Order Resources and Artifact Power headers also show the total amount available.

## Statistics

Click **Stats** on the panel, or type `/wqb stats`. The window is hidden by default. It never opens on its own, neither at login nor when the map opens; only its position is remembered.

The window tracks these values per character:

- **World quests completed**
- **Gold earned** from world quests
- **Order Resources earned** from world quests
- **Highest item level gear** received from a world quest, with the item. Hover the item to see its tooltip.

It also lists the most recent completions, with the rewards credited for each one.

### Resetting statistics

1. Click **Reset statistics...** in the statistics window, or type `/wqb resetstats`.
2. Click **Yes, reset** to confirm. The confirmation cancels itself after 15 seconds.

Only the current character is reset. Other characters and interface settings are not affected.

## Slash commands

| Command | Effect |
| --- | --- |
| `/wqb` | Show or hide the quest list |
| `/wqb show`, `/wqb hide` | Show or hide the quest list explicitly |
| `/wqb stats` | Open or close the statistics window |
| `/wqb resetstats` | Reset this character's statistics (asks for confirmation) |
| `/wqb reset filters` | Show all reward types and pet battles again |
| `/wqb reset position` | Restore the default positions of the panel and the statistics window |
| `/wqb reset all` | Restore all interface settings (statistics are kept) |
| `/wqb lock`, `/wqb unlock` | Lock or unlock dragging of the panel |
| `/wqb skin` | Turn the ElvUI look on or off (takes effect after `/reload`) |
| `/wqb scan` | Print diagnostics: zones queried, quests found, quests still waiting for data, and any missing client APIs |
| `/wqb aptip` | Print the raw reward tooltip text of up to three Artifact Power quests, with the amount the addon parsed. Use this if AP amounts look wrong |
| `/wqb log` | Print a chat message for every completion and every reward credited (useful to verify the statistics) |

## Saved data

Saved data lives in `WTF\Account\<account>\SavedVariables\WorldQuestBoard.lua`, in two separate tables:

- **`WorldQuestBoardDB`** holds the account-wide interface settings: filters (including the pet battle toggle), collapsed groups, sort order, grouping (category or zone), the ElvUI look, panel visibility, panel position (stored separately for the windowed and fullscreen map), the lock state and the statistics window position.
- **`WorldQuestBoardStatsDB.chars["Name-Realm"]`** holds the per-character statistics. Each record also stores the character's GUID:
  - A renamed character keeps its statistics.
  - A new character that reuses a deleted character's name starts fresh. The old record is kept under a separate key.

Missing, outdated or invalid values are repaired field by field when the addon loads.

## How it works, and its limits on 7.3.5

These limits come from what the 7.3.5 client exposes. They were verified against the 7.3.5 FrameXML source.

### Quest list

- **Quest source:** quests come from `C_TaskQuest.GetQuestsForPlayerByMapID` for every Broken Isles and Argus zone. The zone list comes from `GetMapZones`, plus a built-in list of zone IDs. Bonus objectives are filtered out.
- **Missing quest data:** a quest is listed only after the client has its quest data. The panel footer shows how many are still waiting. Data that arrives later (`QUEST_LOG_UPDATE`, `GET_ITEM_INFO_RECEIVED`) refreshes the list automatically, with at most one refresh per second.
- **Refresh fallback:** the list rescans every 60 seconds while the map is open, and retries a few times while data is still loading. Nothing runs while the map is closed.
- **Item level and AP amount:** no API reports these, so they are read from the reward tooltip text. If the tooltip isn't loaded, no number is shown.
  - AP amounts may be written as "1,250", "2.5 million", "6 billion" or "96M". Colour codes and non-breaking spaces are ignored.
  - If amounts still look wrong, `/wqb aptip` shows the exact tooltip text the client provides.
  - The item level shown is the listed reward. Warforged or Titanforged upgrades only show up after you receive the item.
- **Reputation:** the client exposes the faction of a quest, but not the reputation amount, so no amount is shown.
- **Time left:** comes from `C_TaskQuest.GetQuestTimeLeftMinutes`. If the server reports no time, the panel shows "--".
- **Fullscreen map:** the panel covers part of the map by default. Drag it, or hide it with the **WQ** button.

### Statistics

- **Completions:** counted from `QUEST_TURNED_IN` and `WORLD_QUEST_COMPLETED_BY_SPELL`, for world quests only. Emissary quests and bonus objectives are not counted.
  - The same quest is never counted twice within an hour, including across `/reload`.
  - A quest disappearing from the map is never treated as a completion.
- **Gold:** the amount the server reports in `QUEST_TURNED_IN`. This includes the gold paid instead of XP at level 110. If the server reports no amount, the quest's listed gold is credited only when your money rises by at least that much within a few seconds.
- **Order Resources:** the client never reports this amount directly. The quest's listed amount is credited only when your Order Resources total rises by at least that much within a few seconds of the completion.
  - Rewards that can't be confirmed this way are not credited. The completion is still counted and is marked "rewards unconfirmed".
- **Gear:** the item from your own "You receive item:" message that matches the quest's reward item is used, so upgrades count. If no such message arrives (for example, the reward was mailed), the listed item level is used and marked "(listed item level)".
- **No history:** completions from before the addon was installed, or made while it was disabled, are not available.
- **Tracking in combat:** Shift-click tracking is refused during combat, because changing the objective tracker from addon code in combat can cause "action blocked" errors.

## Checking it in game

1. **Panel appears:** open the map in windowed mode, then switch to fullscreen. The panel should appear beside or over the map in both modes, and a `WQ` button should be in the map's title bar.
2. **Quests match the map:** run `/wqb scan`. Compare the number of world quests with what the map shows. "Missing client APIs: none" is expected.
3. **Categories:** check that the categories match the reward icons on the map. Hover a few quests and compare the tooltip with Blizzard's pin tooltip.
4. **Filters:** toggle filters, right-click one, then use **Reset filters**. Collapse a category, then `/reload`. Filters, collapsed categories, sort order and panel position should persist.
5. **Navigation:** click a quest in another zone. The map should switch zones and a ring should pulse on the quest. Shift-click should track the quest. With TomTom installed, Ctrl-click should add a waypoint.
6. **Statistics:** run `/wqb log`, then complete a gold quest, an Order Resources quest and a gear quest.
   - The chat should show each completion and each reward credited.
   - The statistics window should show the new totals.
   - Run `/reload` and check that the totals are unchanged.
7. **Separate characters:** log in on another character. Its statistics should start at zero, and the first character's statistics should be unchanged.
8. **Reset:** reset the statistics and confirm. Only the current character should be cleared.
