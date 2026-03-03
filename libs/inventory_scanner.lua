local res = require('resources')
local extdata = require('extdata')
local packets = require('packets')

local inventory_scanner = {}

local bag_ids = {
    inventory = 0,
    safe      = 1,
    storage   = 2,
    locker    = 4,
    satchel   = 5,
    sack      = 6,
    case      = 7,
    wardrobe  = 8,
    safe2     = 9,
    wardrobe2 = 10,
    wardrobe3 = 11,
    wardrobe4 = 12,
    wardrobe5 = 13,
    wardrobe6 = 14,
    wardrobe7 = 15,
    wardrobe8 = 16,
}

local bag_names_ordered = {
    'inventory', 'wardrobe', 'wardrobe2', 'wardrobe3', 'wardrobe4',
    'wardrobe5', 'wardrobe6', 'wardrobe7', 'wardrobe8',
    'satchel', 'sack', 'case',
}

local all_bag_names_ordered = {
    'inventory', 'wardrobe', 'wardrobe2', 'wardrobe3', 'wardrobe4',
    'wardrobe5', 'wardrobe6', 'wardrobe7', 'wardrobe8',
    'satchel', 'sack', 'case',
    'safe', 'safe2', 'storage', 'locker',
}

local equipment_slots = {
    [0]  = 'main',
    [1]  = 'sub',
    [2]  = 'range',
    [3]  = 'ammo',
    [4]  = 'head',
    [5]  = 'body',
    [6]  = 'hands',
    [7]  = 'legs',
    [8]  = 'feet',
    [9]  = 'neck',
    [10] = 'waist',
    [11] = 'left_ear',
    [12] = 'right_ear',
    [13] = 'left_ring',
    [14] = 'right_ring',
    [15] = 'back',
}

local cached_equipment = {}
local cached_inventory = {}
local last_scan_time = 0

function inventory_scanner.get_bag_names()
    return bag_names_ordered
end

function inventory_scanner.get_bag_id(bag_name)
    return bag_ids[bag_name]
end

function inventory_scanner.get_slot_name(slot_id)
    return equipment_slots[slot_id]
end

function inventory_scanner.get_slot_names()
    return equipment_slots
end

function inventory_scanner.get_all_bag_ids()
    return bag_ids
end

function inventory_scanner.get_all_bag_names()
    return all_bag_names_ordered
end

function inventory_scanner.get_bag_capacity(bag_name)
    local items_data = windower.ffxi.get_items()
    if not items_data or not items_data[bag_name] then return 0, 0 end
    local bag = items_data[bag_name]
    local mx = bag.max or 80
    local used = 0
    for i = 1, mx do
        if bag[i] and bag[i].id and bag[i].id ~= 0 then used = used + 1 end
    end
    return used, mx
end

function inventory_scanner.decode_augments(item_tab)
    if not item_tab or not item_tab.extdata then return nil end
    local ok, decoded = pcall(extdata.decode, item_tab)
    if ok and decoded and decoded.augments then
        local valid = {}
        for _, aug in pairs(decoded.augments) do
            if aug and aug ~= 'none' then
                table.insert(valid, aug)
            end
        end
        if #valid > 0 then return valid end
    end
    return nil
end

