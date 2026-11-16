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

| 命令名 | 读/写 | 协议 3 实现位置 | gen4 实现位置 | 归属 / 备注 | S1 后状态 |
|---|---|---|---|---|---|
| `profile_uids` | 读 | `profile_data.rs` `SrsCore::profile_uids` | 缺 | 建议 G9-5（收薄 profile 关联）；新代等价物是 `collections` 全表 | 未接线（报 `gen4: not wired yet`），归 G9-5 |
| `read_lib` | 读 | `reads.rs` `run_lib` | `cmd/reads.rs:run_lib` | G7-4 已有；S1 接线 | 已接 |
| `orphan_sweep_done` | 写 | `profile_data.rs` | 缺 | G9-5（旧 profile 孤儿清扫，换代后随并入代码删） | 未接线（报 `gen4: not wired yet`），归 G9-5 |
| `profile_merge_mark` / `profile_merge_commit` | 写 | `profile_data.rs` | 缺 | G9-5（D23：迁移前用旧代码做完并入，新代不移植） | 未接线（报 `gen4: not wired yet`），归 G9-5 |
| `meta_set_edit` | 写 | `profile_data.rs` `meta_set_edit` | 缺 | G9-5 / G9-6（退役设备 / uid 集合，偏好与持久化 ID 归一） | 未接线（报 `gen4: not wired yet`），归 G9-5 |
| `wal_checkpoint` | 写 | `store/mod.rs` `SrsCore::wal_checkpoint` | 缺 | S1（连接层：新代文件同样是 WAL，命令外壳照搬） | 已接 |
| `gen4_rehearse` / `gen4_rehearsal_report` / `gen4_rehearse_cancel` | 读（写临时文件） | `gen4/dryrun.rs` | `gen4/dryrun.rs`（本来就是新代） | 换代后无用，G7-6 删 | 已删（报 `gen4: removed`）；实现 G7-6 删 |
| `bulk_cache` | 写 | `store/mod.rs` `bulk_begin` / `bulk_end`（大批写入期间暂缓缓存刷新） | 缺（新代大批写入走 `ingest.rs:ingest_settle(Settle::Rebuild)`） | S1：决定保留开关还是删入口 | 保留，已接（嵌套深度 + 放宽 WAL 自动检查点） |
| `ingest_yield` | 无 | `sync2/transport.rs` `sync2_ingest_yield`（收段让路标记） | 缺 | G8-7（收段调度） | 未接线（报 `gen4: not wired yet`），归 G8-7 |
| `refresh_keys` | 读 | `refresh.rs` `refresh_keys` | 缺（派生层随写入维护，无「待刷新」集合） | S1：新代不需要，接线时删 | 已删（报 `gen4: removed`） |

### 7.2 缓存 / 本机状态（`sync2_dispatch_op` 后半，分发器自己处理的特殊臂）

| 命令名 | 读/写 | 协议 3 实现位置 | gen4 实现位置 | 归属 / 备注 | S1 后状态 |
|---|---|---|---|---|---|
| `cache_config_set` | 写 | `cache_rev.rs` `upgrade` | 部分：`truth.rs:set_derive_cfg`（`derive_cfg` 存配置）+ `ingest.rs:ingest_settle(Rebuild)` | S1：命令外壳缺；配置变了要按 `Settle::Rebuild` 重建 | 已接；回包改成 `{changed, settled?}` |
| `refresh_caches` / `rebuild_caches` | 写 | `caches.rs` `refresh` / `rebuild` | 部分：`ingest.rs:ingest_settle` / `derive.rs:Index::rebuild_all` | S1 | 已接（`Settle::Incremental` / `Rebuild`），回包 `{settled}` |
| `backfill_dupe_norms` / `backfill_tag_sources` / `backfill_source_keys` | 写 | `caches.rs` | 不需要（新代缓存层建行时就算全列） | G7-6 删 | 已删（报 `gen4: removed`）；实现 G7-6 删 |
| `edits_rewrite_repr` | 写 | `repr_rewrite.rs` | 不需要（存量样式去重是协议 3 存储表示的事） | G7-6 删 | 已删（报 `gen4: removed`）；实现 G7-6 删 |
| `media_gc_queue` / `media_gc_collect` | 写 | `media_gc.rs` | 缺 | 建议 S1：待回收集合是本机状态键、核对存活引用读缓存层，形状不变；新代存哪（`srs_meta` 键）要定 | 未接线（报 `gen4: not wired yet`），归 S1 后续（媒体回收） |
| `media_live_refs` | 读 | `media_gc.rs` `live_refs` | 缺 | 同上 | 未接线（报 `gen4: not wired yet`），归 S1 后续（媒体回收） |
| `ingest_commit` | 写 | `sync2/transport.rs` | 缺（新代收段 `receive.rs` 是存储层） | G8-7 | 未接线（报 `gen4: not wired yet`），归 G8-7 |

### 7.3 写命令（`local_write_body`，`LOCAL_WRITE_OPS`）

