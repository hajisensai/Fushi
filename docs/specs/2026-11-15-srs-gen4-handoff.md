# SRS 协议 4 换代：交接说明（2026-11-15）

> 本文是 W1ght 这边 agent 停手时的现场交接，接手方从这里继续。设计以
> [2026-11-11-srs-generation-break.md](2026-11-11-srs-generation-break.md)（已按定案改过，含 §11.5 D 号索引）为准；
> G7–G11 的实施规划见同目录 [2026-11-15-srs-gen4-g7-g11-plan.md](2026-11-15-srs-gen4-g7-g11-plan.md)
> （原在本机 scratchpad，原样拷入；文中「分规划 JSON」「scratchpad」路径只在原机器上有，结论已汇总进正文）。

## 1. 已定的事（不用再问）

- 2026-11-15 所有者对 G7–G11 规划 §4 的 D1–D34 回复「都按你推荐」，全部定案。要点：
  - **两段式合入**：没有调用方的新模块逐个合进 develop（不改线上行为）；接线、删旧代码、换同步格式在集成分支 `pr/srs-gen4-switch` 上做完，**一次推送**进 develop。断代只许一次。
  - **旧版本硬要求放宽**为「数据内容不变 + 旧版本明确拒绝并提示升级」。实测（`tool/srs_old_binary/` 装置，#3420）已发布的 Windows 版本拒开新库时会改 SQLite 头 24–27 / 92–95 两处计数字段，写成已知例外。
  - 封存原位、不改名；保留副本被删时放墓碑库。封存值 39999，新代文件 `srs4.db`，写 `application_id`。
  - d 项：已删卡的 revlog 保留，只进统计 / 日历，不参与排期（#3434 已实现）。
  - 旧 debug 安装包已存档到 prerelease `srs-old-binaries-2026-11`，装置从那里取包。
- 合并授权：W1ght 的 PR 审查后可直接合；其他作者照 CLAUDE.md 先问所有者。

## 2. 本轮已合进 develop

| PR | 内容 |
|---|---|
| #3284 | 写路径第 2～14 步（链底，收拢 #3289…#3385） |
| #3381 | profile 归属 |
| #3391 / #3392 | 写路径 15（内核修订号）/ 16（原始通道 cargo feature） |
| #3409 | windows appSmoke runner 基线修复 |
| #3411 #3413 #3418 #3420 | G 系列前置、gen4_ids、旧版本实测装置 |
| #3430 | 设计稿定案 + 旧包存档 |
| #3429 #3433 #3435 #3431 | G8-2 中继件、G10-1 远程复习版本协商、G8-1 位置命名、G11-1 导出格式 |
| #3434 | d 项：已删卡 revlog 只进统计（BUG-4657，修了 Fushi→Anki→Fushi 往返重复计数） |
| #3424 #3427 #3436 #3440 #3443 | 界面反馈修复、admin 路由遮蔽（BUG-4627）、浏览页 Enter 抢焦点（BUG-4628）、SRS 页面测试改等写入完成信号 |

## 3. 在途（按顺序接）

