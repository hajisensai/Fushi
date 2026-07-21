## BUG-963 · 长按倍速拖动卡顿：每步全页 setState 掉帧

- **报告**：2026-07-21（用户：长按倍速条块没办法流畅拖动）
- **真实性**：✅ 真 bug。根因 `hibiki/lib/src/pages/implementations/video_hibiki/speed.part.dart:37`（`_setSpeed` 里 `if (mounted) _rebuild(() {});`）在长按横拖调速热路径 `_handleVideoLongPressMoveUpdate`（`speed.part.dart:91`）中被高频触发。
  - 长按视频临时加速后横向拖动调速（TODO-338/1154）：徽章位置走 `_longPressSpeedBadge`（`ValueNotifier` + 独立 `ValueListenableBuilder`，`volume_osd.part.dart:295`）每次 move 更新，本该丝滑；但每越过 0.1x 步进就 `unawaited(_setSpeed(snapped, persist: false))`，而 `_setSpeed` 内 `_rebuild(() {}) => setState(fn)`（`video_hibiki_page.dart:889`）**重建整个 ~7300 行视频页**（视频纹理 + 弹幕层 + 字幕 overlay + 控制条 + 章节刻度 + 缩略图预览）。
  - 拖动横移每 ~20px 触发一次全页 setState（`1/200` px→倍速，0.1x/步 = 20px/步），在重子树上掉帧 → 整帧卡顿，连带徽章「跟手」也一顿一顿。用户说「不流畅」而非「拖不动」正符合"手势已生效但掉帧"，非手势竞技场未抢到。
- **[x] ① 已根因修复** — `_setSpeed` 加 `bool rebuild = true`；长按临时加速的 start/move 传 `rebuild: false`——拖动全程徽章已实时渲染倍速，页面无需全页重建；松手 end 走默认 `rebuild: true` 一次性对账倍速按钮标签。消掉每步全页 setState 风暴，并顺带消除标签在拖动中"跳临时速再弹回"的闪烁。控制器 `setSpeed` 仍照发（弹幕靠 `controller.speed` 保持同步，不受影响）。提交：<待填>
- **[x] ② 已加自动化测试** — 扩展源码守卫 `hibiki/test/pages/video_long_press_speed_drag_static_test.dart` + `video_speed_follow_static_test.dart`：断言 `_setSpeed` 的 `_rebuild` 受 `rebuild` 门控、start/move 传 `rebuild: false`、end 不带（默认对账重建）。纯函数映射测试保持。测试文件：`hibiki/test/pages/video_long_press_speed_drag_static_test.dart`。
- **备注**：BUG 工具初分配 962，与在途 PR#301/#302 撞号（二者在各自分支占用 962，未进 develop），按撞号纪律改到 963。media_kit/libmpv 在测试宿主不可用，拖动手势与掉帧无法纯单测，故守在源码接线层 + 纯函数层；真机顺滑度需按 `docs/agent/integration-testing.md` 在真实设备复测（掉帧类问题截图难留证，PR 保持 draft 待真机验收）。
