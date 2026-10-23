## BUG-3663 · video-home-filtered-by-hidden-tag
- **报告**：2026-10-22（用户：反馈 ZjKzpkfZ1N「选中标签以后，首页即使没有标签模块也不显示东西」，Android 截图：视频库「首页」分区整页空白，「系列」分区选着 1⭐ 标签、显示「没有符合当前筛选条件的视频」）
- **真实性**：✅ 真 bug。视频库三个分区共用 `HomeVideoPage` 的同一个 State 与同一份筛选状态（`selectedTagIdsProvider` 还与书架共享）；首页分区不显示标签栏 / 筛选面板 / 页头搜索（`home_video_page.dart` `widget.section != VideoLibrarySection.home` 门控），但首页概览 `_buildOverviewSection(all, remoteVideos, ordered, …)` 吃的是**标签 + 搜索 + 面板过滤后**的 `ordered` 与过滤后的远端 `remoteVideos`（`_visibleRemoteVideos(state, filter)` 在标签筛选激活时直接返回空）。于是在系列页选一个标签，首页所有行被静默筛空，且空态只在 `all.isEmpty` 时出现，整页空白。
- **[x] ① 已修复** — 首页分区改取未过滤的全量：本地 `homeLocal = all`（骨架期为空），远端 `homeRemote` 只保留「显示远端条目」开关与本机同集去重，不过任何筛选；概览门控与空态判据同步换成这两份。提交 `13bf9d1b01`。
- **[x] ② 已加自动化测试** — `fushi/test/pages/home_video_home_row_tags_test.dart`「在别的分区选中的标签不筛首页」：真 HomeVideoPage 首页分区，置 `selectedTagIdsProvider` 为一个没有条目打过的标签，断言在看条目仍出现在继续观看行。
- **备注**：真机未复测（Android 截图路径）。
