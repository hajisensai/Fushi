## BUG-5612 · video-web-parentdata-conflict
- **报告**：2026-11-28（BUG-5611 集成测试 `fushi/integration_test/web_video_builtin_capture_itest.dart` 在 Debug 构建里发现，非用户报告）
- **真实性**：✅ 真问题（Debug 断言），根因位置未定。网页站流媒体书在 `VideoFushiPage` 以「制卡优先」档打开时，框架报两次 `Incorrect use of ParentDataWidget`：同一个 RenderObject 上叠了两层 `Positioned`——外层 `Positioned(left: 0, top: 0, right: 0, bottom: 0)`（即 `Positioned.fill`），内层 `Positioned(left: 0, top: 84, right: 0, bottom: 0)`。所有权链：`Padding ← SafeArea ← Positioned ← Positioned ← Stack ← Positioned ← Stack ← SizedBox ← Row ← AnimatedBuilder ← ⋯`。说明某个返回 `Positioned` 的叠层 builder 又被调用方包了一层 `Positioned.fill`。Release 里断言不跑，但内层的 `top` 偏移会被外层覆盖或丢掉，该叠层的位置可能不对。app 的 `FlutterError.onError` 会把它吞进错误日志，所以平时看不到。
- **[ ] ① 未修复** — 待定位：按上面的所有权链在 `video_fushi_page.dart` / `video_fushi/*.part.dart` 里找「Positioned.fill 包着一个自己返回 Positioned(top: 顶栏高) + SafeArea 的 builder」的调用点；用 `--track-widget-creation` 跑可以直接拿到行号。
- **[ ] ② 未加自动化测试** — 修后在网页档打开的 widget 测试里断言 `tester.takeException()` 为 null。
- **备注**：复现：`$env:FUSHI_WEB_VIDEO_BUILTIN_CAPTURE_ITEST=1; .\tool\run_windows_itest.ps1 integration_test\web_video_builtin_capture_itest.dart`，在 FlutterError.onError 交还给测试 binding 的情况下即可看到。