| 命令名 | 读/写 | 协议 3 实现位置 | gen4 实现位置 | 归属 / 备注 | S1 后状态 |
|---|---|---|---|---|---|
| `apply` | 写 | `sync2/mod.rs` `apply_local_on`（先 `changing::drop_noops`） | `cmd/writes.rs:apply` | G7-3b 已有；S1 接线 | 已接 |
| `import_drafts` | 写 | `sync2/mod.rs` `import_drafts_on` | `cmd/writes.rs:import_drafts` | 同上 | 已接 |
| `change` | 写 | `sync2/change.rs` `change_on` | `cmd/writes_intent.rs:change` | 同上 | 已接 |
| `note_fields_if` | 写 | `sync2/note_fields_if.rs` `note_fields_if_on` | `cmd/writes_intent.rs:note_fields_if` | 同上 | 已接 |
| `merge_notes` | 写 | `sync2/merge_notes.rs` | `cmd/writes_intent.rs:merge_notes` | 同上 | 已接 |
| `sched` | 写 | `sync2/sched_local.rs` | `cmd/writes_intent.rs:sched` | 同上 | 已接 |
| `deck_delete` | 写 | `sync2/deck_delete.rs` | `cmd/writes_intent.rs:deck_delete` | 同上 | 已接 |
| `resolve` | 写 | `sync2/mod.rs` `resolve_bodies` | `cmd/writes.rs:resolve` | 同上；冲突 ID 与 `cmd/center.rs:conflicts` 同一公式 | 已接 |
| `purge` | 写 | `sync2/mod.rs` `purge_bodies` | `cmd/writes.rs:purge` | 同上 | 已接 |
| `checkpoint` | 写 | `sync2/mod.rs` `append_on` | `cmd/writes.rs:checkpoint` | 同上 | 已接 |
| `restore` | 写 | `sync2/timeline.rs` `restore_on` | `cmd/writes_restore.rs:restore` | 同上 | 已接 |
| `trust` | 写 | `sync2/trust.rs` `trust_on` | `cmd/writes_local.rs:trust` | 同上 | 已接 |
| `dedup` | 写 | `sync2/dedup.rs` | `cmd/writes_local.rs:dedup`（换代后恒 `{"done": true}`） | 同上 | 已接 |
| `digest_heal` | 写 | `sync2/heal.rs` | `cmd/writes_local.rs:digest_heal`（整集合派生重建） | 同上 | 已接 |
| `import` | 写 | `sync2/transport.rs` `import_on` | 部分：`gen4/import.rs:import_ops` / `import_backup`（存储层） | G11-3（`.fushisrs` v2 接线） | 未接线（报 `gen4: not wired yet`），归 G11-3 |
| `retire` | 写 | `sync2/devices.rs` `retire` | 缺（停用标记不迁移，`carry.rs` 文件头） | G8-7：连同 `status` 设备行的 `retired` 状态一起接 | 未接线（报 `gen4: not wired yet`），归 G8-7 |

### 7.4 读命令与其余（`sync2_command`）

