--[[
Copyright © 2026, mullerdane85-hash
All rights reserved. BSD-3-Clause. See LICENSE.

GSUI — graphical GearSwap / Inventory companion.

Two modes share the same window:

    GearSwap   Visual equipset builder: drag inventory items onto the
               13-slot equip pane, compute stat totals, save back to
               your GearSwap file. GearTree-style sets sub-panel for
               browsing and overlaying named sets.

    Organizer  Bag-by-bag view of every storage container (inventory,
               wardrobes 1-8, satchel, sack, case, mog safe, safe2,
               storage, locker). Move items between containers with
               drag-and-drop or multi-select + bag-row click. Surfaces
               conflicts (duplicate paired-slot equipment in the same
               bag) and scattered items (same id in multiple bags).
               Works at Nomad/Porter Moogles, not just inside the
               mog house.

Slash entry: //gsui. See README.md for keybinds, settings, and the
GearTree-style sets integration.
]]

_addon.name     = 'GSUI'
_addon.version  = '2.0.0'
_addon.author   = 'mullerdane85-hash'
_addon.commands = { 'gsui' }

require('luau')
local config = require('config')
local packets = require('packets')
local res = require('resources')
local texts = require('texts')
local images = require('images')

local ui = require('libs/ui_renderer')
local scanner = require('libs/inventory_scanner')
local set_gen = require('libs/set_generator')
local icon_handler = require('libs/icon_handler')
local bag_org = require('libs/bag_organizer')

-- ----------------------------------------------------------------------------
-- Move-queue pump
--
-- bag_org.queue_move() just appends to an in-memory list -- the actual
-- get_item / put_item / 0x029 packet only fires from bag_org.process_queue(),
-- and NOTHING was calling it. So bulk-move click handlers looked correct
-- but items never left their source slot. This pump fixes that:
--
--   * start_move_pump() schedules a self-rescheduling tick that calls
--     process_queue() every 0.1 s.
--   * process_queue() itself enforces the 0.5 s MOVE_DELAY throttle on
--     real packet emission, so the 0.1 s tick is just our "is it time yet"
--     poller. Server-side rate-limiting is handled by the bag_org module.
--   * When process_queue returns false (queue drained), the pump
--     deactivates so we don't spin a forever-coroutine when idle.
--   * A single _move_pump_active guard ensures we never run two pumps in
--     parallel even if several click handlers fire queue_move()+
--     start_move_pump() in the same frame.
-- ----------------------------------------------------------------------------
local _move_pump_active = false
-- Set true on incoming zone packet (0x00B). Cleared by 0x00A (zone-finish)
-- AFTER windower.ffxi.get_items() returns a valid inventory snapshot, or
-- by a 30 s safety ceiling if 0x00A never arrives (disconnect / bad
-- packet). Any coroutine that touches windower.ffxi.* must early-out when
-- this is set or it can crash Windower when get_items() returns a partial
-- snapshot mid-zone.
local _zoning = false
local _zoning_session = 0  -- incremented on each 0x00B; lets the safety
                           -- timer / pending checks tell if they're still
                           -- the current zone's deadlines or stale.

-- =============================================================================
-- Diagnostic breadcrumb log. Lines append to GSUI/debug.log; file is reset
-- on every addon load so each Windower session starts fresh. The file is
-- opened+closed per write so the last line hits disk BEFORE any native
-- d3d8.dll AV that would crash the process. Tail debug.log after a crash
-- to see what code path was active.
--
-- Disable by flipping _dbg_enabled to false.
-- =============================================================================
local _dbg_enabled = true
local _dbg_path = nil   -- set in 'load' once windower.addon_path is known
local function dbg(tag, msg)
    if not _dbg_enabled or not _dbg_path then return end
    local ok, f = pcall(io.open, _dbg_path, 'a')
    if ok and f then
        local ts = os.date('%H:%M:%S')
        local clk = string.format('%.3f', os.clock())
        f:write(ts .. ' (' .. clk .. ') [' .. tag .. '] ' .. (msg or '') .. '\n')
        f:close()
    end
end

local function start_move_pump()
    if _move_pump_active then
        dbg('pump', 'start refused: already active')
        return
    end
    if _zoning then
        dbg('pump', 'start blocked: _zoning=true')
        return
    end
    if not bag_org.is_moving() then return end
    dbg('pump', 'started')
    _move_pump_active = true
    local function tick()
        if _zoning then
            dbg('pump', 'tick aborted: _zoning=true')
            _move_pump_active = false
            return
        end
        -- pcall the process_queue call so a server-side rejection
        -- or transient API glitch can't strand _move_pump_active=true
        -- forever (which was making the user reload GSUI after a few
        -- bulk moves -- no new pump could start because the flag was
        -- stuck).
        local ok, more = pcall(bag_org.process_queue)
        if not ok then
            dbg('pump', 'tick errored: ' .. tostring(more) .. ' -- clearing flag')
            _move_pump_active = false
            return
        end
        if more then
            coroutine.schedule(tick, 0.1)
        else
            dbg('pump', 'queue drained')
            _move_pump_active = false
        end
    end
    coroutine.schedule(tick, 0.1)
end

local stat_parser = require('libs/stat_parser')
-- Augment decoder for /check examination packets. Used by the 0x0C9
-- listener below to turn a player's ExtData blob into a list of
-- augment description strings that stat_parser can scan.
local extdata = require('extdata')

-- Sets controller (GearTree-style integration). Lives in its own
-- sub-window so it doesn't tangle with the main GSUI window's tab
-- system. Toggled via //gsui sets or F5.
local sets_ctl = require('libs/gear_tree/sets_controller')
local hotkey = require('libs/hotkey')

-- Settings
local defaults = {
    pos = { x = 200, y = 200 },
    visible = true,
    game_path = nil,
    kb_mode = false,
    -- DIK scancode used to toggle the GSUI window (legacy raw-keyboard
    -- path). 0 disables the old handler; the modifier-based hotkey below
    -- is the modern default and avoids macro/chat conflicts.
    toggle_key_dik = 0,
    -- Modifier-based hotkey. Goes through Windower's `bind` system, which
    -- automatically respects FFXI's chat-input state. Default Alt+G.
    --   modifier = 'alt' | 'ctrl' | 'shift' | 'none' | 'off'
    --   key      = single character or DIK name (lowercase)
    hotkey_modifier = 'alt',
    hotkey_key      = 'g',
}
local settings = config.load(defaults)
config.save(settings)

-- DIK (DirectInput) scancode lookup for the //gsui togglekey command.
-- These are physical scancodes -- they DO NOT match the ASCII letter
-- values. The full reference is Microsoft's dinput.h. We ship the most
-- useful subset inline because Windower's res lib doesn't expose them.
local DIK_NAMES = {
    -- letters
    ['a']=30, ['b']=48, ['c']=46, ['d']=32, ['e']=18, ['f']=33, ['g']=34,
    ['h']=35, ['i']=23, ['j']=36, ['k']=37, ['l']=38, ['m']=50, ['n']=49,
    ['o']=24, ['p']=25, ['q']=16, ['r']=19, ['s']=31, ['t']=20, ['u']=22,
    ['v']=47, ['w']=17, ['x']=45, ['y']=21, ['z']=44,
    -- digits (number row)
    ['0']=11, ['1']=2, ['2']=3, ['3']=4, ['4']=5, ['5']=6,
    ['6']=7, ['7']=8, ['8']=9, ['9']=10,
    -- function keys
    ['f1']=59, ['f2']=60, ['f3']=61, ['f4']=62, ['f5']=63, ['f6']=64,
    ['f7']=65, ['f8']=66, ['f9']=67, ['f10']=68, ['f11']=87, ['f12']=88,
    -- common punctuation
    ['minus']=12, ['-']=12, ['equals']=13, ['=']=13,
    ['lbracket']=26, ['[']=26, ['rbracket']=27, [']']=27,
    ['backslash']=43, ['\\']=43, ['semicolon']=39, [';']=39,
    ['apostrophe']=40, ['\'']=40, ['grave']=41, ['`']=41,
    ['comma']=51, [',']=51, ['period']=52, ['.']=52, ['slash']=53, ['/']=53,
    -- navigation / misc
    ['tab']=15, ['space']=57, ['enter']=28, ['backspace']=14, ['escape']=1, ['esc']=1,
    ['insert']=210, ['delete']=211, ['home']=199, ['end']=207,
    ['pageup']=201, ['pagedown']=209,
    ['up']=200, ['down']=208, ['left']=203, ['right']=205,
    ['numpad0']=82, ['numpad1']=79, ['numpad2']=80, ['numpad3']=81, ['numpad4']=75,
    ['numpad5']=76, ['numpad6']=77, ['numpad7']=71, ['numpad8']=72, ['numpad9']=73,
    ['off']=0, ['none']=0, ['disable']=0, ['disabled']=0,
}
-- Reverse lookup (dik -> human name) so we can echo what we resolved.
local DIK_DISPLAY = {}
for nm, dik in pairs(DIK_NAMES) do
    if not DIK_DISPLAY[dik] then DIK_DISPLAY[dik] = nm:upper() end
end
DIK_DISPLAY[0] = '(disabled)'

-- State
local initialized = false
local pending_refresh = false
local refresh_timer = 0
-- Hard deadline so a long burst of inventory packets (e.g. buying a
-- stack of stuff from a vendor in rapid succession) doesn't push the
-- debounced refresh out indefinitely. Refresh fires no later than
-- 1 second after the FIRST packet in a burst.
local refresh_deadline = 0
local cached_all_items = {}
local custom_set_active = false
local _org_all_bag_items = {}
local _org_conflicts = {}
local _org_scattered = {}

-- Get player's current main job ID and level
local function get_current_job_info()
    local player = windower.ffxi.get_player()
    if player then
        return player.main_job_id, player.main_job_level
    end
    return nil, nil
end

-- Scan all bags into one unified list, filtered to current job and level, sorted by slot
local function scan_all_inventory()
    local all_items = {}
    local job_id, job_level = get_current_job_info()
    local bag_names = scanner.get_bag_names()
    for _, bag_name in ipairs(bag_names) do
        local bag_items = scanner.scan_bag(bag_name)
        for _, item in ipairs(bag_items) do
            if scanner.is_equippable_by(item, job_id, job_level) then
                table.insert(all_items, item)
            end
        end
    end
    scanner.sort_by_slot(all_items)
    cached_all_items = all_items
    return all_items
end

-- Build stats from custom set and update the stat panel
local function update_custom_stats()
    local slots = set_gen.get_all_slots()
    local eq = {}
    for slot_name, item in pairs(slots) do
        eq[slot_name] = { item = item }
    end
    local totals = stat_parser.calc_totals(eq)
    local view = ui.get_stat_view and ui.get_stat_view() or 'gear'
    local summary = (view == 'total') and stat_parser.format_total_summary(totals)
                                       or stat_parser.format_summary(totals)
    ui.update_stat_text(summary)
end

-- Apply current filter to cached inventory and update UI
local function apply_filter()
    local preset = ui.get_active_filter()
    local slot_filter = ui.get_slot_filter()
    local has_stat_filter = preset and preset.pattern
    local has_slot_filter = slot_filter ~= nil

    -- Update inv label to reflect active filters
    local label = 'All Storage'
    if has_stat_filter and has_slot_filter then
        label = preset.name .. ' [' .. ui.get_slot_display_name(slot_filter) .. ']'
    elseif has_slot_filter then
        label = 'All Storage [' .. ui.get_slot_display_name(slot_filter) .. ']'
    elseif has_stat_filter then
        label = 'Filter: ' .. preset.name
    end
    ui.set_inv_label(label)

    if not has_stat_filter and not has_slot_filter then
        ui.update_inventory(cached_all_items)
        return
    end

    local filtered = {}
    for _, item in ipairs(cached_all_items) do
        local stat_ok = true
        local slot_ok = true
        if has_stat_filter then
            stat_ok = scanner.matches_filter(item, preset.pattern)
        end
        if has_slot_filter then
            slot_ok = scanner.matches_slot_filter(item, slot_filter)
        end
        if stat_ok and slot_ok then
            table.insert(filtered, item)
        end
    end
    ui.update_inventory(filtered)
end

-- Organizer helpers (forward declarations)
local show_org_bag
local show_org_conflicts
local show_org_scattered

-- Bulk-move generation counter. Every click that fires a bulk move
-- increments this. The verify coroutine captures its own _bulk_op_id
-- at schedule time and bails on entry if a newer bulk has started
-- since -- prevents stale verifies from firing refresh_organizer
-- over and over after a chain of bulk moves.
local _bulk_op_id = 0

-- Wardrobes 1-8 only hold equipment (gear with a slots>0 mask). If a
-- non-equipment item ends up routed to a wardrobe via GSUI's bag-to-bag
-- two-leg path (get_item to inventory, then put_item to wardrobe), the
-- server rejects leg 2 and the item is STRANDED in inventory. The
-- bulk-move click handler pre-filters out non-equipment items when the
-- destination is a wardrobe so this can't happen.
local _wardrobe_bags = {
    wardrobe=true, wardrobe2=true, wardrobe3=true, wardrobe4=true,
    wardrobe5=true, wardrobe6=true, wardrobe7=true, wardrobe8=true,
}
local function is_wardrobe(bag_name)
    return _wardrobe_bags[bag_name] == true
end
-- res.items[id].slots is a bitmask of equipment slots this item can
-- occupy. 0 (or missing) means the item isn't equippable -- consumables,
-- crafting mats, key items, furniture, etc.
local function is_equipment(item_id)
    if not item_id then return false end
    local def = res.items[item_id]
    return def and def.slots and def.slots > 0 or false
end

-- Print a smart "N items did not move" message that diagnoses the
-- actual failure mode instead of always blaming mog-house location.
-- Three cases the server actually rejects on:
--   1. Destination bag isn't unlocked from the player's current spot
--      (Storage / Safe2 from Mog Garden, etc.) -- talk-to-moogle path
--   2. Destination bag is full at 80/80 -- bag full path
--   3. Item is locked / rare-exclusive duplicate / quest item or the
--      server timing missed the verify window -- generic fallback
local function report_single_move_failure(item_name, dest)
    local dest_used, dest_max = nil, nil
    local ok_snap, snap_items = pcall(windower.ffxi.get_items)
    if ok_snap and snap_items and snap_items[dest] then
        dest_used = snap_items[dest].count
        dest_max  = snap_items[dest].max
    end
    local dest_accessible = true
    if bag_org.is_bag_currently_accessible then
        dest_accessible = bag_org.is_bag_currently_accessible(dest)
    end
    local hint
    if not dest_accessible then
        hint = dest .. ' is not unlocked from your current location. Talk to Marston (Mog Garden), a Nomad Moogle, or a Porter Moogle to unlock ' .. dest .. '.'
    elseif dest_max and dest_used and dest_used >= dest_max then
        hint = dest .. ' is full (' .. dest_used .. '/' .. dest_max .. '). Move something out first.'
    elseif is_wardrobe(dest) then
        hint = dest .. ' only accepts equipment (gear). This item belongs in safe / safe2 / storage / locker / sack / satchel / case.'
    else
        hint = dest .. ' (' .. tostring(dest_used or '?') .. '/' .. tostring(dest_max or '?')
            .. ') -- item may be locked / rare-exclusive duplicate / quest item.'
    end
    windower.add_to_chat(207, 'GSUI: ' .. item_name .. ' did not move -> ' .. hint)
    if dbg then
        dbg('move-fail', 'single: ' .. item_name .. ' to ' .. dest
            .. ' / accessible=' .. tostring(dest_accessible)
            .. ' / used=' .. tostring(dest_used)
            .. ' / max=' .. tostring(dest_max))
    end