function inventory_scanner.get_item_info(item_tab)
    if not item_tab or not item_tab.id or item_tab.id == 0 then
        return nil
    end
    local item_res = res.items[item_tab.id]
    if not item_res then return nil end

    -- Description comes from a separate resource table (res.item_descriptions)
    local desc = ''
    local ok_desc, desc_tbl = pcall(function() return res.item_descriptions[item_tab.id] end)
    if ok_desc and desc_tbl then
        local d = desc_tbl.en or desc_tbl.english or ''
        if type(d) == 'string' then desc = d end
    end

    local info = {
        id = item_tab.id,
        name = item_res.english or item_res.en or 'Unknown',
        name_log = item_res.english_log or item_res.en_log or '',
        count = item_tab.count or 1,
        status = item_tab.status or 0,
        description = desc,
        category = item_res.category or '',
        level = item_res.level or 0,
        item_level = item_res.item_level or 0,
        jobs = {},
        job_ids = {},
        slots = {},
        flags = item_res.flags or {},
        type = item_res.type or 0,
        skill = item_res.skill or 0,
        damage = item_res.damage or 0,
        delay = item_res.delay or 0,
        shield_size = item_res.shield_size or 0,
        targets = item_res.targets or 0,
        cast_time = item_res.cast_time or 0,
        superior_level = item_res.superior_level or 0,
        extdata = item_tab.extdata,
        augments = nil,
        bag_name = nil,
        bag_index = nil,
    }

    if item_res.jobs then
        for job_id = 1, 23 do
            if item_res.jobs[job_id] then
                info.job_ids[job_id] = true
                local job = res.jobs[job_id]
                if job then
                    table.insert(info.jobs, job.ens or job.english_short or '')
                end
            end
        end
    end

    if item_res.slots then
        for slot_id in item_res.slots:it() do
            local slot_name = equipment_slots[slot_id]
            if slot_name then
                table.insert(info.slots, slot_name)
            end
        end
    end

    info.augments = inventory_scanner.decode_augments(item_tab)

    return info
end

function inventory_scanner.scan_equipment()
    local result = {}
    local items = windower.ffxi.get_items()
    if not items then return result end
    local equipment = items.equipment

    for slot_id = 0, 15 do
        local slot_name = equipment_slots[slot_id]
        local bag_id = equipment[slot_name .. '_bag']
        local inv_index = equipment[slot_name]

        result[slot_name] = { slot_id = slot_id, slot_name = slot_name, item = nil }

        if inv_index and inv_index ~= 0 and bag_id then
            local ok, item_tab = pcall(windower.ffxi.get_items, bag_id, inv_index)
            if ok and item_tab and item_tab.id ~= 0 then
                local info = inventory_scanner.get_item_info(item_tab)
                if info then
                    info.bag_id = bag_id
                    info.bag_index = inv_index
                    for bname, bid in pairs(bag_ids) do
                        if bid == bag_id then
                            info.bag_name = bname
                            break
                        end
                    end
                    result[slot_name].item = info
                end
            end
        end
    end

    cached_equipment = result
    return result
end

function inventory_scanner.scan_bag(bag_name)
    local items_data = windower.ffxi.get_items()
    if not items_data then return {} end

    local bag = items_data[bag_name]
    if not bag then return {} end

    local result = {}
    local max_slots = bag.max or 80

    for i = 1, max_slots do
        local item_tab = bag[i]
        if item_tab and item_tab.id and item_tab.id ~= 0 then
            local info = inventory_scanner.get_item_info(item_tab)
            if info then
                info.bag_name = bag_name
                info.bag_index = i
                info.bag_id = bag_ids[bag_name]
                table.insert(result, info)
            end
        end
    end

    return result
end

function inventory_scanner.scan_all_bags()
    local result = {}
    for _, bag_name in ipairs(bag_names_ordered) do
        result[bag_name] = inventory_scanner.scan_bag(bag_name)
    end
    cached_inventory = result
    last_scan_time = os.clock()
    return result
end

function inventory_scanner.get_cached_equipment()
    return cached_equipment
end

function inventory_scanner.get_cached_inventory()
    return cached_inventory
end

function inventory_scanner.needs_rescan(interval)
    interval = interval or 2
    return (os.clock() - last_scan_time) > interval
end

local function word_wrap(text, max_chars)
    max_chars = max_chars or 38
    if #text <= max_chars then return text end
    local wrapped = {}
    local remaining = text
    while #remaining > max_chars do
        local break_pos = max_chars
        -- Find last space within limit
        for i = max_chars, 1, -1 do
            if remaining:sub(i, i) == ' ' then
                break_pos = i
                break
            end
        end
        table.insert(wrapped, remaining:sub(1, break_pos))
        remaining = remaining:sub(break_pos + 1)
    end
    if #remaining > 0 then
        table.insert(wrapped, remaining)
    end
    return table.concat(wrapped, '\n')
