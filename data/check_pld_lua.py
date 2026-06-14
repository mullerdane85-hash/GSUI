#!/usr/bin/env python3
"""Cross-reference Kalitzo_pld.lua against item_jobs.json + the gs export
inventory. Flags non-PLD-equippable picks AND items that aren't in the
player's inventory.
"""
import json
import re
from pathlib import Path

PLD_LUA = Path(r"C:\Users\Jason\Desktop\Windower\addons\GearSwap\data\Kalitzo_pld.lua")
ITEM_JOBS = Path(r"C:\Users\Jason\Desktop\Windower\addons\GSUI\data\item_jobs.json")
EXPORT  = Path(r"C:\Users\Jason\Desktop\Windower\addons\GearSwap\data\export\Kalitzo 2026-06-08 18-14-28.lua")

JOB = 'PLD'

item_jobs = json.loads(ITEM_JOBS.read_text(encoding='utf-8'))
text = PLD_LUA.read_text(encoding='utf-8')
text = re.sub(r'--\[\[.*?\]\]', '', text, flags=re.DOTALL)
text = re.sub(r'--[^\n]*', '', text)

slot_re = re.compile(
    r'(?:^|[\s\{\(,])'
    r'(?:main|sub|range|ammo|head|neck|left_ear|right_ear|body|hands|left_ring|right_ring|back|waist|legs|feet|name)\s*='
    r'\s*"([^"]+)"',
    re.MULTILINE
)
referenced = set(slot_re.findall(text))

# Inventory: every named item in the latest export
export_text = EXPORT.read_text(encoding='utf-8')
INVENTORY = set(re.findall(r'(?:item|main|sub|range|ammo|head|neck|left_ear|right_ear|body|hands|left_ring|right_ring|back|waist|legs|feet)="([^"]+)"', export_text))
INVENTORY |= set(re.findall(r'name="([^"]+)"', export_text))

missing_db, wrong_job, missing_inv, ok = [], [], [], []
for name in sorted(referenced):
    jobs = item_jobs.get(name)
    if jobs is None:
        missing_db.append(name)
        continue
    if 'All Jobs' not in jobs and JOB not in jobs:
        wrong_job.append((name, jobs))
        continue
    if name not in INVENTORY:
        missing_inv.append(name)
        continue
    ok.append(name)

print(f'Total unique items referenced: {len(referenced)}')
print(f'  OK (PLD-eq + in inventory):  {len(ok)}')
print(f'  WRONG JOB (cannot equip):    {len(wrong_job)}')
print(f'  NOT IN INVENTORY:            {len(missing_inv)}')
print(f'  NOT IN DB:                   {len(missing_db)}')
print()
if wrong_job:
    print('=== WRONG JOB -- PLD CANNOT EQUIP ===')
    for name, jobs in wrong_job:
        print(f'  {name!r:30}  jobs={jobs}')
    print()
if missing_inv:
    print('=== NOT IN INVENTORY ===')
    for name in missing_inv:
        print(f'  {name}')
    print()
if missing_db:
    print('=== NOT IN ITEM_JOBS DB ===')
    for name in missing_db:
        print(f'  {name}')
