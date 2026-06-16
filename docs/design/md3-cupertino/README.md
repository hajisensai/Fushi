# Hibiki MD3 + Cupertino design board

This folder is the design-selection board for the MD3 + Cupertino redesign goal. It does not change runtime code yet.

## Start Here

| Need | Open |
| --- | --- |
| Chinese decision flow | [SELECTION_GUIDE.zh-CN.md](SELECTION_GUIDE.zh-CN.md) |
| Fastest per-screen picker | [interface-pack-comparison.html](interface-pack-comparison.html) |
| Printable 84-surface table | [INTERFACE_DECISION_MATRIX.zh-CN.md](INTERFACE_DECISION_MATRIX.zh-CN.md) |
| Whole-app baseline comparison | [pack-selection-index.html](pack-selection-index.html) |
| Representative image comparison | [design-pack-gallery.html](design-pack-gallery.html) |
| One-page board gallery | [gallery.html](gallery.html) |
| Exact per-interface visual gallery | [interface-gallery.html](interface-gallery.html) |
| Review queue with standalone images | [interface-images/index.html](interface-images/index.html) |
| Board-level crops only | [variant-gallery.html](variant-gallery.html) |

## Recommended Flow

1. Start with [SELECTION_GUIDE.zh-CN.md](SELECTION_GUIDE.zh-CN.md) or the recommended Hibiki Balanced pack.
2. Use [interface-pack-comparison.html](interface-pack-comparison.html) for final per-interface picks; it shows A/B/C images, pack defaults, local saved state, reviewed/unreviewed tracking, and copyable final-selection text.
3. Use [INTERFACE_DECISION_MATRIX.zh-CN.md](INTERFACE_DECISION_MATRIX.zh-CN.md) when you want the same 84 surfaces in Markdown table form.
4. Generate the implementation spec from the copied picks before touching Flutter code.

## Pick Format

Reply with the copied result or with choices like:

```text
Home A
Shelf B
Dictionary C
Reader A
Settings B
```

You can also mix details, for example `Reader B, but use A's bottom bar`.

For a complete board worksheet, use [PICKS.md](PICKS.md). For final implementation input, use copied text from [interface-pack-comparison.html](interface-pack-comparison.html), [interface-gallery.html](interface-gallery.html), or [interface-images/index.html](interface-images/index.html); all three copied formats are accepted by `generate-implementation-spec.mjs`.

Start from [RECOMMENDED_FINAL_SELECTION.zh-CN.txt](RECOMMENDED_FINAL_SELECTION.zh-CN.txt) when you want a ready-to-edit Hibiki Balanced picks file with high-risk surfaces called out, or [FINAL_SELECTION_TEMPLATE.zh-CN.md](FINAL_SELECTION_TEMPLATE.zh-CN.md) if you want a blank hand-edit template. For full baseline directions, start from [DESIGN_PACKS.md](DESIGN_PACKS.md) or [design-pack-gallery.html](design-pack-gallery.html), then use [INTERFACE_DECISION_MATRIX.zh-CN.md](INTERFACE_DECISION_MATRIX.zh-CN.md) or [INTERFACE_PICKS.md](INTERFACE_PICKS.md) for file-by-file exceptions.

## Generate Specs

After choices are copied back into a text file, generate the implementation spec draft with:

```powershell
node .\generate-implementation-spec.mjs --pack hibiki-balanced --picks .\my-picks.txt --output .\IMPLEMENTATION_SPEC_DRAFT.md
```

To regenerate the reviewable final draft from the recommended Hibiki Balanced seed:

```powershell
node .\generate-implementation-spec.mjs --picks .\RECOMMENDED_FINAL_SELECTION.zh-CN.txt --output .\IMPLEMENTATION_SPEC_FINAL_DRAFT.md
```

Use `--pack hibiki-balanced` without `--picks` to generate the recommended hybrid spec directly. A picks file may also contain `Pack: hibiki-balanced`, so a final selection can be generated with only `--picks`.

| Output | Meaning |
| --- | --- |
| [IMPLEMENTATION_SPEC_FINAL_DRAFT.md](IMPLEMENTATION_SPEC_FINAL_DRAFT.md) | Current reviewable final draft, generated from [RECOMMENDED_FINAL_SELECTION.zh-CN.txt](RECOMMENDED_FINAL_SELECTION.zh-CN.txt). |
| [IMPLEMENTATION_SPEC_HIBIKI_BALANCED.md](IMPLEMENTATION_SPEC_HIBIKI_BALANCED.md) | Pure pack-generated reference. |
| [IMPLEMENTATION_SPEC_DRAFT.md](IMPLEMENTATION_SPEC_DRAFT.md) | Manifest-default draft; useful before final choices only. |