end

local slot_display_names = {
    main = 'Main', sub = 'Sub', range = 'Range', ammo = 'Ammo',
    head = 'Head', body = 'Body', hands = 'Hands', legs = 'Legs', feet = 'Feet',
    neck = 'Neck', waist = 'Waist', left_ear = 'Ear', right_ear = 'Ear',
    left_ring = 'Ring', right_ring = 'Ring', back = 'Back',
}

-- Get deduplicated slot display string for an item
local function get_slot_display(item_info)
    if not item_info or not item_info.slots or #item_info.slots == 0 then return nil end
    local names = {}
    for _, s in ipairs(item_info.slots) do
        local d = slot_display_names[s] or s
        local found = false
        for _, e in ipairs(names) do
            if e == d then found = true; break end
        end
        if not found then table.insert(names, d) end
    end
    return '[' .. table.concat(names, '/') .. ']'
end

function inventory_scanner.get_slot_display_name(slot_name)
    return slot_display_names[slot_name] or slot_name
end

function inventory_scanner.build_tooltip_text(item_info, highlight_pattern)
    if not item_info then return '' end
    local lines = {}
    local max_chars = 38

    -- Item name
    table.insert(lines, word_wrap(item_info.name, max_chars))

    -- Always show slot indicator after name
    local slot_str = get_slot_display(item_info)
    if slot_str then
        table.insert(lines, slot_str)
    end

    -- Full description from item_descriptions resource
    -- This contains slot type, races, DEF/stats, abilities, etc.
    if item_info.description and item_info.description ~= '' then
        for line in item_info.description:gmatch('[^\r\n]+') do
            local trimmed = line:gsub('%s+$', '')
            if trimmed ~= '' then
                local wrapped = word_wrap(trimmed, max_chars)
                -- Highlight matching lines if filter active
                if highlight_pattern then
                    local pats = type(highlight_pattern) == 'table' and highlight_pattern or {highlight_pattern}
                    for _, pat in ipairs(pats) do
                        if trimmed:find(pat) then
                            wrapped = '>> ' .. wrapped
                            break
                        end
                    end
                end
                table.insert(lines, wrapped)
            end
        end
    else
        -- Weapon skill type
        local skill_names = {
            [1] = 'Hand-to-Hand', [2] = 'Dagger', [3] = 'Sword', [4] = 'Great Sword',
            [5] = 'Axe', [6] = 'Great Axe', [7] = 'Scythe', [8] = 'Polearm',
            [9] = 'Katana', [10] = 'Great Katana', [11] = 'Club', [12] = 'Staff',
            [25] = 'Archery', [26] = 'Marksmanship', [27] = 'Throwing',
        }
        if item_info.type == 4 and skill_names[item_info.skill] then
            table.insert(lines, '(' .. skill_names[item_info.skill] .. ')')
        end

        -- DMG / Delay for weapons
        if item_info.damage and item_info.damage > 0 then
            local stat_line = 'DMG:' .. item_info.damage
            if item_info.delay and item_info.delay > 0 then
                stat_line = stat_line .. ' Delay:' .. item_info.delay
            end
            table.insert(lines, stat_line)
        end
    end

    table.insert(lines, '')

    -- Augments
    if item_info.augments and #item_info.augments > 0 then
        table.insert(lines, 'Augments:')
        for _, aug in ipairs(item_info.augments) do
            local aug_text = ' ' .. word_wrap(aug, max_chars - 1)
            -- Highlight matching augments if filter active
            if highlight_pattern then
                local pats = type(highlight_pattern) == 'table' and highlight_pattern or {highlight_pattern}
                for _, pat in ipairs(pats) do
                    if aug:find(pat) then
                        aug_text = '>> ' .. aug_text
                        break
                    end
                end
            end
            table.insert(lines, aug_text)
        end
        table.insert(lines, '')
    end

    -- Job / Level
    if #item_info.jobs > 0 then
        local job_line = 'Lv.' .. item_info.level .. ' ' .. table.concat(item_info.jobs, '/')
        table.insert(lines, word_wrap(job_line, max_chars))
    end

    -- Item Level
    if item_info.item_level and item_info.item_level > 0 then
        table.insert(lines, '<Item Level: ' .. item_info.item_level .. '>')
    end

    -- Conflict warning
    if item_info.conflict_warning then
        table.insert(lines, '')
        table.insert(lines, word_wrap(item_info.conflict_warning, max_chars))
    end

    -- Also in other bags
    if item_info.also_in then
        table.insert(lines, '')
        table.insert(lines, 'Also in:')
        for _, loc in ipairs(item_info.also_in) do
            table.insert(lines, '  ' .. loc)
        end
    end

    -- Bag
    if item_info.bag_name then
        table.insert(lines, '[' .. item_info.bag_name .. ']')
    end

    return table.concat(lines, '\n')
