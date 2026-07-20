## BUG-877 · 字幕列表面板大小不可自定义
- **报告**：2026-07-18（用户：看 2 分钟动漫默认设置反馈，第 1 点）
- **真实性**：✅ 真 bug。面板宽度写死 `screenWidth*0.28` 钳制 `[240,420]`（`hibiki/lib/src/pages/implementations/video_hibiki/subtitle.part.dart` 原 `_subtitleJumpSidePanel`），无滚轮 / 拖拽 / 持久化；用户要求像 asbplayer 一样可调。
- **[x] ① 已修复** — 新增持久化字段 `videoSubtitleListWidth`（`preferences_repository.dart` + `app_model.dart`，0=跟随自适应）；`_subtitleJumpSidePanel` 读持久化宽度（未自定义按屏宽自适应，clamp 到 `[240, min(屏宽*0.6,720)]`）；面板叠一层左边缘拖拽把手 `_subtitleListResizeHandle`（`subtitle.part.dart`）——拖动改宽（面板在右、左边缘向左拖变宽 `base-delta.dx`）、松手落盘、双击复位为自适应（存 0）。裸滚轮仍滚列表（缩放走 Ctrl+滚轮，见 BUG-878）。
- **[x] ② 已加自动化测试** — `hibiki/test/pages/video_subtitle_list_zoom_lookup_wiring_guard_test.dart`（BUG-877 组：面板宽度读 `appModel.videoSubtitleListWidth`、存在 `_subtitleListResizeHandle`、拖拽经 `setVideoSubtitleListWidth` 落盘）。
- **备注**：与 BUG-878 同一 PR。修复提交 `96763ac23`。拖拽把手 UI 需真机 / 离屏目视验收手感。
