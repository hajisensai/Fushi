## BUG-3837 · 进度条悬停缩略图被字幕挡住
- **报告**：2026-10-27（用户：应用内反馈 KKxMNpG99t，Windows 3.0.1-debug.21088，附截图）
- **真实性**：✅ 真 bug（沿代码路径确认）。视频控件 Stack 的子节点顺序即绘制层级：`fushi/lib/src/pages/implementations/video_fushi/layout.part.dart:582`（修前）先挂 `_buildThumbnailPreviewOverlay(controller)`，`:599` 弹幕、`:617` `VideoSubtitleOverlay`、其后图形字幕遮蔽 / OCR 层都排在它后面，于是画在缩略图之上；控制条可见时字幕又恰好被抬到进度条上方，正好压住 hover 预览。
- **[x] ① 已修复** — 缩略图层挪到弹幕 / 文本字幕 / 图形字幕遮蔽 / 图形字幕 OCR 与其进度卡之后、OSD 之前（`layout.part.dart`）。该层是 `IgnorePointer`，挪层不改任何命中；OSD / 制卡角标 / 长按徽章等仍在其上。
- **[x] ② 已加自动化测试** — `fushi/test/pages/video_thumbnail_preview_z_order_guard_test.dart`（源码层序守卫：整页在 headless 下起不来，层序只能在源码钉）。变异：把缩略图层挪回章节刻度层之后 → 红，还原后绿。
- **备注**：未在 Windows 真机目测截图复现路径。
