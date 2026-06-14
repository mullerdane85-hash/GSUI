--[[
Sets controller — pure data + save layer for GSUI's GearTree integration.

This module is intentionally headless. It does NOT draw any windows or
own any text/image primitives. Rendering of the sets list happens inside
GSUI's main ui_renderer.lua, alongside everything else in the GearSwap
tab. The controller only:

  * locates and parses the player's active GearSwap .lua file
  * holds the resulting tree of sets
  * resolves a node's slot contents for display
  * writes per-slot edits back to disk via writer.save (with .bak backup)

API summary (called from gsui.lua):

  open(player, job)        → bool ok      -- load + parse the GS file
  refresh()                → bool ok      -- re-read + re-parse
  get_tree()               → root node    -- nil if not loaded
  get_assignments()        → list         -- raw parser output
  get_file_info()          → { path, name }
  get_error()              → string|nil
  preview_for(node)        → list[{slot,value}]
  save_changes(node, changes) → bool ok, string err
                                          -- changes: { [slot]={name=...} }
]]

local parser   = require('libs/gear_tree/parser')
local tree_mod = require('libs/gear_tree/tree')
local writer   = require('libs/gear_tree/writer')
local locator  = require('libs/gear_tree/locator')

local controller = {}

local state = {
    file_path   = nil,
    file_name   = nil,
    raw_text    = nil,
    assignments = nil,
    tree        = nil,
    last_error  = nil,
    -- Local variable table — populated at open() by scanning the raw text
    -- for `local <name> = { key = "value", ... }` blocks. Used by
    -- resolve_value() so that slot expressions like `vanya.head` can be
    -- resolved to their actual item name when loading a set's contents
    -- into the equipment grid. Without this, set_combine-based sets
    -- (the common GearSwap pattern) appear empty.
    locals      = nil,
}

-- =============================================================================
-- Local-variable extractor + resolver
-- =============================================================================
-- Find every top-level `local NAME = { ... }` block in the source text and
-- parse the inner key="value" pairs. Stored as locals[NAME][field] = value.
-- Handles inline string literals and nested `name="..."` table notation;
-- doesn't try to resolve nested references — keeps it simple. Good enough
-- for the common GearSwap idiom of  local vanya = { head="Vanya Hood +1", ... }
local function find_matching_brace(src, open_pos)
    local depth = 0
    local i = open_pos
    while i <= #src do
        local c = src:sub(i, i)
        if c == '{' then depth = depth + 1
        elseif c == '}' then
            depth = depth - 1
            if depth == 0 then return i end
        elseif c == '"' or c == "'" then
            local q = c
            i = i + 1
            while i <= #src do
                local sc = src:sub(i, i)
                if sc == '\\' then i = i + 2
                elseif sc == q then break
                else i = i + 1 end
            end
        end
        i = i + 1
    end
    return nil
end

local function parse_local_table_body(body)
    local out = {}
    local i = 1
    while i <= #body do
        local _, ke, key = body:find('([%w_]+)%s*=%s*', i)
        if not ke then break end
        i = ke + 1
        -- skip whitespace
        while i <= #body and body:sub(i, i):match('%s') do i = i + 1 end
        local c = body:sub(i, i)
        if c == '"' or c == "'" then
            local q = c
            local val_start = i + 1
            i = i + 1
            while i <= #body do
                local sc = body:sub(i, i)
                if sc == '\\' then i = i + 2
                elseif sc == q then break
                else i = i + 1 end
            end
            out[key] = body:sub(val_start, i - 1)
            i = i + 1
        elseif c == '{' then
            -- Inline table — look for `name = "..."` inside
            local close = find_matching_brace(body, i)
            if not close then break end
            local sub = body:sub(i + 1, close - 1)
            local inner_name = sub:match('name%s*=%s*"([^"]+)"')
                            or sub:match("name%s*=%s*'([^']+)'")
            if inner_name then out[key] = inner_name end
            i = close + 1
        else
            -- Skip to next comma
            while i <= #body and body:sub(i, i) ~= ',' do i = i + 1 end
        end
    end
    return out
end

local function extract_locals(src)
    local locals = {}
    local i = 1
    while i <= #src do
        local s, e, name = src:find('local%s+([%w_]+)%s*=%s*{', i)
        if not s then break end
        local close = find_matching_brace(src, e)
        if not close then break end
        local body = src:sub(e + 1, close - 1)
        locals[name] = parse_local_table_body(body)
        i = close + 1
    end
    return locals
end

-- Public: resolve a raw RHS expression string (as captured by the parser)
-- to an actual item name where possible. Supported forms:
--   "Foo"                  → Foo
--   'Foo'                  → Foo
--   var.field              → resolved via state.locals[var][field]
--   { name = "Foo", ... }  → Foo
--   <anything else>        → raw expression returned as-is
function controller.resolve_value(raw)
    if not raw then return nil end
    if type(raw) ~= 'string' then return raw end
    local s = raw:gsub('^%s+', ''):gsub('%s+$', '')
    if s == '' then return nil end

    -- 1. Bare string literal
    local lit = s:match('^"(.-)"$') or s:match("^'(.-)'$")
    if lit then return lit end

    -- 2. Inline table with name field
    local nm = s:match('name%s*=%s*"([^"]+)"') or s:match("name%s*=%s*'([^']+)'")
    if nm then return nm end

    -- 3. Local var reference: var.field
    local var, field = s:match('^([%w_]+)%.([%w_]+)$')
    if var and field and state.locals and state.locals[var] then
        local v = state.locals[var][field]
        if v then return v end
    end

    return s
end

