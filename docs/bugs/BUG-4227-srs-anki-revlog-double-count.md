## BUG-4227 · 从 Anki 迁移后复习数 ×2（同一条 Anki revlog 落在两张卡上算两次）
- **报告**：2026-11-07（用户：Discord 群反馈；2026-09-06 这天 Anki 统计 2082 次复习，Fushi 统计日历 4164 次，正好 2 倍）
- **真实性**：✅ 真 bug（合成 apkg 复现，`packages/fushi_engine/test/srs/apkg/srs_apkg_anki_revlog_dedupe_test.dart`）。
  - 根因：导入的复习日志 ID 由**本机卡 ID** 派生（`packages/fushi_srs/lib/src/ids.dart:223` `SrsIds.importedRevlogs`，
    调用点 `packages/fushi_engine/lib/srs/apkg/srs_apkg_import.dart:1919`），写入前不看本 profile 里是否已有同一条 revlog。
    来源笔记换过模板 / 笔记类型之后再导入，同一条 revlog 落到另一张卡上就成了另一条日志：
    - **B 形态（同一血统）**：Lapis 迁到 Fushi 卡片（新卡经 `historyFrom` 继承旧卡历史）后，Anki 端笔记已是 Fushi 卡片、
      再迁一次——新卡上又写一份。选取规则的同事件身份含卡（`native/fushi_fsrs/src/history.rs` `EventKey.card`），
      血统里两份都算有效：排程、统计、重放都推进两次。不删也会发生。
    - **C 形态（没有血统链接）**：先按一种类型导入，删光后按另一种类型重导（`srs_apkg_import.dart` 的恢复 + `retype`）——
      旧卡隐藏、新卡可见，两张卡各自是投影的归属卡（`native/fushi_fsrs/src/store/caches.rs` `refresh_stats` 的
      `owner_of`），统计读取不分隐藏（`store/bulk.rs` `stats_bundle`）：两份都进 `srs_stat_reviews`。
  - 「删光重导」消不掉：日志永不物理删除（`srs_purge.dart` 文件头），重导按新卡 ID 又派生一份。
- **[x] ① 已修复** — 读侧（治已受害的库，内核）：`history.rs:125` Anki 来源日志的 `EventKey` 不比卡（血统内同一 revlog
  只算一份，排程 / 重放 / 统计 / 优化器同一判据）；`caches.rs` `refresh_stats` 增量刷新时把有同一 Anki 时刻日志的卡
  （`anki_partners`）一起重算到不动点，投影后按 `history::AnkiEvent`（revlog id + HLC + 种类 + 评分 + 复习类型 + 用时）
  跨归属组只留一份（`dedupe_anki_rows`，按笔记收紧：认得出的笔记不同不合并；留可见卡的那份）；srs.db v28
  （`store/sync2/mod.rs` `replay_anki_copies`）按新规则重放带这种副本的卡、摘要前缀换 `5:`；Dart 缓存修订号 12
  （`srs_db_store.dart` `_kCacheRevision`）整库重算卡片状态与投影。写侧：`srs_apkg_import.dart` `_importCardSchedule`
  写 revlog 前按块预读本机已有的 Anki 日志（`SrsDbStore.ankiImportedLogsAt`），在血统里的不写，在已隐藏旧卡上的给新卡
  接 `historyFrom/<旧卡>`，在仍可见的卡上的不写（报告 `revlogsAlreadyPresent`）。
- **[x] ② 已加自动化测试** — `packages/fushi_engine/test/srs/apkg/srs_apkg_anki_revlog_dedupe_test.dart`（B1 / B2 / C1 写侧、
  C2 对照、不同笔记同一毫秒不误认、读侧两种形态 + 重建缓存）；Rust：`history.rs`
  `anki_revlog_imported_onto_two_cards_of_one_lineage_counts_once` 等、`caches.rs`
  `anki_revlog_on_two_unlinked_cards_is_projected_once`、`sync2/tests.rs` `v28_upgrade_replays_cards_with_anki_copies_across_cards`。
- **备注**：卡片翻倍（内置 Fushi Card 多出第二个模板）不在本条范围（上游 PR #3032 / #3044）。没有用户的库，修复按合成库验证；
  已受害的库升级后统计应回到 Anki 的数，未在真实用户库上验证。
