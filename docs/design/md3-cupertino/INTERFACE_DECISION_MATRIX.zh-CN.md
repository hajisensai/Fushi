# Hibiki MD3 + Cupertino 全界面选择矩阵

这份文件是最终挑图时的中文总表。它从 [interface-images/manifest.json](interface-images/manifest.json) 和 [design-packs.json](design-packs.json) 生成，不手写界面清单。当前覆盖 84 个界面/支撑组件，每行都有 A/B/C 三张候选图；完整横向大图和可复制导出在 [interface-pack-comparison.html](interface-pack-comparison.html)。

## 使用方式

先选一个整包作为基准，再只改少量例外。推荐基准仍然是 `hibiki-balanced`。如果你想直接点图并导出最终文本，打开 [interface-pack-comparison.html](interface-pack-comparison.html)；如果想在 Markdown 里审查所有界面，用下面的表逐行看图，并在“最终选择”列记 A/B/C。

- `md3-practical` / MD3 Practical: Android-native clarity, predictable controls, and the lowest implementation risk.
- `reading-calm` / Reading Calm: Grouped settings, quiet reader chrome, and softer mobile-first navigation.
- `adaptive-power` / Adaptive Power: Dense workspaces, split panes, inspectors, and tablet or desktop readiness.
- `hibiki-balanced` / Hibiki Balanced: Calm reader surfaces, dense management surfaces, and strict shared component tokens.

## 判定规则

- 推荐列来自 `Hibiki Balanced`，它不是最终决定，只是当前实现起点。
- “四套整包默认”展示同一个界面在四种整体方向下会选哪张图。
- 最终实现前必须把确认结果保存成 picks 文件，再用 `generate-implementation-spec.mjs` 生成规格草案。
- 如果某行不确定，保留推荐值。例外越少，后续 Flutter token 和共享组件越不会分裂。

## 入口和外部壳层

| 界面 | 设计族 | 三张候选图 | 四套整包默认 | 推荐 | 最终选择 |
| --- | --- | --- | --- | --- | --- |
| `main.dart` | 首页和导航 | [A](interface-images/main-A.svg) [B](interface-images/main-B.svg) [C](interface-images/main-C.svg) | MD3 Practical: A<br>Reading Calm: B<br>Adaptive Power: C<br>Hibiki Balanced: C | C | |
| `popup_main.dart` | 词典 | [A](interface-images/popup-main-A.svg) [B](interface-images/popup-main-B.svg) [C](interface-images/popup-main-C.svg) | MD3 Practical: A<br>Reading Calm: B<br>Adaptive Power: C<br>Hibiki Balanced: B | B | |
| `floating_dict_main.dart` | 词典 | [A](interface-images/floating-dict-main-A.svg) [B](interface-images/floating-dict-main-B.svg) [C](interface-images/floating-dict-main-C.svg) | MD3 Practical: A<br>Reading Calm: B<br>Adaptive Power: C<br>Hibiki Balanced: B | B | |

## 页面

