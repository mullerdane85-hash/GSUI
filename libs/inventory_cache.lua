local inventory_cache = {}

local data_path = windower.addon_path .. 'data/'

-- Get cache file path for current character
local function get_cache_path()
    local player = windower.ffxi.get_player()
    if not player or not player.name then return nil end
    return data_path .. 'inv_cache_' .. player.name .. '.lua'
end

-- Serialize a single value to valid Lua source
local function serialize_value(v)
    local t = type(v)
    if t == 'string' then
        return string.format('%q', v)
    elseif t == 'number' then
        return tostring(v)
    elseif t == 'boolean' then
        return v and 'true' or 'false'
    elseif t == 'table' then
        local parts = {}
        -- Check if sequential array
        local is_array = true
        local max_i = 0
        for k in pairs(v) do
            if type(k) ~= 'number' or k < 1 or math.floor(k) ~= k then
                is_array = false
                break
            end
            if k > max_i then max_i = k end
        end
        if is_array and max_i == #v then
            for i = 1, #v do
                parts[i] = serialize_value(v[i])
            end
            return '{' .. table.concat(parts, ',') .. '}'
        else
            for k, val in pairs(v) do
                local key
                if type(k) == 'number' then
                    key = '[' .. k .. ']'
                else
                    key = '["' .. tostring(k) .. '"]'
                end
                table.insert(parts, key .. '=' .. serialize_value(val))
            end
            return '{' .. table.concat(parts, ',') .. '}'
        end
    end
    return 'nil'
end

-- Fields to save per item (skip extdata/flags which are non-serializable)
local save_fields = {
    'id', 'name', 'name_log', 'count', 'description', 'category',
    'level', 'item_level', 'jobs', 'job_ids', 'slots', 'augments',
    'bag_name', 'bag_index', 'bag_id', 'type', 'skill', 'damage', 'delay',
    'shield_size', 'targets', 'cast_time', 'superior_level', 'status',
}

-- Serialize one item table
local function serialize_item(item, indent)
    indent = indent or '        '
    local parts = {}
    for _, field in ipairs(save_fields) do
        local v = item[field]
        if v ~= nil then
            table.insert(parts, indent .. '["' .. field .. '"]=' .. serialize_value(v))
        end
    end
    return '{\n' .. table.concat(parts, ',\n') .. '\n' .. indent:sub(1, -5) .. '}'
end

-- Save all bag items to disk cache
-- all_bag_items: { bag_name = { item1, item2, ... }, ... }
function inventory_cache.save(all_bag_items)
    if not windower.dir_exists(data_path) then
        windower.create_dir(data_path)
    end
    local path = get_cache_path()
    if not path then return false end

    local lines = {}
    table.insert(lines, 'return {')
    for bag_name, items in pairs(all_bag_items) do
        table.insert(lines, '    ["' .. bag_name .. '"]={')
        for _, item in ipairs(items) do
            table.insert(lines, '        ' .. serialize_item(item, '            ') .. ',')
        end
        table.insert(lines, '    },')
    end
    table.insert(lines, '}')

    local f = io.open(path, 'w+')
    if f then
        f:write(table.concat(lines, '\n'))
        f:close()
        return true
    end
    return false
end

-- Load cached inventory from disk
-- Returns { bag_name = { items... }, ... } or nil
function inventory_cache.load()
    local path = get_cache_path()
    if not path then return nil end

    local loader, err = loadfile(path)
    if not loader then return nil end

    local ok, data = pcall(loader)
    if not ok or type(data) ~= 'table' then return nil end
    return data
end

-- Compare two flat sorted item arrays by position
-- Returns { changed = bool, changed_indices = { [idx] = true } }
function inventory_cache.diff(old_items, new_items)
    local changed_indices = {}
    local changed = false
    local max_len = math.max(#old_items, #new_items)

    for i = 1, max_len do
        local old = old_items[i]
        local new = new_items[i]
        local old_id = old and old.id or 0
        local new_id = new and new.id or 0
        local old_bag = old and old.bag_index or 0
        local new_bag = new and new.bag_index or 0
        if old_id ~= new_id or old_bag ~= new_bag then
            changed_indices[i] = true
            changed = true
        end
    end

    return { changed = changed, changed_indices = changed_indices }
end

return inventory_cache