| 顺序 | PR / 分支 | 现状 | 下一步 |
|---|---|---|---|
| 1 | **#3395 G5a**（读站点改内核读命令、删 Drift 执行器），头 `25af71be856`，base develop | 与 develop **冲突**，所以主 CI 没跑（GitHub 上 dirty 的 PR 不触发 pull_request CI）。已含修复：#3434 新增代码还在用被删的 Drift 执行器，改为新 Rust 读命令 `native_logs_near`。本地 cargo check、fushi_engine / fushi_server analyze 过；要 DLL 的定向测试未跑 | 合 develop → `dart run tool/bug.dart settle --base upstream/develop` → 推 → CI 只剩基线红就合 |
| 2 | **#3396 G5b**（根上 ID 与同步目录名改向内核要，含 G3 #3374），头 `0fc2e458f5c`，**base 仍是 G5a 分支** | 已合入新的 G5a；已删卡派生按 #3434 口径（`uuidV5(defaultDeckId, 'anki-deleted-card/$cid')`，Rust `rules::deleted_anki_card(&Id, i64)`），`git merge-tree` 试合无冲突；4 处测试从 `SrsIds.builtinDefaultDeck` 改为 `SrsKernelIds(uid).defaultDeck`。Rust gen4_ids / golden / 删卡 revlog / ids 守卫的定向测试**跑到一半被停，无结论** | G5a 合后 `gh pr edit 3396 --base develop`，合 develop，重跑上述定向测试，CI 过就合 |
| 3 | **#3399 G4 / G4b**（真实库只读干跑 + 后台预演自检），头 `86300449212`，base develop | 已含最新 develop；本地 Rust 全量 784 passed / 0 failed / 38 ignored，全量 analyze 无问题；修了本 PR 的 file_picker 守卫真红（去掉 `FileType.custom`）。CI 停手时还在跑 | CI 只剩基线红就合 |
| — | **Flutter 3.50 升级 #3400** | 等 1～3 合完再进 develop，免得中途换工具链出伪红 | 1～3 合完后在 #3400 下评论「SRS 链已合完，可以进」 |
| 4 | **#3452 G7-1**（gen4 本机状态表、换代锁 GenLock、打开模式、封存与墓碑库），未合 | 实现已开 PR，**还没经过独立审查**（工作流停在审查前） | 对抗式审查 → 修 → 合（规划 §2.1） |
| 5 | **#3453 G9-1**（读侧按别名类判定，不接线），未合 | 同上未审查。**需所有者拍板**：样本库量出 144 个寄存器（笔记类型 css 1、字段 18、卡 newPos 125）换代后从「有冲突」变成「没冲突」，根因已隔离为写入者归回（设计 §5.3「三处一起换」的预期结果）。PR 建议接受；备选是 G9-2 把这 144 处列进迁移报告的已知差异 | 拍板 → 审查 → 合；与 #3399 只在 `store/gen4/mod.rs` 冲突一行 |
| 6 | **#3451**（BUG-4694：`tool/native_licenses.dart` 在 Windows 上把 git 符号链接许可文件读成别的文本、还删已入库文件），未合 | 未审查 | 审查 → 合 |
| 7 | 分支 **`pr/srs-ffi-op-meta`**（FFI 命令元数据由 Rust 声明），已推到 upstream，**无 PR** | 叠在旧 G5b 上；最后功能提交 `2b46d84b1e6` 标 wip，作者注明「11-13 未提交工作原样提交，未验证」 | 放到切 3.50 之后做。范围：命令性质（是否改投影、是否通道透明、可否不进独占区、回包是否带 `settled` / `localRevision`、输入项标记）由 `store/ops.rs` 声明并生成 Dart `SrsOp` 绑定；删 Dart 的 `kSrsSync2ProjectingOps` / `_kSync2CacheOps` / `kSrsSync2LockFreeOps` 和对应同文守卫；删 `ffsrs_memory_input`（ABI 7）。先 rebase 到合了 G5b 的 develop 再验证 |
| 末 | **#3344**（集成演练草稿） | 永不合 | 全部做完后关掉 |

## 4. 之后的路线（规划 §2）

1. 第一段剩余（无调用方模块，逐个合）：G7-1 → G7-3a（原生写入器 `Native` + `write_salts` + `ingest_settle`）→ G9-3（绑定 / join / adopt_foreign）与 G8-3（媒体清单 + `media_at`，D18 取 HLC 最大者）并行；G9-1 → G9-2（缓存层接规范 ID、按规范 ID 对拍）；再 G7-2、G8-4/5/6、G11-2、G7-3b、G7-4。依赖与文件热点排队见规划 §2.1、§2.3；凡要改 `store/ffi.rs` / `store/ops.rs` 的，等 op-meta 定了再做。
2. 第二段：`pr/srs-gen4-switch` 上接线、删旧、换格式，合并条件见规划 §6。
3. G12 与真机 / 大库 / 服务端真权重验证；旧版本拒开用 `tool/srs_old_binary/` 实测。

## 5. 还要所有者确认的

