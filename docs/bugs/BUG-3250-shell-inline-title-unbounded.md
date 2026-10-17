## BUG-3250 · 库页宽窗标题胶囊不限宽长页面名挤压页签
- **报告**：2026-10-10（PR #2056 审查遗留疑点）
- **真实性**：✅ 真 bug。`FushiFloatingChromeBar` 在 `FushiShellInlineTitle` 生效（宽窗 ≥600 的库页 / 浏览）时把外壳页面名画成标题胶囊，作为 Row 的非弹性子项直接放入（`fushi/lib/src/utils/components/fushi_floating_chrome.dart:1410`）。Row 给非弹性子项无界主轴约束，长页面名按自然宽排开，页签胶囊（`Expanded`）被挤到 0，整行溢出（720 宽 + 长名实测溢出 920px）。
- **[x] ① 已修复** — 标题胶囊外包 `ConstrainedBox(maxWidth: 行宽 / 3)`，超长名在胶囊里省略号截断（胶囊本就 maxLines 1 + ellipsis），页签保有剩余宽度；返回键前导不受影响。提交 fix(ui): cap the inline shell title pill so long page names cannot squeeze the tabs
- **[x] ② 已加自动化测试** — `fushi/test/widgets/fushi_shell_inline_title_width_bug3250_test.dart`（修复前 RenderFlex overflow 红）。
- **备注**：
