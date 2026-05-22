# MD3 + Cupertino interface picks

This file is the per-interface selector for the redesign. `COVERAGE.md` maps each current UI surface to design images; this file turns that map into a pick sheet.

Use [gallery.html](gallery.html) for the clickable version. It contains the same interface list plus the visual boards. The primary image supplies the `A` / `B` / `C` options for that interface; the secondary image is the supporting style to preserve. Use [variant-gallery.html](variant-gallery.html) when you want each A/B/C option as its own visual crop.

## Pick rule

- Pick one `A`, `B`, or `C` for every row, or accept the default from the primary board.
- Override individual rows only when a screen needs to differ from its board family.
- Board `17-full-coverage-map.svg` is documentation-only and is not assigned to runtime interfaces.
- The table covers 81 design surfaces: 53 page-level surfaces and 28 shared/support surfaces. The UI audit matched 78 build files; the extra 3 rows are manual UI support files already mapped in `COVERAGE.md`.

## Board defaults

| Board | Default |
| --- | --- |
| `01-home-navigation.svg` | C |
| `02-reader-shelf.svg` | A |
| `03-dictionary.svg` | B |
| `04-reader.svg` | B |
| `05-settings.svg` | B |
| `06-import-and-modals.svg` | A |
| `07-creator-anki.svg` | C |
| `08-collections-stats.svg` | A |
| `09-system-debug.svg` | C |
| `10-dictionary-management.svg` | C |
| `11-reader-customization.svg` | B |
| `12-media-and-sentences.svg` | A |
| `13-tags-and-filters.svg` | C |
| `14-profile-language-system.svg` | A |
| `15-logs-and-debug.svg` | A |
| `16-empty-loading-error-states.svg` | A |
| `18-component-system.svg` | C |

## Page surfaces

