## BUG-4387 · 无主复习数据扫描在 BUG-4292 之前已扫过的库里不再跑，采用 / 并入旧实现的残留永远留下
- **报告**：2026-11-11（内部：BUG-4292 备注「已跑过扫描的设备、以及并入留下的 meta 键 / `sync2_deps` 不在任何清理路径上」）
- **真实性**：✅ 真 bug（沿代码路径 + 新测试在修复前的判定）。
  - 一次性无主扫描 `fushi/lib/src/srs/srs_profile_cleanup.dart` `sweepOrphans`（进 Profile 管理时跑，2026-10-27 c1e3480876e 起）
    记完成标记 `profile_orphan_sweep_v1`（`native/fushi_fsrs/src/store/profile_data.rs` `ORPHAN_SWEEP_KEY`）后不再跑。
  - BUG-4292（0968c54cc82，2026-11-10）之前删一个 uid 有三份实现，其中两份留残留（实测数见 BUG-4292）：
    - 采用 uid（`srs_backup_merge.dart` `_deleteProfileRows`，手抄 10 张 `srs_*` 表）：旧 uid 的 `sync2_ops` / `sync2_self` /
      `sync2_devices` / `sync2_digest_buckets` 等全部 `sync2_*` 行与按 profile 的 `srs_meta` 键留下；
    - 并入（`srs_profile_merge.dart` `_deleteProfile`）：按 `sqlite_master` 原序删致 `sync2_digest_buckets` 残留，
      `sync2_digest/<uid>` 等 meta 键留下，`sync2_deps` 不回收；
    - 删 profile（Rust `profile_purge`）：只漏 uid 在中间的 meta 键（`sync2_device_ext/<uid>/…`、`sync2_retired/<uid>/…`、
      `sync2_head_sig/<uid>/…`），表行删干净。
  - 在 v1 标记写下之后才发生的采用 / 并入，残留的表行让旧 uid 留在 `profile_uids` 里，但扫描已标记完成，永不再扫。
  - 害处：死数据占空间（采用残留含旧 uid 的整条操作日志与身份）；`sync2_self` 有行的残留 uid 会被逐 profile 的一次性
    升级（如 `sync2/mod.rs` `replay_event_copies` / `revoke_copies_of_revoked_events`、`sync2/mvr.rs` `rebuild` 按
    `sync2_self` 枚举 profile）当成活 profile 处理；它们引用的 `sync2_deps` 不被回收。
  - 另：并入做到一半（`profile_merge/<旧 uid>` 标记在、改主库 uid 前后）时，旧 uid 或目标 uid 不在主库 `profiles` 里，
    原扫描会把它们当无主数据删掉（先备份），并入的第二遍就收不到——扫描重跑会放大这个窗口，所以一并修。
- **[x] ① 已修复** —
  - `profile_data.rs` `ORPHAN_SWEEP_KEY` 换成 `profile_orphan_sweep_v2`：扫描（同一套「主库现存 uid」判定、同一个
    `profile_purge`）在每个库上再跑一次；之后照旧只跑一次。不升 schema、不改同步协议。
  - `srs_profile_cleanup.dart` `sweepOrphans`：`profile_merge/<旧 uid>` 标记涉及的旧 uid 与目标 uid 不算无主（标记值读不懂时
    旧 uid 照样保护）；有进行中并入时不记完成标记，下次进来再扫。主库读不出任何 uid 时照旧什么都不删。
  - 第一版不清的两类，跟进里补上（扫描的收尾 `profile_data.rs` `SrsCore::orphan_sweep_done`，一个 savepoint；完成标记
    再换成 `profile_orphan_sweep_v3`，v2 扫过的库再扫一次）：
    - 只剩 meta 键、表里已没有行的 uid（Rust 旧 `profile_purge` 留下的 `…/<uid>/…` 键、并入旧实现没删的
      `sync2_digest/<uid>` 等）。键里的 UUID 段可能是 profile 也可能是设备 ID（`sync2_device_hint/<设备>`、
      `sync2_device_ext/<profile>/<设备>`），所以不按「键里出现的 UUID」找，只认登记过写法的前缀里 profile 所在的那一段
      （`META_PROFILE_LAST` / `META_PROFILE_FIRST`；`sync2_device_hint/` 与并入标记不取），源码扫描测试钉住「内核里每个
      带 `{profile}` 的键前缀都登记过」。主库现存 uid、进行中并入的 uid 不动；「表里没有行」与删除在同一个 savepoint 里判。
      留着的害处：同一 uid 以后被重新用上（重新关联到同一个同步集合）时，残留的 `sync2_retired/<uid>/<设备>` 让投递
      不再等那些设备（`devices.rs` `deps_ready`），残留的设备扩展显示旧名；体积可忽略。
    - 没被任何操作引用的 `sync2_deps`（并入旧实现删 `sync2_ops` 不回收；换身份 `transport.rs` `rotate` 撤出本机操作
      后也会留下）。只占体积、没有行为后果：一行 `sync2_deps` 只经 `sync2_ops.deps` 读到。以前只在扫到至少一个无主
      uid 时随 `profile_purge` 的 GC 回收，现在收尾总是回收一次。
- **[x] ② 已加自动化测试** — `fushi/test/srs/srs_profile_cleanup_test.dart`：v1 已扫过的库里造采用旧实现的残留
  （真实 `SrsDbStore.open` 后按旧表清单删）→ 扫描清干净（每张带 `profile_uid` 的表、按 profile 的 meta 键为零）、活 profile
  逐表行数与 meta 键不变、再扫无变化；进行中并入的两个 uid 一行不少、无关无主 uid 照删、不记完成标记；没有可比的活 uid
  时什么都不删。Rust `profile_data.rs` `profile_uids_lists_every_owner_and_the_sweep_marker` 补「v1 标记不算完成」。
  跟进：`profile_data.rs` 的 `sweep_rest_*`（只剩 meta 键的无主 uid 清掉、活 profile 名下带设备 ID 的键与
  `sync2_device_hint/<设备>` 不动、`keep` 里的 uid 与表里还有行的 uid 不动、孤立 `sync2_deps` 回收而被引用的不动、
  重复调用幂等）、`every_profile_meta_key_prefix_is_classified`（源码扫描）；`srs_profile_cleanup_test.dart` 两条
  （v2 已扫过的库再扫一次清掉两类残留、再扫无变化；进行中并入的目标 uid 只剩 meta 键时不动、不记完成标记）。
- **备注**：扫描对每个无主 uid 照旧先开副本导出 `.fushisrs` 备份再删，残留 uid 也会多一份备份文件（BUG-4292 已记）；
  只剩 meta 键的 uid 没有行可导出，不备份、也不动它的媒体目录。
