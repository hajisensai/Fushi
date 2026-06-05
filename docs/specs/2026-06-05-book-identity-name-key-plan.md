# 书身份重构（名字当主键）实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: 用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans 逐任务实现。步骤用 `- [ ]` 复选框跟踪。**所有派生子代理（含 review）必须 `model: "opus"`。**

**Goal:** 把 EpubBooks 主键从自增 `id` 改成 `bookKey = sanitizeTtuFilename(title)`，全 app 阅读数据无损重键，消灭 int↔title 双重身份。

**Architecture:** drift schema v15→v16，Dart 驱动的 `customStatement` 迁移（先把 id→bookKey 映射灌进临时表，再 JOIN 重建各表）。代码扫荡由编译器驱动（改签名 int→String，逐文件修复编译错）。迁移测试照 `migration_downgrade_test.dart` 的 seed-raw-DB 范式打底。

**Tech Stack:** Dart 3.12 / Flutter 3.44 / drift 2.23 / SQLite。测试 `flutter test`（项目工具链）。

**前置铁律：** 本仓库 develop 直提、多 agent 共享工作树——每个 commit 只 `git add` 本任务文件，禁 `git add -A`，提交前 `git diff --cached --check`。

**关键约束（非增量可编译）：** 改 EpubBooks 主键会让 drift 重生成 `database.g.dart`，所有用 `int bookId` 的访问器与 58 处消费点同时编译失败。故 Task 1–10 之间 app 不可编译；以"全部改完后整体编译 + 迁移测试"为验证点。迁移测试可先写（针对目标 schema），编译通过后才能跑。

---

## 文件结构地图

**Schema / 迁移（packages/hibiki_core/）**
- 修改：`lib/src/database/tables.dart` — EpubBooks PK + 6 张关联表列改 TEXT `bookKey`
- 修改：`lib/src/database/database.dart` — `schemaVersion 15→16`、`onUpgrade` 加 `if (from<16)` 分支 + 新迁移函数 `_migrateBookKeyV16`、访问器签名 int→String
- 新建：`test/migration_book_key_test.dart` — seed v15 库断言无损

**身份编解码中枢（hibiki/lib/）**
- 修改：`src/media/sources/reader_hibiki_source.dart` — `mediaIdentifierFor/parseBookKey`，删 `bookUidFor` 的 int 包装
- 删除/改写：`packages/hibiki_core/lib/src/legacy_book_uid.dart` — `buildLegacyBookUid` 退化为恒等或删除

**消费点扫荡（hibiki/lib/ + packages/hibiki_audio/）**
- `src/epub/epub_importer.dart`、`src/epub/epub_storage.dart`
- `src/pages/implementations/reader_hibiki_page.dart`、`reader_hibiki_history_page.dart`
- `src/sync/sync_manager.dart`、`sync_orchestrator.dart`、`sync_compare_dialog.dart`、`sync_auto_trigger.dart`、`sync_repository.dart`
- `packages/hibiki_audio/lib/src/audiobook/*_repository.dart`

**设计决定（spec review 已默认采纳）：**
1. 磁盘目录**不 rename**：reader 一律读 `EpubBookRow.extractDir` 列定位，`EpubStorage.bookDirectory(key)` 仅用于新书。旧 `hoshi_books/<int>/` 目录原样保留，`extract_dir` 列是真相源。
2. bookUid 去掉 URI 包装：`Audiobooks/AudioCues/BookProfiles` 直接用 bookKey 字符串。
3. 列改名 `ttuBookId`/`bookId` → `bookKey`（消除误导）。

---

## Task 1：新 schema 表定义 + 版本号

**Files:**
- Modify: `packages/hibiki_core/lib/src/database/tables.dart`（EpubBooks `:192-206` 等）
- Modify: `packages/hibiki_core/lib/src/database/database.dart:60`

- [ ] **Step 1: 改 EpubBooks 主键为 bookKey**