end

local function report_bulk_move_failure(unmoved_count, dest)
    local dest_used, dest_max = nil, nil
    local ok_snap, snap_items = pcall(windower.ffxi.get_items)
    if ok_snap and snap_items and snap_items[dest] then
        dest_used = snap_items[dest].count
        dest_max  = snap_items[dest].max
    end
    local dest_accessible = true
    if bag_org.is_bag_currently_accessible then
        dest_accessible = bag_org.is_bag_currently_accessible(dest)
    end
    local hint
    if not dest_accessible then
        hint = dest .. ' is not unlocked from your current location. Talk to Marston (Mog Garden), a Nomad Moogle, or a Porter Moogle to unlock it.'
    elseif dest_max and dest_used and dest_used >= dest_max then
        hint = dest .. ' is full (' .. dest_used .. '/' .. dest_max .. '). Move something out first.'
    elseif is_wardrobe(dest) then
        hint = dest .. ' (' .. tostring(dest_used or '?') .. '/' .. tostring(dest_max or '?')
            .. ') only accepts equipment (gear). Non-equipment items (consumables, materials, key items) belong in safe / safe2 / storage / locker / sack / satchel / case.'
    else
        hint = 'destination ' .. dest .. ' (' .. tostring(dest_used or '?')
            .. '/' .. tostring(dest_max or '?')
            .. ') -- item may be locked / rare-exclusive duplicate / quest item, or the server-side verify window timed out.'
    end
    windower.add_to_chat(207, 'GSUI: ' .. unmoved_count .. ' item(s) did not move -> ' .. hint)
    if dbg then
        dbg('move-fail', 'bulk: ' .. unmoved_count .. ' to ' .. dest
            .. ' / accessible=' .. tostring(dest_accessible)
            .. ' / used=' .. tostring(dest_used)
            .. ' / max=' .. tostring(dest_max))
    end
end