- **D21（只有协议 1 旧根的位置）**：规划没给推荐，设计稿按 §9 第 4 项写成继续支持，入口改为只读转译、不写 v3 meta，`srsMigrateV1Media` 移植到新库。
- **D16（加密数据跨钥匙转发）**：设计稿写成转发方解密后用目标位置钥匙重新加密、签名沿用作者的（由「签名覆盖明文哈希」推出），G8 实现时再核。
- 设计稿 §9 第 2、9 项及第 15、16 项里几个子项没有 D 号覆盖，写成「按推荐、已随实现落地」，不算所有者签字。
- #3453 的 144 个寄存器判定差异（见上表）。
- BUG-4500（#3424）的「不查词」范围没包含卡片里的链接 / 图片按钮，是否要扩。

## 6. 坑

- develop 上与 SRS 无关的已知红（停手时）：fushi_server `server_data_lock_test` 偶发超时；`guards` 里 reader 测试 `LateInitializationError`。#3372 带进来的那批 format / 单测红已由 #3442 修掉。
- BUG 号经常撞，合并前一律 `bug.dart settle --base upstream/develop`，别手改。
- 叠放 PR 的下层合掉后上层 base 不会自动变，要手动改 base 再合 develop。
- 本机重活走 heavy 租约；Rust 大批测试放 Mac（sccache）跑更快，本机内存紧时后台任务会被停。
- 旧版本实测装置用法：`docs/agent/srs-old-binary-harness.md`。

## 7. 分发器命令对照表（G7-4e，2026-11-16）

协议 3 分发器（`native/fushi_fsrs/src/store/ffi.rs` 的 `sync2_dispatch_op` / `sync2_command` / `local_write_body`，加上
`ffsrs_store_*` C 直出入口）里的每一条命令，与新代（`store/gen4/`，命令层在 `store/gen4/cmd/`）的对应实现。第二段 S1
切分发器时照这张表接线。

- **`store/ops.rs` 在 develop 上不存在**：它只在未合的 `pr/srs-ffi-op-meta` 分支上（§3 第 7 行）。本表按 develop 的
  `ffi.rs` 列全；op-meta 合入后命令性质（投影、通道透明、独占区、回包项）随 `ops.rs` 声明，本表的命令名不变。
- 「协议 3 实现位置」写分发器臂调到的函数；「gen4」列写 `文件:函数`，没有就写「缺」。新代命令一律按**集合号 `col`**
  （S1 用 `Truth::binding_of(profile)` 换算），一条命令一个读快照（`cmd/mod.rs` `snapshot`）或一个写事务（`cmd/writes.rs`
  `write`）。
- 「归属」：规划（`2026-11-15-srs-gen4-g7-g11-plan.md` §2.2）点名了的照写；没点名的写「建议」并说明理由。学习 / 出卡
  归 G7-4c，`browse_*` 归 G7-4d（在做，本表只标注）。
- 读 / 写：「读」= 只读；「写」= 写库（真相、派生或本机状态）；「无」= 不碰库的纯计算。

### 7.1 库级（不针对单个 profile，`sync2_dispatch_op` 前半）

| 命令名 | 读/写 | 协议 3 实现位置 | gen4 实现位置 | 归属 / 备注 |
|---|---|---|---|---|
| `profile_uids` | 读 | `profile_data.rs` `SrsCore::profile_uids` | 缺 | 建议 G9-5（收薄 profile 关联）；新代等价物是 `collections` 全表 |
| `read_lib` | 读 | `reads.rs` `run_lib` | `cmd/reads.rs:run_lib` | G7-4 已有；S1 接线 |
| `orphan_sweep_done` | 写 | `profile_data.rs` | 缺 | G9-5（旧 profile 孤儿清扫，换代后随并入代码删） |
| `profile_merge_mark` / `profile_merge_commit` | 写 | `profile_data.rs` | 缺 | G9-5（D23：迁移前用旧代码做完并入，新代不移植） |
| `meta_set_edit` | 写 | `profile_data.rs` `meta_set_edit` | 缺 | G9-5 / G9-6（退役设备 / uid 集合，偏好与持久化 ID 归一） |
| `wal_checkpoint` | 写 | `store/mod.rs` `SrsCore::wal_checkpoint` | 缺 | S1（连接层：新代文件同样是 WAL，命令外壳照搬） |
| `gen4_rehearse` / `gen4_rehearsal_report` / `gen4_rehearse_cancel` | 读（写临时文件） | `gen4/dryrun.rs` | `gen4/dryrun.rs`（本来就是新代） | 换代后无用，G7-6 删 |
| `bulk_cache` | 写 | `store/mod.rs` `bulk_begin` / `bulk_end`（大批写入期间暂缓缓存刷新） | 缺（新代大批写入走 `ingest.rs:ingest_settle(Settle::Rebuild)`） | S1：决定保留开关还是删入口 |
| `ingest_yield` | 无 | `sync2/transport.rs` `sync2_ingest_yield`（收段让路标记） | 缺 | G8-7（收段调度） |
| `refresh_keys` | 读 | `refresh.rs` `refresh_keys` | 缺（派生层随写入维护，无「待刷新」集合） | S1：新代不需要，接线时删 |

