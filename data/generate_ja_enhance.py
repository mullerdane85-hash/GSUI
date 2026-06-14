#!/usr/bin/env python3
"""Generate libs/ja_enhance.lua from res/items.lua.

The hand-curated approach (writing item names manually for every relic/empy
tier across 22 jobs) is error-prone -- FFXI abbreviates some tiers and not
others (e.g. "Geo. Tunic +1" but "Geomancy Tunic +2"), and the abbreviation
choice isn't predictable from outside the game. The only source of truth is
items.lua's `en` field for each item ID.

This generator:
  1. Reads res/items.lua, indexes every item by id with (en, jobs_mask, slots_mask).
  2. Walks a table of relic / empyrean / AF set families with one row per
     piece, identified by a CONSISTENT identifier (the english_log lowercased
     full name, e.g. "geomancy tunic", "geomancy tunic +1", ...). enl never
     gets abbreviated -- it's always the full name -- so matching on it is
     stable across tiers.
  3. For each piece, emits the actual `en` form into ja_enhance.lua so the
     in-game inventory comparison hits.

Run after Windower res/items.lua is updated; commit the generated lua.
"""
import re
import pathlib

ITEMS_LUA = pathlib.Path(r"C:\Users\Jason\Desktop\Windower\res\items.lua")
OUT = pathlib.Path(r"C:\Users\Jason\Desktop\Windower\addons\GSUI\libs\ja_enhance.lua")

# Slot bitmask bits (bit 4 = head, 5 = body, 6 = hands, 7 = legs, 8 = feet).
SLOT_BITS = {
    "head":  1 << 4,    # 16
    "body":  1 << 5,    # 32
    "hands": 1 << 6,    # 64
    "legs":  1 << 7,    # 128
    "feet":  1 << 8,    # 256
}

# Job bitmask bit for GEO etc. (1 << job_id where 21 = GEO).
JOB_BITS = {
    "WAR": 1 << 1, "MNK": 1 << 2, "WHM": 1 << 3, "BLM": 1 << 4, "RDM": 1 << 5,
    "THF": 1 << 6, "PLD": 1 << 7, "DRK": 1 << 8, "BST": 1 << 9, "BRD": 1 << 10,
    "RNG": 1 << 11,"SAM": 1 << 12,"NIN": 1 << 13,"DRG": 1 << 14,"SMN": 1 << 15,
    "BLU": 1 << 16,"COR": 1 << 17,"PUP": 1 << 18,"DNC": 1 << 19,"SCH": 1 << 20,
    "GEO": 1 << 21,"RUN": 1 << 22,
}