| 命令名 | 读/写 | 协议 3 实现位置 | gen4 实现位置 | 归属 / 备注 | S1 后状态 |
|---|---|---|---|---|---|
| `identity` | 写 | `sync2/mod.rs` `sync2_identity` + `legacy_clock.rs` | 部分：`truth.rs:create_self` / `self_identity` | 建议 G9-4（身份命令）；`legacyWriter` / `channel` 两项新代没有对应物 | 未接线（报 `gen4: not wired yet`），归 G9-4 |
| `channel_settle` | 写 | `sync2/channel.rs` | 不需要（新代没有收段通道，收段即落真相） | S1 删 | 已删（报 `gen4: removed`） |
| `migrate` | 写 | `sync2/mod.rs` `sync2_migrate`（v1→v2） | 不需要（`gen4/migrate.rs` 是协议 3→4 的另一件事） | G7-6 删 | 已删（报 `gen4: removed`）；实现 G7-6 删 |
| `replay_all` | 写 | `sync2/mod.rs` | 不需要（派生层是真相的纯函数） | G7-6 删 | 已删（报 `gen4: removed`）；实现 G7-6 删 |
| `study` | 读 | `study.rs` `SrsCore::study` | 缺 | **G7-4c**（学习 / 出卡） | 已接（每条命令一个读快照现排，不常驻） |
| `preview` | 读 | `sync2/mod.rs` `sync2_preview` | 缺 | **G7-4c**（评分预览在作答路径上）。要先把 `cmd/writes.rs` 里 `Session` 的 `deck_tree` / `default_deck` / `card_deck` 抽成只读可用的函数（`study` 的牌组计数同样要），与 `study` 一个 PR 做，避免两处各改一遍 `writes.rs`。**待协调方确认 G7-4c 接收**（任务书原把它列在 G7-4e；G7-4c 不收就另派） | 未接线（报 `gen4: not wired yet`），归 G7-4f |
| `read` | 读 | `reads.rs` `run`（27 个查询名） | `cmd/reads.rs:run`（同 27 个，逐名核过） | G7-4 已有；S1 接线 | 已接 |
| `card_columns` | 读 | `bulk.rs` `card_columns` | `cmd/columns.rs:card_columns` | G7-4b 已有 | 已接 |
| `anki_resolve` / `anki_notes_info` | 读 | `bulk.rs` | `cmd/columns.rs:anki_resolve` / `anki_notes_info` | G7-4b 已有 | 已接 |
| `stats_report` / `stats_recall` / `stats_rows` | 读 | `stats.rs` | `cmd/stats.rs:stats_report` / `stats_recall` / `stats_rows` | G7-4b 已有；原料缓存（协议 3 `StatsCache`）归 S1 命令层，未命中时调 `cmd/stats.rs:snapshot_of` | 已接 |
| `stats_release` | 无 | `stats.rs` `stats_release` | 缺（随缓存） | S1 | 已接（丢命令层原料缓存） |
| `browse_query` / `browse_rows` / `browse_ids` / `browse_targets` / `browse_close` / `browse_stats` / `browse_counts` / `browse_sources` / `anki_find` / `anki_dupes` / `anki_tags` | 读（常驻会话） | `browse.rs` `SrsCore::browse` | 缺 | **G7-4d** | 已接（会话在命令层，每库一把锁） |
| `lineages` | 读 | `caches.rs` `lineage_ids` | `cmd/lineage.rs:lineages` | G7-4b 已有 | 已接 |
| `history` | 读 | `sync2/timeline.rs` `sync2_history` | `cmd/history.rs:history` | G7-4 已有 | 已接 |
| `entity_views` | 读 | （协议 3 没有） | `cmd/views.rs:entity_views` | G7-4 已有；G10-2 远程复习 V2 用 | 未接（协议 3 没有；线上形状归 G10-2） |
| `conflicts` | 读 | `sync2/mod.rs` `sync2_conflicts` | `cmd/center.rs:conflicts` | **G7-4e 已补**；S1 接线 | 已接 |
| `checkpoints` | 读 | `sync2/timeline.rs` `sync2_checkpoints` | `cmd/center.rs:checkpoints` | **G7-4e 已补**（真相层种类 6 操作 + 迁移照搬的 `checkpoints` 表，部分索引 `ops_checkpoint`，schema 40017） | 已接 |
| `undo_check` | 读 | `sync2/undo_check.rs` | `cmd/center.rs:undo_check` | **G7-4e 已补** | 已接 |
| `plan_restore` | 读 | `sync2/timeline.rs` `sync2_plan_restore` | `cmd/writes_restore.rs:plan_restore` | G7-3b 已有 | 已接 |
| `binding_get` | 读 | `binding.rs` `binding_get` | `cmd/profile.rs:binding_get` | **G7-4e 已补** | 已接 |
| `binding_set` | 写 | `binding.rs` `binding_set` | 部分：`truth.rs:settle_binding`（存储层） | G9-4（规划 §1.6：可能改绑定的命令提交后发 `binding_changed`） | 未接线（报 `gen4: not wired yet`），归 G9-4 |
| `profile_footprint` | 读 | `profile_data.rs` `profile_footprint` | `cmd/profile.rs:profile_footprint` | **G7-4e 已补**（`rows` 只保证「是否为 0」与协议 3 一致） | 已接 |
| `profile_purge` | 写 | `profile_data.rs` `profile_purge` | 缺 | 建议 G9-5（删一个集合 = 删 `collections` 行与该集合的设备、派生、本机状态；与并入收薄同一处） | 未接线（报 `gen4: not wired yet`），归 G9-5 |
| `status` | 读 | `sync2/transport.rs` `sync2_status` + `devices.rs` `status_extras` | `cmd/writes_local.rs:status` | G7-3b 已有；G7-4e 补设备行 `gap` / `blocking`（`op_wait`）与 `state` 的 `missing` / `upgrade`；`retired` 归 G8-7（随 `retire`）；`seenAt` / `warning` / `frozen` / `digestMismatch` 仍是占位值，归 G8-7 | 已接 |
| `device_info` / `device_hint` | 写 | `sync2/devices.rs` | `cmd/writes_local.rs:device_info` / `device_hint` | G7-3b 已有 | 已接 |
| `outbox` / `outbox_ack` / `head` / `plan` / `relay_outbox` / `relay_ack` / `obsolete` / `obsolete_former` / `obsolete_ack` | 读写 | `sync2/transport.rs`、`relay.rs` | 部分：`gen4/sync_state.rs`（`loc_heads` / `relay_out` / `oldroot_fp`）、`gen4/oldroot.rs`、`gen4/compact.rs`（存储层） | G8-7（同步一轮 `g4_*` + 调度） | 未接线（报 `gen4: not wired yet`），归 G8-7 |
| `ingest` / `ingest_begin` / `ingest_batch` / `ingest_prepare` / `ingest_end` / `ingest_finish` / `replay_pending` | 写 | `sync2/transport.rs`、`channel.rs` | 部分：`gen4/receive.rs:Receiver`（`native` / `heritage` / `legacy` / `finish`）+ `ingest.rs:ingest_settle` | G8-7 | 未接线（报 `gen4: not wired yet`），归 G8-7 |
| `rotate` | 写 | `sync2/transport.rs` `sync2_rotate` | 部分：`gen4/fork.rs:rotate_on_fork` | G8-6 / G8-7（规划：`Truth::rotate_identity` 归 G8-6） | 未接线（报 `gen4: not wired yet`），归 G8-7 |
| `export` | 读 | `sync2/transport.rs` `sync2_export` | 部分：`gen4/export.rs:export_ops` | G11-3 | 未接线（报 `gen4: not wired yet`），归 G11-3 |
| `digest` / `digest_buckets` | 读 | `sync2/transport.rs` `sync2_digest` / `sync2_digest_buckets` | 部分：`gen4/digest.rs:Index::digest` / `digest_buckets` | G8-7（随 head 发） | 未接线（报 `gen4: not wired yet`），归 G8-7 |
| `legacy_dots` | 读 | `sync2/mod.rs` | 不需要（旧 v1 dot，承袭日志自带） | G7-6 删 | 已删（报 `gen4: removed`）；实现 G7-6 删 |
| `local_state` / `local_state_ensure` / `local_anchor` | 读 / 写 | `local_state.rs` | 缺 | 建议 S1（内核持有的本机状态行：修订号、校时锚点；协议 3 存 `srs_meta`，新代沿用 `srs_meta` 键即可） | 已接（`srs_meta` 键 `local_state/<profile>`；迁移不带旧行） |
| `location_sealed` / `location_seal` | 读 / 写 | `sync2/sealed.rs` | 部分：`loc_state` 表（G7-1）、迁移已灌（`carry.rs`），读写 API 缺 | G8-7 | 未接线（报 `gen4: not wired yet`），归 G8-7 |
| `media_known` / `media_record` / `media_hash` / `media_scan` / `media_landed` / `media_bind_unbound` / `media_doomed` | 读写 | `sync2/media*.rs` | 部分：`gen4/media.rs`（`known` / `record` / `ingest` / …，存储层） | G8-7（G8-3 存储层已合） | 未接线（报 `gen4: not wired yet`），归 G8-7 |
| `seal` / `open` / `open_v1` / `seal_file` / `open_file` / `derive_key` | 无 | `crate::sync2::media_seal` / `keys` | 不需要新实现（纯加解密，不碰库） | S1 原样接（与库代无关） | 已接 |

### 7.5 C 直出入口（`ffsrs_store_*`）

