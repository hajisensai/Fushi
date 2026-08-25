## BUG-1855 · 视频首页「继续观看」一集看完退出后合集消失，只有中途退出才在
- **报告**：2026-08-25（用户：截图 Yuru Yuri「看到第 9 集」；一集从头看完退出，再进首页「继续观看」里就没它了，只有中途退出才有；用户提议「下一集也放一份在这」）
- **真实性**：✅ 真 bug。`fushi/lib/src/pages/implementations/home_video_page.dart:3126-3132`（改前 `_buildContinueRow`）对合集只认「最近播放那集未完成」——`latestPlayedSeriesIndex` 取到的那集 `completedAt != null` 就直接 `return`，合集整个不进本行。而同页 hero 大卡的「继续看·第 N 集」走 `collection_continue.dart` 的 `continueMemberIndex`（锚点已完成 → 下一集），同一页两套口径，行卡那套是残缺的。
- **[x] ① 已修复** — 新增纯函数 `continueWatchingSeriesIndex`（`fushi/lib/src/media/video/video_home_layout.dart`）：最近播放那集没看完 → 它自己；已看完 → 紧接的下一集；整部看完 / 无痕迹 / 位置拖回 0 → null。`_buildContinueRow` 改用它；目标集尚未开播时卡片副文案走 `video_home_next_episode_number`（「下一集 · 第 N 集」）而非「看到第 N 集」，由成员自身状态决定不另传标志。「下一集」行照旧，两行各一份。提交见 PR。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/video_home_layout_test.dart`（纯函数四态）+ `fushi/test/pages/home_video_continue_row_nextup_test.dart`（真 widget：看完→继续行出合集卡指向第 2 集且文案「下一集 · 第 2 集」；中途退出停在自身；整部看完不进本行）。变异实测：把「未开播即 return」的旧判据加回去，widget 测试红。
- **备注**：远端占位卡（`RemoteVideoInfo`）无完成口径，不在本改动范围。未做真机复测（逻辑层已由 widget 测试覆盖）。