# Slot -> JA enhanced, per set family. Sourced from BG-Wiki per-piece tooltips.
# Each entry is the BASE-NQ name (lowercase) as it appears in enl, plus the
# slot bonus map. Tiers (+1/+2/+3) are auto-generated.
SET_FAMILIES = [
    # ---- Relic ----
    ("GEO",  "Relic", "bagua",         {"head":"Widened Compass","body":"Bolster","hands":"Full Circle","legs":"Mending Halation","feet":"Radial Arcana"}),
    ("WAR",  "Relic", "pummeler's",    {"head":"Mighty Strikes","body":"Berserk","hands":"Aggressor","legs":"Defender","feet":"Warcry"}),
    ("MNK",  "Relic", "hesychast's",   {"head":"Hundred Fists","body":"Focus","hands":"Chi Blast","legs":"Dodge","feet":"Counterstance"}),
    ("WHM",  "Relic", "piety",         {"head":"Benediction","body":"Devotion","hands":"Martyr","legs":"Divine Seal","feet":"Afflatus Solace"}),
    ("BLM",  "Relic", "archmage's",    {"head":"Manafont","body":"Mana Wall","hands":"Magic Burst","legs":"Elemental Seal"}),
    ("RDM",  "Relic", "atrophy",       {"head":"Chainspell","body":"Convert","hands":"Composure","legs":"Saboteur"}),
    ("THF",  "Relic", "pillager's",    {"head":"Perfect Dodge","body":"Hide","hands":"Despoil","legs":"Conspirator","feet":"Trick Attack"}),
    ("PLD",  "Relic", "caballarius",   {"head":"Invincible","body":"Cover","hands":"Sentinel","legs":"Holy Circle","feet":"Chivalry"}),
    ("DRK",  "Relic", "ignominy",      {"head":"Blood Weapon","body":"Last Resort","hands":"Souleater","legs":"Arcane Circle","feet":"Diabolic Eye"}),
    ("BST",  "Relic", "pantin",        {"head":"Familiar","body":"Killer Instinct","hands":"Reward","legs":"Charm","feet":"Spur"}),
    ("BRD",  "Relic", "bihu",          {"head":"Soul Voice","body":"Troubadour","hands":"Tenuto","legs":"Marcato","feet":"Nightingale"}),
    ("RNG",  "Relic", "arcadian",      {"head":"Eagle Eye Shot","body":"Sharpshot","hands":"Bounty Shot","legs":"Velocity Shot","feet":"Snapshot"}),
    ("SAM",  "Relic", "sakonji",       {"head":"Meikyo Shisui","body":"Hagakure","hands":"Sekkanoki","legs":"Sengikori","feet":"Zanshin"}),
    ("NIN",  "Relic", "mochizuki",     {"head":"Mijin Gakure","body":"Yonin","hands":"Sange","legs":"Innin","feet":"Futae"}),
    ("DRG",  "Relic", "vishap",        {"head":"Spirit Surge","body":"Ancient Circle","hands":"Restoring Breath","legs":"Healing Breath","feet":"Spirit Link"}),
    ("SMN",  "Relic", "convoker's",    {"head":"Astral Flow","body":"Astral Conduit","hands":"Mana Cede","legs":"Apogee","feet":"Elemental Siphon"}),
    ("BLU",  "Relic", "magus",         {"head":"Burst Affinity","body":"Chain Affinity","hands":"Convergence","legs":"Efflux","feet":"Diffusion"}),
    ("COR",  "Relic", "lanun",         {"head":"Wild Card","body":"Bust","hands":"Snake Eye","legs":"Random Deal","feet":"Fold"}),
    ("PUP",  "Relic", "cirque",        {"head":"Overdrive","body":"Repair","hands":"Maneuver","legs":"Heady Artifice","feet":"Tactical Switch"}),
    ("DNC",  "Relic", "maxixi",        {"head":"Trance","body":"Saber Dance","hands":"No Foot Rise","legs":"Climactic Flourish","feet":"Reverse Flourish"}),
    ("SCH",  "Relic", "argute",        {"head":"Tabula Rasa","body":"Modus Veritas","hands":"Sublimation","legs":"Enlightenment","feet":"Stratagem"}),
    ("RUN",  "Relic", "futhark",       {"head":"Embolden","body":"Pflug","hands":"Lunge","legs":"Vivacious Pulse","feet":"Swordplay"}),
    # ---- Empyrean ----
    ("GEO",  "Empy",  "azimuth",       {"head":"Full Circle","body":"Indi/Geo Radius","hands":"Curative Recantation","legs":"Entrust","feet":"Mending Halation"}),
    ("WAR",  "Empy",  "boii",          {"head":"Restraint","body":"Aggressive Aim","hands":"Tomahawk","legs":"Blood Rage","feet":"Retaliation"}),
    ("MNK",  "Empy",  "hizamaru",      {"head":"Mantra","body":"Footwork","hands":"Impetus","legs":"Formless Strikes","feet":"Inner Strength"}),
    ("WHM",  "Empy",  "ebers",         {"head":"Divine Caress","body":"Asylum","hands":"Sacrosanctity","legs":"Esunaga Radius","feet":"Sacred Trust"}),
    ("BLM",  "Empy",  "wicce",         {"head":"Subtle Sorcery","body":"Sublime Sorcery","hands":"Enmity Douse","legs":"Mana Wall Radius","feet":"Mana Wall Duration"}),
    ("RDM",  "Empy",  "lethargy",      {"head":"Stymie","body":"Phalanx II","hands":"Temper II","legs":"Spontaneity"}),
    ("THF",  "Empy",  "skulker",       {"head":"Aura Steal","body":"Accomplice","hands":"Larceny","legs":"Collaborator","feet":"Feint"}),
    ("PLD",  "Empy",  "reverence",     {"head":"Iron Will","body":"Fealty","hands":"Sepulcher","legs":"Palisade","feet":"Sentinel Duration"}),
    ("DRK",  "Empy",  "fallen",        {"head":"Nether Void","body":"Muted Soul","hands":"Weapon Bash","legs":"Dark Seal","feet":"Diabolic Eye Duration"}),
    ("BST",  "Empy",  "totemic",       {"head":"Bestial Loyalty","body":"Beast Affinity","hands":"Beast Healer","legs":"Beast Warder","feet":"Sic"}),
    ("BRD",  "Empy",  "brioso",        {"head":"Maestoso","body":"Pianissimo","hands":"Tenuto Duration","legs":"Marcato Duration","feet":"Hymn of Krieg"}),
    ("RNG",  "Empy",  "orion",         {"head":"Stealth Shot","body":"Recycle","hands":"Decoy Shot","legs":"Camouflage","feet":"Scavenge"}),
    ("SAM",  "Empy",  "wakido",        {"head":"Shikikoyo","body":"Konzen-ittai","hands":"Hasso","legs":"Meditate","feet":"Seigan"}),
    ("NIN",  "Empy",  "hachiya",       {"head":"Ninja Tool Expertise","body":"Migawari","hands":"Issekigan","legs":"Tonko Effect","feet":"Yonin Duration"}),
    ("DRG",  "Empy",  "pteroslaver",   {"head":"Empathy","body":"Strafe","hands":"Steady Wing","legs":"Wyvern Max HP","feet":"Wyvern HP"}),
    ("SMN",  "Empy",  "beckoner's",    {"head":"Mana Cede Duration","body":"Convergence","hands":"Avatar Favor","legs":"Smart Companion","feet":"Heavenly Caress"}),
    ("BLU",  "Empy",  "assimilator's", {"head":"Unbridled Wisdom","body":"Burst Affinity Duration","hands":"Azure Lore","legs":"Enchainment","feet":"Diffusion Duration"}),
    ("COR",  "Empy",  "chasseur's",    {"head":"Loaded Deck","body":"Triple Shot","hands":"Cutting Cards","legs":"Allies' Roll","feet":"Quick Draw"}),
    ("PUP",  "Empy",  "foire",         {"head":"Activate","body":"Cooldown","hands":"Repair Duration","legs":"Ventriloquy","feet":"Role Reversal"}),
    ("DNC",  "Empy",  "horos",         {"head":"Step Duration","body":"Building Flourish","hands":"Box Step","legs":"Quickstep","feet":"Striking Flourish"}),
    ("SCH",  "Empy",  "pedagogy",      {"head":"Penury","body":"Parsimony","hands":"Manifestation","legs":"Accession","feet":"Klimaform"}),
    ("RUN",  "Empy",  "runeist",       {"head":"One for All","body":"Battuta","hands":"Vivacious Pulse","legs":"Valiance","feet":"Inspiration"}),
    # ---- Geomancy AF (only the GEO AF set ties bonuses to JAs; other AF sets
    # carry stats/skills, not JAs) ----
    ("GEO",  "AF",    "geomancy",      {"head":"Cardinal Chant","body":"Life Cycle"}),
]

