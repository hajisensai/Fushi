## BUG-733 · 手机统计页文字被省略号裁切显示不全
- **报告**：2026-07-11（用户：手机上统计页「有好多显示不全的字」）
- **真实性**：✅ 真 bug。根因在统计页的小格子把 `Text` 钉死 `maxLines: 1` + `TextOverflow.ellipsis`：
  - `reading_statistics_page.dart` `_miniStat`（原 886/896 行，速度/连击/收藏三宫格，每格约 1/3 卡片宽）
  - `reading_statistics_page.dart` `_summaryTile`（原 967/977 行，速度摘要半宽六宫格；其中 `_extremeTile` 还塞进「速度 · 日期」复合值，半宽单行必被裁）
  - `reading_statistics_page.dart` 按书标题（原 1264 行）与 `video_statistics_page.dart` 视频标题（462 行）
  手机窄屏下这些格子放不下中文标签/复合数值，单行被省略号截断 → 「显示不全的字」。
- **[x] ① 已修复** — commit 见下。去掉 `maxLines: 1` 特例，让文字自然换行：把 `_miniStat` / `_summaryTile` 提取为可测试的公有 widget `StatMiniTile` / `StatSummaryTile`，数值与标签改 `maxLines: 2` + `softWrap: true`（`ellipsis` 仅作极端长文案兜底）；两处标题 `maxLines` 1→2。改动文件：`reading_statistics_page.dart` / `video_statistics_page.dart`。
- **[x] ② 已加自动化测试** — `hibiki/test/pages/reading_statistics_text_clip_test.dart`：在窄约束下渲染真实生产 widget，量出单行基线高度后再在「逼出恰好 2 行」的宽度渲染，断言 `didExceedMaxLines == false`（完整可读）且高度高于单行（确实换行）。反向对照：临时把 `maxLines` 改回 1，两条用例均变红，证明守卫有效。
- **备注**：本次只放开换行，未改列数/断点。若后续用户仍嫌三宫格/半宽格拥挤，可再做窄屏自适应列数（phase 2）。`_summaryStatPanel` 计数行本就无 `maxLines`（软换行，只挤不裁），非本 bug 范围。