`tables.dart` 把 EpubBooks 改为：
```dart
@DataClassName('EpubBookRow')
class EpubBooks extends Table {
  TextColumn get bookKey => text()();
  TextColumn get title => text()();
  TextColumn get author => text().nullable()();
  TextColumn get coverPath => text().nullable()();
  TextColumn get epubPath => text()();
  TextColumn get extractDir => text()();
  IntColumn get chapterCount => integer()();
  TextColumn get chaptersJson => text()();
  TextColumn get tocJson => text().nullable()();
  TextColumn get sourceMetadata => text().nullable()();
  IntColumn get importedAt => integer()();

  @override
  Set<Column> get primaryKey => {bookKey};
}
```

- [ ] **Step 2: 关联表列 int→TEXT bookKey**

```dart
// Bookmarks（原 :114-117）
TextColumn get bookKey =>
    text().references(EpubBooks, #bookKey, onDelete: KeyAction.cascade)();
// BookTagMappings（原 :223-224）
TextColumn get bookKey =>
    text().references(EpubBooks, #bookKey, onDelete: KeyAction.cascade)();
// ReaderPositions（原 :105 ttuBookId int unique）
TextColumn get bookKey => text().unique()();
// SrtBooks（原 :98 ttuBookId int default 0）—— standalone 用空串
TextColumn get bookKey => text().withDefault(const Constant(''))();
// Audiobooks（原 :60 bookUid unique）
TextColumn get bookKey => text().unique()();
// AudioCues（原 :76 bookUid）
TextColumn get bookKey => text()();
// BookProfiles（原 :287-288 bookUid PK）
TextColumn get bookKey => text()();
// ... primaryKey => {bookKey}
```

- [ ] **Step 3: 版本号 15→16**

`database.dart:60`：`int get schemaVersion => 16;`

- [ ] **Step 4: 重生成 drift 代码**

Run: `cd packages/hibiki_core && dart run build_runner build --delete-conflicting-outputs`
Expected: `database.g.dart` 重生成，`EpubBookRow.bookKey` 等出现。**此时 app 其它包不可编译——预期，继续。**

- [ ] **Step 5: Commit**

```bash
git add packages/hibiki_core/lib/src/database/tables.dart packages/hibiki_core/lib/src/database/database.dart packages/hibiki_core/lib/src/database/database.g.dart
git commit -m "feat(db): EpubBooks PK -> bookKey, relation tables to TEXT (schema v16 wip)"
```

---

## Task 2：迁移函数 `_migrateBookKeyV16`（Dart 驱动）

**Files:**
- Modify: `packages/hibiki_core/lib/src/database/database.dart`（`onUpgrade` 内 + 新私有方法）

迁移不能纯 SQL（`sanitizeTtuFilename` 是 Dart 函数）。策略：Dart 读 `(id,title)` → 算 key + 去重 → 灌进临时表 `_id_key_map(old_id, book_key)` → 各表 JOIN 重建。

- [ ] **Step 1: onUpgrade 加分支**

`database.dart` 的 `onUpgrade` 阶梯末尾加：
```dart
if (from < 16) {
  await _migrateBookKeyV16(m);
}
```

- [ ] **Step 2: 写迁移函数**

`sanitizeTtuFilename` 在 `package:hibiki/...`？否——它在 `hibiki` app 包，`hibiki_core` 不能反向依赖。**迁移内联一份 sanitize 逻辑**（与 `ttu_filename.dart` 同算法；实现时照抄该函数体到 database.dart 私有 `_sanitizeBookKey`，并在 Task 11 加源码守卫断言两者一致）。先在 database.dart 顶部加：

```dart
/// 与 hibiki/lib/src/sync/ttu_filename.dart 的 sanitizeTtuFilename 同算法。
/// hibiki_core 不能依赖 app 包，故内联；Task 11 源码守卫锁定一致性。
String _sanitizeBookKey(String title) {
  // TODO(impl): 照抄 sanitizeTtuFilename 函数体（替换非法路径字符等）。
  // 实现者必须读 ttu_filename.dart 原文逐字复制，不得凭记忆。
  return title.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
}
```

> 实现者注意：上面的正则是占位近似。**必须**打开 `hibiki/lib/src/sync/ttu_filename.dart` 把真实 `sanitizeTtuFilename` 函数体逐字复制进来，否则迁移算出的 key 与 sync/folder 用的 key 不一致 → 跨设备身份错位。