end

-- Master list of all known FFXI stat/ability filters
local filter_master_list = {
    -- Melee
    { name = 'Double Attack',      pattern = '[Dd]ouble [Aa]ttack' },
    { name = 'Triple Attack',      pattern = '[Tt]riple [Aa]ttack' },
    { name = 'Store TP',           pattern = '[Ss]tore TP' },
    { name = 'Dual Wield',         pattern = '[Dd]ual [Ww]ield' },
    { name = 'Subtle Blow',        pattern = '[Ss]ubtle [Bb]low' },
    { name = 'Critical Hit',       pattern = '[Cc]ritical' },
    { name = 'WS Damage',          pattern = '[Ww]eapon [Ss]kill' },
    { name = 'Skillchain',         pattern = '[Ss]killchain' },
    { name = 'Kick Attacks',       pattern = '[Kk]ick [Aa]ttack' },
    { name = 'Martial Arts',       pattern = '[Mm]artial [Aa]rts' },
    { name = 'Counter',            pattern = '[Cc]ounter' },
    { name = 'Guard',              pattern = '[Gg]uard' },
    -- Ranged
    { name = 'Snapshot',           pattern = '[Ss]napshot' },
    { name = 'Rapid Shot',         pattern = '[Rr]apid [Ss]hot' },
    { name = 'Ranged Attack',      pattern = {'[Rr]anged [Aa]tt', 'Rng%.Atk'} },
    { name = 'Ranged Accuracy',    pattern = {'[Rr]anged [Aa]cc', 'Rng%.Acc'} },
    { name = 'Recycle',            pattern = '[Rr]ecycle' },
    { name = 'Barrage',            pattern = '[Bb]arrage' },
    -- Magic offense
    { name = 'Magic Atk Bonus',    pattern = '[Mm]ag.*[Aa]tk' },
    { name = 'Magic Accuracy',     pattern = '[Mm]ag.*[Aa]cc' },
    { name = 'Magic Damage',       pattern = '[Mm]agic [Dd]amage' },
    { name = 'Magic Burst',        pattern = '[Mm]agic [Bb]urst' },
    { name = 'Occult Acumen',      pattern = '[Oo]ccult [Aa]cumen' },
    -- Casting
    { name = 'Fast Cast',          pattern = '[Ff]ast [Cc]ast' },
    { name = 'Quick Magic',        pattern = '[Qq]uick [Mm]agic' },
    { name = 'Conserve MP',        pattern = '[Cc]onserve MP' },
    { name = 'Spell Interrupt Down', pattern = '[Ss]pell [Ii]nterrupt' },
    -- Healing / Cure
    { name = 'Cure Potency',       pattern = '[Cc]ure.*[Pp]otency' },
    { name = 'Cure Cast Time',     pattern = {'[Cc]ure.*[Cc]ast.*[Tt]ime', '[Cc]ure.*[Ss]pellcasting'} },
    { name = 'Healing Magic',      pattern = '[Hh]ealing [Mm]agic' },
    { name = 'Cursna',             pattern = '[Cc]ursna' },
    -- Buffing
    { name = 'Enhancing Duration', pattern = {'[Ee]nhancing.*[Dd]uration', '[Ee]nhance.*[Dd]uration'} },
    { name = 'Regen Potency',      pattern = '[Rr]egen.*[Pp]otency' },
    { name = 'Bar Spell Effect',   pattern = '[Bb]ar.*[Ss]pell' },
    { name = 'Stoneskin',          pattern = '[Ss]toneskin' },
    { name = 'Phalanx',            pattern = '[Pp]halanx' },
    -- Enfeebling
    { name = 'Enfeebling Duration', pattern = '[Ee]nfeebling.*[Dd]uration' },
    -- Pet / SMN
    { name = 'BP Delay',           pattern = {'[Bb]lood [Pp]act.*[Dd]elay', '[Bb]lood [Pp]act.*[Rr]ecast'} },
    { name = 'BP Damage',          pattern = {'[Bb]lood [Pp]act.*[Dd]amage', '[Bb]lood [Pp]act.*DMG'} },
    { name = 'Avatar',             pattern = '[Aa]vatar' },
    { name = 'Avatar Perpetuation', pattern = '[Pp]erpetuation' },
    { name = 'Pet',                pattern = '[Pp]et:' },
    { name = 'Pet: Haste',         pattern = '[Pp]et:.*[Hh]aste' },
    { name = 'Pet: Attack',        pattern = '[Pp]et:.*[Aa]ttack' },
    { name = 'Pet: Accuracy',      pattern = '[Pp]et:.*[Aa]cc' },
    { name = 'Pet: MAB',           pattern = '[Pp]et:.*[Mm]ag.*[Aa]tk' },
    { name = 'Pet: Regen',         pattern = '[Pp]et:.*[Rr]egen' },
    -- BST
    { name = 'Charm',              pattern = '[Cc]harm' },
    { name = 'Reward',             pattern = '[Rr]eward' },
    -- BRD
    { name = 'Song Duration',      pattern = '[Ss]ong.*[Dd]uration' },
    { name = 'Song Recast',        pattern = '[Ss]ong.*[Rr]ecast' },
    { name = 'Song Effect',        pattern = '[Ss]ong.*[Ee]ffect' },
    -- COR
    { name = 'Phantom Roll',       pattern = '[Pp]hantom [Rr]oll' },
    { name = 'Quick Draw',         pattern = '[Qq]uick [Dd]raw' },
    -- DNC
    { name = 'Waltz Potency',      pattern = '[Ww]altz.*[Pp]otency' },
    { name = 'Waltz Delay',        pattern = '[Ww]altz.*[Dd]elay' },
    { name = 'Step',               pattern = '[Ss]tep.*[Aa]cc' },
    -- RUN
    { name = 'Elemental Resist',   pattern = '[Ee]lemental [Rr]esist' },
    { name = 'Rune Enchantment',   pattern = '[Rr]une [Ee]nchant' },
    -- Magic Skills
    { name = 'Summoning Magic',    pattern = '[Ss]ummoning [Mm]agic' },
    { name = 'White Magic Skill',  pattern = '[Ww]hite [Mm]agic' },
    { name = 'Black Magic Skill',  pattern = '[Bb]lack [Mm]agic' },
    { name = 'Enfeebling Magic',   pattern = '[Ee]nfeebling' },
    { name = 'Enhancing Magic',    pattern = '[Ee]nhanc[ei]' },
    { name = 'Elemental Magic',    pattern = '[Ee]lemental [Mm]agic' },
    { name = 'Dark Magic',         pattern = '[Dd]ark [Mm]agic' },
    { name = 'Divine Magic',       pattern = '[Dd]ivine [Mm]agic' },
    { name = 'Blue Magic Skill',   pattern = '[Bb]lue [Mm]agic' },
    { name = 'Ninjutsu',           pattern = '[Nn]injutsu' },
    { name = 'Singing',            pattern = '[Ss]inging' },
    { name = 'Wind Instrument',    pattern = '[Ww]ind [Ii]nstrument' },
    { name = 'String Instrument',  pattern = '[Ss]tring [Ii]nstrument' },
    { name = 'Geomancy',           pattern = '[Gg]eomancy' },
    { name = 'Handbell',           pattern = '[Hh]andbell' },
    -- Combat Skills
    { name = 'Shield Skill',       pattern = '[Ss]hield [Ss]kill' },
    { name = 'Parrying Skill',     pattern = '[Pp]arrying' },
    { name = 'Evasion Skill',      pattern = '[Ee]vasion [Ss]kill' },
    -- Defense
    { name = 'Enmity',             pattern = '[Ee]nmity' },
    { name = 'Damage Taken',       pattern = '[Dd]amage [Tt]aken' },
    { name = 'Phys. Dmg Taken',    pattern = '[Pp]hys.*[Dd]amage [Tt]aken' },
    { name = 'Mag. Dmg Taken',     pattern = '[Mm]ag.*[Dd]amage [Tt]aken' },
    { name = 'Magic Evasion',      pattern = '[Mm]ag.*[Ee]va' },
    { name = 'Magic Defense',      pattern = '[Mm]ag.*[Dd]ef' },
    -- Utility
    { name = 'Haste',              pattern = '[Hh]aste' },
    { name = 'Refresh',            pattern = '[Rr]efresh' },
    { name = 'Regen',              pattern = '[Rr]egen' },
    { name = 'Movement Speed',     pattern = '[Mm]ovement [Ss]peed' },
    { name = 'Treasure Hunter',    pattern = '[Tt]reasure [Hh]unter' },
    -- Stats
    { name = 'Attack',             pattern = 'Attack' },
    { name = 'Accuracy',           pattern = 'Accuracy' },
    { name = 'STR',                pattern = 'STR' },
    { name = 'DEX',                pattern = 'DEX' },
    { name = 'VIT',                pattern = 'VIT' },
    { name = 'AGI',                pattern = 'AGI' },
    { name = 'INT',                pattern = 'INT' },
    { name = 'MND',                pattern = 'MND' },
    { name = 'CHR',                pattern = 'CHR' },
}