| 界面 | 设计族 | 三张候选图 | 四套整包默认 | 推荐 | 最终选择 |
| --- | --- | --- | --- | --- | --- |
| `anki_settings_page.dart` | 制卡和 Anki | [A](interface-images/anki-settings-page-A.svg) [B](interface-images/anki-settings-page-B.svg) [C](interface-images/anki-settings-page-C.svg) | MD3 Practical: A<br>Reading Calm: B<br>Adaptive Power: C<br>Hibiki Balanced: C | C | |
| `audio_recorder_page.dart` | 制卡和 Anki | [A](interface-images/audio-recorder-page-A.svg) [B](interface-images/audio-recorder-page-B.svg) [C](interface-images/audio-recorder-page-C.svg) | MD3 Practical: A<br>Reading Calm: B<br>Adaptive Power: C<br>Hibiki Balanced: C | C | |
| `blur_options_dialog_page.dart` | 阅读自定义 | [A](interface-images/blur-options-dialog-page-A.svg) [B](interface-images/blur-options-dialog-page-B.svg) [C](interface-images/blur-options-dialog-page-C.svg) | MD3 Practical: A<br>Reading Calm: B<br>Adaptive Power: C<br>Hibiki Balanced: B | B | |
| `book_css_editor_page.dart` | 阅读自定义 | [A](interface-images/book-css-editor-page-A.svg) [B](interface-images/book-css-editor-page-B.svg) [C](interface-images/book-css-editor-page-C.svg) | MD3 Practical: A<br>Reading Calm: B<br>Adaptive Power: C<br>Hibiki Balanced: B | B | |
| `collections_page.dart` | 收藏和统计 | [A](interface-images/collections-page-A.svg) [B](interface-images/collections-page-B.svg) [C](interface-images/collections-page-C.svg) | MD3 Practical: A<br>Reading Calm: B<br>Adaptive Power: C<br>Hibiki Balanced: A | A | |
| `crop_image_dialog_page.dart` | 制卡和 Anki | [A](interface-images/crop-image-dialog-page-A.svg) [B](interface-images/crop-image-dialog-page-B.svg) [C](interface-images/crop-image-dialog-page-C.svg) | MD3 Practical: A<br>Reading Calm: B<br>Adaptive Power: C<br>Hibiki Balanced: C | C | |
| `custom_fonts_page.dart` | 阅读自定义 | [A](interface-images/custom-fonts-page-A.svg) [B](interface-images/custom-fonts-page-B.svg) [C](interface-images/custom-fonts-page-C.svg) | MD3 Practical: A<br>Reading Calm: B<br>Adaptive Power: C<br>Hibiki Balanced: B | B | |
| `custom_theme_page.dart` | 阅读自定义 | [A](interface-images/custom-theme-page-A.svg) [B](interface-images/custom-theme-page-B.svg) [C](interface-images/custom-theme-page-C.svg) | MD3 Practical: A<br>Reading Calm: B<br>Adaptive Power: C<br>Hibiki Balanced: B | B | |
| `debug_log_page.dart` | 日志和调试 | [A](interface-images/debug-log-page-A.svg) [B](interface-images/debug-log-page-B.svg) [C](interface-images/debug-log-page-C.svg) | MD3 Practical: A<br>Reading Calm: B<br>Adaptive Power: C<br>Hibiki Balanced: A | A | |
| `dictionary_dialog_delete_page.dart` | 词典管理 | [A](interface-images/dictionary-dialog-delete-page-A.svg) [B](interface-images/dictionary-dialog-delete-page-B.svg) [C](interface-images/dictionary-dialog-delete-page-C.svg) | MD3 Practical: A<br>Reading Calm: B<br>Adaptive Power: C<br>Hibiki Balanced: C | C | |
| `dictionary_dialog_import_page.dart` | 词典管理 | [A](interface-images/dictionary-dialog-import-page-A.svg) [B](interface-images/dictionary-dialog-import-page-B.svg) [C](interface-images/dictionary-dialog-import-page-C.svg) | MD3 Practical: A<br>Reading Calm: B<br>Adaptive Power: C<br>Hibiki Balanced: C | C | |
| `dictionary_dialog_page.dart` | 词典管理 | [A](interface-images/dictionary-dialog-page-A.svg) [B](interface-images/dictionary-dialog-page-B.svg) [C](interface-images/dictionary-dialog-page-C.svg) | MD3 Practical: A<br>Reading Calm: B<br>Adaptive Power: C<br>Hibiki Balanced: C | C | |
| `dictionary_entry_page.dart` | 词典 | [A](interface-images/dictionary-entry-page-A.svg) [B](interface-images/dictionary-entry-page-B.svg) [C](interface-images/dictionary-entry-page-C.svg) | MD3 Practical: A<br>Reading Calm: B<br>Adaptive Power: C<br>Hibiki Balanced: B | B | |
| `dictionary_page_mixin.dart` | 词典 | [A](interface-images/dictionary-page-mixin-A.svg) [B](interface-images/dictionary-page-mixin-B.svg) [C](interface-images/dictionary-page-mixin-C.svg) | MD3 Practical: A<br>Reading Calm: B<br>Adaptive Power: C<br>Hibiki Balanced: B | B | |
| `dictionary_popup_layer.dart` | 词典 | [A](interface-images/dictionary-popup-layer-A.svg) [B](interface-images/dictionary-popup-layer-B.svg) [C](interface-images/dictionary-popup-layer-C.svg) | MD3 Practical: A<br>Reading Calm: B<br>Adaptive Power: C<br>Hibiki Balanced: B | B | |
| `dictionary_popup_native.dart` | 词典 | [A](interface-images/dictionary-popup-native-A.svg) [B](interface-images/dictionary-popup-native-B.svg) [C](interface-images/dictionary-popup-native-C.svg) | MD3 Practical: A<br>Reading Calm: B<br>Adaptive Power: C<br>Hibiki Balanced: B | B | |
| `dictionary_popup_webview.dart` | 词典 | [A](interface-images/dictionary-popup-webview-A.svg) [B](interface-images/dictionary-popup-webview-B.svg) [C](interface-images/dictionary-popup-webview-C.svg) | MD3 Practical: A<br>Reading Calm: B<br>Adaptive Power: C<br>Hibiki Balanced: B | B | |
| `dictionary_progress_dialog_content.dart` | 词典管理 | [A](interface-images/dictionary-progress-dialog-content-A.svg) [B](interface-images/dictionary-progress-dialog-content-B.svg) [C](interface-images/dictionary-progress-dialog-content-C.svg) | MD3 Practical: A<br>Reading Calm: B<br>Adaptive Power: C<br>Hibiki Balanced: C | C | |
| `dictionary_result_page.dart` | 词典 | [A](interface-images/dictionary-result-page-A.svg) [B](interface-images/dictionary-result-page-B.svg) [C](interface-images/dictionary-result-page-C.svg) | MD3 Practical: A<br>Reading Calm: B<br>Adaptive Power: C<br>Hibiki Balanced: B | B | |
| `dictionary_settings_dialog_page.dart` | 词典管理 | [A](interface-images/dictionary-settings-dialog-page-A.svg) [B](interface-images/dictionary-settings-dialog-page-B.svg) [C](interface-images/dictionary-settings-dialog-page-C.svg) | MD3 Practical: A<br>Reading Calm: B<br>Adaptive Power: C<br>Hibiki Balanced: C | C | |
| `dictionary_structured_content_page.dart` | 词典 | [A](interface-images/dictionary-structured-content-page-A.svg) [B](interface-images/dictionary-structured-content-page-B.svg) [C](interface-images/dictionary-structured-content-page-C.svg) | MD3 Practical: A<br>Reading Calm: B<br>Adaptive Power: C<br>Hibiki Balanced: B | B | |
| `dictionary_term_page.dart` | 词典 | [A](interface-images/dictionary-term-page-A.svg) [B](interface-images/dictionary-term-page-B.svg) [C](interface-images/dictionary-term-page-C.svg) | MD3 Practical: A<br>Reading Calm: B<br>Adaptive Power: C<br>Hibiki Balanced: B | B | |
| `dictionary_webview_media.dart` | 词典 | [A](interface-images/dictionary-webview-media-A.svg) [B](interface-images/dictionary-webview-media-B.svg) [C](interface-images/dictionary-webview-media-C.svg) | MD3 Practical: A<br>Reading Calm: B<br>Adaptive Power: C<br>Hibiki Balanced: B | B | |
| `display_settings_page.dart` | 阅读自定义 | [A](interface-images/display-settings-page-A.svg) [B](interface-images/display-settings-page-B.svg) [C](interface-images/display-settings-page-C.svg) | MD3 Practical: A<br>Reading Calm: B<br>Adaptive Power: C<br>Hibiki Balanced: B | B | |
| `error_log_page.dart` | 日志和调试 | [A](interface-images/error-log-page-A.svg) [B](interface-images/error-log-page-B.svg) [C](interface-images/error-log-page-C.svg) | MD3 Practical: A<br>Reading Calm: B<br>Adaptive Power: C<br>Hibiki Balanced: A | A | |
| `example_sentences_dialog_page.dart` | 媒体和例句弹窗 | [A](interface-images/example-sentences-dialog-page-A.svg) [B](interface-images/example-sentences-dialog-page-B.svg) [C](interface-images/example-sentences-dialog-page-C.svg) | MD3 Practical: A<br>Reading Calm: B<br>Adaptive Power: C<br>Hibiki Balanced: A | A | |
| `floating_dict_page.dart` | 词典 | [A](interface-images/floating-dict-page-A.svg) [B](interface-images/floating-dict-page-B.svg) [C](interface-images/floating-dict-page-C.svg) | MD3 Practical: A<br>Reading Calm: B<br>Adaptive Power: C<br>Hibiki Balanced: B | B | |
| `history_reader_page.dart` | 书架 | [A](interface-images/history-reader-page-A.svg) [B](interface-images/history-reader-page-B.svg) [C](interface-images/history-reader-page-C.svg) | MD3 Practical: A<br>Reading Calm: B<br>Adaptive Power: C<br>Hibiki Balanced: A | A | |
| `home_dictionary_page.dart` | 词典 | [A](interface-images/home-dictionary-page-A.svg) [B](interface-images/home-dictionary-page-B.svg) [C](interface-images/home-dictionary-page-C.svg) | MD3 Practical: A<br>Reading Calm: B<br>Adaptive Power: C<br>Hibiki Balanced: B | B | |
| `home_page.dart` | 首页和导航 | [A](interface-images/home-page-A.svg) [B](interface-images/home-page-B.svg) [C](interface-images/home-page-C.svg) | MD3 Practical: A<br>Reading Calm: B<br>Adaptive Power: C<br>Hibiki Balanced: C | C | |
| `home_reader_page.dart` | 首页和导航 | [A](interface-images/home-reader-page-A.svg) [B](interface-images/home-reader-page-B.svg) [C](interface-images/home-reader-page-C.svg) | MD3 Practical: A<br>Reading Calm: B<br>Adaptive Power: C<br>Hibiki Balanced: C | C | |
| `hoshi_settings_page.dart` | 设置 | [A](interface-images/hoshi-settings-page-A.svg) [B](interface-images/hoshi-settings-page-B.svg) [C](interface-images/hoshi-settings-page-C.svg) | MD3 Practical: A<br>Reading Calm: B<br>Adaptive Power: C<br>Hibiki Balanced: B | B | |
| `illustrations_viewer_page.dart` | 收藏和统计 | [A](interface-images/illustrations-viewer-page-A.svg) [B](interface-images/illustrations-viewer-page-B.svg) [C](interface-images/illustrations-viewer-page-C.svg) | MD3 Practical: A<br>Reading Calm: B<br>Adaptive Power: C<br>Hibiki Balanced: A | A | |
| `language_dialog_page.dart` | 资料、语言、系统 | [A](interface-images/language-dialog-page-A.svg) [B](interface-images/language-dialog-page-B.svg) [C](interface-images/language-dialog-page-C.svg) | MD3 Practical: A<br>Reading Calm: B<br>Adaptive Power: C<br>Hibiki Balanced: A | A | |
| `loading_page.dart` | 空、加载、错误状态 | [A](interface-images/loading-page-A.svg) [B](interface-images/loading-page-B.svg) [C](interface-images/loading-page-C.svg) | MD3 Practical: A<br>Reading Calm: B<br>Adaptive Power: C<br>Hibiki Balanced: A | A | |
| `lyrics_dialog_page.dart` | Hoshi 阅读器 | [A](interface-images/lyrics-dialog-page-A.svg) [B](interface-images/lyrics-dialog-page-B.svg) [C](interface-images/lyrics-dialog-page-C.svg) | MD3 Practical: A<br>Reading Calm: B<br>Adaptive Power: C<br>Hibiki Balanced: B | B | |
| `media_item_dialog_page.dart` | 媒体和例句弹窗 | [A](interface-images/media-item-dialog-page-A.svg) [B](interface-images/media-item-dialog-page-B.svg) [C](interface-images/media-item-dialog-page-C.svg) | MD3 Practical: A<br>Reading Calm: B<br>Adaptive Power: C<br>Hibiki Balanced: A | A | |
| `media_item_edit_dialog_page.dart` | 媒体和例句弹窗 | [A](interface-images/media-item-edit-dialog-page-A.svg) [B](interface-images/media-item-edit-dialog-page-B.svg) [C](interface-images/media-item-edit-dialog-page-C.svg) | MD3 Practical: A<br>Reading Calm: B<br>Adaptive Power: C<br>Hibiki Balanced: A | A | |
| `media_source_picker_dialog_page.dart` | 媒体和例句弹窗 | [A](interface-images/media-source-picker-dialog-page-A.svg) [B](interface-images/media-source-picker-dialog-page-B.svg) [C](interface-images/media-source-picker-dialog-page-C.svg) | MD3 Practical: A<br>Reading Calm: B<br>Adaptive Power: C<br>Hibiki Balanced: A | A | |
| `miscellaneous_settings_page.dart` | 资料、语言、系统 | [A](interface-images/miscellaneous-settings-page-A.svg) [B](interface-images/miscellaneous-settings-page-B.svg) [C](interface-images/miscellaneous-settings-page-C.svg) | MD3 Practical: A<br>Reading Calm: B<br>Adaptive Power: C<br>Hibiki Balanced: A | A | |
| `open_stash_dialog_page.dart` | 媒体和例句弹窗 | [A](interface-images/open-stash-dialog-page-A.svg) [B](interface-images/open-stash-dialog-page-B.svg) [C](interface-images/open-stash-dialog-page-C.svg) | MD3 Practical: A<br>Reading Calm: B<br>Adaptive Power: C<br>Hibiki Balanced: A | A | |
| `placeholder_source_page.dart` | 空、加载、错误状态 | [A](interface-images/placeholder-source-page-A.svg) [B](interface-images/placeholder-source-page-B.svg) [C](interface-images/placeholder-source-page-C.svg) | MD3 Practical: A<br>Reading Calm: B<br>Adaptive Power: C<br>Hibiki Balanced: A | A | |
| `popup_dictionary_page.dart` | 词典 | [A](interface-images/popup-dictionary-page-A.svg) [B](interface-images/popup-dictionary-page-B.svg) [C](interface-images/popup-dictionary-page-C.svg) | MD3 Practical: A<br>Reading Calm: B<br>Adaptive Power: C<br>Hibiki Balanced: B | B | |
| `profile_management_page.dart` | 资料、语言、系统 | [A](interface-images/profile-management-page-A.svg) [B](interface-images/profile-management-page-B.svg) [C](interface-images/profile-management-page-C.svg) | MD3 Practical: A<br>Reading Calm: B<br>Adaptive Power: C<br>Hibiki Balanced: A | A | |
| `reader_hoshi_history_page.dart` | 书架 | [A](interface-images/reader-hoshi-history-page-A.svg) [B](interface-images/reader-hoshi-history-page-B.svg) [C](interface-images/reader-hoshi-history-page-C.svg) | MD3 Practical: A<br>Reading Calm: B<br>Adaptive Power: C<br>Hibiki Balanced: A | A | |
| `reader_hoshi_page.dart` | Hoshi 阅读器 | [A](interface-images/reader-hoshi-page-A.svg) [B](interface-images/reader-hoshi-page-B.svg) [C](interface-images/reader-hoshi-page-C.svg) | MD3 Practical: A<br>Reading Calm: B<br>Adaptive Power: C<br>Hibiki Balanced: B | B | |
| `reading_statistics_page.dart` | 收藏和统计 | [A](interface-images/reading-statistics-page-A.svg) [B](interface-images/reading-statistics-page-B.svg) [C](interface-images/reading-statistics-page-C.svg) | MD3 Practical: A<br>Reading Calm: B<br>Adaptive Power: C<br>Hibiki Balanced: A | A | |
| `switch_settings_page.dart` | 设置 | [A](interface-images/switch-settings-page-A.svg) [B](interface-images/switch-settings-page-B.svg) [C](interface-images/switch-settings-page-C.svg) | MD3 Practical: A<br>Reading Calm: B<br>Adaptive Power: C<br>Hibiki Balanced: B | B | |
| `tag_filter_sheet.dart` | 标签和筛选 | [A](interface-images/tag-filter-sheet-A.svg) [B](interface-images/tag-filter-sheet-B.svg) [C](interface-images/tag-filter-sheet-C.svg) | MD3 Practical: A<br>Reading Calm: B<br>Adaptive Power: C<br>Hibiki Balanced: C | C | |
| `tag_management_page.dart` | 标签和筛选 | [A](interface-images/tag-management-page-A.svg) [B](interface-images/tag-management-page-B.svg) [C](interface-images/tag-management-page-C.svg) | MD3 Practical: A<br>Reading Calm: B<br>Adaptive Power: C<br>Hibiki Balanced: C | C | |
| `tag_picker_page.dart` | 标签和筛选 | [A](interface-images/tag-picker-page-A.svg) [B](interface-images/tag-picker-page-B.svg) [C](interface-images/tag-picker-page-C.svg) | MD3 Practical: A<br>Reading Calm: B<br>Adaptive Power: C<br>Hibiki Balanced: C | C | |
| `text_segmentation_dialog_page.dart` | 制卡和 Anki | [A](interface-images/text-segmentation-dialog-page-A.svg) [B](interface-images/text-segmentation-dialog-page-B.svg) [C](interface-images/text-segmentation-dialog-page-C.svg) | MD3 Practical: A<br>Reading Calm: B<br>Adaptive Power: C<br>Hibiki Balanced: C | C | |
| `websocket_dialog_page.dart` | 资料、语言、系统 | [A](interface-images/websocket-dialog-page-A.svg) [B](interface-images/websocket-dialog-page-B.svg) [C](interface-images/websocket-dialog-page-C.svg) | MD3 Practical: A<br>Reading Calm: B<br>Adaptive Power: C<br>Hibiki Balanced: A | A | |

