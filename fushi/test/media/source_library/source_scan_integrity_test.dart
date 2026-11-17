// 来源扫描的正确性（nmv c08）：
//
//  BUG-4791 / BUG-2979 ②  视频「搬家」要正证据：规格缓存里的字节数，或路径尾段。
//  BUG-4792  系统 / 垃圾条目不入库；一个读不了的子目录不再让整次扫描失败。
//  BUG-4794  远端书：一本失败不中断其余、临时目录必删；被杀进程留下的临时来源行与
//            临时目录能被认出并回收，活着的另一个实例的不动。
//
// 漫画来源索引逐卷落盘（BUG-4793）的测试在 source_library_scanner_test.dart 的
// 「SourceLibraryScanner.scan manga source」组里（要用那里的压缩包夹具）。

import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/source_library/add_local_folder_source.dart';
import 'package:fushi/src/media/source_library/source_file_system.dart';
import 'package:fushi/src/media/source_library/source_library_scanner.dart';
import 'package:fushi/src/media/source_library/source_scan_temp.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/epub_storage.dart';
import 'package:fushi_engine/media/source_library/source_library_row.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:path/path.dart' as p;

FushiDatabase _memDb() => FushiDatabase.forTesting(NativeDatabase.memory());

Future<SourceLibraryRow> _source(
  FushiDatabase db,
  String root, {
  String kind = 'video',
}) async {
  final int id = await db.insertMediaSource(
    MediaSourcesCompanion.insert(
      label: 'Src',
      mediaKind: kind,
      rootPath: root,
      recursive: const Value<bool>(true),
      createdAt: 1000,
    ),
  );
  return (await db.getMediaSourceById(id))!;
}

Future<SourceScanSummary> _scan(FushiDatabase db, SourceLibraryRow source) =>
    SourceLibraryScanner(db, transcribeAudiobook: null).scan(source);

File _video(String path, {int bytes = 4}) => File(path)
  ..parent.createSync(recursive: true)
  ..writeAsBytesSync(List<int>.filled(bytes, 7));

Future<void> _setProgress(FushiDatabase db, String bookUid, int ms) =>
    (db.update(db.videoBooks)..where((t) => t.bookUid.equals(bookUid))).write(
      VideoBooksCompanion(
        lastPositionMs: Value<int>(ms),
        lastPlayedAt: const Value<int?>(99),
      ),
    );

Future<void> _recordSpec(FushiDatabase db, String path, int bytes) =>
    db.upsertVideoFileSpec(
      VideoFileSpecsCompanion.insert(
        filePath: path,
        fileSizeBytes: bytes,
        fileModifiedAt: 1,
        probedAt: 1,
        probeVersion: 1,
      ),
    );

Future<Map<String, VideoBookRow>> _rowsByUid(FushiDatabase db) async =>
    <String, VideoBookRow>{
      for (final VideoBookRow r in await VideoBookRepository(db).listAll())
        r.bookUid: r,
    };

/// `list()` 恒报错的目录：模拟没权限的系统目录（`System Volume Information`）。
class _UnreadableDirectory implements Directory {
  _UnreadableDirectory(this.path);

  @override
  final String path;

