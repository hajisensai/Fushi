# Hibiki MD3 + Cupertino implementation spec draft

This is the bridge from visual A/B/C choices to a runtime implementation plan. It is not the final implementation approval until the user confirms the selected choices.

## Selection Source

- Source: Hibiki Balanced pack
- Surfaces: 84
- Generated image choices: 252
- Sections: Entry 3, Pages 53, Shared/support 28
- Explicit surface picks imported: 0
- Board-level picks imported: 17
- Draft status: user choices imported

## Non-Negotiable Design Contract

- Use Flutter Material 3 as the base: `ThemeData(useMaterial3: true)`, `ColorScheme`, `TextTheme`, Material 3 buttons, bars, chips, sheets, menus, and dialogs.
- Add Cupertino behavior only where it improves reading calm or preference density: large titles, grouped settings, quiet translucent reader chrome, stable bottom accessory bars, and predictable sheet transitions.
- Current EPUB rendering is Hoshi. Reader implementation must stay on `ReaderHoshiPage`, `ReaderHoshiSource`, `reader_pagination_scripts.dart`, `reader_content_styles.dart`, `reader_selection_scripts.dart`, Hoshi resource interception, and `window.hoshiReader`.
- Do not rename persisted TTU/Hoshi compatibility keys unless a migration is explicitly designed and tested.
- Do not solve the redesign by page-local decoration. Shared tokens and components come first, then page groups inherit them.
- Dense operational surfaces may be compact, but they must not fake state. Empty, loading, error, import, and debug states need honest copy and visible recovery actions.

## Board Direction Summary

Choice counts are `A/B/C` across the exact mapped surfaces that use each board as their primary board.
Boards marked support-only are still part of the design language, but they currently appear only as secondary/support references in the surface matrix.

| Board | Image | Area | Choice counts | Dominant direction | Scope |
| --- | --- | --- | --- | --- | --- |
| 01 | [01-home-navigation.svg](01-home-navigation.svg) | Home and navigation | 0/0/3 | C: Adaptive mobile plus wider-layout shell | Main shell, bottom tabs, navigation rail, top actions. |
| 02 | [02-reader-shelf.svg](02-reader-shelf.svg) | Reader shelf | 3/0/0 | A: MD3 grid/list shelf | Library, history, covers, selection, import entry points. |
| 03 | [03-dictionary.svg](03-dictionary.svg) | Dictionary | 0/14/0 | B: Readable result browsing | Search, history, result browsing, popup lookup stack. |
| 04 | [04-reader.svg](04-reader.svg) | Hoshi reader | 0/3/0 | B: Immersive calm reader | Reading chrome, lookup overlay, audiobook bar, lyrics mode. |
| 05 | [05-settings.svg](05-settings.svg) | Settings | 0/2/0 | B: Grouped Cupertino settings | Profile, theme, reader settings, display, Anki, updates, logs. |
| 06 | [06-import-and-modals.svg](06-import-and-modals.svg) | Import and modals | 3/0/0 | A: Step-based MD3 flow | Book import, audiobook import, dictionary import, picker dialogs. |
| 07 | [07-creator-anki.svg](07-creator-anki.svg) | Creator and Anki | 0/0/4 | C: Mapping panel | Card mining fields, Anki settings, recorder, crop, segmentation. |
| 08 | [08-collections-stats.svg](08-collections-stats.svg) | Collections and stats | 3/0/0 | A: Scannable lists | Bookmarks, favorite sentences, reading statistics, illustration viewer. |
| 09 | [09-system-debug.svg](09-system-debug.svg) | System and debug | 0/0/0 | Support-only in current surface map | Language, profile management, miscellaneous settings, logs, websocket. |
| 10 | [10-dictionary-management.svg](10-dictionary-management.svg) | Dictionary management | 0/0/5 | C: Admin workspace | Installed dictionaries, import progress, ordering, CSS, audio sources. |
| 11 | [11-reader-customization.svg](11-reader-customization.svg) | Reader customization | 0/6/0 | B: Preview studio | Display settings, custom fonts, custom theme, book CSS, blur options. |
| 12 | [12-media-and-sentences.svg](12-media-and-sentences.svg) | Media and sentence dialogs | 5/0/0 | A: Mobile action sheet | Media item dialogs, edit dialogs, source picker, examples, stash, recorder. |
| 13 | [13-tags-and-filters.svg](13-tags-and-filters.svg) | Tags and filters | 0/0/4 | C: Batch editor | Tag management, tag picker, tag filter sheet, batch tag assignment. |
| 14 | [14-profile-language-system.svg](14-profile-language-system.svg) | Profile, language, system | 6/0/0 | A: Settings hub | Profiles, language, miscellaneous settings, websocket, app icon choices. |
| 15 | [15-logs-and-debug.svg](15-logs-and-debug.svg) | Logs and debug | 2/0/0 | A: Plain log viewer | Debug log, error log, diagnostics, low-memory and import messages. |
| 16 | [16-empty-loading-error-states.svg](16-empty-loading-error-states.svg) | Empty, loading, error states | 3/0/0 | A: Actionable empty state | Shared empty, loading, error, placeholder states. |
| 18 | [18-component-system.svg](18-component-system.svg) | Component system | 0/0/18 | C: Hybrid density kit | Shared buttons, rows, search, sheets, placeholders, popups, and selection grammar. |

