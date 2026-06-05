-- =============================================================================
-- base_stats.lua
--
-- Look up an item's BASE stats (the values printed in the in-game description)
-- by name. Data source: data/item_stats.json -- a one-shot extract from
-- LandSandBoat's modifier.h + item_basic.sql + item_mods.sql + Windower's
-- res/items.lua for display names. See FFXIChecklist-Data\extract_item_stats.py
-- in the user's Documents folder for the generator.
--
-- Why this exists: GSUI's stat_parser was originally meant to scan
-- item_def.description text + augments. res.items has NO description field
-- though -- it has always been nil -- so the Total panel was effectively
-- augment-only. This module fills in the base-stat numbers from the same
-- authoritative source the FFXI server uses.
--
-- Public API:
--   base_stats.lookup(item_name)  -> { gsui_stat_key = value, ... } | nil
--   base_stats.is_loaded()        -> bool
--
-- Caller stays decoupled from the on-disk JSON shape: this module owns the
-- translation from LSB modifier names to GSUI stat_def keys and the scaling
-- rules for percent-style mods.
-- =============================================================================

local base_stats = {}

local json
local lazy_loaded = false
local stats_by_name = {}     -- en-form display name -> { LSB_NAME = int, ... }
local aliases = {}           -- enl-form -> en-form

-- --------------------------------------------------------------------------
-- LSB modifier -> GSUI stat key translation.
-- Scale field is the divisor applied to LSB value before adding into GSUI.
-- Most stats are stored as raw int in LSB; a handful (HASTE_GEAR, DMG family)
-- use a x100 scaling where 800 = 8.00%. See LSB modifier.h comments
-- "10000 base, 375 = 3.75%" for the canonical examples.
-- --------------------------------------------------------------------------
local LSB_TO_GSUI = {
    -- Core defense
    DEF                       = { key = 'def',          scale = 1 },
    HP                        = { key = 'hp',           scale = 1 },
    MP                        = { key = 'mp',           scale = 1 },
    HPP                       = { key = 'hp',           scale = 1 },   -- HP% bonus folds into HP slot
    MPP                       = { key = 'mp',           scale = 1 },
    -- Base stats
    STR                       = { key = 'str',          scale = 1 },
    DEX                       = { key = 'dex',          scale = 1 },
    VIT                       = { key = 'vit',          scale = 1 },
    AGI                       = { key = 'agi',          scale = 1 },
    INT                       = { key = 'int',          scale = 1 },
    MND                       = { key = 'mnd',          scale = 1 },
    CHR                       = { key = 'chr',          scale = 1 },
    -- Offense
    ACC                       = { key = 'acc',          scale = 1 },
    ATT                       = { key = 'atk',          scale = 1 },
    RACC                      = { key = 'ranged_acc',   scale = 1 },
    RATT                      = { key = 'ranged_atk',   scale = 1 },
    MACC                      = { key = 'macc',         scale = 1 },
    MATT                      = { key = 'mab',          scale = 1 },
    -- Evasion / defense extras
    EVA                       = { key = 'evasion',      scale = 1 },
    MEVA                      = { key = 'meva',         scale = 1 },
    MDEF                      = { key = 'mdef',         scale = 1 },
    -- Damage-taken (percent stored x100: 800 -> 8.00%)
    DMG                       = { key = 'dt',           scale = 100, abs = true },
    DMGPHYS                   = { key = 'pdt',          scale = 100, abs = true },
    DMGMAGIC                  = { key = 'mdt',          scale = 100, abs = true },
    -- Multi-attack / TP (stored as raw % integer: 6 -> 6%)
    DOUBLE_ATTACK             = { key = 'da',           scale = 1 },
    TRIPLE_ATTACK             = { key = 'ta',           scale = 1 },
    QUADRUPLE_ATTACK          = { key = 'qa',           scale = 1 },
    CRITHITRATE               = { key = 'crit',         scale = 1 },
    CRIT_DMG_INCREASE         = { key = 'crit_dmg',     scale = 1 },
    SUBTLE_BLOW               = { key = 'subtle',       scale = 1 },
    STORETP                   = { key = 'stp',          scale = 1 },
    DUAL_WIELD                = { key = 'dw',           scale = 1 },
    -- Magic burst / damage
    MAGIC_DAMAGE              = { key = 'mag_dmg',      scale = 1 },
    MAGIC_BURST_BONUS_CAPPED  = { key = 'mb_dmg',       scale = 1 },
    SKILLCHAINDMG             = { key = 'sc_dmg',       scale = 100 },
    -- Haste (LSB stores percent x100: 800 -> 8.00%)
    HASTE_GEAR                = { key = 'haste',        scale = 100 },
    -- Casting
    FASTCAST                  = { key = 'fc',           scale = 1 },
    CONSERVE_MP               = { key = 'conserve_mp',  scale = 1 },
    SPELLINTERRUPT            = { key = 'sird',         scale = 1 },
    -- Healing / utility
    REFRESH                   = { key = 'refresh',      scale = 1 },
    REGEN                     = { key = 'regen',        scale = 1 },
    CURE_POTENCY              = { key = 'cure_pot',     scale = 1 },
    -- Skills (per-school)
    HEALING                   = { key = 'healing_skill',scale = 1 },
    ENHANCE                   = { key = 'enh_skill',    scale = 1 },
    ENFEEBLE                  = { key = 'enf_skill',    scale = 1 },
    DARK                      = { key = 'dark_skill',   scale = 1 },
    BLUE                      = { key = 'blue_skill',   scale = 1 },
    SUMMONING                 = { key = 'summon_skill', scale = 1 },
    -- Misc
    ENMITY                    = { key = 'enmity',       scale = 1 },
    SNAPSHOT                  = { key = 'snapshot',     scale = 1 },
    BP_DELAY                  = { key = 'bp_delay',     scale = 1, abs = true },
    WSACC                     = { key = 'ws_acc',       scale = 1 },
    PARRY                     = { key = 'parrying',     scale = 1 },
}

