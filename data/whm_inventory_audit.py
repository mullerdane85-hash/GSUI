#!/usr/bin/env python3
"""One-shot WHM inventory audit helper.

Parses Kalitzo's latest gs export, filters to WHM-equippable items via
item_jobs.json, attaches stats from item_stats.json, and groups by slot.
Output goes to whm_inventory_audit.txt next to this script -- a flat,
greppable view of every piece WHM can wear in current inventory with
its stats, so the GS-file audit doesn't have to repeat lookups.

Items with augments get their augment list appended in [brackets] so
the audit knows which physical cape (FC vs TP variant) it's looking at.
"""

import json
import re
from pathlib import Path
from collections import defaultdict

EXPORT = Path(r"C:\Users\Jason\Desktop\Windower\addons\GearSwap\data\export\Kalitzo 2026-06-07 21-53-22.lua")
ITEM_STATS = Path(r"C:\Users\Jason\Desktop\Windower\addons\GSUI\data\item_stats.json")
ITEM_JOBS  = Path(r"C:\Users\Jason\Desktop\Windower\addons\GSUI\data\item_jobs.json")
ITEMS_LUA  = Path(r"C:\Users\Jason\Desktop\Windower\res\items.lua")
OUTPUT     = Path(r"C:\Users\Jason\Desktop\Windower\addons\GSUI\data\whm_inventory_audit.txt")

JOB = 'WHM'

# Slot enum from Windower's res/slots.lua (the correct mapping --
# my first attempt at this was wrong, which is why the first audit
# report had earrings under RING and pants under EAR).
SLOT_BITS = {
    0:  'main',  1:  'sub',   2:  'range', 3:  'ammo',
    4:  'head',  5:  'body',  6:  'hands', 7:  'legs',
    8:  'feet',  9:  'neck',  10: 'waist',
    11: 'left_ear',  12: 'right_ear',
    13: 'left_ring', 14: 'right_ring',
    15: 'back',
}


def slot_from_bitmask(mask):
    """Items can be wearable in multiple slots (ear, ring). Returns the
    first canonical slot name we see in the bitmask."""
    for bit, name in SLOT_BITS.items():
        if mask & (1 << bit):
            # Map slot variants to a single category for grouping.
            if name in ('left_ear', 'right_ear'): return 'ear'
            if name in ('left_ring', 'right_ring'): return 'ring'
            return name
    return '?'


def parse_items_lua():
    """Build {name: {id, slot}} from items.lua. Used to slot items in
    the inventory; gs export doesn't carry slot info."""
    text = ITEMS_LUA.read_text(encoding='utf-8')
    pat = re.compile(
        r'\[(\d+)\]\s*=\s*\{'
        r'.*?\ben="([^"]+)"'
        r'.*?\bcategory="(Armor|Weapon)"'
        r'.*?\bslots=(\d+)'
    )
    out = {}
    for m in pat.finditer(text):
        item_id, name, _cat, slots_mask = m.groups()
        if name not in out:
            out[name] = {'id': int(item_id), 'slot': slot_from_bitmask(int(slots_mask))}
    return out


def parse_export(path):
    """Return list of (name, augments) tuples for every item line in the
    gs export. Augmented items appear as `slot={ name="X", augments={...} }`;
    bare items appear as `slot="X"` or `item="X"`."""
    text = path.read_text(encoding='utf-8')
    out = []

    # Augmented form -- need to match across newlines (augments table can wrap)
    aug_re = re.compile(
        r'(?:item|main|sub|range|ammo|head|neck|left_ear|right_ear|body|hands|left_ring|right_ring|back|waist|legs|feet)='
        r'\{\s*name="([^"]+)"\s*,\s*augments=\{([^}]+)\}',
        re.DOTALL
    )
    for m in aug_re.finditer(text):
        name, aug_body = m.groups()
        augs = re.findall(r"'([^']+)'", aug_body)
        out.append((name, augs))

    # Bare form
    bare_re = re.compile(r'(?:item|main|sub|range|ammo|head|neck|left_ear|right_ear|body|hands|left_ring|right_ring|back|waist|legs|feet)="([^"]+)"')
    for m in bare_re.finditer(text):
        name = m.group(1)
        out.append((name, []))

    return out


def main():
    item_stats = json.loads(ITEM_STATS.read_text(encoding='utf-8'))
    item_jobs  = json.loads(ITEM_JOBS.read_text(encoding='utf-8'))
    items_meta = parse_items_lua()
    inventory = parse_export(EXPORT)

    # Dedup -- one entry per (name, augs-key) so each physical item appears once.
    seen = set()
    deduped = []
    for name, augs in inventory:
        key = (name, tuple(augs))
        if key in seen: continue
        seen.add(key)
        deduped.append((name, augs))

    # Filter to WHM-equippable
    by_slot = defaultdict(list)
    for name, augs in deduped:
        jobs = item_jobs.get(name)
        if jobs is None:
            # Not in db -- assume non-equipment (consumable, material, etc).
            continue
        if 'All Jobs' not in jobs and JOB not in jobs:
            continue
        stats = item_stats.get(name)
        meta  = items_meta.get(name, {})
        slot  = meta.get('slot', '?')
        by_slot[slot].append({
            'name': name,
            'augments': augs,
            'stats': stats,
            'jobs': jobs,
        })

    # Write a flat text report
    lines = []
    lines.append('WHM-equippable inventory audit')
    lines.append(f'  Source: {EXPORT.name}')
    lines.append(f'  Stats:  item_stats.json  ({len(item_stats)} items)')
    lines.append(f'  Jobs:   item_jobs.json   ({len(item_jobs)} items)')
    lines.append('')

    slot_order = ['main','sub','range','ammo','head','neck','ear','body',
                  'hands','ring','back','waist','legs','feet','?']
    for slot in slot_order:
        if slot not in by_slot: continue
        items = sorted(by_slot[slot], key=lambda x: x['name'])
        lines.append(f'=== {slot.upper()} ({len(items)} items) ===')
        for item in items:
            line = f'  {item["name"]}'
            if item['augments']:
                line += '  AUG[' + ' | '.join(item['augments']) + ']'
            if item['stats']:
                stat_str = ', '.join(f'{k}={v}' for k, v in sorted(item['stats'].items()))
                line += f'  -- {stat_str}'
            else:
                line += '  -- (no stats in db)'
            lines.append(line)
        lines.append('')

    OUTPUT.write_text('\n'.join(lines), encoding='utf-8')
    print(f'Wrote {OUTPUT}')
    print(f'  {sum(len(v) for v in by_slot.values())} WHM-equippable items across {len(by_slot)} slot categories.')


if __name__ == '__main__':
    main()
