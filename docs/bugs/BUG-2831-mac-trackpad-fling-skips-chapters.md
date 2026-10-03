## BUG-2831 · Mac触控板滚动模式乱跳章节
- **报告**：2026-10-01（用户：「mac用触摸板滚动的时候会乱跳章节」，附 16.7s 录屏，横排滚动模式）
- **真实性**：✅ 真 bug。录屏逐帧：进度 17.4%→28.1% 为章内平滑滚动，之后 28.1→34.4→45.2→54.0→55.1% 逐章跳。28.1→34.4 那一跳的全帧显示新章「第三章」从开头装好后，**手指已离开**的情况下正文又被继续推下去一屏多——上一章那次触控板滑动的系统惯性跨过了换 document 的跨章，在新章接着滚。连续滑几下就一章章往后跳。根因：连续模式 wheel 监听（`fushi/lib/src/pages/implementations/reader_fushi/webview.part.dart` 正文引擎 wheel 监听的连续分支）的手势时间线 `_continuousWheelLastTickAt` 随换文档归零，新章收到的残余惯性 tick 被当作普通滚动直接落地；Dart 侧 `_pagedWheelGestureGate` 只拦「二次跨章」，拦不住惯性在新章里滚动。手机跨章后新页面没有惯性，所以只有触控板出问题。
- **[x] ① 已修复** — `kContinuousWheelScrollJs` 新增 `_swallowInheritedTrackpadFling`：每个章节文档装载起，触控板 tick 一律吞掉（`preventDefault`，不滚、不判边界），直到出现一次 ≥ 滚轮手势静默窗的间隔（= 新手势）才恢复跟手；鼠标滚轮不受影响。
- **[x] ② 已加自动化测试** — `fushi/test/reader/continuous_wheel_smooth_scroll_test.dart`：真 Chrome 执行生产 helper 新增 2 个用例（1.5s 惯性流整段被吞、静默后新手势放行；装载后静默的首个手势不被吞），外加监听接线守卫（吞惯性只在触控板分支、先于试滚与跨章回传）；变异实测（吞惯性恒放行）转红。
- **备注**：未在 Mac 真机复测。代价是章节装载后静默窗（150–800ms，取「滚轮翻页间隔」设置值）内的第一次触控板滑动会被吞掉，需要重新滑一下。
