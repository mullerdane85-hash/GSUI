#!/usr/bin/env python3
"""One-shot generator for item_jobs.json.

Walks Windower's res/items.lua, decodes the jobs bitmask on every armor
or weapon entry, and writes a flat JSON map:

    {
      "Epona's Ring": ["MNK","THF","BST","RNG","NIN","BLU","COR","PUP","DNC","RUN"],
      "Sherida Earring": ["MNK","RDM","THF","BST","RNG","DRG","DNC","RUN"],
      ...
    }

Jobs bitmask layout (from res/jobs.lua):
    bit  0  NONE   (skipped)
    bit  1  WAR
    bit  2  MNK
    bit  3  WHM
    bit  4  BLM
    bit  5  RDM
    bit  6  THF
    bit  7  PLD
    bit  8  DRK
    bit  9  BST
    bit 10  BRD
    bit 11  RNG
    bit 12  SAM
    bit 13  NIN
    bit 14  DRG
    bit 15  SMN
    bit 16  BLU
    bit 17  COR
    bit 18  PUP
    bit 19  DNC
    bit 20  SCH
    bit 21  GEO
    bit 22  RUN

A bitmask of 8388606 (= 0x7FFFFE = bits 1..22 all set) means All Jobs.

Run from anywhere -- paths below are absolute.
"""

import json
import re
from pathlib import Path

ITEMS_LUA = Path(r"C:\Users\Jason\Desktop\Windower\res\items.lua")
OUTPUT    = Path(r"C:\Users\Jason\Desktop\Windower\addons\GSUI\data\item_jobs.json")

JOB_NAMES = [
    None,   # bit 0 = NONE
    'WAR','MNK','WHM','BLM','RDM','THF','PLD','DRK','BST','BRD',
    'RNG','SAM','NIN','DRG','SMN','BLU','COR','PUP','DNC','SCH',
    'GEO','RUN',
]
ALL_JOBS_MASK = 0
for bit in range(1, 23):
    ALL_JOBS_MASK |= (1 << bit)


def decode_jobs(mask):
    """Bitmask -> list of job short names. 'All Jobs' returns the
    sentinel ['All Jobs'] so callers can short-circuit without iterating."""
    if mask == ALL_JOBS_MASK:
        return ['All Jobs']
    out = []
    for bit in range(1, 23):
        if mask & (1 << bit):
            out.append(JOB_NAMES[bit])
    return out


# Regex matches both Armor and Weapon entries, skipping materials/consumables.
# Each item entry is one line in items.lua.
ENTRY = re.compile(
    r'\[(\d+)\]\s*=\s*\{'
    r'.*?\ben="([^"]+)"'
    r'.*?\bcategory="(Armor|Weapon)"'
    r'.*?\bjobs=(\d+)'
)


def main():
    text = ITEMS_LUA.read_text(encoding='utf-8')
    result = {}
    # Skip items where jobs == 0 -- those are zero-equippability shells
    # (deprecated entries, NPC-only items, etc.).
    for m in ENTRY.finditer(text):
        item_id, name, _category, mask_str = m.groups()
        mask = int(mask_str)
        if mask == 0:
            continue
        jobs = decode_jobs(mask)
        # Many items share names across IDs (NQ vs HQ, augment variants).
        # We keep the first one we see; identical names always have
        # identical jobs in res.items.lua, so collisions are no-ops.
        if name not in result:
            result[name] = jobs

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(
        json.dumps(result, indent=1, ensure_ascii=False, sort_keys=True),
        encoding='utf-8',
    )
    print(f"wrote {len(result)} items -> {OUTPUT}")

    # Sanity-check with the three items I got wrong on Black Halo.
    for spot in ("Epona's Ring", "Sherida Earring", "Hetairoi Ring",
                 "Brutal Earring", "Rajas Ring", "Mache Earring +1"):
        print(f"  {spot!r:25} -> {result.get(spot, 'NOT FOUND')}")


if __name__ == '__main__':
    main()
