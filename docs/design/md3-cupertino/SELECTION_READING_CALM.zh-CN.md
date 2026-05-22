# Reading Calm 逐界面整包选择

这份文件把 `Reading Calm` 展开到全部 84 个界面/支撑组件。它不是最终用户确认；它是 整包基准，方便你逐行看图并指出例外。

## 选择结论

- Pack: `reading-calm`
- Surfaces: 84
- Images available: 252
- Selection source: [design-packs.json](design-packs.json)
- Full visual page: [selection-reading-calm.html](selection-reading-calm.html)
- Pack index: [pack-selection-index.html](pack-selection-index.html)
- Interface pack comparison: [interface-pack-comparison.html](interface-pack-comparison.html)
- All A/B/C choices: [interface-images/index.html](interface-images/index.html)

## 整体规则

- 基准：Reading Calm。
- 优先使用分组设置、大标题节奏和半透明阅读/附件 chrome。
- 词典结果保持可浏览，不把输入焦点当作唯一中心。

## 适用判断

- 适合：希望 Hibiki 首先像一个能长时间阅读的应用。
- 代价：管理密集的页面可能需要显式例外，才能保持足够信息密度。

## Board 展开

Choice counts 是该 board 作为 primary board 的界面选择分布，格式为 `A/B/C`。

| Board | 区域 | Pack 选择 | Choice counts | 方向 | 作用域 |
| --- | --- | --- | --- | --- | --- |
| 01 | 首页和导航 | B | 0/3/0 | Cupertino 大标题壳层 | 主壳层、底部导航、宽屏导航栏、顶部动作。 |
| 02 | 书架 | B | 0/3/0 | 阅读优先书架 | 书库、历史、封面、选择模式、导入入口。 |
| 03 | 词典 | B | 0/14/0 | 可浏览结果 | 搜索、历史、结果浏览、弹出查词栈。 |
| 04 | Hoshi 阅读器 | B | 0/3/0 | 沉浸安静阅读器 | 阅读 chrome、查词浮层、有声书播放栏、歌词模式。 |
| 05 | 设置 | B | 0/2/0 | Cupertino 分组设置 | 个人资料、主题、阅读设置、显示、Anki、更新、日志。 |
| 06 | 导入和弹窗 | B | 0/3/0 | 轻量 sheet 流 | 图书导入、有声书导入、词典导入、选择器弹窗。 |
| 07 | 制卡和 Anki | B | 0/4/0 | 引导式制卡 | 挖卡字段、Anki 设置、录音、裁剪、分词。 |
| 08 | 收藏和统计 | B | 0/3/0 | 媒体图库 | 书签、收藏句、阅读统计、插图查看。 |
| 09 | 系统和调试 | B | 0/0/0 | 分组资料感 | 语言、资料管理、杂项设置、日志、WebSocket。 |
| 10 | 词典管理 | B | 0/5/0 | 词典检查器 | 已安装词典、导入进度、排序、CSS、音频源。 |
| 11 | 阅读自定义 | B | 0/6/0 | 预览工作室 | 显示设置、自定义字体、自定义主题、书籍 CSS、模糊选项。 |
| 12 | 媒体和例句弹窗 | B | 0/5/0 | 模态栈 | 媒体条目、编辑弹窗、来源选择、例句、stash、录音。 |
| 13 | 标签和筛选 | B | 0/4/0 | 分组标签管理 | 标签管理、标签选择、筛选 sheet、批量标签操作。 |
| 14 | 资料、语言、系统 | B | 0/6/0 | 账户式资料 | 资料、语言、杂项设置、WebSocket、应用图标选择。 |
| 15 | 日志和调试 | B | 0/2/0 | 错误收件箱 | 调试日志、错误日志、诊断、低内存和导入消息。 |
| 16 | 空、加载、错误状态 | B | 0/3/0 | 安静骨架屏 | 共享空状态、加载、错误、占位页面。 |
| 18 | 组件系统 | B | 0/18/0 | Cupertino surface kit | 按钮、行、搜索、sheet、占位、弹窗、选择语法。 |

## 入口和外部壳层

