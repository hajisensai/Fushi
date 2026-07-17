## BUG-873 · 手机端视频卡片过大（窄屏只出 1 列铺满整屏）
- **报告**：2026-07-18（用户：）
- **真实性**：✅ 真 bug。根因 `hibiki/lib/src/pages/implementations/home_video_page.dart:1694`（原 `unifiedShelfCardLayout(..., targetWidth: 240)` 硬编码）。手机竖屏可用宽≈380dp 时 `columns = floor((380+12)/(240+12)) = 1` → 卡片被拉满整屏宽。而书架页早已用响应式 `readerShelfGridExtentForWidth`（手机<600→150），视频页与之不一致。附带：卡高 `mainAxisExtent`/`rowHeight` 硬编码 218（只在 240 宽才对），窄卡会残留封面上下留白。
- **[x] ① 已修复** — targetWidth 改用书架同款 `readerShelfGridExtentForWidth(constraints.maxWidth)`（手机出≥2 列）；卡高改成随卡宽按 16:9 联动的 `_videoCardExtent(cardWidth) = cardWidth*9/16 + 83`（cardWidth=240 时回落到旧的 218，向后兼容），散卡网格与合集横排行共用。提交见 PR。
- **[x] ② 已加自动化测试** — `hibiki/test/utils/misc/platform_layout_test.dart` 新增 group：手机宽（≤599）+ `readerShelfGridExtentForWidth` 目标宽经 `unifiedShelfCardLayout` 必得 ≥2 列（守卫「回到硬编码 240 → 1 列」的回归）。
- **备注**：`unifiedShelfCardLayout` 被散卡网格与合集横排行成员卡共用，故两处逐像素同尺寸。
