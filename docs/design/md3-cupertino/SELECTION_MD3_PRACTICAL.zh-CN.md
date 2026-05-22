# MD3 Practical 逐界面整包选择

这份文件把 `MD3 Practical` 展开到全部 84 个界面/支撑组件。它不是最终用户确认；它是 整包基准，方便你逐行看图并指出例外。

## 选择结论

- Pack: `md3-practical`
- Surfaces: 84
- Images available: 252
- Selection source: [design-packs.json](design-packs.json)
- Full visual page: [selection-md3-practical.html](selection-md3-practical.html)
- Pack index: [pack-selection-index.html](pack-selection-index.html)
- Interface pack comparison: [interface-pack-comparison.html](interface-pack-comparison.html)
- All A/B/C choices: [interface-images/index.html](interface-images/index.html)

## 整体规则

- 基准：MD3 Practical。
- 视觉默认使用 Material 3 组件。
- 工作流保持直接，阅读器 chrome 不做装饰化处理。

## 适用判断

- 适合：优先要一致、直接、快速落地，而不是更柔和的阅读氛围。
- 代价：阅读器和偏好页会偏工具化，不如 Cupertino 倾向方案安静。

## Board 展开

Choice counts 是该 board 作为 primary board 的界面选择分布，格式为 `A/B/C`。

| Board | 区域 | Pack 选择 | Choice counts | 方向 | 作用域 |
| --- | --- | --- | --- | --- | --- |
| 01 | 首页和导航 | A | 3/0/0 | 安静 MD3 手机壳层 | 主壳层、底部导航、宽屏导航栏、顶部动作。 |
| 02 | 书架 | A | 3/0/0 | MD3 网格/列表书架 | 书库、历史、封面、选择模式、导入入口。 |
| 03 | 词典 | A | 14/0/0 | 快速 MD3 搜索 | 搜索、历史、结果浏览、弹出查词栈。 |
| 04 | Hoshi 阅读器 | A | 3/0/0 | 纸面 chrome 阅读器 | 阅读 chrome、查词浮层、有声书播放栏、歌词模式。 |
| 05 | 设置 | A | 2/0/0 | MD3 设置列表 | 个人资料、主题、阅读设置、显示、Anki、更新、日志。 |
| 06 | 导入和弹窗 | A | 3/0/0 | MD3 步骤导入 | 图书导入、有声书导入、词典导入、选择器弹窗。 |
| 07 | 制卡和 Anki | A | 4/0/0 | 简单字段表单 | 挖卡字段、Anki 设置、录音、裁剪、分词。 |
| 08 | 收藏和统计 | A | 3/0/0 | 可扫列表 | 书签、收藏句、阅读统计、插图查看。 |
| 09 | 系统和调试 | A | 0/0/0 | 朴素系统设置 | 语言、资料管理、杂项设置、日志、WebSocket。 |
| 10 | 词典管理 | A | 5/0/0 | 库存列表 | 已安装词典、导入进度、排序、CSS、音频源。 |
| 11 | 阅读自定义 | A | 6/0/0 | 控件优先 | 显示设置、自定义字体、自定义主题、书籍 CSS、模糊选项。 |
| 12 | 媒体和例句弹窗 | A | 5/0/0 | 手机动作 sheet | 媒体条目、编辑弹窗、来源选择、例句、stash、录音。 |
| 13 | 标签和筛选 | A | 4/0/0 | Chip 控制台 | 标签管理、标签选择、筛选 sheet、批量标签操作。 |
| 14 | 资料、语言、系统 | A | 6/0/0 | 设置中心 | 资料、语言、杂项设置、WebSocket、应用图标选择。 |
| 15 | 日志和调试 | A | 2/0/0 | 朴素日志查看 | 调试日志、错误日志、诊断、低内存和导入消息。 |
| 16 | 空、加载、错误状态 | A | 3/0/0 | 可行动空状态 | 共享空状态、加载、错误、占位页面。 |
| 18 | 组件系统 | A | 18/0/0 | MD3 token kit | 按钮、行、搜索、sheet、占位、弹窗、选择语法。 |

## 入口和外部壳层

