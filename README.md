# GSUI - GearSwap UI & Inventory Organizer

A Windower 4 addon for FFXI that provides a visual gear set builder, inventory organizer, and live gear stat tracker.

## Keybind

- **B** - Toggle window open/close (automatically ignored while typing in chat)

## Commands

- `/gsui` - Toggle window
- `/gsui show` / `/gsui hide` - Show or hide
- `/gsui refresh` - Rescan inventory
- `/gsui pos <x> <y>` - Set window position
- `/gsui gen` - Generate GearSwap set to clipboard
- `/gsui clear` - Reset to currently equipped gear
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

Displays totals from your equipped gear, grouped by category:

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

Stats with known caps (Fast Cast 80%, Haste 26%, DT 50%, etc.) show the cap and display `[CAPPED]` when reached. Stats update live whenever your equipment changes.

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
