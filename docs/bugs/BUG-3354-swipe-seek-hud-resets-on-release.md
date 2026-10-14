## BUG-3354 · 横滑跳转松手瞬间 HUD 显示回滑动起始进度
- **报告**：2026-10-14（反馈 #J1NJL1a75F，Android 扩展在线播放，三张截图：起手帧 / 滑动结束帧 / 松手帧显示「15:19 +0:00」；实际 seek 落点正确）
- **真实性**：✅ 真 bug。`third_party/media_kit_video/lib/media_kit_video_controls/src/controls/material.dart:1001-1025`（修复前）——`onHorizontalDragEnd` 提交 seek 后在同一个 setState 里把 `swipeDuration` 清零（BUG-1485 需要：防退化拖动重放上次增量），而 seek 指示器（:1665 一带）套在 `AnimatedOpacity` 里淡出、淡出期间仍随重建读 `swipeDuration`，于是整个淡出过程显示「基准 + 0:00」= 滑动起始位置。与平台 / 片源无关，本地视频同样会出现。
- **[x] ① 已修复** — fork 新增显示状态 `_swipeIndicatorDuration`：拖动更新时与 `swipeDuration` 一起写，松手不清；指示器（宿主 builder 与内建兜底文字）只读它。提交路径仍读、仍清 `swipeDuration`。PATCHES.md 已登记。
- **[x] ② 已加自动化测试** — `fushi/test/pages/video_swipe_seek_hud_release_test.dart`（真实 vendored 移动控制条 + 触屏横滑：松手后淡出首帧 HUD 仍显示目标；已做变异实测，还原旧读法即红）。
- **备注**：桌面触屏层 `touch_swipe_gesture_layer.dart` 松手即从树上移除 HUD、不淡出，不受影响。
