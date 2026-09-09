## BUG-2373 · 安卓平板触控笔闲置1-2分钟后悬停/压力/侧键全失效
- **报告**：2026-09-09（用户：hajisensai）
- **现象**：安卓平板在 Hibiki 内使用触控笔，约 1~2 分钟不操作后，笔的悬停光标、压力感应、侧键**全部**失效；同一时刻手指触摸完全正常（点击、滑动均可）。唯一恢复方式是切后台（多任务界面）再切回前台，恢复后再次闲置又复发。系统自带笔记应用与其他第三方应用无此现象。用户已关闭平板全局手势与电池优化，问题依旧。
- **真实性**：⏳ **未复现**（缺设备侧证据，见下）。三条独立代码路径排查后，**本仓不存在任何 1~2 分钟量级、会影响输入或窗口状态的逻辑**：
  - Android 原生层：全树无 `Timer` / `TimerTask` / `ScheduledExecutorService`；唯二 `postDelayed` 在独立 `:network_challenge` 进程；窗口 flag 创建后除亮度（`MainActivity.java:1089-1101`）与悬浮窗焦点开关（`FloatingDictService.java:164-172`）外从不变动；无 `onHoverEvent` / `onGenericMotionEvent` / `setPointerIcon` / `TOOL_TYPE_STYLUS` 任何实现（零匹配）。
  - Dart 层：最接近的空闲门是 `StudyClock`，默认 `kDefaultReadingIdleTimeout = 10 分钟`（`packages/fushi_audio/lib/src/audiobook/study_clock.dart:32`），且超时只做 `_seal()` 结算 DB 段落，不触碰窗口/焦点/WebView。全部 `SystemChrome.*` 调用均由页面进出、用户点击、内容就绪或 `resumed` 触发，无一由定时器触发。
  - WebView/JS 层：注入脚本无任何定时 `removeEventListener`，无定时改 `pointer-events`/`touch-action`/`cursor`，reader 内 30 秒~3 分钟量级定时逻辑零匹配。
- **两条相关但独立的既有事实**（排查副产物，均非本症状根因）：
  1. **`keepScreenAwake` 走 `FLAG_KEEP_SCREEN_ON`**：`reader_fushi_page.dart:2462` / `app_model.dart:5820` → `wakelock_plus-1.7.0/android/.../Wakelock.kt:28` `window.addFlags(FLAG_KEEP_SCREEN_ON)`。这是本 app 唯一与「用户长时间无输入」耦合的窗口状态：其他应用屏幕会超时变暗迫使用户交互，Hibiki 让屏幕长亮而系统侧「用户已闲置」计时照走。**是否会导致厂商停止笔数字化仪扫描，未经证实，不得当结论。**
  2. **本 app 对 stylus hover 的支持本就缺失**（既有缺口，与「先能用后失效」无关）：`fushi/lib/src/focus/fushi_focus_target.dart:209`、`fushi/lib/src/utils/misc/platform_utils.dart:301`、`dictionary_popup_layer.dart:984`、`video_fushi/controls_visibility.part.dart:74` 的 hover 逻辑一律 `kind != PointerDeviceKind.mouse → return`，把 stylus 排除；阅读器注入 JS 只监听 `mousemove`（`reader_fushi/webview.part.dart:1505`），无 `pointerover`/`pointerenter`，全仓无 `pointerType === 'pen'` 分支。侧键唯一通道是 `webview.part.dart:1371` 的 `mousedown` 非左键分支。
- **待用户提供的定性证据**（每条都能单独切开责任方）：
  1. 失效时**不切后台**，改为旋转屏幕（触发 `onConfigurationChanged`，窗口重建但不离开 app）——若恢复则问题在窗口/输入通道层；若不恢复则在进程/系统层。
  2. 失效时下拉系统通知栏，在通知栏区域悬停——系统 UI 也失效 = 系统级停止笔扫描，与 Hibiki 无关；仅 app 内失效 = 本窗口问题。
  3. 关闭阅读器「保持屏幕常亮」设置后复现——验证事实 1 的 `FLAG_KEEP_SCREEN_ON` 假说。
  4. 停在**设置页**（纯 Flutter，无 WebView）而非阅读器页时是否同样失效——切开 WebView 责任。
  5. 平板品牌型号 + 系统版本（S Pen / 华为 M-Pencil / 小米灵感笔的悬停与侧键实现各不相同）。
  6. 失效前后 `adb shell dumpsys input`（关注 stylus InputDevice 是否仍 enabled）与 `adb logcat` 片段。
- **[ ] ① 未修复** — 根因未定位，等设备侧证据。
- **[ ] ② 未加自动化测试** —
- **备注**：现阶段证据不支持「这是 Hibiki 的 bug」，也不足以排除。三路排查（Android 原生 / Dart 生命周期 / WebView+JS）均为负面证据，已在上方逐条记录，避免后续重复挖掘。上述「既有事实 2」（stylus hover 支持缺失）可独立立项改善，与本条互不阻塞。
