-- Safe text patcher for GearSwap set assignments.
-- Bundled under GSUI/libs/gear_tree/ — the original GearTree addon uses
-- a flat require path, so we point at the sibling module explicitly.

local slots = require('libs/gear_tree/gear_slots')

local writer = {}

local BACKUPS_PER_FILE = 5

local function read_file(path)
    local f, err = io.open(path, 'r')
    if not f then return nil, err end
    local src = f:read('*a')
    f:close()
    return src
end

local function write_file(path, src)
    local f, err = io.open(path, 'w+')
    if not f then return nil, err end
    f:write(src)
    f:close()
    return true
end

local function path_basename(path)
    return path:match('[^/\\]+$') or 'gear.lua'
end

local function ensure_backup_dir()
    local base = (windower and windower.addon_path) or ''
    local dir = base .. 'data/backups/'
    if windower and windower.dir_exists and not windower.dir_exists(dir) then
        windower.create_dir(dir)
    end
    return dir
end

local function cmd_quote(path)
    return '"' .. tostring(path or ''):gsub('"', ''):gsub('/', '\\') .. '"'
end

local function is_backup_for_basename(filename, basename)
    filename = tostring(filename or '')
    basename = tostring(basename or '')
    local prefix = basename .. '.'
    if filename:sub(1, #prefix) ~= prefix then return false end

    local suffix = filename:sub(#prefix + 1)
    return suffix:match('^%d%d%d%d%d%d%d%d_%d%d%d%d%d%d%.bak$') ~= nil
        or suffix:match('^%d%d%d%d%d%d%d%d_%d%d%d%d%d%d%.%d+%.bak$') ~= nil
end

local function cleanup_old_backups(path)
    -- Keep only the newest few backups for this Lua filename. This is best-effort:
    -- save safety is more important than cleanup, so errors here are ignored.
    if not io.popen or not os.remove then return end

    local dir = ensure_backup_dir()
    local basename = path_basename(path)
    local command = 'cmd /c dir /b /a-d ' .. cmd_quote(dir .. basename .. '.*.bak') .. ' 2>nul'

    local ok, pipe = pcall(io.popen, command)
    if not ok or not pipe then return end

    local backups = {}
    for line in pipe:lines() do
        local name = tostring(line or ''):gsub('\r', ''):gsub('^%s+', ''):gsub('%s+$', '')
        local filename = name:match('[^/\\]+$') or name
        if is_backup_for_basename(filename, basename) then
            backups[#backups + 1] = {
                name = filename,
                path = dir .. filename,
            }
        end
    end
    pipe:close()

    table.sort(backups, function(a, b)
        return tostring(a.name) > tostring(b.name)
    end)

    for i = BACKUPS_PER_FILE + 1, #backups do
        pcall(os.remove, backups[i].path)
    end
end

local function backup_file(path, src)
    local dir = ensure_backup_dir()
    local stem = dir .. path_basename(path) .. '.' .. os.date('%Y%m%d_%H%M%S')
    local backup = stem .. '.bak'
    local n = 2
    while true do
        local existing = io.open(backup, 'r')
        if not existing then break end
        existing:close()
        backup = stem .. '.' .. n .. '.bak'
        n = n + 1
    end
    local ok, err = write_file(backup, src)
    if not ok then return nil, err end
    cleanup_old_backups(path)
    return backup
end

local function is_space(c)
    return c and c:match('%s')
end

local function skip_string(src, i)
    local quote = src:sub(i, i)
    i = i + 1
    while i <= #src do
        local c = src:sub(i, i)
        if c == '\\' then
            i = i + 2
        elseif c == quote then
            return i + 1
        else
            i = i + 1
        end
    end
    return i
end

local function skip_comment(src, i)
    if src:sub(i, i + 1) ~= '--' then return i end
    if src:sub(i, i + 3) == '--[[' then
        local close = src:find(']]', i + 4, true)
        return close and close + 2 or #src + 1
    end
    local nl = src:find('\n', i + 2, true)
    return nl or #src + 1
end

local function skip_ws_comments(src, i, limit)
    while i <= limit do
        local c = src:sub(i, i)
        if is_space(c) then
            i = i + 1
        elseif src:sub(i, i + 1) == '--' then
            i = skip_comment(src, i)
        else
            break
        end
    end
    return i
end

local function find_matching(src, start, open, close)
    local depth = 0
    local i = start
    while i <= #src do
        local c = src:sub(i, i)
        if c == '"' or c == "'" then
            i = skip_string(src, i)
        elseif src:sub(i, i + 1) == '--' then
            i = skip_comment(src, i)
        elseif c == open then
            depth = depth + 1
            i = i + 1
        elseif c == close then
            depth = depth - 1
            if depth == 0 then return i end
            i = i + 1
        else
            i = i + 1
        end
    end
    return nil
end

local function trim_range(src, first, last)
    while first <= last and is_space(src:sub(first, first)) do first = first + 1 end
    while last >= first and is_space(src:sub(last, last)) do last = last - 1 end
    return first, last
end

local function parse_table_fields(src, body_start, body_end)
    local fields = {}
    local i = body_start
    while i <= body_end do
        i = skip_ws_comments(src, i, body_end)
        while src:sub(i, i) == ',' do
            i = skip_ws_comments(src, i + 1, body_end)
        end
        if i > body_end then break end

        local key_start = i
        local c = src:sub(i, i)
        local key

        if c == '[' then
            i = skip_ws_comments(src, i + 1, body_end)
            local quote = src:sub(i, i)
            if quote == '"' or quote == "'" then
                local key_parts = {}
                i = i + 1
                while i <= body_end do
                    local ch = src:sub(i, i)
                    if ch == '\\' and i < body_end then
                        key_parts[#key_parts + 1] = src:sub(i + 1, i + 1)
                        i = i + 2
                    elseif ch == quote then
                        i = i + 1
                        break
                    else
                        key_parts[#key_parts + 1] = ch
                        i = i + 1
                    end
                end
                i = skip_ws_comments(src, i, body_end)
                if src:sub(i, i) == ']' then
                    key = table.concat(key_parts)
                    i = i + 1
                else
                    key = nil
                end
            end
        elseif c:match('[%a_]') then
            i = i + 1
            while i <= body_end and src:sub(i, i):match('[%w_]') do
                i = i + 1
            end
            key = src:sub(key_start, i - 1)
        end

        if not key then
            i = key_start + 1
        else
            i = skip_ws_comments(src, i, body_end)
            if src:sub(i, i) ~= '=' then
                i = i + 1
            else
                i = skip_ws_comments(src, i + 1, body_end)
                local val_start = i
                local depth_p, depth_b, depth_c = 0, 0, 0
                while i <= body_end do
                    local ch = src:sub(i, i)
                    if ch == '"' or ch == "'" then
                        i = skip_string(src, i)
                    elseif src:sub(i, i + 1) == '--' then
                        i = skip_comment(src, i)
                    elseif ch == '(' then
                        depth_p = depth_p + 1
                        i = i + 1
                    elseif ch == ')' then
                        depth_p = depth_p - 1
                        i = i + 1
                    elseif ch == '[' then
                        depth_b = depth_b + 1
                        i = i + 1
                    elseif ch == ']' then
                        depth_b = depth_b - 1
                        i = i + 1
                    elseif ch == '{' then
                        depth_c = depth_c + 1
                        i = i + 1
                    elseif ch == '}' then
                        depth_c = depth_c - 1
                        i = i + 1
                    elseif ch == ',' and depth_p == 0 and depth_b == 0 and depth_c == 0 then
                        break
                    else
                        i = i + 1
                    end
                end
                local val_first, val_last = trim_range(src, val_start, i - 1)
                fields[#fields + 1] = {
                    key = key,
                    canonical = slots.canonical(key),
                    key_start = key_start,
                    key_end = key_start + #key - 1,
                    val_start = val_first,
                    val_end = val_last,
                }
            end
        end
    end
    return fields
end

local function apply_edits(src, edits)
    table.sort(edits, function(a, b) return a.start > b.start end)
    for _, edit in ipairs(edits) do
        src = src:sub(1, edit.start - 1) .. edit.text .. src:sub(edit.finish + 1)
    end
    return src
end

local function quote_double(s)
    return '"' .. tostring(s):gsub('\\', '\\\\'):gsub('"', '\\"') .. '"'
end

local function quote_single(s)
    return "'" .. tostring(s):gsub('\\', '\\\\'):gsub("'", "\\'") .. "'"
end

local function serialize_item(item)
    if not item or item.empty then return 'empty' end
    if item.augments and #item.augments > 0 then
        local augments = {}
        for _, augment in ipairs(item.augments) do
            augments[#augments + 1] = quote_single(augment)
        end
        return '{ name=' .. quote_double(item.name) .. ', augments={' .. table.concat(augments, ',') .. '} }'
    end
    return quote_double(item.name)
end

local function table_indent(src, open_pos, close_pos)
    local body = src:sub(open_pos + 1, close_pos - 1)
    local indent = body:match('\n([ \t]*)[%a_][%w_]*%s*=')
    if indent then return indent end

    local before_open = src:sub(1, open_pos)
    local line_indent = before_open:match('\n([ \t]*)[^\n]*$') or ''
    return line_indent .. '    '
end

local function close_indent(src, close_pos)
    local before_close = src:sub(1, close_pos - 1)
    return before_close:match('\n([ \t]*)[^\n]*$') or ''
end

local function build_inline_table(changes)
    local parts = {}
    for _, slot in ipairs(slots.ordered_changes(changes)) do
        parts[#parts + 1] = slot .. '=' .. serialize_item(changes[slot])
    end
    return '{' .. table.concat(parts, ', ') .. '}'
end

-- Strip Lua line-comments so we can check the last meaningful char of a
-- table body. Bug we're fixing: the previous "does the body already end
-- in a comma?" check looked at the raw last char, which for a body like
--     `feet = "Inyan. Crackows +2",        -- Acc+42, Crit+6%, Haste+3%`
-- was '%' (from Haste+3%) -- so the writer prepended ANOTHER ',' before
-- its new field, producing `,\n,\nammo=...` which Lua refuses to parse.
local function _strip_line_comments(s)
    -- Block comments `--[[...]]` are intentionally NOT stripped -- the
    -- writer doesn't expect to see them mid-table and we don't want to
    -- accidentally eat through one.
    return (s:gsub('%-%-[^\n]*', ''))
end

local function build_table_additions(src, open_pos, close_pos, changes, handled)
    local parts = {}
    for _, slot in ipairs(slots.ordered_changes(changes)) do
        if not handled[slot] then
            parts[#parts + 1] = slot .. '=' .. serialize_item(changes[slot]) .. ','
        end
    end
    if #parts == 0 then return nil end

    local body = src:sub(open_pos + 1, close_pos - 1)
    -- Comment-stripped view for the "needs leading comma?" decision.
    local trimmed = _strip_line_comments(body):gsub('%s+$', '')
    local separator = trimmed ~= '' and trimmed:sub(-1) ~= ',' and ',' or ''
    if body:find('\n', 1, true) then
        local indent = table_indent(src, open_pos, close_pos)
        local closing = close_indent(src, close_pos)
        return separator .. '\n' .. indent .. table.concat(parts, '\n' .. indent) .. '\n' .. closing
    end
    return (separator ~= '' and separator .. ' ' or '') .. table.concat(parts, ' ')
end

local function update_table_at(src, open_pos, close_pos, changes)
    local fields = parse_table_fields(src, open_pos + 1, close_pos - 1)
    local handled = {}
    local edits = {}

    for _, field in ipairs(fields) do
        local canonical = slots.canonical(field.key)
        if changes[canonical] and not handled[canonical] then
            edits[#edits + 1] = {
                start = field.val_start,
                finish = field.val_end,
                text = serialize_item(changes[canonical]),
            }
            handled[canonical] = true
        end
    end

    local additions = build_table_additions(src, open_pos, close_pos, changes, handled)
    if additions then
        edits[#edits + 1] = { start = close_pos, finish = close_pos - 1, text = additions }
    end

    if #edits == 0 then return src end
    return apply_edits(src, edits)
end

local function parse_args(src, body_start, body_end)
    local args = {}
    local start = body_start
    local i = body_start
    local depth_p, depth_b, depth_c = 0, 0, 0
    while i <= body_end do
        local c = src:sub(i, i)
        if c == '"' or c == "'" then
            i = skip_string(src, i)
        elseif src:sub(i, i + 1) == '--' then
            i = skip_comment(src, i)
        elseif c == '(' then
            depth_p = depth_p + 1
            i = i + 1
        elseif c == ')' then
            depth_p = depth_p - 1
            i = i + 1
        elseif c == '[' then
            depth_b = depth_b + 1
            i = i + 1
        elseif c == ']' then
            depth_b = depth_b - 1
            i = i + 1
        elseif c == '{' then
            depth_c = depth_c + 1
            i = i + 1
        elseif c == '}' then
            depth_c = depth_c - 1
            i = i + 1
        elseif c == ',' and depth_p == 0 and depth_b == 0 and depth_c == 0 then
            local first, last = trim_range(src, start, i - 1)
            if first <= last then args[#args + 1] = { start = first, finish = last } end
            start = i + 1
            i = i + 1
        else
            i = i + 1
        end
    end
    local first, last = trim_range(src, start, body_end)
    if first <= last then args[#args + 1] = { start = first, finish = last } end
    return args
end

local function first_non_space(src, first, last)
    return skip_ws_comments(src, first, last)
end

-- gs_export-exact slot order. /gs export emits slots in this sequence;
-- any slot missing from `changes` is omitted entirely (which is how the
-- user removes a slot -- empty grid slot -> no field in the output).
local _GS_EXPORT_ORDER = {
    'main', 'sub', 'range', 'ammo',
    'head', 'body', 'hands', 'legs', 'feet',
    'neck', 'waist', 'left_ear', 'right_ear', 'left_ring', 'right_ring',
    'back',
}

-- Serialize one slot the way /gs export does:
--   bare item        ->  slot="Name"
--   augmented item   ->  slot={ name="Name", augments={'aug1','aug2',}}
-- Note the trailing comma INSIDE the augments table -- gs_export emits it,
-- and we match that exactly so files round-trip clean.
local function _gs_export_serialize(slot, item)
    if not item or item.empty then return nil end
    if item.augments and #item.augments > 0 then
        local augs = {}
        for _, a in ipairs(item.augments) do augs[#augs+1] = quote_single(a) end
        return slot .. '={ name=' .. quote_double(item.name)
            .. ', augments={' .. table.concat(augs, ',') .. ',}}'
    end
    return slot .. '=' .. quote_double(item.name)
end

-- Build the body of a sets.<name> = { ... } block in /gs export's exact
-- format. Indent comes from the surrounding file so the result blends in.
local function _build_gs_export_body(changes, indent)
    indent = indent or '    '
    local lines = {}
    local seen = {}
    for _, slot in ipairs(_GS_EXPORT_ORDER) do
        local item = changes[slot]
        if item and item.name and item.name ~= '' then
            lines[#lines+1] = indent .. _gs_export_serialize(slot, item) .. ','
            seen[slot] = true
        end
    end
    -- Any caller-supplied slot we don't know about gets appended after the
    -- standard slots so we don't silently lose data.
    for slot, item in pairs(changes) do
        if not seen[slot] and item and item.name and item.name ~= '' then
            lines[#lines+1] = indent .. _gs_export_serialize(slot, item) .. ','
        end
    end
    return table.concat(lines, '\n')
end

local function patch_table_assignment(src, assignment, changes)
    local open_pos = first_non_space(src, assignment.rhs_start, assignment.rhs_end)
    if src:sub(open_pos, open_pos) ~= '{' then
        return nil, 'Could not locate the table for this set.'
    end
    local close_pos = find_matching(src, open_pos, '{', '}')
    if not close_pos then return nil, 'Could not find the end of this set table.' end

    -- WHOLE-BLOCK REPLACEMENT (gs_export format).
    -- User explicit ask: "rewrite of the gear set when clicking update gear"
    -- so we no longer surgically patch individual fields. The grid IS the
    -- new set definition: any slot the user removed disappears from the
    -- file, and we emit in the canonical /gs export slot order. Comments
    -- inside the set block are intentionally dropped -- they routinely went
    -- stale (e.g. the WHM file's "-- Acc+44, STP+6" notes survived an Aya
    -- -> Inyanga swap and started lying).
    local indent = table_indent(src, open_pos, close_pos)
    local closing_indent = close_indent(src, close_pos)
    local body = _build_gs_export_body(changes, indent)
    local replacement = '{\n' .. body .. '\n' .. closing_indent .. '}'

    return apply_edits(src, {
        { start = open_pos, finish = close_pos, text = replacement },
    })
end

local function patch_combine_assignment(src, assignment, changes)
    local open_pos = src:find('(', assignment.rhs_start, true)
    if not open_pos or open_pos > assignment.rhs_end then
        return nil, 'Could not locate set_combine arguments.'
    end
    local close_pos = find_matching(src, open_pos, '(', ')')
    if not close_pos then return nil, 'Could not find the end of set_combine().' end

    local args = parse_args(src, open_pos + 1, close_pos - 1)
    local table_arg
    for _, arg in ipairs(args) do
        local arg_start = first_non_space(src, arg.start, arg.finish)
        if src:sub(arg_start, arg_start) == '{' then
            table_arg = { open = arg_start, close = find_matching(src, arg_start, '{', '}') }
        end
    end

    if table_arg and table_arg.close then
        return update_table_at(src, table_arg.open, table_arg.close, changes)
    end

    local prefix = (#args > 0) and ', ' or ''
    return apply_edits(src, {
        { start = close_pos, finish = close_pos - 1, text = prefix .. build_inline_table(changes) },
    })
end

local function patch_ref_assignment(src, assignment, changes)
    local rhs = src:sub(assignment.rhs_start, assignment.rhs_end):gsub('%s+$', '')
    local replacement = 'set_combine(' .. rhs .. ', ' .. build_inline_table(changes) .. ')'
    return apply_edits(src, {
        { start = assignment.rhs_start, finish = assignment.rhs_end, text = replacement },
    })
end

function writer.save(path, assignment, changes)
    if not assignment or not assignment.rhs then
        return nil, 'No editable set is selected.'
    end

    local src, read_err = read_file(path)
    if not src then return nil, read_err end

    local patched, patch_err
    if assignment.rhs.kind == 'table' then
        patched, patch_err = patch_table_assignment(src, assignment, changes)
    elseif assignment.rhs.kind == 'combine' then
        patched, patch_err = patch_combine_assignment(src, assignment, changes)
    elseif assignment.rhs.kind == 'ref' then
        patched, patch_err = patch_ref_assignment(src, assignment, changes)
    else
        return nil, 'This set is dynamic or unsupported, so GearTree will not rewrite it yet.'
    end

    if not patched then return nil, patch_err end
    if patched == src then
        return { changed = false }
    end

    local backup, backup_err = backup_file(path, src)
    if not backup then return nil, 'Could not create backup: ' .. tostring(backup_err) end

    local ok, write_err = write_file(path, patched)
    if not ok then return nil, write_err end

    return {
        changed = true,
        backup = backup,
    }
end

return writer
