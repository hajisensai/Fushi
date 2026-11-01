# SRS 事件库归 Rust：独立 srs.db（P4 设计，2026-10-23）

> 接 [2026-10-23-srs-rust-core.md](2026-10-23-srs-rust-core.md) §3 的 P4。所有者 2026-10-23 拍板：SRS 拆成独立
> 的 `srs.db`，只由 Rust 持有连接；P2 → P3 → P4 一路做完。本文只讲存储归属、迁移、备份与线程边界；
> 事件模型、线格式、落库 JSON、持久化名一律不变。

## 1. 为什么是独立文件

- Rust 连库用 rusqlite（`bundled`，自带一份 SQLite 3.50.x）。Drift 用的是 Dart `sqlite3` 包那一份。
  同一进程里两份 SQLite **打开同一个文件**，在 POSIX 平台（Android / iOS / macOS / Linux）上会互相
  清掉对方的 fcntl 锁（SQLite 官方「How To Corrupt An SQLite Database」§2.2.1），可能损坏数据库；
  Windows 不受影响，本机测不出来。
- 让 Rust 动态链接 Dart 那一份要按五个平台各写一套查找规则（iOS 还是静态的），脆弱。
- 两份 SQLite 各开**不同的文件**没有这个问题。SRS 的 SQL 本来就不与非 SRS 表 JOIN（盘点：
  `srs_db_store.dart` 里唯一的 JOIN 是 `srs_review_logs LEFT JOIN srs_event_local`），拆库的
  代价只在备份 / 合并 / profile 身份三处跨库编排（§4）。

**硬规则（守卫钉死）**：
1. Rust 只打开 `srs.db`、备份快照里的 `srs.db` 副本、或 Rust 自己生成的临时文件；绝不打开 `fushi.db`
   或 Dart 正在 ATTACH 的文件。
2. Dart（Drift / `sqlite3`）绝不打开 `srs.db`。
3. 旧库里的 SRS 数据一律由 **Dart 读出、按页交给 Rust 写入**（§3），不让 Rust 去读 `fushi.db`。

## 2. 存储与线程

- 文件：`<数据库目录>/srs.db`（与 `fushi.db` 同目录；`-wal` / `-shm` 同名）。一个文件放全部 profile，
  表结构与今天 9 张 `srs_*` 表逐列相同（含 `profile_uid` 列与全部索引，含部分索引
  `idx_srs_field_edits_history_from` 的 WHERE 原文），SQL 可以原样搬。
- 文件内另有 `srs_meta(key TEXT PRIMARY KEY, value TEXT)`：`schema`（本库自己的版本号，从 1 起，
  迁移阶梯在 Rust）、`legacy_import`（旧库搬迁完成标记，§3）。
- PRAGMA：`journal_mode=WAL`、`busy_timeout=5000`、`synchronous=NORMAL`、`foreign_keys=OFF`（与主库的
  WAL / busy_timeout 一致；SRS 表没有外键）。
- Rust 侧对象 `SrsCore`：一条写连接 + 一条读连接，各在一把 `Mutex` 里。写命令 = 写连接上的一个事务；
  读命令走读连接（WAL 快照），不被长写阻塞。多进程（主进程、`:popup` 进程）各自打开，跨进程靠
  SQLite 文件锁，与今天主库相同。
- Dart 侧：命令都在后台 isolate 执行（一个常驻 worker isolate，持有句柄地址；Rust 对象线程安全），
  入参 / 出参是 `Uint8List`（`TransferableTypedData` 零拷贝转移）。UI isolate 不做同步 FFI 读库。
- 写锁：一个写命令就是一个 Rust 事务，Rust 的写连接 Mutex 即写锁。Dart 的 `runExclusive` 只在仍有
  「Dart 读现值 → 组草稿 → 提交」三段式的过渡期保留（排队语义不变），P4 完成时只剩提交一步，
  `runExclusive` 删除。

## 3. 旧库搬迁（一次性，可重入）

时机：`SrsDbStore.open` 之前、由 app 装配层调用 `srsMigrateLegacyStore(db, core)`：

1. `core.legacyImported` 为真 → 第 4 步。
2. 主库没有 `srs_entities` 表（新装）→ 写标记，结束。
3. Dart 用 Drift `customSelect` 按 rowid 分页读 9 张旧表（每页约 5000 行，行打包成列式字节），
   每页一次 `ffsrs_store_legacy_page`；最后一次 `ffsrs_store_legacy_commit` 在同一个 Rust 事务里
   写入全部页与标记（页先进 Rust 内存中的暂存表 / 临时文件，commit 才落 `srs.db`）。中途崩溃 =
   `srs.db` 里什么都没有，下次从头搬。
