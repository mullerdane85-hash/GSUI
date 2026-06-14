#!/usr/bin/env python3
"""Cross-reference Kalitzo_geo.lua against item_jobs.json + the gs export
inventory. Flags non-GEO-equippable picks AND items not in inventory.
"""
import json
import re
from pathlib import Path

GEO_LUA = Path(r"C:\Users\Jason\Desktop\Windower\addons\GearSwap\data\Kalitzo_geo.lua")
ITEM_JOBS = Path(r"C:\Users\Jason\Desktop\Windower\addons\GSUI\data\item_jobs.json")
EXPORT  = Path(r"C:\Users\Jason\Desktop\Windower\addons\GearSwap\data\export\Kalitzo 2026-06-08 18-14-28.lua")

JOB = 'GEO'
item_jobs = json.loads(ITEM_JOBS.read_text(encoding='utf-8'))
text = GEO_LUA.read_text(encoding='utf-8')
text = re.sub(r'--\[\[.*?\]\]', '', text, flags=re.DOTALL)
text = re.sub(r'--[^\n]*', '', text)
slot_re = re.compile(
    r'(?:^|[\s\{\(,])'
    r'(?:main|sub|range|ammo|head|neck|left_ear|right_ear|body|hands|left_ring|right_ring|back|waist|legs|feet|name)\s*='
    r'\s*"([^"]+)"',
    re.MULTILINE
)
referenced = set(slot_re.findall(text))
export_text = EXPORT.read_text(encoding='utf-8')
INVENTORY = set(re.findall(r'(?:item|main|sub|range|ammo|head|neck|left_ear|right_ear|body|hands|left_ring|right_ring|back|waist|legs|feet)="([^"]+)"', export_text))
INVENTORY |= set(re.findall(r'name="([^"]+)"', export_text))

missing_db, wrong_job, missing_inv, ok = [], [], [], []
for name in sorted(referenced):
    jobs = item_jobs.get(name)
    if jobs is None: missing_db.append(name); continue
    if 'All Jobs' not in jobs and JOB not in jobs:
        wrong_job.append((name, jobs)); continue
    if name not in INVENTORY: missing_inv.append(name); continue
    ok.append(name)

print(f'Total: {len(referenced)} unique items')
print(f'  OK:           {len(ok)}')
print(f'  WRONG JOB:    {len(wrong_job)}')
print(f'  NOT IN INV:   {len(missing_inv)}')
print(f'  NOT IN DB:    {len(missing_db)}')
print()
for cat, lst in [('WRONG JOB', wrong_job), ('NOT IN INVENTORY', missing_inv), ('NOT IN DB', missing_db)]:
    if lst:
        print(f'=== {cat} ===')
        for x in lst:
            print(f'  {x}')
        print()