-- Organizer: scan all bags (unfiltered) and detect issues
local function refresh_organizer()
    if not initialized or _zoning then
        if _zoning then dbg('refresh', 'blocked: _zoning=true (this is GOOD - guard caught it)') end
        return
    end
    dbg('refresh', 'refresh_organizer entered')
    local all_bag_items = {}
    local bag_data = {}
    local all_bags = scanner.get_all_bag_names()
    for _, bag_name in ipairs(all_bags) do
        local items = scanner.scan_bag(bag_name)
        all_bag_items[bag_name] = items
        local used, max = scanner.get_bag_capacity(bag_name)
        bag_data[bag_name] = { used = used, max = max }
    end
    ui.set_mog_house(bag_org.is_in_mog_house())
    ui.update_bag_counts(bag_data)

    local conflicts = bag_org.find_conflicts(all_bag_items)
    local scattered = bag_org.find_scattered(all_bag_items)
    ui.update_org_counts(#conflicts, #scattered)

    -- Store for use by view switching
    _org_all_bag_items = all_bag_items
    _org_conflicts = conflicts
    _org_scattered = scattered

    -- If currently viewing a bag, refresh the grid
    local view = ui.get_org_view()
    if view == 'bags' then
        show_org_bag(ui.get_org_selected_bag())
    elseif view == 'conflicts' then
        show_org_conflicts()
    elseif view == 'scattered' then
        show_org_scattered()
    end
end

show_org_bag = function(bag_name)
    -- Switching bags invalidates the current multi-select context.
    if ui.selection_count() > 0 then ui.clear_selection() end
    ui.select_org_bag(bag_name)
    ui.set_inv_label(ui.get_bag_label(bag_name))
    local items
    if bag_name == 'all' then
        items = {}
        local src = _org_all_bag_items or {}
        for _, bag_items in pairs(src) do
            for _, item in ipairs(bag_items) do
                table.insert(items, item)
            end
        end
    else
        items = _org_all_bag_items and _org_all_bag_items[bag_name] or scanner.scan_bag(bag_name)
    end
    items = scanner.sort_organized(items, ui.get_sort_mode())
    ui.update_inventory(items)
    ui.set_org_view('bags')
end

show_org_conflicts = function()
    ui.set_org_view('conflicts')
    ui.set_inv_label('Conflicts')
    local display_items = {}
    for _, conflict in ipairs(_org_conflicts or {}) do
        for _, item in ipairs(conflict.items) do
            local copy = {}
            for k, v in pairs(item) do copy[k] = v end
            copy.conflict_warning = 'Duplicate in ' .. conflict.bag .. ' - GearSwap cannot distinguish for L/R slots'
            table.insert(display_items, copy)
        end
    end
    display_items = scanner.sort_organized(display_items, ui.get_sort_mode())
    ui.update_inventory(display_items)
end

show_org_scattered = function()
    ui.set_org_view('scattered')
    ui.set_inv_label('Scattered')
    local display_items = {}
    for _, info in ipairs(_org_scattered or {}) do
        local also_in = {}
        local first_bag = nil
        for bag_name, count in pairs(info.bags) do
            if not first_bag then first_bag = bag_name end
            table.insert(also_in, bag_name .. ' (' .. count .. ')')
        end
        -- Create a display item from the first occurrence
        local found = false
        if _org_all_bag_items then
            for bag_name, items in pairs(_org_all_bag_items) do
                for _, item in ipairs(items) do
                    if item.id == info.id then
                        local copy = {}
                        for k, v in pairs(item) do copy[k] = v end
                        copy.also_in = also_in
                        table.insert(display_items, copy)
                        found = true
                        break
                    end
                end
                if found then break end
            end
        end
    end
    display_items = scanner.sort_organized(display_items, ui.get_sort_mode())
    ui.update_inventory(display_items)
end

-- Stats panel display mode:
--   'self'  -> show YOUR currently-equipped gear totals (default)
--   'check' -> show the LAST /check-examined player's gear totals
-- Toggle to 'self' via //gsui mystats. Toggles to 'check' automatically
-- when an incoming 0x0C9 player-examination packet arrives.
local _stats_mode = 'self'
local _last_checked = nil   -- { name, mjob, sjob, eq } from the last /check

local function update_stats(eq)
    -- If the user is viewing a /checked player's stats, don't let a
    -- self-equipment refresh overwrite the panel. The check display
    -- survives until //gsui mystats or another /check.
    if _stats_mode == 'check' and _last_checked then return end

    local totals = stat_parser.calc_totals(eq)
    local view = ui.get_stat_view and ui.get_stat_view() or 'gear'
    local summary = (view == 'total') and stat_parser.format_total_summary(totals)
                                       or stat_parser.format_summary(totals)
    ui.update_stat_text(summary)
end

-- Forward declarations for KB bind functions (defined after handle_kb_action)
local activate_kb_binds
local deactivate_kb_binds
local activate_fn_binds
local deactivate_fn_binds

-- Sync binds to current state
-- F1/F2/F3 active whenever visible; nav keys active when visible + KB mode
local function sync_kb_binds()
    if initialized and ui.is_visible() then
        activate_fn_binds()
        if ui.get_kb_mode() then
            activate_kb_binds()
        else
            deactivate_kb_binds()
        end
    else
        deactivate_kb_binds()
        deactivate_fn_binds()
    end
end

-- Initialize
local function initialize()
    if initialized then return end

    ui.init({
        pos_x = settings.pos.x,
        pos_y = settings.pos.y,
        game_path = settings.game_path,
    })
    ui.build()

    if settings.visible == false then
        ui.hide()
    end

    -- Restore KB mode
    if settings.kb_mode then
        ui.set_kb_mode(true)
    end
    sync_kb_binds()

    -- Register filter callback
    ui.set_on_filter(function()
        apply_filter()
    end)

    -- Initial data load
    local eq = scanner.scan_equipment()
    ui.update_equipment(eq)
    set_gen.populate_from_equipment(eq)
    update_stats(eq)

    scan_all_inventory()
    local active_filters = scanner.find_active_filters(cached_all_items)
    ui.update_filter_presets(active_filters)

    -- GearTree integration: try to locate + parse the currently-active
    -- GearSwap file based on the player's name + main job. If it parses,
    -- push the tree to the UI so the GearSwap tab shows the Sets list.
    -- Failures (no file, parse error) are non-fatal — the addon still
    -- works as a normal builder; user just won't see the Sets list.
    local p = windower.ffxi.get_player()
    if p and p.name and p.main_job then
        local ok = sets_ctl.open(p.name, p.main_job)
        if ok then
            local info = sets_ctl.get_file_info()
            if ui.set_sets_data then ui.set_sets_data(sets_ctl.get_tree(), info) end
            windower.add_to_chat(207, 'GSUI: Loaded GearSwap file — ' .. (info.name or '?'))
        else
            windower.add_to_chat(167, 'GSUI: ' .. tostring(sets_ctl.get_error()))
        end
    end

    initialized = true
    windower.add_to_chat(207, 'GSUI: Loaded. Use /gsui to toggle.')
end

local function save_position()
    local px, py = ui.get_position()
    settings.pos.x = px
    settings.pos.y = py
    config.save(settings)
end

local function refresh_data()
    if not initialized or _zoning then return end
    if not custom_set_active then
        local eq = scanner.scan_equipment()
        ui.update_equipment(eq)
        update_stats(eq)
    end
    scan_all_inventory()
    apply_filter()
end

-- FFXI's /equip command uses ear1/ear2/ring1/ring2; GSUI / GearSwap use
-- left_ear/right_ear/left_ring/right_ring internally. Map one to the
-- other when generating the chat command. Other slot names pass
-- through unchanged.
local _SLOT_TO_CHAT = {
    left_ear   = 'ear1',
    right_ear  = 'ear2',
    left_ring  = 'ring1',
    right_ring = 'ring2',
}

-- Map GSUI slot names (also the GearSwap convention) to FFXI's internal
-- slot IDs used by windower.ffxi.set_equip. Standard ordering 0..15.
local _SLOT_NAME_TO_ID = {
    main      = 0,  sub       = 1,  range     = 2,  ammo      = 3,
    head      = 4,  neck      = 5,  left_ear  = 6,  right_ear = 7,
    body      = 8,  hands     = 9,  left_ring = 10, right_ring= 11,
    back      = 12, waist     = 13, legs      = 14, feet      = 15,
}

-- FFXI's res.items has TWO english fields per item:
--   .english     = inventory-display short form ("Hashi. Bazu. +2",
--                                                 "Behem. Leather")
--   .english_log = full english name             ("Hashishin Bazubands +2",
--                                                 "Behemoth Leather")
-- A set declaration can use either form (gs_export emits the short one;
-- hand-written sets and Mote includes use the long one). Without a
-- both-ways match, "not in inventory" fires on items the user clearly
-- has -- the exact community report ("Hashishin Bazubands +2 (not in
-- inventory)" when the item IS sitting in wardrobe).
--
-- One-shot name -> item id resolver. Hot path: called ONCE per gear
-- slot when loading a set, then reused for every inventory item we
-- compare against. Earlier I had `_names_match(have, want)` doing
-- BOTH lookups inline -- so a set click meant
--   16 slots * ~100 cached items * 2 res.items:with() = ~3,000
-- res.items linear scans, and each scan walks ~10,000 entries. That
-- adds up to ~30M ops per click, which is exactly what was lagging.
local function _resolve_name_to_id(n)
    if not n or n == '' then return nil end
    local hit = res.items:with('english', n) or res.items:with('english_log', n)
    return hit and hit.id or nil
end

-- Returns true if `want` resolves to the same item id as `have`. Falls
-- through to a raw string compare for items res.items doesn't know about.
-- Kept for the augment-aware equip path where we resolve on a per-item
-- basis; the hot set-load loop bypasses this and uses pre-resolved ids.
local function _names_match(have, want)
    if not have or not want then return false end
    if have == want then return true end
    local have_id = _resolve_name_to_id(have)
    local want_id = _resolve_name_to_id(want)
    if have_id and want_id and have_id == want_id then return true end
    return false
end

-- Compare two augment lists for equality (order-independent). Items in
-- inventory may report augments in a slightly different order than what
-- gs_export saved, so we sort-compare to be safe.
-- Normalize an augment string so cosmetic differences (extra whitespace,
-- punctuation drift, case) don't sink the equality check.
--   * lowercase
--   * collapse runs of whitespace to a single space
--   * strip double-quote characters (some sets write "Fast Cast"+10, some
--     just Fast Cast+10)
--   * trim leading / trailing whitespace
local function _augnorm(s)
    if type(s) ~= 'string' then return '' end
    s = s:lower()
    s = s:gsub('"', '')
    s = s:gsub('%s+', ' ')
    s = s:gsub('^%s+', ''):gsub('%s+$', '')
    return s
end

local function _augments_match(a, b)
    if not a and not b then return true end
    if not a or not b then return false end
    if #a ~= #b then return false end
    local copy_a, copy_b = {}, {}
    for i, v in ipairs(a) do copy_a[i] = _augnorm(v) end
    for i, v in ipairs(b) do copy_b[i] = _augnorm(v) end
    table.sort(copy_a); table.sort(copy_b)
    for i = 1, #copy_a do
        if copy_a[i] ~= copy_b[i] then return false end
    end
    return true
end

-- Search every inventory bag for an item matching `name` AND (if
-- augments were provided) the augment block. Returns bag_id, inv_index
-- or nil if not found. Used as a fallback when the caller doesn't have
-- the bag/index handy (e.g. //gsui equip slash from a stored set).
local function _find_in_inventory(name, augs)
    if not name then return nil end
    local want_augs = augs and #augs > 0
    -- Bare-name fallback. If the augment match never lands (Windower's
    -- extdata cache for that slot can be empty / formatted slightly
    -- differently than the saved set's augment block), we still land
    -- SOMETHING -- the first copy by name. This is what you usually want
    -- when you only own one copy of the item; if you own multiple variants
    -- (FC cape vs Pet cape), this picks whichever is indexed first, which
    -- is the same behavior a bare /equip command gives anyway.
    local first_by_name = nil

    for bag_name, bag_id in pairs(scanner.get_all_bag_ids() or {}) do
        local ok, bag_items = pcall(windower.ffxi.get_items, bag_id)
        if ok and bag_items and bag_items.enabled then
            for inv_index, raw in pairs(bag_items) do
                if type(raw) == 'table' and raw.id and raw.id > 0 then
                    local def = res.items[raw.id]
                    if def and (def.english == name or def.en == name
                                or def.english_log == name or def.enl == name) then
                        if not want_augs then
                            return bag_id, inv_index
                        end
                        if not first_by_name then
                            first_by_name = { bag_id, inv_index }
                        end
                        local ok_ext, decoded = pcall(extdata.decode,
                            { id = raw.id, extdata = raw.extdata })
                        if ok_ext and decoded and _augments_match(decoded.augments or {}, augs) then
                            return bag_id, inv_index
                        end
                    end
                end
            end
        end
    end
    -- Augment search struck out; fall through to whichever bare-name copy
    -- we saw first so the slot still equips. _send_equip will still chat-
    -- warn if BOTH paths failed.
    if first_by_name then
        return first_by_name[1], first_by_name[2]
    end
    return nil
end

-- Send a single-slot equip. Two paths:
--   1. Item has bag_id + bag_index (from inventory_scanner) -> direct API:
--      windower.ffxi.set_equip(inv_index, slot_id, bag_id). This is the
--      same call GearSwap makes internally; it lands the EXACT inventory
--      slot we point at, so an augmented cape's specific copy gets
--      equipped instead of whichever copy sorts first.
--   2. Item has only a name (legacy callers / load-from-disk path) ->
--      search every bag for a matching name (+ augments if present) and
--      then call set_equip with the found index.
local function _send_equip(slot, item)
    local name, augs, bag_id, inv_index
    if type(item) == 'table' then
        name = item.name; augs = item.augments
        bag_id = item.bag_id; inv_index = item.bag_index
    else
        name = item
    end
    if not name then return end
    local slot_id = _SLOT_NAME_TO_ID[slot]
    if not slot_id then
        windower.add_to_chat(167, 'GSUI: unknown slot "'..tostring(slot)..'" -- skipping equip.')
        return
    end
    -- Resolve bag/index if the caller didn't have it.
    if not (bag_id and inv_index) then
        bag_id, inv_index = _find_in_inventory(name, augs)
    end
    if bag_id and inv_index then
        windower.ffxi.set_equip(inv_index, slot_id, bag_id)
    else
        -- Last-ditch: bare /equip lets the game pick whichever copy. Better
        -- than silently no-equipping, with a warning so the user sees it.
        windower.add_to_chat(167, ('GSUI: could not locate %s for %s slot; falling back to /equip (no augment match).'):format(name, slot))
        local chat_slot = _SLOT_TO_CHAT[slot] or slot
        windower.send_command('input /equip ' .. chat_slot .. ' "' .. name .. '"')
    end
end

local function handle_kb_action(action)
    if action.type == 'equip' then
        -- Slot protection: check if item can go in target slot
        if not scanner.can_equip_in_slot(action.item, action.slot) then
            ui.set_status('Cannot equip ' .. action.item.name .. ' in ' .. action.slot)
            windower.add_to_chat(207, 'GSUI: ' .. action.item.name .. ' cannot be equipped in ' .. action.slot)
            return
        end
        custom_set_active = true
        set_gen.set_slot(action.slot, action.item)
        ui.set_equip_slot_item(action.slot, action.item)
        ui.set_status(action.item.name .. ' -> ' .. action.slot)
        ui.update_tooltip(action.item)
        update_custom_stats()
        -- Instant equip: also send the actual /equip chat command so
        -- the item lands on the character, not just in GSUI's in-memory
        -- custom set display. Previous behavior was display-only, which
        -- looked like "I clicked the item and nothing happened" in game.
        _send_equip(action.slot, action.item)   -- whole item so augments survive
        windower.add_to_chat(207, 'GSUI: equipped ' .. action.item.name .. ' -> ' .. action.slot)
    elseif action.type == 'bag' then
        local dest = action.bag_name
        local item = action.item
        -- Per user (2026-06-14): the preflight is_bag_currently_accessible
        -- check was unreliable (refused legit moves while the user was
        -- standing in their mog house). We just attempt the move now and
        -- verify by inventory diff. If nothing landed, suggest the mog
        -- house. If something landed, list what moved.
        if ui.get_org_view() == 'scattered' and _org_all_bag_items then
            -- Snapshot how much of this item id sits in `dest` BEFORE.
            -- After the queue settles we re-scan and the delta = what
            -- actually moved (server-rejected moves leave dest unchanged).
            local dest_before = 0
            for _, it in ipairs(_org_all_bag_items[dest] or {}) do
                if it.id == item.id then dest_before = dest_before + it.count end
            end
            local move_count = 0
            for bag_name, items in pairs(_org_all_bag_items) do
                if bag_name ~= dest then
                    for _, bag_item in ipairs(items) do
                        if bag_item.id == item.id then
                            bag_org.queue_move(bag_name, bag_item.bag_index, dest, bag_item.count, bag_item.id)
                            move_count = move_count + 1
                        end
                    end
                end
            end
            if move_count > 0 then
                ui.set_status('Consolidating ' .. item.name .. ' -> ' .. dest)
                start_move_pump()
                coroutine.schedule(function()
                    if not initialized or _zoning then return end
                    refresh_organizer()
                    local dest_after = 0
                    for _, it in ipairs(_org_all_bag_items[dest] or {}) do
                        if it.id == item.id then dest_after = dest_after + it.count end
                    end
                    local moved = dest_after - dest_before
                    if moved > 0 then
                        windower.add_to_chat(207, 'GSUI: moved ' .. moved .. 'x ' .. item.name .. ' -> ' .. dest)
                    else
                        report_single_move_failure(item.name, dest)
                    end
                -- Wait per move bumped 0.5 -> 1.5 to cover the two-leg
                -- bag-to-bag path (each item is now pull-to-inventory +
                -- push-to-dest, two MOVE_DELAY ticks apart). Over-waits
                -- harmlessly for one-leg moves.
                end, 2 + move_count * 1.5)
            else
                ui.set_status('Nothing to move')
            end
        elseif item.bag_name == dest then
            ui.set_status('Already in ' .. dest)
        else
            -- Single-item move: snapshot the source slot's count, attempt,
            -- and verify the slot drained.
            local src_before = item.count or 1
            bag_org.queue_move(item.bag_name, item.bag_index, dest, item.count, item.id)
            start_move_pump()
            ui.set_status(item.name .. ' -> ' .. dest)
            coroutine.schedule(function()
                if not initialized or _zoning then return end
                refresh_organizer()
                local src_after = 0
                for _, it in ipairs(_org_all_bag_items[item.bag_name] or {}) do
                    if it.id == item.id and it.bag_index == item.bag_index then
                        src_after = it.count
                        break
                    end
                end
                local moved = src_before - src_after
                if moved > 0 then
                    windower.add_to_chat(207, 'GSUI: moved ' .. moved .. 'x ' .. item.name .. ' (' .. item.bag_name .. ' -> ' .. dest .. ')')
                else
                    report_single_move_failure(item.name, bag_org.is_mog_bag(dest) and dest or item.bag_name)
                end
            end, 1.5)
        end
    elseif action.type == 'select' then
        ui.set_status('Selected: ' .. (action.item.name or '?'))
    elseif action.type == 'deselect' then
        ui.set_status('')
    elseif action.type == 'show_bag' then
        show_org_bag(action.bag_name)
    end
end

local function handle_click(mx, my)
    local hit = ui.hit_test(mx, my)
    if not hit then return false end

    -- Close dropdown if clicking outside it
    if ui.is_dropdown_open() then
        if hit.type ~= 'filter_dropdown' and hit.type ~= 'filter_menu_item' and hit.type ~= 'filter_menu' then
            ui.close_dropdown()
            return true
        end
    end

    if hit.type == 'stat_label' then
        ui.toggle_stat_view()
        local eq = scanner.scan_equipment()
        update_stats(eq)
        return true
    elseif hit.type == 'kb_mode_toggle' then
        local enabled = ui.toggle_kb_mode()
        settings.kb_mode = enabled
        config.save(settings)
        sync_kb_binds()
        windower.add_to_chat(207, 'GSUI: ' .. (enabled and 'Keyboard' or 'Drag') .. ' mode.')
        return true
    elseif hit.type == 'sort_toggle' then
        ui.toggle_sort_mode()
        local view = ui.get_org_view()
        if view == 'bags' then
            show_org_bag(ui.get_org_selected_bag())
        elseif view == 'conflicts' then
            show_org_conflicts()
        elseif view == 'scattered' then
            show_org_scattered()
        end
        return true
    elseif hit.type == 'stack_button' then
        -- Fire FFXI's "Sort Item" packet (0x03A) for the bag currently
        -- being shown. Server merges same-id stacks up to each item's
        -- stack cap and reshuffles to the lowest slots. The Conflicts
        -- and Scattered views don't have a single source bag, so in
        -- those cases we stack every known bag in sequence.
        local view = ui.get_org_view()
        local targets = {}
        if view == 'bags' then
            local b = ui.get_org_selected_bag()
            if b and b ~= 'all' then
                table.insert(targets, b)
            else
                -- "All Bags" view: stack every real bag in sequence.
                for _, bag_name in ipairs(scanner.get_all_bag_names()) do
                    table.insert(targets, bag_name)
                end
            end
        else
            -- Conflicts / Scattered views: no single bag context, so
            -- stack everything.
            for _, bag_name in ipairs(scanner.get_all_bag_names()) do
                table.insert(targets, bag_name)
            end
        end
        if #targets == 0 then return true end
        local fired = 0
        for i, bag_name in ipairs(targets) do
            coroutine.schedule(function()
                if not initialized or _zoning then return end
                bag_org.sort_bag(bag_name)
            end, (i - 1) * 0.4)
            fired = fired + 1
        end
        local label = (#targets == 1) and targets[1] or (#targets .. ' bags')
        ui.set_status('Stacking ' .. label)
        windower.add_to_chat(207, 'GSUI: stacking ' .. label .. '...')
        coroutine.schedule(function()
            if not initialized or _zoning then return end
            refresh_organizer()
            windower.add_to_chat(207, 'GSUI: stack complete for ' .. label .. '.')
        end, fired * 0.4 + 1.0)
        return true
    elseif hit.type == 'org_scroll_up' then
        ui.org_bag_scroll_up()
        return true
    elseif hit.type == 'org_scroll_down' then
        ui.org_bag_scroll_down()
        return true
    elseif hit.type == 'tab_organizer' then
        if ui.get_mode() ~= 'organizer' then
            ui.set_mode('organizer')
            refresh_organizer()
            show_org_bag('inventory')
        end
        return true
    elseif hit.type == 'tab_gearswap' then
        if ui.get_mode() ~= 'gearswap' then
            ui.set_mode('gearswap')
            ui.set_inv_label('All Storage')
            ui.update_inventory(cached_all_items)
            apply_filter()
        end
        return true
    elseif hit.type == 'org_bag' then
        -- Two behaviors depending on whether you have items multi-selected:
        --   selection_count > 0  -> treat the bag as a MOVE TARGET. Same
        --                           bulk-move logic the right-click handler
        --                           used to do, only routed through left-
        --                           click because Windower / the user's
        --                           system filters right-click before it
        --                           reaches the addon (right-click only
        --                           rotates the camera).
        --   selection_count == 0 -> SWITCH VIEW to that bag (the original
        --                           behavior). show_org_bag already clears
        --                           any straggler selection.
        if ui.selection_count() > 0 then
            local dest = hit.bag_name
            local selected = ui.get_selected_items()
            -- Snapshot the DESTINATION count before queueing. The verify
            -- compares dest.count post-move vs this baseline -- that's
            -- the only number that says definitively whether items
            -- landed, regardless of overlapping bulks rearranging source
            -- slots or bag-to-bag legs leaving items briefly in inventory.
            local dest_pre = 0
            do
                local ok_snap, snap_items = pcall(windower.ffxi.get_items)
                if ok_snap and snap_items and snap_items[dest] then
                    dest_pre = snap_items[dest].count or 0
                end
            end
            local items_attempted = {}
            local queued, skipped, skipped_non_gear = 0, 0, {}
            local dest_is_wardrobe = is_wardrobe(dest)
            for _, item in ipairs(selected) do
                if item.bag_name == dest then
                    skipped = skipped + 1
                elseif dest_is_wardrobe and not is_equipment(item.id) then
                    skipped_non_gear[#skipped_non_gear+1] = item.name
                else
                    items_attempted[#items_attempted+1] = (item.count or 1) .. 'x ' .. item.name
                    bag_org.queue_move(item.bag_name, item.bag_index, dest, item.count, item.id)
                    queued = queued + 1
                end
            end
            if #skipped_non_gear > 0 then
                windower.add_to_chat(207, 'GSUI: ' .. #skipped_non_gear .. ' non-equipment item(s) skipped -> ' .. dest .. ' only holds gear: ' .. table.concat(skipped_non_gear, ', '))
            end
            ui.clear_selection()
            ui.set_status('Moving ' .. queued .. ' item(s) -> ' .. dest
                          .. (skipped > 0 and ' (' .. skipped .. ' skipped)' or '')
                          .. (#skipped_non_gear > 0 and ' (' .. #skipped_non_gear .. ' non-gear)' or ''))
            _bulk_op_id = _bulk_op_id + 1
            local my_op = _bulk_op_id
            dbg('bulk', 'A start op=' .. my_op .. ' queued=' .. queued .. ' dest=' .. dest .. ' dest_pre=' .. dest_pre)
            start_move_pump()
            coroutine.schedule(function()
                if not initialized or _zoning then return end
                if my_op ~= _bulk_op_id then
                    dbg('bulk', 'A verify SKIPPED op=' .. my_op .. ' (newer=' .. _bulk_op_id .. ')')
                    return
                end
                dbg('bulk', 'A verify firing op=' .. my_op)
                refresh_organizer()
                local dest_post = 0
                local ok_snap, snap_items = pcall(windower.ffxi.get_items)
                if ok_snap and snap_items and snap_items[dest] then
                    dest_post = snap_items[dest].count or 0
                end
                local delta = dest_post - dest_pre
                dbg('bulk', 'A op=' .. my_op .. ' dest_pre=' .. dest_pre
                            .. ' dest_post=' .. dest_post .. ' delta=' .. delta
                            .. ' queued=' .. queued)
                if delta >= queued then
                    windower.add_to_chat(207, 'GSUI: moved -> ' .. dest .. ': '
                        .. table.concat(items_attempted, ', '))
                elseif delta > 0 then
                    windower.add_to_chat(207, 'GSUI: partial move -> ' .. dest
                        .. ': ' .. delta .. ' of ' .. queued .. ' items landed.')
                    report_bulk_move_failure(queued - delta, dest)
                else
                    report_bulk_move_failure(queued, dest)
                end
            end, 1 + queued * 1.5)
        else
            show_org_bag(hit.bag_name)
        end
        return true
    elseif hit.type == 'org_conflict_btn' then
        show_org_conflicts()
        return true
    elseif hit.type == 'org_scattered_btn' then
        show_org_scattered()
        return true
    elseif hit.type == 'title_bar' then
        ui.start_drag(mx, my)
        return true
    elseif hit.type == 'scroll_up' then
        ui.scroll_up()
        return true
    elseif hit.type == 'scroll_down' then
        ui.scroll_down()
        return true
    elseif hit.type == 'generate_btn' then
        -- "Update Gear": pull the LIVE currently-equipped gear (with
        -- augments) straight from windower.ffxi.get_items() via the
        -- inventory scanner, then write it to the selected set in the
        -- .lua file. This mirrors what `//gs export` does, so what you
        -- have on right now is what lands in the file -- no parsing the
        -- GSUI grid, no dependency on what was drag-dropped in the UI.
        --
        -- (The Equipment grid on the left is still useful for visual
        -- preview; we refresh it from the captured snapshot below so the
        -- panel matches what was just written.)
        local sel_node = ui.get_selected_set_node and ui.get_selected_set_node() or nil
        windower.add_to_chat(207, ('GSUI dbg: Update Gear -> sel_node=%s has_gear=%s assignment=%s'):format(
            tostring(sel_node and sel_node.key or 'nil'),
            tostring(sel_node and sel_node.has_gear),
            tostring(sel_node and sel_node.assignment ~= nil)))
        if sel_node and sel_node.has_gear then
            -- GRID-as-source-of-truth. Earlier this read live equipped
            -- gear via scan_equipment(), but that round-tripped through
            -- the character -- meaning whatever GearSwap had auto-equipped
            -- (its in-memory cached set) is what got written, not what
            -- the user designed in the GSUI grid. User feedback:
            --   "Equip now is not equipping the set I changed it to.
            --    It equips sets that are already in my LUA but it's
            --    not equipping any changes I make"
            -- Root cause: grid edits never reached the .lua, so /gs
            -- reload kept loading the OLD set in-memory, and GearSwap
            -- auto-reverted every Equip Now call. Now we write what the
            -- grid says directly -- the grid IS the spec.
            local slots = set_gen.get_all_slots() or {}
            local changes = {}
            local slot_count = 0
            for slot, item in pairs(slots) do
                if item and item.name then
                    changes[slot] = {
                        name     = item.name,
                        augments = item.augments,   -- nil if no augments
                    }
                    slot_count = slot_count + 1
                end
            end
            windower.add_to_chat(207, ('GSUI dbg: captured %d slots from the GSUI grid'):format(slot_count))
            -- Dump the slot list so it's obvious which slots got written.
            -- Empty grid is INTENTIONAL: user feedback was "if the grid in
            -- GSUI shows I only have weapons then it should update my GS to
            -- be only weapons", which implies the grid IS the spec -- even
            -- when that spec is the empty set. Used to early-return here on
            -- empty grid; that blocked the legitimate "clear this set"
            -- workflow, so we now let the writer through and let it produce
            -- `sets.<name> = {}`.
            do
                local present = {}
                for s in pairs(changes) do present[#present+1] = s end
                table.sort(present)
                windower.add_to_chat(160, 'GSUI dbg: slots in changes: ' ..
                    (#present > 0 and table.concat(present, ', ') or '(none -- writing empty set)'))
            end
            -- Detect if writer.save returned "changed = false" (it found
            -- the assignment but the patched source ended up identical
            -- to the original — usually means no field matched).
            local ok, err = sets_ctl.save_changes(sel_node, changes)
            if ok then
                if type(ok) == 'table' and ok.changed == false then
                    ui.set_status('Save ran but no fields changed.')
                    windower.add_to_chat(167,
                        'GSUI: writer ran but produced identical text — no slot keys matched the assignment.')
                else
                    ui.set_status('Updated set in .lua (.bak created).')
                    windower.add_to_chat(207, 'GSUI: Updated ' ..
                        (sets_ctl.get_file_info().name or '?') .. '; .bak created.')
                    -- Without this, GearSwap keeps using the in-memory copy
                    -- of the sets table that was loaded at game start. The
                    -- file is fine on disk; only the in-memory state is
                    -- stale. //gs reload re-reads the file and rebuilds
                    -- the sets table so the next cast uses the new gear.
                    windower.send_command('gs reload')
                    windower.add_to_chat(160,
                        'GSUI: auto-fired "//gs reload" so the new gear takes effect immediately.')
                end
                -- Re-push the freshly-parsed tree so the panel reflects
                -- whatever changed on disk. Catch: set_sets_data() always
                -- nulls state.sets_selected_node -- so without this dance,
                -- the second click on Update Gear sees sel_node=nil, falls
                -- through to clipboard-export mode, and the file never
                -- gets rewritten. Preserve the selection by stashing the
                -- node's .path (stable across re-parses), then re-resolving
                -- it in the fresh tree via tree.find().
                local sel_path = sel_node and sel_node.path
                if ui.set_sets_data then
                    ui.set_sets_data(sets_ctl.get_tree(), sets_ctl.get_file_info())
                end
                if sel_path and ui.set_selected_set_node then
                    local ok_tm, tree_mod = pcall(require, 'libs/gear_tree/tree')
                    local fresh_tree = sets_ctl.get_tree()
                    if ok_tm and tree_mod and tree_mod.find and fresh_tree then
                        local found = tree_mod.find(fresh_tree, sel_path)
                        if found then ui.set_selected_set_node(found) end
                    end
                end
                if ui.refresh_sets_panel then ui.refresh_sets_panel() end
            else
                ui.set_status('Save failed: ' .. tostring(err))
                windower.add_to_chat(167, 'GSUI: save failed — ' .. tostring(err))
            end
            return true
        end
        -- No set selected → original Generate Set behavior (export to clipboard)
        if set_gen.has_items() then
            set_gen.generate_to_clipboard()
            ui.set_status('Copied to clipboard!')
            windower.add_to_chat(207, 'GSUI: Copied to clipboard.')
        else
            ui.set_status('No items selected.')
        end
        return true
    elseif hit.type == 'sets_row' and hit.node then
        local node = hit.node
        local has_children = node.children and #node.children > 0
        -- Click priority:
        --   has_gear (with or without children) → LOAD the set's gear.
        --     This covers GearSwap's common idiom where a parent like
        --     sets.precast.FC IS itself a gear set AND has sub-sets like
        --     FC.Cure / FC.Curaga. Without this branch, the user could
        --     never see the "general magic fast cast" gear — only the
        --     Cure-specific overrides.
        --   children only (no own gear) → toggle expand/collapse.
        if not node.has_gear then
            if has_children then ui.toggle_set_node(node) end
            return true
        end
        -- Leaf set → load its gear into the equipment grid.
        ui.set_selected_set_node(node)
        ui.refresh_sets_panel()              -- redraw with selection highlight
        ui.refresh_generate_button_label()   -- "Generate Set" → "Update Gear"

        -- Reset working grid
        custom_set_active = true
        set_gen.clear()
        ui.clear_all_equip_slots()

        -- Walk preview entries; for each slot value, try to find the
        -- matching inventory item by name and assign it.
        local preview = sets_ctl.preview_for(node)
        local missing = {}
        -- Slot-name normalizer. GearSwap files use short slot names
        -- (ear1/ear2/ring1/ring2/ranged) but the equipment grid is keyed
        -- by the canonical long names (left_ear/right_ear/left_ring/
        -- right_ring/range). Without this map, click-loading a set
        -- silently skips every ear/ring/ranged slot.
        local gear_slots_lib = require('libs/gear_tree/gear_slots')
        -- Normalize an augment string so two semantically-equal copies
        -- compare equal. The /gs export emitter and the extdata reader
        -- can produce small drift -- different quote escapes, trailing
        -- whitespace -- so we strip down to lower-case alphanumerics
        -- plus the +/- digits that actually carry the stat value. Same
        -- approach the GSUI Equip Now writer uses for /equip matching.
        local function _augnorm(s)
            return (s or ''):lower()
                :gsub('%s+', '')
                :gsub('["\']', '')
        end
        for _, entry in ipairs(preview) do
            local slot = gear_slots_lib.canonical(entry.slot)
            local val = entry.value
            local want_name = nil
            local want_augments = nil   -- list of augment-line strings, or nil
            if type(val) == 'string' then
                -- The parser stores slot values as raw RHS expressions —
                -- for set_combine'd sets this is often `vanya.head` or
                -- `{ name = "Foo", augments = {...} }`. Resolve through
                -- the local-var table sets_ctl built at open() time so
                -- references like `vanya.head` turn into "Vanya Hood +1".
                want_name     = sets_ctl.resolve_value(val) or val
                want_augments = sets_ctl.resolve_augments(val)
            elseif type(val) == 'table' then
                want_name     = val.name
                want_augments = val.augments
            end
            if want_name then
                local item_info = nil
                -- Pre-resolve once outside the inventory walk. Inner
                -- loop becomes pure id-or-name compare (O(1) per cached
                -- item) instead of the previous O(res.items size) per
                -- cached item -- this was the "click a set, GSUI lags
                -- like crazy" bug. With ~10k res.items entries, hoisting
                -- this cut the inner work by ~10,000x.
                local want_id = _resolve_name_to_id(want_name)
                -- When the lua slot specifies augments, prefer the
                -- inventory copy whose extdata-decoded augments match
                -- the specified set. Without this, "Alaunus's Cape" with
                -- three augment variants in inventory would silently
                -- return the first one, and the tooltip would render
                -- with an arbitrary augment list (or none) regardless
                -- of what the lua actually declared.
                local fallback = nil   -- first name/id match without augment scoring
                for _, it in ipairs(cached_all_items) do
                    if it.name == want_name
                        or (want_id and it.id == want_id) then
                        if not fallback then fallback = it end
                        if want_augments and #want_augments > 0 then
                            -- Require every augment specified by the lua
                            -- to be present (normalized) in the item's
                            -- extdata. Inventory items without augments
                            -- (legacy bare-name entries) can never match
                            -- and fall through to the next candidate.
                            local it_augs = it.augments or {}
                            local matched_count = 0
                            for _, want_a in ipairs(want_augments) do
                                local wn = _augnorm(want_a)
                                for _, have_a in ipairs(it_augs) do
                                    if _augnorm(have_a) == wn then
                                        matched_count = matched_count + 1
                                        break
                                    end
                                end
                            end
                            if matched_count == #want_augments then
                                item_info = it
                                break
                            end
                        else
                            -- No augments specified by the lua -- use the
                            -- first match. This preserves the prior "first
                            -- of N" behavior for bare-name slot picks.
                            item_info = it
                            break
                        end
                    end
                end
                -- Augment-match failed -- fall back to the first
                -- name/id match so the slot still shows SOMETHING. The
                -- tooltip will render with whichever variant landed.
                if not item_info and fallback then item_info = fallback end
                if item_info then
                    ui.set_equip_slot_item(slot, item_info)
                    set_gen.set_slot(slot, item_info)
                else
                    -- Item not in inventory — still show the name so the
                    -- user knows what the set expects. Build a stub with
                    -- every field the tooltip/stat code reads, defaulted
                    -- to empty so #item.jobs etc. don't crash.
                    local stub = {
                        name        = want_name,
                        slot        = slot,
                        id          = 0,
                        jobs        = {},
                        level       = 0,
                        item_level  = 0,
                        stats       = '',
                        augments    = nil,
                        description = '(not in inventory)',
                        bag_name    = nil,
                        bag_index   = nil,
                        category    = 'Armor',
                    }
                    ui.set_equip_slot_item(slot, stub)
                    set_gen.set_slot(slot, stub)
                    table.insert(missing, want_name)
                end
            end
        end
        update_custom_stats()
        local path_str = '?'
        local ok, tree_mod = pcall(require, 'libs/gear_tree/tree')
        if ok and tree_mod and tree_mod.path_string then
            path_str = tree_mod.path_string(node) or '?'
        end
        if #missing == 0 then
            ui.set_status('Loaded ' .. path_str)
        else
            ui.set_status('Loaded ' .. path_str .. ' (' .. #missing .. ' missing)')
        end
        windower.add_to_chat(207, 'GSUI: Loaded ' .. path_str ..
            (#missing > 0 and (' (' .. #missing .. ' items missing in storage)') or ''))
        return true
    elseif hit.type == 'filter_dropdown' then
        ui.toggle_dropdown()
        return true
    elseif hit.type == 'filter_menu_item' then
        ui.set_active_filter(hit.index)
        return true
    elseif hit.type == 'remove_btn' then
        -- Single-slot Remove. Uses whatever slot the user has focused
        -- via clicking it in the equipment grid (state.slot_filter).
        -- If no slot is focused, prompt them to pick one first.
        local slot = ui.get_slot_filter and ui.get_slot_filter() or nil
        if not slot then
            ui.set_status('Click a slot first, then Remove.')
            windower.add_to_chat(167, 'GSUI: Remove -- no slot focused. Click a slot in the equipment grid first.')
            return true
        end
        custom_set_active = true
        set_gen.remove_slot(slot)
        if ui.clear_equip_slot then
            ui.clear_equip_slot(slot)
        elseif ui.set_equip_slot_item then
            ui.set_equip_slot_item(slot, nil)
        end
        update_custom_stats()
        ui.set_status(slot .. ' cleared.')
        windower.add_to_chat(207, 'GSUI: ' .. slot .. ' slot cleared.')
        return true
    elseif hit.type == 'remove_all_btn' then
        custom_set_active = true
        set_gen.clear()
        ui.clear_all_equip_slots()
        update_custom_stats()
        ui.set_status('All slots cleared.')
        windower.add_to_chat(207, 'GSUI: All equipment slots cleared.')
        return true
    elseif hit.type == 'reequip_btn' then
        -- "Equip Now" -- applies every slot in the GSUI grid to the
        -- character via the augment-aware _send_equip helper. Augmented
        -- items go through `//gs equip` (which matches the augment block
        -- in inventory) so the right cape / weapon variant lands instead
        -- of whichever copy /equip happened to find first.
        --
        -- The grid's source-of-truth pattern is now:
        --   * "Update Gear" READS live equipped -> grid -> .lua
        --   * "Equip Now"   WRITES grid -> character (no .lua touch)
        -- so this branch no longer has the prior "reset to equipped"
        -- fallback -- Update Gear already does that direction better.
        local slots = set_gen.get_all_slots()
        if not slots or not next(slots) then
            ui.set_status('Nothing in the GSUI grid to equip.')
            windower.add_to_chat(167, 'GSUI: Equip Now -- grid is empty. Drop items in the slots first (or use Update Gear / Load).')
            return true
        end

        -- Pre-scan inventory to know what we can actually equip. Items not
        -- in any reachable bag are silently skipped -- no red "could not
        -- locate X" spam per missing slot. User specifically asked for
        -- this: "maybe it needs to skip stuff that can't be found."
        --
        -- Approach matches what GearSwap's equip() does internally: build
        -- a list of available items first, then fire one /input /equip
        -- per slot the game can actually fulfill. /equip is the same
        -- mechanism /gs export round-trips through, so behavior is
        -- consistent with what the user sees when they manually export.
        local available = {}   -- canonical_name(lowercased) -> true
        for bag_name, bag_id in pairs(scanner.get_all_bag_ids() or {}) do
            local ok, bag_items = pcall(windower.ffxi.get_items, bag_id)
            if ok and bag_items and bag_items.enabled then
                for _, raw in pairs(bag_items) do
                    if type(raw) == 'table' and raw.id and raw.id > 0 then
                        local def = res.items[raw.id]
                        if def then
                            if def.english     then available[def.english:lower()]     = true end
                            if def.en          then available[def.en:lower()]          = true end
                            if def.english_log then available[def.english_log:lower()] = true end
                            if def.enl         then available[def.enl:lower()]         = true end
                        end
                    end
                end
            end
        end

        local SLOT_ORDER = {
            'main', 'sub', 'range', 'ammo',
            'head', 'body', 'hands', 'legs', 'feet',
            'neck', 'waist', 'left_ear', 'right_ear',
            'left_ring', 'right_ring', 'back',
        }
        local sent, skipped = 0, {}
        local idx = 0
        for _, slot_name in ipairs(SLOT_ORDER) do
            local item = slots[slot_name]
            if item and item.name and item.name ~= '' then
                if available[item.name:lower()] then
                    local chat_slot = _SLOT_TO_CHAT[slot_name] or slot_name
                    local cmd = 'input /equip ' .. chat_slot .. ' "' .. item.name .. '"'
                    local delay = idx * 0.20
                    idx = idx + 1
                    sent = sent + 1
                    coroutine.schedule(function()
                        windower.send_command(cmd)
                    end, delay)
                else
                    skipped[#skipped + 1] = slot_name .. '=' .. item.name
                end
            end
        end
        local total_time = math.max(0, (idx - 1) * 0.20)
        local msg = ('GSUI: Equip Now -- %d sent via /equip over %.1fs.'):format(sent, total_time)
        if #skipped > 0 then
            msg = msg .. (' Skipped %d (not in inventory): %s'):format(#skipped, table.concat(skipped, ', '))
        end
        ui.set_status(('Equip Now: %d sent, %d skipped.'):format(sent, #skipped))
        windower.add_to_chat(207, msg)
        return true
    elseif hit.type == 'save_btn' then
        if set_gen.has_items() then
            -- Prompt for name via chat
            ui.set_status('Use: /gsui save <name>')
            windower.add_to_chat(207, 'GSUI: Use /gsui save <name> to save current set.')
        else
            ui.set_status('No items to save.')
        end
        return true
    elseif hit.type == 'load_btn' then
        local sets = set_gen.list_sets()
        if #sets == 0 then
            ui.set_status('No saved sets.')
            windower.add_to_chat(207, 'GSUI: No saved sets found.')
        else
            windower.add_to_chat(207, 'GSUI: Saved sets:')
            for _, name in ipairs(sets) do
                windower.add_to_chat(207, '  ' .. name)
            end
            ui.set_status('Use: /gsui load <name>')
            windower.add_to_chat(207, 'GSUI: Use /gsui load <name> to load a set.')
        end
        return true
    elseif hit.type == 'equip_slot' then
        -- Left-click on equip slot: toggle slot filter so the inventory pane
        -- shows only items eligible for that slot. Works whether the slot
        -- is currently empty OR already populated — that's how the user
        -- swaps out an already-equipped piece (click slot to arm it for
        -- replacement, then click an inventory item).
        if hit.slot then
            if ui.get_slot_filter() == hit.slot then
                ui.clear_slot_filter()
                ui.set_inv_label('All Storage')
            else
                ui.set_slot_filter(hit.slot)
            end
            apply_filter()
        end
        if hit.item then ui.update_tooltip(hit.item) end
        return true
    elseif hit.type == 'inv_item' then
        if hit.item then
            ui.update_tooltip(hit.item)
            -- Organizer mode: LEFT-click toggles multi-select (instead of
            -- starting a drag, since you can't drag-equip in the organizer
            -- anyway -- the workflow there is "tag items -> right-click a
            -- bag to bulk-move"). Right-click also toggles selection, so
            -- either button works.
            --
            -- All other modes (regular inventory, Sets tab): left-click
            -- still starts drag-and-drop as before.
            if ui.get_mode() == 'organizer' and not ui.get_kb_mode() then
                local now_selected = ui.toggle_selection(hit.item)
                local count = ui.selection_count()
                ui.set_status((now_selected and 'Selected: ' or 'Deselected: ')
                              .. hit.item.name .. ' (' .. count .. ')')
            elseif not ui.get_kb_mode() then
                -- Start drag-and-drop (only in drag mode)
                ui.start_item_drag(hit.item)
            end
        end
        return true
    elseif hit.type == 'window' then
        return true
    end

    return false
end

local function handle_mouse_up(mx, my)
    -- Window drag release
    if ui.is_dragging() then
        ui.stop_drag()
        save_position()
        return true
    end

    -- Item drag-and-drop release
    if ui.is_item_dragging() then
        local drop = ui.end_item_drag(mx, my)
        if drop and drop.item then
            if drop.type == 'equip' then
                -- Slot protection
                if not scanner.can_equip_in_slot(drop.item, drop.slot) then
                    ui.set_status('Cannot equip ' .. drop.item.name .. ' in ' .. drop.slot)
                    windower.add_to_chat(207, 'GSUI: ' .. drop.item.name .. ' cannot be equipped in ' .. drop.slot)
                    return true
                end
                -- Dropped on an equipment slot
                custom_set_active = true
                set_gen.set_slot(drop.slot, drop.item)
                ui.set_equip_slot_item(drop.slot, drop.item)
                ui.set_status(drop.item.name .. ' -> ' .. drop.slot)
                ui.update_tooltip(drop.item)
                update_custom_stats()
                windower.add_to_chat(207, 'GSUI: ' .. drop.item.name .. ' assigned to ' .. drop.slot)
            elseif drop.type == 'bag' then
                -- Dropped on a bag in organizer.
                -- Same attempt-then-verify pattern as action.type=='bag'
                -- (see comment up there for rationale).
                local dest = drop.bag_name
                local item = drop.item
                if ui.get_org_view() == 'scattered' and _org_all_bag_items then
                    local dest_before = 0
                    for _, it in ipairs(_org_all_bag_items[dest] or {}) do
                        if it.id == item.id then dest_before = dest_before + it.count end
                    end
                    local move_count = 0
                    for bag_name, items in pairs(_org_all_bag_items) do
                        if bag_name ~= dest then
                            for _, bag_item in ipairs(items) do
                                if bag_item.id == item.id then
                                    bag_org.queue_move(bag_name, bag_item.bag_index, dest, bag_item.count, bag_item.id)
                                    move_count = move_count + 1
                                end
                            end
                        end
                    end
                    if move_count > 0 then
                        ui.set_status('Consolidating ' .. item.name .. ' -> ' .. dest)
                        start_move_pump()
                        coroutine.schedule(function()
                            if not initialized or _zoning then return end
                            refresh_organizer()
                            local dest_after = 0
                            for _, it in ipairs(_org_all_bag_items[dest] or {}) do
                                if it.id == item.id then dest_after = dest_after + it.count end
                            end
                            local moved = dest_after - dest_before
                            if moved > 0 then
                                windower.add_to_chat(207, 'GSUI: moved ' .. moved .. 'x ' .. item.name .. ' -> ' .. dest)
                            else
                                report_single_move_failure(item.name, dest)
                            end
                        end, 1 + move_count * 1.5)
                    else
                        ui.set_status('Nothing to move')
                    end
                elseif item.bag_name == dest then
                    ui.set_status('Already in ' .. dest)
                else
                    -- Same attempt-then-verify pattern.
                    local src_before = item.count or 1
                    bag_org.queue_move(item.bag_name, item.bag_index, dest, item.count, item.id)
                    start_move_pump()
                    ui.set_status(item.name .. ' -> ' .. dest)
                    coroutine.schedule(function()
                        if not initialized or _zoning then return end
                        refresh_organizer()
                        local src_after = 0
                        for _, it in ipairs(_org_all_bag_items[item.bag_name] or {}) do
                            if it.id == item.id and it.bag_index == item.bag_index then
                                src_after = it.count
                                break
                            end
                        end
                        local moved = src_before - src_after
                        if moved > 0 then
                            windower.add_to_chat(207, 'GSUI: moved ' .. moved .. 'x ' .. item.name .. ' (' .. item.bag_name .. ' -> ' .. dest .. ')')
                        else
                            report_single_move_failure(item.name, bag_org.is_mog_bag(dest) and dest or item.bag_name)
                        end
                    end, 1.5)
                end
            end
        end
        return true
    end

    return false
end

local function handle_hover(mx, my)
    if not ui.is_visible() then return end

    -- If dragging an item, move the drag icon
    if ui.is_item_dragging() then
        ui.move_item_drag(mx, my)
        return
    end

    local hit = ui.hit_test(mx, my)
    if hit then
        if (hit.type == 'equip_slot' or hit.type == 'inv_item') and hit.item then
            ui.update_tooltip(hit.item)
        end
    end
end

-- Events
windower.register_event('load', function()
    -- Reset the diagnostic log on every Windower start so each session
    -- begins with a clean file. If the file is huge from a long previous
    -- session that didn't reload, this keeps it bounded.
    _dbg_path = windower.addon_path .. 'debug.log'
    pcall(function()
        local f = io.open(_dbg_path, 'w')
        if f then
            f:write('# GSUI debug log -- session start ' .. os.date() .. '\n')
            f:close()
        end
    end)
    dbg('load', 'addon loaded, debug log armed')

    -- Bind the toggle hotkey through Windower's bind system. This respects
    -- FFXI's chat-input state automatically -- no manual chat_open guard
    -- needed, and the bare-letter conflict that broke macros is gone.
    local ok, msg = hotkey.bind('gsui', 'toggle',
        settings.hotkey_modifier, settings.hotkey_key)
    if ok then
        windower.add_to_chat(207, 'GSUI: ' .. msg .. '. //gsui hotkey <alt|ctrl|none|off> <key> to rebind.')
    else
        windower.add_to_chat(167, 'GSUI: hotkey bind failed -- ' .. tostring(msg))
    end
    if windower.ffxi.get_info().logged_in then
        initialize()
    end
end)

-- KB mode: use Windower bind system to intercept at DirectInput level
local kb_binds_active = false

local function kb_handle_up()    ui.kb_navigate('up') end
local function kb_handle_down()  ui.kb_navigate('down') end
local function kb_handle_left()  ui.kb_navigate('left') end
local function kb_handle_right() ui.kb_navigate('right') end

local function kb_handle_tab()
    ui.kb_switch_focus()
end

local function kb_handle_enter()
    local focus = ui.get_kb_focus()
    if focus == 'filter' then
        local idx = ui.kb_get_filter_index()
        ui.set_active_filter(idx)
        ui.kb_close_filter()
        return
    end
    if focus == 'equip' and not ui.get_kb_selected_item() then
        local slot_name = ui.get_kb_equip_slot()
        local icon_data = ui.get_equip_icon_data(slot_name)
        if slot_name and (not icon_data or not icon_data.item) then
            if ui.get_slot_filter() == slot_name then
                ui.clear_slot_filter()
                ui.set_inv_label('All Storage')
            else
                ui.set_slot_filter(slot_name)
            end
            apply_filter()
            return
        end
    end
    local action = ui.kb_select()
    if action then handle_kb_action(action) end
end

local function kb_handle_escape()
    if ui.get_kb_focus() == 'filter' then
        ui.kb_close_filter()
    elseif ui.get_slot_filter() then
        ui.clear_slot_filter()
        ui.set_inv_label('All Storage')
        apply_filter()
    elseif ui.get_kb_selected_item() then
        ui.kb_cancel()
        ui.set_status('')
    end
end

local function kb_handle_delete()
    local focus = ui.get_kb_focus()
    if focus == 'equip' then
        local slot_name = ui.get_kb_equip_slot()
        if slot_name then
            set_gen.remove_slot(slot_name)
            ui.set_equip_slot_item(slot_name, nil)
            custom_set_active = true
            update_custom_stats()
            ui.set_status('Removed ' .. slot_name)
            windower.add_to_chat(207, 'GSUI: Removed ' .. slot_name)
        end
    end
end

local function kb_handle_f1()
    if ui.get_mode() ~= 'gearswap' then
        ui.set_mode('gearswap')
        ui.set_inv_label('All Storage')
        ui.update_inventory(cached_all_items)
        apply_filter()
    end
end

local function kb_handle_f2()
    if ui.get_mode() ~= 'organizer' then
        ui.set_mode('organizer')
        refresh_organizer()
        show_org_bag('inventory')
    end
end

local function kb_handle_f3()
    local enabled = ui.toggle_kb_mode()
    settings.kb_mode = enabled
    config.save(settings)
    sync_kb_binds()
    windower.add_to_chat(207, 'GSUI: ' .. (enabled and 'Keyboard' or 'Drag') .. ' mode.')
end

local function kb_handle_f4()
    if ui.get_kb_focus() == 'filter' then
        ui.kb_close_filter()
    else
        ui.kb_open_filter()
    end
end

local fn_binds_active = false

activate_fn_binds = function()
    if fn_binds_active then return end
    fn_binds_active = true
    windower.send_command('bind F1 gsui kb_f1')
    windower.send_command('bind F2 gsui kb_f2')
    windower.send_command('bind F3 gsui kb_f3')
    windower.send_command('bind F4 gsui kb_f4')
end

deactivate_fn_binds = function()
    if not fn_binds_active then return end
    fn_binds_active = false
    windower.send_command('unbind F1')
    windower.send_command('unbind F2')
    windower.send_command('unbind F3')
    windower.send_command('unbind F4')
end

activate_kb_binds = function()
    if kb_binds_active then return end
    kb_binds_active = true
    windower.send_command('bind up gsui kb_up')
    windower.send_command('bind down gsui kb_down')
    windower.send_command('bind left gsui kb_left')
    windower.send_command('bind right gsui kb_right')
    windower.send_command('bind tab gsui kb_tab')
    windower.send_command('bind enter gsui kb_enter')
    windower.send_command('bind escape gsui kb_escape')
    windower.send_command('bind delete gsui kb_delete')
    windower.send_command('bind backspace gsui kb_delete')
end

deactivate_kb_binds = function()
    if not kb_binds_active then return end
    kb_binds_active = false
    windower.send_command('unbind up')
    windower.send_command('unbind down')
    windower.send_command('unbind left')
    windower.send_command('unbind right')
    windower.send_command('unbind tab')
    windower.send_command('unbind enter')
    windower.send_command('unbind escape')
    windower.send_command('unbind delete')
    windower.send_command('unbind backspace')
end

-- LEGACY raw-keyboard toggle. The modifier-based hotkey above is the
-- primary path now. This block stays so an upgrading user with a
-- pre-existing settings.toggle_key_dik > 0 still gets that key working,
-- but new installs default toggle_key_dik = 0 (disabled) and use the
-- libs/hotkey.lua modifier system instead.
local _capture_pending = false   -- set true by //gsui changekey capture
windower.register_event('keyboard', function(dik, pressed, flags, blocked)
    if blocked then return false end
    if not pressed then return false end
    -- Capture mode: next physical key press becomes the new LEGACY binding.
    -- Kept for users who want a bare-key hotkey for some reason; the
    -- modifier-based system is preferred and doesn't go through this path.
    if _capture_pending then
        _capture_pending = false
        settings.toggle_key_dik = dik
        config.save(settings)
        local nm = DIK_DISPLAY[dik] or ('DIK_'..tostring(dik))
        windower.add_to_chat(207, 'GSUI: legacy toggle key set to ' .. nm
            .. ' (DIK ' .. tostring(dik) .. '). Modifier hotkey unaffected.')
        return true
    end
    local bound = settings.toggle_key_dik or 0
    if bound == 0 then return false end   -- legacy hotkey disabled
    local info = windower.ffxi.get_info()
    if not info or info.chat_open then return false end
    if dik == bound then
        windower.send_command('gsui')
        return true
    end
    return false
end)

windower.register_event('login', function()
    coroutine.schedule(initialize, 5)
end)

windower.register_event('logout', function()
    dbg('logout', 'event received, flipping guards')
    -- Same race-condition protection as the unload handler. Flip the
    -- guards first so any pending coroutine bails immediately, then
    -- pcall the cleanup so a partial failure doesn't strand UI
    -- elements on the screen.
    initialized = false
    _zoning     = true
    _move_pump_active = false
    pcall(bag_org.clear_queue)
    pcall(deactivate_kb_binds)
    pcall(deactivate_fn_binds)
    pcall(save_position)
    pcall(ui.destroy)
end)

windower.register_event('unload', function()
    -- Two race conditions that have crashed Windower on //lua reload:
    --
    --   1. `initialized` was never flipped to false here (only the
    --      logout handler did that). So any coroutine.schedule that
    --      fired BETWEEN the start of unload and Windower fully
    --      tearing down the Lua state would still pass its
    --      `if not initialized` guard and then touch UI elements
    --      that destroy_all() had just freed -- racing the destroy
    --      and the access.  Flip `initialized` FIRST so every
    --      remaining coroutine fast-paths out.
    --
    --   2. The bag_org move pump and the verify-coroutines kept
    --      running too. Mid-pump packet sends after the addon's
    --      destroyed state has been GC'd produce Windower crashes
    --      identical to the zone-time ones we just fixed (the
    --      inventory snapshot is in an indeterminate state for the
    --      reload window). Re-use the _zoning guard since semantics
    --      are identical -- "stop touching game state until things
    --      have settled".
    dbg('unload', 'event received, flipping guards before cleanup')
    initialized = false
    _zoning     = true               -- gates every other coroutine
    _move_pump_active = false        -- next tick will see this + bail

    -- Drop any pending moves; we don't want them firing into a
    -- half-torn-down addon. pcall everything below so one
    -- component's destruction failing doesn't leave a stale Windower
    -- text/image floating on the screen forever.
    pcall(bag_org.clear_queue)
    pcall(deactivate_kb_binds)
    pcall(deactivate_fn_binds)
    pcall(hotkey.unbind, 'gsui')
    pcall(save_position)
    pcall(ui.destroy)
    pcall(icon_handler.cleanup)
end)

-- Packet handling for real-time updates
windower.register_event('incoming chunk', function(id, original, modified, injected, blocked)
    if not initialized or _zoning then return end

    if id == 0x050 or id == 0x020 or id == 0x01F or id == 0x01E or id == 0x01B then
        -- First packet of a new burst: set the hard deadline so we
        -- never wait longer than 1s for the refresh to land, even
        -- under a packet flood (e.g. buying multiple stacks in a row).
        if not pending_refresh then
            refresh_deadline = os.clock() + 1.0
        end
        pending_refresh = true
        refresh_timer = os.clock()
    elseif id == 0x0C9 then
        -- /check examination of another player. Same packet checkparam
        -- uses. Type 1 = player examination (Type 3 = item linkshell
        -- examine etc.). Pulls every equipped slot's item id + extdata
        -- out of the packet, builds the structured shape stat_parser
        -- already understands, and displays totals in the existing
        -- stats panel with the target's name + job as the header.
        local ok, p = pcall(packets.parse, 'incoming', original)
        if ok and p and p['Type'] == 1 then
            local target = windower.ffxi.get_mob_by_index(p['Target Index'] or 0)
            local target_name = (target and target.name) or 'Unknown'
            local mjob_def = res.jobs[p['Main Job'] or 0]
            local sjob_def = res.jobs[p['Sub Job'] or 0]
            local mjob = (mjob_def and mjob_def.english_short) or '???'
            local sjob = (sjob_def and sjob_def.english_short) or '???'

            -- Build equipment_data shape: { slot_name = { item = { description, augments } } }.
            -- res.slots index matches the packet's per-slot order; the
            -- english name gets lowercased + spaces -> underscores so
            -- it matches the slot names stat_parser expects
            -- (left_ear / right_ring / etc.).
            local eq = {}
            local count = p['Count'] or 0
            for i = 1, count do
                local item_id = p['Item ' .. i]
                local ext     = p['ExtData ' .. i]
                if item_id and item_id > 0 then
                    local item_def = res.items[item_id]
                    local slot_def = res.slots[i - 1]
                    if item_def and slot_def then
                        local slot_name = slot_def.english:lower():gsub(' ', '_')
                        local augments
                        if ext then
                            local ok_ext, decoded = pcall(extdata.decode,
                                { id = item_id, extdata = ext })
                            if ok_ext and decoded and decoded.augments then
                                augments = decoded.augments
                            end
                        end
                        eq[slot_name] = {
                            item = {
                                description = item_def.description,
                                augments    = augments,
                            }
                        }
                    end
                end
            end

            _last_checked = { name = target_name, mjob = mjob, sjob = sjob, eq = eq }
            _stats_mode = 'check'

            -- Render the check totals in the stats panel. Self-refresh
            -- calls to update_stats are gated on _stats_mode so they
            -- can't overwrite this until the user runs //gsui mystats.
            local totals = stat_parser.calc_totals(eq)
            local view = ui.get_stat_view and ui.get_stat_view() or 'gear'
            local summary = (view == 'total')
                              and stat_parser.format_total_summary(totals)
                              or  stat_parser.format_summary(totals)
            ui.update_stat_text(
                '-- ' .. target_name .. ' (' .. mjob .. '/' .. sjob .. ') --\n'
                .. summary)
            windower.add_to_chat(207, 'GSUI: showing stats for ' .. target_name
                .. ' (' .. mjob .. '/' .. sjob .. '). //gsui mystats to switch back.')
        end
    elseif id == 0x05F then -- Music Change: BGM Type 6 = mog house
        local bgm_type = original:byte(5) + original:byte(6) * 256
        -- Only SET mog house on type 6; never UNSET from music packets
        -- (unsetting is handled by zoning packet 0x00B)
        if bgm_type == 6 and not bag_org.is_in_mog_house() then
            bag_org.set_mog_house(true)
            ui.set_mog_house(true)
            if ui.get_mode() == 'organizer' then
                coroutine.schedule(function()
                    if initialized then refresh_organizer() end
                end, 0.5)
            end
        end
    elseif id == 0x00A then -- Zone finish
        dbg('00A', 'zone-finish packet received, _zoning=' .. tostring(_zoning))
        local my_session = _zoning_session
        coroutine.schedule(function()
            if not initialized then
                dbg('00A', 'rebuild skipped: not initialized')
                return
            end
            -- If a second zone fired in between, drop this stale rebuild
            -- so it doesn't run against the new zone's half-loaded state.
            if my_session ~= _zoning_session then
                dbg('00A', 'rebuild skipped: stale session (got ' .. my_session .. ', now ' .. _zoning_session .. ')')
                return
            end
            -- Sync the cached mog-house flag from LIVE bag-enabled state.
            -- Old code looked for 'Residential' in the zone name; that
            -- string doesn't appear in any res/zones.lua entry, so the
            -- flag never got restored after 0x00B cleared it -- meaning
            -- Mog Garden (zone 280, has Mog Safe + Locker auto-enabled),
            -- Nomad Moogles, Porter Moogles, and the actual Mog House
            -- all looked like "not in mog house" until a bag-move
            -- specifically retried it. bag_org.is_in_mog_house() polls
            -- windower.ffxi.get_items()[bag].enabled for every mog bag
            -- and returns true if any of them is accessible -- that's
            -- the authoritative live signal.
            local live_mog = bag_org.is_in_mog_house()
            bag_org.set_mog_house(live_mog)
            ui.set_mog_house(live_mog)
            dbg('00A', 'mog house flag synced from live: ' .. tostring(live_mog))
            ui.build()
            refresh_data()
            if ui.get_mode() == 'organizer' then
                refresh_organizer()
            end
            if settings.visible == false then
                ui.hide()
            end
            -- Only clear _zoning AFTER the rebuild has completed against a
            -- valid inventory snapshot. If the snapshot still looks empty
            -- (max == 0 or nil), keep _zoning armed and retry shortly.
            local snap = windower.ffxi.get_items()
            local snap_ok = snap and snap.inventory
                            and (snap.inventory.max or 0) > 0
            if snap_ok then
                dbg('00A', 'rebuild ok, snap valid, clearing _zoning')
                _zoning = false
            else
                dbg('00A', 'snap invalid (max='..tostring(snap and snap.inventory and snap.inventory.max)..
                           '), keeping _zoning armed, retrying in 1s')
                coroutine.schedule(function()
                    if my_session ~= _zoning_session then return end
                    local s = windower.ffxi.get_items()
                    if s and s.inventory and (s.inventory.max or 0) > 0 then
                        dbg('00A-retry', 'snap valid, clearing _zoning')
                        _zoning = false
                    else
                        dbg('00A-retry', 'snap STILL invalid, will rely on safety ceiling')
                    end
                end, 1)
            end
        end, 3)
    elseif id == 0x00B then -- Zoning
        _zoning_session = _zoning_session + 1
        local my_session = _zoning_session
        dbg('00B', 'zone packet received, session=' .. my_session)
        -- IMPORTANT diagnostic ordering: flip _zoning + stop pump BEFORE
        -- ui.hide() so any in-flight texts/images coroutine bails. Then
        -- breadcrumb between every step -- if we crash here the last
        -- log line tells us which call AV'd d3d8.dll.
        _zoning = true                      -- guard for any other coroutine FIRST
        _move_pump_active = false           -- stops the tick coroutine
        dbg('00B', 'step 1: flipped _zoning + pump')
        pcall(bag_org.clear_queue)
        dbg('00B', 'step 2: queue cleared')
        pcall(bag_org.set_mog_house, false)
        dbg('00B', 'step 3: bag_org mog flag cleared')
        pcall(ui.set_mog_house, false)
        dbg('00B', 'step 4: ui mog flag cleared')
        local ok_hide, err_hide = pcall(ui.hide)
        dbg('00B', 'step 5: ui.hide() returned ok=' .. tostring(ok_hide)
                   .. (err_hide and (' err=' .. tostring(err_hide)) or ''))
        pcall(sync_kb_binds)
        dbg('00B', 'step 6: sync_kb_binds done')
        if ui.clear_selection then
            pcall(ui.clear_selection)
            dbg('00B', 'step 7: selection cleared')
        end
        -- Safety ceiling: if 0x00A never arrives (disconnect, missed
        -- packet, etc.) force _zoning false after a long timeout so the
        -- UI doesn't stay frozen forever. 30s is generous for the worst
        -- long-zone (Reisenjima, Vagary, Dynamis Divergence) and short
        -- enough that a forgotten _zoning isn't user-visible for long.
        -- Session check makes sure this only fires for the LATEST zone,
        -- not a stale prior-zone safety.
        coroutine.schedule(function()
            if my_session ~= _zoning_session then return end
            if _zoning then
                dbg('safety', '30s ceiling reached without 0x00A clear, forcing _zoning=false')
                _zoning = false
            end
        end, 30)
    end
end)

windower.register_event('outgoing chunk', function(id, original, modified, injected, blocked)
    if not initialized or _zoning then return end
    if id == 0x100 then -- Job change
        if not pending_refresh then
            refresh_deadline = os.clock() + 1.0
        end
        pending_refresh = true
        refresh_timer = os.clock()
    end
end)

-- Job change event: refresh after server has updated player data
windower.register_event('job change', function()
    if not initialized or _zoning then return end
    coroutine.schedule(function()
        if initialized then
            custom_set_active = false
            refresh_data()
            set_gen.clear()
            local eq = scanner.scan_equipment()
            set_gen.populate_from_equipment(eq)
            update_stats(eq)
            -- Rebuild filters for new job
            local active_filters = scanner.find_active_filters(cached_all_items)
            ui.update_filter_presets(active_filters)
            -- Re-locate + re-parse the GS file for the new job
            local p = windower.ffxi.get_player()
            if p and p.name and p.main_job then
                local ok = sets_ctl.open(p.name, p.main_job)
                if ok then
                    local info = sets_ctl.get_file_info()
                    if ui.set_sets_data then ui.set_sets_data(sets_ctl.get_tree(), info) end
                else
                    if ui.set_sets_data then ui.set_sets_data(nil, nil) end
                end
            end
        end
    end, 2)
end)

-- Mouse handling
windower.register_event('mouse', function(type, x, y, delta, blocked)
    if not initialized or not ui.is_visible() then return false end

    local over = ui.is_over_window(x, y)

    -- KB mode: block all game mouse input (clicks outside GSUI window)
    if ui.get_kb_mode() and not over then
        return true
    end

    -- Right click down: remove piece from equip slot / toggle multi-select / bulk-move
    if type == 3 then
        if over then
            local hit = ui.hit_test(x, y)
            -- Organizer-mode diagnostic. The move-to-bag workflow needs
            -- the RIGHT-click to land on a BAG entry in the left sidebar,
            -- not on the items themselves. Right-clicking the items just
            -- toggles them off the selection (the existing inv_item
            -- behavior). Print a one-line hint so silent failures are
            -- obvious — common confusion is "I highlighted items, I'm
            -- right-clicking on them to move, why nothing happens".
            if ui.get_mode() == 'organizer' and ui.selection_count() > 0 then
                local kind = (hit and hit.type) or 'nothing'
                if kind == 'inv_item' then
                    -- Don't change behavior, but warn so the user knows
                    -- they're about to deselect rather than move.
                    ui.set_status(('Tip: right-click a BAG in the left sidebar to MOVE the %d selected item(s). Right-clicking items toggles them off.')
                                  :format(ui.selection_count()))
                elseif kind ~= 'org_bag' and kind ~= 'equip_slot' then
                    ui.set_status(('Right-click a BAG in the left sidebar to move (%d selected, you clicked: %s)')
                                  :format(ui.selection_count(), kind))
                    return true
                end
            end
            if hit and hit.type == 'equip_slot' and hit.slot and hit.item then
                custom_set_active = true
                set_gen.remove_slot(hit.slot)
                ui.set_equip_slot_item(hit.slot, nil)
                update_custom_stats()
                ui.set_status('Removed ' .. hit.slot)
                windower.add_to_chat(207, 'GSUI: Removed ' .. hit.slot)
            elseif hit and hit.type == 'inv_item' and hit.item then
                -- Toggle item in multi-select set (works in both modes;
                -- bulk-move via right-click on a bag only fires in Organizer).
                local now_selected = ui.toggle_selection(hit.item)
                local count = ui.selection_count()
                ui.set_status((now_selected and 'Selected: ' or 'Deselected: ') .. hit.item.name .. ' (' .. count .. ')')
            elseif hit and hit.type == 'org_bag' and hit.bag_name then
                -- Move every selected item into this bag.
                -- Same attempt-then-verify pattern (no preflight, diff
                -- after) -- each queued move is tracked by its source
                -- slot's pre-count so we can name what actually landed.
                local dest = hit.bag_name
                local selected = ui.get_selected_items()
                if #selected == 0 then
                    ui.set_status('No items selected. Right-click items first.')
                else
                    -- Snapshot the DESTINATION count before queueing.
                    -- See site A for why this is more robust than the old
                    -- source-slot lookup.
                    local dest_pre = 0
                    do
                        local ok_snap, snap_items = pcall(windower.ffxi.get_items)
                        if ok_snap and snap_items and snap_items[dest] then
                            dest_pre = snap_items[dest].count or 0
                        end
                    end
                    local items_attempted = {}
                    local queued, skipped, skipped_non_gear = 0, 0, {}
                    local dest_is_wardrobe = is_wardrobe(dest)
                    for _, item in ipairs(selected) do
                        if item.bag_name == dest then
                            skipped = skipped + 1
                        elseif dest_is_wardrobe and not is_equipment(item.id) then
                            skipped_non_gear[#skipped_non_gear+1] = item.name
                        else
                            items_attempted[#items_attempted+1] = (item.count or 1) .. 'x ' .. item.name
                            bag_org.queue_move(item.bag_name, item.bag_index, dest, item.count, item.id)
                            queued = queued + 1
                        end
                    end
                    if #skipped_non_gear > 0 then
                        windower.add_to_chat(207, 'GSUI: ' .. #skipped_non_gear .. ' non-equipment item(s) skipped -> ' .. dest .. ' only holds gear: ' .. table.concat(skipped_non_gear, ', '))
                    end
                    ui.clear_selection()
                    ui.set_status('Moving ' .. queued .. ' item(s) -> ' .. dest
                                  .. (skipped > 0 and ' (' .. skipped .. ' skipped)' or '')
                                  .. (#skipped_non_gear > 0 and ' (' .. #skipped_non_gear .. ' non-gear)' or ''))
                    _bulk_op_id = _bulk_op_id + 1
                    local my_op = _bulk_op_id
                    dbg('bulk', 'B start op=' .. my_op .. ' queued=' .. queued .. ' dest=' .. dest .. ' dest_pre=' .. dest_pre)
                    -- Drain the queue. Without this nothing ever moves;
                    -- bag_org.queue_move only appends to the queue.
                    start_move_pump()
                    coroutine.schedule(function()
                        if not initialized or _zoning then return end
                        if my_op ~= _bulk_op_id then
                            dbg('bulk', 'B verify SKIPPED op=' .. my_op .. ' (newer=' .. _bulk_op_id .. ')')
                            return
                        end
                        dbg('bulk', 'B verify firing op=' .. my_op)
                        refresh_organizer()
                        local dest_post = 0
                        local ok_snap, snap_items = pcall(windower.ffxi.get_items)
                        if ok_snap and snap_items and snap_items[dest] then
                            dest_post = snap_items[dest].count or 0
                        end
                        local delta = dest_post - dest_pre
                        dbg('bulk', 'B op=' .. my_op .. ' dest_pre=' .. dest_pre
                                    .. ' dest_post=' .. dest_post .. ' delta=' .. delta
                                    .. ' queued=' .. queued)
                        if delta >= queued then
                            windower.add_to_chat(207, 'GSUI: moved -> ' .. dest .. ': '
                                .. table.concat(items_attempted, ', '))
                        elseif delta > 0 then
                            windower.add_to_chat(207, 'GSUI: partial move -> ' .. dest
                                .. ': ' .. delta .. ' of ' .. queued .. ' items landed.')
                            report_bulk_move_failure(queued - delta, dest)
                        else
                            report_bulk_move_failure(queued, dest)
                        end
                    end, 1 + queued * 1.5)
                end
            end
            return true
        end
        return false
    end

    -- Left click down
    if type == 1 then
        if over then return handle_click(x, y) or true end
        return false
    end

    -- Left click up (drags can release outside window)
    if type == 2 then
        if ui.is_dragging() or ui.is_item_dragging() then
            return handle_mouse_up(x, y) or true
        end
        if over then return true end
        return false
    end

    -- Mouse move
    if type == 0 then
        if ui.is_dragging() then ui.drag(x, y); return true end
        if ui.is_item_dragging() then ui.move_item_drag(x, y); return true end
        if over then handle_hover(x, y); return true end
        return false
    end

    -- Scroll wheel
    if type == 10 then
        if over then
            local hit = ui.hit_test(x, y)
            if ui.is_dropdown_open() and hit and (hit.type == 'filter_menu_item' or hit.type == 'filter_menu') then
                if delta > 0 then ui.menu_scroll_up() else ui.menu_scroll_down() end
            elseif hit and (hit.type == 'org_bag' or hit.type == 'org_scroll_up' or hit.type == 'org_scroll_down') then
                if delta > 0 then ui.org_bag_scroll_up() else ui.org_bag_scroll_down() end
            elseif hit and hit.type == 'tooltip_panel' then
                if delta > 0 then ui.tooltip_scroll_up() else ui.tooltip_scroll_down() end
            elseif hit and hit.type == 'stat_panel' then
                if delta > 0 then ui.stat_scroll_up() else ui.stat_scroll_down() end
            elseif hit and hit.type == 'sets_row' then
                -- Scroll the sets list. positive delta = scroll UP.
                local SCROLL_PX = 14 * 3   -- 3 rows per wheel tick
                ui.scroll_sets_panel(delta > 0 and -SCROLL_PX or SCROLL_PX)
            elseif hit and (hit.type == 'inv_item' or hit.type == 'window') then
                if delta > 0 then ui.scroll_up() else ui.scroll_down() end
            end
            return true
        end
        return false
    end

    -- All other events (right click, middle click, etc.)
    if over then return true end
    return false
end)

-- Periodic refresh for pending changes + move queue.
--
-- Fires the refresh as soon as EITHER condition is met:
--   * 0.3s of quiet since the most recent inventory packet (debounce
--     so a burst of 0x020 / 0x01E packets only triggers ONE rebuild)
--   * 1.0s since the FIRST packet in the burst (hard ceiling so a
--     sustained flood -- e.g. buying lots of items rapidly -- still
--     produces a visible refresh within 1s of the first packet)
--
-- Both the gear-tab view (refresh_data) AND the organizer view
-- (refresh_organizer) are rebuilt. Previously only refresh_data ran,
-- so users browsing the Organizer pane saw stale bag contents after
-- a purchase until they switched modes / zoned.
-- Text-input visibility state. The GSUI panel auto-hides while the
-- chat input or macro editor is open so it can't ghost on top of the
-- in-game text overlay. settings.visible is left untouched -- the
-- panel reappears as soon as the user closes their text input.
local _was_input_open = false
-- Second signal for the auto-hide: track the last keyboard event that
-- arrived with blocked=true. The macro editor doesn't set chat_open
-- but routes keys through FFXI's intercept (blocked flag), so any
-- recent blocked event = text entry active.
local _last_blocked_at = 0
windower.register_event('keyboard', function(dik, pressed, flags, blocked)
    if blocked then _last_blocked_at = os.clock() end
end)

windower.register_event('prerender', function()
    if not initialized or _zoning then return end
    if pending_refresh then
        local now = os.clock()
        if (now - refresh_timer) > 0.3 or now > refresh_deadline then
            pending_refresh = false
            -- Only refresh when the UI is actually visible. Without this
            -- guard, refresh_organizer() -> refresh_org_bags() unconditionally
            -- calls show_element() on every bag entry, which un-hides the
            -- bag list after the user toggled GSUI off. User report: the
            -- "All Bags" list stayed on screen after the toggle because
            -- every inventory packet (buy / move / craft) was reviving it.
            if ui.is_visible and ui.is_visible() then
                refresh_data()
                if ui.get_mode and ui.get_mode() == 'organizer' then
                    refresh_organizer()
                end
            end
        end
    end
    if bag_org.is_moving() then
        bag_org.process_queue()
    end

    -- Hide while chat OR macro editor OR any FFXI text-entry surface is
    -- open; restore on close. See _last_blocked_at definition above
    -- for the why-two-signals rationale.
    local info = windower.ffxi.get_info()
    local input_open = (info and info.chat_open == true)
                       or (os.clock() - _last_blocked_at) < 1.5
    if input_open and not _was_input_open then
        ui.hide()
        _was_input_open = true
    elseif (not input_open) and _was_input_open then
        if settings.visible ~= false then ui.show() end
        _was_input_open = false
    end
end)

-- Status change (hide on cutscene)
windower.register_event('status change', function(new_status_id)
    if not initialized or _zoning then return end
    if new_status_id == 4 then
        ui.hide()
        sync_kb_binds()
    else
        if settings.visible ~= false then
            ui.show()
            sync_kb_binds()
        end
    end
end)

-- Commands
windower.register_event('addon command', function(...)
    local cmd = (...) and (...):lower() or ''
    local args = { select(2, ...) }

    if cmd == '' or cmd == 'toggle' then
        if not initialized then
            initialize()
        end
        ui.toggle()
        settings.visible = ui.is_visible()
        config.save(settings)
        sync_kb_binds()
    elseif cmd == 'show' then
        if not initialized then initialize() end
        ui.show()
        settings.visible = true
        config.save(settings)
        sync_kb_binds()
    elseif cmd == 'hide' then
        ui.hide()
        settings.visible = false
        config.save(settings)
        sync_kb_binds()
    elseif cmd == 'refresh' or cmd == 'scan' then
        refresh_data()
        windower.add_to_chat(207, 'GSUI: Refreshed.')
    elseif cmd == 'sets-where' or (cmd == 'sets' and args[1] == 'where') then
        -- Diagnostic — shows exactly where the locator is looking and
        -- what filenames it tries. Use this when "(no GS file)" shows up
        -- in the panel and you're not sure which name the locator wants.
        local p = windower.ffxi.get_player()
        local pname = p and p.name or '?'
        local pjob  = p and p.main_job or '?'
        local loc = require('libs/gear_tree/locator')
        windower.add_to_chat(207, 'GSUI: player="' .. pname .. '"  job="' .. pjob .. '"')
        windower.add_to_chat(207, 'GSUI: data dir = ' .. loc.data_dir())
        windower.add_to_chat(207, 'GSUI: candidate filenames being tried:')
        local cands = {
            pname .. '_' .. pjob:upper() .. '.lua',
            pname .. '_' .. pjob:lower() .. '.lua',
            pname:lower() .. '_' .. pjob:lower() .. '.lua',
            pname:upper() .. '_' .. pjob:upper() .. '.lua',
            pname .. '.lua', pname:lower() .. '.lua',
            pjob:upper() .. '.lua', pjob:lower() .. '.lua',
        }
        for _, c in ipairs(cands) do
            local f = io.open(loc.data_dir() .. c, 'r')
            local mark = f and '✓' or '✗'
            if f then f:close() end
            windower.add_to_chat(160, '  ' .. mark .. '  ' .. c)
        end
        return
    elseif cmd == 'debugenhance' or cmd == 'debugaug' then
        -- Diagnostic for the base_stats JSON loader. Walks each step of
        -- _load() manually so we can see exactly where it's silently failing.
        local target = (args[1] and table.concat(args, ' ')) or 'Prolix Ring'

        -- Step 1: addon path
        local ap = windower.addon_path or '(nil)'
        windower.add_to_chat(207, 'GSUI debug: windower.addon_path = '..tostring(ap))

        -- Step 2: can we open the JSON file directly?
        local path = ap .. 'data/item_stats.json'
        local f, err = io.open(path, 'r')
        if not f then
            windower.add_to_chat(167, 'GSUI debug: io.open FAILED for '..path..'  err='..tostring(err))
            -- Try a Windows-style backslash path too
            path = ap .. 'data\\item_stats.json'
            f, err = io.open(path, 'r')
            if not f then
                windower.add_to_chat(167, 'GSUI debug: also failed with backslash: '..path)
                return
            end
            windower.add_to_chat(207, 'GSUI debug: but backslash path WORKED: '..path)
        else
            windower.add_to_chat(207, 'GSUI debug: io.open OK for '..path)
        end
        local bytes = f:seek('end')
        windower.add_to_chat(207, 'GSUI debug: file size = '..tostring(bytes)..' bytes')
        f:close()

        -- Step 3: JSON module loadable?
        local ok_json, jmod = pcall(require, 'json')
        if not ok_json then
            ok_json, jmod = pcall(require, 'libs/json')
        end
        windower.add_to_chat(207, 'GSUI debug: json module loaded = '..tostring(ok_json))
        if not ok_json then
            windower.add_to_chat(167, '   error: '..tostring(jmod))
            return
        end
        windower.add_to_chat(207, 'GSUI debug: json.decode is function = '..tostring(type(jmod.decode) == 'function'))

        -- Step 4: base_stats module + lookup
        local ok_bs, bs = pcall(require, 'libs/base_stats')
        windower.add_to_chat(207, 'GSUI debug: require(libs/base_stats) = '..tostring(ok_bs))
        if not ok_bs then return end
        windower.add_to_chat(207, 'GSUI debug: bs.is_loaded = '..tostring(bs.is_loaded and bs.is_loaded()))
        if bs.raw_lookup then
            local raw = bs.raw_lookup(target)
            if raw then
                local parts = {}
                for k, v in pairs(raw) do parts[#parts+1] = k..'='..v end
                windower.add_to_chat(207, 'GSUI debug: raw_lookup('..target..') = { '..table.concat(parts, ', ')..' }')
            else
                windower.add_to_chat(167, 'GSUI debug: raw_lookup('..target..') = nil')
            end
            windower.add_to_chat(207, 'GSUI debug: bs.is_loaded (post-call) = '..tostring(bs.is_loaded()))
        end
        return
    elseif cmd == 'sets-reload' or cmd == 'sets' then
        -- Reparse the active GearSwap file. Used after the user edits the
        -- .lua manually outside of GSUI, or after a save to confirm the
        -- written file still parses cleanly.
        local p = windower.ffxi.get_player()
        local pname = p and p.name or '?'
        local pjob  = p and p.main_job or '?'
        local ok = sets_ctl.open(pname, pjob)
        if ok then
            local info = sets_ctl.get_file_info()
            windower.add_to_chat(207, 'GSUI: Sets reloaded from ' .. (info.name or '?'))
            if ui.set_sets_data then ui.set_sets_data(sets_ctl.get_tree(), info) end
        else
            windower.add_to_chat(167, 'GSUI: ' .. tostring(sets_ctl.get_error()))
        end
    elseif cmd == 'pos' or cmd == 'position' then
        if #args >= 2 then
            local x = tonumber(args[1])
            local y = tonumber(args[2])
            if x and y then
                ui.move_to(x, y)
                save_position()
                windower.add_to_chat(207, 'GSUI: Position set to ' .. x .. ', ' .. y)
            end
        else
            local px, py = ui.get_position()
            windower.add_to_chat(207, 'GSUI: Position: ' .. px .. ', ' .. py)
        end
    elseif cmd == 'generate' or cmd == 'gen' then
        if not set_gen.has_items() then
            local eq = scanner.scan_equipment()
            set_gen.populate_from_equipment(eq)
        end
        set_gen.generate_to_clipboard()
        windower.add_to_chat(207, 'GSUI: Copied to clipboard.')
    elseif cmd == 'clear' then
        custom_set_active = false
        set_gen.clear()
        -- Reset equip icons to actual equipment
        local eq = scanner.scan_equipment()
        ui.update_equipment(eq)
        ui.set_status('Set cleared.')
        windower.add_to_chat(207, 'GSUI: Set cleared.')
    elseif cmd == 'gamepath' or cmd == 'game_path' then
        if #args > 0 then
            local path = table.concat(args, ' ')
            settings.game_path = path
            config.save(settings)
            icon_handler.init(path)
            windower.add_to_chat(207, 'GSUI: Game path set to ' .. path)
        else
            windower.add_to_chat(207, 'GSUI: Usage: /gsui gamepath <path-to-FINAL FANTASY XI directory>')
        end
    elseif cmd == 'debug' or cmd == 'diag' or cmd == 'diagnostic' then
        -- Dumps icon-extraction state to chat. Use this when the inventory
        -- grid is blank or icons are missing to find the cause.
        icon_handler.diagnostic_report()
    elseif cmd == 'org' or cmd == 'organize' or cmd == 'organizer' then
        if not initialized then initialize() end
        if ui.get_mode() ~= 'organizer' then
            ui.set_mode('organizer')
            refresh_organizer()
            show_org_bag('inventory')
            windower.add_to_chat(207, 'GSUI: Organizer mode.')
        else
            ui.set_mode('gearswap')
            ui.set_inv_label('All Storage')
            ui.update_inventory(cached_all_items)
            apply_filter()
            windower.add_to_chat(207, 'GSUI: GearSwap mode.')
        end
    elseif cmd == 'kb' or cmd == 'keyboard' then
        if not initialized then initialize() end
        local enabled = ui.toggle_kb_mode()
        settings.kb_mode = enabled
        config.save(settings)
        sync_kb_binds()
        windower.add_to_chat(207, 'GSUI: ' .. (enabled and 'Keyboard' or 'Drag') .. ' mode.')
    elseif cmd == 'changekey' or cmd == 'togglekey' or cmd == 'hotkey' then
        -- Rebind the GSUI toggle hotkey. Two systems:
        --
        -- NEW (recommended): modifier-based, uses Windower bind so chat
        -- and macros work normally. The default since 2026-06.
        --   //gsui hotkey alt g          -- Alt+G
        --   //gsui hotkey ctrl j         -- Ctrl+J
        --   //gsui hotkey shift k        -- Shift+K
        --   //gsui hotkey none g         -- bare G (conflicts with typing)
        --   //gsui hotkey alt+g          -- combined form
        --   //gsui hotkey off            -- disable
        --
        -- LEGACY: raw DIK / keyboard event, kept for users with pre-2026
        -- settings or who want a bare scancode bind. Bare keys fire even
        -- while typing and break macros -- the modifier path is preferred.
        --   //gsui changekey <name>      -- named key from DIK_NAMES
        --   //gsui changekey #<dik>      -- raw DIK scancode 1..255
        --   //gsui changekey capture     -- next physical key sets it
        if #args == 0 then
            local mh = hotkey.display(settings.hotkey_modifier, settings.hotkey_key)
            local cur = settings.toggle_key_dik or 0
            local lg  = (cur == 0) and 'OFF' or (DIK_DISPLAY[cur] or ('DIK_'..tostring(cur)))
            windower.add_to_chat(207, 'GSUI: modifier hotkey = ' .. mh .. ' | legacy DIK = ' .. lg)
            windower.add_to_chat(207, '  //gsui hotkey <alt|ctrl|shift|none|off> <key>   - modifier hotkey (recommended)')
            windower.add_to_chat(207, '  //gsui changekey <name|#dik|capture>             - legacy raw-key bind')
            return
        end
        -- Route to modifier-based system if first arg looks like a modifier.
        local a1 = tostring(args[1]):lower()
        if a1 == 'alt' or a1 == 'ctrl' or a1 == 'shift' or a1 == 'none'
            or a1 == 'no' or a1 == 'off' or a1 == 'disable' or a1 == 'disabled'
            or a1:find('+', 1, true)
        then
            local mod, key, err = hotkey.parse_args(args[1], args[2])
            if err then
                windower.add_to_chat(167, 'GSUI: ' .. err)
                return
            end
            local ok, msg = hotkey.bind('gsui', 'toggle', mod, key)
            if ok then
                settings.hotkey_modifier = mod
                settings.hotkey_key      = key
                config.save(settings)
                windower.add_to_chat(207, 'GSUI: ' .. msg)
            else
                windower.add_to_chat(167, 'GSUI: ' .. tostring(msg))
            end
            return
        end
        -- else: legacy DIK path below
        do
            local raw = tostring(args[1])
            local key = raw:lower()
            local dik = nil
            if key == 'capture' or key == 'press' then
                _capture_pending = true
                windower.add_to_chat(207, 'GSUI: press the key you want to use as the toggle. (Press ESC to cancel.)')
                -- Snag ESC as a cancel sentinel: if it's pressed, the
                -- listener stores DIK 1 which IS the escape key. User
                -- can immediately rebind back if they meant something else.
                return
            elseif raw:sub(1,1) == '#' then
                dik = tonumber(raw:sub(2))
                if not dik or dik < 0 or dik > 255 then
                    windower.add_to_chat(167, 'GSUI: raw DIK must be a number 0-255.')
                    return
                end
            else
                dik = DIK_NAMES[key]
            end
            if dik == nil then
                windower.add_to_chat(167, 'GSUI: unknown key "' .. raw
                    .. '". Try a letter (a-z), digit (0-9), F1-F12, "off",')
                windower.add_to_chat(167, '   "#<dik>" with the raw scancode, or "capture" to press a key.')
            else
                settings.toggle_key_dik = dik
                config.save(settings)
                if dik == 0 then
                    windower.add_to_chat(207, 'GSUI: toggle key disabled. Use /gsui to toggle.')
                else
                    local nm = DIK_DISPLAY[dik] or ('DIK_'..tostring(dik))
                    windower.add_to_chat(207, 'GSUI: toggle key set to ' .. nm
                        .. ' (DIK ' .. tostring(dik) .. ').')
                end
            end
        end
    elseif cmd == 'save' then
        local name = args[1]
        if not name or name == '' then
            windower.add_to_chat(207, 'GSUI: Usage: /gsui save <name>')
            return
        end
        if not set_gen.has_items() then
            local eq = scanner.scan_equipment()
            set_gen.populate_from_equipment(eq)
        end
        local ok, path = set_gen.save_set(name)
        if ok then
            windower.add_to_chat(207, 'GSUI: Saved set "' .. name .. '" to ' .. path)
            ui.set_status('Saved: ' .. name)
        else
            windower.add_to_chat(207, 'GSUI: Failed to save set.')
        end
    elseif cmd == 'load' then
        local name = args[1]
        if not name or name == '' then
            windower.add_to_chat(207, 'GSUI: Usage: /gsui load <name>')
            return
        end
        local eq = set_gen.load_set(name)
        if eq then
            custom_set_active = true
            for slot_name, item in pairs(eq) do
                set_gen.set_slot(slot_name, item)
                ui.set_equip_slot_item(slot_name, item)
            end
            update_custom_stats()
            ui.set_status('Loaded: ' .. name)
            windower.add_to_chat(207, 'GSUI: Loaded set "' .. name .. '"')
        else
            windower.add_to_chat(207, 'GSUI: Set "' .. name .. '" not found.')
        end
    elseif cmd == 'equip' then
        -- Bulk "Equip Now" -- flush every slot in GSUI's current custom
        -- set to the character via /equip chat commands. Same target as
        -- the "Equip Now" button below; this is the slash-command form
        -- so a user can bind a key to it (e.g. //bind ^e gsui equip).
        local slots = set_gen.get_all_slots()
        local count = 0
        for slot_name, item in pairs(slots) do
            if item and item.name then
                _send_equip(slot_name, item)   -- whole table so augments survive
                count = count + 1
            end
        end
        if count > 0 then
            windower.add_to_chat(207, 'GSUI: equipped ' .. count .. ' slot(s) from custom set.')
            ui.set_status('Equipped ' .. count .. ' slots.')
        else
            windower.add_to_chat(207, 'GSUI: nothing in the custom set to equip. Click items first or //gsui load <name>.')
        end
    elseif cmd == 'delete' then
        local name = args[1]
        if not name or name == '' then
            windower.add_to_chat(207, 'GSUI: Usage: /gsui delete <name>')
            return
        end
        if set_gen.delete_set(name) then
            windower.add_to_chat(207, 'GSUI: Deleted set "' .. name .. '"')
            ui.set_status('Deleted: ' .. name)
        else
            windower.add_to_chat(207, 'GSUI: Set "' .. name .. '" not found.')
        end
    elseif cmd == 'deselect' or cmd == 'clear_selection' then
        local n = ui.selection_count()
        ui.clear_selection()
        ui.set_status('Cleared ' .. n .. ' selection(s)')
        windower.add_to_chat(207, 'GSUI: Cleared ' .. n .. ' selected item(s).')
    elseif cmd == 'sets' then
        local sets = set_gen.list_sets()
        if #sets == 0 then
            windower.add_to_chat(207, 'GSUI: No saved sets.')
        else
            windower.add_to_chat(207, 'GSUI: Saved sets:')
            for _, name in ipairs(sets) do
                windower.add_to_chat(207, '  ' .. name)
            end
        end
    elseif cmd == 'mystats' or cmd == 'selfstats' then
        -- Switch the stats panel back to your own equipped gear after
        -- a /check examination redirected it to another player.
        _stats_mode = 'self'
        _last_checked = nil
        local eq = scanner.scan_equipment()
        update_stats(eq)
        if _last_checked then
            windower.add_to_chat(207, 'GSUI: stat panel back to your own gear.')
        else
            windower.add_to_chat(207, 'GSUI: stat panel showing your own gear.')
        end
    elseif cmd == 'help' then
        windower.add_to_chat(207, 'GSUI Commands:')
        windower.add_to_chat(207, '  /gsui - Toggle window')
        windower.add_to_chat(207, '  /gsui show|hide - Show/hide window')
        windower.add_to_chat(207, '  /gsui refresh - Rescan inventory')
        windower.add_to_chat(207, '  /gsui pos <x> <y> - Set window position')
        windower.add_to_chat(207, '  /gsui gen - Generate set to clipboard')
        windower.add_to_chat(207, '  /gsui clear - Reset to currently equipped')
        windower.add_to_chat(207, '  /gsui equip - Apply current custom set to character (Equip Now)')
        windower.add_to_chat(207, '  /gsui mystats - Stats panel: switch back to your own gear after a /check')
        windower.add_to_chat(207, '  /gsui save <name> - Save current set')
        windower.add_to_chat(207, '  /gsui load <name> - Load a saved set')
        windower.add_to_chat(207, '  /gsui delete <name> - Delete a saved set')
        windower.add_to_chat(207, '  /gsui sets - List saved sets')
        windower.add_to_chat(207, '  /gsui org - Toggle organizer mode')
        windower.add_to_chat(207, '  /gsui kb - Toggle keyboard/drag mode')
        windower.add_to_chat(207, '  /gsui changekey <key> - Rebind toggle hotkey (name, #<dik>, capture, or "off")')
        windower.add_to_chat(207, '  /gsui deselect - Clear multi-select')
        windower.add_to_chat(207, '  /gsui gamepath <path> - Set FFXI install path')
        windower.add_to_chat(207, '  /gsui debug - Dump icon-extraction diagnostic (use if inventory is blank)')
        windower.add_to_chat(207, 'Multi-move (Organizer): right-click items to select (yellow tint),')
        windower.add_to_chat(207, '  then right-click a bag to move all selected there.')
    -- KB bind commands (called by Windower bind system)
    elseif cmd == 'kb_up' then kb_handle_up()
    elseif cmd == 'kb_down' then kb_handle_down()
    elseif cmd == 'kb_left' then kb_handle_left()
    elseif cmd == 'kb_right' then kb_handle_right()
    elseif cmd == 'kb_tab' then kb_handle_tab()
    elseif cmd == 'kb_enter' then kb_handle_enter()
    elseif cmd == 'kb_escape' then kb_handle_escape()
    elseif cmd == 'kb_delete' then kb_handle_delete()
    elseif cmd == 'kb_f1' then kb_handle_f1()
    elseif cmd == 'kb_f2' then kb_handle_f2()
    elseif cmd == 'kb_f3' then kb_handle_f3()
    elseif cmd == 'kb_f4' then kb_handle_f4()
    else
        windower.add_to_chat(207, 'GSUI: Unknown command. Use /gsui help')
    end
end)
