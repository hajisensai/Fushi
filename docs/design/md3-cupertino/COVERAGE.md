# MD3 + Cupertino coverage map

This file maps current Hibiki UI files to the design boards in this folder. It is a checklist for the redesign spec. It does not change runtime code.

## Design board index

| Board | Scope |
| --- | --- |
| `01-home-navigation.svg` | App shell, tabs, navigation rail, top actions |
| `02-reader-shelf.svg` | Library, history, covers, selection, import entry points |
| `03-dictionary.svg` | Search, history, result browsing, popup lookup |
| `04-reader.svg` | Hoshi reader chrome, lookup, audiobook bar, lyrics |
| `05-settings.svg` | Settings home and major settings sections |
| `06-import-and-modals.svg` | Import flows and generic modal/picker behavior |
| `07-creator-anki.svg` | Anki, card mining, segmentation, crop, recording |
| `08-collections-stats.svg` | Collections, reading statistics, illustrations |
| `09-system-debug.svg` | System, profile, language, logs, websocket overview |
| `10-dictionary-management.svg` | Installed dictionaries, import progress, ordering, CSS, audio sources |
| `11-reader-customization.svg` | Display settings, custom fonts, theme, book CSS, blur |
| `12-media-and-sentences.svg` | Media item dialogs, edit dialogs, source picker, examples, stash |
| `13-tags-and-filters.svg` | Tag management, tag picker, tag filter sheet, batch tag picker |
| `14-profile-language-system.svg` | Profiles, language, miscellaneous settings, websocket, icon choices |
| `15-logs-and-debug.svg` | Debug log, error log, diagnostics, operational messages |
| `16-empty-loading-error-states.svg` | Shared empty, loading, error, placeholder states |
| `17-full-coverage-map.svg` | Visual map of the board-to-page coverage |
| `18-component-system.svg` | Shared components for buttons, rows, search, bottom sheets, placeholders, popups, and selection |

## Page mapping

| File | Primary board | Secondary board |
| --- | --- | --- |
| `anki_settings_page.dart` | `07-creator-anki.svg` | `05-settings.svg` |
| `audio_recorder_page.dart` | `07-creator-anki.svg` | `12-media-and-sentences.svg` |
| `blur_options_dialog_page.dart` | `11-reader-customization.svg` | `06-import-and-modals.svg` |
| `book_css_editor_page.dart` | `11-reader-customization.svg` | `04-reader.svg` |
| `collections_page.dart` | `08-collections-stats.svg` | `12-media-and-sentences.svg` |
| `crop_image_dialog_page.dart` | `07-creator-anki.svg` | `12-media-and-sentences.svg` |
| `custom_fonts_page.dart` | `11-reader-customization.svg` | `05-settings.svg` |
| `custom_theme_page.dart` | `11-reader-customization.svg` | `05-settings.svg` |
| `debug_log_page.dart` | `15-logs-and-debug.svg` | `09-system-debug.svg` |
| `dictionary_dialog_delete_page.dart` | `10-dictionary-management.svg` | `06-import-and-modals.svg` |
| `dictionary_dialog_import_page.dart` | `10-dictionary-management.svg` | `06-import-and-modals.svg` |
| `dictionary_dialog_page.dart` | `10-dictionary-management.svg` | `03-dictionary.svg` |
| `dictionary_entry_page.dart` | `03-dictionary.svg` | `10-dictionary-management.svg` |
| `dictionary_page_mixin.dart` | `03-dictionary.svg` | `04-reader.svg` |
| `dictionary_popup_layer.dart` | `03-dictionary.svg` | `04-reader.svg` |
| `dictionary_popup_native.dart` | `03-dictionary.svg` | `04-reader.svg` |
| `dictionary_popup_webview.dart` | `03-dictionary.svg` | `04-reader.svg` |
| `dictionary_progress_dialog_content.dart` | `10-dictionary-management.svg` | `16-empty-loading-error-states.svg` |
| `dictionary_result_page.dart` | `03-dictionary.svg` | `12-media-and-sentences.svg` |
| `dictionary_settings_dialog_page.dart` | `10-dictionary-management.svg` | `05-settings.svg` |
| `dictionary_structured_content_page.dart` | `03-dictionary.svg` | `10-dictionary-management.svg` |
| `dictionary_term_page.dart` | `03-dictionary.svg` | `07-creator-anki.svg` |
| `dictionary_webview_media.dart` | `03-dictionary.svg` | `10-dictionary-management.svg` |
| `display_settings_page.dart` | `11-reader-customization.svg` | `04-reader.svg` |
| `error_log_page.dart` | `15-logs-and-debug.svg` | `16-empty-loading-error-states.svg` |
| `example_sentences_dialog_page.dart` | `12-media-and-sentences.svg` | `03-dictionary.svg` |
| `floating_dict_page.dart` | `03-dictionary.svg` | `14-profile-language-system.svg` |
| `history_reader_page.dart` | `02-reader-shelf.svg` | `13-tags-and-filters.svg` |
| `home_dictionary_page.dart` | `03-dictionary.svg` | `01-home-navigation.svg` |
| `home_page.dart` | `01-home-navigation.svg` | `05-settings.svg` |
| `home_reader_page.dart` | `01-home-navigation.svg` | `02-reader-shelf.svg` |
| `hoshi_settings_page.dart` | `05-settings.svg` | `11-reader-customization.svg` |
| `illustrations_viewer_page.dart` | `08-collections-stats.svg` | `12-media-and-sentences.svg` |
| `language_dialog_page.dart` | `14-profile-language-system.svg` | `06-import-and-modals.svg` |
| `loading_page.dart` | `16-empty-loading-error-states.svg` | `01-home-navigation.svg` |
| `lyrics_dialog_page.dart` | `04-reader.svg` | `12-media-and-sentences.svg` |
| `media_item_dialog_page.dart` | `12-media-and-sentences.svg` | `08-collections-stats.svg` |
| `media_item_edit_dialog_page.dart` | `12-media-and-sentences.svg` | `07-creator-anki.svg` |
| `media_source_picker_dialog_page.dart` | `12-media-and-sentences.svg` | `06-import-and-modals.svg` |
| `miscellaneous_settings_page.dart` | `14-profile-language-system.svg` | `05-settings.svg` |
| `open_stash_dialog_page.dart` | `12-media-and-sentences.svg` | `07-creator-anki.svg` |
| `placeholder_source_page.dart` | `16-empty-loading-error-states.svg` | `04-reader.svg` |
| `popup_dictionary_page.dart` | `03-dictionary.svg` | `14-profile-language-system.svg` |
| `profile_management_page.dart` | `14-profile-language-system.svg` | `05-settings.svg` |
| `reader_hoshi_history_page.dart` | `02-reader-shelf.svg` | `13-tags-and-filters.svg` |
| `reader_hoshi_page.dart` | `04-reader.svg` | `11-reader-customization.svg` |
| `reading_statistics_page.dart` | `08-collections-stats.svg` | `16-empty-loading-error-states.svg` |
| `switch_settings_page.dart` | `05-settings.svg` | `14-profile-language-system.svg` |
| `tag_filter_sheet.dart` | `13-tags-and-filters.svg` | `02-reader-shelf.svg` |
| `tag_management_page.dart` | `13-tags-and-filters.svg` | `05-settings.svg` |
| `tag_picker_page.dart` | `13-tags-and-filters.svg` | `06-import-and-modals.svg` |
| `text_segmentation_dialog_page.dart` | `07-creator-anki.svg` | `12-media-and-sentences.svg` |
| `websocket_dialog_page.dart` | `14-profile-language-system.svg` | `15-logs-and-debug.svg` |