4. 标记已在 → Dart 在主库 `DROP TABLE IF EXISTS` 9 张旧表与其索引（Drift schema v125 不再声明它们；
   迁移步只建 / 删别的东西，不碰这 9 张表，**删表只在搬迁标记写入之后发生**）。

只有主进程搬迁。`:popup` 进程（`isMainProcess: false`）只读 `srs.db`；标记还没写（主进程尚未
完成首次搬迁）时它当作没有 SRS 数据，不去读主库旧表。

实现：`packages/fushi_engine/lib/srs/srs_legacy_store_migration.dart`（列序表 `kSrsLegacyTables`
与 Rust `schema.rs` 的 `TABLES` 逐项相同，`srs_legacy_store_migration_test.dart` 钉住它与 Drift
表的 `PRAGMA table_info` 一致、搬迁逐行逐字节相同、失败整体回滚且旧表不删）。

## 4. 跨库编排

| 流程 | 今天 | P4 |
|---|---|---|
| 通用备份导出（`backup_service.dart`） | `VACUUM INTO` 主库副本，再按类别删 srs 表 | 主库副本不再含 srs；勾「复习」时另由 Rust `VACUUM INTO` 出 `srs.db` 快照（并在快照里清空 5 张设备本地表），作为 zip 里的 `srs.db` 条目 |
| 覆盖恢复 | 换主库文件，清 5 张设备本地表 | 先关 SRS（provider 失效 → `core.close()`），换主库文件；备份带 `srs.db` 就换 `srs.db`（删 `-wal` / `-shm`），老备份（srs 在 `fushi.db` 里）就删掉 `srs.db`，下次打开走 §3 搬迁 |
| 合并导入（`BackupMergeEngine` ATTACH 备份库） | `mergeSrsFromAttachedBackup` 经 ATTACH 读备份的 4 张事件表 | 新备份：Rust 只读打开 zip 解出的 `srs.db` 副本（Dart 不碰它）读事件；老备份：Dart 经 ATTACH 读、按页交给 Rust。合并本身是 `applyRemote` 同一条 Rust 路径 |
| profile 身份（`profiles.uid` 与 srs 的 `profile_uid`） | 同一事务里删 srs 行 + 写 `profiles.uid` | 跨文件不再原子：先在 Rust 里改 / 删 srs 行，再写主库 `profiles.uid`；两步都幂等，中途失败重跑即收敛 |
| `profiles` 清理子查询（`backup_service.dart:843`） | `NOT IN (SELECT profile_uid FROM srs_entities)` | 由 Rust 返回快照里出现过的 profile_uid 集合，Dart 拼 `NOT IN (?, ?, …)` |

## 5. Dart 接口

- `SrsCardCacheRow` / `SrsNoteCacheRow` 等改为 `fushi_srs` 里手写的不可变值类（字段名与今天 Drift
  生成的同名同型），调用方基本不改；Drift 生成的 `Srs*Row` 随表声明一起删除。
- `SrsDbStore` 不再持有 `FushiDatabase`；`store.db` 的外部直接查询（统计、RWKV、apkg、制卡、
  笔记类型、Lapis 迁移）全部改为 store 上的粗粒度命令。
- 测试：直接 SQL 断言改用 `store.debugQuery(sql)`（Rust 读连接上执行、结果 JSON；只在 `assert`
  模式 / 测试库可用），不再经 Drift。

## 6. 守卫

- `fushi/test/build/srs_store_ownership_guard_test.dart`：`fushi/lib` 与 `packages/*/lib` 里不得出现
  `srs_entities` 等 9 个表名（Rust 源码与搬迁代码白名单）；Drift `tables.dart` 不得声明 `Srs*` 表；
  Rust 源码不得出现 `fushi.db`。
- `backup_table_rules_guard_test` 的「每表必登记」随表声明删除自然不再包含这 9 张。

## 7. 落地状态与实测（2026-10-24）

已落地：
- srs.db（`native/fushi_fsrs/src/store/`）：建表 / 版本、旧库搬迁事务、`VACUUM INTO` 快照、只读调试查询、
  Drift 执行器后端（`ffsrs_store_exec` / `_exec_batch`）、缓存刷新的直读命令 `ffsrs_store_history_states`。
- 主库 Drift 不再声明 9 张 srs_* 表（schema 版本不变，仍 124）；迁移阶梯上的老库仍按 `kLegacySrsTableDdl`
  建出旧表，由 `srsMigrateLegacyStore` 搬走后删除。