function inventory_scanner.matches_filter(item_info, pattern)
    if not pattern then return true end
    local patterns = type(pattern) == 'table' and pattern or {pattern}
    for _, pat in ipairs(patterns) do
        if item_info.description and item_info.description:find(pat) then return true end
        if item_info.augments then
            for _, aug in ipairs(item_info.augments) do
                if aug:find(pat) then return true end
            end
        end
    end
    return false
end

-- Escape special Lua pattern characters for literal matching
local function escape_pattern(str)
    return str:gsub('([%(%)%.%%%+%-%*%?%[%]%^%$])', '%%%1')
end

function inventory_scanner.find_active_filters(items)
    local matched = {}
    local seen_names = {}
    -- Check master list
    for _, filter in ipairs(filter_master_list) do
        for _, item in ipairs(items) do
            if inventory_scanner.matches_filter(item, filter.pattern) then
                table.insert(matched, filter)
                seen_names[filter.name:lower()] = true
                break
            end
        end
    end

    -- Auto-detect job ability enhancements from item descriptions
    local found_abilities = {}
    for _, item in ipairs(items) do
        if item.description then
            for ability in item.description:gmatch('[Ee]nhances "([^"]+)"') do
                found_abilities[ability] = true
            end
            for ability in item.description:gmatch('"([^"]+)" [Dd]uration') do
                found_abilities[ability] = true
            end
            for ability in item.description:gmatch('[Aa]ugments "([^"]+)"') do
                found_abilities[ability] = true
            end
            for ability in item.description:gmatch('"([^"]+)" [Ee]ffect') do
                found_abilities[ability] = true
            end
        end
        if item.augments then
            for _, aug in ipairs(item.augments) do
                for ability in aug:gmatch('[Ee]nhances "([^"]+)"') do
                    found_abilities[ability] = true
                end
                for ability in aug:gmatch('"([^"]+)" [Dd]uration') do
                    found_abilities[ability] = true
                end
            end
        end
    end
    for ability in pairs(found_abilities) do
        if not seen_names[ability:lower()] then
            table.insert(matched, { name = ability, pattern = escape_pattern(ability) })
        end
    end

    table.sort(matched, function(a, b) return a.name < b.name end)
    local active = {{ name = 'All', pattern = nil }}
    for _, f in ipairs(matched) do
        table.insert(active, f)
    end
    return active
