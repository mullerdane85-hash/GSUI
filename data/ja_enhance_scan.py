#!/usr/bin/env python3
"""Scan the latest gs export for JA-enhancing gear.

Catches two kinds:
  1. Augmented JA-enhance gear: items with literal 'Enhances "<JA>" effect'
     augment text (e.g. Bagua Tunic with Bolster aug).
  2. Base relic/empyrean gear that natively enhances a JA, even without
     an augment text line. Mapped here by set-family + slot.

Output: every owned JA enhancer with the JA it enhances, grouped by job.
"""
import re
import sys

EXPORT = r"C:\Users\Jason\Desktop\Windower\addons\GearSwap\data\export\Kalitzo 2026-06-09 20-22-20.lua"

exp = open(EXPORT, encoding="utf-8").read()
inv = set(re.findall(
    r'(?:item|main|sub|range|ammo|head|neck|left_ear|right_ear|body|hands|left_ring|right_ring|back|waist|legs|feet)="([^"]+)"',
    exp))
inv |= set(re.findall(r'name="([^"]+)"', exp))

# Relic family name -> (job, slot -> JA enhanced).
# Source: BG-Wiki per-piece tooltips (Bagua, Pummeler, Magus, Mochizuki, etc.)
RELIC = {
    "Pummeler":   ("WAR",  {"head":"Mighty Strikes","body":"Berserk","hands":"Aggressor","legs":"Defender","feet":"Warcry"}),
    "Hesychast":  ("MNK",  {"head":"Hundred Fists","body":"Focus","hands":"Chi Blast","legs":"Dodge","feet":"Counterstance"}),
    "Piety":      ("WHM",  {"head":"Benediction","body":"Devotion","hands":"Martyr","legs":"Divine Seal","feet":"Afflatus Solace"}),
    "Archmage":   ("BLM",  {"head":"Manafont","body":"Mana Wall","hands":"Magic Burst","legs":"Elemental Seal","feet":"Manafont Recast"}),
    "Atrophy":    ("RDM",  {"head":"Chainspell","body":"Convert","hands":"Composure","legs":"Saboteur","feet":"Composure Duration"}),
    "Pillager":   ("THF",  {"head":"Perfect Dodge","body":"Hide","hands":"Despoil","legs":"Conspirator","feet":"Trick Attack"}),
    "Caballarius":("PLD",  {"head":"Invincible","body":"Cover","hands":"Sentinel","legs":"Holy Circle","feet":"Chivalry"}),
    "Ignominy":   ("DRK",  {"head":"Blood Weapon","body":"Last Resort","hands":"Souleater","legs":"Arcane Circle","feet":"Diabolic Eye"}),
    "Pantin":     ("BST",  {"head":"Familiar","body":"Killer Instinct","hands":"Reward","legs":"Charm","feet":"Spur"}),
    "Bihu":       ("BRD",  {"head":"Soul Voice","body":"Troubadour","hands":"Tenuto","legs":"Marcato","feet":"Nightingale"}),
    "Arcadian":   ("RNG",  {"head":"Eagle Eye Shot","body":"Sharpshot","hands":"Bounty Shot","legs":"Velocity Shot","feet":"Snapshot"}),
    "Sakonji":    ("SAM",  {"head":"Meikyo Shisui","body":"Hagakure","hands":"Sekkanoki","legs":"Sengikori","feet":"Zanshin"}),
    "Mochizuki":  ("NIN",  {"head":"Mijin Gakure","body":"Yonin","hands":"Sange","legs":"Innin","feet":"Futae"}),
    "Vishap":     ("DRG",  {"head":"Spirit Surge","body":"Ancient Circle","hands":"Restoring Breath","legs":"Healing Breath","feet":"Spirit Link"}),
    "Convoker":   ("SMN",  {"head":"Astral Flow","body":"Astral Conduit","hands":"Mana Cede","legs":"Apogee","feet":"Elemental Siphon"}),
    "Magus":      ("BLU",  {"head":"Burst Affinity","body":"Chain Affinity","hands":"Diffusion","legs":"Efflux","feet":"Convergence"}),
    "Lanun":      ("COR",  {"head":"Wild Card","body":"Bust","hands":"Snake Eye","legs":"Random Deal","feet":"Fold"}),
    "Cirque":     ("PUP",  {"head":"Overdrive","body":"Repair","hands":"Maneuver","legs":"Heady Artifice","feet":"Tactical Switch"}),
    "Maxixi":     ("DNC",  {"head":"Trance","body":"Saber Dance","hands":"No Foot Rise","legs":"Climactic Flourish","feet":"Reverse Flourish"}),
    "Argute":     ("SCH",  {"head":"Tabula Rasa","body":"Modus Veritas","hands":"Sublimation","legs":"Enlightenment","feet":"Stratagem"}),
    "Bagua":      ("GEO",  {"head":"Widened Compass","body":"Bolster","hands":"Full Circle","legs":"Mending Halation","feet":"Radial Arcana"}),
    "Futhark":    ("RUN",  {"head":"Embolden","body":"Pflug","hands":"Lunge","legs":"Vivacious Pulse","feet":"Swordplay"}),
}

