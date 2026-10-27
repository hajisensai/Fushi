## BUG-3801 · web-browser-tab-strip-caption-row-and-exit
- **报告**：2026-10-27（用户：Windows 上 app 内浏览器顶部标签栏下面另起一行、标题栏那一行空着；进了浏览器找不到退出按钮）
- **真实性**：✅ 真 bug。① 自绘标题栏 `FushiDesktopTitleBar` 浮在页面上、经 MediaQuery 顶部 padding 让位 32；浏览页宽屏壳 `_buildWide`（`fushi/lib/src/pages/implementations/fushi_web_browser_page.dart`）先用 `SafeArea` 垫出这 32 的空行，再在下面画 36 高的 `WebBrowserTabStrip`，标题行除窗口按钮外整条是 `DragToMoveArea`（`fushi/lib/src/utils/components/fushi_desktop_title_bar.dart` `_buildCaptionControls`），页面也没法把控件放进去。② 工具栏只有「后退」，走 `webBrowserBackStep` 阶梯：要先退完网页历史才离开浏览页，没有直接退出的入口。
- **[x] ① 已修复** — 标题栏加所有者式「让出标题行」开关 `FushiDesktopTitleBar.setCaptionPassthrough` / `FushiTitleBarPassthroughScope`（被整页盖住 / dispose 自动撤回）与 `captionReservedInsets`（Windows/Linux 右侧窗口按钮组、macOS 左侧红绿灯留位）；接管时标题行左段与底色层不吃指针。浏览页顶部标签栏模式下（桌面自绘标题栏、非网页全屏、非收起迷你条）标签栏直接占标题行，空白处自带 `DragToMoveArea` 拖窗；标签网格打开时收回。工具栏最左加「退出浏览器」按钮，⋯ 菜单末尾同项，直接 `Navigator.pop` 回入口页。
- **[x] ② 已加自动化测试** — `fushi/test/pages/fushi_web_browser_shell_test.dart`「桌面自绘标题栏：顶部标签栏并进标题行…」（标签与关闭按钮同一行、标题行里的 + 真能点、空白处 startDragging、窗口关闭按钮可用、退出后撤回接管）与「⋯ 菜单里有「退出浏览器」…」。
- **备注**：Windows 真机像素验证未做（离屏 widget 测试覆盖布局与命中）；侧边栏样式无横向标签栏，标题行保持原样。
