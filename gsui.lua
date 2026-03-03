_addon.name = 'GSUI'
_addon.version = '1.2.0'
_addon.author = 'GSUI'
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
    local summary = stat_parser.format_summary(totals)
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

local function update_stats(eq)
    local totals = stat_parser.calc_totals(eq)
    local summary = stat_parser.format_summary(totals)
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
        windower.add_to_chat(207, 'GSUI: ' .. action.item.name .. ' assigned to ' .. action.slot)
    elseif action.type == 'bag' then
        local dest = action.bag_name
        local item = action.item
        if not bag_org.is_in_mog_house() and (bag_org.is_mog_bag(dest) or bag_org.is_mog_bag(item.bag_name)) then
            ui.set_status('Must be in Mog House')
            windower.add_to_chat(207, 'GSUI: Unable to move items to/from Mog House storage unless in your Mog House.')
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

    if hit.type == 'kb_mode_toggle' then
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
        if set_gen.has_items() then
            set_gen.generate_to_clipboard()
            ui.set_status('Copied to clipboard!')
            windower.add_to_chat(207, 'GSUI: Copied to clipboard.')
        else
            ui.set_status('No items selected.')
        end
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
        custom_set_active = false
        set_gen.clear()
        local eq = scanner.scan_equipment()
        ui.update_equipment(eq)
        set_gen.populate_from_equipment(eq)
        update_stats(eq)
        ui.set_status('Reset to equipped gear.')
        windower.add_to_chat(207, 'GSUI: Reset to currently equipped gear.')
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
        if hit.item then
            ui.update_tooltip(hit.item)
        elseif hit.slot then
            -- Left-click on empty equip slot: toggle slot filter
            if ui.get_slot_filter() == hit.slot then
                ui.clear_slot_filter()
                ui.set_inv_label('All Storage')
            else
                ui.set_slot_filter(hit.slot)
            end
            apply_filter()
        end
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
                if not bag_org.is_in_mog_house() and (bag_org.is_mog_bag(dest) or bag_org.is_mog_bag(item.bag_name)) then
                    ui.set_status('Must be in Mog House')
                    windower.add_to_chat(207, 'GSUI: Unable to move items to/from Mog House storage unless in your Mog House.')
                elseif ui.get_org_view() == 'scattered' and _org_all_bag_items then
                    -- Consolidate: move all copies from every bag into destination
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

-- B key toggle
local DIK_B = 48
windower.register_event('keyboard', function(dik, pressed, flags, blocked)
    if blocked then return false end
    if dik == DIK_B and pressed then
        local info = windower.ffxi.get_info()
        if info and not info.chat_open then
            windower.send_command('gsui')
            return true
        end
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
        pending_refresh = true
        refresh_timer = os.clock()
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

    -- Right click down: remove piece from equip slot
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

-- Periodic refresh for pending changes + move queue
windower.register_event('prerender', function()
    if not initialized then return end
    if pending_refresh and (os.clock() - refresh_timer) > 0.3 then
        pending_refresh = false
        refresh_data()
    end
    if bag_org.is_moving() then
        bag_org.process_queue()
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
        end
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
    elseif cmd == 'help' then
        windower.add_to_chat(207, 'GSUI Commands:')
        windower.add_to_chat(207, '  /gsui - Toggle window')
        windower.add_to_chat(207, '  /gsui show|hide - Show/hide window')
        windower.add_to_chat(207, '  /gsui refresh - Rescan inventory')
        windower.add_to_chat(207, '  /gsui pos <x> <y> - Set window position')
        windower.add_to_chat(207, '  /gsui gen - Generate set to clipboard')
        windower.add_to_chat(207, '  /gsui clear - Reset to currently equipped')
        windower.add_to_chat(207, '  /gsui save <name> - Save current set')
        windower.add_to_chat(207, '  /gsui load <name> - Load a saved set')
        windower.add_to_chat(207, '  /gsui delete <name> - Delete a saved set')
        windower.add_to_chat(207, '  /gsui sets - List saved sets')
        windower.add_to_chat(207, '  /gsui org - Toggle organizer mode')
        windower.add_to_chat(207, '  /gsui kb - Toggle keyboard/drag mode')
        windower.add_to_chat(207, '  /gsui gamepath <path> - Set FFXI install path')
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
