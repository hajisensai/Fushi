import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/backup_service.dart';
import 'package:fushi/src/sync/sync_settings_schema.dart'
    show
        BackupImportMode,
        BackupImportPreset,
        backupImportPresetCategories,
        backupImportSelectableCategories;
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

import 'temp_dir_cleanup.dart';

/// 整库备份（定时还原点，用户 2026-11-25「整库 + 挑文件」）：
/// - 导出不按类别剥行（书 / 视频行、进度、统计、设置都在），类别只挑文件树；
/// - 手动导出（不开 fullDatabase）行为不变；
/// - 覆盖恢复（还原点页「替换」）由 meta 标记驱动：整库换回，没带文件的类别保留行、本机文件树
///   原样不动，同一台设备上路径改基是空操作。
void main() {
  late Directory root;
  late String dbDir;
  late String booksRoot;
  late String videosDir;
  late FushiDatabase db;

  Future<int> count(FushiDatabase d, String table) async =>
      (await d.customSelect('SELECT COUNT(*) AS c FROM $table').getSingle())
          .read<int>('c');

  Future<Set<String>> statTitles(FushiDatabase d) async => <String>{
    for (final row
        in await d.customSelect('SELECT title FROM reading_statistics').get())
      row.read<String>('title'),
  };

  Future<void> addStat(String title) => db.customStatement(
    'INSERT INTO reading_statistics (title, date_key, characters_read, '
    'reading_time_ms, last_statistic_modified) '
    "VALUES (?, '2026-11-01', 100, 1000, 1)",
    <Object?>[title],
  );

  BackupService service() => BackupService(
    db: db,
    dbDirectory: dbDir,
    appVersion: '9.9.9',
    booksRootDirectory: booksRoot,
  );

  Future<Archive> readZip(String zipPath) async =>
      ZipDecoder().decodeBytes(await File(zipPath).readAsBytes());

  Future<FushiDatabase> openZipDb(String zipPath, String name) async {
    final ArchiveFile entry = (await readZip(zipPath)).findFile('fushi.db')!;
    final Directory dir = Directory(p.join(root.path, name))
      ..createSync(recursive: true);
    File(
      p.join(dir.path, 'fushi.db'),
    ).writeAsBytesSync(entry.content as List<int>);
    return FushiDatabase(dir.path);
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('fushi_full_db_backup_');
    dbDir = p.join(root.path, 'db');
    booksRoot = p.join(root.path, 'fushi_books');
    videosDir = p.join(root.path, 'my_videos');
    Directory(dbDir).createSync(recursive: true);
    File(p.join(booksRoot, 'Bk', 'original.epub'))
      ..createSync(recursive: true)
      ..writeAsStringSync('EPUB-v1');
    File(p.join(videosDir, 'Film.mp4'))
      ..createSync(recursive: true)
      ..writeAsStringSync('MP4');
    db = FushiDatabase(dbDir);
    await db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: 'Bk',
        title: 'Bk',
        epubPath: p.join(booksRoot, 'Bk', 'original.epub'),
        extractDir: p.join(booksRoot, 'Bk'),
        chapterCount: 1,
        chaptersJson: '["c"]',
        importedAt: 0,
      ),
    );
    final String bkUid = (await db.resolveEpubBookUid('Bk'))!;
    await db.upsertReaderPosition(
      ReaderPositionsCompanion.insert(
        bookUid: bkUid,
        sectionIndex: 0,
        normCharOffset: 100,
        updatedAt: 1,
      ),
    );
    await db.upsertVideoBook(
      VideoBooksCompanion.insert(
        bookUid: 'video/film',
        title: 'Film',
        videoPath: p.join(videosDir, 'Film.mp4'),
        playlistJson: Value(jsonEncode(<Object?>[])),
      ),
    );
    await addStat('kept-before-backup');
  });

  tearDown(() async {
    await db.close();
    await cleanupTempDir(root);
  });

  test('整库导出：只挑字体时书 / 视频行、进度、统计照样在库里，书文件不进包', () async {
    final String zip = p.join(root.path, 'full.zip');
    final BackupMeta meta = await service().createBackup(
      zip,
      categories: <BackupCategory>{BackupCategory.fonts},
      fullDatabase: true,
      compress: true,
      includeSrsMedia: false,
    );
    expect(meta.fullDatabase, isTrue);
    expect(meta.toJson()['fullDatabase'], isTrue);
    // 只列没带文件的文件类别；数据类别都在。
    expect(
      meta.excludedCategories,
      containsAll(<String>['books', 'videos', 'audiobooks', 'games']),
    );
    expect(
      meta.excludedCategories,
      isNot(anyOf(contains('progress'), contains('statistics'))),
    );
    expect(meta.excludedCategories, isNot(contains('settings')));
    expect(meta.excludedCategories, isNot(contains('fonts')));
    final Archive archive = await readZip(zip);
    expect(
      archive.files.where(
        (ArchiveFile f) =>
            f.name.startsWith('fushi_books/') || f.name.startsWith('videos/'),
      ),
      isEmpty,
    );
    final FushiDatabase copy = await openZipDb(zip, 'full_copy');
    try {
      expect(await count(copy, 'epub_books'), 1);
      expect(await count(copy, 'video_books'), 1);
      expect(await count(copy, 'reader_positions'), 1);
      expect(await statTitles(copy), <String>{'kept-before-backup'});
    } finally {
      await copy.close();
    }
  });

  test('手动导出（不开 fullDatabase）行为不变：没勾的内容类别照旧剥行，meta 不带整库标记', () async {
    final String zip = p.join(root.path, 'manual.zip');
    final BackupMeta meta = await service().createBackup(
      zip,
      categories: <BackupCategory>{
        BackupCategory.fonts,
        BackupCategory.settings,
        BackupCategory.profiles,
        BackupCategory.statistics,
      },
    );
    expect(meta.fullDatabase, isFalse);
    final Archive archive = await readZip(zip);
    final Map<String, Object?> rawMeta =
        jsonDecode(
              utf8.decode(
                archive.findFile('backup_meta.json')!.content as List<int>,
              ),
            )
            as Map<String, Object?>;
    expect(rawMeta.containsKey('fullDatabase'), isFalse);
    expect(
      meta.excludedCategories,
      containsAll(<String>['books', 'videos', 'progress']),
    );
    // 手动导出的库条目仍是 STORE（只有定时还原点压缩）。
    expect(archive.findFile('fushi.db')!.compressionType, ArchiveFile.STORE);
    final FushiDatabase copy = await openZipDb(zip, 'manual_copy');
    try {
      expect(await count(copy, 'epub_books'), 0);
      expect(await count(copy, 'video_books'), 0);
      expect(await count(copy, 'reader_positions'), 0);
      expect(await statTitles(copy), <String>{'kept-before-backup'});
    } finally {
      await copy.close();
    }
  });

  test('从默认整库定时点「替换」：书 / 视频行留着，书文件树原样不动，路径改基是空操作', () async {
    final String zip = p.join(root.path, 'point.zip');
    await service().createBackup(
      zip,
      categories: <BackupCategory>{BackupCategory.fonts},
      fullDatabase: true,
      compress: true,
      includeSrsMedia: false,
    );
    // 备份之后：统计改了、书文件改了、多了一本书的文件。
    await db.customStatement(
      'DELETE FROM reading_statistics WHERE title = ?',
      <Object?>['kept-before-backup'],
    );
    await addStat('added-after-backup');
    File(p.join(booksRoot, 'Bk', 'original.epub')).writeAsStringSync('EPUB-v2');
    File(p.join(booksRoot, 'New', 'new.epub'))
      ..createSync(recursive: true)
      ..writeAsStringSync('NEW');
    await db.close();

    // 与还原点页「替换」同一套分类折算（预设：覆盖 + 导入设置，分类缺省）。
    final BackupMeta meta = (await BackupRestoreService.validateBackup(zip))!;
    final BackupContentSummary summary =
        await BackupRestoreService.summarizeBackupFile(zip);
    final Set<BackupCategory> categories = backupImportPresetCategories(
      const BackupImportPreset(
        mode: BackupImportMode.overwrite,
        importSettings: true,
      ),
      summary,
      fullDatabase: meta.fullDatabase,
    );
    // 包里没带书文件 → 书类别没被选上；整库标记保证行照样不剥。
    expect(categories, isNot(contains(BackupCategory.books)));
    expect(
      categories,
      containsAll(<BackupCategory>{
        BackupCategory.progress,
        BackupCategory.statistics,
        BackupCategory.srs,
        BackupCategory.music,
      }),
    );
    await BackupRestoreService.restoreBackup(
      dbDirectory: dbDir,
      zipPath: zip,
      categories: categories,
      booksRootDirectory: booksRoot,
      videosRootDirectory: p.join(root.path, 'videos'),
    );
    db = FushiDatabase(dbDir);

    final EpubBookRow book = (await db.getEpubBook('Bk'))!;
    expect(book.epubPath, p.join(booksRoot, 'Bk', 'original.epub'));
    expect(await count(db, 'video_books'), 1);
    final String video =
        (await db
                .customSelect('SELECT video_path FROM video_books')
                .getSingle())
            .read<String>('video_path');
    expect(video, p.join(videosDir, 'Film.mp4'));
    expect(await count(db, 'reader_positions'), 1);
    expect(await statTitles(db), <String>{'kept-before-backup'});
    // 书文件树一个字节都没动。
    expect(
      File(p.join(booksRoot, 'Bk', 'original.epub')).readAsStringSync(),
      'EPUB-v2',
    );
    expect(File(p.join(booksRoot, 'New', 'new.epub')).existsSync(), isTrue);
    expect(File(p.join(videosDir, 'Film.mp4')).existsSync(), isTrue);
  });

  test('整库备份覆盖导入时只有文件类别可挑；手动导出的包不变', () {
    expect(
      backupImportSelectableCategories(
        BackupImportMode.overwrite,
        fullDatabase: true,
      ),
      everyElement(isIn(kBackupFileCategories)),
    );
    expect(
      backupImportSelectableCategories(BackupImportMode.overwrite),
      contains(BackupCategory.progress),
    );
    expect(
      backupImportSelectableCategories(
        BackupImportMode.merge,
        fullDatabase: true,
      ),
      contains(BackupCategory.progress),
    );
  });
}
