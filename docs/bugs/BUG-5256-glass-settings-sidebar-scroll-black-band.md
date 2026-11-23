## BUG-5256 · glass-settings-sidebar-scroll-black-band
- **报告**：2026-11-21（用户：Windows，设计系统「Cupertino」= 玻璃 + 自定义壁纸，宽屏设置滚左栏，内容区顶部整宽冒出一条黑线）
- **真实性**：✅ 真 bug。离屏 itest 复现（壁纸 + 玻璃，左栏滚 120px 后顶部整宽黑带），修后同路径无黑带。两处根因叠加：
  1. 外壳 `FushiAppleScrollChrome.handleNotification`（`fushi/lib/src/utils/components/glass/fushi_apple_scroll_chrome.dart`）收任何可见竖向滚动，设置宽屏左栏（导航侧窗格）一滚就把 `contentUnderTop` 置真，`home_page.dart` `_withAppleTopEdge` 亮出整宽顶部 scroll edge 带；
  2. `FushiAppleScrollEdge` 底色取 `scaffoldBackgroundColor.withValues(alpha: 1)`，自定义壁纸下 `FushiPageBackdrop`（`fushi_page_backdrop.dart:144`）把它换成 `Colors.transparent`（RGB 黑），带成了实心黑。
- **[x] ① 已修复** — 新增 `FushiSidePaneScrollScope` 标出侧窗格、`fushiNotificationDrivesPageChrome` 过滤（页面级滚动观察全部改用它），设置主页三种宽屏版式的左栏都包上；边缘带底色改走 `fushiAppleScrollEdgeColor`（完全透明时退回 token 页面底色，半透明玻璃底照旧不透明化）。
- **[x] ② 已加自动化测试** — `fushi/test/widgets/apple_scroll_chrome_side_pane_test.dart`：侧窗格滚动不置 `contentUnderTop`、正文滚动照常、透明底色不出黑、设置主页每个 `supporting:` 都包了侧窗格标记。
- **备注**：同类侧窗格以后要接这套过滤，包一层 `FushiSidePaneScrollScope` 即可。
