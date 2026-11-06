## BUG-4126 · Windows WebView build 读 FlutterView.display 空断言（视图 displayId 不在引擎显示器表里）
- **报告**：2026-11-06（闪退报告整批分诊：`eZMo2PT6c_`，Windows 11 26100，3.3.0-debug.23855 的历史日志段）。
- **真实性**：✅ 真 bug（非致命，不是那份报告里进程退出的原因）。日志 18:11:09–18:16:43 连续 5 次 `FlutterError: building Instance of 'StatefulElement'`，`Null check operator used on a null value`：
  - `#0 FlutterView.display (dart:ui/window.dart:107)` ← `#1 _CustomPlatformViewState.build (flutter_inappwebview_windows/src/in_app_webview/custom_platform_view.dart:583)`。
  - Flutter 3.47.6 `window.dart:105-108`：`display` getter 只有 debug 断言 `_displays.containsKey(displayId)`，release 下对查不到的 id 直接 `!`。Windows 引擎给视图报的 displayId（视图所在显示器）不保证已在 `PlatformDispatcher.displays` 里（推测场景：显示器热插拔 / 睡眠唤醒 / 远程桌面切换后，引擎显示器表还没刷新）。
  - 后果：WebView 的 build 抛错，整块变成错误占位（release 下灰块），直到下一次重建恰好拿得到。
  - 用它只是为了给纹理容量增长封顶（BUG-3913 `nextTextureCapacity` 的 `display` 参数，0 = 无上限）。
- **[ ] ① 未修复（PR 待合）** — `custom_platform_view.dart` build 不再读 `FlutterView.display`，改用 `largestDisplayCapacity(View.of(context).platformDispatcher.displays)`（`texture_capacity.dart`）：已知显示器里最大的一块；一块都不知道时为 0（无上限）。封顶语义不变（窗口拖到哪块屏上都放得下，扩容次数仍有界），也不依赖引擎「视图 → 显示器」映射。
- **[ ] ② 自动化测试（PR 待合）** — `packages/flutter_inappwebview_windows/test/texture_capacity_test.dart` 的 `largestDisplayCapacity` 组：多显示器取最大并取整、零显示器时无上限。
- **备注**：未在真机复现「displayId 不在表里」的触发场景（需要热插拔 / RDP），修法不依赖具体触发方式。
