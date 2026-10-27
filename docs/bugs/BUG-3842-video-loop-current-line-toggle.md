## BUG-3842 · 视频页没有「循环当前句」开关，精听只能反复按重播
- **报告**：2026-10-27（用户：GitHub Issue #2537 经 fushi-bot 转应用内反馈 Ix4j5SKUth，Windows / 浏览器扩展，功能诉求；所有者 2026-10-27 按分诊推荐拍板：加开关动作、默认不绑键、状态在 UI 上可见）
- **真实性**：✅ 缺口确认。`VideoPlayerController` 只有一次性「播到句尾就停」（`replayCue` 的 `_oneShotHoldCueIndex`，`fushi/lib/src/media/video/video_player_controller.dart:580`），没有任何循环播放某句的状态；`ShortcutAction` 里也没有对应动作。
- **[x] ① 已修复** — 状态归控制器（不在页面另存镜像）：
  - `_loopCurrentCue`（`ValueNotifier<bool>`，`loopCurrentCue` / `loopCurrentCueListenable` / `setLoopCurrentCue`）是**模式**不是钉死某一句：用户跳到别的句，循环的就是新进入的那句。
  - 武装目标 `_loopArmedCueIndex`：位置落在句内时记下该句；只有它被**播放中**越过句尾（相邻下一句 / gap 两条路径）才经 `skipToCue` 回到句首（前导余量、cue-snap 与跳句同一套，以「自动」身份登记不计遥控修订号）。任何显式 seek（`_noteSeekIssued`：`seekMs` / `_rawSeekMs` / `notifyExternalSeek`）与进度条开始拖动（`clearSeekTargetSnap`）都先撤武装，于是 seek 走不会被拽回原句，回绕后滞后的旧位置 tick 也不会连发；暂停中不回绕；一次性「播完就停」优先；`setCues` 清武装、插入解码字幕时随下标平移。
  - 新动作 `videoToggleLoopCurrentSubtitle`（**默认空绑定**，反馈提议的 Ctrl+R 与「重播当前句」R 太近，留给用户自配），接进 `VideoPlayerShortcutActions` / `videoActionCallbacks` / `kVideoAssignableActions`、标签 + 图标、i18n。页面 `_toggleLoopCurrentCue`（无字幕时提示、不开）。
  - UI：`fushi/lib/src/media/video/video_loop_cue_badge.dart` `VideoLoopCueBadge`，开着时右上角常驻「循环当前句」标记（与制卡队列角标同锚点，角标在时让一格；`AnimatedSwitcher` 淡入缩放，时长 `FushiMotion.short`，按压 `FushiPressScale`），点它关闭循环。网页视频页（WebView 播放、无本地位置 tick）该动作为 noop。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/video_loop_current_cue_test.dart`（控制器状态机 8 例：两条回绕路径 / 滞后 tick 不连发 / 关着不回绕 / seek 与拖进度条不被拽回 / 跳句后循环新句 / 暂停不回绕 / 一次性 hold 优先 / 开关通知；标记 widget 显隐与点击；全平台默认空绑定；页面接线守卫）；构造 `VideoPlayerShortcutActions` 的 7 个测试补参数。变异：去掉三处撤武装 → 3 例红，还原后全绿。
- **备注**：未在真机 / 真视频上验证 mpv 真实位置回调下的回绕手感（关键帧吸附由 `skipToCue` 的前导余量吸收）。循环模式跨换集保留（标记常驻可见）；浏览器扩展未加循环（分诊未要求，扩展另有自己的快捷键表）。顺带删掉 `video_copy_current_line_shortcut_test.dart` 两条多余 import（analyze warning）。