| 界面 | 选择 | 选择图 | 方向 | 为什么 | 其它图 |
| --- | --- | --- | --- | --- | --- |
| `main.dart` | A | [选择图](interface-images/main-A.svg) | 安静 MD3 手机壳层 | 保留 Android 原生导航和清楚动作，适合低风险主壳层。 | [A](interface-images/main-A.svg) [B](interface-images/main-B.svg) [C](interface-images/main-C.svg) |
| `popup_main.dart` | A | [选择图](interface-images/popup-main-A.svg) | 快速 MD3 搜索 | 适合一次性输入和立即查词。 | [A](interface-images/popup-main-A.svg) [B](interface-images/popup-main-B.svg) [C](interface-images/popup-main-C.svg) |
| `floating_dict_main.dart` | A | [选择图](interface-images/floating-dict-main-A.svg) | 快速 MD3 搜索 | 适合一次性输入和立即查词。 | [A](interface-images/floating-dict-main-A.svg) [B](interface-images/floating-dict-main-B.svg) [C](interface-images/floating-dict-main-C.svg) |

## 页面

| 界面 | 选择 | 选择图 | 方向 | 为什么 | 其它图 |
| --- | --- | --- | --- | --- | --- |
| `anki_settings_page.dart` | A | [选择图](interface-images/anki-settings-page-A.svg) | 简单字段表单 | 适合低频制卡和少字段操作。 | [A](interface-images/anki-settings-page-A.svg) [B](interface-images/anki-settings-page-B.svg) [C](interface-images/anki-settings-page-C.svg) |
| `audio_recorder_page.dart` | A | [选择图](interface-images/audio-recorder-page-A.svg) | 简单字段表单 | 适合低频制卡和少字段操作。 | [A](interface-images/audio-recorder-page-A.svg) [B](interface-images/audio-recorder-page-B.svg) [C](interface-images/audio-recorder-page-C.svg) |
| `blur_options_dialog_page.dart` | A | [选择图](interface-images/blur-options-dialog-page-A.svg) | 控件优先 | 适合快速改滑块、开关、分段控件。 | [A](interface-images/blur-options-dialog-page-A.svg) [B](interface-images/blur-options-dialog-page-B.svg) [C](interface-images/blur-options-dialog-page-C.svg) |
| `book_css_editor_page.dart` | A | [选择图](interface-images/book-css-editor-page-A.svg) | 控件优先 | 适合快速改滑块、开关、分段控件。 | [A](interface-images/book-css-editor-page-A.svg) [B](interface-images/book-css-editor-page-B.svg) [C](interface-images/book-css-editor-page-C.svg) |
| `collections_page.dart` | A | [选择图](interface-images/collections-page-A.svg) | 可扫列表 | 收藏和统计需要快速扫描，不需要过多装饰。 | [A](interface-images/collections-page-A.svg) [B](interface-images/collections-page-B.svg) [C](interface-images/collections-page-C.svg) |
| `crop_image_dialog_page.dart` | A | [选择图](interface-images/crop-image-dialog-page-A.svg) | 简单字段表单 | 适合低频制卡和少字段操作。 | [A](interface-images/crop-image-dialog-page-A.svg) [B](interface-images/crop-image-dialog-page-B.svg) [C](interface-images/crop-image-dialog-page-C.svg) |
| `custom_fonts_page.dart` | A | [选择图](interface-images/custom-fonts-page-A.svg) | 控件优先 | 适合快速改滑块、开关、分段控件。 | [A](interface-images/custom-fonts-page-A.svg) [B](interface-images/custom-fonts-page-B.svg) [C](interface-images/custom-fonts-page-C.svg) |
| `custom_theme_page.dart` | A | [选择图](interface-images/custom-theme-page-A.svg) | 控件优先 | 适合快速改滑块、开关、分段控件。 | [A](interface-images/custom-theme-page-A.svg) [B](interface-images/custom-theme-page-B.svg) [C](interface-images/custom-theme-page-C.svg) |
| `debug_log_page.dart` | A | [选择图](interface-images/debug-log-page-A.svg) | 朴素日志查看 | 日志页第一任务是诚实展示文本和时间，不要用装饰掩盖错误。 | [A](interface-images/debug-log-page-A.svg) [B](interface-images/debug-log-page-B.svg) [C](interface-images/debug-log-page-C.svg) |
| `dictionary_dialog_delete_page.dart` | A | [选择图](interface-images/dictionary-dialog-delete-page-A.svg) | 库存列表 | 适合简单查看已安装词典。 | [A](interface-images/dictionary-dialog-delete-page-A.svg) [B](interface-images/dictionary-dialog-delete-page-B.svg) [C](interface-images/dictionary-dialog-delete-page-C.svg) |
| `dictionary_dialog_import_page.dart` | A | [选择图](interface-images/dictionary-dialog-import-page-A.svg) | 库存列表 | 适合简单查看已安装词典。 | [A](interface-images/dictionary-dialog-import-page-A.svg) [B](interface-images/dictionary-dialog-import-page-B.svg) [C](interface-images/dictionary-dialog-import-page-C.svg) |
| `dictionary_dialog_page.dart` | A | [选择图](interface-images/dictionary-dialog-page-A.svg) | 库存列表 | 适合简单查看已安装词典。 | [A](interface-images/dictionary-dialog-page-A.svg) [B](interface-images/dictionary-dialog-page-B.svg) [C](interface-images/dictionary-dialog-page-C.svg) |
| `dictionary_entry_page.dart` | A | [选择图](interface-images/dictionary-entry-page-A.svg) | 快速 MD3 搜索 | 适合一次性输入和立即查词。 | [A](interface-images/dictionary-entry-page-A.svg) [B](interface-images/dictionary-entry-page-B.svg) [C](interface-images/dictionary-entry-page-C.svg) |
| `dictionary_page_mixin.dart` | A | [选择图](interface-images/dictionary-page-mixin-A.svg) | 快速 MD3 搜索 | 适合一次性输入和立即查词。 | [A](interface-images/dictionary-page-mixin-A.svg) [B](interface-images/dictionary-page-mixin-B.svg) [C](interface-images/dictionary-page-mixin-C.svg) |
| `dictionary_popup_layer.dart` | A | [选择图](interface-images/dictionary-popup-layer-A.svg) | 快速 MD3 搜索 | 适合一次性输入和立即查词。 | [A](interface-images/dictionary-popup-layer-A.svg) [B](interface-images/dictionary-popup-layer-B.svg) [C](interface-images/dictionary-popup-layer-C.svg) |
| `dictionary_popup_native.dart` | A | [选择图](interface-images/dictionary-popup-native-A.svg) | 快速 MD3 搜索 | 适合一次性输入和立即查词。 | [A](interface-images/dictionary-popup-native-A.svg) [B](interface-images/dictionary-popup-native-B.svg) [C](interface-images/dictionary-popup-native-C.svg) |
| `dictionary_popup_webview.dart` | A | [选择图](interface-images/dictionary-popup-webview-A.svg) | 快速 MD3 搜索 | 适合一次性输入和立即查词。 | [A](interface-images/dictionary-popup-webview-A.svg) [B](interface-images/dictionary-popup-webview-B.svg) [C](interface-images/dictionary-popup-webview-C.svg) |
| `dictionary_progress_dialog_content.dart` | A | [选择图](interface-images/dictionary-progress-dialog-content-A.svg) | 库存列表 | 适合简单查看已安装词典。 | [A](interface-images/dictionary-progress-dialog-content-A.svg) [B](interface-images/dictionary-progress-dialog-content-B.svg) [C](interface-images/dictionary-progress-dialog-content-C.svg) |
| `dictionary_result_page.dart` | A | [选择图](interface-images/dictionary-result-page-A.svg) | 快速 MD3 搜索 | 适合一次性输入和立即查词。 | [A](interface-images/dictionary-result-page-A.svg) [B](interface-images/dictionary-result-page-B.svg) [C](interface-images/dictionary-result-page-C.svg) |
| `dictionary_settings_dialog_page.dart` | A | [选择图](interface-images/dictionary-settings-dialog-page-A.svg) | 库存列表 | 适合简单查看已安装词典。 | [A](interface-images/dictionary-settings-dialog-page-A.svg) [B](interface-images/dictionary-settings-dialog-page-B.svg) [C](interface-images/dictionary-settings-dialog-page-C.svg) |
| `dictionary_structured_content_page.dart` | A | [选择图](interface-images/dictionary-structured-content-page-A.svg) | 快速 MD3 搜索 | 适合一次性输入和立即查词。 | [A](interface-images/dictionary-structured-content-page-A.svg) [B](interface-images/dictionary-structured-content-page-B.svg) [C](interface-images/dictionary-structured-content-page-C.svg) |
| `dictionary_term_page.dart` | A | [选择图](interface-images/dictionary-term-page-A.svg) | 快速 MD3 搜索 | 适合一次性输入和立即查词。 | [A](interface-images/dictionary-term-page-A.svg) [B](interface-images/dictionary-term-page-B.svg) [C](interface-images/dictionary-term-page-C.svg) |
| `dictionary_webview_media.dart` | A | [选择图](interface-images/dictionary-webview-media-A.svg) | 快速 MD3 搜索 | 适合一次性输入和立即查词。 | [A](interface-images/dictionary-webview-media-A.svg) [B](interface-images/dictionary-webview-media-B.svg) [C](interface-images/dictionary-webview-media-C.svg) |
| `display_settings_page.dart` | A | [选择图](interface-images/display-settings-page-A.svg) | 控件优先 | 适合快速改滑块、开关、分段控件。 | [A](interface-images/display-settings-page-A.svg) [B](interface-images/display-settings-page-B.svg) [C](interface-images/display-settings-page-C.svg) |
| `error_log_page.dart` | A | [选择图](interface-images/error-log-page-A.svg) | 朴素日志查看 | 日志页第一任务是诚实展示文本和时间，不要用装饰掩盖错误。 | [A](interface-images/error-log-page-A.svg) [B](interface-images/error-log-page-B.svg) [C](interface-images/error-log-page-C.svg) |
| `example_sentences_dialog_page.dart` | A | [选择图](interface-images/example-sentences-dialog-page-A.svg) | 手机动作 sheet | 媒体和例句弹窗要短路径完成动作，MD3/Cupertino sheet 都能安全收束。 | [A](interface-images/example-sentences-dialog-page-A.svg) [B](interface-images/example-sentences-dialog-page-B.svg) [C](interface-images/example-sentences-dialog-page-C.svg) |
| `floating_dict_page.dart` | A | [选择图](interface-images/floating-dict-page-A.svg) | 快速 MD3 搜索 | 适合一次性输入和立即查词。 | [A](interface-images/floating-dict-page-A.svg) [B](interface-images/floating-dict-page-B.svg) [C](interface-images/floating-dict-page-C.svg) |
| `history_reader_page.dart` | A | [选择图](interface-images/history-reader-page-A.svg) | MD3 网格/列表书架 | 书架要能扫封面、状态和选择模式，MD3 列表/网格最稳。 | [A](interface-images/history-reader-page-A.svg) [B](interface-images/history-reader-page-B.svg) [C](interface-images/history-reader-page-C.svg) |
| `home_dictionary_page.dart` | A | [选择图](interface-images/home-dictionary-page-A.svg) | 快速 MD3 搜索 | 适合一次性输入和立即查词。 | [A](interface-images/home-dictionary-page-A.svg) [B](interface-images/home-dictionary-page-B.svg) [C](interface-images/home-dictionary-page-C.svg) |
| `home_page.dart` | A | [选择图](interface-images/home-page-A.svg) | 安静 MD3 手机壳层 | 保留 Android 原生导航和清楚动作，适合低风险主壳层。 | [A](interface-images/home-page-A.svg) [B](interface-images/home-page-B.svg) [C](interface-images/home-page-C.svg) |
| `home_reader_page.dart` | A | [选择图](interface-images/home-reader-page-A.svg) | 安静 MD3 手机壳层 | 保留 Android 原生导航和清楚动作，适合低风险主壳层。 | [A](interface-images/home-reader-page-A.svg) [B](interface-images/home-reader-page-B.svg) [C](interface-images/home-reader-page-C.svg) |
| `hoshi_settings_page.dart` | A | [选择图](interface-images/hoshi-settings-page-A.svg) | MD3 设置列表 | 直接、低风险、符合 Android 设置习惯。 | [A](interface-images/hoshi-settings-page-A.svg) [B](interface-images/hoshi-settings-page-B.svg) [C](interface-images/hoshi-settings-page-C.svg) |
| `illustrations_viewer_page.dart` | A | [选择图](interface-images/illustrations-viewer-page-A.svg) | 可扫列表 | 收藏和统计需要快速扫描，不需要过多装饰。 | [A](interface-images/illustrations-viewer-page-A.svg) [B](interface-images/illustrations-viewer-page-B.svg) [C](interface-images/illustrations-viewer-page-C.svg) |
| `language_dialog_page.dart` | A | [选择图](interface-images/language-dialog-page-A.svg) | 设置中心 | 资料、语言、系统入口要清楚可发现。 | [A](interface-images/language-dialog-page-A.svg) [B](interface-images/language-dialog-page-B.svg) [C](interface-images/language-dialog-page-C.svg) |
| `loading_page.dart` | A | [选择图](interface-images/loading-page-A.svg) | 可行动空状态 | 空、加载、错误状态要短文案和明确恢复动作，别伪装成功。 | [A](interface-images/loading-page-A.svg) [B](interface-images/loading-page-B.svg) [C](interface-images/loading-page-C.svg) |
| `lyrics_dialog_page.dart` | A | [选择图](interface-images/lyrics-dialog-page-A.svg) | 纸面 chrome 阅读器 | 控件可见但克制，适合保守阅读器改造。 | [A](interface-images/lyrics-dialog-page-A.svg) [B](interface-images/lyrics-dialog-page-B.svg) [C](interface-images/lyrics-dialog-page-C.svg) |
| `media_item_dialog_page.dart` | A | [选择图](interface-images/media-item-dialog-page-A.svg) | 手机动作 sheet | 媒体和例句弹窗要短路径完成动作，MD3/Cupertino sheet 都能安全收束。 | [A](interface-images/media-item-dialog-page-A.svg) [B](interface-images/media-item-dialog-page-B.svg) [C](interface-images/media-item-dialog-page-C.svg) |
| `media_item_edit_dialog_page.dart` | A | [选择图](interface-images/media-item-edit-dialog-page-A.svg) | 手机动作 sheet | 媒体和例句弹窗要短路径完成动作，MD3/Cupertino sheet 都能安全收束。 | [A](interface-images/media-item-edit-dialog-page-A.svg) [B](interface-images/media-item-edit-dialog-page-B.svg) [C](interface-images/media-item-edit-dialog-page-C.svg) |
| `media_source_picker_dialog_page.dart` | A | [选择图](interface-images/media-source-picker-dialog-page-A.svg) | 手机动作 sheet | 媒体和例句弹窗要短路径完成动作，MD3/Cupertino sheet 都能安全收束。 | [A](interface-images/media-source-picker-dialog-page-A.svg) [B](interface-images/media-source-picker-dialog-page-B.svg) [C](interface-images/media-source-picker-dialog-page-C.svg) |
| `miscellaneous_settings_page.dart` | A | [选择图](interface-images/miscellaneous-settings-page-A.svg) | 设置中心 | 资料、语言、系统入口要清楚可发现。 | [A](interface-images/miscellaneous-settings-page-A.svg) [B](interface-images/miscellaneous-settings-page-B.svg) [C](interface-images/miscellaneous-settings-page-C.svg) |
| `open_stash_dialog_page.dart` | A | [选择图](interface-images/open-stash-dialog-page-A.svg) | 手机动作 sheet | 媒体和例句弹窗要短路径完成动作，MD3/Cupertino sheet 都能安全收束。 | [A](interface-images/open-stash-dialog-page-A.svg) [B](interface-images/open-stash-dialog-page-B.svg) [C](interface-images/open-stash-dialog-page-C.svg) |
| `placeholder_source_page.dart` | A | [选择图](interface-images/placeholder-source-page-A.svg) | 可行动空状态 | 空、加载、错误状态要短文案和明确恢复动作，别伪装成功。 | [A](interface-images/placeholder-source-page-A.svg) [B](interface-images/placeholder-source-page-B.svg) [C](interface-images/placeholder-source-page-C.svg) |
| `popup_dictionary_page.dart` | A | [选择图](interface-images/popup-dictionary-page-A.svg) | 快速 MD3 搜索 | 适合一次性输入和立即查词。 | [A](interface-images/popup-dictionary-page-A.svg) [B](interface-images/popup-dictionary-page-B.svg) [C](interface-images/popup-dictionary-page-C.svg) |
| `profile_management_page.dart` | A | [选择图](interface-images/profile-management-page-A.svg) | 设置中心 | 资料、语言、系统入口要清楚可发现。 | [A](interface-images/profile-management-page-A.svg) [B](interface-images/profile-management-page-B.svg) [C](interface-images/profile-management-page-C.svg) |
| `reader_hoshi_history_page.dart` | A | [选择图](interface-images/reader-hoshi-history-page-A.svg) | MD3 网格/列表书架 | 书架要能扫封面、状态和选择模式，MD3 列表/网格最稳。 | [A](interface-images/reader-hoshi-history-page-A.svg) [B](interface-images/reader-hoshi-history-page-B.svg) [C](interface-images/reader-hoshi-history-page-C.svg) |
| `reader_hoshi_page.dart` | A | [选择图](interface-images/reader-hoshi-page-A.svg) | 纸面 chrome 阅读器 | 控件可见但克制，适合保守阅读器改造。 | [A](interface-images/reader-hoshi-page-A.svg) [B](interface-images/reader-hoshi-page-B.svg) [C](interface-images/reader-hoshi-page-C.svg) |
| `reading_statistics_page.dart` | A | [选择图](interface-images/reading-statistics-page-A.svg) | 可扫列表 | 收藏和统计需要快速扫描，不需要过多装饰。 | [A](interface-images/reading-statistics-page-A.svg) [B](interface-images/reading-statistics-page-B.svg) [C](interface-images/reading-statistics-page-C.svg) |
| `switch_settings_page.dart` | A | [选择图](interface-images/switch-settings-page-A.svg) | MD3 设置列表 | 直接、低风险、符合 Android 设置习惯。 | [A](interface-images/switch-settings-page-A.svg) [B](interface-images/switch-settings-page-B.svg) [C](interface-images/switch-settings-page-C.svg) |
| `tag_filter_sheet.dart` | A | [选择图](interface-images/tag-filter-sheet-A.svg) | Chip 控制台 | 适合简单筛选和标签选择。 | [A](interface-images/tag-filter-sheet-A.svg) [B](interface-images/tag-filter-sheet-B.svg) [C](interface-images/tag-filter-sheet-C.svg) |
| `tag_management_page.dart` | A | [选择图](interface-images/tag-management-page-A.svg) | Chip 控制台 | 适合简单筛选和标签选择。 | [A](interface-images/tag-management-page-A.svg) [B](interface-images/tag-management-page-B.svg) [C](interface-images/tag-management-page-C.svg) |
| `tag_picker_page.dart` | A | [选择图](interface-images/tag-picker-page-A.svg) | Chip 控制台 | 适合简单筛选和标签选择。 | [A](interface-images/tag-picker-page-A.svg) [B](interface-images/tag-picker-page-B.svg) [C](interface-images/tag-picker-page-C.svg) |
| `text_segmentation_dialog_page.dart` | A | [选择图](interface-images/text-segmentation-dialog-page-A.svg) | 简单字段表单 | 适合低频制卡和少字段操作。 | [A](interface-images/text-segmentation-dialog-page-A.svg) [B](interface-images/text-segmentation-dialog-page-B.svg) [C](interface-images/text-segmentation-dialog-page-C.svg) |
| `websocket_dialog_page.dart` | A | [选择图](interface-images/websocket-dialog-page-A.svg) | 设置中心 | 资料、语言、系统入口要清楚可发现。 | [A](interface-images/websocket-dialog-page-A.svg) [B](interface-images/websocket-dialog-page-B.svg) [C](interface-images/websocket-dialog-page-C.svg) |