## Runtime Architecture

1. Token layer: create one MD3 + Cupertino token source for color, radius, spacing, text scale, elevation, scrim, and motion. Keep cards at 8px radius or less unless the chosen board says a component is a sheet or modal.
2. Shared component layer: implement reusable search, list rows, grouped settings rows, bottom sheets, popups, segmented controls, icon buttons, placeholders, toast/snackbar surfaces, and reader accessory bars before rewriting individual pages.
3. Shell layer: update app entry, tab shell, navigation rail, popup dictionary shell, and floating dictionary shell without changing route state ownership.
4. Feature page layer: apply the selected surface choices by group. Route-level files should compose shared components instead of inventing local visual grammar.
5. Reader layer: treat Hoshi reader, dictionary lookup, audiobook bar, lyrics, restore state, and display settings as one interaction surface. Validate layout against WebView bounds, body bounds, and playback chrome bounds.

## Surface Matrix

### Entry

Entry surfaces define the app shell, process-text popup shell, and floating dictionary shell. They must keep startup/loading/error behavior separate from regular page content.

| Surface | Choice | Selected image | Source | Primary board | Support board |
| --- | --- | --- | --- | --- | --- |
| `main.dart` | C | [image](interface-images/main-C.svg) | board pick | 01 Home and navigation | 16 Empty, loading, error states |
| `popup_main.dart` | B | [image](interface-images/popup-main-B.svg) | board pick | 03 Dictionary | 16 Empty, loading, error states |
| `floating_dict_main.dart` | B | [image](interface-images/floating-dict-main-B.svg) | board pick | 03 Dictionary | 18 Component system |

### Pages

Page surfaces define route-level layout and interaction rhythm. They inherit shared tokens, but may use a board-specific choice when the screen has a clear workflow need.

