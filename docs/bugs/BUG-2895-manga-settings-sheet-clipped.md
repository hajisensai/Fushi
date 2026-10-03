## BUG-2895 · 漫画阅读设置侧栏显示不全
- **报告**：2026-10-03（用户：漫画模块的设置显示不全，每个标签都要看）
- **真实性**：✅ 真 bug。阅读器设置是 400px 右侧栏（`reader_desktop_chrome.dart` `kReaderSideSheetWidth`，窄窗更窄），四个标签逐个用真字体渲染（中/英 × 400/320 宽）后定位到：
  - 「阅读模式」「常规」标签的下拉行：`manga_reader_settings_sheet.dart` `_choice` 里 `AdaptiveSettingsPickerRow` 走默认并排布局，下拉只分到一百来像素，值被硬裁（英文 320 宽下「Right to」「Fit scree」）。
  - 「漫画 OCR」标签嵌入的 `MangaOcrSettingsSection`（`manga_ocr_settings_section.dart`）：引擎下拉闭合态 `TextOverflow.ellipsis` 单行省略 + `DropdownButtonFormField` 默认 dense 固定一行高；并行任务说明 `helperMaxLines: 3` 吞掉结尾；mokuro 路径提示默认单行；探测结果单行省略。
  - 底部「当前作品 / 恢复全部全局默认」竖排占近 100px，横屏手机上设置列表只剩一两行可见。
  - 「自定义滤镜」标签本身无截断（滑条与颜色输入均完整）。
- **[x] ① 已修复** — 下拉行 `controlBelow: true`（与小说 `reader_quick_settings_sheet.dart` 同形）；引擎下拉 `isDense: false` + 标签可换行；说明 `helperMaxLines: 8`（不能传 null：helper 带 ellipsis，null 反而退化成单行）；mokuro 提示 `hintMaxLines: 3`、探测结果 `maxLines: 3`；页脚改 `Wrap(spaceBetween)` 放得下就一行。
- **[x] ② 已加自动化测试** — `fushi/test/media/manga/manga_reader_settings_sheet_test.dart`「BUG-2895: choice dropdowns span the narrow sheet」（320 宽下每个下拉宽 ≥ 260）、`fushi/test/media/manga/manga_ocr_settings_section_ui_test.dart`「BUG-2895: narrow reader sheet shows engine and helper in full」（引擎标签与说明 `didExceedMaxLines` 为假、不越出输入框）。两条均已验证在旧实现上变红。
- **备注**：未上真机 / 模拟器复测，验证依据是 widget test 真字体（等线）像素预览逐标签前后对比。
