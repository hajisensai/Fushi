## BUG-1945 · 视频取消全屏短暂闪现 deactivated widget 红屏
- **报告**：2026-08-29（用户：）
- **真实性**：✅ 真 bug。`fushi/lib/src/pages/implementations/video_fushi/fullscreen.part.dart` 先 `await Navigator.of(context).maybePop()` 卸载全屏路由，随后又通过同一 controls `context` 调 `FullscreenInheritedWidget.of(context)`；元素处于 deactivated、尚未 dispose 的窗口里仍可能 `mounted == true`，因此原有 mounted 判断无法阻止截图中的祖先查找异常。
- **[x] ① 已修复** — `_exitVideoFullscreen` 在 pop 前捕获 `NavigatorState` 和父 `VideoState`，await 后只使用稳定引用，并在刷新前检查父 state 是否仍 mounted，不再访问已失活 context。
- **[x] ② 已加自动化测试** — `fushi/test/pages/video_fullscreen_exit_context_guard_test.dart` 钉住两项依赖必须在 pop 前捕获，并禁止 `await navigator.maybePop()` 后残留任何 context 访问。
- **备注**：Windows 真实退出全屏路径仍需增量构建后复测；按用户要求跳过测试套件。
