## BUG-411 · 选集列表两位数序号大字号下换行被裁(leading固定宽24不随字号)
- **报告**：2026-06-23（用户：）
- **真实性**：✅ 真 bug — 根因 `hibiki/lib/src/media/video/video_episode_panel.dart:186-201`（修复前）
- **[x] ① 已修复** — `hibiki/lib/src/media/video/video_episode_panel.dart`（commit fed72eab9）
- **[x] ② 已加自动化测试** — `hibiki/test/media/video/video_episode_panel_test.dart`「two-digit episode numbers stay single-line and visible at large font (TODO-759)」（commit fed72eab9）
- **备注**：
  - **根因**：选集列表（`VideoEpisodePanel._buildList`）非当前集的序号 `leading` 用 `SizedBox(width: 24)` 固定宽装 `Text('${i+1}')`，宽度不随字号缩放。字号 `fontSize = 14 * _videoUiScale`，`_videoUiScale = appModel.appUiScale`（`app_ui_scale.dart` 范围 0.3–3.0，最大 42px）。界面调大后两位数序号（10 起，tabular figures 等宽，约字号×1.2）实际宽度超 24px → `Text` 默认 `softWrap:true` 把数字断成两行 → dense `ListTile` 行高按 title 决定、不随 leading 抬高 → 第二行/数字被纵向裁切看不见。
  - **修复**（改约束，对齐已修先例 TODO-567 `video_subtitle_jump_panel.dart` 的时间戳列范式）：① leading 列宽 `24` 改为随字号缩放 `math.max(24.0, widget.fontSize + 12)`（下界 24 保证窄字号像素不变、向后兼容）；② 序号 `Text` 加 `maxLines: 1, softWrap: false`（序号本就该单行，永不溢出/被裁）。只动 episode 一处；章节列表 `video_chapter_panel.dart` 用裸 `Text` 无固定宽不复现，未动。
  - **测试**：大字号（fontSize=42 / appUiScale=3.0）下 pump `VideoEpisodePanel` 喂 12 集，scrollUntilVisible 到两位数序号「10」，断言其 `maxLines==1` / `softWrap==false` / 渲染高度 < 字号×1.6（未换两行）/ leading `SizedBox` 宽度 ≥ 字号+12。原有 `find.text('1')/'3'` 单行序号断言仍绿。
