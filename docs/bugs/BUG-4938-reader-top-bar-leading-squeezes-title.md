## BUG-4938 · 小说阅读器顶部悬浮栏书名胶囊被左上角前置圆钮挤没
- **报告**：2026-11-16（用户：应用内反馈 B7sPaMIlzD「顶部的导航被挤没了」，Android 363dp 竖屏，截图里返回 / 音乐 / 目录 / 图库 / 统计五颗圆钮排开后书名胶囊只剩约 30dp 空壳）
- **真实性**：✅ 真 bug。
  - 根因：`fushi/lib/src/utils/components/fushi_floating_toolbar.dart:1358`（修前行号）`fushiTopBarLeadingFitCount` 判断前置圆钮能平铺几颗时只给「⋯」预留一格（`:1366`），没扣标题胶囊保底宽 `kFushiFloatingTopBarTitleMinWidth`（`:1177`）。`fushiTopBarActionsBudget` 只保护右侧动作组，而阅读器把 `ReaderControlSlot.topLeft` 槽位的按钮全放进 `leading`（`fushi/lib/src/pages/implementations/reader_fushi/chrome.part.dart:3495`），于是五颗钮里平铺了四颗，标题胶囊的 `Expanded` 只剩几十 dp。
- **[x] ① 已修复** — `fushiTopBarLeadingFitCount` 增加 `hasTitle` / `titleWidth` / `subtitleWidth` / `titleFirst`，与 `fushiTopBarActionsBudget` 共用 `_topBarTitleReserve` 同一口径扣标题预留宽（短标题只扣自然宽，长标题扣 160 保底）；放不下的前置钮照旧从末尾收进「⋯」、返回恒在。`FushiFloatingTopBar.build` 把同一份 `_titleWidths` 测量结果同时喂给前置钮测宽与动作预算。提交见本文件 Git 历史。
- **[x] ② 已增加自动化测试** — `fushi/test/widgets/fushi_floating_top_bar_adaptive_overflow_test.dart`：纯函数测试（363dp、五颗前置钮、有标题时平铺数 + 标题保底 + ⋯ 不超宽；无标题 / 短标题时能多平铺）与 widget 测试（363dp 五颗前置钮 + 长书名：不溢出、返回在、末颗收进 ⋯、标题胶囊宽 ≥ 160）。
- **备注**：布局类修复，未在真机复测原始路径（按维护者「真机验证取消」口径记缺口）。
