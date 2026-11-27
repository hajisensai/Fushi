## BUG-5554 · ocr-frame-pick-main-window-stays-front
- **报告**：2026-11-26（应用内反馈 6RETmKY1TH，Windows 3.4.0）
- **真实性**：✅ 真 bug。开了「制卡时框选截图」，在截屏识字的查词卡上点「+」：`fushi/lib/src/floating_ball/app_floating_ball_host.dart` 的 `_pickDesktopScreenOcrCardFrame` 关冻结层、`dismissLookup()` 关掉查词卡后调 `bringMainWindowToFront()`（`DesktopLookupService.bringMainWindowToFront`，`fushi/lib/src/sync/desktop_lookup_service.dart:147` 起：已最小化就 `restore()`，再 `show()` + `focus()`）把主窗拉到前台推框选页；框选页返回后（制卡、放弃都一样）整条链上没有任何地方把主窗放回原处，也没有把前台还给原来的程序。原来最小化 / 收在托盘的 Fushi 就停在前台（最小化前是最大化的话还原成最大化），用户正在用的程序丢了前台。而且查词卡已经被关掉，结果只能在主窗 toast（`overlay_bridge_handlers.dart` 的 `toastOutcome`），这又反过来要求主窗留在前台。
- **[x] ① 已修复** — 拉前台只是框选那一会儿要用，框完放回：
  - 截屏识字开始时（冻结层抢前台之前）记下主窗呈现状态（在屏 / 最小化 / 托盘）与用户前台窗口：`DesktopLookupService.captureMainWindowPresentation` + 新原生方法 `floating_ball.foregroundAppToken`（Windows 回 `GetForegroundWindow()` 的 HWND，macOS 回 `frontmostApplication` 的 pid，前台是 Fushi 自己时回 null），存进 `_DesktopScreenOcrSession.presentation`。
  - 框选时查词卡用 `suspendForCapture` **收起**而不是关掉（WebView、route、位置都留着；收不起来才退回关卡）。
  - 框选页返回（`finally`，制卡与放弃都走）：`settleMainWindowPresentation` 把主窗放回托盘 / 最小化 / 不动，再 `restoreAfterCapture(gen, returnForeground: token)`：原生先 `SetForegroundWindow` / `NSRunningApplication.activate` 把前台还给原程序，并把这次交还登记成「本进程主动交还」（Windows 复用 BUG-2651 的放行标记，改名 `expected_foreground_return_`；macOS 新增 `expectedActivationPid`），前台钩子不会因此关卡，然后不激活地放回卡片。制卡结果照常回给卡片就地说；只有卡收不起来 / 放不回来时才在主窗 toast（`ScreenOcrFramePick.reportOutcomeOnHost`）。
  - 顺带修 macOS：卡片收起期间点主窗（框选页里拖框）会被 `localClickMonitor` 当成点卡外关卡，切 app 也会被激活观察者关卡；收起中一律不算（Windows 那边收起时 `IsShowing()` 本来就为假）。
- **[x] ② 已加自动化测试** — `fushi/test/floating_ball/app_floating_ball_host_test.dart`「反馈 6RETmKY1TH」组：框选页放弃后依次 `settle:minimized` → `restore:<gen>:<前台句柄>`、托盘场景 `settle:hidden`、卡收不起来时退回关卡且主窗不放回；`overlay_window_channel_test.dart` 钉 `returnForeground` 上线。
- **备注**：前台交还与窗口状态是原生行为，没做真机验证（PR 里写明）。Linux 没有桌面系统球截屏识字，`restoreAfterCapture` 多出的参数被忽略。
