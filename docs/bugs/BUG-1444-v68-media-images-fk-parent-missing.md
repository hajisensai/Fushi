## BUG-1444 · v68 迁移 INSERT media_images 在外键开启时因 FK 父表缺席抛 no such table，整条 onUpgrade 中断
- **报告**：2026-08-02（用户：PR#712 集成线硬停，`hibiki/test/database` 65 个 error / 18 个文件）
- **真实性**：✅ 真 bug。根因 `packages/hibiki_core/lib/src/database/database.dart:1379`（`if (from < 68)` 步里那条 `INSERT INTO media_images ... SELECT ... FROM collection_scrape_meta`）。

  `media_images` 带两条外键（`collection_id` → `media_collections`、`book_uid` → `video_books`，
  `packages/hibiki_core/lib/src/database/tables.dart:1355`）。SQLite 解析外键父表的时机是**执行 DML 时**、
  不是建表时：只要 `PRAGMA foreign_keys = ON`，这条 INSERT 就会去找两张父表，缺任何一张直接抛
  `SqliteException(1): no such table: main.<父表>`，把整条 `onUpgrade` 打断——库升不上去、app 打不开。
  抛不抛与本条 INSERT 搬几行、`book_uid` 是否恒为 NULL 全都无关。

  两张父表都不是「从来就有」：`video_books` 只在 `from<17` / `from<20` 建、`media_collections` 只在
  `from<38` 建（`database.dart:628` / `:660` / `:875`）。而真实 app 恒以 `PRAGMA foreign_keys = ON`
  打开库（`database.dart:156` `_openWithRecovery` 的 `applyPragmas`），所以「外键开着」不是测试专属条件。

  实测 65 个 error 里 44 个是这条（33 个 `video_books` + 11 个 `media_collections`），其余 20 个是
  schema bump 后没跟着改的 `expect(..., 67)` 字面量、1 个是前面抛错后的文件锁连带。

  **爆炸半径的如实边界**：真实用户库走到 v68 时两张父表恒在（v38+ 的库必有 `media_collections`，
  v20+ 的库必有 `video_books`），所以这条**不会**让正常升级路径的老用户打不开 app。硬红的是
  部分迁移库 / 阶梯测试的最小种子库，以及由此而来的 CI 单测门。另有一条外溢：升级完成后
  `media_images` 在这类库里成了一张「碰不得」的表——`DELETE FROM video_books` 触发 cascade 时
  SQLite 要解析 `media_images` 自己的 FK，同样抛（`migration_v57_naming_unification_test` 实测）。
- **[x] ① 已修复** — `b821cfe51`：搬运期间 `PRAGMA foreign_keys = OFF`，收尾**按进入时的取值恢复**
  （新增 `_foreignKeysEnabled()`；不像 v57 无条件置 ON，那会把调用方显式关掉的外键悄悄打开）。
  沿用 v16/v57 的既有先例：搬运的引用完整性由源表 `collection_scrape_meta` 自己的外键继承；
  刻意不加 `foreign_key_check` 门——真库若存过孤儿刮削行，抛错等于把用户锁死在「app 打不开」，
  代价远大于一行永不渲染的残图。
- **[x] ② 已加自动化测试** — `hibiki/test/database/migration_v68_media_images_test.dart`（4 例，全部
  **显式指定**外键状态）：父表缺席 + 外键开着不抛；父表齐全时搬运正确且外键仍是**真强制**（删合集
  cascade 清图组，只断言 PRAGMA 值会被「写回去但没生效」骗过）；进来时外键关着则升完仍关着；
  `media_images` 已在场时重复升级不重插。变异实测：还原 FK-off 后第 1 例红在原始报错
  `no such table: main.video_books`；把恢复改成无条件 ON 后第 3 例红。
- **备注**：同域既有的 `media_images_test.dart` 覆盖不到这条——它的 v67 种子用 `NativeDatabase.memory()`
  默认关外键，父表缺不缺都不报，正是本仓反复记过的「memory DB 默认关外键 = FK/cascade 用例假绿」同一个坑。
  同轮连带修正：`migration_v57_naming_unification_test` 种子补 `media_collections`（真实 v56 库恒有该表，
  种子缺它是 fixture 不真实）、`migration_v63` 新增表白名单补 `media_images`、14 个文件 37 处
  `expect(..., 67)` → `68`。纯 DB 迁移层，无需设备复测。
