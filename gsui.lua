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
local stat_parser = require('libs/stat_parser')
-- Augment decoder for /check examination packets. Used by the 0x0C9
-- listener below to turn a player's ExtData blob into a list of
-- augment description strings that stat_parser can scan.
local extdata = require('extdata')

-- Sets controller (GearTree-style integration). Lives in its own
-- sub-window so it doesn't tangle with the main GSUI window's tab
-- system. Toggled via //gsui sets or F5.
local sets_ctl = require('libs/gear_tree/sets_controller')

-- Settings
local defaults = {
    pos = { x = 200, y = 200 },
    visible = true,
    game_path = nil,
    kb_mode = false,
}
local settings = config.load(defaults)
config.save(settings)

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

-- Organizer: scan all bags (unfiltered) and detect issues
local function refresh_organizer()
    if not initialized then return end
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
    if not initialized then return end
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

local function _send_equip(slot, item_name)
    local chat_slot = _SLOT_TO_CHAT[slot] or slot
    windower.send_command('input /equip ' .. chat_slot .. ' "' .. item_name .. '"')
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
        _send_equip(action.slot, action.item.name)
        windower.add_to_chat(207, 'GSUI: equipped ' .. action.item.name .. ' -> ' .. action.slot)
    elseif action.type == 'bag' then
        local dest = action.bag_name
        local item = action.item
        if not bag_org.is_bag_currently_accessible(dest)
           or not bag_org.is_bag_currently_accessible(item.bag_name) then
            local blocked = not bag_org.is_bag_currently_accessible(dest) and dest or item.bag_name
            ui.set_status('Bag not accessible: ' .. blocked)
            windower.add_to_chat(207, 'GSUI: ' .. blocked .. ' is not accessible from your current location. Stand in your Mog House or at a Nomad/Porter Moogle that has unlocked it.')
        elseif ui.get_org_view() == 'scattered' and _org_all_bag_items then
            local move_count = 0
            for bag_name, items in pairs(_org_all_bag_items) do
                if bag_name ~= dest and bag_org.is_bag_accessible(bag_name) then
                    for _, bag_item in ipairs(items) do
                        if bag_item.id == item.id then
                            bag_org.queue_move(bag_name, bag_item.bag_index, dest, bag_item.count)
                            move_count = move_count + 1
                        end
                    end
                end
            end
            if move_count > 0 then
                ui.set_status('Consolidating ' .. item.name .. ' -> ' .. dest)
                windower.add_to_chat(207, 'GSUI: Consolidating ' .. item.name .. ' to ' .. dest .. ' (' .. move_count .. ' moves)')
            else
                ui.set_status('Nothing to move')
            end
            coroutine.schedule(function()
                if initialized then refresh_organizer() end
            end, 1 + move_count * 0.5)
        elseif item.bag_name == dest then
            ui.set_status('Already in ' .. dest)
        else
            bag_org.queue_move(item.bag_name, item.bag_index, dest, item.count)
            ui.set_status(item.name .. ' -> ' .. dest)
            windower.add_to_chat(207, 'GSUI: Moving ' .. item.name .. ' to ' .. dest)
            coroutine.schedule(function()
                if initialized then refresh_organizer() end
            end, 1)
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
        show_org_bag(hit.bag_name)
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
        -- Context-aware: if a GearSwap set is currently selected, the
        -- "Generate Set" button is relabeled "Update Gear" by
        -- ui.refresh_generate_button_label(), and clicking it saves the
        -- current equipment grid contents back into that set in the .lua
        -- file via writer.save (with .bak backup).
        local sel_node = ui.get_selected_set_node and ui.get_selected_set_node() or nil
        windower.add_to_chat(207, ('GSUI dbg: Update Gear -> sel_node=%s has_gear=%s assignment=%s'):format(
            tostring(sel_node and sel_node.key or 'nil'),
            tostring(sel_node and sel_node.has_gear),
            tostring(sel_node and sel_node.assignment ~= nil)))
        if sel_node and sel_node.has_gear then
            local changes = {}
            local slot_count = 0
            for slot, item in pairs(set_gen.get_all_slots() or {}) do
                if item and item.name then
                    changes[slot] = { name = item.name }
                    slot_count = slot_count + 1
                end
            end
            windower.add_to_chat(207, ('GSUI dbg: %d slots in changes table'):format(slot_count))
            if not next(changes) then
                ui.set_status('No equipment to save.')
                windower.add_to_chat(167, 'GSUI: set_gen has 0 slots — nothing to save.')
                return true
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
                -- whatever changed on disk
                if ui.set_sets_data then
                    ui.set_sets_data(sets_ctl.get_tree(), sets_ctl.get_file_info())
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
        for _, entry in ipairs(preview) do
            local slot = gear_slots_lib.canonical(entry.slot)
            local val = entry.value
            local want_name = nil
            if type(val) == 'string' then
                -- The parser stores slot values as raw RHS expressions —
                -- for set_combine'd sets this is often `vanya.head` or
                -- `{ name = "Foo", augments = {...} }`. Resolve through
                -- the local-var table sets_ctl built at open() time so
                -- references like `vanya.head` turn into "Vanya Hood +1".
                want_name = sets_ctl.resolve_value(val) or val
            elseif type(val) == 'table' then
                want_name = val.name
            end
            if want_name then
                local item_info = nil
                for _, it in ipairs(cached_all_items) do
                    if it.name == want_name then
                        item_info = it
                        break
                    end
                end
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
    elseif hit.type == 'remove_all_btn' then
        custom_set_active = true
        set_gen.clear()
        ui.clear_all_equip_slots()
        update_custom_stats()
        ui.set_status('All slots cleared.')
        windower.add_to_chat(207, 'GSUI: All equipment slots cleared.')
        return true
    elseif hit.type == 'reequip_btn' then
        -- Dual purpose:
        --   * If a custom set is pending (the user has been clicking
        --     items into the equip pane), commit the whole pending set
        --     to the character via /equip chat commands. This is the
        --     "Equip Now" / batch-apply path users asked for.
        --   * Otherwise, do the original behavior: reset GSUI's display
        --     to whatever's currently equipped on the character. Useful
        --     when the user wants to start a new build from scratch.
        if custom_set_active and set_gen.has_items() then
            local slots = set_gen.get_all_slots()
            local count = 0
            for slot_name, item in pairs(slots) do
                if item and item.name then
                    _send_equip(slot_name, item.name)
                    count = count + 1
                end
            end
            ui.set_status('Applied custom set (' .. count .. ' slots).')
            windower.add_to_chat(207, 'GSUI: equipped ' .. count .. ' slot(s) from custom set.')
        else
            custom_set_active = false
            set_gen.clear()
            local eq = scanner.scan_equipment()
            ui.update_equipment(eq)
            set_gen.populate_from_equipment(eq)
            update_stats(eq)
            ui.set_status('Reset to equipped gear.')
            windower.add_to_chat(207, 'GSUI: Reset to currently equipped gear.')
        end
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
            if not ui.get_kb_mode() then
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
                -- Dropped on a bag in organizer
                local dest = drop.bag_name
                local item = drop.item
                if not bag_org.is_bag_currently_accessible(dest)
                   or not bag_org.is_bag_currently_accessible(item.bag_name) then
                    local blocked = not bag_org.is_bag_currently_accessible(dest) and dest or item.bag_name
                    ui.set_status('Bag not accessible: ' .. blocked)
                    windower.add_to_chat(207, 'GSUI: ' .. blocked .. ' is not accessible from your current location. Stand in your Mog House or at a Nomad/Porter Moogle that has unlocked it.')
                elseif ui.get_org_view() == 'scattered' and _org_all_bag_items then
                    -- Consolidate: move all copies from every bag into destination
                    local move_count = 0
                    for bag_name, items in pairs(_org_all_bag_items) do
                        if bag_name ~= dest and bag_org.is_bag_currently_accessible(bag_name) then
                            for _, bag_item in ipairs(items) do
                                if bag_item.id == item.id then
                                    bag_org.queue_move(bag_name, bag_item.bag_index, dest, bag_item.count)
                                    move_count = move_count + 1
                                end
                            end
                        end
                    end
                    if move_count > 0 then
                        ui.set_status('Consolidating ' .. item.name .. ' -> ' .. dest)
                        windower.add_to_chat(207, 'GSUI: Consolidating ' .. item.name .. ' to ' .. dest .. ' (' .. move_count .. ' moves)')
                    else
                        ui.set_status('Nothing to move')
                    end
                    coroutine.schedule(function()
                        if initialized then refresh_organizer() end
                    end, 1 + move_count * 0.5)
                elseif item.bag_name == dest then
                    ui.set_status('Already in ' .. dest)
                else
                    bag_org.queue_move(item.bag_name, item.bag_index, dest, item.count)
                    ui.set_status(item.name .. ' -> ' .. dest)
                    windower.add_to_chat(207, 'GSUI: Moving ' .. item.name .. ' to ' .. dest)
                    coroutine.schedule(function()
                        if initialized then refresh_organizer() end
                    end, 1)
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

