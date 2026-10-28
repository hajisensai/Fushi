## BUG-3870 · reader-floating-leading-overflow
- **报告**：2026-10-28（用户：群反馈，手机竖屏 M3E 阅读器右上角「⋯」点不到）
- **真实性**：✅ 真 bug。左上角槽位的按钮全部画成 `FushiFloatingTopBar.leading` 独立圆钮，而前置圆钮不参与 `adaptiveOverflow` 收纳（`fushi/lib/src/utils/components/fushi_floating_toolbar.dart` build 里 leading 循环恒画全部）；布局把模式 / 目录 / 图库 / 统计放进 topLeft 后，五颗圆钮 + ⋯ 超出 393dp 宽，⋯ 被挤出右边缘。
- **[x] ① 已修复** — 新增纯函数 `fushiTopBarLeadingFitCount`：前置圆钮放不下时从末尾起收进「⋯」（返回恒在），动作预算按「⋯ 恒占一格」重算。所有用 `FushiFloatingTopBar` 的页面一起受益。
- **[x] ② 已加自动化测试** — `fushi/test/widgets/fushi_floating_top_bar_adaptive_overflow_test.dart`（369 宽五颗前置钮：不溢出、⋯ 落在顶栏内、收起的钮进 ⋯ 菜单）。
- **备注**：未在真机复测。
