## BUG-3959 · srs-deck-settings-slow-open
- **报告**：2026-11-01（用户：复习的牌组设置打开很慢，约 20 秒起步）
- **真实性**：✅ 真 bug。牌组设置页 `_load`（`fushi/lib/src/pages/implementations/srs/srs_deck_settings_page.dart:154`）只为标出本牌组哪几项有同步冲突，却调不限实体的 `SrsDbStore.syncConflicts()`（`packages/fushi_engine/lib/srs/srs_db_store.dart:4277`）：子查询 GROUP BY 扫本 profile 全部修改记录索引，外层普通 JOIN 又被 SQLite 排成按 `profile_uid` 扫 `srs_field_edits` 全部行再探子查询。用户真实库（1.5 万笔记、65 万条修改记录，两台设备各导入过同一个包，每条笔记的「所属牌组」都有两条并发记录）上实测 `syncConflicts()` 热缓存 2.0–2.9 s、冷缓存 9.9 s，读回 4.7 万行全部丢弃（结果为 0 条冲突），此时库还被持续写入的同步占着连接，两者叠加。
- **[x] ① 已修复** — `syncConflicts({entity})` 可按单个实体查（子查询按 `idx_srs_field_edits_profile_register` 前缀定位），外层改 `CROSS JOIN` 钉死「先挑多记录字段键、再按完整索引键取记录」的顺序；牌组设置页与控制通道 `conflicts/fields/resolve` 传实体。真实库副本上牌组设置这一步 2932 ms → 4 ms（`packages/fushi_engine/test/srs/srs_deck_settings_open_bench_test.dart`，`FUSHI_SRS_REAL_DB=<副本>` 手动跑）。
- **[x] ② 已加自动化测试** — `packages/fushi_engine/test/srs/srs_db_store_test.dart`「同步冲突按实体查：只读回这一个实体的记录」：两张卡有冲突时按实体只返回该实体、只读回 2 行；无冲突实体 / 种类不符返回空。
- **备注**：同一时段用户反映「同步一直在跑没停过」、打开卡片也慢（srs.db 在 app 开着时 6 分钟涨约 40 MB）——另行调查，不在本修复范围。不限实体的全量路径（冲突中心 / 牌组列表冲突角标）在该库上仍约 2 s，主要是 GROUP BY 扫全部修改记录索引。
