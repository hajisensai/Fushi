## BUG-4850 · 没有自绘标题栏的平台进设置，正文连同全部保活 tab 被整棵卸载
- **报告**：2026-11-16（用户：转来群反馈录屏「切 tab 变卡了」；修完 BUG-4851 / BUG-4896 后列出的剩余项「Linux、横屏安卓平板进设置走全屏分支，整个正文连同全部保活页被卸载」，用户回「都做都做，能优化就优化」）
- **真实性**：✅ 真 bug（沿代码路径确认 + 组件测试复现；手头没有 Linux / 横屏安卓平板的测速环境，未量耗时）。
  - 根因：`fushi/lib/src/pages/implementations/home_page.dart:2043-2062`（修前行号）`_buildDesktopLayout` 在 `_visibleTab == HomeTab.settings && !FushiDesktopTitleBar.isEnabled` 时返回一个只装设置页的 `Scaffold`，不再包含 `_homeContentPane()`。带 `_homeBodyKey` 的正文不在新树里，于是整棵卸载：全部保活 tab 的 State、滚动位置、远端列表、预热的 WebView 一起销毁；从设置回来每个 tab 都是冷启动。保活机制（`Offstage` 藏着）在这条分支上等于没有。Windows / macOS 有自绘标题栏，不走这条分支。
- **[x] ① 已修复** — 全屏设置分支只摘侧栏：`Scaffold` 的 body 换成 `SafeArea(child: _homeContentPane())`，正文（带 `_homeBodyKey`）留在树上，设置页作为正文里的当前 tab 渲染，其余保活页照常 `Offstage`。返回箭头是否显示由 `_settingsFullscreen` 决定（三种布局各自置位）。提交见 PR #3534。
- **[x] ② 已加自动化测试** — `fushi/test/pages/home_hidden_tab_select_behavior_test.dart`「全屏设置只摘侧栏：藏着的保活 tab 不被卸载，返回箭头切回来源 tab」：挂真 `HomePage`（测试环境没有自绘标题栏，正是这条分支），进设置后侧栏消失、设置页带返回箭头、藏着的查词页仍挂载，返回后是同一个 State。
- **备注**：行为变化：这些平台上全屏设置页底部现在也有迷你播放条 / 后台任务浮钮（与 Windows / macOS 的设置页一致），此前全屏分支里没有。
- **被 PR #3676 取代（2026-11-18）**：#3676 让设置全平台同壳（主导航 rail 常驻 + 二栏 list-detail），`_buildDesktopLayout` 里「摘掉侧栏的全屏设置」分支连同 `_settingsFullscreen` / 设置页头返回箭头整段删除，本条的修法随之不再存在；根因（进设置时正文离树）在新结构里已不可能发生。原测试改为守「宽窗进设置侧栏常驻、藏着的保活 tab 不被卸载、返回后是同一个 State」这条不变式（同文件同位置）。
