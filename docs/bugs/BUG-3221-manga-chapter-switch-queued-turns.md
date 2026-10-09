## BUG-3221 · 换章装载期间多滑的几下在新章装好后被逐页消费
- **报告**：2026-10-09（用户：反馈处理台 qMRtA75fhO：「跨章时有点卡，卡得急了多滑了几下，加载完后它还真给往后翻几页，感觉干脆直接给个缓冲加载转圈圈页面」）
- **真实性**：✅ 真 bug。`fushi/lib/src/media/manga/reader/manga_fushi_page.dart`（upstream/develop）`_onMangaTurn` `:2958` 换章期间照常 `_turnQueue.enqueue`：`canApply` 里的 `!_switchingChapter` 只让 drain 暂停，`MangaTurnQueue._pendingDelta` 却一直累加（注释声称「换章期间排队的 step 直接被丢掉」与实现不符）。换章那一步本身在 drain 循环里 await，返回后 `_switchingChapter=false`，循环立刻把攒下的步数在新章上逐页消费。换章期间也没有任何加载反馈，用户以为没翻动于是多滑。
- **[x] ① 已修复** — `_onMangaTurn` 在 `_switchingChapter` 时直接 return（输入丢弃）；`_switchToChapter` 置位后立刻 `_turnQueue.clear()`（丢弃撞到章尾前攒下的长按步数）；新增 `MangaTurnQueue.clear()`；换章装载期间正文上盖 `MangaChapterSwitchingOverlay`（遮罩 + 进度环 + 目标章名，不吃指针，淡入淡出走 `fushiMotionDuration`）。同时去掉章末「下一章」卡片（翻过末页本来就直接换章）。
- **[x] ② 已加自动化测试** — `fushi/test/media/manga/manga_chapter_crossing_test.dart`（队列行为：换章期间 / 换章前攒下的步数都不在新章上消费；接线守卫）、`fushi/test/media/manga/manga_chapter_switching_overlay_test.dart`（加载层可见、显示章名、不挡指针；`FUSHI_PREVIEW_DIR` 出真实像素 PNG）。
- **备注**：用户顺带提的「提前加载下一章的设置开关」：已下载章节已有「预下载」（`downloadAhead`），在线直读章不预取是所有者 2026-09-26 拍板（不替直读用户落盘下一话），本 PR 不改，列待定。