迁移主体：
```dart
Future<void> _migrateBookKeyV16(Migrator m) async {
  await customStatement('PRAGMA foreign_keys = OFF');
  try {
    // 1. 读 (id, title)，算 key + 去重。
    final List<QueryRow> books =
        await customSelect('SELECT id, title FROM epub_books').get();
    final Map<int, String> idToKey = <int, String>{};
    final Set<String> used = <String>{};
    for (final QueryRow r in books) {
      final int id = r.read<int>('id');
      String key = _sanitizeBookKey(r.read<String>('title'));
      if (used.contains(key)) {
        for (int i = 2;; i++) {
          final String c = '$key ($i)';
          if (!used.contains(c)) { key = c; break; }
        }
      }
      used.add(key);
      idToKey[id] = key;
    }

    // 2. 临时映射表。
    await customStatement(
        'CREATE TABLE _id_key_map (old_id INTEGER PRIMARY KEY, book_key TEXT NOT NULL)');
    for (final MapEntry<int, String> e in idToKey.entries) {
      await customStatement('INSERT INTO _id_key_map (old_id, book_key) VALUES (?, ?)',
          <Object?>[e.key, e.value]);
    }

    // 3. 重建 epub_books。
    await customStatement('''
      CREATE TABLE epub_books_new (
        book_key TEXT NOT NULL PRIMARY KEY, title TEXT NOT NULL, author TEXT,
        cover_path TEXT, epub_path TEXT NOT NULL, extract_dir TEXT NOT NULL,
        chapter_count INTEGER NOT NULL, chapters_json TEXT NOT NULL, toc_json TEXT,
        source_metadata TEXT, imported_at INTEGER NOT NULL)''');
    await customStatement('''
      INSERT INTO epub_books_new
      SELECT m.book_key, b.title, b.author, b.cover_path, b.epub_path, b.extract_dir,
             b.chapter_count, b.chapters_json, b.toc_json, b.source_metadata, b.imported_at
      FROM epub_books b JOIN _id_key_map m ON m.old_id = b.id''');
    await customStatement('DROP TABLE epub_books');
    await customStatement('ALTER TABLE epub_books_new RENAME TO epub_books');

    // 4. int-FK / int-key 表：reader_positions, bookmarks, book_tag_mappings, srt_books。
    //    （各表 CREATE new + INSERT...SELECT JOIN _id_key_map ON m.old_id = old_int_col，
    //     DROP/RENAME。standalone srt（ttu_book_id=0）映射为 book_key=''。）
    //    —— 逐表照 epub_books 范式写，列清单见 tables.dart。
    await _rebuildIntKeyedTable(
        table: 'reader_positions', oldCol: 'ttu_book_id',
        createSql: 'CREATE TABLE reader_positions_new (id INTEGER PRIMARY KEY AUTOINCREMENT, '
            'book_key TEXT NOT NULL UNIQUE, /* 其余列照 tables.dart */ ... )',
        selectCols: 'm.book_key, /* 其余列 */ ...');
    // bookmarks / book_tag_mappings 同理（带 FK 重建）。
    // srt_books：LEFT JOIN（standalone 无映射）→ COALESCE(m.book_key,'')。

    // 5. uid-字符串表：audiobooks, audio_cues, book_profiles。
    //    旧 book_uid = 'reader_ttu/hoshi://book/<oldId>'，抠 int 再 JOIN：
    //    JOIN _id_key_map m ON m.old_id =
    //      CAST(replace(book_uid,'reader_ttu/hoshi://book/','') AS INTEGER)
    //    新列 book_key = m.book_key。

    // 6. media_items identifier 重写（UPDATE）。
    //    旧 'hoshi://book/<oldId>' → 'hoshi://book/<bookKey>'。逐行 Dart 翻译 UPDATE。
    final List<QueryRow> items = await customSelect(
        "SELECT rowid, media_identifier FROM media_items "
        "WHERE media_identifier LIKE 'hoshi://book/%'").get();
    for (final QueryRow it in items) {
      final String mid = it.read<String>('media_identifier');
      final int? oldId = int.tryParse(mid.substring('hoshi://book/'.length));
      final String? key = oldId == null ? null : idToKey[oldId];
      if (key == null) continue;
      await customStatement(
          'UPDATE media_items SET media_identifier = ?, unique_key = ? WHERE rowid = ?',
          <Object?>['hoshi://book/$key', 'hoshi://book/$key', it.read<int>('rowid')]);
    }

    // 7. prefs 重键（reading data 在 preferences 表里）。
    await _migrateBookKeyPrefs(idToKey);

    // 8. reading_statistics 的 title 对齐 sanitize（按 {title,dateKey} upsert 合并）。
    //    逐条读 title → _sanitizeBookKey → 若变化则 UPDATE/合并。

    await customStatement('DROP TABLE _id_key_map');
  } finally {
    await customStatement('PRAGMA foreign_keys = ON');
  }
}
```

