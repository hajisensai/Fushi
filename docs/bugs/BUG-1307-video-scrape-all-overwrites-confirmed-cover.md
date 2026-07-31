## BUG-1307 · 手动整库刮削用高分近似匹配覆盖用户已确认的封面
- **报告**：2026-08-01（用户：PR#595 集成复核）
- **真实性**：✅ 真 bug（本 PR 新增路径引入，未合入 develop 前发现）

  视频域页头新增的「全部刮削」是四域里**唯一**开 `rescrapeScraped: true` 的批处理
  （`hibiki/lib/src/pages/implementations/home_video_page.dart:1874`），而它自动落盘的判据
  仍是综合分阈值而非唯一精确标题：

  - 保护判据只挡 manual / sidecar，`scraped` 在 `rescrapeScraped: true` 下解锁
    （`hibiki/lib/src/media/video/scraper/cover_scraper_service.dart:302-305`）；
  - **用户在匹配弹窗里亲手点「使用」选定的封面，写的也是 `CoverOrigin.scraped`**
    （`cover_scraper_service.dart:389` → `_applyCandidate` 的 `CoverMeta(origin: CoverOrigin.scraped)`，
    调用点 `hibiki/lib/src/media/video/cover_ui/cover_match_dialog.dart:361`），
    与自动刮削结果在 `cover_meta.json` 里无法区分；
  - 自动落盘判据是 `MatchConfidence.high`（`cover_scraper_service.dart` 的 `_applyResolved`），
    而 high = 综合分 ≥ 0.85、标题相似度低至 0.55 即可参评
    （`hibiki/lib/src/media/video/scraper/match_scorer.dart:48`、`:55`）——
    标题相似度 0.70 + 年份吻合 0.15 就够线，**这不是精确标题匹配**；
  - 号称能兜底的别名缓存不可靠：`_resolveAliasCandidate` 用 `parsed.title` 重搜该源再按
    entryId 过滤（`cover_scraper_service.dart:686-696`），而用户会去纠错**正是因为**文件名标题
    搜不出正确条目，此时重搜命中不到 → 返回 null → 直落第 ⑤ 层模糊匹配 → 覆盖用户的选择。

  同一 PR 的书 / 漫画 / 游戏三域都接了唯一归一化精确匹配
  （`hibiki/lib/src/media/metadata/scrape_title_matcher.dart` 的 `uniqueExactScrapeTitleMatch`，
  接线于 `reader_hibiki_history_page.dart` 与 `games_library_page.dart`），且都不覆盖已有封面，
  唯独视频域漏接。

- **[x] ① 已修复** — `scrapeOne` / `scrapeLibrary` 新增 `requireUniqueExactTitle`（默认 false，
  既有自动刮削判据不变）；目录级缓存单元由裸 `MatchDecision?` 升为 `_ResolvedMatch`，
  携带「唯一归一化精确标题」判据，由 `_resolveBestDecision` 在打分同一趟里按
  source/entryId 去重统计得出；开关打开时 `_applyResolved` 的 high 分支必须同时满足
  `uniqueExactTitle` 才落盘，否则降级 `ScrapeNeedsConfirm`。
  页头「全部刮削」（`home_video_page.dart`）传 `requireUniqueExactTitle: true`。
  用户自己纠过的别名命中仍恒当唯一精确处理，重刮会把用户的选择原样恢复。
- **[x] ② 已加自动化测试** — `hibiki/test/media/video/scraper/cover_scraper_service_test.dart`
  四个用例：唯一精确才落盘 / 多个同名精确不落盘 / 高分近似降级待确认 / 默认开关关闭时
  既有判据不变（防过度收敛）。已做变异实测两个方向。
- **备注**：同批顺带修的另两处（都在本 PR 自己新增/改动的代码里，未合入 develop 前发现）：
  1. `hibiki/lib/src/media/metadata/scrape_batch.dart` 的计数吞没——收尾动作抛错会把
     已真实写盘的累计计数整个换成 `failed: 1`，500 本已落盘会显示成「应用 0 / 失败 1」。
     改为沿用最后一次进度回调的累计值，非条目级异常只进错误日志，不伪造条目计数。
  2. `hibiki/lib/src/mining/galgame_scrape_dialog.dart` 的 `_downloadScrapedCover`：
     新增 `replaceExistingCover` 时把 `await File(existingPath).exists()` 写成了**无条件**
     求值，显式覆盖路径（`replaceExistingCover: true`，即弹窗里点「使用」）根本不消费它，
     却因此多插一轮真实文件 I/O，打破 develop 既有用例
     「封面下载失败静默降级」（`galgame_scrape_dialog_test.dart:253`，pumpAndSettle 超时）。
     改成惰性求值后显式路径与 develop 语义逐字节一致。
