# Hibiki MD3 + Cupertino design board

This folder is the design-selection board for the MD3 + Cupertino redesign goal. It does not change runtime code yet.

## Pick format

Reply with choices like:

```text
Home A
Shelf B
Dictionary C
Reader A
Settings B
```

You can also mix details, for example `Reader B, but use A's bottom bar`.

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

See [COVERAGE.md](COVERAGE.md) for the file-by-file mapping from current Flutter pages to these boards.

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

## Coverage status

Every current file under `hibiki/lib/src/pages/implementations/` now has a board-level design reference in `COVERAGE.md`. After choices are made, the next step is a precise implementation spec with shared Flutter components, route-by-route behavior, and verification gates. More pictures are useful only when a selected board still has unresolved variants.