| 界面 | 选择 | 选择图 | 方向 | 为什么 | 其它图 |
| --- | --- | --- | --- | --- | --- |
| `main.dart` | B | [选择图](interface-images/main-B.svg) | Cupertino 大标题壳层 | 降低顶部噪音，让入口更像阅读应用。 | [A](interface-images/main-A.svg) [B](interface-images/main-B.svg) [C](interface-images/main-C.svg) |
| `popup_main.dart` | B | [选择图](interface-images/popup-main-B.svg) | 可浏览结果 | Hibiki 的查词结果需要浏览和递归查找，不能总把焦点拉回输入框。 | [A](interface-images/popup-main-A.svg) [B](interface-images/popup-main-B.svg) [C](interface-images/popup-main-C.svg) |
| `floating_dict_main.dart` | B | [选择图](interface-images/floating-dict-main-B.svg) | 可浏览结果 | Hibiki 的查词结果需要浏览和递归查找，不能总把焦点拉回输入框。 | [A](interface-images/floating-dict-main-A.svg) [B](interface-images/floating-dict-main-B.svg) [C](interface-images/floating-dict-main-C.svg) |

## 页面

| 界面 | 选择 | 选择图 | 方向 | 为什么 | 其它图 |
| --- | --- | --- | --- | --- | --- |
| `anki_settings_page.dart` | B | [选择图](interface-images/anki-settings-page-B.svg) | 引导式制卡 | 适合新用户一步步完成挖卡。 | [A](interface-images/anki-settings-page-A.svg) [B](interface-images/anki-settings-page-B.svg) [C](interface-images/anki-settings-page-C.svg) |
| `audio_recorder_page.dart` | B | [选择图](interface-images/audio-recorder-page-B.svg) | 引导式制卡 | 适合新用户一步步完成挖卡。 | [A](interface-images/audio-recorder-page-A.svg) [B](interface-images/audio-recorder-page-B.svg) [C](interface-images/audio-recorder-page-C.svg) |
| `blur_options_dialog_page.dart` | B | [选择图](interface-images/blur-options-dialog-page-B.svg) | 预览工作室 | 阅读自定义必须边调边看，预览比纯设置列表更重要。 | [A](interface-images/blur-options-dialog-page-A.svg) [B](interface-images/blur-options-dialog-page-B.svg) [C](interface-images/blur-options-dialog-page-C.svg) |
| `book_css_editor_page.dart` | B | [选择图](interface-images/book-css-editor-page-B.svg) | 预览工作室 | 阅读自定义必须边调边看，预览比纯设置列表更重要。 | [A](interface-images/book-css-editor-page-A.svg) [B](interface-images/book-css-editor-page-B.svg) [C](interface-images/book-css-editor-page-C.svg) |
| `collections_page.dart` | B | [选择图](interface-images/collections-page-B.svg) | 媒体图库 | 适合插图和视觉素材为主的页面。 | [A](interface-images/collections-page-A.svg) [B](interface-images/collections-page-B.svg) [C](interface-images/collections-page-C.svg) |
| `crop_image_dialog_page.dart` | B | [选择图](interface-images/crop-image-dialog-page-B.svg) | 引导式制卡 | 适合新用户一步步完成挖卡。 | [A](interface-images/crop-image-dialog-page-A.svg) [B](interface-images/crop-image-dialog-page-B.svg) [C](interface-images/crop-image-dialog-page-C.svg) |
| `custom_fonts_page.dart` | B | [选择图](interface-images/custom-fonts-page-B.svg) | 预览工作室 | 阅读自定义必须边调边看，预览比纯设置列表更重要。 | [A](interface-images/custom-fonts-page-A.svg) [B](interface-images/custom-fonts-page-B.svg) [C](interface-images/custom-fonts-page-C.svg) |
| `custom_theme_page.dart` | B | [选择图](interface-images/custom-theme-page-B.svg) | 预览工作室 | 阅读自定义必须边调边看，预览比纯设置列表更重要。 | [A](interface-images/custom-theme-page-A.svg) [B](interface-images/custom-theme-page-B.svg) [C](interface-images/custom-theme-page-C.svg) |
| `debug_log_page.dart` | B | [选择图](interface-images/debug-log-page-B.svg) | 错误收件箱 | 适合聚合错误并分组处理。 | [A](interface-images/debug-log-page-A.svg) [B](interface-images/debug-log-page-B.svg) [C](interface-images/debug-log-page-C.svg) |
| `dictionary_dialog_delete_page.dart` | B | [选择图](interface-images/dictionary-dialog-delete-page-B.svg) | 词典检查器 | 适合查看词典元数据和结构内容。 | [A](interface-images/dictionary-dialog-delete-page-A.svg) [B](interface-images/dictionary-dialog-delete-page-B.svg) [C](interface-images/dictionary-dialog-delete-page-C.svg) |
| `dictionary_dialog_import_page.dart` | B | [选择图](interface-images/dictionary-dialog-import-page-B.svg) | 词典检查器 | 适合查看词典元数据和结构内容。 | [A](interface-images/dictionary-dialog-import-page-A.svg) [B](interface-images/dictionary-dialog-import-page-B.svg) [C](interface-images/dictionary-dialog-import-page-C.svg) |
| `dictionary_dialog_page.dart` | B | [选择图](interface-images/dictionary-dialog-page-B.svg) | 词典检查器 | 适合查看词典元数据和结构内容。 | [A](interface-images/dictionary-dialog-page-A.svg) [B](interface-images/dictionary-dialog-page-B.svg) [C](interface-images/dictionary-dialog-page-C.svg) |
| `dictionary_entry_page.dart` | B | [选择图](interface-images/dictionary-entry-page-B.svg) | 可浏览结果 | Hibiki 的查词结果需要浏览和递归查找，不能总把焦点拉回输入框。 | [A](interface-images/dictionary-entry-page-A.svg) [B](interface-images/dictionary-entry-page-B.svg) [C](interface-images/dictionary-entry-page-C.svg) |
| `dictionary_page_mixin.dart` | B | [选择图](interface-images/dictionary-page-mixin-B.svg) | 可浏览结果 | Hibiki 的查词结果需要浏览和递归查找，不能总把焦点拉回输入框。 | [A](interface-images/dictionary-page-mixin-A.svg) [B](interface-images/dictionary-page-mixin-B.svg) [C](interface-images/dictionary-page-mixin-C.svg) |
| `dictionary_popup_layer.dart` | B | [选择图](interface-images/dictionary-popup-layer-B.svg) | 可浏览结果 | Hibiki 的查词结果需要浏览和递归查找，不能总把焦点拉回输入框。 | [A](interface-images/dictionary-popup-layer-A.svg) [B](interface-images/dictionary-popup-layer-B.svg) [C](interface-images/dictionary-popup-layer-C.svg) |
| `dictionary_popup_native.dart` | B | [选择图](interface-images/dictionary-popup-native-B.svg) | 可浏览结果 | Hibiki 的查词结果需要浏览和递归查找，不能总把焦点拉回输入框。 | [A](interface-images/dictionary-popup-native-A.svg) [B](interface-images/dictionary-popup-native-B.svg) [C](interface-images/dictionary-popup-native-C.svg) |
| `dictionary_popup_webview.dart` | B | [选择图](interface-images/dictionary-popup-webview-B.svg) | 可浏览结果 | Hibiki 的查词结果需要浏览和递归查找，不能总把焦点拉回输入框。 | [A](interface-images/dictionary-popup-webview-A.svg) [B](interface-images/dictionary-popup-webview-B.svg) [C](interface-images/dictionary-popup-webview-C.svg) |
| `dictionary_progress_dialog_content.dart` | B | [选择图](interface-images/dictionary-progress-dialog-content-B.svg) | 词典检查器 | 适合查看词典元数据和结构内容。 | [A](interface-images/dictionary-progress-dialog-content-A.svg) [B](interface-images/dictionary-progress-dialog-content-B.svg) [C](interface-images/dictionary-progress-dialog-content-C.svg) |
| `dictionary_result_page.dart` | B | [选择图](interface-images/dictionary-result-page-B.svg) | 可浏览结果 | Hibiki 的查词结果需要浏览和递归查找，不能总把焦点拉回输入框。 | [A](interface-images/dictionary-result-page-A.svg) [B](interface-images/dictionary-result-page-B.svg) [C](interface-images/dictionary-result-page-C.svg) |
| `dictionary_settings_dialog_page.dart` | B | [选择图](interface-images/dictionary-settings-dialog-page-B.svg) | 词典检查器 | 适合查看词典元数据和结构内容。 | [A](interface-images/dictionary-settings-dialog-page-A.svg) [B](interface-images/dictionary-settings-dialog-page-B.svg) [C](interface-images/dictionary-settings-dialog-page-C.svg) |
| `dictionary_structured_content_page.dart` | B | [选择图](interface-images/dictionary-structured-content-page-B.svg) | 可浏览结果 | Hibiki 的查词结果需要浏览和递归查找，不能总把焦点拉回输入框。 | [A](interface-images/dictionary-structured-content-page-A.svg) [B](interface-images/dictionary-structured-content-page-B.svg) [C](interface-images/dictionary-structured-content-page-C.svg) |
| `dictionary_term_page.dart` | B | [选择图](interface-images/dictionary-term-page-B.svg) | 可浏览结果 | Hibiki 的查词结果需要浏览和递归查找，不能总把焦点拉回输入框。 | [A](interface-images/dictionary-term-page-A.svg) [B](interface-images/dictionary-term-page-B.svg) [C](interface-images/dictionary-term-page-C.svg) |
| `dictionary_webview_media.dart` | B | [选择图](interface-images/dictionary-webview-media-B.svg) | 可浏览结果 | Hibiki 的查词结果需要浏览和递归查找，不能总把焦点拉回输入框。 | [A](interface-images/dictionary-webview-media-A.svg) [B](interface-images/dictionary-webview-media-B.svg) [C](interface-images/dictionary-webview-media-C.svg) |
| `display_settings_page.dart` | B | [选择图](interface-images/display-settings-page-B.svg) | 预览工作室 | 阅读自定义必须边调边看，预览比纯设置列表更重要。 | [A](interface-images/display-settings-page-A.svg) [B](interface-images/display-settings-page-B.svg) [C](interface-images/display-settings-page-C.svg) |
| `error_log_page.dart` | B | [选择图](interface-images/error-log-page-B.svg) | 错误收件箱 | 适合聚合错误并分组处理。 | [A](interface-images/error-log-page-A.svg) [B](interface-images/error-log-page-B.svg) [C](interface-images/error-log-page-C.svg) |
| `example_sentences_dialog_page.dart` | B | [选择图](interface-images/example-sentences-dialog-page-B.svg) | 模态栈 | 适合嵌套查看句子和媒体详情。 | [A](interface-images/example-sentences-dialog-page-A.svg) [B](interface-images/example-sentences-dialog-page-B.svg) [C](interface-images/example-sentences-dialog-page-C.svg) |
| `floating_dict_page.dart` | B | [选择图](interface-images/floating-dict-page-B.svg) | 可浏览结果 | Hibiki 的查词结果需要浏览和递归查找，不能总把焦点拉回输入框。 | [A](interface-images/floating-dict-page-A.svg) [B](interface-images/floating-dict-page-B.svg) [C](interface-images/floating-dict-page-C.svg) |
| `history_reader_page.dart` | B | [选择图](interface-images/history-reader-page-B.svg) | 阅读优先书架 | 突出继续阅读，减少管理感。 | [A](interface-images/history-reader-page-A.svg) [B](interface-images/history-reader-page-B.svg) [C](interface-images/history-reader-page-C.svg) |
| `home_dictionary_page.dart` | B | [选择图](interface-images/home-dictionary-page-B.svg) | 可浏览结果 | Hibiki 的查词结果需要浏览和递归查找，不能总把焦点拉回输入框。 | [A](interface-images/home-dictionary-page-A.svg) [B](interface-images/home-dictionary-page-B.svg) [C](interface-images/home-dictionary-page-C.svg) |
| `home_page.dart` | B | [选择图](interface-images/home-page-B.svg) | Cupertino 大标题壳层 | 降低顶部噪音，让入口更像阅读应用。 | [A](interface-images/home-page-A.svg) [B](interface-images/home-page-B.svg) [C](interface-images/home-page-C.svg) |
| `home_reader_page.dart` | B | [选择图](interface-images/home-reader-page-B.svg) | Cupertino 大标题壳层 | 降低顶部噪音，让入口更像阅读应用。 | [A](interface-images/home-reader-page-A.svg) [B](interface-images/home-reader-page-B.svg) [C](interface-images/home-reader-page-C.svg) |
| `hoshi_settings_page.dart` | B | [选择图](interface-images/hoshi-settings-page-B.svg) | Cupertino 分组设置 | 设置项很多时，分组卡住信息密度和节奏，读起来更安静。 | [A](interface-images/hoshi-settings-page-A.svg) [B](interface-images/hoshi-settings-page-B.svg) [C](interface-images/hoshi-settings-page-C.svg) |
| `illustrations_viewer_page.dart` | B | [选择图](interface-images/illustrations-viewer-page-B.svg) | 媒体图库 | 适合插图和视觉素材为主的页面。 | [A](interface-images/illustrations-viewer-page-A.svg) [B](interface-images/illustrations-viewer-page-B.svg) [C](interface-images/illustrations-viewer-page-C.svg) |
| `language_dialog_page.dart` | B | [选择图](interface-images/language-dialog-page-B.svg) | 账户式资料 | 适合更强个人资料氛围。 | [A](interface-images/language-dialog-page-A.svg) [B](interface-images/language-dialog-page-B.svg) [C](interface-images/language-dialog-page-C.svg) |
| `loading_page.dart` | B | [选择图](interface-images/loading-page-B.svg) | 安静骨架屏 | 适合等待内容加载时减少跳动。 | [A](interface-images/loading-page-A.svg) [B](interface-images/loading-page-B.svg) [C](interface-images/loading-page-C.svg) |
| `lyrics_dialog_page.dart` | B | [选择图](interface-images/lyrics-dialog-page-B.svg) | 沉浸安静阅读器 | 正文优先，播放栏、查词、歌词只在需要时出现，最符合长时间阅读。 | [A](interface-images/lyrics-dialog-page-A.svg) [B](interface-images/lyrics-dialog-page-B.svg) [C](interface-images/lyrics-dialog-page-C.svg) |
| `media_item_dialog_page.dart` | B | [选择图](interface-images/media-item-dialog-page-B.svg) | 模态栈 | 适合嵌套查看句子和媒体详情。 | [A](interface-images/media-item-dialog-page-A.svg) [B](interface-images/media-item-dialog-page-B.svg) [C](interface-images/media-item-dialog-page-C.svg) |
| `media_item_edit_dialog_page.dart` | B | [选择图](interface-images/media-item-edit-dialog-page-B.svg) | 模态栈 | 适合嵌套查看句子和媒体详情。 | [A](interface-images/media-item-edit-dialog-page-A.svg) [B](interface-images/media-item-edit-dialog-page-B.svg) [C](interface-images/media-item-edit-dialog-page-C.svg) |
| `media_source_picker_dialog_page.dart` | B | [选择图](interface-images/media-source-picker-dialog-page-B.svg) | 模态栈 | 适合嵌套查看句子和媒体详情。 | [A](interface-images/media-source-picker-dialog-page-A.svg) [B](interface-images/media-source-picker-dialog-page-B.svg) [C](interface-images/media-source-picker-dialog-page-C.svg) |
| `miscellaneous_settings_page.dart` | B | [选择图](interface-images/miscellaneous-settings-page-B.svg) | 账户式资料 | 适合更强个人资料氛围。 | [A](interface-images/miscellaneous-settings-page-A.svg) [B](interface-images/miscellaneous-settings-page-B.svg) [C](interface-images/miscellaneous-settings-page-C.svg) |
| `open_stash_dialog_page.dart` | B | [选择图](interface-images/open-stash-dialog-page-B.svg) | 模态栈 | 适合嵌套查看句子和媒体详情。 | [A](interface-images/open-stash-dialog-page-A.svg) [B](interface-images/open-stash-dialog-page-B.svg) [C](interface-images/open-stash-dialog-page-C.svg) |
| `placeholder_source_page.dart` | B | [选择图](interface-images/placeholder-source-page-B.svg) | 安静骨架屏 | 适合等待内容加载时减少跳动。 | [A](interface-images/placeholder-source-page-A.svg) [B](interface-images/placeholder-source-page-B.svg) [C](interface-images/placeholder-source-page-C.svg) |
| `popup_dictionary_page.dart` | B | [选择图](interface-images/popup-dictionary-page-B.svg) | 可浏览结果 | Hibiki 的查词结果需要浏览和递归查找，不能总把焦点拉回输入框。 | [A](interface-images/popup-dictionary-page-A.svg) [B](interface-images/popup-dictionary-page-B.svg) [C](interface-images/popup-dictionary-page-C.svg) |
| `profile_management_page.dart` | B | [选择图](interface-images/profile-management-page-B.svg) | 账户式资料 | 适合更强个人资料氛围。 | [A](interface-images/profile-management-page-A.svg) [B](interface-images/profile-management-page-B.svg) [C](interface-images/profile-management-page-C.svg) |
| `reader_hoshi_history_page.dart` | B | [选择图](interface-images/reader-hoshi-history-page-B.svg) | 阅读优先书架 | 突出继续阅读，减少管理感。 | [A](interface-images/reader-hoshi-history-page-A.svg) [B](interface-images/reader-hoshi-history-page-B.svg) [C](interface-images/reader-hoshi-history-page-C.svg) |
| `reader_hoshi_page.dart` | B | [选择图](interface-images/reader-hoshi-page-B.svg) | 沉浸安静阅读器 | 正文优先，播放栏、查词、歌词只在需要时出现，最符合长时间阅读。 | [A](interface-images/reader-hoshi-page-A.svg) [B](interface-images/reader-hoshi-page-B.svg) [C](interface-images/reader-hoshi-page-C.svg) |
| `reading_statistics_page.dart` | B | [选择图](interface-images/reading-statistics-page-B.svg) | 媒体图库 | 适合插图和视觉素材为主的页面。 | [A](interface-images/reading-statistics-page-A.svg) [B](interface-images/reading-statistics-page-B.svg) [C](interface-images/reading-statistics-page-C.svg) |
| `switch_settings_page.dart` | B | [选择图](interface-images/switch-settings-page-B.svg) | Cupertino 分组设置 | 设置项很多时，分组卡住信息密度和节奏，读起来更安静。 | [A](interface-images/switch-settings-page-A.svg) [B](interface-images/switch-settings-page-B.svg) [C](interface-images/switch-settings-page-C.svg) |
| `tag_filter_sheet.dart` | B | [选择图](interface-images/tag-filter-sheet-B.svg) | 分组标签管理 | 适合设置式管理。 | [A](interface-images/tag-filter-sheet-A.svg) [B](interface-images/tag-filter-sheet-B.svg) [C](interface-images/tag-filter-sheet-C.svg) |
| `tag_management_page.dart` | B | [选择图](interface-images/tag-management-page-B.svg) | 分组标签管理 | 适合设置式管理。 | [A](interface-images/tag-management-page-A.svg) [B](interface-images/tag-management-page-B.svg) [C](interface-images/tag-management-page-C.svg) |
| `tag_picker_page.dart` | B | [选择图](interface-images/tag-picker-page-B.svg) | 分组标签管理 | 适合设置式管理。 | [A](interface-images/tag-picker-page-A.svg) [B](interface-images/tag-picker-page-B.svg) [C](interface-images/tag-picker-page-C.svg) |
| `text_segmentation_dialog_page.dart` | B | [选择图](interface-images/text-segmentation-dialog-page-B.svg) | 引导式制卡 | 适合新用户一步步完成挖卡。 | [A](interface-images/text-segmentation-dialog-page-A.svg) [B](interface-images/text-segmentation-dialog-page-B.svg) [C](interface-images/text-segmentation-dialog-page-C.svg) |
| `websocket_dialog_page.dart` | B | [选择图](interface-images/websocket-dialog-page-B.svg) | 账户式资料 | 适合更强个人资料氛围。 | [A](interface-images/websocket-dialog-page-A.svg) [B](interface-images/websocket-dialog-page-B.svg) [C](interface-images/websocket-dialog-page-C.svg) |

