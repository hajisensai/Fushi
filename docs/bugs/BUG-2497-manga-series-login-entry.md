## BUG-2497 · manga-series-login-entry
- **报告**：2026-09-13（用户：截图 BookWalker Japan 作品页，「这个怎么登录，这里应该有登录按钮」）
- **真实性**：✅ 真 bug（入口缺失）。登录流程本身存在（BUG-2479），但作品页 `fushi/lib/src/media/manga/library/manga_series_page.dart` 的 `FushiPageScaffold.actions` 只有收藏 / 刷新；登录只能从 ① 点一条锁章 → 弹窗「登录」（`_promptLockedChapter`）或 ② 漫画源管理页每行的 🔑 图标（`manga_sources_page.dart` `_loginTargetFor`）进入。用户看到「锁」的这一页反而没有入口。
- **[x] ① 已修复** — 抽 `_loginTarget` getter（与锁章弹窗共用同一判据 `is OnlineMangaLoginCapable`），AppBar 加 `manga_series_login` IconButton 复用 `_loginToSource`（登录成功后自动 `_refreshFromSource` 刷锁位）。Aidoku / 互联对端适配器不实现该接口，按钮自然不出现。
- **[x] ② 已加自动化测试** — `fushi/test/media/manga/manga_series_page_locked_chapter_test.dart`：登录适配器 → AppBar 有按钮且可点；普通适配器 → 无按钮。
- **备注**：
