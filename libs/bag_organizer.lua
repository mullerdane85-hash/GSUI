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

-- Returns whether ANY mog-storage bag is currently writable.
--
-- The live check reads `enabled` flags from `windower.ffxi.get_items()`.
-- Each mog-only bag's `enabled` flag is true when the server has granted
-- the client access to that bag, which happens in three situations:
--
--   * Inside the player's Mog House (all four mog bags enabled)
--   * At a Nomad Moogle (Tu'Lia, Whitegate, Adoulin, etc.) -- the bag
--     the player selected from the moogle's menu becomes enabled
--   * At a Porter Moogle -- typically Storage becomes enabled
--
-- The previous implementation only checked `items.safe.enabled`, which
-- silently blocked transfers when the user was at a Nomad Moogle and
-- selected Mog Safe 2 / Storage / Locker instead of Mog Safe.
--
-- Packet-based detection (0x05F BGM, 0x00A zone finish) still updates
-- the cached `in_mog_house` flag as a fallback for the actual mog house.
function organizer.is_in_mog_house()
    local ok, items = pcall(windower.ffxi.get_items)
    if ok and items then
        for bag in pairs(mog_only_bags) do
            if items[bag] and items[bag].enabled == true then
                in_mog_house = true
                return true
            end
        end
        in_mog_house = false
        return false
    end
    return in_mog_house
end

-- Per-bag accessibility check. Returns true if the named bag is
-- currently writable from the player's location:
--
--   * "Anywhere" bags (inventory, wardrobe1-8, satchel, sack, case)
--     are always accessible while logged in.
--   * Mog-only bags (safe, safe2, storage, locker) require either
--     standing in the mog house OR a Nomad/Porter Moogle interaction
--     that has flipped this specific bag's `enabled` flag.
--
-- This is what the gsui.lua transfer guards should consult instead of
-- the coarse is_in_mog_house() check -- it correctly allows transfers
-- to/from whichever bag the Nomad Moogle has unlocked without
-- requiring the user to be at every other mog bag's home location.
function organizer.is_bag_currently_accessible(bag_name)
    if anywhere_bags[bag_name] then return true end
    if not mog_only_bags[bag_name] then return false end
    local ok, items = pcall(windower.ffxi.get_items)
    if not ok or not items then return false end
    local bag = items[bag_name]
    if not bag then return false end
    -- If `enabled` isn't exposed for some reason, fall back to the
    -- cached mog-house flag so we don't accidentally block transfers
    -- when the client API briefly omits the field.
    if bag.enabled == nil then return in_mog_house end
    return bag.enabled == true
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

-- Queue an item move between bags.
--
-- One-leg case (src OR dest is inventory) -- uses Windower's native
-- get_item / put_item in process_queue.
--
-- Two-leg case (neither side is inventory, e.g. wardrobe -> wardrobe2,
-- satchel -> sack) -- the legacy 0x029 packet for direct bag-to-bag
-- has been silently rejected by the server since an SE update, so
-- nothing actually moved. We now SPLIT it into two queued legs that
-- both go through inventory:
--     leg 1: get_item(src_bag, src_index)   -> lands in inventory
--     leg 2: put_item(dest_bag, ???, count) <- ??? is the new inventory
--            slot, looked up by item_id at execution time because the
--            destination index isn't known until leg 1 has actually
--            run server-side.
-- item_id is therefore REQUIRED for two-leg moves so leg 2 can find
-- the item again in inventory.
function organizer.queue_move(src_bag, src_index, dest_bag, count, item_id)
    if src_bag ~= 'inventory' and dest_bag ~= 'inventory' then
        table.insert(move_queue, {
            src_bag = src_bag, src_index = src_index,
            dest_bag = 'inventory', count = count,
            item_id = item_id,
        })
        table.insert(move_queue, {
            src_bag = 'inventory', src_index = nil,
            dest_bag = dest_bag, count = count,
            item_id = item_id,
        })
    else
        table.insert(move_queue, {
            src_bag = src_bag, src_index = src_index,
            dest_bag = dest_bag, count = count,
            item_id = item_id,
        })
    end
end

-- Process one move per tick with throttle.
--
-- Windower's native item-movement API:
--   get_item(bag_id, slot, count)  -- pulls FROM `bag_id` slot INTO inventory
--   put_item(bag_id, slot, count)  -- pushes FROM inventory slot INTO `bag_id`
--
-- For a leg whose source is 'inventory' but src_index is nil, we look
-- the item up in inventory by item_id (used by the second leg of a
-- bag-to-bag move, which only knows what item it pushed to inventory
-- in the first leg). Highest-index match wins -- new arrivals to
-- inventory go to the lowest free slot, so the original copies (if
-- any) sit lower and the one we want is the most recently added.
local function find_inventory_slot(item_id)
    if not item_id then return nil end
    local items = windower.ffxi.get_items()
    if not items or not items.inventory then return nil end
    local inv = items.inventory
    local found = nil
    for i = 1, (inv.max or 80) do
        local it = inv[i]
        if it and it.id == item_id then
            found = i  -- keep walking; we want the highest matching slot
        end
    end
    return found
end

-- Max times a single queue entry can fail its precondition check
-- before we give up. With MOVE_DELAY = 0.5s, 6 retries = 3 seconds of
-- patience -- generous for normal server latency, short enough that
-- a truly stranded item isn't held in the queue forever.
local MAX_RETRIES = 6

function organizer.process_queue()
    if #move_queue == 0 then return false end
    if os.clock() - move_timer < MOVE_DELAY then return true end
    -- Bail without consuming the queue if the inventory snapshot isn't
    -- valid yet -- happens during zoning, immediately after //gs reload,
    -- and a few other client-side blackout windows. Firing get_item/
    -- put_item with a stale-slot index here has crashed Windower.
    local snap = windower.ffxi.get_items()
    if not snap or not snap.inventory or (snap.inventory.max or 0) == 0 then
        return true                          -- keep ticks coming
    end
    -- PEEK the head entry instead of popping. If the move can't fire
    -- yet (leg-2 with item not yet in inventory, leg-1 with inventory
    -- full), leave it in the queue and retry next tick. This is what
    -- keeps the throughput correct when the player has only 1-2 free
    -- inventory slots and queues 20+ bag-to-bag moves: leg 2 waits for
    -- leg 1 to actually settle on the server before firing, so each
    -- item really does cycle through inventory one at a time.
    local move = move_queue[1]
    local bag_ids = scanner.get_all_bag_ids()
    local src_id = bag_ids[move.src_bag]
    local dest_id = bag_ids[move.dest_bag]
    if not src_id or not dest_id then
        -- Unknown bag id -- can't process. Drop and move on so we
        -- don't loop forever on a bogus entry.
        table.remove(move_queue, 1)
        move_timer = os.clock()
        return #move_queue > 0
    end
    local fired = false
    if move.dest_bag == 'inventory' then
        -- Leg 1: pull from source bag into inventory. Skip without
        -- consuming if inventory is full; the next leg-2 (which empties
        -- a slot) should make room on the next tick.
        local inv_used = snap.inventory.count or 0
        local inv_max  = snap.inventory.max or 80
        if inv_used >= inv_max then
            move.retries = (move.retries or 0) + 1
            if move.retries >= MAX_RETRIES then
                table.remove(move_queue, 1)   -- give up
            end
            move_timer = os.clock()
            return #move_queue > 0
        end
        windower.ffxi.get_item(src_id, move.src_index, move.count)
        fired = true
    elseif move.src_bag == 'inventory' then
        -- Leg 2: push from inventory into dest bag. src_index may be
        -- nil if this is leg-2 of a bag-to-bag -- look up by item id.
        -- If the item isn't yet in inventory (leg 1 still in flight
        -- server-side), wait without consuming the queue entry.
        local inv_slot = move.src_index or find_inventory_slot(move.item_id)
        if inv_slot then
            windower.ffxi.put_item(dest_id, inv_slot, move.count)
            fired = true
        else
            move.retries = (move.retries or 0) + 1
            if move.retries >= MAX_RETRIES then
                table.remove(move_queue, 1)   -- give up; item stranded
            end
            move_timer = os.clock()
            return #move_queue > 0
        end
    end
    if fired then
        table.remove(move_queue, 1)
    end
    move_timer = os.clock()
    return #move_queue > 0
end

-- Stack identical items within a single bag. This is the same packet
-- the in-game "Sort" menu button sends -- the server merges all stacks
-- of the same item id in the named bag up to each item's stack cap and
-- reshuffles them to the lowest slot indices. Fire-and-forget; the
-- server pushes an inventory update packet back.
function organizer.sort_bag(bag_name)
    local bag_ids = scanner.get_all_bag_ids()
    local bag_id = bag_ids[bag_name]
    if not bag_id then return false end
    local p = packets.new('outgoing', 0x03A)
    p['Bag'] = bag_id
    packets.inject(p)
    return true
end

function organizer.is_moving()
    return #move_queue > 0
end

-- Wipe everything in the queue without sending packets. Called from
-- the zoning event handler (0x00B incoming) so we don't fire put_item
-- / get_item calls against an inventory snapshot the server has just
-- invalidated -- those calls have crashed Windower in the past.
function organizer.clear_queue()
    while #move_queue > 0 do table.remove(move_queue) end
end

function organizer.clear_queue()
    move_queue = {}
end

function organizer.get_queue_count()
    return #move_queue
end

return organizer
