## BUG-3836 · 长按倍速后徽章一直停在画面上，直到重开视频
- **报告**：2026-10-27（用户：应用内反馈 3sDHeyPQ-I，Windows 3.0.0+19763，视频播放页）
- **真实性**：✅ 真 bug（沿代码路径 + Flutter 框架源码确认，未在设备复现）。长按会话的收尾只挂在一个不保证回调的出口上：
  - `fushi/lib/src/pages/implementations/video_fushi/layout.part.dart:491-493`（修前）裸 `GestureDetector` 只接 `onLongPressStart / MoveUpdate / End`；清徽章 `_longPressSpeedBadge.value = null` 与恢复倍速只在 `video_fushi/speed.part.dart:118-133`（修前）`_handleVideoLongPressEnd` 里。
  - Flutter `LongPressGestureRecognizer`（`packages/flutter/lib/src/gestures/long_press.dart:670-672、716-718、862-866`）：长按**被接受之后**收到 `PointerCancelEvent` 只在 `state == possible` 时回调 `onLongPressCancel`，接受后直接 `_reset()`，start 之后不再有任何回调；识别器随手势层被销毁也一样。分诊里「接 `onLongPressCancel`」修不了这条——它只覆盖「还没开始就输掉」。
  - 于是被系统取消的长按（窗口失焦 / 指针捕获被抢 / 布局重建）留下徽章与 `_longPressPreviousSpeed` / `_longPressDragBaseSpeed`；`speed.part.dart:74` 的 `if (_longPressPreviousSpeed != null) return;` 又让之后的长按 start 早退、不再接管。反馈日志里 cue 时间与墙钟同速（1x），与「拖到 1.0x 后会话被取消、徽章停在 1.0x」吻合。
- **[x] ① 已修复** — 新增 `fushi/lib/src/media/video/video_long_press_session_detector.dart`（`VideoLongPressSessionDetector`）：外层 `Listener` 记按下的主指针，长按开始时把会话绑到这根指针；该指针的 up / cancel（指针层事件不经手势竞技场，一定会到）、识别器 end、widget 卸载三个出口汇到同一个幂等 `_finish`，每个已开始的会话恰好收尾一次（卸载时推到微任务，避开树锁定）。视频页手势层换成它，`_handleVideoLongPressEnd` 改为无参并在页面已卸载时直接返回。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/video_long_press_session_detector_test.dart`（真实手势：正常松手 / 接受后 cancel / 途中卸载 / 阈值前 cancel / 多指 / 连续两次，6 例）。变异：去掉 `onPointerCancel` 绑定 + 去掉卸载收尾 → 3 例红，还原后全绿。
- **备注**：未在 Windows 真机复现「被系统取消」的具体触发源（日志无指针事件记录）；修复不依赖触发源，所有收尾出口都已覆盖。
