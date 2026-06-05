# 书身份重构：名字当主键（sub-project 1/3）

- 日期：2026-06-05
- 状态：设计待 review
- 模块：`packages/hibiki_core/`（schema+迁移）、`hibiki/lib/`（全 app 代码扫荡）、`packages/hibiki_audio/`（repos）
- 依赖关系：这是地基。完成并验证后，② 同步 hash manifest（建在新身份上、统一 upsert、不再需要 reimportInPlace）和 ③ 删有声书位置开关分别另立计划。

## 1. 背景与动机

当前书的身份被**两个概念混在一起**：

- `EpubBooks.id`（自增整数）= 本地行 id，且被当作**物理/编码 token**（磁盘目录名 `hoshi_books/<id>/`、`mediaIdentifier=hoshi://book/<id>`、`bookUid=reader_ttu/hoshi://book/<id>`）。
- **跨设备书身份** = `sanitizeTtuFilename(title)`，已用于 sync folder/asset key、SyncBaselines.assetKey、ReadingStatistics（按 title）。

两者并存导致：① 同步层要靠 `ttuBookIdOverride` 在 int 与 title 间反复翻译（`sync_asset_package_service.dart:148-170`）；② `audiobook_pos_` 有**两套不一致键空间**（`SyncRepository` 用 int id、`AudiobookRepository` 用 bookUid 字符串）；③ 重导入换 id → 阅读数据孤儿。

**目标**：消灭这层双重身份，让 `bookKey = sanitizeTtuFilename(title)` 成为**唯一**身份——主键、关联键、磁盘目录、mediaIdentifier 全用它。本地导入早已强制 `sanitizeTtuFilename(title)` 唯一（`resolveBookTitleConflict` 同名加后缀），所以名字当主键与现有不变量天然吻合。

**收益**：跨设备天然一致；重导入/覆盖统一为"按 bookKey upsert"，**消除 reimportInPlace 的必要**；统一 `audiobook_pos_` 单键空间；删除 int↔title 翻译层。

## 2. 范围

**无损迁移**（用户拍板）：现有本地书 + 全部阅读数据（进度/书签/有声书/cue/srt/位置/Profile/标签）必须无损保留。

### 非目标
- 不引入同步 hash（那是 sub-project 2）。
- 不删有声书位置开关（sub-project 3）。
- 不改 ReadingStatistics 的存储（已按 title，仅对齐 sanitize 口径，见 §4.5）。

## 3. 新身份模型

```
bookKey: String = sanitizeTtuFilename(title)   // 唯一身份，本地已保证唯一
```

- **EpubBooks 主键**：`id`(int autoincrement) → `bookKey`(TEXT PRIMARY KEY)。删除自增 id。
- **关联键全部改 TEXT bookKey**：
  - `ReaderPositions.bookKey`（原 ttuBookId int，unique→PK 或 unique 保持）
  - `Bookmarks.bookKey`（原 ttuBookId int FK→ TEXT FK cascade）
  - `BookTagMappings.bookKey`（原 bookId int FK→ TEXT FK cascade）
  - `SrtBooks.bookKey`（原 ttuBookId int；sentinel 0=standalone 改为 NULL/空串语义，见 §4.3）
  - `Audiobooks.bookKey`（原 bookUid 字符串 → 直接用 bookKey，去掉 `reader_ttu/hoshi://book/` 包装）
  - `AudioCues.bookKey`（同上）
  - `BookProfiles.bookKey`（PK，原 bookUid 字符串 → bookKey）
- **磁盘目录**：`hoshi_books/<bookKey>/`（sanitizeTtuFilename 已是路径安全字符）。`EpubStorage` 的 `bookDirectory/bookPath/deleteBook/bookExists` 签名 `int`→`String`。
- **mediaIdentifier**：`hoshi://book/<bookKey>`（格式不变，仅 int→name）。MediaItems 存量 identifier 随迁移重写。
- **prefs 统一单键空间**：`audiobook_pos_<bookKey>`，连带 `audiobook_follow_/delay_/speed_/volume_/image_pause_/health_overlay_<bookKey>`、`bookmarks_<bookKey>`。**两套 audiobook_pos 键空间合一。**
- **删除 `buildLegacyBookUid` 与 int 解析**：`legacy_book_uid.dart`、`reader_hibiki_source.parseBookId` 的 `int.tryParse`、`audiobook_repository.buildTtuBookIdMap` 的 `int.tryParse` 全部改为直接用 bookKey 字符串。保留旧 `?id=<int>` 格式仅在**迁移读取存量 MediaItems**时用于解析，迁移后不再产生。

