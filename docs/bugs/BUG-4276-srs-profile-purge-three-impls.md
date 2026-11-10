## BUG-4276 · 删 / 换 profile uid 的三份实现不一致，并入与采用后旧 uid 在 srs.db 留残留
- **报告**：2026-11-10（内部审查：「删掉某个 uid 在 srs.db 里的全部行」有三份实现）
- **真实性**：✅ 真 bug（新测试 `srs_profile_purge_single_test.dart` 在修复前两条红，实测残留见下）。三份实现：
  1. Rust `native/fushi_fsrs/src/store/profile_data.rs:79` `profile_purge`（删 profile 用）：现查每张带 `profile_uid`
     的 `srs_*` / `sync2_*` 表、删 `srs_meta` 里 `…/<uid>` 键、回收没人引用的 `sync2_deps`，一个 savepoint。
     **它自己也漏一类键**：`profile_data.rs:106` 只删以 `/<uid>` 结尾的键，uid 在中间的
     `sync2_device_ext/<uid>/<设备>`、`sync2_retired/<uid>/<设备>`（sync2/devices.rs:83/87）、
     `sync2_head_sig/<uid>/<位置>`（sync2/transport.rs:2498）留下。
  2. Dart `packages/fushi_engine/lib/srs/srs_profile_merge.dart:1212` `_deleteProfile`（并入另一个 uid 后删旧 uid）：
     表清单现查，但 `:1230` 只删 `sync2_migrating/<uid>` 与并入标记两个 meta 键，漏 `sync2_digest/<uid>`、
     `sync2_digest_at/<uid>`、`sync2_fork_at/<uid>`、`sync2_self_info/<uid>`、上面三类中间带 uid 的键；不回收
     `sync2_deps`（旧 uid 操作独占的因果上下文成死行）。另外它按 `sqlite_master` 的未排序顺序删：投影表
     （`srs_entities` 等）的删除触发器往 `sync2_digest_buckets` 写负项（sync2/digest.rs:151），桶表先删时触发器写回的行
     留下——实测并入后旧 uid 还剩 4 行 `sync2_digest_buckets`。
  3. Dart `packages/fushi_engine/lib/srs/srs_backup_merge.dart:239` `_kSrsProfileTables`（`:399` `_deleteProfileRows`）：
     手抄 10 张 `srs_*` 表，**一张 `sync2_*` 都没有**、不删任何 meta 键、不回收 `sync2_deps`。用于备份合并「本机同名
     profile 采用备份 uid」（`:286`）与 `srsAdoptProfileUid`（`:394`，同步链接到同步目录里已有 profile、本机没用户笔记
     时直接改用对方 uid：srs_profile_link.dart `_switchUid`，以及它失败时的回退）。实测只打开过一次复习的 profile
     采用后，旧 uid 还剩 `sync2_ops` 3、`sync2_self` 1、`sync2_devices` 1、`sync2_digest_buckets` 3 行。
- **可观察后果**（沿真实代码路径）：
  - 采用后的残留让旧 uid 仍出现在 `profile_uids`（Rust 按带 `profile_uid` 的表并集取 uid）里：存量扫描
    （fushi/lib/src/srs/srs_profile_cleanup.dart `sweepOrphans`）还没跑过的设备，下次进 Profile 管理会把旧 uid 当无主
    数据，**先导出一份 `fushi-review-orphan-xxxxxxxx-….fushisrs` 备份文件**再删；已跑过（`profile_orphan_sweep_v1` 已写）
    的设备，这些行永远留在库里。
  - 并入后的残留：`sync2_digest_buckets` 带 `profile_uid`，同样让旧 uid 出现在 `profile_uids` 里、走上一条的无主扫描
    （多出一份无主备份文件）；meta 键与 `sync2_deps` 用户看不到，是只增不减的死数据（每次并入都留一份旧 uid 独占的
    因果上下文）。
  - Rust 版漏中间带 uid 的键：删 profile 后这些键永远留下（死数据，无功能影响）。
- **[x] ① 已修复**（0968c54cc82）— 只留 Rust `profile_purge` 一份实现：
  - `profile_data.rs` 的 meta 删除补 `instr(key, '/' || uid || '/') > 0`（uid 在中间的键）；表删除顺序依赖（桶表按名字排在
    三张投影表之后）写进注释。
  - `srs_profile_merge.dart`：删掉 `_deleteProfile`，并入收尾在原来的 Drift 事务里调 `srsPurgeProfileRows(core, oldUid)`。
    Drift 的 BEGIN 经内核写连接执行（srs_database_executor.dart），Rust 命令拿同一条写连接、`in_savepoint` 嵌在那笔
    事务里，事务回滚 purge 一起回滚（新测试第三条钉住）；`legacy_open` 时 purge 报错 → 事务回滚，与之前 Drift 语句
    在搬迁期间被 `exec` 拒绝的行为相同。purge 末尾的 `sync2_ingest_end(oldUid)` 只改内存里的收段阶段，事务回滚时
    不会被撤销——旧 uid 的收段会话被作废，下一轮同步重开，无数据影响。
  - `srs_backup_merge.dart`：删掉 `_kSrsProfileTables` 与 `_deleteProfileRows`；采用是整体删除（旧 uid 没有要带过去的
    行，新 uid 的内置行与同步身份按新 uid 重建），不是改写 uid，所以直接调 `profile_purge`。`srsAdoptProfileUid`
    第二个参数由 `SrsDatabase` 改为 `SrsCore`（调用方 srs_profile_link.dart 两处、测试同步改）。以前经 Drift 事务删，
    由 Drift 的事务锁与旧副本开着的事务排队；内核命令直接上共用写连接，所以 `_switchUid` 的采用改在旧副本的
    `runExclusive` 里跑（与删 profile 走 `retire` / `runExclusive` 同一规矩），不夹进它开着的 Drift 事务随之回滚。
  - 不升 srs.db SCHEMA_VERSION、不改同步协议。
- **[x] ② 已加自动化测试** — `packages/fushi_engine/test/srs/srs_profile_purge_single_test.dart`（并入 / 采用后旧 uid 在
  `sqlite_master` 现查的每张带 `profile_uid` 的表、`…/<uid>` 与 `…/<uid>/…` meta 键里为零，没人引用的 `sync2_deps` 不增；
  调用方 Drift 事务回滚时 purge 一起回滚）；Rust `profile_data.rs` `purge_removes_every_row_of_the_profile_and_keeps_the_other`
  补中间带 uid 的 meta 键断言。
- **备注**：存量库里已经留下的残留：采用留下的会被一次性无主扫描（若还没跑）清掉；已跑过扫描的设备、以及并入留下的
  meta 键 / `sync2_deps` 不在任何清理路径上，本修复不回收（需要的话另做一次性清扫，待拍板）。