### 7.2 缓存 / 本机状态（`sync2_dispatch_op` 后半，分发器自己处理的特殊臂）

| 命令名 | 读/写 | 协议 3 实现位置 | gen4 实现位置 | 归属 / 备注 |
|---|---|---|---|---|
| `cache_config_set` | 写 | `cache_rev.rs` `upgrade` | 部分：`truth.rs:set_derive_cfg`（`derive_cfg` 存配置）+ `ingest.rs:ingest_settle(Rebuild)` | S1：命令外壳缺；配置变了要按 `Settle::Rebuild` 重建 |
| `refresh_caches` / `rebuild_caches` | 写 | `caches.rs` `refresh` / `rebuild` | 部分：`ingest.rs:ingest_settle` / `derive.rs:Index::rebuild_all` | S1 |
| `backfill_dupe_norms` / `backfill_tag_sources` / `backfill_source_keys` | 写 | `caches.rs` | 不需要（新代缓存层建行时就算全列） | G7-6 删 |
| `edits_rewrite_repr` | 写 | `repr_rewrite.rs` | 不需要（存量样式去重是协议 3 存储表示的事） | G7-6 删 |
| `media_gc_queue` / `media_gc_collect` | 写 | `media_gc.rs` | 缺 | 建议 S1：待回收集合是本机状态键、核对存活引用读缓存层，形状不变；新代存哪（`srs_meta` 键）要定 |
| `media_live_refs` | 读 | `media_gc.rs` `live_refs` | 缺 | 同上 |
| `ingest_commit` | 写 | `sync2/transport.rs` | 缺（新代收段 `receive.rs` 是存储层） | G8-7 |

### 7.3 写命令（`local_write_body`，`LOCAL_WRITE_OPS`）

| 命令名 | 读/写 | 协议 3 实现位置 | gen4 实现位置 | 归属 / 备注 |
|---|---|---|---|---|
| `apply` | 写 | `sync2/mod.rs` `apply_local_on`（先 `changing::drop_noops`） | `cmd/writes.rs:apply` | G7-3b 已有；S1 接线 |
| `import_drafts` | 写 | `sync2/mod.rs` `import_drafts_on` | `cmd/writes.rs:import_drafts` | 同上 |
| `change` | 写 | `sync2/change.rs` `change_on` | `cmd/writes_intent.rs:change` | 同上 |
| `note_fields_if` | 写 | `sync2/note_fields_if.rs` `note_fields_if_on` | `cmd/writes_intent.rs:note_fields_if` | 同上 |
| `merge_notes` | 写 | `sync2/merge_notes.rs` | `cmd/writes_intent.rs:merge_notes` | 同上 |
| `sched` | 写 | `sync2/sched_local.rs` | `cmd/writes_intent.rs:sched` | 同上 |
| `deck_delete` | 写 | `sync2/deck_delete.rs` | `cmd/writes_intent.rs:deck_delete` | 同上 |
| `resolve` | 写 | `sync2/mod.rs` `resolve_bodies` | `cmd/writes.rs:resolve` | 同上；冲突 ID 与 `cmd/center.rs:conflicts` 同一公式 |
| `purge` | 写 | `sync2/mod.rs` `purge_bodies` | `cmd/writes.rs:purge` | 同上 |
| `checkpoint` | 写 | `sync2/mod.rs` `append_on` | `cmd/writes.rs:checkpoint` | 同上 |
| `restore` | 写 | `sync2/timeline.rs` `restore_on` | `cmd/writes_restore.rs:restore` | 同上 |
| `trust` | 写 | `sync2/trust.rs` `trust_on` | `cmd/writes_local.rs:trust` | 同上 |
| `dedup` | 写 | `sync2/dedup.rs` | `cmd/writes_local.rs:dedup`（换代后恒 `{"done": true}`） | 同上 |
| `digest_heal` | 写 | `sync2/heal.rs` | `cmd/writes_local.rs:digest_heal`（整集合派生重建） | 同上 |
| `import` | 写 | `sync2/transport.rs` `import_on` | 部分：`gen4/import.rs:import_ops` / `import_backup`（存储层） | G11-3（`.fushisrs` v2 接线） |
| `retire` | 写 | `sync2/devices.rs` `retire` | 缺（停用标记不迁移，`carry.rs` 文件头） | G8-7：连同 `status` 设备行的 `retired` 状态一起接 |

