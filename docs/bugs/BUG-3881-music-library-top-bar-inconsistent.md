## BUG-3881 · music-library-top-bar-inconsistent
- **报告**：2026-10-30（用户：群反馈「音乐的顶栏和其他的不太一样」）
- **真实性**：✅ 真 bug。`fushi/lib/src/pages/implementations/music/music_library_page.dart` 自己画 `FushiFloatingTopBar` + 分段按钮，没走其它库页共用的 `FushiFloatingChromeBar` + `LibrarySectionTabs` + `FushiShellActionsSlot`；`home_page.dart` 的 `_tabHasFloatingChrome` / `homeShellTitleFor` 也没把 music 算进来。
- **[x] ① 已修复** — 音乐页改用 `FushiFloatingChromeBar`（分区 tabs + 右上动作槽，动作经 `FushiShellHeaderActions` 上报）与 `FushiFloatingChromeInsetPadding`；home_page 把 `HomeTab.music` 并入浮动 chrome 与标题判据。
- **[x] ② 已加自动化测试** — 既有 `fushi/test/pages/music_library_page_test.dart`、`fushi/test/pages/home_shell_title_compact_test.dart` 覆盖新结构（见 PR）。
- **备注**：Windows 调试实例上人工确认过。顺带修了自测时日志里的 Scrollbar 断言「ScrollController is attached to more than one ScrollPosition」：音乐页 `AnimatedSwitcher` 切分区（及搜索页两态）时新旧主滚动视图同挂外壳那一个 PrimaryScrollController（tab 藏起时 ticker 静音、旧子树不移除，存量问题），每个分区改套 `SectionPrimaryScrollScope`，与视频库外壳同做法；未在运行时复现确认断言消失。