end

function inventory_scanner.can_equip_in_slot(item_info, slot_name)
    if not item_info or not item_info.slots or not slot_name then return false end
    for _, s in ipairs(item_info.slots) do
        if s == slot_name then return true end
    end
    return false
end

function inventory_scanner.matches_slot_filter(item_info, slot_name)
    if not slot_name then return true end
    return inventory_scanner.can_equip_in_slot(item_info, slot_name)
end

function inventory_scanner.is_equippable_by(item_info, job_id, player_level)
    if not item_info then return false end
    if not item_info.slots or #item_info.slots == 0 then return false end
    if not job_id then return false end
    if not item_info.job_ids or not item_info.job_ids[job_id] then return false end
    if player_level and item_info.level and item_info.level > player_level then return false end
    return true
end

local slot_sort_priority = {
    main = 1, sub = 2, range = 3, ammo = 4,
    head = 5, neck = 6, left_ear = 7, right_ear = 7,
    body = 8, hands = 9, left_ring = 10, right_ring = 10,
    back = 11, waist = 12, legs = 13, feet = 14,
}

local weapon_type_priority = {
    [1] = 1, [2] = 2, [3] = 3, [4] = 4, [5] = 5, [6] = 6,
    [7] = 7, [8] = 8, [9] = 9, [10] = 10, [11] = 11, [12] = 12,
    [25] = 13, [26] = 14, [27] = 15,
}