| 入口 | 读/写 | 协议 3 实现位置 | gen4 实现位置 | 归属 / 备注 | S1 后状态 |
|---|---|---|---|---|---|
| `ffsrs_store_open` / `ffsrs_store_close` | — | `store/mod.rs` `SrsCore` | `gen4/files.rs:open_gen4`（G7-1 的 C 入口另有） | S1（规划：删 `ffsrs_store_open`） | `open` 已删，改 `ffsrs_store_open_mode(dir, mode)`（打开模式 + 代际状态返回码）；`close` 已接（句柄里是 `G4Core`） |
| `ffsrs_store_snapshot` / `ffsrs_store_debug_query` / `ffsrs_store_exec` / `ffsrs_store_exec_batch` / `ffsrs_store_in_transaction` / `ffsrs_store_read_concurrency` / `ffsrs_store_diag_counts` | 读写 | `ffi.rs` 原始通道 / 诊断 | 缺 | S1（原始通道 cargo feature，#3392；新代只留诊断需要的） | `snapshot` 未接线，归 G11-4（备份格式）；`exec` / `exec_batch` 已接、仍只在测试 / `raw_sql` feature 下；其余已接 |
| `ffsrs_store_legacy_state` / `_begin` / `_page` / `_commit` / `_abort` / `_mark_none` | 写 | `store/mod.rs` 旧库搬迁 | 不需要（协议 1 旧库走 D21 只读转译） | G7-6 删（或 D21 定后改走 `gen4/import.rs:import_v1`） | 未接线，归 G7-6 / D21 |
| `ffsrs_store_history_states` / `ffsrs_store_stat_projection` | 读 | `history.rs` / `projection.rs` 按血统重放 | 缺 | 建议 G7-4c（学习 / 统计侧的逐卡重放；规划未点名，G7-4c 不收则归 S1） | 未接线，归 G7-4f（待合） |
| `ffsrs_store_optimizer_items` / `ffsrs_store_calibration_items` / `ffsrs_store_rwkv_rows` / `ffsrs_store_rwkv_log_tail` | 读 | `calibration.rs` / 优化器 / RWKV 训练集 | 缺 | 同上：训练集读血统日志，新代按 `cache.rs:replayed_card_logs` 取日志即可 | 未接线，归 G7-4f（待合） |
| `ffsrs_set_temp_dir` | — | `ffi.rs` | 不需要（与库代无关） | S1 原样保留 | 原样保留 |
| `ffsrs_store_sync2` | — | `ffi.rs` 分发器入口 | — | S1：本表全部命令的入口 | 已接新代分发器 `gen4/dispatch.rs` |

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

## 8. S1 接线设计（2026-11-16，分支 `pr/srs-gen4-s1-dispatch`）

S1 把 `ffsrs_store_sync2` 与 C 直出入口切到新代：句柄里放 `store/gen4/kernel.rs` 的 `G4Core`（profile 目录里的
`srs4.db`），命令经 `store/gen4/dispatch.rs`。协议 3 的分发器 `ffi.rs` `sync2_dispatch` 与它调到的实现原地保留（`pub`，
给协议 3 的测试与对拍装置用，G7-6 删），生产入口不再调它。§7 各表的「S1 后状态」列是逐条结果。schema 不变（40017：
S1 没有加表或索引，本机状态行与缓存配置都放现有的 `srs_meta` / `derive_cfg`）。`ABI_VERSION` 7 → 8。

### 8.1 打开与迁移的状态机

- 入口 `ffsrs_store_open_mode(dir, dir_len, mode, core_out, err)`：`dir` 是 profile 目录（不是文件路径），`mode` 0 =
  Primary（主进程，唯一的写者；全新安装建空库）、1 = Secondary（查词弹窗等辅助进程，只读）。底下是 G7-1 的
  `files::open_gen4`。**`ffsrs_store_open` 已删**（不是改成「先试新代、不行开旧库」：那正是「静默用旧库」）。
- 打不开时各状态各有返回码，库一概不动：

  | 目录里 | 返回码 | 错误文本 |
  |---|---|---|
  | 协议 3 的 `srs.db`，没迁移 | `STORE_NOT_MIGRATED` (-4) | 后接 `{"state": "needsMigration"}` |
  | 只剩封存的旧库 / 墓碑（新代库不见了） | -4 | `{"state": "sealedOldOnly"}`（不建空库顶上） |
  | 上次迁移失败留下的半成品 | -4 | `{"state": "migrationFailed"}` |
  | 什么都没有、Secondary 先到 | -4 | `{"state": "ready"}`（等主进程建库） |
  | 换代锁被别的进程拿着 | `STORE_MIGRATING` (-5) | — |
  | 新代库旁边有一份没封存、也不是它迁移来源的 `srs.db` | `STORE_LEGACY_UNMIGRATED` (-6) | — |
  | 其余（文件坏、IO） | `STORE_ERROR` (-1) | 原因 |

- 迁移走三条**全局命令**（`ffsrs_call` 的 JSON 命令，不要句柄；`gen4/kernel.rs` `global`）：
  - `gen4_migrate_status {dir}` → `{state, running}`（`running` = 本进程里正在跑的那次的 `{step, done, total}`，没有 = null）；
  - `gen4_migrate_run {dir, caches: {profile: 缓存配置}, now, batch?, runId?}` → `migrate::Outcome::json`
    （`{verdict: committed | aborted | blocked | noSpace | cancelled, ...}`）。阻塞调用，放后台 isolate；同一目录同时只跑
    一次（第二次回 `blocked`）。新身份的设备 ID 用 `migrate::random_device`。本进程里「这个目录正在跑」的登记由析构守卫
    摘掉（正常返回、报错、`migrate::run` 中途 panic 被 `ffsrs_call` 接住都一样，不会把这个目录永远卡成 `blocked`），同时清掉
    这个目录下给了 `runId` 却始终没有对应运行的提前取消；
  - `gen4_migrate_cancel {dir, runId?}`：叫停正在跑的那次（提交点之前有效）；还没开始的按 `runId` 先登记，开始时即停。