  @override
  Stream<FileSystemEntity> list({
    bool recursive = false,
    bool followLinks = true,
  }) => Stream<FileSystemEntity>.error(
    FileSystemException('Directory listing failed', path),
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 远端书来源替身：清单给定，`copyToLocal` 把同名本地夹具拷进目标目录，并记下每次
/// 用的目标目录；[failing] 里的路径下载即抛。
class _RemoteBookFs implements SourceFileSystem {
  _RemoteBookFs(this.fixtures, {this.failing = const <String>{}});

  /// 远端路径 → 本地夹具文件。
  final Map<String, String> fixtures;
  final Set<String> failing;
  final List<String> destDirs = <String>[];

  @override
  bool get isLocal => false;

  @override
  Future<List<SourceFileEntry>> listFiles(
    String dirPath, {
    bool recursive = false,
  }) async => <SourceFileEntry>[
    for (final String remote in fixtures.keys)
      SourceFileEntry(
        name: p.url.basename(remote),
        path: remote,
        isDirectory: false,
        sizeBytes: 1,
      ),
  ];

  @override
  Future<List<String>> listSiblingNames(String filePath) async => <String>[
    for (final String remote in fixtures.keys)
      if (p.url.dirname(remote) == p.url.dirname(filePath))
        p.url.basename(remote),
  ];

  @override
  Future<String> readText(String filePath) async =>
      throw StateError('unexpected readText');

  @override
  Future<String> copyToLocal(String filePath, String destDir) async {
    destDirs.add(destDir);
    if (failing.contains(filePath)) {
      throw const SocketException('connection reset while downloading');
    }
    final String dest = p.join(destDir, p.url.basename(filePath));
    File(fixtures[filePath]!).copySync(dest);
    return dest;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('scan_integrity_');
  });
  tearDown(() {
    debugResetSourceScanTempSession();
    debugSourceScanTempRoot = null;
    try {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows 上偶发的句柄延迟释放不算测试失败。
    }
  });

  group('视频搬家判定要正证据（BUG-4791 / BUG-2979 ②）', () {
    test('整个剧目录挪了位置：旧行改指新路径，进度保留，不再建 X (2)', () async {
      final FushiDatabase db = _memDb();
      addTearDown(db.close);
      final String oldRoot = p.join(tmp.path, 'smb');
      final String oldFile = p.join(oldRoot, 'Show', 'Season 03', 'ep10.mkv');
      _video(oldFile);
      await _scan(db, await _source(db, oldRoot));
      await _setProgress(db, 'video/ep10', 107774);

      // 用户把整部剧挪进 `动漫/`，再把新位置加成来源（BUG-2979 的真实案例）。
      final String newRoot = p.join(tmp.path, 'anime');
      Directory(newRoot).createSync();
      Directory(p.join(oldRoot, 'Show')).renameSync(p.join(newRoot, 'Show'));
      final String newFile = p.join(newRoot, 'Show', 'Season 03', 'ep10.mkv');

      final SourceScanSummary summary = await _scan(
        db,
        await _source(db, newRoot),
      );

      expect(summary.error, isNull);
      final Map<String, VideoBookRow> rows = await _rowsByUid(db);
      expect(rows.keys, <String>['video/ep10'], reason: '只剩一行');
      expect(rows['video/ep10']!.videoPath, newFile);
      expect(rows['video/ep10']!.lastPositionMs, 107774);
    });

    test('删掉 A 剧的 01.mkv 再放进 B 剧的 01.mkv：新建一行，A 行原样不动', () async {
      final FushiDatabase db = _memDb();
      addTearDown(db.close);
      final String aFile = p.join(tmp.path, 'ShowA', '01.mkv');
      _video(aFile, bytes: 10);
      final SourceLibraryRow source = await _source(db, tmp.path);
      await _scan(db, source);
      await _setProgress(db, 'video/01', 5000);

      File(aFile).deleteSync();
      final String bFile = p.join(tmp.path, 'ShowB', '01.mkv');
      _video(bFile, bytes: 20);
      final SourceScanSummary summary = await _scan(db, source);

      expect(summary.error, isNull);
      final Map<String, VideoBookRow> rows = await _rowsByUid(db);
      expect(rows.keys.toSet(), <String>{'video/01', 'video/01 (2)'});
      expect(rows['video/01']!.videoPath, aFile, reason: 'A 行没被改指到 B 的文件');
      expect(rows['video/01']!.lastPositionMs, 5000);
      expect(rows['video/01 (2)']!.videoPath, bFile);
      expect(rows['video/01 (2)']!.lastPositionMs, 0);
    });

    test('规格缓存里记过旧文件大小：大小不等就不是搬家，哪怕目录名一模一样', () async {
      final FushiDatabase db = _memDb();
      addTearDown(db.close);
      final String oldFile = p.join(tmp.path, 'old', 'Show', 'S1', '01.mkv');
      _video(oldFile, bytes: 10);
      await _scan(db, await _source(db, p.join(tmp.path, 'old')));
      await _recordSpec(db, oldFile, 10);
      File(oldFile).deleteSync();

      // 同样的 `Show/S1/01.mkv` 尾段，但字节数不同：是另一部片子。
      final String newFile = p.join(tmp.path, 'new', 'Show', 'S1', '01.mkv');
      _video(newFile, bytes: 33);
      await _scan(db, await _source(db, p.join(tmp.path, 'new')));

      final Map<String, VideoBookRow> rows = await _rowsByUid(db);
      expect(rows.keys.toSet(), <String>{'video/01', 'video/01 (2)'});
      expect(rows['video/01']!.videoPath, oldFile);
    });

    test('规格缓存里记过旧文件大小：大小相等即搬家，目录名对不上也认', () async {
      final FushiDatabase db = _memDb();
      addTearDown(db.close);
      final String oldFile = p.join(tmp.path, 'old', 'Inbox', '01.mkv');
      _video(oldFile, bytes: 10);
      await _scan(db, await _source(db, p.join(tmp.path, 'old')));
      await _recordSpec(db, oldFile, 10);
      await _setProgress(db, 'video/01', 777);
      File(oldFile).deleteSync();

      final String newFile = p.join(tmp.path, 'new', 'Sorted', '01.mkv');
      _video(newFile, bytes: 10);
      await _scan(db, await _source(db, p.join(tmp.path, 'new')));

      final Map<String, VideoBookRow> rows = await _rowsByUid(db);
      expect(rows.keys, <String>['video/01']);
      expect(rows['video/01']!.videoPath, newFile);
      expect(rows['video/01']!.lastPositionMs, 777);
    });

    test('两部剧的同名集都在库，删掉其中一部：不把它并进另一部再删行', () async {
      final FushiDatabase db = _memDb();
      addTearDown(db.close);
      // 父目录名相同（`Season 01`）、再上一层不同：只够「改指」，不够合并删行。
      final String aFile = p.join(tmp.path, 'ShowA', 'Season 01', '01.mkv');
      final String bFile = p.join(tmp.path, 'ShowB', 'Season 01', '01.mkv');
      _video(aFile);
      _video(bFile);
      final SourceLibraryRow source = await _source(db, tmp.path);
      await _scan(db, source);
      await _setProgress(db, 'video/01', 4242);

      File(aFile).deleteSync();
      final SourceScanSummary summary = await _scan(db, source);

      expect(summary.error, isNull);
      final Map<String, VideoBookRow> rows = await _rowsByUid(db);
      expect(rows.keys.toSet(), <String>{'video/01', 'video/01 (2)'});
      expect(rows['video/01']!.videoPath, aFile);
      expect(rows['video/01']!.lastPositionMs, 4242);
      expect(
        rows['video/01 (2)']!.lastPositionMs,
        0,
        reason: 'A 的进度没有被并到 B 的同名集上',
      );
    });

    test('修复前已建出 X (2) 的搬家残留：尾段两层都对得上才并回一行', () async {
      final FushiDatabase db = _memDb();
      addTearDown(db.close);
      final String oldFile = p.join(tmp.path, 'smb', 'Show', 'S3', 'ep.mkv');
      final String newFile = p.join(
        tmp.path,
        'smb',
        'anime',
        'Show',
        'S3',
        'ep.mkv',
      );
      _video(oldFile);
      _video(newFile);
      final SourceLibraryRow source = await _source(db, tmp.path);
      await _scan(db, source);
      Map<String, VideoBookRow> rows = await _rowsByUid(db);
      expect(rows.keys.toSet(), <String>{'video/ep', 'video/ep (2)'});
      final String staleUid = rows.entries
          .firstWhere(
            (MapEntry<String, VideoBookRow> e) => e.value.videoPath == oldFile,
          )
          .key;
      await _setProgress(db, staleUid, 9000);

      File(oldFile).deleteSync();
      await _scan(db, source);

      rows = await _rowsByUid(db);
      expect(rows, hasLength(1));
      expect(rows.values.single.videoPath, newFile);
      expect(rows.values.single.lastPositionMs, 9000);
    });

    test('videoRowMoveEvidence：旧盘不在线 / 旧文件还在都不算搬家', () async {
      final FushiDatabase db = _memDb();
      addTearDown(db.close);
      final String oldFile = p.join(tmp.path, 'a', 'S1', '01.mkv');
      _video(oldFile);
      await _scan(db, await _source(db, tmp.path));
      final VideoBookRow row = (await _rowsByUid(db))['video/01']!;
      Future<int?> noSpec(String _) async => null;

      expect(
        await videoRowMoveEvidence(
          row,
          p.join(tmp.path, 'b', 'S1', '01.mkv'),
          knownSizeOf: noSpec,
        ),
        VideoMoveEvidence.none,
        reason: '旧文件还在',
      );
      File(oldFile).deleteSync();
      expect(
        await videoRowMoveEvidence(
          row,
          p.join(tmp.path, 'b', 'S1', '01.mkv'),
          knownSizeOf: noSpec,
        ),
        VideoMoveEvidence.parentDirectory,
      );
      expect(
        await videoRowMoveEvidence(
          row,
          p.join(tmp.path, 'b', 'a', 'S1', '01.mkv'),
          knownSizeOf: noSpec,
        ),
        VideoMoveEvidence.parentChain,
      );
      expect(VideoMoveEvidence.parentDirectory.allowsMerge, isFalse);
      expect(VideoMoveEvidence.parentChain.allowsMerge, isTrue);
      expect(VideoMoveEvidence.sameSize.allowsMerge, isTrue);
    });
  });

  group('系统 / 垃圾条目与读不了的子目录（BUG-4792）', () {
    test('isSourceScanJunkPath：只认 ._ 文件与系统目录，不一刀切隐藏名', () {
      bool junk(String rel, {bool dir = false}) =>
          isSourceScanJunkPath('/lib/$rel', scanRoot: '/lib', isDirectory: dir);
      expect(junk('._01.mkv'), isTrue);
      expect(junk('Show/._01.mkv'), isTrue);
      expect(junk(r'$RECYCLE.BIN/S-1-5/$R1A2B.mkv'), isTrue);
      expect(junk('System Volume Information', dir: true), isTrue);
      expect(junk('Show/@eaDir/01.mkv/SYNOVIDEO_VIDEO_SCREENSHOT.jpg'), isTrue);
      expect(junk('#recycle/old.cbz'), isTrue);
      expect(junk('.Trash-1000/files/a.epub'), isTrue);
      expect(junk('.Trashes/501/a.mkv'), isTrue);

      expect(junk('Show/01.mkv'), isFalse);
      expect(junk('.hidden/01.mkv'), isFalse, reason: '隐藏目录里放媒体是合法用法');
      expect(junk('.01.mkv'), isFalse);
      expect(junk('Show/._extras', dir: true), isFalse, reason: '._ 只对文件');
      // 只看扫描根之下的路径段：把回收站本身加成来源是用户自己的选择。
      expect(
        isSourceScanJunkPath(
          r'D:\$RECYCLE.BIN\keep\01.mkv',
          scanRoot: r'D:\$RECYCLE.BIN\keep',
          isDirectory: false,
        ),
        isFalse,
      );
      // 远端命名空间（URL）同样适用。
      expect(
        isSourceScanJunkPath(
          'https://nas.example/dav/video/@eaDir/a.mkv',
          scanRoot: 'https://nas.example/dav/video',
          isDirectory: false,
        ),
        isTrue,
      );
    });

    test('视频来源实扫：._ 资源叉、回收站、@eaDir 里的文件不入库', () async {
      final FushiDatabase db = _memDb();
      addTearDown(db.close);
      _video(p.join(tmp.path, 'Show', '01.mkv'));
      _video(p.join(tmp.path, 'Show', '._01.mkv'));
      _video(p.join(tmp.path, r'$RECYCLE.BIN', 'S-1-5-21', r'$RABCDEF.mkv'));
      _video(p.join(tmp.path, 'Show', '@eaDir', 'thumb.mp4'));

      final SourceScanSummary summary = await _scan(
        db,
        await _source(db, tmp.path),
      );

      expect(summary.error, isNull);
      expect(summary.discoveredPaths, <String>[
        p.join(tmp.path, 'Show', '01.mkv'),
      ]);
      expect((await _rowsByUid(db)).keys, <String>['video/01']);
    });

    test('一个子目录读不了：跳过它、其余照常入库，错误里指名道姓', () async {
      final FushiDatabase db = _memDb();
      addTearDown(db.close);
      _video(p.join(tmp.path, 'Good', '01.mkv'));
      final String locked = p.join(tmp.path, 'Locked');
      Directory(locked).createSync();
      final SourceLibraryRow source = await _source(db, tmp.path);

      final SourceScanSummary summary = await IOOverrides.runZoned(
        () => _scan(db, source),
        createDirectory: (String path) => path == locked
            ? _UnreadableDirectory(path)
            : Zone.root.run(() => Directory(path)),
      );

      expect((await _rowsByUid(db)).keys, <String>['video/01']);
      expect(summary.importedMediaCount, 1);
      expect(summary.error, contains('could not be read'));
      expect(summary.error, contains(locked));
      final SourceLibraryRow after = (await db.getMediaSourceById(source.id))!;
      expect(after.lastScanError, contains(locked));
    });

    test('读不了的是系统目录（System Volume Information）：不算失败', () async {
      final FushiDatabase db = _memDb();
      addTearDown(db.close);
      _video(p.join(tmp.path, 'Good', '01.mkv'));
      final String svi = p.join(tmp.path, 'System Volume Information');
      Directory(svi).createSync();
      final SourceLibraryRow source = await _source(db, tmp.path);

      final SourceScanSummary summary = await IOOverrides.runZoned(
        () => _scan(db, source),
        createDirectory: (String path) => path == svi
            ? _UnreadableDirectory(path)
            : Zone.root.run(() => Directory(path)),
      );

      expect(summary.error, isNull);
      expect(summary.importedMediaCount, 1);
    });

    test('根目录读不了仍然是整次扫描失败', () async {
      final List<String> skipped = <String>[];
      final LocalSourceFileSystem fs = LocalSourceFileSystem(
        onUnreadableDirectory: (String dir, FileSystemException _) =>
            skipped.add(dir),
      );
      await expectLater(
        IOOverrides.runZoned(
          () => fs.listFiles(tmp.path, recursive: true),
          createDirectory: (String path) => path == tmp.path
              ? _RootUnreadable(path)
              : Zone.root.run(() => Directory(path)),
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(skipped, isEmpty);
    });
  });

  group('远端书：单本失败隔离与临时目录（BUG-4794）', () {
    late Directory books;

    setUp(() {
      books = Directory(p.join(tmp.path, 'bookroot'))..createSync();
      EpubStorage.debugBaseDirectoryOverride = books.path;
      debugSourceScanTempRoot = Directory(p.join(tmp.path, 'scan_tmp'));
    });
    tearDown(() {
      EpubStorage.debugBaseDirectoryOverride = null;
    });

    test('第一本下载失败：后面的书照常入库，错误指名，临时目录一个不剩', () async {
      final FushiDatabase db = _memDb();
      addTearDown(db.close);
      // 不是合法 EPUB 也没关系：这里钉的是「失败只作废这一本」与临时目录的清理。
      final String fixture = p.join(tmp.path, 'fixture.epub');
      File(fixture).writeAsBytesSync(<int>[1, 2, 3]);
      final _RemoteBookFs fs = _RemoteBookFs(
        <String, String>{
          '/srv/books/a.epub': fixture,
          '/srv/books/b.epub': fixture,
          '/srv/books/c.epub': fixture,
        },
        failing: <String>{'/srv/books/a.epub'},
      );
      final SourceLibraryRow source = await _source(
        db,
        '/srv/books',
        kind: 'book',
      );

      final SourceScanSummary summary = await SourceLibraryScanner(
        db,
        transcribeAudiobook: null,
      ).scan(source, fs: fs);

      expect(fs.destDirs, hasLength(3), reason: '第一本失败后 b / c 仍被处理（此前循环直接跳出）');
      expect(fs.destDirs.toSet(), hasLength(3), reason: '每本书各用一个临时目录');
      for (final String dir in fs.destDirs) {
        expect(Directory(dir).existsSync(), isFalse, reason: '$dir 必须已删');
      }
      expect(summary.error, contains('a.epub'));
      expect(summary.error, contains('3 failed'));
      final SourceLibraryRow after = (await db.getMediaSourceById(source.id))!;
      expect(after.lastScanError, contains('a.epub'));
    });
  });

  group('被杀进程留下的残留（BUG-4794）', () {
    test('临时来源行带标记；清扫删掉陈旧的、留下正在跑的与普通来源', () async {
      final FushiDatabase db = _memDb();
      addTearDown(db.close);
      final SourceLibraryRow normal = await _source(db, p.join(tmp.path, 'n'));
      Future<int> insertOneShot(String root) => db.insertMediaSource(
        MediaSourcesCompanion.insert(
          label: 'temp',
          mediaKind: 'video',
          rootPath: root,
          configJson: Value<String?>(oneShotSourceConfig(null)),
          createdAt: 1000,
        ),
      );
      final int stale = await insertOneShot(p.join(tmp.path, 'stale'));
      final int live = await insertOneShot(p.join(tmp.path, 'live'));
      markOneShotSourceLive(live);
      addTearDown(() => markOneShotSourceDone(live));
      final List<int> released = <int>[];

      final int removed = await sweepStaleOneShotSources(
        db,
        releaseAccess: (int id) async => released.add(id),
      );

      expect(removed, 1);
      expect(released, <int>[stale]);
      expect(
        (await db.getAllMediaSources()).map((MediaSourceRow r) => r.id).toSet(),
        <int>{normal.id, live},
      );
    });

    test('标记与 iOS 书签并存，书签刷新重写 configJson 后标记仍在', () {
      final String config = oneShotSourceConfig('bm-1');
      expect(sourceBookmarkFromConfig(config), 'bm-1');
      final String refreshed = configWithSourceBookmark(config, 'bm-2')!;
      expect(sourceBookmarkFromConfig(refreshed), 'bm-2');
      expect(decodeSourceConfig(refreshed)[kSourceConfigOneShotKey], isTrue);
    });

    test('importLocalFolderOnceAt：扫描期间临时行带标记，扫完行已删', () async {
      final FushiDatabase db = _memDb();
      addTearDown(db.close);
      _video(p.join(tmp.path, 'once', '01.mkv'));
      int? tempId;
      Future<MediaSourceRow?>? rowDuringScan;

      final SourceScanSummary? summary = await importLocalFolderOnceAt(
        db: db,
        transcribeAudiobook: null,
        mediaKind: 'video',
        path: p.join(tmp.path, 'once'),
        // 查询在扫描开始前就排进了库的执行队列，读到的是扫描期间的那一行。
        onScanning: (int id) {
          tempId = id;
          rowDuringScan = db.getMediaSourceById(id);
        },
      );

      expect(summary?.error, isNull);
      final MediaSourceRow? during = await rowDuringScan;
      expect(during, isNotNull);
      expect(isOneShotSourceRow(during!), isTrue);
      expect(await db.getMediaSourceById(tempId!), isNull);
      expect(await sweepStaleOneShotSources(db), 0);
      expect((await _rowsByUid(db)).keys, <String>['video/01']);
    });

    test('临时目录清扫：死会话的目录被回收，本进程自己的会话不动', () async {
      final Directory root = Directory(p.join(tmp.path, 'scan_tmp'));
      debugSourceScanTempRoot = root;
      final Directory mine = createSourceScanTempDir('m1c_scan_books_');
      File(p.join(mine.path, 'book.epub')).writeAsBytesSync(<int>[1]);

      // 死会话：锁文件在、没人持锁，目录里留着半本书。
      File(p.join(root.path, 's4242_1.lock')).writeAsBytesSync(<int>[]);
      final Directory dead = Directory(
        p.join(root.path, 's4242_1', 'm1c_scan_manga_x'),
      )..createSync(recursive: true);
      File(p.join(dead.path, 'p001.jpg')).writeAsBytesSync(<int>[1, 2]);
      // 清到一半的残留：有目录没锁文件。
      final Directory orphan = Directory(p.join(root.path, 's7_7'))
        ..createSync();

      final int reclaimed = await sweepDeadSourceScanSessions();

      expect(reclaimed, 2);
      expect(dead.parent.existsSync(), isFalse);
      expect(File(p.join(root.path, 's4242_1.lock')).existsSync(), isFalse);
      expect(orphan.existsSync(), isFalse);
      expect(
        File(p.join(mine.path, 'book.epub')).existsSync(),
        isTrue,
        reason: '本进程正在用的临时目录不能被自己的清扫删掉',
      );
    });

    test(
      '临时目录清扫：另一个句柄持着锁的会话（活着的另一个实例）原样留着',
      () async {
        final Directory root = Directory(p.join(tmp.path, 'scan_tmp'))
          ..createSync();
        debugSourceScanTempRoot = root;
        final RandomAccessFile holder = File(
          p.join(root.path, 's9_9.lock'),
        ).openSync(mode: FileMode.write)..lockSync(FileLock.exclusive);
        addTearDown(holder.closeSync);
        final Directory theirs = Directory(p.join(root.path, 's9_9', 'x'))
          ..createSync(recursive: true);

        expect(await sweepDeadSourceScanSessions(), 0);
        expect(theirs.existsSync(), isTrue);
      },
      // POSIX 的文件锁按进程算，同一进程里第二个句柄照样拿得到，测不出「别的进程
      // 持锁」；Windows 的锁按句柄算，同进程就能验。
      skip: Platform.isWindows ? false : 'POSIX 文件锁是进程级的，同进程无法模拟',
    );
  });
}

/// 根目录的 `exists()` 为真、`list()` 报错。
class _RootUnreadable extends _UnreadableDirectory {
  _RootUnreadable(super.path);

  @override
  Future<bool> exists() async => true;
}