- `SrsDatabase`（fushi_core）+ `srsDatabaseConnection`（fushi_engine）：Dart 的查询构造器不变，语句在 Rust
  写连接上执行；`SrsDbStore.open(db:, core:)`。app 侧进程级 `SrsStorage`（`fushi/lib/src/srs/srs_storage_host.dart`）。
- 缓存刷新：血统修改记录仍由 Dart 预读（寄存器内核要它们），**日志不再经过 Dart**：每块一次
  `ffsrs_store_history_states`（后台 isolate），Rust 在同一条写连接上 JOIN 读日志与服务器时刻、选取、只回状态。
- 备份 / 恢复 / 合并按 §4（新备份带 `srs.db` 条目，老备份照旧）。
- 连接设置：`mmap_size = 256 MB`、`cache_size = 64 MB`；结构体字段顺序保证写连接最后关闭（WAL 并回主文件，
  测试 `closing_folds_the_wal_back_into_the_main_file`）。

实测（Windows x64，`FUSHI_SRS_CACHE_BENCH=<笔记数> dart test test/srs/srs_cache_rebuild_bench_test.dart`，每卡 10 条日志；
改前 = `534c1f6ebf`（P1+P2，Drift 唯一连接），改后 = 本阶段；同一时段新旧交替各跑两遍、每遍三轮）：

| 规模 | 操作 | 改前 | 改后 |
|---|---|---:|---:|
| 3000 笔记 / 6000 卡 / 6.6 万日志 | `rebuildCaches()` | 976–1081 ms | 564–761 ms |
| | `histories(全部)` | 830–969 ms | 601–883 ms |
| | 全部笔记批量改标签 | 1531–1758 ms | 954–1315 ms |
| 10000 笔记 / 20000 卡 | `rebuildCaches()` | 4156–5112 ms | 2024–2384 ms |
| | `histories(全部)` | 2965–4188 ms | 2190–3126 ms |
| | 全部笔记批量改标签 | 6093–8013 ms | 3557–5796 ms |

- 执行器本身与 Drift 自带的 NativeDatabase 同速（`srs_executor_ab_bench_test.dart`：6 万行全表 + 200 次按卡查询，
  两边 650–730 ms 交替持平）；收益来自两处：日志不再跨 isolate、Rust 连接的 mmap + 大页缓存（直读命令里 SQLite
  读 6.6 万行从 260–400 ms 降到约 160 ms；`opt-level` 3 / z 无差别）。

### 7.1 P6：统计 / 优化器 / RWKV 取数收编（2026-10-24）

三处「把整份历史读进 Dart 再算」改成 Rust 在 srs.db 的**读连接**上一个读事务里直读日志 + 服务器时刻、选取、投影，
只把结果列交回 Dart（`native/fushi_fsrs/src/store/projections.rs`，规则在 `src/projection.rs`）。读连接 = 只看
已提交的行、不挡写连接上的作答；血统与数字 id 仍由 Dart 给出（与缓存刷新的 `history_states` 同一形态，只预读修改记录）。

| 路径 | 命令 | 交回 Dart 的东西 | 删掉的 Dart |
|---|---|---|---|
| 优化器训练集（`srsPrepareOptimization`） | `ffsrs_store_optimizer_items` | 列式训练集（每张进训练集的卡一条评审序列 + 按时刻排好的前缀条目），`SrsTrainingSet` 一块字节跨 isolate，拟合用的后台 isolate 里才展开 | `store.histories` 循环、`_timeUncertain`、逐卡 `srsCollectMemoryInput` |
| RWKV 全量回放 / 增量追加 / 排队此刻行（`SrsRwkvService`） | `ffsrs_store_rwkv_rows`（逐卡 / 全量）、`ffsrs_store_rwkv_log_tail`、`ffsrs_rwkv_now_rows` | `RwkvRows` 同布局的字节（全量已按时刻排好）、指纹与日志尾巴 | 整个 `srs_rwkv_history.dart`（保留评分 / card_type / 间隔 / 行构建 / 排序）、服务里 4 条 SQL 与「读完再核对、丢卡重读」循环 |
| 统计页（`loadSrsStats`） | ~~`ffsrs_store_stats_reviews`~~ → 见 §7.2，改为读投影表 | — | 全表 `db.select` + 逐卡 `SrsCardHistory` |
| 记忆状态输入（排程 `SrsCardOps` 也用） | `ffsrs_memory_input`（列模式） | 评审序列与起点 | `srsElapsedDays`、`srsIsReset`、`srsIsRestoreState`、`_fromAnchor` / `_lastAnchor` |