-- B key toggle for the GSUI main window. (Was temporarily N during the
-- GSUI2 development fork so the two addons could coexist; now that v2 is
-- GSUI it reclaims the original B hotkey.) GearTree-style sets editing
-- lives inside the main GearSwap tab — no separate window / hotkey.
local DIK_B = 48
windower.register_event('keyboard', function(dik, pressed, flags, blocked)
    if blocked then return false end
    if not pressed then return false end
    local info = windower.ffxi.get_info()
    if not info or info.chat_open then return false end
    if dik == DIK_B then
        windower.send_command('gsui')
        return true
    end
    return false
end)

windower.register_event('login', function()
    coroutine.schedule(initialize, 5)
end)

windower.register_event('logout', function()
    deactivate_kb_binds()
    deactivate_fn_binds()
    if initialized then
        save_position()
        ui.destroy()
        initialized = false
    end
end)

windower.register_event('unload', function()
    deactivate_kb_binds()
    deactivate_fn_binds()
    if initialized then
        save_position()
        ui.destroy()
        icon_handler.cleanup()
    end
end)

-- Packet handling for real-time updates
windower.register_event('incoming chunk', function(id, original, modified, injected, blocked)
    if not initialized then return end

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
        coroutine.schedule(function()
            if initialized then
                -- Zone-based mog house detection as reliable fallback
                local info = windower.ffxi.get_info()
                if info then
                    local zone = res.zones[info.zone]
                    if zone and zone.name and zone.name:find('Residential') then
                        bag_org.set_mog_house(true)
                        ui.set_mog_house(true)
                    end
                end
                ui.build()
                refresh_data()
                if ui.get_mode() == 'organizer' then
                    refresh_organizer()
                end
                if settings.visible == false then
                    ui.hide()
                end
            end
        end, 3)
    elseif id == 0x00B then -- Zoning
        bag_org.set_mog_house(false)
        ui.set_mog_house(false)
        ui.hide()
        sync_kb_binds()
    end
end)