| Surface | Choice | Selected image | Source | Primary board | Support board |
| --- | --- | --- | --- | --- | --- |
| `anki_settings_page.dart` | C | [image](interface-images/anki-settings-page-C.svg) | board pick | 07 Creator and Anki | 05 Settings |
| `audio_recorder_page.dart` | C | [image](interface-images/audio-recorder-page-C.svg) | board pick | 07 Creator and Anki | 12 Media and sentence dialogs |
| `blur_options_dialog_page.dart` | B | [image](interface-images/blur-options-dialog-page-B.svg) | board pick | 11 Reader customization | 06 Import and modals |
| `book_css_editor_page.dart` | B | [image](interface-images/book-css-editor-page-B.svg) | board pick | 11 Reader customization | 04 Hoshi reader |
| `collections_page.dart` | A | [image](interface-images/collections-page-A.svg) | board pick | 08 Collections and stats | 12 Media and sentence dialogs |
| `crop_image_dialog_page.dart` | C | [image](interface-images/crop-image-dialog-page-C.svg) | board pick | 07 Creator and Anki | 12 Media and sentence dialogs |
| `custom_fonts_page.dart` | B | [image](interface-images/custom-fonts-page-B.svg) | board pick | 11 Reader customization | 05 Settings |
| `custom_theme_page.dart` | B | [image](interface-images/custom-theme-page-B.svg) | board pick | 11 Reader customization | 05 Settings |
| `debug_log_page.dart` | A | [image](interface-images/debug-log-page-A.svg) | board pick | 15 Logs and debug | 09 System and debug |
| `dictionary_dialog_delete_page.dart` | C | [image](interface-images/dictionary-dialog-delete-page-C.svg) | board pick | 10 Dictionary management | 06 Import and modals |
| `dictionary_dialog_import_page.dart` | C | [image](interface-images/dictionary-dialog-import-page-C.svg) | board pick | 10 Dictionary management | 06 Import and modals |
| `dictionary_dialog_page.dart` | C | [image](interface-images/dictionary-dialog-page-C.svg) | board pick | 10 Dictionary management | 03 Dictionary |
| `dictionary_entry_page.dart` | B | [image](interface-images/dictionary-entry-page-B.svg) | board pick | 03 Dictionary | 10 Dictionary management |
| `dictionary_page_mixin.dart` | B | [image](interface-images/dictionary-page-mixin-B.svg) | board pick | 03 Dictionary | 04 Hoshi reader |
| `dictionary_popup_layer.dart` | B | [image](interface-images/dictionary-popup-layer-B.svg) | board pick | 03 Dictionary | 04 Hoshi reader |
| `dictionary_popup_native.dart` | B | [image](interface-images/dictionary-popup-native-B.svg) | board pick | 03 Dictionary | 04 Hoshi reader |
| `dictionary_popup_webview.dart` | B | [image](interface-images/dictionary-popup-webview-B.svg) | board pick | 03 Dictionary | 04 Hoshi reader |
| `dictionary_progress_dialog_content.dart` | C | [image](interface-images/dictionary-progress-dialog-content-C.svg) | board pick | 10 Dictionary management | 16 Empty, loading, error states |
| `dictionary_result_page.dart` | B | [image](interface-images/dictionary-result-page-B.svg) | board pick | 03 Dictionary | 12 Media and sentence dialogs |
| `dictionary_settings_dialog_page.dart` | C | [image](interface-images/dictionary-settings-dialog-page-C.svg) | board pick | 10 Dictionary management | 05 Settings |
| `dictionary_structured_content_page.dart` | B | [image](interface-images/dictionary-structured-content-page-B.svg) | board pick | 03 Dictionary | 10 Dictionary management |
| `dictionary_term_page.dart` | B | [image](interface-images/dictionary-term-page-B.svg) | board pick | 03 Dictionary | 07 Creator and Anki |
| `dictionary_webview_media.dart` | B | [image](interface-images/dictionary-webview-media-B.svg) | board pick | 03 Dictionary | 10 Dictionary management |
| `display_settings_page.dart` | B | [image](interface-images/display-settings-page-B.svg) | board pick | 11 Reader customization | 04 Hoshi reader |
| `error_log_page.dart` | A | [image](interface-images/error-log-page-A.svg) | board pick | 15 Logs and debug | 16 Empty, loading, error states |
| `example_sentences_dialog_page.dart` | A | [image](interface-images/example-sentences-dialog-page-A.svg) | board pick | 12 Media and sentence dialogs | 03 Dictionary |
| `floating_dict_page.dart` | B | [image](interface-images/floating-dict-page-B.svg) | board pick | 03 Dictionary | 14 Profile, language, system |
| `history_reader_page.dart` | A | [image](interface-images/history-reader-page-A.svg) | board pick | 02 Reader shelf | 13 Tags and filters |
| `home_dictionary_page.dart` | B | [image](interface-images/home-dictionary-page-B.svg) | board pick | 03 Dictionary | 01 Home and navigation |
| `home_page.dart` | C | [image](interface-images/home-page-C.svg) | board pick | 01 Home and navigation | 05 Settings |
| `home_reader_page.dart` | C | [image](interface-images/home-reader-page-C.svg) | board pick | 01 Home and navigation | 02 Reader shelf |
| `hoshi_settings_page.dart` | B | [image](interface-images/hoshi-settings-page-B.svg) | board pick | 05 Settings | 11 Reader customization |
| `illustrations_viewer_page.dart` | A | [image](interface-images/illustrations-viewer-page-A.svg) | board pick | 08 Collections and stats | 12 Media and sentence dialogs |
| `language_dialog_page.dart` | A | [image](interface-images/language-dialog-page-A.svg) | board pick | 14 Profile, language, system | 06 Import and modals |
| `loading_page.dart` | A | [image](interface-images/loading-page-A.svg) | board pick | 16 Empty, loading, error states | 01 Home and navigation |
| `lyrics_dialog_page.dart` | B | [image](interface-images/lyrics-dialog-page-B.svg) | board pick | 04 Hoshi reader | 12 Media and sentence dialogs |
| `media_item_dialog_page.dart` | A | [image](interface-images/media-item-dialog-page-A.svg) | board pick | 12 Media and sentence dialogs | 08 Collections and stats |
| `media_item_edit_dialog_page.dart` | A | [image](interface-images/media-item-edit-dialog-page-A.svg) | board pick | 12 Media and sentence dialogs | 07 Creator and Anki |
| `media_source_picker_dialog_page.dart` | A | [image](interface-images/media-source-picker-dialog-page-A.svg) | board pick | 12 Media and sentence dialogs | 06 Import and modals |
| `miscellaneous_settings_page.dart` | A | [image](interface-images/miscellaneous-settings-page-A.svg) | board pick | 14 Profile, language, system | 05 Settings |
| `open_stash_dialog_page.dart` | A | [image](interface-images/open-stash-dialog-page-A.svg) | board pick | 12 Media and sentence dialogs | 07 Creator and Anki |
| `placeholder_source_page.dart` | A | [image](interface-images/placeholder-source-page-A.svg) | board pick | 16 Empty, loading, error states | 04 Hoshi reader |
| `popup_dictionary_page.dart` | B | [image](interface-images/popup-dictionary-page-B.svg) | board pick | 03 Dictionary | 14 Profile, language, system |
| `profile_management_page.dart` | A | [image](interface-images/profile-management-page-A.svg) | board pick | 14 Profile, language, system | 05 Settings |
| `reader_hoshi_history_page.dart` | A | [image](interface-images/reader-hoshi-history-page-A.svg) | board pick | 02 Reader shelf | 13 Tags and filters |
| `reader_hoshi_page.dart` | B | [image](interface-images/reader-hoshi-page-B.svg) | board pick | 04 Hoshi reader | 11 Reader customization |
| `reading_statistics_page.dart` | A | [image](interface-images/reading-statistics-page-A.svg) | board pick | 08 Collections and stats | 16 Empty, loading, error states |
| `switch_settings_page.dart` | B | [image](interface-images/switch-settings-page-B.svg) | board pick | 05 Settings | 14 Profile, language, system |
| `tag_filter_sheet.dart` | C | [image](interface-images/tag-filter-sheet-C.svg) | board pick | 13 Tags and filters | 02 Reader shelf |
| `tag_management_page.dart` | C | [image](interface-images/tag-management-page-C.svg) | board pick | 13 Tags and filters | 05 Settings |
| `tag_picker_page.dart` | C | [image](interface-images/tag-picker-page-C.svg) | board pick | 13 Tags and filters | 06 Import and modals |
| `text_segmentation_dialog_page.dart` | C | [image](interface-images/text-segmentation-dialog-page-C.svg) | board pick | 07 Creator and Anki | 12 Media and sentence dialogs |
| `websocket_dialog_page.dart` | A | [image](interface-images/websocket-dialog-page-A.svg) | board pick | 14 Profile, language, system | 15 Logs and debug |

