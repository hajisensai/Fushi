## BUG-4323 · 内置浏览器旋转屏幕网页重载、YouTube 播放中断（iOS）
- **报告**：2026-11-09（开发者应用内反馈 kd7syQrdFd，iOS iPhone18,3）
- **真实性**：✅ 真 bug，沿代码路径确认。`fushi/lib/src/pages/implementations/fushi_web_browser_page.dart` `build` 按窗口尺寸在 `_buildNarrow`（竖屏底栏壳：`Column > Expanded(key) > _buildTabs`）和 `_buildWide`（顶栏 / 侧边栏壳：`Column > Expanded > Row > Expanded > Stack > _buildTabs`）两棵结构不同的树之间切换（旧 `:2593-2594`）。手机旋转跨过布局门槛时标签页的父链改变，`WebBrowserTabView`（`:2105`，只有 `ValueKey(tab.id)`）的 State 被销毁重建，里面的 `_webViewKey`（`web_browser_tab_view.dart:106`）随之换新，InAppWebView 重建、网页重载。键盘开合已按「树形恒定」修过（`_avoidKeyboard`），旋转没有。
- **[x] ① 已修复** — 窄 / 宽两种壳收成同一棵树 `_buildShell`：网页区固定是带 key 的 `Expanded('web-browser-content') > Row > [推挤侧边栏, Expanded > Stack > KeyedSubtree('web-browser-tabs') > _buildTabs, 抽屉…]`；窄形态下推挤侧边栏宽度恒为 0、不建内容，抽屉只在宽侧边栏形态出现且排在标签页之后；只有网页区上下的 chrome（`_narrowTopChrome` / `_narrowBottomChrome` / `_wideTopChrome`）随形态增删。没有用 GlobalKey 搬家。
- **[x] ② 已加自动化测试** — `fushi/test/pages/fushi_web_browser_shell_test.dart`「旋转（窄 ↔ 宽 …）不重建标签页 State」：标签页换成有状态桩，390×844 → 844×390（手机横屏抽屉）/ 1280×800（推挤侧边栏）→ 390×844，断言桩的 State 始终是同一个实例。
- **备注**：iOS 真机 / 模拟器旋转复测未做（本批次不做真机验证）；待补：iOS 打开 YouTube 播放中旋转，确认不重载、播放不中断。
