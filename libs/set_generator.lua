local set_generator = {}

local selected_items = {}

local slot_order = {
    'main', 'sub', 'range', 'ammo',
    'head', 'neck', 'left_ear', 'right_ear',
    'body', 'hands', 'left_ring', 'right_ring',
    'back', 'waist', 'legs', 'feet',
}

function set_generator.clear()
    selected_items = {}
end

function set_generator.set_slot(slot_name, item_info)
    selected_items[slot_name] = item_info
end

function set_generator.remove_slot(slot_name)
    selected_items[slot_name] = nil
end

function set_generator.get_slot(slot_name)
    return selected_items[slot_name]
end

function set_generator.get_all_slots()
    return selected_items
end

function set_generator.has_items()
    for _ in pairs(selected_items) do
        return true
    end
    return false
end

function set_generator.populate_from_equipment(equipment_data)
    set_generator.clear()
    for slot_name, slot_data in pairs(equipment_data) do
        if slot_data.item then
            selected_items[slot_name] = slot_data.item
        end
    end
end

local function format_augments(augments)
    if not augments or #augments == 0 then return nil end
    local parts = {}
    for _, aug in ipairs(augments) do
        local escaped = aug:gsub("'", "\\'")
        table.insert(parts, "'" .. escaped .. "'")
    end
    return '{' .. table.concat(parts, ',') .. '}'
end

local function format_entry(item_info)
    local name = item_info.name
    local augs = format_augments(item_info.augments)
    if augs then
        return '{ name="' .. name .. '", augments=' .. augs .. ' }'
    else
        return '"' .. name .. '"'
    end
end

function set_generator.generate()
    local lines = {}
    table.insert(lines, '{')

    for _, slot_name in ipairs(slot_order) do
        local item = selected_items[slot_name]
        if item then
            table.insert(lines, '        ' .. slot_name .. '=' .. format_entry(item) .. ',')
        end
    end

    table.insert(lines, '}')
    return table.concat(lines, '\n')
end

function set_generator.generate_to_clipboard()
    local output = set_generator.generate()
    windower.copy_to_clipboard(output)
    return output
end

function set_generator.generate_to_file(filename)
    local output = set_generator.generate()
    local path = windower.addon_path .. 'data/'
    if not windower.dir_exists(path) then
        windower.create_dir(path)
    end
    local f = io.open(path .. (filename or 'generated_set') .. '.lua', 'w+')
    if f then
        f:write(output)
        f:close()
        return true, path .. (filename or 'generated_set') .. '.lua'
    end
    return false
end

-- Save current set as a named set with full item data
function set_generator.save_set(name)
    local path = windower.addon_path .. 'data/'
    if not windower.dir_exists(path) then
        windower.create_dir(path)
    end
    local filepath = path .. name .. '.lua'
    local lines = {}
    table.insert(lines, 'return {')
    for _, slot_name in ipairs(slot_order) do
        local item = selected_items[slot_name]
        if item then
            table.insert(lines, '    ["' .. slot_name .. '"] = {')
            table.insert(lines, '        id = ' .. (item.id or 0) .. ',')
            table.insert(lines, '        name = "' .. (item.name or ''):gsub('"', '\\"') .. '",')
            if item.augments and #item.augments > 0 then
                local augs = {}
                for _, aug in ipairs(item.augments) do
                    table.insert(augs, '"' .. aug:gsub('"', '\\"') .. '"')
                end
                table.insert(lines, '        augments = {' .. table.concat(augs, ', ') .. '},')
            end
            if item.bag_name then
                table.insert(lines, '        bag_name = "' .. item.bag_name .. '",')
            end
            table.insert(lines, '    },')
        end
    end
    table.insert(lines, '}')

    local f = io.open(filepath, 'w+')
    if f then
        f:write(table.concat(lines, '\n'))
        f:close()
        return true, filepath
    end
    return false
end

-- Load a named set
function set_generator.load_set(name)
    local filepath = windower.addon_path .. 'data/' .. name .. '.lua'
    local loader, err = loadfile(filepath)
    if not loader then return nil end
    local ok, data = pcall(loader)
    if not ok or type(data) ~= 'table' then return nil end

    -- Reconstruct item info from saved data
    -- We need the full item info from resources, so use the scanner
    local res = require('resources')
    local extdata_lib = require('extdata')
    set_generator.clear()
    local result = {}
    for slot_name, saved in pairs(data) do
        if saved.id and saved.id > 0 then
            local item_res = res.items[saved.id]
            if item_res then
                local info = {
                    id = saved.id,
                    name = saved.name or item_res.english or 'Unknown',
                    slots = {},
                    jobs = {},
                    job_ids = {},
                    augments = saved.augments,
                    bag_name = saved.bag_name,
                    level = item_res.level or 0,
                    item_level = item_res.item_level or 0,
                    description = '',
                    type = item_res.type or 0,
                    skill = item_res.skill or 0,
                    damage = item_res.damage or 0,
                    delay = item_res.delay or 0,
                    flags = item_res.flags or {},
                }
                -- Get description
                local ok_desc, desc_tbl = pcall(function() return res.item_descriptions[saved.id] end)
                if ok_desc and desc_tbl then
                    info.description = desc_tbl.en or desc_tbl.english or ''
                end
                -- Slot info
                local eq_slots = {
                    [0]='main',[1]='sub',[2]='range',[3]='ammo',
                    [4]='head',[5]='body',[6]='hands',[7]='legs',[8]='feet',
                    [9]='neck',[10]='waist',[11]='left_ear',[12]='right_ear',
                    [13]='left_ring',[14]='right_ring',[15]='back',
                }
                if item_res.slots then
                    for slot_id in item_res.slots:it() do
                        local sn = eq_slots[slot_id]
                        if sn then table.insert(info.slots, sn) end
                    end
                end
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
                selected_items[slot_name] = info
                result[slot_name] = info
            end
        end
    end
    return result
end

-- List saved sets
function set_generator.list_sets()
    local path = windower.addon_path .. 'data/'
    local sets = {}
    if not windower.dir_exists(path) then return sets end
    local files = windower.get_dir(path)
    if files then
        for _, file in ipairs(files) do
            local name = file:match('^(.+)%.lua$')
            if name and name ~= 'generated_set' then
                table.insert(sets, name)
            end
        end
    end
    table.sort(sets)
    return sets
end

-- Delete a saved set
function set_generator.delete_set(name)
    local filepath = windower.addon_path .. 'data/' .. name .. '.lua'
    local ok = os.remove(filepath)
    return ok ~= nil
end

return set_generator
