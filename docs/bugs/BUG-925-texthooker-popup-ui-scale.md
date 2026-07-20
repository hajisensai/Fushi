## BUG-925 · 捕获工作台非默认缩放下查词断言
- **报告**：2026-07-19（用户：）
- **真实性**：✅ 真 bug。`hibiki/lib/src/pages/implementations/texthooker_page.dart:601` 旧实现把查词浮层直接放在捕获页内的缩放 Stack；`DictionaryPopupWebView` 在 `hibiki/lib/src/pages/implementations/dictionary_popup_webview.dart:971` 明确断言必须处在净缩放 1 的 `HibikiAppUiScaleNeutralizer` 下，非默认 UI 缩放必然触发截图中的红屏。
- **[x] ① 已修复** — 查词浮层移到根 Overlay，整棵 barrier / loading / WebView 浮层由 `HibikiAppUiScaleNeutralizer` 包裹；点词的 `localToGlobal` 屏幕矩形与中和后的浮层统一使用真实屏幕坐标。销毁/切页时同步摘除 Overlay，避免失活 State 重建。
- **[x] ② 已加自动化测试** — `hibiki/test/pages/texthooker_lookup_popup_overlay_test.dart` 守住“根 Overlay + 缩放中和 + 页面内不再内嵌浮层”的接线；现有 `app_ui_scale_neutralizer_test.dart` 覆盖中和器几何行为。捕获页 widget 测试在 520/1000/1440 宽度全部通过。
- **备注**：真实 Windows WebView 无法在 widget test 创建，因此采用平台视图可落地的最强层：中和器行为测试 + 宿主接线守卫。
