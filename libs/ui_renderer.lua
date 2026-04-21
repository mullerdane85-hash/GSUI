local images = require('images')
local texts = require('texts')
local icon_handler = require('libs/icon_handler')

local ui = {}

local ICON_SIZE = 40
local SLOT_PAD = 3
local CELL = ICON_SIZE + SLOT_PAD
local PANEL_GAP = 12
local TITLE_BAR_H = 30
local BORDER = 3
local SCROLL_BTN_H = 22
local INV_COLS = 8
local INV_VISIBLE_ROWS = 8
local TOOLTIP_W = 320
local STAT_W = 240
local TOOLTIP_PAD = 10
local BTN_H = 28
local BTN_W = 150
local LABEL_H = 18
local FILTER_BAR_H = 24
local MENU_ITEM_H = 22
local MENU_VISIBLE = 15

-- Equipment slot layout: col, row in left panel
local equip_layout = {
    main       = { col = 0, row = 0, label = 'Main' },
    sub        = { col = 1, row = 0, label = 'Sub' },
    range      = { col = 2, row = 0, label = 'Rng' },
    ammo       = { col = 3, row = 0, label = 'Ammo' },
    head       = { col = 0, row = 1, label = 'Head' },
    neck       = { col = 1, row = 1, label = 'Neck' },
    left_ear   = { col = 2, row = 1, label = 'LEar' },
    right_ear  = { col = 3, row = 1, label = 'REar' },
    body       = { col = 0, row = 2, label = 'Body' },
    hands      = { col = 1, row = 2, label = 'Hand' },
    left_ring  = { col = 2, row = 2, label = 'LRng' },
    right_ring = { col = 3, row = 2, label = 'RRng' },
    back       = { col = 0, row = 3, label = 'Back' },
    waist      = { col = 1, row = 3, label = 'Wst' },
    legs       = { col = 2, row = 3, label = 'Legs' },
    feet       = { col = 3, row = 3, label = 'Feet' },
}

-- Build col/row -> slot_name lookup for keyboard navigation
local equip_nav_grid = {}
for slot_name, layout in pairs(equip_layout) do
    if not equip_nav_grid[layout.row] then
        equip_nav_grid[layout.row] = {}
    end
    equip_nav_grid[layout.row][layout.col] = slot_name
end

local ORG_BAG_LIST = {
    {key='all', label='All Bags'},
    {key='inventory', label='Inventory'},
    {key='wardrobe', label='Wardrobe'},
    {key='wardrobe2', label='Wardrobe 2'},
    {key='wardrobe3', label='Wardrobe 3'},
    {key='wardrobe4', label='Wardrobe 4'},
    {key='wardrobe5', label='Wardrobe 5'},
    {key='wardrobe6', label='Wardrobe 6'},
    {key='wardrobe7', label='Wardrobe 7'},
    {key='wardrobe8', label='Wardrobe 8'},
    {key='satchel', label='Satchel'},
    {key='sack', label='Sack'},
    {key='case', label='Case'},
    {key='_divider', label='-- Mog House --'},
    {key='safe', label='Mog Safe', mog=true},
    {key='safe2', label='Mog Safe 2', mog=true},
    {key='storage', label='Storage', mog=true},
    {key='locker', label='Locker', mog=true},
}
local ORG_ENTRY_H = 32
local ORG_VISIBLE = 8

-- State
local elements = {
    border_top = nil, border_bottom = nil, border_left = nil, border_right = nil,
    title_bar = nil, title_text = nil,
    bg = nil,
    equip_bg = nil, equip_icons = {}, equip_labels = {},
    inv_label = nil,
    inv_bg = nil, inv_icons = {},
    scroll_up = nil, scroll_down = nil,
    filter_dropdown = nil, filter_menu = nil, filter_menu_items = {},
    tooltip_bg = nil, tooltip_text = nil,
    generate_btn_bg = nil, generate_btn_text = nil,
    remove_all_btn_bg = nil, remove_all_btn_text = nil,
    reequip_btn_bg = nil, reequip_btn_text = nil,
    save_btn_bg = nil, save_btn_text = nil,
    load_btn_bg = nil, load_btn_text = nil,
    status_text = nil,
    drag_icon = nil,
    -- Stat panel
    stat_bg = nil, stat_label = nil, stat_text = nil,
    -- Tabs
    tab_gs_bg = nil, tab_gs_text = nil,
    tab_org_bg = nil, tab_org_text = nil,
    org_header = nil, org_divider = nil, org_bag_entries = {},
    org_conflict_btn_bg = nil, org_conflict_btn_text = nil,
    org_scattered_btn_bg = nil, org_scattered_btn_text = nil,
    org_scroll_up = nil, org_scroll_down = nil,
    sort_toggle_bg = nil, sort_toggle_text = nil,
    -- Keyboard navigation
    kb_cursor = nil, kb_selection = nil, kb_mode_text = nil,
}

local state = {
    visible = true,
    pos_x = 200,
    pos_y = 200,
    win_dragging = false,
    drag_offset_x = 0,
    drag_offset_y = 0,
    item_dragging = false,
    dragged_item = nil,
    scroll_offset = 0,
    hovered_item = nil,
    inv_items = {},
    equipment = {},
    mouse_x = 0,
    mouse_y = 0,
    on_close = nil,
    -- Filter state
    active_filter = 1,
    dropdown_open = false,
    on_filter = nil,
    filter_presets = {{ name = 'All', pattern = nil }},
    filter_y = 0,
    menu_x = 0,
    menu_w = 0,
    menu_scroll = 0,
    -- Organizer
    mode = 'gearswap',
    org_view = 'bags',
    org_selected_bag = 'inventory',
    org_conflicts = {},
    org_scattered = {},
    in_mog_house = false,
    -- Multi-select (organizer mode): keyed by "<bag_name>:<bag_index>" for uniqueness.
    selected_set = {},
    tab_gs_rect = {},
    tab_org_rect = {},
    org_conflict_btn_rect = {},
    org_scattered_btn_rect = {},
    org_bag_scroll = 0,
    sort_mode = 'gear_first',
    sort_toggle_rect = {},
    -- Tooltip/stat scroll state
    tooltip_lines = {},
    tooltip_scroll = 0,
    tooltip_max_lines = 10,
    tooltip_rect = {},
    stat_lines = {},
    stat_scroll = 0,
    stat_max_lines = 10,
    stat_rect = {},
    -- Keyboard navigation
    kb_mode = false,
    kb_focus = 'inv',
    kb_inv_index = 1,
    kb_equip_col = 0,
    kb_equip_row = 0,
    kb_bag_index = 1,
    kb_selected_item = nil,
    kb_selected_inv_index = nil,
    kb_mode_rect = {},
    kb_filter_index = 1,
    -- Slot filter
    slot_filter = nil,
    -- Save/load
    save_btn_rect = {},
    saved_sets = {},
    saved_dropdown_open = false,
}

-- Dimensions
local left_panel_w = CELL * 4
local left_panel_h = CELL * 4
local right_panel_w = CELL * INV_COLS
local inv_grid_h = CELL * INV_VISIBLE_ROWS
local content_w = 0
local content_h = 0
local total_w = 0
local total_h = 0

local function calc_dimensions()
    left_panel_w = CELL * 4
    left_panel_h = CELL * 4 + LABEL_H
    right_panel_w = CELL * INV_COLS
    inv_grid_h = CELL * INV_VISIBLE_ROWS
    local right_h = LABEL_H + inv_grid_h + SCROLL_BTN_H + 2 + FILTER_BAR_H
    content_w = left_panel_w + PANEL_GAP + right_panel_w + PANEL_GAP + TOOLTIP_W + PANEL_GAP + STAT_W
    content_h = math.max(left_panel_h + (BTN_H + SLOT_PAD) * 4, right_h)
    total_w = BORDER + SLOT_PAD + content_w + SLOT_PAD + BORDER
    total_h = BORDER + TITLE_BAR_H + SLOT_PAD + content_h + SLOT_PAD + BORDER
end

local function make_bg(x, y, w, h, alpha, r, g, b)
    return images.new({
        color = { alpha = alpha or 180, red = r or 15, green = g or 15, blue = b or 35 },
        pos = { x = x, y = y },
        size = { width = w, height = h },
        draggable = false,
    })
end

local function make_text(content, x, y, size, r, g, b, bold)
    local t = texts.new({
        text = { size = size or 10, font = 'Consolas',
            alpha = 255, red = r or 255, green = g or 255, blue = b or 255,
            stroke = { width = 1, alpha = 180, red = 0, green = 0, blue = 0 },
        },
        bg = { alpha = 0 },
        pos = { x = x, y = y },
        flags = { draggable = false, bold = bold or false },
    })
    t:text(content)
    return t
end

local function show_element(el)
    if el and el.show then el:show() end
end

local function hide_element(el)
    if el and el.hide then el:hide() end
end

function ui.init(settings)
    calc_dimensions()
    state.pos_x = settings.pos_x or 200
    state.pos_y = settings.pos_y or 200
    state.on_close = settings.on_close
    icon_handler.init(settings.game_path)
end

function ui.set_on_close(callback)
    state.on_close = callback
end

function ui.set_on_filter(callback)
    state.on_filter = callback
end

