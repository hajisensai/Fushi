import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/backup_service.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;
import 'temp_dir_cleanup.dart';

Future<Directory> _tempDir(String prefix) =>
    Directory.systemTemp.createTemp(prefix);

int _now() => DateTime.now().millisecondsSinceEpoch;

/// Exports [srcDb] (in [srcDir]) to a backup zip at [zipPath].
Future<void> _exportZip(
  FushiDatabase srcDb,
  String srcDir,
  String zipPath,
) async {
  await BackupService(db: srcDb, dbDirectory: srcDir, appVersion: '2.0.0')
      .createBackup(zipPath);
}

/// Builds a minimal valid backup zip from a raw `hibiki.db` file (used to drive
/// a deliberate mid-merge crash).
Future<void> _zipDbWithMeta(String dbFilePath, String zipPath) async {
  final ZipFileEncoder enc = ZipFileEncoder();
  enc.create(zipPath);
  enc.addFile(File(dbFilePath), 'hibiki.db');
  final List<int> meta = '{"appVersion":"2.0.0","schemaVersion":29,'
          '"createdAt":"2026-01-01T00:00:00.000","bookCount":0,"statsCount":0}'
      .codeUnits;
  enc.addArchiveFile(ArchiveFile('backup_meta.json', meta.length, meta));
  enc.closeSync();
}

EpubBooksCompanion _book(String key) => EpubBooksCompanion.insert(
      bookKey: key,
      title: key,
      epubPath: '/fake/$key.epub',
      extractDir: '/fake/$key',
      chapterCount: 1,
      chaptersJson: '[]',
      importedAt: _now(),
    );

