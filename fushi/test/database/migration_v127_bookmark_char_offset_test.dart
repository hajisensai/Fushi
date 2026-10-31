import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

/// v127：`bookmarks.char_offset`（书签页首字符的章内精确偏移）与
/// `bookmarks.chapter_key`（在线漫画书签所在章的稳定键）。
///
/// 迁移只加两列、不动数据：存量书签 char_offset 落 -1（跳转回退 norm_char_offset
/// 分数），chapter_key 落 NULL；重跑幂等。
void main() {
  Set<String> columnsOf(sqlite.Database raw, String table) => <String>{
    for (final sqlite.Row row in raw.select("PRAGMA table_info('$table')"))
      row['name'] as String,
  };

  test(
    'v126 → v127 给 bookmarks 加 char_offset / chapter_key；存量行 -1 / NULL；重跑幂等',
    () async {
      final Directory directory = Directory.systemTemp.createTempSync(
        'bookmark_char_offset_v127',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final String path = '${directory.path}/test.db';
      final FushiDatabase db = FushiDatabase.atFile(path, isMainProcess: false);
      await db.getAllTags(); // 触发建库
      await db.close();

      final sqlite.Database raw = sqlite.sqlite3.open(path);
      raw.execute('ALTER TABLE bookmarks DROP COLUMN char_offset');
      raw.execute('ALTER TABLE bookmarks DROP COLUMN chapter_key');
      expect(columnsOf(raw, 'bookmarks'), isNot(contains('char_offset')));
      expect(columnsOf(raw, 'bookmarks'), isNot(contains('chapter_key')));
      raw.execute(
        'INSERT INTO bookmarks '
        '(book_uid, section_index, norm_char_offset, label, created_at) '
        "VALUES ('book_1', 3, 4200, 'Ch. 4', 1000)",
      );
      raw.execute('PRAGMA user_version = 126');
      raw.dispose();

      final FushiDatabase migrated = FushiDatabase.atFile(
        path,
        isMainProcess: false,
      );
      expect(migrated.schemaVersion, 141);
      final List<Bookmark> legacy = await BookmarkRepository(
        migrated,
      ).getBookmarks('book_1');
      expect(legacy, hasLength(1));
      expect(
        legacy.single.charOffset,
        -1,
        reason: '存量书签没有精确偏移：跳转回退 norm_char_offset 分数',
      );
      expect(legacy.single.chapterKey, isNull);
      expect(legacy.single.normCharOffset, 4200);
      await migrated.close();

      final sqlite.Database probe = sqlite.sqlite3.open(path);
      expect(probe.select('PRAGMA user_version').first.values.first, 141);
      expect(columnsOf(probe, 'bookmarks'), contains('char_offset'));
      expect(columnsOf(probe, 'bookmarks'), contains('chapter_key'));
      // 重跑 v127 步：列已在，不得报错、不得清数据。
      probe.execute(
        "UPDATE bookmarks SET char_offset = 512, chapter_key = 'ch-9' "
        "WHERE book_uid = 'book_1'",
      );
      probe.execute('PRAGMA user_version = 126');
      probe.dispose();

      final FushiDatabase reopened = FushiDatabase.atFile(
        path,
        isMainProcess: false,
      );
      final List<Bookmark> kept = await BookmarkRepository(
        reopened,
      ).getBookmarks('book_1');
      expect(kept.single.charOffset, 512);
      expect(kept.single.chapterKey, 'ch-9');
      await reopened.close();
    },
  );

  test('BookmarkRepository 读写 charOffset / chapterKey 往返', () async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final BookmarkRepository repo = BookmarkRepository(db);
    await repo.addBookmark(
      'book_2',
      Bookmark(
        sectionIndex: 1,
        normCharOffset: 0,
        label: 'Page 5',
        createdAt: DateTime.fromMillisecondsSinceEpoch(2000),
        charOffset: 1234,
        chapterKey: 'https://example/ch/1',
      ),
    );
    await repo.addBookmark(
      'book_2',
      Bookmark(
        sectionIndex: 4,
        normCharOffset: 0,
        label: 'Page 5',
        createdAt: DateTime.fromMillisecondsSinceEpoch(3000),
      ),
    );
    final List<Bookmark> rows = await repo.getBookmarks('book_2');
    expect(rows.map((Bookmark b) => b.sectionIndex), <int>[
      4,
      1,
    ], reason: 'createdAt 倒序');
    expect(rows.last.charOffset, 1234);
    expect(rows.last.chapterKey, 'https://example/ch/1');
    expect(rows.first.charOffset, -1, reason: '没给精确偏移时默认 -1');
    expect(rows.first.chapterKey, isNull);
  });
}
