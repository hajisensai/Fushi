import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

/// v118：epub_books / srt_books / video_books 各加 `local_added_at`（本机开始拥有
/// 该条目的时刻），从 `imported_at`（原始入库时刻）里拆出来。
///
/// 存量行回填 = imported_at（两者在存量里本就同义）；视频 imported_at 为 NULL 的
/// 旧行保持 NULL（时刻未知）。重跑幂等：已有值的行不被回填覆盖。
void main() {
  const List<String> tables = <String>[
    'epub_books',
    'srt_books',
    'video_books',
  ];

  Set<String> columnsOf(sqlite.Database raw, String table) => <String>{
    for (final sqlite.Row row in raw.select("PRAGMA table_info('$table')"))
      row['name'] as String,
  };

  /// 建当前 schema 的库并写入三类存量行，再退回 v117 形态（三张表去掉新列）。
  Future<String> createV117Db(Directory directory) async {
    final String path = '${directory.path}/test.db';
    final FushiDatabase db = FushiDatabase.atFile(path, isMainProcess: false);
    await db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: 'Book',
        title: 'Book',
        epubPath: 'b.epub',
        extractDir: '/abs/b',
        chapterCount: 1,
        chaptersJson: '[]',
        importedAt: 1111,
      ),
    );
    await db.upsertSrtBook(
      SrtBooksCompanion.insert(
        uid: 'srt-1',
        title: 'Srt',
        srtPath: '/abs/s.srt',
        importedAt: 2222,
      ),
    );
    await db.upsertVideoBook(
      const VideoBooksCompanion(
        bookUid: Value<String>('vid-1'),
        title: Value<String>('Vid'),
        videoPath: Value<String>('/abs/v.mp4'),
        importedAt: Value<int?>(3333),
      ),
    );
    await db.upsertVideoBook(
      const VideoBooksCompanion(
        bookUid: Value<String>('vid-legacy'),
        title: Value<String>('Legacy'),
        videoPath: Value<String>('/abs/l.mp4'),
        importedAt: Value<int?>(null),
      ),
    );
    await db.close();

    final sqlite.Database raw = sqlite.sqlite3.open(path);
    for (final String t in tables) {
      raw.execute('ALTER TABLE $t DROP COLUMN local_added_at');
      expect(columnsOf(raw, t), isNot(contains('local_added_at')));
    }
    raw.execute('PRAGMA user_version = 117');
    raw.dispose();
    return path;
  }

  test('v117 → v118 加列并以 imported_at 回填；NULL 导入时刻保持 NULL；重跑不覆盖已有值', () async {
    final Directory directory = Directory.systemTemp.createTempSync(
      'local_added_at_v118',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final String path = await createV117Db(directory);

    final FushiDatabase migrated = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    expect(migrated.schemaVersion, 138);
    await migrated.customSelect('SELECT 1').get();
    await migrated.close();

    final sqlite.Database probe = sqlite.sqlite3.open(path);
    expect(probe.select('PRAGMA user_version').first.values.first, 138);
    for (final String t in tables) {
      expect(columnsOf(probe, t), contains('local_added_at'), reason: t);
    }
    int? localAddedAt(String sql) =>
        probe.select(sql).first.values.first as int?;
    expect(localAddedAt('SELECT local_added_at FROM epub_books'), 1111);
    expect(localAddedAt('SELECT local_added_at FROM srt_books'), 2222);
    expect(
      localAddedAt(
        "SELECT local_added_at FROM video_books WHERE book_uid = 'vid-1'",
      ),
      3333,
    );
    expect(
      localAddedAt(
        'SELECT local_added_at FROM video_books '
        "WHERE book_uid = 'vid-legacy'",
      ),
      isNull,
      reason: '导入时刻本就未知的旧视频不编造拥有时刻',
    );

    // 重跑 v118 步：列已在、值已有，回填只碰 NULL 行——改过的值必须原样保留。
    probe.execute('UPDATE epub_books SET local_added_at = 9999');
    probe.execute('PRAGMA user_version = 117');
    probe.dispose();

    final FushiDatabase reopened = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    await reopened.customSelect('SELECT 1').get();
    await reopened.close();

    final sqlite.Database probe2 = sqlite.sqlite3.open(path);
    addTearDown(probe2.dispose);
    expect(probe2.select('PRAGMA user_version').first.values.first, 138);
    expect(
      probe2.select('SELECT local_added_at FROM epub_books').first.values.first,
      9999,
    );
  });
}