## 共享和支撑组件

| 界面 | 设计族 | 三张候选图 | 四套整包默认 | 推荐 | 最终选择 |
| --- | --- | --- | --- | --- | --- |
| `app_model.dart` | 组件系统 | [A](interface-images/app-model-A.svg) [B](interface-images/app-model-B.svg) [C](interface-images/app-model-C.svg) | MD3 Practical: A<br>Reading Calm: B<br>Adaptive Power: C<br>Hibiki Balanced: C | C | |
| `base_history_page.dart` | 书架 | [A](interface-images/base-history-page-A.svg) [B](interface-images/base-history-page-B.svg) [C](interface-images/base-history-page-C.svg) | MD3 Practical: A<br>Reading Calm: B<br>Adaptive Power: C<br>Hibiki Balanced: A | A | |
| `base_media_search_bar.dart` | 组件系统 | [A](interface-images/base-media-search-bar-A.svg) [B](interface-images/base-media-search-bar-B.svg) [C](interface-images/base-media-search-bar-C.svg) | MD3 Practical: A<br>Reading Calm: B<br>Adaptive Power: C<br>Hibiki Balanced: C | C | |
| `base_page.dart` | 组件系统 | [A](interface-images/base-page-A.svg) [B](interface-images/base-page-B.svg) [C](interface-images/base-page-C.svg) | MD3 Practical: A<br>Reading Calm: B<br>Adaptive Power: C<br>Hibiki Balanced: C | C | |
| `base_source_page.dart` | 组件系统 | [A](interface-images/base-source-page-A.svg) [B](interface-images/base-source-page-B.svg) [C](interface-images/base-source-page-C.svg) | MD3 Practical: A<br>Reading Calm: B<br>Adaptive Power: C<br>Hibiki Balanced: C | C | |
| `base_tab_page.dart` | 组件系统 | [A](interface-images/base-tab-page-A.svg) [B](interface-images/base-tab-page-B.svg) [C](interface-images/base-tab-page-C.svg) | MD3 Practical: A<br>Reading Calm: B<br>Adaptive Power: C<br>Hibiki Balanced: C | C | |
| `audiobook_import_dialog.dart` | 导入和弹窗 | [A](interface-images/audiobook-import-dialog-A.svg) [B](interface-images/audiobook-import-dialog-B.svg) [C](interface-images/audiobook-import-dialog-C.svg) | MD3 Practical: A<br>Reading Calm: B<br>Adaptive Power: C<br>Hibiki Balanced: A | A | |
| `audiobook_play_bar.dart` | Hoshi 阅读器 | [A](interface-images/audiobook-play-bar-A.svg) [B](interface-images/audiobook-play-bar-B.svg) [C](interface-images/audiobook-play-bar-C.svg) | MD3 Practical: A<br>Reading Calm: B<br>Adaptive Power: C<br>Hibiki Balanced: B | B | |
| `book_import_dialog.dart` | 导入和弹窗 | [A](interface-images/book-import-dialog-A.svg) [B](interface-images/book-import-dialog-B.svg) [C](interface-images/book-import-dialog-C.svg) | MD3 Practical: A<br>Reading Calm: B<br>Adaptive Power: C<br>Hibiki Balanced: A | A | |
| `sasayaki_rematch.dart` | 导入和弹窗 | [A](interface-images/sasayaki-rematch-A.svg) [B](interface-images/sasayaki-rematch-B.svg) [C](interface-images/sasayaki-rematch-C.svg) | MD3 Practical: A<br>Reading Calm: B<br>Adaptive Power: C<br>Hibiki Balanced: A | A | |
| `profile_selector.dart` | 资料、语言、系统 | [A](interface-images/profile-selector-A.svg) [B](interface-images/profile-selector-B.svg) [C](interface-images/profile-selector-C.svg) | MD3 Practical: A<br>Reading Calm: B<br>Adaptive Power: C<br>Hibiki Balanced: A | A | |
| `hibiki_bottom_sheet.dart` | 组件系统 | [A](interface-images/hibiki-bottom-sheet-A.svg) [B](interface-images/hibiki-bottom-sheet-B.svg) [C](interface-images/hibiki-bottom-sheet-C.svg) | MD3 Practical: A<br>Reading Calm: B<br>Adaptive Power: C<br>Hibiki Balanced: C | C | |
| `hibiki_divider.dart` | 组件系统 | [A](interface-images/hibiki-divider-A.svg) [B](interface-images/hibiki-divider-B.svg) [C](interface-images/hibiki-divider-C.svg) | MD3 Practical: A<br>Reading Calm: B<br>Adaptive Power: C<br>Hibiki Balanced: C | C | |
| `hibiki_dropdown.dart` | 组件系统 | [A](interface-images/hibiki-dropdown-A.svg) [B](interface-images/hibiki-dropdown-B.svg) [C](interface-images/hibiki-dropdown-C.svg) | MD3 Practical: A<br>Reading Calm: B<br>Adaptive Power: C<br>Hibiki Balanced: C | C | |
| `hibiki_icon_button.dart` | 组件系统 | [A](interface-images/hibiki-icon-button-A.svg) [B](interface-images/hibiki-icon-button-B.svg) [C](interface-images/hibiki-icon-button-C.svg) | MD3 Practical: A<br>Reading Calm: B<br>Adaptive Power: C<br>Hibiki Balanced: C | C | |
| `hibiki_list_tile.dart` | 组件系统 | [A](interface-images/hibiki-list-tile-A.svg) [B](interface-images/hibiki-list-tile-B.svg) [C](interface-images/hibiki-list-tile-C.svg) | MD3 Practical: A<br>Reading Calm: B<br>Adaptive Power: C<br>Hibiki Balanced: C | C | |
| `hibiki_marquee.dart` | 组件系统 | [A](interface-images/hibiki-marquee-A.svg) [B](interface-images/hibiki-marquee-B.svg) [C](interface-images/hibiki-marquee-C.svg) | MD3 Practical: A<br>Reading Calm: B<br>Adaptive Power: C<br>Hibiki Balanced: C | C | |
| `hibiki_placeholder_message.dart` | 空、加载、错误状态 | [A](interface-images/hibiki-placeholder-message-A.svg) [B](interface-images/hibiki-placeholder-message-B.svg) [C](interface-images/hibiki-placeholder-message-C.svg) | MD3 Practical: A<br>Reading Calm: B<br>Adaptive Power: C<br>Hibiki Balanced: A | A | |
| `hibiki_popup_position.dart` | 组件系统 | [A](interface-images/hibiki-popup-position-A.svg) [B](interface-images/hibiki-popup-position-B.svg) [C](interface-images/hibiki-popup-position-C.svg) | MD3 Practical: A<br>Reading Calm: B<br>Adaptive Power: C<br>Hibiki Balanced: C | C | |
| `hibiki_search_history.dart` | 组件系统 | [A](interface-images/hibiki-search-history-A.svg) [B](interface-images/hibiki-search-history-B.svg) [C](interface-images/hibiki-search-history-C.svg) | MD3 Practical: A<br>Reading Calm: B<br>Adaptive Power: C<br>Hibiki Balanced: C | C | |
| `hibiki_selectable_text.dart` | 组件系统 | [A](interface-images/hibiki-selectable-text-A.svg) [B](interface-images/hibiki-selectable-text-B.svg) [C](interface-images/hibiki-selectable-text-C.svg) | MD3 Practical: A<br>Reading Calm: B<br>Adaptive Power: C<br>Hibiki Balanced: C | C | |
| `hibiki_tag.dart` | 标签和筛选 | [A](interface-images/hibiki-tag-A.svg) [B](interface-images/hibiki-tag-B.svg) [C](interface-images/hibiki-tag-C.svg) | MD3 Practical: A<br>Reading Calm: B<br>Adaptive Power: C<br>Hibiki Balanced: C | C | |
| `hibiki_text_selection_controls.dart` | 组件系统 | [A](interface-images/hibiki-text-selection-controls-A.svg) [B](interface-images/hibiki-text-selection-controls-B.svg) [C](interface-images/hibiki-text-selection-controls-C.svg) | MD3 Practical: A<br>Reading Calm: B<br>Adaptive Power: C<br>Hibiki Balanced: C | C | |
| `hibiki_toast.dart` | 组件系统 | [A](interface-images/hibiki-toast-A.svg) [B](interface-images/hibiki-toast-B.svg) [C](interface-images/hibiki-toast-C.svg) | MD3 Practical: A<br>Reading Calm: B<br>Adaptive Power: C<br>Hibiki Balanced: C | C | |
| `platform_utils.dart` | 组件系统 | [A](interface-images/platform-utils-A.svg) [B](interface-images/platform-utils-B.svg) [C](interface-images/platform-utils-C.svg) | MD3 Practical: A<br>Reading Calm: B<br>Adaptive Power: C<br>Hibiki Balanced: C | C | |
| `swipe_dismiss_wrapper.dart` | 组件系统 | [A](interface-images/swipe-dismiss-wrapper-A.svg) [B](interface-images/swipe-dismiss-wrapper-B.svg) [C](interface-images/swipe-dismiss-wrapper-C.svg) | MD3 Practical: A<br>Reading Calm: B<br>Adaptive Power: C<br>Hibiki Balanced: C | C | |
| `update_checker.dart` | 资料、语言、系统 | [A](interface-images/update-checker-A.svg) [B](interface-images/update-checker-B.svg) [C](interface-images/update-checker-C.svg) | MD3 Practical: A<br>Reading Calm: B<br>Adaptive Power: C<br>Hibiki Balanced: A | A | |
| `blur_options.dart` | 阅读自定义 | [A](interface-images/blur-options-A.svg) [B](interface-images/blur-options-B.svg) [C](interface-images/blur-options-C.svg) | MD3 Practical: A<br>Reading Calm: B<br>Adaptive Power: C<br>Hibiki Balanced: B | B | |

## 生成最终规格

```powershell
node .\generate-implementation-spec.mjs --picks .\my-final-selection.txt --output .\IMPLEMENTATION_SPEC_FINAL_DRAFT.md
```

本矩阵只负责选择，不代表已经开始 runtime 实现。
