## BUG-4861 · home-recent-cell-shadow-clipped
- **报告**：2026-11-16（用户截图，手机首页小组件网格「最近添加」格：色块外观的半高封面色块投影被齐格子边切成直角矩形，左上角与右缘能看到一条直边）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/pages/implementations/home_dashboard_widget_cells.part.dart:1055`（修复前行号）：`_recentBlocks` 把半高色块的 `Wrap` 包在 `ClipRect` 里，色块（`fushiCoverBlockShadows`）与封面卡的投影伸出块外，被这层矩形裁切切平。同一套半高块在「继续」（`_continueBlockSide`）里是裸 `Wrap`、无裁切，所以其它格子正常。
- **[x] ① 已修复** — 去掉 `ClipRect`：块数按行列算好（`count ≤ rows × cols`、块宽高恰好铺满，`RenderWrap` 换行判定带 `precisionErrorTolerance`），本就不会溢出，不需要裁切；投影伸进格间距，与「继续」同口径。（未提交，按委托不 commit）
- **[x] ② 已加自动化测试** — `fushi/test/pages/home_dashboard_page_test.dart`「色块「最近添加」：半高色块到格子之间没有裁切层……（BUG-4861）」：拼贴外观、宽网格，逐个 `home-recent-block/<i>` 沿渲染树上溯到「最近添加」格子，断言其间没有 `RenderClipRect` / `RenderClipRRect` / `RenderClipPath`。
- **备注**：设备肉眼复测待补。