- 回归向量：`packages/fushi_engine/test/srs/fixtures/p6_vectors.json.gz` 与
  `packages/fushi_srs/test/memory/fixtures/memory_input_vectors.json.gz` 由删除前的 Dart 实现生成（脚本留档
  `gen_p6_vectors.dart.txt`），1200 份随机历史 × 四种日界；`srs_p6_vectors_test.dart` 把日志写进真实 srs.db 经命令取回逐条比
  （训练条目、回放行逐字节、此刻行逐字节、统计投影与记忆状态），`memory_input_vectors_test.dart` 钉列模式三种算法。
- RWKV 全量回放的指纹与回放行出自同一条语句（同一快照），列卡之后才新建的卡由 Rust 作为「漏卡」报出、补进再取，
  取代原来「读完核对指纹 → 丢掉有新日志的卡重读」的五轮循环。
- **行为差异（有意）**：统计页以前构造 `SrsCardHistory` 时不带服务器时刻（不钳位排序键），与缓存刷新 / `histories()` 的
  选取不一致；现在与它们同一套（含钳位）。只影响有被钳位日志、且钳位改变了有效顺序的卡。
- 日志 ID 排序 / 时刻并列：训练条目按评分时刻**稳定**排序（同刻按卡的输入顺序）；旧实现用 Dart 的不稳定 `List.sort`，
  并列时的先后本来就不确定。

实测（Windows x64，`FUSHI_SRS_P6_BENCH=<笔记数> dart test test/srs/srs_p6_projection_bench_test.dart`，每卡 10 条日志，
三轮；改前 = `fce7dacc18`（只加了向量与 bench，取数代码与 `9320259ca4` 相同；实测在它 rebase 前的同内容提交上跑），改后 = 本阶段；同一时段新旧交替各跑两遍）。
计的是调用方看到的整段耗时：优化器 = 每个参数归属牌组一次准备 + 训练集送进后台 isolate 展开；RWKV = `rebuild()`
一次全量回放（后端是只收行的替身）；统计 = `loadSrsStats` 一次。

| 规模 | 操作 | 改前 | 改后 |
|---|---|---:|---:|
| 3000 笔记 / 6000 卡 / 6 万日志 | 优化器准备 + 跨 isolate | 1615–1950 ms | 544–780 ms |
| | RWKV 全量回放 | 1194–1455 ms | 563–792 ms |
| | 统计页装载 | 1322–1592 ms | 709–907 ms |
| 10000 笔记 / 20000 卡 / 20 万日志 | 优化器准备 + 跨 isolate | 4802–6303 ms | 1490–2286 ms |
| | RWKV 全量回放 | 3465–4638 ms | 1944–2736 ms |
| | 统计页装载 | 4402–5187 ms | 2182–2919 ms |

### 7.2 有效复习投影 `srs_stat_reviews`（与 #2481 合并，2026-10-25）

#2481 给统计页（BUG-3772）与统计总览的复习时长（BUG-3771）加了一张可重建的投影表，原设计放在主库、投影算法在 Dart
`_cardCacheRow` 里按卡算。与本设计合并时改成：

- **表在 srs.db**（schema v3，`SrsStatReviews`），设备本地缓存：快照剥离（`snapshot_into` 清空）、合并改 uid 时随 profile 删，
  主库 schema 不因它升版本（没有 v129）。
- **投影规则在 Rust**：`history::stats_from_json`（与删除前的 Dart `srsStatProjectionOf` 逐条对应，p6 向量的统计期望就是
  删除前 Dart 实现的输出）；store 命令 `stat_projection(groups)` / `ffsrs_store_stat_projection` 在写连接上直读日志（看得见
  本事务未提交的行），一批归属组一次调用，回 9 列行页。缓存刷新里日志仍不经 Dart。
- **归属在缓存刷新的第二趟定**（`SrsDbStore._refreshStatProjection`，在本轮全部缓存行写完、可见性定下之后）：卡自己可见
  → 归自己；否则归继承它历史的可见卡中 id 最小的；都不可见 → 归后代里的链尾；没有后代 → 归自己。每个归属组的日志合在一起
  按合并历史分类。#2481 原来「每条日志只由自己的卡投影、读时再按 `historyOwnerIndex` 换归属」在三处出错（审查实锤）：前身卡
  没有缓存行（重建 / 覆盖恢复 / 新设备首次同步）时它的复习整段消失；前身与后继日志交错时分类与成熟净值错；物理清除后增量与
  重建结果不同。现在增量、重建、升级同一规则；清除后的复习照样计入（与旧统计、Anki 保留 revlog 一致），重建按「全部有日志的卡」重算。
