## BUG-3064 · 移动端查词页往下滑底部栏不收起
- **报告**：2026-10-07（用户：「移动端查词页往下滑底部栏不会收起来」）
- **真实性**：✅ 真 bug，两层根因叠在一起：
  1. **底栏自己拒收**：MD3 悬浮底栏把「查词」拆成胶囊右侧的 FAB，`fushi/lib/src/utils/adaptive/adaptive_navigation.dart:573`（旧）写死「FAB 那一项（查词）选中时不收起：收起胶囊只装得下胶囊里的当前项」——只要当前页是查词，`glassMinimized` 再怎么为真底栏都不动，查词历史列表（Flutter `ListView`）滑也不收。
  2. **结果区收不到滚动**：底栏收起由外壳 `fushi/lib/src/pages/implementations/home_page.dart:1435` 的 `NotificationListener` 把 Flutter `ScrollNotification` 喂给 `FushiAppleScrollChrome`（`fushi/lib/src/utils/components/glass/fushi_apple_scroll_chrome.dart:158`，内部 `GlassTabBarMinimizeController`）驱动；查词结果卡整块是 `DictionaryPopupWebView`（`fushi/lib/src/pages/implementations/home_dictionary_page.dart:1815`），正文在 WebView 文档里原生滚动，Flutter 树收不到任何滚动通知，状态机（以及外壳大标题收起）从未被喂到。
  真机 HiBreak（824x1648）复测：只修第 2 层时外壳大标题已随滑动收起（证明通知到了），底栏仍不动——即第 1 层。
- **[x] ① 已修复** —
  - 第 1 层：FAB 是当前项时照常收起，收起 = 整条胶囊（连同底色 / 投影）淡出让位、不吃指针 / 不进焦点与语义，FAB 留下（M3E 浮动工具栏滚走、FAB 保留）；回滚或焦点进入照旧展开。胶囊里的目的地为当前项时行为不变（留小胶囊）。新组件 `_NavCapsuleVanish`。
  - 第 2 层：新增 `fushi/lib/src/utils/misc/webview_scroll_notification_bridge.dart`：注入脚本每帧最多报一次文档纵向滚动（`popupHostScroll`：位置 / 可滚范围 / 视口 / 是否用户输入后），`WebViewScrollNotificationBridge` 按 Flutter Scrollable 的形状派发 `UserScrollNotification`（方向变化时）+ `ScrollUpdateNotification`，从 WebView 所在位置冒泡给外壳——与库页 ListView 同一台状态机、同一组阈值，不另造判据。「用户滚动」由 JS 在 touchstart / wheel / pointerdown / keydown 后置位、宿主整页重渲染（换词归零 / 恢复滚动位）前清位，程序滚动按 idle 派发不会收起底栏。`DictionaryPopupWebView.forwardScrollToHost` 开关，只有首页查词结果卡打开。
  - 提交：第 2 层 `f799264f25d`，第 1 层见本文件同一提交之后的 `fix(nav)` 提交。
- **[x] ② 已加自动化测试** —
  - `fushi/test/widgets/adaptive_nav_fab_current_minimize_test.dart`：FAB 当前项 + 收起时胶囊目的地不可命中、淡到 0、FAB 仍可点；回滚展开；胶囊目的地当前项时仍留小胶囊。
  - `fushi/test/widgets/webview_scroll_notification_bridge_test.dart`：真实 `FushiAppleScrollChrome` + 外壳同款 `NotificationListener` 下用户下滑收起 / 上滑展开 / 程序滚动不收起 / 回顶展开、通知形状，`fromJs` 解析，首页结果 WebView 打开转发、WebView 注册 handler 并注入脚本的接线守卫。
- **备注**：注入脚本只认文档本身的滚动，内层横滚表格不参与；嵌套查词弹窗（根 Overlay）不转发。Apple 玻璃底栏（`adaptive_navigation.dart:416`「搜索项选中时不收起」）未改：iOS 26 的搜索 tab 本身就是展开搜索栏的形态，且 Apple 设计系统是隐藏内部能力，留待按需处理。
