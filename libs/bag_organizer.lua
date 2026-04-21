local res = require('resources')
local packets = require('packets')
local scanner = require('libs/inventory_scanner')

local organizer = {}

local anywhere_bags = {
    inventory=true, wardrobe=true, wardrobe2=true, wardrobe3=true,
    wardrobe4=true, wardrobe5=true, wardrobe6=true, wardrobe7=true,
    wardrobe8=true, satchel=true, sack=true, case=true,
}
local mog_only_bags = {safe=true, safe2=true, storage=true, locker=true}

local move_queue = {}
local move_timer = 0
local MOVE_DELAY = 0.5
local in_mog_house = false

function organizer.set_mog_house(val)
    in_mog_house = val
end

-- Returns whether the player is in their mog house.
-- Prefers a live check against `windower.ffxi.get_items().safe.enabled` (ground
-- truth from the client — the Mog Safe is only `enabled` when inside the mog
-- house). Packet-based detection (0x05F BGM, 0x00A zone finish) is still wired
-- up to update the cached flag, but the live check fixes the case where GSUI
-- was loaded while already inside the mog house — neither packet fires then.
function organizer.is_in_mog_house()
    local ok, items = pcall(windower.ffxi.get_items)
    if ok and items and items.safe and items.safe.enabled ~= nil then
        in_mog_house = items.safe.enabled and true or false
        return in_mog_house
    end
    return in_mog_house
end

function organizer.is_bag_accessible(bag_name)
    if anywhere_bags[bag_name] then return true end
    return mog_only_bags[bag_name] or false
end

function organizer.is_mog_bag(bag_name)
    return mog_only_bags[bag_name] or false
end

-- Find rings/earrings with identical copies in same bag
function organizer.find_conflicts(all_bag_items)
    local conflicts = {}
    local paired = {left_ring=true, right_ring=true, left_ear=true, right_ear=true}
    for bag_name, items in pairs(all_bag_items) do
        local by_key = {}
        for _, item in ipairs(items) do
            local is_paired = false
            if item.slots then
                for _, slot in ipairs(item.slots) do
                    if paired[slot] then is_paired = true; break end
                end
            end
            if is_paired then
                local aug_str = item.augments and table.concat(item.augments, '|') or 'none'
                local key = item.id .. ':' .. aug_str
                by_key[key] = by_key[key] or {}
                table.insert(by_key[key], item)
            end
        end
        for _, group in pairs(by_key) do
            if #group > 1 then
                table.insert(conflicts, {bag=bag_name, items=group, name=group[1].name})
            end
        end
    end
    return conflicts
end

-- Find non-equipment items scattered across multiple bags
function organizer.find_scattered(all_bag_items)
    local locations = {}
    for bag_name, items in pairs(all_bag_items) do
        for _, item in ipairs(items) do
            if not item.slots or #item.slots == 0 then
                if not locations[item.id] then
                    locations[item.id] = {name=item.name, bags={}}
                end
                locations[item.id].bags[bag_name] = (locations[item.id].bags[bag_name] or 0) + item.count
            end
        end
    end
    local scattered = {}
    for id, info in pairs(locations) do
        local n = 0
        for _ in pairs(info.bags) do n = n + 1 end
        if n > 1 then
            table.insert(scattered, {id=id, name=info.name, bags=info.bags})
        end
    end
    table.sort(scattered, function(a, b) return a.name < b.name end)
    return scattered
end

-- Queue an item move between bags
function organizer.queue_move(src_bag, src_index, dest_bag, count)
    table.insert(move_queue, {
        src_bag=src_bag, src_index=src_index,
        dest_bag=dest_bag, count=count,
    })
end

-- Process one move per tick with throttle
function organizer.process_queue()
    if #move_queue == 0 then return false end
    if os.clock() - move_timer < MOVE_DELAY then return true end
    local move = table.remove(move_queue, 1)
    local bag_ids = scanner.get_all_bag_ids()
    local src_id = bag_ids[move.src_bag]
    local dest_id = bag_ids[move.dest_bag]
    if src_id and dest_id then
        local p = packets.new('outgoing', 0x029)
        p['Count'] = move.count
        p['Bag'] = src_id
        p['Target Bag'] = dest_id
        p['Current Index'] = move.src_index
        p['Target Index'] = 0x52
        packets.inject(p)
    end
    move_timer = os.clock()
    return #move_queue > 0
end

function organizer.is_moving()
    return #move_queue > 0
end

function organizer.clear_queue()
    move_queue = {}
end

function organizer.get_queue_count()
    return #move_queue
end

return organizer