-- --------------------------------------------------------------------------
-- Lazy load. First call to lookup() reads the JSON files from data/.
-- We use Windower's bundled JSON if available, else a Lua-native fallback
-- (the file is small enough to dofile() but we avoid that for safety).
-- --------------------------------------------------------------------------
local function _try_json_module()
    local ok, mod = pcall(require, 'json')   -- Windower libs/json.lua
    if ok then return mod end
    -- Fall back to Lua require 'libs/json'
    ok, mod = pcall(require, 'libs/json')
    if ok then return mod end
    return nil
end

local function _read_file(path)
    local f = io.open(path, 'r')
    if not f then return nil end
    local data = f:read('*a')
    f:close()
    return data
end

local function _load()
    if lazy_loaded then return end
    lazy_loaded = true
    json = json or _try_json_module()
    if not json then
        windower.add_to_chat(167, 'GSUI base_stats: no JSON parser found; base stats disabled.')
        return
    end
    local addon_path = windower.addon_path
    local stats_text = _read_file(addon_path .. 'data/item_stats.json')
    local alias_text = _read_file(addon_path .. 'data/item_name_aliases.json')
    if stats_text then
        local ok, parsed = pcall(json.decode, stats_text)
        if ok and type(parsed) == 'table' then stats_by_name = parsed end
    end
    if alias_text then
        local ok, parsed = pcall(json.decode, alias_text)
        if ok and type(parsed) == 'table' then aliases = parsed end
    end
end

-- --------------------------------------------------------------------------
-- Public lookup. Returns a {gsui_stat_key = numeric_value, ...} table or
-- nil if the item is unknown (caller falls through to augment-only parse).
-- --------------------------------------------------------------------------
function base_stats.lookup(item_name)
    if not item_name or item_name == '' then return nil end
    _load()
    local raw = stats_by_name[item_name]
    if not raw then
        local en = aliases[item_name]
        if en then raw = stats_by_name[en] end
    end
    if not raw then return nil end
    local out = {}
    for lsb_name, lsb_val in pairs(raw) do
        local rule = LSB_TO_GSUI[lsb_name]
        if rule then
            local v = lsb_val
            if rule.scale and rule.scale ~= 1 then
                v = math.floor(v / rule.scale + 0.5)
            end
            if rule.abs then v = math.abs(v) end
            out[rule.key] = (out[rule.key] or 0) + v
        end
    end
    return out
end

-- --------------------------------------------------------------------------
-- Raw LSB-key lookup, for callers that need the original modifier name
-- (e.g. the tooltip's "Enhances X effect" annotation, which has to query
-- LSB names like FASTCAST / REFRESH directly). Returns nil if the item
-- isn't in the JSON. Mirrors lookup() except for the LSB->GSUI conversion.
-- --------------------------------------------------------------------------
function base_stats.raw_lookup(item_name)
    if not item_name or item_name == '' then return nil end
    _load()
    local raw = stats_by_name[item_name]
    if not raw then
        local en = aliases[item_name]
        if en then raw = stats_by_name[en] end
    end
    return raw
end

function base_stats.is_loaded()
    return lazy_loaded and next(stats_by_name) ~= nil
end

return base_stats