- Dart 侧（G7-5）的顺序：开库 → -4 且 `needsMigration` → 关掉所有协议 3 句柄 → `gen4_migrate_run` → 再开。
  `sealedOldOnly` / `migrationFailed` 给恢复页，不自动重跑。

### 8.2 命令层的状态与锁

`G4Core` 持有（都随句柄，关库即丢）：

| 状态 | 锁 | 说明 |
|---|---|---|
| 写连接 | `Mutex<Option<Connection>>` | 只有 Primary 有。写命令 `G4Core::write` = `BEGIN IMMEDIATE` 一个事务；命令 panic 后下一个拿锁的先回滚残留事务（不毒化）。Secondary 上一律报 `READ_ONLY` |
| 读连接池 | `Mutex<Pool>` + `Condvar` | 上限 `read_pool::read_concurrency()`；还回来时还在事务里的连接直接丢掉；`close` 等借出的都还回来 |
| 浏览会话 | `Mutex<Browse>`（每库一把） | `cmd/browse.rs` 的会话原样常驻；集合号在锁外先换算（浏览自己开快照，要分清是不是在写事务里读） |
| 统计原料缓存 | `Mutex<Option<StatsEntry>>` | 一份：键 = (集合, 请求的 `key`, 写入代数, 缓存层代号 `cache_gen (gen, floor)`)，未命中调 `cmd/stats.rs:snapshot_of`；`stats_release` 丢掉。写入代数管本进程的写（含不碰缓存层的写，如 `local_anchor`），缓存层代号管别的进程（Primary 写、Secondary 读）的写：两个条件各有一条测试卡住 |
| 写入代数 | `AtomicU64` | 本进程每次写命令**提交成功**后 +1 |
| 大批写入开关 | `Mutex<Bulk>` | `bulk_cache` 保留：嵌套深度；开着时放宽 WAL 自动检查点（`BULK_WAL_AUTOCHECKPOINT_PAGES`），关到 0 时恢复。新代没有「暂缓缓存刷新」——派生层随写入维护 |

- profile → 集合号：每条命令在自己的快照 / 事务里用 `Truth::binding_of(profile)` 换算；没绑定 = 明确报错（绑定由迁移或
  G9-4 的身份命令建）。本机状态行与 `device_hint` 不要绑定。
- **出卡不常驻**（协议 3 的 `StudyHub` 不搬）：`cmd/study.rs` 每条命令在一个读快照里现排。取舍：省掉「写后失效」整套
  簿记，代价是每次 `study` 重读到期卡（S1 没有实测这部分开销）；量出问题再加常驻队列，失效的键与统计缓存同法。
- `wal_checkpoint`：Primary 上另开一条连接做 `PASSIVE`，不占写锁。Secondary 上报 `READ_ONLY`、不开连接：辅助进程按设计
  只读（可能在没有写权限的沙箱里），并回 WAL 是写库的主进程的事（协议 3 没有 Secondary，句柄一律读写）。
- 本机状态行（`local_state` / `local_state_ensure` / `local_anchor`，`gen4/local.rs`）：`srs_meta` 键
  `local_state/<profile>`，存修订号、纪元、校时锚点（协议 3 行里的 `styleCursor` / `cacheRev` / `mediaGc` 新代没有：
  `local_state` 的回包形态照协议 3 的 `view`，其中 `styleCursor` 恒为默认值）。**迁移不带协议 3 的那一行**：
  换代后纪元换新、修订号从 0 起；Dart 按纪元变了整份重读（与「库换了」同一条路径）。键里的 profile 串**原样、不归一**
  （协议 3 经 `srs_id(?1)` 打包成 16 字节，大小写不同的同一个 UUID 落同一行）：与新代 `collections.profile_uid`
  （`Truth::binding_of`）一致，一个 profile 只认一种写法；Dart 一直传 `Profile.uid` 同一种写法，不受影响。
- 返回码 `STORE_NO_SPACE`（-3）S1 后没有返回点（它属于已删的 `ffsrs_store_open` 的升级前空间检查；迁移的空间不够走
  `gen4_migrate_run` 的 `noSpace`）。值保留、不复用；Dart 删对应分支归 G7-5，删常量归 G7-6。
- 纯加解密命令（`seal` / `open` / `open_v1` / `seal_file` / `open_file` / `derive_key`）抽成 `ffi.rs` `crypto_command`，
  两代分发器共用。

### 8.3 写命令的形状与会话失效

- 本机写命令（§7.3 的 `LOCAL_WRITE_OPS`）：集合号、命令本体（`cmd/writes*.rs`，自己开 SAVEPOINT）、请求带 `study` 时的
  排队（看得见这笔还没提交的写入）、本机状态行（`local::persist`：修订号 += `changed` + `purged` + `replayed` + `edits`
  的条数，带 `anchor` 时一并写）**一个事务**；任何一步出错整笔回滚。`apply` 的前置条件不成立回 `{"stale": true}`，
  什么都不写、修订号不动。
- 回包：G7-3b 的统一形状（`changed` / `purged` / `replayed` / `edits` / `nextSeq` / `settled`）+ `localRevision` /
  `localEpoch` + `study`。协议 3 的 `marks` / `diagnostics` / `cache`（Dart 缓存镜像的写入清单）新代没有。
- `cache_config_set {caches}`：先按协议 3 同一份 `CacheConfig::parse` 核对（坏的不写），与 `derive_cfg` 里存的按 JSON 值
  比；相同回 `{changed: false}`，变了写下并 `Settle::Rebuild` 整层重建，同一个事务，回 `{changed: true, settled}`。
  协议 3 的 `{from, to, current, cache}`（推导口径版本）新代没有。`refresh_caches` / `rebuild_caches` 回 `{settled}`。