### Shared/support

Shared and support surfaces define reusable Flutter components. They must prevent page-by-page styling drift and should be implemented before broad page rewrites.

| Surface | Choice | Selected image | Source | Primary board | Support board |
| --- | --- | --- | --- | --- | --- |
| `app_model.dart` | C | [image](interface-images/app-model-C.svg) | board pick | 18 Component system | 14 Profile, language, system |
| `base_history_page.dart` | A | [image](interface-images/base-history-page-A.svg) | board pick | 02 Reader shelf | 16 Empty, loading, error states |
| `base_media_search_bar.dart` | C | [image](interface-images/base-media-search-bar-C.svg) | board pick | 18 Component system | 03 Dictionary |
| `base_page.dart` | C | [image](interface-images/base-page-C.svg) | board pick | 18 Component system | 16 Empty, loading, error states |
| `base_source_page.dart` | C | [image](interface-images/base-source-page-C.svg) | board pick | 18 Component system | 03 Dictionary |
| `base_tab_page.dart` | C | [image](interface-images/base-tab-page-C.svg) | board pick | 18 Component system | 01 Home and navigation |
| `audiobook_import_dialog.dart` | A | [image](interface-images/audiobook-import-dialog-A.svg) | board pick | 06 Import and modals | 18 Component system |
| `audiobook_play_bar.dart` | B | [image](interface-images/audiobook-play-bar-B.svg) | board pick | 04 Hoshi reader | 18 Component system |
| `book_import_dialog.dart` | A | [image](interface-images/book-import-dialog-A.svg) | board pick | 06 Import and modals | 18 Component system |
| `sasayaki_rematch.dart` | A | [image](interface-images/sasayaki-rematch-A.svg) | board pick | 06 Import and modals | 04 Hoshi reader |
| `profile_selector.dart` | A | [image](interface-images/profile-selector-A.svg) | board pick | 14 Profile, language, system | 18 Component system |
| `hibiki_bottom_sheet.dart` | C | [image](interface-images/hibiki-bottom-sheet-C.svg) | board pick | 18 Component system | 06 Import and modals |
| `hibiki_divider.dart` | C | [image](interface-images/hibiki-divider-C.svg) | board pick | 18 Component system | 05 Settings |
| `hibiki_dropdown.dart` | C | [image](interface-images/hibiki-dropdown-C.svg) | board pick | 18 Component system | 05 Settings |
| `hibiki_icon_button.dart` | C | [image](interface-images/hibiki-icon-button-C.svg) | board pick | 18 Component system | 01 Home and navigation |
| `hibiki_list_tile.dart` | C | [image](interface-images/hibiki-list-tile-C.svg) | board pick | 18 Component system | 05 Settings |
| `hibiki_marquee.dart` | C | [image](interface-images/hibiki-marquee-C.svg) | board pick | 18 Component system | 12 Media and sentence dialogs |
| `hibiki_placeholder_message.dart` | A | [image](interface-images/hibiki-placeholder-message-A.svg) | board pick | 16 Empty, loading, error states | 18 Component system |
| `hibiki_popup_position.dart` | C | [image](interface-images/hibiki-popup-position-C.svg) | board pick | 18 Component system | 03 Dictionary |
| `hibiki_search_history.dart` | C | [image](interface-images/hibiki-search-history-C.svg) | board pick | 18 Component system | 03 Dictionary |
| `hibiki_selectable_text.dart` | C | [image](interface-images/hibiki-selectable-text-C.svg) | board pick | 18 Component system | 03 Dictionary |
| `hibiki_tag.dart` | C | [image](interface-images/hibiki-tag-C.svg) | board pick | 13 Tags and filters | 18 Component system |
| `hibiki_text_selection_controls.dart` | C | [image](interface-images/hibiki-text-selection-controls-C.svg) | board pick | 18 Component system | 03 Dictionary |
| `hibiki_toast.dart` | C | [image](interface-images/hibiki-toast-C.svg) | board pick | 18 Component system | 15 Logs and debug |
| `platform_utils.dart` | C | [image](interface-images/platform-utils-C.svg) | board pick | 18 Component system | 01 Home and navigation |
| `swipe_dismiss_wrapper.dart` | C | [image](interface-images/swipe-dismiss-wrapper-C.svg) | board pick | 18 Component system | 06 Import and modals |
| `update_checker.dart` | A | [image](interface-images/update-checker-A.svg) | board pick | 14 Profile, language, system | 15 Logs and debug |
| `blur_options.dart` | B | [image](interface-images/blur-options-B.svg) | board pick | 11 Reader customization | 18 Component system |

## Imported Notes

- Baseline: Hibiki Balanced.
- Reader stays calm; management surfaces stay dense.
- Shared components use hybrid density so pages do not drift.

## Implementation Gates

Before runtime implementation starts:

1. User confirms this spec or supplies revised picks.
2. Run `node docs\design\md3-cupertino\verify-interface-coverage.mjs` and keep `interfaceCoverage=ok`.
3. Write the implementation plan from this spec, grouped by shared components first and page families second.

Before claiming runtime completion:

1. Run `D:\flutter_sdk\flutter_extracted\flutter\bin\dart.bat format .`.
2. Run `D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat test`.
3. For Hoshi reader UI changes, validate on a real emulator or the user-specified device with screenshots/UI hierarchy/log evidence.
4. Reader manual validation must cover cover image page, long vertical text page, audiobook bar bottom layout, play/pause, previous/next cue, follow-audio jump, chapter boundary behavior, first open after import, and restart restore.
