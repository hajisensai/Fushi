# MD3 + Cupertino picks

Use this worksheet to choose the direction for each board. Pick `A`, `B`, or `C`; add notes when you want a mix such as `B with A bottom bar`.

For visual review, open [gallery.html](gallery.html) in this folder. It shows all boards on one page, has clickable board-level `A` / `B` / `C` controls, and includes a per-interface selector for screen-specific exceptions.

Use [INTERFACE_PICKS.md](INTERFACE_PICKS.md) when you want to review every mapped UI surface as a table instead of clicking through the gallery.

Use [interface-gallery.html](interface-gallery.html) when you want each exact interface surface to show three A/B/C mockup images. Use [interface-images/index.html](interface-images/index.html) when you want those exact choices as standalone image files. Use [variant-gallery.html](variant-gallery.html) when you want each board direction as a separate crop instead of reading a dense three-column board.

## Recommended baseline

If you want the shortest path to a coherent implementation, start from this baseline and override only the rows you dislike:

| Board | Recommended | Why |
| --- | --- | --- |
| `01-home-navigation.svg` | C | Keeps mobile tabs and desktop rail/sidebar behavior coherent. |
| `02-reader-shelf.svg` | A | Best Android-default library layout with simple selection states. |
| `03-dictionary.svg` | B | Keeps lookup calm and readable while preserving result browsing. |
| `04-reader.svg` | B | Gives the reader the most Cupertino calm without hiding core controls. |
| `05-settings.svg` | B | Grouped settings reduce visual noise and fit reader preferences. |
| `06-import-and-modals.svg` | A | MD3 import steps are clearer for file-heavy flows. |
| `07-creator-anki.svg` | C | Dense forms and field mapping need power-user clarity. |
| `08-collections-stats.svg` | A | Lists and stats stay scannable. |
| `09-system-debug.svg` | C | Debug/system surfaces should be compact and operational. |
| `10-dictionary-management.svg` | C | Dictionary management benefits from table/details/log structure. |
| `11-reader-customization.svg` | B | Persistent preview plus grouped controls fits reading settings. |
| `12-media-and-sentences.svg` | A | Mobile action sheet is the safest default for sentence/media actions. |
| `13-tags-and-filters.svg` | C | Batch editing matters for library operations. |
| `14-profile-language-system.svg` | A | Settings hub keeps profile/language/system discoverable. |
| `15-logs-and-debug.svg` | A | Plain log viewer avoids decorative fake diagnostics. |
| `16-empty-loading-error-states.svg` | A | Empty states should be actionable and boring. |
| `17-full-coverage-map.svg` | B | The map is documentation only; no runtime direction needed. |
| `18-component-system.svg` | C | Hybrid density gives shared components enough structure without turning every page into a card wall. |

## Your picks

The fastest path is to use [gallery.html](gallery.html), click one option per board, then press `Copy result`. If you prefer editing manually, copy this block into chat and fill the choices:

```text
01:
02:
03:
04:
05:
06:
07:
08:
09:
10:
11:
12:
13:
14:
15:
16:
17:
18:
Notes:
```

## What happens after picks

1. Lock selected board directions and note any mixed details.
2. Lock per-interface exceptions for screens that should not follow their board default.
3. Write the implementation design spec with shared component tokens, page groups, migration risks, and verification gates.
4. Review the spec with you before touching runtime Flutter code.
5. Only after approval, turn the spec into an implementation plan.

The current coverage audit maps all 81 UI-building Dart files matched under `hibiki/lib` to the boards above. `INTERFACE_PICKS.md` and `interface-images/manifest.json` expand that into 84 design surfaces and 252 standalone image choices, including 3 manual UI support files already listed in `COVERAGE.md`. See `UI_COVERAGE_AUDIT.md` for the scan.