| Surface | Primary image | Secondary image | Default | Pick |
| --- | --- | --- | --- | --- |
| `anki_settings_page.dart` | [07](07-creator-anki.svg) | [05](05-settings.svg) | C |  |
| `audio_recorder_page.dart` | [07](07-creator-anki.svg) | [12](12-media-and-sentences.svg) | C |  |
| `blur_options_dialog_page.dart` | [11](11-reader-customization.svg) | [06](06-import-and-modals.svg) | B |  |
| `book_css_editor_page.dart` | [11](11-reader-customization.svg) | [04](04-reader.svg) | B |  |
| `collections_page.dart` | [08](08-collections-stats.svg) | [12](12-media-and-sentences.svg) | A |  |
| `crop_image_dialog_page.dart` | [07](07-creator-anki.svg) | [12](12-media-and-sentences.svg) | C |  |
| `custom_fonts_page.dart` | [11](11-reader-customization.svg) | [05](05-settings.svg) | B |  |
| `custom_theme_page.dart` | [11](11-reader-customization.svg) | [05](05-settings.svg) | B |  |
| `debug_log_page.dart` | [15](15-logs-and-debug.svg) | [09](09-system-debug.svg) | A |  |
| `dictionary_dialog_delete_page.dart` | [10](10-dictionary-management.svg) | [06](06-import-and-modals.svg) | C |  |
| `dictionary_dialog_import_page.dart` | [10](10-dictionary-management.svg) | [06](06-import-and-modals.svg) | C |  |
| `dictionary_dialog_page.dart` | [10](10-dictionary-management.svg) | [03](03-dictionary.svg) | C |  |
| `dictionary_entry_page.dart` | [03](03-dictionary.svg) | [10](10-dictionary-management.svg) | B |  |
| `dictionary_page_mixin.dart` | [03](03-dictionary.svg) | [04](04-reader.svg) | B |  |
| `dictionary_popup_layer.dart` | [03](03-dictionary.svg) | [04](04-reader.svg) | B |  |
| `dictionary_popup_native.dart` | [03](03-dictionary.svg) | [04](04-reader.svg) | B |  |
| `dictionary_popup_webview.dart` | [03](03-dictionary.svg) | [04](04-reader.svg) | B |  |
| `dictionary_progress_dialog_content.dart` | [10](10-dictionary-management.svg) | [16](16-empty-loading-error-states.svg) | C |  |
| `dictionary_result_page.dart` | [03](03-dictionary.svg) | [12](12-media-and-sentences.svg) | B |  |
| `dictionary_settings_dialog_page.dart` | [10](10-dictionary-management.svg) | [05](05-settings.svg) | C |  |
| `dictionary_structured_content_page.dart` | [03](03-dictionary.svg) | [10](10-dictionary-management.svg) | B |  |
| `dictionary_term_page.dart` | [03](03-dictionary.svg) | [07](07-creator-anki.svg) | B |  |
| `dictionary_webview_media.dart` | [03](03-dictionary.svg) | [10](10-dictionary-management.svg) | B |  |
| `display_settings_page.dart` | [11](11-reader-customization.svg) | [04](04-reader.svg) | B |  |
| `error_log_page.dart` | [15](15-logs-and-debug.svg) | [16](16-empty-loading-error-states.svg) | A |  |
| `example_sentences_dialog_page.dart` | [12](12-media-and-sentences.svg) | [03](03-dictionary.svg) | A |  |
| `floating_dict_page.dart` | [03](03-dictionary.svg) | [14](14-profile-language-system.svg) | B |  |
| `history_reader_page.dart` | [02](02-reader-shelf.svg) | [13](13-tags-and-filters.svg) | A |  |
| `home_dictionary_page.dart` | [03](03-dictionary.svg) | [01](01-home-navigation.svg) | B |  |
| `home_page.dart` | [01](01-home-navigation.svg) | [05](05-settings.svg) | C |  |
| `home_reader_page.dart` | [01](01-home-navigation.svg) | [02](02-reader-shelf.svg) | C |  |
| `hoshi_settings_page.dart` | [05](05-settings.svg) | [11](11-reader-customization.svg) | B |  |
| `illustrations_viewer_page.dart` | [08](08-collections-stats.svg) | [12](12-media-and-sentences.svg) | A |  |
| `language_dialog_page.dart` | [14](14-profile-language-system.svg) | [06](06-import-and-modals.svg) | A |  |
| `loading_page.dart` | [16](16-empty-loading-error-states.svg) | [01](01-home-navigation.svg) | A |  |
| `lyrics_dialog_page.dart` | [04](04-reader.svg) | [12](12-media-and-sentences.svg) | B |  |
| `media_item_dialog_page.dart` | [12](12-media-and-sentences.svg) | [08](08-collections-stats.svg) | A |  |
| `media_item_edit_dialog_page.dart` | [12](12-media-and-sentences.svg) | [07](07-creator-anki.svg) | A |  |
| `media_source_picker_dialog_page.dart` | [12](12-media-and-sentences.svg) | [06](06-import-and-modals.svg) | A |  |
| `miscellaneous_settings_page.dart` | [14](14-profile-language-system.svg) | [05](05-settings.svg) | A |  |
| `open_stash_dialog_page.dart` | [12](12-media-and-sentences.svg) | [07](07-creator-anki.svg) | A |  |
| `placeholder_source_page.dart` | [16](16-empty-loading-error-states.svg) | [04](04-reader.svg) | A |  |
| `popup_dictionary_page.dart` | [03](03-dictionary.svg) | [14](14-profile-language-system.svg) | B |  |
| `profile_management_page.dart` | [14](14-profile-language-system.svg) | [05](05-settings.svg) | A |  |
| `reader_hoshi_history_page.dart` | [02](02-reader-shelf.svg) | [13](13-tags-and-filters.svg) | A |  |
| `reader_hoshi_page.dart` | [04](04-reader.svg) | [11](11-reader-customization.svg) | B |  |
| `reading_statistics_page.dart` | [08](08-collections-stats.svg) | [16](16-empty-loading-error-states.svg) | A |  |
| `switch_settings_page.dart` | [05](05-settings.svg) | [14](14-profile-language-system.svg) | B |  |
| `tag_filter_sheet.dart` | [13](13-tags-and-filters.svg) | [02](02-reader-shelf.svg) | C |  |
| `tag_management_page.dart` | [13](13-tags-and-filters.svg) | [05](05-settings.svg) | C |  |
| `tag_picker_page.dart` | [13](13-tags-and-filters.svg) | [06](06-import-and-modals.svg) | C |  |
| `text_segmentation_dialog_page.dart` | [07](07-creator-anki.svg) | [12](12-media-and-sentences.svg) | C |  |
| `websocket_dialog_page.dart` | [14](14-profile-language-system.svg) | [15](15-logs-and-debug.svg) | A |  |

