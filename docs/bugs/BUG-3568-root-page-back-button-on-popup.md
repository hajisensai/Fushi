## BUG-3568 · 根页打开弹出菜单 / 对话框后重建会凭空长出返回键（浏览器页点「⋯」左上角出现返回）
- **报告**：2026-10-19（用户：截图「点击三个点左上角会出现返回按钮，之前为什么没有？」）
- **真实性**：✅ 真 bug。脚手架默认返回键问的是整个导航栈 `Navigator.canPop()`（旧 `fushi/lib/src/utils/components/fushi_material_components.dart:5267` `FushiPageScaffold._defaultLeading`、`:5465` `FushiToolScaffold._defaultLeading`、`fushi/lib/src/utils/components/glass/fushi_glass_bars.dart:1415` `FushiRouteBackButton`）。首页外壳里的 tab 是根路由，平时为 false；「⋯」弹出菜单（PopupRoute）压栈后只要根页重建一次，`canPop()` 就是 true，返回键凭空出现。点它 `maybePop` 弹掉的是菜单，不是页面。
- **[x] ① 已修复** — `740c612c11`：新增 `fushiRouteImpliesBack`（`fushi_glass_bars.dart`），看本页路由的 `ModalRoute.impliesAppBarDismissal`（与 `AppBar` 同一判据），三处默认返回键统一走它。
- **[x] ② 已加自动化测试** — `fushi/test/pages/fushi_web_browser_page_redesign_test.dart`「根页在弹出路由（菜单 / 对话框）打开期间重建，不长出返回键」+「推出来的页照常有返回键」；变异实测：判据改回 `Navigator.canPop()` 即红（找到 1 个返回键）。
- **备注**：全局修复，所有用 `FushiPageScaffold` / `FushiToolScaffold` 默认返回键的根页都受益。
