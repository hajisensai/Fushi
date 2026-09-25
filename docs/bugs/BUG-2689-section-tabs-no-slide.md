## BUG-2689 · 库页顶部导航切分区时指示条没有滑动动画
- **报告**：2026-09-26（用户：「视频顶部只有首页、系列、全部视频这几个导航栏下面那个条有动画，其他都没有，而且无论是小说漫画游戏导航栏都没动画」）
- **真实性**：✅ 真 bug，两种结构两个根因：
  - 视频 / 书 / 漫画壳（`video_library_shell.dart` `_navigationFor`、`media_library_shell.dart` builder 里 `i == _currentIndex ? navigation : SizedBox.shrink()`）为避免 focusId 重复注册，页签只交给当前分区，隐藏分区拿空占位。切分区时新分区挂的是**全新**的 `FushiSectionTabBar`，`TabController(initialIndex: 目标)` 起步即落位，没有起点可滑。视频的首页 / 系列 / 全部视频共用一个 `HomeVideoPage`，页签 State 一直活着，才是唯一会滑的三段。
  - 游戏（`home_game_page.dart`）七个子区在 IndexedStack 里常驻，每页各挂一份 `selected` 为常量的 `GameSectionTabs`：被切出来的那页页签早就停在自己的位置上。
- **[x] ① 已修复** — 壳侧给页签一个壳持有的 `GlobalKey`，切分区就是同一个 State 换父节点，controller 从旧下标 `animateTo` 新下标；游戏侧新增 `LibrarySectionFollowScope`（`fushi/lib/src/utils/components/library_section_tabs.dart`），`HomeGamePage` 以 `gameSectionNotifier` 广播真实所在子区，隐藏页页签跟随它，被切出时从来源子区滑到自己；不在段里的值（诊断）回落到自身 `selected`。
- **[x] ② 已加自动化测试** — `fushi/test/pages/video_library_shell_test.dart`「切到非本地分区：同一个页签 State 换位置，指示条从旧分区滑过去」、`fushi/test/pages/media_library_shell_test.dart`「切视图：同一个分段条 State 换位置…」、`fushi/test/pages/game_section_tabs_slide_test.dart`（断言 State 同一性 + 动画中途值介于新旧下标之间）。
- **备注**：GlobalKey 要求同一帧只挂一份页签；已审计各库页只在一处摆 `navigation`（页头标题位 / mihon 的 `bottom`），无 AnimatedSwitcher 双挂。
