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
| `ingest_yield` | 无 | `sync2/transport.rs` `sync2_ingest_yield`（收段让路标记） | 缺 | G8-7（收段调度） | 已删（G8-7：没有收段通道，报 `gen4: removed`） |
| `refresh_keys` | 读 | `refresh.rs` `refresh_keys` | 缺（派生层随写入维护，无「待刷新」集合） | S1：新代不需要，接线时删 | 已删（报 `gen4: removed`） |

### 7.2 缓存 / 本机状态（`sync2_dispatch_op` 后半，分发器自己处理的特殊臂）

| 命令名 | 读/写 | 协议 3 实现位置 | gen4 实现位置 | 归属 / 备注 | S1 后状态 |
|---|---|---|---|---|---|
| `cache_config_set` | 写 | `cache_rev.rs` `upgrade` | 部分：`truth.rs:set_derive_cfg`（`derive_cfg` 存配置）+ `ingest.rs:ingest_settle(Rebuild)` | S1：命令外壳缺；配置变了要按 `Settle::Rebuild` 重建 | 已接；回包改成 `{changed, settled?}` |
| `refresh_caches` / `rebuild_caches` | 写 | `caches.rs` `refresh` / `rebuild` | 部分：`ingest.rs:ingest_settle` / `derive.rs:Index::rebuild_all` | S1 | 已接（`Settle::Incremental` / `Rebuild`），回包 `{settled}` |
| `backfill_dupe_norms` / `backfill_tag_sources` / `backfill_source_keys` | 写 | `caches.rs` | 不需要（新代缓存层建行时就算全列） | G7-6 删 | 已删（报 `gen4: removed`）；实现 G7-6 删 |
| `edits_rewrite_repr` | 写 | `repr_rewrite.rs` | 不需要（存量样式去重是协议 3 存储表示的事） | G7-6 删 | 已删（报 `gen4: removed`）；实现 G7-6 删 |
| `media_gc_queue` / `media_gc_collect` | 写 | `media_gc.rs`（逐名规则抽成 `sweep` / `CollectArgs` / `add_names`，两代共用） | `cmd/media_gc.rs:queue` / `collect` | S1b：待回收集合存在新代本机状态行（`srs_meta` 键 `local_state/<profile>`）的 `mediaGc` 键，键名与形态同协议 3；存活引用读缓存层 `notes.media_refs` + 按类判定的笔记类型视图；没绑定 / 没设缓存配置时 `collect` 回 `deferred` 不删（§8.6） | 已接（S1b；经分发器对拍） |
| `media_live_refs` | 读 | `media_gc.rs` `live_refs`（后一半抽成 `finish_live_refs`，笔记类型文本抽成 `caches::note_type_view_texts`） | `cmd/media_gc.rs:live_refs_json` | 同上；读不全（没绑定 / 没缓存配置）明确报错，不回空集合 | 已接（S1b；经分发器对拍） |
| `ingest_commit` | 写 | `sync2/transport.rs` | 缺（新代收段 `receive.rs` 是存储层） | G8-7 | 已删（G8-7：没有收段通道） |

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
| `import` | 写 | `sync2/transport.rs` `import_on` | 部分：`gen4/import.rs:import_ops` / `import_backup`（存储层） | G11-3（`.fushisrs` v2 接线） | 已接（G11-3，`store/gen4/cmd/fushisrs.rs`，§15） |
| `retire` | 写 | `sync2/devices.rs` `retire` | 缺（停用标记不迁移，`carry.rs` 文件头） | G8-7：连同 `status` 设备行的 `retired` 状态一起接 | 已接（G8-7 `cmd/sync.rs:retire`；`status` 设备行出 `retired` / `retiredAt`） |

### 7.4 读命令与其余（`sync2_command`）

| 命令名 | 读/写 | 协议 3 实现位置 | gen4 实现位置 | 归属 / 备注 | S1 后状态 |
|---|---|---|---|---|---|
| `identity` | 写 | `sync2/mod.rs` `sync2_identity` + `legacy_clock.rs` | `cmd/identity.rs:identity_read` / `identity_ensure`（`truth.rs:create_self` / `self_identity`） | G9-4；`legacyWriter` / `channel` 新代不回，新增 `dir`（「G9-4」一节） | 已接（G9-4） |
| `channel_settle` | 写 | `sync2/channel.rs` | 不需要（新代没有收段通道，收段即落真相） | S1 删 | 已删（报 `gen4: removed`） |
| `migrate` | 写 | `sync2/mod.rs` `sync2_migrate`（v1→v2） | 不需要（`gen4/migrate.rs` 是协议 3→4 的另一件事） | G7-6 删 | 已删（报 `gen4: removed`）；实现 G7-6 删 |
| `replay_all` | 写 | `sync2/mod.rs` | 不需要（派生层是真相的纯函数） | G7-6 删 | 已删（报 `gen4: removed`）；实现 G7-6 删 |
| `study` | 读 | `study.rs` `SrsCore::study` | 缺 | **G7-4c**（学习 / 出卡） | 已接（每条命令一个读快照现排，不常驻） |
| `preview` | 读 | `sync2/mod.rs` `sync2_preview`（计算与回包抽成 `preview_of`，连接级 `preview_on`） | `cmd/preview.rs:preview` | **G7-4f 已补**。牌组树 / 默认牌组 / 卡的有效牌组都是 `cmd/mod.rs` 的只读函数（`deck_tree` / `default_deck` / `card_deck`；`Session::card_deck` 改为先收尾再调它）；归属组日志与笔记取 `cache.rs:Index::group`（写命令 `sched` 同一份）。卡与笔记先归一，回包 ID 是规范 ID。已知差别：协议 3 `group_of` 读链尾日志不带 `ORDER BY`（`idx_srs_review_logs_card` 上的 rowid 序 = 落库序），「链尾最后一条记了笔记的」在新代按 (发生时刻, 操作主键) 取；只在链尾晚到的旧日志记了另一个笔记时两边可能不同，新代的序与时间一致，不改 | 已接（S1b：`dispatch.rs` 的 `preview` 臂，请求形状同协议 3；经分发器对拍） |
| `read` | 读 | `reads.rs` `run`（27 个查询名） | `cmd/reads.rs:run`（同 27 个，逐名核过） | G7-4 已有；S1 接线 | 已接 |
| `card_columns` | 读 | `bulk.rs` `card_columns` | `cmd/columns.rs:card_columns` | G7-4b 已有 | 已接 |
| `anki_resolve` / `anki_notes_info` | 读 | `bulk.rs` | `cmd/columns.rs:anki_resolve` / `anki_notes_info` | G7-4b 已有；G7-4g 成员号改按缓存层反查表 `anki_members` 点查，从没出现在操作里的带盐卡的号也查得到（schema 40019） | 已接 |
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
| `binding_set` | 写 | `binding.rs` `binding_set` | `cmd/identity.rs:binding_set`（`truth.rs:settle_binding`） | G9-4；只写绑定状态三列、不改绑定，不发 `bindingChanged`（「G9-4」一节） | 已接（G9-4），回包与协议 3 逐键相同 |
| `profile_footprint` | 读 | `profile_data.rs` `profile_footprint` | `cmd/profile.rs:profile_footprint` | **G7-4e 已补**（`rows` 只保证「是否为 0」与协议 3 一致） | 已接 |
| `profile_purge` | 写 | `profile_data.rs` `profile_purge` | 缺 | 建议 G9-5（删一个集合 = 删 `collections` 行与该集合的设备、派生、本机状态；与并入收薄同一处） | 未接线（报 `gen4: not wired yet`），归 G9-5 |
| `status` | 读 | `sync2/transport.rs` `sync2_status` + `devices.rs` `status_extras` | `cmd/writes_local.rs:status` | G7-3b 已有；G7-4e 补设备行 `gap` / `blocking`（`op_wait`）与 `state` 的 `missing` / `upgrade`；`retired` 归 G8-7（随 `retire`）；`seenAt` / `warning` / `frozen` / `digestMismatch` 仍是占位值，归 G8-7 | 已接 |
| `device_info` / `device_hint` | 写 | `sync2/devices.rs` | `cmd/writes_local.rs:device_info` / `device_hint` | G7-3b 已有 | 已接 |
| `outbox` / `outbox_ack` / `head` / `plan` / `relay_outbox` / `relay_ack` / `obsolete` / `obsolete_former` / `obsolete_ack` | 读写 | `sync2/transport.rs`、`relay.rs` | 部分：`gen4/sync_state.rs`（`loc_heads` / `relay_out` / `oldroot_fp`）、`gen4/oldroot.rs`、`gen4/compact.rs`（存储层） | G8-7（同步一轮 `g4_*` + 调度） | `outbox` / `outbox_ack` / `head` / `plan` / `obsolete` 已接（G8-7 `cmd/sync.rs`）；`obsolete_ack` 已删（无待删清单）；`relay_outbox` / `relay_ack` / `obsolete_former` 未接线，归 G8-7b |
| `ingest` / `ingest_begin` / `ingest_batch` / `ingest_prepare` / `ingest_end` / `ingest_finish` / `replay_pending` | 写 | `sync2/transport.rs`、`channel.rs` | 部分：`gen4/receive.rs:Receiver`（`native` / `heritage` / `legacy` / `finish`）+ `ingest.rs:ingest_settle` | G8-7 | `ingest` / `ingest_finish` 已接（G8-7）；`ingest_begin` / `ingest_batch` / `ingest_prepare` / `ingest_end` / `replay_pending` 已删（没有收段通道） |
| `rotate` | 写 | `sync2/transport.rs` `sync2_rotate` | 部分：`gen4/fork.rs:rotate_on_fork` | G8-6 / G8-7（规划：`Truth::rotate_identity` 归 G8-6） | 已接（G8-7 `cmd/sync.rs:rotate`） |
| `export` | 读 | `sync2/transport.rs` `sync2_export` | 部分：`gen4/export.rs:export_ops` | G11-3 | 已接（G11-3，`store/gen4/cmd/fushisrs.rs`，§15） |
| `digest` / `digest_buckets` | 读 | `sync2/transport.rs` `sync2_digest` / `sync2_digest_buckets` | 部分：`gen4/digest.rs:Index::digest` / `digest_buckets` | G8-7（随 head 发） | `digest` 已接（读，回 `{digest}` = `Index::digest`）；`digest_buckets` 已删 |
| `legacy_dots` | 读 | `sync2/mod.rs` | 不需要（旧 v1 dot，承袭日志自带） | G7-6 删 | 已删（报 `gen4: removed`）；实现 G7-6 删 |
| `local_state` / `local_state_ensure` / `local_anchor` | 读 / 写 | `local_state.rs` | 缺 | 建议 S1（内核持有的本机状态行：修订号、校时锚点；协议 3 存 `srs_meta`，新代沿用 `srs_meta` 键即可） | 已接（`srs_meta` 键 `local_state/<profile>`；迁移不带旧行） |
| `location_sealed` / `location_seal` | 读 / 写 | `sync2/sealed.rs` | 部分：`loc_state` 表（G7-1）、迁移已灌（`carry.rs`），读写 API 缺 | G8-7 | 已接（G8-7，读写 `loc_state`，回包形状同协议 3） |
| `media_known` / `media_record` / `media_hash` / `media_scan` / `media_landed` / `media_bind_unbound` / `media_doomed` | 读写 | `sync2/media*.rs` | 部分：`gen4/media.rs`（`known` / `record` / `ingest` / …，存储层） | G8-7（G8-3 存储层已合） | 未接线，归 G8-7b |
| `seal` / `open` / `open_v1` / `seal_file` / `open_file` / `derive_key` | 无 | `crate::sync2::media_seal` / `keys` | 不需要新实现（纯加解密，不碰库） | S1 原样接（与库代无关） | 已接 |

### 7.5 C 直出入口（`ffsrs_store_*`）

| 入口 | 读/写 | 协议 3 实现位置 | gen4 实现位置 | 归属 / 备注 | S1 后状态 |
|---|---|---|---|---|---|
| `ffsrs_store_open` / `ffsrs_store_close` | — | `store/mod.rs` `SrsCore` | `gen4/files.rs:open_gen4`（G7-1 的 C 入口另有） | S1（规划：删 `ffsrs_store_open`） | `open` 已删，改 `ffsrs_store_open_mode(dir, mode)`（打开模式 + 代际状态返回码）；`close` 已接（句柄里是 `G4Core`） |
| `ffsrs_store_snapshot` / `ffsrs_store_debug_query` / `ffsrs_store_exec` / `ffsrs_store_exec_batch` / `ffsrs_store_in_transaction` / `ffsrs_store_read_concurrency` / `ffsrs_store_diag_counts` | 读写 | `ffi.rs` 原始通道 / 诊断 | 缺 | S1（原始通道 cargo feature，#3392；新代只留诊断需要的） | `snapshot` 未接线，归 G11-4（备份格式）；`exec` / `exec_batch` 已接、仍只在测试 / `raw_sql` feature 下；其余已接 |
| `ffsrs_store_legacy_state` / `_begin` / `_page` / `_commit` / `_abort` / `_mark_none` | 写 | `store/mod.rs` 旧库搬迁 | 不需要（协议 1 旧库走 D21 只读转译） | G7-6 删（或 D21 定后改走 `gen4/import.rs:import_v1`） | 未接线，归 G7-6 / D21 |
| `ffsrs_store_history_states` / `ffsrs_store_stat_projection` | 读 | `store/mod.rs` `SrsCore::history_states` / `stat_projection`（计算抽成 `history_states_of` / `stat_projection_of`） | `cmd/training.rs:history_states` / `stat_projection` | **G7-4f 已补**。日志取 `cache.rs:Index::replayed_logs`（`replayed_card_logs` 的批量版，按连通分量重放），一份历史里同一张规范卡只算一次。S1：C 入口照旧解码两列页，按集合号调这里 | 已接（S1b：C 入口照旧解码两列页，经 `dispatch.rs` `direct_col` 换出集合号——页里带 `[-1, profile]` 行按它，否则按卡认集合（§8.6）——在一个读快照里调 `cmd/training.rs`；经 C ABI 与协议 3 逐字节对拍） |
| `ffsrs_store_optimizer_items` / `ffsrs_store_calibration_items` / `ffsrs_store_rwkv_rows` / `ffsrs_store_rwkv_log_tail` | 读 | `store/projections.rs` `SrsCore::optimizer_items` / `calibration_items` / `rwkv_cards` / `rwkv_replay` / `rwkv_log_tail`（计算抽成 `*_of` / `ReplayScan` / `rwkv_log_tail_of`，取数抽成连接级 `training_groups_on` / `rwkv_scan_on` / `rwkv_log_tail_on`） | `cmd/training.rs:optimizer_items` / `calibration_items` / `rwkv_cards`（`rwkv_rows` 模式 0）/ `rwkv_replay`（模式 1，profile 换成集合号）/ `rwkv_log_tail` | **G7-4f 已补**，输出逐字节同协议 3。**游标换了**：协议 3 的 rowid（本机落库序）在新代是本机状态表 `log_seq`（schema 40018，`derive.rs` 随 `log_ix` 逐条维护、整层重建保留序号）——操作主键 `k` = 设备下标 × 2^40 + seq，不随落库单调，不能当游标。指纹按日志操作数；尾巴每个规范日志 ID 只出代表。**落库序从 `derive.rs:SEQ_BASE`（2^40）+ 1 起**：RWKV 状态机（`fushi_rwkv` `sched/machine.rs`）判主快照 / 检查点只看 (行数, 最大 rowid)、没有库代标记，若两代都从 1 起编号，协议 3 留下的检查点会因条数相同通过 `count - tailRows` 核对（两边同一前缀圈进的日志并不相同），RWKV 状态静默缺评分；起点错开后两代游标空间不相交，旧主快照指纹必不相等、旧检查点必被拒，第一次对齐必然全量重放（`training_tests.rs:protocol_3_checkpoints_and_fingerprints_never_fit_the_new_library`），S1 换代**不必**删 RWKV 快照目录。`rwkv_log_tail` 带行时每行尾巴 5～8 次点查，只适合增量尾巴（调用方传上次的最大序号）| 已接（S1b：同上；`rwkv_rows` 模式 1 与 `rwkv_log_tail` 页里本来就有 profile 行。进程内换库时 RWKV 内存态的处理见 §8.6） |
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
  G9-4 的身份命令 `identity` / `collection_adopt` 建，其余命令不顺手建，见「G9-4」一节）。本机状态行与 `device_hint` 不要绑定。
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

- 未接线（报 ``gen4: not wired yet: `<op>` belongs to <owner>``，不 panic、不回落协议 3）。下面是 S1 时的清单；W2 合流
  （`pr/srs-gen4-w2-merge`）后 G11-3（§15）接了 `import` / `export`，G8-7（§17）接了同步一轮的大部分，`dispatch.rs`
  `wiring` 里仍是 `Unwired` 的只剩 G9-5 这一组与 G8-7b（`relay_outbox` / `relay_ack` / `obsolete_former` / `media_*`）：
  - G9-5：`profile_uids`、`orphan_sweep_done`、`profile_merge_mark` / `_commit`、`meta_set_edit`、`profile_purge`
  - G8-7：收段 / 发件 / head / plan / 中继 / 废弃 / 摘要 / `retire` / `rotate` / `location_seal*` / `media_*`（媒体同步）
  - G11-3：`import`、`export`；G11-4：`ffsrs_store_snapshot`
  - G7-6 / D21：`ffsrs_store_legacy_*`
- 已删（报 ``gen4: removed: `<op>` (<原因>)``）：`refresh_keys`（派生层随写入维护，没有「待刷新」）、`channel_settle`（没有收段通道）、
  `migrate` / `replay_all` / `legacy_dots` / `backfill_*` / `edits_rewrite_repr`（协议 3 存储细节）、`gen4_rehearse*`
  （换代前才有意义）。
- `entity_views` 没有协议 3 对应命令，线上形状归 G10-2，S1 不接。
- §7.6（带盐成员上被扣住的删除 `resolve` 不掉）**已修**（G7-4g，方案 1：扣住按类判，`weigh.rs` `weigh_holds`），已在集成分支里。

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

### 8.6 S1b 收尾接线（2026-11-17，分支 `pr/srs-gen4-s1b-wire-tail`）

S1b 把 G7-4f（评分预览、逐卡重放 / 训练集）与媒体回收接上，§8.4 的 G7-4f 与「S1 后续」两项清空。**schema 不变**
（仍是 40019；分给 S1b 的 40020 没用上：待回收集合放现有的本机状态行，媒体回收的读走现有键）。`ABI_VERSION` 不变
（C 入口签名与输入 / 输出布局都没变）。

- **`preview`**：`dispatch.rs` 的读臂，请求形状同协议 3（`card` / `note?` / `now` / `utcOff` / `rollover`），集合号与
  `cmd/preview.rs` 同一个读快照。
- **C 直出入口按哪个集合读**（`dispatch.rs` `direct_col`）：协议 3 这些入口按全局唯一的卡 ID 读、不分 profile，Dart 给
  `history_states` / `stat_projection` / `optimizer_items` / `calibration_items` / `rwkv_rows` 模式 0 的页里没有 profile
  行（这一段 Dart 不动）。取舍：页里带 `[-1, profile]` 行就按它的绑定（没绑定明确报错）；没有就看文件里有几个集合——
  一个（一个 profile 目录一个 profile 的通常情形）就是它，一个都没有用空集合号 0（结果 = 卡不存在的形状），几个时按
  请求里的卡认（卡的别名类里任何成员在哪个集合里有日志或修改，`HOLDS_ANY_CARD_SQL`：一个集合一条语句，全部卡经
  `json_each` 一次传进去、在 SQL 里归一并展开别名类，语句数 = 1 + 集合数、与卡数无关；最初逐卡在 Rust 里点查，几万张卡
  的多 profile 库每个无关集合几十万次查询，复核后改掉；`direct_col_runs_one_statement_per_collection` 钉住语句数）；对不上任何集合 = 卡不存在的形状，
  对上不止一个明确报错（不拼两份历史）。迁移来的多 profile 库里协议 3 的实体本来就只属于一个 profile，按卡认不会撞。
  **G7-5 建议**：Dart 改调用时在这五个入口的页里补 profile 行，按卡认集合就只剩兜底。
- **媒体回收**（`cmd/media_gc.rs`）：
  - 待回收集合是本机状态（不进真相、不同步、不参与对拍），存在新代本机状态行的 `mediaGc` 键（`local.rs`
    `media_gc_pending` / `set_media_gc_pending`），键名与形态同协议 3（排序的字符串数组，空集合没有这个键），整行读改写
    时原样留着、`local_state` 回包不带它。**迁移不带**（本机状态行整行不迁移，§8.2）：换代时还没回收的名字留在旧库里，
    这些文件这一轮不删——宁可多留；以后引用它们的笔记删除满保留期时会重新成为候选。
  - 存活引用 = 缓存层 `notes.media_refs`（按规范 ID 物化：一个别名类一行，类里每个成员上写的字段都在那一行里）∪ 全部
    笔记类型（含已删除的）现行模板与 CSS 的引用（每个规范笔记类型：类的定义 + 按类判定的修改拼视图，同缓存层）。
    并候选的 `notes` 先归一再读缓存行（派生层随写入维护，同一个事务里缓存行就是字段现值算的）。逐名回收规则、参数、
    「只留裸文件名」都是协议 3 同一个函数。
  - **读不全就不删**：协议 3 在缓存行没刷完时回 `deferred`；新代提交后不欠刷新，但缓存层只在设了缓存配置之后才物化，
    没设（或 profile 没绑定集合）时 `notes` 没有行、存活引用是空的。此时 `collect` 回 `deferred` 什么都不删，
    `media_live_refs` 明确报错（调用方的位置清理拿空集合会把位置上的媒体全当无引用），`queue` 只收直接给的名字。
  - 查询：并候选的笔记按 `notes` 主键点查；「过期的已删笔记」「存活笔记」两条按 `col` 圈出这个集合（规划器在主键与
    `notes_dupe` 之间二选一，都是这个集合的一段；回收本来就要读这个集合的全部存活笔记，不为前者另建索引）；笔记类型走
    `ent_kind` 部分索引。`dispatch_tests.rs` `s1b_statements_use_their_keys` 钉住。
  - `queue` / `collect` 走 `G4Core::write_local`（同一把写锁、同一种事务，**不推进写入代数**）：它们只改本机状态行，
    不是统计原料；走 `write` 的话后台按游标分批回收每批都让统计原料缓存失效、下一次统计整份重算。`write_local` 的 `f`
    不得动真相与派生层。`media_gc_writes_keep_the_write_generation` 钉住（改回 `write` 就红）。
- **按类取日志代表只有一份**：`cache.rs` `Index::log_class_rep`（类里每个成员 `win = 1` 那份里操作号最小的），缓存层
  `card_logs` 与 `cmd/training.rs` 的 RWKV 尾巴（`is_rep`）都调它；原来两处各写一遍。复核要的变异测试：
  `tests_class.rs` `the_log_tail_names_a_class_only_through_its_smallest_op`（`since` 卡在同一条日志的两份带盐导入之间，
  尾巴里只有后落库、操作号大的那份，不出行）——把代表规则改成取操作号最大的就红（实测；原有的
  `training_reads_see_a_log_class_once_through_any_member` 在这个变异下仍绿）。
- **进程内换库时 RWKV 内存态**（复核 nit）：RWKV 状态机（`fushi_rwkv` `sched/machine.rs`）的内存态是 `replayed`（已回放到
  的指纹 (行数, 最大 rowid)）、`checked_revision`（宿主落库键 `SrsDbStore.landedFingerprint`）与快照 / 检查点文件。
  核过的结论：
  1. 契约路径：RWKV 服务挂在一个 `SrsDbStore` 上（`srsAttachRwkv`），宿主关库前 `await service.close()`（存快照、关 runtime），
     关了的服务永远不就绪。Dart 的换代顺序（§8.1：关掉所有协议 3 句柄 → `gen4_migrate_run` → 再开）因此是「旧服务关、新
     服务开」，新服务没有内存态，只有磁盘上的快照与检查点：协议 3 留下的指纹最大 rowid < `SEQ_BASE`（2^40），新库的最大
     序号恒 > `SEQ_BASE`，主快照指纹必不相等；检查点的 `count - tailRows` 必为 0（G7-4f 已钉的
     `protocol_3_checkpoints_and_fingerprints_never_fit_the_new_library`），对不上就走第 4 级全量重建。协议 3 库是空库
     （行数 0）时 0 = 0 能对上，但那时「从空状态追加全部行」就是全量回放，结果相同。
  2. 违约路径（同一个服务对象跨了换库，G7-5 不该这样接）也不会给出错误状态：`checked_revision` 的捷径只在宿主给的
     落库键与上次相同时才走（协议 3 的落库键来自 `refresh_keys`，前缀每次开库随机生成；新代删了 `refresh_keys`，G7-5
     换的落库键要同样保证换库后不与旧值相同，例如带上迁移后新生成的本机纪元）——即使撞上，内存里的状态也是同一批复习
     （迁移不改日志内容）的回放，只是游标是旧的，下一次对齐照样走下面这条路；`tail_after(协议 3 的最大 rowid)` 把新库的每一行都算成新增，
     追加（第 1 级）只接受严格晚于已回放最后一条的评分，旧评分必然不满足 → 退回重放（第 2 级）的
     「`count - tailRows` = 已回放行数」核对 0 ≠ 旧行数 → 全量重建。代价是那一次 `append_new` 带行取尾巴：
     `rwkv_log_tail` 带行每行 5～8 次点查（§7.5），大库上是一次可感的慢查询——所以 G7-5 要按契约换库时换服务。
  结论：S1 / S1b 换代**不必**删 RWKV 快照目录，也不必在内核里加库代标记；G7-5 照 `srsAttachRwkv` 的契约在换库时关旧服务、
  挂新服务即可。
- 测试（`dispatch_tests.rs`，一律经 C ABI）：`preview_and_training_entries_through_the_c_abi_match_protocol_3`（迁移前后，
  页里带 / 不带 profile 行，六个入口逐字节对拍，RWKV 指纹的最大序号两代各是各的游标、比之前置零；没绑定的 profile 报错；
  preview 五种卡经 `sync2` 对拍）、`direct_entries_find_the_collection_by_their_cards`（两个集合：按卡认、对不上、两边都有报错、
  带 profile 各读各的）、`media_gc_through_the_dispatcher_matches_protocol_3`（三条命令逐条对拍，回收两侧各一个媒体目录，
  分批游标、删掉 / 留下的文件、剩下的集合都相同）、`media_gc_reads_references_through_the_alias_class`（带盐成员字段上的引用
  算存活，按另一份成员 ID 并候选取整个类那一行）、`media_gc_defers_while_live_references_cannot_be_read`、
  `s1b_statements_use_their_keys`。

## 10. G9-4 身份命令（2026-11-17，分支 `pr/srs-gen4-g9-4-identity-commands`）

实现在 `store/gen4/cmd/identity.rs`，接线在 `store/gen4/dispatch.rs`（`identity` / `binding_set` 从「未接线」改「已接」，
另加 7 条新代才有的命令），测试 `store/gen4/cmd/identity_tests.rs`（一律经 C ABI）。存储层全部复用：`truth.rs` 的
`bind` / `binding_of` / `settle_binding` / `create_self` / `self_identity`、G9-3 `identity.rs` 的 `Truth::join` /
`adopt_foreign` / `Index::joins`、`alias.rs` 的 `canonical` / `key_evidence` / `hollowed` / `withheld_salts`。没有新
语句、没有加表或索引（schema 不升，分到的 40021 没用）；`store/ffi.rs` 没动。

### 命令

| 命令 | 读/写 | 请求 | 回包 |
|---|---|---|---|
| `identity` | 写（已有身份时是读） | `{profile, now}` | `{device, collection, dir, nextSeq, migrated, name, public}` + 建了时的 `bindingChanged` |
| `binding_set` | 写 | `{profile, state, via, now}` | `{binding: {state, via, at}}`，与协议 3 逐键相同 |
| `collection_info` | 读 | `{profile}` | `{profile, collection, dir, salts, binding, joins: [{op: {device, seq}, from, dir, salts, trusted}]}` |
| `collection_join` | 写 | `{profile, into, dir, now}` | `{outcome: "joined", op, from, fromDir, rebound, collection, dir, settled}` + `bindingChanged` |
| `collection_salts_add` | 写 | `{profile, salts, now}` | `{outcome: "same"}` 或 `{outcome: "saltsAdded", op, settled}` + `bindingChanged` |
| `collection_adopt` | 写 | `{profile, collection, dir, salts?, confirmed?, now}` | `{outcome: same / alreadyJoined / needsConfirm / bound / joined / saltsAdded, …}` + 有变化时的 `bindingChanged` |
| `canonical_ids` | 读 | `{profile, ids}` | `{ids}`：逐个归一，顺序与条数照请求；一次最多 `LOOKUP_MAX` = 4096 条，超了报错、调用方分批 |
| `key_evidence` | 读 | `{profile, items: [{kind, entity}]}` | `{evidence: [n…]}`；成员 ID **原样**问（这是拿另一台 `divergence` 列出的成员来查分叉，归一会把分叉抹平）；上限同 `canonical_ids` |
| `divergence` | 读 | `{profile}` | `{hollowed: [{kind, entity, purges, distrusted, evidence, pending}], withheldSalts: [{salt, ops}]}` |

`collection_salts_add` 走 `adopt_foreign` 的「同一个集合」分支（判据与事件只在 G9-3 那一处）；`collection_adopt` 是
`adopt_foreign` 的命令外壳（G11-3 / G11-4 / G9-5 调），结论 `bound` 时同一个事务里建本机身份。

### 定案（所有者授权自定，理由一并记下）

1. **身份与绑定只在两处建**：`identity`（Dart 每次打开 profile 都调，协议 3 `sync2_identity` 同样「没有就建」）与
   `collection_adopt` 的 `bound`。其余按集合的命令遇到没绑定的 profile 照旧报 `has no collection`，**不顺手建**：
   建身份要可信的时刻（身份建立时刻、`Salts` 的 HLC 起点），读命令与 `cache_config_set` 等的请求里没有 `now`，内核
   不读系统时钟（Dart 的时刻来自校时时钟，系统时钟错了会把本机 HLC 推到未来）；顺手建还会让「先加入」永远走不到。
   Secondary 上没有身份时 `identity` 报只读，等主进程建。
2. **全新 profile 的集合 = `collection_of(uid)`、目录名 = uid**，与协议 3 `Local::create`、迁移（`dryrun.rs` 的 `bind`）
   同一口径。**有意偏离设计 §5.1「新集合随机 UUIDv7」**：同一个 uid 的两台设备（协议 3 时代采用过同一 uid 的、D32
   服务端 uid = 目录名的）不用并入就是同一个集合，行为与协议 3 一致；全新库与「迁移一份空的协议 3 库」逐表相同，
   派生层只有一条路。设计稿 §5.1 / §4.3 与规划 §4「实现补记」已同步加注：判「新集合」看有没有 `v3/meta.json`，
   不看目录名形状（G8-7 围栏、G9-5 关联、G10 host 目录照此实现）；「目录名 = 本机 uid」的读法仍然禁止（并入 / 认领后不成立）。
3. **新身份**：随机 UUIDv7 设备 ID（`migrate::random_device`）、随机签名钥匙、时钟从零起；集合的盐集合里没有这个
   uid 就在本机日志写一条 `Salts{uid}`——与迁移的初始盐同口径：G9-6 之前 Dart 仍按 profile uid 加盐算内置实体 ID
   （默认牌组等），盐在集合里才归得到规范 ID。
4. **`bindingChanged` 就放在回包里**：可能改绑定的命令（`identity` 第一次建、`collection_join` / `collection_salts_add`
   / `collection_adopt`）把存储层的 `BindingChanged` 交给分发器，`write_binding` 在 `G4Core::write` **提交成功之后**
   写进回包 `bindingChanged: {profile}`；提交失败或命令中途 panic（被回滚）就没有回包，事件随之丢掉（缺口 G-4 的
   「返回 Some 就发了、回滚就没发」逐条命令卡住：`collection_join`、`collection_salts_add`、`identity`（全新库）、
   `collection_adopt` 的 `bound` 与 `joined` 各有一次提交前 panic 注入；「进了写路径但绑定没变就不发」由
   `identity_that_only_builds_the_local_identity_reports_no_binding_change`（已绑定、只缺本机身份、盐里已有 uid）与
   `a_second_caller_that_also_saw_no_identity_builds_nothing_and_reports_no_change`（两个调用方都看到「没有」、后进
   事务的那个只是读，同一个设备 ID）卡住）。内核没有另起一条事件
   流：Dart 的每条内核命令都经 `SrsDbStore` 同一个入口，回包就是事件流。`binding_set` 只写 `state` / `via` / `at`
   三列（不属于 `Binding`、不影响任何 ID），不发。改绑定的命令**不推进本机修订号**（不是 `LOCAL_WRITE_OPS`）：
   Dart 收到 `bindingChanged` 要按「库换了」整份重读，而不是靠修订号。
5. **`identity` 回包**：`legacyWriter`（协议 1 写入者 ID，`legacy_clock.rs`，迁移不带）与 `channel`（收段通道，新代没有）
   **不回**——不回占位值：`legacyWriter: null` 会让 Dart `writerId` 的非空断言在用到时才炸，缺键在改调用点时一眼可见。
   `migrated` 恒为 true（Dart 不再发已删的 `migrate`）；`nextSeq` = 本机原生日志末尾 + 1；`name` = `device_info` 的人读名；
   新增 `dir`（设计 §5.1：同步目录向内核要，不再按 uid 拼）。请求里的 `legacyDevice` 忽略。

### Dart 侧要跟着改的调用点（本 PR 不改）

- **G7-5**
  - `packages/fushi_engine/lib/srs/srs_db_store.dart:426-463` `SrsDbStore.open`：现在的顺序是 `local_state` →
    `cache_config_set`（`_registerCacheConfig`）→ … → `ensureBuiltins` → `_sync2Open`（`identity`）。全新 profile 上
    `cache_config_set` 会先撞「没绑定」：**`identity` 必须挪到第一条按集合的命令之前**（`local_state` 不要绑定，可以在前）。
  - 同文件 `_sync2Open`（:479-496）：不再发 `legacyDevice`；`_legacyWriter` 恒为 null，`writerId`（:853，`_legacyWriter!`）
    与 `isOwnWriter`（:856）的旧写入者部分删掉；`migrated` 恒真，`migrateLegacy` / `_sync2MigrateAll` / `_sync2MigrateBatch`（:509-545，发已删的
    `migrate`）删掉。
  - 同文件 `_sync2Raw`（:2243）：每条回包看 `bindingChanged`，有就发 `onBindingChanged()`，缓存的 `kernelIds` /
    `defaultDeckId` / `lapisNoteTypeId` / `fushiCardNoteTypeId` 失效并整份重读（设计 §5.1）。
  - 同文件 :2151（`import` 之后再取 `identity`）只读 `device`，不受影响（`import` 本身归 G11-3）。
  - `setCollectionBinding`（:5526，`binding_set`）形状不变；要求 profile 已绑定（打开时 `identity` 建好）。
- **G8-7 / G9-5**
  - 读 `identity` 的 `collection` / `device` 的同步路径形状不变：`sync2/srs_sync2_round.dart:202/264/361`、
    `sync2/srs_folder_location.dart:238`、`sync2/srs_location_migration.dart:560/604/698`、`sync2/srs_sync2_pull_first.dart:74`。
    位置目录名改用回包的 `dir`，不再按 uid 拼（`srsLocationDirOf(profileUid)`：`sync2/srs_folder_location.dart:83/96`、
    `srs_profile_link.dart:359/407`；`sync2/srs_location_runner.dart:39-47`，设计 §5.1）。
  - 关联流程（`srs_profile_link.dart` / `srs_profile_merge.dart`）的「采用对方 uid」改成 `collection_adopt` /
    `collection_join`（G9-5）；备份合并的 `adoptedUid`（`srs_backup_merge.dart`）改 `collection_adopt`（G11-3 / G11-4）。
- **G10**：分叉提示（D30）读 `divergence`、到另一台问 `key_evidence`。

### 没做 / 交给谁

- **合并条件（已写进规划 §6）**：G7-5 把 `identity` 挪到 `cache_config_set` 之前、删 `legacyWriter` 相关代码，整批合入
  develop 前用全新 profile（空库、新建 profile 两种）经 app 打开做一次端到端验证；在这之前集成分支上全新 profile
  打开仍会先报 `has no collection`（S1 之后本来就如此，不是本 PR 的回归）。
- **「先加入」在 app 里走不到**（**G9-5 必做**，规划 §6 合并条件；涉及 G9-3 的 `identity.rs` 判据；验收：端到端测试
  「新设备打开 profile 后再关联已有集合，结论 `bound`，不产生 `Join`、不需别的设备再确认」）：`identity` 在打开时就绑了新 profile，之后
  `adopt_foreign` 只能并入，不会是 `bound`；新设备关联已有集合时，若本机目录名（= 新 uid）较小，按 D27 是对方并入本机，
  别的设备看到 `Join` 要再确认一次（D25）。建议 G9-5 在 `adopt_foreign` 里加「空集合可换绑」：本机集合的日志只有本机
  身份写的 `Salts`、没有别的设备、从没发布到任何位置（`loc_heads` / `relay_out` 为空）时，确认后同一个事务里丢掉这个空
  集合、绑到对方（结论 `bound`），本机身份在对方集合里重建。
- **`profile_of_dir`（规划 §1.1 G10 行）没做**：`collections.dir` 没有索引，D32 下服务端 uid = 目录名，暂不需要反查；
  需要时加索引（升 schema）并让 `collection_info` 接 `{dir}`。
- `bindingChanged` 只随引起它的那条命令的回包回来；别的进程（Secondary 查词弹窗）看不到。弹窗只读、绑定变化极少，
  G7-5 让 Secondary 在打开 / 重新激活时重取 `identity` 即可。

### 测试（`cmd/identity_tests.rs`，13 条，除「两个调用方」一条直接在 `G4Core` 上跑外全部经 C ABI）

新库建身份 → 写 → 读（含建之前按集合命令报错、没有 `now` 报错、第二次 `identity` 不带事件、Secondary 只读）；迁移库上
`identity` 与协议 3 对拍（`collection` / `public` / `name` / `migrated` 相同，`device_info` 改名后仍相同）与 `binding_set`
逐条对拍；多 profile 各自一个集合、同一集合不能绑两个 profile、没绑过的 profile 经 `collection_adopt` 先问后绑并建身份；
改绑不丢笔记 / 卡片 / 复习日志 / 修改历史、默认牌组的规范 ID 不变、方向反了报错；提交前 panic 不发事件、库不变；补盐
只在真有新盐时发事件；别名类成员经 `canonical_ids` 归一、`key_evidence` / `divergence` 的形状；每条新命令都有臂；
`identity` 进了写路径但绑定没变（只缺本机身份、并发的第二个调用方）不发事件；`identity` / `collection_adopt`（`bound`、
`joined`）提交前 panic 不发事件、什么都没建；`canonical_ids` / `key_evidence` 的条数上限。
`dispatch_tests.rs` 的未接线清单去掉了 `identity`，并把几个装置函数开成 `pub(super)` 给这里复用。

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

## 11. G7-2b 迁移前提补完（2026-11-17，分支 `pr/srs-gen4-g7-2b-migrate-preconditions`，基于 `pr/srs-gen4-switch`）

补 §9.5 第 1、2、7 条。schema 不变（40019；分给本块的 40020 没用上：没有加表 / 索引），`ABI_VERSION` 不变。
复核（同日第二轮）之后改成「在副本上补完」，下文是改完的样子。

### 前提补完（`store/gen4/prepare.rs`，新步骤 `Step::Prepare`，线上 `prepare`）

- 位置：`migrate::run` 拿到换代锁、读过旧库 schema、**拿到原件的写锁**（`hold_legacy`，`BEGIN IMMEDIATE`，不写）之后，
  前提核对（`Step::Precondition`）之前。写锁从这里一直持到封存。步骤数 9 → 10。
- `prepare::plan`（只读）：先拦补不了的——并入做到一半（`legacy::merge_marks`）、旧库里有 profile 没给缓存配置；再按
  `legacy::preflight` + `migration_blockers` 列出要补的 profile。schema 比这一版协议 3 旧时全部 profile 都走一遍（表形态
  不同，`preflight` 读不了）。计划为空 = 不拷副本，读快照直接开在原件上。
- `prepare::complete`：写之前对原件 `PRAGMA quick_check`（不过 = `corrupt`）；用 SQLite 在线备份把原件逐页拷成
  `srs.db-gen4-prepare`（`files::PREPARE_COPY`；一个读快照，含 WAL 里已提交的部分；每 4096 页看一次叫停）；在**副本**上
  `SrsCore::open`（协议 3 的升级阶梯；空间守卫 `UPGRADE_NO_SPACE` 换成 `noSpace`）并经协议 3 分发器 `sync2_dispatch` 发与
  旧 app 同形的命令：`migrate`（`limit` = 迁移的 `batch`）到 `done` → `dedup` 到 `done` 不为假 → `replay_pending`（带缓存
  配置）到 `more` 不为真。每条命令之前看叫停、之后报进度 `(prepare, 已做完的 profile, 要补的 profile 数)`。拷副本前按
  「原件 + WAL 的大小」多核一份空间，补完后按副本再核一次。之后的前提核对、灌入、对拍都开在副本的读快照上。
- 迁移结束（不论结论）删副本；崩溃留下的由下一次迁移（取锁后先删）或 Primary 打开（`files::open_gen4` 补封之后删）删掉。
- **原件在提交点之前逐字节不变**：叫停、panic、进程被杀、对拍中止、补完报错之后，原件都还是写它的那个协议 3 版本能打开
  的库——包括 v3.3.0（schema 26，见下）。所以 `srs_gen4_cancelled` / `srs_gen4_failed` / `srs_gen4_aborted` 里「旧库没有任何
  改动」仍然成立，文案不用改。
- 提交与封存针对原件：新代库记的迁移来源是**原件**的指纹（`files::source_mark`：有身份 = 身份 + 日志水位，与以前相同；
  原件没有协议 3 身份——从没启用过协议 3、或数据只在投影表里，身份是补完在副本里才建的——记 `NO_IDENTITY`（`-`）+ 除
  `srs_meta` 以外全部表的内容摘要，封存只改 `srs_meta`，封存前后一致，别的写入都会改它）。`seal::seal_legacy` 接受
  1..=29（v3.3.0 的原件封存时保持 26，`sealed_from` 记原号）；`files::finish_seal` 对比这一版旧的原件只在它就是迁移来源时
  补封，不是就不动（与以前一样，不当「没迁移的库」拦）。报告的 `legacyIdentity` 也按原件记。
- 只在投影表里的孤儿 uid：`migrate` 在副本里给它建本机身份并把旧行包成操作，迁移时成为新代库里的一个集合，卡片与日志
  不丢。
- 并入做到一半不补（D23：由冻结的旧并入代码做完，它由 Dart 驱动、带着主库那一侧的状态，归 G9-5）。

### 定案

- **schema 较老的旧库升级后迁移，升级只在副本上做。** v3.3.0（最新的协议 3 正式版、D2 的回退目标）是 schema 26
  （`git show v3.3.0:native/fushi_fsrs/src/store/schema.rs`），这一版是 29：从正式版升上来的用户全部走这条路，是主路径。
  第一轮在原件上升级，之后对拍中止 / 取消 / 崩溃，用户就回不到 v3.3.0（它遇到更新的 schema 直接拒绝打开），而这一版又没有
  协议 3 的开库入口；复核后改成在副本上补完，原件提交前不动。代价：补完期间多占一份旧库的空间（空间核对算进去了）、
  每次重跑都从原件重拷重补（不在半份副本上续做，与「提交点之前整个删掉从头来」一致）。
- **不先只拉不发（BUG-4011 的推迟迁移语义没有保留）。** 协议 3 的 app 要等首次同步确认、先从同步位置收一轮才执行
  `migrate`（`srs_sync_scheduler.dart` `ensureMigrated`），为的是只包装还没有任何设备的操作代表的旧行。补完直接在本机
  `migrate`：多台设备、协议 3 同步从没确认过、却共享同一份旧行的用户，每台设备各自把旧行包一遍，迁到新代之后存储里是
  两份操作流。新代派生层按 dot / 日志 ID 取操作号最小的那份（`derive.rs`），用户看到的结果不会错，只是体积与同步量多一份
  （推测，没有实测）。补完时联网收一轮不在迁移的职责里（迁移不碰同步位置）；**交 G8 / G9 判断要不要在新代做副本收敛**。
- 缓存配置不放进内核（§9.5 第 2 条取方案 B）：Dart `srsCacheConfigFor` 虽然只取决于 uid，但内容是内置笔记类型的代码
  默认值（模板 / CSS / 字段，`kSrsBuiltinNoteTypes`），搬进 Rust 等于维护两份、漂移了就是对拍不过；由 Dart 按列表给最稳。

### `blocked` 的机器可读 `code`（`migrate::BlockCode`）

`migrating` / `busy` / `missingCacheConfig` / `mergeHalfDone` / `schemaNewer` / `notProtocol3` / `corrupt` / `noLibrary` /
`sealedWithoutNew` / `legacyBesideNew` / `precondition`（补完之后核对仍不过，不该出现）。`Outcome::Blocked {code, reason}`，
回包 `{verdict: "blocked", code, reason}`；本进程里同一目录已在跑也回 `migrating`。`reason` 只给人看，Dart 不再比对原文。
旧库读不出页头 / schema 表（`SQLITE_CORRUPT` / `SQLITE_NOTADB`）在空间检查之前就报 `corrupt`；页头完好、页内坏了的由补完前的
`quick_check` 报 `corrupt`。

### 旧库的 profile 列表（§9.5 第 2 条）

独立的全局命令 `gen4_migrate_profiles {dir}` → `{profiles}`（`legacy::all_profiles`：协议 3 一侧的并上只在投影表里的，缺表
跳过；没有旧库 / 读不了 = 报错）。`gen4_migrate_status` 回到 `{state, running}`，只看文件与锁、读一行 schema，Dart 在 UI
isolate 上轮询它。列表要读旧库的大表：每张表按 `profile_uid` 跳着取（`legacy::PROFILES_OF_TABLE_SQL`，递归 CTE 的松散
索引扫描，每步一次「`profile_uid > 上一个`」的 `MIN`，代价 profile 数 × log(行数)；以前是 `SELECT DISTINCT
srs_idt(profile_uid)`，对函数结果去重要整索引扫，BUG-4011 现场光修改记录就有 64.5 万行），协议 3 一侧也不再
`UNION` 整个 `sync2_ops`。`srs_unknown_events` 没有 `profile_uid` 打头的索引（通常没几行），每步是一次全表扫描。Dart 在
后台 isolate 调（`SrsGen4Migration.legacyProfiles`，`Isolate.run`）。

### Dart

- `SrsGen4MigrationStep.prepare`（第 3 步，提交点之前可取消）；`SrsGen4Migration.legacyProfiles`（后台 isolate）；
  `SrsGen4MigrationStatus` 去掉 `profiles`；`SrsGen4MigrationOutcome.code`；`SrsGen4BlockedReason` 按 `code` 分 `migrating` /
  `busy` / `newerBuild`（schemaNewer）/ `damaged`（corrupt、notProtocol3）/ `mergePending` / `precondition`（其余与不认识的
  code），`retryable` 只有 migrating、busy、precondition。`kernelCodes` 与 migrate.rs `BlockCode::wire`、步骤与 `Step::wire`
  由 Dart 测试读 Rust 源码核对；另核 `gen4_migrate_profiles` 在 kernel.rs / lib.rs 有路由、Dart 侧在 `Isolate.run` 里调。
- 控制器：缓存配置给「主库 profile ∪ `legacyProfiles`」（列表读不到只记日志、按主库的给，缺了内核点名拦下）。`canStart` =
  没在跑且主库开着（`AppModel.isDatabaseOpen`）；新增 `databaseClosing` = 收到过关库信号（`databaseCloseNotifier`）且主库
  还没重新开好——启动中还没初始化完只置灰、不说「正在关闭」；控制器同时听 `AppModel` 本身（初始化 / 重新开库完成时通知），
  `canStart` 变了才通知页面，关库再开库后按钮恢复。§9.5 第 7 条：关库后「开始升级」置灰并说明（`srs_gen4_closing`），
  `start` 无操作。「静默在 provider 建之前也登记」没有另做：`closeDatabase` 先置 `isDatabaseOpen` 为假再等静默，provider 晚于
  关库才建、或在静默清单拷贝之后才建的控制器都开始不了迁移；能开始迁移的控制器一定已经建好、登记过。另找启动时的登记点要
  改 `srs_app_runtime.dart` / `app_model.dart`（别的模块的热点），闸门之后已无必要（复核认可这一论证）。
- 页面：步骤「整理旧库」；`blocked` 每类一句（`srs_gen4_blocked_unfinished` / `_newer` / `_damaged` / `_merge`，删
  `srs_gen4_blocked_precondition`），等一会再来的两类不给原文，其余给原文；`retryable` 的恢复「重新升级」。

### 测试

- Rust `store/gen4/prepare_tests.rs`（17 条）：从没同步过（`migrated_at` 为空、旧修改与旧日志在投影表）、协议 3 迁移做到
  一半（队列有残留）、收段残留（待重放 + 待刷新缓存 + 去重作业）、**只剩待重放 / 待刷新缓存**（`migrated_at` 已写，只有
  `migration_blockers` 判得出）、孤儿 profile（经 `gen4_migrate_profiles` 取列表、按列表给配置后提交、两个集合；只给主库配置 =
  `missingCacheConfig` 且旧库逐字节不变）、**没有协议 3 身份的原件**（记 `NO_IDENTITY`）各一次提交、对拍全过、新代库日志条数
  不少于旧库，且原件里补完前的状态原样（`migrated_at` 仍空、队列 / 残留表行数不变）。**v3.3.0 的库**：夹具把这一版的库去掉
  `sync2_trust` / `sync2_trust_held`、号写回 26（26→29 的阶梯只有 v29 建这两张表，v27 / v28 只改数据；≤26 的步骤与 v3.3.0
  逐字相同，见 `git diff v3.3.0 HEAD -- native/fushi_fsrs/src/store/schema.rs native/fushi_fsrs/src/store/sync2/schema.rs`），
  计划 = 升级 + 全部 profile、列表命令在旧表形态上列得出、对拍与提交两步时原件逐字节不变、提交后原件只多了封存（仍是 26 的
  表形态）；叫停 / panic 后原件仍是 26 且逐字节不变、重跑提交；子进程被杀（三个断点 × 这一版 / v3.3.0 两种库）后原件逐字节
  不变、重跑提交；**提交点之后、封存之前被杀**（v3.3.0 原件与无身份原件）由 Primary 打开补封、清掉副本，之后原件又被写过的
  不封、不动。页内损坏（页头与 `srs_meta` 完好、缓存表索引页坏）= `corrupt`、不拷副本、原件逐字节不变；整文件垃圾 =
  `corrupt`；并入做到一半 = `mergeHalfDone`；就绪库计划为空、不拷副本。EXPLAIN：`PROFILES_OF_TABLE_SQL`（实现执行的同一个
  常量）在六张有 `profile_uid` 索引的表上每一处都是 `SEARCH … INDEX / PRIMARY KEY`。`files.rs`：无身份来源按内容摘要记、封存
  前后对得上、写入后对不上。`seal.rs`：schema 26 照封、`sealed_from` = 26，0 / 40006 拒绝。
  `migrate_tests.rs` 改：步骤序列含 `prepare`、各拦下带 code、schema 新于这一版 = `schemaNewer`、非数字 = `notProtocol3`。
- 变异实测（每条都让对应用例变红，复核轮全部重做）：旧 schema 一律拦下（`v == SCHEMA_VERSION`，v3.3.0 四条红）、计划去掉
  `migration_blockers`（只剩残留那条红）、吃掉 `quick_check` 结论（页内损坏那条红）、补完不拷副本直接写原件（11 条红）、
  封存只认 29（v3.3.0 四条红）、补封不认旧 schema（提交点后被杀那条红）、迁移来源按副本记（无身份两条红）、列 profile
  换回 `SELECT DISTINCT srs_idt(profile_uid)`（EXPLAIN 那条红）。第一轮的：跳过补完、去掉 `dedup`、去掉 `replay_pending`、
  列表只认协议 3 一侧、补完里不看叫停。
- Dart：`srs_gen4_migration_test.dart`（code 与 Rust 核对、分类、retryable、状态只带 state / running、列表命令的路由与
  isolate、步骤与 Rust 核对）、控制器测试（孤儿 uid 并集、列表读不到退回主库 profile、启动中不算正在关、关库后再开库恢复、
  关库后不开始）、页面测试（七种 code × 两套设计、关库置灰 × 两套设计、启动中置灰不说正在关 + 再开库恢复 × 两套设计、
  步骤 n/10）。

### 已知 / 交出去的

- 集成分支上 `cmd/dispatch_tests.rs::unwired_and_removed_commands_name_their_owner` 本来就红（G9-4 已把 `binding_set` 接上，
  用例仍断言它未接线），不在本块文件边界内，没改。
- 并入做到一半的旧库仍迁不了（`mergeHalfDone`），归 G9-5。
- 协议 1 主库（D21）不在此列，归 G7-6。
- 多设备、从没同步过的用户迁移后多一份操作流（见「定案」第二条），交 G8 / G9。
- 没有协议 3 身份的原件对拍中止后，`gen4_migrate_status` 不报 `migrationFailed`（报告的 `legacyIdentity` 为空，状态命令按
  身份认报告，算内容摘要太重不放进 UI isolate 上的状态命令），页面显示「需要升级」、重跑会再中止一次并重写报告。不丢数据，
  只是少一个「上次失败」的提示。
- v3.3.0 夹具是由这一版的库改出来的表形态（理由见「测试」），不是 v3.3.0 二进制建的库；v3.3.0 的协议 3 代码在别的方面
  （例如投影的写法）与这一版的差别不在夹具里。真机 / 真实 v3.3.0 用户库的回归没做（本机没有 v3.3.0 构建）。

## 12. S1c 刷新计数与写回包（2026-11-17，分支 `pr/srs-gen4-s1c-refresh-counters-apply-reply`，基于 `pr/srs-gen4-switch`）

收掉 §9.5 第 3、4、5 条。schema 不变（没加表 / 索引，分到的 40021 没用）。

### 刷新键（`gen4/refresh.rs`，命令 `refresh_keys` 由 Removed 改为 Wired）

- `G4Core` 持有 `refresh: Mutex<Refresh>`：开库随机标识 + 按 profile 的五个计数（content / view / rwkv / stats / landed），
  键形同协议 3（`<开库标识>:<n>`，`structure` = `<开库标识>:<content>:<view>`）。Primary 读只碰内存。
- 推进规则（与协议 3 `store/refresh.rs` + `sync2/mod.rs` `Marks` 同口径，文件头有表）：`Session::land` 按每条操作体记
  一份 `Tally`（日志 → landed + stats；界面状态修改 → landed + view；其余修改 / 身份记录 → landed + content + stats，
  牌组 / profile 的再加 rwkv；标签操作、彻底清除 → landed + content + stats；还原点什么都不动），`Session::finish` 写进回包
  `refreshTally`，`dispatch.rs` `local_write` 在**提交之后**取走（不交给 Dart）再推进；`apply {remote}` 落了东西加 rwkv。
  信任改了 → content + stats + landed；`digest_heal` 的整层重建、`cache_config_set` 改了配置、`rebuild_caches`、
  `refresh_caches` 实际收了东西、`identity` 第一次建绑定、`binding_set` / `collection_join` / `collection_salts_add` /
  `collection_adopt`、`local_state {reload: true}` → 整份作废。只写本机状态行 / 设备信息 / 媒体回收集合的不推进。
- 定案（所有者授权自定）：
  - 命令失败不推进（协议 3 按「可能提交了一部分」作废一次）：新代一条命令一个事务，失败什么都没落。
  - **Secondary** 看不见主进程内存，五个键同值，一个读快照里拼
    `<开库标识>:s:<纪元|unstored>:<修订号>:<gen>.<floor>:<绑定指纹>`：修订号（本机状态行，主进程每条改投影的写命令同一笔
    事务推进）+ 缓存层代号 `cache_gen`（补上修订号不覆盖的整层重建）+ 绑定指纹（`collections` 那一行——集合标识、位置
    目录名、盐集合、绑定状态——的散列，没绑定记 `-`）。只用 `cache_gen` 不够：牌组收起 / 排序位、profile 设置不碰缓存行，
    代号不动。绑定指纹是复核后补的：`collection_salts_add` / `binding_set` 这类身份命令不推进修订号，实测补一个还没有数据
    的盐也不推进 `cache_gen`，原先 Secondary 看不到（Primary 整份作废）。不改身份命令本身去推进修订号：修订号是 Dart
    `changeFingerprint` 的一半、按「投影变化条数」记，身份命令不归本模块。Secondary 只会多重读。
  - 收段会话期间的 RWKV 延后（协议 3 `rwkv_held`）属于同步命令，G8-7 接 `ingest_*` 时按协议 3 口径补（`refresh_note`
    的 `merged` 入口已在）。
- Dart：`SrsCore.refreshKeys` 改发 `refresh_keys`（`srsRefreshKeysOf` 解析、缺键报错），删 `srsRefreshKeyOf`。
  `SrsDbStore` 的五个指纹与 `_structureKey` 注释恢复按类语义：作答只动 `statsFingerprint` / `landedFingerprint`，RWKV 分数表
  不再每题整表重查（`SrsRwkvService` 读 `rwkvScoresKey`，没改代码），牌组树 / profile 修改记录不再每题重建。

### `apply` 回包（`cmd/writes.rs` 文件头「回包」）

- `edits` 每项第 7 列 = 输入下标（`apply` / `change` 原样，`import_drafts` 按筛掉初值之前的原输入，意图命令自己拼的 /
  直接落的 = null）。
- `tagWrites`：整列表 `tags` 项一条 `[输入下标, 规范笔记, 设备, 展开出的最后一条操作的 seq]`；不进 `edits`（撤销记录器的
  `noteWritten` 按 dot 撤修改记录，标签走 `noteTags` 差量撤，混进去会改变撤销行为）。
- `logHlcs`：请求带 `logHlcs: true` 才报，`[输入下标, 规范日志 ID, HLC]`（与 `read logs` 行的 `hlc` 同形）。默认不报：导入
  成批日志时回包会线性涨。
- `stamps: true` 仍拒，替代形状就是上面三项。
- Dart：`_readBackEdits` 按下标认领（`srsWrittenByInput`，一条输入认领两次 / 越界报错），删 `srsMatchWrittenEdits` 与
  `_canonicalDraftIds`（N+1 点查）；标签草稿取那条笔记读侧合成的 `tags` 行。作答发 `logHlcs: true`，`_answeredLogHlc` 从回包
  取，删按卡读全部日志的 `_storedLogHlc`。

### 测试（`cmd/refresh_tests.rs`，全部经 C ABI；`refresh.rs` 单元测试 4 条）

- 与协议 3 对拍：迁移前后两侧发同一串写入（作答、改字段、建牌组、收起、改名、标签、no-op、还原点、彻底清除、remote、
  reload、stale），每步「哪几个键变了」相同，并钉住作答 = `[stats, landed]`、收起 = `[structure, landed]`。
- 整层重建作废、只写本机状态行不动；Secondary 五键同值、随作答 / 收起 / 重建变；带盐成员上的修改与标签按下标认领、实体与
  键是规范形；`logHlcs` 与 `read logs` 一致、不要就不报。
- 变异实测（各自让对应用例变红）：日志推进 content/rwkv、界面状态当内容、分发器不推进、`edits` 丢下标、`tagWrites` 丢下标、
  Secondary 键去掉修订号。
- 复核补测（2026-11-17）：`import_drafts` 前面放一条会被筛掉的 `init` 项，后面的修改回包下标 = 原输入下标 1（变异：
  `Origin::Kept` 改 `Origin::Caller` 变红）；Secondary 随 `collection_salts_add`（`saltsAdded`）与 `binding_set`
  （provisional → settled）变、同样内容再发（`same` / 已 settled 只进不退）不变（变异：键里去掉绑定指纹变红）。
- 小节标号：本节不带编号，代码里按节名引用（`writes.rs` / `refresh.rs` 文件头），合流统一编号时不用改代码。
- 顺手修：`dispatch_tests.rs` `unwired_and_removed_commands_name_their_owner` 里 `binding_set` 还当 G9-4 未接线（G9-4 已接，
  集成分支上这条本来就红），删掉该行。

### 没做 / 交给谁

- 撤销记录器 `_SrsUndoRecorder.noteWritten` 仍按 `(种类, 实体, 字段键)` 对 `_before`：草稿点名别名类的非规范成员时回包实体是
  规范形，对不上、这一项的 dot 记不下（撤销退回无 dot 的比较）。现在有输入下标可以改成按下标认领，但不在本模块点名的段落里，
  留给 G7-5b。
- `srs_core_test.dart` 用本 worktree 编的 quick 版 `fushi_fsrs.dll`（`FUSHI_FSRS_LIB`）跑过；顺手把「未接线命令带类型」用例里的
  `identity`（G9-4 已接）换成 G9-5 的 `profile_merge_mark`。`SrsDbStore` 层的 `srs_fingerprint_instance_test.dart` 等还按
  `srs.db` 路径开库（新代开库要目录），且要 `fushi_compute`，本机没跑；改写归 G7-5b。

## 13. G7-5b 开库先取身份、绑定变化、直出入口带 profile（2026-11-17，分支 `pr/srs-gen4-g7-5b-dart-open-identity`，基于 `pr/srs-gen4-switch`）

纯 Dart，Rust 未改。

### 13.1 开库顺序与身份

- `SrsDbStore.open`：`_loadLocal` → `identity`（`_sync2Open`，第一条按集合的命令）→ 主进程才 `_registerCacheConfig` /
  `_ensureLocalState` / `ensureBuiltins` → `_loadRootIds`。设备号 / 集合 / 目录一律取 identity 回包（`sync2Device` /
  `sync2Collection` / `sync2Dir`），不再发 `legacyDevice`；构造参数 `deviceId` 只剩 app 层用途。
- 删了旧写入方身份那套、`_sync2MigrateAll` / `_sync2MigrateBatch`。`migrateLegacy` 留成空操作：唯一调用方是 G8-7 的
  `srs_sync_scheduler.dart` `ensureMigrated`，G8-7 删调度时连同 `kSrsSync2MigrateBatch` 一起删。
- 辅助进程（只读）开一个主进程还没建身份的 profile：内核回 READ_ONLY，这里改抛 `SrsProfileIdentityPending(profile)`，
  `srs_load_error.dart` 映射成「先在主窗口打开一次复习」的等待文案（`srs_gen4_profile_pending_primary`，替掉
  `srs_gen4_profile_unbound`）。`srsStoreProvider` 复用已开的库且是辅助进程时调 `refreshIdentity()`（集合 / 目录变了按绑定变化处理）。

### 13.2 绑定变化

- `_sync2Raw` 每个回包看 `bindingChanged`：有就 `onBindingChanged()`（`kernelIds` 置空懒重建、派生缓存 / 笔记类型缓存 /
  RWKV 候选缓存作废、`bindingChanges` 广播）并在根上 ID 已载入时重读 `_loadRootIds`。
- `srsStoreProvider` 与 `srsRwkvServiceProvider` 订阅 `bindingChanges` → `invalidateSelf`：旧 RWKV 服务关掉、新库挂新服务；
  落卡键里带本地纪元，换库后不同。
- 根上 ID（默认牌组 / Lapis / FushiCard 笔记类型）不再按 uid 本地派生，而是 `canonical_ids` 取规范形（§5.2），
  `ensureBuiltins` 按规范 ID 判在不在。

### 13.3 预览 / media_gc / C 直出入口

- 去掉 Dart 侧「暂不可用」兜底；`historyStates` / `statProjection` / `optimizerItems` / `calibrationItems` / `rwkvCards`
  五个直出入口的页里带 `[-1, profile]` 行（按 profile 的集合读，不按卡认），store 传 `profileUid`。

### 13.4 备份

- 未迁移的协议 3 用户：`summarizeLiveContent` 接 `SrsStoreOpenBlocked`，复习类记进 `needsUpgrade`（在 present 里、无计数），
  导出页这一行默认不勾、禁用、副标题「需先升级」（`backup_export_srs_needs_upgrade`）；其余类别照常导出；硬勾复习仍明确失败、不出半份包。

### 13.5 测试

- 新增 `packages/fushi_engine/test/srs/srs_fresh_profile_e2e_test.dart`（4 条：全新 profile 开库→内置→笔记→出卡→预览→作答→统计；
  第二个 profile 互不串且直出入口按 profile 读；辅助进程等待态→主进程建好后可开；`collection_salts_add` 的 `bindingChanged`）。
  用当前 DLL 4 条里 3 条红（见 10.6 上游缺口 1）；用 `salt_of` 返回 `None` 的实验 DLL 4/4 绿。
- 新增 `fushi/test/sync/backup_srs_needs_upgrade_test.dart`（4 条）+ `srs_generation_view_test.dart`：14 条全绿。
- `test/srs/support/srs_test_storage.dart` `openTestSrsAt`：新代 `SrsCore.open` 收库目录，旧写法 `<tmp>/srs.db` 改成当目录建出来
  （已是文件的协议 3 夹具不动、照实失败）。消掉约 76 条「gen4 lock: open …/srs.db\srs.gen.lock」。

### 13.6 已知缺口与上游

1. **上游：`native/fushi_fsrs/src/gen4_ids/derive.rs` `salt_of` 仍返回 `Some(profile)`**。§5.2 要求新写入去盐；现在 Dart 派生的 ID
   全是别名，`createNote` 回的不是规范 ID，新卡被藏、学习队列空。临时把它改成 `None` 编 quick DLL 实测 E2E 4/4 绿（改动已撤回）。
   修了之后 Dart 里大量 `srsLapisNoteTypeId(uid)` 一类的直接比较才成立。
2. 仍红、不归本模块（实验 DLL 下 engine `test/srs` +522 ~32 -422，按类）：G8-7 未接（`location_sealed` 等，含全部
   `fushi_server` SRS 测试——服务端首轮同步跑完才对外提供库，`storeFor` 为 null）；G9-5 未接（`meta_set_edit` / `profile_merge_mark` /
   `profile_purge`，含「stamped items carry a foreign identity」）；G11-3 `export`；直接对协议 3 表（`sync2_self` / `srs_cards_cache` /
   `srs_stat_reviews` / `srs_field_edits` / `srs_review_logs` 等）写原始 SQL 的用例需按新代重写或删；`srs_note_type_cache_test`
   「作答不失效」红（作答推进了内容指纹，属 S1c refreshKeys / stamps 范围）。
3. 本机 release 构建 `fushi_fsrs` 撞 zstd-sys `LNK1106`（环境问题），实验 DLL 用 `--profile quick --features raw_sql` 出。

### 13.7 复核修复（2026-11-17）

- **RWKV 落库键对进程内换库也变**：原来 `rwkvScoresClearKey` 只是本机纪元，迁移后重开会变，但进程内的绑定变化（补盐 /
  认领 / 并入）不重建本机状态行、纪元不变。现在加了绑定代号 `bindingKey` = `srsBindingKey(collection, dir, 升序盐集合)`
  的 SHA-256 前 16 位（盐取自 `collection_info`，identity 回包里没有），清空键是 `纪元|绑定代号`。10.2 里「落卡键带本地纪元」
  这句话以本节为准。
- **绑定变化后重读失败不丢已提交回包**：`_sync2Raw` 收到 `bindingChanged` 时，`_reloadBinding` 依次重读身份、绑定代号、根上 ID。
  中途失败时只把绑定标成过期（`_bindingStale`），原回包照常返回，因为那条命令已经在内核提交了。下一条命令（`_read` /
  `_columnsCommand` / `_sync2Raw`）发出之前先补读，补读失败就由那条还没发出的命令报错。重读自己发的 `identity` /
  `collection_info` / `canonical_ids` 不查过期标记，也不递归重读。
- **辅助进程按绑定代号判变化**：`refreshIdentity` 比较 `bindingKey`，只补了盐（集合 / 目录没变）也算绑定变化。
  identity 回包自己带了 `bindingChanged`、`_sync2Raw` 已经报过时，不再重复报。
- `retire` 时关掉 `bindingChanges` 控制器，作废之后在途回包不再广播。
- **ctl 备份导出与设置页一致**：用 `dropBackupCategoriesNeedingUpgrade`（`ctl_data_routes.dart`）处理。缺省类别或 `all` 时，
  去掉 `needsUpgrade` 里的类别，回包写 `skippedCategories: [{category: srs, reason: needsUpgrade}]`，其余照常导出。
  显式点名 srs 时返回 422 明确拒绝。只有要导出的类别里有复习时才调 `summarizeLiveContent`。
- 导出框里「需先升级」那一行的逻辑抽成可测函数，补了 widget 测试（默认不勾、开关不可点、副标题是需先升级的文案）。
- 测试：`packages/fushi_engine/test/srs/srs_binding_reload_test.dart`，5 条：
  - 重开不重复写内置实体：先补盐，让请求形 ≠ 规范形，第二次打开不产生内置实体写入；
  - RWKV 清空键补盐后变、同一绑定重开不变；
  - 辅助进程只补盐也按绑定变化处理；
  - 重读失败不丢回包、下一条命令前补读；
  - 作废关控制器。

  另有 `fushi/test/ops/ctl_backup_export_needs_upgrade_test.dart`（4 条）和
  `fushi/test/sync/backup_export_picker_needs_upgrade_test.dart`（3 条）。
  每条修复都做了变异实测：去掉修复后对应测试变红。这包括把「按规范 ID 判在不在」改回按请求 ID。
- 仍不归本模块：13.6 第 1 条上游 `salt_of`。修好之后，`srs_fresh_profile_e2e_test` 是 §6 合并条件的必绿门，不加 skip。

## 14. G9-6 偏好与持久化 ID 归一（2026-11-17，分支 `pr/srs-gen4-g9-6-prefs-id-normalize`，基于 `pr/srs-gen4-switch`）

Rust 没动，schema 不升。统一入口一处：`packages/fushi_engine/lib/srs/srs_canonical_ids.dart`（分批、改写、缺失保留），
app 侧只把偏好仓库接上：`fushi/lib/src/srs/srs_persisted_ids.dart`（`srsNormalizeStoreIds`）。

### 实测先说：规范 ID 不带盐，Dart 派生的 ID 现在就是成员

集成分支上（全新 profile，`identity` 之后开库）：`SrsKernelIds(uid).defaultDeck` = `7a6e…`，`canonical_ids` 答 `0279…`，
牌组树里的默认牌组是 `0279…`；`createDeck('X')` 返回 `63ad…`（派生、带盐），牌组树里那个牌组是 `4c4d…`。也就是说不用
等补盐 / 并入，凡是 Dart 按 uid 加盐派生、又拿去和内核读回的 ID 比对的地方，切到新代后就已经对不上（`tree[store.defaultDeckId]`
为 null、偏好里存的成员 ID 被当成「已删除」回落默认）。内核对**请求**里的 ID 一律先归一，所以读写不会落错实体，错在 Dart
的比对。补盐 / 并入（`bindingChanged`）只会让别的盐算出的成员也归过来。

### 持久化 SRS 实体 ID 的位置清单（grep 偏好键、主库表、json 配置）

| 位置 | 存什么 | 处理 |
|---|---|---|
| 偏好 `srs_mining_deck_id` | 制卡牌组 ID（`''` = 默认） | 开库后写回规范 ID；制卡解析落点时读时归一 |
| 偏好 `srs_mining_note_type_id` | 制卡笔记类型 ID（`''` = 内置 Fushi 卡片） | 同上 |
| 偏好 `srs_mining_field_mappings` | `{noteTypeId: {fieldId: 模板}}`，两层键都是 ID | 同上；两层键都归一，成员键撞到同一规范键时规范键原有的项优先、别的只补缺 |
| 作品级覆盖层（绑定配置的 `profile_settings` 快照里的同三键） | 绑定配置自己的复习库的 ID | 不写回（ID 属于绑定配置的库，不是激活副本的）；制卡时 `resolveSrsMiningDestination` 用那份库读时归一 |
| 别的配置的快照 / 浏览器扩展的只读视图（`PreferencesRepository.readOnlySnapshot`） | 同三键 | 只读视图不写；激活那个配置时随开库写回；扩展制卡经 `minerFor` 那份库读时归一 |
| `SrsDbStore.defaultDeckId` / `lapisNoteTypeId` / `fushiCardNoteTypeId`（内存，原是 uid 加盐派生的 `late final`） | 内置实体 ID | 改成向内核要：`ensureBuiltins` 按规范 ID 判在不在并记下规范 ID；`resolveBuiltinIds()` 单独可调（只读打开、`bindingChanged` 后） |
| `SrsWordAudioBackfillFields.forProfile`（补单词音频按派生 ID 比笔记类型 / 取字段） | 内置 Fushi 卡片的笔记类型与三个字段 ID | 新增 `ofStore(store)`，一条 `canonical_ids` 问齐；两个调用点改用它 |
| `mine_to_server_targets` | 主机上的牌组**全名**（不是 ID） | 不涉及 |
| `srs_browse_saved_views` | 浏览查询文本（`deck:` 按名字） | 不涉及 |
| `srs_home_paired_cache` | 主机牌组的显示缓存，每次探测覆盖 | 不涉及（主机的 ID，不是用户的选择） |
| `last_selected_deck` | Anki 牌组名 | 不涉及 |
| 主库协议 1 的 `srs_*` 表 | 冻结的旧数据，只给 G7-6 / D21 导入读 | 不动（存量列名冻结） |
| 主库其余表 | 没有引用 SRS 实体的列（grep `tables.dart`：`entity_uid` 一类只在音乐锁定字段表） | 不涉及 |
| `srsCacheConfigFor(uid)`（发给内核的缓存配置里的默认牌组 / 内置笔记类型） | 派生 ID | 内核收到后自己归一（`cmd/mod.rs` `default_deck`），不改 |
| AI 撤销载荷（ctl 写操作的 `undo` 凭据，`srs_ctl_ops.dart` `_editUndo` → `SrsDbStore.revertEdits`；设计 §5.3 点名） | 实体 ID + 字段键 + dot | 不需要改写：字段项走内核 `undo_check`，`cmd/center.rs` 先 `ix.canonical(&ref_of(entity))` / `ix.canonical_key(key)` 再找行（约 :204-234），成员 ID 照样落到同一个类；标签项经 `notes()` 物化，`_materializeNotes`（`srs_db_store.dart` 约 :2548-2568）按请求 ID 作键回包。旧载荷（无 `undo` 键）走 `legacy` 换凭据，同一条路 |
| 读点：设置页字段映射（`anki_settings_page.dart` `_buildSrsMiningRows`）、字段说明页（`srs_field_info_page.dart` `_sourceCard`）、笔记编辑页（`srs_note_editor_page.dart` `_miningSlotsOf`） | 按 `type.id`（规范）查偏好里的字段映射 | 读时归一：设置页用 `resolveSrsMiningDestination` 回的 `resolved.destination`（已归一）；两个 SRS 页载入时 `srsCanonicalizeMiningDestination` 问一次存进状态。设置页改映射时按规范键写一份，与旧成员键并存：下次归一按「规范键优先、成员键补缺」合并，只有用户这次改的那个字段以新值为准 |
| 读点：引导页「选了 Fushi 复习就把旧默认 Lapis 换成没选过」（`onboarding_wizard_page.dart` `_adoptFushiCard`） | 拿偏好里的笔记类型 ID 和 `store.lapisNoteTypeId`（规范）比 | 比之前先 `srsCanonicalIdMap` 归一（开库归一在后台，可能还没跑完） |
| 读点：`SrsMiner` 的覆写 / 取字段 / 「按类型列映射」（`overwrite`、`prepareFieldsFor`、`miningFieldMappingLookup`，后者给 `srs_mining.dart` `listNewCards`） | 按 `type.id` 查落点里的字段映射 | 每个入口现问一次 `canonical_ids`（`_canonicalDestination()`），不靠实例缓存；制卡（`mine`）用解析落点时归一好的 `target.destination` |

### 定案（所有者授权自定）

1. **读时归一 + 落盘归一两条路，同一份纯函数。** 落盘只写激活 profile 的偏好本体（绕过作品级覆盖层），开库 / 重新激活
   时在 `srsStoreProvider` 后台跑一次（`srsRunLogged`，失败留痕不挡开库）；制卡解析落点（`resolveSrsMiningDestination`）
   每次都先把落点换成规范 ID（一条 `canonical_ids`，ID 至多几十个），覆盖作品级覆盖层、别的配置的视图、`bindingChanged`
   之后还没重归一的窗口。`SrsMiner` 凡要查字段映射的入口（制卡、覆写、取字段、按类型列映射）都各自现问一次（复核修正：
   第一版只在解析落点时记在实例上，而 `_readSrsMiner` 每次制卡新建 `SrsMiner`，覆写 / 取字段那条路永远拿原样偏好查，
   作品级覆盖层里成员 ID 键的映射查不到、退回按字段名猜，覆写「没映射到的写空」会把现存笔记写错）。UI 读点同理（上表）。
2. **缺失保留。** 内核对不认识的 ID 原样返回；原值不动、不写，交给已有的「缺失」处理（`deckFellBack` / `noteTypeFellBack`，
   设置页照旧显示「已删除，回落默认」）。不清空用户设置。
3. **只在真变了时写**，改写时现读当前值（问内核期间用户改了设置，不拿旧值覆盖）；问完内核时副本已换（切 profile）就不写。
4. **分批**：`srsCanonicalIdMap` 去重、跳过空串，按 `kSrsCanonicalIdsBatchMax` = 4096（内核 `LOOKUP_MAX`）分批；回包条数
   不对抛 `StateError`。全部位置的 ID 合成一批问。
5. **远程库**（`SrsRemoteStore`）的 `canonicalIds` 原样返回：远程协议没有 `canonical_ids`，主机的内核对请求里的 ID 自己归一；
   远程库的内置 ID 仍是派生值（G10-2 接远程 `canonical_ids` 时一起改）。
6. `ensureBuiltins` 原来按派生 ID 判「在不在」：新代读回的是规范 ID，**每次开库都重发一遍内置实体**（实测修订号 3 → 6）；
   改成按规范 ID 判之后不再重发。第一次建内置实体时建之前问到的是它自己，建完再问一次才是规范 ID。

### 没做 / 交给谁

- **`bindingChanged` 的订阅点（等 G7-5b）。** 现在 `SrsDbStore` 没有绑定变化的通知（`_sync2Raw` 归 G7-5b）。接上之后在通知里
  调 `srsNormalizeStoreIds(store: store, prefs: app.prefsRepo, shouldStop: …)`（内置重问 + 偏好重归一）；若 G7-5b 的做法是
  作废 `srsStoreProvider` 整份重开，开库那一次已经覆盖，不用另接。Secondary 只读打开不跑 `ensureBuiltins`：复核后改在
  `SrsDbStore.open` 尾部（`_sync2Open` 之后、只在非 primary 时）调 `resolveBuiltinIds()`（只读命令），作品会话 / 扩展的副本
  （`srsProfileStores._openForeign`）、服务端、备份合并开的副本都覆盖，不靠调用方记得去调。这是 `open` 里唯一一行改动，
  不碰 G7-5b 的 `_sync2Raw` / 绑定变化通知。
- **与 G7-5b 合流（复核时核过 `origin/pr/srs-gen4-g7-5b-dart-open-identity` 头 `19f40b16`）。** G7-5b 加了
  `SrsDbStore.bindingChanges`，`srsStoreProvider` 订阅后 `ref.invalidateSelf()` 整份重建：本模块放在 provider 体里的
  `srsNormalizeStoreIds` 随重建再跑一次，**订阅点因此不用另接**。G7-5b 还把内置 ID 改成开库时 `_loadRootIds` 读规范形
  （`defaultDeckId` 等改读 `_roots`，主从模式都读）：与本模块的 `_canonicalBuiltins` / `resolveBuiltinIds` / `open` 尾部
  那一行是同一件事，合流时**保留 G7-5b 的 `_loadRootIds`**，删掉本模块这三处，`srsNormalizeStoreIds` 里的
  `store.resolveBuiltinIds()` 一并去掉（重建会重开 / 重读）；`ensureBuiltins` 按规范 ID 判在不在的改动两边都要留一份。
  **已在 W2 合流（分支 `pr/srs-gen4-w2-merge`）照此做完**：`open` 尾部只留 `_loadRootIds`；`_canonicalBuiltins` /
  `_derivedBuiltins` / `resolveBuiltinIds` 删掉，`ensureBuiltins` 用 G7-5b 的写法；本模块公开的 `canonicalIds`（带条数校验）
  保留并顶替 G7-5b 私有的 `_canonicalIds`（`srs_canonical_ids.dart` / 语音回填 / 远端客户端要用）。上面「复核后」那一行
  （`open` 尾部非 primary 时 `resolveBuiltinIds`）随之撤掉：`_loadRootIds` 主从模式都跑，Secondary 用例照样覆盖。
  `srs_canonical_ids_store_test.dart` 的补盐用例改经 `store.sync2Command` 发命令（让 store 收到回包里的
  `bindingChanged` 自己重读），不再手调 `resolveBuiltinIds`。下文「测试」里提到 `resolveBuiltinIds` 的变异实测是合流前的记录。
- **派生 ID 的返回值（G7-5b / 上游）。** `createDeck` / `deckIdForNew` / `createNote` 等返回 `SrsKernelIds` 派生的成员 ID，调用方
  拿它与读命令回的规范 ID 比（以及 store 测试里 `expect(..., noteId)` 一类）会对不上。不在本模块范围（不是持久化），建议：
  写命令回包带上规范 ID、Dart 返回规范 ID；或 `SrsKernelIds` 按文件头说的「G7 起连到 store」直接答规范 ID。
- **按成员 ID 读实体视图会崩（G7-5b / 读路径负责模块）。** `store.noteType(<createStockNoteType 回的派生 ID>)` 报
  `Null check operator`：`_prefetchEdits`（`srs_db_store.dart` 约 :2734）按**请求** ID 预建 `pre.edits` 的槽，内核
  `_editItemsById` 回包按**规范** ID 作键，`pre.edits['…/$规范ID']!` 取空。成员 ID 来自上一条「派生 ID 的返回值」，
  两条一起修（回包换回请求 ID，或写命令直接回规范 ID）。G9-6 的测试只拿规范 ID 读视图。
- **测试辅助没绑定。** `fushi/test` 的 `openSrsTestStore` 不先跑 `identity`，`srs_word_audio_backfill_test.dart` 的 store 用例在
  集成分支上本来就报 `SrsProfileUnboundException`（G7-5 记过的那批红），本模块没修（只把它的 `forProfile` 改成 `ofStore`）；
  `ofStore` 的真库验证放在 `srs_persisted_ids_test.dart`（先 `identity` 再开库）。
- **设置页 / 字段说明页 / 笔记编辑页 / 引导页没有页面级测试。** 它们调的归一函数（`srsCanonicalizeMiningDestination`、
  `resolveSrsMiningDestination` 回的 `destination`、`srsCanonicalIdMap`）在引擎测试里对真内核验过；页面本身要真内核的
  widget 测试，受上面「测试辅助没绑定」那条拖着，等测试辅助补 `identity` 后再补。

### 测试

- `packages/fushi_engine/test/srs/srs_canonical_ids_test.dart`（纯逻辑，12 条）：单值位置与两层键位置各验成员 → 规范并落盘、
  并入后再跑重归一、缺失保留不写；撞键合并；改写时现读；`shouldStop`；读时归一一批问齐；4096 分批（8193 条 → 3 批）、
  偏好位置超上限分批、回包条数不对抛错。
- `packages/fushi_engine/test/srs/srs_canonical_ids_store_test.dart`（真内核，4 条）：开库后内置 ID 是规范 ID、牌组树查得到、
  再跑 `ensureBuiltins` 修订号不变；偏好三位置成员 → 规范、不存在的牌组保留、建出来后重归一、补盐（`bindingChanged`）后稳定；
  `resolveSrsMiningDestination` 拿成员 ID 不误判已删除、真没有的照旧回落默认；内核 4097 条报错、统一入口分 4096 + 2。
  变异实测：`ensureBuiltins` 退回按派生 ID 判 → 修订号 3 → 6 变红；落点不归一 → `deckFellBack` 变红。
  复核后加 2 条、扩 1 条（共 6 条）：新建的 `SrsMiner`（没走过解析落点）在偏好是成员 ID 键时 `miningFieldMappingLookup` /
  `prepareFieldsFor` / `overwrite` 都按存下的映射写（故意与按名猜的相反）；Secondary 只读打开后 `defaultDeckId` 等与主副本
  相同、牌组树查得到；`resolveSrsMiningDestination` 回的 `destination` 字段映射键已是规范 ID。变异实测：`_mappingFor`
  退回按原样 `destination` 查 → 映射用例红；只把 `overwrite` 的归一换成原样落点 → `note.field(front)` 红（:285）；
  删掉 `open` 尾部的 `resolveBuiltinIds` → Secondary 用例红（拿到派生值 `7a6e…`）。
- `fushi/test/srs/srs_persisted_ids_test.dart`（真偏好仓库 + 内存主库，6 条）：三条偏好写回规范 ID、键名不变；并入后重归一；
  缺失保留、空串不动；只读视图不写也不问；真内核上 `srsNormalizeStoreIds` 把 `createDeck` 回的派生 ID 写回成牌组树里的
  规范 ID；`SrsWordAudioBackfillFields.ofStore` 的笔记类型 / 三个字段 ID 在内核的笔记类型视图里查得到（派生的对不上）。

## 15. G11-3 `.fushisrs` 第 2 版接线（2026-11-17，分支 `pr/srs-gen4-g11-3-fushisrs-v2`，基于 `pr/srs-gen4-switch`）

规划 §1.9、§2.2「G11-3 ← G9-4」。复用 G11-1（`gen4/export.rs` 编解码、`legacy_export.rs` 冻结 v1 读入器）与 G11-2
（`store/gen4/export.rs` `export_ops`、`store/gen4/import.rs` `import_ops` / `import_v1`），没有重写。schema 没动（`peers`
清单走主键前缀，不加表 / 索引），分到的 40023 没用。

### 命令（`store/gen4/cmd/fushisrs.rs`，分发器 `import` / `export` 由 `Unwired("G11-3")` 改为 `Wired`）

- `export {path?}`：读连接一个读快照。给 `path` 就边压缩边写进该文件（先写 `<path>.g4tmp`、刷盘后改名，出错删掉），
  不给就回包文件 `ops.bin`。回包 `{collection, dir, salts, peers: [{device, public, name?}], counts}`——清单里归内核的几项。
- `import {path? | 第一个字节块, manifest?: {collection, dir, salts, peers}, confirmed?, now, anchor?}`：一个写事务
  （`write_binding`，绑定变了提交后回包带 `bindingChanged`）。嗅探魔数：
  - 第 2 版（`FSRS4EXP`）：清单的集合必须等于流头的集合 → `collection_adopt`（G9-4，判据只在 `adopt_foreign`）：
    `same` / `alreadyJoined` / `saltsAdded` 照常导入；另一个集合没 `confirmed` 回 `{format: 2, outcome: "needsConfirm",
    collection, dir}`、什么都不写，带 `confirmed` 重发先并入（`joined`，profile 没绑过是 `bound`）再导入 → 清单 `peers`
    进 `import_peers` → `own_fork_point` 发现本机身份分叉就 `rotate_identity_report(col, keep, now)`（回包 `rotated`）→
    `import_ops_from`。不带清单（裸 `ops.bin`）不认领，`outcome: "stream"`。
  - 第 1 版（协议 3 的 `FSRS2EXP`，即 v1 `.fushisrs` 的 `ops.bin` 与协议 3 `export` 命令的输出）：`import_v1`，
    `outcome: "legacy"`；另一个集合拒绝（D34）。
  - 回包 `{format, outcome, applied, unchanged, peers, rotated, counts, settled, localRevision, localEpoch}`；
    `applied` = 新落原生操作 + 空洞区间 + 新落 / 换掉 / 分叉的承袭槽。

### 定案（所有者授权自定）

1. **缺口 G-12 选清单方案**：`.fushisrs` 第 2 版清单带 `peers`（导出时整张 `peers` 表：设备、公钥、名字），导入时
   `import.rs` 新的 `import_peers` 与旧备份读入 `backup_peers` 共用 `land_peers`（公钥先到先得、冲突整个拒绝、本机身份
   必须是本机公钥、名字只补空缺）。不升 `FSRS4EXP` 版本（G11-1 的格式不动）。G11-4 的整包备份 `srs/manifest.json`
   照同一口径带 `peers`，导入调 `import_peers`。测试钉住：不带清单时协议 3 设备的公钥进不来，带了才有。
2. **内存遗留根修**：`ZstdWindow` / `Export4Reader` 加 `Read` 来源（`from_reader` / `open_reader`，默认类型参数仍是切片，
   既有调用点不变；`at_end_of_input` 改成「再读一个字节读不到」，切片上与看空等价）。`import_ops` 拆成
   `open_ops_reader` + `import_ops_from<R: Read>`，命令层按文件 `BufReader<File>` 读三遍（嗅探、分叉预扫、导入），内存
   = 一个读窗口 + 一项，不随文件变大。Dart 不再把 `ops.bin` 读进内存：zip 里 `ops.bin` **不压缩存放**（流本身是 zstd），
   导入时 `ZipFile.rawContent` → `OutputFileStream.writeInputStream` 按 1 MB 分块拷进临时文件交给内核；导出时内核直接
   写临时文件，`ZipFileEncoder.addFile` 流式拷进 zip。第 1 版仍整份读进内存（冻结读入器只收切片，`legacy_export.rs` 不为
   新代码改；第 1 版文件只会越来越少），v1 包里 deflate 过的 `ops.bin` 也只能整份解压。
3. **本机身份分叉先换身份**（协议 3 `import_on` 同口径）：`own_fork_point` 按 4096 项一块把流里本机当前身份的原生日志
   喂 G8-6 的 `ForkScan`（与位置上的分叉同一判据），两边在某个 seq 不同或流比本机长就 `Some(keep)`。
4. **本机状态行**：导入是本机写（`local::persist`，带 `anchor`）；派生层整份重建、没有逐实体变更清单，有改动时修订号
   推进 1（经 `persist` 的计数口径，`local.rs` 没改），回包不带 `changed`，Dart 见 `unchanged != true` 就整份丢缓存日志。
5. **v2 同步之前的事件备份（清单魔数 `fushi-srs-backup`）明确拒收**：新代 `apply` 拒 stamped 输入，冻结侧的 stamped apply /
   `open_legacy_scratch` 还没有（G7-6）。Dart 抛 `SrsFushiSrsLegacyFormat`，界面提示「先在 Fushi 3.x 里导入，升级时随库
   迁移」（`srs_timeline_import_legacy_format`）。**与 D34「只有 v1 事件的旧输入长期支持」不一致**：等 G7-6 把 stamped
   apply 冻结进 `legacy3/` 后，在临时协议 3 副本里落事件、再走 `import_backup`，由 G11-4 / G7-6 接。
6. **旧版本互拒**：新清单 `v: 2, gen: 4`、不带 `magic`；已发布版本的 Dart 读者对 `v > 1` 抛「unsupported .fushisrs
   version」（碰库之前），协议 3 内核对 `FSRS4EXP` 魔数报「not a .fushisrs file」（Rust 测试经冻结在树里的
   `sync2_import` 钉住，库一字不变）。真旧二进制的实测归 R0 / G11-5。
7. 导出走读连接的读快照（只含已提交写入），Dart 侧仍经 `sync2Command` 排在写事务之后，导出与随后的媒体清单读同一状态。

### Dart（`packages/fushi_engine`、`fushi`）

- `srs_db_store.dart`：`sync2ExportOps(String path)` → 回包 map；`sync2ImportOps({path, manifest, confirmed})` → 回包 map
  （`needsConfirm` 不接本机状态）。`srs_backup_merge.dart` 的 `adoptedUid` 属 G11-4，没碰。
- `sync2/srs_fushisrs.dart` 重写：清单 `{v: 2, gen: 4, profile, collection, dir, salts, peers, exportedAt, media}`；
  `srsImportFushiSrs(..., confirmForeign:)`，没给 / 答否回 `declined`；删掉旧事件格式的转换（`legacyMediaPool` 参数随之删）。
- `srs_history_page.dart`：导入时另一个复习库弹确认（`srs_timeline_import_foreign_confirm`），旧事件备份给专门提示。
- 任务书提到的 `plugin_tracking_provider` 与 `.fushisrs` 导出无关（媒体追踪插件），没改。

### 没做 / 交给谁

- `_sync2Raw` 统一处理回包的 `bindingChanged`（G7-5b）：导入认领改绑后这里只重读了 `status`。
- v2 同步之前的事件备份导入（见定案 5，G7-6 / G11-4）。
- 整包备份 / 还原、`ffsrs_store_snapshot`（G11-4）。

### 测试（`cmd/fushisrs_tests.rs`，12 条，全部经 C ABI；Dart `srs_fushisrs_test.dart`）

导出 → 导入空库（需确认 → `bound`，导出流逐项 / 派生表逐行 / 公钥相同，再导一遍什么都不改、修订号不动，字节块与文件
两种来源）；同集合并入 + G-12 公钥；另一个集合需确认 → `joined` → 再导 `alreadyJoined`；清单与流头不符 / 截断 / 不是
导出流 / 文件不存在一律拒、库不变；拷过的数据目录各写一条后导入先换身份（`keep = 2`、`moved = 1`，三处写入都在）、
导回自己更早的导出不换；第 1 版与直接迁移逐行相同、另一个集合拒；协议 3 `sync2_import` 拒收新流；大文件（明文 > 1 MiB）
读窗口 ≤ 256 KiB；双盐别名类导出后在另一个集合认领，按任何成员点名都是整个类；`PEERS_SQL` 查询计划。

## 16. G11-3 复核修复（2026-11-17，同分支 `pr/srs-gen4-g11-3-fushisrs-v2`）

§15 的复核发现逐条处理如下（每条配测试，变异实测：去掉修复后对应测试变红）。

- **导入预检（孤儿媒体 / 还原点）**：`import` 加 `preflight: true`：只判「要不要确认、会不会被拒」，什么都不写、修订号不动。
  判据与真导入同一处：第 1 版走 `import.rs` 新抽出的 `check_v1_collection`（`import_v1` 也改调它）；第 2 版先比清单与流头，
  再在一个**回滚掉的保存点**（`Truth::tx` 返回哨兵错误）里跑 `collection_adopt` 与 `check_stream_collection`（`import_ops_from`
  也改调它），所以 `same` 时补的盐不留。回包 `{format, outcome: "ready" | "needsConfirm", preflight: true, collection?, dir?}`。
  Dart `srsImportFushiSrs` 改成：解包（只拷 `ops.bin`，不碰媒体目录）→ `SrsDbStore.sync2ImportPreflight` → 需要时问用户，
  答否直接返回 `declined`（`mediaFiles: 0`，不打还原点）→ 打还原点 → 后台 isolate 补媒体（回补进来的文件名）→ 真导入；
  真导入报错（坏在流中间的文件，预检不读全流看不出）就删掉这次补进来的媒体再抛。预检之后真导入仍回 `needsConfirm`（别的
  调用在这之间改了绑定）抛 `StateError` 让用户重来，不按旧的确认结论并入。测试：Rust `preflight_judges_without_writing`
  （变异：不回滚保存点 → 红）；Dart `srs_fushisrs_test.dart` 外来包拒绝后媒体目录为空、还原点数不变，源码守卫钉住预检在还原点
  与补媒体之前、读包函数不碰媒体。
- **`unchanged` 计入认领写入**：`unchanged = got.unchanged() && peers == 0 && !wrote`（`wrote` = 补盐 / 并入 / 绑定 / 换身份）。
  测试 `new_salts_or_peers_alone_are_a_change`：操作全已有、只带新盐（`saltsAdded`）或只带新设备公钥的再导入回包 `unchanged:
  false`、修订号推进；真的什么都没带来才是 `true`。变异：去掉 `!wrote` 或去掉 `peers == 0` 各自让它变红。
- **命令层读法钉测**：按路径的来源改经 `FileSource`（包一层 `File` 的 `Read`），测试编译下按线程记每次读的请求大小与字节
  （`fushisrs::meter`）。`a_large_file_is_read_with_a_bounded_window` 断言导入命令对文件读满整份、最大一次请求 ≤ 256 KiB 且小于
  文件。变异 M4（`fs::read` 整份进内存再包 `Cursor`）：记录为零 → 红。
- **临时文件名**：`<path>.g4tmp` 改为在整个文件名后追加（`tmp_of`），不再 `with_extension` 替换扩展名。测试
  `the_export_temp_file_appends_to_the_whole_name`（同目录的 `ops.g4tmp` 不被覆盖挪走；变异回 `with_extension` → 红）。
- **旧事件备份进合并条件**：规划 §6 加一条：G7-6 / G11-4 给 stamped apply 接上冻结侧转译、旧事件备份能经 `.fushisrs` 入口导入
  并有测试之前，整批不合入 develop（D34）。

仍留给别人：

- `dispatch_tests.rs` `unwired_and_removed_commands_name_their_owner` 与 `pr/srs-gen4-switch` 尖端 1bbd15c75e 的冲突：合并时取本
  分支的 `[("profile_merge_mark", "G9-5"), ("plan", "G8-7")]`（integration owner；本分支按规则不 rebase / merge）。
- §7 对照表 import / export 行（「S1 后状态」列）与 `dispatch.rs` 文件头的未接线清单：改成「已接线（G11-3，`cmd/fushisrs.rs`）」，
  integration owner 合并时顺手改（多个并行分支都在改这两处，各自改会互相冲突）。**W2 合流已改**。
- Dart 侧 v1 zip 包（`v: 1` 清单 + deflate 的 `ops.bin`）端到端测试：要一份协议 3 `FSRS2EXP` 夹具（Dart 已没有协议 3 导出入口）
  且依赖 Dart 侧绑定接通（G7-5b：全新库 `SrsDbStore.open` 抛 `SrsProfileUnboundException`，`srs_fushisrs_test.dart` 里碰库的
  测试在基线上都红）。Rust 侧第 1 版流已有对拍（`a_version_1_file_lands_exactly_like_the_migration`）。

## 17. G8-7 同步一轮（2026-11-17，分支 `pr/srs-gen4-g8-7-sync-round`，基于 `pr/srs-gen4-switch`）

G8 子规划文档在仓库里不存在（任务点名的「G8 子规划」找不到），本节按规划 §2.2 / §1.7 / §1.5、本交接说明 §7 与设计
2026-11-11 §4 / §6.2 定。存储层全部复用第一段（G8-1 布局、G8-4 收段与同步状态、G8-6 分叉换身份、原生段打包、head），
命令层在 `native/fushi_fsrs/src/store/gen4/cmd/sync.rs`，测试 `cmd/sync_tests.rs`（经 C ABI，内存位置）。

### 17.1 命令（全部按 profile，一条命令一个读快照或一个写事务）

| 命令 | 事务 | 做什么 |
|---|---|---|
| `location_root {location, now, has4, has3, locs, enableKdf?}` + 块 `v4/meta.json`、`v3/meta.json` | `write_local` | 新根 meta（`meta4`，只读不改；唯一改写 = 位置上没 `kdf`、本机要开加密）、loc 标记（没有就建）、旧根围栏（`fence3`；没有 `v3/meta.json` = 新集合：预先立围栏，墓碑 head 进 `ensure`「不存在才写」）。新根 meta 要更新的读者 → `needsUpgrade`，别的集合 / 坏 meta → `refused`，都不写。回包 `{state, loc, kdf, media, fresh, ensure}`，文件路径带 `v4/` / `v3/` 前缀，按顺序写（先新根后围栏）。 |
| `plan {location, loc?, now, listing?}` + 块 = 各设备代号最大的 head | `write_local` | `Head4::decode`；要求更新的读者 → `needsUpgrade`；别的集合不认；对端：`set_peer`（公钥先到先得、对不上 = 冒名）、`put_loc_head`、停用过又写了更新 head 的取消停用；本机身份：`fork::judge_own_head`（`Fetch` 的段一并拉、`Known` = `finishPending`）；承袭段按 `listing` 的文件名定区间。`sealed` = 本位置 loc 的 head 带 `seal`。 |
| `ingest {key?}` + 块 = 段 | `write` | `Receiver`（增量收尾）收一批；本机当前身份的原生段再喂 `ForkScan`，找到分叉点 `record_fork`。推进本机修订号。 |
| `ingest_finish {now}` | `write` | `fork::rotate_on_fork`；换了身份推进修订号。 |
| `outbox {progress, key?, maxBytes?, segBytes?, present?}` | `write_local` | 本机当前身份从已传水位起切段（`native_walk`，到 `segBytes` 就在链值已知处切，累计到 `maxBytes` 停这一批）、签名、按位置钥匙封装。水位（`srs_meta` `gen4_out/<col>/<progress>`）记已传段（首尾、链尾标签、传时空洞条数）；`present` 里缺了水位以下的段 / 已传段里后来多了空洞（清除了已发布的操作）→ 退水位重切重传。 |
| `outbox_ack {progress, segments}` | `write_local` | 必须正好接在水位上且链尾标签与本机相符，否则 `accepted: false`、不记。 |
| `head {location, progress, loc?, seal?, now, skipUnchangedMs?}` | `write_local` | 水位签成 `Head4`（`ack` = 已应用、`digest` = `Index::digest`、`derive` = 1、名字 / 扩展信息、`prev`）；内容指纹没变且没满心跳 = `unchanged`。代号 = 位置上本机最新 head 与水位里记的取大 + 1；记进 `loc_heads`（`status` 的 `uploaded` / `headGen`）。 |
| `obsolete {progress, present, archive?}` | 读 | 比最新两代旧的本机 head、不在已传段清单里的本机 `seg-`；归档 / 还没写过 head 不删。不记待删清单（`obsolete_ack` 已删）。 |
| `retire {device, retire, now}` | `write` | 停用记录 `srs_meta` `gen4_retired/<col>/<device>`（`Truth::retired` / `set_retired`）；`Receiver` 把停用设备上的依赖当成已满足（`deps_ready`），同一事务里投递等它的操作；`status` 设备行 `state = retired` + `retiredAt`，`blocking` 不再记到停用设备头上。 |
| `rotate {now}` | `write` | `Truth::rotate_identity(col, 本机末尾, now)`。 |
| `location_sealed` / `location_seal` | 读 / `write_local` | 协议 3 `sealed.rs` 同语义同回包，存 `loc_state`（`sealed` / `kdf` / `check_`）；段前缀判密封认 `FSG4` / `FRL4` / `FSH4` 的 flags bit0。 |
| `digest` | 读 | `{digest}` = `Index::digest`（测试与诊断比收敛）。 |

已删：`ingest_yield` / `ingest_commit` / `ingest_begin` / `ingest_batch` / `ingest_prepare` / `ingest_end` /
`replay_pending`（没有收段通道）、`digest_buckets`、`obsolete_ack`。未接线、归 **G8-7b**：`relay_outbox` / `relay_ack` /
`obsolete_former` / `media_*`。

### 17.2 定案（所有者授权自定）

- **不加表、不升 schema**：水位、停用记录放 `srs_meta`（主键区间读），loc 标记记进已有的 `loc_state.loc_ids`；分配的
  40022 没用上。新语句（`RETIRED_SQL` / `VOIDS_SQL` / `LOC_STATE_SQL` / `LOC_HEAD_SEQ_SQL`）有查询计划测试。
- **水位按「位置 + 密钥指纹」**（Dart 的进度身份，同协议 3）：换钥匙全部重传；换身份水位从 0 起（旧身份目录留在位置上，
  清理归 G8-7b 的 `obsolete_former`）。
- **清除改写**：比「传时空洞条数」与现在的，变了就退到那一段之前重切。空洞记着该处链值，重切出的段区间与链尾标签不变 =
  同名覆盖写，位置上不留已清除的原文。
- **新集合判据只看 `v3/meta.json` 在不在**（规划 §4 补记），不看目录名。
- **旧版本互斥（D3）**：新根 meta `minReader` 4、旧根围栏 `minReader` 4 + `moved: v4`、新集合的墓碑 head——协议 3 的版本
  读到这三样都停下报升级，字节由本版本写定（`location.rs`，G8-1 的测试覆盖）；本版本读到要更新读者的新根 meta / head 停下、
  什么都不写（`sync_tests.rs`）。
- **Dart `kSrsSync2Protocol` / `kSrsSync2MinReader` 升到 4**；加密握手（`srsLocationHandshake`）照旧判口令，但对 meta 只看
  不写：它想写的 `kdf` 经 `_SrsMetaView` 截下来交给 `location_root` 的 `enableKdf`。
- **位置目录名取 `identity` 的 `dir`**（`srsLocationDir` / `srsFolderLocationDir`），新根 `fushi-srs/<dir>/v4/`、旧根
  `…/v3/`（只读 meta、写围栏；存量集合的媒体仍在旧根，新根 meta 记 `media: v3`）。
- **收段会话**：Dart 的 `sync2IngestBegin` / `sync2IngestEnd` 只剩「整 profile RWKV 回放排到收段之后」的 Dart 侧标记；
  `sync2IngestBatch` = 一条 `ingest`（一批一个写事务），`sync2IngestFinish` = `ingest_finish`。按片投递、`ingest_yield`
  收片、`replay_pending` 全删。

### 17.3 委托描述与代码不符

- 「调度器『已在运行』导致永久 `_failed`」：`srs_sync_scheduler.dart` 里没有 `_failed` 状态；同一后端排着没开跑的轮次
  本来就合并（`syncWithBackend` 的 `_queuedRounds`）。「already running」只出现在内核 `dryrun.rs` 的换代预演里（G7-5 已删
  Dart 侧的预演调度）。协议 3 收段会话的并发冲突随会话一起删了。没有改调度器。
- `ensureMigrated` / `deferMigration`：G7-5 已把 `sync2Migrated` 定成恒真，`ensureMigrated` 开头即返回；它后面整套「迁移前
  只拉不发」（`_pullInto`、`srsSync2PullOnly`）成了死路径，删除连带调度器上千行，留给 G9-5（规划：`srs_sync_scheduler.dart`
  G8-7 → G9-5）。

### 17.4 没做 / 交给谁

- **G8-7b**：转发（`relay_outbox` / `relay_ack`，要存收到的作者段原字节）、旧身份目录清理（`obsolete_former`）、媒体命令
  （`media_*`，`srsRunLocationMedia` 接上之前报未接线）。
- **旧根接手**：协议 1 根 `v2/` 的一次性迁移（`srsPrepareLocation`，按协议 3 命令写）与协议 3 根 `v3/` 上的段的接手
  （`oldroot.rs` 的 `oldroot_scan` / 承袭上传 `Uploader`）都没接；`srsRunLocationRound` 与文件夹位置都不再调
  `srsPrepareLocation`（文件夹那条复核后才去掉，见 §17.6）。存量集合的协议 3 段因此要等这一步才进新根——**接上之前，迁移过的设备之间
  只同步迁移之后的新操作**（迁移本身把各自的旧数据带进了本机库，不丢）。
- **摘要核对**：head 带 `digest`，但对端摘要不一致时的定位 / 自愈（协议 3 `heal.rs`）没接；`healFailed` 恒空。
- **`status` 的 `seenAt` / `warning` / `frozen` / `digestMismatch`** 仍是占位值。
- **上游缺口**：`purge` 命令只追加「删除 + 清除」两条操作、不把目标落成空洞（`Truth::advance_purge` 没有生产调用方），
  所以清除改写目前只有测试能触发（`purging_published_ops_rewrites_the_uploaded_segments` 直接推进真相层的槽）。
- **Dart 测试**：删了只测协议 3 机制的 5 个文件（收段通道 `channel_settle`、两段式删除回执 `delete_ack`、旧身份清理
  `former_identity`、按片投递 `ingest_slices`、收段中作废 `retire_mid_ingest`）；其余用真内核跑协议 3 一轮的老测试
  （`srs_sync2_round_test` 等）在新代上跑不通，按新命令重写归后续。新增 `srs_sync4_round_test.dart`（假内核 + 内存位置）。

### 17.5 测试（`cmd/sync_tests.rs`，12 条 + `sync.rs` 单元 2 条）

两台全新设备经文件夹位置互相同步（并发改同一字段收敛、语义摘要相同、增量 == 重建、没变不重写 head、每台最多两代 head、
根与围栏）；小段小批多段多批续传；丢段重传；清除已发布操作后同名重写；加密位置（段密封、`plan.sealed`、无钥匙收不进、
`location_seal(ed)` 形状）；位置的根（存量协议 3 改写围栏、媒体根 v3、新根要更新读者 / 别的集合 / 坏 meta 停下、旧根别的
集合停下）；要更新读者的 head；停用与自动取消；主动换身份；复制目录分叉 → 换身份 → 三方收敛；已删 / 未接线命令的原因；
新语句查询计划。

### 17.6 复核修复（2026-11-17，同一分支）

逐条对应 PR #3616 的复核意见；每条都有测试，并做了变异实测（去掉修复，对应测试变红）。

| 复核项 | 修法 | 守住它的测试（变异） |
|---|---|---|
| 两份纯 Dart 假宿主测试变红（`srs_sync2_dedup_round_test`、`srs_sync2_head_retention_test`） | 两份都删：新的一轮不调 `dedup` / `digest_heal`，`obsolete_ack` 与「再问」已删。留下来的语义挪走：head 只留两代（`two_devices_converge…`）、归档位置一个不删（新 `an_archive_location_keeps_every_head`，Rust 端到端；Dart 侧 `obsolete` 带 `archive` 见 `srs_sync4_round_test`）。`kSrsSync2DedupBudget` 一并删。 | — |
| 文件夹位置先跑 `srsPrepareLocation`，往 `v3/` 写协议 3 的 meta，全新位置被判成存量集合 | 文件夹路径和云端 runner 一样不再调 `srsPrepareLocation`（v2 接手、v1 媒体搬家随旧根接手归后续，`prepared` / `v1Media` 恒为 null）。根这一步抽成 `srsSync4LocationRoot`（`srs_sync2_round.dart`），一轮同步与只做媒体的位置共用，只做媒体的位置不再拿 `v3` 根做握手。媒体按新根 meta 的 `media` 选根（`SrsSync2Report.mediaRoot`、`onLocationRoot`），不再写死 `v3`。 | `srs_sync4_folder_test.dart`（真内核）：全新位置 `media = v4`、旧根有围栏与墓碑、`v2/` 不存在、两台设备收敛；存量位置 `media = v3`。变异 D1（一轮前往 `v3/` 写 meta）红。 |
| 停用核心语义没测试 | — | `retiring_a_device_delivers_what_waited_on_it`：b 的操作同时依赖 c、d 没到 a 的操作；停用 c 后不投递、c 的 `blocking` 归零、d 照记；再停用 d 同一事务投递；c、d 晚到后四台收敛、增量 == 重建、自动取消停用。变异 M1（`deps_ready` 不认停用）、M2（`stuck` 记到停用设备）、M8（`retire` 不补投递）全红。 |
| `outbox_ack` 链尾标签核对没测试 | — | `outbox_ack_refuses_a_tail_tag_that_is_not_the_local_chain`：标签对不上 → `accepted: false`、水位不动、再发还是同一段。变异 M7 红。（委托说的「推进空洞」做不出拒绝：空洞记着该处链值，链尾标签不变，所以直接篡改标签。） |
| Dart 对 `plan` 仍走协议 3 的 `readOnly` 两段式，新代 `plan` 在写锁外写库 | `SrsDbStore.sync2Command` 删 `plan` 分支，和别的同步写命令一样进 `runExclusive`；内核 `plan` 遇到 `readOnly` 明确报错。 | Rust `an_archive_location_keeps_every_head` 末尾（变异 M9 红）；Dart 变异 D2（恢复 readOnly 分支）让真内核文件夹测试红。 |
| `v4/` 被当成 v1 写入者目录 | `srs_profile_link.dart` 列远端 profile、`SrsAssetV1Writers.writers()` 都跳过 `v4`。 | `srs_profile_link_test`「新代集合根 v4/ 不是写入者目录」，变异 D4 红。 |
| `kSrs4LocationErrors` 没有消费方 | 删掉。调度器本来就把一轮报告里的任何 `error` 当「这个位置这一轮没同步成」报（`syncNow` / `syncLocalDirectories` / `classifySrsFolderReport` 都不分来源），这个集合不改变任何分流；`kSrs4LocationRefused` 还带 `: 原因` 后缀，集合判等本来就对不上。 | — |
| `plan` / 密封记录用墙钟 | `srsSync2Pull` 加必填 `nowMs`，`plan` 的 `now` 与两处 `location_seal` 都取它。 | `srs_sync4_round_test`「轮次时钟」，变异 D5 红。 |
| `identity` 的 `dir` 又被 `srsLocationDirOf` 映射一次 | `SrsAssetLocationStore` 加 `locationDir`，给了就原样用；runner 传 `identity` 的 `dir`。 | `srs_sync4_folder_test`「云端位置实例直接用 identity 给的目录名」，变异 D3 红。 |
| 停用记录解析失败静默当已停用 | 停用与否只看键；记录体读不懂 = `Null`，`status` 在那一行报 `warning: retired record unreadable`，取消停用即清掉。不报错让整条收段失败（那会让用户卡在同步不了的状态）。 | `an_unreadable_retire_record_is_reported`，变异 M10（读不懂当空对象）红。 |

复核外顺带修的（真内核 Dart 测试跑出来的）：

- **`ingest_finish` 没分叉时回包缺 `localRevision` / `localEpoch`**：Dart 把它当改投影命令（`kSrsSync2ProjectingOps`），每一轮收了段都调，于是真内核上每轮报「projecting command reply lacks localRevision」。改成没分叉也带（修订号不推进）。`projecting_sync_replies_carry_the_local_revision`，变异 M11 红。

仍没做 / 移交：

- **旧根接手**（v2 一次性迁移、v3 段承袭上传 `oldroot_scan` / `Uploader`）：两条路径现在都不跑，交接 §17.4 原状。规模大（Dart 要列旧根段、走承袭上传），本轮没做。
- **G9-5**：`srsRemoveOwnProfileFolder` 遇到 `v4/` 按「别人的东西」处理（不删整个 profile 目录），安全但不清理本机在新根的目录；`srs_profile_link.dart` 列远端时只跳过 `v4/`，新根下设备的说明文件（若以后要放）还没有读法。
- **上游（不归 G8-7）**：① `SrsDbStore.open` 在还没绑定的 profile 上直接抛 `SrsProfileUnboundException`（open 段；真内核测试得先经 `SrsCore.sync2` 发 `identity` 立绑定）；② 新代库上 `SrsDbStore.note(...)` 在 `_prefetchEdits`（`srs_db_store.dart` 约 2500 行）Null check 崩——`edits` 表读回来的 `e` 与请求的 id 对不上，自己写的笔记也一样，所以 `srs_sync4_folder_test` 改按 `status` 与语义摘要核收敛。
- 媒体命令（`media_*`）仍归 G8-7b；文件夹位置的媒体对账在接上之前照样报未接线。

## 18. W2 合流修复（2026-11-17，分支 `pr/srs-gen4-w2-merge`，integration owner）

本波六个分支（G7-2b §11、S1c §12、G7-5b §13、G9-6 §14、G11-3 §15–§16、G8-7 §17）合流时与合流后自动审查发现的跨模块问题。

### 合流取舍

- `srs_db_store.dart`：G9-6 的 `_canonicalBuiltins` / `_derivedBuiltins` / `resolveBuiltinIds` / `open` 尾部那一行删掉，保留
  G7-5b 的 `_loadRootIds`（§14「与 G7-5b 合流」）；G9-6 公开的 `canonicalIds`（带条数校验）顶替 G7-5b 私有的 `_canonicalIds`。
  `srsNormalizeStoreIds` 不再手调 `resolveBuiltinIds`（绑定变化让 `srsStoreProvider` 整份重建）。
- `dispatch_tests.rs` 未接线清单 = 合流后 `wiring` 里仍是 `Unwired` 的：G9-5（`profile_merge_mark`）、G8-7b（`relay_outbox`）。
- §7 对照表 `import` / `export` 行取 G11-3，同步一轮各行取 G8-7。

### 刷新键：不经 `Session` 落真相的写（S1c × G11-3 / G8-7）

`import`、`ingest`、`ingest_finish`、`retire`、`rotate` 落真相、推进本机修订号，却不经 `Session`，合流后 Primary 的进程内
刷新计数（`refresh.rs`）不动：Dart 按刷新键判缓存，导入 / 收段之后读旧缓存（Secondary 按修订号拼键，不受影响）。修法：
与修订号同一个判据（`sync.rs` `bump_revision` 的 `n > 0`；导入 `!unchanged`）在回包里放 `Tally::all()`，分发器提交之后
`noted` 取走、整份作废（`refresh.rs` 文件头「谁推进」已补）。预检、要确认、`unchanged`、没收到东西的一轮不推进。
测试：`fushisrs_tests.rs` `an_import_that_changes_something_moves_the_refresh_keys`、`sync_tests.rs`
`landing_sync_commands_move_the_refresh_keys`（经 C ABI；变异实测：去掉两处 `Tally::all` → 两条都红）。

### 导入补盐与设备公钥要确认（G11-3 × G9-4）

合流前：同一个集合 / 早已并入的 `.fushisrs`，清单里本机还不算数的盐（`collection_adopt` → 本机签名的 `Salts`，结论
`saltsAdded`）与本机还不认识的设备公钥（清单 `peers`）不经确认直接落。查设计（§5.1 盐由受信设备签名的操作携带、§5.4 第 6 条
同一集合另一个旧 uid 的备份「只写一条 `Salts`」）没有「同一集合的盐无需确认」的安全论证，代码里也没有证据约束：
`gen4_ids/alias.rs` `profile_entities` 对每个盐把「ID 等于这个盐」且出现过的实体直接归到 profile 级设置实体（不看种类、
不做自然键验算），一个自称同一集合的文件带一个等于本机某条笔记 / 某个牌组 ID 的「盐」就能把它并错；设备公钥先到先得，
错的公钥让那台设备真正的段以后一直被拒。所以取保守做法：

- 内核（`cmd/fushisrs.rs` `unconfirmed_identity`）：同一个集合 / 已并入、没带 `confirmed` 时，有新盐或新设备就回
  `{outcome: "needsConfirm", reason: "identity", collection, dir, newSalts, newPeers}`、什么都不写；另一个集合仍是
  `reason: "join"`（同形，也带两张表）。预检同形。确认过的再导一遍不再问。
- Dart：`SrsFushiSrsForeign` 加 `reason` / `newSalts` / `newPeers`（`fromReply`），导入页按原因换提示
  （新键 `srs_timeline_import_identity_confirm`，其余 15 种语言是英文占位）。
- 测试：`new_salts_and_peers_from_a_same_collection_file_need_confirmation`（变异实测：去掉门 → 红）；既有用例里同集合带
  新设备的导入改为确认后导入；Dart `srs_fushisrs_test.dart` 同步。
- 代价：新装设备第一次导入自己复习库的包也会问一次（包里设备的公钥本机还没有）。流里原生日志抬头自带的公钥
  （`import_ops_from` 的 `got.peers`）仍不经确认落下——与清单 `peers` 同样是先到先得，这一处没收，归 G11-3 / 身份负责模块定。
- 另记（不归本次合流修）：`profile_entities` 不看实体种类就把等于盐的已出现 ID 归到 profile 设置实体，即使经确认、经同步
  （受信设备写的 `Salts`）进来的盐也一样，归 G9 / 别名层核实是否要限定种类。

### 没做 / 交给谁

- S1c 留给 G7-5b 的撤销记录器（`_SrsUndoRecorder.noteWritten` 按输入下标认领，§12「没做」）：两边 API 合流后都在，改动本身
  很小（`_emit` 传一张「第 i 条草稿点名的键」表，`noteWritten` 有下标时按它对 `_before`），但真内核上的测试（草稿点名
  `createDeck` 回的带盐成员）在改之前就先崩在 `noteBefore` → `_currentValues` → `_prefetchEdits` 的
  `Null check`——即 §14「按成员 ID 读实体视图会崩」那条（请求按成员 ID、回包按规范 ID 作键），没法证明改对，本次没合入。
  先修读路径（或上游 `salt_of`，§13.6 第 1 条），再按上面的做法补，测试照「成员 ID 改一个牌组字段 → 撤销项带 dot、撤销完整」。
- 本波定向 Dart 测试里的红都属这一族（上游 `salt_of` 仍给 Dart 派生的 ID 加盐 → `createNote` / `createDeck` 回成员 ID）：
  `srs_fresh_profile_e2e_test.dart` 3 条（新卡被藏，§13.6 第 1 条）、`srs_fushisrs_test.dart` 3 条与
  `srs_write_statement_cost_test.dart` 2 条（`note` / `noteType` 按成员 ID 读崩在 `_prefetchEdits`，§14）、
  `fushi/test/srs/srs_word_audio_backfill_test.dart` 的 store 用例（成员 / 规范 ID 对不上，§14「派生 ID 的返回值」）。

## 19. G9-7 ID 口径根修（2026-11-17，分支 `pr/srs-gen4-g9-7-id-derivation`，基于 `pr/srs-gen4-switch`）

收掉 §13.6 第 1 条、§14「派生 ID 的返回值」「按成员 ID 读实体视图会崩」、§18「没做」第 1、2 条。schema 不升（没加表 /
索引，分到的 40020 没用）；ABI 不变（只多回包键）。

### 定案：新写入一律规范 ID，`ids` 不再加盐（按设计正文定）

- **口径**：`gen4_ids/derive.rs` 删掉 `salt_of`，根上的规则（笔记、笔记类型、内置笔记类型、牌组、备选牌组、内置默认
  牌组）一律按 `rules::CANONICAL` 答，与 profile 无关、不碰库；只有 `location_dir` 还要 `profile`（协议 3 时代的目录名，
  新代目录向绑定要）。依据：设计 §5.2「新写入的实体一律按现有规则表、去掉 `<profileUid>/` 前缀」、§5.1 2026-11-15 改正
  「查绑定只为两件事：位置目录名，与别名验算用的盐集合；写入不用盐」（D24）——绑定表没有「写入用哪个盐」的列，也不需要
  （规划 §11.5 第 8 条矛盾按设计正文定）。
- **为什么不让内核另给「新实体 ID」**：规范 ID 本来就是「规则表（不带盐）」的纯函数，内核答的 `ids` 就是权威来源，Dart
  不加盐、不自己算（`SrsKernelIds` 仍是唯一入口，守卫 `srs_kernel_ids_guard_test` 照旧）。另开一条按库的命令只会多一次
  往返，答案相同。
- **迁移来的库**：存量实体 ID 是协议 3 按 uid 加盐的；迁移写了 `Salts{uid}`，别名层（`alias.rs`，自然键 × 盐集合反向验算）
  把它们归到**同一个**规范 ID（内置默认牌组 `builtin_default_deck(CANONICAL)`、内置笔记类型同理）。所以 Dart 拿规范 ID
  建内置实体落在已有的类上，不另建一份（`ensureBuiltins` 按读回的 ID 判在不在；Rust 测 `a_migrated_library_folds_the_
  salted_builtins_into_the_ids_it_answers`：带盐默认牌组归一 = `ids` 的答案、重发身份记录 `landed: false`、牌组数不变）。
- **全新库**：`identity` 仍写 `Salts{uid}`（G9-4 定案 3），保留：全新库与「迁移一份空的协议 3 库」逐表相同的性质不变；
  它不再是 Dart 写入归一的前提，只给以后进来的存量（备份 / 旧设备的带盐操作）归一用。
- **规范 ID 是不带盐的常量**：补盐 / 并入（`bindingChanged`）不改变内置 ID 与按名字 / guid 算出的 ID。

### 写回包带落下的规范 ID：`entityWrites`

- `cmd/writes.rs` `Session::land`：每条身份记录进回包 `entityWrites: [[输入下标, 种类, 规范实体 ID], …]`（下标规则同 `edits`
  第 7 列：`apply` / `change` 原样、`import_drafts` 按筛掉之前的原输入、意图命令自己拼的 = null）。文件头「回包」已补。
- Dart：`srsEntityWritesByInput`（同 `srsWrittenByInput` 的严格认领：一条认领两次 / 越界报错）。`_emit` 加 `onEntities`；
  `createDeck`、`createNote` 返回回包里的规范 ID；`writeEdits` 加 `onRecords`，`_writeNewType`（`createStockNoteType` /
  克隆）返回它。身份记录草稿必定回一条，缺了报 `StateError`（内核与 Dart 对不上），不退回请求 ID。
- 新口径下这些入口的请求 ID 本来就是规范 ID，回包只在「请求 ID 是别名成员」时（调用方传进持久化的旧 ID）不同；以回包为准
  是为了不再有第二个真相。

### 按请求 ID 预建槽的读：回包 `canon` 表

- `cmd/reads.rs`：`entities` / `edits`（带 `ids` 时）的 JSON 回包放 `canon: {请求 ID: 规范 ID}`，只列两者不同的（`cmd/mod.rs`
  `canon_ids_echo`，与 `canon_ids` 同一次归一）；都是规范 ID 时不带这个键。行照旧按规范 ID 出、一个类一份（文件头「回包里
  的 ID 按什么对回去」的契约不变，只是省掉调用方另问别名表）。
- Dart：`srsRowsByRequest`（`canon` 为空时原样返回）。`_editItemsById` 改读 `_read` 拿 JSON、按请求 ID 对回：`_prefetchEdits`
  （§14 的 `Null check`）、`_editItems`、`_entityEditsMany`、`noteFieldKeyValues` / `noteFieldKeyPrefixValues` 都随之按调用方
  给的 ID 拿到行；`_prefetchEntities` 同理（以前成员 ID 的笔记 / 笔记类型视图读成 null）。没有在 Dart 侧逐条 `canonical_ids`。
- `_loadRootIds` 不再发 `canonical_ids`：内置 ID 直接取 `SrsKernelIds`（一次 FFI，不碰库）；`ensureBuiltins` 去掉归一往返。

### 撤销记录器按输入下标认领（S1c 留下、§18「没做」第 1 条）

- `_SrsUndoRecorder.noteWritten(edits, byInput:)`：`_emit` 把「第 i 条草稿点名的 (种类, 实体, 字段键)」交进去，回包 `edits`
  有输入下标的项按它对 `_before`（请求形），没有下标的（意图命令自拼、`editNoteFieldsIf` / `mergeNotesInto` 等直接传
  `edits` 的调用点）仍按回包里的 (种类, 实体, 字段键)。草稿点名别名成员时撤销项也带 dot。
- 改前值（`_currentValues`）：实体 ID 已按 `canon` 对回，但**键里嵌的 ID**（`f/<字段>`、`fieldDef/`、`fieldDesc/`、`tmplDef/`、
  `historyFrom/`）是成员时，视图与寄存器按规范键出、按请求键取不到，改前值记成空，撤销把字段清空（e2e 测出来的）。复核
  后改成由内核随读回键的规范形（见下「复核修复」第 2 条），不再另发 `canonical_ids`。

### ID 审计接到新代（`store/gen4/id_audit.rs`）

- 协议 3 的审计只挂在协议 3 的写连接与 `SrsCore::exec_raw`，生产入口换成 `G4Core` 后一次都不经过，审计版库里连
  `id audit: ` 都被裁掉（`build_windows_dll.ps1 -IdAudit` 的 `audited=True` 校验失败）。现在 `id_audit` 构建里：`G4Core::open`
  的写连接与读连接池每条连接装 trace（`id_audit::install`）；分发器每条命令之后（`dispatch.rs` `dispatch`）、原始通道
  （`kernel.rs` `exec_raw` / `exec_batch_raw`，写之后再扫存储）调 `id_audit::take`，有问题回 `id audit: …` 错误。
- ID 列从新代建表语句里取（不手抄清单）：有表声明成 `BLOB` / 无类型、且没有表把同名列声明成 `TEXT` 的列名；拿 UUID 文本去比
  这些列算漏编码（新代没有 `srs_id(` 这一层，不用协议 3「整条没 `srs_id(` 就全算」那条，按文本存 uid / 目录名的列本来就该绑
  文本）。判定复用 `ids::audit::quoted_uuid_with`（协议 3 的 `quoted_uuid` 改成它的一个特例，行为不变）。
- 测试构建不装 trace（每条语句展开 SQL 太贵，且进程级的记录会串到并行的用例）；`id_audit.rs` 的 3 条单元测试在内存库上
  直接装了测判定与存储扫描。

### 测试

- Rust：`cmd/id_reply_tests.rs`（3 条，经 C ABI）——全新库 `ids` 答的写进去读回同一个、`canon` 为空；迁移来的库（真
  `gen4_migrate_run`）带盐默认牌组归到 `ids` 的答案、不另建、按带盐 ID 读回 `canon`；别名类成员的 `entityWrites` 与 `canon`。
  `gen4_ids/derive.rs` 的 `answers_the_canonical_rules_whatever_the_profile`（换 profile 答案不变、不带 profile 也答）；
  `id_audit.rs` 3 条。全量 `cargo test --profile quick --lib -j 4`：1240 passed / 0 failed / 39 ignored，无告警。
- Dart：新 `packages/fushi_engine/test/srs/srs_id_derivation_e2e_test.dart`（真内核，2 条）——全新库与迁移形的库（带盐身份
  记录 / 修改 / 带盐内置实体经 `writeEdits` 写成存量，`identity` 的 `Salts{uid}` 归一）各走一遍「建牌组 → 建笔记 → 读回 →
  改 → 撤销」，后者含按带盐 ID 读视图、重开指纹不变（不重复建内置实体）、按成员改字段撤销项带 dot。Dart 侧造不出协议 3
  库（没有协议 3 写入口），真迁移那一份在 Rust 测里。`srs_binding_reload_test` 第 1 条按新口径改：前提「请求形 ≠ 规范形」
  不再成立，改成「补盐换库前后重开都不写、默认牌组只有一个」。golden 测试与 `kernel_ids_test` 改成「`SrsKernelIds(uid)` 答
  规范值、与 uid 无关」，带盐向量按存量公式在测试里算，冻结文件一个字节没变。`srs_canonical_ids_store_test`（G9-6）与
  `fushi/test/srs/srs_persisted_ids_test` 的真内核组同理改造：成员 ID 不再是 `createDeck` / `SrsKernelIds` 的返回值，按存量
  公式算并把带盐实体作为存量写进库（别名层只归一库里出现过的成员——迁移来的库里偏好指向的实体都在）；「实体后来出现」
  改成带盐存量后到（如旧设备的操作）。
- 真内核实测（`--here`，本 worktree 的 DLL；`dart test -r json` 按文件计数）：engine `srs_fresh_profile_e2e_test` 4/4、
  `sync2/srs_fushisrs_test` 7/7、`srs_id_derivation_e2e_test` 2/2、`srs_binding_reload_test` 5/5、`srs_canonical_ids_store_test`
  6/6、`srs_canonical_ids_test` 12/12、`srs_gen4_canonical_ids_golden_test` 4/4、`srs_write_statement_cost_test` 2 过 1 跳 1 红
  （见下）；`fushi_srs` `kernel_ids_test` 7/7；app `srs_word_audio_backfill_test` 7/7、`srs_persisted_ids_test` 6/6、
  `srs_remote_review_test` 29/29。`flutter analyze --no-pub`（fushi/）No issues。

### 没做 / 交给谁

- `srs_profile_merge.dart`（协议 3 的旧 profile 并入）第 1、2 步按 `SrsKernelIds(oldUid)` / `(newUid)` 现算带盐 ID 对存量；
  新口径下两边答同一个规范值，这段映射退化（带盐存量走兜底 ID）。这条路在新代没接线（`profile_merge_mark` 是
  `Unwired("G9-5")`），归 **G9-5** 按操作并集重写时一并删掉。
- `cards` 等别的按 ID 出行的读（`cardRows` 按 `r.id` 对）没加 `canon`：卡 ID 由规范笔记 / 模板派生，Dart 手里的卡 ID 都是读回
  来的规范形；真遇到成员卡 ID 的调用点再按同一个 `single_echo` 补。
- 远程库（`SrsRemoteStore` / `entity_views`）的对回方式不变，归 **G10-2**：`SrsRemoteStore.writeEdits` 跟着加了
  `onRecords`，远程协议不回落下的 ID，报请求里的身份记录 ID（与它的 `canonicalIds` 原样返回同一处理）。
- 本波定向测试里仍红、不归本模块（改动前同样红，已用 HEAD 的 Dart 源 + 同一 DLL 复核 `srs_edit_undo_test`）：
  `srs_write_statement_cost_test`「本机写操作的语句数与内核命令数」——以前先崩在 `_prefetchEdits`，现在走到最后的
  `applyRemote`（另一台设备导出的带戳事件）被内核拒：`apply: stamped items carry a foreign identity`（见下「复核修复」第 4
  条，归 **T1 / G9-5 二选一，由 integration owner 指定**）；`srs_edit_undo_test`「连续两步倒序撤」（与 ID 无关）；`fushi/test/srs/srs_remote_store_parity_guard_test`
  第 1 条（守卫的覆盖正则认不出 `late final String defaultDeckId = …` 这种覆写，本模块没碰这几行）。

### 复核修复（2026-11-17，同一分支）

1. **ID 审计的 Dart 自检改新代口径**（`packages/fushi_engine/test/srs/srs_id_audit_gate_test.dart`）。审计接到新代后测试宿主
   优先加载 `prebuilt/windows-x64/id_audit/` 那份库（`FushiFsrs.isIdAuditVariant` 为真），这个门不再 skip，而它仍按协议 3 的
   `srs_review_logs` 与 `srs_id(?)` 写，3/3 红（`no such table`）。改成新代的表与 ID 绑定：拿 UUID 文本比 `notes.id` 报
   `id audit`；同一条语句一个按 Ref 绑、另一个漏成文本仍报；原始通道把 UUID 文本写进 `cache_log.note` 写完扫存储报；
   按 Ref（16 字节，测试里的 `srsIdType`）绑、`collections.profile_uid` 这类按文本存的列绑文本照常执行（4 条）。
2. **改前值的键归一放进内核**（复核 minor：`_currentValues` 给空字段写值时每次多一次 `canonical_ids`）。`read edits` 多一个
   可选的 `keys`（调用方接下来要取值的字段键），回包 `keyCanon` 给其中归一后不同的「请求键 → 规范键」（`Index::canonical_key`，
   与 `canon` 同口径、只列不同的，`cmd/reads.rs` `edits`）。Dart `_currentValues` 把嵌着 ID 的键交给它本来就要发的那次寄存器
   读（`_entityEditsMany` → `_prefetchEdits` → `_editItemsById`，只在第一块带），按 `keyCanon` 换规范键取视图 / 寄存器的值；
   删掉兜底的 `srsCanonicalIdMap` 往返。测试用的计数 `SrsDbStore.debugCanonicalIdsCalls`。
3. **真迁移库的内置笔记类型折叠**（复核 minor：Dart 侧的「迁移形库」是先建规范内置实体再补带盐的，证不了真迁移库开库不
   另建）。Dart 造不出协议 3 库（`ffsrs_store_open` 已删，Dart 没有协议 3 写入口；`SrsGen4Migration.run` 要现成的 `srs.db`），
   所以在 Rust 补：`id_reply_tests::a_migrated_library_folds_the_salted_builtin_note_types_and_takes_new_writes`——协议 3 库里
   按 uid 加盐写下内置 Lapis、Fushi 卡片（`ankiNum` + `builtin`）与一个用户牌组，经真 `gen4_migrate_run` 迁移；断言带盐的
   三者与默认牌组都归到 `ids` 的答案、笔记类型表里没有带盐那份；按规范 ID 再发一遍 `ensureBuiltins` 那一批身份记录
   `landed` 全 false、笔记类型 / 牌组集合不变；再建同名牌组（落在已有类上）、新牌组、新笔记，读回 `canon` 为空，按带盐
   ID 改牌组名落在规范 ID 上、`edits` 按带盐 ID 读回 `canon`。撤销在 Dart（`revertEdits` 是条件写），Dart 的迁移形 e2e
   覆盖。`dispatch_tests::migrated_prepared` 改成 `pub(super)` 供它用。
4. **`srs_write_statement_cost_test` 第 1 条的归属**：红在最后一步 `dst.store.applyRemote(remote)`，内核按设计拒绝外来的带戳
   事件（`apply: stamped items carry a foreign identity`，`cmd/writes.rs` 约 :621；复核用基线 Dart lib + 同一 DLL 同样卡在这
   一步）。这条用例本身还是协议 3 的「两台设备互灌事件」场景，以前被 `_prefetchEdits` 的崩溃挡在前面。要改成走 collection
   join（同步 / 并入的新路径）或删掉这一步——归 **T1（测试重写）/ G9-5（并入）二选一，由 integration owner 指定**；本模块
   不改（不是 ID 口径）。
5. **已知行为：信任未确认 / 名字史被清时的可见重复（推测，未复现）**。新口径下带盐存量能不能归到规范 ID 看盐集合，作者
   未被本机信任时它带来的盐不算（`alias.rs` 模块说明、`Index::withheld_salts`）。所以：一台全新设备加入别人迁移出来的集合、
   还没确认信任时，对方带盐的默认牌组 / Lapis 是独立的类，本机 `ensureBuiltins` 会再写一份规范的，用户短暂看到两个
   Default；确认信任后两份并成一类，不丢数据。另外牌组名字史被清除后规范 ID 退回带盐 ID 自身，这时按同名再建牌组也会
   重名。没让 `ensureBuiltins` 在有被扣住的盐时暂缓：暂缓意味着全新设备在确认信任前没有默认牌组 / Lapis 可用（制卡直接
   失败），比短暂重复更糟；重复会在确认后自动合并。真要处理归确认信任的 UI（G9-4 / G8-7b）。

## 20. G9-5 删旧并入、收薄 profile 关联（2026-11-17，分支 `pr/srs-gen4-g9-5-profile-merge`）

### 内核命令逐条去向（`cmd/profile_data.rs` 文件头有同一张表）

| 命令 | 结论 | 说明 |
|---|---|---|
| `profile_uids` | 实现（读） | `collections` 全表的 `profile_uid`；`orphanSweptAt` 记在新键 `profile_orphan_sweep_g4`（协议 3 的完成标记不带过来：迁移把孤儿 uid 各迁成一个集合，新代要再扫一次） |
| `orphan_sweep_done` | 实现（`write_local`） | 只清「没有绑定、只剩 `local_state/<uid>`」且不在 `keep` 里的；`deps` 恒 0（新代没有 `sync2_deps`，`op_deps` / `writers` / `snapshots` 按内容共用，不 GC） |
| `meta_set_edit` | 实现（只读走读快照，否则 `write_local`） | 协议 3 同键同语义；迁移把两行带过来 |
| `profile_purge` | 实现（`write`，之后 `refresh_invalidate`） | 删这个 profile 绑定的一个集合（`discard.rs`）+ `local_state/<profile>`；可带 `collection` 核对用户确认的集合，对不上报错、什么都不删 |
| `profile_merge_mark` | **Removed**（`NO_P3_MERGE`） | 新代不再起协议 3 式 uid 并入，关联走 `collection_adopt` / `collection_join` |
| `profile_merge_commit` | **改义**（`write_binding`，之后 from / to 各 `refresh_invalidate`） | 迁移带过来的半截并入的收尾：`{from, to, now}`，见下 |

`read_lib profile_merges` 改为读新代库 `srs_meta` 的 `profile_merge/` 区间（以前恒空）。

### 空集合可换绑（`identity.rs` `adopt_foreign` → `rebind_empty`，判据 `discard.rs` `disposable`）

确认之后、写 `Join` 之前判：有本机身份，`devs` 里只有本机，本机区间里全是 `Salts`、没有空洞 / 承袭槽 / 暂缓 / 分叉 / 等待，
`peers` 里没有别的设备、`trust` 无记录，`loc_heads` / `relay_out` 无本集合行，`srs_meta` 无 `gen4_out/<col>/…`。成立就同一个
事务里 `discard_collection` + `bind` 到对方、`derive_cfg` 照搬，结论 `bound`；本机身份由 `cmd/identity.rs` 在对方集合里重建
（`Salts{profile}`）。取舍：`location_root` 只写位置 meta 与围栏、不含操作，**不算**发布。

`discard_collection`：表清单现查（`sqlite_schema` × `pragma_table_info`），按 `col` / 设备主键区间 `k BETWEEN` / `dev` 删；
`cache_gen` 不删而是抬一代并抬下限（`collections.col` 无 AUTOINCREMENT，号会被紧接着的 `bind` 复用，常驻浏览会话按
(集合号, 代号) 认缓存）；`srs_meta` 删 `self_info/<col>`、`gen4_out/<col>/…`、`gen4_retired/<col>/…`；最后删绑定行、
`t.reset()`。

行为变化（已改测试）：全新 profile 导入别的集合的 `.fushisrs`（`fushisrs_tests.rs`
`alias_classes_survive_an_export_and_a_foreign_import`）现在是 `bound` 不是 `joined`；`identity.rs` 几条 Join 单元测试的夹具
先写一条修改（`substantive`）让集合不空。

### 半截并入（D23 改判）

迁移不再以 `mergeHalfDone` 拦（`BlockCode::MergeHalfDone`、Dart `SrsGen4BlockedReason.mergePending`、i18n
`srs_gen4_blocked_merge` 都删了）。两个 uid 各迁成一个集合，`profile_merge/<旧 uid>` 与 `srs_retired_v2_devices` /
`srs_retired_profile_uids` 由 `migrate.rs` `carry_library_meta` 在提交步骤原样写进新代库。收尾 `profile_merge_commit
{from, to, now}`：标记在且 `newUid == to` 才做；`from` 有集合就导出它的操作与公钥 → `discard_collection(from)` →
以 `to` 的身份 `collection_adopt(confirmed)`（`to` 有内容按 D27 Join，空就换绑）→ `import_peers` + `import_ops`；
删标记与 `local_state/<from>`。重映射副本靠别名层（`A_FALLBACK` / `alias_writer_ix`）归回原件。**代价**：`from` 的
`op_pending` 与本机状态（信任决定、暂扣、检查点、媒体记录、位置记忆）不带过去，以 `to` 的为准。端到端测试
`prepare_tests.rs` `a_half_done_merge_is_migrated_and_finished_in_the_new_generation`。

### G7-2b verify2 三处遗留

- 补完之后的第二次空间核对：`check_space(.., PrepCopy::InUse)` 不再把在用的补完副本算成可用空间（`reclaimable`，
  测试 `migrate_tests.rs` `an_in_use_preparation_copy_is_not_counted_as_free_space`）。
- 升级路径「全部 profile 都补」：`prepare_tests.rs` `a_v3_3_0_upgrade_completes_every_profile_even_clean_ones`（同一份库
  不降级只补孤儿、降级后 P 也在清单里，两个分支互换都过不了）。
- 新代库旁更老 schema、没封存、来源无身份的 `srs.db`：`files.rs` `source_is` 按文件状态（主文件与 `-wal` 的长度 +
  修改时刻）在新代库 `srs_meta` 的 `retained_unrelated` 记「不是来源」，同一状态不再算整库摘要；`migrated_from_is` 先比
  身份有无。测试 `an_unrelated_older_library_is_digested_once_per_file_state`（`files::DIGESTS` 计数）。

### Dart

- `srsPurgeProfileRows(core, uid, {collection})`；`srsRemoveOwnProfileFolder(.., v4Device)` 认识 `v4/`：先于写入者
  目录判、只删 `v4/devices/<v4Device>`，有别的设备就保留整个根，不给 `v4Device` 时 `v4/` 一个字节不碰（测试
  `srs_profile_link_test.dart`「清理认识新代根 v4/」）。

### 没做 / 交给谁（G9-5 续，建议另开一段）

- `srs_profile_link.dart` 的关联流程改走 `collection_adopt` / `collection_join`（按 `v4/meta.json` 列远端集合、确认页沿用、
  位置目录用 `identity` 回的 `dir`），`srs_profile_merge.dart` 收成「续做半截并入」（改主库 uid → 拷媒体 →
  `profile_merge_commit {from, to, now}`），`srs_profile_data.dart` 删 `srsMarkProfileMerge`、`srsCommitProfileMerge` 改新
  语义：本次没做。现状：Dart 旧并入仍会发 `profile_merge_mark`（现报 `REMOVED`，此前报 `UNWIRED`，同样失败，没有新的
  回退），`srs_profile_merge_test.dart` 等在新代内核上本来就红（§ 前文「G9-5 未接」）。linker 调
  `srsRemoveOwnProfileFolder` 时还没传 `v4Device`（新代身份的设备 ID 要从 `identity` 取）。
- `ensureMigrated` 后走不到的「迁移前只拉不发」（`srs_sync_scheduler.dart` `_pullInto`、`srsSync2PullOnly`）与其余协议 3
  并入残留没删（连带调度器上千行，§17.4）。
- `ffi.rs` `every_protocol_3_command_has_a_gen4_wiring` 的未接线下限从 `> 10` 放到 `> 0`（未接线只会随模块接线减少）。
- `cmd/dispatch_tests.rs` 的 `open` / `call` / `g4req` / `g4` / `T1` / `cfg` 与 `cmd::dispatch_tests` 模块改成 `pub(crate)`，
  给 `prepare_tests.rs` 经 C ABI 跑半截并入收尾用。

## 21. G9-5 复核修复（2026-11-17，同分支 `pr/srs-gen4-g9-5-profile-merge`）

### 半截并入的 Dart 收尾接上了（复核 major）

上一轮只改了内核：迁移不再拦 `mergeHalfDone`，标记带进新代库，`profile_merge_commit {from, to, now}` 收尾；但 Dart 的
`_resumePendingMerges` 仍调协议 3 的 `srsMergeProfileUid`，第一步发 `profile_merge_mark`（`REMOVED`），而以前被拦在迁移
外的这批用户现在能迁进来、`read_lib profile_merges` 读得到标记——每一轮 link 都失败、记一条错误日志，`from` 的集合作为
看不见的第二个集合一直留着、收尾永远做不完。上一轮交接里「此前报 UNWIRED，同样失败，没有新的回退」对这批用户不成立，
特此更正。本轮：

- `srs_profile_merge.dart` 收成「续做半截并入」：`srsResumeProfileMerge(db, profileId, oldUid, newUid, commit, mediaRoot)`。
  主库还指着旧 uid 时先拷媒体（内容寻址、不覆盖）、改主库 uid，再调 `commit`（生产 = `srsFinishProfileMerge`，发
  `profile_merge_commit {from, to, now}`），之后再拷一次媒体并删旧媒体目录；主库已是新 uid 时只做收尾。顺序不能反：先收尾
  后改主库，中间被杀主库就指着一个没有集合也没有标记的 uid，打开时建空集合、数据看上去全丢。失败留着标记，同样参数重跑。
- 协议 3 的重映射算法（约 800 行）、`SrsProfileMergeDeferred` / `SrsProfileMergeStage` / `SrsProfileMergeResult` /
  `kSrsMergedWriterPrefix` 删了；`srsMergeProfileUid` 只剩抛 `SrsProfileMergeRemoved`（签名留着只因冻结的协议 1 客户端测试
  副本 `test/srs/sync2/v1_client` 不许改；那份副本随 G7-6 删时一起删）。
- `srs_profile_data.dart`：删 `srsMarkProfileMerge`，`srsCommitProfileMerge` 换成新语义的 `srsFinishProfileMerge`
  （回 `SrsProfileMergeFinish = (folded, outcome)`）。
- `SrsDbProfileLinker`：`_resumePendingMerges` 改走 `srsResumeProfileMerge`；续做失败不往外抛（标记留着、下一轮重试），
  同一个失败每进程只记一次日志（`_resumeFailuresLogged`），不每轮刷。新代没有「暂缓的并入」：`deferredMerge` 恒 null，
  `_noteDeferred` / `_deferred` 删了；`SrsDeferredProfileMerge` / `SrsProfileAdoptDeferred` 类型留给调度器与同步状态页，
  随关联重写删。用户在冲突弹窗里选定候选、本机有数据（要并入）时 `_switchUid` 在记退役设备之前就抛
  `SrsProfileMergeRemoved`、什么都不改（以前是发到 `REMOVED` 才失败）。新的时钟注入点 `nowMs`。
- 「调度器每一轮都调 link」仍是从 `srs_sync_scheduler` 持有 `profileLinker` 推出来的，没有 app 实测。

### 其余复核项

- **补完后第二次空间核对的调用处**：`migrate.rs` 加 `free_bytes` 测试注入点（`FREE_BYTES`，按调用现算）；测试
  `prepare_tests.rs` `the_second_space_check_after_completion_does_not_count_the_copy_as_free`：副本出来之后那次核对注入
  「副本要的 − 1」，结论必须 `noSpace`、原件不动、不留新代库。变异实测：`PrepCopy::InUse` → `Stale` 该测试红。
- **真实半截并入的重映射副本**：`a_half_done_merge_with_remapped_copies_folds_them_back_into_one`——P 里放协议 3 并入第一遍
  落下的副本（经 `apply` 写成 P 的操作；日志与卡都按兜底 ID `v5(NS, profile-merge/<P>/<旧 ID>)`），旧 uid 的默认牌组按旧
  uid 派生。收尾之后复习日志按规范 ID 数不多出一条，兜底 ID 与原件同一个规范 ID，两个 uid 的默认牌组归成同一个。变异实测：
  `gen4_ids/alias.rs` `fallbacks_of` 不认兜底 ID 时该测试红。**没覆盖**：`merged-…~<原写入者>` 改名写入者的修改记录与按新
  uid 重新派生的笔记类型 / 字段 / 模板副本（夹具要先在旧 uid 下造笔记与修改记录；别名层对这两类各有单元测试）。另：一开始
  把副本写成 P 的**旧投影行**（不是操作）时迁移对拍判 `fail`（P 已包完、补完不再包那一行）——那不是真实形态（协议 3 并入
  经 `applyRemote` 写操作），记在这里免得后人再踩。
- **`profile_purge` 的确认**：`srs_profile_cleanup.dart` 在 `_prepareUid`（给用户看规模、导出备份）时记下
  `store.sync2Collection`，`run()` 作为 `collection` 传给 `srsPurgeProfileRows`；确认之后改绑 / 并入过就报错、一行不删。
  测试 `fushi/test/srs/srs_profile_cleanup_test.dart`「G9-5: the purge checks the collection the user confirmed …」（准备后
  经 `collection_adopt` 按 D27 并入对方并改绑，`run()` 抛错、规模不变）。`srs_backup_merge.dart` 里的两处调用（归 G11-4）
  没传，未动。
- **空集合换绑带走本机声明过的盐**：`AdoptOutcome::Bound` 加 `carry`（换绑丢掉的空集合里本机算数、对方不算数的盐）；
  `cmd/identity.rs` `collection_adopt` 在 `ensure_self` 之后 `carry_salts` 补写一条 `Salts`。测试
  `cmd/profile_data_tests.rs` `rebinding_an_empty_collection_carries_the_salts_it_declared`（`collection_salts_add` 过的旧 uid
  换绑后仍在盐集合里、`nextSeq` = 3）。变异实测：`carry` 恒空该测试红。
- **`srsRemoveOwnProfileFolder` 不再删 `v4/` 根**：只删 `v4/devices/<本机>`，根（含 `meta.json`）与 profile 目录永远留着——
  别的设备可能已按 `meta.json` 换绑、还没发布设备目录。`srs_profile_link_test.dart`「清理认识新代根 v4/」改断言。
- **死测试**：`fushi/test/srs/srs_pull_before_migrate_test.dart` 的「档案合并之前的拉取按进度判」整组（测协议 3 并入前的
  只拉不发，路径已不存在）与只供它用的 `_HangingStore` / `_DeviceB` 删了；`srs_profile_purge_single_test.dart` 的并入用例删了。

### 没做 / 交给谁（G9-5 续）

- `srs_profile_link.dart` 关联流程改走 `collection_adopt` / `collection_join`（按 `v4/meta.json` 的 `collection` 列远端集合，
  确认页沿用，位置目录用 `identity` 回的 `dir`，linker 传 `v4Device`）：没做。现状：本机有数据的 profile 在冲突弹窗里选定
  候选会明确报 `SrsProfileMergeRemoved`（不改任何东西），只有本机没数据的「采用」还能走。没定的设计点：D27 吸收方向
  （本机目录名小、对方并进来）时对方设备读不到本机位置上的 `Join`，要先定发现机制。
- `ensureMigrated` 之后的「迁移前只拉不发」（`srs_sync_scheduler.dart` `_pullInto` / `pullBeforeMerge`、`srsSync2PullOnly`、
  linker 的 `pullBeforeMerge` 参数与 app 装配）没删：调度器是同批多个模块的热点文件，删上千行留给 integration owner 合流后
  单独一段做。`srs_pull_before_migrate_test.dart` 剩下的用例本来就 `skip`。

### 第二轮复核修复（2026-11-17，同分支，针对 `f3f567d61c`）

- **半截并入收尾方向固定，`to` 绝不改绑（复核 major）**：`profile_merge_commit` 以前借 `collection_adopt`，按 D27 比目录名
  定方向、`to` 空就换绑、`to` 没绑定就直接绑到 `from` 的集合——`to` 的目录名比 `from` 大、`to` 在本机没绑定、`to` 是空集合
  三种情形都会把 `to` 改绑到 `from` 的集合和目录，本机从此跟用户别的设备同步不到一起且不报错（原来两条端到端测试恰好都是
  P < ORPHAN，只覆盖了不改绑的方向）。现在收尾单独走 `identity.rs` `absorb_foreign`：不按 D27、不换绑，一律在 `to` 的日志里
  写 `Join{from: from 的集合}`，`to` 的集合标识与目录名不变；`to` 在本机还没有集合时先按打开 profile 的口径建
  （`cmd/identity.rs` `identity_ensure`：`collection_of(to)`、目录名 `to`——协议 3 时代采用过 `to` 的设备迁移后都在这个集合）。
  测试 `cmd/profile_data_tests.rs` `finishing_a_half_done_merge_keeps_a_larger_target` /
  `…_binds_an_unbound_target_to_its_own_collection` / `…_keeps_an_empty_target`（`to` = Q > `from` = P；断言 `to` 的
  `collection` / `dir` 不变、只有一条 from = P 集合的 `Join`、两边的修改都在、库里只剩一个集合）。变异实测：收尾换回
  `adopt_foreign(.., confirmed)` 三条全红。**已知取舍**：`from` 的集合若曾被别的设备持有，那台设备之后遇到 `to` 仍按 D27 判，
  看不到 `to` 日志里这条 `Join`；`from` 是本机被并入方的旧 uid，正常只有本机持有，不另做处理。
- **空集合只在 D27 方向上换绑（复核 minor 4）**：以前「空集合可换绑」不看方向，两台都是空集合的设备互相确认会交叉换绑。
  现在只有本机目录名**更大**（D27 本来就是本机改绑到对方）时才换绑；本机目录名更小时照 D27 吸收。结果与 D27 完全一致（都落在
  目录名小的集合），只省掉那条 `Join`。新 profile 的目录名是它的 uid（UUIDv7，按时间递增），「新设备加入已有集合」的常见情形
  仍换绑。测试 `identity.rs` `two_empty_collections_converge_whichever_initiates`；变异实测：去掉方向条件该测试红（A 也换绑到 B）。
  `fushisrs_tests.rs` `alias_classes_survive_an_export_and_a_foreign_import` 的导出方目录名改成 `0-dir`（比导入方 Q 小），
  仍断言 `bound`。
- **孤儿 `meta.json`（复核 minor 4 后半）**：`disposable` 多一条——`loc_state` 有本集合的行（`location_root` 写过位置的根 /
  `location_seal` 记过加密）就不算空集合。位置上的 `meta.json` 已经让别的设备看得见这个集合，内核不碰位置上的文件、删不掉它，
  所以碰过位置的集合不丢，照 D27 并入。调度器先 `link` 后跑第一轮，新设备关联时通常还没立根，不影响换绑。测试
  `a_collection_with_anything_beyond_its_own_salts_still_joins` 加 `rooted` 一项；变异实测：去掉这条子查询该项红。
  `discard_statements_use_an_index` 照旧覆盖 `DISPOSABLE_SQL`（`loc_state` 主键打头是 `col`）。
- **续做时旧 uid 的副本退役（复核 minor 3）**：`srs_profile_link.dart` `_resumePendingMerges` 手里的副本还是旧 uid 的时，
  续做（改主库 uid → `profile_merge_commit` → 删旧媒体）在它的 `retire` 里跑：在途写入先写完，之后经它来的写入一律
  `SrsStoreRetiredError`，不会落进已并走的旧 uid、让 `local_state/<旧 uid>` 重新长出来；作废了就不管成败都按 profiles 表
  当前的 uid 重开。测试 `packages/fushi_engine/test/srs/srs_profile_merge_resume_test.dart`（真主库 + 真内核：旧副本
  `isUsable` 为假、写入抛 `SrsStoreRetiredError`、新 uid 里查得到旧 uid 的笔记、标记与旧本机状态行都没了）；变异实测：
  去掉 `retire` 该测试红。
- **一个写事务里整份导出再导入（复核 nit 5）**：没改，理由写进 `cmd/profile_data.rs` 文件头——拆成多个事务会出现
  「`from` 已丢、`to` 只导入了一部分」且无从续做的中间态；同一事务里分批要么边读 `from` 边往 `to` 导入（导入改 `to` 的派生层，
  读游标跨着写不安全），要么落临时文件（多一份要清理的用户数据）。内存占用是压缩过的 `FSRS4EXP` 流（`export.rs` 边读边压），
  半截并入只发生在协议 3 并入中断过的少数库上、一次性。
- `packages/fushi_srs/test/store/srs_core_test.dart` 里仍断言 `profile_merge_mark` 是 `Unwired` 的那条归合流代理改，本分支没动。

## 22. G8-7b 同步补全（2026-11-17，分支 `pr/srs-gen4-g8-7b-sync-complete`，基于 `pr/srs-gen4-switch`）

接 §17.4 的全部「没做」。Rust 在 `native/fushi_fsrs/src/store/gen4/cmd/` 的 `media_sync.rs`（媒体同步）、`sync_oldroot.rs`
（旧根接手与承袭上传）、`sync_relay.rs`（转发）、`sync.rs`（收段切片、`plan` 收被转发的 head、`obsolete_former`），存储层
复用第一段（G8-3 媒体清单 / `media_at`，G8-5 `oldroot.rs` / `inherit.rs`，G8-4 `sync_state.rs`，G8-2 `FRL4`）。Dart 在
`srs_sync2_round.dart`（一轮的顺序）与新文件 `srs_sync4_steps.dart`（旧根、承袭、媒体清单、旧身份目录、转发各一步）。

### 命令（新接线 / 改了请求的）

| 命令 | 事务 | 做什么 |
|---|---|---|
| `media_known` / `media_record` / `media_hash` / `media_scan` / `media_landed` / `media_bind_unbound` / `media_doomed` | 见 `media_sync.rs` 文件头的表 | 协议 3 同名命令的新代实现；名字 → 内容的绑定是真相层的 `Media` 操作 |
| `media_manifests` / `media_manifest_ingest` / `media_manifest_build` / `media_manifest_published` | 读 / `write_local` | 新代才有的媒体清单收发（D18：每个 hash 带在 / 不在与 HLC） |
| `oldroot_scan` / `oldroot_ingest` | 读 / `write` | 协议 3 根 `v3/` 上的段 → 本机承袭日志（指纹门；指纹与落库同一事务） |
| `heritage_plan` / `heritage_outbox` / `heritage_ack` | 读 / 读 / `write_local` | 本机承袭日志里位置上缺的区间 → `v4/devices/<本机>/hrt-…`（D19，先于本机原生段） |
| `obsolete_former {device, present, archive?}` | 读 | 本机旧身份目录里只删旧两代以上的 head，段一个不删 |
| `relay_outbox {location, key?, maxBytes?}` | 读 | 位置缺的别的设备的段（`rly-`，按目标位置钥匙封装）与段齐了之后的 head（`rhd-`）；回包 `{files, more, incomplete}` |
| `relay_ack {location, paths?, deleted?}` | `write_local` | 记 `relay_out`；head 写上后不再被引用的中继件与旧 `rhd-` 改待删；删可转发段；回包 `{delete}`（两段式：删好了带 `deleted` 报回） |
| `ingest {key?, maxItems?}` | `write` | 新增 `maxItems`（收段让路）：一个事务最多做多少项新工作，回包 `rest` = 交完了的段数；另回 `kept`（留了几份转发原文） |
| `plan {…, relayed?}` | `write_local` | 新增 `relayed`：块的末尾几份是 `rhd-`（认公钥、定要拉的段，不记 `loc_heads`、不取消停用）；早有但没留原文、别的位置缺的段再要一次 |
| `ingest_begin` / `ingest_end` | 无事务 | 内核收段会话：期间攒住 RWKV 刷新键，结束放一次（`refresh.rs` `rwkv_held`） |

schema `40021`：`relay_segs`（收段时留下的可转发作者段，不封装的 `FRL4`；普通 rowid 表 + 唯一约束，没有显式索引，
`PLANNER_STATS` 不变）。40020 没用（预分配给同批别的 PR）。

### 定案（所有者授权自定）

1. **文件夹位置只收不发（major）**：`media_*` 全部接线后 `beforeUpload` 的媒体对账不再抛 `SrsCoreUnwiredException`，
   文件夹与云端位置都走到 outbox / head（`srs_folder_location_test`、`sync_complete_tests.rs` 的媒体两设备用例）。
2. **旧根接手（硬条件）**：`v3/` 每轮按清单指纹判要不要读（没变不读），收进承袭日志后经承袭段发到新根；新设备只连
   新根也拿得全（`old_root_takeover_reaches_migrated_and_new_devices_alike`：两台各自接手 + 一台新设备，派生层相同）。
   **只有协议 1 `v2/` 的位置不做一次性迁移，明确拒绝——这是偏离 D21，不是按 D21**（上一版这里写成「D21 定为不支持」
   是错引：设计稿 `2026-11-11-srs-generation-break.md` 的 D21 原文与 §G8 行都是「协议 1 旧根继续支持，入口改只读转译
   （转进承袭日志）、不写 v3 meta」，本文开头的 D21 条也是这么记的）。按所有者授权「旧格式兼容可从简（明确拒绝并提示
   升级），不能丢用户现有卡片和复习记录」定案：机读码 `srs_location_protocol1_root`、位置上一个字节不写、本机卡片与复习
   记录不动（拒绝发生在碰位置、碰本机库之前），界面给专门的升级提示（见下「复核修复」第 3 条）。理由：旧迁移入口
   `srsPrepareLocation` 按协议 3 写 `minReader 3` 的 v3 meta，在协议 4 下等于拆围栏；按 D21 原文做只读转译要在新代
   重写一份协议 1 读者（Dart 旧入口 `srs_location_migration.dart` 1649 行），代价与风险都远大于收益（协议 1 已两代之前）。
   另外每个位置都先在 `v2/` 立协议 1 围栏（`srsEncodeV1Fence`），协议 1 客户端读到就停。
   **后果**：只在协议 1 位置上同步过、从没用 3.x 同步过的用户，升级后这个位置用不了（本机数据完好），要先用 3.x 同步一次
   或换位置；位置上只存在于协议 1 根里的别的设备的操作，在那台设备升级之前拿不到。**与任务书「v2/ 一次性迁移接进一轮
   同步」及设计稿 D21 都不符，交 integration owner / 所有者确认；不认可就按 D21 原文补只读转译（可复用 `oldroot` /
   承袭那套积木）。**
3. **多台各自迁移的设备不做副本收敛**（§11 第二条交 G8 / G9 的那项）：同一份协议 3 历史经旧根接手走承袭日志，按
   （旧设备, seq）槽对齐（同号槽只降不升，D19），不会多一份；§11 说的「每台各自把旧行包一遍」产生的是各自设备名下的
   原生操作，派生层按 dot / 日志 ID 取操作号最小的那份（`derive.rs`），用户看到的结果正确，只多体积与同步量。要收敛
   就得跨设备删别人签过的操作，违反「只增」与签名链；只出现在「多台设备、协议 3 从没同步确认过、共享旧行」的用户身上。
   不做，记在这里。
4. **摘要核对不需要协议 3 `heal.rs` 的新代对应物**：新代真相是每台设备一条签名链（收段逐项验链），派生层是真相的
   纯函数（每条端到端测试都核「增量 == 整个重建」），所以同一个版本向量（head 的 `ack`）下摘要必然相同；不同只可能是
   派生口径版本不同（head 的 `derive`）或派生 bug，本机重放修不好、只能升级或修 bug。所以只诊断不自愈：`status` 的
   `seenAt`（对端最新 head 的写出时刻）/ `digestMismatch`（同 `ack` 指纹下摘要不同）/ `warning` / `frozen`（换身份后
   冻结的旧身份）填真实值（`plan` 把对端 head 的时刻、`ack` 指纹、摘要记进 `peers.ext`）。Dart 的
   `SrsSync2Report.healFailed` 与调度器 `_reportHealFailed` 一起删掉（恒空的字段）。本机派生层坏了的修复入口照旧是
   `digest_heal`（整个重建，冲突中心 / 诊断用），一轮同步里不调。
5. **收段让路**：`ingest` 带 `maxItems`，`Receiver::with_budget` 数「落进日志 + 新进等待缓冲」的项，用完时停在原生段
   的下一项之前（已落的是日志前缀，下一事务再交同一段时按本机已有跳过，只重算链）。Dart `SrsDbStore.sync2IngestBatch`
   按 `kSrsSync2IngestSliceItems = 256` 循环，每片一次 `_sync2IngestStep`（各进一次写锁），作答在两片之间插进来；各片计数
   合成一份回包。实测（`ingest_slices_a_large_batch_into_budgeted_transactions`，桌面 quick profile）：1500 条操作、
   每片 ≤ 200 项、8 个事务，最慢一片约 0.47 s（大半是每片重新解开整段的开销）。收段会话期间 RWKV 刷新推迟到
   `ingest_end`（`an_ingest_session_holds_the_rwkv_key_until_it_ends`）。
6. **purge 接成生产路径**：`Session` 收尾与 `Receiver` 收尾里 `Index::execute_purges` 把被清除的操作在同一事务落成空洞，
   发件按「传时空洞条数」退水位重切重传（`the_purge_command_voids_published_ops_everywhere`）。
7. **转发**（协议 3 `relay.rs` 的新代对应物，设计 §4.4 / D16 A）：收段时把别的受信设备的原生段 / 中继件重新包成不封装
   的 `FRL4` 存进 `relay_segs`（只在本机同步着 ≥ 2 个活跃位置时存，活跃见「复核修复」第 2 条）；`plan` 把读到的别的设备 head 按代号只进不退记进
   `srs_meta` `gen4_rhead/<col>/<设备>`；`relay_outbox` 给目标位置缺的段（按目标位置钥匙封装，签名照用作者的），段都
   确认之后才给 `rhd-` head；每个位置都有了就删原文。本机在有第二个位置之前就收过的段：`plan` 再要一次（收段按已有
   跳过、只留原文），下一轮转发。被转发的 head 用 `rhd-` 前缀，不覆盖作者自写的 `head-`、不当位置证据。

### 委托描述与代码不符

- 「转发要存收到的作者段原字节」：原字节在加密位置上是按源位置钥匙封装的密文，换位置要先解开；存的是解开后、作者签名
  不变的不封装中继件（`wrap_relay4(seg, pub, src_key, None)`），发出时再按目标钥匙封装。效果相同，且本机不必记源位置钥匙。
- 「新加入的设备只能拿到迁移之后的操作」：旧根接手接上之前确实如此；接上后由承袭段补齐（见定案 2）。

### 测试

Rust（`cmd/sync_complete_tests.rs`、`cmd/sync_relay_tests.rs`，经 C ABI）：媒体两设备经文件夹位置对账；旧根接手（协议 3
位置 + 两台迁移设备 + 一台新设备）；新集合不判成存量、只有 `v2/` 拒绝；purge 两端落空洞；收段会话攒 RWKV；状态字段；
旧身份目录清理；拓扑不全连通的转发（明文 L1 + 加密 L2，三台收敛、转发件按 L2 钥匙封装、转发完不留原文）；作者自己连上
目标位置后停止转发；后连上的位置补拉转发；只连一个位置不留原文；收段切片（增量 == 重建、三台摘要相同）；并入
（`collection_join`）之后经位置同步收敛、两份盐的默认牌组归一到同一规范 ID；围栏中途（只写成新根就断）由下一台设备
补上；新语句查询计划（`relay_lookups_use_their_keys`、`g87b_lookups_use_their_keys`）。加密位置、增量 == 重建的
通用用例在 G8-7 的 `sync_tests.rs`。

Dart：`srs_format_break_test`（保留并转绿）、`srs_sync4_round_test`（假内核：一轮顺序、旧根 / 承袭 / 媒体清单 / 旧身份
目录 / 转发各一步）、`srs_sync4_folder_test`、`srs_sync2_lock_free_test`、`srs_sync2_ingest_batching_test` 的新用例「收段
让路」（真内核：一批切成多个写锁事务，摘要与对端一致）；`fushi_server` 的 `server_srs_test`（首次同步含 `location_sealed`
一路走通，7 条全绿）。

### 没做 / 交给谁

- **ID 口径（G9-7）一族的红**（`SrsDbStore.note` 读回的 `edits` 与请求 ID 对不上，崩在 `_prefetchEdits`）：
  `srs_folder_location_test`「两台设备经同一个文件夹收敛」、`srs_sync2_round_test` 4 条、`srs_sync2_relay_test`（转发本身已
  通：C 收到 A 的段，崩在之后的 `c.note`）、`srs_sync2_ingest_batching_test` 3 条（其中「第二批上传失败」的前提已按新代
  改成切小段）、`srs_location_sealed_test`「从没见过加密的明文位置」。没有绕开，等 G9-7。
- `oldroot_ingest`（旧根接手的落库）没有 `maxItems`：每批按 Dart 的 8 MB 字节预算切，一批一个写事务。迁移后第一轮捡
  大的旧根时一个事务可能装几百个协议 3 段，作答要等它。没切是因为收尾批（`settle`）要求「这一批正好是本轮重算的待读
  清单」才记指纹（指纹与落库同一事务，`oldroot.rs` 文件头）——按项切会让收尾批永远凑不齐整份清单，得先把指纹改成
  跨事务累计的形状。影响只在迁移后第一次捡旧根（之后清单不变不读）。
- 移除位置没有生产路径删 `loc_state` / 调 `forget_location`（新代没有「移除位置」命令）：转发已按活跃窗口不再等死位置，
  剩下的只是几行状态。要做就在 G10 的位置管理里加一条命令。
- `ffi.rs` wiring 分类断言是 `unwired > 0`（只剩 G9-5 的 `profile_merge_mark`）：G9-5 合流后要改成允许为空或删掉。

### 复核修复（2026-11-17 第二轮）

1. **收段切片误判没进展（major）**：`ingest` 回包新增 `spent`（这一片做的新工作：落库 + 新进等待缓冲，`Receiver::spent`）。
   Dart `sync2IngestBatch` 只在 `rest == 0 && spent == 0` 时判契约坏了；以前拿 `landed` 当代理，依赖方的段排在前面时
   一片全停进等待缓冲（`landed = 0`）就抛 `StateError`，大库首次同步要连着失败约 N/256 轮。用例
   `ingest_slices_count_parked_items_as_progress`（a 写 300、b 改这 300、c 收时 b 的段在前、预算 100，至少一片是「只停
   放」，一路收完、与 b 收敛）；Dart 真内核用例 `srs_sync2_ingest_batching_test`「收段让路：依赖另一台设备的段排在前面时…」
   （a、b 交替各写 256 条，c 一轮收完无错、摘要与 a 相同——不论 a、b 谁的段在前，前面那台都有一长串依赖后面那台的项）。
   变异：回包 `spent` 改回 `landed` → Rust 用例红；Dart 判据改回 `landed` → Dart 用例抛 `sync2 ingest slice made no
   progress`。
2. **转发目标只认活跃位置（major）**：`head` 写 head 时记 `loc_state.last_ok`（不变跳过也记，这一轮在这个位置成功了）；
   转发目标 = `last_ok` 非空、且离本机最近一次成功不超过 30 天（`ACTIVE_WINDOW_MS`，协议 3 同值）。与协议 3 不同，
   `last_ok` 为空的不算：新代的空行来自迁移（`carry.rs` 把协议 3 见过的每个加密位置都灌进来）和 `plan` 第一次读到位置
   时建的行，都证明不了位置还在用；新位置第一轮写完 head 就进来，晚一轮开始转发。用例
   `stale_or_never_synced_locations_are_not_relay_targets`（迁移行 + 40 天前的旧位置：不留原文、`plan` 不为它补拉）、
   `a_location_left_idle_past_the_window_stops_holding_relay_copies`（超出窗口后下一轮 `plan` 的 prune 清空原文、之后不再
   留）。变异：去掉窗口筛选 → 两条都红。
3. **协议 1 旧根的升级提示**：`srsSync2Round` 遇到 `srs_location_protocol1_root` 时 `report.error` 就是机读码本身
   （`kSrsLocationProtocol1Root`）；i18n `srs_sync_location_protocol1_root`（`i18n_sync` 加齐 17 语言）；调度器发一次
   `SrsSyncNotice.locationProtocol1`（toast），「立即同步」的失败原因与复习历史页的位置行都显示这句，不再是泛泛的
   「同步失败 / 位置不可用」。定案改写见上「定案」第 2 条。
4. **被转发 head 不当位置证据**：`a_device_on_two_locations_relays_between_them` 末尾先让 c 再写一条、b 在 L2 收下，再让 b 在
   L1 跑一轮（读得到 L1 上 c 的 `rhd-`），断言 c 不进 L1 的 `loc_heads`、留给 L1 的原文没被 prune。变异：`plan` 的
   `if !is_relayed` 改 `if true` → 该用例红（以前三个模块 35 条全绿）。
5. **转发的读取**：`wanted_for_relay` 判原文在不在改用 `RELAY_HAS_SQL`（`SELECT 1 … LIMIT 1`，不读 `piece`）；`relay_out`
   按 `(col, loc_key, device)` 主键前缀查（`Truth::relay_out_of`，`relay_ack` 循环里与 `sent_names` 都用它）；`plan` 与
   `relay_outbox` 的旧身份整轮取一次。两条新语句进 `relay_lookups_use_their_keys`。
6. **承袭段计入收段预算**：`land_slots` 把落下 / 待投的槽记进 `spent`；承袭段不在中途停，但用完预算后这一片不再开下一段。
   用例 `heritage_segments_count_toward_the_ingest_budget`（旧根接手后的新设备按预算 1 收：第一片只收承袭段、`spent` ≥
   落下的旧历史，原生段留到下一片）。变异：去掉计数 → 该用例红。`oldroot_ingest` 本身没切，见「没做」。
7. **收尾投递等待缓冲也按片**（上一轮「没做」里的那条）：`drain_native` 投出的项计入 `spent`，预算用完时停在下一项
   接得上的等待项之前，回包 `drainMore`；Dart 段都交完了见到 `drainMore` 就不带段再收一片（投递片必有进展，否则抛
   `sync2 ingest drain made no progress`）。不用跨事务游标：投出的行当场删，下一片重扫 `op_wait` 从剩下的接着投。停下时
   那一遍的分叉 / 两支报告可能不全，投完那一片再报。用例 `ingest_drain_of_the_waiting_buffer_is_sliced_too`（c 先把 b 依赖
   a 的 300 条整段停进缓冲，再按预算 64 收 a：之后有 ≥ 3 片不带段的投递片、每片投出 ≤ 64，最后不剩等待项、与 b 收敛）。
   Rust 测试的收段循环收成一个照搬 Dart 判据的 `ingest_like_dart`。变异：去掉投递时的预算判断 → 两条用例红；Dart 忽略
   `drainMore` → 真内核双作者用例红（剩等待项）。

## 23. G10-2 远程复习 V2（2026-11-17，分支 `pr/srs-gen4-g10-2-remote-review-v2`）

### 线上形状与决定

- 内核 `entity_views`（`native/fushi_fsrs/src/store/gen4/cmd/views.rs` 文件头）：请求 `{kind, ids}`，回 `{views:[{id, tag, v}]}`。
  `v` 是视图 JSON 原文（`id/k/d/edits/tags/logs/row`），`tag` = blake3(v) 前 16 字节 hex——**标签就是视图本身的摘要**，
  客户端按标签缓存不再自己拼「身份记录 + 修改记录」再算。同一别名类只出一份（规范 ID）、不存在的跳过；单次上限同
  `canonical_ids`（`LOOKUP_MAX` = 4096，Dart 侧 `kSrsEntityViewsBatchMax`）。走 `read_col`，集合查找与命令体一个快照。
- 解码只有一份：`packages/fushi_engine/lib/srs/srs_entity_views.dart`（`SrsEntityView` → 修改记录 / 物化输入）。
  `SrsDbStore.entitySources` 删掉，换成 `entityViews`（分块发内核命令）。
- V2 端点 `/api/srs/remote2/`：请求体带 `g: 4` 与（握手之后的读写）握手时拿到的 `col`；回包信封多了 `col` 与
  `ids {deck, lapis, fushi}`——**内置实体 ID 一律取主机的规范 ID**，客户端不再按 uid 派生；要把派生 / 成员 ID 归一走新操作
  `canonicalIds`（问主机内核，单次上限同上，超了 400）。读写带的 `col` 与主机当前集合不一致 → 409 `profile_changed`；客户端只在握手时取 `col`，之后回包里看到别的集合
  也报 `profile_changed`（作废缓存、不改手里的 `col`），不在某次读里悄悄换成新集合再拿旧集合的 ID 落写。
- 已配对首页缓存版本 `_kPairedCacheVersion` 升到 2（旧缓存里的卡片 / 牌组 ID 是派生口径，直接作废）。

### 四个方向

| 客户端 | 主机 | 结果 |
|---|---|---|
| V2 | V2 | 照常 |
| V2 | 旧（只认 `/api/srs/remote/`） | 能力位只有 V1 → `hostNeedsUpgrade`，列出不握手；真打到旧端点的 404 无机读码 → 客户端换成 426 `upgrade_required` |
| 旧（V1） | V2 | 主机能力位声明 V2 + V1（V1 只是拒绝桩）；V1 前缀任何请求 → 426 `upgrade_required`，不进服务、不碰库 |
| V2，`g` 不对 | V2 | 426 `upgrade_required` |

复习关掉时 V2 路径回 503 `{error: unavailable}`，V1 仍 404。

### 白名单

- 操作表即白名单：表外操作（`identity` / `binding_*` / `collection_*` / `import` / `export` / `purge` 等）→ `unknown_op`。
- 透传内核的只有 `kSrsRemoteKernelOps`（`entity_views`、`canonical_ids`、`history` 与浏览类读命令），唯一出口是
  `srsRemoteKernelCommand`（闸门本身有直接测试）；`browseCommand` 再收窄到浏览会话命令，点别的 → 400。
- 写操作的实体种类拒 `profile`（`editFields*` / `writeEdits` / `revertEdits` 的撤销项都查）；`writeEdits` 带非空
  `records`（身份记录）→ 400。
- 库在换代途中（`SrsStoreOpenBlocked`）：`Migrating` / 未迁完 → 503 `migrating`；迁移失败 / 只剩封存旧库 /
  旧库没迁 → 503 `migration_failed`。app 侧 `SrsAppRuntime` 给远程复习服务单独的 `readRemoteStore`，不把这个异常吞成「没有库」。

### 测试

- Rust `cmd/views_tests.rs` 4 条：经 C ABI 与本机 `read entities/edits/logs` 对拍、别名类（`tests_class::land`）只出规范 ID、
  畸形请求拒绝、缓存行点查走主键（EXPLAIN）。
- Dart：engine `srs_remote_store_test.dart` 新组「V2 协商、规范 ID 与白名单」8 条（含读带错集合 409、内核闸门、
  `syncConflicts` 按类批量取视图）；fushi `srs_remote_review_test.dart` 新组「远程复习 V2（G10-2）」6 条（读卡 → 作答 →
  主机日志、回包换集合报 `profile_changed`、笔记视图无身份记录报 `bad_response`、新客户端 → 旧主机、旧客户端 → 新主机、白名单）。
  「读卡 → 作答」的卡 ID 从主机库直接读（`noteIdsOfType` / `cardsOfNote`），不经出卡队列，现在就卡住 V2 作答链路。
- 复核修复（同分支第二轮）：`syncConflicts` 的修改记录按类收齐、归一后每类一次 `entity_views`（原来每个冲突实体整份取一次视图）；
  `cardDetail` 卡在而笔记视图没有身份记录 → `bad_response`（原来静默当成卡不存在）。

### 本波定向测试的红（都不归 G10-2）

- 「ID 口径」族（§14 / §18）：`srs_remote_review_test.dart` 里凡要主机出卡 / 按 `createDeck` 回值找牌组的那些（停在主机
  `studyState(...).next` 为 null；主机自己 `host.store.studyState` 也一样；V2 组的作答链路已改成不依赖出卡队列）；engine `srs_profile_ownership_test.dart` 全组与
  `srs_exclusive_sites_cost_test.dart` 第 10 步崩在 `_prefetchEdits` 的 `Null check`（seed 阶段，未经远程通道）。
- `fushi_server/test/server_srs_test.dart` 5 条：`readyProfiles` 一直为空（服务端 profile 起不来），远程复习两条因此拿不到
  `remoteStore`——归 G10-3（服务端迁移状态机）。

### 没做 / 交给谁

- 本机 `SrsDbStore` 的物化仍走 `read entities` + `edits`，没改成读视图（与 `entity_views` 已经 C ABI 对拍等价）。
- `fushi_server` 的 `migrating` 映射：服务端 profile 打开 / 迁移状态归 G10-3；本模块只在共用的 `SrsRemoteStoreService` 里接了。
- `profile_of_dir` 没做；客户端 `noteTypesFrom` 里内置笔记类型的字段 ID 仍按 uid 派生（ID 口径模块）。
- 主机目录与信任（G10-4）没碰。schema 号 40023 未使用（没加表 / 索引）。

## 24. G10-3 服务端无头迁移与代际状态机（2026-11-17，分支 `pr/srs-gen4-g10-3-server-migration`，基于 `pr/srs-gen4-switch`）

纯 Dart（`packages/fushi_server`），Rust 未改，没用 schema 号，`server_backup.dart` 未碰。

### 实现

- `ServerSrs`（`server_srs.dart`）开库前先调 `gen4_migrate_status`：`needsMigration` 时不开库，直接在后台无头跑
  `gen4_migrate_run`（`SrsGen4Migration.run`，后台 isolate；`start()` / 改配置不等它）。`migrationFailed` / `sealedOldOnly` /
  `migratingElsewhere` 记成对应状态。状态是 `ready` 时才开库；开库再抛 `SrsStoreOpenBlocked` 的照同一张表处理，
  其中 -6 对应 `legacyBesideNew`。
- 代际状态 `ServerSrsGeneration`（`generation`）：`ready` / `migrating` / `migrating_elsewhere` / `needs_migration` /
  `migration_failed` / `sealed_old_only` / `legacy_beside_new` / `blocked`（带内核 `BlockCode`）/ `no_space` / `error`。每个状态都带
  步骤进度、上次结论、原因原文、报告路径、空间数，以及给管理员的处置说明 `advice`。结论到状态的映射：
  - `committed` → `ready`，随后重新套用配置：开库、各份打开并同步；
  - `aborted` → `migration_failed`（带报告路径；之后状态命令报的 `migrationFailed` 不覆盖它）；
  - `cancelled` → `needs_migration`；
  - `noSpace` → `no_space`；
  - `blocked`：`migrating` → `migrating_elsewhere`，`sealedWithoutNew` → `sealed_old_only`，`legacyBesideNew` → 同名状态，其余 → `blocked`；
  - 迁移命令抛异常 → `error`。
- 自动重跑规则（`autoRetry`）：只有 `ready`、`migrating_elsewhere`、`blocked(busy)` 这几种「等一会再来」的状态会自动重跑，
  并且距上次结论至少过了 `kServerSrsMigrationRetryDelay`（1 分钟）。实际重跑发生在兜底定时器（30 分钟）的下一轮判定，
  不会在刚跑完时紧接着再跑。其余结论一律不自动重跑，也不删任何文件，等管理员处置。进程被杀后重启，`autoRetry` 在新
  进程里是初始值，会自动续做：内核取锁后先清掉临时库与补完副本，然后从头开始。如果是提交点之后才被杀，Primary 开库时会
  补封。
- 缓存配置的来源是 `legacyProfiles`（内核列出的旧库 profile，含孤儿 uid）∪ 配置里提供的 profile ∪ 同步目录里看得到的
  profile，每个 uid 用 `srsCacheConfigFor` 生成。多给的配置内核不用；列表读不到时只记日志，缺了哪个由内核拦下
  （`missingCacheConfig`）。
- 进度：每秒轮询一次 `gen4_migrate_status.running`，写进 `generation`，也就是 admin 状态与 ctl 看到的进度；步骤变化、开始、
  结论、状态转换都写日志（`ServerSrs.migrate` / `ServerSrs.generation`）。
- 不可用期间的请求（`upgradeRefusal`）不会 500，也不会挂起，一律回 503：
  - 升级中（含 busy）：`srs_upgrading`；
  - 其余失败类状态：`srs_upgrade_blocked`；
  - 远程复习：选了 profile 时 `remoteStore` 照样给出，默认 profile 或点名的已提供 profile 回 `SrsRemoteStoreError.migrating` /
    `migrationFailed`（G10-1 预留的两个码），没提供的 uid 仍回 `profile_changed`；
  - admin ctl 的复习内容端点、设备信任端点、AI 操作的可用性：回 503 加上面两个 reason；
  - AnkiConnect：503，正文说明是升级中还是要服务端处理。
  各份 profile 的状态新增 `upgrading` / `upgrade_blocked`，`lastError` 填处置说明；迁完后回到 `opening`，第一轮同步跑完才对外提供。
- 停服：提交点之前叫停并等结论；过了提交点就等迁移跑完。
- admin API 新增三个端点：`GET /api/admin/srs/migration`（`generation` 加各份状态）、`POST …/migration/start`（202，或 409
  `srs_migration_running` / `srs_migration_not_needed` / `srs_migrating_elsewhere` / `srs_stopped` / `srs_unavailable`）、
  `POST …/migration/cancel`（409 `srs_migration_not_running` / `srs_migration_past_commit`）。`GET /api/admin/srs` 也带 `generation`。
  ctl 新增 `srs migration [status|start|cancel]`。操作目录新增 `server.srs.migration`（只读）、`server.srs.migration.start` 与
  `.cancel`（irreversible，要表态），描述与路由一起写在 `admin_ops.dart`。

### 定案与任务书不符处

- **迁移按目录做，不按 profile 做。** 服务端只有一个库目录 `<support>`，所有 profile 共用一份 `srs.db` / `srs4.db`，内核的
  迁移也是整目录一次提交。任务书里「多 profile 目录逐个迁，单个失败不影响其余」在现在的结构里不成立：某个 profile 的问题
  （例如 `mergeHalfDone`）会拦下整个目录，所有 profile 一起进 `upgrade_blocked`。要做到按 profile 隔离，得先把服务端改成每个
  profile 一个库目录，那是存储布局层面的改动（会动备份布局与 G10-4 的 host 目录），不在本块。
- 「缓存配置按 `status.profiles` 给」：G7-2b 已经把 `profiles` 从状态命令里拿掉，改由 `gen4_migrate_profiles` 提供（§11），
  这里按后者取。

### 测试

- `test/server_srs_migration_test.dart`（9 条，用假执行端）：
  - 启动即后台迁移，缓存配置是旧库 profile 并上配置里的；迁移中远程复习默认 / 点名都回 503 `migrating`、没提供的 uid 回
    409，ctl 回 503 `srs_upgrading`；进度进 `generation`；迁移中改配置不另起一次；提交后开库、各份离开 upgrading；
  - `mergeHalfDone` 可见且不重跑，管理员手动开始后再跑；对拍不过记报告路径，之后状态命令报的不覆盖它；
  - 启动时目录已是 `migrationFailed` / `sealedOldOnly` / `migratingElsewhere`：不迁移、文件不动；别的进程迁完后下一轮自动接着迁；
  - `legacyBesideNew` / `sealedWithoutNew` / `noSpace` 不重跑（重试间隔设成 0 也不重跑），`busy` 自动再试；
  - 叫停：过了提交点拒绝，之前叫停后不重跑；停服时过了提交点等它跑完，没过提交点先叫停；
  - 迁移命令报错记成 `error`；复习关时不判定。
  变异实测：把 `autoRetry` 改成恒真，5 条变红。
- `test/server_srs_migration_e2e_test.dart`（真原生库）：用协议 3 夹具 `fixtures/srs_protocol3_two_profiles.db.gz`（schema 29，
  两个 profile，其中一个只在投影表里；生成器 `srs_protocol3_two_profiles_generator.rs.txt`，生成时临时贴进 `prepare_tests.rs`，
  贴进去的那份已撤回）。场景：目录里先放上被杀进程留下的坏临时库与补完副本；启动后自动迁移，提交，副本被清掉，旧库原位封存；
  另开句柄读主 profile，笔记 3 条都在；重启直接开新代库，不再迁移。日志里能看到真的走了 `precondition` → `commit` →
  `committed`。
- `ctl_commands_test`（`srs migration` 三个动作，用法错误回 64）、`admin_srs_ops_test`（三个新操作的风险分级）、
  `admin_srs_test`（没有旧库时迁移端点回 ready / `not_needed` / `not_running`）。

### 已知 / 交出去的

- **服务端现有 SRS 测试仍红，归 G8-7b。** 服务端第一轮同步卡在 `SrsCoreUnwiredException: media_hash is not wired yet (G8-7b)`
  （日志里 98 次，没有别的内核错误），profile 一直停在 `opening`、`storeFor` 为 null。红的有：
  - `server_srs_test` 5 条、`admin_srs_ctl_test` 7 条、`admin_srs_device_trust_test` 3 条、`server_srs_mining_test` 5 条；
  - `server_srs_rwkv_test` 3 条、`server_ankiconnect_test` 2 条、`admin_srs_test`「加 / 设默认 / 去掉 profile」1 条。
  共 26 条（9 个文件 53 条执行）。这些和迁移无关，G8-7b 接上 `media_hash` 后应自然转绿，不加 skip。
- `server_backup.dart`（G11-4）：迁移进行中复习库没开，`snapshotFn` 为 null，备份会自己离线打开 `srs.db`。G11-4 改服务端备份时
  请看 `ServerSrs.migrationRunning`，迁移中拒绝或等待。本块按文件边界没碰这个文件。
- D32 的「服务端保留副本在首次新代同步成功 14 天后自动删，并给 ctl 提前删除的入口」没做：需要第一轮新代同步先能跑通（G8-7b），
  还需要内核提供删保留副本 / 写墓碑的全局命令，目前没有（`write_tombstone` 不经 C ABI）。交 G8-7b 之后的服务端后续或 G7-6。
- ~~WebUI 没加迁移状态的显示与按钮~~：复核修复轮已补（见下「复核修复」）。
- 没有协议 3 身份的原件对拍中止后，状态命令报 `needsMigration`（§11 已知），服务端每次启动会自动再迁一次，每次再中止并重写报告。
  不丢数据，只是每次启动多跑一遍；这一点继承自 G7-2b 的缺口。

### 复核修复（2026-11-17）

- 互联制卡（`remote_mining_host.dart`）：复习库升级中 / 升级受阻且这次本该落进复习（点名复习、默认落复习、或没接 Anki）时，回
  类型化的 `error` + `errorCode` `srs_upgrading`（transient）/ `srs_upgrade_blocked`（permanent，附 `generation.advice`），
  不再按 2026-11-08「点名的给不了就退回默认」悄悄落进 Anki、也不回 `notConfigured`；`miningTargets` 带 `reviewUnavailable`。
  点名 Anki 且 Anki 可用的照常进 Anki。
- `precondition` / `missingCacheConfig` / `noLibrary` 各自有处置说明；`precondition` 与未知 code 不再引导「再跑一次」。
- 叫停：用现取的 `gen4_migrate_status` 进度判断能不能叫停（不用滞后一个轮询间隔的那份）；仍可能与提交点竞态，内核在提交点
  之后不受理，以最终结论（cancelled / committed）为准，操作目录描述与日志写明。
- `busy` / 别的进程在迁移：隔 `migrationRetryDelay` 挂一次性定时器自己再判定，不等 30 分钟兜底定时器。
- 执行端接口 `SrsGen4MigrationBackend` / `SrsNativeGen4MigrationBackend` 下沉到 `packages/fushi_srs`
  （`srs_gen4_migration.dart`），app 迁移控制器与服务端共用。
- WebUI 复习页：新增「复习库换代」块（各状态文案、步骤进度、原因、报告路径、处置说明），「开始升级」/「叫停升级」按钮经确认
  对话框才发，叫停只在 `cancellable` 时出现。
- 端到端测试补核：迁移后主 profile 的两条复习日志（本机一条 + 协议 1 时代一条）都在；孤儿 profile（只在投影表里）的牌组与
  它那条旧日志也迁过来、可读（这一条是纯测试补强，数据保全在 Rust 迁移里，不另做变异）。
- 变异实测（`server_srs_migration_test.dart`，每条打变异后定向跑、红后还原）：`_upgradeRefusalFor` 恒 null → 制卡用例红；
  去掉 `precondition` 分支 → 处置说明用例红；叫停不用现取进度 → 叫停用例红；`_armMigrationRetry` 直接返回 → busy 与别的
  进程两条红；WebUI「开始升级」去掉确认 → WebUI 用例红。

## 25. G11-4 备份 / 还原、主库 schema 升档、服务端备份 v2（2026-11-17，分支 `pr/srs-gen4-g11-4-backup-restore`，基于 `pr/srs-gen4-switch`）

规划 §1.9、§6、D33 / D34；本节「§9.5 第 6 条」「§13」「§15 定案 5」「§16 旧事件备份进合并条件」点名 G11-4 的全部在这里收口。
Rust `SCHEMA` 没升（没加表 / 索引，分到的 40024 没用）；ABI 不变（`ffsrs_store_snapshot` 是既有入口）。

### 定案（所有者授权自定）

1. **整包备份的复习部分 = 按集合的 `FSRS4EXP` 流**（不是快照）：zip 里 `srs/manifest.json` + 每个集合一条 `srs/<n>.bin`
   （内核 `export`，与 `.fushisrs` 第 2 版的 `ops.bin` 同一种）。清单 `{v: 2, gen: 4, exportedAt, collections: [{n, profiles:
   [{uid, name}], collection, dir, salts, peers, counts}]}`，**不带 `magic`**、不带签名私钥（快照带私钥，还原到另一台设备 = 两台
   设备共用一个身份）。不再写 `srs.db` 条目。实现 `packages/fushi_engine/lib/srs/srs_backup_bundle.dart`。
2. **`ffsrs_store_snapshot` 接新代**（`G4Core::snapshot_into`，`kernel.rs`）：`VACUUM INTO` 一个读事务里的一致快照（读不挡写）；
   Secondary 报只读；`stripDeviceLocal = true` 报错（新代不给半定义的剥表模式）；先查空闲空间、写完核对是建好的新代库、
   中途失败删掉半截目标。只给服务端备份用。
3. **服务端备份第 2 版**（`kServerBackupFormatVersion = 2`）：`data/support/srs4.db` = 上面的快照（同一台设备原样回来，身份
   与同步进度都要在）；封存的 `srs.db`（有才带）原样拷。旧二进制（只认 v1）在动任何东西之前拒绝、提示升级；这一版照样还原
   v1（只有协议 3 `srs.db`，下次启动按迁移处理）。还原把现有数据目录整体挪到 `<data_dir>.pre-restore-<时间>/`，不删。
4. **覆盖还原 = 空库 + 并入（D34）**：在 `<库目录>/srs-restore-staged/` 新建空的新代库，把备份的复习数据全部落进去（任何一步
   失败删掉暂存目录、原样抛错，本机没动）；主库换好之后换库：本机 `srs4.db`（连同 -wal / -shm）改名成
   `srs4.db.pre-restore-<UTC 时间>`（回退副本，**不删**；同名已在就加序号），暂存库改名到位。封存的协议 3 `srs.db` 一概不碰。
   sidecar 的 `srs` 键记新代计划 `{gen4, rollback, profiles}`，崩溃后 `recoverPendingRestore` 幂等重放。**旧版本留下的协议 3
   计划（字符串）不再删 / 换 `srs.db`**，只把没换进去的暂存文件改名成 `-unapplied` 留存、记日志（§9.5 第 6 条）。
5. **合并还原**经内核落库（新形态 `import`、旧形态 `legacy_backup_import`，先 G9-4 `collection_adopt` 认领）。并入另一个
   复习库、记下新的旧 profile 标识（盐）/ 设备公钥要用户确认：导入流程里加一个确认框（`backup_srs_merge_confirm*`），答否 =
   只合并其余内容、那份复习数据不落（回报 `declined`）；控制通道的预设不替用户确认。`srs_backup_merge.dart` 的 `adoptedUid`
   改成 `collection_adopt`（profile 的 uid 不变，以前是改 uid）。
6. **本机复习库状态不对时整次拒绝**（`SrsRestoreBlockedException`，`backup_srs_restore_blocked`）：只看代际状态
   （`SrsGen4Migration.status`，**不开库**——开库会写文件头，失败时本机就不再逐字节原样）；没迁移 / 迁移中 / 只剩封存旧库 /
   上次迁移失败都拒，提示先完成升级或取消勾选「复习」。G7-5 的 `SrsRestoreUnavailableException` 整次拒绝删掉。
   只在备份里**真有**复习数据（解出的待落库单元非空）时才判，覆盖 / 合并同一口径（复核修复 3）。
7. **旧形态全部能进（D34）**，经新命令 `legacy_backup_import`（`cmd/backup.rs`）：
   - 协议 3 整包备份的 `srs.db` 条目：`source: "db"`；
   - 2026-10-23 之前 SRS 表在主库条目里的整包备份、v2 同步之前的 `.fushisrs` 事件备份（魔数 `fushi-srs-backup`）：Dart 写成
     「外来、已盖戳」的 JSONL，`source: "events"`。
   命令先在新代库写锁之外用冻结的协议 3 代码备一份临时副本（schema 阶梯 → `cache_config_set` → `migrate` → 分批 `apply` →
   `dedup` → `replay_pending`，副本里记 `gen4_backup_prepared`，预检之后的真导入不重备），再一个写事务里认领 + G11-2
   `import_backup` + 本机状态行。确认口径与 `.fushisrs` 第 2 版相同。坏文件 / 备不好的副本整笔回滚。
8. **`.fushisrs` 旧事件备份不再拒收**（推翻 §15 定案 5）：`srs_fushisrs.dart` 校验 `minReaderVersion`、事件摘要与条数，写
   JSONL（带 `server_times.json` 的逐事件服务器时间）交给 `SrsDbStore.sync2LegacyEventsImport`；只认本 profile 的（另一个
   profile 的拒收，同协议 3 时代与 D34）；媒体取内嵌 `media/<sha256>`、再到旧备份根共享池找，按 SHA-256 校验。
   `SrsFushiSrsLegacyFormat` 与 i18n 键 `srs_timeline_import_legacy_format` 删掉。
9. **旧事件的日志笔记**：v1 事件的复习日志多数不带笔记 ID（`.fushisrs` 事件备份没有卡片缓存）。副本分两遍读：先落身份 /
   修改记录、`replay_pending` 派生出卡片，再按副本 `srs_cards_cache`（`LOG_NOTE_SQL`，走索引）给没带笔记的日志补上，与协议 3
   `applyRemote` 落库前按卡片行查笔记同口径。
10. **旧输入读入幂等**：副本把旧事件包成操作，成为副本身份名下的承袭日志。副本身份每次随机的话，再导一次同一份旧输入会以
    另一个合成设备再落一遍（实测 `inserted 26` / 换了时钟后 `replaced 10, forks 16`）。现在：副本里没有这个 profile 的身份时
    先写一个**可重现**的（`seed_scratch_identity`：BLAKE3 派生自目标集合的本机签名钥匙种子 + 备份 profile + 输入摘要 + 来源
    种类，设备 ID 是 UUIDv8）；事件来源的副本时钟取输入里最晚的时刻（`input_time`，上限压到请求的 `now`，输入不可信）。同一台
    设备、同一个集合再导一次全是已有的槽（`unchanged`）。钥匙必须混本机秘密：合成设备的公钥进 `peers`，只凭备份内容就能推出
    私钥的话，拿到备份文件的人能冒充它往位置上写协议 3 段。
11. **主库 Drift schemaVersion 155 → 156（D33）**，空迁移：旧版本见到更新的主库在动任何文件之前拒绝整份备份（导入流程既有
    的 `backup_schema_newer`）。这是旧二进制拒收新整包备份的唯一闸门（旧二进制只找 `srs.db` 条目，会把 `srs/` 当未知条目
    跳过），所以与断代同一次推送。

### 守卫 / 测试

- `fushi/test/build/backup_srs_gen4_guard_test.dart`：备份路径（`backup_service.dart`、`restore.part.dart`、`srs_restore.part.dart`、
  `backup_merge_engine.dart`、`server_backup.dart`、`srs_backup_bundle.dart`、`srs_backup_merge.dart`）里没有 `SrsStorage.open`、
  没有 `stripDeviceLocal: true`、清单不写 `magic`、封存的 `srs.db` 只在协议 3 暂存文件路径上出现。
- Rust `cmd/backup_tests.rs`（7 条，经 C ABI）：别的线程一直在写时拍的快照能当新代库打开、派生层与整层重建逐行相同；
  快照拒绝路径不留文件；协议 3 `srs.db` 读入与直接迁移逐行相同、再读不改；另一个集合要确认、坏文件库一字不变；v1 事件与
  直接迁移条数相同、坏行报行号；日志不带笔记时从派生卡片补齐（EXPLAIN 测执行的同一份 `LOG_NOTE_SQL`）；换副本目录隔天再导
  同一份全是已有的槽、派生层与导出流不变，另一个库得到另一个合成设备。变异实测：去掉可重现身份 → `inserted 26` 红；副本时钟
  回到请求 `now` → `replaced 10` 红。
- Dart：`backup_srs_category_test.dart`（覆盖还原逐表与源一致且本机旧 `srs4.db` 改名留存逐字节原样、合并没确认不落 / 确认后落
  且再合并不变、坏操作流与更新版本清单什么都不换、没迁移时拒绝且 `srs.db` 逐字节原样、主库表形态 v1 事件覆盖还原、协议 3
  `srs.db` 条目合并两次不重复）、
  `srs_backup_merge_test.dart`、`server_backup_srs_test.dart`（serve 在跑 / 离线两种快照、没开过复习库不带、v2 往返后新代库照常
  打开且封存旧库逐字节回来；旧二进制拒 v2 靠的是既有的 `formatVersion > kServerBackupFormatVersion` 判断）、`srs_fushisrs_test.dart`
  （旧事件备份读入对拍 + 再导不重复；另一个 profile / 摘要不符拒收、不打还原点）、`backup_device_local_leak_guard_test.dart`
  （整包备份不再带整库快照）。

### 没做 / 交给谁

- 覆盖还原后的**第一次**合并同一份旧输入仍会多落一份：暂存库里 profile 还没有本机身份（绑定在落库事务里才建），副本身份只能
  随机；之后的再导入才可重现。要根治得让落库前先建身份（改 `collection_adopt` 的时序，归 G9 身份模块评估）。新形态（`FSRS4EXP`）
  备份不受影响。
- 协议 3 `srs.db` 来源（`source: "db"`）里没包过的 v1 旧行由副本 `migrate` 按请求的 `now` 包，同一份隔天再导会是「替换」：
  只影响 v2 同步之前从没迁移过的库的整包备份（很少见），没做输入时刻推断。
- 旧二进制（已发布版本）真机互拒实测归 R0 / G11-5（本分支只有源码层与单测层证据）。
- 已知基线红（不归本模块，原样记下）：`srs_fushisrs_test.dart` 的 3 条 ID 口径族（§18「没做」）；`fushi_engine` 的
  `srs_profile_link_sync_test` / `srs_profile_purge_single_test` / `srs_profile_adopt_user_data_test`（断言协议 3 表 `sync2_ops`，
  归 T1 / G9-5）；`fushi/test/srs/srs_profile_cleanup_test.dart`（`profile_purge` 未接线，G9-5）；
  `srs_store_ownership_guard_test.dart`（`srs_storage.dart:112` 的表名，本分支没碰该文件）。

### 复核修复（2026-11-17，同一分支）

1. **身份确认闸门补测试**：`a_legacy_backup_bringing_a_new_identity_needs_confirmation`（经 C ABI）——本机 profile 已绑在
   `collection_of(uid)` 上，旧 `srs.db` 多一个退役 uid（新盐）或多一台本机没记过公钥的设备：预检与真导入不确认都回
   `needsConfirm` / `identity`，`newSalts` / `newPeers` 就是它，导出流与 `peers` 逐字节不变；确认后盐进绑定、设备进 `peers`。
   变异实测：`if identity.is_some()` 改成 `if false && …` → 该条红。
2. **预检「副本没备好」补测试**：`preflight_reports_a_backup_library_that_is_not_ready`——副本按这份输入备好（标记有效）之后
   又被改得不满足前提（开一条新设备收段通道）：预检报 `not ready`，不先答 `ready`。变异实测：去掉 `if !blockers.is_empty()`
   → 红。备副本本身不会留下这种状态（冻结代码的 `migrate` / `dedup` / `replay_pending` 收干净），所以只能从「备好之后被改」进。
3. **合并还原只在备份真有复习数据时检查本机复习库**（`restore.part.dart` 第 2b 步）：先解出复习单元（新形态清单 / 协议 3
   `srs.db` / 主库老表里有数据的 profile），非空才 `_checkSrsLibraryRestorable`，与覆盖还原（`srsUnits != null`）同一口径；
   都在快照 / 改主库之前，失败删掉刚解出的临时备份主库。顺带：坏的操作流条目现在在改主库之前就拒，不再是主库合并提交之后才报。
4. **declined 不再静默丢**：`migration_import_page.dart`（同机换包名）传 `srsConfirmed: true`；`backup.part.dart` 合并后数
   `declined`，有就记错误日志、完成提示换成 `backup_import_success_srs_declined`（几份没并入、再导一次并确认），不报全部成功。
5. **不可信输入加固**（`cmd/backup.rs`）：
   - 两种来源都要 `scratch`；`db` 来源**只读不改输入**，拷进 `scratch` 再备。`scratch` 里只能有本命令备的 `srs.db*`（别的文件
     拒绝、不删），不得与已打开的新代库目录相交（命令会删 / 重建 `<scratch>/srs.db*`，库目录里可能是封存的协议 3 库）。
   - 「已备好」标记的值 = `profile:来源:输入文件 BLAKE3`：备份文件自带的标记要等于它自身的摘要，做不到，跳不过备副本；
     换了输入的旧副本也不会被误认（以前只记 profile 名）。
   - 同一份协议 3 `srs.db` 里的多个 profile：Dart 给每个 profile 一个 `scratch`，输入始终原样，每个 profile 的输入摘要都相同
     （以前 `prepare(A)` 原地改文件，B 的摘要随 A 的准备结果变）。
   测试 `the_input_file_is_read_only_and_its_own_prepared_marker_is_ignored`、`a_scratch_that_is_not_ours_is_refused`；变异实测：
   标记退回只记 profile → 前者红；去掉相交核对 → 后者红；退回原地备 → 前者红。
6. **「同名、本机没数据但发布过批次 → 新建（备份）」场景迁回**：`srs_backup_merge_test.dart` 补一条（经文件夹位置真跑一轮
   同步让 `status.locations[].uploaded > 0`），断言不认领、建「（备份）」、本机 profile 的集合不动。
7. **旧 `.fushisrs` 事件备份流式读**：`events.jsonl` 按 64 KiB 块读压缩正文 → `ZLibDecoder(raw)` → 同时喂 SHA-256 与
   UTF-8 按行解码，峰值内存与正文大小无关；声明 / 实际解压大小都卡 1 GiB；加密条目拒收；摘要或条数不符删掉写了一半的 JSONL。

### 复核修复后仍没做 / 交给谁

- **G9-5 关联到同一集合的多个 profile，覆盖还原后只有第一个重新绑定**：备份按集合去重，`unit.profiles` 可能是 [A, B]；
  `mergeSrsFromBackup` 只给匹配上的第一个认领集合。B 在暂存的空库里没有绑定，还原后 B 的复习页是空的（数据还在，经 A 看得到）。
  `collection_adopt` 不能把第二个 profile 绑到已被绑定的集合（`already bound to profile`），要用 G9-5 的关联命令（本分支里
  `profile_uids` 等仍是 `Unwired("G9-5")`）。归 G9-5：接线后在落库之后对 `unit.profiles` 其余已在本机的 profile 调关联命令。
- 上一节「没做」前三条不变（覆盖还原后第一次合并同一份旧事件输入多落一份归 G9；`source: "db"` 的 v1 旧行按请求 `now` 包；
  旧二进制真机互拒归 R0 / G11-5）。

## 26. T1 旧测试按新代重写（2026-11-17，分支 `pr/srs-gen4-t1-tests-to-gen4`，基于 `pr/srs-gen4-switch`）

只改测试与测试辅助，不改 Rust、不改别的模块的生产代码。四处 SRS 测试在真内核上跑（`FUSHI_FSRS_LIB` 指向
`pr/srs-gen4-switch` + G9-7 `8cf0aaea77` 合起来编的 `fushi_fsrs.dll`：不带 G9-7 时引擎侧约 100 条先崩在 ID 口径的
`Null check`，看不到后面的问题），每条红逐条分成 A（测试为协议 3 写的，本模块改写 / 删除）、B（本波别的模块在修，
只记归属）、C（没人认领的新代缺陷）。

### 开库辅助（`packages/fushi_engine/test/srs/support/srs_test_storage.dart`）

- `newTestSrsDir` 建临时库目录（新代 `SrsCore.open` 收目录）；`openTestSrsIn(dir, mode:)` 开库；`bindTestProfile`
  给只用 `SrsCore` 的测试补 `identity` + `cache_config_set`（与 `SrsDbStore.open` 同序）；`openMigratedTestSrs`
  把协议 3 冻结夹具放成封存旧库 `srs.db`、跑一次换代迁移、断言提交再开新代库（用户升级走的同一条路）。
- `support/srs_bulk_fixture.dart` 的 `dumpSrsState` 改成只经公开读命令：导出的身份记录 / 修改记录 / 日志 / 不认识的
  事件（设备 ID 与本机日志 ID 归一）、`status` 的 `ops|nextSeq`、`listNotes` / `allCardRows` 两层派生行。
- 落库形态只有表里看得到、没有公开读命令的（彻底清除抹掉操作体里的内容、样式去重后的字节数、每台设备 seq 连续、
  派生行没被重算的记号、某 profile 名下的原始操作），改走测试专用原始通道查**新代**的表（`ops` 主键
  `k = 设备下标 << 40 | seq`、派生表 `notes`，ID 列按 `lower(hex(id))` 比），注释写明为什么没有公开读命令可用。

### 分类结果（真内核）

| 范围 | 跑的 | 绿 | 红 | 跳过 |
| --- | --- | --- | --- | --- |
| `packages/fushi_engine/test/srs`（`-j 4` 整跑；之后又改 2 个文件，见下） | 976 | 761 | 191 | 24 |
| `fushi/test/srs`（`flutter test test/srs`；之后改的 2 个文件另跑转绿 3 条，见下） | 1273 | 1223 | 37 | 13 |
| `packages/fushi_srs/test` | 226 | 226 | 0 | 0 |
| `packages/fushi_server/test` 的 8 个 SRS 文件 | 43 | 17 | 26 | 0 |

整跑之后又改的：引擎 `srs_write_preread_cost` / `srs_bulk_ops_roundtrips` 与 `srs_bulk_ops_equivalence` 串行重跑
17 绿 4 红（清除计数、后继卡两条由红转绿；剩下 4 条见 B）；app `srs_content_memo_providers` /
`srs_extension_profile_mining` / `srs_review_inline_edit` / `srs_import_entry` 重跑 14 绿 1 红。整跑里的 7 条 30 s 超时
（`srs_bulk_ops_equivalence` 3、`srs_bulk_ops_roundtrips` 1、`srs_optimizer` 1、`srs_ankiconnect_resident`「大库」、
`srs_rwkv_service_close_download`）是 `-j 4` 下本机满载，前两个文件串行重跑不超时。

跳过的只剩环境门控的基准 / 浏览器 / node 用例与 G9-5 要整份删的 `srs_pull_before_migrate_test`（8 条），
本模块没有新增也没有留下按波次挂名的 skip（原来那批 `G7-5: protocol 3 cache revision ...` 的 skip 全部改写或删除）。

**A（本模块改写 / 删除，改后在真内核上全绿，除表里注明归 B / C 的那几条）**

| 文件 | 改法 | 改后 |
| --- | --- | --- |
| `srs_raw_sql_canary` / `srs_fingerprint_instance` | 开库目录 | 全绿 |
| `srs_stats_test` | 统计投影走 `statProjection`；日志用 Anki 来源（本机来源的会被内核重排程） | 全绿 |
| `srs_profile_ownership_test` | 别的 profile 的 ID 在新代里等于不存在的 ID：比 B 的导出与视图不变、A 的 `ops` 增量与「不存在的 ID」相同 | 78/78 |
| `srs_bulk_ops_equivalence_test` | `dumpSrsState` 走公开读；删牌组按规范 ID 序 | 9/10（1 条 B G9-5） |
| `apkg/srs_apkg_stream_roundtrip_test` | 同上；HLC 不比；重导不改修改记录 | 5/5 |
| `srs_stat_projection_test` | 投影经统计读取看；参考实现取导出日志 + `server_times`；删 2 条 cacheRev 升级 | 全绿 |
| `srs_local_state_kernel_test` | 经另开副本的修订号 / 指纹 / 校时看；回包键改 `changed`/`replayed`；删 4 条协议 3 行级用例 | 4/4 |
| `srs_stats_columns` / `srs_media_refs` / `srs_pending_decision` / `srs_new_card_frequency_order` / `srs_new_card_position` | 「老库 cacheRev N 开库补齐」改成「派生列经原始通道改坏后整层重建复原」（`expectRebuildRestores`，复核修复见下） | 全绿 |
| `srs_intent_commands` / `srs_ctl_routes` | 操作条数改 `status.ops` | 全绿 |
| `srs_db_store_test` | 并发正文记录改数导出的修改记录 | 14/16（1 C、1 B G11-4） |
| `srs_write_lock_order` / `srs_style_dedup` / `srs_write_path_read_amplification` | 查新代 `ops` / `notes`；`noteIdsOfType` 按规范 ID 序（派生表无 rowid） | 2/2；4/5（1 B G8-7b）；7/8（1 C） |
| `srs_write_statement_cost_test` | 删 cacheRev 那一项；开库命令 3 → 4（多一条 `collection_info`） | 3/4（1 B G9-5） |
| `srs_write_preread_cost_test` | 操作 / 修改记录条数、被清除实体数改查新代 `ops` / `purge_ix` | 1/3（2 B G9-7） |
| `srs_bulk_ops_roundtrips_test` | 「找后继卡」删协议 3 的 EXPLAIN 计划断言（新代没有 `srs_field_edits`），语句数常数照钉 | 7/8（1 B G9-5） |
| `sync2/srs_sync2_command_lock_test` | 派生表触发器挂 `notes`；发件箱检查改 `status.ops` | 1/1 |
| `srs_purge_test` | 修改记录键改走导出；操作体查新代 `ops` | 4/6（2 C） |
| `apkg/srs_apkg_import_vectors_test` | 日志 HLC 去掉写入者段（两个库的设备 ID 不同） | 全绿 |
| `apkg/srs_apkg_import_test` | 取词按笔记类型第一个字段（新代字段表按 ID 出） | 53/54（1 C） |
| `srs_stats_vectors` / `srs_stats_report_parity` / `ankiconnect/srs_ankiconnect_vectors` | 冻结协议 3 夹具改走 `openMigratedTestSrs`；统计夹具的 schema 标记 13 → 9（开发版缺 `sync2_replay_pending` 等表） | 红（C1） |
| `fushi/test/srs/srs_content_memo_providers` / `srs_extension_profile_mining` | 查新代 `notes` / `ops` | 1/1；5/5 |
| 删：`srs_legacy_clock_conformance_test.dart` + `fixtures/legacy_clock_store_vectors.json` | 协议 3 旧写入者时钟状态，新代不迁（设计 §2.4） | — |
| 删：`srs_cache_vectors_test.dart` | 协议 3 四张原始表灌库 → 三张缓存表逐行比；新代没有这些表。派生层与协议 3 缓存的对拍在 Rust：换代迁移的 parity（`store::gen4::migrate::tests::a_ready_library_is_migrated_sealed_and_opens` 断言 `parity == []`）；Dart 侧「重建真按真相重算」由 `expectRebuildRestores` 那 7 个文件锁住（复核修复）。**更正**：上一版写「由各『增量 = 重建』用例覆盖」不成立——那些用例重建前后比同一份值，重建是空操作也绿（复核 M3）。夹具与生成脚本留着（Rust `card_cache.rs` / `caches.rs` 注释引用） | — |

`srs_write_path_roundtrips`「批量落库与逐条落库同结果」「新建牌组语句数不随笔记数增长」：在 switch 上先崩在 ID 口径
（`Null check`），带 G9-7 全绿——归 **B G9-7**，测试不用改。300 条导入 30 s 超时：**上一版定成「并发满载」是错的**，复核时量到是导入随库大小超线性变慢（C8，
见下）；本模块其余超时（`srs_ankiconnect_resident`「大库」、`srs_rwkv_service_close_download`、
`fushi/test/srs/srs_import_entry`）单跑都过或属同一负载现象，`srs_rwkv_service_test` 的 42 条是 `fushi_rwkv` 库没装上
（本 worktree 的 setup 停在 IdAudit 失败，ENV）。

**B（本波别的模块在修，只记归属）**

- **G9-5**（并入 / 带戳事件 / collection join）：`srs_backup_merge`、`srs_bulk_ops_equivalence`（同步那条）、
  `srs_bulk_ops_roundtrips`、`srs_profile_merge`、`srs_write_statement_cost`（第 1 条）——`apply: stamped items carry a
  foreign identity`；`srs_collection_binding`、`srs_profile_adopt_user_data`、`srs_profile_link_sync`、
  `srs_profile_purge_single`——`meta_set_edit` / `profile_merge_mark` / `profile_purge` 没接；`fushi/test/srs` 的
  `srs_profile_cleanup`（8）、`srs_join_first`（2）、`srs_pull_before_migrate`（6 红 + 8 跳过，G9-5 分支整份删）。
- **G8-7b**（同步）：`media_hash` 没接 / `missing location` / `location root refused`——`srs_media_presence`、
  `srs_media_sync`、`srs_style_dedup`（同步那条）、`sync2/srs_folder_location`、`sync2/srs_format_break`、
  `sync2/srs_location_crypto*`；`sync2/srs_sync2_bootstrap_channel_entry`（协议 3 收段通道表）、`srs_sync2_head_gap`、
  `srs_sync2_ingest_batching`、`srs_sync2_relay`、`sync2/srs_duplicate_notes`；`fushi/test/srs/srs_sync_scheduler`（9）。
- **G9-7**（ID 口径）：`srs_browse_vectors`（夹具里的卡 ID 是旧口径，要在 G9-7 上重新生成）、`srs_write_path_roundtrips`；
  `srs_write_preread_cost` 2 条——带 G9-7 的 Dart 后 `editFields` / `editFieldsBatch` / `writeEdits` 发命令前各多一条读
  （守卫的就是「发命令前不读现值」），`applyLapisBackfill` 读命令 8 → 9（`entities` 4 + `edits` 4 + `lapis_backfill` 1）；
  switch 上这两条先崩在 ID 口径、量不到，只能在 G9-7 上判是有意改了口径（改期望）还是回归（疑为「改前值按规范键取」
  多出来的预读）。
- **G10-2**（远程）：`fushi/test/srs/srs_remote_store_parity_guard` 第 1 条（G9-7 交接已记）。
- **G10-3**（服务端）：`packages/fushi_server/test` 的 SRS 红全部（26 条：服务端拿不到所服务 profile 的新代库，
  `Null check` / `notConfigured` / 读不到笔记；远程复习那几条同时涉及 G10-2）。
- **G11-4**（备份）：`srs_db_store_test`「覆盖恢复备份后：换新化身」（协议 3 删表模拟恢复，新代的恢复路径归 G11-4）。
- ~~下一波：`srs_legacy_store_migration_test`~~ → 复核时改写（A），见下「复核修复」。

**C（没人认领的新代缺陷，见 upstream_bugs）**

1. **未定因，疑为夹具问题（复核更正：不要当成 G7-2 已证实的缺陷）**。冻结协议 3 夹具（`srs_stats_vectors.db.gz` / `srs_ankiconnect_vectors.db.gz`）换代迁移判 aborted：报告
   `profileVerdict = fail`，parity 的 notes / cards / stats 有 onlyNew / onlyOld，`existingCachesVsRebuilt` 20 条笔记
   不同；switch 与 G9-7 的 DLL 一样。根因没在本模块定位到（`native/fushi_fsrs/src/store/gen4/migrate.rs` / `parity.rs`）。
   复核补证：同一个头上 Rust 的 `store::gen4::migrate::tests`（17 条，含 `a_ready_library_is_migrated_sealed_and_opens`：
   用当前协议 3 代码造的库迁移后 `parity == []`）全过；而统计夹具出自「V12 的表并进来之前的开发版本」（协议 3
   `schema.rs` V14 注释），`existingCachesVsRebuilt` 里旧缓存与协议 3 现行代码重算的卡 ID 整批不同（`09cef016…` 对
   `0338b9d8…`），说明夹具里的数据 / 缓存是旧开发代码按另一套派生规则写的；ankiconnect 夹具没改标记同样 aborted，来源没核。
   所以先当夹具问题：要么用真实协议 3 发布版造的库跑一次同样的迁移（过了就按那份重生成两份冻结夹具，不再手改 schema 标记），
   要么由内核 owner 判 parity 对这类开发版数据该给什么结论。重生成要一个能写协议 3 库的生成器（Dart 侧已没有协议 3 开库入口，
   只能在 Rust 侧做），本模块没做。3 个文件的向量用例因此仍红（已知红，归属：换代迁移 owner 定因后决定重生成或改判）。
2. 新设备首次出现不判「待确认」（BUG-4306 回归；原写的 BUG-4276 号有误，那个号是互联局域网设备列表）：协议 3 在 `store/sync2/trust.rs:70 note_new_device` 判库非空时首见的
   设备为 pending、它的删除 / 清除扣住；新代生产代码里没有任何地方写 `TRUST_PENDING`（只有 `cmd/writes_local.rs:136`
   用户手动改信任与测试），`receive.rs:592`（承袭段上传者核对）只读 `trust_of`。别的设备的删除直接生效。红：引擎 `srs_devices_test`（4）、
   `srs_db_store_test`「删除与对端并发修改」，app `srs_device_trust_test`（4）、`srs_conflicts_held_delete_test`（2）。
3. 彻底清除不抹本机操作日志里的内容：`Truth::advance_purge`（`store/gen4/truth.rs:2881`，完整内容 → 空洞）在生产代码里
   没有调用方，`cmd/writes.rs:989 purge` 只追加 删除 + Purge 两条操作。清除后 `ops` 里带原文的修改记录原样留着（实测
   seq 6、7 两条仍含 `secret-snow`，`op_voids` / `op_alias` 都是 0 行）。红：`srs_purge_test` 2 条。
4. Anki 导入日志的 HLC 被内核重打，同一条 revlog 的副本不再归成一个事件：选取的事件身份（`history.rs:118-139`
   `EventKey`）对 Anki 来源只靠「由 revlog id 派生的 HLC」把换卡导入的副本归一（文件头 :19、:154），新代落库丢掉日志
   自带的 HLC、改用操作自己的（`cmd/writes.rs:23` / `:643`）。同一条 revlog 落到血统里两张卡（Lapis → Fushi 卡片后再
   导入、旧版写出的副本）就被算两次（统计 / 排程）。红：`srs_apkg_anki_revlog_dedupe_test` 2 条、`srs_apkg_import_test`
   「① 导入 …」（锚点 HLC 不再是 `srsImportAnchorHlc`）。
5. 笔记类型改名 / 改 CSS / 改字段说明也把这一类的笔记整类重算（H5 读放大回归）：`store/gen4/cache.rs:495-510`
   `refresh_caches` 只按实体收脏，不看改的是哪个键。红：`srs_write_path_read_amplification_test`「名字 / CSS / 字段说明
   不重算 …」。只是多算，不出错结果。
6. 连续两步倒序撤销，第二步被拒：先撤 two（写回 1），再撤 one 时 `undo_check` 判不能撤。协议 3 允许「现值是它写下的
   值、且现值记录的因果覆盖它」（`registers.rs:1344`）；疑为新代 `cmd/center.rs:207 edit_rows` 给出的记录 ctx 只含直接
   支配的 dot、不含传递的，`x.ctx.contains(one)` 不成立——未逐行证实。switch 上同样红（G9-7 交接已记）。红：
   `srs_edit_undo_test`「连续两步倒序撤」；app `srs_review_inline_edit_test` 最后一步（复核时定位：前面那段是测试时序问题，
   已修；剩下的就是第二次倒序撤销不落库）。
7. 标签只改不动字段时 `updated_at` 不前移：浏览 `edited:1` 漏掉只改了标签的笔记、按修改时间排序错位。新代
   `updated_at` = 活着写入的最大 HLC 物理时刻（`cache.rs:1401`，标签取 `tag_time` `:726`），疑为改标签那条操作没进
   `tag_ix` 的 `state >= 0` 或没收脏——未逐行证实。红：`srs_browse_test` 2 条。

另记两处观察（不单列缺陷）：夹具 schema 标记与表不符时（开发版库），换代迁移的 prepare 在协议 3 命令失败时整个返回
错误而不是判 blocked（`store/gen4/prepare.rs` `finish_profiles`）；`apply` 收到已在库里的日志 ID 会再追加一条操作
（`cmd/writes.rs` `apply_in`），协议 3 同样如此，不是回归。

### 没做 / 交给谁

- 上面 C1～C7 交内核 owner；C2、C3 涉及安全 / 隐私语义（别的设备的删除直接生效、清除后原文还在本机），建议排在前面。
- B 类测试等对应模块合进 switch 后在 integration 上整批复跑；本模块没碰它们（`srs_profile_ownership_test` 避开了 G10-2
  改的那几处）。
- `srs_p6_vectors_test`（A，没改）：1200 份历史连同服务器时刻直接灌协议 3 的 `srs_review_logs` / `srs_event_local`。
  新代只有承袭来的服务器时刻，能保住这组向量的路只有「建协议 3 旧库 → 换代迁移 → 新代读命令」，而 C1 下冻结的协议 3
  数据迁移判 aborted，Dart 侧也已没有建协议 3 库的入口；C1 修好后按 `openMigratedTestSrs` 改写（要一个能生成协议 3
  库的 Rust 夹具生成器）。现在红在 setUpAll（2 条）。
- `srs_note_type_store.dart:135` `noteIdsOfType` 的注释还写「按落库顺序」，新代是规范 ID 序；不是本模块的生产代码，没改。

### T1 复核修复（2026-11-17，同分支）

验证环境：`pr/srs-gen4-t1-tests-to-gen4` 合 G9-7 `8cf0aaea77` 的本地验证分支（不推送），`--profile quick --features raw_sql`
编的 `fushi_fsrs.dll`。

- **整层重建用例测不出重建坏掉（复核 major）**：新增 `support/srs_test_storage.dart` 的 `expectRebuildRestores(store, table, damage)`
  ——先记下派生表（`notes` / `cards` / `stats`）全部行，经测试原始通道执行一条改坏语句（确认表已变），再 `rebuildCaches`，
  断言逐行复原。7 个文件改用它：`srs_media_refs`（`media_refs`）、`srs_pending_decision`（`pending_decision` 错标 1）、
  `srs_stats_columns`（`source_kind` / `source_title`）、`srs_new_card_frequency_order`（`freq_rank`）、`srs_new_card_position`
  （`new_position`）、`srs_db_store`「缓存可由事件完整重建」（卡行打回新卡）、`srs_stat_projection` 5 处（删光 `stats`），
  另 `apkg/srs_apkg_anki_revlog_dedupe` 2 处（C4 红在重建之前，不影响判定）。变异实测 M3（`rebuildCaches` 里的
  `_sync2({'op': 'rebuild_caches'})` 换成空操作）：这几个文件新红 10 条（`srs_db_store` 另 2 条是改前就红的 C2 / G11-4），
  还原后全绿。上一版「由『增量 = 重建』覆盖」那句已更正（见 A 表 `srs_cache_vectors_test` 行）。
- **`openTestSrsAt` 桩删掉（复核 minor）**：22 个调用方改按库目录开库（`openTestSrsIn(tmp.path)`；同一临时目录要几个库的用
  `testSrsSubdir`）。真实数据基准（`srs_review_open_real_data_bench`、`srs_concurrent_reads_bench`、
  `srs_deck_settings_open_bench`、`srs_browse_bench`、`ankiconnect/srs_ankiconnect_real_db_bench`、`srs_stats_load_bench`）
  改走 `openRealDataTestSrs`：一律在副本上跑，源是新代库目录就拷文件，是协议 3 的 `srs.db` 就经换代迁移（与用户升级同一条路）；
  `srs_answer_study_roundtrips` 的基准缓存改成库目录。这些基准环境门控、默认跳过，本轮只编译过、没带真库跑。
- **`dumpSrsState` 加 `serverTimes`（复核 minor）**：`server_times` 读命令，日志 ID 按同一套序号归一后排序比。用到它的
  「应用一批对端事件 = 逐条应用」目前红在 G9-5（`apply: stamped items carry a foreign identity`），这一维的变异实测要等 G9-5
  合进来后补。
- **BUG-4626 判据在新代放宽（复核 minor，待 G9-5 确认）**：协议 3 在追加前拒绝写别人 profile 的 ID（`ownership.rs` foreign，
  A 一条操作都不多）；新代按「别人的 ID = 不存在的 ID」，允许 A 的集合里留下指向 B 的实体 ID 的悬空操作。同库两集合互不
  影响时没有后果；但设计稿 2026-11-11 §2（ID 去掉 uid 盐、并入 = 操作并集）下，A 并入 B 之后这些悬空操作可能对 B 的同一
  实体生效——推测，未实测（并入命令 `profile_merge_mark` 等还没接线）。G9-5 接线后要补「A 写 B 的 ID → 并入 → B 不被改」
  的用例；不成立就要在写入口或并入时丢掉悬空操作。`srs_profile_ownership_test` 文件头已写明。
- **后继卡查询的计划测试（复核 nit）**：新代缓存刷新找后继 / 前身在 `gen4/cache.rs` `load_links`（`reg_ix` 按
  `(col, ekind, key)` / `(col, ekind, ent)`），由 Rust `store::gen4::schema::tests::lookups_with_a_key_never_walk_the_whole_collection`
  逐条 EXPLAIN cache.rs 的语句常量钉住；`srs_bulk_ops_roundtrips_test` 注释已指过去。
- **`srs_legacy_store_migration_test` 不再无主（复核 nit）**：协议 3 的搬迁命令（`srsMigrateLegacyStore` /
  `legacyImported`）在新代没有生产调用方（G7-5 起 `SrsStorage.open(legacy:)` 只做守卫）。测试改成锁住这条守卫：主库还有
  协议 1 的表、库目录空 → 抛 `SrsLegacyMainDatabasePending`、不建 `srs4.db`、旧表一行不动；没有旧表 → 照常开；目录里已有
  `srs.db` / `srs4.db` → 不拦。列序对拍那条留着。删掉的三条（逐字节搬迁 / 失败回滚 / 全新安装只写标记）测的是协议 3
  搬迁命令，搬迁入口接回来时（G7-6 / D21）按新代重写。变异实测：去掉 `SrsStorage.open` 里的 `throw` → 第 2 条变红。4/4 绿。
- **C8（新发现，没人认领）：`.apkg` 导入随库大小超线性变慢**。`BulkFixture.open`（基准包导入）实测 250 / 500 / 1000 / 2000 条
  笔记 = 4.6 / 10.0 / 32.9 / 124.5 s（串行、`-j 1`），时间几乎全在内核命令 `import_drafts`（`SrsOpLedger`：500 条 7 批共 9.5 s、
  单批最长 2.1 s；1000 条 14 批共 34.7 s、单批最长 4.1 s）——每批的代价随库里已有笔记数线性涨，总量 O(n²)。这就是上一版
  「300 条导入 30 s 超时」与 `srs_ankiconnect_resident`「大库」（2000 条，放宽超时后单跑 129 s 才过）超时的根因，不是并发满载。
  疑点（未逐行证实）：`gen4/cache.rs:485` 一次写入变动的 ID 超过 `MOVES_IN_PLACE`（256）就整层重建；或 `:561` 起「脏的笔记
  类型把这一类全部笔记重算」（与 C5 同一处）——导入每批都碰同一个笔记类型的话，每批都会重算已有的全部笔记。要内核 owner
  在 `import_drafts` 上量一下每批走的是哪条路。
- **app `srs_review_inline_edit_test` 定位（上一版 not_done）**：上一版记的「清除格式后撤销按钮两分钟没亮」其实是测试的时序
  问题（A）：加粗那步只等修订号，修订号到了页面还在「写库 → 发修订号 → 重读」的忙态里（实测 bump 之后约 360 ms 才回到
  可按），紧接着注入选区、点「清除」，键是禁用的，点击被吞，之后再也等不到写入。改成加粗后也等撤销键重新可按（与后面几步
  同一个等法）。改后跑到最后一步：连续第二次撤销（倒序撤回原值）没有写命令落库（`SrsDbStore.revision` 停住）——就是 C6
  （`undo_check` 拒第二步），现在由同一条用例实证，不再是推断。变异：去掉新加的 `until`，复现「srsRevisionProvider 停在 1」。
  带 G9-7 的本地验证：1 绿 1 红（红 = C6）。
- 仍没做：`srs_p6_vectors_test`（同上，卡在 C1 与「没有协议 3 库生成器」）。

## 27. W3 合流修复（2026-11-17，分支 `pr/srs-gen4-w3-merge` / `pr/srs-gen4-w3-merge-dev`，integration owner）

第三波七块（G9-7、G9-5、G8-7b、G10-2、G10-3、G11-4、T1）按此顺序合进集成分支，再并入 develop。只修合流引入的冲突与断裂：

- **分发器**：G8-7b 接上 `relay_outbox`、G9-5 把 `profile_merge_mark` 标成已删后，新代已没有未接线命令。`dispatch.rs`
  文件头相应改写；`dispatch_tests.rs` 删掉未接线那一段循环（未接线臂由 `ffi.rs` 全量分类测试兜底）；`ffi.rs` 的分类断言
  改成 `unwired == 0`。`Wiring::Unwired` 变体保留给以后的模块。
- **测试期望随合流对齐**：`srs_core_test` 的 `profile_merge_mark` 改断言已删、快照剥离本机状态改断言一般错误（G11-4 已接
  新代）；`backup_tests.rs`「另一个集合要确认」最后一步改断言 `bound`（G9-5「空集合可换绑」× G11-4：全新 profile 的集合是
  空集合，确认后换绑而不是 Join）；`server_srs_migration_test` 的远程 hello 改走 V2 端点（G10-2 起 V1 一律 426）。
- **主库 schemaVersion**：develop 已占 156–158（NSFW 标记 / 来源自动扫描 / 音乐隐藏），G11-4 的空迁移顺延到 **v159**，
  全部 migration 测试的「当前版本」断言同步到 159（§25 第 11 条里的「155 → 156」现在是「158 → 159」）。
- **develop 的新功能接到新代**：存量单位提醒（`srsLimitUnitLegacyDecks`）用的读查询 `reviewed_decks` 在新代读命令
  （`cmd/reads.rs`）补上，语义同协议 3；`fushi/test/srs/srs_limit_unit_legacy_count_test.dart` 改按文件导出、确认后导入，并去掉「只并入复习日志不推进内容
  指纹」那条前提断言（新代导入整份重建派生层，指纹会推进；用例只钉合并后重算、本机评分不重扫的结果）。
  `backup_merge_engine.dart` 保留 develop 的 `excludedBookKeys`，不带回 G11-4 已删的 `localSrs` / `sourceSrs`。develop 改过的
  三份协议 3 测试 / 夹具（`srs_legacy_clock_conformance_test`、`legacy_clock_store_vectors.json`、`srs_gen4_rehearsal_test`）
  维持删除。

## 28. 第四波 K3 Anki 来源日志的 HLC 与写回包修改行（2026-11-17，分支 `pr/srs-gen4-k3-anki-log-hlc`，基于 `pr/srs-gen4-switch`）

修 §26 的 C4，顺带根治 §26 记在 G9-7 名下的 `srs_write_preread_cost` 2 条（定因见下）。不改线格式、不改 `native_allowed`、
不改冻结的 `history.rs` 规则，不升 SCHEMA（仍 40021）。

### C4：换代后新导入的 Anki 日志按操作 HLC 排

- **根因**：新代原生日志不带旧 HLC（设计 §3.4），`cmd/writes.rs` `parse_item` 丢掉输入里的 `hlc`，日志投影
  （`cache.rs` `log_body` → `log_json`）于是回落到操作自己的 HLC（导入时刻 + 本机设备）。可协议 3 的卡片历史规则
  （`history.rs` `EventKey` / `AnkiEvent` / `SortKey`）依赖「Anki 来源日志的 HLC 由来源数据派生」（铁律 C，Dart
  `anki_import_rules.dart`）：同一条 revlog 在血统两张卡上的副本靠它归成一个事件，更早的 Anki 复习靠它排在更晚的原生复习
  之前，锚点靠 counter = 1 排在同毫秒 revlog 之后。后果：统计 / 重放把副本算两次；比原生复习早的 Anki 复习成了最后一条
  有效日志，静默改掉卡片排程（实测 ivl 从协议 3 的值回到导入包里的 9）。旧库迁移进来的日志带承袭 HLC，不受影响。
- **定案**：Anki 来源日志的 HLC 在**日志投影层**派生，不进操作。唯一实现
  `native/fushi_fsrs/src/anki_import_rules.rs` `anki_source_hlc(origin, kind, anki_id, at)`：origin = `anki` 时，锚点
  （`importAnchor`）= `{at}:1:anki`，带 revlog id 的 = `{ankiId}:0:anki`，其余 None。与 Dart
  `srsImportedRevlogHlc` / `srsImportAnchorHlc` 共用向量 `native/fushi_fsrs/src/anki_source_hlc_vectors.json`（Rust 单测与
  `packages/fushi_srs/test/anki_source_hlc_vectors_test.dart` 两边各读一遍）。`cache.rs` `log_body` 对没有旧 HLC 的日志回落
  到它；`cmd/writes.rs` 回包 `logHlcs` 同口径（与 `read logs` 的 `hlc` 逐字相同）。派生值只依赖操作体，每台设备算的一样，
  摘要（只含日志 ID 集合）不受影响，head 的 `derive` 不升。`gen4/op.rs` `Log4` 与 `cmd/writes.rs` 文件头的说明更正（删掉
  「排序键是 (发生时刻, 操作号)」这句不准确的话：`history::select` 按 HLC 排）。
- **已有新代开发库的派生层**：新代原来没有「推导口径版本」，这里补一个最小的：`derive_cfg` 新键 `cacheRules`
  （`cache.rs` `RULES_KEY` / `CACHE_RULES` = 1）。整份物化（`materialize_caches`，`rebuild_all` / `rebuild_caches` 的最后一步）
  写下当前值；宿主每次打开都发的 `cache_config_set` 发现库里的不是当前值（这次之前建的库没有这一项）就整层重建一次
  （`Settle::Rebuild`，回包 `changed: true`）。真相不动、没加表，不升 SCHEMA。委托写的是「按现有重建标记机制」，代码里
  新代并没有这种机制（`dispatch.rs` 原注释写的是「换口径 = 新的 schema / 重建」，而新 schema 会被 `check_kind` 直接拒），
  所以补了这一个键；以后推导规则再改、同一份真相算出的缓存行变了时 +1。
- **没选**：让原生日志带 `hlc` 线字段（违反 §3.4 与 `native_allowed`，还让调用方能注入任意 HLC）；改 `history.rs` 让 Anki
  来源忽略 HLC（动的是与 Dart 共用的冻结规则与向量）。
- **信任边界**：派生 HLC 取自操作体里的 `ankiId` / `at`，对端写一条伪造 `ankiId` 的 Anki 来源日志就能影响它在选取里的位置；
  这与协议 3 里作者直接给 `hlc` 的信任面相同（本来就要信任作者写的日志），没有扩大。

### `srs_write_preread_cost` 2 条（`editFields` / `editFieldsBatch` / `writeEdits` / `applyLapisBackfill` 多 1 条读）

- **根因**：不是 G9-7 引入的，也不是「发命令前多读」：是命令**之后**的回读——`_emit(stamps: true)` → `_readBackEdits`
  再发一条 `read edits` 拼返回值（G7-5 起就有，switch 上同样存在，被 ID 口径的崩溃挡住没量到）。
- **修法（回包形状）**：`apply` / `import_drafts` / `change` 的请求带 `editRows: true` 时，`Session::finish` 收尾之后给回包
  `edits` 里有输入下标的每项补 `[行 JSON, 服务器时刻]`、`tagWrites` 每项补 `[行 JSON]`——都由 `read edits` 用的同一个
  `cmd/mod.rs` `edit_rows` 出（逐字相同；那一行已被同批后面的写入盖掉 = null）。不带这个键的回包形状不变（导入大批不付这笔
  成本）。Dart `_emit` 带 `stamps` 时发 `editRows`，`_writtenEdits`（原 `_readBackEdits`）直接从回包拼 `SrsFieldEdit`，删掉
  命令后的 `_editItemsById` 回读；`SrsWrittenItem` 加 `row` / `serverTime`。preread 期望（0 / 8）不动。

### 测试

- Rust（`store/gen4/cmd/writes_tests.rs`，与协议 3 对拍）：`an_anki_revlog_on_two_cards_of_a_lineage_counts_once`（统计
  (1, 1)、日志 HLC 是派生值、`same_state`）、`an_anki_review_older_than_a_native_one_does_not_reschedule_the_card`
  （最后一条日志仍是 r3）、`an_import_anchor_sorts_after_the_revlog_of_the_same_millisecond`（输入里锚点在前；`logHlcs` 与
  `read logs` 相同）、`edit_rows_in_the_reply_are_what_read_edits_gives`；`cmd/sync_tests.rs`
  `an_anki_revlog_imported_on_two_devices_is_one_event`（两台设备各导入一份、同步后统计 1 行、卡片行逐行相同、摘要相同）、
  `a_cache_built_under_older_rules_is_rebuilt_once_on_open`；`anki_import_rules` 两条（共用向量、锚点排序）。
- Dart：`packages/fushi_srs/test/anki_source_hlc_vectors_test.dart`（新）；`srs_written_edits_match_test` 加一条回包带行。
- 变异（各自还原后 `git status` 干净）：`log_body` 不派生 → Rust 4 条 C4 用例红；Dart（同一变异编出的 DLL）
  `srs_apkg_anki_revlog_dedupe` 2 条 + `srs_apkg_import`「① 导入」红。`logHlcs` 不派生 → 锚点用例红。`cache_config_set` 不看
  `cacheRules` → 重建用例红。不补修改行 → `edit_rows…` 红；Dart 不发 `editRows` → `srs_write_preread_cost` 3 条红（报
  「carries no stored row」）。

### 没做 / 交给谁

- `srs_write_preread_cost`「彻底清除」仍红（ops 计数 Expected 973 / Actual 958），与本节无关：§26 C1C5 定因时就量到
  971 / 956（同样差 15），疑与 G8-7b 合入有关，归彻底清除 / 同步 owner。
- （更正）§26 C4 报告里说的「Dart `srs_profile_merge.dart:617/631` 按 `l.hlc == srsImportedRevlogHlc(...)` 认导入日志」是
  另一条分支上的代码：G9-5 之后 profile 并入已移到 Rust，本分支的 `srs_profile_merge.dart` 只剩「续做半截并入」（169 行，
  没有任何 hlc 引用）；`lib` 里用到 `srsImportedRevlogHlc` / `srsImportAnchorHlc` 的只有 `srs_apkg_import.dart` 写入侧
  （2255 / 2312）。Dart 端没有按 hlc 认导入日志的代码，这一项无需交接。
- 从 Fushi 导出包回导、按新卡重映射的「外来原生日志」（`srs_apkg_import.dart` `_remapExtLog`，origin = fushi）的 `hlc`
  同样在 `parse_item`（`cmd/writes.rs` `l.legacy_hlc = None`）被丢、按操作 HLC 排；它们的 EventKey 比卡，不跨卡成组，
  所以不会重复计数，但排序从作者 HLC 变成了导入时刻：更早的外来复习可能排到本机更晚的原生复习之后、改掉当前排程（与 C4
  第二种表现同类）。本节没改、没实测（不在 C4 范围）；已单列进规划 §6 合并条件，切换前由导入 owner 判断要不要在投影层
  保留作者时刻。
- 同批后一条写入盖掉前一条时，回包里前一项的修改行是 null（`edit_rows_in_the_reply_are_what_read_edits_gives` 明确如此），
  而 Dart `_writtenEdits` 遇到 null 抛 `StateError`。旧 `_readBackEdits` 在同样场景下同样会抛，不是本节引入的回归，但
  「内核说 null 正常、Dart 说是两边对不上」的契约矛盾仍在：另开一项，定同批重复写同一字段时 Dart 的返回语义（取最后一条
  还是跳过），归写入接口 owner。
- 性能注记：`editRows` 让读回修改行在写事务里做（`Session::finish` → `attach_rows` 对每个碰过的实体调一次 `edit_rows`）。
  apkg 导入的 `_mapInto` 也走 `_emit(stamps: true)`，所以大批导入的写锁持有时间会变长；总工作量与原来的 Dart 回读相同，
  命令后被并发写插队的窗口反而没了。暂不改；若量到导入时写锁过长，可以只对非导入调用发 `editRows`。

## 29. 第四波 内核 C6 / C7（2026-11-17，分支 `pr/srs-gen4-k4-undo-tags`，基于 `pr/srs-gen4-switch` `9ad57c7109`）

§26 T1 节的 C6（连续两步倒序撤销第二步被拒）与 C7（只改标签不前移修改时间）。只改 Rust，不改 Dart、不加表 / 索引，
SCHEMA 不动（40021）。

### C6 根因与修法

- 根因：新代 `cmd/center.rs` `check_item` 把投影行的 `ctx` 当因果事实，交给 `registers::undo_verdict` 问「唯一活着的那条
  见没见过那次写入」。不带旧戳的写入的投影上下文由 `derive.rs` `edit_lines_as` 现拼，`by_dot.retain(emit)` 在拼 ctx 之前，
  只记「别的要输出的行」的 dot——判寄存器支配够用（`class.rs` `class_lines` 文件注释说明这是有意的），但被支配、不输出的旧
  写入（倒序撤到第二步时被问的那次写入）永远不在里面，于是必判不能撤。协议 3 的行 ctx 是写入者维护的完整 DVV，所以协议 3 能过。
- 修法（技术取舍）：「见没见过」改由真相层回答，不改 `edit_lines_as` 的 ctx 口径（给每行塞完整闭包会撑大读命令与缓存行、
  改掉对拍结果）。
  - `registers::undo_verdict` 的判据由调用方注入（`sees: &mut dyn FnMut(&UndoLive, &UndoTarget)`），值相同才问；唯一活着、
    值相同的规则仍只有内核这一份。协议 3（`store/sync2/undo_check.rs`）传按行 ctx 判的闭包（`UndoLive::ctx_contains`），行为不变。
  - `derive.rs` `Index::write_sees(k, w, q, class)`：带旧戳的写入看旧戳上下文（按类时过 `Canon::dvv` 换名），不带的看依赖 +
    自己之前的前缀与旧闭包（复用 `seen`，含别名类换名）。拼行与它共用新抽出的 `edit_write`。
  - `class.rs` `Index::class_write_sees`：按活行的规范 dot 在这个类的寄存器里找回操作（同 dot 多条取操作号最小的代表，同
    `edit_lines_as`），再问 `write_sees`。找不到 = false，只有笔记 `tags` 合成行这样（无因果过去，协议 3 那一行也是空 ctx）。
  - 可撤范围没有超出协议 3 语义：仍要求唯一活着、值相同、因果见过；并发同值（两条活着）照旧不能撤。

### C7 根因与修法

- 根因（交接文档原先猜的 `tag_ix` / 收脏方向不对）：缓存 `notes.updated_at` 本来就并上了 `tag_time`；浏览的 `edited:` 与按修改
  时间排都读 `Source::edits`，新代 `cmd/browse.rs` `edits_with` 只取 `class_lines`（寄存器行），新代的标签增删是 `tag_ix` 的
  OR-Set 操作、不进寄存器，于是漏掉。
- 修法：`edits_with` 改用读命令同一份 `cmd/mod.rs` `edit_rows`（寄存器活行 + 合成 `tags` 行，`hlc` = 最后一条标签操作，与协议 3
  `srs_field_edits` 同形）；`keys` 过滤按 `edit_rows` 给的键做，只要字段键时不带 `tags` 行。`note_browse_values` 只把 `f/` 键当字段
  原文，`tags` 行只进最后改动时刻（测试钉住）。

### 测试与验证

- 新增 Rust：`center_tests.rs` `undo_check_reverse_steps_on_native_writes`（`writes::apply` 本机写入：两步 / 三步倒序撤、跨键穿插、
  撤完又改成别的值不能撤）、`undo_check_reverse_steps_across_an_alias_class`（双盐场景跨设备：任意成员号 / 规范号点名结果相同；
  并发同值不能撤；`write_sees` 本身的真 / 假；传递见过能撤；再改走不能撤；重建恒等）；`undo_check_matches_protocol_3` 加 N2
  「y1 → y2 → 写回 y1」倒序序列；`browse_tests.rs` `browse_edits_count_the_last_tag_op_as_a_modification`。
- 变异实测：`check_item` 的闭包改回按行 ctx 判、`edits_with` 滤掉 `tags` 行 → 上面 4 条 Rust 用例全红（含对拍那条）；同一变异编
  quick DLL，engine `srs_edit_undo_test`「连续两步倒序撤」与 `srs_browse_test` 两条（「排序 … 修改时间」「行数据与笔记视图一致」）
  变红；还原后工作区干净。
- `native/fushi_fsrs`：`cargo fmt --check` 0；`cargo test --profile quick --lib -j 4` 0，1316 过 / 0 败 / 39 忽略（忽略的是存量）。
- 真内核（本 worktree `--profile quick --features raw_sql` 编的 `fushi_fsrs.dll`，`FUSHI_FSRS_LIB`）：engine
  `srs_edit_undo_test` + `srs_browse_test` 24/24；app `srs_review_inline_edit_test` 2/2（`heavy.dart --here`）。

### 复核修复（2026-11-17，同分支）

- 「见没见过」接进裁决后没有用例能区分（把注入的闭包改成恒真，相关用例全过）：补 `center_tests.rs`
  `undo_check_refuses_a_lone_same_value_write_that_never_saw_ours`——0xf1:1 写 V、0xf2:1 见过它写 W、0xf3:1 只见过 0xf2:1 写回 V，
  唯一活着、值相同、没见过 0xf1:1 → 不能撤；0xf4:1 见过两者再写 V → 能撤。原生写入按因果顺序投递时造不出「见过 0xf2:1 却没见过
  它见过的 0xf1:1」这种依赖，判据在新代是保险（防不可信的对端操作），用例直接喂操作。
- `write_sees` 旧戳分支的按类换名（`Canon::dvv`）没被钉住：补 `class.rs` `class_write_sees_renames_a_heritage_context`
  （(w1, 2) 的旧上下文写的是改名后的 `merged:1`，按类见过 (w1, 1)；(w1, 5) 没见过；类里没有的 dot = false）。撤销路径上被问的是不带
  旧戳的原生写入，这条分支答 true 的情形罕见。
- 浏览 `edits_with` 只要字段键时也拼合成 `tags` 行（每份成员一次 `tag_ix` / `reg_ix` 查询 + 每条标签操作一次读）：拆出
  `cmd/mod.rs` `edit_rows_with(.., tags: bool)`，`edits_with` 在 `keys` 为空或含 `tags` 时才拼；`browse.rs` 文件头「代价」写明。
  `browse_edits_count_the_last_tag_op_as_a_modification` 加「键里点名 `tags` 时带它」两条断言。
- 变异实测（各自单独套上、跑 `undo_check browse_ class_` 过滤、再还原）：闭包恒真 → 新 center 用例红；旧戳分支不换名 → 新 class
  用例红；`tags` 恒 false → C7 用例红；`tags` 只在 `keys` 为空时拼 → C7 用例（新断言）红。还原后工作区干净。
- `cargo fmt --check` 0；`cargo test --profile quick --lib -j 4` 0，1318 过 / 0 败 / 39 忽略（存量）。没改 Dart，没重跑 engine / app 测试。

## 30. 第四波 K5 别名表增量（C8 `.apkg` 导入超线性，2026-11-17，分支 `pr/srs-gen4-k5-alias-incremental`，基于 `pr/srs-gen4-switch`）

- **根因（§26 T1 节 C8 的疑点不对）**：不是 `cache.rs` 的整层重建，而是别名表的增量证明。Dart 导入按「笔记身份 → 字段 →
  标签 → 卡片修改」发草稿，`cmd/writes.rs` `apply_in` 在身份记录处、`expand_tags` 在标签项处各收尾一次，于是一条笔记的
  卡片修改总是和**下一条**笔记的身份记录落进同一次收尾，而不是和它自己的笔记同批。那次收尾里这张卡是新卡、没有日志带的
  提示笔记，`alias_probe` 拼的小份证据 P 里没有它的父笔记，卡验不上（条件 b），退回整表重算——每条笔记一次，每次
  O(库大小)，整次导入 O(n²)。日常路径同病：任何只碰一张从没出现过的卡的命令（改新卡牌组、暂停、新卡位置）都整表重算。
- **修法（`gen4/alias.rs`）**：没带提示的新卡向缓存层要父笔记（`card_parent_hint`：`cards.note_id`），提示笔记连同它在
  别名表里的整个类并进 P（`hint_class`，条件 c 要类全）。证明条件 a–d 一条没改，提示只添证据：缓存旧了、没配置缓存、
  卡 ID 不是规范形，都只是证不出、退回整表重算，别名表的内容不依赖缓存，只有「走不走增量」依赖它。
- **取舍：没建 `card_parent_ix` 反查表，schema 不升（仍 40021，40022 没用）**。委托里推荐的是别名层自建「卡 → 笔记」
  派生表，代码里不成立：一条笔记有哪些卡要看填空序号，序号来自字段内容（`card_cache::cloze_ordinals`），别名层不读字段；
  不读字段就只能按 `Limits::cloze_ords`（0～500）枚举，填空笔记每条每模板 501 行，存不下；读字段则要再给字段修改接一条
  维护路径（字段修改对别名表是中性的，不进 `AliasDelta`，否则逐条维护与重建对拍不齐），等于第二份「笔记有哪些卡」的判定。
  缓存层已经是那唯一一份（`cmd/writes.rs` `note_cards` 的注释同口径），所以直接拿它当提示源。
- **辅修没做（`apply_in` / `expand_tags` 每条命令只收尾一次）**：主修之后每次收尾只做这一批的量，剩下的只是常数项。
  辅修要改 `apply_in` 的读时序：`existed` 与标签展开（`expand_tags` 读别名类的现有标签）依赖收尾后的别名表，新笔记在批内
  并入已有别名类时口径会变，需要单独论证和对拍协议 3，风险高于收益，留给以后。
- **可观测**：`Settled` 加 `aliases_rebuilt`（这一次收尾整表重算了没有），写命令回包的 `settled` 加诊断键
  `aliasRebuilds`（整条命令里整表重算的次数；Dart 不读这个块）。
- **测试**：`alias.rs` `a_new_cards_own_edits_are_proven_from_the_cached_parent_note`（笔记与它的卡片修改分两次收尾、
  模板定义变了之后新模板的卡、父笔记哪里都没有时照旧整表重算并成候选行，末尾 `assert_rebuild_is_identity`）；
  `cmd/writes_tests.rs` `importing_in_the_dart_order_never_recomputes_the_whole_alias_table`（`import_drafts` 按 Dart 顺序
  4 批各 15 条，每批 `aliasRebuilds == 0`，末尾重建等同）。变异：去掉缓存提示两条都红（第二条报每批 15 次 = 每条笔记一次）。
- **实测**（临时探针，没提交：`import_drafts` 每批 70 条、每条两张卡，卡片修改 deck + newPosition，quick profile，机器负载
  较高、数字有抖动）：修后 250 / 500 / 1000 / 2000 条 = 1.8 / 3.1 / 6.6 / 12.9 s，整表重算 0 次，2000 条时前 14 批与后 15 批
  单批均值 474 / 411 ms（不随库变大）；去掉修复同一探针 = 2.8 / 5.1 / 16.9 / 92.2 s，整表重算次数 = 笔记数，单批从
  1.3 s 涨到 3.5 s。

## 31. 第四波 G8-7c 同步收尾（2026-11-17，分支 `pr/srs-gen4-g8-7c-sync-tail`，基于 `pr/srs-gen4-switch`）

接 §22 的遗留。schema 不升（仍是 `40021`）：新增的状态都放进已有的 `srs_meta` / `loc_state`，没有新表。

1. **收尾投递与 `finish` 不再整表重扫 `op_wait`**（§22 第 7 条的「每片重扫」）：`drain_native` 按设备走
   （`Truth::devices`），每台只按主键区间读到「下一个接得上的 seq」为止（`WAIT_RANGE_SQL`，`k BETWEEN key(dev, …)`），
   只对真正投出的那一行取操作体（`WAIT_OP_SQL`）；非原生设备的残留整段删（`drop_waiting_of`）。承袭那一支同样按设备走、
   投出一项记一次 `spent`，预算用完回 `drainMore`。`finish` 与 `status` 的「还剩几项」改用按设备区间的 `COUNT`
   （`waiting_count` / `pending_count`），只数不解码。`COUNT` 本身仍随剩余项数线性，但不解码、不再在每片里乘上片数。
   用例：`draining_a_large_waiting_buffer_reads_only_what_it_delivers`（300 与 1200 条等待项、预算 64、各投两片：VM 步数
   45331 对 48915，断言 ≤ 1.3 倍且没有全表扫）、`wait_lookups_use_their_keys`（EXPLAIN）。Rust 测试的 `v_pending` 改成
   只读连接直接数 `op_wait + op_pending`，不再先投递残留再数（以前的数法把「没投完」掩盖成 0）。变异：区间改全表读、
   改回整表解码、承袭投递去掉预算、测试的收段循环忽略 `drainMore`（新 `v_pending` 才抓得到）→ 各自用例红。
2. **`oldroot_ingest` 按 `maxItems` 切片，指纹跨事务累计**：每个写事务把这一批段的结论（落库 / 已有 / 坏段；要等的不算）
   记到 `srs_meta` 的 `gen4_oldrun/<col>/<位置>\n<路径>`（值 = 这一轮清单指纹）下，与落库同事务提交；最后一次不带段、带
   `settle` 与清单的收尾按清单重算待读列表，每一段都在同一指纹名下有结论、围栏也立好了才记指纹并清掉累计
   （`Receiver::finish_oldroot`）。清单中途变了，累计不算，下一轮重来。`oldroot_scan` 回包加 `fp`；`oldroot_ingest`
   必须带 `fp`，回包加 `rest` / `spent` / `drainMore`；Dart `srsSync4TakeOldRoot` 按 `kSrsSync4OldRootSliceItems = 256`
   切片，一片既没交完段也没新工作就抛 `StateError`。用例：`slices_of_one_round_add_up_to_a_recorded_fingerprint`、
   `old_root_takeover_is_sliced_and_still_records_its_fingerprint`（正序 / 倒序，`maxItems` 3）、Dart
   `srs_sync4_round_test` 的切片与无进展两条。变异：累计查找失效、忽略 `maxItems` → 红。
3. **协议 1 旧根的提示改了（偏离 D21 的那条定案的补充，§22 定案第 2 条）**。按 v3.3.0 源码核过：
   - 本机库迁移后原地封存成 `SEALED_SCHEMA = 39999`（`seal.rs`）。v3.3.0 的 `schema::migrate` 在任何步骤之前比
     `current > SCHEMA_VERSION`，报 `srs.db schema 39999 is newer than this build`；`SrsStorage.open` →
     `SrsCore.openInBackground` 失败即抛，`SrsStorageHost.acquire` 不缓存、不重建，墓碑库同样挡住「建一份空库」。所以
     **已迁移的设备装回 3.x：整个卡片库打不开，什么也同步不了，也不会往任何位置写东西**。Android 降级还得先卸载（清空本机
     数据，除非另有备份），iOS 商店版不能降级。原提示「先用 3.x 同步一次」对这台设备不成立，照做反而有丢数据的风险。
   - 在**另一台装 v3.3.0 的设备**上同步一次是安全的（复核更正：原文写「3.x」，只对 v3.3.0 成立，见本节「复核修复（第二轮）」
     第 1 条）：v3.3.0 的 `srsPrepareLocation` 把 `v2/` 升成 `v3/`（`v2/` 立协议 1
     围栏），之后 4.x 的设备按存量协议 3 位置接手（旧根接手、`v3/meta.json` 改写成 `minReader 4` / `moved: v4` 的围栏）。
     4.x 拒绝协议 1 位置时一个字节不写（`check_root` 在碰位置之前），所以 3.x 那边看到的仍是纯协议 1 的位置，不会和新代分叉。
   - 位置已经被 4.x 立过围栏之后，3.x 读到 `v3/meta.json` 的 `minReader 4` 就 `needsUpgrade`、整轮不写（v3.3.0
     `srs_location_crypto.dart` 握手 + `srs_folder_location.dart` needsUpgrade 时连媒体也不碰）；云盘先删后传窗口里 3.x 重建
     `minReader 3` meta、或一轮进行中被立围栏的情况，新设备下一轮重立围栏、按变了的清单只读新多出的段并承袭上传
     （下面第 6 条的用例）。
   - **定案**（第二轮复核后的最终文案，见「复核修复（第二轮）」第 1 条）：i18n `srs_sync_location_protocol1_root` 是「要升级
     它，请在另一台装 Fushi 3.3.0 的设备上用它同步一次——只有 3.3.0 能升级它，3.0.x 和更早的预发布版做不到。也可以换一个
     同步位置。不要把本机装回 3.x：本机的卡片库已经升级，3.x 打不开；Android 降级还得先卸载，会清空本机数据。」（第一轮
     `i18n_sync --remove` + `--add` 清掉了意思错的旧译文；第二轮用 `--set` 改 17 份，其余 14 种语言仍回落英文）；内核
     `check_root` 的英文消息与 `oldroot.rs` 文件头同步改。用例 `only_a_protocol1_root_is_refused` 钉住新消息。
   - **用户影响**：只在协议 1 位置上同步过、手上已没有 3.x 设备的用户，这个位置在 4.x 下没法升级，只能换位置（本机数据
     完好，新位置照常同步）；位置上只存在于协议 1 根里的别的设备的操作，要那台设备自己升级后才拿得到。这仍是 §22 定案
     第 2 条交所有者确认的那一项，没变。
4. **`location_forget {location}`（移除位置）**：`write_local`。依次 `forget_location`（`loc_*` 等位置行）、删 `loc_state`、
   清旧根累计（`oldroot_forget_run`）、对 `relay_segs` 里每个作者跑一遍 `sync_relay::prune`（不再是转发目标的原文立刻
   丢掉）。回包 `{forgotten, relayDropped}`，幂等。**刻意保留**：本机 outbox 水位、承袭指纹、`media_*`（同一个目录再加回来
   不必重传，媒体绑定是真相层操作，与位置无关）。Dart：`srsSync4ForgetLocation(host, locationId)`（`srs_sync4_steps.dart`）
   → `SrsSyncScheduler.forgetLocation(locationId, dropFromConfig:)`（进串行队列；内核忘掉成功之后才在同一个串行步骤里去掉
   配置，见「复核修复（第二轮）」第 3 条）→ 复习历史页「移除文件夹」。**G10-4 的
   host 目录接口**：互联 host 目录移除位置时同样调 `srsSync4ForgetLocation(store, locationId)` 即可，不用新命令。用例：
   Rust `a_removed_location_is_forgotten_and_no_longer_relayed_to`、Dart 真内核 `srs_sync4_folder_test`「移除位置」。
   变异：不删 `loc_state` / 不 prune → 红。
5. **小项**：
   - `head` 在没变化时不开写事务：分发器先在读快照上跑 `head_unchanged`（带 `skipUnchangedMs`、本机摘要没变、`last_ok`
     离现在不到一天 `LAST_OK_REFRESH_MS`），成立就直接回「不变」；否则照旧 `write_local(head)`。代价：`last_ok` 的精度
     从「每轮」变成「最多晚一天」，对 30 天的转发窗口无影响。用例 `an_unchanged_head_commits_nothing`（只读连接看
     `PRAGMA data_version` 不变）。
   - `loc_state.last_ok` 的 schema 注释改成实际含义（最后一次成功一轮、最多晚一天、转发窗口用它；列名冻结）。
   - Rust `v_pending` 不再先投递残留（见第 1 条）。
6. **规划 §6 同步相关的合并条件逐条核**（只核自动化测试能覆盖的；R0 真机实测不在本分支）：
   | 条件 | 覆盖 |
   |---|---|
   | 存量集合旧根接手 | `old_root_takeover_reaches_migrated_and_new_devices_alike`、切片用例、`a_new_collection_is_never_taken_for_an_existing_one` |
   | 新集合 / 存量集合立围栏 | `the_location_root_fences_protocol_3_and_refuses_what_it_cannot_read`、`fences_are_put_back_when_missing_or_changed`、Dart `srs_sync4_folder_test` |
   | 围栏写到一半 | `a_fence_interrupted_midway_is_completed_by_the_next_device` |
   | meta 先删后传的窗口、一轮进行中被立围栏 | **本分支新增** `an_old_client_writing_past_the_fence_is_still_taken_over`（3.x 重建 `minReader 3` meta 又写完一轮：围栏重立、只读新段、新设备拿全；变异「记过指纹就不再比清单」→ 红） |
   | 协议 1 旧客户端碰新位置 | `srs_format_break_test`（冻结的 v1 客户端真跑一轮，字节不变） |
   | 新版本碰协议 1 位置 | `only_a_protocol1_root_is_refused`、`srs_format_break_test` 第二组 |
   | 协议 3 客户端碰新位置 | 围栏内容（`minReader 4`、`moved`）由上面用例钉住；v3.3.0 的停下行为按源码核（第 3 条），树里没有冻结的协议 3 Dart 客户端，没法真跑 |
   | 转发件新旧格式互拒 | `gen4/relay.rs` `protocol_3_and_protocol_4_relays_reject_each_other` |

   远程复习的「新旧互拒四个方向」归 G10，不在同步模块，本分支没核。

### 复核修复（第二轮，2026-11-17，同一分支）

1. **协议 1 位置的提示点名 3.3.0**（复核 major）。按 tag 核过：正式版只有 v3.0.0、v3.0.1、v3.3.0。v3.0.x 的 `fushi/lib`
   里没有 `kSrsSync2V1Folder` / `srsPrepareLocation`（`git grep` 0 处）——它们还没有 sync2，走 `packages/fushi_srs` 的旧事件
   同步，根本不碰 `v2/`；会写 `v2/` 的协议 1 是 2026-10-30 断代之前的 sync2 预发布构建，它们只写 `v2/`；只有 v3.3.0
   （`srs_sync_scheduler.dart` 的 `srsPrepareLocation` + `srs_location_migration.dart`）会把 `v2/` 升成 `v3/`。一个位置只剩
   `v2/`，本身就说明从来没有 v3.3.0 设备在上面同步过，所以用户手上「仍是 3.x」的设备多半是 3.0.x 或预发布版，照第一轮的
   提示做什么也不会发生。**最终定案**：提示、内核 `check_root` 消息、`oldroot.rs` 文件头一律写「在另一台装 Fushi 3.3.0
   的设备上同步一次；3.0.x 和更早的预发布版做不到」。**对用户的影响**：要么另找一台设备装 v3.3.0（新装也行：v3.3.0 新库
   同步这个位置时同样先 `srsPrepareLocation` 升级位置，再由 4.x 设备按存量协议 3 位置接手），要么换一个同步位置；本机卡片与
   复习记录不受影响。协议 1 位置的只读转译（D21 原文）仍没做。
2. **旧根收尾护栏补用例**（复核 minor，第一轮变异全部存活）：
   - `slices_of_one_round_add_up_to_a_recorded_fingerprint` 加一步：收尾批交来的清单与这一轮指纹对不上 → 不记；
   - 新 `a_settling_slice_that_must_drain_more_does_not_record`：收尾批预算 1、等待缓冲没投完（`drainMore`）→ 不记，不带段
     的片投完那一片才记；
   - 新 `forgetting_a_location_drops_its_accumulated_old_root_conclusions`：`location_forget` 后 `gen4_oldrun/<col>/<位置>`
     前缀下 0 行。
   - 变异实测（`store::gen4::oldroot` 8 条）：(a) `location_forget` 去掉 `oldroot_forget_run`、(c) `finish_oldroot` 去掉
     `drain_more` 守卫、(g) 去掉 `scan.fp != *fp` 检查 → 各自对应用例红（exit 101，1 failed），还原后工作区干净。
   - (b) `head_unchanged` 去掉 `self_digest` 比较：判为等价变异，不补用例——`skip_unchanged` 比的 tag 已含本机摘要与版本向量，
     摘要变了 tag 必变、前一道就回 `None`。
3. **移除位置不再留孤儿状态**（复核 minor）：原顺序是先改偏好删掉位置、再 `forgetLocation`；后者抛错或卡片库没打开时直接
   `return`，位置已从界面消失、`loc_state` 还在，用户再无入口重试，活跃窗口里还为它留转发原文。改成
   `SrsSyncScheduler.forgetLocation(locationId, dropFromConfig:)`：在同一个 `_serially` 步骤里先让内核忘掉、成功之后才调
   `dropFromConfig` 去掉配置（中间插不进新的一轮把状态行建回来）；卡片库没打开 / 正在关闭就抛 `StateError`，配置不动。复习
   历史页失败提示换成新 key `srs_timeline_location_remove_failed`（复核 nit：原来复用的「文件夹不可用」意思不对）。用例：
   `fushi/test/srs/srs_sync_scheduler_test.dart`「移除文件夹位置：内核先忘掉、再去掉配置；卡片库不可用时配置不动、报错」。
   未改：`forgetLocation` 排在串行队列里，一轮长同步没跑完之前界面会等（与写 head 不交错是刻意的）。主同步后端（云 /
   WebDAV / 互联通道）断开或切换时要不要也忘掉位置：本分支没查清入口，归 G10-4（host 目录 / 通道位置的移除，接口就是
   `srsSync4ForgetLocation`）。
4. **规划 §6 / 设计稿 §6.3 同步类条件补全对照**（复核 minor）：

   规划 §6 位置覆盖面里第一轮没列的两项：

   | 条件 | 覆盖 |
   |---|---|
   | 互联 host 目录 | **缺**：没有经互联 host 目录跑新代位置的端到端用例（`srs_sync2_relay_test` 只覆盖经互联通道的转发，不是 host 目录本身的换代）。归 G10-4 |
   | link 步骤（D3 残留：旧服务端收到 v4 `seg-` 仍写一行设备名补充） | **缺**：没有用例。归 G10（服务端 / 互联） |

   设计稿 §6.3（规划 §6「§6.3 每一行一个测试」），逐行：

   | §6.3 行 | 覆盖 |
   |---|---|
   | 两台先后升级，后一台离线期间还在旧版本上写 | `an_old_client_writing_past_the_fence_is_still_taken_over`、`old_root_takeover_reaches_migrated_and_new_devices_alike` |
   | 两台同时升级（转译逐字节相同、新根 meta 相同、承袭段幂等） | 部分：`translation_is_total_deterministic_and_canonical`（proptest）、`meta4_is_a_frozen_pure_function`、`upload_fills_the_location_and_others_receive_it_identically`、`old_root_takeover_reaches_migrated_and_new_devices_alike`（B 看见 A 的承袭段不重传）。**缺**两台各自迁移同一份协议 3 库后比较本机转译结果与位置文件逐字节相同的端到端用例。归 G7（迁移）/ G8 |
   | 有一台永远不升级 / 已经丢了 | `old_root_takeover_reaches_migrated_and_new_devices_alike`（OLD 只在旧根上的历史经承袭到达新设备 C） |
   | 新装的新版本设备加入全是旧版本的位置 | 部分：`the_location_root_fences_protocol_3_and_refuses_what_it_cannot_read`（存量位置立围栏）、`a_new_collection_is_never_taken_for_an_existing_one`。**缺**「新装设备（无迁移来源）接触存量协议 3 位置」单独一条。归 G8 |
   | 升级时旧根还在被旧版本写 | `an_old_client_writing_past_the_fence_is_still_taken_over`、`the_old_root_is_rescanned_only_when_its_listing_changes` |
   | 升级中途断电 | `every_crash_point_resumes_to_the_same_library`（§6.1，G7）、`a_fence_interrupted_midway_is_completed_by_the_next_device` |
   | 回退到旧版本 | 本机：`a_ready_library_is_migrated_sealed_and_opens`、`opening_after_a_lost_seal_finishes_it`（封存）；v3.3.0 拒开按源码核（第 3 条）。位置：围栏内容由 `fence3_is_a_function_of_dir_and_meta` 钉住；**缺**真跑协议 3 客户端（树里没有冻结的 v3 客户端）。归 G8 |
   | 旧设备身份分叉过 | `a_different_fingerprint_is_a_fork_and_both_branches_are_kept`、`a_fork_is_never_swallowed` |
   | 不信任 / 拒绝过另一台的 Purge | `a_device_that_purged_and_one_that_has_not_yet_converge`、`a_library_that_purged_does_not_take_content_away_from_one_that_has_not`、`coverage_by_an_untrusted_or_unknown_uploader_does_not_count` |
   | 加密位置（kdf 原样抄、承袭段同钥匙密封） | `the_location_root_fences_protocol_3_and_refuses_what_it_cannot_read`（kdf 从旧根抄）、`check_meta4_compares_fields`、`an_encrypted_location_seals_segments_and_needs_the_key` |
   | 只有协议 1 旧根 | 按 D21 偏离定案明确拒绝：`only_a_protocol1_root_is_refused`、`a_new_collection_is_never_taken_for_an_existing_one`、`srs_format_break_test` 第二组；只读转译**缺**（待所有者确认，§22 定案第 2 条） |
   | 旧 `.fushisrs` / 旧备份 | 不属同步：G11（`v1_events_land_with_the_same_cards_and_logs` 等） |
   | 同机多 profile | 不属同步：G7（`profiles_bind_to_their_own_collections_and_an_unbound_one_joins_first`、`server_srs_migration_e2e_test` 两 profile 夹具） |
   | 服务端先升级，客户端还是旧版本 | 部分：`server_srs_migration_e2e_test`（启动自动迁移）、`srs_remote_generation_test`（V1 拒绝桩 426）。**缺**「经新服务端同步的旧客户端被围栏挡住」端到端。归 G10 |
   | 客户端先升级，服务端还是旧版本 | **缺**：旧服务端读到围栏进入「需要升级」、复习服务停掉，没有用例（树里没有冻结的旧服务端）。归 G10 |
   | 服务端一直不升级 | 同上，**缺**，归 G10 |

### 没做

- 规划 §6 的 R0 真机实测（文件夹 / 互联 host / WebDAV × 新集合 / 存量集合 / 先删后传窗口 / 一轮中立围栏 / link 步骤）：
  只有上表的自动化覆盖。
- 上面第 4 条表里标「缺」的各行（按标注归属）。
- 协议 3 客户端碰新位置没有「真跑旧客户端」的用例（树里只冻结了协议 1 客户端）；要的话得把 v3.3.0 的位置握手冻结进
  `test/srs/sync2/` 另一个 `v3_client/`。
- `COUNT(*)` 统计等待项仍随剩余项数线性（只数不解）；要做到常数得另存计数器，等实测证明是瓶颈再说。
- 协议 1 位置的只读转译（D21 原文）仍没做，见第 3 条。

## 32. 第四波 K1 换代迁移对拍（C1）与缓存层脏标记（C5）（2026-11-17，分支 `pr/srs-gen4-k1-migrate-parity`，基于 `pr/srs-gen4-switch`）

§26 的 C1 不是夹具问题，是内核里叠在一起的几处缺陷：任何带「没改过的内置 Lapis / Fushi 卡片」笔记的真实用户库换代迁移
都会因对拍判 aborted。本段把它们按根因修掉，并修了 C5。SCHEMA 不变（40021），没加表 / 索引。

### C1 修了什么

1. **协议 3 那份缓存配置由内核派生**（`store/gen4/class.rs` `legacy_config_for`）。宿主（Dart `srsCacheConfigFor`）G9-7 起
   只给规范 ID 的配置；冻结的协议 3 重建要的是按 profile uid 加盐的那份。`legacy_config_for(uid, cfg)` 用
   `builtin_rule_canon(&[uid])` 的反向表把配置里的默认牌组、内置笔记类型的字段 / 模板 ID、模板文本里的字段引用、词条 /
   读音字段换回带盐 ID；本来就带盐的输入、不是内置实体的 ID 原样。`compare.rs` `cache_pairs` 交给协议 3 重建（干跑的
   `old_caches`、测试装置的 `protocol_3_caches` 都经它）的改用这份；配置不是 JSON 时与「解析配置失败」同类，记成
   `caches` 差异。`migrate.rs` / `dryrun.rs` 的 `caches` 文档同步。Dart 照旧只传 `srsCacheConfigFor`，不在 Dart 拼盐。
2. **嵌入 ID 归一只有一个来源**（定案：走「`canonical_embedded`」这条，不让 `Index::canonical` 按规则回退）。这一处
   develop 上 `abc04c5fa3` 已经做了大半（键 / 值 / 整份 JSON / 配置都经 `canonical_embedded`：先查别名表、查不到再按当前
   盐集合的内置规则），本段把剩下的两套遍历合成一套：`canonical_key` 改走 `alias.rs` `key_ids_by` + `canonical_text`，
   值 / 整份 JSON / 配置 / 模板文本的遍历提成 `class.rs` 的自由函数（`value_ids_by` / `json_ids_by` / `config_ids_by` /
   `template_ids_by`），归一与 `legacy_config_for` 共用。`Index::canonical`（实体口径）**保持只查表**：别名类的成员
   （`members` / `aliases_of` / 缓存层 `anki_members`）只来自表，若 `canonical()` 按规则把表外 ID 归到别处，`members()`
   会给出不含它自己的类；只嵌在键 / 配置里、从不作为实体出现的内置字段 / 模板由 `canonical_embedded` 认。键 / 值 /
   JSON / 配置 / 对外命令 `canonical_ids` 五路结论一致由 `an_embedded_builtin_field_has_one_canonical_id_everywhere`
   钉住；实体口径（`canonical()` / `members()`）对表外 ID 有意不同，见下文「复核修复」1。
3. **重放的 fuzz 种子按作答时日志记的原值卡**：`sync2/replay.rs` `Row` 加 `seed_card: Option<&str>`（`None` = 取 JSON 的
   `card`，协议 3 调用方全部传 `None`）。新代 `LogIn` 带 `seed_card`（`log_at` 里取日志操作体的原值卡），缓存重建
   （`lineage`）、评分预览（`cmd/preview.rs`）、`sched` 写命令（`cmd/writes_intent.rs`）三处重放都传它（`group_rows` 回
   `GroupRow` 四元组）。以前种子是归一后的规范卡，带盐存量日志迁移后 fuzz 换了，违反 `replay.rs`「迁移不改任何一张卡的
   到期日」。
4. **prepare 缺表判 blocked**（`prepare.rs` `missing_tables`）：副本升级到这一版 schema 后，与同一份升级阶梯在空库上建出的
   表逐个比，缺表（schema 标记与表不符，如开发版标 13 却没有 v12 的 `sync2_replay_pending`）判 `blocked(corrupt)`、原因带
   缺的表名。不新增 wire code：Dart 已把 `corrupt` 归为 `damaged`（重试不会变、原样保留、带日志联系支持），正是这类库该有
   的处理。没有按「no such table」错误文本猜。

### C5 修了什么

`cache.rs` `Dirt::register`：笔记类型的寄存器只在键影响缓存行时记脏（移植协议 3 `note_type_key_affects_caches`：名字、
CSS、`fieldDesc/` 不进笔记 / 卡行；键按紧凑编码 `read_edit_key` 解回文本）。`settle` 的 `registers`、`judge` 的状态变化
都走它。`weigh_rest` 原来把 `touched` 整个并进脏集合，笔记类型由此绕过了键过滤：改成 `Dirt::touched`，笔记类型不从
`touched` 记脏——它的来源只有写入 / 重判（已按键判）、身份记录（`dirt.ids`）与 `Purge`（`derive.rs` 落 `Purge` 时直接记）。
`refresh_caches` 不改。

### 委托描述与代码不符

- 定因报告说 `canonical_config` 里有「单独的规则回退」、`canonical_key` 只查表：switch 头上（含 develop 的 `abc04c5fa3`）
  已经统一经 `canonical_embedded`，报告是在不含这个提交的本地合并上做的。②本段只做了收尾（遍历合一、文档、测试）。
- 定因报告的 Rust 迁移测试设想「评分日志 ID 随便取」：别名证据只收 UUID 形的日志 ID（`alias.rs` `alias_evidence`
  `typeof(id) = 'blob'`），日志 ID 不是 UUID 时日志上的卡不算观察到、带盐卡认不出规范卡。真实日志 ID 都是 UUIDv7，
  新测试照真实形状写；这本身不是缺陷。

### 测试

Rust（`cargo test --profile quick --lib -j 4`）：新增 6 条——`migrate_tests` `a_salted_library_of_untouched_builtin_note_types_migrates_unchanged`
（带盐、未改过的内置 Lapis，8 条笔记各 5 次带 `sc` 的评分；只传规范配置迁移 → committed、`parity` / `canonical` 为空、
笔记字段不空、卡不隐藏、到期日与间隔逐张等于协议 3 当时算的）、`replay` `the_fuzz_seed_is_the_card_the_log_was_answered_on`、
`class` `the_protocol_3_config_is_derived_from_the_canonical_one` / `an_embedded_builtin_field_has_one_canonical_id_everywhere`、
`cache` `note_type_keys_outside_the_rows_do_not_recompute_its_notes`（名字 / CSS / 字段说明 0 条，词条字段 / 模板 1 条，
每步增量 = 重建）、`prepare_tests` `a_library_missing_tables_its_schema_claims_is_refused_as_corrupt`（对拍装置 `KNOWN`
登记了这一条：库被有意弄缺表，协议 3 收尾在副本关库时没有基准）。变异实测：去掉 `legacy_config_for` / 去掉
`seed_card`（缓存层）/ 去掉键过滤 / 去掉缺表判定 / 去掉嵌入 ID 的规则回退 / `replay.rs` 不用 `seed_card`，各自让对应
用例变红，还原后工作区干净。

Dart（本 worktree 编的 release DLL）：`srs_stats_vectors` 2/2、`srs_stats_report_parity` 2/2、
`srs_write_path_read_amplification` 8/8（含 C5 那条）、`fushi_srs` `srs_gen4_migration_test` + `srs_core_test` 27/27。
统计两份的测试侧改动：期望值是按冻结库的带盐 ID 记的，新代给规范 ID，比对前经内核 `canonical_ids` 换 ID
（`test/srs/support/srs_migrated_ids.dart`），假 RWKV 打分器按旧 ID 算；报告对拍的浮点按相对 1e-12 比（卡 ID 变了，
内核按卡 ID 序累加的均值 / 合计只差最后一位，实测 4.159955977448237 对 …238、0.81 对 0.8100000000000002），其余逐值。
到期 / 间隔 / 稳定度 / 难度逐值相同，即迁移没改任何调度。

### 没做 / 交给谁

- **(c) 写回包补 `edits`、去掉命令后的回读**：归 K3，本段没碰。
- `srs_ankiconnect_vectors_test`：复核修复里已转绿（见下文「复核修复」2），这里不再是遗留。
- **`srs_p6_vectors_test`（没做，步骤留给下一段）**：develop（`origin/develop`，协议 3 仍在）上还能 `SrsCore.open('<dir>/srs.db')`
  + `debugExecBatchRaw` 灌协议 3 表。步骤：① 在 develop 的独立 worktree 里给 `srs_p6_vectors_test` 的 `setUpAll` 加
  `SRS_P6_VECTORS_WRITE=1` 分支：灌完 1200 份历史后 `core.snapshotInto(snap, stripDeviceLocal: false)`，gzip 存成
  `test/srs/fixtures/p6_vectors.db.gz`（与 `srs_stats_vectors` 当初同一种造法）；② 把这份 `.db.gz` 带到本线，测试改走
  `openMigratedTestSrs`（迁移时每个 `p$i` 各一份 `srsCacheConfigFor`），再按 profile 开 `SrsDbStore` 调新代的读命令；
  ③ 先确认两点再动手：profile `p$i` / 卡 `v$i` 不是 UUID，迁移与新代读命令对文本 ID 的处理（`Key::Text`）要验；1200 个
  profile 各一个集合，迁移耗时要量。服务器时刻（`srs_event_local`）经迁移承袭（G7-2 `server_time`），向量里的 `server`
  照比。

### 复核修复（2026-11-18，同分支）

复核（verify:K1）的三条逐条处理，各配测试并做变异实测：

1. **对外命令 `canonical_ids` 与键 / 配置口径不一致**（minor）：`cmd/identity.rs` `canonical_ids` 改走
   `Index::canonical_embedded`（先查别名表、查不到按当前盐集合的内置规则认），偏好里存的带盐内置字段 / 模板 ID 发进来换成
   笔记视图里的规范字段 ID，与键 / 值 / JSON / 缓存配置同一个结论（`a984d35bed`）。`Index::canonical` / `members` 仍只查表
   （定案不变：别名类成员只来自表，否则 `members()` 会给出不含自己的类）——实体口径对「只嵌在键里、从不作为实体出现」的
   内置字段 / 模板 ID 原样返回是有意的，对外只经 `canonical_ids`，Dart 不直接拿实体口径归一嵌入 ID，所以不另加 Dart 守卫。
   测试：`class.rs` `an_embedded_builtin_field_has_one_canonical_id_everywhere` 加 `canonical_ids` 断言。变异：改回
   `ix.canonical` → 该用例在 `canonical_ids` 断言处变红。
2. **`srs_ankiconnect_vectors` 仍红**（minor）：根因有两层。
   - 内核：协议 3 给从没复习、没改过的内置笔记的卡也发了数字 id（带盐笔记 × 带盐内置模板），内置模板从不作为实体出现、
     别名表里没有它的带盐 ID，`anki_members` 配不出那张卡的旧号，旧号反查落空。`class.rs` 新增
     `builtin_template_members`：内置模板的成员由所属笔记类型的成员按 `rules::template` 算回，`cache.rs` `member_numbers`
     并进模板成员（`dd2cf77eaf`）。测试：`migrate_tests` `a_salted_library_of_untouched_builtin_note_types_migrates_unchanged`
     加两条从没复习的笔记，协议 3 每张卡的数字 id 迁移后经 `anki_resolve` 都反查到对应规范卡。变异：
     `builtin_template_members` 返回空 → 该用例在「protocol 3 card … resolves to its canonical card」变红。
   - 测试：冻结向量是旧实现按带盐 ID 的号记的。G9-7 起对外数字 id 是规范 ID 的号（`hash53("anki-id/<规范 ID>")`），内置
     实体换号。测试先把向量里出现的旧笔记 / 卡号经 `noteIdsForAnkiNumericIds` / `cardIdsForAnkiNumericIds`（即走产品的
     旧号反查路径）换成规范 ID 再算新号，反查不到直接失败（= 迁移丢了实体）；牌组 / 笔记类型按名字对号；请求里用到的号按
     冻结向量里记的那批旧号换算（不取「新列表的第 n 个」，顺序本身也在比对之列），期望值与请求键里的旧号统一换成新号后
     逐项比，其余值（字段、到期、间隔、顺序）一个不放宽。另断言冻结向量点名的已删笔记换号后就是库里那条已删笔记。
     变异：换号表置空 → 测试变红；还原后 1/1 绿。
   - **外部客户端看到换号的定案（所有者授权自定）：接受**。理由：旧号经 `anki_members` 仍能反查（AnkiConnect 按号点名的
     入口经内核 `anki_resolve` / `anki_notes_info`（`cmd/columns.rs`，缓存行查不到时查 `anki_members`），旧号照常命中），只是查询结果吐新号；新号是规范 ID 的号，
     多设备 / 多盐下同一实体只有一个号，比保留带盐旧号（各设备各一套）更稳。不丢卡片与复习记录。
3. **prepare 缺表检查拿全新库当基准的误拦风险**（nit）：`schema.rs` `migrate` 文档写明不变量「从任何版本升级上来的库与全新库
   的表集合相同」，`tests_v15_upgrade.rs` 的 v8 / v15 冻结夹具升级用例加表集合比对（`a984d35bed`）。变异：在
   `current < 1` 分支多建一张表 → v8 / v15 两条用例报 `upgraded lacks fresh tables ["srs_k1_fresh_only"]` 变红。

验证：`native/fushi_fsrs` `cargo fmt --check` 退出 0；`cargo test --profile quick --lib -j 4` 退出 0，1319 passed / 0 failed /
39 ignored。`packages/fushi_engine` `dart test` 定向跑 `srs_ankiconnect_vectors_test` + `srs_stats_report_parity_test` +
`srs_stats_vectors_test` + `srs_write_path_read_amplification_test`（本 worktree 编的 DLL）退出 0，13 条全过。

## 33. 第四波 K2 首见信任与清除字节层（2026-11-17，分支 `pr/srs-gen4-k2-trust-purge`，基于 `pr/srs-gen4-switch`）

修 §26 T1 节的 C2、C3。SCHEMA 不升（没加表 / 索引，只多两个 `srs_meta` 键）。

### C2 首见设备判待确认（BUG-4306）

- 真相层新子模块 `store/gen4/truth/trust.rs`：`Truth::library_fresh(col)` 直接查真相（逐台设备按主键区间扫 `ops`，
  只认内置种子 = `data` 带 `builtin` 的实体创建、盐、并入、还原点为「没有用户内容」；有空洞 / 副本记录 / 待投递承袭槽
  就不算空），不读派生投影（BUG-4478 那类「投影滞后误判空库」从结构上没有）。比协议 3 的口径更保守，偏差方向只会多问。
- `Truth::note_new_peer(col, device, public, prev, seen_at)`，判定顺序：① 本机已有它的日志（承袭日志先于公钥到）→ 不追溯，
  按可信（协议 3 给「有设备行、没公钥」补公钥时也不判待确认）；② 带 `prev` 且 `peers` 里旧身份的公钥与新 head 公钥逐字节
  相同 → 原样继承旧身份的信任状态与 `since`，新身份没自报名字时带上旧名字；公钥不同不继承；③ 库空 → 首次信任；④ 待确认。
  由于 ①，写下信任行的设备在本机一条已落库的操作都没有，派生层不必重判。
- 入口：`cmd/sync.rs` `plan`（含转发来的 head）与 `cmd/sync_oldroot.rs` `oldroot_ingest`（v3 head，没有 prev）在
  `PeerPut::Inserted` 时调。`plan` 是本机状态写命令（`write_local`，不动派生层），所以不调 `trust_changed`；旧根那条在写了
  信任行时调 `Receiver::trust_changed` 兜底。
- 迁移端到端已实测（`sync_trust_tests` 的 `a_migrated_*`）：协议 3 两台库迁移后各换新身份，新 head 的 `prev` 公钥就是
  `peers` 里搬来的旧公钥（迁移沿用 `key_seed`），b 上 a 的新身份原样继承可信 / 待确认、`since`、名字，不会整批待确认。
- 语义变化的连带：库非空的设备首见对端都是待确认，D20（不受信上传者的承袭段等确认再收）与转发「只存受信作者的段」从此真的
  生效。两条既有测试（`old_root_takeover_reaches_migrated_and_new_devices_alike`、`a_device_on_two_locations_relays_between_them`）
  改成先确认对端再断言原意。

### C3 清除的字节层

- `schema.rs` `configure`：写连接一律 `PRAGMA secure_delete = ON`（读回核对）。新代库的写连接只有 `schema::open` 一个口
  （内核写连接、迁移 / 预演目标库）；读连接 `query_only`；`kernel.rs` 并 WAL 的旁路连接只做检查点；协议 3 旧库连接不是新代库。
- 新模块 `store/gen4/scrub.rs`：`advance_purge` 落空洞的同一个事务里记 `srs_meta` `gen4_scrub_due`；`kernel.rs` `write_tx`
  提交后（事务外、仍拿写锁）做收尾：没有 `gen4_secure_delete` 标记的存量库先 `VACUUM` 一次并记标记，再
  `wal_checkpoint(TRUNCATE)`，成了才删 `gen4_scrub_due`。命令本身已提交，收尾没做成不改它的结果，标记留着。没做成分两种
  （复核修复，`scrub.rs`「没做成怎么办」）：检查点被读者挡住 → 之后每条写命令提交后再试，但**不等**读者（忙等临时设 0）；
  出错（整理时空间不够、I/O 错误）→ 原因记进 `srs_meta` `gen4_scrub_error`，由新读命令 `scrub_state`（`{due, error}`，
  整库一份）报给 UI，**不再逐条写命令重试**，只在下一次打开或下一次又有清除落空洞时再试，做成了删掉错误。没放进 `status`：
  `status` 的形状按规划 §2.1 与协议 3 逐键相同（`status_keeps_the_protocol_3_shape` 守着）。`schema::open` 建库那一笔记
  `gen4_secure_delete`，所以换代迁移建的库与全新安装都不需要整理。
- 存量库的取舍：每次清除都 `VACUUM` 代价太大（约等于库大小的临时空间、期间占写锁），开库时做会让每个存量库启动卡一次；
  只在第一次清除时做一次。生产里需要整理的只有换代开发期间用集成分支建的库（develop 上只有预演，没有在用的 `srs4.db`）。
- 绕开 `write()`/`finish` 的灌库入口：`.fushisrs` 第 2 版、第 1 版、旧备份读入（`import.rs` 三处）原来只 `ingest_settle(Rebuild)`，
  带进来的 `Purge` 要等下一条写命令的 `finish` 才执行；改成同一个事务里 `execute_purges`（`settle_imported`）。迁移
  （`dryrun.rs` 的重建）没改：协议 3 的清除在旧库里已经执行过，迁移不改真相是既定口径。

### 封存旧库 `srs.db` 里的原文（定案）

不改封存库。理由：保留副本存在的意义是「出事能回退旧版本」，在封存库上做局部清除会让它变成协议 3 自己也没写过的状态
（协议 3 的清除要同时改投影、日志、段缓存），回退时反而可能出问题；按 D6 / D32 的设计，它在新代第一次同步成功 14 天后整份删除（设置里
可提前删），迁移前的原文随之消失。**依赖**：D32 的自动删除与提前删除入口还没实现（§25 末、G7-6），彻底清除确认处的说明也要跟
那个入口一起加（说明里要指向真实存在的删除入口，现在加只会说空话）。归属 G7-6 / 保留副本 owner。

复核后补充（不改定案）：复核建议的另一条路「先加一句不指向入口的说明（旧版本保留副本里的内容会在保留期结束时一起删除）」
没采用——自动删除还没实现，这句话现在是假的，用户据此放心反而是误导。**G7-6 的任务清单必须明列两项**：① 彻底清除的
确认处（`srs_deck_list_page.dart` 的 `_DeckDeleteMode.purge` 选项说明，`srs_deck_delete_purge_hint`）加一句「旧版本保留副本里
还有迁移前的内容，会在保留期结束时（或你在设置里提前删除时）一起删除」；② 新读命令 `scrub_state` 的 `error` 非空时的提示
（「清除的内容在磁盘上还没抹干净：<原因>」）。在 G7-6 落地之前，彻底清除迁移前的内容后封存库里原文仍在、界面没有提示，
这是已知缺口。

### 转发里的副本（复核修复两轮，2026-11-17 / 11-18）

复核指出转发缓存 `relay_segs`（G8-7b）存着作者段原文：同步着 ≥ 2 个位置时，清除之后原文仍留在 `srs4.db` 里、之后还会
原样转发出去。清除的执行点归本模块，所以在这里修，不外推给转发 owner。

**第一版（6c8d73af34）的回归，已废弃**：清除时整份删掉缓存里的作者段、把已转发的 `rly-` 改成待删、收段时拒收带原文的段，
等作者自己重切。第二轮复核实测：清除由**转发者 b**（不是作者 a）发起、a 不回来时，只连 L2 的 c 拿不到 a 那一段，b 的 Purge
指向 a 的 seq、b 此后每条操作的依赖都点着 a，于是 **b 之后的全部操作**（包括普通复习）在 c 上都卡在等待缓冲。根因：作者
签名覆盖整段明文，转发者改不出空洞，「不搬」就断流。

**现在的数据流（第三轮）**：转发者自己**重切**——新格式 `FRX4`（`gen4/recut.rs`）：同区间、同首尾链值、同文件名，把本机
已清除的操作换成空洞（相邻空洞合并），用**转发者自己的钥匙**签（签名覆盖原段头、重切者 ID、明文压缩体，域前缀
`fushi-srs-recut/4`）。读者照原生段的规则落库（空洞落成空洞，本机已有的完整操作不因此被清掉），但只收**本机信任的**
重切者签的件（`receive.rs`：没记过重切者公钥 = `UnknownSigner`，信任表有它的行 = `UntrustedUploader`，同承袭段上传者，D20）。
作者自己签的段到了之后链值不接 = 分叉，照常报 G8-6。

**更正（第四轮复核 major，2026-11-18）**：上一版这里写的「受信设备本来就能发 Purge，重切件给它的权力不超过这一条」**不成立**。
复核实测：重切件的段头与明文全由重切者签名担保，读者只核「操作的 device / seq 对得上段头、至少一个空洞、重算链值等于段头
`last_chain`」，而空洞的 `chain_after` 与段头 `last_chain` 都由重切者自己填。受信的 b 能伪造作者 a 的段头 `[1..4]`（a 一条都
没写过），内容是三条 `FORGED` 加一个空洞，读者照收（`last_of(a) = 4`）；a 真正的段到了反而 `Diverged`。也就是能以作者的名义
写入任意内容、抢占作者以后的 seq（所有读者上 a 的日志分叉，等于拒绝服务）、日后吊销 b 也撤不回。Purge 只能把已有操作挖成
空洞，做不到这些。

现在的收法（`58e57cf4e6`）：
- `plan` 读到每一份验过签名、公钥与记录相符的别的设备的 head（直接读到的与被转发来的 `rhd-` 都算，不论信任），把它的
  (代号, seq, 末端链值, 段清单) 记进 `srs_meta` 的 `gen4_ahead/<col>/<设备>`（`Truth::note_author_head`，只进不退；本机状态，
  不同步、不导出，丢了下一轮 `plan` 回来）。
- 收重切件（`receive.rs`）：验过重切者签名之后，区间与链尾必须是作者自己签过的一段——记下的作者最新 head 的段清单里正好有
  `(first, last, 链尾标签)`，`last` 正好是那份 head 的末端时完整链值也等于 head 的 `chain`（`Truth::author_listed`）；本机自己
  的日志则要本机已写到 `last`、那里的链值相同。否则 `Defer::Unlisted`（不落、不进等待缓冲；作者的 head 还没读到时下一轮再试）。
- 这样封住了：伪造作者还没写到的 seq（上面的探针场景）、伪造作者没签过的区间、伪造链尾（标签不同；区间末是 head 末端时
  完整链值不同）。

**残余风险（如实记下，没有修掉）**：在作者已列出的区间里，空洞**之前**的操作仍只由重切者担保。受信的重切者可以把它们换成
任意内容，末尾放一个空洞、链值填作者的真链尾，读者核不出来；伪造内容以作者的 HLC 参与冲突裁决，日后吊销重切者也撤不回。
所以重切件给受信设备的权力**超过** Purge，只是被限制在作者已发布的区间里。另外 head 的段清单只带链尾的前 4 字节（标签），
区间末不是 head 末端时读者只核得了这 4 字节：重切者可以随手填一个标签相同、其余不同的链尾，读者照收，作者接在后面的段
到了才报分叉（G8-6 两支都留、不丢数据，但这位作者在这台读者上的后续日志会卡在分叉处理上）。
根治方案（没做，原因如下）：空洞对每条被挖掉的操作带「信封 + 载荷哈希」（正是 `chain_next4` 的输入，链定义不用改），重切件
里不再允许只带链值的重置空洞，读者从 `prev_chain` 一路重算到作者签的链尾，活着的操作就都绑回作者签名。卡在数据来源：
`recut_from_log`（缓存里没有这一段时从日志重切）用的是本机日志，清除之后日志空洞只留区间末链值，被挖掉操作的信封与载荷
哈希已经没了；要在挖空之前把它们存下来就得动 schema（本模块没有分到 SCHEMA 号），作者自己签的空洞（只带链值）也无法换成
这种形态。做这一步之前，重切件的这一残余风险由「只收本机信任的重切者」兜着。归同步安全 owner 排期（需 SCHEMA 号）。

- 清除时（`Truth::advance_purge` 同一个事务，`sync_state.rs` `Truth::relay_purged`）：缓存里覆盖这个 seq 的件原地换成本机签
  的重切件（本机还没有身份签不了才整份删）；`relay_out` 里已转发到各位置、覆盖它的 `rly-` 改成待删。
- 转发时（`cmd/sync_relay.rs` `relay_outbox`）：待删的同名件算「缺」，用重切件同名重写（`relay_ack` 记回在用，不删）；作者
  新 head 不再引用的旧名的待删件照两段式删除。缓存里没有这一段（从没留、或每个位置都有了已删）时从本机日志重切
  （`Truth::recut_from_log`：本机这段有空洞、日志盖得到、两端链值都在、段尾链值与文件名的标签相符）。
- 收段时（`keep`）：在本机已清除的 seq 上还带着完整内容的件（作者 / 别的重切者清除之前的那份）不留；同一段已存着重切件、
  这回收到作者签的那份（作者自己重切了）就换成作者签的，读者不必信任本机这个重切者。`wanted_for_relay` 不再为本机清除过
  其中操作的段去拉原文（`Truth::voids_within`）。原来的 `gen4_rrefuse/…` 拒收记录整套去掉（第二轮复核 nit：键不回收、
  没有 head 时代号记 0 每轮白拉），不再写这种键；开发期集成分支库里可能残留的这种键没人读，无害。
- 切点落在一次跨段清除的空洞内部（作者分两次同步写的同一条笔记、两段相邻，清除把两条合成一个空洞区间）：原生日志的空洞
  区间只记区间末的链值，合并会把切点处的链值埋掉。`Truth::insert_void_run` 合并**别的设备**的原生日志的空洞时，把被合进
  区间内部的那几处区间末链值记成 `log_marks` 记号，`Truth::chain_known` 在空洞内部先查记号。本机自己的日志不记（本机的段
  按新切点重签，`cmd/sync.rs`）。**代价**：`.fushisrs` 第 2 版导出流的空洞只带区间末的链值，导入方拿不到这些记号
  （`import_tests` 的往返测试显式核对了这一处差异，`truth_lines` 不比空洞内部的记号）；从备份还原的库若又要从日志重切一段
  切点埋在空洞里的作者段，退回「这位作者整台不转发」（`incomplete`）。要彻底补上需导出流升 `ver` 带上这些链值，归 G11 owner
  评估，本分支不改导出格式。
- 测试（`cmd/purge_scrub_tests.rs`，a 只连 L1、b 连 L1 + L2、c 只连 L2）：
  - `a_purge_by_the_relay_does_not_cut_off_a_location_only_it_feeds`（复核 major 的原场景：b 已把 a 的段转发到 L2 后由 b 清除、
    b 再写一条，a 一直不回来；c1 清除前收过原文、c2 只在清除后来，两台都收齐 a 其余的与 b 之后的、等待缓冲为 0，L2 / c 的库
    字节里扫不到原文；作者签的原文再到 b 手里，缓存不留）；
  - `a_purge_recuts_the_relay_copy_in_place_and_relays_the_recut`（缓存原地重切，转发到 L2 的是 b 签的件）；
  - `a_purge_across_the_authors_cut_point_still_recuts_both_segments`（切点埋在合并后的空洞里，两段都从日志重切出来）；
  - `a_location_joined_after_the_purge_gets_a_recut_and_no_original_is_fetched`（b 收段时只连 L1、没留原文，清除之后才连上
    L2：不为转发去拉原文，L2 拿到的是 b 从日志重切的件）；
  - `a_purge_by_the_author_takes_back_what_was_already_relayed`（作者发起：已转发的旧 `rly-` 删掉，转发作者自己重切的新段，
    不为转发去拉原文）；
  - `receive.rs` `recut_pieces_need_a_trusted_recutter_and_land_their_voids`（含作者清单没读到时 `Unlisted`）、
    `a_trusted_recutter_cannot_write_where_the_author_has_not_signed`（第四轮复核 major 的探针场景：作者没写过时伪造 1..=4、
    超出作者 head 的区间、链尾标签不同、标签相同而完整链值不同，一律 `Unlisted`、不落不等；作者真正的段与接在后面的照常）、
    `a_recut_of_my_own_log_must_match_what_i_wrote`；`sync_state.rs` `the_authors_listing_only_moves_forward_and_binds_range_and_chain`；
    `gen4/recut.rs` 六条编解码 / 验签 / 拒写测试；
  - `truth.rs` `voids_within_reports_runs_cut_to_the_range_including_a_leading_one`（第二轮复核 minor：前导空洞分支）、
    `scrub.rs` `a_retry_that_does_not_wait_returns_at_once_when_a_reader_holds_the_wal`（第二轮复核 minor：`Wait::No` 不等读者）。
  - 变异实测见 PR 描述（9 项，各自对应测试变红）。
- 没覆盖：别的设备从 L2 上拉走那份旧件、在它收到清除之前——那台设备收到清除时自己落空洞、做字节层收尾，与作者自己的段
  同一个口径。
- 清除时缓存里读不了的件（第四轮复核 minor）：`Truth::recut_kept` 遇到解不开、签名者公钥本机没有、重切签不出的缓存件一律按
  「整份删掉」处理，不再把错误往上报——它跑在 `advance_purge` 的同一个事务里，上一版会让用户的彻底清除整笔失败。删的是转发
  缓存、不是数据，缺的那一段之后由 `relay_outbox` 从日志重切或记 `incomplete`。测试 `sync_state.rs`
  `an_unreadable_relay_copy_does_not_fail_the_purge`。
- 第四轮变异实测（各自还原，工作区干净）：M1 不核作者清单（3 条红）、M2 不核 head 末端完整链值（2 条红）、M3 本机日志不核
  （1 条红）、M4 `plan` 不记作者清单（4 条端到端红）、M5 读不了的缓存往上报错（1 条红）、M6 清单不只进不退（1 条红）。
- 交接 §26 T1 节 C2、C3 两条上一轮加的「已修：§28」指针已撤回（不改别人的节）；修复记录只在本节。

### 已知残余风险（复核记录）

- **承袭设备 ID 的认领**（推测，未实测，与协议 3 一致、不是本分支引入）：`note_new_peer` 的 KnownLog 分支对「本机已有
  它的日志」的设备按可信、不写信任行。协议 3 时代只经代传、从没登记过公钥的承袭设备 ID，能写同步位置的人可以用自己的
  钥匙在旧根放一份 v3 head 认领它（`oldroot_ingest` 里 `set_peer` 返回 `Inserted` → KnownLog → 可信），之后它以这个 ID
  写的承袭段里的删除与清除不被扣。新代原生段对承袭类设备有 `receive.rs` 的类型检查，走不通。前提是明文位置、承袭链可续写。
  可选收紧：只在有可信上传者背书时才走 KnownLog，其余按首见规则判。留给 C2 后续或同步安全 owner 拍。
- 旧根路径 `cmd/sync_oldroot.rs` 的 `rx.trust_changed()` 是兜底：KnownLog 不变量下不改变结果，删掉它相关测试全绿（复核变异
  M9）。注释已写明，接受它没有测试能证伪。

### 没做 / 归属别的模块

- 迁移本身（`dryrun.rs` 重建）不执行清除，见上。
- Dart 侧没接 `scrub_state`（没有 UI 提示），归 G7-6，见上「封存旧库」节的任务清单。
- Dart：`srs_purge_test`、`srs_devices_test`、`srs_db_store_test` 等的复跑结果见 PR 描述。
- 清除确认处的封存库说明与 `scrub_state` 出错提示已写成规划 §6 的合并条件（G7-6 不带上这两项不合入 develop）。
- 导出流带不走空洞内部的链值记号（见「转发里的副本」节的代价），要补需导出格式升 `ver`，归 G11 owner（第四轮复核确认属实、
  维持登记）。
- 重切件里空洞之前的操作只由重切者担保（见「转发里的副本」节的更正与残余风险）：根治要空洞带被挖掉操作的信封与载荷哈希、
  清除前存下这两样，需要 SCHEMA 号，归同步安全 owner。

## 34. 第四波 G10-4 host 目录与信任（2026-11-17，分支 `pr/srs-gen4-g10-4-host-directory`，基于 `pr/srs-gen4-switch` 9ad57c71096）

收口 §10「没做」的 `profile_of_dir`、§23「没做」第 3、4 条、§24「已知」的 `server_backup` 与「每 profile 一个库目录」。
Rust `SCHEMA` 没升（没加表 / 索引，分到的 40025 没用）；ABI 不变（多一条 JSON 命令）。

### 规划与现状不符处（以代码为准）

- 规划 §2.2 只写了「G10-4 host 目录与信任 ← G9-5、G8-7」，没有条目细则；设计稿 §8 G10 行写的「服务端设备信任（#3294）接到
  新表」只成立一半：admin `GET/POST /api/admin/srs/devices[/trust]` → `srsSetDeviceTrust` → 内核 `trust`（新代
  `cmd/writes_local.rs`，S1 已接线）、派生层按信任扣删除（`weigh.rs` `distrusted`）都在，但**没有任何写者会把设备记成待确认**：
  协议 3 的「首次信任」（`store/sync2/trust.rs` `note_new_device`，BUG-4306）没移进新代，gen4 `plan` 记下新对端公钥时不判信任，
  所以所有设备一律可信、服务端直接应用陌生设备的删除。`admin_srs_device_trust_test.dart` 里 3 条在 `pr/srs-gen4-switch` 上本来就是红的
  （删除没被扣住），就是这个缺口。本块补上（见「实现」最后一条）。
- §10 写「`collections.dir` 没有索引，需要时加索引（升 schema）」：一台设备的 `collections` 只有几行，`profile_of_dir` 全表扫，
  **不加索引、不升 SCHEMA**。
- 「host 目录」在 app 侧没有按目录名找 profile 的读法：`srs_app_runtime.dart` 的 `_onHostClientWrite` 只叫醒本机目录的整轮同步，
  补充名按设备记；按目录名当 uid 读的只有无头服务端（`server_srs.dart` 的 `onClientWrite` / `onClientUpload`，以及
  `_reconcile` 取名字 / 笔记数），本块改的就是这三处。

### 实现

- **内核 `profile_of_dir`**（`cmd/identity.rs`，不针对单个 profile 的读，`dispatch.rs` 全局臂）：请求 `{dir}`，回
  `{profiles: [uid…]}`——当前**绑定**的位置目录名等于 `dir` 的本机 profile（`Truth::profiles_of_dir`，按 uid 排）。`dir` 来自对端
  写入的路径，不可信：缺、不是字符串、空、`.` / `..`、含 `/` `\`、超过 255 字节（`DIR_MAX`）一律报错（`profile_of_dir: bad dir` /
  `dir must be a string` / `missing dir`），不回空表，调用方据此区分「坏路径」与「没人绑这个目录」。位置目录名的判据与
  `joined4` 同一份（`gen4/location.rs` `dir_name_ok` 改成 `pub(crate)`）。
- **engine**（`srs_host_directory.dart`）：`srsHostPathProfile` 改名 `srsHostPathDir`（它取的一直是目录名，不是 uid；空段 / `.` / `..`
  回 null）；新 `srsHostProfilesOfDir(core, dir)`（后台 isolate 发 `profile_of_dir`，回包形状不对抛 `FormatException`）。
- **服务端**（`server_srs.dart`）：
  - `onClientWrite` 按绑定反查（`_servedProfilesOfDir`：库目录开着才查；内核拒绝坏目录名记诊断日志、当作不属于任何 profile；
    只叫醒在提供中的 profile）。改成返回 `Future<List<String>>`（排了同步的 uid，测试用），`headless_host.dart` 包一层 `unawaited`。
  - `onClientUpload`（补充名）：同样按绑定反查，只给落在提供中的 profile 绑定目录里的段补；补充名按设备记（内核 `device_hint`
    不分集合），去重键从 `uid/device` 改成 `device`。
  - `_reconcile` 的名字 / 笔记数：库开着按 `srsLocationDir`（`identity` 的 `dir`）取同步目录里的说明；库没开时仍按配置里的 uid——
    D32：管理员勾的就是同步目录名，第一次 `identity` 绑的也是它。
- **整机备份与迁移互斥**（§24「已知」第 2 条）：迁移进行中库没开、`srs4.db` 不存在，提交点又会改名出 `srs4.db` 并原位封存
  `srs.db`——中途拷出来的包可能只有封存的旧库、没有新库。`ServerSrs.holdForBackup()`：迁移在跑回 null（admin
  `POST /api/admin/backups` 回 409 `srs_migration_running`）；否则给一个占位（`ServerSrsBackupHold`，`release` 只生效一次），持有期间
  `_beginMigration` 不开始、记「推迟」，管理员手动开始回 409 `srs_backup_running`；最后一个占位放开时有推迟就重新套用配置一次。
  `server_backup.dart` 另把换代过程文件（`srs4.db-migrating`、`srs4.db-creating`、`srs.db-gen4-prepare` 及其 `-wal/-shm/-journal`）
  排除出包：只在迁移中或被杀后存在，还原回来也只是要清的垃圾。复习关着（没有 `ServerSrs`）不占位。
- **远程复习客户端内置笔记类型**（§23「没做」第 3 条）：`SrsRemoteWire.noteTypesFrom` 的参数从 profile uid 改成主机信封里的
  `SrsRemoteRootIds`，内置类型的代码默认值（字段 / 模板 ID）由 `ids.lapis` / `ids.fushi` 派生（新 `srsBuiltinNoteTypeIn(nt, spec)`，
  `srsBuiltinNoteType(uid, spec)` 改为转调它）。信封没带某种内置类型的 ID 时报线格式错，不退回按 uid 派生。G9-7 之后
  `SrsKernelIds(uid)` 的内置 ID 与 uid 无关，所以这是口径收口（客户端不再拿主机 uid 派生任何 ID），不是行为修复。
- **首次信任**（内核 `cmd/sync.rs`）：`plan` 里 `Truth::set_peer` 回 `PeerPut::Inserted`（第一次见到这台设备的公钥）时调新
  `note_new_peer`：本机集合已有用户数据（新 `reads::collection_has_user_data`，与 `has_user_data` 读同一判据，内置默认牌组 / 笔记类型
  按规范 ID 不算）就设 `TRUST_PENDING`；库还空（全新设备第一次同步、服务端刚开始提供）直接可信。`Updated` / `Same` 不动信任，
  冒名（`KeyMismatch`）照旧报错跳过。迁移带来的（`carry.rs`）、导入随备份记的（`import.rs`）不经这里。没加表，`SCHEMA` 不变。
  （复核后改：身份承接、旧根设备也过首次信任、判空算等待缓冲，见下「复核修复」。）

### 每 profile 一个库目录（评估，本块不做）

§24 提出「多 profile 逐个迁、单个失败不影响其余」要每 profile 一个库目录。评估结论：**不改布局，保留一个 `<support>` 一份
`srs4.db`**。理由：

1. 迁移是「一份协议 3 `srs.db` → 一份新代库」整目录一次提交（对拍、封存、提交点都按文件）。按 profile 拆要内核新增「只迁旧库里
   某几个 profile 到另一个目录」的能力，封存语义也要改（一份旧库被拆成几次迁，什么时候封？封了之后没迁的 profile 怎么办），
   这是 G7-2 级别的改动，不是服务端布局能单独做的。
2. 唯一会拦下整个目录的 profile 级原因是 `mergeHalfDone`（半截并入），G9-5 已经让迁移带过去、由 `profile_merge_commit` 收尾
   （§20「半截并入」），剩下的拦截原因（空间、锁、对拍）本来就是整库的。隔离的收益很小。
3. 代价面大：整机备份格式（v2 刚定，G11-4）、还原、`snapshotFn`、`profile_of_dir`（要遍历 N 个库）、AnkiConnect / 制卡按 profile
   取库、app 侧 `SrsStorage` 单例都要改，而且是又一次存储布局换代。
如果以后真的需要，先做内核「按 profile 子集迁移 + 分库」，服务端布局随后。

### 测试

- Rust `cmd/identity_tests.rs` 2 条（经 C ABI）：`profile_of_dir_follows_the_binding_not_the_uid`（没绑过的目录空表；认领到
  `zz-remote` 的 R 只在那个目录下、不在 R 的 uid 下；大小写不同不算同一个目录；`collection_join` 改绑后跟着新目录走；Secondary
  只读也能查）、`profile_of_dir_refuses_untrusted_dir_names`（缺 / 非字符串 4 种 / 空 / `.` / `..` / `a/b` / `a\b` / `../uid` / 256 字节
  一律报错，255 字节可用）。
- engine `srs_v4_layout_names_test.dart` 新 1 条：空段、`.`、`..`、别的命名空间不是任何目录。
- 服务端 `server_srs_test.dart`：原「已配对设备写进来的文件只叫醒对应那份 profile」改成 await 回值；新 1 条「写入按绑定的位置目录
  找 profile」（两份 profile 各叫醒自己；kJa `collection_join` 到 `0000-home` 后那个目录叫醒 kJa、kJa 的 uid 目录不再算它；补充名
  只落绑定目录里的段；超长目录名（内核拒绝）、空段、`..`、`.`、别的命名空间不叫醒；管理员不再提供的 profile 不叫醒）。
- 服务端 `server_srs_migration_test.dart` 新 1 条：备份占位期间自动判定与手动开始都不迁移（`srs_backup_running`）、放开后接着迁、
  重复放开只算一次、迁移中拿不到占位、没有推迟就不因放开重跑。
- 服务端 `admin_srs_device_trust_test.dart`「参数与拒绝原因」补：不是设备 ID 的串（`../uid`、500 字符）点名 profile 回 404
  `device_unknown`，空白回 400。
- engine `srs_remote_store_test.dart`「线格式还原的视图与主机上读到的相同」改用主机根 ID：经线格式还原的内置 Lapis 与主机
  `noteTypes()` 里的逐字段相同；对调两种内置类型的根 ID 后物化出的不同（证明默认值来自给的 ID）。
- Rust 首次信任：`sync_tests.rs` 新 `first_sight_of_a_device_is_pending_only_when_the_library_has_data`（空库见到的设备可信；有数据的库见到
  的设备待确认，`trust` 后可信、再同步不回待确认；第三台新设备照样待确认）。改了口径的两条旧测试补显式确认：
  `sync_relay_tests.rs` `a_device_on_two_locations_relays_between_them`（b 先断言 c 待确认再 `trust`，否则不转发 c 的段）、
  `sync_complete_tests.rs` `old_root_takeover_reaches_migrated_and_new_devices_alike`（b 有数据，先确认 a 再收 a 上传的承袭段）。
- 服务端 `admin_srs_device_trust_test.dart` 原有 3 条（待确认设备的删除被扣住 / 确认后放行 / 拒绝）在基线上红，首次信任补上后转绿。
- 变异实测（去掉修复 → 红，复原 → 绿）：`note_new_peer` 调用换成空臂 → 首次信任、中继、旧根接手 3 条红；
  `profile_of_dir` 去掉目录名校验 → `profile_of_dir_refuses_untrusted_dir_names` 红；`onClientWrite` 改回「目录名当 uid」→
  「写入按绑定的位置目录找 profile」红；`_beginMigration` 去掉占位判断 → 「整机备份与迁移互斥」红；`_builtinOf` 改回
  `srsBuiltinNoteType(uid, spec)` → 「线格式还原的视图与主机上读到的相同」红。复原后 cargo 定向 5 条、服务端 3 个文件 28 条、
  engine 2 个文件 35 条全绿。

### 没做 / 交给谁

- admin `POST /api/admin/backups` 的 409 `srs_migration_running` 只有 `ServerSrs` 层的测试（占位语义），没有经 AdminBackups +
  真 HeadlessHost 的端到端测试（要让真 HeadlessHost 停在迁移中，没有现成接缝）。
- 离线 `fushi_server backup create`（serve 不在跑）不经 `ServerSrs`，不占位；那时没有本进程迁移，别的进程迁移被数据目录锁挡住。
- 同步目录的 profile 列表（`srsListRemoteProfiles`，WebUI 勾选列表）仍只读 `v3/devices/*/profile.json`；规划 §1.1 G-6 定的
  `v4/devices/<dev>/profile.json` 现在没有写者（`srsPublishProfileInfo` 仍写 `v3/devices`），读者跟着写者一起改，归 G9-5 续
  （§21「没做」的关联流程改走 `v4/meta.json`）。新代全新集合在 WebUI 里因此只显示目录名、没有名字与笔记数估计。
- D32「服务端保留副本 14 天自动删 + ctl 提前删」仍没做（§24 已记，要内核删保留副本的全局命令）。

### 复核修复（2026-11-17，同分支）

- **首次信任按签名钥匙承接身份**（blocker）。原实现只按设备 ID 判「第一次见到」，而迁移强制换新设备 ID、钥匙沿用（`dryrun.rs`
  `new_self`、`carry.rs`），`rotate` 同样换 ID 沿用钥匙：每个多设备用户升级后，自家设备在有数据的对端上全部变成待确认，无头服务端
  上所有客户端也都待确认，删除被扣、承袭段被 Deferred、中继不转发。现 `note_new_peer(t, col, device, public, prev, seen_at)`：
  1. 钥匙是本机自己的（本机旧身份、协议 3 时期的本机）→ 可信；
  2. 钥匙与已在册的别的设备相同（新 `Truth::peers_with_key`，`peers` 按集合扫，几行）→ 沿用前身的信任：head 自报的 `prev` 在这些
     设备里就取它的，否则取其中最不受信的（只往待确认偏）；
  3. 否则按原判据（库有数据 → 待确认）。
  **定案**：只认钥匙、不单凭自报的 `prev` 承接——`prev` 是对端随便写的字段，钥匙要签名才有（`Head4::decode` / 协议 3
  `Head::decode` 都验签）；同钥匙就是同一台设备，不必再核 `prev` 的链。复核建议里的「或 prev 的链已核对过」这一支没做：钥匙不同时
  核 `prev.chain` 只能证明对端知道旧链值（链值写在公开的 head 上），证明不了身份。
- **旧根上的协议 3 设备也过首次信任**（major）。`oldroot_ingest` 原来对 `set_peer` 的 `Inserted` 不判信任，`Receiver::legacy` 又不看
  信任，任何能写同步位置的人在 `v3/devices/<新ID>/` 放自签 head + 段，它的删除 / 清除就按可信执行，比协议 3 还宽。原注释「旧根设备
  按上传者信任收（D20）」不成立：D20 管的是新代设备上传的 `hrt-` 承袭段，`oldroot_ingest` 是本机直接读 v3 段。现 `Inserted` 时同样调
  `note_new_peer`（`prev` 为空、`since` 取 v3 head 的 `at_ms`）；迁移带来的 v3 设备回 `Same` 不受影响，本机自己的协议 3 旧身份按
  钥匙认成本机。
- **判空算上等待缓冲**（minor，推测缺口）：`has_user_data` 新增 `has_buffered`，集合内各设备主键区间在 `op_wait` / `op_pending` 有行就算
  「有」（协议 3 BUG-4478 同类：已收下、未投递的也是要应用的数据）。同一判据也被 `SrsDbStore.hasUserData`（profile 关联）用，
  只往「有」偏，不会丢数据。
- **`since` 改用 head 的写出时刻**（minor）：与协议 3 `note_new_device` 的 `seen_at` 同口径（同步页「首次出现」）。值来自对端，只用于显示。
- **越界说明**（nit）：规划 §2.3 把 `packages/fushi_server/lib/src/backup/server_backup.dart` 划给 G11-4 独改。本块为「迁移进行中
  备份要拒绝或等待」改了它一处（把换代过程文件 `srs4.db-migrating` / `srs4.db-creating` / `srs.db-gen4-prepare` 及其 `-wal/-shm/-journal`
  排除出包，文件名与 `files.rs` 的 `GEN4_TEMP` / `GEN4_CREATING` / `PREPARE_COPY` 已核对一致），因为任务书把这件事交给了 G10-4、
  而只靠 `ServerSrs` 占位挡不住「被杀后残留的过程文件被打进包」。**G11-4 合并时注意这处冲突**，保留排除表即可。
- 复核说两条旧测试补的显式 `trust` 「盖住了回归」：核过，`a_device_on_two_locations_relays_between_them` 的 c、
  `old_root_takeover_reaches_migrated_and_new_devices_alike` 的 a 都是全新安装、与对端不同钥匙的另一台设备，在有数据的库上待确认是
  正确口径，显式确认保留；真正被盖住的「迁移 / 换身份后的自家设备」由下面新测试覆盖。

测试（Rust，经 C ABI）：

- `sync_tests.rs` `a_new_identity_on_the_same_key_inherits_trust`：a 连续三次 `rotate`，b 上新 ID 依次沿用前身的待确认 / 拒绝 /
  受信（最后一次同钥匙旧身份里有待确认与拒绝的，按自报 `prev` 取受信的）；陌生钥匙自报 `prev` 指向受信设备仍待确认，`since` 是给的
  写出时刻。
- `sync_tests.rs` `two_migrated_devices_keep_trusting_each_other`：两台协议 3 设备互信后各自真迁移（`gen4_migrate_run`，新 ID），在新根
  上互相同步：彼此仍可信、写入互相收到。辅助 `dispatch_tests.rs` 抽出 `migrate_legacy`（`migrated_prepared` 改为调它）。
- `sync_complete_tests.rs` `an_unknown_old_root_device_is_pending_on_a_library_with_data`：有数据的库捡到陌生 OLD（含一条清除）→
  待确认、`heldPurges` = 1，确认后可信；全新库捡同一个旧根 → 可信。辅助 `old_root` 抽出 `old_root_ops`（自带操作）。
- `receive.rs` `ops_still_waiting_count_as_user_data`：只有等待缓冲里的操作时 `collection_has_user_data` 为真。
- 变异实测：承接去掉（`same_key` 恒空）→ 前两条红；`oldroot_ingest` 的 `note_new_peer` 换空臂 → 旧根那条红；去掉 `has_buffered` →
  等待缓冲那条红；`plan` 传 `now` 代替 `h.at_ms` → `first_sight_of_a_device_is_pending_only_when_the_library_has_data`（补了
  `since` = 对端写 head 的时刻的断言）红；复原后工作区干净、相关 8 条全绿，`cargo test --profile quick --lib -j 4` 全量 1320 过。

### 第二次复核修复（第三轮，2026-11-18，同分支；提交 `dffeeae986`、`6251f850e9` 与本节同提交的测试 / 文档）

上面「复核修复」第 1 条（钥匙承接：本机钥匙可信、`peers_with_key`、同钥匙取最不受信）与第 3 条（`has_buffered`）的**实现已被替换**，
以本节为准。

- **首次信任并入 K2 的单一实现**。K2（`pr/srs-gen4-k2-trust-purge`）同时在改首见信任，为不两边各写一份，删掉 G10-4 自己的
  `cmd/sync.rs` `note_new_peer`、`Truth::peers_with_key`、`reads::collection_has_user_data` / `has_buffered` 及重复测试，改用 K2 的
  `truth/trust.rs` `Truth::note_new_peer` / `library_fresh`（判定顺序：本机已有它的日志 → 不追溯；`prev` + 同一把钥匙 → 原样承接；
  库空 → 首次信任；否则待确认）。口径差异：同钥匙但不带 `prev`（或 `prev` 指向别的钥匙的设备）**不承接**、当新设备判。定案理由：
  迁移与 `rotate` 写的新 head 都带 `prev`，诚实路径都能承接；不带 `prev` 的同钥匙新身份最多拿到「待确认」，不会比换一把新钥匙
  更宽（对方随时能换钥匙），所以原先「同钥匙取最不受信」那支没有安全价值，不保留。
- **承袭段只替本机信任的作者上传**（复核 major）。D20 收承袭段只看上传者信不信，段里各作者在收方没有信任行（= 可信），收方之后
  在旧根上见到这位作者也按「本机已有它的日志」不追溯——所以首次信任只挡住了读旧根的那一台。现 `inherit.rs` 新
  `vouches_for(t, col, dev)`：作者在本机有待确认 / 已拒绝的信任行时，`Uploader::open` 不替它切段、`cmd/sync_oldroot.rs`
  `heritage_logs`（承袭对账指纹）也不含它；本机确认之后指纹变、下一轮照常补传。别的设备拿不到它就自己捡旧根、自己读它的 head、
  自己做首次信任，待确认作者的清除在那边同样扣住。选这一支（复核建议 a）而不是让收方对承袭来的作者也做首次信任（建议 b）：b 要
  承袭段带作者公钥或先从旧根学 head，且会把**受信上传者已担保**的作者也回溯扣住（下一条 minor 的口径问题）。
  **残余**：本机改成不信任之前已经传上去的承袭段收不回（同新代原生段：信任是各设备本机的事）。
- **混合版本家庭不再把自家未升级设备记成待确认**（复核 minor 2）。经受信上传者承袭来的作者在收方已有日志，之后在旧根上第一次见到
  它的 head 走 `trust.rs` 第 1 条（`KnownLog`），不记待确认、清除不扣，与上传者 a 上的结果一致。
  **与协议 3 口径仍有的差异（不修，记在这里）**：一台协议 3 设备 OLD 如果**没有任何已升级设备担保过**（例如它是迁移之后才加入
  旧根的新设备、在库里有数据的已升级设备上本来就是待确认），全新设备 c 第一轮先收新根（库里就有了 a 的内容）、再捡旧根，OLD 在 c
  上也是待确认；协议 3 的全新设备第一轮会信任所有设备。这里与 a 上的状态一致、不丢数据、只多一次确认。要完全对齐协议 3 需要
  「本轮开始时库是空的」这种按轮记的判据，而旧根两条命令目前还没有 Dart 调用方（同步轮 2b 步未接线），等接线时由同步轮持有者
  决定要不要加。
- **身份承接边界补测试**（复核 minor 3）。复核变异的两支（本机钥匙恒可信、同钥匙取最不受信）随 K2 合一已不存在，按现口径补：
  - 本机迁移前的协议 3 旧身份在旧根上再见到：迁移已把它记进 `peers`（同钥匙），登记不是「第一次见到」，不判待确认。
  - 与在册设备同钥匙、不带 `prev` / `prev` 指向另一把钥匙的受信设备：不承接，库非空即待确认（前身已拒绝 / 待确认也不能换 ID 洗白，
    前身可信也不凭钥匙自动承接）。

**归 K2 文件的改动（由合流统一）**：

- `truth/trust.rs`：`library_fresh` 的空洞表多查 `op_wait`（等待缓冲里已收下的原生操作算内容）；文件头第 1 条补一句「前提是承袭段只带
  上传者自己信任的作者（`vouches_for`）」。其余与 K2 当前头（`003b61429f`）逐字节相同。
- `cmd/sync_trust_tests.rs`：`legacy_library` / `migrate_to` 改成 `pub(super)`（本块新测试复用），其余不动。
- `cmd/sync.rs`、`receive.rs`：本分支是 K2 较早版本的逐字节副本；K2 之后加了重切中继件（`FRX4`）等，**合流时取 K2 的**。
- `inherit.rs`（`vouches_for`、`Uploader::open`）与 `cmd/sync_oldroot.rs`（`heritage_logs`）归本块。

测试（Rust，经 C ABI 或真相层）：

- `cmd/sync_heritage_trust_tests.rs`（本块新文件）：
  - `a_purge_held_on_the_uploader_stays_held_on_other_devices`（拒绝路径）：a 上待确认的 OLD 不经承袭段上传，c 收不到它的任何操作，
    c 捡旧根自己判待确认、清除同样扣住；a 确认后下一轮补传。
  - `an_old_device_vouched_for_through_heritage_is_not_pending_later`：经受信 a 承袭来的 OLD 之后在旧根上写新段（含清除），c 不记待确认、
    清除不扣。
  - `the_own_protocol3_identity_seen_on_the_old_root_is_not_pending`、`a_same_key_identity_without_a_matching_prev_is_judged_as_new`：上面 minor 3。
- `inherit_tests.rs` `an_author_this_device_does_not_trust_is_not_uploaded`：`Uploader` 本身不替待确认的作者切段（不靠同步轮指纹）。
- 两条旧根接手测试改为先确认 OLD 再上传（`sync_complete_tests.rs`）。

变异实测（改完跑、看红、`git restore` 复原）：

- `vouches_for` 去掉信任条件 → `store::gen4` 596 条里 4 条红（上面拒绝路径、`an_author_this_device_does_not_trust_is_not_uploaded`、
  `heritage_segments_count_toward_the_ingest_budget`、`old_root_takeover_reaches_migrated_and_new_devices_alike`），exit 101。
- `note_new_peer` 去掉「本机已有它的日志」 → `an_old_device_vouched_for_through_heritage_is_not_pending_later` 与 K2 的
  `note_new_peer_inherits_only_under_the_same_key` 红。
- 承接不核公钥（只要 `prev` 在册就承接） → `a_same_key_identity_without_a_matching_prev_is_judged_as_new` 与 K2 那条红。
- 本机旧身份：迁移有两处各自把它记进 `peers`（`carry.rs` 搬 `sync2_devices`、`create_self` 的 `own_peer(prev)`），单去一处测试仍绿
  （冗余，符合预期），两处一起去掉 → `the_own_protocol3_identity_seen_on_the_old_root_is_not_pending` 红。
- 复原后 `cargo fmt --check` exit 0；`cargo test --profile quick --lib -j 4 store::gen4` exit 0，596 passed、0 failed、7 ignored。

### 第三次复核修复（第四轮，2026-11-18，同分支；提交 `af6f224fb0`、`dd0f2a229c` 与本节同提交的文档）

上一节「混合版本家庭」一条的实现（`truth/trust.rs` 第 1 条「本机已有它的日志 → `KnownLog` 不追溯」）**已删**，以本节为准。

- **复核 major：经承袭段认识的旧作者可被换钥匙冒充**。`KnownLog` 只看「本机有没有它的日志」，不看它的公钥有没有受信方担保。
  承袭段原先不带作者公钥，收方 c 经承袭段收下 OLD 的日志后 `peers` 里没有 OLD 的钥匙；攻击者在旧根上拿另一把钥匙写 OLD 的
  head 与清除，`set_peer` 回 `Inserted`、走 `KnownLog` 判可信，冒充者签的段按它自报的钥匙验签通过，清除照执行（复核探针实测：
  c 上 applied=6、name=evil、没有 heldPurges）。新根 `plan` 收冒充 OLD 的 v4 head 同一条路，冒充者成了 c 上受信、认识钥匙的设备后
  还能当承袭段上传者过 D20。定案（复核建议的做法一 + 做法二都做）：
  - **承袭段头带作者公钥**（`gen4/heritage.rs`）：flags bit1 = 带 `author_key[32]`（紧跟 `uploader` 之后，在签名覆盖的头里）。
    上传者打段时带本机 `peers` 里记着的这位作者的公钥（`inherit.rs` `pack`；协议 3 里没有公钥的设备行不带）。不带时字节与原
    黄金向量完全相同（旧格式不变，`VERSION` 仍是 1）；`segment.rs` 新 `read_magic_flags` 让各格式声明自己认得的 flags 位，`FSG4`
    仍只认 bit0。**格式改动**：设计稿 §3.1 的段头布局没同步改，待设计稿持有者补一行（本块只改交接本节，不动设计稿）。
  - **收方登记、对不上整段拒**（`receive.rs` `vouched_author_key`）：承袭段验签、整段合规之后，本机还没记过作者公钥就按段头
    登记（不写信任行：上传者受信，它担保的作者可信，D20）；记着另一把 = 新拒绝 `Reject::AuthorKeyMismatch(设备)`，整段不落、
    不登记。`Uploader::see` 同口径（这样的段不算位置上有、本机照传）。登记之后旧根上 OLD 的 head 不再进 `oldroot_scan` 的
    `heads`（公钥已知），冒充者签的段按真公钥验签不过；新根上冒充的 head 在 `set_peer` 就是 `KeyMismatch`。
  - **首次信任删掉「本机已有日志」放行**（`truth/trust.rs`，归 K2 的文件）：公钥第一次登记一律按「`prev` + 同钥匙承接 → 库空首次
    信任 → 待确认」判。到这里还「已有日志」的只剩段头没带公钥的作者（上传者也不知道），它的公钥没有任何受信方担保，不能先到
    先得地变成可信。库里有它的日志就不是空库 → 待确认；`oldroot_ingest` 已按 `FirstSeen::wrote` 让派生层重判，它已落下的删除与
    清除随之扣住（与重建一致），用户确认后放行。**与协议 3 的差异**：协议 3 `trust_head` 给「有设备行、没公钥」补公钥时不判
    待确认；这里有意收紧——只多一次确认，不丢东西，已执行的清除不受影响。
  - **`plan` 拒绝冒用协议 3 作者 ID 的新根 head**（`cmd/sync.rs`）：本机有这台设备的日志、却从没记过它的公钥，只能是段头没带
    公钥的承袭作者；换代迁移给每台设备换新 ID，协议 4 的 head 不会用协议 3 的设备 ID，所以按冒名报错、不登记。这样 `plan`
    写下的待确认设备在本机仍一条操作都没有，`plan` 继续不动派生层。
  - 顺带效果：c 经承袭段学到 OLD 的公钥后，OLD 自己迁移出来的新身份（head 带 `prev = OLD`、同一把钥匙）在 c 上走「换身份继承」
    可信——上一轮复核 minor「混合版本家庭」那条因此由公钥承接解决，不再依赖 `KnownLog`。这一支没有单独的端到端测试（要两台
    协议 3 库各自迁移再互相同步，装置较重），靠 `note_new_peer_inherits_only_under_the_same_key`（K2）与本节的公钥登记测试组合覆盖。
  - **残余**：开发期别的构建已经传上位置、段头不带公钥的承袭段，收方照旧不登记公钥（该作者之后的 head 会判待确认）；gen4 没发布，
    不做迁移。上传者自己先被冒充者抢先登记了错误公钥的（它会把冒充者判待确认、不替它传），不在本条范围。
- **复核 minor：待确认作者不替传后「位置上原生操作依赖的承袭操作一定在位置上」被有意打破**。定案：`inherit.rs` 文件头写明旧根
  退役的前提——所有设备都捡完旧根，或每台设备上都没有待确认 / 已拒绝的承袭作者（确认了的下一轮补传）；在此之前不能清空、删除
  旧根。`cmd/sync_oldroot.rs` `heritage_plan` 回包（`skip` 与否都带）新增 `unvouched: [设备…]` = 本机有内容、因作者不受信而不替传
  的承袭日志，同步页据此提示用户先确认或拒绝。旧根命令目前仍没有 Dart 调用方，提示文案与接线交给同步轮持有者（G8-7 / G9-5）。

**归 K2 文件的改动（由合流统一）**：`truth/trust.rs` 删 `FirstSeen::KnownLog` 与第 1 条、文件头判定顺序重写；
`cmd/sync_trust_tests.rs` `note_new_peer_inherits_only_under_the_same_key` 末尾「本机已有它的日志 → KnownLog」一段删掉（拿本机身份
自己调 `note_new_peer` 的人造场景，新口径下没有意义，覆盖改由下面的端到端测试承担）；`cmd/sync.rs` `plan` 加上面的拒绝；
`receive.rs` 加 `vouched_author_key` 与 `Reject::AuthorKeyMismatch`。K2 若另改了这几处，合流时按本节语义合并，**不要**把 `KnownLog`
带回来。

测试（Rust）：

- `gen4/heritage.rs` `author_key_round_trips_under_the_signature`：带公钥的段头读回相同、改公钥一个字节验签失败、不认识的 flags 位仍按损坏。
- `receive.rs` `heritage_author_keys_are_registered_and_must_agree`：段头公钥登记、不写信任行；之后换钥匙的 `set_peer` 是
  `KeyMismatch`；另一上传者担保另一把 → `AuthorKeyMismatch`、一条不落；同一把或不带照收；增量 == 重建。
- `inherit_tests.rs` `coverage_vouching_another_author_key_does_not_count`：位置上担保另一把的段不算有、本机照传；本机打的段头带
  本机记着的作者公钥；同一把照常算。
- `cmd/sync_heritage_trust_tests.rs`（经 C ABI）：
  - `an_impostor_cannot_take_over_an_author_known_through_heritage`（复核 major 的原场景，拒绝路径）：c 经 a 的承袭段认识 OLD 后，
    攻击者用 0xee 冒充 OLD 换掉旧根 head、写 4..=6（最后一条彻底清除）：c 与 a 上都一条不落（`BadSignature`）、名字不变、没有
    trust 行与 heldPurges，`applied` 仍是 3。
  - `a_heritage_author_without_a_vouched_key_is_judged_when_its_head_first_arrives`：段头不带公钥时，新根上冒用 OLD ID 的 head 被
    `plan` 按冒名拒、不登记；旧根上的冒充 head 第一次登记 OLD 的公钥 → 待确认，清除扣住（heldPurges=1）。
  - `a_purge_held_on_the_uploader_stays_held_on_other_devices` 补断言：a 上 `heritage_plan` 的 `unvouched` 列出待确认的 OLD，确认后为空。
  - `an_old_device_vouched_for_through_heritage_is_not_pending_later` 改断言：c 已从段头认识 OLD 的公钥，`oldroot_scan` 不再读它的
    head（`heads` 为空），新段照收、可信、清除不扣。
- `sync_complete_tests.rs`：`old_root_with` 拆出 `old_root_signed`（指定签名钥匙与名字），原调用不变。

变异实测（改完跑、看红、复原；复原后 `git status` 干净）：

| 变异 | 结果 |
|---|---|
| M1 `pack` 段头不带作者公钥 | 定向 44 条里 3 条红（impostor、vouched…not_pending_later、without_a_vouched_key），`inherit` 模块另 1 条红（coverage_vouching…） |
| M2 收段不登记作者公钥 | 3 条红（含 `heritage_author_keys_are_registered_and_must_agree`、impostor） |
| M3 收段公钥对不上也收 | `heritage_author_keys_are_registered_and_must_agree` 红 |
| M4 恢复「已有日志 → 放行」 | `a_heritage_author_without_a_vouched_key_is_judged_when_its_head_first_arrives` 红 |
| M5 `plan` 不拒冒用协议 3 ID 的 head | 同上一条红 |
| M6 `unvouched` 恒空 | `a_purge_held_on_the_uploader_stays_held_on_other_devices` 红 |
| M7 `Uploader::see` 不核作者公钥 | `coverage_vouching_another_author_key_does_not_count` 红 |
| M8 读段头不认 bit1 / M9 写段头不写公钥字节 | `author_key_round_trips_under_the_signature` 红 |

全部 exit 101；复原后 `cargo fmt --check` exit 0，`cargo test --profile quick --lib -j 4` 全量 exit 0：1335 passed、0 failed、39 ignored（都是已有的 ignore）。

## 35. 第四波 G9-5 续：profile 关联流程与并入相关测试（2026-11-17，分支 `pr/srs-gen4-g9-5d-link-flow`，基于 `pr/srs-gen4-switch` `9ad57c7109`）

### 关联流程改走 `collection_adopt`（`packages/fushi_engine/lib/srs/srs_profile_link.dart`）

- **不再改 profile uid**：`SrsDbProfileLinker` 的自动认领（`link` 判成 `SrsProfileLinkAdopt`）与用户选定（`adopt`）都调内核
  `collection_adopt {collection, dir, confirmed: true, now}`；`_switchUid`、`_retireV2Device`、对 `srsAdoptProfileUid` 的调用删了，
  也不再抛 `SrsProfileMergeRemoved`（本机有数据照样能选，按 D27 并入）。`srsAdoptProfileUid` 本身留着只因冻结的协议 1 客户端
  副本 `test/srs/sync2/v1_client/srs_profile_link.dart` 还 import 它（随 G7-6 删那份副本时一起删）。
- **按 `meta.json` 认集合**：`srsListRemoteProfiles` 给每个 `fushi-srs/<目录>/` 读 `v4/meta.json` 的 `collection`（没有新根退到
  旧根 `v3/meta.json`），记进 `SrsRemoteProfile.collection`；`uid` 字段现在是**位置目录名**（字段名沿用）。外来文件按
  `kSrsLocationJsonMaxBytes`（64 KiB）卡大小。
- **判定**（`srsDecideProfileLink` 新增 `ownCollection` / `joined`）：`localUid` 传本机集合的 `dir`；集合标识等于本机的、在本机
  `collection_info.joins` 里的（已经并进来的）、读不出集合标识的（没立过根，认领不了）目录都不算候选。其余规则（有数据交给
  用户选、双方都空按目录名只让大的一边认领、`settled` 不再自动认领）照旧。认领目标若已绑在本机另一个 profile 上
  （`collections.collection` 唯一）：自动路径保持、选定路径抛 `StateError`，都不改任何东西。
- **认领之后收拾位置**（`_adoptCollection`）：`bound` / `joined` 且 `rebound`（本机离开了原目录）→ 删本机在原目录里的说明
  文件目录（`v3/devices/<本机>`）；新代设备目录 `v4/devices/<本机>` 只在原集合里没有别的设备时才删（有的话它们跟过来之前还要
  从那里收本机之前的段）；`v4/` 根永远留着（§21）。`joined` 没改绑（对方并进本机）→ 在对方目录里放**并入提示**（下条）。
  收拾失败只记日志（认领已在内核提交）。`srsPublishProfileInfo` / `srsRemoveOwnProfileFolder` 加 `dir` 参数：说明文件写进
  `identity` 的 `dir`，不再按 uid 拼。
- **调度器**：`SrsProfileLinkOutcome` 加 `changed`；新代认领不换 store 对象，`SrsSyncScheduler._link` 在 `changed` 且对象没换时
  直接通知界面重读（原来只靠比对象身份）。

### 定案：D27 吸收方向的发现机制（所有者授权自定）

问题（§21「没做」）：本机目录名小、对方并进本机时，`Join{from: 对方}` 写在本机集合的日志里、发在本机目录的 `v4/` 根；对方
集合的设备只读自己目录的根，看不到它，也就永远不跟过来（而且对方集合里有别的设备时，旧判定按「已关联」直接保持，连候选都
不列）。按设计稿 §5.4 第 3 条（「B 的根里留一个指向 A 的提示，放独立文件、不进 meta.json」「不凭提示自动跟随」「跟随前再问
一次用户」D25）定案：

1. 吸收的一方在被并入方的目录里写 `fushi-srs/<对方目录>/joined-into-<本机集合标识>.json`
   （`{"v":1,"collection":<本机集合>,"dir":<本机目录>}`，`srsWriteJoinHint`）。放在集合目录这一级、不在 `v4/` 里：同步一轮只读
   `v4/` / `v3/` / `v2/`，列 profile 时只认文件夹，旧版本不受影响；`srsRemoveOwnProfileFolder` 把它算成「别人的东西」，有它就
   不删那个目录。内容只由两个集合标识决定，几台设备各写一次结果相同。
2. 被并入方的设备每次关联时读自己目录里的提示；提示指向的目录在位置上、`meta.json` 的集合标识与提示一致、目录名比自己小、
   不是本机集合也没并进来过，就把它当候选交给用户**再确认一次**——**不看「已关联」**（`srsDecideProfileLink` 里提示先于
   `linked` 判）。用户确认后照常 `collection_adopt`，本机目录名大 → 按 D27 改绑过去，收敛。
3. 提示没有签名：伪造它最多让对方多弹一次确认，跟不跟由用户定；设计稿里「依据受信设备签名的 `Join`」这一步没做——对方
   设备通常从没见过吸收方的设备，谈不上信任，用户确认就是信任的来源。若要做，得让内核先读吸收方根里的 `Join` 再弹框（归 G10）。
4. 已知时效：调度器对「已关联」的位置在进程内只判一次（`_linkDecided` 不过期），被吸收方已经跑着的进程要到下次启动才看到
   提示。

### 发现：打开过的 profile 不是「空集合」（`bound` 换绑在 app 里走不到）

`SrsDbStore.open` → `ensureBuiltins` 把内置牌组 / 笔记类型写成本机日志里的身份记录，`discard.rs` `disposable` 只认「本机区间
全是 `Salts`」，所以任何经 `SrsDbStore` 打开过的 profile 认领别的集合都是 `joined`（D27 改绑、写一条 `Join`），§20 的「空集合
可换绑」只在内核直接建身份、没开过 store 的 profile 上成立（Rust 测试覆盖）。结果正确（内置记录是同一个规范 ID，随本机身份
带过去，不丢不重），只是多一条 `Join`、留一个没用的旧集合标识进 `join_ix`。要让 `bound` 生效得让 `disposable` 把「只有内置
实体身份记录」也算空——内核取舍，交 G9 身份模块，本分支没改。Dart 测试按「集合换了、旧集合标识不再绑着、只剩一个集合、
profile uid 不变」断言，不分 `bound` / `joined`。

### 删掉的死路径

`ensureMigrated` 与「迁移前只拉不发」：`srs_sync_scheduler.dart` 的 `ensureMigrated` / `pullInto` / `pullBeforeMerge` / `_migrations` /
`_SrsMigrateScope` 与构造参数 `migratePullBound` / `mergePullBound` / `pullTimer`；`SrsDbStore.migrateLegacy` / `sync2Migrated` /
`kSrsSync2MigrateBatch`；linker 的 `pullBeforeMerge` 参数与 app 装配（`srs_app_runtime.dart`）；整个
`packages/fushi_engine/lib/srs/sync2/srs_sync2_pull_first.dart`（`srsSync2PullOnly` / `srsSync2PullBounded` / `SrsPullBound` …）及其
测试 `srs_sync2_pull_progress_test.dart`、`fushi/test/srs/srs_pull_before_migrate_test.dart`。

### 合流后新冒的红：`srs_profile_ownership_test`「自己的 ID：照常生效 sync2Purge 笔记」

根因：测试拿 `status.ops`（日志里还带内容的操作行数）数「写没写操作」；G8-7b 起彻底清除在同一事务里把被清除实体的旧操作落成
空洞（`weigh.rs` `execute_purges` → `Truth::advance_purge`），清除一条笔记追加「删除 + 清除」两条、空洞掉更早的四条，行数从 26 降到
24。产品行为正确，是度量错了：改数本机日志长度（`status.nextSeq − 1`）。78 条全绿。

### 测试（本分支改的 / 新增的）

- `srs_profile_link_sync_test`（7 → 8 条）：断言改成「同一个集合、同一个目录、profile uid 不变」；B 并入 A 用 `adopt(.., within:)`；
  旧目录断言改成「不再列着本机这个写入者」（`v4/` 根按 §21 留着）；新增「A 吸收 B：B 的设备（已关联）经并入提示再确认一次，确认后
  三台收敛到 A」。变异实测：去掉 `joined` 过滤 → 该条红在「已经并进 A 的集合不再算候选」；去掉提示判定（`srsDecideProfileLink` 里 `hinted` 不再返回 `Choose`）→ 该条红在「b：提示指向的 A 交给用户确认」（`Actual: <null>`）；还原后全绿（44 条，与本组其余四个文件同跑）。
- `srs_profile_adopt_user_data_test`、`srs_collection_binding_test`：同口径改断言；`rows('sync2_ops')` 那条改成数新代 `collections`。
- `srs_profile_purge_single_test`：协议 3 的「采用删旧 uid / 在途写入 / 回退」三条按新代重写（认领后旧集合标识不再绑着、只剩一个
  集合、主库 uid 不变；与在途写入交错写下的笔记都在；目标是本机另一个 profile 的集合则拒绝、什么都不动）。
- `fushi/test/srs/srs_limit_unit_legacy_count_test`（⑥）：W3 改成 `.fushisrs` 导入，不是生产上「只同步进来旧日志」的路；改回两台设备
  经同一个位置跑同步一轮。协议 3 的前提「只并入日志不推进内容指纹」在新代不成立（收段后内容指纹的修订段推进，实测 `…:5 → …:6`），
  不再断言；回归由结果钉住（合并前缓存了 0、合并后必须 1）。变异实测：把 `srs_providers.dart` 里提醒计数 provider 的缓存键
  （`contentFingerprint|rwkvScoresKey`）换成常量 → 红在 `Expected: <1>`；还原后 1 条绿、工作区干净。

### 没做 / 交出去

- **BUG-4626 在新代的并入场景是真红（交 G9 身份 / 设计拍板）**：同库 A、B 两份 profile，A 拿 B 的笔记 / 卡片 ID 改字段、标签、
  旗标、暂停（新代不在追加前拒绝，落成 A 集合里的悬空操作，B 当时看不到），之后另一台设备上的 B 经 `.fushisrs`
  （`srsExportFushiSrs` → `srsImportFushiSrs`，用户确认）把 A 的集合并进来 → **B 的笔记字段变成 A 写的值**
  （`Expected: '鳥'` / `Actual: '被 A 改'`）。设计稿 §2「ID 不再按 uid 加盐、并入 = 操作并集」下这是按设计并集的结果，还是该
  让并入方丢掉「改的是本集合当时不存在的实体」的操作，属于语义取舍，本分支不定、不改内核。复现测试没提交（不提交红）：
  写法是上面这一段，同库两份 store 用 `openTestSrsStorage` + `SrsFakeEngine`，B 的数据先经 `.fushisrs` 导到 `dev-remote` 上的 B，
  再导 A 的。
- ③ 余项没做：`srs_write_statement_cost_test` 第 1 条与 `bulk_ops_roundtrips` / `equivalence` 里依赖 `applyRemote` 外来已盖戳事件
  的步骤改走集合并入；`dumpSrsState.serverTimes` 维度的变异测试。
- ⑤ 没做（G11-4 遗留）：覆盖恢复后同集合多 profile 只有第一个重绑（`srs_backup_merge.dart:349`）、覆盖恢复后第一次合并把同一批
  旧事件输入落两遍。分析：新代 `collections.profile_uid` / `collection` 都唯一，两个不同 uid 的本机 profile 不能绑同一个集合，
  「同一单位多个 profile」只可能是共用 uid 的情形，要先在 G11-4 的备份格式里确认这种输入是否还存在再定修法。
- `SrsDeferredProfileMerge` / `SrsProfileAdoptDeferred` 还留着（调度器与界面仍引用）；`srsAdoptProfileUid` 随 G7-6 删。
- 本机目录名小、本机为空时只能等对方设备跟过来（对方按提示确认）；本机这边不主动做什么。

### 复核修复（2026-11-17 第三轮，同分支，针对 `4f609737fc`）

- **新代集合永远判成「已关联」，关联在生产路径上根本不发生（新发现，major）**：新代每轮立旧根围栏时在
  `v3/devices/<墓碑设备>/` 写墓碑 head（内核 `gen4/location.rs` `tombstone_device` = `v5(NS, "fushi-srs/tombstone/4/<dir>")`），
  `srsListRemoteProfiles` 把它当成写入者 `v2:<墓碑>`，于是每个新代集合都「有别的设备」→ `srsDecideProfileLink` 返回
  `Keep(linked)`，空设备不自动认领、两边有数据也不弹冲突。本组测试一直没看出来，因为它们的 `_round` 直接调
  `srsSync2Round` 且把旧根 `v3/` 当新根用（不传 `oldRoot`，不立围栏）。修复：`srsTombstoneDevice(dir)`，列 profile 时跳过它；
  `srs_profile_link_sync_test` / `srs_collection_binding_test` / `srs_profile_adopt_user_data_test` 的一轮同步改走生产入口
  `srsRunLocationRound`。变异实测：去掉跳过 → 3 条红（自动认领、候选、用户选定），还原后 20 条绿。
- **互联 host 上用户选定候选必然失败（major）**：`SrsSyncScheduler.adoptProfile` 在本机目录（互联 host）上传 `within: null`，
  而 `adopt` 现在没有 `within` 就抛错。改成一律传当前位置；`_onLocation` 的 `channel` 标志（只为旧的「并入前只拉不发」不重入
  通道锁）删了。`fushi/test/sync/interconnect_srs_two_way_sync_test.dart` 按新代改写（5 条：集合 / 目录一致、uid 不变；host 经
  本机目录认领客户端集合；host 吸收客户端集合、客户端经 WebDAV 读到提示再确认），删掉依赖协议 3 暂缓并入与外来已盖戳
  事件的那条。变异实测：`within: null` → 两条 host 认领用例红在 `adopting … needs the location it was found on`。
- **并入提示从持久状态派生（major）**：原来只在认领那一刻、那一个位置写一次，失败只记日志、以后没有代码补。现在
  `SrsDbProfileLinker.publish`（每轮同步成功后都调）按本机集合 `collection_info.joins` 里受信、带 `dir` 的 `Join`，在当前位置上
  对「目录在、`meta.json` 集合标识等于 `from`、还没有指向本机集合的提示」的目录补写 `joined-into-<本机集合>.json`
  （`_ensureJoinHints`；同一位置同一组 `Join` 补齐一次后进程内不再列目录，没补齐就下一轮再补）。两个方向同一条规则：吸收
  （`Join{from: 对方}`）在对方目录里放提示；**改绑**（`rebound`，`Join{from: 本机原集合}` 在新集合里）在离开的旧目录里放指向
  新集合的提示，旧集合里没被问过的设备据此跟过来（设计 §5.4 第 3 条不分谁发起）。集合里别的设备、别的位置上的同名目录都会补。
  认领那一刻照样先试一次（`_adoptCollection`）。新用例：首次写提示失败 → A 下一轮发布补上 → B 被问；x 改绑进 A → X 里
  已关联的 x2 / x3 经提示被问并跟过来。变异实测：去掉发布里的补写 → 前者红；改绑时不写 → 后者红。
- **已并入的集合只认受信的 `Join`（minor）**：`srsTrustedJoins` 只收 `trusted == true` 的条目，与内核 `AlreadyJoined`
  （`identity.rs` `ix.joined`）同口径；判定（`joined`）与提示派生共用。纯函数用例；变异实测（去掉 `trusted` 判断）红。
- **⑥ 存量单位提醒（minor）**：新代收段 / 导入只要落了东西就 `Tally::all()`（`gen4/cmd/sync.rs`），内容指纹本身推进，develop
  拼上的 RWKV 键（合并信号）成了冗余保险——撤掉它测试仍绿是预期。测试改成断言这条新代前提（只并进复习日志的一轮收段也推进
  内容指纹），`srs_providers.dart` 的注释同步改正。代码里的合并信号留着（无害）。
- **认领与在途写入两种先后都测（nit）**：`srs_profile_purge_single_test` 加「认领先发、写入后发」。
- **③ 余项**：`srs_write_statement_cost_test` 第 1 条、`srs_bulk_ops_roundtrips_test`「语句数不随事件数增长」、
  `srs_bulk_ops_equivalence_test`「同步」组改走集合并入（新 helper `joinCollectionFrom`：`.fushisrs` 导出 → 确认导入）。
  等价测试换成「一次并入对端最终集合 = 分几次并入它的增量（含重复并入、后来的改名支配先前的）」，`ops` 一行不比（每次导入
  先打一个还原点，本机日志长度按导入次数本来就不同）。成本表重钉：`import` 内核命令 2 → 3（新代导入后重取 `identity`，这条以前
  因为测试在 `applyRemote` 就崩了一直没被核对过）、`joinCollection` (0, 5)。
- **没做：`dumpSrsState.serverTimes` 的变异实测**——新代只有承袭来的事件才有服务器时刻（内核 `gen4/cmd/reads.rs`
  `server_times` 文档），Dart 侧造承袭事件只有旧事件备份读入（`legacy_backup_import {source: "events"}`）一条路，仓库里没有现成的
  旧 `.fushisrs` 事件备份夹具；现有等价用例里这一维都是空表，变异无从下手。要做得先写旧事件备份夹具（归 G11-4 / T1）。
- **⑤ G11-4 遗留的判断**：
  - 「同一集合多个 profile，覆盖还原后只有第一个重新绑定」在新代**合法输入里不存在**：`collections.profile_uid` 与
    `collection` 都是 UNIQUE（`gen4/schema.rs`），导出时 `_exportStreams` 按 `collection_info` 分组，每组恰好一个 profile；旧形态
    （协议 3 `srs.db` / 主库老表）每个 profile 一个单元。只有伪造的清单会给一个单元多个 profile：只绑第一个，其余不动，数据经
    第一个可见，不丢。不改代码。
  - 「覆盖还原后第一次合并同一份旧事件输入多落一份」没做：要让旧备份读入在落库前先建本机身份（`collection_adopt` / `backup.rs`
    的时序），是内核身份时序的改动，归 G9 身份模块；本分支没碰内核。
- **BUG-4626 并入场景**仍按上一轮结论交出（真红、未提交）：要么写入口对「本集合没有、本库别的集合有」的实体 ID 拒绝（需要
  跨 `col` 按实体查的索引，即新代库 schema 改动），要么并入时丢掉悬空操作（并集语义改动），都是内核取舍，本分支不定。

### 复核修复（2026-11-18 第四轮，同分支，针对 `c3dfeaa22a`）

- **并入提示的发布缓存把「不确定」记成已补齐（minor）**：`_publishJoinHints` 原来只要 `_ensureJoinHints` 不抛就按「这组 `Join`」
  记进程内缓存，而 `_ensureJoinHints` 对「目录此刻不在这个位置上」和「目录在、`meta.json` 读不出 / 集合标识对不上」都静默跳过。
  于是 A 先在第二个位置发布、B 的设备之后才开始同步那里，或者云盘一次瞬时读失败，同一进程里 A 都不再补那里的提示，只用那个
  位置的 B 设备要等 A 重启才被问。修法：缓存的观察改成「这组 `Join` + 位置命名空间下此刻在的那几个旧目录」（一次列根目录，
  便宜；旧目录一出现观察就变、重新完整列目录补写）；`_ensureJoinHints` 返回是否**确认**补齐（每个旧目录要么此刻不在，要么集合
  标识对得上且提示已在 / 刚写成），`meta.json` 读不出、对不上、写失败都返回 false，不记缓存、下一轮再看。取舍：没有把各目录
  `meta.json` 摘要并进观察——那要每轮下载文件，与缓存要省的开销相同；目录在而 meta 一直读不出的位置会每轮完整列一次，属
  外来坏数据，按不确定处理。
- **提示一直写不成时每轮刷错误日志（nit）**：写提示失败不再往外抛（以前经调度器 `SrsSyncScheduler.profileInfo` 每轮记一条），
  改在 `_ensureJoinHints` 里按 `位置键|目标目录|错误` 只经 `onError` 记一次（`_hintFailuresLogged`，同 `_resumeFailuresLogged`），
  每轮照样重试（重试是补写的唯一途径，不退避）。认领那一刻的失败记在 `adopt` 这个键下。列目录失败照旧原样抛（位置整个
  够不着，与说明文件发布失败同一出口）。
- 新用例（`srs_profile_link_sync_test`，11 → 14 条）：「B 的目录在 A 首次发布之后才出现在第二个位置：A 之后的发布补上那里的
  提示」「B 目录的 meta.json 一时读不出：这一轮不算补齐，下一轮发布补上提示」「提示一直写不成：每轮发布都重试，同一个失败只记
  一次日志」。变异实测（各自单独改、跑完 `git restore`，工作区干净）：观察里不含在场目录 → 第一条红（`Actual: <false>`）；不确定也
  记缓存 → 第二、三条红；每次失败都记日志 → 第三条红。
- **BUG-4626 新代并入场景已正式登记为 BUG-4843**（`docs/bugs/BUG-4843-srs-gen4-dangling-op-joins-into-other-collection.md`）：根因
  `file:line`（`gen4/cmd/writes.rs:31` / `:886` 写入口不设闸，`gen4/identity.rs:430` / `:572` 并入无条件并集）、两种修法与复现用例
  全文都在 bug 文件里，交 G9 身份 / 设计；本分支仍不改内核。

## 36. 第五波 同步收尾（2026-11-18，分支 `pr/srs-gen4-w5-sync-tail`，基于 `pr/srs-gen4-switch` `3d78fe51d0`）

输入：第五波只读审计 sched9 / plan6 / ledger（同步项）。逐条结论：

- **R10 新根 `meta.json` 一时读不到不重写（真 bug，已修）**。根因：内核 `location_root`（`cmd/sync.rs`）在 `has4 == false` 时只看
  `v3/meta.json` 在不在就按「旧集合，从 v3 重建 v4」走，先写 v4 再写围栏；v4 的 meta 只是这一轮读失败（云盘瞬时错误）而 v3 早已是
  围栏、或 v4 下已有设备 / 加密媒体时，它会拿围栏（没有 `media`）重建出一份 meta 盖掉原来的（媒体根被改）。修法：Dart 把「v4 下已有
  数据」（`devices/` 或 `media-e/` 有文件，与握手同一判据；不含 `media/`——测试与真实流程里媒体会先于 meta 上传）作为 `v4Data` 传给
  内核；内核在 v4 meta 缺、而 v3 已是围栏或 `v4Data` 为真时拒绝，机读码 `srs_location_meta_unavailable`；Dart 在握手之前同样先判
  一次，报 `kSrsSync2MetaUnavailable`，这一轮不写任何东西，下一轮 meta 读得到就照常。测试：`sync_tests.rs`
  `an_unreadable_new_root_meta_behind_a_fence_is_not_rebuilt`、`srs_sync4_folder_test` 真内核用例。变异：内核判据改 `if false &&` →
  Rust 用例红；Dart 与内核两道都去掉 → Dart 用例红（`Expected meta unavailable, Actual null`）。
- **删协议 1 位置迁移的死结构**：`srs_location_migration.dart`（新代不再迁移协议 1 位置，只按 `kSrsLocationProtocol1Root` 拒绝）与它
  在 `srs_folder_location.dart` / `srs_location_runner.dart` / 调度器里的接线（`kSrsV1MigrateActivity`、`v1MediaMigrations`、
  `onV1Bound`、quiesce / settle 等迁移）、测试 `srs_v1_media_migration_stop_test.dart`；围栏编解码留在新文件 `srs_v1_fence.dart`
  （新集合立围栏、判 v2 围栏仍要用）。随之死掉的 UI 管线一并删：`srsMigrationProgress`、`SrsSyncStage.migrating`、后台任务 /
  同步横幅里的「旧文件迁移」一行与两条测试、i18n `srs_sync_progress_migrating` / `_count`（`i18n_sync --remove`）。
- **调度器测试按新代布局改**：`srs_sync_scheduler_test` 9 条过期用例改成读 `v4/devices/<设备>/seg-` / `v4/meta.json` + v3 围栏；
  R5 / R6 两条协议 1 媒体迁移用例改成拒绝路径（只有协议 1 旧根的位置：报 `kSrsLocationProtocol1Root`、提示一次、位置字节不动；关掉
  的位置不报错、不跑）。
- **K2 合流后的两条红是测试过期、不是回归**：`sync2 relay` 与 `media_sync`「记日志的位置」都撞上 K2 首见信任（库非空时第一次见到
  的设备是待确认）+ 两道有意的信任闸——只替受信作者转发（`relayable`）、不收待确认 / 已拒绝设备的媒体清单（`gen4/media.rs`
  `IngestError::Untrusted`，G8-3：「它说的在」可能是要别人别传）。测试改成先由用户确认对端（`sync2Trust`），与 K2 改 Rust 用例同口径。
- **既有红逐条定因（均为测试过期）**：`bootstrap_channel_entry` ×3 测的是协议 3 收段通道（`sync2_boot*` 表），新代没有收段通道 →
  只测通道机制的两条删掉，收敛断言移到新文件 `srs_sync4_new_device_convergence_test.dart`；`head_gap` 读 head 的段表键名新代是
  `segs`；`media_presence` ×2 媒体事实按位置记，对账要带与同步一轮相同的 `locationId`，另一条再加确认对端；`style_dedup` 在 `ops`
  的操作体上 `instr`，但够大的操作体按 zstd 存（`gen4/pack.rs`），改数 `exportAll` 的修改记录；`preread_cost` 973/958：清除会作废旧
  操作，`status.ops` 数的是内容行，改按 `nextSeq - 1` 数写入条数。
- **G10-4 残余 1：混合版本家庭按轮判首次信任（已修）**。`plan`（每轮开头、收段之前）按位置记 `gen4_round_fresh/<集合>/<位置>` =
  这一轮开始时库是不是空的（`cmd/sync.rs` `round_fresh_key`）；`oldroot_ingest` 第一次见到、且本机还没有它任何日志的协议 3 作者按
  这一轮开头的结论判（`truth/trust.rs` `note_new_peer_in_round`，文件头「这一轮」一段）。本机已有它日志、公钥第一次登记的照旧按此刻
  判，不放宽 G10-4 的收紧。测试：`sync_heritage_trust_tests.rs` 两条（全新设备第一轮先收新根再捡旧根 → OLD 无信任行、清除不扣；后
  续一轮才第一次见到 → 待确认、清除扣住）。变异：`fresh_round` 恒为 false → 第一条红（`sync_heritage_trust_tests.rs:431`）。
  没用 SCHEMA 40022：标记放在已有的 meta 键值表里，不需要新表。
- **G10-4 残余 2：`heritage_plan` 的 `unvouched` 接到同步页**。`srsSync4UploadHeritage` 把回包的 `unvouched`（`skip` 时也带）记进
  `SrsSync2Report.heritageUnvouched`（没走到这一步为 null）；调度器 `heritageUnvouched`（`ValueListenable<Set<String>>`，通道 / 本机
  目录 / 文件夹位置三条路径都更新，取最近一轮走到这一步的结论，null 不动）；「同步与历史」页状态卡在非空时加一行
  `srs_sync_heritage_unvouched` / `_hint`（「有 N 台旧设备的数据等你确认该设备后才会继续上传」，指向下面的设备列表）。测试：
  `srs_sync4_round_test`（skip 回包带 unvouched → 进报告；空表 → 空不是 null）、`srs_sync_scheduler_test`（有 → null 不动 → 空）。

**更正 §34（G10-4）的两处说法**：「旧根两条命令目前还没有 Dart 调用方（同步轮 2b 步未接线）」与「旧根命令目前仍没有 Dart 调用方」
不成立——G8-7b 已接线：`packages/fushi_engine/lib/srs/sync2/srs_sync2_round.dart` 一轮的「2b. 旧根接手」步调
`srsSync4TakeOldRoot`（`srs_sync4_steps.dart`，内核 `oldroot_scan` / `oldroot_ingest`），承袭上传 `srsSync4UploadHeritage` 调
`heritage_plan`。§34 里「等接线时由同步轮持有者决定」的两件事本节已做（上面残余 1 / 2）。

**没做 / 留给后面的**：
- `SrsDeferredProfileMerge` 仍有读者（`srs_history_page.dart` 的「并入暂缓」行），不是死代码，本节不动。
- `docs/agent/subsystem-map.md` 里协议 2 断代那段仍提到 `srs_location_migration.dart`（历史描述），没改。

### 复核修复（2026-11-18，同分支，针对 `297301f89a`）

- **协议 1 迁移的内核死命令一并删掉**（上一轮只删了 Dart 半边）：`open_v1`（只给 v1 位置的按名字整份封装解密）与
  `media_bind_unbound`（只给 v1 媒体迁移补绑定）在 Dart 已无调用方。删两代分发器的匹配臂与登记（`ffi.rs` 的
  `CHANNEL_TRANSPARENT` / `crypto_command`、`gen4/dispatch.rs` 的分类表与分发）、实现（`sync2/media_seal.rs` `open_v1`、
  `store/sync2/media.rs` `sync2_media_bind_unbound`、`gen4/cmd/media_sync.rs` `bind_unbound`）与测试（`tests_break.rs`、
  `sync_complete_tests.rs` 各一条；`media_seal.rs` 那条改成只断言整份封装是坏对象）。`srs_media_sync_test`「BUG-3865」原来用
  `media_bind_unbound` 造「别的设备绑定过」，改成真有一台设备传上去、同步过来。`oldroot.rs` 文件头说的是 v3.3.0 里的旧入口，注明
  「本仓已删」。本文 §7.4 对照表、§8.2 与 §22（G8-7b）里列着这两条命令的行是当时的事实，不改别人的节，以本条为准。
- **R10 的内核判据补上 loc 标记**：`location_root` 判「新根立过」的证据从「围栏 || `v4Data`」改成「围栏 || `v4Data` || 新根下有 loc
  标记」——loc 标记总在新根 meta 之后写，内核自己从 `locs` 就看得到，不全靠 Dart 传来的 `v4Data`。Dart 闸同样把 loc 标记算进
  `v4Data`（`srs_sync2_round.dart`，`loc/` 只列一次，传给内核的也是这一份）。
- **新根整个被删、只剩围栏：不再永久报「暂时读不到」**。v4 下没有 meta、设备 / 媒体数据、loc 标记，而 v3 是围栏时，新根多半被用户 /
  网盘整个删了（也可能是列目录一时为空），等下去不会自己好。仍然不重建（媒体根 / `kdf` 从围栏推不出来，按任务书「不重写」），但换
  一个机读码：内核 `ERR_NEW_ROOT_MISSING` = Dart `kSrsLocationNewRootMissing` = `srs_location_new_root_missing`；新根下还列得到东西
  时仍是 `srs_location_meta_unavailable`。界面：`srsSyncErrorReason` 与文件夹位置行给 `srs_sync_location_new_root_missing`，说明
  恢复办法。**人工恢复**：确认网盘上 `fushi-srs/<集合目录>/v4/` 确实没了，删掉同目录下 `v3/meta.json`（围栏），再同步一次——这一轮
  按新集合重建（新根 meta 的媒体根是 `v4`，围栏重新立起，本机的数据重新传上去；真内核用例实测）。代价：v4 上原有的段已经随目录
  没了，只能由各设备从本机重新上传；还没上线的设备的新代数据要等它上线；协议 3 时代留在 `v3/media/` 的媒体不再被这个集合引用
  （设备本机有的会重新传到 `v4/media/`）。**定案（所有者授权自定）：不做「确认后按新集合重建」的界面入口**——自动或一键重建都要替
  用户断定「v4 真的没了、不是一时列不到」，判错就是 R10 本身；人工删围栏这一步把这个判断留给看得到网盘的人。
- **承袭日志的提示只对待确认作者**：`unvouched` 包含待确认与已拒绝的作者（两者都不替传，都让旧根不能退役），但「等你确认」对用户
  有意拒绝的设备是误导。内核 `heritage_plan` 另回 `pending`（`unvouched` 里信任状态是 `TRUST_PENDING` 的）；Dart
  `SrsSync2Report.heritagePending`；调度器的 `ValueListenable` 改名 `heritagePending`，只装待确认的；页面经新 provider
  `srsHeritagePendingProvider`（`srs_app_runtime.dart`，页面测试可注入）听它，行函数改名 `srsHeritagePendingRow`（key 与 i18n 不变）。

测试：`sync_tests.rs` `an_unreadable_new_root_meta_behind_a_fence_is_not_rebuilt` 加两段（无围栏只有 loc 标记 → meta 不可用；只剩
围栏 → `ERR_NEW_ROOT_MISSING`）；`sync_heritage_trust_tests.rs` 新增 `a_rejected_heritage_author_is_unvouched_but_not_pending`、原用例
加 `pending` 断言；`srs_sync4_folder_test` 两条真内核用例（meta 与围栏都读不到、再藏掉设备目录只剩 loc 标记 → 不重建，放回照常；
v4 整个删掉 → 新根不见了、不重建，删围栏后重建、媒体根 v4、重新上传）；`srs_sync4_round_test`（`pending` 进报告）；
`srs_sync_scheduler_test`（改用 `heritagePending`）；`srs_history_page_test` 新增 widget 用例（集合空 → 无行；两台待确认 → 行与
标题；清空 → 消失），MD3 / Apple 各一遍。变异：内核 `v4_listed` 去掉 `!locs.is_empty()` → `an_unreadable_new_root_meta…` 红
（`sync_tests.rs:1012`，围栏 + loc 标记的那段变成 `new_root_missing`）；`pending` 不按信任状态筛 → `a_rejected_heritage_author…`
红（`sync_heritage_trust_tests.rs:147`）；Dart 闸只剩围栏时也报 `kSrsSync2MetaUnavailable` → 「新根整个被删」用例红；
`srsSync4UploadHeritage` 不记 `pending` → `srs_sync4_round_test` 红（`Actual: <null>`）；页面不画这一行 → 新 widget 用例 MD3 / Apple
都红；还原后工作区干净。

既有红（不是本分支引入）：`srs_history_page_test`「存储位置：添加文件夹 / 改用途停用 / 移除，都写进 prefs」MD3 / Apple 两条在
`297301f89a` 上同样红（把页面 / 调度器 / 运行时 / 测试四个文件换回 `297301f89a` 实测：`timed out waiting: usb removed`）。根因：
`de04352167`（移除位置先让内核 `location_forget`）之后 `_removeFolder` 要 `srsAppRuntimeProvider` 的调度器，没有就抛
`StateError('removeFolder: srs runtime unavailable')`，而这个页面测试把运行时覆盖成 null。归 `location_forget` 那一块的所有者：给
页面一个可注入的「忘掉位置」入口（同 `srsDeferredProfileMergeReaderProvider` 的做法）再改测试，本节不动。

另：全量 `cargo test --profile quick --lib` 一次里 `store::gen4::files::tests::a_fresh_install_appears_under_the_final_name_only_when_complete`
红过一次（目录里多出 `SRS4.DB-SHM.tmp`），单跑 3/3 绿，本分支没碰 `files.rs`——高负载下的偶发，留给新代库文件层的所有者看。

## 37. 第五波 G9 身份收尾（2026-11-18，分支 `pr/srs-gen4-w5-identity-tail`，基于 `pr/srs-gen4-switch` `3d78fe51d0`）

审计 G9 项（B1、B7、N7、N11、C11、X1）的六件事，内核 SCHEMA 40021 → 40023（本分支分到的号）。

### 做了什么、取舍

- **① 空集合判据（`962462eafa`）**：`gen4/discard.rs` 的 `disposable` 以前只认「只有 `Salts`」，app 里的全新设备开库就写了内置
  种子（`SrsDbStore.ensureBuiltins`），关联已有集合一律 `joined` + `Join`。现在与 K2 首见信任共用**同一份**判据
  `Truth::library_fresh`（`truth/trust.rs`，它顺带补查 `op_forks`），`disposable` 只在它之外再看「别的设备 / 对等方 / 位置游标 /
  已发布 / 本机日志里有 `Join`」这几条廉价条件（`DISPOSABLE_SQL`）。只有内置种子与盐 = 空，D27 方向上换绑（`bound`）、不写 `Join`。
  测试：内核 `cmd/profile_data_tests.rs` `a_profile_with_only_builtin_seeds_binds_without_a_join`；Dart 真内核端到端
  `srs_profile_link_sync_test`「全新设备（开库已写内置种子、从没同步过）关联已有集合：bound，两边日志里都没有 Join」。
- **② BUG-4843 写入口实体归属闸（`e7ad8988eb`）**：选「写入口设闸」而不是「并入时丢悬空操作」。新文件
  `gen4/cmd/writes_owner.rs`，唯一判据 `Session::foreign`：一条本机操作指向的实体在库里别的集合有（`ent_ix.id` /
  `alias_ix.canon` / `cards.id`）、本集合一点痕迹都没有（身份、别名类、卡片行、修改 / 日志 / 标签索引行、同一批要建的实体；
  先不收尾查，没查到再收尾查一遍）时不写：`apply_in` 那一项 `landed: false` 并把下标放进回包 `foreign`，`purge` 跳过并回
  `foreign`，`sched` 按「没有这张卡」跳过（撤销计入 `blocked`）。库里只有一个集合时一条查询就放行（`others` 缓存在 `Session`）。
  - 并集收敛不受影响：闸只决定本机要不要写下一条操作；写下之后的传播 / 收段 / 导入 / 并入语义一个字没改，几台设备的状态仍只由
    同一份操作集合决定。丢悬空操作的修法要给「并入时不存在」定跨设备一致的判据，还会误丢合法的先写后有。
  - SCHEMA 40023：三个按 ID 跨集合查的部分索引 `ent_id ON ent_ix(id)`、`alias_canon_any ON alias_ix(canon) WHERE canon != id`、
    `cards_id ON cards(id)`，都带 `col > 0`——只有归属闸的查询写这个条件，规划器不会拿它们替换既有查询的索引（不带条件时
    `s1b_statements_use_their_keys` 被 `alias_canon_any` 抢走，加统计也压不住）。`PLANNER_STATS` 补了三行。
  - 测试：`cmd/writes_owner_tests.rs`（三条，含两条执行计划断言）；engine `srs_profile_ownership_merge_test.dart`（bug 复现：A 写
    B 的 ID 一条不落 → A 并进 B → B 不变）；`editFields` 别人的笔记回空、批量改卡别人的卡不落。**更正（复核）**：这一版把
    `srs_profile_ownership_test.dart` 矩阵判据改成「不多于不存在的 ID」并称之为收紧，实际是放宽，盖住了身份记录与 profile 设置
    两类泄漏；闸也确实漏了这两类。见下面「复核后补修」。
- **③ 覆盖恢复后第一次合并同一份旧输入多落一份（`e2f517c820`）**：根因是旧备份读入（`legacy_backup_import`）在 profile 还没
  绑定时先用随机 scratch 身份落库、之后 `collection_adopt` 才生成本机身份，下一次合并同一份输入时 scratch 身份对不上。修法：
  `cmd/identity.rs` 加 `PendingSelf`（先生成本机设备 ID 与种子），scratch 身份从它派生，`collection_adopt_with` 把它定为本机身份；
  `cmd/backup.rs` 的 `prepared_marker` 把密钥指纹（blake3 derive-key）算进标记。测试 `cmd/backup_tests.rs`
  `the_first_merge_after_landing_into_an_unbound_profile_changes_nothing`。
- **④ 墓碑设备 ID 改向内核要（`cb1d756508`）**：`gen4_ids/derive.rs` 加 `tombstone_device` 一种（`gen4::location::tombstone_device`），
  Dart `srsTombstoneDevices(dirs)` 一次批量走 `ids`，`srs_profile_link.dart` 不再拿命名空间自己 `uuidV5`。守卫
  `srs_kernel_ids_guard_test` 转绿。
- **⑤ `srs_db_store_test`「覆盖恢复备份后：换新化身…」改写成新代**：不再删协议 3 的本机表，改为整包导出
  （`srsExportBackupStreams`）→ 空的新代库 → `srsLandBackupUnit(confirmed: true)`（`bound`）→ 按原 profile 打开，断言同一个集合。
- **⑥ 新代全新集合在 WebUI / 关联列表里没有名字与笔记数**：`srsPublishProfileInfo` 改写到 `v4/devices/<设备>/profile.json`
  （规划 G-6、内核 `gen4/location.rs` 的布局），`srsListRemoteProfiles` 在 `v4/` 根下读各设备的说明文件（只有发布了说明文件的设备
  算写入者，名字仍是 `srsV2WriterName`），旧根 `v3/devices/` 照旧读（协议 3 设备）。笔记数仍由调用方向内核 `entity_count` 要
  （`userNoteCount`），Dart 不存镜像。`srsRemoveOwnProfileFolder` 在没有新代设备目录可删时只删本机的说明文件。测试在
  `srs_profile_link_test.dart`（两条新用例 + 路径断言改为 v4、旧根没有）。

### 变异实测（各自单独改，跑完还原，工作区干净）

- 内核：归属闸恒放行 → `writes_owner_tests` 红；不用 `PendingSelf` → `backup_tests` 新用例红；标记不含密钥指纹 → 红；
  `disposable` 不看 `library_fresh` / 回到只认 `Salts` → `profile_data_tests` 新用例红。
- Dart：读端不读 `v4/devices/*/profile.json` → 15 条红；清理不删说明文件 → 1 条红；发布写回旧根 → 1 条红。

### 没做 / 留给后面

- `fushi_server`（headless host）至今不发布 `profile.json`，WebUI 列表里 server 那一端的新代集合仍没有名字 / 笔记数；要接 host
  钩子，见 `server-parity-gaps.md`，本分支没碰 server。
- `PendingSelf` 只在 `legacy_backup_import` 遇到未绑定 profile 时生成；同一 profile 若同时有别的路径在建立本机身份（并发的
  `collection_adopt`），以先提交的为准，scratch 身份可能对不上、下一次合并会再落一份。按现有单写者调度不会并发，未加测试，
  未实测。（第二轮已修：落库时核对、对不上整条失败，见「复核后补修」。）
- 闸之前已写下的悬空操作挡不住：新代还没发布、协议 3 有 `ownership.rs` 闸且 ID 带盐，迁移来的日志里没有这种存量。

### 复核后补修（2026-11-18 第二轮）

复核实测出第一版的四个问题，按根因补了：

- **归属闸漏了身份记录与 profile 设置实体（`089ff6b293`）**。身份记录：以前不过闸、还直接进 `Born`，A 写一条 B 的笔记的身份
  记录（伪造 guid、A 的笔记类型）就落了，同批对这条笔记的修改也借它过闸；并入后 `derive.rs` 的「规范 JSON 最小者胜」可能拿 A 的
  那份顶掉 B 的。profile 设置实体：不在 `ent_ix` / `alias_ix` / `cards` 留痕迹，A 拿 B 的 uid 改设置照写，并入（盐取并集）后
  成了 B 的。取舍：
  - **身份记录不能简单按「别的集合有、本集合没有」拒**：ID 不加盐后，内置笔记类型、默认牌组、按全名派生的牌组、按 guid 派生的
    笔记在两个集合里天然同 ID——第二个 profile 导入同一个包、导入同一份挖词历史（`srs_mined_history_import.dart` 按内容定 guid、
    走 `createNote` 即 `apply`）、建同名牌组都会被误拒。所以按种类判：笔记身份记录的 ID 等于 `v5(NS, note/<自己的 guid>)` 的放行，
    对不上的（随机 guid 新建的、存量带盐的、伪造的）按原判据判；牌组 / 笔记类型的身份记录不判（对它们的修改仍判）；卡片身份记录
    按原判据判；判身份记录时不拿 `Born` 给它自己作保，只有过了闸的才进 `Born`（`apply_in` 先过一遍身份记录）。
  - profile 设置实体按协议 3 `ownership.rs` 的口径：ID 是别的集合绑定的 profile uid 或盐、又不是本集合的才拒（`PROFILE_SQL`，
    `collections` 几行、`json_each(salts)`），规范值 `v5(NS, profile)` 永远放行。
  - 残留：伪造一条 guid 与 B 的笔记一致、但笔记类型换掉的身份记录仍会过闸——它与「别的集合独立导入同一份内容」在写入口分不出来。
    正常写入口不会这样写；要彻底防得改并入时同 ID 身份记录的取舍规则，不在本模块。
- **写入口矩阵判据改回能发现漏闸**：`srs_profile_ownership_test.dart` 按入口断言 A 为别人的 ID 一条都不写（只碰别人 ID 的入口：
  A 的日志长度不变；同时写自己实体的 `dismissDuplicates 自己的 + 别人的`（实测只有它）：A 的真相里没有指向别人
  ID 的操作）；远程路由那组断言 0 条。
- **`sched` 闸补测试**：`writes_owner_tests` `sched_skips_another_collections_cards`（迁移来的集合 + 同库第二个集合：重置 / 改期 /
  撤销别人的卡，A 的日志不增、撤销计入 `blocked`；对照组陌生的卡照写）。
- **`PendingSelf` 的 TOCTOU 与换绑（`6797d17551`、`395161488c`）**：分发器在读快照里定副本身份用的本机秘密，落库在之后的写事务里。
  ① 落库那一笔核对「集合此刻的本机秘密 == 备副本时用的」，对不上整条命令失败、什么都不留（`LOCAL_IDENTITY_MOVED`，重发即按新
  秘密重备），不再静默落下一份之后会重复的数据。测试 `backup_tests`
  `a_local_identity_created_while_the_copy_is_prepared_fails_the_landing`（经 `dispatch::legacy_backup_import` 的 `before_land`
  钩子在备好副本之后插入并发的 `identity`）。② 这道核对顺带暴露了复核说的「绑到别的集合时种子不一致」的真实路径：已绑定的全新
  profile 读进别的集合的旧备份时走「空集合可换绑」（`rebind_empty`），对方集合里重建的本机身份以前是现生成的钥匙，副本身份却按
  旧集合的钥匙派生——换绑之后再读同一份输入会以另一个合成设备再落一遍。修法：已绑定时 `PendingSelf::carrying` 沿用现有钥匙种子、
  设备 ID 照旧新生成（被丢掉的空集合导出过的话，同一设备号从头记会撞号；钥匙只在本机、空集合从没发布过，沿用不扩大暴露面）。
  测试：`another_collection_needs_confirmation_and_bad_files_change_nothing` 补「换绑后换新副本目录再读：`applied` 0、`inserted` 0」。
  观察（未查）：这第二次读入的结论是 `saltsAdded`（补写一条 `Salts`），不是 `same`；没有重复数据。
- 小项：`discard.rs` `DISPOSABLE_SQL` 恢复 `\` 续行（语义不变）。

变异实测（各自单独改、跑完还原、工作区干净）：身份记录恒放行 → `another_collections_identity_records_are_not_written` 红；
profile 判据恒放行 → `another_collections_profile_settings_are_not_written` 红；内容派生放行关掉 → `another_collections_entities_are_not_written`
红；`sched` 闸关掉 → `sched_skips_another_collections_cards` 红；落库核对关掉 → `a_local_identity_created_…` 红；`carrying` 换回 None →
`another_collection_needs_confirmation_…` 红。

没做（归属）：

- `fushi_server` 不发布 `profile.json`：已登记进 `docs/agent/server-parity-gaps.md`「Other known gaps / SRS follow-ups」，归 server
  模块（要定 server 端的名字来源，笔记数向内核要）。
- 未绑定时预检与确认两次请求各生成一份 `PendingSelf`，副本整份重备两遍（性能代价，结果正确）；要省得把预先生成的身份跨请求
  留存，没做。

## 38. 第五波 导入与写接口（2026-11-18，分支 `pr/srs-gen4-w5-import-write`，基于 `pr/srs-gen4-switch` `3d78fe51d0`）

收第五波审计（规划 §6）里归「导入与写接口」的四项：B4 / C13（回导外来原生日志的排序键）、N6（`.fushisrs` 内核流不带空洞内部
记号）、N13（写回包没标被同批盖掉的项）、R4 之后剩的两条既有红与 K1 两条 nit。不升 SCHEMA（仍 40021），不加表 / 索引；
存量持久化名不动。

### ① 回导外来原生日志：排序键由来源数据派生（B4 / C13）

- **根因**：`.apkg` 回导时 Dart `_remapExtLog`（`packages/fushi_engine/lib/srs/apkg/srs_apkg_import.dart`）把别处导出、
  origin = `fushi` 的原生日志重新挂到本机卡上，内核当新原生操作收下；原生操作不带旧 HLC（设计 §3.4 `native_allowed`），
  投影回落到操作自己的 HLC（导入时刻 + 本机设备）。后果：一条比本机复习**早**的外来复习排到了本机复习**之后**，成了最后一条
  有效日志，静默改掉当前排程；两台设备各导一次，排序键各不相同（各自的导入时刻 / 设备），重放结果不一致。
- **定案**：与 K3（§28）同一层——**日志投影层派生，不进操作**。Dart 在 `_remapExtLog` 给日志的 `extra` 打记号
  `"foreignLog": true`（键常量 `srsForeignLogKey`，`packages/fushi_srs/lib/src/anki_import_rules.dart`）；内核
  `anki_import_rules.rs` 的唯一入口 `derived_log_hlc(origin, kind, anki_id, at, extra)`：origin = `anki` 走原来的
  `anki_source_hlc`，否则 extra 带记号的派生 `{at}:0:fushi`（`at` = 复习发生时刻，写入者固定 `fushi`），其余 None。
  `cache.rs` `log_body` 与 `cmd/writes.rs` 回包 `logHlcs` 都改用它（两处逐字同口径）。派生只依赖操作体，各设备一致；摘要
  只含 ID 集合，不受影响。
- **口径变了要重建**：`CACHE_RULES` 1 → 2（`cache.rs`）。已打开过的库在 `derive_cfg` 里记的是 1，开库时按「推导口径变了」
  全量重物化一次；不改真相、不丢卡。
- **同发生时刻的并列**：外来日志 `{at}:0:fushi` 与本机同毫秒的原生日志靠 `history.rs` 冻结的排序键后几位（counter、writer、
  event_id）定序，各设备算出的相同；不是本波的问题。
- **测试**：Rust `writes_tests.rs` `a_foreign_native_review_older_than_a_local_one_does_not_reschedule_the_card`（修前红：
  最后一条有效日志变成外来那条）、`importing_the_same_foreign_logs_twice_changes_nothing`（防回归，不是修前红，见下「复核
  修复」）；`sync_tests.rs` `a_foreign_native_log_imported_on_two_devices_keeps_the_local_schedule`（两台设备各导一次，卡行
  逐列相同、最后一条日志仍是本机那条；修前红）；`anki_import_rules.rs` 单测 `a_marked_foreign_log_sorts_by_when_it_happened`。
  Dart `srs_apkg_import_test.dart`「回导的外来复习比本机复习早」：断言见下「复核修复」第 3 条（原先只比 dueAt 是空比）。

### ② `.fushisrs` 内核流第 2 版：空洞带区间内部的链值记号（N6）

- **根因**：K2（§33）在合并别的设备的空洞时留下区间**内部**的切点链值（`log_marks` 里 seq 落在 [区间首, 区间末) 的），之后切
  承袭段要用；FSRS4EXP 第 1 版的空洞项只有 (首, 长度, 末链值)，导出 → 导入后这些内部记号丢了，导入方之后再切承袭段对不上链。
- **定案**：`gen4/export.rs` `EXPORT4_VER` 1 → 2（`EXPORT4_VER_OLDEST` = 1，读侧 1..=2 都收）；新项标签 4（`ITEM_VOID_MARKED`）
  = 空洞 + 内部记号表，只在第 2 版出现，记号必须严格升序、落在 [首, 首 + 长度 − 1) 里，否则整流拒收；没有内部记号的空洞仍写
  标签 3，字节与第 1 版相同。导入（`store/gen4/import.rs`）对每个记号：本库已知那一格的链值就比对（不一致拒收，同普通原生操作
  的分叉判定），未知就经 `truth.rs` `land_void_mark` 落在本库同一空洞的内部（不在空洞内部 = 拒收；本机设备 / 已有记号跳过）。
  第 1 版流照常读（没有记号，行为同以前）；未知版本（0、3、255）拒收。
- **测试**：`gen4/export.rs` 新 golden `export4_native_void_marks`、冻结的第 1 版头 golden、`older_versions_still_read`、
  `void_marks_must_sit_inside_their_run`、未知版本拒收；`store/gen4/import_tests.rs` 往返用例改为断言两边内部记号相同
  （修前红：导入方没有记号）、`a_version_1_stream_still_imports`、`a_void_mark_that_disagrees_with_this_library_is_refused`。

### ③ 写回包标出被同批盖掉的项（N13）

- **根因**：请求带 `editRows` 时，`cmd/writes.rs` `attach_rows` 给被同批后一项盖掉（或实体被同批清除）的修改补的行是 null，
  可「行是 null」也可能是内核没物化出这一项（真异常）；Dart `_writtenEdits` 分不清，只能一律当错误抛或一律放过。
- **定案**：回包每项**明确带一列布尔「被盖掉」**：`edits` 项 = `[…, 行 JSON, 服务器时刻, 被盖掉]`，`tagWrites` 项 =
  `[…, 行 JSON|null, 被盖掉]`。被盖掉 = 行为 null 且（同批后面还有同 (种类, 实体, 键) 的写 / 实体在同批清除集里）；标签整列表
  写入同理（同批后面还有同一笔记的标签写入 / 笔记被清除，行给 null）。Dart `SrsWrittenItem` 加 `superseded`，
  `srsWrittenByInput` 读这一列，`_writtenEdits` 跳过被盖掉的，**没标被盖掉却没有行的仍抛**（错误信息写明）。
- **测试**：Rust `writes_tests.rs` `a_later_write_in_the_same_batch_marks_the_earlier_one_superseded`、`edit_rows` 用例改 10 列；
  Dart `srs_written_edits_match_test.dart` 新形状、新文件 `srs_written_edits_superseded_test.dart`（真库同批写同一键两次 +
  标签两次，回 2 项、值是后写的）。

### ④ 既有红定因

- **`srs_exclusive_sites_cost_test.dart` 远程作答**：期望（6 条读、2 条命令）量的是 V1 路由；G10-2 起远程复习走 V2，每个
  回包的信封带牌组树标签（`srs_remote_store.dart` `_treeWire`），按结构键缓存，服务的第一次调用取一次 `entity_views`。V2 那一轮
  这条用例还崩在 ID 口径上，从没重量过。不是回归。用例冷、热分开钉（复核后改，见下「复核修复」第 4 条）。
- **`srs_browse_vectors_test.dart`**：fixture 里的卡 / 笔记 ID 是 G9-7 之前的口径，ID 规则换了，向量全错。重新生成前按
  「排序字段 + 牌组 + 笔记类型」把新旧 16 张卡一一对上（无歧义、笔记 / 牌组映射一致）逐项核过：行的其余列除两张复习卡的到期
  天数（重放的 fuzz 以卡 ID 为种子：338→346、344→347）外完全相同；2340 条结果里 396 条不同，**全部**是「同一排序值的两行按 ID
  定序」的相邻对换，0 条别的差异。浏览语义没变，按文件头允许的方式重新生成，证据写进了用例文件头。

### ⑤ K1 nit

- **AnkiConnect 向量的牌组 / 笔记类型号独立比对**：`srs_ankiconnect_vectors_test.dart` `_renumber` 以前从被测的
  `deckNamesAndIds` / `modelNamesAndIds` 回答里按名字抄新号，等于自己跟自己比。改为由规则独立算：牌组的新号 =
  `SrsIds.ankiNumericId(SrsKernelIds.deck(全名))`（`Default` 用 `defaultDeck`）；笔记类型的号是 ankiNum（内置是固定常量、
  自建是存量属性），迁移不换号，不进映射表、原样比。
- **`anki_members` 内置模板成员的笛卡尔积不收窄到同盐组合**（记量级，不改）：一张卡的行数 = (1 + 笔记成员数) × (1 + 模板
  成员数)；k 个盐下内置笔记的卡是 (k+1)² 行，只配同盐是 k+1 行。k 实际 1～2，即每卡 4～9 行对 2～3 行，按卡线性。收窄要逐盐
  `rules::note(盐, guid)` 认出笔记成员的盐，换来的只是少几行没有旧号的组合，不做；写在 `cache.rs` 文件头「表」那段。

### 复核修复（2026-11-18）

1. **外来日志派生排序键加上界（major）**：`at` 来自 `.apkg` 的 fushi-ext，不可信；原先无条件派生 `{at}:0:fushi`，一条发生
   时刻在未来的伪造日志会排在此后本机所有复习之后，把排程钉死在它的结果上（复核实测：未来 1000 天的外来日志 + 之后一条本机
   复习，最后一条有效日志仍是外来那条）。定案：真正回导的外来日志一定早于载着它的那条操作，`derived_log_hlc` 加参数
   `op_wall`（那条操作 HLC 的物理时刻，真相里的数据，各设备一致），**只有 `at <= op_wall` 才派生**，否则回落到操作 HLC
   （即修之前的行为）。`cache.rs` `log_body(l, op_wall)` 从 `log_at` 拿 wall；`cmd/writes.rs` 回包 `logHlcs` 在写下后读
   操作 HLC 再派生（Anki 来源照旧不读）。Dart 导入器（`srs_apkg_import.dart` 逐卡恢复处）把 fushi-ext 日志的 `occurredAt`
   与 revlog 同口径纳入未来时刻守卫：超过 `now + srsClockToleranceMs` 整张卡记进 `futureCards`、跳过，伪造包不能只改 ext
   绕过 revlog 那道守卫。测试：Rust `anki_import_rules.rs` `a_foreign_log_from_after_its_op_does_not_derive`、
   `writes_tests.rs` `a_foreign_log_from_the_future_does_not_pin_the_schedule`（变异：去掉 `at <= op_wall` 两条都红）；Dart
   「fushi-ext 里发生时刻在未来的日志：整张卡记进 futureCards、不恢复」（变异：去掉 ext 那段比较即红）。
2. **幂等用例的说法改实（minor）**：`importing_the_same_foreign_logs_twice_changes_nothing` 去掉派生照样绿——同 ID 日志类
   的代表取操作号最小的那份（`cache.rs` `log_class_rep`），第二次导入的副本本来当不了代表。注释改为「防回归，不是修前红」。
3. **卡行的到期日 / 间隔从哪来（nit）**：内核卡片状态（`history.rs` `state_of`、新代经 `sync2/replay.rs` 重放）的队列、
   `dueDay`、`dueAt`、`scheduledDays` 全部取**最后一条有效日志的结果**；派生日志（评分等）的结果在重放时用前一状态重算。
   所以外来的更早复习排进来之后，本机那条仍是最后一条，但它的结果是在「前面多一条复习」的历史上重放出的，`dueDay` 与
   `scheduledDays` 一起变（实测：导入前 dueDay 21069 / ivl 329，导入后 20743 / 3，前面那条外来复习是「忘了」）——这是
   重放语义（设计 §4，与协议 3 同口径，Rust 用例用 `same_state` 对拍了协议 3），不是「到期与间隔来源不一致」。复习队列的
   `dueAt` 是 null（只有学习队列有），原先 Dart 用例只比 `dueAt` 等于没比。Dart 用例改为：最后一条日志仍是本机那条、
   reps = 2（外来那条排在前面）、卡行 (queue, dueDay, scheduledDays) = 本机那条日志重放后的结果、再导一次卡行逐列不变。
4. **独占站点开销冷 / 热分开钉（nit）**：同一服务第一次作答（冷）实测 4 条读（edits ×2、entities ×2）+ 3 条命令；第二次
   作答（另一张卡，热）0 条读 + 2 条命令。两者都钉进 `srs_exclusive_sites_cost_test.dart`（冷的读种类钉 `{edits, entities}`，
   热的钉空集）。上一轮写的「先打 `hello` 暖上后 3 条读 + 2 条命令」量的其实是 hello 之后第一次作答，作答自己那几条读在
   hello 里取不到；这一轮按实测改。
5. **空洞记号的信任面（nit，不改代码）**：`truth.rs` `land_void_mark` 在本库不知道那一格链值时信任流里的值，与空洞区间的
   `chain_after` 同一信任面。后果：用户导入过一份伪造了记号的 `.fushisrs` 之后，再导入同一作者的真实流会因「链值分叉」整笔
   拒收（拒收是整事务回滚，不丢已有卡片和复习记录）；伪造的记号也会随承袭段转发，对端同样拒收。恢复办法：还原到导入那份
   伪造流之前的整库备份，或不再导入该作者的流。单个空洞项的记号数只要求小于区间长度，内存占用
   受文件大小约束，没有另加上限。

### 没做 / 交给别人

- 本分支没在真机 / 双设备上实测回导与 `.fushisrs` 往返；证据是上面的 Rust / Dart 用例。
- Dart 回导用例（复核修复第 3 条）的新断言没有对内核做变异实测（要另编一份原生库）；内核那侧的排序由 Rust 用例变异实测过。

## 39. 第五波 重切件根治（K2 残余，2026-11-18，分支 `pr/srs-gen4-w5-recut-proof`，基于 `pr/srs-gen4-switch` `3d78fe51d0`）

§33「转发里的副本」记下的残余风险（受信重切者能换掉空洞之前的操作、链尾只核 4 字节标签）与复核 minor（作者段清单取各位置
最大代号、而代号与切点按位置各自走，合法的重切件被永远判 `Unlisted`；`Defer::Unlisted` 每轮重拉）在本节根治。§33 里
「现在的收法」「根治方案（没做）」两段描述的是被本节取代的旧设计，本节不改 §33 原文，以本节为准。

### 做法（可剔除的作者签名）

- **FSG4 作者签名改签逐项摘要**（`gen4/segment.rs` 文件头「签名」）：
  `digest = blake3("fushi-srs-seg/4\n" ‖ 段头 ‖ item_digest × n)`；操作项 `blake3(0x00 ‖ 信封 ‖ blake3(载荷) ‖ 清除目标 v1)`，
  空洞项 `blake3(0x01 ‖ 条数 uv ‖ chain_after)`。链定义（`chain_next4`）不变。段字节形状不变，黄金向量重生成
  （`GOLDEN_FILE` / `GOLDEN_FILE_SEALED` / `GOLDEN_RELAY` / `GOLDEN_RELAY_SEALED`）。签不出的段（某条操作的信封解不出，例如
  依赖里点了作者自己）`pack_native` 直接拒签，读者算摘要时报坏件。
- **清除目标 v1**（`gen4/op.rs` `purge_targets_v1`，冻结规则，镜像 `weigh.rs`「彻底清除」）：fmt 4 的 Edit（键不是 `deleted`）→
  (kind, entity)，卡片的 `deck` 编辑值是 JSON 字符串时再加 (Deck, d)；TagAdd / TagRemove / TagOrder → (Note, note)；其余为空。
  键按 `Key::of(text)` 归一。以后 Purge 语义变了要另立 v2（旧段的摘要里签的是 v1）。
- **FRX4 第 2 版**（`gen4/recut.rs` 文件头）：带作者原签名；槽 0 操作 / 1 作者空洞 / 2 剔除项（wall、logical、deps、kind、fmt、
  载荷哈希、清除目标、清掉它的 Purge 的 OpId）。重切者签名覆盖 `段头 ‖ 作者签名 ‖ recutter ‖ 明文压缩体`。`ver = 1` 一律按损坏拒。
- **读者**（`store/gen4/receive.rs` `native_inner`）：验重切者签名 → 结构（没有重切者自造的空洞、至少一个剔除项）→ 经剔除项重算链 →
  **作者签名**（留下的每条操作都是作者原件、每个剔除项对应作者签过的一条操作）→ 本机日志末尾之后的每个剔除项核对它点名的
  Purge（`purge_vouches`：日志或等待缓冲里有、是 `KIND_PURGE`、目标在剔除项的清除目标里、剔除项作者写它时没见过它）。
  Purge 本机还没有 = `Defer::PurgePending(OpId)`；管不到 = `Reject::NotPurged(OpId)`；Purge 的作者本机不信任 = `UntrustedUploader`。
  重切者信任闸保留，作纵深防御。`Defer::Unlisted`、`Truth::note_author_head` / `author_listed`、`gen4_ahead/…` 元数据键整套删掉：
  区间与链尾由作者签名担保，不再看任何位置的 head（复核 minor 的跨位置代号问题与无限重试一并消失）。开发期集成分支库里
  可能残留的 `gen4_ahead/…` 键没人读，无害。
- **材料在收段 / 清除时存下**（上一版卡在 `recut_from_log` 拿不到被挖操作的信封与载荷哈希）：SCHEMA **40024** 加两张本机状态表
  （不同步、不导出）：`relay_auth (col, device, first, last, head, sig, voids)` 每个区间记一份作者签名版本（只换成作者签的空洞
  更多的那份，`Truth::note_author_version`，收别的设备的原生段 / 中继件 / 重切件整段走完时记）；`relay_stubs (k, stub)` 剔除记录
  （`Truth::put_stub`：收重切件落下剔除项时、`Truth::advance_purge` 把别的设备的操作挖空之前按 `purge_covering` 找到的生效 Purge 记）。
  `recut_from_log` 用作者签名版本 + 日志里的操作 + 剔除记录拼出、先拿作者公钥核过再交 `recut4` 签出。
- 顺带修：`Truth::relay_purged` 遇到缓存里那份在这个 seq 上本来就没有内容的件（作者自己重切过的那份，或已是重切件）不再
  重切 / 删除（上一版靠旧重切路径碰巧保住，新路径下作者版本还没记进来时会把作者的新段删掉，
  `a_purge_by_the_author_takes_back_what_was_already_relayed` 抓到）。
- `gen4/segment.rs` 文件头与 FRX4 矛盾的那段（复核 nit）改写：只有作者签的空洞只能由作者签出，重切件留的是剔除项。

### 测试

- `gen4/recut.rs`：`the_author_signature_binds_every_kept_op_and_every_stub`（改留下操作的内容、重置空洞、改清除目标、伪造以后的
  seq 全拒；剔除项换一条别的 Purge 仍过作者签名——由读者核 Purge）、`stubs_round_trip_and_know_which_purge_covers_them`、
  `landing_items_chain_through_the_stubs`、`open_is_strict` 等 8 条。
- `receive.rs`：`a_trusted_recutter_cannot_forge_kept_ops_future_seqs_or_unpurged_stubs`（伪造留下操作的内容 → `BadSignature` /
  `ChainMismatch`；伪造以后的 seq → `BadSignature`；重置空洞 → `BadSignature`；剔除没有 Purge 管的操作（点名的是普通操作、清别的
  实体的 Purge、作者已见过的 Purge）→ `NotPurged`；Purge 未到 → `PurgePending`；都不落、不进等待缓冲；合法那份随后照收）、
  `a_legal_recut_lands_on_every_reader`（只有 Purge 的、有原文没 Purge 的、两者都有的、只有前一半的读者）、
  `recut_pieces_need_a_trusted_recutter_and_land_their_voids`（剔除记录与作者签名版本都记下）、`a_recut_of_my_own_log_must_carry_my_signature`、
  `an_op_with_a_bad_envelope_refuses_its_whole_segment`（改为手拼段，`pack_native` 已签不出）。
- `sync_state.rs`：`author_versions_keep_the_most_voided_and_stubs_round_trip`（取代 `the_authors_listing_only_moves_forward…`）。
- `cmd/purge_scrub_tests.rs` 五条端到端（含 `a_purge_by_the_relay_does_not_cut_off_a_location_only_it_feeds`、
  `a_purge_across_the_authors_cut_point_still_recuts_both_segments`）全绿，未改断言。
- 变异实测（脚本逐个改、跑、还原，工作区干净）：M1 不核点名的 Purge → forge 测试红；M2 不验作者签名 → forge 测试与
  `the_author_signature_binds…` 红；M3 收段不记作者签名版本 → `recut_pieces_need…` 与 `a_purge_by_the_relay_does_not_cut_off…` 红；
  M4 清除时不记剔除记录 → `a_purge_by_the_relay_does_not_cut_off…` 红；M5 缓存件不带内容也重切 / 删 → `a_purge_by_the_author_takes_back…` 红。

### 已知限制（如实记下）

- 受信重切者点名一条永远不来的 Purge：这一件一直 `PurgePending`、每轮按通用的「延后件重拉」再拉一次（与其它延后原因同一
  口径，不落、不进等待缓冲，不影响作者真正的段）。被拒的件同样按通用口径每轮重拉。
- ~~一批之内不重试~~：已修，见下文「复核修复」。
- `.fushisrs` 导出不带 `relay_auth` / `relay_stubs`：从备份还原的库再要从日志重切时缺材料，退回 `incomplete`（与 §33 的
  `log_marks` 同一类代价），归 G11 owner 评估导出流升版。
- 剔除项的载荷哈希允许「猜测确认」，与段头明文链值同类泄露，没有新增。
- 直接调 `advance_purge` 而本机没有生效 Purge 的路径（测试与工具）不记剔除记录：这一段本机重切不出来，转发退回「缺」。
- 协调目录 claim 没登记：本代理在隔离 worktree 里，写 `.worktrees/coordination/claims/` 被拒。

### 复核修复（2026-11-18，同分支）

- **压缩炸弹（major，相对基线的回归）**：FSG4 改签逐项摘要后，验签之前要先解压、逐项解码，明文位置上任何人放一个段头写着
  已知作者、签名乱填、里面一条高压缩比巨大载荷的件，读者每轮都在验签前分配 GB 级内存。修法是让验签前的工作量有硬上限：
  - `sync2/codec.rs` `ZstdWindow::limit(n)`：解压总字节超过 `n` 报 `LIMIT_EXCEEDED`（多解最多一个字节，窗口与解码器不为超限
    部分分配）；不设就是不限（导入、协议 3 路径不变）。
  - `gen4/segment.rs` `MAX_BODY_RAW = 64 MiB`：`ItemStream`（原生段 / 中继件，验签与校验两遍都走它）与 `recut.rs` `read_items`
    都带这个上限；写侧 `seal_native` 与 `recut4` 拒签解压后超限的段体。
  - `gen4/op.rs` `MAX_OP_PAYLOAD = 16 MiB`：`native_allowed` 写读两侧同用（本机写入 `append_native`、`pack_native`、收段）；
    读侧 `read_op_slot(…, max_payload)` 读到长度前缀就拒，不去补读。承袭段 `FSH4` 先验签（签名覆盖压缩体）后解压，传
    `usize::MAX`，行为不变。取值依据：本机真实库 `srs.db` `sync2_ops` 51.7 万条，最大载荷 311 KiB（只读查询）。
  - 写者保证不碰上限：发件 `outbox` 的 `segBytes` 夹到不超过 `SEGMENT_TARGET_BYTES`（4 MB 估计体积）；小段合并整组打一段时
    额外要求未压缩估计体积不超过 `SEGMENT_MAX_RAW_BYTES`（16 MiB），超了按 `min(target, 上限)` 切（以前只看压缩后体积，
    重复度高的内容能打出解压后几百 MB 的段）。
  - 测试：`a_decompression_bomb_is_refused_before_the_signature_within_bounded_work`（手拼 zstd RLE 帧，件本身 < 64 KiB：
    一条声明 1 GiB 载荷的 → `Corrupt("op payload too large")`；每条 1 MiB、总量过 64 MiB 的 → `Corrupt(LIMIT_EXCEEDED)`，
    都没走到验签）、`op_payload_cap_is_the_same_on_both_sides`、`zstd_window_limit_is_exact`、
    `a_group_that_compresses_small_but_is_large_uncompressed_is_cut`。
- **Purge 作者不受信 → 延后（minor，缺测试）**：`a_stub_naming_a_purge_by_an_untrusted_author_is_deferred_until_trusted`
  （待确认 / 已拒绝两态：`Deferred(UntrustedUploader(B))`、A 的日志不前进、没有剔除记录；信任之后同一件照收）。
- **一批之内的顺序**：`ingest` 里等 Purge（`PurgePending`）的重切件在整批交完之后再收一次（`Receiver::native_again`，先前
  那次延后不再计数）；预算截断时从这一件起由 Dart 下一个事务重交。测试 `a_recut_ahead_of_its_purge_in_one_batch_lands_in_that_round`
  （测试轮次 `Opts::recut_first` 把重切件排到最前面；修之前第一轮报 `PurgePending`、等待 3 条）。
- 变异实测（`mut.py` 逐个改、跑、还原，工作区干净）：去掉单条载荷前缀检查 / 去掉段体总量上限 / 去掉窗口超限判断 /
  去掉 `native_allowed` 载荷上限 / 合并不看未压缩体积 / 去掉 Purge 作者信任闸 / 去掉一批内重收，各自对应的测试都红。

### 复核修复后仍未做（如实记下）

- 受信重切者点名一条读者永远拿不到的 Purge、或 Purge 的作者被读者拒绝：这一件每轮按通用口径重拉（不丢数据；只经这位
  重切者供数据的位置对该读者仍然断流）。待办：按 (件名, 原因) 记延后次数或在 Purge 所在设备的 head 上退避。
- `relay_auth` / `relay_stubs` 的回收：集合删除**已经**覆盖（`discard.rs` 按 `sqlite_schema` 现查表，带 `col` 列的
  `relay_auth` 按 col 删、带 `k` 列的 `relay_stubs` 按设备主键区间删；复核说「集合删除不清」与代码不符）；本机自己身份的
  日志截断（换身份）不涉及（本机设备的操作不记剔除记录）。没做的是作者重切 / 合并之后旧区间的 `relay_auth` 行与已不需要
  转发的段的剔除记录：别的位置的 head 可能还列着旧区间，按区间回收要先定「哪些位置还需要」，留给 G8 转发 owner。
- 发件 `segBytes` 夹紧没有单独测试（要 4 MB 以上的数据，本机内存紧，没写）。

## 40. 第五波 保留副本与清除提示（2026-11-18，分支 `pr/srs-gen4-w5-retain-ui`，基于 `pr/srs-gen4-switch` `3d78fe51d0`）

补规划 §6 K2 新增的两条合并条件与 D32。schema 不变（40021，没有加表 / 索引；新增的只是 `srs_meta` 的三个键），
`ABI_VERSION` 不变（新增的是两条全局 JSON 命令，经已有的 `ffsrs_call`）。

### 内核（`native/fushi_fsrs/src/store/gen4/retained.rs`，测试 `retained_tests.rs`）

- **到期规则（定案）**：新代**第一次同步成功**之后 14 天；**从没同步成功过**（没有同步位置、或位置一直没跑通）按
  **迁移提交之后 30 天**——设计 §9 第 3 项「从不同步的保留 30 天」的等价落法，`N = 30`。两个时刻都没有（这一版之前的开发
  构建迁出来的库）不自动删、只能手动删。第一次同步成功之后到期时刻改按它算（可能晚于「迁移 + 30 天」，例如第 29 天才
  第一次同步成功 → 第 43 天）：设计的意思是「新代同步跑通之后再留两周退路」，不取两者较早的。
- **时刻怎么记**：`gen4_migrated_at_ms` 在迁移提交步骤里写进临时文件（随改名一起提交；断点续做与补改名都是同一个文件，
  所以带着）；`gen4_first_sync_ok_ms` 在 `cmd/sync.rs` `head` 的写事务里 `INSERT OR IGNORE`（走到写 head 就是这一轮在这个
  位置上成功了，`last_ok` 同一处），只记第一次。没有这一行但 `loc_state.last_ok` 有值的库取其中最早的。
- **到期自动删**：Primary 打开新代库（`files::open_gen4`，持换代锁，在 `finish_seal` 之后）时，保留副本在、到期了就核对、
  换墓碑。核对 = `files::open_ready`（已经做过）+ `PRAGMA quick_check` = `ok`；再由 `seal::write_tombstone` 自己核对
  「是封存进旁边这份新代库的保留副本」。**核对不过不删**；自动删没做成不挡开库，原因记进 `srs_meta.gen4_retained_error`
  （状态命令报给设置页 / ctl），做成了删掉。保留副本读不了（`retained_copy_unreadable`）时不碰它。
- **为什么在开库时而不是同步后**：开库在锁里、有核对过的新代库连接，app 与服务端同一处；同步一轮在写连接的事务里，换
  墓碑要的「本机没有任何连接开着旧库」在那里不好保证。代价：到期之后要等下一次开库（下一次启动）才真正删。
- **立即删除**：全局命令 `gen4_retained_delete {dir}` → `{deleted, freedBytes}` / `{deleted: false, reason: absent | migrating}`，
  不看到期，同样的核对，核对不过报错、什么都不动。`gen4_retained_state {dir, now}` → `{copy: sealed|tombstone|absent|other,
  bytes, migratedAtMs, firstSyncAtMs, dueAtMs, due, error}`，只读（要打开两个 SQLite 文件，Dart 侧在后台 isolate 调，见下文
  「复核修复」）。看保留副本
  一律**只读**打开：读写打开会在旁边建 `-wal` / `-shm`、改掉文件状态，让 `RETAINED_UNRELATED_KEY` 的「判过不是迁移来源」
  失效、每次开库重算整库摘要（第一版就这么踩了，`an_unrelated_older_library_is_digested_once_per_file_state` 红）。
- **测试时钟**：开库用真实时钟判到期，而测试的迁移时刻 `NOW` 在 2023 年，所以测试里迁移完再 Primary 打开的库都会当场换成
  墓碑。全量 1398 条照样绿（墓碑同样是 `SEALED_SCHEMA`、旧版本照样拒绝）；要验「没到期不动」的用例先把迁移时刻挪到将来。

### 迁移状态机（§11 已知项）

- 没有协议 3 身份的原件对拍中止后，报告的 `legacyIdentity` 是 null，`migrate::status` 以前要求身份非空才认报告，于是报
  `needsMigration`，服务端每次启动自动重迁、每次再中止。现在 null 与 null 也算「是这份」→ `migrationFailed`：认不出是不是
  同一份（没有身份、整库摘要太重不进状态命令），但误判成「上次失败」只多一次手动「重新升级」，反过来是无限重迁。有身份的
  库不会被 null 身份的报告认走。测试 `prepare_tests.rs` `an_aborted_migration_of_a_library_without_identity_reads_as_failed`。
- **「迁移中关库之后『开始升级』仍可点」委托描述与代码不符**：§11 已经做了（`SrsGen4MigrationController.canStart` 看
  `isDatabaseOpen`、`databaseClosing`，页面置灰并显示 `srs_gen4_closing`，`srs_generation_view_test.dart` 覆盖），本分支没再改。

### Dart

- `fushi_srs` `srs_retained_copy.dart`：`SrsRetainedCopyBackend`（`state` / `delete`，后者在后台 isolate），真实实现走
  `callGlobal`。
- 设置 › 存储 › 维护「删除旧版本保留副本」（`storage.srs_retained_copy`）：只在本机有封存的保留副本时出现，副标题 = 大小 +
  到期日（或「删除前一直保留」/ 自动删出错的原因），点了先确认（不可撤销、之后不能退回旧版本、清除过的原文随之消失）再删。
  控制通道上这一行声明 `unsupported`，指向下面的 ctl 操作。
- ctl：engine `srs_ctl_routes.dart` 新增 `GET /api/admin/srs/retained` 与 `POST /api/admin/srs/retained/delete`（要
  `confirm: true`，核对不过回 409 `retained_copy_kept`），描述 `srs.retained.status`（read）/ `srs.retained.delete`
  （irreversible + userGate `confirm`）在 `srs_ctl_ops.dart`。`SrsCtlHost` 新增 `libraryDir`：app 给 `AppModel.srsStorage.directory`
  （主库没开好 = null → 422），服务端给 `ServerSrs.support.path`——**服务端 admin 的入口就是同一组路由**（`server.srs.retained.*`，
  admin API 同路径），不另写一份。
- 彻底清除（`srs_deck_list_page.dart` 删牌组 → 彻底清除）：本机有保留副本时选项说明换成 `srs_deck_delete_purge_retained_hint`
  （保留副本里仍有升级前的原文，直到它被删除：到期自动删，或 设置 › 存储 里立即删）；选了彻底清除后再问一次去向：
  「只彻底清除」/「彻底清除并立即删除保留副本」（后者清除做完再删，结果 toast）；取消 = 整次删除不做。没有保留副本时不问。
- `SrsDbStore.scrubState()` 读内核 `scrub_state`（走写锁队列，不进 `kSrsSync2LockFreeOps`：那张表有逐项守卫，读一次很便宜）。
  `SrsScrubErrorNotice`（随复习库修订号重读）放在同步与历史页（云同步说明下面）和牌组列表横幅最前：`error` 非空时显示
  「清除的内容在磁盘上还没抹干净：<原因>」。

### 复核修复（2026-11-18 第二轮）

- **到期自动删的删前核对补了测试**：`an_expired_copy_is_kept_when_generation_4_fails_its_check_on_open`——迁移时刻设成已到期、
  新代库多一页没人用的页（打得开、`quick_check` 不过），Primary 开库：副本仍是 `Sealed`，`error` 含 `integrity check`，开库
  照常。变异：删掉 `sweep` 里的 `verify_gen4(ready)?;` 这条红。
- **立即删除不再拿新代库的写锁**：以前换上墓碑之后还要 `DELETE` 掉 `gen4_retained_error`，同步正占着写锁时超过 busy timeout
  就整体报错——ctl 回 409、app toast「没删」，文件其实已经换了。现在 `delete` 只读核对新代库、换墓碑，删成没删成只看墓碑；
  `gen4_retained_error` 改成「只在副本还是 `Sealed` 时有意义」：`state` 只在那时报它，陈旧的那行由下一次 Primary 开库的
  `sweep` 删掉（副本不在时）。测试 `deleting_now_succeeds_while_another_connection_holds_the_write_lock`（另一条连接
  `BEGIN IMMEDIATE` 占着写锁时删 → `deleted: true`；陈旧原因不报；开库后那一行没了）。四处变异（删 sweep 核对 / `delete` 里
  恢复写库清原因 / 去掉 `state` 的过滤 / 去掉 `sweep` 的清理）各自变红。
- **状态命令挪到后台 isolate**：`SrsRetainedCopyBackend.state` 改成 `Future`，真实实现跟 `delete` 一样走 `Isolate.run`；app
  侧新增 `srsRetainedCopyProvider`（`FutureProvider`，随复习库修订号重读，删完调用方 `invalidate`），设置行的 `visible` /
  副标题 `watch` 它（读好之前行不显示），删牌组 `await` 它。没有实测 UI isolate 上的耗时：既然要开两个 SQLite 文件，直接按
  「可能 >1 ms」放后台，不再纠结数字。
- **状态读不了不挡删牌组**：读失败（内核报错）在 provider 里记日志、按「没有保留副本」处理（它只决定提示文字和入口显不显示；
  删除本身同样会被内核拒绝）。设置页原来各自接异常的代码删掉，统一在 provider。
- **没有到期时刻的副本**：彻底清除的说明与「只彻底清除」选项的副标题换成「直到你在 设置 › 存储 里删除它（不会自动到期）」
  （`srs_deck_delete_purge_retained_kept_hint` / `srs_deck_delete_purge_retained_keep_kept_hint`），不再一律写「到期自动删除」。
- **页面接线测试**：`fushi/test/srs/srs_retained_copy_wiring_test.dart`——真牌组列表上右键删牌组：有副本时彻底清除的说明是
  保留副本那句，选彻底清除后出第二个对话框，选立即删除 → 执行端被调到、状态重读、牌组没了；状态命令抛错时说明是原来那句、
  不问去向、删除照常做完；设置 › 存储的 `storage.srs_retained_copy` 行：有副本时可见、副标题是大小 + 到期，点它确认后删、
  删完行隐藏。
- 复核里「无身份中止的状态机测试用的是手写报告」没改：真实写报告处（`migrate.rs` `report.insert("legacyIdentity", json!(identity))`）
  没有身份时就是 null，与手写报告一致。

### 没做 / 归属

- **profile 级删除（`srs_profile_cleanup.dart`）没加保留副本说明**：那条路是本机删数据、先导出 `.fushisrs` 备份当撤销途径，
  原文本来就留在备份文件里；保留副本说明只加在会同步到各设备的「彻底清除」上。要不要在删 profile 的确认框里也写，交 UI owner。
- 服务端 WebUI 没加按钮（admin API / ctl / AI 操作目录都有）；`fushi_server ctl srs` 没加专门的子命令（走通用的操作目录）。
  归 G10 后续。
- 位置上的旧根（`v3/`）不自动删（设计定案），不在本块。
- 真机验证按用户 07-29 指令不做。

## 41. 第五波 测试与守卫（2026-11-18，分支 `pr/srs-gen4-w5-tests-guards`，基于 `pr/srs-gen4-switch` `3d78fe51d0`）

只补测试、守卫与夹具，没改生产行为；SCHEMA 不变（40021）。生产代码唯一的改动是 `gen4/migrate.rs` 里一个 `#[cfg(test)]`
钩子（`STAGE_CONN`，暂存库刚打开时交给测试一次，用来注入「写到一半磁盘满」）。

### 1. 规划 §6 源码守卫补齐 4 条（目录枚举型）

| 守卫 | 位置 | 变异实测 |
|---|---|---|
| 活代码里没有协议 3 旧表名（Rust：`gen4/**/*.rs` 去掉测试模块与 `#[cfg(test)]` 之后；旧表名 = 协议 3 建表语句里的 `srs_*` / `sync2_*` 减去新代同名表；冻结侧白名单 `carry` / `cmd/backup` / `compare` / `dryrun` / `legacy` / `media`（`seed_legacy`）/ `migrate`（空间估算），白名单过时也红） | `native/fushi_fsrs/src/store/gen4/guards_tests.rs` `live_code_names_no_protocol_3_table` | `cmd/reads.rs` 末尾加一句含 `srs_review_logs` 的常量 → 红 |
| 同上（Dart：生产代码不写协议 3 `sync2_*` 表名） | `fushi/test/build/srs_gen4_source_guard_test.dart` | 见下 |
| SCHEMA 冻结：`application_id` + `sqlite_schema` 全部行的 blake3 按号钉死（`40_021` 一条），改表不升号就红 | `guards_tests.rs` `the_gen4_schema_is_frozen_at_its_number` | `schema.rs` 的 `TRUTH` 多建一张表 → 红 |
| 命令登记：`dispatch.rs` 的 `run()` 每个分支都在 `wiring()` 登记、登记的 `Wired` 都有分支（Rust）；Dart 侧 SRS 面（`fushi_srs` 库、`/srs/` 路径、`srs_*.dart`、import 了 `package:fushi_srs/` 或 `package:fushi_engine/srs/` 的文件）里每个 `'op': 'x'` 必须是 `Wired` 或 `lib.rs` 的全局命令（`dispatch` + `ffsrs_fit`） | `guards_tests.rs` `every_dispatched_command_is_registered_and_every_registered_one_has_an_arm`；Dart 同上文件 | `status` 改登记成 `Removed` → Rust 红；Dart 发一个没登记的 op → 红 |
| 生产代码不把同步目录名当 profile uid（`profileUid: x.uid` / `x.uid == profileUid` / `xxxUids.contains(x.uid)` 等；禁 `srsHostPathProfile`） | `srs_gen4_source_guard_test.dart` | 追加一个 `profileUid: r.uid.toString()` 的函数 → 红 |

- **与委托描述不符**：委托与审计 C9 写的「在 `ops.rs` 登记」——本分支没有 `ops.rs`（只在没合的 `pr/srs-ffi-op-meta` 上），登记表是
  `gen4/dispatch.rs` 的 `wiring()`，守卫按它写。`ops.rs` 合进来时要把守卫的解析对象换过去。
- **目录名当 uid 的已知违例（棘轮，归 G9-5）**：`packages/fushi_engine/lib/srs/srs_profile_link.dart` 四处按远端目录的 `r.uid`
  比 / 传 `profileUid`（`_kKnownDirAsUid` 逐行登记，只许减不许加）。同文件 `:95` 的 `uuidV5(srsNamespace, 'fushi-srs/tombstone/4/$dir')`
  另外让既有守卫 `srs_kernel_ids_guard_test` 红（生产代码自己做带盐派生），同归 **G9-5**。
- Dart 守卫：`dart tool/heavy.dart -- flutter test test/build/srs_gen4_source_guard_test.dart` 4/4；三处变异各红一条。

### 2. 迁移：写到一半出错、双 profile 一个对拍不过（审计 C4）

`native/fushi_fsrs/src/store/gen4/migrate_tests.rs` 新增两条：

- `a_disk_full_midway_through_staging_leaves_the_library_as_it_was`：暂存库刚打开时把 `max_page_count` 压到当前页数，转译写满
  → 迁移返回含 `full` 的错；走到了 Translate、没走到 Commit；旧库去掉文件头计数字段后逐字节不变；`GEN4_FILE` / `GEN4_TEMP` /
  `PREPARE_COPY` 都不在；状态仍是 NeedsMigration；去掉钩子重跑提交。
- `one_failing_profile_of_two_keeps_the_whole_file_uncommitted`：两个 profile 各一个集合，对照先证明能提交；改坏第二个 profile 的
  缓存后 → `Aborted`，逐 profile 结论 `[(P, pass), (Q, fail)]`，没有 `srs4.db`，旧库逐字节与 schema 不变，状态 MigrationFailed；重复两次同结果。
- 变异：`dryrun.rs` 的总结论只看第一个 profile → 第二条红；`migrate.rs` 出错不删临时文件 → 第一条红。

### 3. `srs_p6_vectors_test` 改吃冻结的协议 3 库（§32 K1 留下的步骤）

- 夹具 `packages/fushi_engine/test/srs/fixtures/p6_vectors.db.gz`（约 3.2 MB）：在 S1 之前最后一个协议 3 提交 `5ad47c2edb`
  （S1 合并 `c9d7703dd6` 的第一父）上生成——1200 份历史各一个 profile `p$i`、卡 `v$i`，日志与服务器时刻按向量灌入，每个 profile
  `sync2 identity` + `migrate`，再 `snapshotInto(stripDeviceLocal: false)` + gzip。schema 29、8548 条日志全部进 `sync2_ops`。
  生成时协议 3 上 4 条用例全绿。注意：向量 JSON 里日志的 `card` 是占位（`c` / `pred`），与 `card_id` 列不一致时迁移对拍
  1080/1200 判 fail（这是对拍正确拦下了自相矛盾的库），生成时把 JSON 改写成 `v$i` / `p$i` 后迁移提交。
- 测试经 `openMigratedTestSrs` 打开；新代按 profile 取数（`gen4: the cards of this request have history in 240 collections`），
  优化器 / RWKV / 统计 / 历史状态都改成一份历史一条命令带 `profile: 'p$i'`。4/4 绿；变异（每份历史问错一个 profile）→ 3 条红。
- 性能旁注（未立项）：统计取数不带 `profile` 时按卡解析集合，跨 1200 个集合实测约 6 分钟；带 `profile` 后整份 1 秒内。生产调用
  都带 profile，记在这里备查。

### 4. `srs_rwkv_service_test` 40 红（委托 ⑤）

根因是**测试过时**，不是内核缺陷：G7-4f 起新代日志序号从 `SEQ_BASE = 2^40` 之后发（`log_seq`），RWKV 编排录制的游标
（`since` / `rebaseSince` / `maxRowId`、快照 `.snap.json` 的 `maxRowId`）还是协议 3 的 rowid。40 条用例与录制只差这个偏移。
修法：`test/srs/support/srs_rwkv_transcript.dart` 按新代落库序记游标（`cursor()` 减去 `kSrsGen4LogSeqBase`，0 / null 原样，
≤ 基数直接判错）；「删过日志」那条改成经原始通道同时删 `log_ix` 与 `log_seq` 里最早一条（只删 `log_seq` 会报
`log op has no arrival order`）。49/49 绿；变异（不减基数）→ 40 红。录制文件没改。

### 5. 设计稿 §6.3 / §5.5 逐行对照（审计 C5）

§6.3 的逐行表在 §31 第 4 条；本段在本分支逐个核过那张表里的测试名都还在（30 个名字全部能在树里找到），只更新变化的行：

| §6.3 行 | 本段更新 |
|---|---|
| 回退到旧版本 | 新增 `store::seal::tests::a_generation_4_library_copied_under_the_old_name_is_refused_by_protocol_3`：新代库拷成 `srs.db` 交协议 3 内核打开 → 拒开，页内容（抹掉文件头计数字段）与 `srs_meta` 不变，新代仍能打开。变异（协议 3 不拒更新的 schema）→ 红。反方向（协议 3 库改名成 `srs4.db`）原有 `gen4/files.rs` `a_protocol_3_library_under_the_new_name_is_refused`；封存库原有 `seal.rs` `a_sealed_library_is_refused_by_protocol_3_and_its_pages_stay`。四个方向（新读旧、旧读新、新读封存、旧读封存）本机层都有了；**位置层**仍只有 `srs_format_break_test`（协议 1 客户端）与围栏内容钉死，没有真跑协议 3 客户端（树里没冻结 v3 客户端），同 §31 |
| 新装的新版本设备加入全是旧版本的位置 | §31 标「缺单独一条」**不准确**：`cmd/sync_tests.rs` `the_location_root_fences_protocol_3_and_refuses_what_it_cannot_read` 的设备是 `Dev::new`（空目录新装、没有迁移来源），断言它在存量协议 3 位置上建新根、立围栏、`fresh: true`。改记为已覆盖 |
| 同机多 profile | 新增 `one_failing_profile_of_two_keeps_the_whole_file_uncommitted`（见第 2 条） |
| 两台同时升级 | 迁移层已补（第 9 条）：`gen4/migrate_tests.rs` `two_devices_upgrading_at_once_translate_the_same_bytes`。位置层「两台重叠上传承袭段幂等」没有两台真并发上传的端到端用例（本段没核位置层现有用例能否覆盖），归 G7 / G8 |
| 服务端 / 客户端先后升级、服务端一直不升级 | 仍缺，归 G10（同 §31） |
| 只有协议 1 旧根 | 仍按 D21 偏离定案拒绝，只读转译缺，等所有者确认（同 §31） |

`srs_format_break_test`（`packages/fushi_engine/test/srs/sync2/`）仍在，本段没动它；第 7 条的全量跑里它没有红。

§5.5 逐行：

| §5.5 行 | 覆盖 |
|---|---|
| 一个集合、多台设备共用同一个 uid | `gen4/legacy.rs` `a_duplicate_skeleton_in_the_log_becomes_an_alias`、`cmd/identity_tests.rs` `alias_class_members_canonicalize_through_the_identity_commands`、`cmd/identity_tests.rs` `profiles_bind_to_their_own_collections_and_an_unbound_one_joins_first` |
| 多台设备各自一个 uid、从没关联过 | `cmd/profile_data_tests.rs` `a_new_device_binds_to_an_existing_collection_without_a_join`；关联流程 Dart `srs_profile_link_sync_test`（§35） |
| 已经用旧办法并入过的库 | 写入者归回 `gen4/alias.rs` `a_renamed_writer_goes_back_to_the_original_when_the_dots_agree`、`gen4/class.rs` `a_renamed_writer_on_a_class_of_one_is_not_the_raw_reading`；§5.3 正向计算 `src/gen4_ids/tests.rs` `a_fallback_root_with_its_own_record_takes_its_children_along`、`a_chained_fallback_definition_takes_its_cards_along`；真实样本库对拍见第 6 条 |
| 并入做到一半 | `prepare_tests.rs` `a_half_done_merge_is_migrated_and_finished_in_the_new_generation`、`a_half_done_merge_with_remapped_copies_folds_them_back_into_one`、`finishing_a_half_done_merge_*` |
| 本机去重作业没做完 | `prepare_tests.rs` `interrupted_ingest_leftovers_are_finished`（夹具带 `sync2_dedup` 没做完的作业，补完后迁移提交） |
| 同机多个 profile | `identity_tests.rs` `profiles_bind_to_their_own_collections_and_an_unbound_one_joins_first`、本段 `one_failing_profile_of_two_keeps_the_whole_file_uncommitted` |

### 6. 设计稿 §10 第 23 条（G6c + 收段通道合起来对拍 5 条红）

**在当前样本库上已不复现，可以关闭**，证据：本分支（含 G6c 与 #3314 收段通道两条链）的 `examples/gen4_dryrun`（`--profile quick`）
对本机样本库 `srs.db` 的副本（1.1 GB，schema 29，单 profile；缓存配置由 `srsCacheConfigFor` 生成）干跑：`verdict: pass`、
`parity: []`、`knownDifferences.total = 0`（examined 340527）、日志 59465 / 有日志的卡 3898 新旧逐类相同，用时 208 s。
限制：样本库自 #23 记录时（1.75 GB）已被用户整理过，原始那份快照不在了，所以是「当前库上不再有差异类别」，不是逐条复现
原 5 条再判因。设计稿 §10 第 23 条本段没改（规则：只写自己的段），交 integration owner 按此关闭。

### 7. `packages/fushi_engine/test/srs` 全量现状（`dart test test/srs -j 2`，本分支 `8941cb4acd`）

exit 1；成功 949、失败 9、错误 6、跳过 21，实际执行 964。上一轮（本分支动手前）是 906 / 48 / 8 / 21：rwkv 40 条、p6 2 条已清。剩 15 条：

| 文件（条数） | 现象 | 归属 / 判断 |
|---|---|---|
| `srs_optimizer_test`（1） | 5 分钟超时 | **ENV**：动手前的全量里同一条 160 s 绿；本轮跑时本机 CPU 96%（别的进程），单跑也超时。库与测试都没变 |
| `srs_browse_vectors`（1） | 卡 ID 列表不同 | G9-7（夹具卡 ID 是旧口径，§26） |
| `srs_write_preread_cost`（1） | 彻底清除语句数 973 → 958 | G9-7（§26 记 2 条，现剩 1 条） |
| `srs_kernel_ids_guard`（1） | `srs_profile_link.dart:95` 自算 `uuidV5(…tombstone/4/$dir)` | G9-5（见第 1 条） |
| `srs_db_store_test`（1） | 覆盖恢复备份：`no such table: srs_local_state` | G11-4（§26） |
| `srs_exclusive_sites_cost`（1） | 第 10 步 `remoteAnswer` 计数不同 | G10-2（§23 记过同一步） |
| `srs_media_presence`（2）、`srs_media_sync`（1）、`srs_style_dedup`（1） | 媒体清单 / 可疑标记 / 补传计数不对 | G8-7b 同步媒体（§26） |
| `sync2/srs_sync2_bootstrap_channel_entry`（3） | 查协议 3 表 `sync2_ops` / `sync2_boot_order`、`missing location` | 测试过时（断言协议 3 收段通道表），G8-7b 改写或删 |
| `sync2/srs_sync2_head_gap`（1） | 取 head 引用段 `Null check` | G8-7b |
| `sync2/srs_sync2_relay`（1） | 经互联转发后 C 没收到 A 的笔记 | G8-7b / G10-4（互联 host 目录，§31 也记缺） |

### 8. 审计 C0：G10-4 段里「旧根命令没有 Dart 调用方」不对

§34（G10-4）两处写「旧根两条命令目前还没有 Dart 调用方（同步轮 2b 步未接线）」。本分支上已接：
`packages/fushi_engine/lib/srs/sync2/srs_sync2_round.dart:286` 调 `srsSync4TakeOldRoot`，`srs_sync4_steps.dart:92` 发
`oldroot_scan`、同文件发 `oldroot_ingest`。**真正没接的是** `heritage_plan` 回包的 `unvouched`：Dart 里一处都没读
（`git grep unvouched -- '*.dart'` 为空），同步页也没提示——归同步轮持有者（G8-7c / G9-5）。

### 9. 复核后修正（同一分支第二轮）

- **Rust 旧表名守卫有盲区**：`live_code` 原来在第一个 `#[cfg(test)]` 处截到文件尾，「测试模块都在末尾」不成立——
  `kernel.rs`（`:388` 的 `test_panic` 注入之后，含 `run_migration`）、`cmd/mod.rs`（`:87` 起一串 `#[cfg(test)] mod x;`
  之后，含 `profile_of` 等约 510 行）、`cmd/fushisrs.rs`（`:151` 的 `meter` 注入之后，整个导入导出）、`files.rs`
  （`DIGESTS` 之后，含 `open_ready`）、`gen4/mod.rs`（`guards_tests` 声明之后）都没扫到。改成**按条目去**：每个
  `#[cfg(test)]` 只去它管的那一项（`mod x;` / 带属性的语句到 `;`，`mod x { … }` / fn / impl / `thread_local! { … }`
  按括号配对到块尾，结构体字段到 `,`；字面量里的括号不算；声明头部的 `<…>` 配对），行号不变。新增
  `live_code_strips_only_the_cfg_test_items`（合成源码逐项断言留 / 去）与 `live_code_keeps_production_code_after_test_hooks`
  （上述五个真实文件里注入点之后的生产代码还在、测试项已去）。按新口径扫，现有活代码里仍没有旧表名。
- **冻结侧白名单按表放行**：`FROZEN_SIDE` 从「文件 → 理由」改成「文件 → 理由 + 允许的表」，冻结侧文件里新写一张没登记的旧表
  照样红，登记了却已不写的表也红。`migrate.rs` 只许 `srs_cards_cache` / `srs_notes_cache` / `srs_stat_reviews`，`media.rs`
  只许 `sync2_media_at` / `sync2_media_seeded`，其余五个文件按现状逐表登记。
- 变异：`kernel.rs`、`cmd/fushisrs.rs` 末尾各加含旧表名的常量 → 守卫报 `kernel.rs:853`、`cmd/fushisrs.rs:576`（原来不报）；
  `migrate.rs` 末尾加 `sync2_ops` → 报 `migrate.rs:1055`（原来整份放行）；`live_code` 改回截到文件尾 → 两条自检红。
- **§6.3「两台同时升级」迁移层用例**：`migrate_tests.rs` `two_devices_upgrading_at_once_translate_the_same_bytes`——同一份两
  profile 的协议 3 库拷两份，分别以不同的新设备 ID、迁移时刻、批大小迁移；比较每个集合的集合标识 / 目录名 / 盐集合、
  `location::meta4` 字节、新身份的签名钥匙与 `prev`、每台承袭设备每个槽的规范编码、原生日志每条操作的 (kind, fmt, deps,
  载荷)，逐行相等。绿：本机转译与设备无关。变异（`dryrun.rs` 写 `Salts` 时把新设备 ID 混进盐集合）→ 红。
- **Dart 命令登记守卫**：原来只认 `'op': '字面量'`。改成取 `'op':` 后面整个值表达式，条件表达式两侧（可嵌套）各自当命令查；
  值不是字面量的必须逐条登记在 `_kOpForwarders`（死条目也红）。新口径扫出两处非字面量，都不是内核命令：
  `fushi/lib/src/srs/srs_remote_store_client.dart` 的 `'op': op`（互联远端复习 V2 协议的动词，主机 `srs_remote_store_routes.dart`
  → `service.call` 自己路由）与 `packages/fushi_srs/lib/src/search/search_kernel.dart` 的 `'op': compare.name`（搜索树比较节点的
  比较符），登记了理由。另加解析自检一条。变异：`srs_db_store.dart:1625` 条件表达式的 `'import_drafts'` 改成没登记的名字 → 红
  （原来条件表达式整个漏检）。不经 dispatch 的 `ffsrs_store_*` 直连 C 入口仍不在这条守卫范围内。
- **p6 冻结库生成脚本留档**：`packages/fushi_engine/test/srs/fixtures/gen_p6_vectors_db.dart.txt`。按第 3 条描述与夹具内容复原
  （灌库同 `5ad47c2edb` 上 `srs_p6_vectors_test` 的 setUpAll，落库前把日志 JSON 的 `card` / `p` 改写成 `v$i` / `p$i`，
  每个 profile `identity` + `migrate` 循环到 `done`，时刻 `1767225600000`，`snapshotInto(stripDeviceLocal: false)` + gzip）。
  对已入库夹具核对过：schema 29、日志 8548 条且 jslim 的 `card` 全部等于 `v$i`、`srs_event_local` 2811、`sync2_ops` 8548、
  `sync2_self` 1200 行且 `migrated_at` 全是 `1767225600000`。**没有在 `5ad47c2edb` 上重跑逐字节比对**。
- 还原了 `store/seal.rs` 里一处与本段无关的空白改动（`static TRACED:` 少了空格；rustfmt 不进花括号宏所以 `fmt --check` 不报）。
- 第 6 条（§10 第 23 条）的口径不变：只证明当前样本库上没有差异类别，不是逐条复现原 5 条；接不接受这个口径关闭由 integration
  owner 定，不接受就要找原 5 类差异对应的代码路径补定向测试。

### 没做

- §6.3 服务端 / 客户端先后升级三行、协议 1 只读转译、位置层真跑协议 3 客户端、两台并发上传承袭段的位置层端到端（见第 5 条，按归属）。
- `unvouched` 提示（第 8 条）。
- 第 7 条表里的 14 条非 ENV 红，按归属各自修。

## 42. 第五波 G7-6 删旧投影、协议 3 代码冻结（2026-11-18，分支 `pr/srs-gen4-g7-6-delete-legacy`，基于 `pr/srs-gen4-switch`）

### 做了什么（按提交）

- `30ae9c49d2`：删协议 3 并入暂缓整条链（`SrsDeferredProfileMerge` / `SrsProfileAdoptDeferred` / `deferredMerge`、调度器的
  发布与读取、`srsDeferredProfileMergeReaderProvider`、历史页那一行）与三个死 i18n key（`srs_timeline_merge_deferred` /
  `_hint`、`srs_sync_profile_merge_queued`，`i18n_sync --remove`）。
- `d5ea00ca1a`：删 app 内换代前预演（`dryrun.rs` 的登记 / 报告 / 取消 / 关库等待，`ffi.rs` 三个 `gen4_rehearse*` 臂；新代
  wiring 仍报 `Removed(NO_REHEARSAL)`）。离线干跑 `dryrun::run`（`examples/gen4_dryrun.rs` 与测试夹具用）保留。迁移拿锁后
  清掉库旁残留的 `gen4-rehearsal/`（`migrate.rs` `remove_leftover_rehearsal`，测试
  `a_leftover_rehearsal_work_dir_is_removed_by_the_migration`，变异实测删掉清理即红）。
- `62708c3258`：协议 3 的 JSON 分发器从 `store/ffi.rs` 整段搬进冻结侧 `store/legacy3/mod.rs`。生产入口
  `legacy3::dispatch` 只认 `FROZEN_OPS`（`cache_config_set` / `migrate` / `apply` / `dedup` / `replay_pending`，换代迁移
  `prepare.rs` 与整包备份读入 `cmd/backup.rs` 用），其余约 90 条臂、`if op == …` 分支与只给它们用的前置步骤一律
  `#[cfg(test)]`。测试入口 `legacy3::sync2_dispatch`（全部臂）照旧给协议 3 测试与对拍装置。守卫：
  `only_the_frozen_commands_are_compiled_into_production`（按源码核对没被 `cfg(test)` 门住的臂 = `FROZEN_OPS`）、
  `the_production_entry_refuses_every_other_command`；`every_protocol_3_command_has_a_gen4_wiring` 改读 legacy3 源码。
  变异实测两条守卫都红。
- `a3eefaf97f`：删 6 个 `ffsrs_store_legacy_*` C 入口与 `gen4/kernel.rs` 对应未接桩。只被测试臂用的约 540 个函数 / 常量 /
  结构 / 方法（`store/sync2/*`、`reads`、`projections`、`profile_data`、`read_pool`、`registers` 等）收进 `#[cfg(test)]`，**不删**
  （仍是对拍语料与 gen4 测试夹具的生成器）。默认 quick 构建告警 8 → 7（dead_code 1 → 0）；`--features id_audit` 96 → 12
  （余下 12 条全是基线既有）。**更正**：这一轮的「dead_code 0」里有 17 条是结构级 `allow(dead_code)` 压下去的，复核后已改成
  按字段 / 类型门住，见下文「复核跟改」。
- `86078b46d4`：删 Dart 协议 1 主库搬迁（`srs_legacy_store_migration.dart`、`SrsCore.legacy*` 与 6 个符号查找——查找是绑定
  构造时一次做完的，原生侧删了符号不跟着删会让整个绑定构造失败）。检测与拒绝 `SrsLegacyMainDatabasePending` 保留，提示改成
  「先用旧版本打开一次完成搬迁」，测试改名 `srs_legacy_main_database_test.dart`。`srs_db_store.dart` 两张命令表去掉新代
  `Removed` 的 op。`gen4/dispatch.rs` 新增 `PROJECTING_OPS` 作 Dart `kSrsSync2ProjectingOps` 的锚（原锚随分发器进了 legacy3），
  测试 `projecting_ops_are_wired_and_cover_every_local_write`（变异实测删一条即红）；`srs_read_only_executor_guard_test` 改读它。

### 取舍（下一棒照此理解）

- **实现链原地冻结、不搬文件**：协议 3 的实现仍在 `store/`、`store/sync2/` 原文件里，生产构建只编得进 `legacy3::dispatch`
  够得着的部分。没有整体搬进 `store/legacy3/`：并行模块正改着同一批文件，搬会成片冲突；冻结边界由编译门（`cfg(test)`）与上面的
  源码守卫钉住，不靠目录。
- **冻结内核共用的结构**里只在测试臂里读的字段 / 变体：已撤掉初版的结构级 `allow(dead_code)`，改成按字段或整类型
  `#[cfg(test)]`（见下文「复核跟改」）。
- `SrsCore::legacy_begin / page / commit / abort / mark_none / legacy_imported`（`store/mod.rs`）没删，显式 `#[cfg(test)]`（连同只给
  它们用的 `LEGACY_KEY` / `meta` / `set_meta` / `refresh_all` / `slim::insert_column`）：它们是写连接恢复（BUG-4297 `legacy_open`）
  用例的一部分。注意：`pub fn` 在 `pub mod store` 上 rustc 从不报 dead_code，所以「生产构建里有没有」要看产物——这几个是在
  quick staticlib 里 grep 符号才发现还在的，门住后 `SrsCore..legacy_begin` 等符号数 3 → 0。
- **产物核对**（quick 构建的 `target/quick/fushi_fsrs.lib`，按符号名 grep）：门住的 `deck_delete_on` / `merge_notes_on` /
  `sync2_retire` / `sync2_restore` / `sync2_import` / `sync2_append` / `SrsCore::legacy_*` 与 `ffsrs_store_legacy*` 均 0 处；冻结侧
  `local_write_body` / `sync2_command` 在（对照）。协议 3 的 op 名字符串本身仍会出现（新代 `wiring` 表里有同名的 Removed 项、
  gen4 实现与协议 3 同文的报错），不能拿字符串判。
- `_kSync2CacheOps` 只删了已删的 op。新代里只有 `cache_config_set` 读请求里的 `caches`（`legacy_backup_import` 由调用方显式带），
  其余命令带着它只是多传，没收窄（行为面改动，不在本项范围）。
- `exec_on` 只在测试与 `raw_sql` 构建编译（以前是基线唯一一条 dead_code）。

### 没做 / 交给别的模块

- **R8 / R9（K2 合入条件）**：清除确认处的保留副本说明、D32 保留副本自动 / 提前删除、Dart 接 `scrub_state` 报错提示——按任务
  分工归 S5（保留副本 UI / D32 / scrub_state），本分支未动。
- **D2 协议 1 位置迁移残留**（`srsPrepareLocation` / `SrsV1MediaMigrations` / `onV1Bound` 等）归 S1，未动。
- **D5**：`srs_profile_merge.dart` 的存根与 `test/srs/sync2/v1_client` 冻结副本**保留**（`srs_format_break_test` 跨版本围栏的唯一
  实跑证据）；要删得先用冻结位置夹具重写那条测试，属方向性取舍。
- **N2 基线就死的新代代码**（不归 G7-6）：`gen4/import.rs` `import_legacy` / `check_ops_stream`、`oldroot.rs` `Meta3` /
  `fence_writes`、`gen4/compact.rs` 整套压实、`Wiring::Unwired` 不再被构造、`cmd/stats.rs:59-79`、`legacy.rs` `merge_marks` /
  `translate_device`、`seal.rs` `write_tombstone`（R8 要用）、`kernel.rs` `retained_copy_unreadable` 从没被读（G7-5 状态枚举的
  缺口，应按 bug 登记）。复查方法：`lib.rs` 临时把 `store` / `sync2` 改成 `pub(crate)` 跑 `cargo check --lib`。
- `srs_p6_vectors_test` 仍是已知红（§32 末「没做」：往协议 3 表灌数据），本分支只删了它对已删 `legacyMarkNone()` 的调用。
- `srs_store_ownership_guard_test` 的基线红（§25「没做」记的 `srs_storage.dart:112` 表名）本分支修了：那处是保留下来的「主库残留协议 1 表
  检测」，加进白名单（理由「老形态检测」）。
- **同步模块的已知红（不归 G7-6，原样交 S1 / 同步 owner）**：`fushi/test/srs/srs_sync_scheduler_test.dart` 9 条（加密路径经调度器、
  支持服务器时间的后端、多个同步目录 ×2、旧根媒体后台迁移、按位置收手、文件夹存储位置 ×3）——测试夹具 `ownDeviceDir` /
  `ownSegments` 还按协议 3 布局找 `<ns>/<uid>/v3/devices/<设备>`，新代写在 `v4/`，于是 `PathNotFoundException` / 段数 0；有两条
  则报 `srs_location_protocol1_root`（夹具建的是旧版位置）。`fushi/test/srs/srs_history_page_test.dart`「存储位置：添加文件夹 /
  改用途停用 / 移除」MD3 / Apple 两条超时在 `usb removed`（移除走 `location_forget`）。两台机器都红（dist 判 real red）；本分支对
  这两个文件与 `srs_sync_scheduler.dart` 的改动只删了并入暂缓那几段，不碰这些路径。

### 复核跟改（2026-11-18 第二轮，同分支）

- **ABI 符号下界**：删 6 个 `ffsrs_store_legacy_*` 后 Dart 绑定查找的 `ffsrs_*` 从 41 个降到 35 个，`native/fushi_fsrs/verify_abi.sh`
  的「期望集塌缩」下界原是 41，合入 develop 后 `native-fsrs-gate` 与多平台构建的 ABI 核对会红。已改成 35，注释记下这 6 个符号。
  **ABI 版本不升 9**：ABI 8 本身就是换代列车（`pr/srs-gen4-switch`）新引入的、还没发布（develop 仍是 7），同列车内的
  删除只补记在 `lib.rs` `ABI_VERSION` 的 8 号说明里；并行模块若各自升号会互相冲突。本机用 NDK 的 `llvm-nm` 对 quick 产物
  `target/quick/fushi_fsrs.lib` 实跑 `verify_abi.sh`：退出 0，「all 35 ffsrs_* symbols exported」；把下界改回 41 实跑退出 1。
- **dead_code 改按字段 / 类型门住**（撤掉 17 处结构级 `#[cfg_attr(not(test), allow(dead_code))]` 与 legacy3 四个函数级
  `allow(unused_variables, unused_imports, unused_mut)`）。撤掉后生产构建报的 17 条死字段 / 死变体，逐条按根因处理：
  - `read_pool::ReadPool` 整个池（连同 `Idle` / `State` / `Opener` / `Clock` / `IDLE_TTL`）、`SrsCore.readers` / `query_readers`、
    `open_pool_reader` / `configure` / `MmapRole::Secondary`、`SrsCore::read_concurrency` / `pooled_readers` 只编进测试构建。生产构建的
    协议 3 内核只跑冻结命令、全走写连接，以前每次打开（迁移、整包备份读入）都为两个池各开一条从来不用的常驻只读连接；
    现在不开了。`read_pool::read_concurrency()`（新代内核的读池上限）照旧在生产里。
  - 收段会话 / 逐条投递整套类型（`transport::{Held, Delivery, IngestSession, IngestPhase, Outcome, PreparedSegment,
    PreparedIngest}`、`channel::{LegacyRow, Append}`）与 `SrsCore.ingest` / `set_ingest_phase` / `ingest_phase` /
    `sync2_ingest_drained` 只编进测试构建：生产构建从不构造它们（收段阶段恒为空闲）。冻结的 `replay_pending` 收尾那一步原来调
    `sync2_ingest_drained`，在生产里恒是空操作，调用处同样门住。`CommitBudget.stretchable` 只给测试里的 `stretch` 读，按字段门住。
    （`SrsCore.ingest_holds_cache` 在生产里因此恒为 false，留着没动，它是写连接放回时读的。）
  - `refresh::Refresh.open` / `all`（只有测试里的 `refresh_keys` / `refresh_all` 读）、`stats::Snapshot.profile` / `key` / `gen` 与
    `StatsCache.snapshot`（协议 3 的原料缓存，只在测试里）、`sync2::Local.name`（只给测试里的 `sync2_identity` 回包）、
    `sync2::Group.note`（只给测试里的作答预览读）按字段门住。`group_of` 去掉笔记兜底参数，兜底挪到唯一读它的 `preview_on`
    里做（结果相同）；`Snapshot::load_with` 去掉只为缓存键传的 `profile` 参数（新代 `cmd/stats.rs` 仍先 `profile_of` 校验集合
    已绑定，报错不变）。
  - legacy3 分发器里只给测试臂用的闭包 / 导入按条门住；三个只有测试臂读的参数（`local_write_body` 的 `blobs`、
    `sync2_command` 的 `blobs` / `files`）在参数上单独 `allow(unused_variables)`——参数没法按 cfg 去掉（调用处的实参不能
    带 cfg）。
  - 结果：`cargo build --profile quick --lib` 告警 7 条，**dead_code 0 条且没有任何 `allow(dead_code)` 压着**；余下 7 条是基线
    既有的 `unused`（`gen4/alias.rs` 的 `json`、`gen4/receive.rs` 的 `DeviceKey`、`ffi.rs` `ffsrs_store_exec` 非 `raw_sql` 构建的
    4 个未用变量与 1 条不可达语句），不归 G7-6。`src/gen4/translate.rs:160` 那一处 `cfg_attr(not(test), allow(dead_code))` 是
    基线既有的，没动。`--features id_audit` 构建：读连接池门住后 `ids::audit::installed` 失去生产调用方，同样门进测试构建，
    告警仍是 12 条（全是基线既有）；`--features raw_sql` 构建与 `--example gen4_dryrun` 照常编过。
- **残留预演目录开库时也清**：`G4Core::open` 以 Primary 打开时幂等删 `gen4-rehearsal/`（`migrate.rs`
  `remove_leftover_rehearsal` 改 `pub(crate)`），覆盖「早期预发布版上已迁移完」与「迁移在拿锁之前就被挡住」的用户；Secondary
  不动（不是这个目录的写者）。删不掉不挡开库（只是一份过时副本，因它打不开库才是让用户出问题），下次 Primary 打开或迁移再删。
  测试 `a_leftover_rehearsal_work_dir_is_removed_when_the_primary_opens`。
- `kernel.rs` 文件头删掉「`ffsrs_store_legacy_*` 未接线桩」那句（桩已在 `a3eefaf97f` 删掉）。
- **越过任务书禁区的两个文件（给同步 / 身份模块 owner 合并时对照）**：`fushi/lib/src/srs/srs_sync_scheduler.dart` 与
  `packages/fushi_engine/lib/srs/srs_profile_link.dart` 在 `30ae9c49d2` 里被改过，**只有删除、没有行为变化**（并入暂缓的生产
  实现恒返回 null，暂缓分支走不到）：`srs_sync_scheduler.dart` 删了 `adoptProfile` 里 `result is SrsProfileAdoptDeferred` 那个
  分支（暂缓时提前发布 `mergingInto`）、`deferredProfileMerge()` 与 `onAdopted` 文档里讲暂缓的几句；`srs_profile_link.dart` 删了
  `SrsDeferredProfileMerge`、`SrsProfileAdoptDeferred` 两个类型与 linker 接口 / 实现的 `deferredMerge` 方法。任务书一边把这两个
  文件划给同步 / 身份模块，一边要求删 `SrsDeferredProfileMerge` 整条链，而整条链就在这两个文件里，只能这样做。

## 43. 第六波 app 侧剩余红与界面接线（2026-11-18，分支 `pr/srs-gen4-w6-app-reds`，基于 `pr/srs-gen4-switch` `0bf8472f40`）

schema 不变（40024，没有加表 / 索引）；`ABI_VERSION` 不变（只改了一条已有命令对没有集合的 profile 的回包）。

### ① 复习首页（手机）找不到牌组行（`srs_pages_test` MD3）

- **真因不是 provider 让列表没渲染**：列表照常渲染，最后一行（`Spark::JP::Vocabulary`）被挤到了屏幕外（412×915，MD3 下行顶在
  915.4，Apple 下 901 刚好还在屏内，所以只红 MD3）。挤它的是 §40 挂进牌组列表横幅最前的 `SrsScrubErrorNotice`：横幅是
  `ListView.separated` 的项，没出错时这一项零高度，但照样占一条 `gap * 1.5` 的间距，整棵树往下推了一截。实测：调试打印各行
  `getRect`（`skipOffstage: false`），四行都在，只有最后一行越界。
- **修法**：新增 `srsScrubErrorProvider`（`scrub_state` 的 `error`），牌组列表只在出错时把提示挂进横幅；提示组件本身改读同一个
  provider。同步与历史页的列表不带间距，照旧常挂（零高度不占地方）。
- 测试：`srs_pages_test` 原用例恢复绿；`srs_retained_copy_wiring_test` 新增「牌组列表：清除收尾出错时横幅提示原因；没出错时
  不挂提示项」（出错 → 文案在；改成没出错重读 → 文案没了、`srs-scrub-ok` 也不在树里）。

### ② 移除存储位置在没有运行时时抛 `StateError`（`srs_history_page_test` MD3 / Apple）

- **根因**：`de04352167` 把「先 `location_forget` 成功、再改配置」做成一步，要求同步调度器（运行时）此刻在；复习模块没起时
  `srsAppRuntimeProvider` 是 null，移除直接失败。用户没开复习模块时根本删不掉一个位置。
- **修法（改契约，不是给测试注入入口）**：移除 = 配置里去掉 + 同一个事务记进「内核待忘」清单（新偏好键
  `srs_sync2_forget_pending`，JSON 字符串数组，元素是位置身份；设备本地，登记进 `preference_keys.dart` 与
  `SyncRepository` 的设备本地清单）。`PreferencesRepository.removeSrsFolderLocation` 用 `setPrefs` 一次事务写两个键，
  所以不会出现「配置没了、清单里也没有」（内核状态成孤儿）或反过来的中间态。
- 调度器新增 `pendingForgets` / `onForgotten` 两个注入点（运行时接 `AppModel.srsPendingLocationForgets` /
  `markSrsLocationForgotten`）和 `forgetPendingLocations()`（排进 `_serially`，卡片库没开 = 什么都不做、留给下一次；内核报错
  抛给调用方）。补忘的时机：运行时 `install()`（复习模块没起时移除的位置，模块一起就忘）、页面移除之后、以及每一轮
  （通道 / 互联 / 本机目录的 `_syncWithBackend`、文件夹 `_syncFolderLocations`）开头（`_forgetPendingIn`：忘不掉不挡这一轮，
  清单留着下一轮再来，同一原因只记一次日志）。删掉了 `forgetLocation(locationId, dropFromConfig:)`。
- 与 `de04352167` 想防的问题对照：那次要防「先去掉配置、再忘失败 → 内核状态孤儿、活跃窗口里继续为它保留转发原文」。现在忘
  失败时位置留在待忘清单里，下一轮自动再忘，不需要用户「再移除一次」；正在跑的一轮可能按移除前读到的配置把状态行建回来，
  它跑完之后排在后面的补忘才执行，之后的轮次读到的配置里已经没有它。
- 测试：`srs_sync_scheduler_test`「移除文件夹位置：待忘清单里的位置由调度器忘掉、划掉；卡片库没开时留着，之后（或下一轮开头）
  补忘」（以 `status.locations` 判内核还记不记着这个位置）；`srs_history_page_test` 原用例在运行时为 null 时断言配置去掉、
  待忘清单 = `{folder:usb}`、页面行消失。

### ③ `srs_profile_cleanup_test` 按新代改写；`srs_join_first_test` 定因

- **产品缺陷（顺带修）**：内核 `profile_footprint` 对没有集合的 profile 报 `has no collection`（经 `read_col`）。被删掉的
  profile、从没在新代里打开过的 profile 都是这样：删 profile 之后的核对、存量扫描对它数数都会抛 `SrsProfileUnboundException`
  （`deleting the active profile…` 就红在这里）。改成没有集合 = 全 0（`cmd/profile.rs` `profile_footprint_of`，分发器接它），
  与 `profile_purge` 对没绑定的 profile 回全 0 同口径。Rust 测试 `purge_deletes_only_the_confirmed_collection` 补断言（删掉之后、
  从没绑定的 R 都是全 0）。
- 测试改写：规模不再查协议 3 的 `srs_cards_cache` / `srs_review_logs`，卡数按 store 现读、`rows` 按内核 `profile_footprint`；
  「v1 扫过的库」改成「协议 3 的完成标记（`profile_orphan_sweep_v1` / `_v3`）在新代不算数，再扫一次清掉迁来的无主集合」；
  「v2 扫过 + `sync2_deps`」改成「只剩本机状态行 `local_state/<uid>` 的无主 uid 清掉、无备份，别的 meta 键与活 profile 不动，
  幂等」（新代没有 `sync2_deps`）；「半截并入的目标」改用本机状态行。
- `srs_join_first_test` 2 条：**不是缺陷**。新代加入（`collection_adopt`）按设计不改 profile uid（§35「不再改 profile uid」），
  测试还在断言协议 3 的「profile uid 收敛到最小」。改成断言同一个集合标识 / 同一个位置目录（两边都空时收敛到目录名小的那个，
  即较小的 uid）、profile uid 与主库 uid 都不变；第二条额外断言 phone 加入后写的笔记 host 收得到。

### ④ 第五波复核遗留

- **清除提示的 widget 测试**：同步与历史页（`srs_history_page_test`「清除收尾出错：页上提示原因；没出错时没有提示」，MD3 /
  Apple）与牌组列表横幅（见 ①）各一条。
- **`srsRetainedCopyProvider`**：改成 `FutureProvider.autoDispose`，不再 watch `srsRevisionProvider`（每次评分 / 编辑 / 同步拉入
  都跳，以前每跳都起一个后台 isolate 打开两个库文件）。会改变它的事件：复习库换了（watch `srsStoreProvider`：迁移完成、换
  profile、到期自动删都在开库时）、删除（调用方 invalidate）、第一次同步成功（只改设置行的日期：没人看就释放，下次进设置页
  现读）。读的过程中 `keepAlive` 撑住，删牌组那条 `read(.future)` 路径照常等到结果。测试（wiring）：修订号跳三次 `state` 只调
  一次；不看了再看 = 现读一次。
- **保留副本 ctl 路由的模块门**：`SrsCtlDeps.host` 的 `libraryDir` 改成先过同一道模块门（`requireSrsCtlLibraryDir`），模块关着
  时 `GET /retained` 与 `POST /retained/delete` 都回 422「复习模块已关闭」、不问库目录、不碰执行端。服务端 admin 没有模块开关，
  不受影响。测试 `ctl_srs_routes_test`「模块关：保留副本的查看 / 删除也回 422，不碰执行端」。
- **「新根不见了」写出真实目录名**：`SrsSync2Report` 新增 `locationDir`（一轮开头 `identity` 回包的 `dir`，任何错误都在它之后），
  `SrsSyncReportError` 带上它；文案 `srs_sync_location_new_root_missing` 改成带 `$path`（`i18n_sync --remove` + `--add`：除 zh-CN
  外 15 份本来就是英文原文，没有译文被降级），`srsNewRootMissingText`：文件夹位置给磁盘完整路径
  `<文件夹>/fushi-srs/<目录>/v3/meta.json`，云盘 / 互联给相对路径 `fushi-srs/<目录>/v3/meta.json`。测试：engine
  `srs_sync4_folder_test`（报告的 `locationDir` 拼出的路径就是围栏文件）、`srs_sync_now_toast_test`（云盘 / 文件夹两种文案）。

### 验证与变异实测

- `cargo fmt --check` 0；`cargo test --profile quick --lib -j 4` 1439 passed / 0 failed / 39 ignored。
- Dart（dist）：`srs_pages` / `srs_history_page` / `srs_profile_cleanup` / `srs_join_first` / `srs_retained_copy_wiring` /
  `srs_retained_copy` / `srs_sync_scheduler` / `srs_sync_now_toast` / `ctl_srs_routes` 一批 187 条，唯一的红是清理测试的备份导回
  （第 2 版 `.fushisrs` 来自另一个复习库要确认，测试补了 `confirmForeign`）；改后 `srs_profile_cleanup` 11 条全绿；engine
  `srs_sync4_folder_test` 7 条全绿。`flutter analyze --no-pub` 无问题。
- 变异（一次全加、一批跑，各自变红，还原后工作区干净）：牌组列表恢复常挂提示 → `srs_pages_test` MD3 与 wiring「不挂提示项」红；
  保留副本 provider 重新 watch 修订号 → wiring「修订号怎么跳都不重读」红；ctl `libraryDir` 不过模块门 → ctl 新用例红；
  `removeSrsFolderLocation` 不写待忘清单 → 历史页存储位置用例两套红（`Expected: {folder:usb}`）；文件夹一轮开头不补忘 →
  调度器新用例红；文案目录写回 `<collection>` → toast 新用例红；报告不带 `locationDir` → engine folder 用例红；历史页去掉清除
  提示 → 历史页新用例两套红；内核 `profile_footprint` 改回 `read_col` → Rust `purge_deletes_only_the_confirmed_collection` 红
  （`has no collection`）。`srs_join_first` 只改了测试断言（产品没改），没有对应的产品变异。

### 没做 / 归属

- 待忘清单只接了文件夹位置的「移除」（本页唯一的移除入口）；云盘通道 / 互联在各自设置页删除时内核位置状态怎么收，本分支没查、
  没改（归同步 owner）。
- 真机验证按用户 07-29 指令不做。

### 续（2026-11-20，第六波复核后的跟进，同分支）

schema 不变（40024）；`ABI_VERSION` 不变（`location_forget` 的请求 / 回包形状不变，只是作用范围从发命令的 profile 的集合扩到
库文件里的全部集合）。

- **待忘清单与内核按 profile 忘对不上（复核 minor）**：清单和位置配置一样是设备级的，但内核 `location_forget` 只在发命令的
  profile 的集合里忘，忘一次就划掉，别的 profile 以前同步过这个位置的状态行（加密记忆 / loc 标记 / head 记录）与为它保留的
  转发原文再也没人清。**修法改内核契约，不在 Dart 里按 (位置, profile) 记账**：`dispatch.rs` 的 `location_forget` 改调
  `cmd/sync.rs` `location_forget_everywhere`，对 `collections` 里每个集合各跑一次 `location_forget`、回包两项相加；发命令的
  profile 没有集合（删掉了 / 新代里从没打开过）也照常忘别的集合，不再报 `has no collection`（以前这种情形清单会一直卡着）。
  理由：位置是设备级配置，所有 profile 都不会再往那里同步；按 profile 记账要在移除时枚举 profile、删 profile 时修清单，还
  漏掉孤儿集合。Dart 侧清单格式不变，只改了 `PreferencesRepository.srsForgetPendingKey`、调度器 `forgetPendingLocations`、
  engine `srsSync4ForgetLocation` 的注释。Rust 测试 `profile_data_tests.rs`
  `forgetting_a_location_forgets_it_in_every_collection`（Q、R 两个集合都记着 `folder:usb`，从没绑定的 S 发命令 =
  忘掉 2 行、别的位置不动、再忘回 0）。
- **牌组列表清除提示的出现 / 消失动画（复核 nit）**：横幅改回常挂，`SrsScrubErrorNotice` 新增 `gapBelow`：提示自己带下方
  间距、`_DeckList` 的 `separatorBuilder` 在它后面不插间距，所以没出错时零高度且不占空白（① 的根因仍然消除），出错时
  `FushiAnimatedSize` + `AnimatedSwitcher` 连同间距一起展开 / 收起。同步与历史页不带间距，用默认 0。wiring 测试改为：出错时
  提示下方有间距且下一项紧贴其下；没出错时提示零高度、下一项（按 `FushiStaggeredEntrance.index` 找）顶边 = 提示顶边。
- **保留副本到期日期在首次同步成功后不刷新（复核 nit）**：新增全局 `srsSyncRoundsSucceeded`（`srs_sync_progress.dart`，与
  `srsSyncProgress` 同一种全局可听值），调度器 `_trackRound` 记成功的一轮时 +1。`srsRetainedCopyProvider` 只在「副本在、
  `firstSyncAtMs` 为 null」时听它，下一轮成功后 `invalidateSelf` 重读一次；记下首次同步之后不再听。测试：wiring「还没记下
  首次同步时，下一轮成功的同步之后重读一次；记下之后不再重读」，调度器文件夹用例断言成功一轮计数 +1。
- **文件夹位置的恢复提示文案（复核 nit）**：新增 `srs_sync_folder_new_root_missing`（`i18n_sync --add`，「请删掉文件 $path」，
  并提到别的同步工具还没同步完的情形），`srsNewRootMissingText` 给了 `folderPath` 用它；云盘 / 互联仍用
  `srs_sync_location_new_root_missing`（相对路径，「这个位置上的 $path」）。toast 测试两种文案各按全文断言。

验证：`cargo fmt --check` 0；`cargo test --profile quick --lib -j 4` 1440 passed / 0 failed / 39 ignored；engine
`srs_sync4_folder_test` 7 条全绿；Dart（dist）`srs_retained_copy_wiring` / `srs_sync_scheduler` / `srs_sync_now_toast` /
`srs_pages` / `srs_history_page` / `srs_retained_copy` 一批 163 条，除 wiring 牌组列表新用例的测试写法外全绿（先是按固定 key 找「下一项」
找错了项，改按列表项序号；再是零高度项被 sliver 算作不可见，改 `skipOffstage: false`），修后 wiring 6 条全绿；`flutter analyze --no-pub` 无问题。

变异（Dart 一次全加、一批跑，还原后工作区干净）：去掉 separator 对提示的跳过 → wiring 牌组列表用例与 `srs_pages_test` MD3
首页用例红；保留副本 provider 不听成功计数 → wiring 首次同步用例红；调度器不加计数 → 调度器文件夹用例红（`Expected: <1>`）；
文件夹文案改回通用 key → toast 用例红。Rust：分发改回只忘发命令的 profile → 新用例红（S 没有集合报错）；同时把测试改成由 Q
发 → `forgotten` 1 ≠ 2 红。

没做 / 归属（更新上面那条）：

- 云盘通道 / 互联的「删除」：查过，没有一个显式的「移除通道位置」入口——通道位置身份由后端账户 / 地址现算
  （`srs_directory_key.dart`），退出登录或改地址后身份就算不出来了，要忘只能在同步设置各后端（7 种）改配置 / 退出前先取
  身份记进待忘清单；而且退出登录不等于不再用这个目录（重新登录同一账户还是同一个位置，忘掉会让下一轮当新位置重新起步）。
  这是同步设置模块的产品取舍，本分支不改，归同步 owner；现状是这些位置的状态行与转发原文一直留着（不丢卡片与复习记录）。
- 真机验证按用户 07-29 指令不做。

### 续二（2026-11-20，第六波第二轮复核后的跟进，同分支）

schema、`ABI_VERSION`、i18n key 都不变；Rust 只改注释。

- **保留副本状态读的过程中被 invalidate 会泄漏同步监听（复核 minor，已实测）**：上一轮在 `await backend.state(...)` 之后
  才 `addListener` + `ref.onDispose`；读的过程中 provider 被 invalidate（换库、删除的调用方）时那次构建已经 dispose，
  `onDispose` 抛 `StateError`，监听永远摘不掉，之后每一轮成功的同步都让元素重读一次。**修法：把注册与释放挪到 provider
  体的同步开头、在第一个 `await` 之前成对登记**，读完只设一个本次构建私有的 `awaitingFirstSync` 标志，监听里按它决定
  要不要 `invalidateSelf`。这样不管在哪一刻被废弃，这次构建的 dispose 都会摘掉自己的监听；代价是副本不在 / 已记下首次
  同步时也挂着一个空转的监听（只比较一个布尔），换来生命周期不依赖 `await` 时序。没有把计数改成 provider 再 `ref.listen`：
  它由调度器在 Riverpod 之外写（`_trackRound`），桥接只是多一层，且在 `await` 之后 `ref.listen` 同样有废弃问题，根因
  在注册时机。测试：wiring「读的过程中被 invalidate 不留下同步监听」（假执行端的状态命令卡在 `Completer` 上，读到一半
  invalidate、紧接着放行，再首次同步 + 连续 3 轮成功 = 只重读一次）。
- **`location_forget` 对全部集合生效后 dispatch 不再校验发命令的 profile（复核 nit）**：核过，没有越权面，不收紧。
  能发这条命令的只有本机调度器的待忘清单（`srs_sync_scheduler.dart` `_forgetPending`）；engine 里所有 `sync2Command`
  调用方的 `op` 都是写死的；远程复习唯一的透传口 `srsRemoteKernelCommand` 只认 `kSrsRemoteKernelOps`（不含它），ctl /
  `fushi_server` 没有入口。位置配置本来就是设备级的：能移除位置的那个 profile 本来就让所有 profile 都不再同步它，忘别的
  集合里的同步状态没有给它更多权力；忘掉的也只是同步状态与多余的转发原文，卡片与复习记录不动。补了守卫：
  `srs_remote_store_test.dart` 白名单用例的禁止清单加上 `location_forget`（远程直调 404、经浏览入口夹带 400）；
  `cmd/sync.rs` `location_forget_everywhere` 注释写明这条结论与前提（位置身份是设备级配置；以后云盘通道 / 互联接移除时
  若配置按 profile 分开，要改回按 profile 取集合）。
- **文件夹位置恢复提示里多余的「at this location」**：上一轮（`30812455b3`）已经给文件夹位置单独用
  `srs_sync_folder_new_root_missing`（「delete the file $path」，17 份 json 里都没有 at this location），这一轮核对后不再改；
  云盘 / 互联的 `srs_sync_location_new_root_missing` 写的是位置里的相对路径，「at this location」在那里是必要的，保留。

验证：`cargo fmt --check` 0；`cargo test --profile quick --lib -j 4` 0，1440 passed / 0 failed / 39 ignored；engine
`dart test test/srs/srs_remote_store_test.dart` 0，32 条全过；Dart（dist）`srs_retained_copy_wiring` + `srs_retained_copy`
0，12 条全过；`flutter analyze --no-pub` 0，No issues found。

变异（还原后工作区干净）：provider 换回上一轮的写法（读完才挂监听）→ 新用例红（`Expected: <4>  Actual: <7>`）；
`kSrsRemoteKernelOps` 加上 `location_forget` → 白名单用例红（`Expected: not contains 'location_forget'`）。

## 44. 第六波 导入红测试收尾（2026-11-18，分支 `pr/srs-gen4-w6-import-reds`，基于 `pr/srs-gen4-switch` `0bf8472f40`）

导入 / 备份侧剩下的红测试逐条定因，外加第五波 S3 复核的 nit。不升 SCHEMA（仍 40024），不加表 / 索引；存量持久化名不动。

### ① `.apkg` 往返用例多出 `"foreignLog":true`：测试过期

- **定因**：`srs_apkg_stream_roundtrip_test.dart`「导出到文件 → 按文件导入另一份库」逐字段比 A（导出方）与 B（导入方）的日志，
  B 的每条日志多了出处标记 `foreignLog: true`（§38 ①，Dart `_remapExtLog` 打、内核 `derived_log_hlc` 读）。标记是**导入方
  这份库**的事实（「这条复习在这里是外来的」，只决定这份库里的派生排序键），导出方自己的原生日志本来就没有；它和已经排除的
  `hlc` 同类，都是落库方本机的东西。不是回归：卡片行（队列、到期、间隔、reps、最后一条日志）两边逐列相同。
- **定案**：比较面去掉标记（`_comparableLog`，按 JSON 解析后去掉顶层 `hlc` 与 `srsForeignLogKey`，不再用正则删 `hlc`），
  标记**另行断言**：A 的日志 0 条带标记、B 的日志条数等于 A 且每条都带。生产代码不动。
- **变异**：生产侧 `_remapExtLog` 不打标记 → 新断言红（见验证）；比较面不去标记 → 即原来的红。

### ② 备份导入源码守卫 3 条：测试过期

- **定因**：`backup_import_overlay_test.dart` 2 条、`backup_import_streaming_guard_test.dart` 1 条逐字锚
  `completeBackupImport(t.backup_import_success)`。G11-4（§25）起合并导入里有没并入的复习数据时完成提示换成
  `t.backup_import_success_srs_declined(...)`（三元二选一，`backup_srs_gen4_guard_test.dart` 钉着），成功出口还在，只是字面变了。
- **定案**：成功出口改按正则 `completeBackupImport\(\s*[^;]*\bt\.backup_import_success\b[^;]*\);` 匹配——实参里必须有**纯**
  成功文案（词边界让带后缀的那条不算数）；其余判据（失败走 `failBackupImport`、成功后 1 秒自动重启、失败不自动重启）不变。

### ③ `SrsBackupManifest` 撞「旧 SRS 同步 / 旧定时备份已删」守卫：改名

- **定因**：`srs_sync_v1_removed_guard_test.dart` 禁的是旧备份库（`srs_backup_store`）的符号，G11-4 的备份 v2 清单类恰好
  也叫 `SrsBackupManifest`。守卫按名字认不出新旧，收窄守卫等于给旧实现复活留口子。
- **定案**：新类改名 `SrsBackupBundleManifest`（所在文件 `srs_backup_bundle.dart`，与 `kSrsBackupManifestEntry` 等常量同族）；
  只是 Dart 类型名，不是持久化名（清单条目名 `srs/manifest.json`、键、版本号都不动）。守卫原样不改。

### ④ `backup_srs_gen4_guard_test.dart` 手写注释剥离：改用共享掩码

- `codeLines` 原来丢掉 `trimLeft().startsWith('//')` 的整行（`source_guard_adoption_test` 禁用形态）：块注释、行尾注释放行。
  改为 `maskComments`（`test/helpers/source_guard.dart`），掩完只剩空白的行不要、行号仍是原文行号；`mergeCalls` 的配平
  扫描与 `contains('…srsResults =\n')` 判据照旧成立。

### ⑤ 第五波 S3 复核 nit

- **回包 `logHlcs` 的时刻上界没有用例**：`a_foreign_log_from_the_future_does_not_pin_the_schedule` 走的是 `import_drafts`，它
  不报 `logHlcs`（只有 `apply` 报），里面 `if let Some(replied)` 那段从来没执行过。新用例
  `a_foreign_log_from_the_future_is_not_derived_in_the_log_hlcs_reply`（`writes_tests.rs`）走 `apply` + `logHlcs: true`：回包
  不是 `{at}:0:fushi`、物理时刻早于伪造的发生时刻、与随后 `read logs` 的 `hlc` 逐字相同。原用例那段空分支换成「`import_drafts`
  不报 `logHlcs`」的断言。变异：`cmd/writes.rs` 回包派生的上界传 `i64::MAX` → 新用例红、原用例仍绿（坐实原来没钉住）。
- **`CACHE_RULES` 2 → 3**：第五波复核给派生加 `op_wall` 上界改了推导口径，但 `0442ce60ac`（`CACHE_RULES` = 2、还没上界）已经推到
  `pr/srs-gen4-w5-import-write` 上过，按 2 物化过的开发库里带未来时刻的外来日志排在派生位置上。按 `cache.rs` 自己的规则（缓存行
  变了就 +1）升到 3，开库时整层重建一次，不改真相、不丢卡。`a_cache_built_under_older_rules_is_rebuilt_once_on_open` 的旧值
  列表加上「上一版口径」（`CACHE_RULES - 1`）。
- **「这次必须升」的用例**（复核 minor，续做补上）：重建用例按 `CACHE_RULES - 1` 取上一版，常量退回 2 照样绿。新加
  `cache_rules_matches_the_pinned_derivation_table`（`cache.rs` 测试模块）：派生排序键 `derived_log_hlc` 的 8 行输入 / 期望 /
  「让这一行成为现在这样的修订号」对表（原生 0、Anki 1、外来早于或同毫秒 2、外来晚于操作 3），要求表里最新修订号等于
  `CACHE_RULES`。以后改派生口径而不升、或把常量退回去，都会红；改口径的人要改期望、记新修订号并升常量。变异：常量退回 2 →
  红（left 2 / right 3）；`derived_log_hlc` 去掉 `at <= op_wall` → 红（「伪造的未来时刻」那行得到 `3000:0:fushi`）。

### 没做 / 交给别人

- 没在真机 / 双设备上验回导与备份还原；证据是上面的 Rust / Dart 用例。
- 对表只覆盖 `derived_log_hlc` 这一处派生；`log_body` 里别的缓存列口径（若以后改）不在表里，靠改的人按 `CACHE_RULES` 的规则自觉升。
- 集成分支后来合入的 T2（#3736）没合进本分支（不 rebase / 不合并），冲突留给合流处理。2026-11-20 对集成分支头 `14799047ca` 做
  `git merge-tree`：只有本交接文档文末追加节冲突（两边各追加一节，两节都保留即可），代码文件无冲突。
- 复核 nit「成功出口正则不看分支可达性」（`false ? t.backup_import_success : …` 能骗绿）未加严：查找范围与基线相同，没有变宽。

### 验证（2026-11-20，头 `2bce09da6f` 续做核验，本 worktree 编出的原生库）

- 续做（`b414ebdbea` 对表用例）：`cargo fmt --check` 退出 0；`cargo test --profile quick --lib -j 4` 退出 0，1441 passed /
  0 failed / 39 ignored（比上次多的 1 条就是对表用例）。只动 Rust 测试与本文档，Dart 侧未重跑。

- `native/fushi_fsrs`：`cargo fmt --check` 退出 0；`cargo test --profile quick --lib -j 4` 退出 0，1440 passed / 0 failed / 39 ignored
  （ignored 为存量，本分支没加）。
- Dart（`--here` 强制本机，用本 worktree `setup_worktree.ps1` 编出的 `fushi_fsrs.dll`）：
  - `packages/fushi_engine`：`dart test` `srs_apkg_stream_roundtrip_test` / `srs_backup_merge_test` / `srs_db_store_test` 退出 0，30 条全过（5 + 9 + 16）。
  - `fushi/`：`flutter test` `backup_srs_gen4_guard_test` / `backup_import_overlay_test` / `backup_import_streaming_guard_test` /
    `backup_srs_category_test` / `srs_sync_v1_removed_guard_test` / `source_guard_adoption_test` 退出 0，45 条全过。
  - 改动的 11 个 Dart 文件 `dart format --set-exit-if-changed` 0 改动；`flutter analyze --no-pub`（经 heavy 外包）No issues，退出 0。
- 变异实测（改完跑、还原后 `git status` 干净）：
  - `cmd/writes.rs` 回包派生上界传 `i64::MAX`：新用例 `…_is_not_derived_in_the_log_hlcs_reply` 红，原用例绿。
  - `_remapExtLog` 不打 `srsForeignLogKey`：往返用例红（期望 `(480, 480)`，实际 `(0, 480)`）。
  - `backup.part.dart` 成功分支改成 `t.backup_import_success_srs_declined(count: 0)`（没有纯成功文案）：overlay 2 条、streaming 1 条红。
  - `backup_srs_gen4_guard_test` 的 `codeLines` 退回 `trimLeft().startsWith('//')`：`source_guard_adoption_test` 红。

## 45. 第六波 身份归属闸收口（BUG-4843 残余，2026-11-18，分支 `pr/srs-gen4-w6-identity-gate`，基于 `pr/srs-gen4-switch` `0bf8472f40`）

收 §37「第五波 G9 身份收尾」第二轮复核留下的两处残余。SCHEMA 不变（40024，没加表 / 索引，分到的 40025 没用）。

### 更正 §37

§37「复核后补修」里两句与实测不符（按规矩不改别人的节，在这里更正）：

- 「牌组 / 笔记类型的身份记录不判（对它们的修改仍判）」——不对：它们不判却进 `Born`，同批对 B 的牌组 / 笔记类型的修改借它
  过闸（第二轮复核探针：A 的日志 1→5、回包里两条 `renamed by A`）；只有修改单独发时才判。
- 「伪造一条 guid 与 B 一致、只换笔记类型的身份记录在写入口分不出来」——分得出来：B 的定义就在同一个库里。

### 判据（`gen4/cmd/writes_owner.rs` 文件头「身份记录：内容寻址的归属」，`Session::foreign_record`）

ID 不加盐以后实体是**内容寻址**的：两个集合拿同一份身份内容建出来的就是同一个实体，并入后合成一份。修改 / 标签 / 日志的闸都看
「本集合有没有痕迹」，痕迹的源头是身份记录，所以归属判据定在身份记录上。库里有别的集合、别的集合里有 X 的痕迹时，本集合为 X
写身份记录要同时满足：

1. **自证**（`Session::derived`）：ID 能由这条记录按规范规则重算出来——笔记 `note/<guid>`；笔记类型 `notetype/<ankiNum>`；牌组
   `deck/<全名>`，全名取同批的 `name`（带 `parent` 时再取父牌组在本集合牌组树里或同批里的全名，「只按叶子名」也认），或第 n 个
   备选 `deck_alternate(全名, n)`，备选只在前一个已被本集合占着时才轮得到（同 Dart `SrsDbStore.deckIdForNew`）；`builtin` 只认
   规范的内置默认牌组常量；卡片没有合法的身份记录来源，永远自证不了。牌组的名字从同批修改里收（`Batch`，`apply_in` 建）。
2. **结构一致**（`Session::conflicts`、`identity_key`）：与库里每个有 X 定义的集合的定义（`Index::new(t, 那个集合).definition`，
   各按自己的别名表归一，类上同一个挑选规则）比结构——笔记 guid + 笔记类型，笔记类型 Anki 编号 + 种类（缺省 `standard`，同
   `registers.rs`）；牌组的结构就是 ID。`createdAt` 不算（同一份内容的合法导入在存量里算法不同）。别的集合把 X 当成另一种实体
   也算冲突。
3. 例外：与本集合此刻的定义逐字相同的重发照写（不带新内容；存量冲突里重发自己那份不被拒）。

不满足的不写、不进 `Born`，同批借它作保的修改一并不写（回包 `foreign`）。字段 / 模板是笔记类型上的 `fieldDef/` / `tmplDef/`
修改，跟着笔记类型的归属走；profile 设置实体仍按 §37 的 `PROFILE_SQL`。

为什么在并集收敛语义下成立：判据只决定本机写不写，写下的操作照常传播、并集，派生只由操作集合决定（同 §37）。剩下按定义不算
「别人的」那一种：A 拿出的身份内容与 B 的**完全一致**——与「A 独立导入了同一份内容」逐字节相同，内容寻址下就是同一个实体，A
之后的修改并入后作用到合成的那一份，是设计里的并集语义。

### 取舍

- **没选**「首个身份记录的作者集合定归属、随操作落库，并入时作者 ≠ 归属的修改不生效」（任务书给的例子）：合法的「两个集合各自
  导入同一份内容」里后建的一方并入后对自己那份写的修改与复习全部失效（丢复习记录，违背所有者底线）；放宽成「内容一致的身份
  记录的作者」又回到内容判据、只是挪到并入时做；作者集合要进操作格式，`derive.rs` 冻结判定、重建恒等、摘要对拍、协议 3 投影
  对拍都要重做；它同样分不出内容完全一致的那种。
- 库里另一个集合已有同 guid、不同笔记类型的笔记时，本集合导入这条笔记不写（`foreign`；Dart 侧不读 `foreign`，导入继续，
  这一条不落）。同 Anki「同 guid 异笔记类型」跳过；不拒的话两个集合日后并入，B 的笔记可能被换笔记类型（字段全空）。
- 只有「X 在别的集合里有痕迹」才多做这些查询（每条身份记录：本集合定义 1 次 + 每个别的集合定义 1 次，牌组另读一次牌组树）；
  单集合库、别的集合没有的 ID 与以前一样一条查询放行。

### 测试与验证

- 内核新文件 `gen4/cmd/writes_owner_merge_tests.rs`（挂在 `writes_owner_tests.rs` 下）：每种实体一条「A 写 B 的 ID → A 的集合导出、
  在另一个库里确认并入 B（`joined`）→ B 的 `entity_views`（定义、活着的修改、标签、日志、缓存行）与并入前逐字相同」——笔记、卡、
  牌组、笔记类型、字段、模板；合法场景：同一份内容两个集合各建（含内置实体、`createdAt` 不同）并入合成一份且两边的写都在、牌组
  备选、子牌组按父牌组全名、迁移库双盐别名类（`tests_class.rs` 场景）、经 `.fushisrs` 带进来的存量同号实体重发自己的定义。
- engine `srs_profile_ownership_merge_test.dart` 补残余二（真实 guid 只换笔记类型 + 同批改字段）与残余一（牌组身份记录 + 同批
  改名），并入后断言 B 的牌组名。
- 变异实测（内核，各自单独改、跑 `owner::`、还原）10 项全红：牌组 / 笔记类型不判（6 条红）、不比别的集合的定义（4）、去掉重发
  例外（1）、备选不往后试（1）、不按父牌组全名（1）、笔记类型自证恒真（1）、内置牌组恒自证（1）、笔记自证恒真（1）、卡片自证
  恒真（1）、笔记自证恒假（3，合法场景红）。Dart 层：前两项合起来（旧行为）重编 `id_audit` + `raw_sql` 库（测试宿主优先加载
  的那份）跑 `srs_profile_ownership_merge_test.dart`：exit 1，「A 的日志里不能有指向 B 的实体的操作」Expected 4 / Actual 8；
  换回本分支编出的库 exit 0。
- `cargo fmt --check` 0；`cargo test --profile quick --lib -j 4` 0，1450 passed / 0 failed / 39 ignored（基线 39，未新增）。
- 续做复核（2026-11-20，上一位实现者额度中断后接手，头 `43125faa5e`）：上面两项变异在本机重跑（牌组 / 笔记类型不判 → 6 条红，
  不比别的集合的定义 → 4 条红，各 exit 101，还原后工作区干净）；engine `srs_profile_ownership_merge_test.dart` +
  `srs_profile_ownership_test.dart` 用本 worktree 编出的库 exit 0，79 条全过。

### 没做

- `PendingSelf` 未绑定时预检与确认各生成一份、副本备两遍（§37「没做」）：没顺手修。根治要把预先生成的本机身份（含签名钥匙
  种子）跨请求落库（`srs_meta`），预检就得写库（现在预检在回滚掉的保存点里跑、不留任何东西），还要在所有绑定路径（`identity`、
  `collection_adopt`、`.fushisrs` 导入、关联已有集合）上消费 / 清掉它，否则留下一份没人用的钥匙种子——这是身份生命周期的改动，
  不是顺手的事。代价只在「覆盖还原进空库」这一条路径上多备一次副本，结果正确。归 G9 身份 / 备份模块。
- 别的集合只有修改、没有身份记录 / 别名 / 卡片行的实体（例如别的集合没配缓存时的卡）`THEIRS_SQL` 看不到（§37 原样）；按
  现有调用方（Dart 开库即配缓存）不会出现，未处理。

### 复核跟改（2026-11-20，同分支第二轮）

复核（major）指出「取舍」节第二条「Dart 侧不读 `foreign`，导入继续，这一条不落」是**静默丢导入**：同一个包 / 同一份 CSV 被同库
两份 profile 导入、两边落到不同笔记类型（`.apkg` 不合并笔记模板时 `_mapNoteType` 改挂到 `_duplicateAnkiNum` 副本类型；文本导入
的 guid 列来自文件、笔记类型由用户选）时，后导入一方的这些笔记被闸拒掉，导入报告却照记「已添加」。写入口分不清它与伪造的
残余二（内容相同），所以闸不动，改成让拒绝**对用户可见、且不留副作用**：

- 内核 `writes.rs` `apply_in`：回包 `foreign` 改报调用方输入下标（`Origin`，同 `edits` 第 7 列）。以前报筛掉初值项之后的位置，
  `import_drafts` 筛掉过初值项时对不上草稿——Dart 要按它认笔记，这是前提。
- Dart `SrsDbStore.importDrafts` 返回 `SrsImportDraftsResult`（`existed` + `foreignNotes`，`_foreignNoteRecords` 从回包 `foreign`
  取笔记身份记录草稿的 ID，下标越界抛 `StateError`）；`.apkg` `_flush` 与文本导入 `flush` 落库后才计数：被拒的记
  `conflictNotes`（新原因代码 `SrsImportIssueReason.otherProfileNoteType`，冻结；报告文案 `srs_import_report_conflicts_other_profile`，
  `i18n_sync --add`，16 种语言先落英文），不加 `notesAdded` / `cardsAdded`，`.apkg` 为它记进报告的复习数 / 重置为新卡数退回
  （`_PendingNewNote`）。
- `.apkg` 落库时按新笔记的卡给日志带上笔记（`importDrafts(logNotes:)`）。新笔记的卡还没有缓存行，以前日志只带卡、目标是「哪里
  都没有的卡」照常写——笔记被拒时它的复习悬空落进本集合，进统计与日历（有效复习投影对没有缓存行的卡也投影）。带上笔记后
  跟着笔记一并被拒。合法新笔记的日志多带一个本来就对的笔记 ID，内核行为不变。
- 选「报冲突」不选「改走新 guid」：`.apkg` 改 guid 后同一个包再导入时认不出这条（`_existingNotes` 按 guid 派生的 ID 查），每导入
  一次多一份；报冲突是确定性的，与本机的「同 guid 异笔记类型」（`noteTypeChanged`）同一种处理，文案给出解法（用同一个笔记类型 /
  打开「合并笔记模板」）。

复核（minor）：同 guid + 同笔记类型、只改 `createdAt` 的记录能过闸，并入时可能顶掉 B 的 `createdAt`——接受，只影响 B 这条笔记的
新卡次序，已写进 BUG-4843 文件。复核（nit）：`PendingSelf` 两遍副本维持上面「没做」的判断。

测试：内核 `import_drafts_reports_foreign_at_the_callers_input_index`；engine `srs_apkg_import_test.dart`「同库另一份 profile 已有
同 guid、另一个笔记类型的笔记」（不合并：`otherProfileNoteType` 一条、`notesAdded` / `cardsAdded` 为 0、`reviewLogsImported` 比只有
一份 profile 的对照少 1（同次导入里别的笔记的复习照常计数）、P2
没有这条笔记也没有它的复习、P1 不变；合并笔记模板再导入：照常加上、复习落下），原「合并笔记模板」用例的包构造提成顶层
`withExtraFieldApkg`、`openTestStore` 加可选 `storage`（同库多份 profile）；`srs_text_import_test.dart`「GUID 列的 guid 在同库另一份
profile 里是另一个笔记类型的笔记」（同批别的行照常、同一个笔记类型照常导入）。

验证（2026-11-20）：`cargo fmt --check` 0；`cargo test --profile quick --lib -j 4` 0，1451 passed / 0 failed / 39 ignored（基线 39）；
engine `srs_apkg_import_test.dart` + `srs_text_import_test.dart` + `srs_profile_ownership_merge_test.dart` +
`srs_import_drafts_initial_test.dart`（`heavy.dart --here`，本 worktree 编出的库）exit 0，74 passed / 1 skipped（既有）。变异实测各自
单独改、跑完还原、工作区干净：内核 `foreign` 按筛掉后的位置报 → 新内核用例红（`[0]` ≠ `[1]`）；Dart 不取 `foreignNotes` → apkg 与
文本两条新用例红（冲突列表为空、`notesAdded` 2 ≠ 1）；`.apkg` 不给日志带笔记 → apkg 用例红（P2 查到那条复习）；不退回复习数 →
apkg 用例红（3 ≠ 2）。

没做（本轮新增）：

- ~~被拒笔记的**卡片级**修改仍落成悬空修改~~：第三轮已修，见下一节。
- 同 guid 异笔记类型**分在两台设备**各自导入时闸看不到对方，日后并入仍按「规范 JSON 最小者胜」二选一笔记类型：ID 只由 guid
  派生的固有代价（设计 2026-11-11 §2），并入只在用户确认时发生。归设计 / G9。

### 复核跟改（2026-11-20，同分支第三轮）

第二轮复核（`verify2` 通过，余 1 minor + 1 nit）与上一节「没做」里的卡片级悬空修改，提交 `f3d5e2cfc7`（内核）、`b31ce6a359`（Dart）：

- minor：`.apkg` 被拒笔记只退回了复习数 / 重置为新卡数，`fushiLogsRestored`、`revlogsVerifiedByExt`、`revlogsAlreadyPresent`、
  `revlogsNotInExt`、`anchorsWritten`、`futureCards` 仍按已导入计。根因是按卡的计数直接写报告、被拒后逐个减回。改成一条笔记的卡片
  计数记在 `_CardTally`（`srs_apkg_import.dart`；`_importNote` 的卡片循环与 `_importCardSchedule` 只记这里，不碰报告）：已有笔记
  当场 `addTo` 报告，新笔记随 `_PendingNewNote` 等落库回包，落了才并进，被拒的整份不计——同一个「被拒」判断推出全部计数，
  `_PendingNewNote.logs` / `resetToNew` 删掉。来源包里卡已删除的 revlog（BUG-4657）不属任何笔记，仍直接记报告。副作用：新笔记的
  卡片计数（含 `futureCards` 的顺序）在落库那一批才进报告，总数不变。
- nit：BUG 文件与上一节写的「`reviewLogsImported` 为 0」与测试不符，按测试改成「比只有一份 profile 的对照少 1」。
- 卡片级悬空修改（上一节「没做」第一条）：在本模块的闸内闭合。内核 `writes.rs` `apply_in`：**卡片修改带笔记**（输入项的 `note`，
  同日志带笔记；`Item.card_note`，按本集合别名表归一）时，除了卡自己过闸，它的笔记也问 `Session::foreign`——同批身份记录被拒的
  笔记没进 `Born`、别的集合有、本集合没有，于是它的卡片修改一并不写、下标进 `foreign`。只加严：不带笔记、或笔记是本集合的 /
  同批要建的 / 哪里都没有的，结果同以前（「哪里都没有的 ID 照常写」不变）。Dart `_applyInput` 给卡片修改（`SrsEditDraft` 与
  `SrsReadyDraft(SrsEditEvent)`）按 `cardNotes`（原 `logNotes` 改名：日志与卡片修改共用这张「卡 → 笔记」表）带上笔记；
  `.apkg` 新笔记的卡全在表里。取舍写在 `writes_owner.rs` 文件头「卡片修改带笔记」：
  - 没选「内核按被拒笔记 × 模板推出卡 ID 一并拒」：填空题卡序号来自字段 `{{cN}}`、上不封顶（别名层靠字段史补上限外的序号），
    副本类型的模板常在同一批才建，内核要在写入口重做一遍 Dart 出卡规则才推得全，推不全的照样漏成悬空修改；调用方本来就是按
    笔记 × 模板派生出这些卡 ID 的，声明给内核即可精确闭合，且复用日志早已有的 `note` 输入位，线上形状不变。
  - 也没选「导入前问内核会不会被拒」的跨集合只读命令：多一次往返、多一条命令，且查询与落库不在同一个事务里，中间可能变。
  - 声明是调用方给的：不带笔记的卡片修改仍按卡自己的判据（与日志不带笔记时一样），所以这条只保护如实声明的调用方（`.apkg`
    导入）。闸挡的本来就是「拿错 ID」而不是恶意调用方，后者不带笔记得到的只是今天的口径。

测试：内核 `card_edits_carrying_a_rejected_note_are_not_written`（`import_drafts`：被拒笔记 + 它的两条卡片修改进 `foreign` 不写，
同批要建的笔记 / 本集合已有的笔记 / 哪里都没有的笔记的卡、不带笔记的哪里都没有的卡照写，A 的操作恰好多 5 条；`apply`：带被拒笔记
的不写、同一张卡不带笔记照写）。engine `srs_apkg_import_test.dart` 组「被拒的笔记整份不计、卡片修改不落（BUG-4843 第二轮复核）」
三条：每条先断言 P2 的报告与「包里没有 g4」的单 profile 对照**整份 `toJson`（除冲突列表）逐项相同**、冲突只多 g4 的
`otherProfileNoteType`，再断言带 g4 的对照里 g4 确实贡献了——① fushi-ext 场景：恢复 / 校验 / 包外 revlog / 日志 / 锚点各 1；
② 未来 revlog：`futureCards` 含 41；③ 新卡 + 暂停：g4 副本类型的卡上有 `newPos` 77 与 `suspended`，P2 同号的卡一条修改都没有。

验证（2026-11-20，本 worktree，HEAD `b31ce6a359` + 本节文档）：`native/fushi_fsrs` `cargo fmt --check` exit 0；`cargo test --profile
quick --lib -j 4` exit 0，1452 passed / 0 failed / 39 ignored（基线 39）；`fushi/` 下 `dart tool/heavy.dart -- flutter analyze --no-pub`
exit 0（No issues found，dist self-mac）；engine 三个改动文件 `dart analyze` No issues；`dart tool/heavy.dart --here -- flutter test`
`srs_apkg_import_test.dart` + `srs_text_import_test.dart` + `srs_profile_ownership_merge_test.dart` + `srs_profile_ownership_test.dart` +
`srs_import_drafts_initial_test.dart`（本 worktree `setup_worktree.ps1` 编出的 `fushi_fsrs`）exit 0，155 passed / 1 skipped（既有）。
变异实测各自单独改、跑完 `git checkout` 还原、工作区干净：被拒笔记的 tally 照样并进 → ① ② 红（`reviewLogsImported` 3 ≠ 2、
`futureCards` 多 41）；复现第一轮「只退回日志数与重置数」→ ① ② 红（`anchorsWritten` 2 ≠ 1、`futureCards` 多 41）；`_applyInput`
卡片修改不带笔记 → ③ 红（P2 卡上有 `newPos` / `suspended`）；内核不看 `card_note` → 内核用例红（`foreign` `[0]` ≠ `[0, 1, 2]`）。

仍没做：

- 同 profile 回导 / 旧卡接链补的 `historyFrom` 链接（`_historyLinks`）在导入末尾经 `writeEdits` 单独写、不带笔记。新笔记要走到这条
  路须 fushi-ext 同 profile 且前身卡在本集合、或撞上认不出笔记的旧卡，被拒笔记几乎走不到；没构造出能触发的路径，不为它加未测的
  过滤。要做时给 `writeEdits` 也接 `cardNotes`，或在 `_flush` 收被拒笔记的卡 ID 后滤掉。归本模块后续 / G9。
- 上一节其余「没做」（跨设备同 guid 异类型、`PendingSelf` 两遍副本、THEIRS_SQL 看不到只有修改的实体）不变。PR CI 未等。

## 46. 第六波 转发 / 重切件收尾（2026-11-20，分支 `pr/srs-gen4-w6-relay-tail`，基于 `pr/srs-gen4-switch` `0bf8472f40`）

§39「复核修复后仍未做」四条与一批之内重收的 minor 在本节收掉，外加自动安全审查的一条 MEDIUM（导入流的转发材料没验签）。
上一位实现者做到一半被额度中断（`16d18a423e` / `410a508500` / `d8bf35b803` 与代存的 WIP `dd9aeb8bc7`），本节由续做者补完，
WIP 原样编不过（schema 守卫表数没改）、三条停放测试装置有误，已改对，不按「已完成」看待。

### 取舍（所有者授权自行定）

- **PurgePending / UntrustedUploader 的出路选「读者事件驱动重试 + 同步页说明」**，不选「重切者另出一份不依赖该 Purge 的件」：
  后者要么把被清除的原文再交出去（违背 §26 C3「清除后原文不经本机离开」），要么让读者收一份它核不了 Purge 的件
  （等于放弃 `purge_vouches`），两条都不可取。读者侧（`cmd/sync_park.rs`，SCHEMA **40026** 加 `relay_park`）记下这一件在
  这个位置上**等哪条 Purge**（`wait` / `wait_seq` > 0）或**等哪台设备的信任变化**（`wait_seq` = 0 + 停放时的信任状态）；
  `plan` 只对被转发来的 head 查停放，等的事没发生就不拉，发生了（Purge 落库或进了等待缓冲 / 信任状态变了）才放行再拉——
  不是定时退避。拒绝之后再拉一次得到同样的延后，按「已拒绝」重新停放，之后不再拉。作者日志末尾到了停放件末尾、作者 head
  不再列这一件、`location_forget` 时清掉。同步页（`status` 设备行 `relayBlocked: [{location, author, reason, pieces}]`，
  `reason` = `purge` / `pending` / `rejected`）挂在**等的那台设备**一行上，那台设备本机还没有日志也补一行；app 设备行按原因
  各说一行（`srs_device_relay_blocked_purge` / `_trust` / `_rejected`：让它同步一次 / 确认它 / 等作者自己同步），点行照旧去
  冲突中心确认 / 拒绝。
- **一批之内的重收在批被截断时**：交完的部分里还在等同一批里 Purge 的重切件不再直接报延后，回包 `requeue`（相对这一片的
  下标）交回 Dart，`SrsDbStore.sync2IngestBatch` 接在剩下的段后面下一片再交（先前那次延后不计，`Receiver::uncount_deferred`）；
  整片交完还交回、或下标越界按契约坏了报错。Dart 收段现在带 `location`（与 `plan` 同值）——不带内核不停放，照旧每轮再拉。
- **`.fushisrs` 带转发材料选「导出流升版」**（`EXPORT4_VER` = 3，第 1、2 版照读），不选「下一轮同步自愈」：被清除的原文本机
  已经没有，同步拿不回剔除记录，自愈不成立。
- **导入流里的转发材料先验签再落库**（安全审查 MEDIUM）：`import.rs` 把一条原生日志链尾之后的材料攒齐，整条日志读完再交
  `land_relay`——作者签名版本拿本机 `peers` 里这位作者的公钥（导入撞上另一把公钥时整笔已拒）、本机日志（此时已灌完）与
  剔除记录拼出全部项（`Truth::author_items`，与 `recut_from_log` 同一套），**作者签名验得过才记**，记时照旧只换成空洞更多的
  那份——没验过的一律不碰本机已有的行；剔除记录要被某个验过的版本担保（拼项时用到了它，即信封 / 载荷哈希 / 清除目标正是
  作者签过的那条）才记，本机已有的那一格**不动**（`put_stub_if_absent`，拼项时本机那条优先）。没记的计入
  `ImportedOps::relay_skipped`，回包 `imported.relaySkipped`（另带 `relayVersions` / `relayStubs`），不报错。段头作者不是所在
  日志作者的由流语法整笔拒（读写两侧 `Grammar`，原有）。剔除记录点名的 Purge 本机不核：重切出去之后读者照样按
  `purge_vouches` 核。文件里新设备的公钥仍是首见即记（与导入的操作本身同一信任口径：`.fushisrs` 的操作不带作者签名）。
- **回收判据**（`cmd/sync_relay.rs` 文件头「重切材料的回收」）：作者区间还需要材料 ⇔ 本机没记它的 head / 最新 head 列着这个
  区间 / 转发缓存里还有这个区间的件；剔除记录跟着**还需要的区间**走：seq 落在某个还需要的区间里就留，只有那个区间本机存着
  作者签名版本、而这个 seq 在它作者签的空洞里时才不算；还需要、本机还没收到版本的区间整段留（复核 major：作者合并后
  `note_head` 早于收段，原先按「本机已存的版本」算会把 [1,4] 版本连同落在里面的剔除记录一起删，[1,8] 的版本晚到时重切
  不出来、这位作者被整台跳过；本机清除时写下的剔除记录删了生不回来）。记下更新的 head 与 `prune` 删缓存件时回收，只按这位
  作者的主键前缀 / 区间删。代价：版本到了之后作者空洞里的剔除记录要等下一次回收（下一份 head / `prune`）才删。
- **单条改动超过 16 MiB**：本机写入与 `.fushisrs` 导入报 `op too large: change <id> is N bytes (x MiB), over the 16 MiB limit …`
  （`gen4/op.rs` `payload_within_cap`），整笔回滚。**第三轮改成按类型认**：FFI 边界 `SrsCoreException.of`
  （`packages/fushi_srs/lib/src/store/srs_core.dart`）按内核那句的标记（`SrsOpTooLargeException.marker` = op.rs
  `ERR_OP_TOO_LARGE` + `": "`，`srs_core_test` 核对两边一致）把它类型化成 `SrsOpTooLargeException`，与 Unwired / ReadOnly
  等同一套机制；它是纯数据对象，经后台 isolate 原样转交（`srs_core_workers.dart` 的 `StateError(e.toString())` 兜底只给发不过去
  的对象用，碰不到它）。界面一律按类型选文案，不再匹配英文（删了 `kSrsOpTooLarge`），错误 → i18n 的表集中在
  `fushi/lib/src/srs/srs_action_error_text.dart`：
  - `srsActionFailedText(e)`：本机写入 → `srs_write_op_too_large`（太大、什么都没存、改用媒体附件），其余「操作没有成功」。
    原 23 处之外补上 `srs_history_page` 设备改名 / 停用 / 恢复 3 处、`srs_note_type_editor_page` 的 `_run`、导入报告
    「继续用 FSRS」（`srsKeepImportedDecksOnFsrsFromReport` 以前写库失败没接、异常直接冒出按钮回调）。
  - `srsImportFailureMessage(e)`（从 `srs_import_entry.dart` 挪来）：.apkg / .colpkg / 文本导入、Anki 一键迁移落库那一批
    超限 → 新 key `srs_import_op_too_large`（导入停在那里、此前已落库的批保留、改小后重导会补齐；每批只含完整笔记、导入
    幂等），不再显示内核英文原话；`srs_anki_migration_page` 的失败对话框原先自己抄了一份判断，改成调它。
  - `srsFushiSrsImportFailureText(e)`：时间线页 `.fushisrs` 导入。`srsFushiSrsKernelError` 遇到 `SrsOpTooLargeException`
    原样交回，不再换成按英文开头认的 `FormatException`。
  - 顺带修掉的真 bug：`srs_history_page` 的 `_run(…, failure: failure)` 在调用时就拿走了字符串初值，导入里 `catch` 再改
    `failure` 不生效——另一个复习库 / 坏文件 / 一条太大一直只显示笼统的「导入失败」。`_run` 的 `failure` 改成
    `String Function(Object error)`，拿到错误对象再选文案。
  - 没换、有意不换的：`srs_import_entry` / `srs_anki_migration_page:343` 里 `store == null` / `media == null` /
    `task == null` / 牌组不存在那几处 `t.srs_action_failed`——那里没有写库、也没有错误对象（库 / 媒体库打开失败已在
    `readSrsStore` / provider 里记日志），超限不可能出现在这些分支。

### 测试

- `cmd/sync_park_tests.rs` 4 条：待确认重切者 → 停放、之后不拉、同步页 `pending`；拒绝 → 再拉一次、按 `rejected` 停放；
  确认 → 拉、收下、同步页不再提。等 Purge → 不拉，b 的段出现后 Purge 进等待缓冲 → 下一轮拉、全部收下。没有日志的等待设备
  照样有一行。截断批交回 `requeue`、照 Dart 接回后全部收下、不报错。
- `import_tests.rs` `forged_relay_material_is_verified_before_it_lands`：已有有效行时导入签名乱填且空洞更多的版本 → 不换、计
  跳过；换了 Purge 的剔除记录 → 本机那条不动；空库导入载荷哈希被改的剔除记录 / 签名被改 / 不带作者公钥 → 都不记、重切不出来；
  真实流照记。`relay_material_survives_export_and_import_so_a_restored_library_can_still_recut` 未改断言照绿。
- 回收：`sync_relay_tests::reclaim` 四条（判据、合并后版本晚到仍能从日志重切的端到端、`put_stub_if_absent` 不换已有、
  规模）。导出 / 超限：`import_tests` 的超限一条、`sync_tests`
  `a_write_over_the_payload_cap_is_refused_readably_and_nothing_lands`、Dart `srs_fushisrs_errors_test.dart`。
  segBytes：`outbox_clamps_the_segment_target_to_the_cap`（测试钩子 `SEG_CAP_FOR_TEST` 把上限调到 300 字节）。
- 第三轮：超限类型化——`srs_core_test` `an op over the payload cap is typed on every write path`（与 op.rs 常量 / 报错格式
  对照）；`packages/fushi_engine/test/srs/srs_op_too_large_e2e_test.dart` 起真实 `SrsDbStore`（语句走后台 isolate）：加笔记
  超限抛 `SrsOpTooLargeException`、笔记数仍 0、之后照常能写，.apkg 里一条超限抛的也是它（不是 `SrsImportException.corrupt`）、
  这一批没落库；`fushi/test/srs/srs_action_error_text_test.dart` 三张表逐类核对。剔除记录核对规模：`gen4/export.rs`
  `relay_stubs_over_many_voids_check_in_linear_time`（三十万段空洞各带一条剔除记录，读写合计约 1.6 s；把双指针换回逐条扫
  空洞实测 28.7 s、超 15 s 时限红）。`put_stub_if_absent` 的 `INSERT OR IGNORE` 改 `OR REPLACE` 实测
  `put_stub_if_absent_never_replaces_a_stored_stub` 红。
- Dart：`srs_device_identity_test.dart` 新一条（`relayBlocked` 解析、按原因合计、认不出的项跳过、设备行文案）；
  `srs_sync4_round_test.dart` 断言收段带的位置与 `plan` 同值；`srs_sync2_ingest_batching_test.dart` 新一条（交回按下标取、坏
  下标报错）。
- 变异实测见 PR 描述（脚本逐个改、跑、还原，工作区干净）。

### 没做 / 已知限制

- 重切者「另出一份不依赖该 Purge 的件」不做（理由见上）。Purge 作者被读者永久拒绝时，只经这位重切者供数据的位置对该读者
  一直不完整，直到作者自己同步到那个位置——同步页如实说明，不丢数据。
- `requeue` 的 Dart 接回循环只单测了取下标的 helper；整条循环由内核测试里照 Dart 写的 `ingest_like_dart`（`sync_relay_tests.rs`）
  与 `a_truncated_batch_hands_the_waiting_recut_back_instead_of_dropping_it` 覆盖，没有起真实 `SrsDbStore` 造一批截断的重切件。
- 服务端管理页 / ctl 的设备列表没显示 `relayBlocked`（只接了 app 同步页）。
- `guards_tests.rs` `FROZEN` 追加了 40026 的指纹；40025 分给同批别的 PR，合流时按实际形状重算（两个号的表合起来才是终态）。
- 真机复测没做（纯内核 + 同步页文案，按规则记一句）。
- 复核 nit「同一位置同一作者既有自写旧 head 又有转发 head 时 tidy 可能删停放行」没改：复核者与续做者都没构造出触发路径
  （`relay_outbox` 的 `present_at` / `have` 挡住了作者已有自写 head 的位置），不为构造不出的情形改 `plan`。
