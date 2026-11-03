## BUG-3993 · media-server-header-under-status-bar
- **报告**：2026-11-02（用户：手机截图，进入媒体服务器后顶部页头顶到状态栏）
- **真实性**：✅ 真 bug。2026-10-30 起「进服务器」改为根 Navigator 上的二级页（`fushi/lib/src/pages/implementations/media_server/media_server_server_list_view.dart` `_openServer`），首页 / 网格 / 搜索不再处于库页外壳之下；外壳所在的首页 `SafeArea`（`home_page.dart`）原本替它吃掉顶部安全区，而 `MediaServerPageFrame`（`media_server_widgets.dart` build）独立使用时把悬浮页头直接叠在 y=0，没让开状态栏 / 刘海。
- **[x] ① 已修复** — `MediaServerPageFrame` 的页头套 `SafeArea(bottom: false)`：在外壳里 padding 已清零是 no-op；独立路由时页头下移，实测高度含状态栏，正文让位 `FushiFloatingChromeInset` 随之加上，收起时整段一起滑出。Material 与 Apple 两条分支都接。
- **[x] ② 已加自动化测试** — `fushi/test/pages/media_server/media_server_home_view_test.dart`「BUG-3993」：view padding top=47 时页头搜索钮顶边 ≥ 47、「媒体库」标题在页头下方；撤掉修复时红（顶边 6.86）。
- **备注**：未上 iOS 真机复测，凭 widget 测试几何断言；详情页（`media_server_detail_view.dart`）自己按 `padding.top + chromeInset` 让位，不受影响。
