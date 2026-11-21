## BUG-4727 · 游戏批量刮削把跨源同名当成歧义，Bangumi 与 VNDB 都收录的作品刮不出封面
- **报告**：2026-11-16（用户：维护者，应用内反馈 tTYcSLWRv_；游戏库 STEINS;GATE RE:BOOT、ATRI 等「全部刮削」后仍无封面）
- **真实性**：✅ 真 bug。`fushi/lib/src/mining/galgame_scrape_controller.dart:110` 把 Bangumi / VNDB / DLsite 三源候选拼成一条列表，`fushi/lib/src/pages/implementations/games_library_page.dart:663` 把整条列表交给 `fushi/lib/src/media/metadata/scrape_title_matcher.dart:20`（`uniqueExactScrapeTitleMatch`），只要出现第二条精确同名就返回 null。两个源都收录的作品各回一条同名 → 判「需确认」，批量永远不自动采用、封面不补。
- **[x] ① 已修复** — 唯一性改为按源判：`uniqueExactScrapeTitleMatch` 新增必填 `sourceOf`，同一源内多条精确同名才是歧义（返回 null）；不同源各一条视为同一作品，取候选顺序里第一个源（Bangumi → VNDB → DLsite）的命中。游戏库 `_scrapeAllGames` 传 `candidate.source`。
- **[x] ② 已加自动化测试** — `fushi/test/mining/galgame_batch_scrape_match_test.dart`（假 adapter 走真实 `GalgameScrapeController.search` 合并路径）、`fushi/test/media/metadata/scrape_title_matcher_test.dart`（跨源 / 同源歧义用例）、`fushi/test/media/metadata/scrape_all_entry_guard_test.dart`（守卫页面传 `sourceOf`）。
- **备注**：同一反馈里 Start、yurialice 取自 exe 名、本就搜不到作品（skipped），属于另一问题，本条不处理。旧注释「跨源同名结果留给单卡确认」是有意设计，本次按维护者要求改。
