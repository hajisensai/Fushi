## BUG-4907 · 漫画阅读器查词时朗读 / 漫画有声不自动暂停
- **报告**：2026-11-20（用户：「缺少查词自动播放暂停」）
- **真实性**：✅ 真 bug。小说阅读器有「查词时暂停」（`ReaderFushiSource.pauseOnLookup`，默认开），漫画阅读器的查词弹窗出现 / 关闭只联动了自动滚动，没接朗读与成品音频，与同一开关的设计意图矛盾。
  - 根因：`fushi/lib/src/media/manga/reader/manga_fushi_page.dart:4440`（`onDictionaryPopupRendered`）与 `:4452`（`onAllPopupsDismissed`）只调 `_syncAutoScrollPause`，没有任何地方暂停 / 恢复 `_MangaReadAloudSupport` 的两种音源。
- **[x] ① 已修复** — 新增 `manga_lookup_pause.dart`（`MangaLookupPause` 只管「按住了没有」一个标记），阅读器把成品音频驱动 / 现场合成控制器适配成 `MangaLookupPausable`：弹窗出现且在播就暂停并记下（多层弹窗幂等），整栈关闭时恢复；查词前本来停着的不动，开关关着不动，用户期间停掉 / 换音源则撤掉标记、关弹窗不恢复。开关复用小说阅读器的「查词时暂停」。
- **[x] ② 已增加自动化测试** — `fushi/test/media/manga/reader/manga_lookup_pause_test.dart`（4 项：按住与恢复、多层幂等、本来停着不动、开关关 / 无音源不动、停掉后不恢复）。
- **验证**：同 BUG-4906 那次定向测试，exit 0，29 项全部执行通过。
- **备注**：副屏伴侣查词见 BUG-4908，「查词后从句首重播」见 BUG-4909（均已在同一 PR 修复）。真机未复测新构建。