### 7.4 读命令与其余（`sync2_command`）

| 命令名 | 读/写 | 协议 3 实现位置 | gen4 实现位置 | 归属 / 备注 |
|---|---|---|---|---|
| `identity` | 写 | `sync2/mod.rs` `sync2_identity` + `legacy_clock.rs` | 部分：`truth.rs:create_self` / `self_identity` | 建议 G9-4（身份命令）；`legacyWriter` / `channel` 两项新代没有对应物 |
| `channel_settle` | 写 | `sync2/channel.rs` | 不需要（新代没有收段通道，收段即落真相） | S1 删 |
| `migrate` | 写 | `sync2/mod.rs` `sync2_migrate`（v1→v2） | 不需要（`gen4/migrate.rs` 是协议 3→4 的另一件事） | G7-6 删 |
| `replay_all` | 写 | `sync2/mod.rs` | 不需要（派生层是真相的纯函数） | G7-6 删 |
| `study` | 读 | `study.rs` `SrsCore::study` | 缺 | **G7-4c**（学习 / 出卡） |
| `preview` | 读 | `sync2/mod.rs` `sync2_preview`（计算与回包抽成 `preview_of`，连接级 `preview_on`） | `cmd/preview.rs:preview` | **G7-4f 已补**。牌组树 / 默认牌组 / 卡的有效牌组都是 `cmd/mod.rs` 的只读函数（`deck_tree` / `default_deck` / `card_deck`；`Session::card_deck` 改为先收尾再调它）；归属组日志与笔记取 `cache.rs:Index::group`（写命令 `sched` 同一份）。卡与笔记先归一，回包 ID 是规范 ID。已知差别：协议 3 `group_of` 读链尾日志不带 `ORDER BY`（`idx_srs_review_logs_card` 上的 rowid 序 = 落库序），「链尾最后一条记了笔记的」在新代按 (发生时刻, 操作主键) 取；只在链尾晚到的旧日志记了另一个笔记时两边可能不同，新代的序与时间一致，不改 |
| `read` | 读 | `reads.rs` `run`（27 个查询名） | `cmd/reads.rs:run`（同 27 个，逐名核过） | G7-4 已有；S1 接线 |
| `card_columns` | 读 | `bulk.rs` `card_columns` | `cmd/columns.rs:card_columns` | G7-4b 已有 |
| `anki_resolve` / `anki_notes_info` | 读 | `bulk.rs` | `cmd/columns.rs:anki_resolve` / `anki_notes_info` | G7-4b 已有；G7-4g 成员号改按缓存层反查表 `anki_members` 点查，从没出现在操作里的带盐卡的号也查得到（schema 40019） |
| `stats_report` / `stats_recall` / `stats_rows` | 读 | `stats.rs` | `cmd/stats.rs:stats_report` / `stats_recall` / `stats_rows` | G7-4b 已有；原料缓存（协议 3 `StatsCache`）归 S1 命令层，未命中时调 `cmd/stats.rs:snapshot_of` |
| `stats_release` | 无 | `stats.rs` `stats_release` | 缺（随缓存） | S1 |
| `browse_query` / `browse_rows` / `browse_ids` / `browse_targets` / `browse_close` / `browse_stats` / `browse_counts` / `browse_sources` / `anki_find` / `anki_dupes` / `anki_tags` | 读（常驻会话） | `browse.rs` `SrsCore::browse` | 缺 | **G7-4d** |
| `lineages` | 读 | `caches.rs` `lineage_ids` | `cmd/lineage.rs:lineages` | G7-4b 已有 |
| `history` | 读 | `sync2/timeline.rs` `sync2_history` | `cmd/history.rs:history` | G7-4 已有 |
| `entity_views` | 读 | （协议 3 没有） | `cmd/views.rs:entity_views` | G7-4 已有；G10-2 远程复习 V2 用 |
| `conflicts` | 读 | `sync2/mod.rs` `sync2_conflicts` | `cmd/center.rs:conflicts` | **G7-4e 已补**；S1 接线 |
| `checkpoints` | 读 | `sync2/timeline.rs` `sync2_checkpoints` | `cmd/center.rs:checkpoints` | **G7-4e 已补**（真相层种类 6 操作 + 迁移照搬的 `checkpoints` 表，部分索引 `ops_checkpoint`，schema 40017） |
| `undo_check` | 读 | `sync2/undo_check.rs` | `cmd/center.rs:undo_check` | **G7-4e 已补** |
| `plan_restore` | 读 | `sync2/timeline.rs` `sync2_plan_restore` | `cmd/writes_restore.rs:plan_restore` | G7-3b 已有 |
| `binding_get` | 读 | `binding.rs` `binding_get` | `cmd/profile.rs:binding_get` | **G7-4e 已补** |
| `binding_set` | 写 | `binding.rs` `binding_set` | 部分：`truth.rs:settle_binding`（存储层） | G9-4（规划 §1.6：可能改绑定的命令提交后发 `binding_changed`） |
| `profile_footprint` | 读 | `profile_data.rs` `profile_footprint` | `cmd/profile.rs:profile_footprint` | **G7-4e 已补**（`rows` 只保证「是否为 0」与协议 3 一致） |
| `profile_purge` | 写 | `profile_data.rs` `profile_purge` | 缺 | 建议 G9-5（删一个集合 = 删 `collections` 行与该集合的设备、派生、本机状态；与并入收薄同一处） |
| `status` | 读 | `sync2/transport.rs` `sync2_status` + `devices.rs` `status_extras` | `cmd/writes_local.rs:status` | G7-3b 已有；G7-4e 补设备行 `gap` / `blocking`（`op_wait`）与 `state` 的 `missing` / `upgrade`；`retired` 归 G8-7（随 `retire`）；`seenAt` / `warning` / `frozen` / `digestMismatch` 仍是占位值，归 G8-7 |
| `device_info` / `device_hint` | 写 | `sync2/devices.rs` | `cmd/writes_local.rs:device_info` / `device_hint` | G7-3b 已有 |
| `outbox` / `outbox_ack` / `head` / `plan` / `relay_outbox` / `relay_ack` / `obsolete` / `obsolete_former` / `obsolete_ack` | 读写 | `sync2/transport.rs`、`relay.rs` | 部分：`gen4/sync_state.rs`（`loc_heads` / `relay_out` / `oldroot_fp`）、`gen4/oldroot.rs`、`gen4/compact.rs`（存储层） | G8-7（同步一轮 `g4_*` + 调度） |
| `ingest` / `ingest_begin` / `ingest_batch` / `ingest_prepare` / `ingest_end` / `ingest_finish` / `replay_pending` | 写 | `sync2/transport.rs`、`channel.rs` | 部分：`gen4/receive.rs:Receiver`（`native` / `heritage` / `legacy` / `finish`）+ `ingest.rs:ingest_settle` | G8-7 |
| `rotate` | 写 | `sync2/transport.rs` `sync2_rotate` | 部分：`gen4/fork.rs:rotate_on_fork` | G8-6 / G8-7（规划：`Truth::rotate_identity` 归 G8-6） |
| `export` | 读 | `sync2/transport.rs` `sync2_export` | 部分：`gen4/export.rs:export_ops` | G11-3 |
| `digest` / `digest_buckets` | 读 | `sync2/transport.rs` `sync2_digest` / `sync2_digest_buckets` | 部分：`gen4/digest.rs:Index::digest` / `digest_buckets` | G8-7（随 head 发） |
| `legacy_dots` | 读 | `sync2/mod.rs` | 不需要（旧 v1 dot，承袭日志自带） | G7-6 删 |
| `local_state` / `local_state_ensure` / `local_anchor` | 读 / 写 | `local_state.rs` | 缺 | 建议 S1（内核持有的本机状态行：修订号、校时锚点；协议 3 存 `srs_meta`，新代沿用 `srs_meta` 键即可） |
| `location_sealed` / `location_seal` | 读 / 写 | `sync2/sealed.rs` | 部分：`loc_state` 表（G7-1）、迁移已灌（`carry.rs`），读写 API 缺 | G8-7 |
| `media_known` / `media_record` / `media_hash` / `media_scan` / `media_landed` / `media_bind_unbound` / `media_doomed` | 读写 | `sync2/media*.rs` | 部分：`gen4/media.rs`（`known` / `record` / `ingest` / …，存储层） | G8-7（G8-3 存储层已合） |
| `seal` / `open` / `open_v1` / `seal_file` / `open_file` / `derive_key` | 无 | `crate::sync2::media_seal` / `keys` | 不需要新实现（纯加解密，不碰库） | S1 原样接（与库代无关） |