-- Pull the augments list out of a raw slot-value source string. Returns
-- a list of trimmed augment-line strings, or nil if the slot didn't
-- declare any augments (bare-name form like `back = "Alaunus's Cape"`
-- or a local-var reference). Used by gsui to disambiguate same-named
-- inventory items at load time -- without this, "Alaunus's Cape" with
-- three augment variants in inventory would match the first one the
-- inventory scan returned, which had nothing to do with what the lua
-- specified. Symptom: click a set, see a different cape than the lua
-- declares + no augments in the tooltip even though the inventory item
-- hover shows them.
--
-- Handles:
--   { name="X", augments={'a','b','c'} }
--   { name='X', augments={"a","b","c"} }
--   var.field   -- looks up state.locals[var][field].augments
-- Whitespace between augments and across the brace is tolerated.
function controller.resolve_augments(raw)
    if not raw then return nil end
    if type(raw) == 'table' then return raw.augments end
    if type(raw) ~= 'string' then return nil end
    local s = raw:gsub('^%s+', ''):gsub('%s+$', '')

    -- 1. Inline table with augments={...} field
    local body = s:match('augments%s*=%s*{(.-)}')
    if body then
        local augs = {}
        -- Match `'...'` or `"..."` and grab the contents. The first
        -- capture group is the quote char (we use it to know which
        -- escape to unescape), the second is the literal string body.
        for q, content in body:gmatch('(["\'])(.-)%1') do
            -- q is the quote char (', "); content is the augment line.
            -- Unescape only the embedded same-quote: GS writer emits
            -- `\'` inside single-quoted strings.
            local clean = content
            if q == "'" then clean = clean:gsub("\\'", "'") end
            if q == '"' then clean = clean:gsub('\\"', '"') end
            augs[#augs + 1] = clean
        end
        if #augs > 0 then return augs end
        return nil
    end

    -- 2. Local-var reference (e.g. `alaunus_tp`) -- look up the augments
    -- field on the local table. Handles both `varname` and `var.field`.
    local var = s:match('^([%w_]+)$')
    if var and state.locals and state.locals[var] then
        local v = state.locals[var]
        if type(v) == 'table' and v.augments then return v.augments end
    end
    local var2, field = s:match('^([%w_]+)%.([%w_]+)$')
    if var2 and field and state.locals and state.locals[var2] then
        local v = state.locals[var2][field]
        if type(v) == 'table' and v.augments then return v.augments end
    end

    return nil
end

-- =============================================================================
-- Load / refresh
-- =============================================================================
function controller.open(player, job)
    state.last_error = nil
    local found = locator.find_active(player, job)
    if not found then
        state.last_error = ('No GearSwap file found for %s / %s in %s'):format(
            tostring(player), tostring(job), locator.data_dir())
        return false
    end
    state.file_path, state.file_name = found.path, found.filename

    local f, err = io.open(found.path, 'r')
    if not f then
        state.last_error = 'Could not open ' .. found.path .. ': ' .. tostring(err)
        return false
    end
    state.raw_text = f:read('*a')
    f:close()

    local ok, parsed = pcall(parser.parse, state.raw_text)
    if not ok or not parsed then
        state.last_error = 'Parse error: ' .. tostring(parsed)
        return false
    end
    state.assignments = parsed
    state.tree        = tree_mod.build(parsed)
    -- Extract local-var gear collections (e.g. `local vanya = {head=...}`)
    -- so click_handler can resolve `vanya.head` style references when it
    -- loads a set into the equipment grid.
    state.locals = extract_locals(state.raw_text)
    -- Expand everything by default so the user sees all sets at a glance.
    tree_mod.expand_all(state.tree)
    return true
end

function controller.refresh()
    if not state.file_path then return false end
    local p = windower.ffxi.get_player() or {}
    return controller.open(p.name, p.main_job)
end

-- =============================================================================
-- Accessors
-- =============================================================================
function controller.get_tree()        return state.tree        end
function controller.get_assignments() return state.assignments end
function controller.get_error()       return state.last_error  end
function controller.get_file_info()
    return { path = state.file_path, name = state.file_name }
end

-- Resolve a tree node's gear contents into a sorted list of {slot, value}
-- entries. Re-exported from tree.lua so gsui doesn't need to know about
-- tree_mod directly.
function controller.preview_for(node)
    if not node then return {} end
    return tree_mod.gear_preview(node) or {}
end

-- =============================================================================
-- Save: write per-slot changes back to the .lua file via writer.save
-- =============================================================================
-- `node` is a tree node with .assignment set (i.e. a leaf with gear).
-- `changes` is a map of slot_name → either a string (item name) or a
-- table { name = "Foo", augments = {...} } or { empty = true }.
-- Returns (true, nil) on success, (false, errmsg) on failure.
function controller.save_changes(node, changes)
    if not node or not node.has_gear or not node.assignment then
        return false, 'No editable set selected.'
    end
    if not state.file_path then
        return false, 'No GearSwap file loaded.'
    end
    -- Normalize changes: writer.serialize_item expects each value to be
    -- a table with .name (or .empty). Strings get wrapped.
    local normalized = {}
    for slot, val in pairs(changes) do
        if type(val) == 'string' then
            normalized[slot] = (val == '' or val:lower() == 'empty')
                and { empty = true } or { name = val }
        elseif type(val) == 'table' then
            normalized[slot] = val
        end
    end
    local result, err = writer.save(state.file_path, node.assignment, normalized)
    if not result then return false, err or 'unknown writer error' end
    -- Re-parse the file so our in-memory tree reflects what's now on disk.
    controller.refresh()
    return true
end

return controller