function ui.build()
    ui.destroy()
    calc_dimensions()

    local x = state.pos_x
    local y = state.pos_y

    -- === WINDOW FRAME ===
    local bc = { a = 220, r = 70, g = 130, b = 200 }
    elements.border_top = make_bg(x, y, total_w, BORDER, bc.a, bc.r, bc.g, bc.b)
    elements.border_top:show()
    elements.border_bottom = make_bg(x, y + total_h - BORDER, total_w, BORDER, bc.a, bc.r, bc.g, bc.b)
    elements.border_bottom:show()
    elements.border_left = make_bg(x, y, BORDER, total_h, bc.a, bc.r, bc.g, bc.b)
    elements.border_left:show()
    elements.border_right = make_bg(x + total_w - BORDER, y, BORDER, total_h, bc.a, bc.r, bc.g, bc.b)
    elements.border_right:show()

    -- Title bar
    local tb_x = x + BORDER
    local tb_y = y + BORDER
    local tb_w = total_w - BORDER * 2
    elements.title_bar = make_bg(tb_x, tb_y, tb_w, TITLE_BAR_H, 240, 30, 60, 120)
    elements.title_bar:show()
    elements.title_text = make_text('GSUI', tb_x + 8, tb_y + 7, 11, 200, 200, 230, true)
    elements.title_text:show()

    -- Tab buttons (leave 65px for mode toggle on right)
    local tab_x = tb_x + 55
    local tab_y = tb_y + 3
    local tab_avail = tb_w - 55 - 65  -- GSUI label left, mode toggle right
    local tab_w = math.floor((tab_avail - 4) / 2)  -- 4px gap between tabs
    local tab_h = TITLE_BAR_H - 6

    state.tab_gs_rect = { x = tab_x, y = tab_y, w = tab_w, h = tab_h }
    elements.tab_gs_bg = make_bg(tab_x, tab_y, tab_w, tab_h, 240, 50, 100, 180)
    elements.tab_gs_bg:show()
    elements.tab_gs_text = make_text('GearSwap [F1]', tab_x + math.floor(tab_w / 2) - 42, tab_y + 4, 11, 255, 255, 255, true)
    elements.tab_gs_text:show()

    local tab2_x = tab_x + tab_w + 4
    state.tab_org_rect = { x = tab2_x, y = tab_y, w = tab_w, h = tab_h }
    elements.tab_org_bg = make_bg(tab2_x, tab_y, tab_w, tab_h, 180, 30, 40, 70)
    elements.tab_org_bg:show()
    elements.tab_org_text = make_text('Organizer [F2]', tab2_x + math.floor(tab_w / 2) - 46, tab_y + 4, 11, 160, 160, 200, true)
    elements.tab_org_text:show()

    -- Apply tab highlight for current mode
    if state.mode == 'organizer' then
        elements.tab_gs_bg:color(30, 40, 70)
        elements.tab_gs_bg:alpha(180)
        elements.tab_gs_text:color(160, 160, 200)
        elements.tab_org_bg:color(50, 100, 180)
        elements.tab_org_bg:alpha(240)
        elements.tab_org_text:color(255, 255, 255)
    end

    -- === CONTENT AREA ===
    local cx = x + BORDER + SLOT_PAD
    local cy = y + BORDER + TITLE_BAR_H + SLOT_PAD
    elements.bg = make_bg(cx, cy, content_w, content_h, 210, 12, 12, 32)
    elements.bg:show()

    -- === LEFT PANEL: Equipment ===
    local eq_x = cx
    local eq_y = cy

    local eq_label = make_text('Equipment', eq_x + 2, eq_y, 9, 180, 180, 220, true)
    eq_label:show()
    elements.equip_labels['_header'] = eq_label

    local eq_grid_y = eq_y + LABEL_H
    elements.equip_bg = make_bg(eq_x, eq_grid_y, left_panel_w, CELL * 4, 130, 20, 20, 50)
    elements.equip_bg:show()

    for slot_name, layout in pairs(equip_layout) do
        local ix = eq_x + layout.col * CELL
        local iy = eq_grid_y + layout.row * CELL
        local img = icon_handler.create_image({
            color = { alpha = 0, red = 255, green = 255, blue = 255 },
            size = { width = ICON_SIZE, height = ICON_SIZE },
            pos = { x = ix, y = iy },
        })
        elements.equip_icons[slot_name] = { image = img, x = ix, y = iy, item = nil, slot_name = slot_name, visible = false }

        local lbl = make_text(layout.label, ix + 1, iy + ICON_SIZE - 12, 7, 160, 160, 200)
        lbl:show()
        elements.equip_labels[slot_name] = lbl
    end

    -- Generate button
    local btn_x = eq_x
    local btn_y = eq_y + left_panel_h + SLOT_PAD
    elements.generate_btn_bg = make_bg(btn_x, btn_y, BTN_W, BTN_H, 220, 35, 110, 35)
    elements.generate_btn_bg:show()
    elements.generate_btn_text = make_text('Generate Set', btn_x + 14, btn_y + 5, 11, 255, 255, 255, true)
    elements.generate_btn_text:show()

    -- Status text
    elements.status_text = make_text('', btn_x + BTN_W + 8, btn_y + 5, 10, 180, 255, 180)
    elements.status_text:show()

    -- Remove All / Re-equip buttons (stacked below Generate)
    local btn2_y = btn_y + BTN_H + SLOT_PAD
    elements.remove_all_btn_bg = make_bg(btn_x, btn2_y, BTN_W, BTN_H, 220, 130, 35, 35)
    elements.remove_all_btn_bg:show()
    elements.remove_all_btn_text = make_text('Remove All', btn_x + 30, btn2_y + 5, 11, 255, 255, 255, true)
    elements.remove_all_btn_text:show()

    local btn3_y = btn2_y + BTN_H + SLOT_PAD
    elements.reequip_btn_bg = make_bg(btn_x, btn3_y, BTN_W, BTN_H, 220, 35, 80, 130)
    elements.reequip_btn_bg:show()
    elements.reequip_btn_text = make_text('Re-equip', btn_x + 36, btn3_y + 5, 11, 255, 255, 255, true)
    elements.reequip_btn_text:show()

    -- Save / Load buttons
    local half_btn = math.floor((BTN_W - SLOT_PAD) / 2)
    local btn4_y = btn3_y + BTN_H + SLOT_PAD
    elements.save_btn_bg = make_bg(btn_x, btn4_y, half_btn, BTN_H, 220, 100, 80, 35)
    elements.save_btn_bg:show()
    elements.save_btn_text = make_text('Save', btn_x + math.floor(half_btn / 2) - 14, btn4_y + 5, 11, 255, 255, 255, true)
    elements.save_btn_text:show()

    local load_x = btn_x + half_btn + SLOT_PAD
    elements.load_btn_bg = make_bg(load_x, btn4_y, half_btn, BTN_H, 220, 35, 80, 100)
    elements.load_btn_bg:show()
    elements.load_btn_text = make_text('Load', load_x + math.floor(half_btn / 2) - 14, btn4_y + 5, 11, 255, 255, 255, true)
    elements.load_btn_text:show()

    state.save_btn_rect = { x = btn_x, y = btn4_y, w = half_btn, h = BTN_H }
    state.load_btn_rect = { x = load_x, y = btn4_y, w = half_btn, h = BTN_H }

    -- === ORGANIZER LEFT PANEL (hidden by default) ===
    local org_x = eq_x
    local org_y = eq_y
    local org_w = left_panel_w + PANEL_GAP

    elements.org_header = make_text('Bags', org_x + 2, org_y, 10, 180, 180, 220, true)

    -- Scroll up button
    local org_list_y = org_y + LABEL_H
    elements.org_scroll_up = {
        bg = make_bg(org_x, org_list_y, org_w, SCROLL_BTN_H, 160, 35, 35, 75),
        text = make_text('^ Scroll Up ^', org_x + 20, org_list_y + 3, 9, 200, 200, 230),
        x = org_x, y = org_list_y, w = org_w, h = SCROLL_BTN_H,
    }

    -- Bag entry visual slots
    local org_entry_start = org_list_y + SCROLL_BTN_H + 2
    elements.org_bag_entries = {}
    for i = 1, ORG_VISIBLE do
        local iy = org_entry_start + (i - 1) * ORG_ENTRY_H
        local entry = {
            bg = make_bg(org_x, iy, org_w, ORG_ENTRY_H - 2, 200, 25, 25, 60),
            text = make_text('', org_x + 8, iy + 7, 10, 200, 200, 230),
            count_text = make_text('', org_x + org_w - 55, iy + 7, 10, 150, 150, 180),
            bag_name = '',
            mog = false,
            x = org_x, y = iy, w = org_w, h = ORG_ENTRY_H,
            active = true,
            list_index = 0,
        }
        elements.org_bag_entries[i] = entry
    end

    -- Scroll down button
    local org_scroll_down_y = org_entry_start + ORG_VISIBLE * ORG_ENTRY_H + 2
    elements.org_scroll_down = {
        bg = make_bg(org_x, org_scroll_down_y, org_w, SCROLL_BTN_H, 160, 35, 35, 75),
        text = make_text('v Scroll Down v', org_x + 16, org_scroll_down_y + 3, 9, 200, 200, 230),
        x = org_x, y = org_scroll_down_y, w = org_w, h = SCROLL_BTN_H,
    }

    -- Conflict + Scattered buttons below scroll
    local org_btn_y = org_scroll_down_y + SCROLL_BTN_H + SLOT_PAD
    state.org_conflict_btn_rect = { x = org_x, y = org_btn_y, w = org_w, h = BTN_H }
    elements.org_conflict_btn_bg = make_bg(org_x, org_btn_y, org_w, BTN_H, 220, 130, 100, 35)
    elements.org_conflict_btn_text = make_text('Conflicts (0)', org_x + 20, org_btn_y + 5, 11, 255, 255, 255, true)

    org_btn_y = org_btn_y + BTN_H + SLOT_PAD
    state.org_scattered_btn_rect = { x = org_x, y = org_btn_y, w = org_w, h = BTN_H }
    elements.org_scattered_btn_bg = make_bg(org_x, org_btn_y, org_w, BTN_H, 220, 35, 100, 130)
    elements.org_scattered_btn_text = make_text('Scattered (0)', org_x + 20, org_btn_y + 5, 11, 255, 255, 255, true)

    -- === RIGHT PANEL: Unified Inventory ===
    local inv_x = eq_x + left_panel_w + PANEL_GAP
    local inv_y = cy

    elements.inv_label = make_text('All Storage', inv_x + 2, inv_y, 9, 180, 180, 220, true)
    elements.inv_label:show()

    -- Sort toggle button (organizer mode only)
    local sort_btn_w = 90
    local sort_btn_x = inv_x + right_panel_w - sort_btn_w
    state.sort_toggle_rect = { x = sort_btn_x, y = inv_y, w = sort_btn_w, h = LABEL_H }
    local sort_label = state.sort_mode == 'gear_first' and 'Gear First' or 'Items First'
    elements.sort_toggle_bg = make_bg(sort_btn_x, inv_y, sort_btn_w, LABEL_H, 200, 40, 70, 120)
    elements.sort_toggle_text = make_text(sort_label, sort_btn_x + 6, inv_y + 1, 9, 220, 220, 255, true)

    local grid_y = inv_y + LABEL_H
    elements.inv_bg = make_bg(inv_x, grid_y, right_panel_w, inv_grid_h, 130, 20, 20, 50)
    elements.inv_bg:show()

    -- Inv grid icons
    elements.inv_icons = {}
    for row = 0, INV_VISIBLE_ROWS - 1 do
        for col = 0, INV_COLS - 1 do
            local ix = inv_x + col * CELL
            local iy = grid_y + row * CELL
            local idx = row * INV_COLS + col + 1
            local img = icon_handler.create_image({
                color = { alpha = 0, red = 255, green = 255, blue = 255 },
                size = { width = ICON_SIZE, height = ICON_SIZE },
                pos = { x = ix, y = iy },
            })
            elements.inv_icons[idx] = { image = img, x = ix, y = iy, item = nil, visible = false }
        end
    end

    -- Scroll buttons
    local scroll_y = grid_y + inv_grid_h
    local half_w = math.floor(right_panel_w / 2)
    elements.scroll_up = {
        bg = make_bg(inv_x, scroll_y, half_w - 1, SCROLL_BTN_H, 160, 35, 35, 75),
        text = make_text('', inv_x + 6, scroll_y + 2, 10),
        x = inv_x, y = scroll_y, w = half_w - 1, h = SCROLL_BTN_H,
    }
    elements.scroll_up.bg:show()
    elements.scroll_up.text:show()

    elements.scroll_down = {
        bg = make_bg(inv_x + half_w, scroll_y, half_w, SCROLL_BTN_H, 160, 35, 35, 75),
        text = make_text('', inv_x + half_w + 6, scroll_y + 2, 10),
        x = inv_x + half_w, y = scroll_y, w = half_w, h = SCROLL_BTN_H,
    }
    elements.scroll_down.bg:show()
    elements.scroll_down.text:show()

    -- === FILTER DROPDOWN ===
    local filter_y = scroll_y + SCROLL_BTN_H + 2
    elements.filter_dropdown = {
        bg = make_bg(inv_x, filter_y, right_panel_w, FILTER_BAR_H, 200, 30, 60, 120),
        text = make_text('[F4] Filter: All', inv_x + 8, filter_y + 4, 10, 220, 220, 255, true),
        arrow = make_text('v', inv_x + right_panel_w - 18, filter_y + 4, 10, 200, 200, 240, true),
        x = inv_x, y = filter_y, w = right_panel_w, h = FILTER_BAR_H,
    }
    elements.filter_dropdown.bg:show()
    elements.filter_dropdown.text:show()
    elements.filter_dropdown.arrow:show()
    local active_preset = state.filter_presets[state.active_filter]
    if active_preset then
        elements.filter_dropdown.text:text('[F4] Filter: ' .. active_preset.name)
    end

    -- === TOOLTIP PANEL (full height) ===
    local LINE_H = 16
    local STAT_LINE_H = 15
    local tt_x = inv_x + right_panel_w + PANEL_GAP
    local tt_y = cy
    local tt_h = content_h
    elements.tooltip_bg = make_bg(tt_x, tt_y, TOOLTIP_W, tt_h, 230, 8, 8, 28)
    elements.tooltip_bg:show()
    elements.tooltip_text = make_text('Hover over an item\nto see details.\n\nDrag items from inventory\nand drop onto equipment\nslots to build a set.', tt_x + TOOLTIP_PAD, tt_y + TOOLTIP_PAD, 10, 220, 220, 240)
    elements.tooltip_text:show()

    state.tooltip_rect = { x = tt_x, y = tt_y, w = TOOLTIP_W, h = tt_h }
    state.tooltip_max_lines = math.floor((tt_h - TOOLTIP_PAD * 2) / LINE_H)
    state.tooltip_scroll = 0
    state.tooltip_lines = {}

    -- === STAT SUMMARY PANEL (new column, right of tooltip) ===
    local st_x = tt_x + TOOLTIP_W + PANEL_GAP
    local st_y = cy
    local st_h = content_h
    elements.stat_bg = make_bg(st_x, st_y, STAT_W, st_h, 230, 8, 18, 28)
    elements.stat_bg:show()
    elements.stat_label = make_text('Gear Stats', st_x + TOOLTIP_PAD, st_y + 4, 10, 100, 200, 255, true)
    elements.stat_label:show()
    elements.stat_text = make_text('Equip gear to see totals.', st_x + TOOLTIP_PAD, st_y + 20, 9, 200, 200, 220)
    elements.stat_text:show()

    state.stat_rect = { x = st_x, y = st_y, w = STAT_W, h = st_h }
    state.stat_max_lines = math.floor((st_h - 20 - TOOLTIP_PAD) / STAT_LINE_H)
    state.stat_scroll = 0
    state.stat_lines = {}

    -- Store layout coords for dynamic menu repositioning
    state.filter_y = filter_y
    state.menu_x = inv_x
    state.menu_w = right_panel_w

    -- === DROPDOWN MENU (pre-create visible slots, hidden by default) ===
    local vis = math.min(#state.filter_presets, MENU_VISIBLE)
    local menu_h = vis * MENU_ITEM_H
    local menu_y = filter_y - menu_h
    elements.filter_menu = {
        bg = make_bg(inv_x, menu_y, right_panel_w, menu_h, 245, 10, 10, 35),
        x = inv_x, y = menu_y, w = right_panel_w, h = menu_h,
    }
    elements.filter_menu_items = {}
    for i = 1, MENU_VISIBLE do
        local iy = menu_y + (i - 1) * MENU_ITEM_H
        local item = {
            bg = make_bg(inv_x + 1, iy, right_panel_w - 2, MENU_ITEM_H - 1, 240, 25, 25, 60),
            text = make_text('', inv_x + 10, iy + 2, 10, 200, 200, 230),
            x = inv_x, y = iy, w = right_panel_w, h = MENU_ITEM_H,
            preset_index = 0,
        }
        elements.filter_menu_items[i] = item
    end
    state.dropdown_open = false

    -- Drag cursor icon (hidden until dragging)
    elements.drag_icon = icon_handler.create_image({
        size = { width = ICON_SIZE, height = ICON_SIZE },
        color = { alpha = 200, red = 255, green = 255, blue = 255 },
    })

    -- Keyboard navigation highlights (created last so they render on top)
    elements.kb_cursor = make_bg(0, 0, ICON_SIZE, ICON_SIZE, 100, 255, 220, 50)
    elements.kb_selection = make_bg(0, 0, ICON_SIZE, ICON_SIZE, 80, 50, 255, 50)

    -- Mode toggle on title bar
    local mode_label = state.kb_mode and '[F3:KB]' or '[F3:Drag]'
    local mode_x = tb_x + tb_w - 55
    elements.kb_mode_text = make_text(mode_label, mode_x, tb_y + 7, 9, 180, 220, 255, true)
    elements.kb_mode_text:show()
    state.kb_mode_rect = { x = mode_x, y = tb_y, w = 50, h = TITLE_BAR_H }

    -- Hide gearswap elements if in organizer mode (build always shows them)
    if state.mode == 'organizer' then
        hide_element(elements.equip_bg)
        hide_element(elements.generate_btn_bg)
        hide_element(elements.generate_btn_text)
        hide_element(elements.remove_all_btn_bg)
        hide_element(elements.remove_all_btn_text)
        hide_element(elements.reequip_btn_bg)
        hide_element(elements.reequip_btn_text)
        hide_element(elements.save_btn_bg)
        hide_element(elements.save_btn_text)
        hide_element(elements.load_btn_bg)
        hide_element(elements.load_btn_text)
        hide_element(elements.status_text)
        for _, lbl in pairs(elements.equip_labels) do
            hide_element(lbl)
        end
        show_element(elements.sort_toggle_bg)
        show_element(elements.sort_toggle_text)
        ui.show_org_panel()
    end
end

-- === FILTER DROPDOWN ===

function ui.update_filter_presets(presets)
    state.filter_presets = presets
    state.active_filter = 1
    state.menu_scroll = 0

    -- Update dropdown button text
    if elements.filter_dropdown then
        elements.filter_dropdown.text:text('[F4] Filter: All')
    end

    -- Recalculate menu dimensions
    local count = #presets
    local vis = math.min(count, MENU_VISIBLE)
    local menu_h = vis * MENU_ITEM_H
    local menu_y = state.filter_y - menu_h

    -- Update menu background
    if elements.filter_menu then
        elements.filter_menu.bg:pos(state.menu_x, menu_y)
        elements.filter_menu.bg:size(state.menu_w, menu_h)
        elements.filter_menu.y = menu_y
        elements.filter_menu.h = menu_h
    end

    -- Update slot positions
    for i = 1, MENU_VISIBLE do
        local item = elements.filter_menu_items[i]
        if not item then break end
        local iy = menu_y + (i - 1) * MENU_ITEM_H
        item.bg:pos(state.menu_x + 1, iy)
        item.text:pos(state.menu_x + 10, iy + 2)
        item.y = iy
        if i <= count then
            item.text:text(presets[i].name)
            item.preset_index = i
        else
            item.preset_index = 0
            item.text:text('')
        end
    end

    -- Close dropdown if open
    if state.dropdown_open then
        ui.close_dropdown()
    end

    -- Fire filter callback to apply "All"
    if state.on_filter then
        state.on_filter()
    end
end

function ui.refresh_menu_items()
    local count = #state.filter_presets
    for i = 1, MENU_VISIBLE do
        local item = elements.filter_menu_items[i]
        if not item then break end
        local pi = state.menu_scroll + i
        if pi <= count then
            local preset = state.filter_presets[pi]
            item.text:text(preset.name)
            item.preset_index = pi
            show_element(item.bg)
            show_element(item.text)
            if pi == state.active_filter then
                item.bg:color(50, 100, 200)
                item.bg:alpha(240)
                item.text:color(255, 255, 255)
            else
                item.bg:color(25, 25, 60)
                item.bg:alpha(240)
                item.text:color(200, 200, 230)
            end
        else
            item.preset_index = 0
            hide_element(item.bg)
            hide_element(item.text)
        end
    end
end

function ui.menu_scroll_up()
    if state.menu_scroll > 0 then
        state.menu_scroll = state.menu_scroll - 1
        ui.refresh_menu_items()
    end
end

function ui.menu_scroll_down()
    local count = #state.filter_presets
    if state.menu_scroll + MENU_VISIBLE < count then
        state.menu_scroll = state.menu_scroll + 1
        ui.refresh_menu_items()
    end
end

function ui.open_dropdown()
    state.dropdown_open = true
    state.menu_scroll = 0
    if elements.filter_dropdown then
        elements.filter_dropdown.arrow:text('^')
    end
    show_element(elements.filter_menu.bg)
    ui.refresh_menu_items()
end

function ui.close_dropdown()
    state.dropdown_open = false
    if elements.filter_dropdown then
        elements.filter_dropdown.arrow:text('v')
    end
    hide_element(elements.filter_menu.bg)
    for _, item in ipairs(elements.filter_menu_items) do
        hide_element(item.bg)
        hide_element(item.text)
    end
end

function ui.toggle_dropdown()
    if state.dropdown_open then
        ui.close_dropdown()
    else
        ui.open_dropdown()
    end
end

function ui.highlight_filter_item(preset_index)
    for _, item in ipairs(elements.filter_menu_items) do
        if item.preset_index == preset_index then
            item.bg:color(80, 140, 240)
            item.bg:alpha(255)
            item.text:color(255, 255, 255)
        elseif item.preset_index == state.active_filter then
            item.bg:color(50, 100, 200)
            item.bg:alpha(240)
            item.text:color(255, 255, 255)
        elseif item.preset_index > 0 then
            item.bg:color(25, 25, 60)
            item.bg:alpha(240)
            item.text:color(200, 200, 230)
        end
    end
end

function ui.kb_open_filter()
    state.kb_filter_index = state.active_filter
    state.kb_focus = 'filter'
    ui.open_dropdown()
    ui.highlight_filter_item(state.kb_filter_index)
end

function ui.kb_close_filter()
    ui.close_dropdown()
    state.kb_focus = 'inv'
    ui.update_kb_cursor()
end

function ui.kb_get_filter_index()
    return state.kb_filter_index
end

function ui.is_dropdown_open()
    return state.dropdown_open
end

function ui.set_active_filter(preset_index)
    state.active_filter = preset_index
    local preset = state.filter_presets[preset_index]
    if preset and elements.filter_dropdown then
        elements.filter_dropdown.text:text('[F4] Filter: ' .. preset.name)
    end
    ui.close_dropdown()
    if state.on_filter then
        state.on_filter()
    end
end

function ui.get_active_filter()
    local preset = state.filter_presets[state.active_filter]
    if preset then return preset end
    return state.filter_presets[1] or { name = 'All', pattern = nil }
end

-- === SLOT FILTER ===

function ui.set_slot_filter(slot_name)
    state.slot_filter = slot_name
    -- Highlight the filtered slot with a colored border
    for sn, icon_data in pairs(elements.equip_icons) do
        local lbl = elements.equip_labels[sn]
        if sn == slot_name then
            if lbl then lbl:color(255, 200, 50) end
        else
            if lbl then lbl:color(160, 160, 200) end
        end
    end
end

function ui.clear_slot_filter()
    state.slot_filter = nil
    -- Reset all slot label colors
    for sn, _ in pairs(elements.equip_icons) do
        local lbl = elements.equip_labels[sn]
        if lbl then lbl:color(160, 160, 200) end
    end
end

function ui.get_slot_filter()
    return state.slot_filter
end

function ui.get_slot_display_name(slot_name)
    local scanner = require('libs/inventory_scanner')
    return scanner.get_slot_display_name(slot_name)
end

-- === KB HELPERS ===

function ui.get_kb_focus()
    return state.kb_focus
end

function ui.get_kb_equip_slot()
    if not equip_nav_grid[state.kb_equip_row] then return nil end
    return equip_nav_grid[state.kb_equip_row][state.kb_equip_col]
end

function ui.get_equip_icon_data(slot_name)
    if not slot_name then return nil end
    return elements.equip_icons[slot_name]
end

-- === DATA UPDATES ===

function ui.update_equipment(equipment_data)
    state.equipment = equipment_data
    for slot_name, icon_data in pairs(elements.equip_icons) do
        local eq = equipment_data[slot_name]
        if eq and eq.item then
            icon_data.item = eq.item
            icon_data.visible = true
            -- Load texture unconditionally. `state.visible` was previously guarding
            -- this, but `initialize()` runs before the window is ever made visible,
            -- so icons never bound their textures on first open. Visibility is
            -- handled by the image's own alpha/show, not by skipping the load.
            if state.mode == 'gearswap' then
                icon_handler.load_icon(icon_data.image, eq.item.id)
            end
        else
            icon_data.item = nil
            icon_data.visible = false
            icon_data.image:alpha(0)
            icon_data.image:hide()
        end
    end
end

function ui.update_inventory(all_items)
    state.inv_items = all_items or {}
    state.scroll_offset = 0
    ui.refresh_inv_grid()
end

-- Stable key for multi-select (bag + slot index uniquely identifies an item).
local function sel_key(item)
    if not item or not item.bag_name or not item.bag_index then return nil end
    return item.bag_name .. ':' .. item.bag_index
end

function ui.toggle_selection(item)
    local key = sel_key(item)
    if not key then return false end
    if state.selected_set[key] then
        state.selected_set[key] = nil
    else
        state.selected_set[key] = item
    end
    ui.refresh_inv_grid()
    return state.selected_set[key] ~= nil
end

function ui.is_selected(item)
    local key = sel_key(item)
    return key and state.selected_set[key] ~= nil or false
end

function ui.get_selected_items()
    local list = {}
    for _, item in pairs(state.selected_set) do
        list[#list + 1] = item
    end
    return list
end

function ui.selection_count()
    local n = 0
    for _ in pairs(state.selected_set) do n = n + 1 end
    return n
end

function ui.clear_selection()
    state.selected_set = {}
    ui.refresh_inv_grid()
end

function ui.refresh_inv_grid()
    local items = state.inv_items
    local start = state.scroll_offset * INV_COLS + 1
    local max_visible = INV_VISIBLE_ROWS * INV_COLS

    for idx = 1, max_visible do
        local icon_data = elements.inv_icons[idx]
        if not icon_data then break end
        local item_idx = start + idx - 1
        local item = items[item_idx]
        if item then
            icon_data.item = item
            icon_data.visible = true
            -- Always load. See note in update_equipment for why state.visible
            -- is no longer gating icon loads.
            icon_handler.load_icon(icon_data.image, item.id)
            -- Tint yellow if this item is in the multi-select set.
            if ui.is_selected(item) then
                pcall(function() icon_data.image:color(255, 220, 80) end)
            else
                pcall(function() icon_data.image:color(255, 255, 255) end)
            end
        else
            icon_data.item = nil
            icon_data.visible = false
            icon_data.image:alpha(0)
            icon_data.image:hide()
        end
    end

    -- Update keyboard navigation highlights
    if state.kb_mode then
        ui.update_kb_cursor()
        ui.update_kb_selection()
    end
end

function ui.scroll_up()
    if state.scroll_offset > 0 then
        state.scroll_offset = state.scroll_offset - 1
        ui.refresh_inv_grid()
    end
end

function ui.scroll_down()
    local total_rows = math.ceil(#state.inv_items / INV_COLS)
    if state.scroll_offset < total_rows - INV_VISIBLE_ROWS then
        state.scroll_offset = state.scroll_offset + 1
        ui.refresh_inv_grid()
    end
end

-- Split text into lines table
local function split_lines(text)
    local lines = {}
    if not text or text == '' then return lines end
    for line in (text .. '\n'):gmatch('([^\n]*)\n') do
        table.insert(lines, line)
    end
    return lines
end

-- Render visible portion of lines into a text element
local function render_scrolled(text_el, lines, scroll, max_lines)
    if not text_el then return end
    local visible = {}
    local total = #lines
    local show_indicator = total > max_lines
    -- Reserve one line for the scroll indicator if needed
    local display_lines = show_indicator and (max_lines - 1) or max_lines
    for i = scroll + 1, math.min(scroll + display_lines, total) do
        table.insert(visible, lines[i])
    end
    if show_indicator then
        local last = math.min(scroll + display_lines, total)
        table.insert(visible, '  [' .. (scroll + 1) .. '-' .. last .. ' / ' .. total .. '] Scroll for more')
    end
    text_el:text(table.concat(visible, '\n'))
end

function ui.update_tooltip(item_info)
    if not elements.tooltip_text then return end
    if item_info then
        local scanner = require('libs/inventory_scanner')
        local active_preset = state.filter_presets[state.active_filter]
        local highlight = active_preset and active_preset.pattern or nil
        local text = scanner.build_tooltip_text(item_info, highlight)
        state.tooltip_lines = split_lines(text)
        state.tooltip_scroll = 0
        render_scrolled(elements.tooltip_text, state.tooltip_lines, state.tooltip_scroll, state.tooltip_max_lines)
        state.hovered_item = item_info
    else
        state.tooltip_lines = split_lines('Hover over an item\nto see details.\n\nDrag items from inventory\nand drop onto equipment\nslots to build a set.')
        state.tooltip_scroll = 0
        render_scrolled(elements.tooltip_text, state.tooltip_lines, state.tooltip_scroll, state.tooltip_max_lines)
        state.hovered_item = nil
    end
end

function ui.tooltip_scroll_up()
    if state.tooltip_scroll > 0 then
        state.tooltip_scroll = state.tooltip_scroll - 1
        render_scrolled(elements.tooltip_text, state.tooltip_lines, state.tooltip_scroll, state.tooltip_max_lines)
    end
end

function ui.tooltip_scroll_down()
    local max_scroll = math.max(0, #state.tooltip_lines - state.tooltip_max_lines)
    if state.tooltip_scroll < max_scroll then
        state.tooltip_scroll = state.tooltip_scroll + 1
        render_scrolled(elements.tooltip_text, state.tooltip_lines, state.tooltip_scroll, state.tooltip_max_lines)
    end
end

local _status_token = 0
function ui.set_status(msg, duration)
    if not elements.status_text then return end
    elements.status_text:text(msg or '')
    -- Auto-clear after `duration` seconds (default 1.5s). Skip clearing empty messages.
    if msg and msg ~= '' then
        _status_token = _status_token + 1
        local my_token = _status_token
        coroutine.schedule(function()
            if my_token == _status_token and elements.status_text then
                elements.status_text:text('')
            end
        end, duration or 1.5)
    end
end

function ui.update_stat_text(summary_text)
    if not elements.stat_text then return end
    state.stat_lines = split_lines(summary_text or '')
    state.stat_scroll = 0
    render_scrolled(elements.stat_text, state.stat_lines, state.stat_scroll, state.stat_max_lines)
end

function ui.stat_scroll_up()
    if state.stat_scroll > 0 then
        state.stat_scroll = state.stat_scroll - 1
        render_scrolled(elements.stat_text, state.stat_lines, state.stat_scroll, state.stat_max_lines)
    end
end

function ui.stat_scroll_down()
    local max_scroll = math.max(0, #state.stat_lines - state.stat_max_lines)
    if state.stat_scroll < max_scroll then
        state.stat_scroll = state.stat_scroll + 1
        render_scrolled(elements.stat_text, state.stat_lines, state.stat_scroll, state.stat_max_lines)
    end
end

-- === DRAG AND DROP ===

function ui.start_item_drag(item)
    state.item_dragging = true
    state.dragged_item = item
    if elements.drag_icon and item then
        icon_handler.load_icon(elements.drag_icon, item.id)
        elements.drag_icon:pos(state.mouse_x - ICON_SIZE / 2, state.mouse_y - ICON_SIZE / 2)
        elements.drag_icon:show()
    end
end

function ui.move_item_drag(mx, my)
    state.mouse_x = mx
    state.mouse_y = my
    if state.item_dragging and elements.drag_icon then
        elements.drag_icon:pos(mx - ICON_SIZE / 2, my - ICON_SIZE / 2)
        elements.drag_icon:update()
    end
end

function ui.end_item_drag(mx, my)
    if not state.item_dragging then return nil end
    state.item_dragging = false
    if elements.drag_icon then
        elements.drag_icon:hide()
    end

    if state.mode == 'gearswap' then
        for slot_name, icon_data in pairs(elements.equip_icons) do
            if mx >= icon_data.x and mx <= icon_data.x + ICON_SIZE and my >= icon_data.y and my <= icon_data.y + ICON_SIZE then
                local item = state.dragged_item
                state.dragged_item = nil
                return { type = 'equip', slot = slot_name, item = item }
            end
        end
    elseif state.mode == 'organizer' then
        for _, entry in ipairs(elements.org_bag_entries) do
            if entry.active and mx >= entry.x and mx <= entry.x + entry.w and my >= entry.y and my <= entry.y + entry.h then
                local item = state.dragged_item
                state.dragged_item = nil
                return { type = 'bag', bag_name = entry.bag_name, item = item }
            end
        end
    end

    state.dragged_item = nil
    return nil
end

function ui.cancel_item_drag()
    state.item_dragging = false
    state.dragged_item = nil
    if elements.drag_icon then
        elements.drag_icon:hide()
    end
end

function ui.is_item_dragging()
    return state.item_dragging
end

function ui.get_dragged_item()
    return state.dragged_item
end

function ui.set_equip_slot_item(slot_name, item_info)
    local icon_data = elements.equip_icons[slot_name]
    if not icon_data then return end
    if item_info then
        icon_data.item = item_info
        icon_data.visible = true
        icon_handler.load_icon(icon_data.image, item_info.id)
    else
        icon_data.item = nil
        icon_data.visible = false
        icon_data.image:alpha(0)
        icon_data.image:hide()
    end
end

function ui.clear_all_equip_slots()
    for slot_name, icon_data in pairs(elements.equip_icons) do
        icon_data.item = nil
        icon_data.visible = false
        icon_data.image:alpha(0)
        icon_data.image:hide()
    end
end

-- === HIT TESTING ===

function ui.hit_test(mx, my)
    -- KB mode toggle (on title bar — check before tabs)
    local km = state.kb_mode_rect
    if km and km.x and mx >= km.x and mx <= km.x + km.w and my >= km.y and my <= km.y + km.h then
        return { type = 'kb_mode_toggle' }
    end

    -- Tab buttons (always active)
    local tg = state.tab_gs_rect
    if tg and tg.x and mx >= tg.x and mx <= tg.x + tg.w and my >= tg.y and my <= tg.y + tg.h then
        return { type = 'tab_gearswap' }
    end
    local to = state.tab_org_rect
    if to and to.x and mx >= to.x and mx <= to.x + to.w and my >= to.y and my <= to.y + to.h then
        return { type = 'tab_organizer' }
    end

    -- Sort toggle (organizer mode)
    if state.mode == 'organizer' then
        local sr = state.sort_toggle_rect
        if sr and sr.x and mx >= sr.x and mx <= sr.x + sr.w and my >= sr.y and my <= sr.y + sr.h then
            return { type = 'sort_toggle' }
        end
    end

    -- Organizer elements
    if state.mode == 'organizer' then
        -- Scroll buttons
        if elements.org_scroll_up then
            local s = elements.org_scroll_up
            if mx >= s.x and mx <= s.x + s.w and my >= s.y and my <= s.y + s.h then
                return { type = 'org_scroll_up' }
            end
        end
        if elements.org_scroll_down then
            local s = elements.org_scroll_down
            if mx >= s.x and mx <= s.x + s.w and my >= s.y and my <= s.y + s.h then
                return { type = 'org_scroll_down' }
            end
        end
        -- Bag entries
        for _, entry in ipairs(elements.org_bag_entries) do
            if entry.active and mx >= entry.x and mx <= entry.x + entry.w and my >= entry.y and my <= entry.y + entry.h then
                return { type = 'org_bag', bag_name = entry.bag_name }
            end
        end
        local cb = state.org_conflict_btn_rect
        if cb and cb.x and mx >= cb.x and mx <= cb.x + cb.w and my >= cb.y and my <= cb.y + cb.h then
            return { type = 'org_conflict_btn' }
        end
        local sb = state.org_scattered_btn_rect
        if sb and sb.x and mx >= sb.x and mx <= sb.x + sb.w and my >= sb.y and my <= sb.y + sb.h then
            return { type = 'org_scattered_btn' }
        end
    end

    -- Dropdown menu (checked first when open, overlays other elements)
    if state.dropdown_open then
        local count = #state.filter_presets
        for _, item in ipairs(elements.filter_menu_items) do
            if item.preset_index > 0 and item.preset_index <= count then
                if mx >= item.x and mx <= item.x + item.w and my >= item.y and my <= item.y + item.h then
                    return { type = 'filter_menu_item', index = item.preset_index }
                end
            end
        end
        local m = elements.filter_menu
        if m and mx >= m.x and mx <= m.x + m.w and my >= m.y and my <= m.y + m.h then
            return { type = 'filter_menu' }
        end
    end

    -- Dropdown button
    if elements.filter_dropdown then
        local d = elements.filter_dropdown
        if mx >= d.x and mx <= d.x + d.w and my >= d.y and my <= d.y + d.h then
            return { type = 'filter_dropdown' }
        end
    end

    -- Generate button (gearswap only)
    if state.mode == 'gearswap' and elements.generate_btn_bg then
        local bx = state.pos_x + BORDER + SLOT_PAD
        local by = state.pos_y + BORDER + TITLE_BAR_H + SLOT_PAD + left_panel_h + SLOT_PAD
        if mx >= bx and mx <= bx + BTN_W and my >= by and my <= by + BTN_H then
            return { type = 'generate_btn' }
        end
        -- Remove All / Re-equip buttons (stacked)
        local btn2_y = by + BTN_H + SLOT_PAD
        if mx >= bx and mx <= bx + BTN_W and my >= btn2_y and my <= btn2_y + BTN_H then
            return { type = 'remove_all_btn' }
        end
        local btn3_y = btn2_y + BTN_H + SLOT_PAD
        if mx >= bx and mx <= bx + BTN_W and my >= btn3_y and my <= btn3_y + BTN_H then
            return { type = 'reequip_btn' }
        end
        -- Save / Load buttons
        local sr = state.save_btn_rect
        if sr and sr.x and mx >= sr.x and mx <= sr.x + sr.w and my >= sr.y and my <= sr.y + sr.h then
            return { type = 'save_btn' }
        end
        local lr = state.load_btn_rect
        if lr and lr.x and mx >= lr.x and mx <= lr.x + lr.w and my >= lr.y and my <= lr.y + lr.h then
            return { type = 'load_btn' }
        end
    end

    -- Scroll buttons
    if elements.scroll_up then
        local s = elements.scroll_up
        if mx >= s.x and mx <= s.x + s.w and my >= s.y and my <= s.y + s.h then
            return { type = 'scroll_up' }
        end
    end
    if elements.scroll_down then
        local s = elements.scroll_down
        if mx >= s.x and mx <= s.x + s.w and my >= s.y and my <= s.y + s.h then
            return { type = 'scroll_down' }
        end
    end

    -- Equipment icons
    for slot_name, icon_data in pairs(elements.equip_icons) do
        if mx >= icon_data.x and mx <= icon_data.x + ICON_SIZE and my >= icon_data.y and my <= icon_data.y + ICON_SIZE then
            return { type = 'equip_slot', slot = slot_name, item = icon_data.item }
        end
    end

    -- Inventory icons
    for idx, icon_data in pairs(elements.inv_icons) do
        if icon_data.visible and icon_data.item then
            if mx >= icon_data.x and mx <= icon_data.x + ICON_SIZE and my >= icon_data.y and my <= icon_data.y + ICON_SIZE then
                return { type = 'inv_item', index = idx, item = icon_data.item }
            end
        end
    end

    -- Tooltip panel
    local tr = state.tooltip_rect
    if tr and tr.x and mx >= tr.x and mx <= tr.x + tr.w and my >= tr.y and my <= tr.y + tr.h then
        return { type = 'tooltip_panel' }
    end

    -- Stat panel
    local sr2 = state.stat_rect
    if sr2 and sr2.x and mx >= sr2.x and mx <= sr2.x + sr2.w and my >= sr2.y and my <= sr2.y + sr2.h then
        return { type = 'stat_panel' }
    end

    -- Title bar for window dragging
    local tb_y_start = state.pos_y + BORDER
    local tb_y_end = tb_y_start + TITLE_BAR_H
    if mx >= state.pos_x and mx <= state.pos_x + total_w and my >= tb_y_start and my <= tb_y_end then
        return { type = 'title_bar' }
    end

    -- Anywhere inside window
    if mx >= state.pos_x and mx <= state.pos_x + total_w and my >= state.pos_y and my <= state.pos_y + total_h then
        return { type = 'window' }
    end

    return nil
end

-- === WINDOW MOVEMENT ===

function ui.move_to(x, y)
    state.pos_x = x
    state.pos_y = y
    ui.build()
    if state.equipment then
        ui.update_equipment(state.equipment)
    end
    if state.inv_items and #state.inv_items > 0 then
        ui.refresh_inv_grid()
    end
end

function ui.start_drag(mx, my)
    state.win_dragging = true
    state.drag_offset_x = mx - state.pos_x
    state.drag_offset_y = my - state.pos_y
end

function ui.drag(mx, my)
    if state.win_dragging then
        ui.move_to(mx - state.drag_offset_x, my - state.drag_offset_y)
    end
end

function ui.stop_drag()
    state.win_dragging = false
end

function ui.is_dragging()
    return state.win_dragging
end

-- === VISIBILITY ===

function ui.show()
    state.visible = true
    icon_handler.set_ui_visible(true)
    -- Window frame (always)
    show_element(elements.border_top)
    show_element(elements.border_bottom)
    show_element(elements.border_left)
    show_element(elements.border_right)
    show_element(elements.title_bar)
    show_element(elements.title_text)
    show_element(elements.bg)
    show_element(elements.tab_gs_bg)
    show_element(elements.tab_gs_text)
    show_element(elements.tab_org_bg)
    show_element(elements.tab_org_text)

    -- Right panel (always)
    show_element(elements.inv_bg)
    show_element(elements.inv_label)
    show_element(elements.tooltip_bg)
    show_element(elements.tooltip_text)
    show_element(elements.stat_bg)
    show_element(elements.stat_label)
    show_element(elements.stat_text)
    if elements.scroll_up then
        show_element(elements.scroll_up.bg)
        show_element(elements.scroll_up.text)
    end
    if elements.scroll_down then
        show_element(elements.scroll_down.bg)
        show_element(elements.scroll_down.text)
    end
    if elements.filter_dropdown then
        show_element(elements.filter_dropdown.bg)
        show_element(elements.filter_dropdown.text)
        show_element(elements.filter_dropdown.arrow)
    end
    for _, icon_data in pairs(elements.inv_icons) do
        if icon_data.visible and icon_data.item then
            icon_data.image:alpha(230)
            icon_data.image:show()
        end
    end

    -- Sort toggle (organizer only)
    if state.mode == 'organizer' then
        show_element(elements.sort_toggle_bg)
        show_element(elements.sort_toggle_text)
    end

    -- Left panel: mode-dependent
    if state.mode == 'gearswap' then
        show_element(elements.equip_bg)
        show_element(elements.generate_btn_bg)
        show_element(elements.generate_btn_text)
        show_element(elements.remove_all_btn_bg)
        show_element(elements.remove_all_btn_text)
        show_element(elements.reequip_btn_bg)
        show_element(elements.reequip_btn_text)
        show_element(elements.save_btn_bg)
        show_element(elements.save_btn_text)
        show_element(elements.load_btn_bg)
        show_element(elements.load_btn_text)
        show_element(elements.status_text)
        for _, lbl in pairs(elements.equip_labels) do
            show_element(lbl)
        end
        for _, icon_data in pairs(elements.equip_icons) do
            if icon_data.item then
                icon_data.image:alpha(230)
                icon_data.image:show()
            end
        end
    else
        ui.show_org_panel()
    end

    if elements.drag_icon and not state.item_dragging then
        elements.drag_icon:hide()
    end

    -- Keyboard nav
    show_element(elements.kb_mode_text)
    if state.kb_mode then
        ui.update_kb_cursor()
        ui.update_kb_selection()
    end
end

function ui.hide()
    state.visible = false
    icon_handler.set_ui_visible(false)
    ui.cancel_item_drag()
    hide_element(elements.border_top)
    hide_element(elements.border_bottom)
    hide_element(elements.border_left)
    hide_element(elements.border_right)
    hide_element(elements.title_bar)
    hide_element(elements.title_text)
    hide_element(elements.bg)
    hide_element(elements.equip_bg)
    hide_element(elements.inv_bg)
    hide_element(elements.inv_label)
    hide_element(elements.tooltip_bg)
    hide_element(elements.tooltip_text)
    hide_element(elements.stat_bg)
    hide_element(elements.stat_label)
    hide_element(elements.stat_text)
    hide_element(elements.generate_btn_bg)
    hide_element(elements.generate_btn_text)
    hide_element(elements.remove_all_btn_bg)
    hide_element(elements.remove_all_btn_text)
    hide_element(elements.reequip_btn_bg)
    hide_element(elements.reequip_btn_text)
    hide_element(elements.save_btn_bg)
    hide_element(elements.save_btn_text)
    hide_element(elements.load_btn_bg)
    hide_element(elements.load_btn_text)
    hide_element(elements.status_text)
    hide_element(elements.drag_icon)
    hide_element(elements.tab_gs_bg)
    hide_element(elements.tab_gs_text)
    hide_element(elements.tab_org_bg)
    hide_element(elements.tab_org_text)
    -- Scroll buttons
    if elements.scroll_up then
        hide_element(elements.scroll_up.bg)
        hide_element(elements.scroll_up.text)
    end
    if elements.scroll_down then
        hide_element(elements.scroll_down.bg)
        hide_element(elements.scroll_down.text)
    end
    -- Filter dropdown + menu
    if elements.filter_dropdown then
        hide_element(elements.filter_dropdown.bg)
        hide_element(elements.filter_dropdown.text)
        hide_element(elements.filter_dropdown.arrow)
    end
    ui.close_dropdown()
    -- Equip labels
    for _, lbl in pairs(elements.equip_labels) do
        hide_element(lbl)
    end
    -- All icons
    for _, icon_data in pairs(elements.equip_icons) do
        icon_data.image:hide()
    end
    for _, icon_data in pairs(elements.inv_icons) do
        icon_data.image:hide()
    end
    -- Sort toggle
    hide_element(elements.sort_toggle_bg)
    hide_element(elements.sort_toggle_text)
    -- Keyboard nav
    hide_element(elements.kb_cursor)
    hide_element(elements.kb_selection)
    hide_element(elements.kb_mode_text)
    -- Organizer elements
    ui.hide_org_panel()
end

function ui.toggle()
    if state.visible then ui.hide() else ui.show() end
end

function ui.is_visible()
    return state.visible
end

function ui.get_position()
    return state.pos_x, state.pos_y
end

function ui.get_state()
    return state
end

function ui.is_over_window(mx, my)
    if not state.visible then return false end
    if mx >= state.pos_x and mx <= state.pos_x + total_w and
       my >= state.pos_y and my <= state.pos_y + total_h then
        return true
    end
    -- Include dropdown menu area when open
    if state.dropdown_open and elements.filter_menu then
        local m = elements.filter_menu
        if mx >= m.x and mx <= m.x + m.w and my >= m.y and my <= m.y + m.h then
            return true
        end
    end
    return false
end

-- === CLEANUP ===

function ui.destroy()
    local function destroy_element(el)
        if not el then return end
        if type(el) == 'table' then
            if el.destroy then
                pcall(el.destroy, el)
            else
                for _, v in pairs(el) do
                    if type(v) == 'table' and v.destroy then
                        pcall(v.destroy, v)
                    end
                end
            end
        end
    end

    destroy_element(elements.border_top)
    destroy_element(elements.border_bottom)
    destroy_element(elements.border_left)
    destroy_element(elements.border_right)
    destroy_element(elements.title_bar)
    destroy_element(elements.title_text)
    destroy_element(elements.bg)
    destroy_element(elements.equip_bg)
    destroy_element(elements.inv_bg)
    destroy_element(elements.inv_label)
    destroy_element(elements.tooltip_bg)
    destroy_element(elements.tooltip_text)
    destroy_element(elements.stat_bg)
    destroy_element(elements.stat_label)
    destroy_element(elements.stat_text)
    destroy_element(elements.status_text)
    destroy_element(elements.generate_btn_bg)
    destroy_element(elements.generate_btn_text)
    destroy_element(elements.remove_all_btn_bg)
    destroy_element(elements.remove_all_btn_text)
    destroy_element(elements.reequip_btn_bg)
    destroy_element(elements.reequip_btn_text)
    destroy_element(elements.save_btn_bg)
    destroy_element(elements.save_btn_text)
    destroy_element(elements.load_btn_bg)
    destroy_element(elements.load_btn_text)
    destroy_element(elements.scroll_up)
    destroy_element(elements.scroll_down)
    destroy_element(elements.drag_icon)
    -- Filter dropdown + menu
    destroy_element(elements.filter_dropdown)
    destroy_element(elements.filter_menu)
    for _, item in ipairs(elements.filter_menu_items) do
        destroy_element(item)
    end

    for _, v in pairs(elements.equip_icons) do destroy_element(v) end
    for _, v in pairs(elements.inv_icons) do destroy_element(v) end
    for _, v in pairs(elements.equip_labels) do
        if v and v.destroy then pcall(v.destroy, v) end
    end
    -- Organizer
    destroy_element(elements.tab_gs_bg)
    destroy_element(elements.tab_gs_text)
    destroy_element(elements.tab_org_bg)
    destroy_element(elements.tab_org_text)
    destroy_element(elements.org_header)
    destroy_element(elements.org_conflict_btn_bg)
    destroy_element(elements.org_conflict_btn_text)
    destroy_element(elements.org_scattered_btn_bg)
    destroy_element(elements.org_scattered_btn_text)
    destroy_element(elements.org_scroll_up)
    destroy_element(elements.org_scroll_down)
    destroy_element(elements.sort_toggle_bg)
    destroy_element(elements.sort_toggle_text)
    destroy_element(elements.kb_cursor)
    destroy_element(elements.kb_selection)
    destroy_element(elements.kb_mode_text)
    for _, entry in ipairs(elements.org_bag_entries) do
        destroy_element(entry)
    end

    elements = {
        border_top = nil, border_bottom = nil, border_left = nil, border_right = nil,
        title_bar = nil, title_text = nil,
        bg = nil, equip_bg = nil, inv_bg = nil, inv_label = nil,
        tooltip_bg = nil, tooltip_text = nil,
        stat_bg = nil, stat_label = nil, stat_text = nil,
        status_text = nil,
        generate_btn_bg = nil, generate_btn_text = nil,
        remove_all_btn_bg = nil, remove_all_btn_text = nil,
        reequip_btn_bg = nil, reequip_btn_text = nil,
        save_btn_bg = nil, save_btn_text = nil,
        load_btn_bg = nil, load_btn_text = nil,
        scroll_up = nil, scroll_down = nil, drag_icon = nil,
        filter_dropdown = nil, filter_menu = nil, filter_menu_items = {},
        equip_icons = {}, inv_icons = {}, equip_labels = {},
        tab_gs_bg = nil, tab_gs_text = nil,
        tab_org_bg = nil, tab_org_text = nil,
        org_header = nil, org_bag_entries = {},
        org_conflict_btn_bg = nil, org_conflict_btn_text = nil,
        org_scattered_btn_bg = nil, org_scattered_btn_text = nil,
        org_scroll_up = nil, org_scroll_down = nil,
        sort_toggle_bg = nil, sort_toggle_text = nil,
        kb_cursor = nil, kb_selection = nil, kb_mode_text = nil,
    }
end

-- === ORGANIZER MODE ===

function ui.get_mode()
    return state.mode
end

function ui.set_mode(mode)
    state.mode = mode
    -- Reset KB navigation on mode switch
    state.kb_focus = 'inv'
    state.kb_selected_item = nil
    state.kb_selected_inv_index = nil
    if mode == 'gearswap' then
        -- Highlight GearSwap tab, dim Organizer tab
        elements.tab_gs_bg:color(50, 100, 180)
        elements.tab_gs_bg:alpha(240)
        elements.tab_gs_text:color(255, 255, 255)
        elements.tab_org_bg:color(30, 40, 70)
        elements.tab_org_bg:alpha(180)
        elements.tab_org_text:color(160, 160, 200)
        -- Hide organizer left panel + sort toggle
        ui.hide_org_panel()
        hide_element(elements.sort_toggle_bg)
        hide_element(elements.sort_toggle_text)
        ui.set_inv_label('All Storage')
        -- Show gearswap left panel
        show_element(elements.equip_bg)
        show_element(elements.generate_btn_bg)
        show_element(elements.generate_btn_text)
        show_element(elements.remove_all_btn_bg)
        show_element(elements.remove_all_btn_text)
        show_element(elements.reequip_btn_bg)
        show_element(elements.reequip_btn_text)
        show_element(elements.save_btn_bg)
        show_element(elements.save_btn_text)
        show_element(elements.load_btn_bg)
        show_element(elements.load_btn_text)
        show_element(elements.status_text)
        for _, lbl in pairs(elements.equip_labels) do
            show_element(lbl)
        end
        for _, icon_data in pairs(elements.equip_icons) do
            if icon_data.item then
                icon_data.image:alpha(230)
                icon_data.image:show()
            end
        end
    else
        -- Highlight Organizer tab, dim GearSwap tab
        elements.tab_org_bg:color(50, 100, 180)
        elements.tab_org_bg:alpha(240)
        elements.tab_org_text:color(255, 255, 255)
        elements.tab_gs_bg:color(30, 40, 70)
        elements.tab_gs_bg:alpha(180)
        elements.tab_gs_text:color(160, 160, 200)
        -- Hide gearswap left panel
        hide_element(elements.equip_bg)
        hide_element(elements.generate_btn_bg)
        hide_element(elements.generate_btn_text)
        hide_element(elements.remove_all_btn_bg)
        hide_element(elements.remove_all_btn_text)
        hide_element(elements.reequip_btn_bg)
        hide_element(elements.reequip_btn_text)
        hide_element(elements.save_btn_bg)
        hide_element(elements.save_btn_text)
        hide_element(elements.load_btn_bg)
        hide_element(elements.load_btn_text)
        hide_element(elements.status_text)
        for _, lbl in pairs(elements.equip_labels) do
            hide_element(lbl)
        end
        for _, icon_data in pairs(elements.equip_icons) do
            icon_data.image:hide()
        end
        -- Show organizer left panel + sort toggle
        ui.show_org_panel()
        show_element(elements.sort_toggle_bg)
        show_element(elements.sort_toggle_text)
        state.org_view = 'bags'
        state.org_selected_bag = 'inventory'
        state.org_bag_scroll = 0
        ui.refresh_org_bags()
    end
end

function ui.hide_org_panel()
    hide_element(elements.org_header)
    hide_element(elements.org_conflict_btn_bg)
    hide_element(elements.org_conflict_btn_text)
    hide_element(elements.org_scattered_btn_bg)
    hide_element(elements.org_scattered_btn_text)
    if elements.org_scroll_up then
        hide_element(elements.org_scroll_up.bg)
        hide_element(elements.org_scroll_up.text)
    end
    if elements.org_scroll_down then
        hide_element(elements.org_scroll_down.bg)
        hide_element(elements.org_scroll_down.text)
    end
    for _, entry in ipairs(elements.org_bag_entries) do
        hide_element(entry.bg)
        hide_element(entry.text)
        hide_element(entry.count_text)
    end
end

function ui.show_org_panel()
    show_element(elements.org_header)
    show_element(elements.org_conflict_btn_bg)
    show_element(elements.org_conflict_btn_text)
    show_element(elements.org_scattered_btn_bg)
    show_element(elements.org_scattered_btn_text)
    if elements.org_scroll_up then
        show_element(elements.org_scroll_up.bg)
        show_element(elements.org_scroll_up.text)
    end
    if elements.org_scroll_down then
        show_element(elements.org_scroll_down.bg)
        show_element(elements.org_scroll_down.text)
    end
    ui.refresh_org_bags()
end

function ui.refresh_org_bags()
    local count = #ORG_BAG_LIST
    for i = 1, ORG_VISIBLE do
        local entry = elements.org_bag_entries[i]
        if not entry then break end
        local li = state.org_bag_scroll + i
        if li <= count then
            local bag_def = ORG_BAG_LIST[li]
            entry.bag_name = bag_def.key
            entry.mog = bag_def.mog or false
            entry.list_index = li
            entry.text:text(bag_def.label)

            -- Apply stored bag counts
            local bag_info = state._bag_data and state._bag_data[bag_def.key]
            if bag_info then
                entry.count_text:text(bag_info.used .. '/' .. bag_info.max)
            else
                entry.count_text:text('')
            end

            if bag_def.key == '_divider' then
                entry.active = false
                entry.bg:alpha(80)
                entry.bg:color(40, 40, 60)
                entry.text:color(120, 120, 160)
                entry.count_text:text('')
            elseif bag_def.key == state.org_selected_bag then
                entry.active = true
                entry.bg:color(50, 100, 200)
                entry.bg:alpha(240)
                entry.text:color(255, 255, 255)
                entry.count_text:color(220, 220, 255)
            else
                entry.active = true
                entry.bg:color(25, 25, 60)
                entry.bg:alpha(200)
                entry.text:color(200, 200, 230)
                entry.count_text:color(150, 150, 180)
            end
            show_element(entry.bg)
            show_element(entry.text)
            show_element(entry.count_text)
        else
            entry.list_index = 0
            entry.bag_name = ''
            entry.active = false
            hide_element(entry.bg)
            hide_element(entry.text)
            hide_element(entry.count_text)
        end
    end
end

function ui.org_bag_scroll_up()
    if state.org_bag_scroll > 0 then
        state.org_bag_scroll = state.org_bag_scroll - 1
        ui.refresh_org_bags()
    end
end

function ui.org_bag_scroll_down()
    local count = #ORG_BAG_LIST
    if state.org_bag_scroll + ORG_VISIBLE < count then
        state.org_bag_scroll = state.org_bag_scroll + 1
        ui.refresh_org_bags()
    end
end

function ui.select_org_bag(bag_name)
    state.org_selected_bag = bag_name
    state.org_view = 'bags'
    ui.refresh_org_bags()
end

function ui.update_bag_counts(bag_data)
    state._bag_data = bag_data
    -- Update count text for currently visible entries
    for _, entry in ipairs(elements.org_bag_entries) do
        if entry.bag_name and entry.bag_name ~= '' and entry.bag_name ~= '_divider' then
            local info = bag_data[entry.bag_name]
            if info then
                entry.count_text:text(info.used .. '/' .. info.max)
            end
        end
    end
end

function ui.set_mog_house(in_mog)
    state.in_mog_house = in_mog
    if state.mode == 'organizer' then
        elements.tab_org_text:text(in_mog and 'Org [F2] [MH]' or 'Organizer [F2]')
    end
end

function ui.set_org_view(view)
    state.org_view = view
    -- Highlight active view button
    if view == 'conflicts' then
        elements.org_conflict_btn_bg:color(180, 130, 40)
        elements.org_scattered_btn_bg:color(35, 100, 130)
    elseif view == 'scattered' then
        elements.org_conflict_btn_bg:color(130, 100, 35)
        elements.org_scattered_btn_bg:color(40, 130, 180)
    else
        elements.org_conflict_btn_bg:color(130, 100, 35)
        elements.org_scattered_btn_bg:color(35, 100, 130)
    end
end

function ui.update_org_counts(num_conflicts, num_scattered)
    if elements.org_conflict_btn_text then
        elements.org_conflict_btn_text:text('Conflicts (' .. num_conflicts .. ')')
    end
    if elements.org_scattered_btn_text then
        elements.org_scattered_btn_text:text('Scattered (' .. num_scattered .. ')')
    end
end

function ui.get_org_view()
    return state.org_view
end

function ui.get_org_selected_bag()
    return state.org_selected_bag
end

function ui.set_inv_label(text)
    if elements.inv_label then
        elements.inv_label:text(text or 'All Storage')
    end
end

function ui.get_sort_mode()
    return state.sort_mode
end

function ui.toggle_sort_mode()
    if state.sort_mode == 'gear_first' then
        state.sort_mode = 'items_first'
    else
        state.sort_mode = 'gear_first'
    end
    if elements.sort_toggle_text then
        elements.sort_toggle_text:text(state.sort_mode == 'gear_first' and 'Gear First' or 'Items First')
    end
    return state.sort_mode
end

function ui.get_bag_label(bag_key)
    for _, entry in ipairs(ORG_BAG_LIST) do
        if entry.key == bag_key then return entry.label end
    end
    return bag_key
end

-- === KEYBOARD NAVIGATION ===

function ui.get_kb_mode()
    return state.kb_mode
end

function ui.set_kb_mode(enabled)
    state.kb_mode = enabled
    if elements.kb_mode_text then
        elements.kb_mode_text:text(enabled and '[F3:KB]' or '[F3:Drag]')
    end
    if not enabled then
        if elements.kb_cursor then elements.kb_cursor:hide() end
        if elements.kb_selection then elements.kb_selection:hide() end
        state.kb_selected_item = nil
        state.kb_selected_inv_index = nil
    else
        state.kb_focus = 'inv'
        state.kb_inv_index = 1
        state.kb_selected_item = nil
        state.kb_selected_inv_index = nil
        if state.visible then
            ui.update_kb_cursor()
        end
    end
    return enabled
end

function ui.toggle_kb_mode()
    return ui.set_kb_mode(not state.kb_mode)
end

function ui.get_kb_selected_item()
    return state.kb_selected_item
end

function ui.update_kb_cursor()
    if not state.kb_mode or not state.visible or not elements.kb_cursor then
        if elements.kb_cursor then elements.kb_cursor:hide() end
        return
    end

    if state.kb_focus == 'inv' then
        local items = state.inv_items or {}
        if #items == 0 then
            elements.kb_cursor:hide()
            return
        end
        if state.kb_inv_index > #items then state.kb_inv_index = #items end
        if state.kb_inv_index < 1 then state.kb_inv_index = 1 end

        -- Auto-scroll to keep cursor visible
        local abs_row = math.floor((state.kb_inv_index - 1) / INV_COLS)
        if abs_row < state.scroll_offset then
            state.scroll_offset = abs_row
            ui.refresh_inv_grid()
            return -- refresh_inv_grid will call update_kb_cursor again
        elseif abs_row >= state.scroll_offset + INV_VISIBLE_ROWS then
            state.scroll_offset = abs_row - INV_VISIBLE_ROWS + 1
            ui.refresh_inv_grid()
            return
        end

        local display_idx = state.kb_inv_index - state.scroll_offset * INV_COLS
        local icon_data = elements.inv_icons[display_idx]
        if icon_data then
            elements.kb_cursor:size(ICON_SIZE, ICON_SIZE)
            elements.kb_cursor:pos(icon_data.x, icon_data.y)
            elements.kb_cursor:show()
        else
            elements.kb_cursor:hide()
        end

    elseif state.kb_focus == 'equip' then
        local slot_name = equip_nav_grid[state.kb_equip_row] and equip_nav_grid[state.kb_equip_row][state.kb_equip_col]
        if slot_name then
            local icon_data = elements.equip_icons[slot_name]
            if icon_data then
                elements.kb_cursor:size(ICON_SIZE, ICON_SIZE)
                elements.kb_cursor:pos(icon_data.x, icon_data.y)
                elements.kb_cursor:show()
            else
                elements.kb_cursor:hide()
            end
        else
            elements.kb_cursor:hide()
        end

    elseif state.kb_focus == 'bags' then
        local bag_def = ORG_BAG_LIST[state.kb_bag_index]
        if not bag_def then
            elements.kb_cursor:hide()
            return
        end

        -- Auto-scroll to keep cursor visible
        local visual_idx = state.kb_bag_index - state.org_bag_scroll
        if visual_idx < 1 then
            state.org_bag_scroll = state.kb_bag_index - 1
            ui.refresh_org_bags()
            visual_idx = 1
        elseif visual_idx > ORG_VISIBLE then
            state.org_bag_scroll = state.kb_bag_index - ORG_VISIBLE
            ui.refresh_org_bags()
            visual_idx = ORG_VISIBLE
        end

        local entry = elements.org_bag_entries[visual_idx]
        if entry then
            elements.kb_cursor:size(entry.w, entry.h - 2)
            elements.kb_cursor:pos(entry.x, entry.y)
            elements.kb_cursor:show()
        else
            elements.kb_cursor:hide()
        end

    elseif state.kb_focus == 'filter' then
        -- Filter dropdown has its own highlight, hide the general cursor
        elements.kb_cursor:hide()
    end
end

function ui.update_kb_selection()
    if not state.kb_mode or not state.visible or not elements.kb_selection or not state.kb_selected_item then
        if elements.kb_selection then elements.kb_selection:hide() end
        return
    end

    if not state.kb_selected_inv_index then
        elements.kb_selection:hide()
        return
    end

    -- Check if selected item is in visible range
    local abs_row = math.floor((state.kb_selected_inv_index - 1) / INV_COLS)
    if abs_row < state.scroll_offset or abs_row >= state.scroll_offset + INV_VISIBLE_ROWS then
        elements.kb_selection:hide()
        return
    end

    local display_idx = state.kb_selected_inv_index - state.scroll_offset * INV_COLS
    local icon_data = elements.inv_icons[display_idx]
    if icon_data then
        elements.kb_selection:size(ICON_SIZE, ICON_SIZE)
        elements.kb_selection:pos(icon_data.x, icon_data.y)
        elements.kb_selection:show()
    else
        elements.kb_selection:hide()
    end
end

function ui.kb_navigate(dir)
    if not state.kb_mode then return end

    if state.kb_focus == 'inv' then
        local items = state.inv_items or {}
        if #items == 0 then return end
        local col = (state.kb_inv_index - 1) % INV_COLS
        local row = math.floor((state.kb_inv_index - 1) / INV_COLS)
        local total_rows = math.ceil(#items / INV_COLS)

        if dir == 'left' then
            if col > 0 then
                state.kb_inv_index = state.kb_inv_index - 1
            end
        elseif dir == 'right' then
            if col < INV_COLS - 1 and state.kb_inv_index < #items then
                state.kb_inv_index = state.kb_inv_index + 1
            end
        elseif dir == 'up' then
            if row > 0 then
                state.kb_inv_index = state.kb_inv_index - INV_COLS
            end
        elseif dir == 'down' then
            local new_idx = state.kb_inv_index + INV_COLS
            if new_idx <= #items then
                state.kb_inv_index = new_idx
            elseif row < total_rows - 1 then
                state.kb_inv_index = #items
            end
        end

        if state.kb_inv_index < 1 then state.kb_inv_index = 1 end
        if state.kb_inv_index > #items then state.kb_inv_index = #items end

        local item = items[state.kb_inv_index]
        if item then ui.update_tooltip(item) end

    elseif state.kb_focus == 'equip' then
        if dir == 'left' then
            if state.kb_equip_col > 0 then state.kb_equip_col = state.kb_equip_col - 1 end
        elseif dir == 'right' then
            if state.kb_equip_col < 3 then state.kb_equip_col = state.kb_equip_col + 1 end
        elseif dir == 'up' then
            if state.kb_equip_row > 0 then state.kb_equip_row = state.kb_equip_row - 1 end
        elseif dir == 'down' then
            if state.kb_equip_row < 3 then state.kb_equip_row = state.kb_equip_row + 1 end
        end

        local slot_name = equip_nav_grid[state.kb_equip_row] and equip_nav_grid[state.kb_equip_row][state.kb_equip_col]
        if slot_name then
            local icon_data = elements.equip_icons[slot_name]
            if icon_data and icon_data.item then
                ui.update_tooltip(icon_data.item)
            end
        end

    elseif state.kb_focus == 'bags' then
        local count = #ORG_BAG_LIST
        if dir == 'up' then
            local new_idx = state.kb_bag_index - 1
            while new_idx >= 1 and ORG_BAG_LIST[new_idx].key == '_divider' do
                new_idx = new_idx - 1
            end
            if new_idx >= 1 then state.kb_bag_index = new_idx end
        elseif dir == 'down' then
            local new_idx = state.kb_bag_index + 1
            while new_idx <= count and ORG_BAG_LIST[new_idx].key == '_divider' do
                new_idx = new_idx + 1
            end
            if new_idx <= count then state.kb_bag_index = new_idx end
        end

    elseif state.kb_focus == 'filter' then
        local count = #state.filter_presets
        if count == 0 then return end
        if dir == 'up' then
            if state.kb_filter_index > 1 then
                state.kb_filter_index = state.kb_filter_index - 1
                -- scroll menu if needed
                if state.kb_filter_index <= state.menu_scroll then
                    state.menu_scroll = state.kb_filter_index - 1
                end
            end
        elseif dir == 'down' then
            if state.kb_filter_index < count then
                state.kb_filter_index = state.kb_filter_index + 1
                -- scroll menu if needed
                if state.kb_filter_index > state.menu_scroll + MENU_VISIBLE then
                    state.menu_scroll = state.kb_filter_index - MENU_VISIBLE
                end
            end
        end
        ui.refresh_menu_items()
        -- highlight the current kb selection
        ui.highlight_filter_item(state.kb_filter_index)
    end

    ui.update_kb_cursor()
    ui.update_kb_selection()
end

function ui.kb_switch_focus()
    if not state.kb_mode then return end

    if state.mode == 'gearswap' then
        if state.kb_focus == 'inv' then
            state.kb_focus = 'equip'
        else
            state.kb_focus = 'inv'
        end
    elseif state.mode == 'organizer' then
        if state.kb_focus == 'inv' then
            state.kb_focus = 'bags'
        else
            state.kb_focus = 'inv'
        end
    end

    ui.update_kb_cursor()
end

-- Returns action info for gsui.lua to handle
function ui.kb_select()
    if not state.kb_mode then return nil end

    if state.kb_focus == 'inv' then
        local items = state.inv_items or {}
        local item = items[state.kb_inv_index]
        if not item then return nil end

        -- Toggle selection on same item
        if state.kb_selected_item and state.kb_selected_inv_index == state.kb_inv_index then
            state.kb_selected_item = nil
            state.kb_selected_inv_index = nil
            ui.update_kb_selection()
            return { type = 'deselect' }
        end

        -- Select this item
        state.kb_selected_item = item
        state.kb_selected_inv_index = state.kb_inv_index
        ui.update_kb_selection()

        -- Auto-switch focus to target panel
        if state.mode == 'gearswap' then
            state.kb_focus = 'equip'
        elseif state.mode == 'organizer' then
            state.kb_focus = 'bags'
        end
        ui.update_kb_cursor()

        return { type = 'select', item = item }

    elseif state.kb_focus == 'equip' then
        if state.kb_selected_item then
            local slot_name = equip_nav_grid[state.kb_equip_row] and equip_nav_grid[state.kb_equip_row][state.kb_equip_col]
            if slot_name then
                local item = state.kb_selected_item
                state.kb_selected_item = nil
                state.kb_selected_inv_index = nil
                ui.update_kb_selection()
                state.kb_focus = 'inv'
                ui.update_kb_cursor()
                return { type = 'equip', slot = slot_name, item = item }
            end
        else
            -- No item selected, just show tooltip
            local slot_name = equip_nav_grid[state.kb_equip_row] and equip_nav_grid[state.kb_equip_row][state.kb_equip_col]
            if slot_name then
                local icon_data = elements.equip_icons[slot_name]
                if icon_data and icon_data.item then
                    ui.update_tooltip(icon_data.item)
                end
            end
        end

    elseif state.kb_focus == 'bags' then
        if state.kb_selected_item then
            local bag_def = ORG_BAG_LIST[state.kb_bag_index]
            if bag_def and bag_def.key ~= '_divider' then
                local item = state.kb_selected_item
                state.kb_selected_item = nil
                state.kb_selected_inv_index = nil
                ui.update_kb_selection()
                state.kb_focus = 'inv'
                ui.update_kb_cursor()
                return { type = 'bag', bag_name = bag_def.key, item = item }
            end
        else
            -- No item selected, show bag contents
            local bag_def = ORG_BAG_LIST[state.kb_bag_index]
            if bag_def and bag_def.key ~= '_divider' then
                return { type = 'show_bag', bag_name = bag_def.key }
            end
        end
    end

    return nil
end

function ui.kb_cancel()
    if not state.kb_mode then return end
    state.kb_selected_item = nil
    state.kb_selected_inv_index = nil
    ui.update_kb_selection()
    state.kb_focus = 'inv'
    ui.update_kb_cursor()
end

return ui