- 删除：`ffsrs_store_stats_reviews`、`SrsStatsColumns`、`SrsDbStore.statsColumns`、Dart 的 `srsStatsFromLogs` /
  `srsStatsFromHistory` / `srsStatProjectionOf`。统计页读投影（`loadSrsStatProjection`），读时按日界分桶（`srsStatsFromProjection`）。
- 总览复习时长：`loadStatFacts(reviewsFrom: SrsDatabase?)`，先在主库把 `profiles.id` 换成 uid，再在 srs.db 上用 Drift 表达式聚合。
- 缓存修订号 2：存量库升级时按全部卡 + 全部有日志的卡算一遍投影。

### 7.3 其它按需读（2026-10-25）

- 时点恢复（`srs_point_in_time_restore.dart`）不再两次整库 `exportAll()`：改回字段只读身份记录 + 修改记录
  （`exportEntitiesAndEdits`），日志一步先读「日志 ID → 卡」两列（`logIdsByCard`）定受影响的卡，再只解码这些卡的日志
  （`logsOfCards`），前身链接走部分索引（`successorIndex`）。
- 媒体同步：笔记缓存加 `media_refs` 列（schema v4，缓存修订号 3），随笔记缓存同一次刷新算出（存量样式去重
  `compactStoredStyles` 改写字段后也会刷新这条笔记）；`srsReferencedMedia` 每轮只读这一列，不再逐页读全部修改记录解析字段。
  媒体回收（`srsAllMediaReferences`，保守口径含已删未清与并发候选值）仍按页读修改记录，只在维护时跑。

仍未收编（下一步）：
- 统计页的笔记缓存行 / 卡缓存行 / 笔记物化仍经 Drift 执行器读；可提取度分组留在 Dart。
- 血统（字段寄存器内核）仍由 Dart 预读修改记录后给出；搬进 Rust 后这几条命令可以只收卡 ID。
- Lapis 迁移里还有直接 SQL，`srs_store_ownership_guard_test` 按文件白名单放行。
- 写路径（事件落库、支配判定、写入者状态）仍是 Dart 组语句、Rust 执行；收编为 Rust 事务命令后删除 Dart 的 `runExclusive`。

### 7.4 事务外查询并发（BUG-3961，2026-11-01）

- 以前：Drift 连接是一个后台 isolate 上的顺序执行器（`isSequential: true`，每条语句一次同步 FFI），内核里事务外查询只有
  一条 `drift_reader`。同步里一条几秒的长读（全量冲突扫描、媒体对账）跑着时，打开卡片 / 牌组设置的短读排在它后面等满全程。
- 现在 `srsDatabaseConnection` 是 `SrsSplitExecutor`：
  - 写那一路（写语句、`runCustom`、批量、事务 / 独占块里的一切语句）仍是原来那条顺序执行器 + 写连接，Drift 的事务语义、
    读己之写、`drift_tx` 选路不变；
  - 事务外的 `runSelect` 发到内核命令 worker 的查询道（`SrsCoreLane.query`，3 个 worker），在内核只读连接池
    （`store/read_pool.rs`，按需开、上限 `DRIFT_READERS` = 4）上并发执行（`ffsrs_store_exec` mode 3 / `SrsCore::snapshot_select`）；
    不是只读查询（PRAGMA、`… RETURNING`）报 `NOT_SNAPSHOT`，改发写那一路。
- 一致性：每条事务外查询自成一个读事务，看它开始时已提交的数据——以前单条读连接上前后两条语句之间也可能隔着一次提交，
  从来没有跨语句快照，所以对调用方是同一种保证。唯一的语义变化：Drift 事务开着时，事务外的查询不再等它提交，而是读到
  事务开始前的已提交数据（与任何多连接 SQLite 相同）；需要「同一时刻」一致读多张表的调用方本来就要放进 `db.transaction`
  （写连接上读）或用 `SrsCore.beginRead` 的只读会话。表更新通知（流查询按 `readsFrom` 重跑）由客户端的 `StreamQueryStore`
  在写返回 / 事务提交后发出，与执行器无关，不变。
- 生命周期：`SrsSplitExecutor.close` 等在途查询结束再关写那一路；`SrsCore::close` 关池时等借出的连接放回（放回即关），
  返回时池子开过的连接一条不剩。
