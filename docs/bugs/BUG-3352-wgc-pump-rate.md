## BUG-3352 · Windows WebView popup scroll capped near 32 fps by WGC pump timer
- **报告**：2026-10-14（用户：查词弹窗查完词后鼠标滚动帧率很低、没有平滑滚动，滚起来怪怪的；不限于小说，别处弹窗也一样）
- **真实性**：✅ 真 bug。Windows 上所有 InAppWebView 都是 WebView2 离屏合成 → WGC 抓帧 → Flutter 纹理，抓帧不订阅 FrameArrived，靠 UI 线程 `DispatcherQueueTimer` 定时拉帧（`packages/flutter_inappwebview_windows/windows/custom_platform_view/texture_bridge.cc:23` 的 `kPumpInterval100ns = 166667`，即 16.67ms「60Hz」）。这种定时器按系统计时器一格（默认 15.625ms）向上取整触发，16.67ms 超过一格就变成每两格一次。本机独立程序实测（UI 消息循环线程 + `DQTYPE_THREAD_CURRENT`，各 120 次 Tick 取均值）：

  | 间隔 | 默认计时精度 | `timeBeginPeriod(1)` |
  |---|---|---|
  | 16.67ms（修复前） | 31.3ms / **31.9Hz** | 18.1ms / 55.4Hz |
  | 15ms | 29.4ms / 34.0Hz | 15.5ms / 64.4Hz |
  | 8.33ms（修复后） | 15.3ms / **65.4Hz** | 8.8ms / 113.4Hz |
  | 4ms | 15.4ms / 65.1Hz | 4.5ms / 221.1Hz |

  WebView 内部的滚动和 popup.js 的 rAF 缓动（BUG-2834）都照常跑，但送到 Flutter 的画面只有约 32 帧，所以缓动看起来一顿一顿的，像「没有平滑滚动」。阅读器等其它 Windows WebView 受同一个上限影响。
- **[x] ① 已修复** — `kPumpInterval100ns` 改成 83333（8.33ms），默认精度下每格都触发（~64Hz），进程提了计时精度时 ~113Hz，可跟上 120Hz 屏。没有新帧时 `TryGetNextFrame` 直接返回空、不推 Flutter 帧，多出来的 Tick 开销很小。没有退回 FrameArrived（BUG-209 系列 UAF 就是为躲开它才改成定时拉帧的）。
- **[x] ② 已加自动化测试** — `fushi/test/widgets/wgc_pump_interval_guard_test.dart`：源码守卫要求间隔在 [4ms, 10ms] 之间，并且确实被泵定时器使用。旧值 166667 时测试红，新值绿。
- **备注**：没有做到对齐垂直同步。默认精度下 64Hz 拉帧对 60Hz 屏仍可能偶尔重复一帧；144Hz 屏在默认精度下也只有 ~64 帧。要彻底对齐需要独立线程等 vblank 再投递到 UI 线程，这块生命周期是 BUG-209 系列的高危区，这次先不动。
