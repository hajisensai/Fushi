## BUG-2396 · 统计中心时段汇总卡在手机上只显示一列
- **报告**：2026-09-10（用户：手机统计中心「今日 / 本周 / 本月 / 全部」只显示一列，希望自适应显示两列）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/pages/implementations/stat_shared.dart:254`（修前）——
  `buildStatPeriodSummaryGrid` 用 `constraints.maxWidth >= 380` 判两列，但 `LayoutBuilder`
  外面就套着 `EdgeInsets.all(tokens.spacing.card)`（20dp），到 `maxWidth` 时左右各已扣掉 20dp：
  360dp 手机只剩 320dp、412dp 大屏手机只剩 372dp，**阈值结构上高于任何手机宽度**，
  两列分支在手机端永远走不到（`statistics_center_page.dart` 的 `ListView` 无额外横向内边距；
  reading / video / game 三个统计页共用同一 helper，症状一致）。
- **[x] ① 已修复** — 判据从「屏幕宽度阈值」改成「实际算出的列宽」：抽纯函数
  `resolveStatPeriodSummaryLayout`，先按 wideGap(12) 试两列，差几 dp 时改 compactGap(8) 再试，
  列宽 ≥ `kStatPeriodSummaryMinColumnWidth`(144) 就排两列，否则退单列；列宽 <
  `kStatPeriodSummaryCompactColumnWidth`(200) 时卡片内边距由 20dp 收到 16dp，避免手机两列下
  主值被 `FittedBox` 压到读不出来。360 / 375 / 412dp 手机现在都是 2×2，320dp 小屏机仍单列。
- **[x] ② 已加自动化测试** — `fushi/test/pages/stat_period_summary_grid_columns_test.dart`：
  纯函数层钉住 320 / 335 / 372dp 判两列、280dp 退单列、紧凑间距救窄带、无界宽度退单列，
  以及「两列宽度和 + 间距永不超出可用宽度」的扫宽不变式；widget 层在 360×800 真实渲染四张卡，
  按 `getTopLeft` 断言 2 列 × 2 行。另在 360dp × dpr3 下渲染真实像素人工复核过四个值均完整可读
  （含最长的「1234 小时 56 分钟」）。
- **备注**：`FushiSpacingTokens.card = 20 / gap = 8 / rowHorizontal = 16`。380..412dp 这一窄带
  （小平板分屏）此前是两列 + 20dp 内边距，现在改为两列 + 16dp 内边距，属阈值统一的附带变化。
