#!/usr/bin/env python3
"""Cross-reference Kalitzo_whm.lua against item_jobs.json.

Lists every item the file references that is NOT WHM-equippable. These
are the highest-priority audit failures -- the gear can never actually
land on character because the server rejects equip packets for any
wrong-job slot.
"""
import json
import re
from pathlib import Path

WHM_LUA   = Path(r"C:\Users\Jason\Desktop\Windower\addons\GearSwap\data\Kalitzo_whm.lua")
ITEM_JOBS = Path(r"C:\Users\Jason\Desktop\Windower\addons\GSUI\data\item_jobs.json")

JOB = 'WHM'

# Extract item names from quoted strings in the lua file. We match
#   "Item Name"           bare-string form
#   { name="Item Name"    table-form item declarations
# and also variables (alaunus, alaunus_tp, sindri, vanya.head, etc.)
# but variables don't carry an item name in the line, so we only catch
# the literal-name references.
item_jobs = json.loads(ITEM_JOBS.read_text(encoding='utf-8'))
text = WHM_LUA.read_text(encoding='utf-8')
# strip lua comments so we don't flag commented-out picks
text = re.sub(r'--\[\[.*?\]\]', '', text, flags=re.DOTALL)
text = re.sub(r'--[^\n]*', '', text)

# Match anything that looks like a slot-keyed item reference. Catches:
#   head="Foo Bar"
#   right_ring = "Foo Bar"
#   { name="Foo Bar", augments=... }
slot_re = re.compile(
    r'(?:^|[\s\{\(,])'
    r'(?:main|sub|range|ammo|head|neck|left_ear|right_ear|body|hands|left_ring|right_ring|back|waist|legs|feet|name)\s*='
    r'\s*"([^"]+)"',
    re.MULTILINE
)
referenced = set(slot_re.findall(text))

missing = []           # not in jobs db (likely material or typo)
wrong_job = []         # in db but WHM can't equip
ok = []
for name in sorted(referenced):
    jobs = item_jobs.get(name)
    if jobs is None:
        missing.append(name)
        continue
    if 'All Jobs' not in jobs and JOB not in jobs:
        wrong_job.append((name, jobs))
        continue
    ok.append(name)

print(f'Total unique item names referenced: {len(referenced)}')
print(f'  OK (WHM can equip):       {len(ok)}')
print(f'  WRONG JOB (cannot equip): {len(wrong_job)}')
print(f'  NOT IN DB (verify):       {len(missing)}')
print()
if wrong_job:
    print('=== WRONG JOB -- WHM CANNOT EQUIP ===')
    for name, jobs in wrong_job:
        print(f'  {name!r:30}  jobs={jobs}')
    print()
if missing:
    print('=== NOT IN ITEM_JOBS DB ===')
    for name in missing:
        print(f'  {name}')
