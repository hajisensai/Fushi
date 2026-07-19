## BUG-912 · 异常/取消路径状态不复位（Windows 弹窗资产永久闩 + 长按缺 onLongPressCancel）

- **报告**：2026-07-19（审计复核）
- **真实性**：✅ 真 bug（#2/#3 沿真实代码路径定位）。#1 见备注。
- **[x] ① 已修复** — #2 去进程级永久闩、#3 补 onLongPressCancel。
- **[x] ② 已加自动化测试** — `hibiki/test/pages/popup_latch_and_longpress_guard_test.dart`（源码扫描守卫）。
- **备注**：审计点名的 #1「temporarilyDisableStatusBarHiding 缺 finally」按当前代码**未能定位到该方法名/语义**——该标识符全仓不存在；最接近的 `openMedia` 沉浸设定本就是「持续隐藏到 closeMedia」的有意设计，且视频页等价路径 `_restoreSystemUiOnExit` 已有 dispose 还原 + `video_statusbar_immersive_guard_test` 守卫。按「不修臆想缺陷」原则，#1 标为**未定位/疑似已消解**，不武断改动核心媒体打开流程。

### 现象
- Windows 弹窗词典偶发永久降级到不可靠的 `file://` 加载：一次读盘异常后，之后整个进程再不尝试内联资产。
- 有声书快捷设置里的 +/- 长按连触按钮：手指滑出取消（而非正常松手）时，数值持续狂涨/狂降不停。

### 根因
- **#2 Windows 资产永久闩** `dictionary_popup_webview.dart`：`static bool _inlineAssetsLoadFailed`，门控 `_ensureInlinePopupAssetsLoaded()` `if (_inlineCss != null || _inlineAssetsLoadFailed) return;`，catch 里 `_inlineAssetsLoadFailed = true`。该闩**只置位无复位**，一次瞬时读盘异常（文件锁/磁盘抖动）即进程级永久 true → 之后早退、内联资产永不重试。
- **#3 长按 Timer 缺 cancel** `reader_quick_settings_sheet.dart` `_RepeatIconButtonState`：GestureDetector 只挂 `onLongPressStart(_start)`/`onLongPressEnd(_stop)`，**无 `onLongPressCancel`**。手势被取消（指针滑出/识别器被上层竞争夺走）时 `onLongPressEnd` 不必然回调，`_timer` 每 100ms 连触 `onPressed()` 直到 widget dispose。孪生实现 `video_hibiki_page.dart:6202` `_VideoRepeatGestureButton` 已正确挂 `onLongPressCancel: _stop`，此处漏了。

### 修复
- #2：删 `_inlineAssetsLoadFailed` 字段，门控收敛为 `if (_inlineCss != null) return;`（成功后 `_inlineCss` 非空已足以防重复读盘），catch 保留 `debugPrint` + `ErrorLogService.log`；失败后下次唤起自然重试，不再永久降级。
- #3：`_RepeatIconButton` 的 GestureDetector 补 `onLongPressCancel: () => _stop()`，与视频页孪生对齐。
