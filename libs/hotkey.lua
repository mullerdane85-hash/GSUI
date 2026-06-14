-- =============================================================================
-- hotkey.lua  --  shared toggle-hotkey library for custom FFXI addons
--
-- Why this exists: each addon used to roll its own raw `register_event
-- ('keyboard', ...)` handler with a hard-coded DIK. That meant:
--   1. Bare letter keys (e.g. plain "O" for FFXIJSE) fired the addon EVEN
--      WHILE TYPING -- so chat / macro names / search bar were unusable.
--   2. Every addon had to re-implement chat-open detection by hand to
--      suppress the fire (and most got it wrong).
--   3. Re-binding required a custom //addon changekey command per addon.
--
-- This library delegates everything to Windower's built-in `bind` command,
-- which respects FFXI's text-input state for free. Each addon picks a
-- modifier (alt/ctrl/shift/none) + key, and the lib turns that into the
-- right `bind <prefix><key> input <slashcmd>` send_command.
--
-- Reserved combos -- the FFXI client claims these for itself, and binding
-- to them silently does nothing in-game (the game eats the keystroke before
-- Windower sees it). The library rejects them with a clear error message.
--   CTRL+0..9, ALT+0..9         macro slot fires
--   CTRL+`, ALT+`               macro book cycle
--   F1..F12 alone / with modifier  game UI / party targeting
-- Bare-key bindings (modifier = 'none') are accepted but warned about, since
-- they conflict with typing.
--
-- Usage in an addon:
--   local hotkey = require('libs/hotkey')
--   hotkey.bind('gsui', 'toggle', 'alt', 'g')          -- alt+g => //gsui toggle
--   -- on settings change:
--   hotkey.rebind('gsui', 'toggle', new_modifier, new_key)
--   -- on addon unload:
--   hotkey.unbind('gsui')
-- =============================================================================

local hotkey = {}

-- Prefix lookup: Windower's bind syntax uses ! for Alt, ^ for Ctrl, ~ for Shift.
-- Empty prefix = no modifier.
local MODIFIER_PREFIX = {
    none  = '',
    alt   = '!',
    ctrl  = '^',
    shift = '~',
}

-- Combos FFXI claims natively. {key_lower => {modifier => 'reason', ...}}
-- The 'any' modifier means any modifier (or none) is bad on this key.
local RESERVED = {
    -- FFXI macro slot keys: 1-0 with Ctrl or Alt fires the active macro bar
    ['1'] = { alt = 'FFXI macro slot 1', ctrl = 'FFXI macro slot 1' },
    ['2'] = { alt = 'FFXI macro slot 2', ctrl = 'FFXI macro slot 2' },
    ['3'] = { alt = 'FFXI macro slot 3', ctrl = 'FFXI macro slot 3' },
    ['4'] = { alt = 'FFXI macro slot 4', ctrl = 'FFXI macro slot 4' },
    ['5'] = { alt = 'FFXI macro slot 5', ctrl = 'FFXI macro slot 5' },
    ['6'] = { alt = 'FFXI macro slot 6', ctrl = 'FFXI macro slot 6' },
    ['7'] = { alt = 'FFXI macro slot 7', ctrl = 'FFXI macro slot 7' },
    ['8'] = { alt = 'FFXI macro slot 8', ctrl = 'FFXI macro slot 8' },
    ['9'] = { alt = 'FFXI macro slot 9', ctrl = 'FFXI macro slot 9' },
    ['0'] = { alt = 'FFXI macro slot 10', ctrl = 'FFXI macro slot 10' },
    ['`'] = { alt = 'FFXI macro book cycle', ctrl = 'FFXI macro book cycle' },
}

-- Tracks live bindings so we can clean up on unload / rebind. Keyed by
-- addon_name, points to the full "prefix+key" string we last bound to.
local _live = {}

