# GSUI - GearSwap UI & Inventory Organizer

A Windower 4 addon for FFXI that provides a visual gear set builder, inventory organizer, and live gear stat tracker.

## Updates

### v1.3.0
- **New**: Clickable Gear Stats header — toggles between **Gear Stats** view (gear-only contributions, the original behavior) and **Total Stats** view (computed totals including base STR/DEX/etc. and skill tiers)
- **New**: Total Stats view shows real-game **Accuracy**, **Attack**, and **Magic Accuracy** combining DEX/STR/skill bases with gear bonuses, using BG-wiki skill→accuracy tier formulas
- **New**: A `-- Total Accuracy --` block is also injected at the top of the regular Gear Stats panel so you can always see the combined Accuracy number without switching views
- **New**: Player stats (STR/DEX/VIT/AGI/INT/MND/CHR/HP/MP) are now cached from incoming Char Stats packet `0x061` (server pushes this on login, zone, gear change, and buff change). Until the first packet arrives the panel says "stats not yet received — swap any gear once or zone to get them"
- **New**: Persistent **inventory cache** (`libs/inventory_cache.lua`) — speeds up first-open scan by remembering item icons/data across sessions. Saved per-character to `data/inv_cache_<name>.lua` (gitignored)
- **Bug Fix**: Stat exclude logic — extracting "Accuracy +N" from a line like `Accuracy+44 Magic Accuracy+44` was rejecting the whole line because it contained the excluded word "Mag". Now strips just the excluded stat phrase so the simple Accuracy total is correct
- **New**: Multi-select + bulk-move in Organizer mode — shift-click or use KB mode to select multiple items, then drag/assign them as a group to a destination bag
- **Bug Fix**: Multi-select highlight now renders correctly in either drag or keyboard mode
- **Bug Fix**: Mog-house detection works when GSUI loads while you're already inside a mog house (previously it only ran the detection on zone-in)

### v1.2.1
- **New**: F1/F2/F3/F4 keybinds — F1 GearSwap, F2 Organizer, F3 toggle KB/Drag mode, F4 open filter dropdown
- **New**: Filter dropdown navigable in KB mode — F4 opens it, arrow keys browse, Enter selects, Escape closes
- **New**: Keybind hints shown on tabs: `GearSwap [F1]`, `Organizer [F2]`, `[F3:KB]`, `[F4] Filter`
- **Bug Fix**: White-box icons no longer appear on first open (extraction cache now warms eagerly)
- **Bug Fix**: Status messages auto-clear after a timeout instead of lingering until the next action

### v1.2.0
- **Bug Fix**: Icons that required scrolling to see now load correctly (fixed extraction cache issue)
- **Bug Fix**: Gear Stats panel now updates live when building custom sets and correctly calculates all stats (Magic Evasion, Damage Taken, etc.)
- **New**: Right-click an equipment slot to remove a single piece (or Delete key in KB mode)
- **New**: Slot indicator shown in item tooltips — always shows which slot(s) an item can go in
- **New**: Slot protection — prevents equipping items in incompatible slots
- **New**: Filter by slot — click an empty equip slot to filter inventory to items for that slot. Works alongside stat filters.
- **New**: Active filter keywords are highlighted with >> in item tooltips
- **New**: Improved filter matching — "Enhancing Magic" filter now catches items like Incanter's Torque
- **New**: Save/Load gear sets — save named sets, load them back, manage via commands (`/gsui save`, `/gsui load`, `/gsui sets`, `/gsui delete`)

## Keybinds

- **B** - Toggle window open/close (automatically ignored while typing in chat)
- **F1** - Switch to GearSwap tab (when GSUI is visible)
- **F2** - Switch to Organizer tab (when GSUI is visible)
- **F3** - Toggle KB/Drag mode (when GSUI is visible)
- **F4** - Open/close filter dropdown (when GSUI is visible); navigate with arrows + Enter in KB mode

## Commands

- `/gsui` - Toggle window
- `/gsui show` / `/gsui hide` - Show or hide
- `/gsui refresh` - Rescan inventory
- `/gsui pos <x> <y>` - Set window position
- `/gsui gen` - Generate GearSwap set to clipboard
- `/gsui clear` - Reset to currently equipped gear
- `/gsui save <name>` - Save current set to a named file
- `/gsui load <name>` - Load a previously saved set
- `/gsui sets` - List all saved sets
- `/gsui delete <name>` - Delete a saved set
- `/gsui org` - Toggle between GearSwap and Organizer mode
- `/gsui kb` - Toggle between Keyboard and Drag mode
- `/gsui gamepath <path>` - Override FFXI install path (auto-detected, rarely needed)
- `/gsui help` - Show command list in-game

## Layout

The UI has four columns:

1. **Left Panel** - Equipment slots (GearSwap mode) or Bag list (Organizer mode)
2. **Inventory Grid** - Browsable item grid with scroll and filter
3. **Item Tooltip** - Hover over any item to see its full description, augments, jobs, and level
4. **Gear Stats** - Live summary of stats from your currently equipped gear

All panels support mouse wheel scrolling when content overflows.