# Parse items.lua line-by-line. Each item is `[id] = {field=value,...},` on
# its own line. We extract the body between `{` and `}` then split fields.
items_text = ITEMS_LUA.read_text(encoding="utf-8", errors="ignore")
line_re = re.compile(r'^\s*\[(\d+)\]\s*=\s*\{(.*)\}\s*,?\s*$', re.MULTILINE)
items_by_enl = {}
for m in line_re.finditer(items_text):
    iid, body = m.groups()
    fields = {}
    # en/enl/jal/ja can contain commas inside quotes; capture each via its
    # own regex with quoted-string handling.
    for key in ("en", "enl"):
        km = re.search(rf'\b{key}="([^"]*)"', body)
        if km: fields[key] = km.group(1)
    for key in ("jobs", "slots", "item_level", "level"):
        km = re.search(rf'\b{key}=(\d+)', body)
        if km: fields[key] = int(km.group(1))
    enl = fields.get("enl")
    if not enl:
        continue
    items_by_enl[enl.lower()] = {
        "id":         int(iid),
        "en":         fields.get("en", enl),
        "enl":        enl,
        "jobs":       fields.get("jobs", 0),
        "slots":      fields.get("slots", 0),
        "item_level": fields.get("item_level", 0),
        "level":      fields.get("level", 0),
    }

