## BUG-3569 · 查词页（MD3 手机）顶部仍有一整行「查词」大标题
- **报告**：2026-10-19（用户：截图「顶部标题怎么还有？」）
- **真实性**：✅ 真 bug。2026-10-18 的 `ae55190552` 只删了查词页**自己**的页头（那行早就只剩一枚清空按钮——标题由外壳画，页头见到同名外壳标题就不重复画）；外壳 `FushiShellLargeTitleBar` 的标题来自 `fushi/lib/src/pages/implementations/home_page.dart:1731` `_shellTitleFor`，MD3 窄窗下仍给查词 tab 返回「查词」，于是标题行原样留着。库页（叠放浮动工具区的 tab）在窄窗本来就不画这行，查词是唯一漏网。
- **[x] ① 已修复** — `740c612c11`：`_shellTitleFor` 在 MD3 窄窗、非浮动工具区 tab 上返回 null（模块名已在底部导航上）；Apple 保留 iOS 根页大标题（搜索中照常折叠）。`64c782849e` 把判据抽成纯函数 `homeShellTitleFor`。
- **[x] ② 已加自动化测试** — `fushi/test/pages/home_shell_title_compact_test.dart`（`64c782849e`）：MD3 窄窗查词无外壳标题、宽窗 / Apple 照常有、库页标题名不受影响；变异实测：去掉窄窗判据即红。
- **备注**：未在真机复测（真机验证本轮不做）。