# Empyrean +0/Reforged set families (each job's lvl 109+ empy armor).
EMPY = {
    "Boii":        ("WAR",  {"head":"Restraint","body":"Aggressive Aim","hands":"Tomahawk","legs":"Blood Rage","feet":"Retaliation"}),
    "Hizamaru":    ("MNK",  {"head":"Mantra","body":"Footwork","hands":"Impetus","legs":"Formless Strikes","feet":"Inner Strength"}),
    "Ebers":       ("WHM",  {"head":"Divine Caress","body":"Asylum","hands":"Sacrosanctity","legs":"Esunaga Radius","feet":"Sacred Trust"}),
    "Wicce":       ("BLM",  {"head":"Subtle Sorcery","body":"Sublime Sorcery","hands":"Enmity Douse","legs":"Mana Wall Radius","feet":"Mana Wall Duration"}),
    "Lethargy":    ("RDM",  {"head":"Stymie","body":"Phalanx II","hands":"Temper II","legs":"Spontaneity","feet":"Magic Burst Spell Radius"}),
    "Skulker":     ("THF",  {"head":"Aura Steal","body":"Accomplice","hands":"Larceny","legs":"Collaborator","feet":"Feint"}),
    "Reverence":   ("PLD",  {"head":"Iron Will","body":"Fealty","hands":"Sepulcher","legs":"Palisade","feet":"Sentinel Duration"}),
    "Fallen":      ("DRK",  {"head":"Nether Void","body":"Muted Soul","hands":"Weapon Bash","legs":"Dark Seal","feet":"Diabolic Eye Duration"}),
    "Totemic":     ("BST",  {"head":"Bestial Loyalty","body":"Beast Affinity","hands":"Beast Healer","legs":"Beast Warder","feet":"Sic"}),
    "Brioso":      ("BRD",  {"head":"Maestoso","body":"Pianissimo","hands":"Tenuto Duration","legs":"Marcato Duration","feet":"Hymn of Krieg"}),
    "Orion":       ("RNG",  {"head":"Stealth Shot","body":"Recycle","hands":"Decoy Shot","legs":"Camouflage","feet":"Scavenge"}),
    "Wakido":      ("SAM",  {"head":"Shikikoyo","body":"Konzen-ittai","hands":"Hasso","legs":"Meditate","feet":"Seigan"}),
    "Hachiya":     ("NIN",  {"head":"Ninja Tool Expertise","body":"Migawari","hands":"Issekigan","legs":"Tonko Effect","feet":"Yonin Duration"}),
    "Pteroslaver": ("DRG",  {"head":"Empathy","body":"Strafe","hands":"Steady Wing","legs":"Wyvern Max HP","feet":"Wyvern HP"}),
    "Beckoner":    ("SMN",  {"head":"Mana Cede Duration","body":"Convergence","hands":"Avatar Favor","legs":"Smart Companion","feet":"Heavenly Caress"}),
    "Assimilator": ("BLU",  {"head":"Unbridled Wisdom","body":"Burst Affinity Duration","hands":"Azure Lore","legs":"Enchainment","feet":"Diffusion Duration"}),
    "Chasseur":    ("COR",  {"head":"Loaded Deck","body":"Triple Shot","hands":"Cutting Cards","legs":"Allies' Roll","feet":"Quick Draw"}),
    "Foire":       ("PUP",  {"head":"Activate","body":"Cooldown","hands":"Repair Duration","legs":"Ventriloquy","feet":"Role Reversal"}),
    "Horos":       ("DNC",  {"head":"Step Duration","body":"Building Flourish","hands":"Box Step","legs":"Quickstep","feet":"Striking Flourish"}),
    "Pedagogy":    ("SCH",  {"head":"Penury","body":"Parsimony","hands":"Manifestation","legs":"Accession","feet":"Klimaform"}),
    "Azimuth":     ("GEO",  {"head":"Full Circle","body":"Indi/Geo Radius","hands":"Curative Recantation","legs":"Entrust","feet":"Mending Halation"}),
    "Runeist":     ("RUN",  {"head":"One for All","body":"Battuta","hands":"Vivacious Pulse","legs":"Valiance","feet":"Inspiration"}),
}

