## BUG-374 · 点视频控制按钮边缘穿透到底层 tap 误暂停/播放
- **报告**：2026-06-21（用户：点按钮边缘导致视频暂停/播放）
- **真实性**：✅ 真 bug（桌面控制条）。根因=vendored media_kit 桌面控制条把 `playOrPause()` 绑在 **`onTapDown`**（`third_party/media_kit_video/lib/media_kit_video_controls/src/controls/material_desktop.dart:674-691`），而 `onTapDown` 在指针落下进入手势竞技场时**立即触发、不等裁决谁最终赢**。点叠在画面上的控制按钮（IconButton / side rail）**边缘/内边距透明区**时，按钮 tap recognizer 与这个作为按钮栏祖先的 GestureDetector 同时进竞技场，祖先 `onTapDown` 抢先 `playOrPause()` → 既按了按钮又误触发播放/暂停。（移动端 `material.dart` 主 tap 走 `onTap`/控制条切换 + 16px 边缘内缩，无此问题。）
- **[x] ① 已修复** — 把 `playOrPause()` 执行从 `onTapDown` 移到新增的 **`onTap`**（手势竞技场裁决后、仅当本 GestureDetector 胜出才触发；按钮认领该 tap 时不触发，消除穿透）。`onTapDown` 退化为只记录该 tap 是否落在播放/暂停可触发区域（避开底部进度条，保留原 `subtitleVerticalShiftOffset`+`tapPadding` 几何）到新字段 `_playPauseTapEligible`，由 `onTap` 消费。提交：<PENDING>
- **[x] ② 已加自动化测试** — 源码守卫 `hibiki/test/pages/video_play_pause_tap_arena_guard_test.dart`（断言 `onTapDown` 块不执行 `playOrPause`、只记录 `_playPauseTapEligible`；`playOrPause` 在 `onTap` 块执行；State 持有 `_playPauseTapEligible` 字段）。真实手势竞技场时序跑不了 headless。
- **备注**：side action rail 按钮（两平台）边缘穿透同被此修复覆盖（rail 按钮是上层 Stack 的 IconButton，胜出竞技场即抑制下层 media_kit `onTap`）。需**真机复测**：点桌面顶/底栏按钮及左右 rail 按钮边缘不再误暂停。
