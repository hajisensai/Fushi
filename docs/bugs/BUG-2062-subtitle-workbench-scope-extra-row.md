## BUG-2062 · 字幕工作台作用域开关独占一行：挂在 AppBar.bottom 上，标题行右半边全空
- **报告**：2026-09-03（用户：截图 QQ_1788367188399.png，「本集和整个合集应该和字幕标题同行才对。中间空了好多」）
- **真实性**：✅ 真 bug。`fushi/lib/src/pages/implementations/subtitle_workbench_page.dart:233`
  把「本集 / 整个合集」`SegmentedButton` 塞进 `AppBar.bottom` 的 `PreferredSize(Size.fromHeight(56))`，
  于是标题行右侧整条空着、开关自己又占满一行，标题与面板之间凭空多一截留白。
  实测（1400x900 宿主）：标题与开关的垂直中心差 **52px**。
- **[x] ① 已修复** — 开关移进 `AppBar.actions`（`Padding` + `Center`，避免 actions 的
  `CrossAxisAlignment.stretch` 把它拉到 toolbar 满高），`bottom` 去掉。
- **[x] ② 已加自动化测试** — `fushi/test/pages/subtitle_workbench_page_test.dart`
  「作用域开关与标题同一行：不再挂 AppBar.bottom 多占一行」：断言 `AppBar.bottom == null`
  **且**标题与开关垂直中心差 < 8px。后一条是实质判据——挂 bottom 时两者也都在 AppBar 里，
  只按「在不在 AppBar 里」判会恒真。变异实测：退回 bottom → `bottom` 断言红；
  单独屏蔽它后 dy 断言实测 52.0，同样红。
- **备注**：无。
