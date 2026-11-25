## BUG-5244 · DLsite 整库识别取消后，缓存命中的专辑仍继续下载主图、写封面和 NSFW
- **报告**：2026-11-22（2026-11-22 项目审查 HBK-AUDIT-229，PR #4032）
- **真实性**：✅ 真 bug。`fushi/lib/src/media/music/metadata/music_dlsite_scraper.dart:293-308`（修前）`scrapeLibrary` 第一轮遍历专辑时，资料已缓存的专辑直接 `_applyToAlbum`（下载主图、写封面、标 NSFW），取消检查只在第二轮（联网取资料）每项开头。第一张补图在途时取消，后面的缓存命中专辑照样下载与写库；同作品其余专辑的补图循环也不查取消。
- **[x] ① 已修复** — `scrapeLibrary` 拆成两趟：第一趟只读（认编号、查缓存），不下载不写库；第二趟逐项落地，缓存命中的专辑、要联网取的作品、同作品的其余专辑，每一项开始前都查 `cancelled`。
- **[x] ② 已加自动化测试** — `fushi/test/media/music/metadata/music_dlsite_scraper_test.dart`「整库：缓存命中的第一张补图在途时取消…（HBK-AUDIT-229）」（修前下载两次、两张都补图标 NSFW）。
- **备注**：
