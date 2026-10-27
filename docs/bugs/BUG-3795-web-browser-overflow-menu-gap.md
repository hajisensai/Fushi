## BUG-3795 · web-browser-overflow-menu-gap
- **报告**：2026-10-26（用户：浏览器「⋯」菜单和上面按钮之间有很大空隙（截图））
- **真实性**：✅ 真 bug。`showWebBrowserMenu`（`fushi/lib/src/pages/implementations/web_browser/web_browser_menus.dart:115`）把锚点矩形整体下移了一个按钮高，而 `showFushiMenu` 的布局（`_RenderFushiMenuLayout`）本来就把菜单排在锚点下沿之下，空出一整个按钮高。
- **[x] ① 已修复** — 锚点改为按钮自身矩形。（分支 `claude/webpage-loading-ui-issues-bd26d2`）
- **[x] ② 已加自动化测试** — `fushi/test/web_browser/web_page_underlay_and_menu_test.dart`「「⋯」菜单紧贴按钮下沿」。
- **备注**：