# Inventory-display family aliases that don't match the family stem.
# E.g. user owns "Geomancy Galero" but the family key is "Geomancy" (AF, NOT relic).
# The GEO AF armor is technically "Geomancy" set — it predates Bagua.
AF_GEOMANCY = {  # Pre-relic GEO AF — same slot->JA mapping concept
    "Geomancy": ("GEO", {
        "head":  "Cardinal Chant",       # not a JA, but worth flagging in same column
        "body":  "Life Cycle Effect",    # GEO Life Cycle JA potency boost
        "hands": "Geomancy Skill",       # raw skill, not a JA
        "legs":  "Fast Cast",            # casting helper, not a JA
        "feet":  "Movement Speed",       # utility, not a JA
    }),
}

SLOT_TOKENS = {
    "head":  ["Mask","Bonnet","Galero","Petasos","Cap","Crown","Helm","Coronet","Burgonet",
              "Beret","Hat","Hood","Headpiece","Tiara","Bandana","Kavuk","Headgear",
              "Sallet","Visor","Jinpachi","Somen","Horn","Top","Khat","Diadem"],
    "body":  ["Lorica","Tunic","Robe","Cyclas","Doublet","Cuirass","Mail","Hauberk",
              "Casaque","Habit","Gambison","Justaucorps","Vest","Jubbah","Coat","Frock",
              "Briault","Lappa","Jerkin","Salonpas","Houppelande"],
    "hands": ["Mufflers","Gloves","Cuffs","Bracers","Vambraces","Gauntlets","Manopolas",
              "Bracelets","Mitaines","Mitts","Mittens","Bazubands","Dastanas","Kote",
              "Tekko","Bracers","Crackows"],
    "legs":  ["Cuisses","Slops","Pants","Trews","Subligar","Brais","Tights","Tassets",
              "Hose","Brayettes","Tonlet","Salvars","Lappas","Shalwar","Hakama","Bottoms"],
    "feet":  ["Sollerets","Crackows","Sandals","Greaves","Boots","Galoshes","Pumps",
              "Babouches","Gaiters","Toeshoes","Schuhs","Charuqs","Soques","Highboots",
              "Sabots","Loafers","Clogs","Slippers","Geta"],
}

def slot_of(item_name: str) -> str | None:
    for slot, tokens in SLOT_TOKENS.items():
        for t in tokens:
            if t in item_name:
                return slot
    return None

# Build a single registry to scan against.
SETS = {}
for fam, (job, m) in RELIC.items(): SETS[fam] = (job, "Relic", m)
for fam, (job, m) in EMPY.items():  SETS[fam] = (job, "Empy",  m)
for fam, (job, m) in AF_GEOMANCY.items(): SETS[fam] = (job, "AF", m)

owned_by_job = {}
for name in inv:
    for fam, (job, kind, slot_map) in SETS.items():
        if fam in name:
            slot = slot_of(name)
            if slot and slot in slot_map:
                owned_by_job.setdefault((job, kind), []).append((slot, name, slot_map[slot]))
            break

print("===== JA-enhance gear OWNED (relic + empyrean + GEO AF) =====")
for (job, kind), entries in sorted(owned_by_job.items()):
    print(f"\n[{job}] {kind}:")
    # Sort by slot order
    order = {"head":1,"body":2,"hands":3,"legs":4,"feet":5}
    entries.sort(key=lambda e: order.get(e[0], 9))
    seen = set()
    for slot, item, ja in entries:
        key = (slot, item)
        if key in seen: continue
        seen.add(key)
        print(f"  {slot:6}  {item:32}  enhances {ja!r}")

print()
print("===== Augment-text JA enhancers in inventory =====")
for m in re.finditer(r'name="([^"]+)"[^}]*augments=\{([^}]+)\}', exp):
    item, augs = m.group(1), m.group(2)
    for ja in re.findall(r'Enhances "([^"]+)" effect', augs):
        print(f"  {item:32}  enhances {ja!r}")
