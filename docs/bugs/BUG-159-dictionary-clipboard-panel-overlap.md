## BUG-159 · 外部查词文本面板不应覆盖查词结果
- **报告**：2026-06-09（用户：截图反馈查词页搜索框下方黑框很丑且压住结果）
- **真实性**：✅ 真 bug；根因 `hibiki/lib/src/pages/implementations/home_dictionary_page.dart:491` 将 `ClipboardLookupTextPanel` 作为 `Positioned(top: 0)` 叠在结果 `Stack` 内，未给 `DictionaryPopupWebView` 让出布局空间。
- **[x] ① 已修复** — 外部查词文本改为结果区上方的普通流式布局，并把提示面板改成无卡片文本条。
- **[x] ② 已加自动化测试** — `hibiki/test/pages/desktop_clipboard_click_lookup_static_test.dart`；`hibiki/test/widgets/clipboard_lookup_text_panel_test.dart`。
- **备注**：已跑相关 Flutter 测试；未做真实设备肉眼复测。