## Shared component mapping

| File | Primary board | Secondary board |
| --- | --- | --- |
| `base_media_search_bar.dart` | `18-component-system.svg` | `03-dictionary.svg` |
| `base_page.dart` | `18-component-system.svg` | `16-empty-loading-error-states.svg` |
| `base_source_page.dart` | `18-component-system.svg` | `03-dictionary.svg` |
| `base_tab_page.dart` | `18-component-system.svg` | `01-home-navigation.svg` |
| `audiobook_import_dialog.dart` | `06-import-and-modals.svg` | `18-component-system.svg` |
| `audiobook_play_bar.dart` | `04-reader.svg` | `18-component-system.svg` |
| `book_import_dialog.dart` | `06-import-and-modals.svg` | `18-component-system.svg` |
| `jidoujisho_bottom_sheet.dart` | `18-component-system.svg` | `06-import-and-modals.svg` |
| `jidoujisho_dropdown.dart` | `18-component-system.svg` | `05-settings.svg` |
| `jidoujisho_icon_button.dart` | `18-component-system.svg` | `01-home-navigation.svg` |
| `jidoujisho_list_tile.dart` | `18-component-system.svg` | `05-settings.svg` |
| `jidoujisho_placeholder_message.dart` | `16-empty-loading-error-states.svg` | `18-component-system.svg` |
| `jidoujisho_popup_position.dart` | `18-component-system.svg` | `03-dictionary.svg` |
| `jidoujisho_search_history.dart` | `18-component-system.svg` | `03-dictionary.svg` |
| `jidoujisho_selectable_text.dart` | `18-component-system.svg` | `03-dictionary.svg` |
| `jidoujisho_tag.dart` | `13-tags-and-filters.svg` | `18-component-system.svg` |

## Current gap after this batch

Every current file under `hibiki/lib/src/pages/implementations/` now has a board-level design reference. The reusable UI components that drive search, rows, popups, placeholders, bottom sheets, and audiobook chrome also have a component-system board. The next real missing piece is the user choice pass and then a written implementation spec that converts the selected A/B/C directions into shared Flutter components, route-by-route behavior, and verification gates.