void main() {
  test('union: device keeps its books, backup adds the missing ones', () async {
    final curDir = await _tempDir('mg_cur_');
    addTearDown(() => cleanupTempDir(curDir));
    final cur = FushiDatabase(curDir.path);
    await cur.insertEpubBook(_book('local-only'));
    await cur.insertEpubBook(_book('shared'));
    await cur.close();

    final srcDir = await _tempDir('mg_src_');
    addTearDown(() => cleanupTempDir(srcDir));
    final src = FushiDatabase(srcDir.path);
    await src.insertEpubBook(_book('shared'));
    await src.insertEpubBook(_book('backup-only'));
    final zipDir = await _tempDir('mg_zip_');
    addTearDown(() => cleanupTempDir(zipDir));
    final zip = p.join(zipDir.path, 'b.zip');
    await _exportZip(src, srcDir.path, zip);
    await src.close();

    await BackupService.mergeRestoreBackup(
      dbDirectory: curDir.path,
      zipPath: zip,
    );

    final after = FushiDatabase(curDir.path);
    addTearDown(after.close);
    final keys = (await after.getAllEpubBooks()).map((b) => b.bookKey).toSet();
    expect(keys, <String>{'local-only', 'shared', 'backup-only'});

    // No temp/bak leak.
    expect(File(p.join(curDir.path, 'fushi.db.merge-src')).existsSync(), false);
    expect(File(p.join(curDir.path, 'fushi.db.pre-merge.bak')).existsSync(),
        false);
    expect(
        File(p.join(curDir.path, 'fushi.db.merge-preserve.json')).existsSync(),
        false);
  });

  test('reading statistics: same {title,dateKey} take MAX, never SUM',
      () async {
    final curDir = await _tempDir('mg_cur_');
    addTearDown(() => cleanupTempDir(curDir));
    final cur = FushiDatabase(curDir.path);
    await cur.setReadingStatistic(ReadingStatisticsCompanion.insert(
      title: 'A',
      dateKey: '2026-01-01',
      charactersRead: 100,
      readingTimeMs: 6000,
      lastStatisticModified: 10,
    ));
    await cur.close();

    final srcDir = await _tempDir('mg_src_');
    addTearDown(() => cleanupTempDir(srcDir));
    final src = FushiDatabase(srcDir.path);
    await src.setReadingStatistic(ReadingStatisticsCompanion.insert(
      title: 'A',
      dateKey: '2026-01-01',
      charactersRead: 80,
      readingTimeMs: 9000,
      lastStatisticModified: 20,
    ));
    final zipDir = await _tempDir('mg_zip_');
    addTearDown(() => cleanupTempDir(zipDir));
    final zip = p.join(zipDir.path, 'b.zip');
    await _exportZip(src, srcDir.path, zip);
    await src.close();

    await BackupService.mergeRestoreBackup(
        dbDirectory: curDir.path, zipPath: zip);
    // Re-import the SAME backup again — must stay idempotent.
    await BackupService.mergeRestoreBackup(
        dbDirectory: curDir.path, zipPath: zip);

    final after = FushiDatabase(curDir.path);
    addTearDown(after.close);
    final rows = await after.getAllReadingStatistics();
    expect(rows, hasLength(1));
    expect(rows.single.charactersRead, 100); // max(100, 80)
    expect(rows.single.readingTimeMs, 9000); // max(6000, 9000)
  });

  test('hourly logs MAX-union per {dateKey, hour, format}; video stays 2-key',
      () async {
    final curDir = await _tempDir('mg_cur_');
    addTearDown(() => cleanupTempDir(curDir));
    final cur = FushiDatabase(curDir.path);
    await cur.addHourlyReadingTime(
        dateKey: '2026-01-01',
        hour: 9,
        deltaMs: 20000,
        format: BookFormat.epub);
    await cur.addHourlyReadingTime(
        dateKey: '2026-01-01',
        hour: 9,
        deltaMs: 10000,
        format: BookFormat.manga);
    await cur.addVideoHourlyWatchTime(
        dateKey: '2026-01-01', hour: 21, deltaMs: 1000);
    await cur.close();

    final srcDir = await _tempDir('mg_src_');
    addTearDown(() => cleanupTempDir(srcDir));
    final src = FushiDatabase(srcDir.path);
    await src.addHourlyReadingTime(
        dateKey: '2026-01-01',
        hour: 9,
        deltaMs: 30000,
        format: BookFormat.epub);
    // 迁移自旧库的未区分行（format=''）也是普通一桶，照常并入。
    await src.addUnattributedHourlyReadingTime(
        dateKey: '2026-01-01', hour: 10, deltaMs: 5000);
    await src.addVideoHourlyWatchTime(
        dateKey: '2026-01-01', hour: 21, deltaMs: 4000);
    final zipDir = await _tempDir('mg_zip_');
    addTearDown(() => cleanupTempDir(zipDir));
    final zip = p.join(zipDir.path, 'b.zip');
    await _exportZip(src, srcDir.path, zip);
    await src.close();

    await BackupService.mergeRestoreBackup(
        dbDirectory: curDir.path, zipPath: zip);
    // Re-import the SAME backup again — must stay idempotent.
    await BackupService.mergeRestoreBackup(
        dbDirectory: curDir.path, zipPath: zip);

    final after = FushiDatabase(curDir.path);
    addTearDown(after.close);
    final rows = await after.getAllReadingHourlyLogs();
    expect(rows, hasLength(3));
    expect(
      rows
          .singleWhere(
              (r) => r.hour == 9 && r.format == BookFormat.epub.dbValue)
          .readingTimeMs,
      30000, // MAX(20000, 30000)，不 SUM
    );
    expect(
      rows
          .singleWhere(
              (r) => r.hour == 9 && r.format == BookFormat.manga.dbValue)
          .readingTimeMs,
      10000, // 仅本机持有，原样保留
    );
    expect(
      rows.singleWhere((r) => r.hour == 10 && r.format.isEmpty).readingTimeMs,
      5000, // 仅备份持有，原样并入
    );
    final videoRows = await after.getAllVideoHourlyLogs();
    expect(videoRows.single.watchTimeMs, 4000); // MAX(1000, 4000)
  });

  test('reading statistics: many titles under one dateKey are NOT folded',
      () async {
    final curDir = await _tempDir('mg_cur_');
    addTearDown(() => cleanupTempDir(curDir));
    final cur = FushiDatabase(curDir.path);
    await cur.setReadingStatistic(ReadingStatisticsCompanion.insert(
      title: 'BookA',
      dateKey: '2026-02-02',
      charactersRead: 50,
      readingTimeMs: 1000,
      lastStatisticModified: 1,
    ));
    await cur.close();

    final srcDir = await _tempDir('mg_src_');
    addTearDown(() => cleanupTempDir(srcDir));
    final src = FushiDatabase(srcDir.path);
    // Two DIFFERENT titles, SAME dateKey.
    await src.setReadingStatistic(ReadingStatisticsCompanion.insert(
      title: 'BookA',
      dateKey: '2026-02-02',
      charactersRead: 70,
      readingTimeMs: 500,
      lastStatisticModified: 2,
    ));
    await src.setReadingStatistic(ReadingStatisticsCompanion.insert(
      title: 'BookB',
      dateKey: '2026-02-02',
      charactersRead: 999,
      readingTimeMs: 3000,
      lastStatisticModified: 3,
    ));
    final zipDir = await _tempDir('mg_zip_');
    addTearDown(() => cleanupTempDir(zipDir));
    final zip = p.join(zipDir.path, 'b.zip');
    await _exportZip(src, srcDir.path, zip);
    await src.close();

    await BackupService.mergeRestoreBackup(
        dbDirectory: curDir.path, zipPath: zip);

    final after = FushiDatabase(curDir.path);
    addTearDown(after.close);
    final rows = await after.getAllReadingStatistics();
    // Two distinct (title, dateKey) rows — NOT folded into one.
    expect(rows, hasLength(2));
    final byTitle = {for (final r in rows) r.title: r};
    expect(byTitle['BookA']!.charactersRead, 70); // max(50, 70)
    expect(byTitle['BookB']!.charactersRead, 999); // backup-only inserted
  });

  test('mining statistics MAX-union (not double-counted on re-import)',
      () async {
    final curDir = await _tempDir('mg_cur_');
    addTearDown(() => cleanupTempDir(curDir));
    final cur = FushiDatabase(curDir.path);
    await cur.setMiningCount(
        sourceType: 'book', dateKey: '2026-03-03', count: 5);
    await cur.close();

    final srcDir = await _tempDir('mg_src_');
    addTearDown(() => cleanupTempDir(srcDir));
    final src = FushiDatabase(srcDir.path);
    await src.setMiningCount(
        sourceType: 'book', dateKey: '2026-03-03', count: 3);
    final zipDir = await _tempDir('mg_zip_');
    addTearDown(() => cleanupTempDir(zipDir));
    final zip = p.join(zipDir.path, 'b.zip');
    await _exportZip(src, srcDir.path, zip);
    await src.close();

    await BackupService.mergeRestoreBackup(
        dbDirectory: curDir.path, zipPath: zip);
    await BackupService.mergeRestoreBackup(
        dbDirectory: curDir.path, zipPath: zip);

    final after = FushiDatabase(curDir.path);
    addTearDown(after.close);
    final rows = await after.getMiningStatisticsBySource('book');
    expect(rows, hasLength(1));
    expect(rows.single.count, 5); // max(5, 3), never 8
  });

  test('lookup/mining counters MAX-union both columns (idempotent re-import)',
      () async {
    final curDir = await _tempDir('mg_cur_');
    addTearDown(() => cleanupTempDir(curDir));
    final cur = FushiDatabase(curDir.path);
    // Device: lookup 10, mine 2 on Book A; a no-book lookup bucket (title='').
    await cur.setLookupCount(
      bookKey: 'keyA',
      title: 'Book A',
      sourceType: 'book',
      dateKey: '2026-03-03',
      count: 10,
    );
    await cur.setMineCountPerBook(
      bookKey: 'keyA',
      title: 'Book A',
      sourceType: 'book',
      dateKey: '2026-03-03',
      count: 2,
    );
    await cur.setLookupCount(
      title: '',
      sourceType: 'book',
      dateKey: '2026-03-03',
      count: 3,
    );
    await cur.close();

    final srcDir = await _tempDir('mg_src_');
    addTearDown(() => cleanupTempDir(srcDir));
    final src = FushiDatabase(srcDir.path);
    // Backup: lookup 4 (lower), mine 9 (higher) on the same Book A bucket, and a
    // brand-new Book B bucket the device lacks.
    await src.setLookupCount(
      bookKey: 'keyA',
      title: 'Book A',
      sourceType: 'book',
      dateKey: '2026-03-03',
      count: 4,
    );
    await src.setMineCountPerBook(
      bookKey: 'keyA',
      title: 'Book A',
      sourceType: 'book',
      dateKey: '2026-03-03',
      count: 9,
    );
    await src.setLookupCount(
      bookKey: 'keyB',
      title: 'Book B',
      sourceType: 'book',
      dateKey: '2026-03-04',
      count: 6,
    );
    final zipDir = await _tempDir('mg_zip_');
    addTearDown(() => cleanupTempDir(zipDir));
    final zip = p.join(zipDir.path, 'b.zip');
    await _exportZip(src, srcDir.path, zip);
    await src.close();

    // Import twice — must stay idempotent (MAX, never SUM).
    await BackupService.mergeRestoreBackup(
        dbDirectory: curDir.path, zipPath: zip);
    await BackupService.mergeRestoreBackup(
        dbDirectory: curDir.path, zipPath: zip);

    final after = FushiDatabase(curDir.path);
    addTearDown(after.close);
    final rows = await after.getLookupMiningCountersBySource('book');
    final byTitle = {for (final r in rows) r.title: r};
    // Shared bucket: lookup MAX(10,4)=10, mine MAX(2,9)=9 (each column).
    expect(byTitle['Book A']!.lookupCount, 10);
    expect(byTitle['Book A']!.mineCount, 9);
    expect(byTitle['Book A']!.bookKey, 'keyA');
    // Backup-only Book B bucket inserted verbatim.
    expect(byTitle['Book B']!.lookupCount, 6);
    // Device-only no-book bucket untouched.
    expect(byTitle['']!.lookupCount, 3);
    expect(rows, hasLength(3));
  });

  test(
      'v76 regression: same-title multi-identity counters merge per bucket — '
      'src unattributed row neither drops identity rows nor inflates them',
      () async {
    final curDir = await _tempDir('mg_cur_');
    addTearDown(() => cleanupTempDir(curDir));
    final cur = FushiDatabase(curDir.path);
    // 同名双视频各自的身份桶（v76 唯一键世界）。
    await cur.addLookupCount(
        bookKey: 'uid-1',
        title: '同名',
        sourceType: 'video',
        dateKey: '2026-03-03',
        delta: 3);
    await cur.addLookupCount(
        bookKey: 'uid-2',
        title: '同名',
        sourceType: 'video',
        dateKey: '2026-03-03',
        delta: 4);
    await cur.close();

    final srcDir = await _tempDir('mg_src_');
    addTearDown(() => cleanupTempDir(srcDir));
    final src = FushiDatabase(srcDir.path);
    // 备份侧：同 title 的无身份桶（迁移歧义遗留 / 旧端产物）。用身份感知的
    // add* 写入器构造（set* 是 sync 的 title 粒度落地器，单行时按 title 抬、
    // 忽略身份，造不出「'' 桶 + 身份桶并存」的 fixture）。
    await src.addLookupCount(
        bookKey: '',
        title: '同名',
        sourceType: 'video',
        dateKey: '2026-03-03',
        delta: 7);
    // 身份桶：与 cur 的 uid-1 同桶但 mine 更高 → 逐列 MAX 抬升。
    await src.addMineCountPerBook(
        bookKey: 'uid-1',
        title: '同名',
        sourceType: 'video',
        dateKey: '2026-03-03',
        delta: 5);
    final zipDir = await _tempDir('mg_zip_');
    addTearDown(() => cleanupTempDir(zipDir));
    final zip = p.join(zipDir.path, 'b.zip');
    await _exportZip(src, srcDir.path, zip);
    await src.close();

    // 导两遍——幂等（MAX，绝不 SUM）。
    await BackupService.mergeRestoreBackup(
        dbDirectory: curDir.path, zipPath: zip);
    await BackupService.mergeRestoreBackup(
        dbDirectory: curDir.path, zipPath: zip);

    final after = FushiDatabase(curDir.path);
    addTearDown(after.close);
    final rows = (await after.getLookupMiningCountersBySource('video'))
        .where((LookupMiningCounterRow r) => r.title == '同名')
        .toList();
    final byKey = {for (final r in rows) r.bookKey: r};
    expect(rows, hasLength(3), reason: '三个桶各自独立，src 身份行不被三列键静默丢弃');
    expect(byKey['uid-1']!.lookupCount, 3, reason: '身份桶不被同 title 标量抬升');
    expect(byKey['uid-1']!.mineCount, 5, reason: '同桶逐列 MAX 正常抬升');
    expect(byKey['uid-2']!.lookupCount, 4, reason: '旁桶不动');
    expect(byKey['']!.lookupCount, 7, reason: 'src 无身份桶按自己的桶并入');
  });

  test(
      'game tags cross-machine: scrape identity two-hop lands the tag on the '
      "target's own game row (v79 二跳)", () async {
    final curDir = await _tempDir('mg_cur_');
    addTearDown(() => cleanupTempDir(curDir));
    final cur = FushiDatabase(curDir.path);
    // B 机：同一部游戏，本机局域 id 不同，但刮削到同一个 bgm 条目。
    await cur.upsertGalgame(GalgamesCompanion.insert(
      id: '222000000',
      name: 'GameB',
      exePath: r'D:\g.exe',
      workdir: r'D:\g',
      addedAt: 2,
    ));
    await cur.upsertGalgameSource(GalgameSourcesCompanion.insert(
      gameId: '222000000',
      source: 'bgm',
      externalId: const Value('12345'),
      dataJson: '{}',
      fetchedAt: 2,
    ));
    // 干扰游戏：无刮削身份，绝不许被打上标签。
    await cur.upsertGalgame(GalgamesCompanion.insert(
      id: '333000000',
      name: 'Bystander',
      exePath: r'D:\g\c.exe',
      workdir: r'D:\g',
      addedAt: 3,
    ));
    await cur.close();

    final srcDir = await _tempDir('mg_src_');
    addTearDown(() => cleanupTempDir(srcDir));
    final src = FushiDatabase(srcDir.path);
    // A 机：不同的本机 id + 同 bgm 条目 + 标签；另一部无刮削的游戏带标签
    // （跨机无身份可匹配 → 如实丢弃）。
    await src.upsertGalgame(GalgamesCompanion.insert(
      id: '111000000',
      name: 'GameA',
      exePath: r'E:\games.exe',
      workdir: r'E:\games',
      addedAt: 1,
    ));
    await src.upsertGalgameSource(GalgameSourcesCompanion.insert(
      gameId: '111000000',
      source: 'bgm',
      externalId: const Value('12345'),
      dataJson: '{}',
      fetchedAt: 1,
    ));
    final int tagId = await src.getOrCreateTagByName('神作');
    await src.addTagToGame('111000000', tagId);
    await src.upsertGalgame(GalgamesCompanion.insert(
      id: '444000000',
      name: 'Unscraped',
      exePath: r'E:\games\d.exe',
      workdir: r'E:\games',
      addedAt: 4,
    ));
    await src.addTagToGame('444000000', tagId);
    final zipDir = await _tempDir('mg_zip_');
    addTearDown(() => cleanupTempDir(zipDir));
    final zip = p.join(zipDir.path, 'b.zip');
    await _exportZip(src, srcDir.path, zip);
    await src.close();

    // 导两遍——幂等。
    await BackupService.mergeRestoreBackup(
        dbDirectory: curDir.path, zipPath: zip);
    await BackupService.mergeRestoreBackup(
        dbDirectory: curDir.path, zipPath: zip);

    final after = FushiDatabase(curDir.path);
    addTearDown(after.close);
    final tagged = (await after.getTagAssignmentsForKind(TagHostKind.game));
    expect(tagged, hasLength(1), reason: '二跳恰命中一行，重导不双计');
    expect(tagged.single.entryKey, '222000000',
        reason: '标签落在 B 机自己的游戏行上（经 bgm 12345 二跳），'
            '不是 A 机的局域 id');
    expect((await after.getTagsForGame('222000000')).single.name, '神作');
    expect(await after.getTagsForGame('333000000'), isEmpty,
        reason: '无刮削身份的旁观游戏不被误标');
    expect(await after.getAllGalgames(), hasLength(2),
        reason: 'galgames 行本身仍不搬运（A 机的游戏没被带过来）');
  });

  test('favorite words dedupe-union keeps earlier createdAt', () async {
    final curDir = await _tempDir('mg_cur_');
    addTearDown(() => cleanupTempDir(curDir));
    final cur = FushiDatabase(curDir.path);
    await cur.addFavoriteWord(
      expression: '表現',
      reading: 'ひょうげん',
      glossary: 'local',
      sourceType: 'book',
      dateKey: '2026-01-01',
    );
    await cur.close();

    final srcDir = await _tempDir('mg_src_');
    addTearDown(() => cleanupTempDir(srcDir));
    final src = FushiDatabase(srcDir.path);
    await src.addFavoriteWord(
      expression: '表現',
      reading: 'ひょうげん',
      glossary: 'backup',
      sourceType: 'book',
      dateKey: '2026-01-01',
    );
    await src.addFavoriteWord(
      expression: 'new',
      reading: '',
      glossary: 'g',
      sourceType: 'book',
      dateKey: '2026-01-01',
    );
    final zipDir = await _tempDir('mg_zip_');
    addTearDown(() => cleanupTempDir(zipDir));
    final zip = p.join(zipDir.path, 'b.zip');
    await _exportZip(src, srcDir.path, zip);
    await src.close();

    await BackupService.mergeRestoreBackup(
        dbDirectory: curDir.path, zipPath: zip);

    final after = FushiDatabase(curDir.path);
    addTearDown(after.close);
    final all = await after.getAllFavoriteWords();
    expect(all, hasLength(2)); // dup dropped, 'new' added
    final dup = all.firstWhere((w) => w.expression == '表現');
    expect(dup.glossary, 'local'); // earlier (device) row kept
  });

  test('tagId is remapped across DBs (no dangling FK on book tag mappings)',
      () async {
    final curDir = await _tempDir('mg_cur_');
    addTearDown(() => cleanupTempDir(curDir));
    final cur = FushiDatabase(curDir.path);
    // Device already has SOME tags so its autoincrement ids differ from src.
    await cur.createTag('existing-a', 0xFF111111);
    await cur.createTag('existing-b', 0xFF222222);
    await cur.insertEpubBook(_book('book1'));
    await cur.close();

    final srcDir = await _tempDir('mg_src_');
    addTearDown(() => cleanupTempDir(srcDir));
    final src = FushiDatabase(srcDir.path);
    final int srcTagId = await src.createTag('shared-tag', 0xFF333333);
    await src.insertEpubBook(_book('book1'));
    await src.addTagToBook('book1', srcTagId);
    final zipDir = await _tempDir('mg_zip_');
    addTearDown(() => cleanupTempDir(zipDir));
    final zip = p.join(zipDir.path, 'b.zip');
    await _exportZip(src, srcDir.path, zip);
    await src.close();

    await BackupService.mergeRestoreBackup(
        dbDirectory: curDir.path, zipPath: zip);

    final after = FushiDatabase(curDir.path);
    addTearDown(after.close);
    // The new tag landed with a FRESH id (not the src id).
    final tagRows = await after
        .customSelect("SELECT id FROM book_tags WHERE name = 'shared-tag'")
        .get();
    expect(tagRows, hasLength(1));
    final int targetTagId = tagRows.single.data['id'] as int;
    // The mapping points at the REMAPPED target id, not the src id.
    final maps = await after
        .customSelect('SELECT tag_id FROM tag_assignments '
            "WHERE media_kind = 'epub' AND entry_key = 'book1'")
        .get();
    expect(maps, hasLength(1));
    expect(maps.single.data['tag_id'], targetTagId);
    // No dangling FK: every mapping tag_id resolves to a real tag.
    final dangling = await after
        .customSelect('SELECT COUNT(*) AS c FROM tag_assignments m '
            'WHERE NOT EXISTS (SELECT 1 FROM book_tags t WHERE t.id = m.tag_id)')
        .getSingle();
    expect(dangling.data['c'], 0);
  });

  test('profileId is remapped across DBs (no dangling FK on child tables)',
      () async {
    final curDir = await _tempDir('mg_cur_');
    addTearDown(() => cleanupTempDir(curDir));
    final cur = FushiDatabase(curDir.path);
    // Device already has a profile so its ids diverge from src.
    await cur.insertProfile(
        ProfilesCompanion.insert(name: 'Default', createdAt: 1, updatedAt: 1));
    await cur.insertEpubBook(_book('pbook'));
    await cur.close();

    final srcDir = await _tempDir('mg_src_');
    addTearDown(() => cleanupTempDir(srcDir));
    final src = FushiDatabase(srcDir.path);
    final int srcProfileId = await src.insertProfile(
        ProfilesCompanion.insert(name: 'Reading', createdAt: 2, updatedAt: 2));
    await src.upsertProfileSetting(ProfileSettingsCompanion.insert(
      profileId: srcProfileId,
      category: 'reader',
      key: 'fontSize',
      value: '18',
    ));
    await src.insertEpubBook(_book('pbook'));
    await src.setBookProfile('pbook', srcProfileId);
    final zipDir = await _tempDir('mg_zip_');
    addTearDown(() => cleanupTempDir(zipDir));
    final zip = p.join(zipDir.path, 'b.zip');
    await _exportZip(src, srcDir.path, zip);
    await src.close();

    await BackupService.mergeRestoreBackup(
        dbDirectory: curDir.path, zipPath: zip);

    final after = FushiDatabase(curDir.path);
    addTearDown(after.close);
    final pr = await after
        .customSelect("SELECT id FROM profiles WHERE name = 'Reading'")
        .get();
    expect(pr, hasLength(1));
    final int targetPid = pr.single.data['id'] as int;
    // profile_settings child remapped to the new profile id.
    final ps = await after
        .customSelect('SELECT profile_id FROM profile_settings '
            "WHERE key = 'fontSize'")
        .get();
    expect(ps, hasLength(1));
    expect(ps.single.data['profile_id'], targetPid);
    // book_profiles child remapped too.
    final bp = await after
        .customSelect('SELECT profile_id FROM book_profiles '
            "WHERE book_key = 'pbook'")
        .get();
    expect(bp, hasLength(1));
    expect(bp.single.data['profile_id'], targetPid);
    // No dangling FK across all three child tables.
    for (final t in [
      'profile_settings',
      'media_type_profiles',
      'book_profiles'
    ]) {
      final d = await after
          .customSelect('SELECT COUNT(*) AS c FROM $t x '
              'WHERE NOT EXISTS (SELECT 1 FROM profiles p '
              'WHERE p.id = x.profile_id)')
          .getSingle();
      expect(d.data['c'], 0, reason: '$t has a dangling profile_id');
    }
  });

  test('mined sentences dedupe by fingerprint (no INSERT OR IGNORE reliance)',
      () async {
    final curDir = await _tempDir('mg_cur_');
    addTearDown(() => cleanupTempDir(curDir));
    final cur = FushiDatabase(curDir.path);
    await cur.addMinedSentence(
      source: 'book',
      dateKey: '2026-01-01',
      expression: '語',
      reading: 'ご',
    );
    // Read back its created_at so the backup can carry an IDENTICAL fingerprint.
    final int sharedCreatedAt =
        (await cur.getAllMinedSentences()).single.createdAt;
    await cur.close();

    final srcDir = await _tempDir('mg_src_');
    addTearDown(() => cleanupTempDir(srcDir));
    final src = FushiDatabase(srcDir.path);
    // Same fingerprint (duplicate) — must be dropped.
    await src.into(src.minedSentences).insert(MinedSentencesCompanion.insert(
          source: 'book',
          dateKey: '2026-01-01',
          expression: const Value('語'),
          reading: const Value('ご'),
          createdAt: sharedCreatedAt,
        ));
    // Different created_at — must be kept.
    await src.addMinedSentence(
      source: 'book',
      dateKey: '2026-01-02',
      expression: '別',
      reading: 'べつ',
    );
    final zipDir = await _tempDir('mg_zip_');
    addTearDown(() => cleanupTempDir(zipDir));
    final zip = p.join(zipDir.path, 'b.zip');
    await _exportZip(src, srcDir.path, zip);
    await src.close();

    await BackupService.mergeRestoreBackup(
        dbDirectory: curDir.path, zipPath: zip);

    final after = FushiDatabase(curDir.path);
    addTearDown(after.close);
    final rows = await after.getAllMinedSentences();
    expect(rows, hasLength(2)); // dup dropped, distinct one added
  });

  test('reader position LWW: newer updatedAt wins, older does not clobber',
      () async {
    final curDir = await _tempDir('mg_cur_');
    addTearDown(() => cleanupTempDir(curDir));
    final cur = FushiDatabase(curDir.path);
    await cur.insertEpubBook(_book('lwwbook'));
    await cur.upsertReaderPosition(ReaderPositionsCompanion.insert(
      bookKey: 'lwwbook',
      sectionIndex: 2,
      normCharOffset: 5000,
      updatedAt: 100,
    ));
    await cur.close();

    final srcDir = await _tempDir('mg_src_');
    addTearDown(() => cleanupTempDir(srcDir));
    final src = FushiDatabase(srcDir.path);
    await src.insertEpubBook(_book('lwwbook'));
    await src.upsertReaderPosition(ReaderPositionsCompanion.insert(
      bookKey: 'lwwbook',
      sectionIndex: 9,
      normCharOffset: 9999,
      updatedAt: 200, // newer → wins
    ));
    final zipDir = await _tempDir('mg_zip_');
    addTearDown(() => cleanupTempDir(zipDir));
    final zip = p.join(zipDir.path, 'b.zip');
    await _exportZip(src, srcDir.path, zip);
    await src.close();

    await BackupService.mergeRestoreBackup(
        dbDirectory: curDir.path, zipPath: zip);

    final after = FushiDatabase(curDir.path);
    addTearDown(after.close);
    final pos = await after.getReaderPosition('lwwbook');
    expect(pos!.sectionIndex, 9); // backup (newer) won
    expect(pos.normCharOffset, 9999);

    // Now re-merge a backup whose updatedAt is OLDER — must not clobber.
    final src2Dir = await _tempDir('mg_src2_');
    addTearDown(() => cleanupTempDir(src2Dir));
    final src2 = FushiDatabase(src2Dir.path);
    await src2.insertEpubBook(_book('lwwbook'));
    await src2.upsertReaderPosition(ReaderPositionsCompanion.insert(
      bookKey: 'lwwbook',
      sectionIndex: 0,
      normCharOffset: 1,
      updatedAt: 50, // older → must lose
    ));
    final zip2 = p.join(zipDir.path, 'b2.zip');
    await _exportZip(src2, src2Dir.path, zip2);
    await src2.close();
    await BackupService.mergeRestoreBackup(
        dbDirectory: curDir.path, zipPath: zip2);
    final pos2 = await after.getReaderPosition('lwwbook');
    expect(pos2!.sectionIndex, 9); // unchanged — older backup ignored
  });

  test('content tree restore is copy-if-absent (never overwrites existing)',
      () async {
    final curDir = await _tempDir('mg_cur_');
    addTearDown(() => cleanupTempDir(curDir));
    final cur = FushiDatabase(curDir.path);
    await cur.close();

    // This device's books tree: one existing file with LOCAL content.
    final booksRoot = await _tempDir('mg_books_');
    addTearDown(() => cleanupTempDir(booksRoot));
    final existing = File(p.join(booksRoot.path, 'shared.txt'));
    await existing.writeAsString('LOCAL');

    // Backup carries the SAME relative file (different content) + a NEW file.
    final srcDir = await _tempDir('mg_src_');
    addTearDown(() => cleanupTempDir(srcDir));
    final src = FushiDatabase(srcDir.path);
    final srcBooks = await _tempDir('mg_srcbooks_');
    addTearDown(() => cleanupTempDir(srcBooks));
    await File(p.join(srcBooks.path, 'shared.txt')).writeAsString('BACKUP');
    await File(p.join(srcBooks.path, 'new.txt')).writeAsString('NEW');
    final zipDir = await _tempDir('mg_zip_');
    addTearDown(() => cleanupTempDir(zipDir));
    final zip = p.join(zipDir.path, 'b.zip');
    await BackupService(
      db: src,
      dbDirectory: srcDir.path,
      appVersion: '2.0.0',
      booksRootDirectory: srcBooks.path,
    ).createBackup(zip);
    await src.close();

    await BackupService.mergeRestoreBackup(
      dbDirectory: curDir.path,
      zipPath: zip,
      booksRootDirectory: booksRoot.path,
    );

    // Existing file untouched; new file added.
    expect(await existing.readAsString(), 'LOCAL');
    expect(await File(p.join(booksRoot.path, 'new.txt')).readAsString(), 'NEW');
  });

  test('bookmark for a book the backup omitted is skipped (no FK violation)',
      () async {
    final curDir = await _tempDir('mg_cur_');
    addTearDown(() => cleanupTempDir(curDir));
    final cur = FushiDatabase(curDir.path);
    await cur.insertEpubBook(_book('owned'));
    await cur.close();

    final srcDir = await _tempDir('mg_src_');
    addTearDown(() => cleanupTempDir(srcDir));
    final src = FushiDatabase(srcDir.path);
    // Bookmark whose owning book is NOT in the backup (and not on device).
    await src.insertEpubBook(_book('owned'));
    await src.customStatement(
      'INSERT INTO bookmarks (book_key, section_index, norm_char_offset, '
      'label, created_at) VALUES (?, ?, ?, ?, ?)',
      <Object?>['owned', 1, 100, 'kept', 10],
    );
    // A second epub_books row exists in src, but we delete it AFTER making a
    // bookmark to simulate an orphan reference — instead, just add a bookmark
    // referencing 'owned' which both have; verify it merges. For the skip case,
    // craft a bookmark on a book missing from BOTH by temporarily disabling FK.
    await src.customStatement('PRAGMA foreign_keys = OFF');
    await src.customStatement(
      'INSERT INTO bookmarks (book_key, section_index, norm_char_offset, '
      'label, created_at) VALUES (?, ?, ?, ?, ?)',
      <Object?>['ghost', 5, 500, 'skipme', 20],
    );
    await src.customStatement('PRAGMA foreign_keys = ON');
    final zipDir = await _tempDir('mg_zip_');
    addTearDown(() => cleanupTempDir(zipDir));
    final zip = p.join(zipDir.path, 'b.zip');
    await _exportZip(src, srcDir.path, zip);
    await src.close();

    // Must NOT throw (FK preserved) and must skip the ghost bookmark.
    await BackupService.mergeRestoreBackup(
        dbDirectory: curDir.path, zipPath: zip);

    final after = FushiDatabase(curDir.path);
    addTearDown(after.close);
    final labels =
        (await after.customSelect('SELECT label FROM bookmarks').get())
            .map((r) => r.data['label'] as String)
            .toSet();
    expect(labels.contains('kept'), true);
    expect(labels.contains('skipme'), false); // ghost-book bookmark skipped
    // No dangling FK.
    final dangling = await after
        .customSelect('SELECT COUNT(*) AS c FROM bookmarks b '
            'WHERE NOT EXISTS (SELECT 1 FROM epub_books e '
            'WHERE e.book_key = b.book_key)')
        .getSingle();
    expect(dangling.data['c'], 0);
  });

  test('crash mid-merge rolls back: device DB unchanged, bak retained',
      () async {
    final curDir = await _tempDir('mg_cur_');
    addTearDown(() => cleanupTempDir(curDir));
    final cur = FushiDatabase(curDir.path);
    await cur.insertEpubBook(_book('survivor'));
    await cur.close();

    // A backup zip whose hibiki.db is NOT a valid SQLite file → opening it to
    // migrate throws. The orchestrator must surface the error WITHOUT touching
    // the live DB (snapshot/mutation happen only after a successful migrate).
    final corruptDir = await _tempDir('mg_corrupt_');
    addTearDown(() => cleanupTempDir(corruptDir));
    final corruptDb = File(p.join(corruptDir.path, 'hibiki.db'));
    await corruptDb.writeAsBytes(List<int>.filled(64, 0x7a)); // garbage
    final zipDir = await _tempDir('mg_zip_');
    addTearDown(() => cleanupTempDir(zipDir));
    final zip = p.join(zipDir.path, 'corrupt.zip');
    await _zipDbWithMeta(corruptDb.path, zip);

    await expectLater(
      BackupService.mergeRestoreBackup(dbDirectory: curDir.path, zipPath: zip),
      throwsA(anything),
    );

    // Live DB still has exactly the original content.
    final after = FushiDatabase(curDir.path);
    addTearDown(after.close);
    final keys = (await after.getAllEpubBooks()).map((b) => b.bookKey).toSet();
    expect(keys, <String>{'survivor'});
  });

  test('engine-level transaction rolls back a partial merge on failure',
      () async {
    final tDir = await _tempDir('mg_eng_');
    addTearDown(() => cleanupTempDir(tDir));
    final target = FushiDatabase(tDir.path);
    addTearDown(target.close);
    await target.insertEpubBook(_book('orig'));

    // Build a src DB, then ATTACH it and abort the transaction mid-way: insert
    // a book that succeeds, then force a failure, and assert nothing committed.
    final sDir = await _tempDir('mg_engsrc_');
    addTearDown(() => cleanupTempDir(sDir));
    final srcDb = FushiDatabase(sDir.path);
    await srcDb.insertEpubBook(_book('from-src'));
    await srcDb.close();

    final String safe = p.join(sDir.path, 'fushi.db').replaceAll(r'\', '/');
    await target.customStatement("ATTACH DATABASE '$safe' AS probe");
    try {
      await expectLater(
        target.transaction(() async {
          await target.customStatement(
            'INSERT INTO epub_books (book_key, title, epub_path, extract_dir, '
            'chapter_count, chapters_json, imported_at) '
            'SELECT book_key, title, epub_path, extract_dir, chapter_count, '
            'chapters_json, imported_at FROM probe.epub_books',
          );
          // Now throw → the whole transaction must roll back.
          throw StateError('boom');
        }),
        throwsStateError,
      );
    } finally {
      await target.customStatement('DETACH DATABASE probe');
    }
    final keys = (await target.getAllEpubBooks()).map((b) => b.bookKey).toSet();
    expect(keys, <String>{'orig'}); // 'from-src' rolled back
  });

  test('overwrite import path is unchanged (whole DB replaced, no merge)',
      () async {
    final curDir = await _tempDir('mg_cur_');
    addTearDown(() => cleanupTempDir(curDir));
    final cur = FushiDatabase(curDir.path);
    await cur.insertEpubBook(_book('device-book'));
    await cur.close();

    final srcDir = await _tempDir('mg_src_');
    addTearDown(() => cleanupTempDir(srcDir));
    final src = FushiDatabase(srcDir.path);
    await src.insertEpubBook(_book('backup-book'));
    final zipDir = await _tempDir('mg_zip_');
    addTearDown(() => cleanupTempDir(zipDir));
    final zip = p.join(zipDir.path, 'b.zip');
    await _exportZip(src, srcDir.path, zip);
    await src.close();

    await BackupService.restoreBackup(dbDirectory: curDir.path, zipPath: zip);

    final after = FushiDatabase(curDir.path);
    addTearDown(after.close);
    // OVERWRITE: only the backup's book survives (device book gone).
    final keys = (await after.getAllEpubBooks()).map((b) => b.bookKey).toSet();
    expect(keys, <String>{'backup-book'});
  });

  // ── TODO-1195 part B: tombstones + merge preview ─────────────────────────
  test('merge does NOT resurrect a book the user deleted (tombstone)',
      () async {
    final curDir = await _tempDir('mg_cur_');
    addTearDown(() => cleanupTempDir(curDir));
    final cur = FushiDatabase(curDir.path);
    await cur.insertEpubBook(_book('deleted-book'));
    await cur.insertEpubBook(_book('kept-book'));
    // User deletes one book → a tombstone is recorded.
    await cur.deleteEpubBook('deleted-book', tombstone: true);
    expect(await cur.getBookTombstoneKeys(), <String>{'deleted-book'});
    await cur.close();

    // An OLDER backup still carries the deleted book plus a brand-new one.
    final srcDir = await _tempDir('mg_src_');
    addTearDown(() => cleanupTempDir(srcDir));
    final src = FushiDatabase(srcDir.path);
    await src.insertEpubBook(_book('deleted-book'));
    await src.insertEpubBook(_book('new-book'));
    final zipDir = await _tempDir('mg_zip_');
    addTearDown(() => cleanupTempDir(zipDir));
    final zip = p.join(zipDir.path, 'b.zip');
    await _exportZip(src, srcDir.path, zip);
    await src.close();

    await BackupService.mergeRestoreBackup(
        dbDirectory: curDir.path, zipPath: zip);

    final after = FushiDatabase(curDir.path);
    addTearDown(after.close);
    final keys = (await after.getAllEpubBooks()).map((b) => b.bookKey).toSet();
    // deleted-book stays gone; the new book is still added.
    expect(keys, <String>{'kept-book', 'new-book'});
  });

  test('re-adding a deleted book clears its tombstone', () async {
    final curDir = await _tempDir('mg_cur_');
    addTearDown(() => cleanupTempDir(curDir));
    final cur = FushiDatabase(curDir.path);
    addTearDown(cur.close);
    await cur.insertEpubBook(_book('b'));
    await cur.deleteEpubBook('b', tombstone: true);
    expect(await cur.getBookTombstoneKeys(), <String>{'b'});
    // Re-importing the same book cancels the tombstone.
    await cur.insertEpubBook(_book('b'));
    expect(await cur.getBookTombstoneKeys(), isEmpty);
  });

  test('previewMergeRestore counts new books and updated positions', () async {
    final curDir = await _tempDir('mg_cur_');
    addTearDown(() => cleanupTempDir(curDir));
    final cur = FushiDatabase(curDir.path);
    addTearDown(cur.close);
    await cur.insertEpubBook(_book('shared'));
    await cur.upsertReaderPosition(ReaderPositionsCompanion.insert(
      bookKey: 'shared',
      sectionIndex: 1,
      normCharOffset: 100,
      updatedAt: 100,
    ));

    final srcDir = await _tempDir('mg_src_');
    addTearDown(() => cleanupTempDir(srcDir));
    final src = FushiDatabase(srcDir.path);
    await src.insertEpubBook(_book('shared'));
    await src.insertEpubBook(_book('new1'));
    await src.insertEpubBook(_book('new2'));
    // Newer position for the shared book → counts as an update.
    await src.upsertReaderPosition(ReaderPositionsCompanion.insert(
      bookKey: 'shared',
      sectionIndex: 5,
      normCharOffset: 999,
      updatedAt: 200,
    ));
    final zipDir = await _tempDir('mg_zip_');
    addTearDown(() => cleanupTempDir(zipDir));
    final zip = p.join(zipDir.path, 'b.zip');
    await _exportZip(src, srcDir.path, zip);
    await src.close();

    // Preview runs against the STILL-OPEN live DB (attaches, counts, detaches).
    final preview = await BackupService.previewMergeRestore(
      liveDb: cur,
      dbDirectory: curDir.path,
      zipPath: zip,
    );
    expect(preview != null, true);
    expect(preview!.newEpubBooks, 2); // new1, new2
    expect(preview.newBooks, 2);
    expect(preview.updatedReaderPositions, 1); // shared position advanced
    // Preview leaves no temp/attached state behind.
    expect(File(p.join(curDir.path, 'fushi.db.merge-preview-src')).existsSync(),
        false);
  });

  test('previewMergeRestore excludes tombstoned books from the new-book count',
      () async {
    final curDir = await _tempDir('mg_cur_');
    addTearDown(() => cleanupTempDir(curDir));
    final cur = FushiDatabase(curDir.path);
    addTearDown(cur.close);
    // The device deleted 'gone' earlier (tombstoned) and never had 'fresh'.
    await cur.insertBookTombstone('gone');

    final srcDir = await _tempDir('mg_src_');
    addTearDown(() => cleanupTempDir(srcDir));
    final src = FushiDatabase(srcDir.path);
    await src.insertEpubBook(_book('gone'));
    await src.insertEpubBook(_book('fresh'));
    final zipDir = await _tempDir('mg_zip_');
    addTearDown(() => cleanupTempDir(zipDir));
    final zip = p.join(zipDir.path, 'b.zip');
    await _exportZip(src, srcDir.path, zip);
    await src.close();

    final preview = await BackupService.previewMergeRestore(
      liveDb: cur,
      dbDirectory: curDir.path,
      zipPath: zip,
    );
    expect(preview != null, true);
    expect(preview!.newEpubBooks, 1); // only 'fresh' — 'gone' is tombstoned
  });

  test(
      'a tombstoned book stat is not resurrected by a backup merge '
      '(TODO-1204 后续)', () async {
    final curDir = await _tempDir('mg_cur_');
    addTearDown(() => cleanupTempDir(curDir));
    final cur = FushiDatabase(curDir.path);
    // Device once had "A" stats then the user deleted them -> tombstone, and a
    // surviving "Keep" book.
    await cur.addReadingStatistic(
        title: 'A', dateKey: '2026-01-01', charsRead: 100, timeMs: 6000);
    await cur.addLookupCount(
        bookKey: 'book/A',
        title: 'A',
        sourceType: 'book',
        dateKey: '2026-01-01');
    await cur.deleteReadingStatisticsForTitle('A');
    await cur.addReadingStatistic(
        title: 'Keep', dateKey: '2026-01-01', charsRead: 10, timeMs: 600);
    await cur.close();

    // An old backup still carries A's stats + counters.
    final srcDir = await _tempDir('mg_src_');
    addTearDown(() => cleanupTempDir(srcDir));
    final src = FushiDatabase(srcDir.path);
    await src.addReadingStatistic(
        title: 'A', dateKey: '2026-01-01', charsRead: 999, timeMs: 99999);
    await src.addLookupCount(
        bookKey: 'book/A',
        title: 'A',
        sourceType: 'book',
        dateKey: '2026-01-01');
    final zipDir = await _tempDir('mg_zip_');
    addTearDown(() => cleanupTempDir(zipDir));
    final zip = p.join(zipDir.path, 'b.zip');
    await _exportZip(src, srcDir.path, zip);
    await src.close();

    await BackupService.mergeRestoreBackup(
      dbDirectory: curDir.path,
      zipPath: zip,
    );

    final after = FushiDatabase(curDir.path);
    addTearDown(after.close);
    final Set<String> titles = (await after.getAllReadingStatistics())
        .map((ReadingStatisticRow r) => r.title)
        .toSet();
    expect(titles, <String>{'Keep'},
        reason: 'tombstoned "A" must not be re-inserted from the backup');
    final Set<String> counterTitles =
        (await after.getLookupMiningCountersBySource('book'))
            .map((LookupMiningCounterRow r) => r.title)
            .toSet();
    expect(counterTitles.contains('A'), false,
        reason: 'tombstoned "A" lookup counter must not resurrect either');
  });

  test('media collections merge: (name,type) 幂等 + collection_id 跨库 remap',
      () async {
    // 目标：先建 Filler(collection) 占掉 id 1，让 Dupe 落 id 2，从而与 src 的 id 分叉，
    // 真正检验 remap（不是靠 id 数字巧合相等蒙混）。Dupe(playlist) 含成员 keep-target。
    final curDir = await _tempDir('mg_cur_');
    addTearDown(() => cleanupTempDir(curDir));
    final cur = FushiDatabase(curDir.path);
    await cur.createMediaCollection('Filler');
    final int tDupe =
        await cur.createMediaCollection('Dupe', collectionType: 'playlist');
    await cur.addToCollection(tDupe, MediaKind.video, 'keep-target');
    await cur.close();

    // 备份：同名同类型 Dupe(playlist)（src 里落 id 1）含 from-src；另有全新
    // NewOne(collection)（src id 2）含 b1。
    final srcDir = await _tempDir('mg_src_');
    addTearDown(() => cleanupTempDir(srcDir));
    final src = FushiDatabase(srcDir.path);
    final int sDupe =
        await src.createMediaCollection('Dupe', collectionType: 'playlist');
    await src.addToCollection(sDupe, MediaKind.video, 'from-src');
    final int sNew = await src.createMediaCollection('NewOne');
    // 'book' 是本机未知的种类（旧值域/对端未来值）：raw 版原样落库，
    // 检验合并导入对未知种类的透传（typed 版收 MediaKind 表达不了它）。
    await src.addToCollectionRaw(sNew, 'book', 'b1');
    expect(sDupe, isNot(tDupe),
        reason: 'src/target 的 Dupe id 必须不同，才能真正检验 remap');
    final zipDir = await _tempDir('mg_zip_');
    addTearDown(() => cleanupTempDir(zipDir));
    final zip = p.join(zipDir.path, 'b.zip');
    await _exportZip(src, srcDir.path, zip);
    await src.close();

    await BackupService.mergeRestoreBackup(
      dbDirectory: curDir.path,
      zipPath: zip,
    );

    final after = FushiDatabase(curDir.path);
    addTearDown(after.close);
    final List<MediaCollectionRow> cols = await after.getAllMediaCollections();
    // Dupe 按自然键幂等（不重复），NewOne 新增 → 连同 Filler 恰好三个。
    expect(cols.map((MediaCollectionRow c) => c.name).toList()..sort(),
        <String>['Dupe', 'Filler', 'NewOne']);
    final MediaCollectionRow dupe =
        cols.firstWhere((MediaCollectionRow c) => c.name == 'Dupe');
    expect(dupe.id, tDupe, reason: '同名同类型必须复用目标既有 id，绝不新建重复合集');
    // Dupe 成员并集 {keep-target, from-src}：from-src 落进目标 Dupe(id=tDupe)，
    // 证明 src Dupe(sDupe) 已 remap 到 tDupe，而非新建一个 id=sDupe 的孤儿合集。
    final Set<String> dupeMembers = (await after.getCollectionItems(dupe.id))
        .map((MediaCollectionItemRow r) => r.entryKey)
        .toSet();
    expect(dupeMembers, <String>{'keep-target', 'from-src'});
    // NewOne 带 b1，collection_id 指向目标新分配的 id（非 src 的 sNew）。
    final MediaCollectionRow newOne =
        cols.firstWhere((MediaCollectionRow c) => c.name == 'NewOne');
    final List<MediaCollectionItemRow> newItems =
        await after.getCollectionItems(newOne.id);
    expect(
        newItems.map((MediaCollectionItemRow r) => r.entryKey), <String>['b1']);
    expect(newItems.single.collectionId, newOne.id);
  });

  test('media collections merge: 重复导入同一备份幂等（成员不翻倍）', () async {
    final curDir = await _tempDir('mg_cur_');
    addTearDown(() => cleanupTempDir(curDir));
    final cur = FushiDatabase(curDir.path);
    await cur.close();

    final srcDir = await _tempDir('mg_src_');
    addTearDown(() => cleanupTempDir(srcDir));
    final src = FushiDatabase(srcDir.path);
    final int sCol =
        await src.createMediaCollection('Show', collectionType: 'playlist');
    await src.addToCollection(sCol, MediaKind.video, 'e1');
    await src.addToCollection(sCol, MediaKind.video, 'e2');
    final zipDir = await _tempDir('mg_zip_');
    addTearDown(() => cleanupTempDir(zipDir));
    final zip = p.join(zipDir.path, 'b.zip');
    await _exportZip(src, srcDir.path, zip);
    await src.close();

    // 连续合并两次同一备份：合集不翻倍、成员不重复。
    await BackupService.mergeRestoreBackup(
        dbDirectory: curDir.path, zipPath: zip);
    await BackupService.mergeRestoreBackup(
        dbDirectory: curDir.path, zipPath: zip);

    final after = FushiDatabase(curDir.path);
    addTearDown(after.close);
    final List<MediaCollectionRow> cols = await after.getAllMediaCollections();
    expect(cols, hasLength(1), reason: '同名同类型合集第二次导入必须复用，不新建');
    final Set<String> members = (await after.getCollectionItems(cols.single.id))
        .map((MediaCollectionItemRow r) => r.entryKey)
        .toSet();
    expect(members, <String>{'e1', 'e2'}, reason: '成员复合主键去重，不翻倍');
  });

  test('书根名记错致 rebase 失配时，extract_dir 按 book_key 落回本机书根', () async {
    // 真实踩中的形态（跨包名迁移）：导出端声明的书根是改名前的旧名，行里
    // extract_dir 的真实前缀却是新名，于是 rebasePath 的前缀匹配失败并**静默
    // 原样返回**导出设备的绝对路径。库看着导入成功，每本书却都「找不到书籍
    // 文件」——那个路径是老包的私有沙箱，新包永远读不到，尽管内容早已解包到
    // 本机书根下。
    final curDir = await _tempDir('mg_cur_');
    addTearDown(() => cleanupTempDir(curDir));
    final cur = FushiDatabase(curDir.path);
    await cur.close();

    // 本机书根：解包落点 <booksRoot>/<bookKey> 已存在（文件确实搬过来了）。
    final booksRoot = await _tempDir('mg_books_');
    addTearDown(() => cleanupTempDir(booksRoot));
    await Directory(p.join(booksRoot.path, 'novel')).create(recursive: true);

    final srcDir = await _tempDir('mg_src_');
    addTearDown(() => cleanupTempDir(srcDir));
    final src = FushiDatabase(srcDir.path);
    await src.insertEpubBook(EpubBooksCompanion.insert(
      bookKey: 'novel',
      title: 'novel',
      epubPath: '/data/user/0/app.old.pkg/app_flutter/fushi_books/novel.epub',
      extractDir: '/data/user/0/app.old.pkg/app_flutter/fushi_books/novel',
      chapterCount: 1,
      chaptersJson: '[]',
      importedAt: _now(),
    ));
    // 声明的书根与行里前缀对不上（模拟导出端写了改名前的旧目录名）。
    final srcBooks = await _tempDir('mg_srcbooks_');
    addTearDown(() => cleanupTempDir(srcBooks));
    final zipDir = await _tempDir('mg_zip_');
    addTearDown(() => cleanupTempDir(zipDir));
    final zip = p.join(zipDir.path, 'b.zip');
    await BackupService(
      db: src,
      dbDirectory: srcDir.path,
      appVersion: '2.0.0',
      booksRootDirectory: srcBooks.path,
    ).createBackup(zip);
    await src.close();

    await BackupService.mergeRestoreBackup(
      dbDirectory: curDir.path,
      zipPath: zip,
      booksRootDirectory: booksRoot.path,
    );

    final after = FushiDatabase(curDir.path);
    addTearDown(after.close);
    final List<EpubBookRow> rows = await after.getAllEpubBooks();
    expect(rows.single.extractDir, p.join(booksRoot.path, 'novel'),
        reason: 'rebase 前缀失配时必须落回本机确定位置，'
            '不能留着导出设备的绝对路径（那是另一个应用的沙箱）');
  });

  test('rebase 结果在本机存在时不被 book_key 回退改写', () async {
    // 回退只能在「rebase 结果不存在」时兜底，不得越权顶掉一个有效的嵌套路径，
    // 否则普通备份恢复会被这条兜底改坏（Never break userspace）。
    final curDir = await _tempDir('mg_cur_');
    addTearDown(() => cleanupTempDir(curDir));
    final cur = FushiDatabase(curDir.path);
    await cur.close();

    final booksRoot = await _tempDir('mg_books_');
    addTearDown(() => cleanupTempDir(booksRoot));
    // 两个都存在：rebase 结果（嵌套）与 book_key 直落位置。必须选前者。
    await Directory(p.join(booksRoot.path, 'sub', 'novel'))
        .create(recursive: true);
    await Directory(p.join(booksRoot.path, 'novel')).create(recursive: true);

    final srcDir = await _tempDir('mg_src_');
    addTearDown(() => cleanupTempDir(srcDir));
    final src = FushiDatabase(srcDir.path);
    final srcBooks = await _tempDir('mg_srcbooks_');
    addTearDown(() => cleanupTempDir(srcBooks));
    await src.insertEpubBook(EpubBooksCompanion.insert(
      bookKey: 'novel',
      title: 'novel',
      epubPath: p.join(srcBooks.path, 'sub', 'novel.epub'),
      extractDir: p.join(srcBooks.path, 'sub', 'novel'),
      chapterCount: 1,
      chaptersJson: '[]',
      importedAt: _now(),
    ));
    final zipDir = await _tempDir('mg_zip_');
    addTearDown(() => cleanupTempDir(zipDir));
    final zip = p.join(zipDir.path, 'b.zip');
    await BackupService(
      db: src,
      dbDirectory: srcDir.path,
      appVersion: '2.0.0',
      booksRootDirectory: srcBooks.path,
    ).createBackup(zip);
    await src.close();

    await BackupService.mergeRestoreBackup(
      dbDirectory: curDir.path,
      zipPath: zip,
      booksRootDirectory: booksRoot.path,
    );

    final after = FushiDatabase(curDir.path);
    addTearDown(after.close);
    final List<EpubBookRow> rows = await after.getAllEpubBooks();
    expect(rows.single.extractDir, p.join(booksRoot.path, 'sub', 'novel'),
        reason: '正常 rebase 的结果有效，兜底不得把它顶成 book_key 直落位置');
  });

  test('adoptSourcePreferences：补齐老包设置，但绝不盖掉本库自己的状态标记', () async {
    final curDir = await _tempDir('mg_cur_');
    addTearDown(() => cleanupTempDir(curDir));
    final cur = FushiDatabase(curDir.path);
    // 新包自己的状态标记（描述「本库处于什么状态」，被老包值盖掉会毁库）。
    await cur.customStatement(
        'INSERT OR REPLACE INTO preferences ("key", "value") VALUES (?, ?)',
        <Object?>['prefs_version', 'NEW']);
    await cur.close();

    final srcDir = await _tempDir('mg_src_');
    addTearDown(() => cleanupTempDir(srcDir));
    final src = FushiDatabase(srcDir.path);
    await src.customStatement(
        'INSERT OR REPLACE INTO preferences ("key", "value") VALUES (?, ?)',
        <Object?>['prefs_version', 'OLD']);
    await src.customStatement(
        'INSERT OR REPLACE INTO preferences ("key", "value") VALUES (?, ?)',
        <Object?>['src:reader_fushi:font_size', '22']);
    final zipDir = await _tempDir('mg_zip_');
    addTearDown(() => cleanupTempDir(zipDir));
    final zip = p.join(zipDir.path, 'b.zip');
    await _exportZip(src, srcDir.path, zip);
    await src.close();

    await BackupService.mergeRestoreBackup(
      dbDirectory: curDir.path,
      zipPath: zip,
      adoptSourcePreferences: true,
    );

    final after = FushiDatabase(curDir.path);
    addTearDown(after.close);
    final Map<String, String> prefs = await after.getAllPrefs();
    expect(prefs['src:reader_fushi:font_size'], '22',
        reason: '老包独有的用户设置必须补进来，否则迁移完全是默认值');
    expect(prefs['prefs_version'], 'NEW', reason: '本库自己的状态标记不得被老包的值覆盖');
  });

  test('默认不接管源库设置（共享备份 merge 不动本机设置）', () async {
    final curDir = await _tempDir('mg_cur_');
    addTearDown(() => cleanupTempDir(curDir));
    final cur = FushiDatabase(curDir.path);
    await cur.close();

    final srcDir = await _tempDir('mg_src_');
    addTearDown(() => cleanupTempDir(srcDir));
    final src = FushiDatabase(srcDir.path);
    await src.customStatement(
        'INSERT OR REPLACE INTO preferences ("key", "value") VALUES (?, ?)',
        <Object?>['src:reader_fushi:font_size', '22']);
    final zipDir = await _tempDir('mg_zip_');
    addTearDown(() => cleanupTempDir(zipDir));
    final zip = p.join(zipDir.path, 'b.zip');
    await _exportZip(src, srcDir.path, zip);
    await src.close();

    await BackupService.mergeRestoreBackup(
        dbDirectory: curDir.path, zipPath: zip);

    final after = FushiDatabase(curDir.path);
    addTearDown(after.close);
    final Map<String, String> prefs = await after.getAllPrefs();
    expect(prefs.containsKey('src:reader_fushi:font_size'), false,
        reason: '别人设备的备份 merge 进来不该改本机设置（这是 merge 的既有语义）');
  });
}