### 7.5 C 直出入口（`ffsrs_store_*`）

| 入口 | 读/写 | 协议 3 实现位置 | gen4 实现位置 | 归属 / 备注 |
|---|---|---|---|---|
| `ffsrs_store_open` / `ffsrs_store_close` | — | `store/mod.rs` `SrsCore` | `gen4/files.rs:open_gen4`（G7-1 的 C 入口另有） | S1（规划：删 `ffsrs_store_open`） |
| `ffsrs_store_snapshot` / `ffsrs_store_debug_query` / `ffsrs_store_exec` / `ffsrs_store_exec_batch` / `ffsrs_store_in_transaction` / `ffsrs_store_read_concurrency` / `ffsrs_store_diag_counts` | 读写 | `ffi.rs` 原始通道 / 诊断 | 缺 | S1（原始通道 cargo feature，#3392；新代只留诊断需要的） |
| `ffsrs_store_legacy_state` / `_begin` / `_page` / `_commit` / `_abort` / `_mark_none` | 写 | `store/mod.rs` 旧库搬迁 | 不需要（协议 1 旧库走 D21 只读转译） | G7-6 删（或 D21 定后改走 `gen4/import.rs:import_v1`） |
| `ffsrs_store_history_states` / `ffsrs_store_stat_projection` | 读 | `store/mod.rs` `SrsCore::history_states` / `stat_projection`（计算抽成 `history_states_of` / `stat_projection_of`） | `cmd/training.rs:history_states` / `stat_projection` | **G7-4f 已补**。日志取 `cache.rs:Index::replayed_logs`（`replayed_card_logs` 的批量版，按连通分量重放），一份历史里同一张规范卡只算一次。S1：C 入口照旧解码两列页，按集合号调这里 |
| `ffsrs_store_optimizer_items` / `ffsrs_store_calibration_items` / `ffsrs_store_rwkv_rows` / `ffsrs_store_rwkv_log_tail` | 读 | `store/projections.rs` `SrsCore::optimizer_items` / `calibration_items` / `rwkv_cards` / `rwkv_replay` / `rwkv_log_tail`（计算抽成 `*_of` / `ReplayScan` / `rwkv_log_tail_of`，取数抽成连接级 `training_groups_on` / `rwkv_scan_on` / `rwkv_log_tail_on`） | `cmd/training.rs:optimizer_items` / `calibration_items` / `rwkv_cards`（`rwkv_rows` 模式 0）/ `rwkv_replay`（模式 1，profile 换成集合号）/ `rwkv_log_tail` | **G7-4f 已补**，输出逐字节同协议 3。**游标换了**：协议 3 的 rowid（本机落库序）在新代是本机状态表 `log_seq`（schema 40018，`derive.rs` 随 `log_ix` 逐条维护、整层重建保留序号）——操作主键 `k` = 设备下标 × 2^40 + seq，不随落库单调，不能当游标。指纹按日志操作数；尾巴每个规范日志 ID 只出代表。**落库序从 `derive.rs:SEQ_BASE`（2^40）+ 1 起**：RWKV 状态机（`fushi_rwkv` `sched/machine.rs`）判主快照 / 检查点只看 (行数, 最大 rowid)、没有库代标记，若两代都从 1 起编号，协议 3 留下的检查点会因条数相同通过 `count - tailRows` 核对（两边同一前缀圈进的日志并不相同），RWKV 状态静默缺评分；起点错开后两代游标空间不相交，旧主快照指纹必不相等、旧检查点必被拒，第一次对齐必然全量重放（`training_tests.rs:protocol_3_checkpoints_and_fingerprints_never_fit_the_new_library`），S1 换代**不必**删 RWKV 快照目录。`rwkv_log_tail` 带行时每行尾巴 5～8 次点查，只适合增量尾巴（调用方传上次的最大序号）|
| `ffsrs_set_temp_dir` | — | `ffi.rs` | 不需要（与库代无关） | S1 原样保留 |
| `ffsrs_store_sync2` | — | `ffi.rs` 分发器入口 | — | S1：本表全部命令的入口 |

