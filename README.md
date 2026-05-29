<!-- BEGIN DISCLAIMER (managed by FFXIWindower author; do not remove) -->
## ⚠️ Disclaimer — Use at Your Own Risk

This is unofficial, fan-made software for *Final Fantasy XI*. It is **not affiliated with, endorsed by, or supported by Square Enix Holdings Co., Ltd.** FINAL FANTASY is a registered trademark of Square Enix.

**Square Enix's official position is that third-party tools and modifications to the FFXI client are prohibited by the Terms of Service.** Installing or using this software may result in account suspension, account termination, character data loss, or other action taken by Square Enix at their sole discretion.

This software is provided **AS IS, without warranty of any kind**, express or implied — including but not limited to warranties of merchantability, fitness for a particular purpose, and non-infringement. In no event shall the author or contributors be liable for any claim, damages, account action, lost time, lost progress, file corruption, or any other liability arising from the use of, or inability to use, this software.

**By installing, building, or running this software you acknowledge that you understand and accept these risks.**

<!-- END DISCLAIMER -->
# GSUI — GSUI + GearTree-style GearSwap integration

**Status: in development.** This is a fork of [GSUI](https://github.com/mullerdane85-hash/GSUI)
that adds direct read/edit/save integration with your currently-loaded
GearSwap Lua file, similar to [GearTree](https://github.com/tru2/GearTree).

GSUI runs **side-by-side with GSUI** so the stable addon stays working
while we iterate on the new features here.

## Key differences from GSUI

| | GSUI | GSUI |
|---|---|---|
| Toggle key | `B` | `N` |
| Slash command | `//gsui` | `//gsui` (or `//g2`) |
| Data file | `GSUI/data/...` | `GSUI/data/...` (separate settings) |
| Window title | "GSUI" | "GSUI" |

Both addons can be loaded at the same time — they don't share state or
keybinds.

## Planned features (the "incorporate GearTree" work)

- [ ] Auto-detect the currently-loaded GearSwap file based on the
      player's job (e.g. `Kalitzo_whm.lua` for WHM).
- [ ] Parse the file as text (not execute) to extract the `sets` table
      hierarchy — idle, engaged, precast, midcast, etc.
- [ ] New "Sets" tab showing the gear sets as a clickable tree.
      Click to expand / preview; double-click to equip via `gs equip`.
- [ ] Right-click a set to see its full slot-by-slot contents + augments
      detected via `extdata.decode`.
- [ ] Edit a set's slot in-place inside GSUI's UI, then save back to
      the source `.lua` file with an automatic backup.
- [ ] Annotation/note system for sets without modifying the source.
- [ ] Undo last save via `//gsui undo` (restore latest backup).

Heavy inspiration / reference implementation: [tru2/GearTree](https://github.com/tru2/GearTree)
(public domain / Unlicense — code may be ported or bundled freely).

## Inherits everything from GSUI 1.3.0

All the existing tabs and features are preserved:
- GearSwap set builder (`F1`)
- Inventory organizer with multi-select + bulk-move (`F2`)
- KB/Drag mode toggle (`F3`)
- Filter dropdown (`F4`)
- Gear Stats / Total Stats toggle
- Icon extraction from FFXI DAT files
- Save/load named sets (`/gsui save <name>` / `/gsui load <name>`)

See the [GSUI 1.3.0 changelog](https://github.com/mullerdane85-hash/GSUI/blob/main/README.md)
for the full list of inherited features.

## Credits

Inherits all of GSUI's credits (Rubenator, Trv, Byrthnoth — see GSUI's
README for details), plus:

- **tru2** — author of GearTree. The parser / tree / writer design that
  the planned Sets-tab work draws from is GearTree's. Bundled or ported
  code will live under `libs/gear_tree/` once added.

## Development notes

This addon is unstable while the GearTree integration is being built.
For day-to-day use, run **GSUI** (the stable one). Load GSUI only when
testing the new features:

```
//lua load GSUI
```