> 实现者：`_rebuildIntKeyedTable` 是本任务内的私有 helper，逐表传入 `CREATE TABLE ..._new` 的完整列定义（**照 `tables.dart` 改后的列原文**）和 `INSERT...SELECT` 的列映射；standalone srt 用 `LEFT JOIN ... COALESCE(m.book_key,'')`。uid-字符串表第 5 步同法但 JOIN 条件用 `CAST(replace(...))`。这些 SQL 列清单必须与 Task 1 改后的 `tables.dart` 完全一致——实现时对照逐列写，不得省略。

- [ ] **Step 3: prefs 重键 helper**

```dart
Future<void> _migrateBookKeyPrefs(Map<int, String> idToKey) async {
  // audiobook_pos_ 两套键空间合一：
  //   audiobook_pos_<int>            （SyncRepository）
  //   audiobook_pos_<reader_ttu/hoshi://book/int>（AudiobookRepository，实时回写，优先）
  // 以及 audiobook_follow_/delay_/speed_/volume_/image_pause_/health_overlay_<uid>
  // 和 bookmarks_<...>。
  // 读 preferences 全表 key，按前缀分类、抠 oldId、映射 bookKey、写新 key、删旧 key。
  // 冲突（两路指向同一 audiobook_pos_<bookKey>）取 uid 路的值。
  final List<QueryRow> prefs =
      await customSelect('SELECT key, value FROM preferences').get();
  // ... 见实现细节：对每个前缀做 oldId 解析（int 直取 / uid 抠 int）→ idToKey → 新 key。
  // 用 setPrefRaw/customStatement 写新键、customStatement 删旧键。
}
```

> 实现者：preferences 表实际列名/读写原语以 `database.dart` 现有 `getPrefTyped/setPrefTyped` 底层为准（读其实现确认表名与列名），prefs 迁移用 `customStatement` 直接 UPSERT/DELETE。前缀清单：`audiobook_pos_`、`audiobook_follow_`、`audiobook_delay_`、`audiobook_speed_`、`audiobook_volume_`、`image_pause_`、`health_overlay_`、`bookmarks_`（确认 `bookmark_repository.dart:71` 的 `_key` 实际格式后纳入）。

- [ ] **Step 4: Commit**

```bash
git add packages/hibiki_core/lib/src/database/database.dart
git commit -m "feat(db): v16 book-key migration (id->name, lossless re-key of all reading data)"
```

---

## Task 3：迁移测试（无损断言，最重门槛）

**Files:**
- Create: `packages/hibiki_core/test/migration_book_key_test.dart`

照 `packages/hibiki_core/test/migration_downgrade_test.dart` 的 seed-raw-DB 范式。

- [ ] **Step 1: 写失败测试（seed v15 → 断言无损）**