# Build the JA -> [item names] map.
ja_to_items = {}
def add(ja, en):
    ja_to_items.setdefault(ja, []).append(en)

for job, kind, family, slot_map in SET_FAMILIES:
    job_bit = JOB_BITS[job]
    for slot, ja in slot_map.items():
        # Try every tier (NQ, +1, +2, +3) by enl pattern.
        slot_bit = SLOT_BITS[slot]
        for tier in ("", " +1", " +2", " +3"):
            # The enl key is the long english_log form -- it's never abbreviated
            # because there's no length limit on enl (only en is constrained).
            # Some families have apostrophes in the long form; ensure we
            # produce the same lowercase enl FFXI uses.
            enl_key = (family + tier).lower()
            # Try direct hit.
            it = items_by_enl.get(enl_key)
            # Sets sometimes have an alternate stem for one piece (e.g. body
            # "tunic", "lorica", "cyclas" etc). We search by family + slot_bit
            # if the direct enl match fails.
            if not it:
                # Walk all items matching family stem + slot + tier.
                cands = []
                for enl, idef in items_by_enl.items():
                    if not enl.startswith(family.lower() + " "):
                        continue
                    if not enl.endswith(tier.strip() if tier else "") and tier:
                        continue
                    if tier == "" and (" +1" in enl or " +2" in enl or " +3" in enl or " +4" in enl):
                        continue
                    if not (idef["slots"] & slot_bit):
                        continue
                    # Restrict to Reforged-era armor (lvl 99, item_level >= 109).
                    # The lvl 75/85 era originals collide with the Reforged set
                    # names by family stem but enhance different JAs (or none).
                    # Pinning to item_level 109+ disambiguates.
                    if idef.get("item_level", 0) < 109:
                        continue
                    # Same-family-stem coincidental items ("Azimuth Turban" =
                    # All-Jobs lvl 119 hat collides with Azimuth Empy set).
                    # The Reforged set is job-locked, so require the item's
                    # jobs bitmask to include this family's job and NOT be a
                    # broad "All Jobs"-style multimatch (Azimuth Turban's
                    # jobs=8388606 includes 22 jobs; a single-job piece has
                    # only ONE bit set).
                    if not (idef["jobs"] & job_bit):
                        continue
                    if bin(idef["jobs"]).count("1") > 3:
                        # More than 3 jobs flagged => generic gear, not a
                        # job-locked set piece. Skips Azimuth Turban (22),
                        # generic 99 gear, etc.
                        continue
                    cands.append(idef)
                if len(cands) == 1:
                    it = cands[0]
            if it and (it["slots"] & slot_bit):
                add(ja, it["en"])

# Emit Lua.
def lua_escape(s: str) -> str:
    return s.replace("\\", "\\\\").replace('"', '\\"')

with open(OUT, "w", encoding="utf-8", newline="\n") as f:
    f.write("-- =============================================================================\n")
    f.write("-- ja_enhance.lua  --  AUTO-GENERATED by data/generate_ja_enhance.py\n")
    f.write("--\n")
    f.write("-- Source: Windower res/items.lua (en + enl fields).\n")
    f.write("-- DO NOT hand-edit. Re-run the generator after items.lua updates.\n")
    f.write("--\n")
    f.write("-- JA name -> list of item.en values that enhance it. Used by\n")
    f.write("-- inventory_scanner.find_active_filters to surface the JA as a sort\n")
    f.write("-- option whenever the player owns at least one enhancer item.\n")
    f.write("-- =============================================================================\n\n")
    f.write("return {\n")
    for ja in sorted(ja_to_items.keys()):
        names = sorted(set(ja_to_items[ja]))
        f.write(f'  ["{lua_escape(ja)}"] = {{\n')
        for n in names:
            f.write(f'    "{lua_escape(n)}",\n')
        f.write("  },\n")
    f.write("}\n")

# Stats line.
ja_count = len(ja_to_items)
item_count = sum(len(set(v)) for v in ja_to_items.values())
print(f"Wrote {OUT}")
print(f"  {ja_count} JA filters, {item_count} item entries.")
