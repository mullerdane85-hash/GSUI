local stat_parser = {}

local res     = require('resources')
local packets = require('packets')

-- ============================================================================
-- Player stats cache.
-- windower.ffxi.get_player() does NOT expose STR/DEX/etc. on most builds.
-- We listen for incoming packet 0x061 (Char Stats), which the server sends on
-- login, zone, gear change, buff change, etc. The cache is populated as soon
-- as the first such packet arrives. Until then, totals show gear-only.
-- ============================================================================

local cached_stats = {}    -- {str, dex, vit, agi, int, mnd, chr, max_hp, max_mp, def}

windower.register_event('incoming chunk', function(id, original)
    if id ~= 0x061 then return end
    local ok, p = pcall(packets.parse, 'incoming', original)
    if not ok or not p then return end
    cached_stats.str    = (p['Base STR'] or 0) + (p['Added STR'] or 0)
    cached_stats.dex    = (p['Base DEX'] or 0) + (p['Added DEX'] or 0)
    cached_stats.vit    = (p['Base VIT'] or 0) + (p['Added VIT'] or 0)
    cached_stats.agi    = (p['Base AGI'] or 0) + (p['Added AGI'] or 0)
    cached_stats.int    = (p['Base INT'] or 0) + (p['Added INT'] or 0)
    cached_stats.mnd    = (p['Base MND'] or 0) + (p['Added MND'] or 0)
    cached_stats.chr    = (p['Base CHR'] or 0) + (p['Added CHR'] or 0)
    cached_stats.max_hp = p['Maximum HP']
    cached_stats.max_mp = p['Maximum MP']
    cached_stats.def    = p['Defense']
    cached_stats.atk    = p['Attack']
end)