```dart
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_core/hibiki_core.dart';

void main() {
  test('v15->v16 re-keys all reading data to bookKey losslessly', () async {
    // 1. seed v15 raw schema + 数据（自增 id 的两本书 + 各关联表 + prefs + media_items）。
    final db = HibikiDatabase.forTesting(NativeDatabase.memory(setup: (raw) {
      raw.execute('PRAGMA user_version = 15');
      // CREATE TABLE epub_books(id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT, ...);
      // INSERT 两本：id=1 'Book A'，id=2 'Book A'（sanitize 后撞名 → 去重测试）。
      // reader_positions(ttu_book_id=1, ...), bookmarks(ttu_book_id=1),
      // audiobooks(book_uid='reader_ttu/hoshi://book/1'), audio_cues 同,
      // book_profiles(book_uid='reader_ttu/hoshi://book/2'),
      // media_items(media_identifier='hoshi://book/1'),
      // preferences('audiobook_pos_1'->1000, 'audiobook_pos_reader_ttu/hoshi://book/1'->2000)。
      // （完整 CREATE/INSERT 照 tables.dart v15 列写；实现者补全。）
    }));
    addTearDown(db.close);

    // 2. 打开触发 onUpgrade → v16。
    expect(await db.customSelect('PRAGMA user_version').getSingle()
        .then((r) => r.read<int>('user_version')), 16);

    // 3. 断言无损：
    final books = await db.getAllEpubBooks();
    expect(books.map((b) => b.bookKey), containsAll(<String>['Book A', 'Book A (2)']));
    // 进度按 bookKey 仍在：
    expect((await db.getReaderPosition('Book A')), isNotNull);
    // 有声书按 bookKey：
    expect(await db.getAudiobookByBookKey('Book A'), isNotNull);
    // prefs 两路汇聚 + uid 路优先：
    expect(await db.getPrefTyped<int>('audiobook_pos_Book A', 0), 2000);
    // media_items 重写：
    final mi = await db.customSelect("SELECT media_identifier FROM media_items").get();
    expect(mi.first.read<String>('media_identifier'), 'hoshi://book/Book A');
  });
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd packages/hibiki_core && flutter test test/migration_book_key_test.dart`
Expected: FAIL（迁移未实现完整或访问器 `getReaderPosition(String)` 未改——本测试同时驱动 Task 2 与后续访问器签名）。

- [ ] **Step 3: 补全迁移 + 访问器直到通过**

迭代 Task 2 的 SQL 与 Task 4 的访问器签名，直到本测试绿。

- [ ] **Step 4: 跑通**