function inventory_scanner.sort_by_slot(items)
    table.sort(items, function(a, b)
        local a_pri = 99
        local b_pri = 99
        if a.slots then
            for _, slot in ipairs(a.slots) do
                local p = slot_sort_priority[slot]
                if p and p < a_pri then a_pri = p end
            end
        end
        if b.slots then
            for _, slot in ipairs(b.slots) do
                local p = slot_sort_priority[slot]
                if p and p < b_pri then b_pri = p end
            end
        end
        if a_pri == b_pri then
            return (a.name or '') < (b.name or '')
        end
        return a_pri < b_pri
    end)
    return items
end

local function gear_compare(a, b)
    local a_pri = 99
    local b_pri = 99
    if a.slots then
        for _, slot in ipairs(a.slots) do
            local p = slot_sort_priority[slot]
            if p and p < a_pri then a_pri = p end
        end
    end
    if b.slots then
        for _, slot in ipairs(b.slots) do
            local p = slot_sort_priority[slot]
            if p and p < b_pri then b_pri = p end
        end
    end
    if a_pri ~= b_pri then return a_pri < b_pri end
    local a_wt = weapon_type_priority[a.skill] or 99
    local b_wt = weapon_type_priority[b.skill] or 99
    if a_wt ~= b_wt then return a_wt < b_wt end
    local a_il = a.item_level or 0
    local b_il = b.item_level or 0
    if a_il ~= b_il then return a_il > b_il end
    local a_el = a.level or 0
    local b_el = b.level or 0
    if a_el ~= b_el then return a_el > b_el end
    return (a.name or '') < (b.name or '')
end

function inventory_scanner.sort_organized(items, mode)
    local gear = {}
    local non_gear = {}
    for _, item in ipairs(items) do
        if item.slots and #item.slots > 0 then
            table.insert(gear, item)
        else
            table.insert(non_gear, item)
        end
    end
    table.sort(gear, gear_compare)
    table.sort(non_gear, function(a, b) return (a.name or '') < (b.name or '') end)
    local result = {}
    if mode == 'items_first' then
        for _, item in ipairs(non_gear) do table.insert(result, item) end
        for _, item in ipairs(gear) do table.insert(result, item) end
    else
        for _, item in ipairs(gear) do table.insert(result, item) end
        for _, item in ipairs(non_gear) do table.insert(result, item) end
    end
    return result
end

return inventory_scanner