- 失效：浏览会话按缓存层代号自己对上（写入经派生层收尾记账）；统计原料缓存的键里有写入代数与缓存层代号（后者兜住
  别的进程的写入）；出卡现读，没有要失效的。

### 8.4 未接线 / 已删的臂

`dispatch.rs` `wiring(op)` 给协议 3 分发器里的**每一条**命令一个去向（`ffi.rs` 测试
`every_protocol_3_command_has_a_gen4_wiring` 按协议 3 分发器源码的匹配臂逐条核对，标成「已接」的必须有臂）：

- 未接线（报 ``gen4: not wired yet: `<op>` belongs to <owner>``，不 panic、不回落协议 3）：
  - G9-4：`identity`、`binding_set`
  - G9-5：`profile_uids`、`orphan_sweep_done`、`profile_merge_mark` / `_commit`、`meta_set_edit`、`profile_purge`
  - G8-7：收段 / 发件 / head / plan / 中继 / 废弃 / 摘要 / `retire` / `rotate` / `location_seal*` / `media_*`（媒体同步）
  - G11-3：`import`、`export`；G11-4：`ffsrs_store_snapshot`
  - G7-4f（待合）：`preview`、`ffsrs_store_history_states` / `stat_projection` / `optimizer_items` /
    `calibration_items` / `rwkv_rows` / `rwkv_log_tail`
  - G7-6 / D21：`ffsrs_store_legacy_*`
  - S1 后续：`media_gc_queue` / `media_gc_collect` / `media_live_refs`（待回收集合的新代存处与存活引用的新代读法没定）
- 已删（报 ``gen4: removed: `<op>` (<原因>)``）：`refresh_keys`（派生层随写入维护，没有「待刷新」）、`channel_settle`（没有收段通道）、
  `migrate` / `replay_all` / `legacy_dots` / `backfill_*` / `edits_rewrite_repr`（协议 3 存储细节）、`gen4_rehearse*`
  （换代前才有意义）。
- `entity_views` 没有协议 3 对应命令，线上形状归 G10-2，S1 不接。
- §7.6（带盐成员上被扣住的删除 `resolve` 不掉）归 G7-4g，S1 没动 `weigh.rs`。分发器接上之后它对用户可见：只影响
  别名类里带盐成员上的删除冲突，G7-4g 合入前冲突中心会反复列出同一条。

### 8.5 测试

`store/gen4/cmd/dispatch_tests.rs`，一律经 C ABI：`tests.rs` 的协议 3 库复制一份、经 `gen4_migrate_run` 迁移，与迁移前的
原件（协议 3 分发器）逐类对拍读 / 出卡 / 浏览 / 统计 / 冲突中心，两侧各发同一次写之后再比；写后统计缓存按写入代数重读、
浏览按代号看见改动、`stats_release`；修订号推进与 `stale`；`cache_config_set`；各代际状态的打开（未迁移、迁移中、
墓碑、只剩封存旧库、旁边另有协议 3 库、Secondary 只读、没有绑定）；迁移的全局命令（含提前取消）；未接线 / 已删的报错；
别名类成员经分发器按类回答；命令层新语句的查询计划。ID 按迁移出来的那份库归一（迁移给集合换了标识，默认牌组等内置
实体的 ID 随之换盐）。

复核补的（2026-11-16）：

- **逐条接线对拍**：第一组之外的每条已接线命令都经分发器与协议 3 的同一条比一次——读（`anki_resolve` /
  `anki_notes_info` / `binding_get` / `profile_footprint` / `status` 形状 / `read_lib` / `stats_recall` / 浏览其余子命令与
  `anki_find` / `anki_dupes` / `anki_tags`）比回包；写（`resolve` / `note_fields_if` / `change` / `sched` / `deck_delete` /
  `merge_notes` / `purge` / `checkpoint` / `plan_restore` / `restore` / `trust` / `device_info` / `device_hint`）比各命令的
  关键键并在每条之后比两侧身份记录表；`dedup` / `digest_heal` 断言新代语义的回包。变异实测：把 `binding_get` 接成
  `profile_footprint`、`anki_resolve` 接成 `anki_notes_info`、`dedup` 接成 `digest_heal`、`purge` 接成 `checkpoint`、
  `device_info` 接成 `device_hint`，各自都红。
- 统计缓存两个失效条件各一条（去掉键里的写入代数 / 缓存层代号各自变红）；Secondary 上 `wal_checkpoint` 报只读；
  迁移中途 panic 之后登记摘掉、提前取消清掉。查询计划测试用实现执行的同一份语句常量（`CACHE_MARK_SQL` / `STORED_SQL`）。

## 9. G7-5 Dart 接线（2026-11-17，分支 `pr/srs-gen4-g7-5-dart-wiring`，基于 `pr/srs-gen4-switch`）

顺序：能启动 → 能迁移 → 页面。Rust 没动。

### 9.1 开库

- `kFushiFsrsAbiVersion` 7 → 8；`SrsCore.open(dir, mode:)` / `openInBackground` / `fromAddress` 走
  `ffsrs_store_open_mode(dir, mode)`，参数是**库目录**（`srs4.db` 新库、`srs.db` 封存旧库、`srs.gen.lock`）。
- 进程角色：主进程 Primary（`SrsStorageHost` 带主库），弹窗 / 查词窗 Secondary（不带主库，只读）。Secondary 遇到
  `NotMigrated(ready)`（主进程还没建库）返回 null、不缓存；其余代际状态原样抛给页面、不缓存。`fushi_server` 只改了开库
  调用（`SrsStorage.open(directory: support.path)`），无头状态机归 G10-3。