## 共享和支撑组件

| 界面 | 选择 | 选择图 | 方向 | 为什么 | 其它图 |
| --- | --- | --- | --- | --- | --- |
| `app_model.dart` | A | [选择图](interface-images/app-model-A.svg) | MD3 token kit | 适合完全标准 Material 组件。 | [A](interface-images/app-model-A.svg) [B](interface-images/app-model-B.svg) [C](interface-images/app-model-C.svg) |
| `base_history_page.dart` | A | [选择图](interface-images/base-history-page-A.svg) | MD3 网格/列表书架 | 书架要能扫封面、状态和选择模式，MD3 列表/网格最稳。 | [A](interface-images/base-history-page-A.svg) [B](interface-images/base-history-page-B.svg) [C](interface-images/base-history-page-C.svg) |
| `base_media_search_bar.dart` | A | [选择图](interface-images/base-media-search-bar-A.svg) | MD3 token kit | 适合完全标准 Material 组件。 | [A](interface-images/base-media-search-bar-A.svg) [B](interface-images/base-media-search-bar-B.svg) [C](interface-images/base-media-search-bar-C.svg) |
| `base_page.dart` | A | [选择图](interface-images/base-page-A.svg) | MD3 token kit | 适合完全标准 Material 组件。 | [A](interface-images/base-page-A.svg) [B](interface-images/base-page-B.svg) [C](interface-images/base-page-C.svg) |
| `base_source_page.dart` | A | [选择图](interface-images/base-source-page-A.svg) | MD3 token kit | 适合完全标准 Material 组件。 | [A](interface-images/base-source-page-A.svg) [B](interface-images/base-source-page-B.svg) [C](interface-images/base-source-page-C.svg) |
| `base_tab_page.dart` | A | [选择图](interface-images/base-tab-page-A.svg) | MD3 token kit | 适合完全标准 Material 组件。 | [A](interface-images/base-tab-page-A.svg) [B](interface-images/base-tab-page-B.svg) [C](interface-images/base-tab-page-C.svg) |
| `audiobook_import_dialog.dart` | A | [选择图](interface-images/audiobook-import-dialog-A.svg) | MD3 步骤导入 | 导入流程必须明确、可恢复、可解释，步骤流最不容易骗用户。 | [A](interface-images/audiobook-import-dialog-A.svg) [B](interface-images/audiobook-import-dialog-B.svg) [C](interface-images/audiobook-import-dialog-C.svg) |
| `audiobook_play_bar.dart` | A | [选择图](interface-images/audiobook-play-bar-A.svg) | 纸面 chrome 阅读器 | 控件可见但克制，适合保守阅读器改造。 | [A](interface-images/audiobook-play-bar-A.svg) [B](interface-images/audiobook-play-bar-B.svg) [C](interface-images/audiobook-play-bar-C.svg) |
| `book_import_dialog.dart` | A | [选择图](interface-images/book-import-dialog-A.svg) | MD3 步骤导入 | 导入流程必须明确、可恢复、可解释，步骤流最不容易骗用户。 | [A](interface-images/book-import-dialog-A.svg) [B](interface-images/book-import-dialog-B.svg) [C](interface-images/book-import-dialog-C.svg) |
| `sasayaki_rematch.dart` | A | [选择图](interface-images/sasayaki-rematch-A.svg) | MD3 步骤导入 | 导入流程必须明确、可恢复、可解释，步骤流最不容易骗用户。 | [A](interface-images/sasayaki-rematch-A.svg) [B](interface-images/sasayaki-rematch-B.svg) [C](interface-images/sasayaki-rematch-C.svg) |
| `profile_selector.dart` | A | [选择图](interface-images/profile-selector-A.svg) | 设置中心 | 资料、语言、系统入口要清楚可发现。 | [A](interface-images/profile-selector-A.svg) [B](interface-images/profile-selector-B.svg) [C](interface-images/profile-selector-C.svg) |
| `hibiki_bottom_sheet.dart` | A | [选择图](interface-images/hibiki-bottom-sheet-A.svg) | MD3 token kit | 适合完全标准 Material 组件。 | [A](interface-images/hibiki-bottom-sheet-A.svg) [B](interface-images/hibiki-bottom-sheet-B.svg) [C](interface-images/hibiki-bottom-sheet-C.svg) |
| `hibiki_divider.dart` | A | [选择图](interface-images/hibiki-divider-A.svg) | MD3 token kit | 适合完全标准 Material 组件。 | [A](interface-images/hibiki-divider-A.svg) [B](interface-images/hibiki-divider-B.svg) [C](interface-images/hibiki-divider-C.svg) |
| `hibiki_dropdown.dart` | A | [选择图](interface-images/hibiki-dropdown-A.svg) | MD3 token kit | 适合完全标准 Material 组件。 | [A](interface-images/hibiki-dropdown-A.svg) [B](interface-images/hibiki-dropdown-B.svg) [C](interface-images/hibiki-dropdown-C.svg) |
| `hibiki_icon_button.dart` | A | [选择图](interface-images/hibiki-icon-button-A.svg) | MD3 token kit | 适合完全标准 Material 组件。 | [A](interface-images/hibiki-icon-button-A.svg) [B](interface-images/hibiki-icon-button-B.svg) [C](interface-images/hibiki-icon-button-C.svg) |
| `hibiki_list_tile.dart` | A | [选择图](interface-images/hibiki-list-tile-A.svg) | MD3 token kit | 适合完全标准 Material 组件。 | [A](interface-images/hibiki-list-tile-A.svg) [B](interface-images/hibiki-list-tile-B.svg) [C](interface-images/hibiki-list-tile-C.svg) |
| `hibiki_marquee.dart` | A | [选择图](interface-images/hibiki-marquee-A.svg) | MD3 token kit | 适合完全标准 Material 组件。 | [A](interface-images/hibiki-marquee-A.svg) [B](interface-images/hibiki-marquee-B.svg) [C](interface-images/hibiki-marquee-C.svg) |
| `hibiki_placeholder_message.dart` | A | [选择图](interface-images/hibiki-placeholder-message-A.svg) | 可行动空状态 | 空、加载、错误状态要短文案和明确恢复动作，别伪装成功。 | [A](interface-images/hibiki-placeholder-message-A.svg) [B](interface-images/hibiki-placeholder-message-B.svg) [C](interface-images/hibiki-placeholder-message-C.svg) |
| `hibiki_popup_position.dart` | A | [选择图](interface-images/hibiki-popup-position-A.svg) | MD3 token kit | 适合完全标准 Material 组件。 | [A](interface-images/hibiki-popup-position-A.svg) [B](interface-images/hibiki-popup-position-B.svg) [C](interface-images/hibiki-popup-position-C.svg) |
| `hibiki_search_history.dart` | A | [选择图](interface-images/hibiki-search-history-A.svg) | MD3 token kit | 适合完全标准 Material 组件。 | [A](interface-images/hibiki-search-history-A.svg) [B](interface-images/hibiki-search-history-B.svg) [C](interface-images/hibiki-search-history-C.svg) |
| `hibiki_selectable_text.dart` | A | [选择图](interface-images/hibiki-selectable-text-A.svg) | MD3 token kit | 适合完全标准 Material 组件。 | [A](interface-images/hibiki-selectable-text-A.svg) [B](interface-images/hibiki-selectable-text-B.svg) [C](interface-images/hibiki-selectable-text-C.svg) |
| `hibiki_tag.dart` | A | [选择图](interface-images/hibiki-tag-A.svg) | Chip 控制台 | 适合简单筛选和标签选择。 | [A](interface-images/hibiki-tag-A.svg) [B](interface-images/hibiki-tag-B.svg) [C](interface-images/hibiki-tag-C.svg) |
| `hibiki_text_selection_controls.dart` | A | [选择图](interface-images/hibiki-text-selection-controls-A.svg) | MD3 token kit | 适合完全标准 Material 组件。 | [A](interface-images/hibiki-text-selection-controls-A.svg) [B](interface-images/hibiki-text-selection-controls-B.svg) [C](interface-images/hibiki-text-selection-controls-C.svg) |
| `hibiki_toast.dart` | A | [选择图](interface-images/hibiki-toast-A.svg) | MD3 token kit | 适合完全标准 Material 组件。 | [A](interface-images/hibiki-toast-A.svg) [B](interface-images/hibiki-toast-B.svg) [C](interface-images/hibiki-toast-C.svg) |
| `platform_utils.dart` | A | [选择图](interface-images/platform-utils-A.svg) | MD3 token kit | 适合完全标准 Material 组件。 | [A](interface-images/platform-utils-A.svg) [B](interface-images/platform-utils-B.svg) [C](interface-images/platform-utils-C.svg) |
| `swipe_dismiss_wrapper.dart` | A | [选择图](interface-images/swipe-dismiss-wrapper-A.svg) | MD3 token kit | 适合完全标准 Material 组件。 | [A](interface-images/swipe-dismiss-wrapper-A.svg) [B](interface-images/swipe-dismiss-wrapper-B.svg) [C](interface-images/swipe-dismiss-wrapper-C.svg) |
| `update_checker.dart` | A | [选择图](interface-images/update-checker-A.svg) | 设置中心 | 资料、语言、系统入口要清楚可发现。 | [A](interface-images/update-checker-A.svg) [B](interface-images/update-checker-B.svg) [C](interface-images/update-checker-C.svg) |
| `blur_options.dart` | A | [选择图](interface-images/blur-options-A.svg) | 控件优先 | 适合快速改滑块、开关、分段控件。 | [A](interface-images/blur-options-A.svg) [B](interface-images/blur-options-B.svg) [C](interface-images/blur-options-C.svg) |

## 确认格式

如果接受这套默认值，回复：

```text
Pack: md3-practical
```

如果只改少量例外，回复：

```text
Pack: md3-practical
reader_hoshi_page.dart: B
dictionary_dialog_page.dart: C
```

不要在确认前改运行时代码。确认后再把选择重新生成到实现规格，并写 Flutter 实施计划。
