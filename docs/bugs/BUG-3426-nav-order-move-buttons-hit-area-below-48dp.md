## BUG-3426 · nav-order-move-buttons-hit-area-below-48dp
- **报告**：2026-10-15（用户：#2198 审查后续）
- **真实性**：✅ 真 bug。`fushi/lib/src/settings/nav_module_order_list.dart:151-153,186-202`（修前）底栏排序的上移 / 下移 `FushiIconButton` 用 18 号图标 + `gap / 2` 的自定义 padding，实测命中区 26×26dp，低于 48dp。
- **[x] ① 已修复** — 去掉自定义 padding，改走 `isWideTapArea: true`（MD3 为 Material IconButton 48dp 命中区；Apple 按 HIG 桌面 36 / 移动 44）。提交：待提交
- **[x] ② 已加自动化测试** — `fushi/test/settings/nav_module_order_list_test.dart`「上移 / 下移按钮命中区不小于 48dp」（修前实测 26.0 红，修后绿）。
- **备注**：
