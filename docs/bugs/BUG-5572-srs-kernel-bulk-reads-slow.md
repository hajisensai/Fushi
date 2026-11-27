## BUG-5572 · SRS 内核批量读慢：笔记 / 实体视图 / 卡历史每条约 3 ms
- **报告**：2026-11-27（BUG-5566「复习历史捐赠页首次统计慢」的「未修」一段拆出来的：用户真实库副本上 `SrsDbStore.notes` 读 3223 条笔记 8–12 s、`entityViews` 同一批约 10 s、`histories` 3223 张卡 6–9 s，release 库，每条约 3 ms。BUG-5566 在 PR hajisensai/Fushi#4541 的分支 `claude/page-load-layout-issues-1739b9` 上，两边互相引用）
- **真实性**：✅ 真 bug（部分是数据量本身，见备注）。用真库副本（profile `01a13df4-…`，25512 张卡，可见卡 4650 张、对应笔记 4650 条；笔记字段是 Yomitan 释义 HTML，每条笔记的修改行约 51 KB）加两份手动基准量的：内核一侧 `native/fushi_fsrs/src/store/gen4/cmd/views_realdb_bench_tests.rs`（`FUSHI_G4_REALDB`，配 `RUSTFLAGS="--cfg srs_probe"` 出 `store/prof.rs` 分段），宿主一侧 `packages/fushi_engine/test/srs/srs_bulk_reads_real_db_bench_test.dart`（`FUSHI_SRS_BULK_BENCH_DB`，按命令打 `SrsOpLedger`）。找到的按条贵的地方：
  1. `entity_views` 把视图 JSON 当**字符串**塞进回包 JSON（`cmd/views.rs` `entity_views_cmd`）：视图里的修改行本身是 JSON 字符串，字段正文的每个 `"` 在回包里转义成 7 个字节，4096 条笔记的回包 280 MB；宿主 `_sync2` 再整个 `jsonDecode`、跨 isolate 拷一遍——宿主侧比内核拼视图本身慢得多，机器内存紧时一批能到几十秒（同一次基准里出现过 343 s）。
  2. 读命令的修改行拼两遍（`cmd/mod.rs` `with_profile`）：`derive.rs` `edit_lines_as` 先按 `p = ""` 拼好整行 JSON，读命令再把整行解开、换 `p`、重新写回——几十 KB 的字段正文多一遍解析加一遍序列化（真库上每 500 条笔记约 90 ms）。
  3. 卡历史的日志逐条查别名（`cache.rs` `card_logs`）：每条日志 `canon` 一次、`class_of` 两次，迁移来的库里每条日志都带一条旧 ID 的别名，于是每条又走 `log_rep` → `class_of` + 每个成员一次 `LOG_REP_SQL`，一条日志五六次点查。
- **[ ] ① 部分修复** — 上面三处已按根因修（提交见 PR）：
  1. `entity_views` 的视图改走列式表（`store/bulk.rs`，与 `read` 同一种）的字符串列，文件名 `t`，列 `id` / `tag` / `v`，回包 JSON 是 `{}`；Dart `SrsDbStore.entityViews` 走 `_columnsCommand` 读列（`cmd/views.rs` 文件头「线上形状」）。`v` 仍是视图的规范 JSON 文本，`tag` 不变，远程复习的线格式不变。
  2. `edit_lines_as` / `class_lines_by` / `class_lines_keyed` / `class_conflict_lines` 加 `profile` 参数，读命令（`edit_rows_with`、`read` 的冲突行与 `style_candidates`）拼的时候就填集合绑定的 profile uid；判定与缓存层仍给空串。输出逐字节不变（`canonical` 就是 `serde_json::to_string`，解开再写回是恒等）。
  3. `CARD_LOGS_SQL` 把每条日志的规范日志 ID 与「类里有没有别的成员」与日志行一条语句带出；`log_class_rep` 改成收规范 ID，全类的 `win = 1` 行一条 `LOG_REP_SQL`（`UNION ALL` 别名成员）取齐；`training.rs` `is_rep` 同步。
  4. 读命令（`read` 的 entities / edits / logs、`entity_views`、浏览的 `edits_with`）共用一次 pass 的写入者换名表与规则（`class.rs` `in_read_pass`），不每个实体各算一遍（实测影响很小，口径对就留着）。

  **前后对比**（同一台机器、同一份库副本、交替跑；机器满载 CPU ~99%，绝对数会抖）：
  - 宿主端到端（quick 构建的 DLL，4650 条）：`entityViews` 每条 2.0–2.1 ms → **0.84–0.93 ms**；`notes` 1.33–1.47 ms → 1.56–1.85 ms（内核读 3.57 s → 3.01 s；物化 3.55 s → 4.11 s 是噪声，物化代码没动）；`histories` 1.07–1.21 ms → 0.98–1.38 ms（在噪声里）。
  - 内核（cargo 基准，4096 条一条命令）：`read edits(notes)` 4.0 / 4.7 s → 3.4 / 3.1 s；`entity_views(notes)` 5.6 / 6.3 s（回包 280 MB）→ 4.2 / 3.8 s（列式表 235 MB）；`read logs(cards)` 3.4 / 3.1 s → 4.0 / 2.4 s（抖得比差值大）。

  **还没修好的（`notes` / `histories` 每条仍约 1–1.5 ms，没到亚毫秒）**：剩下的主要是数据量本身——每条笔记约 51 KB 修改行 JSON，要经过 真相层解码 → 值解析 → 整行序列化 → 列式表 → 宿主 → `srsMaterializeNotes` 再解析一遍 → 物化输出再序列化 → 宿主 `jsonDecode`，每一遍都是几百 MB/s（依赖是 `opt-level = "z"`；把 serde_json 单独拉到 3 实测只快约 10%，已试过没留）。要再降一个量级得减少遍数，下一步两件：(a) 内核出一条「读 + 物化」合一的笔记命令，修改行不出内核再进内核、不再解析第二遍（Rust 胖核心方向，Dart `SrsDbStore.notes` 改用它，`SrsNoteView.edits` 要的修改项照旧带出）；(b) `read logs` 里同一个历史族的卡各自重建一遍 `card_logs`（4096 张卡 6104 次、`log_at` 56690 次，交回的只有 39971 条），按族一次取齐。两件都属于 BUG-5572 的剩余部分，下一个会话接着做。
- **[x] ② 已加自动化测试** — `cmd/views_tests.rs` `entity_view_rows`（回包 `{}`、一个文件 `t`、三列，按列解码；`views()` 与 `writes_owner_merge_tests.rs` 的 `views()` 都走它）；`cmd/training_tests.rs` `fingerprint_tail_and_scan_statements_use_the_arrival_order` 加 `CARD_LOGS_SQL` 与新 `LOG_REP_SQL` 的查询计划断言（只走 `log_ix` 主键 / `log_id`、`alias_ix` 主键 / `alias_canon`，不扫表、不建临时表）；`with_profile` 去掉后读命令行与写命令回包行逐字相同由现有的 `writes_tests.rs` `edit_rows_in_the_reply_are_what_read_edits_gives` 咬住。`cargo test --profile quick --lib` 1551 passed / 0 failed；Dart `srs_remote_store_test.dart` + `srs_profile_ownership_test.dart` 110 passed（新代码的 quick DLL）。
- **备注**：两份基准默认跳过，跑法写在各自文件头。真库副本只在 scratchpad 里，原件 `D:/APP/HIBIKI_date/support/` 没动。