windower.register_event('outgoing chunk', function(id, original, modified, injected, blocked)
    if not initialized then return end
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
    if not initialized then return end
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
                -- Move every selected item into this bag
                local dest = hit.bag_name
                local selected = ui.get_selected_items()
                if #selected == 0 then
                    ui.set_status('No items selected. Right-click items first.')
                elseif not bag_org.is_bag_currently_accessible(dest) then
                    ui.set_status('Bag not accessible: ' .. dest)
                    windower.add_to_chat(207, 'GSUI: ' .. dest .. ' is not accessible from your current location. Stand in your Mog House or at a Nomad/Porter Moogle that has unlocked it.')
                else
                    local queued, skipped = 0, 0
                    for _, item in ipairs(selected) do
                        if item.bag_name == dest then
                            skipped = skipped + 1
                        elseif not bag_org.is_bag_currently_accessible(item.bag_name) then
                            skipped = skipped + 1
                        else
                            bag_org.queue_move(item.bag_name, item.bag_index, dest, item.count)
                            queued = queued + 1
                        end
                    end
                    ui.clear_selection()
                    ui.set_status('Moving ' .. queued .. ' item(s) -> ' .. dest .. (skipped > 0 and ' (' .. skipped .. ' skipped)' or ''))
                    windower.add_to_chat(207, 'GSUI: Moving ' .. queued .. ' items to ' .. dest .. (skipped > 0 and ' (' .. skipped .. ' skipped)' or ''))
                    coroutine.schedule(function()
                        if initialized then refresh_organizer() end
                    end, 1 + queued * 0.5)
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

windower.register_event('prerender', function()
    if not initialized then return end
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

    -- Hide while chat / macro editor is open; restore on close.
    local info = windower.ffxi.get_info()
    local input_open = info and info.chat_open == true
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
    if not initialized then return end
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
                _send_equip(slot_name, item.name)
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
