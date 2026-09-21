import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

/// v112：新建 `manga_reader_overrides`（每作品稀疏覆盖 + LWW 墓碑），并把存量
/// `epub_books.manga_reading_mode` 搬成覆盖。
///
/// 这一版的关键语义是**稀疏**：只有真正被单独设过阅读模式的书才写行。
/// `manga_reading_mode` 为 NULL = 「跟随全局」，给它写一行 `{'autoMode': true}`
/// 会把每本存量漫画都钉成自动判定——此后用户改全局阅读模式对全部存量书永久
/// 不再生效，而且每本书都会因此多一次 sidecar 资产上传与一条互联 wire 条目。
void main() {
  test('v111 → v112：建表 + 只搬「设过模式」的书，NULL 保持跟随全局', () async {
    final Directory directory = Directory.systemTemp.createTempSync(
      'mangaprefs112',
    );
    addTearDown(() {
      // Windows 上 sqlite 句柄释放晚于 tearDown，删不掉不该让用例红。
      try {
        directory.deleteSync(recursive: true);
      } on FileSystemException {
        // 临时目录留给系统回收。
      }
    });
    final String path = '${directory.path}/test.db';
    final FushiDatabase original = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    expect(await original.getCollectionBookAliases(), isEmpty);
    await original.close();

    final sqlite.Database raw = sqlite.sqlite3.open(path);
    raw.execute('DROP TABLE manga_reader_overrides');
    void insertBook(String key, String uid, String format, String? mode) {
      raw.execute(
        'INSERT INTO epub_books (book_key, uid, title, format, '
        'manga_reading_mode, epub_path, extract_dir, chapter_count, '
        'chapters_json, imported_at) '
        "VALUES (?, ?, ?, ?, ?, '/tmp/x', '/tmp/x', 1, '[]', 1)",
        <Object?>[key, uid, key, format, mode],
      );
    }

    insertBook('spread-book', 'uid-spread', 'manga', 'spread');
    insertBook('webtoon-book', 'uid-webtoon', 'manga', 'webtoon');
    insertBook('untouched-book', 'uid-untouched', 'manga', null);
    insertBook('epub-book', 'uid-epub', 'epub', 'spread');
    raw.execute('PRAGMA user_version = 111');
    raw.dispose();

    final FushiDatabase migrated = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    addTearDown(migrated.close);
    expect(migrated.schemaVersion, 112);

    Future<Map<String, Object?>?> overridesOf(String uid) async {
      final MangaReaderOverrideRow? row = await migrated.getMangaReaderOverride(
        uid,
      );
      if (row == null || row.deleted) return null;
      return (jsonDecode(row.overridesJson) as Map<String, Object?>);
    }

    expect(await overridesOf('uid-spread'), <String, Object?>{
      'autoMode': false,
      'mode': 'spread',
    });
    expect(await overridesOf('uid-webtoon'), <String, Object?>{
      'autoMode': false,
      'mode': 'webtoon',
    });
    expect(
      await migrated.getMangaReaderOverride('uid-untouched'),
      isNull,
      reason: 'NULL = 跟随全局：写一行会把这本书永久钉成自动判定',
    );
    expect(
      await migrated.getMangaReaderOverride('uid-epub'),
      isNull,
      reason: '只搬 format=manga 的书',
    );
  });

  test('patchMangaReaderOverride 只改给定键，其余覆盖原样保留', () async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final String bookKey = await db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: 'patch-book',
        title: 'Patch book',
        epubPath: '/tmp/patch-book',
        extractDir: '/tmp/patch-book',
        chapterCount: 1,
        chaptersJson: '[]',
        importedAt: 1,
        format: Value<String>(BookFormat.manga.dbValue),
      ),
    );
    final String uid = (await db.getEpubBook(bookKey))!.uid;
    await db.setMangaReaderOverride(uid, <String, Object?>{
      'mode': 'spread',
      'autoMode': false,
      'scaleType': 'fitWidth',
      'cropBorders': true,
    });

    // 顶栏切换只改模式：整行替换会把 scaleType / cropBorders 一并抹掉，并把这份
    // 残缺快照经 LWW 同步给对端。
    await db.patchMangaReaderOverride(uid, <String, Object?>{
      'mode': 'webtoon',
      'autoMode': false,
    });

    final MangaReaderOverrideRow row = (await db.getMangaReaderOverride(uid))!;
    expect(jsonDecode(row.overridesJson), <String, Object?>{
      'mode': 'webtoon',
      'autoMode': false,
      'scaleType': 'fitWidth',
      'cropBorders': true,
    });
  });
}