-- Normalize and validate modifier + key inputs. Returns (modifier, key, err).
-- modifier is one of {'none','alt','ctrl','shift','off'} on success.
-- key is lowercased single character / Windower DIK name.
local function _normalize(modifier, key)
    modifier = (modifier or 'alt'):lower()
    if modifier == 'no' or modifier == 'none' or modifier == '' then
        modifier = 'none'
    end
    if modifier == 'off' or modifier == 'disabled' then
        return 'off', nil
    end
    if not MODIFIER_PREFIX[modifier] then
        return nil, nil, 'invalid modifier "' .. modifier .. '" (try alt / ctrl / shift / none / off)'
    end
    if not key or key == '' then
        return nil, nil, 'no key specified'
    end
    key = tostring(key):lower()
    -- Reserved combo check.
    local r = RESERVED[key]
    if r and r[modifier] then
        return nil, nil, modifier .. '+' .. key .. ' is reserved by FFXI: ' .. r[modifier]
    end
    -- F-key warning (we don't reject -- some users rebind them in FFXI -- but
    -- we hint the caller).
    return modifier, key
end

-- Build the Windower bind-string form: e.g. 'alt' + 'g' -> '!g'.
local function _bind_str(modifier, key)
    return MODIFIER_PREFIX[modifier] .. key
end

-- Bind the addon's toggle key. Returns (ok, message).
--   addon_name: short addon command (e.g. 'gsui', 'fj').
--   slash_arg:  argument after //<addon>, typically 'toggle' or empty.
--   modifier:   'alt' | 'ctrl' | 'shift' | 'none' | 'off'
--   key:        single char or Windower key name (lowercase preferred)
function hotkey.bind(addon_name, slash_arg, modifier, key)
    if not addon_name or addon_name == '' then
        return false, 'hotkey.bind: addon_name required'
    end
    -- Unbind any existing binding for this addon first so a rebind doesn't
    -- leave the old combo firing.
    hotkey.unbind(addon_name)
    local nmod, nkey, err = _normalize(modifier, key)
    if err then return false, err end
    if nmod == 'off' then
        return true, addon_name .. ' hotkey disabled'
    end
    local combo = _bind_str(nmod, nkey)
    local cmd = 'input //' .. addon_name
    if slash_arg and slash_arg ~= '' then cmd = cmd .. ' ' .. slash_arg end
    windower.send_command('bind ' .. combo .. ' ' .. cmd)
    _live[addon_name] = combo
    local label = (nmod == 'none' and '' or (nmod:upper() .. '+')) .. nkey:upper()
    return true, addon_name .. ' hotkey bound to ' .. label
end

-- Convenience: hotkey.rebind() is an alias for hotkey.bind() that's named
-- to clarify intent at the call site when invoked after a settings change.
hotkey.rebind = hotkey.bind

-- Remove the active binding for an addon (if any). Idempotent.
function hotkey.unbind(addon_name)
    local combo = _live[addon_name]
    if combo then
        windower.send_command('unbind ' .. combo)
        _live[addon_name] = nil
    end
end

-- Pretty-print modifier+key for chat output. Returns "ALT+G" / "F12" / "OFF".
function hotkey.display(modifier, key)
    if not modifier or modifier == 'off' then return 'OFF' end
    if modifier == 'none' or modifier == '' then return key and key:upper() or '?' end
    return modifier:upper() .. '+' .. (key and key:upper() or '?')
end

-- Parse a "/<addon> hotkey <mod> <key>" arg list. Accepts:
--   ('alt','g')           -> mod='alt', key='g'
--   ('off')               -> mod='off'
--   ('g')                 -> mod='none', key='g' (no modifier shortcut)
--   ('alt+g')             -> mod='alt', key='g' (combined form)
-- Returns (modifier, key) or (nil, nil, err).
function hotkey.parse_args(arg1, arg2)
    if not arg1 or arg1 == '' then
        return nil, nil, 'usage: hotkey <alt|ctrl|shift|none|off> <key>  -- or hotkey alt+g'
    end
    arg1 = tostring(arg1):lower()
    if arg1 == 'off' or arg1 == 'disabled' or arg1 == 'disable' then
        return 'off', nil
    end
    -- Combined form: "alt+g"
    local mod, key = arg1:match('^(%a+)%+(.+)$')
    if mod and key then return mod, key end
    -- Two-arg form
    if arg2 and arg2 ~= '' then
        return arg1, tostring(arg2):lower()
    end
    -- Single-arg form: just a key, no modifier
    return 'none', arg1
end

return hotkey
