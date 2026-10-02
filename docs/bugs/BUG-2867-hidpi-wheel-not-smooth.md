## BUG-2867 · 高 DPI 下鼠标滚轮补间从不生效：粗细判据按逻辑像素
- **报告**：2026-10-02（用户：「fushi 很多地方滚轮滑动都不够流畅没有滚动动画，还有查词框也没滚动动画」）
- **真实性**：✅ 真 bug。BUG-2834 的根部 `SmoothWheelScrollScope` 只给「粗滚轮」补间，判据 `isCoarseDesktopPointerScrollDelta`（`fushi/lib/src/utils/misc/smooth_wheel_scroll.dart:9`）写的是**逻辑像素** `delta.abs() >= 80`，注释假设「Windows/Linux 一档约 100–120 logical px」。实际引擎发的是**物理像素**、框架 converter 再除以 devicePixelRatio（`packages/flutter/lib/src/gestures/converter.dart:283`）：
  - Windows：`flutter_window.cc` `UpdateScrollOffsetMultiplier` 一档 = `行数 × 100/3` 物理 px（默认 3 行 = 100）→ 150% 缩放 66.7、175% 57、200% 50 逻辑 px；
  - Linux：`fl_scrolling_manager.cc` 一档 = `53 × 缩放` 物理 px → 任何缩放都是 53 逻辑 px。

  都低于 80，于是每一档都被当成触控板 / 高精度滚轮走原生同步路径，补间从未生效。报告机器 `AppliedDPI=192`（200%）、滚动 3 行，正中此列；测试环境用的是 120 逻辑 px，所以 BUG-2834 的测试全绿。

  查词框（popup.js）这条链路**没有**同类问题：inappwebview Windows fork 把 Flutter 逻辑 delta 按 `dpr × WHEEL_DELTA / (行数×100/3)` 逆回原生滚轮单位再交给 WebView2（`packages/flutter_inappwebview_windows/windows/in_app_webview/in_app_webview.cpp:2061`），WebView2 一档报 `deltaY=100` CSS px（Edge `--force-device-scale-factor=1.5` 实测，真实 `WM_MOUSEWHEEL`），popup.js 的 `>= 60` 判据在任何缩放下都判为粗滚轮、走 `popupWheelEaseBy` 缓动。报告者日常用的开发版构建自本地 develop（2026-09-30），还没合入 BUG-2834（2026-10-01），所以查词框还是一格一跳；升级到含 BUG-2834 的构建即可。
- **[x] ① 已修复** — 判据改按物理像素：`isCoarseDesktopPointerScrollDelta(delta, devicePixelRatio:)` = `|delta| × dpr >= 30`（`kCoarseWheelMinPhysicalDelta`；一档最少是每次 1 行的 33 物理 px，高精度滚轮 1/8 档约 12.5），DPR 取 `View.maybeOf(context)`。距离仍 1:1（BUG-2009），只改「要不要补间」。
- **[x] ② 已加自动化测试** — `fushi/test/utils/misc/smooth_wheel_scroll_scope_test.dart`：200% 缩放一档 50 逻辑 px 分帧到达、200% + 每次 1 行（16.5 逻辑 px）仍补间、200% 下高精度 1/8 档（6.25 逻辑 px）仍同步；原有细 delta 用例显式设 DPR 1（测试视图默认 DPR 3）。`fushi/test/utils/misc/desktop_scroll_physics_test.dart`：150% / 200% / 1 行 / Linux 53 的判据单测。变异实测：判据改回逻辑 px `>= 80` → 见下方备注。
- **备注**：未在 Windows 真机手测补间观感，只有 widget 测试；Linux 未实机验证（结论来自引擎源码）。
