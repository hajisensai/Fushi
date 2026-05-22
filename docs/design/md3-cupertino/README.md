# Hibiki MD3 + Cupertino design board

This folder is the first design-selection board for the MD3 + Cupertino redesign goal. It does not change runtime code yet.

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

## First batch images

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

## Current interface groups

| Group | Representative files | Notes |
| --- | --- | --- |
| Home shell | `home_page.dart`, `home_reader_page.dart`, `home_dictionary_page.dart`, `hoshi_settings_page.dart` | Mobile uses bottom navigation; wider layouts use `NavigationRail`. Redesign should preserve per-tab state. |
| Reader shelf | `reader_hoshi_history_page.dart`, `tag_filter_sheet.dart`, `book_import_dialog.dart`, `audiobook_import_dialog.dart` | Needs cover grid/list, tag chips, selection mode, import paths. |
| Dictionary | `home_dictionary_page.dart`, `dictionary_result_page.dart`, `dictionary_popup_layer.dart`, `dictionary_popup_webview.dart`, `dictionary_settings_dialog_page.dart` | Search should stay fast and history/results must not be confused. Popup behavior must remain shared with reader lookup. |
| Hoshi reader | `reader_hoshi_page.dart`, `audiobook_play_bar.dart`, `lyrics_dialog_page.dart`, `display_settings_page.dart`, `custom_fonts_page.dart`, `book_css_editor_page.dart` | Current reader is Hoshi. Design work must not route current-reader fixes to legacy TTU assets. |
| Creator and Anki | `anki_settings_page.dart`, `audio_recorder_page.dart`, `text_segmentation_dialog_page.dart`, `crop_image_dialog_page.dart`, `open_stash_dialog_page.dart` | Second batch. Needs form-heavy MD3 controls with Cupertino-style modal flow. |
| Collections and stats | `collections_page.dart`, `reading_statistics_page.dart`, `illustrations_viewer_page.dart` | Second batch. Needs list/detail and media actions. |
| System/debug | `miscellaneous_settings_page.dart`, `profile_management_page.dart`, `language_dialog_page.dart`, `debug_log_page.dart`, `error_log_page.dart`, `websocket_dialog_page.dart` | Second batch. Keep dense, predictable, low-decoration. |

## Design rules for this goal

- Use Flutter's existing `ThemeData(useMaterial3: true)` as the base, then replace old ad hoc surfaces with explicit tokens and shared components.
- Keep Android structure MD3-native: `NavigationBar`, `NavigationRail`, `SearchBar`, `FilledButton`, `SegmentedButton`, modal and persistent sheets.
- Borrow Cupertino behavior where it improves reading feel: large titles, quiet translucent chrome, grouped settings, bottom accessory bars, stable tab destinations.
- Do not rename persisted TTU/Hoshi compatibility keys during design implementation unless migration is explicitly designed and tested.
- Treat reader, dictionary lookup, and audiobook controls as shared interaction surfaces, not one-off styling jobs.

## Coverage status

This first pass covers every visible interface family in the current `hibiki/lib/src/pages/implementations/` tree at group level. After choices are made, each group still needs a precise implementation spec and smaller per-screen variants for edge states such as empty, loading, error, import blocked, selection mode, nested lookup, playback unavailable, and desktop width.
