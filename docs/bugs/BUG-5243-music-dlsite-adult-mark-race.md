## BUG-5243 · DLsite 整库识别的 R-18 自动标记与并发取消有空档，取消可被盖回 NSFW
- **报告**：2026-11-22（2026-11-22 项目审查 HBK-AUDIT-216，PR #4140）
- **真实性**：✅ 真 bug。`fushi/lib/src/media/music/metadata/music_dlsite_scraper.dart:216-222`（修前）`_markAdultByDefault` 先 `mediaNsfwClock` 读两只时钟、判「从没动过」，再另起一次 `setMediaNsfw(true, at: _clock())` 写入。两步之间用户手动取消或互联合并落库的 `clearedAt`，会被这次更晚的 `nsfwAt` 按 LWW 盖回去——专辑又成了 NSFW，违背「用户取消过就不再标回去」的设计意图。
- **[x] ① 已修复** — `packages/fushi_core/lib/src/database/database_tags_sync.part.dart` 新增 `markMediaNsfwIfUndecided`：一条 `INSERT … ON CONFLICT DO UPDATE … WHERE nsfw_at IS NULL AND cleared_at IS NULL`，判定与写入在库里同一条语句完成；`_markAdultByDefault` 改用它。
- **[x] ② 已加自动化测试** — `fushi/test/media/music/metadata/music_dlsite_scraper_test.dart`「自动标记与并发取消…（HBK-AUDIT-216）」（在自动标记取时钟的同一刻插入取消，修前断言 NSFW 为 false 失败）+「markMediaNsfwIfUndecided：只写从没决定过的宿主…」。
- **备注**：
