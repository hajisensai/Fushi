## BUG-4478 · 复习同步 v2 的新设备收段通道在生产里一次都不会被选中
- **报告**：2026-11-11（调查报告：通道的进入判据与真实新设备的起点对不上）
- **真实性**：✅ 真 bug。新设备第一次同步本该走「先追加后折叠」的收段通道（`docs/specs/2026-11-03-srs-sync2-bootstrap-channel.md`，
  真实全量数据 229 s 对逐条投递 413 s），实际一直走逐条投递。
  - 根因：进入判据 `native/fushi_fsrs/src/store/sync2/channel.rs:124` `fresh()` 要求这个 profile 的 `sync2_ops`、
    `srs_entities`、`srs_field_edits`、`srs_review_logs` 全空；而 `packages/fushi_engine/lib/srs/srs_db_store.dart:428`
    `SrsDbStore.open` 在任何同步之前无条件 `ensureBuiltins()`（`:2263`），经内核 `apply` 写下 3 条本机操作与 3 行投影
    （默认牌组 + 两个内置笔记类型，`srs_builtin.dart:171` `srsBuiltinEntities`）。所有生产路径都经 `SrsDbStore.open`，
    开收段会话（`transport.rs:2735` `channel::begin`）时判据恒为假，`sync2_boot` 始终 0 行。
  - 为什么测试没发现：通道的对拍测试（`tests_channel.rs`）与基准（`bootstrap_probe.rs`）都从不带内置实体的裸内核库起步；
    Dart 的 `srs_sync2_channel_settle_test.dart` 手工往 `sync2_boot` 插行。没有一条测试在 `SrsDbStore` 打开过的库上让通道被
    自然选中；`channel_is_only_for_a_fresh_profile` 甚至断言「写了默认牌组的 profile 逐条投递」。
  - 顺带的第二处（通道一旦在生产打开就会暴露）：`plan` 不会先做完通道（`ffi.rs` `CHANNEL_TRANSPARENT`），
    `trust.rs:63` `note_new_device` 却按投影判「本机库里有没有用户的东西」。通道在追加 / 折叠阶段被打断、下一轮才第一次见到
    的设备，通道路径读到的投影还是空的 → 直接可信；逐条路径同一时刻投影已有数据 → 待确认、删除被扣。两条路径的
    `sync2_trust` / `sync2_trust_held` / 投影都不同。
- **[x] ① 已修复** — 7b6d4757bd0（PR 分支 `pr/srs-sync2-bootstrap-with-builtins`）。只改内核本机怎么收：
  - 判据（`channel.rs` `fresh`）：这个 profile 在本机只有开库时自己写下的内置身份记录（或什么都没有）才开通道——投影里
    没有用户的东西（`trust::library_fresh`：没有复习日志、没有修改记录、身份记录的载荷全带 `builtin` 键），没有不认识的
    事件行，本机没换过身份，操作日志里每一条都是本机当前身份写的身份记录，且与投影里的身份记录行逐个对应（同 ID、同
    种类、同内容）。用户改过内置牌组名 / 内置笔记类型模板（多一条修改操作）不算新设备，照旧逐条投递。
  - 折叠（`channel.rs` `fold_part`）：身份记录撞到投影里已有同 ID 的行就不折，按投递顺序交给生产的 `project_entity`
    （同内容不写、不同内容取规范文本小者）；其余照常折——判据保证修改记录、日志、索引、清除、挂起、标签在本机全空。
  - 信任（`trust.rs` `note_new_device` / `sees_new_device`，`transport.rs` `sync2_plan_at`）：通道没做完时第一次见到
    某台设备，先把通道做完再按投影判「本机库里有没有用户的东西」（进写事务之前按片做，事务里的那次只是兜底）。
- **[x] ② 已加自动化测试** — `native/fushi_fsrs/src/store/sync2/tests_channel.rs`（起点 × 世界的通道 / 逐条对拍：带内置
  实体的起点、迁移出来的内置实体、远端没动过 / 改过 / 删过并清除过 / 同 ID 内容不同、追加 / 本机写入 / 折叠 / 归并四种
  打断、判据逐项、通道没做完时新见到的设备的信任与放行、开通道时没有不被信任的设备、别的 profile 占着同 ID）；
  `packages/fushi_engine/test/srs/sync2/srs_sync2_bootstrap_channel_entry_test.dart`（真实 `SrsDbStore.open` 的两台设备，
  通道被自然选中并收敛）；`fushi/test/srs/srs_pull_before_migrate_test.dart`（app 顺序：只拉不发 → 迁移 → 正式一轮）。
- **备注**：只改本机怎么收，不动别的设备读到的任何字节（段、head、摘要、协议常量都不变）。
  - 对拍要两边同一个投递顺序（同样的切片）。逐条投递的结果本身随片长而变（存量，与通道无关，未在本 bug 里修）：
    `transport.rs` `deliver_ready` 每片从第一台设备重新轮，而删除挂起（`semantics.rs` `evaluate_holds`）随投递顺序而变；
    两台都逐条投递、只是片长 64 / 97，`srs_field_edits` 与摘要桶就不同（未改动的 develop 上 10 个随机世界 7 个如此）。
  - 对拍里的中途打断落在「交完一半的段」之后，所以段按世界里钉死的设备顺序交（`tests_channel.rs` `World::feed`），
    不按文件夹里设备 ID 的顺序：ID 是随机的 UUIDv7（测试里前四台的时间前缀相同），照它交时六次里有一次，本机写入
    那一刻通道里只有撞上本机已有行的内置身份记录、一条可折的都没有。PR 的 CI 为此红过一次——红的是拿「折了几条」
    当「走没走通道」的断言，通道是走了的；现在直接断言 `ingest_begin` 报的 `channel`，那种到法另由
    `a_local_write_settles_a_channel_holding_only_identity_records_already_there` 钉住（同样逐表相同）。
  - 已知边界：通道做到一半时换回旧版本的二进制（同一个库），旧折叠不认识「投影里已有行」，归并会撞主键报错，
    换回新版本即恢复。