- 返回码类型化（`SrsCoreException.of`）：-4 `SrsStoreNotMigrated(state)`、-5 `SrsStoreMigrating`、-6
  `SrsStoreLegacyUnmigrated`（三者是 sealed `SrsStoreOpenBlocked`）；`SrsCoreUnwiredException{op, owner}`、
  `SrsCoreRemovedException{op}`、`SrsProfileUnboundException{profile}`（归 G9-4）、`SrsCoreReadOnlyException`。
  STORE_NO_SPACE(-3) 分支与 `SrsUpgradeNoSpaceException` 删了（空间不够现在是迁移结论 `noSpace`）。
- `SrsStorage.open` 不再调 `srsMigrateLegacyStore`：主库里还有协议 1 的 `srs_entities` 且目录里两份库都没有时抛
  `SrsLegacyMainDatabasePending`，页面给「原样保留、等后续导入」（G7-6 / D21），主库不动。

### 9.2 迁移

- `SrsGen4Migration.status / run / cancel`（`packages/fushi_srs/lib/src/store/srs_gen4_migration.dart`）包三条全局命令；
  `run` 在后台 isolate 里阻塞到结论，进度靠轮询 `status.running`。提交点（`commit`）之前的步骤可取消。
- `SrsGen4MigrationController`（`fushi/lib/src/srs/srs_gen4_migration_controller.dart`）：按主库 profile 表每个 uid 交
  `srsCacheConfigFor(uid)`（旧库里多出的 profile 见 §9.5 缺口 2）；提交后 `SrsStorageHost.reopen()` 再作废
  `srsStorageProvider` / `srsStoreProvider`。进程级 provider，换页不丢进度。登记 `AppModel.addDatabaseCloseQuiescer`：关库
  （覆盖恢复 / 换数据根 / 退出）前提交点之前叫停并等结论，过了提交点就等它跑完。
- `blocked` 按原因分类（`SrsGen4BlockedReason.of`，只比 migrate.rs 两个常量的全文，Dart 测试读 Rust 源码核对两边一字
  不差）：`migrating`（换代锁在别处 / 本进程已在跑）→「别的窗口在升级」；`busy`（旧库正被写）→「被占用，稍后再试」；
  其余一律 `precondition`（协议 3 收尾没做完、缺缓存配置、schema 不对……）→「这一版还升级不了」+ 内核原因原文，**不给
  「重新升级」**（重试不会变，见 §9.5 缺口 1）。
- 页面 `SrsGenerationView`（`srs_generation_view.dart`）：`SrsLoadErrorView` 收到 `SrsStoreOpenBlocked` /
  `SrsLegacyMainDatabasePending` 时转过去。状态：要迁移（开始 → 步骤 n/9 + 进度条 + 取消）、结论（取消 / 被占用 / 空间
  不够〔差多少〕/ 对拍不过〔报告路径〕/ 内核报错）、上次失败（重新升级）、只剩封存旧库（不自动重建）、别的窗口在迁移、
  -6、协议 1 主库、非主进程（去主窗口）。MD3 / Apple 都走 `FushiPlaceholderMessage` + Fushi 按钮，错峰进场 + 按压缩放。

### 9.3 调用点（`srs_db_store.dart` 等）

| 调用点 | 处理 |
|---|---|
| `migrate` / `_sync2MigrateAll` / `beforeMigrate` / `deferMigration` | 删；`migrateLegacy` 留成空操作、`sync2Migrated` 恒 true（调度器 G8-7 改） |
| `edits_rewrite_repr` / `compactStoredStyles` / `_styleCursor` | 删（协议 3 存储细节） |
| `backfill_*`、`legacy_dots`（store 内） | 删 |
| `gen4_rehearse*`、预演调度 / 预演页 / 预演测试 | 整块删（换代后没有意义） |
| `bulk_cache` / `cache_config_set` | 新回包 `{depth}` / `{changed, settled?}`；`changed` 时作废派生缓存 |
| 写回包 | 不再读 `marks` / `diagnostics` / `cache`；按 `changed` / `purged` / `replayed` 吸收；只改卡时记卡号进日志，其余整份作废 |
| `stamps` | 内核拒 `stamps:true`：草稿与回包 `edits` 按 (种类, 规范实体, 字段键) 配对（`srsMatchWrittenEdits`；草稿实体不在 `edits` 里时按 `read edits` 点查归一），再按 `(device, seq)` 读回 `edits` 行。整列表标签草稿不在其中（§9.5 缺口 4） |
| 答题的 `hlc` | 从 `logs` 读回存下的 `hlc` |
| `refreshKeys` | 改读 sync2 `local_state`：五个键都等于 `epoch:revision`（跨进程可见；纪元变 = 整份重读）；纪元没落盘时是固定的 `unstored:revision`。比协议 3 粗得多、作答热路径有代价，见 §9.5 缺口 3 |
| 设备号 | 开库读 `status.device`（`_sync2Open`），`identity` 归 G9-4；`isOwnWriter` 只认本机设备 |
| 开库时的 `afterRestore` | 删（备份恢复 G11-4 自己调 `rebuildCaches`） |
| Secondary 开库 | 跳过登记缓存配置 / 写本机状态 / 内置实体（都是写） |

未接线、保留为类型化错误（不崩、页面显示「暂不可用」，不当成功）：

- G9-4：`identity`（同步轮次）、`binding_set`、新 profile 建绑定——**全新安装与新建 profile 现在开不出复习库**
  （`SrsProfileUnboundException`）。
- G9-5：`srs_profile_merge.dart` 的 `profile_uids` / `profile_purge` / `profile_merge_*` / `meta_set_edit` / `legacy_dots`。
- G8-7：全部同步命令、`ingest_yield`、`SrsSyncScheduler.ensureMigrated`。
- G11-3：导入 / 导出（含 `plugin_tracking_provider`）；G11-4：`ffsrs_store_snapshot` 与备份恢复。还原（覆盖 / 合并）
  在备份带复习数据、又选了「复习」类别时**动任何文件之前**抛 `SrsRestoreUnavailableException`（提示取消勾选复习再还原
  其余内容），见 §9.5。备份导出判断「本机有没有复习库」认 `srs4.db` 与 `srs.db` 两种文件（`SrsStorageHost.hasStoredLibrary`）：
  只有协议 3 库、没迁移时导出打开新代库抛 `SrsStoreNotMigrated`，明确失败、不做出不带卡片的备份。
