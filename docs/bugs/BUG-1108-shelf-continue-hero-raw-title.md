## BUG-1108 · 改名后书架继续阅读条仍显示旧名
- **报告**：2026-07-25（用户：编辑弹窗改书名后，书架顶部「继续阅读」hero 条仍显示旧名）
- **真实性**：✅ 真 bug。根因：`hibiki/lib/src/pages/implementations/reader_hibiki_history_page.dart:884`（修复前）`_buildContinueReadingHero` 直读 DB 原始值 `hero.title` 上屏；同 hero 的封面在 `:867` 早已走 override（`getDisplayThumbnailFromMediaItem`）——名字漏了一行。BUG-1018 修 dashboard 改名不同步时因**无面级守卫**而漏掉本面（网格卡的同类守卫在 `shelf_srt_card_override_title_guard_test.dart`，hero 条无守卫覆盖）。
- **[x] ① 已修复** — `0d52d9bc3`：`reader_hibiki_history_page.dart` `_buildContinueReadingHero` 书名改经 `mediaSource.getDisplayTitleFromMediaItem(hero)`（State 内 `mediaSource` 即 `ReaderHibikiSource.instance`，与封面同源应用 override 书名）。
- **[x] ② 已加自动化测试** — `hibiki/test/pages/shelf_continue_hero_override_title_guard_test.dart`（源码扫描守卫，沿 `shelf_srt_card_override_title_guard_test.dart` 范式）：`_buildContinueReadingHero` 函数体必须含 `getDisplayTitleFromMediaItem(hero)` 且不得裸用 `hero.title,` 上屏。
- **备注**：真机复测（改名 → 回书架看 hero 条）待补。