-- =============================================================================
-- Stat definitions: master list of every stat GSUI knows about, with EVERY
-- known FFXI phrasing per stat. Each entry is { key, name, cap, suffix,
-- patterns, exclude?, negative? }. Patterns are Lua patterns (not regex);
-- each captures a single numeric value via %+(%d+) / %-(%d+).
--
-- For each stat we try to cover FIVE source forms:
--
--   1. BG-Wiki / full description  ("Critical Hit Rate +N%")
--   2. In-game tooltip abbreviation ("Crit. Hit Rate +N%")
--   3. Inventory-display short     ("Crit.hit rate+N")
--   4. Augment quoted form         ('"Crit. Hit Rate"+N%')
--   5. Community shorthand         ("CHR +N%" / "MAB +N")
--
-- Pattern variants were seeded from a sweep of every augment line across
-- 40 gs_export files (user + friend's set) plus FFXI conventions documented
-- on BG-Wiki. Real-world source is noted in-line where the variant came
-- from a specific item.
-- =============================================================================
local stat_defs = {
    -- Casting
    { key = 'fc',          name = 'Fast Cast',         cap = 80,   suffix = '%',  patterns = {
        -- 1. BG-Wiki full         "Fast Cast +N%"
        'Fast Cast%s*%+(%d+)',
        -- 2. Augment quoted       '"Fast Cast"+N%'
        '"Fast Cast"%s*%+(%d+)',
        -- 3. Description form     "Spellcasting time -N%" (Loricate Torque +1 etc.)
        '[Ss]pellcasting time%s*%-(%d+)',
        '[Ss]pell casting time%s*%-(%d+)',
        -- 4. Community shorthand  "FC +N%"
        'FC%s*%+(%d+)',
    } },
    { key = 'qm',          name = 'Quick Magic',       cap = 10,   suffix = '%',  patterns = {
        'Quick Magic%s*%+(%d+)',
        '"Quick Magic"%s*%+(%d+)',
        'QM%s*%+(%d+)',
    } },
    { key = 'conserve_mp', name = 'Conserve MP',       cap = nil,  suffix = '',   patterns = {
        'Conserve MP%s*%+(%d+)',
        '"Conserve MP"%s*%+(%d+)',
    } },
    { key = 'sird',        name = 'Spell Interrupt',   cap = 100,  suffix = '%',  patterns = {
        -- 1. BG-Wiki full         "Spell interruption rate -N%"
        '[Ss]pell [Ii]nterrupt.*%s*%-(%d+)',
        -- 2. Augment text         "Spell interruption rate down +N%" (Nodens Gorget)
        'Spell interruption rate down%s*%+(%d+)',
        -- 3. Variant phrasings    "Spellcast interruption -N%"
        '[Ss]pellcast interruption%s*%-(%d+)',
        -- 4. Community shorthand  "SIRD +N%"
        'SIRD%s*%+(%d+)',
    } },
    -- Haste
    { key = 'haste',       name = 'Haste (Gear)',      cap = 26,   suffix = '%',  patterns = {'Haste%s*%+(%d+)'}, exclude = {'Pet'} },
    -- Pet / SMN
    { key = 'bp_delay',    name = 'BP Delay',          cap = nil,  suffix = '',   patterns = {'[Bb]lood [Pp]act.*[Dd]el[aey]*[ .]*%s*%-(%d+)', '[Bb]lood [Pp]act.*[Dd]el[aey]*[ .]*II? %s*%-(%d+)'} },
    { key = 'bp_dmg',      name = 'BP Damage',         cap = nil,  suffix = '',   patterns = {'[Bb]lood [Pp]act [Dd][am]g?%.?%s*%+(%d+)', '[Bb]lood [Pp]act [Dd]amage%s*%+(%d+)'} },
    { key = 'pet_haste',   name = 'Pet: Haste',        cap = nil,  suffix = '%',  patterns = {'Pet: Haste%s*%+(%d+)'} },
    { key = 'pet_atk',     name = 'Pet: Attack',       cap = nil,  suffix = '',   patterns = {'Pet: Attack%s*%+(%d+)', 'Pet: Atk%.%s*%+(%d+)'} },
    { key = 'pet_macc',    name = 'Pet: Mag. Acc.',    cap = nil,  suffix = '',   patterns = {
        'Pet: Mag%. Acc%.%s*%+(%d+)',
        -- Abbreviated form seen on Apogee gear etc.
        'Pet: M%.Acc%.%s*%+(%d+)',
    } },
    { key = 'pet_mab',     name = 'Pet: MAB',          cap = nil,  suffix = '',   patterns = {'Pet: "Mag%.Atk%.Bns%."%s*%+(%d+)', 'Pet: MAB%s*%+(%d+)'} },
    { key = 'pet_acc',     name = 'Pet: Accuracy',     cap = nil,  suffix = '',   patterns = {'Pet: Acc%.%s*%+(%d+)', 'Pet: Accuracy%s*%+(%d+)'} },
    { key = 'pet_ratk',    name = 'Pet: R.Atk',        cap = nil,  suffix = '',   patterns = {
        'Pet: R%.Atk%.%s*%+(%d+)',
        -- "Pet: Rng.Atk." seen on PUP / BST gear
        'Pet: Rng%.Atk%.%s*%+(%d+)',
    } },
    { key = 'pet_racc',    name = 'Pet: R.Acc',        cap = nil,  suffix = '',   patterns = {'Pet: R%.Acc%.%s*%+(%d+)', 'Pet: Rng%. Acc%.%s*%+(%d+)'} },
    { key = 'pet_mdmg',    name = 'Pet: M.Dmg.',       cap = nil,  suffix = '',   patterns = {
        'Pet: Mag%. Dmg%.%s*%+(%d+)',
        'Pet: M%.Dmg%.%s*%+(%d+)',
    } },
    { key = 'pet_enmity',  name = 'Pet: Enmity',       cap = nil,  suffix = '',   patterns = {
        -- Pet enmity can be +N (tank pets) or -N (dps pets). We capture
        -- both signs; UI displays the raw signed value.
        'Pet: Enmity%s*%+(%d+)',
        'Pet: Enmity%s*%-(%d+)',
    } },
    { key = 'perp',        name = 'Avatar Perp.',      cap = nil,  suffix = '',   patterns = {'[Aa]vatar.*[Pp]erpetuation.*%s*%-(%d+)', 'Perpetuation [Cc]ost %s*%-(%d+)'}, negative = true },
    { key = 'summon_skill',name = 'Summoning Skill',   cap = nil,  suffix = '',   patterns = {'[Ss]ummoning [Mm]agic [Ss]kill %s*%+(%d+)', '[Ss]ummoning [Mm]agic%s*%+(%d+)'} },
    { key = 'healing_skill',name = 'Healing Skill',    cap = nil,  suffix = '',   patterns = {
        -- Augment seen on Theophany / Pixie set Cure pieces.
        '[Hh]ealing [Mm]agic [Ss]kill%s*%+(%d+)',
        '[Hh]ealing [Mm]agic%s*%+(%d+)',
    } },
    -- Melee
    { key = 'da',          name = 'Double Attack',     cap = nil,  suffix = '%',  patterns = {
        -- 1. BG-Wiki full         "Double Attack +N%"
        'Double Attack%s*%+(%d+)',
        -- 2. Tooltip abbreviation "Dbl. Atk. +N%"
        'Dbl%. Atk%.%s*%+(%d+)',
        -- 3. Inventory-display    "Dbl.Atk.+N" (no space)
        'Dbl%.Atk%.%s*%+(%d+)',
        -- 4. Augment quoted       '"Dbl.Atk."+N' / '"Dbl. Atk."+N' / '"Double Attack"+N'
        '"Dbl%.Atk%."%s*%+(%d+)',
        '"Dbl%. Atk%."%s*%+(%d+)',
        '"Double Attack"%s*%+(%d+)',
    } },
    { key = 'ta',          name = 'Triple Attack',     cap = nil,  suffix = '%',  patterns = {
        -- 1. BG-Wiki full         "Triple Attack +N%"
        'Triple Attack%s*%+(%d+)',
        -- 2. Tooltip abbreviation "Triple Atk. +N%" / "Trpl. Atk. +N%"
        'Triple Atk%.%s*%+(%d+)',
        'Trpl%. Atk%.%s*%+(%d+)',
        -- 3. Inventory-display    "Triple Atk.+N" / "Trpl.Atk.+N"
        'Trpl%.Atk%.%s*%+(%d+)',
        -- 4. Augment quoted
        '"Triple Atk%."%s*%+(%d+)',
        '"Triple Attack"%s*%+(%d+)',
        '"Trpl%. Atk%."%s*%+(%d+)',
    } },
    { key = 'stp',         name = 'Store TP',          cap = nil,  suffix = '',   patterns = {
        -- 1/2. Full / abbreviated "Store TP +N"
        'Store TP%s*%+(%d+)',
        -- 3. Augment quoted       '"Store TP"+N'
        '"Store TP"%s*%+(%d+)',
        -- 4. Community shorthand  "STP +N"
        'STP%s*%+(%d+)',
    } },
    { key = 'dw',          name = 'Dual Wield',        cap = nil,  suffix = '',   patterns = {
        -- 1/2. Full                "Dual Wield +N"
        'Dual Wield%s*%+(%d+)',
        -- 3. Augment quoted        '"Dual Wield"+N'
        '"Dual Wield"%s*%+(%d+)',
        -- 4. Community shorthand   "DW +N"
        'DW%s*%+(%d+)',
    } },
    { key = 'subtle',      name = 'Subtle Blow',       cap = 50,   suffix = '',   patterns = {
        -- 1/2. Full                "Subtle Blow +N"
        'Subtle Blow%s*%+(%d+)',
        -- 3. Augment quoted        '"Subtle Blow"+N'
        '"Subtle Blow"%s*%+(%d+)',
        -- 4. Community shorthand   "SB +N" -- rare, not added (too generic)
    } },
    { key = 'crit',        name = 'Crit. Hit Rate',    cap = nil,  suffix = '%',  patterns = {
        -- 1. BG-Wiki full         "Critical Hit Rate +N%"
        '[Cc]ritical [Hh]it [Rr]ate%s*%+(%d+)',
        -- 2. Tooltip abbreviation "Crit. Hit Rate +N%" / "Crit. hit rate +N%"
        '[Cc]rit%. [Hh]it [Rr]ate%s*%+(%d+)',
        '[Cc]rit%. hit rate%s*%+(%d+)',
        -- 3. Inventory-display    "Crit.hit rate+N" (no space) -- Trial weapons / Colada
        '[Cc]rit%.hit rate%s*%+(%d+)',
        '[Cc]rit%.[Hh]it [Rr]ate%s*%+(%d+)',
        -- 4. Augment quoted       '"Crit. Hit Rate"+N' / '"Critical Hit Rate"+N'
        '"[Cc]rit%. [Hh]it [Rr]ate"%s*%+(%d+)',
        '"[Cc]ritical [Hh]it [Rr]ate"%s*%+(%d+)',
        -- 5. Community shorthand  "Crit Rate +N%" / "CHR +N%"
        '[Cc]rit [Rr]ate%s*%+(%d+)',
    } },
    { key = 'crit_dmg',    name = 'Crit. Hit Dmg.',    cap = nil,  suffix = '%',  patterns = {
        -- Trial weapons / Empyrean +3
        '[Cc]rit%. hit damage%s*%+(%d+)',
        '[Cc]ritical hit damage%s*%+(%d+)',
    } },
    { key = 'mag_crit_dmg',name = 'Mag. Crit. Dmg.',   cap = nil,  suffix = '%',  patterns = {
        -- Theophany / Inyanga +3 set bonus, Magic Burst gear
        'Mag%. crit%. hit dmg%.%s*%+(%d+)',
        'Magic crit%. hit damage%s*%+(%d+)',
    } },
    { key = 'tp_bonus',    name = 'TP Bonus',          cap = nil,  suffix = '',   patterns = {
        -- "TP Bonus +N" — Naegling, Tauret, Kannagi, others
        'TP Bonus%s*%+(%d+)',
        '"TP Bonus"%s*%+(%d+)',
    } },
    -- WS
    { key = 'ws_dmg',      name = 'WS Damage',         cap = nil,  suffix = '%',  patterns = {
        -- 1. BG-Wiki full        "Weapon Skill Damage +N%"
        '[Ww]eapon [Ss]kill [Dd]amage%s*%+(%d+)',
        -- 2. Augment quoted      '"Weapon Skill Damage"+N'
        '"Weapon Skill Damage"%s*%+(%d+)',
        -- 3. Community shorthand "WSD +N%"
        'WSD%s*%+(%d+)',
    } },
    -- Weapon: trial weapons add a "DMG: +N" augment that boosts base weapon damage
    { key = 'wpn_dmg_aug', name = 'Wpn DMG Aug',       cap = nil,  suffix = '',   patterns = {
        'DMG:%s*%+(%d+)',
        '"DMG:"%s*%+(%d+)',
    }, exclude = {'Blade', 'Skill'} },
    -- Magic Offense
    { key = 'mab',         name = 'Magic Atk. Bonus',  cap = nil,  suffix = '',   patterns = {
        -- 1. BG-Wiki full         "Magic Attack Bonus +N"
        'Magic Attack Bonus%s*%+(%d+)',
        -- 2. Tooltip abbreviation "Magic Atk. Bonus +N" / "Mag. Atk. Bonus +N"
        'Magic Atk%. Bonus%s*%+(%d+)',
        'Mag%. Atk%. Bonus%s*%+(%d+)',
        -- 3. Inventory-display    "Mag.Atk.Bns.+N" (no spaces in compound)
        'Mag%.Atk%.Bns%.%s*%+(%d+)',
        -- 4. Augment quoted       '"Mag.Atk.Bns."+N' (most common in extdata)
        '"Mag%.Atk%.Bns%."%s*%+(%d+)',
        '"Magic Atk%. Bonus"%s*%+(%d+)',
        '"Magic Attack Bonus"%s*%+(%d+)',
        -- 5. Community shorthand  "MAB +N" / "M.Atk.B +N"
        'MAB%s*%+(%d+)',
        'M%.Atk%.B%s*%+(%d+)',
        'M%.Atk%.Bns%.%s*%+(%d+)',
    }, exclude = {'Pet'} },
    { key = 'macc',        name = 'Magic Accuracy',    cap = nil,  suffix = '',   patterns = {
        -- 1. BG-Wiki full         "Magic Accuracy +N"
        'Magic Accuracy%s*%+(%d+)',
        -- 2. Tooltip abbreviation "Magic Acc. +N" / "Magic Acc +N"
        'Magic Acc%.%s*%+(%d+)',
        'Magic Acc%s+%+(%d+)',
        -- 3. Inventory-display    "Mag. Acc.+N" / "Mag. Acc+N" / "Mag.Acc.+N"
        'Mag%. Acc%.%s*%+(%d+)',
        'Mag%. Acc%s*%+(%d+)',
        'Mag%.Acc%.%s*%+(%d+)',
        -- 4. Augment quoted
        '"Mag%. Acc%."%s*%+(%d+)',
        '"Magic Accuracy"%s*%+(%d+)',
        -- 5. Community shorthand  "MAcc +N"
        'MAcc%s*%+(%d+)',
    }, exclude = {'Pet'} },
    { key = 'mag_dmg',     name = 'Magic Damage',      cap = nil,  suffix = '',   patterns = {
        -- Weapon stat (Maxentius, Daybreak, etc.)
        'Magic Damage%s*%+(%d+)',
        'Mag%. Dmg%.%s*%+(%d+)',
    }, exclude = {'Pet'} },
    { key = 'mb_dmg',      name = 'Magic Burst Dmg',   cap = 40,   suffix = '%',  patterns = {
        -- 1. BG-Wiki full        "Magic Burst Damage +N%" / "Magic Burst Damage II +N%"
        'Magic Burst Damage II%s*%+(%d+)',
        'Magic Burst Damage%s*%+(%d+)',
        -- 2. Inventory short     "Magic burst dmg. +N%"
        'Magic burst dmg%.%s*%+(%d+)',
        '[Mm]agic burst dmg%.%s*%+(%d+)',
        -- 3. Augment quoted
        '"Magic Burst Damage"%s*%+(%d+)',
        '"Magic Burst Damage II"%s*%+(%d+)',
        -- 4. Catch-all (kept from prior version)
        '[Mm]agic [Bb]urst.*%s*%+(%d+)',
    } },
    { key = 'occult_acumen',name= '"Occult Acumen"',   cap = nil,  suffix = '',   patterns = {
        -- JSE / Empyrean +3 BST aug
        '"Occult Acumen"%s*%+(%d+)',
    } },
    -- Defense
    { key = 'dt',          name = 'Damage Taken',      cap = 50,   suffix = '%',  patterns = {
        -- 1. BG-Wiki / tooltip   "Damage Taken -N%"
        '[Dd]amage [Tt]aken%s*%-(%d+)',
        -- 2. Inventory short     "Dmg. taken -N%"
        '[Dd]mg%. taken%s*%-(%d+)',
        '[Dd]amage taken%s*%-(%d+)',
        -- 3. Augment quoted      '"Damage Taken"-N%'
        '"Damage Taken"%s*%-(%d+)',
        -- 4. Community shorthand "DT -N%"
        'DT%s*%-(%d+)',
    }, negative = true, exclude = {'Phys', 'Mag', 'Pet', 'Breath'} },
    { key = 'pdt',         name = 'Phys. Dmg Taken',   cap = 50,   suffix = '%',  patterns = {
        -- 1. BG-Wiki full        "Physical Damage Taken -N%"
        'Physical [Dd]amage [Tt]aken%s*%-(%d+)',
        -- 2. Tooltip             "Phys. Damage Taken -N%" / "Phys. Dmg. Taken -N%"
        '[Pp]hys%. [Dd]amage [Tt]aken%s*%-(%d+)',
        '[Pp]hys%. [Dd]mg%. [Tt]aken%s*%-(%d+)',
        -- 3. Inventory short     "Phys. dmg. taken -N%"
        '[Pp]hys%. dmg%. taken%s*%-(%d+)',
        -- 4. Catch-all for       "Phys[anything]Damage Taken"
        '[Pp]hys[^%d]*[Dd]amage [Tt]aken%s*%-(%d+)',
        -- 5. Community shorthand "PDT -N%"
        'PDT%s*%-(%d+)',
    }, negative = true },
    { key = 'mdt',         name = 'Mag. Dmg Taken',    cap = 50,   suffix = '%',  patterns = {
        -- 1. BG-Wiki full        "Magic Damage Taken -N%"
        'Magic [Dd]amage [Tt]aken%s*%-(%d+)',
        -- 2. Tooltip             "Mag. Damage Taken -N%" / "Mag. Dmg. Taken -N%"
        'Mag%. [Dd]amage [Tt]aken%s*%-(%d+)',
        'Mag%. [Dd]mg%. [Tt]aken%s*%-(%d+)',
        -- 3. Inventory short     "Magic dmg. taken -N%" / "Mag. dmg. taken -N%"
        '[Mm]agic dmg%. taken%s*%-(%d+)',
        'Mag%. dmg%. taken%s*%-(%d+)',
        -- 4. Catch-all for       "Mag[anything]Damage Taken"
        '[Mm]ag[^%d]*[Dd]amage [Tt]aken%s*%-(%d+)',
        -- 5. Community shorthand "MDT -N%"
        'MDT%s*%-(%d+)',
    }, negative = true },
    { key = 'meva',        name = 'Magic Evasion',     cap = nil,  suffix = '',   patterns = {
        -- 1. BG-Wiki full         "Magic Evasion +N"
        'Magic Evasion%s*%+(%d+)',
        -- 2. Tooltip abbreviation "Magic Eva. +N" / "Mag. Evasion +N"
        'Magic Eva%.%s*%+(%d+)',
        'Mag%. Evasion%s*%+(%d+)',
        -- 3. Inventory-display    "Mag. Eva.+N" / "Mag. Eva+N"
        'Mag%. Eva%.%s*%+(%d+)',
        'Mag%. Eva%s*%+(%d+)',
        'Mag%.Eva%.%s*%+(%d+)',
        -- 4. Augment quoted
        '"Mag%. Eva%."%s*%+(%d+)',
        '"Magic Evasion"%s*%+(%d+)',
        -- 5. Community shorthand  "MEva +N"
        'MEva%s*%+(%d+)',
        -- Catch-all for weird truncations (Mag.Evas, Mag.Eva, etc.)
        '[Mm]ag[ic]*.*[Ee]vas?i?o?n?%.?%s*%+(%d+)',
    } },
    { key = 'mdef',        name = 'Magic Def. Bonus',  cap = nil,  suffix = '',   patterns = {
        -- 1. BG-Wiki full         "Magic Defense Bonus +N"
        'Magic Defense Bonus%s*%+(%d+)',
        -- 2. Tooltip abbreviation "Magic Def. Bonus +N" / "Mag. Def. Bonus +N"
        'Magic Def%. Bonus%s*%+(%d+)',
        'Mag%. Def%. Bonus%s*%+(%d+)',
        -- 3. Inventory-display    "Mag.Def.Bns.+N" (no spaces)
        'Mag%.Def%.Bns%.%s*%+(%d+)',
        -- 4. Augment quoted
        '"Mag%.Def%.Bns%."%s*%+(%d+)',
        '"Magic Def%. Bonus"%s*%+(%d+)',
        '"Magic Defense Bonus"%s*%+(%d+)',
        -- 5. Community shorthand  "MDB +N"
        'MDB%s*%+(%d+)',
        'M%.Def%.B%s*%+(%d+)',
    } },
    { key = 'evasion',     name = 'Evasion',           cap = nil,  suffix = '',   patterns = {
        -- Regular evasion stat (PLD / NIN / DNC tank gear)
        'Evasion%s*%+(%d+)',
        'Eva%.%s*%+(%d+)',
    }, exclude = {'Mag', 'Pet'} },
    { key = 'enmity',      name = 'Enmity',            cap = nil,  suffix = '',   patterns = {
        -- Enmity can be + (tank) or - (DPS). Captured separately.
        'Enmity%s*%+(%d+)',
        'Enmity%s*%-(%d+)',
    }, exclude = {'Pet'} },
    -- Healing
    { key = 'cure_pot',    name = 'Cure Potency',      cap = 50,   suffix = '%',  patterns = {
        -- 1. BG-Wiki full        "Cure Potency +N%"
        'Cure Potency%s*%+(%d+)',
        'Cure potency%s*%+(%d+)',
        -- 2. Quoted-spell variant '"Cure" Potency +N%' (Bunzi gear)
        '"Cure" [Pp]otency%s*%+(%d+)',
        -- 3. "Cure Potency II"   for the II tier (Empyrean +3 etc.)
        'Cure Potency II%s*%+(%d+)',
        '"Cure Potency II"%s*%+(%d+)',
        -- 4. Augment quoted
        '"Cure Potency"%s*%+(%d+)',
        -- 5. Inventory short     "Cure pot.+N%"
        'Cure pot%.%s*%+(%d+)',
    } },
    -- Utility
    { key = 'refresh',     name = 'Refresh',           cap = nil,  suffix = '',   patterns = {
        'Refresh%s*%+(%d+)',
        '"Refresh"%s*%+(%d+)',
    }, exclude = {'Pet'} },
    { key = 'regen',       name = 'Regen',             cap = nil,  suffix = '',   patterns = {
        'Regen%s*%+(%d+)',
        '"Regen"%s*%+(%d+)',
    }, exclude = {'Pet'} },
    { key = 'th',          name = 'Treasure Hunter',   cap = nil,  suffix = '',   patterns = {
        -- 1. BG-Wiki / tooltip   "Treasure Hunter +N"
        'Treasure Hunter%s*%+(%d+)',
        -- 2. Augment quoted      '"Treasure Hunter"+N'
        '"Treasure Hunter"%s*%+(%d+)',
        -- 3. Community shorthand "TH +N"
        'TH%s*%+(%d+)',
    } },
    -- Stats
    { key = 'str',         name = 'STR',               cap = nil,  suffix = '',   patterns = {'STR%s*%+(%d+)'}, exclude = {'Pet'} },
    { key = 'dex',         name = 'DEX',               cap = nil,  suffix = '',   patterns = {'DEX%s*%+(%d+)'}, exclude = {'Pet'} },
    { key = 'vit',         name = 'VIT',               cap = nil,  suffix = '',   patterns = {'VIT%s*%+(%d+)'}, exclude = {'Pet'} },
    { key = 'agi',         name = 'AGI',               cap = nil,  suffix = '',   patterns = {'AGI%s*%+(%d+)'}, exclude = {'Pet'} },
    { key = 'int',         name = 'INT',               cap = nil,  suffix = '',   patterns = {'INT%s*%+(%d+)'}, exclude = {'Pet'} },
    { key = 'mnd',         name = 'MND',               cap = nil,  suffix = '',   patterns = {'MND%s*%+(%d+)'}, exclude = {'Pet'} },
    { key = 'chr',         name = 'CHR',               cap = nil,  suffix = '',   patterns = {'CHR%s*%+(%d+)'}, exclude = {'Pet'} },
    { key = 'hp',          name = 'HP',                cap = nil,  suffix = '',   patterns = {'HP%s*%+(%d+)'} },
    { key = 'mp',          name = 'MP',                cap = nil,  suffix = '',   patterns = {'MP%s*%+(%d+)'} },
    { key = 'acc',         name = 'Accuracy',          cap = nil,  suffix = '',   patterns = {'Accuracy%s*%+(%d+)'}, exclude = {'Pet', 'Rng', 'Mag'} },
    { key = 'atk',         name = 'Attack',            cap = nil,  suffix = '',   patterns = {'Attack%s*%+(%d+)'}, exclude = {'Pet', 'Rng', 'Mag'} },
    -- Pet base stats. Each strips its own "Pet: " prefix during exclude
    -- handling on the main stat parser. Kept compact since they all share
    -- the same shape; add more as they appear in gs_export sweeps.
    { key = 'pet_str',     name = 'Pet: STR',          cap = nil,  suffix = '',   patterns = {'Pet: STR%s*%+(%d+)'} },
    { key = 'pet_dex',     name = 'Pet: DEX',          cap = nil,  suffix = '',   patterns = {'Pet: DEX%s*%+(%d+)'} },
    { key = 'pet_vit',     name = 'Pet: VIT',          cap = nil,  suffix = '',   patterns = {'Pet: VIT%s*%+(%d+)'} },
    { key = 'pet_agi',     name = 'Pet: AGI',          cap = nil,  suffix = '',   patterns = {'Pet: AGI%s*%+(%d+)'} },
    { key = 'pet_int',     name = 'Pet: INT',          cap = nil,  suffix = '',   patterns = {'Pet: INT%s*%+(%d+)'} },
    { key = 'pet_mnd',     name = 'Pet: MND',          cap = nil,  suffix = '',   patterns = {'Pet: MND%s*%+(%d+)'} },
    { key = 'pet_chr',     name = 'Pet: CHR',          cap = nil,  suffix = '',   patterns = {'Pet: CHR%s*%+(%d+)'} },
    { key = 'pet_dt',      name = 'Pet: DT',           cap = 50,   suffix = '%',  patterns = {
        'Pet: [Dd]amage [Tt]aken%s*%-(%d+)',
        'Pet: DT%s*%-(%d+)',
    }, negative = true },
    -- =========================================================================
    -- Additional patterns from second-pass sweep of a friend's Wingdings export
    -- (mostly multi-job WS / spell-skill / JSE coverage). Real augment text
    -- noted next to each.
    -- =========================================================================
    -- Ranged offense (RNG / BST / COR / weapon-bow gear, not pet)
    { key = 'ranged_acc', name = 'Ranged Acc.',        cap = nil,  suffix = '',   patterns = {
        'Rng%.Acc%.%s*%+(%d+)',
        'Rng%. Acc%.%s*%+(%d+)',
        'R%.Acc%.%s*%+(%d+)',
        'Ranged Accuracy%s*%+(%d+)',
    }, exclude = {'Pet'} },
    { key = 'ranged_atk', name = 'Ranged Atk.',        cap = nil,  suffix = '',   patterns = {
        'Rng%.Atk%.%s*%+(%d+)',
        'Rng%. Atk%.%s*%+(%d+)',
        'R%.Atk%.%s*%+(%d+)',
        'Ranged Attack%s*%+(%d+)',
    }, exclude = {'Pet'} },
    -- Quadruple Attack (very rare, found on some Empyrean +3 / Mythic Aftermath)
    { key = 'qa',         name = 'Quadruple Atk.',     cap = nil,  suffix = '%',  patterns = {
        -- 1. BG-Wiki full        "Quadruple Attack +N%"
        'Quadruple Attack%s*%+(%d+)',
        -- 2. Tooltip abbreviated "Quad. Atk. +N%"
        'Quad%. Atk%.%s*%+(%d+)',
        -- 3. Augment quoted
        '"Quadruple Attack"%s*%+(%d+)',
        '"Quad%. Atk%."%s*%+(%d+)',
        -- 4. Community shorthand "QA +N%"
        'QA%s*%+(%d+)',
    } },
    -- Defense stat (PLD / NIN tank gear)
    { key = 'def',        name = 'Defense',            cap = nil,  suffix = '',   patterns = {
        'DEF%s*%+(%d+)',
        'Defense%s*%+(%d+)',
    }, exclude = {'Pet'} },
    -- Parrying rate (PLD / DRK gear)
    { key = 'parrying',   name = 'Parrying Rate',      cap = nil,  suffix = '%',  patterns = {
        'Parrying rate%s*%+(%d+)',
    } },
    -- Breath damage taken (DRG / dragoon-specific)
    { key = 'breath_dt',  name = 'Breath Dmg Taken',   cap = 50,   suffix = '%',  patterns = {
        '[Bb]reath dmg%. taken%s*%-(%d+)',
        '[Bb]reath damage taken%s*%-(%d+)',
    }, negative = true },
    -- Weapon delay reduction (Trial / Aeonic / Mythic)
    { key = 'delay_red',  name = 'Weapon Delay',       cap = nil,  suffix = '',   patterns = {
        'Delay:%s*%-(%d+)',
        'Delay%s*%-(%d+)',
    }, negative = true },
    -- Job-ability recast reduction
    { key = 'ja_recast',  name = 'Ability Delay',      cap = nil,  suffix = '',   patterns = {
        'ability delay%s*%-(%d+)',
        '[Aa]bility recast%s*%-(%d+)',
    }, negative = true },
    -- Capacity point / merit XP gain
    { key = 'cap_point',  name = 'Cap. Point',         cap = nil,  suffix = '%',  patterns = {
        'Cap%. Point%s*%+(%d+)',
        'Capacity Point%s*%+(%d+)',
    } },
    -- Weapon Skill Accuracy (Aeonic weapons / Empyrean +3)
    { key = 'ws_acc',     name = 'WS Accuracy',        cap = nil,  suffix = '',   patterns = {
        'Weapon Skill Acc%.%s*%+(%d+)',
        'Weapon [Ss]kill [Aa]ccuracy%s*%+(%d+)',
    } },
    -- ---------- Magic skills (per school) ----------
    { key = 'enh_skill',  name = 'Enhancing Skill',    cap = nil,  suffix = '',   patterns = {
        '[Ee]nha%.mag%. skill%s*%+(%d+)',
        '[Ee]nhancing [Mm]agic [Ss]kill%s*%+(%d+)',
    } },
    { key = 'enf_skill',  name = 'Enfeebling Skill',   cap = nil,  suffix = '',   patterns = {
        '[Ee]nfb%.mag%. skill%s*%+(%d+)',
        '[Ee]nfeebling [Mm]agic [Ss]kill%s*%+(%d+)',
    } },
    { key = 'dark_skill', name = 'Dark Magic Skill',   cap = nil,  suffix = '',   patterns = {
        '[Dd]ark magic skill%s*%+(%d+)',
        '[Dd]ark [Mm]agic [Ss]kill%s*%+(%d+)',
    } },
    { key = 'blue_skill', name = 'Blue Magic Skill',   cap = nil,  suffix = '',   patterns = {
        'Blue Magic skill%s*%+(%d+)',
        '[Bb]lue [Mm]agic [Ss]kill%s*%+(%d+)',
    } },
    { key = 'geo_skill',  name = 'Geomancy Skill',     cap = nil,  suffix = '',   patterns = {
        'Geomancy Skill%s*%+(%d+)',
        '[Gg]eomancy [Ss]kill%s*%+(%d+)',
    } },
    -- ---------- Spell effect durations ----------
    { key = 'enh_dur',    name = 'Enh. Mag. Dur.',     cap = nil,  suffix = '',   patterns = {
        'Enh%. Mag%. eff%. dur%.%s*%+(%d+)',
        '[Ee]nhancing magic effect duration%s*%+(%d+)',
    } },
    { key = 'indi_dur',   name = 'Indi. Eff. Dur.',    cap = nil,  suffix = '',   patterns = {
        'Indi%. eff%. dur%.%s*%+(%d+)',
        'Indi effect duration%s*%+(%d+)',
    } },
    { key = 'helix_dur',  name = 'Helix Eff. Dur.',    cap = nil,  suffix = '',   patterns = {
        'Helix eff%. dur%.%s*%+(%d+)',
        'Helix effect duration%s*%+(%d+)',
    } },
}

-- Extract a numeric value from a text line using patterns.
-- exclude: list of word prefixes whose stat phrase should be STRIPPED from the
-- text before matching, e.g. exclude={'Mag'} on a stat 'Accuracy' will strip
-- "Magic Accuracy+44" out of "Accuracy+44 Magic Accuracy+44" so the simple
-- 'Accuracy' pattern only sees the +44 we care about.
local function extract_value(text, patterns, exclude)
    if not text then return 0 end
    if exclude then
        for _, ex in ipairs(exclude) do
            -- Match "<exclude_word>...+<num>" non-greedily so we strip just one
            -- stat-phrase per match, not eat the whole line.
            text = text:gsub(ex .. '[%w%.%:%s%(%)%-]-%+%-?%d+', '')
        end
    end
    for _, pat in ipairs(patterns) do
        local val = text:match(pat)
        if val then return tonumber(val) or 0 end
    end
    return 0
end

-- Base-stat lookup table. Loaded lazily from data/item_stats.json on first
-- use. See libs/base_stats.lua for the LSB-to-GSUI translation rules.
local base_stats = require('libs/base_stats')

-- Parse a single item (base stats from the LSB JSON + description + augments)
-- and return stat contributions.
--
-- Resolution order:
--   1. item.name              -> base_stats.lookup() -> numeric base stats
--   2. item.description text  -> regex stat_defs (legacy path; description
--                                field is usually nil because res.items has
--                                never populated it, but kept as a fallback)
--   3. item.augments text     -> regex stat_defs (always parsed)
-- All three sum into the same return table per stat key.
local function parse_item_stats(item)
    local stats = {}
    if not item then return stats end

    -- 1. JSON base-stat lookup. Try `name` first (gs_export shape), then
    -- `english` (windower.ffxi.get_items() shape), then `en`. Same physical
    -- item just labeled differently depending on which code path built it.
    local lookup_name = item.name or item.english or item.en
    if lookup_name then
        local base = base_stats.lookup(lookup_name)
        if base then
            for k, v in pairs(base) do
                stats[k] = (stats[k] or 0) + v
            end
        end
    end

    -- 2 + 3. Description + augment regex scan. Augments are the important
    -- contributor here -- the description field is almost always nil.
    local lines = {}
    if item.description then
        for line in item.description:gmatch('[^\r\n]+') do
            table.insert(lines, line)
        end
    end
    if item.augments then
        for _, aug in ipairs(item.augments) do
            table.insert(lines, aug)
        end
    end

    for _, def in ipairs(stat_defs) do
        local total = 0
        for _, line in ipairs(lines) do
            total = total + extract_value(line, def.patterns, def.exclude)
        end
        if total > 0 then
            stats[def.key] = (stats[def.key] or 0) + total
        end
    end

    return stats
end

-- Calculate totals from all equipped items
-- equipment_data: table of slot_name -> { item = item_info }
function stat_parser.calc_totals(equipment_data)
    local totals = {}
    for _, def in ipairs(stat_defs) do
        totals[def.key] = 0
    end

    if not equipment_data then return totals end

    for slot_name, eq_data in pairs(equipment_data) do
        if eq_data and eq_data.item then
            local item_stats = parse_item_stats(eq_data.item)
            for key, val in pairs(item_stats) do
                totals[key] = (totals[key] or 0) + val
            end
        end
    end

    return totals
end

-- Get ordered list of stats that have non-zero values, for display
function stat_parser.get_display_stats(totals)
    local result = {}
    for _, def in ipairs(stat_defs) do
        local val = totals[def.key] or 0
        if val > 0 then
            local display_val = def.negative and ('-' .. val) or ('+' .. val)
            local cap_text = ''
            if def.cap then
                if val >= def.cap then
                    cap_text = ' [CAPPED]'
                else
                    cap_text = ' /' .. def.cap
                end
            end
            table.insert(result, {
                key = def.key,
                name = def.name,
                value = val,
                display = def.name .. ': ' .. display_val .. def.suffix .. cap_text,
                capped = def.cap and val >= def.cap or false,
                category = get_category(def.key),
            })
        end
    end
    return result
end

-- Category grouping for display
function get_category(key)
    local categories = {
        fc = 'Casting', qm = 'Casting', conserve_mp = 'Casting', sird = 'Casting',
        haste = 'Haste',
        bp_delay = 'Pet/SMN', bp_dmg = 'Pet/SMN', pet_haste = 'Pet/SMN',
        pet_atk = 'Pet/SMN', pet_macc = 'Pet/SMN', pet_mab = 'Pet/SMN',
        pet_acc = 'Pet/SMN', pet_ratk = 'Pet/SMN', pet_racc = 'Pet/SMN',
        perp = 'Pet/SMN', summon_skill = 'Pet/SMN',
        da = 'Melee', ta = 'Melee', stp = 'Melee', dw = 'Melee',
        subtle = 'Melee', crit = 'Melee', acc = 'Melee', atk = 'Melee',
        ws_dmg = 'WS',
        mab = 'Magic', macc = 'Magic', mb_dmg = 'Magic',
        dt = 'Defense', pdt = 'Defense', mdt = 'Defense',
        meva = 'Defense', mdef = 'Defense',
        cure_pot = 'Healing',
        refresh = 'Utility', regen = 'Utility', th = 'Utility',
        str = 'Stats', dex = 'Stats', vit = 'Stats', agi = 'Stats',
        int = 'Stats', mnd = 'Stats', chr = 'Stats',
        hp = 'Stats', mp = 'Stats',
    }
    return categories[key] or 'Other'
end

-- ============================================================================
-- Total Accuracy calculation
-- Formula (from BG-wiki): Total Acc = floor(DEX * 0.75) + skill_acc + gear_acc
-- where skill_acc tiers are:
--   skill <= 200          -> skill
--   200 < skill <= 400    -> floor((skill-200) * 0.9) + 200
--   400 < skill <= 600    -> floor((skill-400) * 0.8) + 380
--   skill > 600           -> floor((skill-600) * 0.9) + 540
-- DEX comes from the player's current stats (already includes gear DEX).
-- ============================================================================

local function skill_to_acc(skill)
    if skill <= 200 then return skill end
    if skill <= 400 then return math.floor((skill - 200) * 0.9) + 200 end
    if skill <= 600 then return math.floor((skill - 400) * 0.8) + 380 end
    return math.floor((skill - 600) * 0.9) + 540
end

-- Map FFXI skill ID -> combat_skills table key in get_player()
local skill_id_to_key = {
    [1]='hand_to_hand', [2]='dagger', [3]='sword', [4]='great_sword',
    [5]='axe', [6]='great_axe', [7]='scythe', [8]='polearm',
    [9]='katana', [10]='great_katana', [11]='club', [12]='staff',
    [25]='archery', [26]='marksmanship', [27]='throwing',
}

local bag_names = {
    [0]='inventory', [8]='wardrobe', [10]='wardrobe2', [11]='wardrobe3',
    [12]='wardrobe4', [13]='wardrobe5', [14]='wardrobe6',
    [15]='wardrobe7', [16]='wardrobe8',
}

-- Returns dex_acc, skill_acc, weapon_skill_value, dex (or nils on failure)
local function get_base_components()
    local p = windower.ffxi.get_player()
    if not p then return nil end
    local s = p.stats or p.attributes or {}
    local dex = s.dex or 0
    local dex_acc = math.floor(dex * 0.75)

    local skill_acc, skill_val = 0, 0
    local items = windower.ffxi.get_items()
    if items and items.equipment and p.combat_skills then
        local idx     = items.equipment.main
        local bag_id  = items.equipment.main_bag or 0
        local bag     = items[bag_names[bag_id] or 'inventory']
        if bag and bag[idx] and bag[idx].id and bag[idx].id ~= 0 then
            local item = res.items[bag[idx].id]
            if item and item.skill then
                local key = skill_id_to_key[item.skill]
                if key and p.combat_skills[key] then
                    skill_val = p.combat_skills[key].value or 0
                    skill_acc = skill_to_acc(skill_val)
                end
            end
        end
    end
    return dex_acc, skill_acc, skill_val, dex
end

function stat_parser.compute_total_accuracy(gear_acc)
    local dex_acc, skill_acc = get_base_components()
    if not dex_acc then return nil end
    return dex_acc + skill_acc + (gear_acc or 0), dex_acc, skill_acc
end

-- ============================================================================
-- Other total-stat formulas (BG-wiki references)
--
-- Attack (main hand) = 8 + Combat Skill + STR  [+ gear atk]
--   Combat Skill uses the same tiered conversion as accuracy.
--
-- Magic Accuracy = magic_skill + dSTAT_bonus + gear_macc
--   For player-side display we omit dSTAT (target-dependent) and just show
--   highest_magic_skill + gear_macc as a baseline.
--
-- Defense ~= 8 + floor(VIT * 1.5) + skill + gear_def  (rough; FFXI calc is
--   defense-skill-tier'd similarly to acc)
--
-- Evasion = floor(AGI * 0.5) + Evasion skill (tiered) + gear_eva
-- Magic Evasion = base_meva + Magic Evasion skill + gear_meva
-- ============================================================================

function stat_parser.compute_total_attack(gear_atk)
    local p = windower.ffxi.get_player()
    if not p then return nil end
    local s = p.stats or p.attributes or {}
    local _, skill_acc, _ = get_base_components()       -- skill→atk uses same tiers
    local str = s.str or 0
    local atk = 8 + (skill_acc or 0) + str + (gear_atk or 0)
    return atk, skill_acc or 0, str
end

local magic_skill_keys = {
    'elemental_magic', 'enfeebling_magic', 'enhancing_magic',
    'dark_magic', 'divine_magic', 'healing_magic',
    'summoning_magic', 'blue_magic', 'ninjutsu', 'singing', 'string_instrument',
    'wind_instrument', 'geomancy', 'handbell',
}

local function get_highest_magic_skill()
    local p = windower.ffxi.get_player()
    if not p then return 0, '?' end
    -- Magic skills are typically in p.magic_skills, but some Windower builds
    -- merge them into p.combat_skills. Check both.
    local sources = { p.magic_skills, p.combat_skills }
    local best, best_name = 0, '?'
    for _, src in ipairs(sources) do
        if src then
            for _, k in ipairs(magic_skill_keys) do
                local s = src[k]
                if s and (s.value or 0) > best then
                    best = s.value
                    best_name = k
                end
            end
        end
    end
    return best, best_name
end

function stat_parser.compute_total_macc(gear_macc)
    local p = windower.ffxi.get_player()
    if not p then return nil end
    local skill_val, skill_name = get_highest_magic_skill()
    local skill_macc = skill_to_acc(skill_val)          -- same tier curve as melee
    return skill_macc + (gear_macc or 0), skill_macc, skill_val, skill_name
end

-- Prefer cached stats from packet 0x061. Fall back to anything
-- get_player()/get_mob_by_target('me') happens to expose.
local function get_player_stats()
    if cached_stats.str then
        return cached_stats
    end
    local p = windower.ffxi.get_player()
    if p then
        if p.stats and next(p.stats) then return p.stats end
        if p.attributes and next(p.attributes) then return p.attributes end
    end
    local me = windower.ffxi.get_mob_by_target('me')
    if me and me.stats and next(me.stats) then return me.stats end
    if me and (me.str or me.dex) then
        return { str = me.str, dex = me.dex, vit = me.vit, agi = me.agi,
                 int = me.int, mnd = me.mnd, chr = me.chr }
    end
    return {}
end

-- Format the alternate "Total Stats" view. Compact layout, no wrapping.
function stat_parser.format_total_summary(totals)
    local p = windower.ffxi.get_player()
    if not p then return 'Player data unavailable.' end
    local s = get_player_stats()
    local v = p.vitals or {}

    -- Resolve weapon skill (for accuracy/attack tiers)
    local skill_val = 0
    local items = windower.ffxi.get_items()
    if items and items.equipment then
        local idx     = items.equipment.main
        local bag_id  = items.equipment.main_bag or 0
        local bag     = items[bag_names[bag_id] or 'inventory']
        if bag and bag[idx] and bag[idx].id and bag[idx].id ~= 0 then
            local item = res.items[bag[idx].id]
            if item and item.skill and skill_id_to_key[item.skill] and p.combat_skills then
                local cs = p.combat_skills[skill_id_to_key[item.skill]]
                if cs then skill_val = cs.value or 0 end
            end
        end
    end

    local has_stats = next(s) ~= nil
    local lines = {}

    if not has_stats then
        table.insert(lines, '(stats not yet received - swap')
        table.insert(lines, ' any gear once or zone to get them)')
        table.insert(lines, '')
    end

    -- Pull in the other gear values
    local gear_acc  = totals.acc  or 0
    local gear_atk  = totals.atk  or 0
    local gear_macc = totals.macc or 0
    local gear_mab  = totals.mab  or 0

    -- Accuracy
    local dex      = s.dex or 0
    local dex_acc  = math.floor(dex * 0.75)
    local skill_acc = skill_to_acc(skill_val)
    local tot_acc  = dex_acc + skill_acc + gear_acc

    -- Attack
    local str     = s.str or 0
    local tot_atk = 8 + skill_acc + str + gear_atk

    -- Magic accuracy (uses highest magic skill)
    local mskill, mname = get_highest_magic_skill()
    local mskill_acc = skill_to_acc(mskill)
    local tot_macc   = mskill_acc + gear_macc

    -- "ACC" = computed accuracy from stats+skill (DEX includes everything FFXI
    -- credits: base + merits + JP/Master gifts + gear DEX + buffs).
    -- "GACC" = explicit "Accuracy +N" from gear augments/descriptions.
    -- ACC + GACC = total accuracy. Same idea for ATK/MACC.
    local acc_base  = dex_acc + skill_acc
    local atk_base  = 8 + skill_acc + str
    local macc_base = mskill_acc

    table.insert(lines, '-- Combat Totals --')
    table.insert(lines, string.format('ACC  %d + GACC  %d = %d',  acc_base,  gear_acc,  tot_acc))
    table.insert(lines, string.format('ATK  %d + GATK  %d = %d',  atk_base,  gear_atk,  tot_atk))
    table.insert(lines, string.format('MACC %d + GMACC %d = %d', macc_base, gear_macc, tot_macc))
    if gear_mab > 0 then
        table.insert(lines, string.format('GMAB %d', gear_mab))
    end
    table.insert(lines, '')

    if has_stats then
        table.insert(lines, '-- Base + Gear --')
        table.insert(lines, string.format('STR%-3d DEX%-3d VIT%-3d', s.str or 0, s.dex or 0, s.vit or 0))
        table.insert(lines, string.format('AGI%-3d INT%-3d MND%-3d', s.agi or 0, s.int or 0, s.mnd or 0))
        table.insert(lines, string.format('CHR%-3d', s.chr or 0))
    end

    if v.max_hp then
        table.insert(lines, string.format('HP %d/%d  MP %d/%d',
            v.hp or 0, v.max_hp or 0, v.mp or 0, v.max_mp or 0))
    end

    -- =========================================================================
    -- Combat Secondaries / Defense / Casting blocks.
    --
    -- The Total view used to stop at the Base + Gear block, which left
    -- out the stats that matter most for a quick "is this player set
    -- up for offense or defense" audit (Haste / DA / TA / DW / DT etc.).
    -- These follow-on sections pull those values straight from the
    -- already-computed `totals` table so they cover both your own
    -- equipped gear AND a /check'd player's gear without further
    -- packet work.
    --
    -- Each line only renders if at least one of its stats is > 0, so
    -- jobs that genuinely have nothing in a category (e.g. a healer
    -- with no melee multi-attack) don't get padded with blank rows.
    --
    -- DT / PDT / MDT are stored as positive percentages internally
    -- (stat_parser flags them with `negative = true` so the gear view
    -- prepends the minus sign). We render them the same way here.
    -- =========================================================================
    local has_sec =
        (totals.haste or 0) > 0 or (totals.da or 0) > 0 or
        (totals.ta or 0) > 0    or (totals.stp or 0) > 0 or
        (totals.dw or 0) > 0    or (totals.crit or 0) > 0 or
        (totals.subtle or 0) > 0
    if has_sec then
        table.insert(lines, '')
        table.insert(lines, '-- Combat Secondaries --')
        local row1 = {}
        if (totals.haste or 0) > 0 then row1[#row1+1] = string.format('Haste %d%%', totals.haste) end
        if (totals.dw    or 0) > 0 then row1[#row1+1] = string.format('DW %d%%',    totals.dw)    end
        if (totals.stp   or 0) > 0 then row1[#row1+1] = string.format('STP %d',     totals.stp)   end
        if #row1 > 0 then table.insert(lines, table.concat(row1, '  ')) end
        local row2 = {}
        if (totals.da   or 0) > 0 then row2[#row2+1] = string.format('DA %d%%',  totals.da)   end
        if (totals.ta   or 0) > 0 then row2[#row2+1] = string.format('TA %d%%',  totals.ta)   end
        if (totals.crit or 0) > 0 then row2[#row2+1] = string.format('Crit %d%%', totals.crit) end
        if #row2 > 0 then table.insert(lines, table.concat(row2, '  ')) end
        if (totals.subtle or 0) > 0 then
            table.insert(lines, string.format('SB %d', totals.subtle))
        end
    end

    local has_def =
        (totals.pdt or 0) > 0 or (totals.mdt or 0) > 0 or
        (totals.dt or 0) > 0  or (totals.meva or 0) > 0
    if has_def then
        table.insert(lines, '')
        table.insert(lines, '-- Defense --')
        local row = {}
        -- pdt / mdt / dt stack: a piece with universal DT contributes
        -- to both PDT and MDT functionally, but the stat_parser tracks
        -- them under separate keys based on the augment text. We show
        -- all three so the user can see each contribution channel.
        if (totals.pdt  or 0) > 0 then row[#row+1] = string.format('PDT -%d%%',  totals.pdt)  end
        if (totals.mdt  or 0) > 0 then row[#row+1] = string.format('MDT -%d%%',  totals.mdt)  end
        if (totals.dt   or 0) > 0 then row[#row+1] = string.format('DT  -%d%%',  totals.dt)   end
        if #row > 0 then table.insert(lines, table.concat(row, '  ')) end
        if (totals.meva or 0) > 0 then
            table.insert(lines, string.format('MEva %d', totals.meva))
        end
    end

    local has_cast =
        (totals.fc or 0) > 0 or (totals.conserve_mp or 0) > 0 or
        (totals.qm or 0) > 0 or (totals.sird or 0) > 0
    if has_cast then
        table.insert(lines, '')
        table.insert(lines, '-- Casting --')
        local row = {}
        if (totals.fc          or 0) > 0 then row[#row+1] = string.format('FC %d%%',  totals.fc) end
        if (totals.qm          or 0) > 0 then row[#row+1] = string.format('QM %d%%',  totals.qm) end
        if (totals.conserve_mp or 0) > 0 then row[#row+1] = string.format('CMP %d',   totals.conserve_mp) end
        if (totals.sird        or 0) > 0 then row[#row+1] = string.format('SIRD %d%%',totals.sird) end
        if #row > 0 then table.insert(lines, table.concat(row, '  ')) end
    end

    return table.concat(lines, '\n')
end

-- Format stats as a multi-line string grouped by category
function stat_parser.format_summary(totals)
    local display = stat_parser.get_display_stats(totals)
    if #display == 0 then return 'No stats detected.\nEquip gear to see totals.' end

    -- Group by category
    local groups = {}
    local group_order = { 'Casting', 'Haste', 'Pet/SMN', 'Melee', 'WS', 'Magic', 'Defense', 'Healing', 'Utility', 'Stats' }
    for _, cat in ipairs(group_order) do
        groups[cat] = {}
    end

    for _, stat in ipairs(display) do
        local cat = stat.category
        if not groups[cat] then groups[cat] = {} end
        table.insert(groups[cat], stat)
    end

    local lines = {}
    for _, cat in ipairs(group_order) do
        local items = groups[cat]
        if items and #items > 0 then
            -- Inject Total Accuracy block right above the Stats section
            if cat == 'Stats' then
                local gear_acc = totals.acc or 0
                local total, dex_acc, skill_acc = stat_parser.compute_total_accuracy(gear_acc)
                if total then
                    table.insert(lines, '-- Total Accuracy --')
                    table.insert(lines, string.format('Total: %d  (DEX %d + Skill %d + Gear %d)',
                        total, dex_acc, skill_acc, gear_acc))
                    table.insert(lines, '')
                end
            end
            table.insert(lines, '-- ' .. cat .. ' --')
            for _, stat in ipairs(items) do
                table.insert(lines, stat.display)
            end
            table.insert(lines, '')
        end
    end

    return table.concat(lines, '\n')
end

return stat_parser