> **持久化 key 残留约束**：CLAUDE.md 警告 `reader_ttu`/`ttuBookId` 等是旧数据兼容残留、"没有迁移方案别动"。本设计**就是**那个迁移方案——schema v16 一次性把它们重键，故可动；但列名对外不可见的可保留旧名（如 `ReaderPositions.ttuBookId` 列可改名 `bookKey` 或保留列名只改类型，实现计划择一，倾向改名以消除误导）。

## 4. 迁移设计（v15 → v16，核心风险）

drift `onUpgrade` 加 `if (from < 16)` 分支，用 `customStatement` 手写"建新表 + 搬数据 + 删旧 + 改名"（drift `m.addColumn` 不足以改主键；参照 `database.dart:165-213` v12 的 `customStatement` + `tableExists` guard 范式）。

### 4.0 前置：构建 id→bookKey 映射 + 去重
1. 读所有 `epub_books(id, title)`。
2. 对每本算 `key = sanitizeTtuFilename(title)`。**去重**：若多本算出同 key（存量脏数据，理论上不该有但必须防），按 `resolveBookTitleConflict` 同款给后者加 ` (2)` 后缀直到唯一，并记日志。
3. 得到 `Map<int oldId, String bookKey>`，迁移全程用它翻译。

### 4.1 EpubBooks 重建
`CREATE TABLE epub_books_new (book_key TEXT PRIMARY KEY, title TEXT, author TEXT, cover_path TEXT, epub_path TEXT, extract_dir TEXT, chapter_count INTEGER, chapters_json TEXT, toc_json TEXT, source_metadata TEXT, imported_at INTEGER)` → `INSERT ... SELECT` 用映射把 id 换成 book_key → `DROP epub_books` → `ALTER ... RENAME`。

### 4.2 真 FK 表（Bookmarks、BookTagMappings）
迁移期 `PRAGMA foreign_keys=OFF`（drift 迁移内安全做法，参照 `database.dart:399-407` 注释的 FK 坑），重建为 `book_key TEXT REFERENCES epub_books_new(book_key) ON DELETE CASCADE`，`INSERT...SELECT` 翻译旧 int → bookKey，迁移结束 `PRAGMA foreign_keys=ON`。

### 4.3 隐式键表（ReaderPositions、SrtBooks）
- ReaderPositions：`ttu_book_id INT` → `book_key TEXT`（保持 unique），翻译。
- SrtBooks：`ttu_book_id INT`（sentinel 0=standalone）→ `book_key TEXT NULL`（standalone=NULL）；`uid` 独立字符串不动。

### 4.4 uid-字符串表（Audiobooks、AudioCues、BookProfiles）
旧 `bookUid = reader_ttu/hoshi://book/<oldId>`。迁移：正则抠出 `<oldId>` → 映射成 bookKey → 写 `book_key` 列。`AudioCues` 行多，用批量 `UPDATE`/重建。BookProfiles 主键随之改。

### 4.5 prefs 重键
- `audiobook_pos_<oldId>`（SyncRepository 风格，int）→ `audiobook_pos_<bookKey>`。
- `audiobook_pos_<reader_ttu/hoshi://book/oldId>`（AudiobookRepository 风格，uid）→ 抠 oldId → `audiobook_pos_<bookKey>`。**两路汇聚到同一新键**；若两路对同一本书都有值，取 reader 实时写的那路（uid 风格）为准（它是播放器实时回写，更新）。
- `audiobook_follow_/delay_/speed_/volume_/image_pause_/health_overlay_<uid>` → `_<bookKey>`。
- `bookmarks_<oldId or uid>` → `bookmarks_<bookKey>`（确认 `bookmark_repository.dart:71` 的 `_key` 口径后翻译）。
- `backup_service.dart:392/395` 的 `NOT LIKE 'audiobook_pos_%'` 过滤：前缀不变，无需改。

### 4.6 ReadingStatistics 对齐
stats 按**裸 title**存（`tables.dart:129-141`），新主键是 **sanitized title**。迁移把 stats 的 `title` 列改写为 `sanitizeTtuFilename(title)` 以对齐主键域（否则查统计对不上）。注意 sanitize 可能让两条裸 title 合并，按 `{title,dateKey}` upsert 累加。

### 4.7 磁盘目录迁移
`hoshi_books/<oldId>/` → `hoshi_books/<bookKey>/`：迁移**在 DB 事务外**做（IO 不能进 SQL 事务），逐目录 rename，更新 `extract_dir` 列。幂等：目标已存在则跳过+日志；rename 失败记录但不中断（reader 用 `extract_dir` 列定位，作兜底）。**实现计划评估**：是否改为 reader 一律读 `extract_dir` 列、彻底不再 `bookDirectory(key)` 算路径，从而免去目录 rename（更安全）。倾向后者——目录名保持旧 int 也无妨，因为 `extract_dir` 列已是真相源。

