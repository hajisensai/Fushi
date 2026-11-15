import 'dart:io';

import 'package:drift/drift.dart' show Value, Variable;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/backup_service.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

import 'temp_dir_cleanup.dart';

/// BUG-4695：覆盖导入成功后保留覆盖前快照；「从快照恢复书库」只补缺合并书库行、
/// 进度、统计，不改当前库已有的行。
void main() {
  late Directory curDir;
  late Directory srcDir;
  late Directory zipDir;
  late String bookDirA;

  setUp(() async {
    curDir = await Directory.systemTemp.createTemp('fushi_ows_cur_');
    srcDir = await Directory.systemTemp.createTemp('fushi_ows_src_');
    zipDir = await Directory.systemTemp.createTemp('fushi_ows_zip_');
    bookDirA = p.join(curDir.path, 'books', 'A');
    Directory(bookDirA).createSync(recursive: true);
  });

  tearDown(() async {
    await cleanupTempDir(curDir);
    await cleanupTempDir(srcDir);
    await cleanupTempDir(zipDir);
  });

  Future<String> insertBook(
    FushiDatabase db,
    String key, {
    required String extractDir,
  }) async {
    await db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: key,
        title: key,
        epubPath: '$key.epub',
        extractDir: extractDir,
        chapterCount: 3,
        chaptersJson: '[]',
        importedAt: 1,
      ),
    );
    return (await db.getEpubBook(key))!.uid;
  }

  Future<void> position(
    FushiDatabase db,
    String uid, {
    required int section,
    required int updatedAt,
  }) => db.upsertReaderPosition(
    ReaderPositionsCompanion.insert(
      bookUid: uid,
      sectionIndex: section,
      normCharOffset: 0,
      updatedAt: updatedAt,
      charOffset: const Value<int>(-1),
    ),
  );

  Future<void> stat(FushiDatabase db, String title, int chars) =>
      db.customStatement(
        'INSERT INTO reading_statistics (title, date_key, characters_read, '
        'reading_time_ms, last_statistic_modified) '
        "VALUES (?, '2026-11-01', ?, 1000, 1)",
        <Object?>[title, chars],
      );

  Future<int?> statChars(FushiDatabase db, String title) async {
    final rows = await db
        .customSelect(
          'SELECT characters_read FROM reading_statistics WHERE title = ?',
          variables: <Variable<Object>>[Variable<String>(title)],
        )
        .get();
    return rows.isEmpty ? null : rows.single.read<int>('characters_read');
  }

  test('overwrite import retains the pre-overwrite snapshot; snapshot restore '
      'only fills what is missing', () async {
    // 本机：书 A（文件在盘上）、书 B、书 C（文件已不在盘上），各有进度与统计。
    final FushiDatabase cur = FushiDatabase(curDir.path);
    final String uidA = await insertBook(cur, 'A', extractDir: bookDirA);
    final String uidB = await insertBook(
      cur,
      'B',
      extractDir: p.join(curDir.path, 'books', 'B'),
    );
    await insertBook(cur, 'C', extractDir: p.join(curDir.path, 'gone', 'C'));
    await position(cur, uidA, section: 2, updatedAt: 500);
    await position(cur, uidB, section: 9, updatedAt: 900);
    await stat(cur, 'A', 1234);
    await stat(cur, 'B', 999);
    await cur.close();

    // 推荐包一类的「别人的库」：只有书 B（进度更旧、统计更少）。
    final FushiDatabase src = FushiDatabase(srcDir.path);
    final String srcUidB = await insertBook(
      src,
      'B',
      extractDir: p.join(srcDir.path, 'books', 'B'),
    );
    await position(src, srcUidB, section: 1, updatedAt: 100);
    await stat(src, 'B', 10);
    final String zipPath = p.join(zipDir.path, 'pack.zip');
    await BackupService(
      db: src,
      dbDirectory: srcDir.path,
      appVersion: '1.0.0',
    ).createBackup(zipPath);
    await src.close();

    await BackupRestoreService.restoreBackup(
      dbDirectory: curDir.path,
      zipPath: zipPath,
    );

    // 覆盖成功：恢复进行中的 bak 不留，覆盖前快照以新名保留，存储页可删。
    final String snapshotPath = BackupRestoreService.overwriteSnapshotPath(
      curDir.path,
    );
    expect(File(snapshotPath).existsSync(), isTrue);
    expect(
      File(p.join(curDir.path, 'fushi.db.pre-restore.bak')).existsSync(),
      isFalse,
    );
    expect(
      isDeletableDatabaseSnapshot(p.basename(snapshotPath), <String>{
        p.basename(snapshotPath),
        'fushi.db.sync-preserve.json',
      }),
      isTrue,
    );

    // 预览：A、C 缺失；C 的书文件不在盘上。
    final FushiDatabase live = FushiDatabase(curDir.path);
    expect((await live.getEpubBookMetas()).map((b) => b.bookKey), <String>[
      'B',
    ]);
    final OverwriteSnapshotPreview preview =
        (await BackupRestoreService.previewOverwriteSnapshot(
          dbDirectory: curDir.path,
          liveDb: live,
        ))!;
    expect(preview.missingBooks.map((b) => b.bookKey).toSet(), <String>{
      'A',
      'C',
    });
    expect(preview.booksWithoutFiles.map((b) => b.bookKey), <String>['C']);
    expect(preview.sizeBytes, greaterThan(0));
    await live.close();

    await BackupRestoreService.mergeFromOverwriteSnapshot(
      dbDirectory: curDir.path,
    );

    final FushiDatabase after = FushiDatabase(curDir.path);
    addTearDown(after.close);
    // 缺的补回来：bookKey 不变，进度与统计随之回来。
    final EpubBookRow a = (await after.getEpubBook('A'))!;
    expect(a.extractDir, bookDirA);
    expect((await after.getReaderPosition(a.uid))?.sectionIndex, 2);
    expect(await statChars(after, 'A'), 1234);
    expect(await after.getEpubBook('C'), isNotNull);
    // 已有的不动：B 的进度（快照里更新）与统计（快照里更大）都保持当前库的值。
    final EpubBookRow b = (await after.getEpubBook('B'))!;
    expect((await after.getReaderPosition(b.uid))?.sectionIndex, 1);
    expect(await statChars(after, 'B'), 10);
    // 快照保留（可再次恢复 / 在存储页删除），合并临时文件已清。
    expect(File(snapshotPath).existsSync(), isTrue);
    expect(File(p.join(curDir.path, 'fushi.db.merge-src')).existsSync(), false);
    expect(
      File(p.join(curDir.path, 'fushi.db.merge-preserve.json')).existsSync(),
      isFalse,
    );
  });

  test('a later overwrite import replaces the retained snapshot', () async {
    final FushiDatabase cur = FushiDatabase(curDir.path);
    await insertBook(cur, 'A', extractDir: bookDirA);
    await cur.close();
    final FushiDatabase src = FushiDatabase(srcDir.path);
    final String zipPath = p.join(zipDir.path, 'empty.zip');
    await BackupService(
      db: src,
      dbDirectory: srcDir.path,
      appVersion: '1.0.0',
    ).createBackup(zipPath);
    await src.close();

    await BackupRestoreService.restoreBackup(
      dbDirectory: curDir.path,
      zipPath: zipPath,
    );
    await BackupRestoreService.restoreBackup(
      dbDirectory: curDir.path,
      zipPath: zipPath,
    );

    // 只留最近一份：第二次覆盖前的库（已是空库）。
    final FushiDatabase live = FushiDatabase(curDir.path);
    addTearDown(live.close);
    final OverwriteSnapshotPreview preview =
        (await BackupRestoreService.previewOverwriteSnapshot(
          dbDirectory: curDir.path,
          liveDb: live,
        ))!;
    expect(preview.missingBooks, isEmpty);
    expect(
      Directory(curDir.path)
          .listSync()
          .map((FileSystemEntity e) => p.basename(e.path))
          .where((String n) => n.contains('pre-overwrite')),
      <String>['fushi.db.pre-overwrite.bak'],
    );
  });
}
