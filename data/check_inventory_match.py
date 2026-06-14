#!/usr/bin/env python3
"""Cross-reference Kalitzo_whm.lua against the gs export inventory.

Flags items referenced by the lua that are NOT in the player's actual
inventory -- those will cause GearSwap to silently skip the slot when
trying to equip.
"""
import re
from pathlib import Path

WHM_LUA = Path(r"C:\Users\Jason\Desktop\Windower\addons\GearSwap\data\Kalitzo_whm.lua")
EXPORT  = Path(r"C:\Users\Jason\Desktop\Windower\addons\GearSwap\data\export\Kalitzo 2026-06-07 21-53-22.lua")

# Pull every name="X" or slot="X" reference from the export.
export_text = EXPORT.read_text(encoding='utf-8')
INVENTORY = set(re.findall(r'(?:item|main|sub|range|ammo|head|neck|left_ear|right_ear|body|hands|left_ring|right_ring|back|waist|legs|feet)="([^"]+)"', export_text))
# Also augmented form (`{ name="X", augments=...}`)
INVENTORY |= set(re.findall(r'name="([^"]+)"', export_text))

# Pull every referenced item from the lua (strip comments first).
lua_text = WHM_LUA.read_text(encoding='utf-8')
lua_text = re.sub(r'--\[\[.*?\]\]', '', lua_text, flags=re.DOTALL)
lua_text = re.sub(r'--[^\n]*', '', lua_text)
referenced = set(re.findall(r'(?:main|sub|range|ammo|head|neck|left_ear|right_ear|body|hands|left_ring|right_ring|back|waist|legs|feet|ear1|ear2|ring1|ring2|name)\s*=\s*"([^"]+)"', lua_text))

missing = sorted(referenced - INVENTORY)
print(f'WHM file references {len(referenced)} unique item names.')
print(f'Inventory has {len(INVENTORY)} unique items.')
print(f'Names referenced but NOT in inventory: {len(missing)}')
print()
for name in missing:
    print(f'  {name!r}')