### 4.8 MediaItems identifier 重写
`mediaIdentifier`/`uniqueKey = hoshi://book/<oldId>` → `hoshi://book/<bookKey>`，`UPDATE` 翻译。

## 5. 代码扫荡（58 处 / 11 文件，机械但量大）

按热点分任务组：
- **编解码中枢 `reader_hibiki_source.dart`**（9 处）：`mediaIdentifierFor(String)`、`bookUidFor`删除/改为恒等、`parseBookId→parseBookKey(String)`、`_extractBookId`。这是 hub，先改。
- **`reader_hibiki_page.dart`**：`widget.bookId:int` → `widget.bookKey:String`，下游 ~20+ 处 `ttuBookId: widget.bookId`、`EpubStorage.*(widget.bookId)`、`findByTtuBookId`、favorite/bookmark 过滤全改。
- **`reader_hibiki_history_page.dart`**：`_parseBookId`→`_parseBookKey`、`bookId: book.ttuBookId`→`bookKey:`、打开 reader 入口。
- **`epub_importer.dart`**：`import*` 返回 `Future<String>`（bookKey 而非 int id）；插库用 bookKey；删除"rename temp dir to id dir"逻辑（改用 bookKey 目录或 extract_dir 列）。
- **DB 访问器签名**（§6 清单）：`int bookId/ttuBookId`→`String bookKey`；`getEpubBook(String)`、`deleteEpubBook(String)`（内部手动 cascade + `buildLegacyBookUid` 删除）、tag/profile/position/srt 全套。
- **repos**（`packages/hibiki_audio/`）：reader_position/srt_book/audiobook/bookmark/favorite_sentence repository 的 int 签名 → String。
- **sync 层**（`sync_manager` 15 处、`sync_orchestrator` 7、`sync_compare_dialog` 3、`sync_auto_trigger`）：去掉 int↔title 翻译，直接用 bookKey；`ttuBookIdOverride`/`bookUidOverride` 机制简化或删除。

## 6. 测试策略

- **迁移测试（最重，照 `packages/hibiki_core/test/migration_downgrade_test.dart` 范式）**：手写 seed 一个 v15 库——自增 id 的几本书 + reader_positions/bookmarks/book_tag_mappings(int) + audiobooks/audio_cues/book_profiles(uid 字符串) + `audiobook_pos_` 两种键 + media_items identifier + reading_statistics(裸 title)——`PRAGMA user_version=15`，打开 `forTesting` 触发 v16，断言：
  - 每本书按 bookKey 存在，所有阅读数据按 bookKey 仍连着（进度值、书签数、有声书行、cue 数、profile、标签一一对上）。
  - 两套 `audiobook_pos_` 正确汇聚到 `audiobook_pos_<bookKey>`，冲突取 uid 风格。
  - media_items identifier 重写成 `hoshi://book/<bookKey>`。
  - 重名 title 去重：seed 两本 sanitize 后撞名的书 → 第二本得 ` (2)` 后缀键，数据不串。
  - 外键完整性：删一本书 cascade 仍清干净。
- **去重纯函数**：复用/扩展 `book_title_conflict_test.dart`。
- **回归**：全量 `flutter test` + reader/audiobook/profile/sync 集成测试（这是行为变更最大的一组，必须真机或离屏跑过）。
- **源码守卫**：扫描无残留 `buildLegacyBookUid`、无 `int.*bookId` 旧签名、无 `hoshi://book/<int>` 生成。

## 7. 向后兼容与风险

- **存量本地数据**：靠 §4 迁移无损保留。**迁移出错 = 用户阅读进度丢失**——这是最大风险点，故迁移测试是硬门槛，且降级分支（`database.dart:64-89`）已有 `.bak` 自动备份兜底。
- **磁盘/DB 不一致窗口**：§4.7 目录迁移在事务外，若中途崩溃可能 DB 已改键但部分目录没 rename。缓解：优先选"reader 读 extract_dir 列、不 rename 目录"方案，消除该窗口。
- **代码扫荡遗漏**：58 处任一漏改 → 运行时类型错或找不到书。靠编译期类型检查（int→String 改签名后漏改处编译不过）+ 源码守卫 + 集成回归三重兜底。
- **不可逆**：v16 迁移无 onDowngrade 数据保留（降级走 DROP+createAll）。与现状一致。

## 8. 完成定义

- schema v16 迁移 + 全套迁移测试绿。
- 全 app `book.id` 扫荡完，`flutter analyze` 0 错，全量单测绿。
- reader/audiobook/profile/sync 集成测试在真机/离屏复测原始路径绿（开书、读进度恢复、有声书跟随、Profile 切换、同步往返）。
- 源码守卫绿。
- 之后 sub-project 2（同步 hash，简化版）与 3（删位置开关）各自立计划。