## 共享和支撑组件

| 界面 | 选择 | 选择图 | 方向 | 为什么 | 其它图 |
| --- | --- | --- | --- | --- | --- |
| `app_model.dart` | B | [选择图](interface-images/app-model-B.svg) | Cupertino surface kit | 适合安静表面、分组行、柔和弹层。 | [A](interface-images/app-model-A.svg) [B](interface-images/app-model-B.svg) [C](interface-images/app-model-C.svg) |
| `base_history_page.dart` | B | [选择图](interface-images/base-history-page-B.svg) | 阅读优先书架 | 突出继续阅读，减少管理感。 | [A](interface-images/base-history-page-A.svg) [B](interface-images/base-history-page-B.svg) [C](interface-images/base-history-page-C.svg) |
| `base_media_search_bar.dart` | B | [选择图](interface-images/base-media-search-bar-B.svg) | Cupertino surface kit | 适合安静表面、分组行、柔和弹层。 | [A](interface-images/base-media-search-bar-A.svg) [B](interface-images/base-media-search-bar-B.svg) [C](interface-images/base-media-search-bar-C.svg) |
| `base_page.dart` | B | [选择图](interface-images/base-page-B.svg) | Cupertino surface kit | 适合安静表面、分组行、柔和弹层。 | [A](interface-images/base-page-A.svg) [B](interface-images/base-page-B.svg) [C](interface-images/base-page-C.svg) |
| `base_source_page.dart` | B | [选择图](interface-images/base-source-page-B.svg) | Cupertino surface kit | 适合安静表面、分组行、柔和弹层。 | [A](interface-images/base-source-page-A.svg) [B](interface-images/base-source-page-B.svg) [C](interface-images/base-source-page-C.svg) |
| `base_tab_page.dart` | B | [选择图](interface-images/base-tab-page-B.svg) | Cupertino surface kit | 适合安静表面、分组行、柔和弹层。 | [A](interface-images/base-tab-page-A.svg) [B](interface-images/base-tab-page-B.svg) [C](interface-images/base-tab-page-C.svg) |
| `audiobook_import_dialog.dart` | B | [选择图](interface-images/audiobook-import-dialog-B.svg) | 轻量 sheet 流 | 适合简单选择和短流程。 | [A](interface-images/audiobook-import-dialog-A.svg) [B](interface-images/audiobook-import-dialog-B.svg) [C](interface-images/audiobook-import-dialog-C.svg) |
| `audiobook_play_bar.dart` | B | [选择图](interface-images/audiobook-play-bar-B.svg) | 沉浸安静阅读器 | 正文优先，播放栏、查词、歌词只在需要时出现，最符合长时间阅读。 | [A](interface-images/audiobook-play-bar-A.svg) [B](interface-images/audiobook-play-bar-B.svg) [C](interface-images/audiobook-play-bar-C.svg) |
| `book_import_dialog.dart` | B | [选择图](interface-images/book-import-dialog-B.svg) | 轻量 sheet 流 | 适合简单选择和短流程。 | [A](interface-images/book-import-dialog-A.svg) [B](interface-images/book-import-dialog-B.svg) [C](interface-images/book-import-dialog-C.svg) |
| `sasayaki_rematch.dart` | B | [选择图](interface-images/sasayaki-rematch-B.svg) | 轻量 sheet 流 | 适合简单选择和短流程。 | [A](interface-images/sasayaki-rematch-A.svg) [B](interface-images/sasayaki-rematch-B.svg) [C](interface-images/sasayaki-rematch-C.svg) |
| `profile_selector.dart` | B | [选择图](interface-images/profile-selector-B.svg) | 账户式资料 | 适合更强个人资料氛围。 | [A](interface-images/profile-selector-A.svg) [B](interface-images/profile-selector-B.svg) [C](interface-images/profile-selector-C.svg) |
| `hibiki_bottom_sheet.dart` | B | [选择图](interface-images/hibiki-bottom-sheet-B.svg) | Cupertino surface kit | 适合安静表面、分组行、柔和弹层。 | [A](interface-images/hibiki-bottom-sheet-A.svg) [B](interface-images/hibiki-bottom-sheet-B.svg) [C](interface-images/hibiki-bottom-sheet-C.svg) |
| `hibiki_divider.dart` | B | [选择图](interface-images/hibiki-divider-B.svg) | Cupertino surface kit | 适合安静表面、分组行、柔和弹层。 | [A](interface-images/hibiki-divider-A.svg) [B](interface-images/hibiki-divider-B.svg) [C](interface-images/hibiki-divider-C.svg) |
| `hibiki_dropdown.dart` | B | [选择图](interface-images/hibiki-dropdown-B.svg) | Cupertino surface kit | 适合安静表面、分组行、柔和弹层。 | [A](interface-images/hibiki-dropdown-A.svg) [B](interface-images/hibiki-dropdown-B.svg) [C](interface-images/hibiki-dropdown-C.svg) |
| `hibiki_icon_button.dart` | B | [选择图](interface-images/hibiki-icon-button-B.svg) | Cupertino surface kit | 适合安静表面、分组行、柔和弹层。 | [A](interface-images/hibiki-icon-button-A.svg) [B](interface-images/hibiki-icon-button-B.svg) [C](interface-images/hibiki-icon-button-C.svg) |
| `hibiki_list_tile.dart` | B | [选择图](interface-images/hibiki-list-tile-B.svg) | Cupertino surface kit | 适合安静表面、分组行、柔和弹层。 | [A](interface-images/hibiki-list-tile-A.svg) [B](interface-images/hibiki-list-tile-B.svg) [C](interface-images/hibiki-list-tile-C.svg) |
| `hibiki_marquee.dart` | B | [选择图](interface-images/hibiki-marquee-B.svg) | Cupertino surface kit | 适合安静表面、分组行、柔和弹层。 | [A](interface-images/hibiki-marquee-A.svg) [B](interface-images/hibiki-marquee-B.svg) [C](interface-images/hibiki-marquee-C.svg) |
| `hibiki_placeholder_message.dart` | B | [选择图](interface-images/hibiki-placeholder-message-B.svg) | 安静骨架屏 | 适合等待内容加载时减少跳动。 | [A](interface-images/hibiki-placeholder-message-A.svg) [B](interface-images/hibiki-placeholder-message-B.svg) [C](interface-images/hibiki-placeholder-message-C.svg) |
| `hibiki_popup_position.dart` | B | [选择图](interface-images/hibiki-popup-position-B.svg) | Cupertino surface kit | 适合安静表面、分组行、柔和弹层。 | [A](interface-images/hibiki-popup-position-A.svg) [B](interface-images/hibiki-popup-position-B.svg) [C](interface-images/hibiki-popup-position-C.svg) |
| `hibiki_search_history.dart` | B | [选择图](interface-images/hibiki-search-history-B.svg) | Cupertino surface kit | 适合安静表面、分组行、柔和弹层。 | [A](interface-images/hibiki-search-history-A.svg) [B](interface-images/hibiki-search-history-B.svg) [C](interface-images/hibiki-search-history-C.svg) |
| `hibiki_selectable_text.dart` | B | [选择图](interface-images/hibiki-selectable-text-B.svg) | Cupertino surface kit | 适合安静表面、分组行、柔和弹层。 | [A](interface-images/hibiki-selectable-text-A.svg) [B](interface-images/hibiki-selectable-text-B.svg) [C](interface-images/hibiki-selectable-text-C.svg) |
| `hibiki_tag.dart` | B | [选择图](interface-images/hibiki-tag-B.svg) | 分组标签管理 | 适合设置式管理。 | [A](interface-images/hibiki-tag-A.svg) [B](interface-images/hibiki-tag-B.svg) [C](interface-images/hibiki-tag-C.svg) |
| `hibiki_text_selection_controls.dart` | B | [选择图](interface-images/hibiki-text-selection-controls-B.svg) | Cupertino surface kit | 适合安静表面、分组行、柔和弹层。 | [A](interface-images/hibiki-text-selection-controls-A.svg) [B](interface-images/hibiki-text-selection-controls-B.svg) [C](interface-images/hibiki-text-selection-controls-C.svg) |
| `hibiki_toast.dart` | B | [选择图](interface-images/hibiki-toast-B.svg) | Cupertino surface kit | 适合安静表面、分组行、柔和弹层。 | [A](interface-images/hibiki-toast-A.svg) [B](interface-images/hibiki-toast-B.svg) [C](interface-images/hibiki-toast-C.svg) |
| `platform_utils.dart` | B | [选择图](interface-images/platform-utils-B.svg) | Cupertino surface kit | 适合安静表面、分组行、柔和弹层。 | [A](interface-images/platform-utils-A.svg) [B](interface-images/platform-utils-B.svg) [C](interface-images/platform-utils-C.svg) |
| `swipe_dismiss_wrapper.dart` | B | [选择图](interface-images/swipe-dismiss-wrapper-B.svg) | Cupertino surface kit | 适合安静表面、分组行、柔和弹层。 | [A](interface-images/swipe-dismiss-wrapper-A.svg) [B](interface-images/swipe-dismiss-wrapper-B.svg) [C](interface-images/swipe-dismiss-wrapper-C.svg) |
| `update_checker.dart` | B | [选择图](interface-images/update-checker-B.svg) | 账户式资料 | 适合更强个人资料氛围。 | [A](interface-images/update-checker-A.svg) [B](interface-images/update-checker-B.svg) [C](interface-images/update-checker-C.svg) |
| `blur_options.dart` | B | [选择图](interface-images/blur-options-B.svg) | 预览工作室 | 阅读自定义必须边调边看，预览比纯设置列表更重要。 | [A](interface-images/blur-options-A.svg) [B](interface-images/blur-options-B.svg) [C](interface-images/blur-options-C.svg) |

## 确认格式

如果接受这套默认值，回复：

```text
Pack: reading-calm
```

如果只改少量例外，回复：

```text
Pack: reading-calm
reader_hoshi_page.dart: B
dictionary_dialog_page.dart: C
```

不要在确认前改运行时代码。确认后再把选择重新生成到实现规格，并写 Flutter 实施计划。