## Gear Stats Panel

The header reads **`Gear Stats  [click to toggle]`** — click it to switch between two views:

### Gear Stats view (default)

Sums of stats from your equipped gear, grouped by category:

- **Casting** - Fast Cast, Quick Magic, Conserve MP, Spell Interrupt Down
- **Haste** - Gear Haste (shows cap at 26%)
- **Pet/SMN** - BP Delay, BP Damage, Pet Haste/Attack/MAB/Accuracy, Avatar Perpetuation, Summoning Skill
- **Melee** - Double Attack, Triple Attack, Store TP, Dual Wield, Subtle Blow, Crit Rate
- **WS** - Weapon Skill Damage
- **Magic** - Magic Atk Bonus, Magic Accuracy, Magic Burst Damage
- **Defense** - DT, PDT, MDT, Magic Evasion, Magic Def Bonus
- **Healing** - Cure Potency
- **Utility** - Refresh, Regen, Treasure Hunter
- **Stats** - HP, MP, STR, DEX, VIT, AGI, INT, MND, CHR, Accuracy, Attack

A `-- Total Accuracy --` block is shown just above the Stats section as a quick reference. Stats with known caps (Fast Cast 80%, Haste 26%, DT 50%, etc.) show the cap and display `[CAPPED]` when reached. Stats update live whenever your equipment changes.

### Total Stats view

Computed totals combining base stats, skill, and gear:

- **ACC + GACC = Total Accuracy** — `floor(DEX × 0.75) + skill_tier(weapon_skill) + gear_acc`
- **ATK + GATK = Total Attack** — `8 + skill_tier + STR + gear_atk`
- **MACC + GMACC = Total Magic Accuracy** — `skill_tier(highest_magic_skill) + gear_macc`
- **GMAB** — Gear Magic Atk Bonus (no client-side computed total available)
- **Base + Gear** — STR/DEX/VIT/AGI/INT/MND/CHR including everything FFXI credits (base, merits, JPs, gear, buffs)
- **HP / MP** — current and max

The skill tier formula matches BG-wiki:
- skill ≤ 200 → 1:1
- 200–400 → diminishing 0.9× after 200
- 400–600 → diminishing 0.8× after 400
- 600+ → 0.9× after 600

Player base stats come from incoming packet `0x061` which the server pushes on login, zone, every gear change, and every buff change — so the values stay current.

## GearSwap Mode

Build GearSwap sets visually. Your current equipment and all equippable items for your job are displayed with icons.

- **Drag** items from the inventory grid onto equipment slots to build a set
- **Keyboard mode** - Arrow keys to navigate items, Enter to select, Tab to switch to equip slots, Enter to assign, Escape to cancel
- **Filter** items by stat/ability using the dropdown (auto-detects relevant filters)
- **Generate Set** copies a GearSwap-formatted Lua table to your clipboard
- **Remove All** clears all slots for a blank set
- **Re-equip** resets slots to your currently equipped gear

## Organizer Mode

Click the **Organizer** tab to switch. Browse and manage items across all bags.

- **Bag list** on the left shows all bags with item counts. Click a bag to view its contents.
- **Sorting toggle** (top-right of grid) switches between **Gear First** and **Items First**
  - Gear First: equipment sorted by slot, weapon type, item level, equip level; then items alphabetically
  - Items First: items alphabetically, then equipment after
- **Drag items** from the grid onto a bag in the left panel to move them (or use keyboard mode: Enter to select, Tab to bags, Enter to assign)
- **Conflicts** button finds duplicate rings/earrings in the same bag (GearSwap can't distinguish identical items in L/R slots)
- **Scattered** button finds non-equipment items split across multiple bags
  - Dragging a scattered item onto a bag consolidates ALL copies from every bag into that destination

## Keyboard Navigation Mode

Toggle with `/gsui kb` or click `[Drag]`/`[KB]` on the title bar. The setting persists across sessions.

In keyboard mode, all game mouse input is blocked so you won't accidentally move the camera or target while navigating.

- **Arrow keys** - Navigate inventory grid, equip slots, or bag list
- **Enter** - Select an item from inventory (focus auto-switches to equip/bag panel), then Enter again on a target to assign
- **Tab** - Manually switch focus between inventory and equip slots (GearSwap) or bag list (Organizer)
- **Escape** - Cancel current selection

A gold highlight shows your cursor position. A green highlight marks the selected item in inventory.

## Mog House

Mog house bags (Safe, Safe 2, Storage, Locker) are greyed out when outside the mog house and become available when you enter. Portable bags (Wardrobes, Satchel, Sack, Case) are always accessible.

## Disclaimer

This addon is provided as-is. Use at your own risk. While there are no known issues, every system is different and results may vary. The author is not responsible for any problems that may arise from using this addon.

## Install

1. Download or clone this repo
2. Copy the entire `GSUI` folder into your Windower `addons` directory (e.g. `C:\Windower4\addons\GSUI`)
3. In-game, type `//lua load gsui`
4. Press **B** to open the window

To auto-load on startup, add `lua load gsui` to your Windower `scripts/init.txt` file.