### 7.6 带盐成员上被扣住的删除，`resolve` 之后扣不掉（**已修**，G7-4g，按方案 1）

原缺口（G7-4e 复核补测试时发现）：删除落在别名类的某个带盐成员上、被并发修改扣住时，`resolve` 写下的恢复 / 再删
经 `Session::land` → `canon_body` 换成了**规范号**，而 `weigh.rs` `weigh_holds` 只按**原值成员**的 `deleted` 寄存器
判「已被见过它的写入盖掉」，于是 `hold_ix` 那一行一直在、冲突中心反复列出同一条冲突；`others` 也只数同一成员上的
并发修改。

修法（方案 1，扣住按类判）：`weigh_holds` 一次看一个别名类（`alias.rs` `Index::members`），「被见过它的写入盖掉」取
全类成员的 `deleted`，`others_of` 取全类成员上的并发操作；状态与 `hold_ix` 的行仍按删除落的原值成员存。为此收尾
顺序改成「清除 → 盐 / 别名表 → 扣住 / 标签 / 媒体 → 寄存器判定 → …」（`derive.rs` `settle` / `rebuild_all`；别名表只看
清除状态，不看扣住与判定），别名表整表重算时总是记下变了的行（`alias_moves`，原先只有物化了缓存的集合才记），
它们牵动的类在同一次收尾里重看——别名迟到（先扣住、后来才并类，或清除让证据变少、类拆开，设计 §10 第 19 条）
时逐条维护与重建相同。测试：`cmd/center_tests.rs` `conflicts_name_a_salted_member_by_its_class`（裁决后消失、
类内别的成员上的并发修改计入 `others`、重建相同）、`a_late_alias_holds_the_delete_by_its_class_and_rebuilds_the_same`
（盐后到 / 先到两种到达顺序结果相同、每步重建相同）。

复核补（G7-4g 复核）：变动牵动的类只重看类里任一成员（不只是变动的那个——删除可能落在类里没变动的成员上）有
`deleted` 写入或 `hold_ix` 行的种类；变动的 ID 多于缓存层的 `MOVES_IN_PLACE`（新盐一到成千上万个带盐 ID 一起换规范
ID）时与重建一样看全部有删除的实体，不逐类点查。测试 `a_late_member_holds_a_delete_on_a_member_that_did_not_move`、
`a_late_alias_moving_many_ids_still_holds_the_delete`（增量 == 重建）。

清除（Purge）与作者不可信仍按原值实体判；一条 Purge 要不要清掉整个类仍归 S1 / G7 接线定（`class.rs` 文件头
「没有并起来的」）。