- S1 后续：`media_gc_*`；G7-6 / D21：`srs_legacy_store_migration.dart` 与它的测试。

### 9.4 测试

新增：`fushi/test/srs/srs_storage_host_gen4_test.dart`（开库状态机）、`srs_gen4_migration_controller_test.dart`（假执行端）、
`srs_generation_view_test.dart`（每种状态 × MD3 / Apple、迁移全流程）；`packages/fushi_srs/test/store/srs_core_test.dart`
改写为新代。老测试按新开库改写；协议 3 专属行为（缓存修订号 `srs_local_state.cacheRev`、推迟迁移）的用例标 `skip:` 并写
原因；被测代码已删的（存量样式压缩、`beforeMigrate` 去重）删用例。依赖 profile 绑定（G9-4）的 store 测试在新代上会红，
不在本模块修。

复核补的（2026-11-17）：`packages/fushi_srs/test/store/srs_gen4_migration_test.dart`（blocked 分类与 Rust 常量核对、
未落盘纪元的稳定键）、`packages/fushi_engine/test/srs/srs_written_edits_match_test.dart`（混合 no-op 草稿的配对）、
`fushi/test/sync/backup_srs_restore_refusal_test.dart`（覆盖 / 合并还原在迁移过的目录上拒绝且 `srs.db` / `srs4.db` 一字节
不动），控制器测试加 quiesce、存储持有者测试加 `acquireIfStored`、状态页测试加三类 blocked × 两套设计。变异实测：
blocked 一律归 busy、去掉 `unstored` 分支、配对退回 (种类, 字段键)、quiesce 不叫停、前提没满足说成「被占用」、只认
`srs4.db`、去掉还原拒绝，各自让对应用例变红。

### 9.5 已知缺口与上游（2026-11-17 复核）

1. **没同步过的老用户迁不了（阻断，上游 G7-2 / 规划 §1.4 第 1 步）。** 协议 3 的 `sync2_self.migrated_at` 只在 `migrate`
   命令（`sync2/mod.rs` `finish_migration`）或同步传输里写；`legacy::preflight` 把 NULL 当硬阻断，`sync2_migrate_queue` /
   `sync2_replay_pending` / `sync2_cache_pending` / `sync2_boot` 残留同样拦。S1 删了 `ffsrs_store_open`、G7-5 删了 Dart 的
   `migrate` 调用，集成分支里没有任何路径补完这些前提。要 Rust：`gen4_migrate_run` 取锁后用冻结的协议 3 代码先补完前提，
   或另开一条全局命令专门补，Dart 在 `run` 之前调。Dart 这边已经把这类 `blocked` 单列成「这一版还升级不了」+ 原因、不再
   说成「被占用」、不给「重新升级」；上游补上之后这里要接那条命令并恢复重试按钮。
2. **旧库里多出的 profile 让迁移 blocked（上游 G7-2）。** 缓存配置只按主库 profile 表给；协议 3 库里删除没清干净 / 备份
   并入留下的孤儿 uid 会报 `no cache configuration was given`。要 Rust：`gen4_migrate_status`（或新的只读全局命令）回旧库的
   profile 列表（`legacy::profiles`），Dart 对每个 uid 给 `srsCacheConfigFor(uid)`（只取决于 uid）。在那之前这类用户看到
   的是 1 同一页（前提没满足 + 原因原文）。
3. **刷新键五合一（上游 S1 后续）。** 新代没有协议 3 `refresh.rs` 的按类计数，五个键都是 `纪元:修订号`，作答也推进修订号：
   RWKV 分数表每题整表重查（「每答几题刷新」形同每题刷新；协议 3 特意不让它随日志变，以前 35 万日志的 iPhone OOM 就是
   这么来的），牌组树 / 笔记类型 / 修改记录这些按键缓存的东西每题重建；`refreshKeys` 也从读内存变成 UI isolate 上每个
   getter 一次同步 FFI 点查。要 Rust：`G4Core` 按 profile、按类别持有进程内刷新计数，由写路径按 `changed` / `replayed` 的
   种类推进，Dart 只读。补上之前 Dart 不加计数镜像。
4. **`apply` 回包不够 Dart 拼 stamps（上游）。** `edits` 不带输入序号，Dart 只能按 (种类, 规范实体, 字段键) 配、非规范草稿
   逐条点查归一；整列表标签草稿展开成标签增删、不进 `edits`，返回里没有标签那一项（协议 3 有）。要 Rust：`edits` 每项带
   输入序号，标签增删也报一项。
5. **作答的 HLC 多一次往返（上游，次要）。** `apply` 回包没有作答日志的 HLC，Dart 按卡读全部日志再找 logId（O(该卡日志数)）。
   要 Rust：回包带上，或给按 logId 点查。
6. **还原（G11-4）。** 协议 3 的还原逻辑会删 / 换 `srs.db`（迁移后是封存的无损回退副本），换进来的协议 3 库让下次开库停在
   -6，合并要开协议 3 库。G11-4 接上新代还原之前，备份带复习数据（`srs.db` 条目 / `srs_media/` / meta 记数 > 0；老形态 meta
   没记数的按带算）且选了复习时整次拒绝、什么都不动。启动时重放旧 sidecar 的 `srs` 计划（`recoverPendingRestore`）只可能
   来自本版之前的还原，没改。「只剩封存旧库」页的文案改成「保持原样、不要用备份覆盖、带日志联系支持」，不再引导还原。
7. **迁移中关库之后的再开始。** quiesce 之后主库已关，迁移页的「开始升级」按钮仍可点（app 未初始化时这一页通常不在
   屏上）。没加额外闸门。
