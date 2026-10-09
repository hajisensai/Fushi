## BUG-3018 · 桌面 smoke 把侧栏菜单图标算成首个导航目的地
- **报告**：2026-10-06（PR #1984 Windows/macOS appSmoke）
- **真实性**：✅ 真测试驱动回归。`fushi/integration_test/test_helpers.dart` 的 `_navigationIconsInside` 枚举全部 Icon，M3E rail 新增菜单/品牌图标后 `navTargets[1]` 指向首页，Enter 后当然仍为 HomeTab.home。Windows CI 37457975011 的实际断言证实此路径。
- **[x] ① 修复** — 自绘导航以编号目的地 FushiFocusTarget 标识枚举，排除菜单/品牌/更多入口；stock 平台导航保留原分支。smoke 强制验证首页就绪与两个目的地，禁止静默跳过。
- **[x] ② 增加自动化测试** — `fushi/test/integration/navigation_helpers_test.dart` 对 Windows/macOS 的真实自绘 rail，经 Tab/Enter 验证第二项切页、第一项切回且不触发菜单。执行结果待补。
- **备注**：需回补集成分支。原始桌面集成 smoke 复验待完成，不以 helper 修订推断生产导航已无回归。