Run: `cd packages/hibiki_core && flutter test test/migration_book_key_test.dart`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add packages/hibiki_core/test/migration_book_key_test.dart
git commit -m "test(db): v16 book-key migration losslessness (dedup, uid re-key, prefs merge)"
```

---

## Task 4：DB 访问器签名 int→String

**Files:**
- Modify: `packages/hibiki_core/lib/src/database/database.dart`（§6 清单）

- [ ] **Step 1: 改全部书相关访问器签名**

逐个把签名 int→String、内部查询列改 `bookKey`：
```
getAudiobookByBookUid(String) -> getAudiobookByBookKey(String bookKey)
deleteAudiobookByBookUid     -> deleteAudiobookByBookKey(String bookKey)
getSrtBookByTtuBookId(int)    -> getSrtBookByBookKey(String bookKey)
getReaderPosition(int)        -> getReaderPosition(String bookKey)
deleteReaderPosition(int)     -> deleteReaderPosition(String bookKey)
getEpubBook(int)              -> getEpubBook(String bookKey)
updateEpubBookTitle(int,...)  -> 删除或改 (String bookKey, ...)（标题=主键，改名=换键，见 §下）
updateEpubBookPath(int,...)   -> (String bookKey, String epubPath)
deleteEpubBook(int)           -> deleteEpubBook(String bookKey)  // 内部 cascade 改用 bookKey；删 buildLegacyBookUid
getTagsForBook(int)           -> (String bookKey)
setTagsForBook/addTagToBook/removeTagFromBook(int,...) -> (String bookKey, ...)
getBookProfile/setBookProfile/deleteBookProfile(String bookUid) -> (String bookKey)
insertEpubBook(...) -> Future<String>  // 返回 bookKey
```

> 改标题=改主键的连锁（updateEpubBookTitle）：标题既是显示名又是主键，改名需级联改所有关联 bookKey——本期**禁用书内改名**或单列为后续；实现计划此处先让 `updateEpubBookTitle` 抛 `UnsupportedError`（附注释指向后续任务），避免悄悄破坏。

- [ ] **Step 2: deleteEpubBook 内部 cascade 改 bookKey**

`deleteEpubBook(String bookKey)` 内（原 `:773-795`）：删 reader_positions/bookmarks（FK 自动）/srt_books/audio_cues/audiobooks 全改 `where bookKey == ?`，删除 `buildLegacyBookUid(id)` 调用。

- [ ] **Step 3: 编译 hibiki_core**

Run: `cd packages/hibiki_core && dart run build_runner build --delete-conflicting-outputs && flutter analyze lib`
Expected: hibiki_core 自身 0 错（消费它的 app 仍报错，后续任务修）。

- [ ] **Step 4: Commit**

```bash
git add packages/hibiki_core/lib/src/database/database.dart packages/hibiki_core/lib/src/database/database.g.dart
git commit -m "refactor(db): book accessors int id -> String bookKey"
```

---

## Task 5：编解码中枢 reader_hibiki_source + 删 legacy uid

**Files:**
- Modify: `hibiki/lib/src/media/sources/reader_hibiki_source.dart`
- Modify/Delete: `packages/hibiki_core/lib/src/legacy_book_uid.dart`

- [ ] **Step 1: 改编解码**

```dart
static String mediaIdentifierFor(String bookKey) => 'hoshi://book/$bookKey';
// 删除 bookUidFor（bookUid 概念消失，关联直接用 bookKey）
static String? parseBookKey(String identifier) {
  final Uri? uri = Uri.tryParse(identifier);
  if (uri == null) return null;
  // 'hoshi://book/<key>' → host=='book', pathSegments[0]==key（或按现有解析口径）
  // 兼容旧 'hoshi://book/<int>' 已由迁移重写，无需保留 int 分支。
  return ...; // 照现有 parseBookId 结构改成返回 String key
}
```
删除 `_extractBookId`（int sentinel 0 逻辑），调用处改 `parseBookKey`。

- [ ] **Step 2: 删 buildLegacyBookUid**

`legacy_book_uid.dart`：删除 `buildLegacyBookUid`（全仓库改用 bookKey 后无引用）。若被 export，从 barrel 移除。

- [ ] **Step 3: 本文件其余 9 处 book.id 改 bookKey**

`:233 findByTtuBookId(book.id)`→`(book.bookKey)`、`:247 mediaIdentifierFor(book.bookKey)`、`:301/:316/:323` 删书改 `deleteEpubBook(bookKey)`/`EpubStorage.deleteBook(bookKey)`。

- [ ] **Step 4: Commit**

```bash
git add hibiki/lib/src/media/sources/reader_hibiki_source.dart packages/hibiki_core/lib/src/legacy_book_uid.dart packages/hibiki_core/lib/hibiki_core.dart
git commit -m "refactor(reader): bookKey codec hub, drop legacy bookUid"
```

---

## Task 6：EpubStorage int→String + 读 extract_dir 真相源

**Files:**
- Modify: `hibiki/lib/src/epub/epub_storage.dart`
- Modify: `hibiki/lib/src/epub/epub_importer.dart`

- [ ] **Step 1: EpubStorage 签名 int→String**

`bookDirectory(String bookKey)`/`bookPath`/`deleteBook`/`bookExists` 改用 bookKey（路径 `hoshi_books/<bookKey>/`，sanitize 已路径安全）。**但**消费侧定位现有书一律用 `EpubBookRow.extractDir` 列（旧书目录名仍是 int，列里存的是真路径）；`bookDirectory(key)` 只用于**新导入**。

- [ ] **Step 2: epub_importer 返回 bookKey**

`import/importFromPath` 返回 `Future<String>`：`storedTitle` 即 bookKey（已 sanitize 唯一），插库 `bookKey: storedTitle`，extractDir 用 `bookDirectory(storedTitle)`，删除"rename temp id dir"段（直接解压进 `bookDirectory(storedTitle)`）。`resolveBookTitleConflict` 保留（仍保证 key 唯一）。

- [ ] **Step 3: 编译 + commit**

Run: `cd hibiki && flutter analyze lib/src/epub`
```bash
git add hibiki/lib/src/epub/epub_storage.dart hibiki/lib/src/epub/epub_importer.dart
git commit -m "refactor(epub): storage + importer keyed by bookKey"
```

---

## Task 7：repos 层 int→String（packages/hibiki_audio）

**Files:**
- Modify: `packages/hibiki_audio/lib/src/audiobook/{reader_position,srt_book,audiobook,bookmark,favorite_sentence}_repository.dart`

- [ ] **Step 1: 全部书相关签名 int/bookUid → String bookKey**

`reader_position_repository.findByTtuBookId(int)`→`findByBookKey(String)`；`srt_book_repository`、`audiobook_repository`（删 `buildTtuBookIdMap` 的 int 解析，直接 bookKey）、`bookmark_repository`（`_key` 改 `'bookmarks_<bookKey>'`）、`favorite_sentence_repository`（ttuBookId→bookKey）。

- [ ] **Step 2: 编译 + commit**

Run: `cd packages/hibiki_audio && flutter analyze lib`
```bash
git add packages/hibiki_audio/lib/src/audiobook/
git commit -m "refactor(audio): repositories keyed by bookKey"
```

---

## Task 8：reader_hibiki_page 消费点扫荡

**Files:**
- Modify: `hibiki/lib/src/pages/implementations/reader_hibiki_page.dart`

- [ ] **Step 1: widget.bookId:int → widget.bookKey:String**

构造器 `:92-99` 改 `final String bookKey;`。编译器会列出全部 ~20+ 处 `widget.bookId` 用点；逐个改：
- `:317 bookUidFor(widget.bookId)`→ 直接 `widget.bookKey`
- `:328/:607 getSrtBookByBookKey(widget.bookKey)`、`:324/:607 getAudiobookByBookKey(widget.bookKey)`
- `:363 EpubStorage.bookExists` / `:372 bookDirectory`：改用 `widget.bookKey`（或经传入的 EpubBookRow.extractDir）
- `:422 findByBookKey(widget.bookKey)`
- `:3245/:3334/:4564/:4858/:4884/:5258/:5275 ttuBookId: widget.bookId`→`bookKey: widget.bookKey`
- `:2066/:2094/:4675/:5220 s.ttuBookId == widget.bookId`→`s.bookKey == widget.bookKey`
- 调用方（打开 reader 处）传 `bookKey:` 替代 `bookId:`。

- [ ] **Step 2: 编译 + commit**

Run: `cd hibiki && flutter analyze lib/src/pages/implementations/reader_hibiki_page.dart`
```bash
git add hibiki/lib/src/pages/implementations/reader_hibiki_page.dart
git commit -m "refactor(reader-page): widget.bookId -> bookKey"
```

---

## Task 9：history 页 + 其余消费点

**Files:**
- Modify: `reader_hibiki_history_page.dart`、`book_import_dialog.dart`、`tag_management_page.dart`

- [ ] **Step 1: history 改 bookKey**

`_parseBookId`→`_parseBookKey`（返回 `String?`）；`:157/:376/:1059/:1106/:1181` 调用点；`:734 mediaIdentifierFor(book.bookKey)`；`:757/:942/:1004 bookKey: book.bookKey` 打开 reader；`book.ttuBookId`→`book.bookKey`。

- [ ] **Step 2: 其余文件编译器驱动修复**

`book_import_dialog.dart`（`_applyCoverToEpub` 用 bookKey 目录）、`tag_management_page.dart` 的 book id 用点。

- [ ] **Step 3: 编译 + commit**

Run: `cd hibiki && flutter analyze lib/src/pages`
```bash
git add hibiki/lib/src/pages/implementations/reader_hibiki_history_page.dart hibiki/lib/src/pages/implementations/book_import_dialog.dart hibiki/lib/src/pages/implementations/tag_management_page.dart
git commit -m "refactor(pages): history + import + tags keyed by bookKey"
```

---

## Task 10：sync 层扫荡 + 删 int↔title 翻译

**Files:**
- Modify: `sync_manager.dart`、`sync_orchestrator.dart`、`sync_compare_dialog.dart`、`sync_auto_trigger.dart`、`sync_repository.dart`

- [ ] **Step 1: sync 全用 bookKey**

`sync_manager`（15 处 book.id）、`sync_orchestrator`（7 处，`buildLegacyBookUid(book.id)`→`book.bookKey`、`getSrtBookByBookKey`）、`sync_compare_dialog`（3 处）、`sync_auto_trigger`。`sync_repository.dart:228-235 getAudiobookPosition(int bookId)`→`(String bookKey)`，pref 键 `audiobook_pos_<bookKey>`（与 AudiobookRepository 合一）。`sync_asset_package_service` 的 `ttuBookIdOverride/bookUidOverride` 简化（本地 id 不再异于 title，override 可去）。

- [ ] **Step 2: 编译全仓库**

Run: `cd hibiki && flutter analyze`
Expected: 0 错（全 app 扫荡完成）。

- [ ] **Step 3: Commit**

```bash
git add hibiki/lib/src/sync/
git commit -m "refactor(sync): keyed by bookKey, drop int<->title translation"
```

---

## Task 11：源码守卫 + 全量回归

**Files:**
- Create: `hibiki/test/identity/book_key_guard_test.dart`

- [ ] **Step 1: 源码守卫**

扫描断言：无 `buildLegacyBookUid` 残留、无 `getReaderPosition(<int>`、无 `hoshi://book/$` 后接 int 变量、`database.dart` 的 `_sanitizeBookKey` 与 `ttu_filename.dart` 的 `sanitizeTtuFilename` 函数体一致（字符串比对两文件相关行）。

```dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
void main() {
  test('no legacy bookUid builder remains', () {
    final hits = Directory('lib').listSync(recursive: true)
        .whereType<File>().where((f) => f.path.endsWith('.dart'))
        .where((f) => f.readAsStringSync().contains('buildLegacyBookUid'));
    expect(hits, isEmpty);
  });
  test('_sanitizeBookKey mirrors sanitizeTtuFilename', () {
    // 读两文件相关函数体，规范化空白后断言等价。
  });
}
```

- [ ] **Step 2: 全量单测**

Run: `cd hibiki && flutter test`
Expected: 全绿（迁移测试 + 既有套件；修复任何因签名变更而红的既有测试——它们传 int id 的地方改 bookKey）。

- [ ] **Step 3: build_runner + analyze 全绿**

Run: `cd hibiki && flutter analyze && cd ../packages/hibiki_core && flutter analyze`
Expected: 0 issue。

- [ ] **Step 4: Commit**

```bash
git add hibiki/test/identity/book_key_guard_test.dart
git commit -m "test(identity): bookKey source guards"
```

---

## Task 12：设备回归（真机/离屏，硬门槛）

**Files:** 无（验证）

- [ ] **Step 1: 集成测试跑原始路径**

按 [docs/agent/integration-testing.md] 在真机/离屏跑：开书→阅读进度恢复、书签、有声书跟随、Profile 切换、标签、同步往返（导出→另一设备导入）。**重点验证迁移**：用一个 v15 时代的真实库（或 seed）升级后开书，进度/有声书/Profile 全在。

- [ ] **Step 2: 留证据**

截图/DB 查询证明迁移后关联完整，记入 `.codex-test/`。

---

## Self-Review 备忘（写计划者已核对）

- **Spec 覆盖**：§3 身份模型→Task1/5；§4 迁移→Task2/3；§5 代码扫荡→Task4-10；§6 测试→Task3/11/12；§7 风险（迁移出错丢进度）→Task3 硬门槛 + 降级 `.bak` 兜底。
- **已知占位需实现者补全**（非偷懒，是必须读现网代码逐字复制的点，计划已显式标注）：① `_sanitizeBookKey` 必须照抄 `ttu_filename.dart`；② Task2 各表 `CREATE ..._new` 列清单照 Task1 改后的 `tables.dart`；③ prefs 表名/列名照 `getPrefTyped` 底层；④ `parseBookKey` 照现有 `parseBookId` 结构。每处都给了"读哪个文件、改成什么"。
- **类型一致**：`bookKey: String` 贯穿；访问器统一 `String bookKey`；`insertEpubBook -> Future<String>`、`importFromPath -> Future<String>`。
