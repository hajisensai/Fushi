## BUG-3570 · 浏览器嵌在模块页里：主导航底栏与「阅读本章」FAB 叠在网页上互相遮挡，顶部还有「浏览器」标题
- **报告**：2026-10-19（用户：截图「阅读在底栏右下角被挡住了」「设计的太烂了，给我重新设计！记得符合 m3e 和苹果风格。这个页面应该是独立的子页面之类的吧，底栏不应该再继续原样显示了」）
- **真实性**：✅ 真 bug。`fushi/lib/src/pages/implementations/web_hub_page.dart:96` 把带 WebView 的 `FushiWebBrowserPage` 直接当模块 tab 内容；页面在首页外壳里，悬浮主导航底栏 + 外壳的悬浮搜索钮压在页面右下，页面自己的扩展 FAB（旧 `fushi_web_browser_page.dart:807`）落在同一位置被盖住。手机上本模块只有这一个子页，`navigation == null` 时脚手架又画了「浏览器」标题胶囊，顶部共三行 chrome（标题 / 地址栏 / 动作行）。
- **[x] ① 已修复** — `740c612c11`：模块页改为入口 `FushiWebBrowserHomePage`（地址栏 + 站点网格，MD3 单子页不画标题，Apple 保留大标题）；打开任何地址经 `openFushiWebBrowser` 推全屏 `FushiWebBrowserPage`，盖住主导航：顶部一行地址栏（✕ 退出 / 刷新），底部居中悬浮工具栏（纯图标、单组无分隔、宽度不够按优先级收进「⋯」，测宽复用 `FushiTopBarOverflowFit`）+「阅读本章」`FushiToolbarFab`，整条落在网页下方不叠网页。系统返回先退网页历史。
- **[x] ② 已加自动化测试** — `fushi/test/pages/fushi_web_browser_page_redesign_test.dart`：入口页不画标题、点站点推全屏浏览页、360 宽下工具栏在窗口内且不压网页、✕ 回入口页。
- **备注**：未在真机复测（真机验证本轮不做）；FAB 只在 WebView 控制器就绪后出现，widget 测试里用的是 WebView 替身，FAB 与工具栏同排的宽度只由测宽预算覆盖。
