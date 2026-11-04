## BUG-4005 · 离开词典样式页时预览续体读已卸载 context 空断言
- **报告**：2026-11-04（从反馈 #63DhJLTAHW 附带日志里发现，Linux 3.0.1：`[2026-11-03 19:06:02] UncaughtZone · Null check operator used on a null value · State.context ← _DictStylePreviewState._pushTheme (dict_style_preview.dart:83) ← _bootstrap (:146)`）。该反馈的主症状另见 BUG-4008。
- **真实性**：✅ 真 bug。`_bootstrap` 由平台 WebView 的 `onLoadStop` 触发，先 `await controller.evaluateJavascript(...)`（修前 `fushi/lib/src/pages/implementations/dict_style_preview.dart:152` 起），再 `await _pushTheme()`（修前 `:170`），而 `_pushTheme` 读 `Theme.of(context)`（修前 `:101`）。JS 往返期间用户离开词典样式页，State 已卸载，续体读 `context` 即空断言；`onLoadStop` 本身也可能在卸载后才到（`_bootstrap` 入口修前 `:152` 直接读 `Theme.of(context)`）。现 develop 代码与 3.0.1 同形，未修。
- **[x] ① 已修复** — 生命周期：`_bootstrap` 入口与每个 await 之后、`_pushTheme` / `_pushStyles` 入口都先确认 `mounted`（`dict_style_preview.dart:91`、`:151` 起）。不是吞异常：卸载后本来就没有可推送的预览。
- **[x] ② 已加自动化测试** — `fushi/test/pages/dict_style_preview_async_unmount_guard_test.dart`（源码守卫：单测环境没有真 WebView，无法让 onLoadStop 在卸载后到达，与 `dict_style_preview_eink_guard_test` 同处境）：钉住 `_pushTheme` 读 context 前、`_pushStyles` 读 widget 前、`_bootstrap` 入口与每个 await 之后都有挂载守卫。
- **备注**：无。
