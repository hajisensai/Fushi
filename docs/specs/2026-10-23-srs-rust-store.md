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

`:popup` 进程不搬迁：它发现标记未写时只读旧表还是等主进程？——它不碰 SRS 写路径；查词状态读
`srs.db`，标记未写时返回空（主进程启动必先完成搬迁）。

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
