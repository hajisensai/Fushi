import 'dart:io';

import 'package:drift/drift.dart' show Value, Variable;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/overwrite_snapshot_notice.dart';
import 'package:fushi/src/sync/backup_service.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/dvd/dvd_title_path.dart';
import 'package:fushi_engine/utils/misc/fushi_time_format.dart';
import 'package:path/path.dart' as p;

import 'temp_dir_cleanup.dart';

/// BUG-4701：覆盖导入成功后保留覆盖前快照；「从快照恢复书库」只补缺合并书库行、
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

  Future<String> emptyPack() async {
    final FushiDatabase src = FushiDatabase(srcDir.path);
    final String zipPath = p.join(zipDir.path, 'empty.zip');
    await BackupService(
      db: src,
      dbDirectory: srcDir.path,
      appVersion: '1.0.0',
    ).createBackup(zipPath);
    await src.close();
    return zipPath;
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
    final String uidC = await insertBook(
      cur,
      'C',
      extractDir: p.join(curDir.path, 'gone', 'C'),
    );
    await position(cur, uidA, section: 2, updatedAt: 500);
    await position(cur, uidC, section: 4, updatedAt: 700);
    await position(cur, uidB, section: 9, updatedAt: 900);
    await stat(cur, 'A', 1234);
    await stat(cur, 'B', 999);
    await stat(cur, 'C', 77);
    await cur.setPref('audiobook_pos_A', '11');
    await cur.setPref('audiobook_pos_C', '33');
    await cur.setPref('audiobook_pos_at_C', '34');
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
    // 会补回来的只有书文件还在的 A（C 跳过，见下）。
    expect(preview.restorableBooks.map((b) => b.bookKey), <String>['A']);
    expect(preview.hasRestorableContent, isTrue);
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
    // 书文件已不在盘上的 C 不恢复（维护者 2026-11-16）：不插打不开的空壳行，
    // 它的进度也不挂到不存在的书身份上；统计按书名记，是历史，照常补回。
    expect(await after.getEpubBook('C'), isNull);
    expect(await after.getReaderPosition(uidC), isNull);
    final int positions =
        (await after
                .customSelect('SELECT COUNT(*) AS c FROM reader_positions')
                .getSingle())
            .read<int>('c');
    expect(positions, 2, reason: 'only A and B carry a reading position');
    expect(await statChars(after, 'C'), 77);
    // 有声书进度跟着书走：A 补回，跳过的 C 连同时间戳孪生键都不落（不留孤儿进度）。
    expect(await after.getPref('audiobook_pos_A'), '11');
    expect(await after.getPref('audiobook_pos_C'), isNull);
    expect(await after.getPref('audiobook_pos_at_C'), isNull);
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

  test('a DVD title (virtual library path) whose disc is still on disk counts '
      'as reachable and is restored from the snapshot', () async {
    // DVD title 是虚拟路径 `<盘根>/VIDEO_TS/TITLE_nn.dvdtitle`，盘上没有这个文件；
    // 盘本身（VIDEO_TS.IFO）还在，这一条就还能放。
    final String discRoot = p.join(curDir.path, 'discs', 'MOVIE');
    final File ifo = File(p.join(discRoot, 'VIDEO_TS', 'VIDEO_TS.IFO'))
      ..createSync(recursive: true);
    ifo.writeAsStringSync('DVDVIDEO-VMG');
    final String dvdTitle = dvdTitlePath(discRoot, 1);
    expect(File(dvdTitle).existsSync(), isFalse);
    final String goneVideo = p.join(curDir.path, 'videos', 'gone.mp4');

    final FushiDatabase cur = FushiDatabase(curDir.path);
    await cur.upsertVideoBook(
      VideoBooksCompanion.insert(
        bookUid: 'video/dvd',
        title: 'DVD',
        videoPath: dvdTitle,
      ),
    );
    await cur.upsertVideoBook(
      VideoBooksCompanion.insert(
        bookUid: 'video/gone',
        title: 'Gone',
        videoPath: goneVideo,
      ),
    );
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

    final FushiDatabase live = FushiDatabase(curDir.path);
    final OverwriteSnapshotPreview preview =
        (await BackupRestoreService.previewOverwriteSnapshot(
          dbDirectory: curDir.path,
          liveDb: live,
        ))!;
    expect(preview.missingVideoCount, 1);
    await live.close();

    await BackupRestoreService.mergeFromOverwriteSnapshot(
      dbDirectory: curDir.path,
    );
    final FushiDatabase after = FushiDatabase(curDir.path);
    addTearDown(after.close);
    expect(
      (await after.allVideoBooks()).map((VideoBookRow v) => v.videoPath),
      <String>[dvdTitle],
    );
  });

  test('snapshot preview and restore never probe book / video files on the '
      'calling (UI) isolate', () async {
    final String videoPath = p.join(curDir.path, 'videos', 'kept.mp4');
    File(videoPath)
      ..createSync(recursive: true)
      ..writeAsStringSync('mp4');
    final FushiDatabase cur = FushiDatabase(curDir.path);
    await insertBook(cur, 'A', extractDir: bookDirA);
    await cur.upsertVideoBook(
      VideoBooksCompanion.insert(
        bookUid: 'video/kept',
        title: 'Kept',
        videoPath: videoPath,
      ),
    );
    await cur.close();
    await BackupRestoreService.restoreBackup(
      dbDirectory: curDir.path,
      zipPath: await emptyPack(),
    );

    // 本 isolate 上一旦为这些路径构造 File / Directory（existsSync 的前置），立刻炸：
    // 存在性检查必须整批在后台 isolate 跑（IOOverrides 不跨 isolate）。
    final _ForbidProbeOverrides guard = _ForbidProbeOverrides(<String>{
      bookDirA,
      videoPath,
    });
    final FushiDatabase live = FushiDatabase(curDir.path);
    final OverwriteSnapshotPreview preview =
        (await IOOverrides.runWithIOOverrides(
          () => BackupRestoreService.previewOverwriteSnapshot(
            dbDirectory: curDir.path,
            liveDb: live,
          ),
          guard,
        ))!;
    await live.close();
    expect(preview.restorableBooks.map((b) => b.bookKey), <String>['A']);
    expect(preview.missingVideoCount, 1);

    await IOOverrides.runWithIOOverrides(
      () => BackupRestoreService.mergeFromOverwriteSnapshot(
        dbDirectory: curDir.path,
      ),
      guard,
    );
    expect(guard.probed, isEmpty);
    final FushiDatabase after = FushiDatabase(curDir.path);
    addTearDown(after.close);
    expect(await after.getEpubBook('A'), isNotNull);
    expect(
      (await after.allVideoBooks()).map((VideoBookRow v) => v.videoPath),
      <String>[videoPath],
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

  String createdRecordPath() =>
      p.join(curDir.path, 'fushi.db.overwrite-snapshot-created');

  DateTime readCreatedRecord() =>
      DateTime.parse(File(createdRecordPath()).readAsStringSync()).toLocal();

  test('the retention period starts at the overwrite, not at the snapshot '
      "file's modification time", () async {
    final FushiDatabase cur = FushiDatabase(curDir.path);
    await insertBook(cur, 'A', extractDir: bookDirA);
    await cur.close();
    final String zipPath = await emptyPack();

    final DateTime before = DateTime.now().subtract(const Duration(minutes: 1));
    await BackupRestoreService.restoreBackup(
      dbDirectory: curDir.path,
      zipPath: zipPath,
    );
    final File snapshot = File(
      BackupRestoreService.overwriteSnapshotPath(curDir.path),
    );
    final DateTime stamped = readCreatedRecord();
    expect(stamped.isAfter(before), isTrue);

    // 快照文件带着旧主库很久以前的修改时刻（改名保留它；此前靠 setLastModified
    // 钉成「现在」，钉失败就是这个样子）：保留期仍从覆盖导入完成算起，不删。
    final DateTime longAgo = DateTime.now().subtract(const Duration(days: 90));
    snapshot.setLastModifiedSync(longAgo);
    expect(
      await BackupRestoreService.pruneExpiredOverwriteSnapshot(curDir.path),
      isFalse,
    );
    expect(snapshot.existsSync(), isTrue);
    expect(
      await BackupRestoreService.pruneExpiredOverwriteSnapshot(
        curDir.path,
        now: stamped.add(
          BackupRestoreService.overwriteSnapshotRetention -
              const Duration(hours: 1),
        ),
      ),
      isFalse,
    );
    expect(snapshot.existsSync(), isTrue);

    // 过了保留期：删掉快照，连同还没显示的提示标记。
    expect(
      await BackupRestoreService.pruneExpiredOverwriteSnapshot(
        curDir.path,
        now: stamped.add(BackupRestoreService.overwriteSnapshotRetention),
      ),
      isTrue,
    );
    expect(snapshot.existsSync(), isFalse);
    final FushiDatabase live = FushiDatabase(curDir.path);
    addTearDown(live.close);
    expect(
      await BackupRestoreService.takeOverwriteSnapshotNotice(
        dbDirectory: curDir.path,
        liveDb: live,
      ),
      isNull,
    );
    expect(
      Directory(curDir.path)
          .listSync()
          .map((FileSystemEntity e) => p.basename(e.path))
          .where((String n) => n.contains('overwrite')),
      isEmpty,
    );
  });

  test('a snapshot without a retention record starts counting at the next '
      'startup instead of being pruned by its stale file time', () async {
    final FushiDatabase cur = FushiDatabase(curDir.path);
    await insertBook(cur, 'A', extractDir: bookDirA);
    await cur.close();
    await BackupRestoreService.restoreBackup(
      dbDirectory: curDir.path,
      zipPath: await emptyPack(),
    );
    final File snapshot = File(
      BackupRestoreService.overwriteSnapshotPath(curDir.path),
    );
    // 收尾时起点记录没写成（或快照来自引入记录之前的版本），快照文件时刻很旧。
    File(createdRecordPath()).deleteSync();
    snapshot.setLastModifiedSync(
      DateTime.now().subtract(const Duration(days: 90)),
    );

    final DateTime startup = DateTime.now();
    expect(
      await BackupRestoreService.pruneExpiredOverwriteSnapshot(
        curDir.path,
        now: startup,
      ),
      isFalse,
    );
    expect(snapshot.existsSync(), isTrue);
    expect(readCreatedRecord(), startup);
    expect(
      await BackupRestoreService.pruneExpiredOverwriteSnapshot(
        curDir.path,
        now: startup.add(BackupRestoreService.overwriteSnapshotRetention),
      ),
      isTrue,
    );
    expect(snapshot.existsSync(), isFalse);
    expect(File(createdRecordPath()).existsSync(), isFalse);
  });

  test('failing to write the retention record keeps the snapshot and still '
      'leaves the post-import notice', () async {
    final FushiDatabase cur = FushiDatabase(curDir.path);
    await insertBook(cur, 'A', extractDir: bookDirA);
    await cur.close();
    // 起点记录路径被一个目录占住：写记录必然 FileSystemException。
    Directory(createdRecordPath()).createSync();
    await BackupRestoreService.restoreBackup(
      dbDirectory: curDir.path,
      zipPath: await emptyPack(),
    );
    expect(
      File(
        BackupRestoreService.overwriteSnapshotPath(curDir.path),
      ).existsSync(),
      isTrue,
    );
    expect(
      File(p.join(curDir.path, 'fushi.db.pre-restore.bak')).existsSync(),
      isFalse,
    );
    final FushiDatabase live = FushiDatabase(curDir.path);
    addTearDown(live.close);
    final OverwriteSnapshotPreview? notice =
        await BackupRestoreService.takeOverwriteSnapshotNotice(
          dbDirectory: curDir.path,
          liveDb: live,
        );
    expect(notice?.restorableBooks.map((b) => b.bookKey), <String>['A']);
  });

  test('the post-import notice is shown once, and only when the snapshot has '
      'something the current library lacks', () async {
    final FushiDatabase cur = FushiDatabase(curDir.path);
    await insertBook(cur, 'A', extractDir: bookDirA);
    await cur.close();
    final String zipPath = await emptyPack();
    await BackupRestoreService.restoreBackup(
      dbDirectory: curDir.path,
      zipPath: zipPath,
    );

    final FushiDatabase live = FushiDatabase(curDir.path);
    addTearDown(live.close);
    final OverwriteSnapshotPreview notice =
        (await BackupRestoreService.takeOverwriteSnapshotNotice(
          dbDirectory: curDir.path,
          liveDb: live,
        ))!;
    expect(notice.restorableBooks.map((b) => b.bookKey), <String>['A']);
    expect(
      notice.expiresAt,
      notice.createdAt.add(BackupRestoreService.overwriteSnapshotRetention),
    );
    final String body = overwriteSnapshotNoticeBody(notice);
    expect(body, contains(FushiTimeFormat.dayKey(notice.expiresAt)));
    expect(body, contains(t.storage_recovery_title));
    // 一次性：消费过就不再弹。
    expect(
      await BackupRestoreService.takeOverwriteSnapshotNotice(
        dbDirectory: curDir.path,
        liveDb: live,
      ),
      isNull,
    );
    // 快照还在，「恢复书库」页照常可用。
    expect(
      File(
        BackupRestoreService.overwriteSnapshotPath(curDir.path),
      ).existsSync(),
      isTrue,
    );
  });

  test('no notice when the overwritten library had nothing to recover '
      '(fresh install importing a pack)', () async {
    final FushiDatabase fresh = FushiDatabase(curDir.path);
    expect(await fresh.getEpubBookMetas(), isEmpty);
    await fresh.close();
    final String zipPath = await emptyPack();
    await BackupRestoreService.restoreBackup(
      dbDirectory: curDir.path,
      zipPath: zipPath,
    );
    final FushiDatabase live = FushiDatabase(curDir.path);
    addTearDown(live.close);
    expect(
      await BackupRestoreService.takeOverwriteSnapshotNotice(
        dbDirectory: curDir.path,
        liveDb: live,
      ),
      isNull,
    );
  });
}

/// 在当前 isolate 上为 [_forbidden] 里的路径构造 [File] / [Directory] 时记录并抛错。
base class _ForbidProbeOverrides extends IOOverrides {
  _ForbidProbeOverrides(this._forbidden);

  final Set<String> _forbidden;
  final List<String> probed = <String>[];

  Never _reject(String path) {
    probed.add(path);
    throw StateError('file probe on the calling isolate: $path');
  }

  @override
  Directory createDirectory(String path) =>
      _forbidden.contains(path) ? _reject(path) : super.createDirectory(path);

  @override
  File createFile(String path) =>
      _forbidden.contains(path) ? _reject(path) : super.createFile(path);
}