## Shared and support surfaces

| Surface | Primary image | Secondary image | Default | Pick |
| --- | --- | --- | --- | --- |
| `app_model.dart` | [18](18-component-system.svg) | [14](14-profile-language-system.svg) | C |  |
| `base_history_page.dart` | [02](02-reader-shelf.svg) | [16](16-empty-loading-error-states.svg) | A |  |
| `base_media_search_bar.dart` | [18](18-component-system.svg) | [03](03-dictionary.svg) | C |  |
| `base_page.dart` | [18](18-component-system.svg) | [16](16-empty-loading-error-states.svg) | C |  |
| `base_source_page.dart` | [18](18-component-system.svg) | [03](03-dictionary.svg) | C |  |
| `base_tab_page.dart` | [18](18-component-system.svg) | [01](01-home-navigation.svg) | C |  |
| `audiobook_import_dialog.dart` | [06](06-import-and-modals.svg) | [18](18-component-system.svg) | A |  |
| `audiobook_play_bar.dart` | [04](04-reader.svg) | [18](18-component-system.svg) | B |  |
| `book_import_dialog.dart` | [06](06-import-and-modals.svg) | [18](18-component-system.svg) | A |  |
| `sasayaki_rematch.dart` | [06](06-import-and-modals.svg) | [04](04-reader.svg) | A |  |
| `profile_selector.dart` | [14](14-profile-language-system.svg) | [18](18-component-system.svg) | A |  |
| `jidoujisho_bottom_sheet.dart` | [18](18-component-system.svg) | [06](06-import-and-modals.svg) | C |  |
| `jidoujisho_divider.dart` | [18](18-component-system.svg) | [05](05-settings.svg) | C |  |
| `jidoujisho_dropdown.dart` | [18](18-component-system.svg) | [05](05-settings.svg) | C |  |
| `jidoujisho_icon_button.dart` | [18](18-component-system.svg) | [01](01-home-navigation.svg) | C |  |
| `jidoujisho_list_tile.dart` | [18](18-component-system.svg) | [05](05-settings.svg) | C |  |
| `jidoujisho_marquee.dart` | [18](18-component-system.svg) | [12](12-media-and-sentences.svg) | C |  |
| `jidoujisho_placeholder_message.dart` | [16](16-empty-loading-error-states.svg) | [18](18-component-system.svg) | A |  |
| `jidoujisho_popup_position.dart` | [18](18-component-system.svg) | [03](03-dictionary.svg) | C |  |
| `jidoujisho_search_history.dart` | [18](18-component-system.svg) | [03](03-dictionary.svg) | C |  |
| `jidoujisho_selectable_text.dart` | [18](18-component-system.svg) | [03](03-dictionary.svg) | C |  |
| `jidoujisho_tag.dart` | [13](13-tags-and-filters.svg) | [18](18-component-system.svg) | C |  |
| `jidoujisho_text_selection_controls.dart` | [18](18-component-system.svg) | [03](03-dictionary.svg) | C |  |
| `hibiki_toast.dart` | [18](18-component-system.svg) | [15](15-logs-and-debug.svg) | C |  |
| `platform_utils.dart` | [18](18-component-system.svg) | [01](01-home-navigation.svg) | C |  |
| `swipe_dismiss_wrapper.dart` | [18](18-component-system.svg) | [06](06-import-and-modals.svg) | C |  |
| `update_checker.dart` | [14](14-profile-language-system.svg) | [15](15-logs-and-debug.svg) | A |  |
| `blur_options.dart` | [11](11-reader-customization.svg) | [18](18-component-system.svg) | B |  |

## Copy format

```text
Interface picks:
anki_settings_page.dart: C
audio_recorder_page.dart: C
...
Notes:
```

After you choose, the implementation spec should freeze both levels:

1. Board defaults define the broad visual family.
2. Interface picks define screen-specific exceptions.
3. Shared/support picks define reusable Flutter components so pages do not drift.