## Selection images

| Area | Image | What it covers |
| --- | --- | --- |
| Home and navigation | [01-home-navigation.svg](01-home-navigation.svg) | Main app shell, bottom tabs, navigation rail, top actions |
| Reader shelf | [02-reader-shelf.svg](02-reader-shelf.svg) | Book library, tag filters, audiobook state, selection mode |
| Dictionary | [03-dictionary.svg](03-dictionary.svg) | Search, history, result browsing, popup lookup stack |
| Hoshi reader | [04-reader.svg](04-reader.svg) | Reading chrome, lookup overlay, audiobook bar, lyrics mode |
| Settings | [05-settings.svg](05-settings.svg) | Profile, theme, reader settings, display, Anki, updates, logs |
| Import and modals | [06-import-and-modals.svg](06-import-and-modals.svg) | Book import, audiobook import, dictionary import, picker dialogs |
| Creator and Anki | [07-creator-anki.svg](07-creator-anki.svg) | Card mining fields, Anki settings, recorder/crop/segmentation family |
| Collections and stats | [08-collections-stats.svg](08-collections-stats.svg) | Bookmarks, favorite sentences, reading statistics, illustration viewer |
| System and debug | [09-system-debug.svg](09-system-debug.svg) | Language, profile management, miscellaneous settings, logs, websocket |
| Dictionary management | [10-dictionary-management.svg](10-dictionary-management.svg) | Installed dictionaries, import progress, ordering, CSS, audio sources |
| Reader customization | [11-reader-customization.svg](11-reader-customization.svg) | Display settings, custom fonts, custom theme, book CSS, blur options |
| Media and sentence dialogs | [12-media-and-sentences.svg](12-media-and-sentences.svg) | Media item dialog, edit dialog, source picker, examples, stash, recorder |
| Tags and filters | [13-tags-and-filters.svg](13-tags-and-filters.svg) | Tag filter sheet, tag picker, tag management, batch tag assignment |
| Profile, language, system | [14-profile-language-system.svg](14-profile-language-system.svg) | Profiles, language, miscellaneous settings, websocket, app icon choices |
| Logs and debug | [15-logs-and-debug.svg](15-logs-and-debug.svg) | Debug log, error log, diagnostics, low-memory and import messages |
| Empty/loading/error states | [16-empty-loading-error-states.svg](16-empty-loading-error-states.svg) | Shared state model for empty, loading, error, placeholder pages |
| Full coverage map | [17-full-coverage-map.svg](17-full-coverage-map.svg) | Visual map from page families to design boards |
| Component system | [18-component-system.svg](18-component-system.svg) | Shared buttons, rows, search, sheets, placeholders, popups, and selection grammar |

The [interface pack comparison](interface-pack-comparison.html) is the fastest exception picker: it shows A/B/C images and all pack defaults per interface, lets you click the final pick in place, tracks reviewed/unreviewed surfaces, can jump to the next unreviewed surface, and exports text that `generate-implementation-spec.mjs` accepts directly. [INTERFACE_DECISION_MATRIX.zh-CN.md](INTERFACE_DECISION_MATRIX.zh-CN.md) is the printable Markdown decision table for the same 84 surfaces. The [pack selection index](pack-selection-index.html) expands all four whole-app baselines across the full 84-surface map. The [design pack gallery](design-pack-gallery.html) compares the same baselines using representative interface images. The [variant gallery](variant-gallery.html) crops the runtime design boards into 51 standalone A/B/C examples. The [interface gallery](interface-gallery.html) expands those into 252 visible choices across 84 mapped UI surfaces. The [interface image pack](interface-images/index.html) writes the same 252 choices as individual SVG image files plus a manifest, and lets you move through the review queue, jump to the next unpicked surface, filter to only unpicked surfaces, and click choices directly before copying the result. Board 17 is excluded there because it is a coverage map, not a runtime interface style.

See [COVERAGE.md](COVERAGE.md) for the file-by-file mapping from current Flutter UI files to these boards, [INTERFACE_PICKS.md](INTERFACE_PICKS.md) for per-interface choices, and [UI_COVERAGE_AUDIT.md](UI_COVERAGE_AUDIT.md) for the scan evidence.

## Verification

Run the coverage gate after changing UI files, board mappings, gallery surfaces, or generated images:

```powershell
node .\verify-interface-coverage.mjs
```

Regenerate the Markdown-wide decision matrix after changing packs or interface images:

```powershell
node .\generate-interface-decision-matrix.mjs
```

The coverage gate scans current non-generated Dart files under `hibiki/lib`, finds UI-building files, checks that every matched UI file is mapped in `COVERAGE.md`, then verifies `interface-gallery.html`, `interface-images/manifest.json`, [INTERFACE_DECISION_MATRIX.zh-CN.md](INTERFACE_DECISION_MATRIX.zh-CN.md), and the generated A/B/C SVG files agree.

## Current interface groups

| Group | Representative files | Notes |
| --- | --- | --- |
| Home shell | `home_page.dart`, `home_reader_page.dart`, `home_dictionary_page.dart`, `hoshi_settings_page.dart` | Mobile uses bottom navigation; wider layouts use `NavigationRail`. Redesign should preserve per-tab state. |
| Reader shelf | `reader_hoshi_history_page.dart`, `tag_filter_sheet.dart`, `book_import_dialog.dart`, `audiobook_import_dialog.dart` | Needs cover grid/list, tag chips, selection mode, import paths. |
| Dictionary | `home_dictionary_page.dart`, `dictionary_result_page.dart`, `dictionary_popup_layer.dart`, `dictionary_popup_webview.dart`, `dictionary_settings_dialog_page.dart` | Search should stay fast and history/results must not be confused. Popup behavior must remain shared with reader lookup. |
| Hoshi reader | `reader_hoshi_page.dart`, `audiobook_play_bar.dart`, `lyrics_dialog_page.dart`, `display_settings_page.dart`, `custom_fonts_page.dart`, `book_css_editor_page.dart` | Current reader is Hoshi. Design work must not route current-reader fixes to legacy TTU assets. |
| Creator and Anki | `anki_settings_page.dart`, `audio_recorder_page.dart`, `text_segmentation_dialog_page.dart`, `crop_image_dialog_page.dart`, `open_stash_dialog_page.dart` | Needs form-heavy MD3 controls with Cupertino-style modal flow. |
| Collections and stats | `collections_page.dart`, `reading_statistics_page.dart`, `illustrations_viewer_page.dart` | Needs list/detail and media actions. |
| System/debug | `miscellaneous_settings_page.dart`, `profile_management_page.dart`, `language_dialog_page.dart`, `debug_log_page.dart`, `error_log_page.dart`, `websocket_dialog_page.dart` | Keep dense, predictable, low-decoration. |
| Dictionary management | `dictionary_dialog_page.dart`, `dictionary_dialog_import_page.dart`, `dictionary_settings_dialog_page.dart`, `dictionary_progress_dialog_content.dart` | Needs installed-dictionary inventory, import progress, CSS editing, and local audio source setup. |
| Reader customization | `display_settings_page.dart`, `custom_fonts_page.dart`, `custom_theme_page.dart`, `book_css_editor_page.dart`, `blur_options_dialog_page.dart` | Needs shared control grammar for sliders, segmented controls, previews, and editors. |
| Tags/media/support states | `tag_management_page.dart`, `tag_picker_page.dart`, `tag_filter_sheet.dart`, `media_item_dialog_page.dart`, `loading_page.dart`, `placeholder_source_page.dart` | Needs reusable modal frames and honest empty/loading/error states. |

## Design rules for this goal

- Use Flutter's existing `ThemeData(useMaterial3: true)` as the base, then replace old ad hoc surfaces with explicit tokens and shared components.
- Keep Android structure MD3-native: `NavigationBar`, `NavigationRail`, `SearchBar`, `FilledButton`, `SegmentedButton`, modal and persistent sheets.
- Borrow Cupertino behavior where it improves reading feel: large titles, quiet translucent chrome, grouped settings, bottom accessory bars, stable tab destinations.
- Do not rename persisted TTU/Hoshi compatibility keys during design implementation unless migration is explicitly designed and tested.
- Treat reader, dictionary lookup, and audiobook controls as shared interaction surfaces, not one-off styling jobs.
- Pick the shared component system before implementation so pages do not drift into one-off styling.

## Coverage status

Every current UI-building file matched under `hibiki/lib` now has a board-level design reference in `COVERAGE.md`, and reusable/support UI surfaces have a component-system board. `INTERFACE_PICKS.md`, the gallery's per-interface selector, and the generated image pack now cover 84 design surfaces: 3 entry surfaces, 53 page-level surfaces, and 28 shared/support surfaces. After choices are made, the next step is a precise implementation spec with shared Flutter components, route-by-route behavior, and verification gates. More pictures are useful only when a selected board still has unresolved variants.
