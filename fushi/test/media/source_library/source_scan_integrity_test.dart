// 来源扫描的正确性（nmv c08）：
//
//  BUG-4820 / BUG-2979 ②  视频「搬家」要正证据：规格缓存里的字节数，或连着对得上的
//            目录尾段（光是 `Season 01` 这种通用目录名不算）。
//  拍板台 design-nmv-video-move-fingerprint：旧行记过内容指纹时只看内容（同一个文件才
//            认，目录名不论），v165 `video_content_fingerprints`。
//  拍板台 hbk-audit-004-video-move-full-hash：只有整文件 SHA-256 能认定；采样指纹
//            （`osh:`）相同而中间不同的文件不改指、不合并。
//  BUG-4831  系统 / 垃圾条目不入库；一个读不了的子目录不再让整次扫描失败。
//  BUG-4835  远端书：一本失败不中断其余（连接断了才整轮结束）、临时目录必删；被杀
//            进程留下的临时来源行与临时目录能被认出并回收，活着的另一个实例的不动。
//
// 漫画来源索引逐卷落盘（BUG-4833）的测试在 source_library_scanner_test.dart 的
// 「SourceLibraryScanner.scan manga source」组里（要用那里的压缩包夹具）。

import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/source_library/add_local_folder_source.dart';
import 'package:fushi/src/media/source_library/source_auto_scan.dart';
import 'package:fushi/src/media/source_library/source_file_system.dart';
import 'package:fushi/src/media/source_library/source_library_scanner.dart';
import 'package:fushi/src/media/source_library/source_scan_temp.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/epub_storage.dart';
import 'package:fushi_engine/media/source_library/source_library_row.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi_engine/media/video/video_content_fingerprint.dart';
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

/// 后台整文件哈希升级不自动跑（测试里按需手动调
/// [upgradeVideoContentFingerprintsToFullHash]，结果才确定）。
Future<SourceScanSummary> _scan(FushiDatabase db, SourceLibraryRow source) =>
    SourceLibraryScanner(
      db,
      transcribeAudiobook: null,
      requestVideoContentFullHash: () {},
    ).scan(source);

/// [bytes] 字节、每字节取 `i % 251` 的文件；`[middleFrom, middleTo)` 区间改填 0xEE。
/// 首尾各 64 KiB 不动时 OpenSubtitles 采样哈希不变。
File _patterned(String path, int bytes, {int? middleFrom, int? middleTo}) {
  final List<int> data = List<int>.generate(bytes, (int i) => i % 251);
  if (middleFrom != null && middleTo != null) {
    data.fillRange(middleFrom, middleTo, 0xEE);
  }
  return File(path)
    ..parent.createSync(recursive: true)
    ..writeAsBytesSync(data);
}

/// [fill] 是文件内容的字节值：两部不同的剧要用不同的值，否则内容指纹相同、确实
/// 是「同一个文件」。
File _video(String path, {int bytes = 4, int fill = 7}) => File(path)
  ..parent.createSync(recursive: true)
  ..writeAsBytesSync(List<int>.filled(bytes, fill));

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
  _RemoteBookFs(
    this.fixtures, {
    this.failing = const <String>{},
    this.dropsConnectionOnFailure = false,
  });

  /// 远端路径 → 本地夹具文件。
  final Map<String, String> fixtures;
  final Set<String> failing;

  /// 第一次下载失败之后连列目录也报错：模拟连接断了（而不是某一本书坏了）。
  final bool dropsConnectionOnFailure;
  bool _connectionDown = false;
  final List<String> destDirs = <String>[];

  @override
  bool get isLocal => false;

  @override
  Future<List<SourceFileEntry>> listFiles(
    String dirPath, {
    bool recursive = false,
  }) async {
    if (_connectionDown) throw const SocketException('connection closed');
    return <SourceFileEntry>[
      for (final String remote in fixtures.keys)
        SourceFileEntry(
          name: p.url.basename(remote),
          path: remote,
          isDirectory: false,
          sizeBytes: 1,
        ),
    ];
  }

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
    if (_connectionDown || failing.contains(filePath)) {
      _connectionDown = dropsConnectionOnFailure;
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

  group('视频搬家判定要正证据（BUG-4820 / BUG-2979 ②）', () {
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
      // 父目录名相同（`Season 01`）、再上一层不同：不是搬家的证据。
      final String aFile = p.join(tmp.path, 'ShowA', 'Season 01', '01.mkv');
      final String bFile = p.join(tmp.path, 'ShowB', 'Season 01', '01.mkv');
      _video(aFile);
      _video(bFile, fill: 8);
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

    // 审查指出的口子：没探过规格时，光凭父目录名一致就改指。`剧/Season 01/` 是最常见
    // 的布局，`Season 01` 区分不了两部剧。
    test('删掉 A 剧再放进 B 剧，父目录都叫 Season 01：A 行不被改指到 B 的文件', () async {
      final FushiDatabase db = _memDb();
      addTearDown(db.close);
      final String aFile = p.join(tmp.path, 'ShowA', 'Season 01', '01.mkv');
      _video(aFile);
      final SourceLibraryRow source = await _source(db, tmp.path);
      await _scan(db, source);
      await _setProgress(db, 'video/01', 6100);

      Directory(p.join(tmp.path, 'ShowA')).deleteSync(recursive: true);
      final String bFile = p.join(tmp.path, 'ShowB', 'Season 01', '01.mkv');
      _video(bFile, fill: 8);
      final SourceScanSummary summary = await _scan(db, source);

      expect(summary.error, isNull);
      final Map<String, VideoBookRow> rows = await _rowsByUid(db);
      expect(rows.keys.toSet(), <String>{'video/01', 'video/01 (2)'});
      expect(rows['video/01']!.videoPath, aFile, reason: 'A 行没被改指到 B 的文件');
      expect(rows['video/01']!.lastPositionMs, 6100);
      expect(rows['video/01 (2)']!.videoPath, bFile);
      expect(rows['video/01 (2)']!.lastPositionMs, 0);
    });

    test('两层都对得上但全是通用目录名（Season 01/Extras）：同样不算搬家', () async {
      final FushiDatabase db = _memDb();
      addTearDown(db.close);
      final String aFile = p.join(
        tmp.path,
        'ShowA',
        'Season 01',
        'Extras',
        'NCOP.mkv',
      );
      _video(aFile);
      final SourceLibraryRow source = await _source(db, tmp.path);
      await _scan(db, source);
      await _setProgress(db, 'video/NCOP', 1234);

      Directory(p.join(tmp.path, 'ShowA')).deleteSync(recursive: true);
      final String bFile = p.join(
        tmp.path,
        'ShowB',
        'Season 01',
        'Extras',
        'NCOP.mkv',
      );
      _video(bFile, fill: 8);
      await _scan(db, source);

      final Map<String, VideoBookRow> rows = await _rowsByUid(db);
      expect(rows.keys.toSet(), <String>{'video/NCOP', 'video/NCOP (2)'});
      expect(rows['video/NCOP']!.videoPath, aFile);
      expect(rows['video/NCOP']!.lastPositionMs, 1234);
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
      final String oldFile = p.join(tmp.path, 'Show', 'S1', '01.mkv');
      _video(oldFile);
      await _scan(db, await _source(db, tmp.path));
      final VideoBookRow row = (await _rowsByUid(db))['video/01']!;
      Future<int?> noSpec(String _) async => null;
      Future<VideoMoveEvidence> evidenceFor(List<String> newSegments) =>
          videoRowMoveEvidence(
            row,
            p.joinAll(<String>[tmp.path, ...newSegments]),
            knownSizeOf: noSpec,
          );

      expect(
        await evidenceFor(<String>['b', 'Show', 'S1', '01.mkv']),
        VideoMoveEvidence.none,
        reason: '旧文件还在',
      );
      File(oldFile).deleteSync();
      expect(
        await evidenceFor(<String>['b', 'S1', '01.mkv']),
        VideoMoveEvidence.none,
        reason: '只对上一层，而且是通用的季目录名',
      );
      expect(
        await evidenceFor(<String>['b', 'Other', 'S1', '01.mkv']),
        VideoMoveEvidence.none,
        reason: '再上一层对不上',
      );
      expect(
        await evidenceFor(<String>['b', 'Show', 'S1', '01.mkv']),
        VideoMoveEvidence.directoryChain,
      );
    });

    test('内容指纹：只对上一层目录的真搬家（没探过规格）也认出，进度保留', () async {
      final FushiDatabase db = _memDb();
      addTearDown(db.close);
      final String oldFile = p.join(tmp.path, 'dl', 'Show', '01.mkv');
      _video(oldFile, bytes: 300 * 1024, fill: 3);
      await _scan(db, await _source(db, p.join(tmp.path, 'dl')));
      expect(
        (await db.allVideoContentFingerprints())['video/01']?.fingerprint,
        startsWith('osh:'),
        reason: '入库当场记下指纹（≥128 KiB 用 OpenSubtitles 哈希）',
      );
      await _setProgress(db, 'video/01', 31337);
      // 后台把采样指纹升级成整文件哈希（文件还在原处）。
      expect(await upgradeVideoContentFingerprintsToFullHash(db), 1);
      expect(
        (await db.allVideoContentFingerprints())['video/01']?.fingerprint,
        startsWith('sha256:'),
      );

      // `dl/Show/01.mkv` → `anime/Renamed/01.mkv`：目录尾段一层都对不上。
      final String newFile = p.join(tmp.path, 'anime', 'Renamed', '01.mkv');
      Directory(p.dirname(newFile)).createSync(recursive: true);
      File(oldFile).renameSync(newFile);
      await _scan(db, await _source(db, p.join(tmp.path, 'anime')));

      final Map<String, VideoBookRow> rows = await _rowsByUid(db);
      expect(rows.keys, <String>['video/01'], reason: '不再另建 X (2)');
      expect(rows['video/01']!.videoPath, newFile);
      expect(rows['video/01']!.lastPositionMs, 31337);
      expect(
        (await db.allVideoContentFingerprints())['video/01']?.fingerprint,
        startsWith('sha256:'),
        reason: '认定时算过的整文件哈希随改指记回，不降回采样指纹',
      );
    });

    test('整文件哈希：首尾 64 KiB 相同、中间不同的同名同大小文件不改指也不合并', () async {
      final FushiDatabase db = _memDb();
      addTearDown(db.close);
      const int size = 1024 * 1024;
      final String oldFile = p.join(tmp.path, 'old', 'Show', 'Arc', '01.mkv');
      _patterned(oldFile, size);
      await _scan(db, await _source(db, p.join(tmp.path, 'old')));
      await _setProgress(db, 'video/01', 777);
      await _recordSpec(db, oldFile, size);
      expect(await upgradeVideoContentFingerprintsToFullHash(db), 1);
      final String oldSampled = (await computeVideoContentFingerprint(
        oldFile,
      ))!.value;
      File(oldFile).deleteSync();

      // 同名、同大小、目录尾段 `Show/Arc` 也对得上，只有中间 400 KB 不同。
      final String newFile = p.join(tmp.path, 'new', 'Show', 'Arc', '01.mkv');
      _patterned(newFile, size, middleFrom: 300 * 1024, middleTo: 700 * 1024);
      expect(
        (await computeVideoContentFingerprint(newFile))!.value,
        oldSampled,
        reason: '采样指纹撞上（审查 HBK-AUDIT-004 的复现）',
      );
      final SourceLibraryRow newSource = await _source(
        db,
        p.join(tmp.path, 'new'),
      );
      await _scan(db, newSource);

      Map<String, VideoBookRow> rows = await _rowsByUid(db);
      expect(rows.keys.toSet(), <String>{'video/01', 'video/01 (2)'});
      expect(rows['video/01']!.videoPath, oldFile, reason: '旧行没被改指');
      expect(rows['video/01']!.lastPositionMs, 777);

      // 已经有 `X (2)` 时重扫：同样不能把旧行并进去再删掉。
      await _scan(db, newSource);
      rows = await _rowsByUid(db);
      expect(rows.keys.toSet(), <String>{'video/01', 'video/01 (2)'});
      expect(rows['video/01']!.lastPositionMs, 777);
    });

    test('整文件哈希还没算到：采样相同不下结论，按没指纹的行看目录链', () async {
      final FushiDatabase db = _memDb();
      addTearDown(db.close);
      const int size = 300 * 1024;
      final String oldFile = p.join(tmp.path, 'dl', 'Show', '01.mkv');
      _patterned(oldFile, size);
      await _scan(db, await _source(db, p.join(tmp.path, 'dl')));
      expect(
        (await db.allVideoContentFingerprints())['video/01']?.fingerprint,
        startsWith('osh:'),
      );

      // 只对上一层目录、没探过规格：没指纹的行也认不出，采样指纹相同不放宽。
      final String renamed = p.join(tmp.path, 'anime', 'Renamed', '01.mkv');
      Directory(p.dirname(renamed)).createSync(recursive: true);
      File(oldFile).renameSync(renamed);
      final VideoBookRow row = (await _rowsByUid(db))['video/01']!;
      final VideoContentFingerprintRow known = (await db
          .allVideoContentFingerprints())['video/01']!;
      Future<int?> noSpec(String _) async => null;
      expect(
        await matchVideoContent(known, renamed),
        VideoContentMatch.unconfirmed,
      );
      expect(
        await videoRowMoveEvidence(
          row,
          renamed,
          knownSizeOf: noSpec,
          knownContent: known,
        ),
        VideoMoveEvidence.none,
      );

      // 整棵 `Show/01.mkv` 挪走（目录链对上）：与没指纹的行一样认。
      final String chained = p.join(tmp.path, 'lib', 'dl', 'Show', '01.mkv');
      Directory(p.dirname(chained)).createSync(recursive: true);
      File(renamed).renameSync(chained);
      expect(
        await videoRowMoveEvidence(
          row,
          chained,
          knownSizeOf: noSpec,
          knownContent: known,
        ),
        VideoMoveEvidence.directoryChain,
      );
    });

    test('整文件哈希：字节数不同不读新文件内容', () async {
      final FushiDatabase db = _memDb();
      addTearDown(db.close);
      final String oldFile = p.join(tmp.path, 'Show', '01.mkv');
      _patterned(oldFile, 300 * 1024);
      await _scan(db, await _source(db, tmp.path));
      expect(await upgradeVideoContentFingerprintsToFullHash(db), 1);
      final VideoContentFingerprintRow known = (await db
          .allVideoContentFingerprints())['video/01']!;
      final String other = p.join(tmp.path, 'Other', '01.mkv');
      _patterned(other, 301 * 1024);
      int fullReads = 0;
      expect(
        await matchVideoContent(
          known,
          other,
          fullHashOf: (String path) async {
            fullReads++;
            return computeVideoContentFullHash(path);
          },
        ),
        VideoContentMatch.different,
      );
      expect(fullReads, 0);
      expect(
        await matchVideoContent(known, oldFile),
        VideoContentMatch.same,
        reason: '同一个文件整文件哈希相等',
      );
    });

    test('VideoContentFullHashUpgrader：后台升级、跑的期间请求补一轮', () async {
      final FushiDatabase db = _memDb();
      addTearDown(db.close);
      _patterned(p.join(tmp.path, 'A', '01.mkv'), 200 * 1024);
      _patterned(p.join(tmp.path, 'B', '02.mkv'), 10);
      await _scan(db, await _source(db, tmp.path));
      int calls = 0;
      final VideoContentFullHashUpgrader upgrader =
          VideoContentFullHashUpgrader(
            db,
            fullHashOf: (String path) async {
              calls++;
              return computeVideoContentFullHash(path);
            },
          );
      upgrader
        ..request()
        ..request();
      expect(await upgrader.running, 1, reason: '只有 ≥128 KiB 的那个是采样指纹');
      expect(upgrader.running, isNull);
      expect(calls, 1, reason: '补的那一轮没有要升级的行，不再读盘');
      final Map<String, VideoContentFingerprintRow> all = await db
          .allVideoContentFingerprints();
      expect(
        all.values.map((VideoContentFingerprintRow r) => r.fingerprint),
        everyElement(startsWith('sha256:')),
      );
    });

    test('整文件哈希算的期间行被改指 / 指纹被重记：丢弃这份哈希，不写错行', () async {
      final FushiDatabase db = _memDb();
      addTearDown(db.close);
      final String aFile = p.join(tmp.path, 'A', '01.mkv');
      final String bFile = p.join(tmp.path, 'B', '02.mkv');
      _patterned(aFile, 200 * 1024);
      _patterned(bFile, 200 * 1024, middleFrom: 70000, middleTo: 90000);
      await _scan(db, await _source(db, tmp.path));
      final Map<String, VideoContentFingerprintRow> before = await db
          .allVideoContentFingerprints();
      expect(before.length, 2);
      // 算 01 的期间：扫描把 video/01 改指到别处；算 02 的期间：扫描重记了 02 的指纹。
      final int written = await upgradeVideoContentFingerprintsToFullHash(
        db,
        fullHashOf: (String path) async {
          final VideoContentFingerprint? full =
              await computeVideoContentFullHash(path);
          if (path == aFile) {
            await (db.update(db.videoBooks)
                  ..where(($VideoBooksTable t) => t.bookUid.equals('video/01')))
                .write(
                  VideoBooksCompanion(
                    videoPath: Value<String>(p.join(tmp.path, 'C', '01.mkv')),
                  ),
                );
          } else {
            await recordVideoContentFingerprint(
              db,
              'video/02',
              const VideoContentFingerprint(
                sizeBytes: 1,
                modifiedAtMs: 1,
                value: 'osh:0000000000000001',
              ),
            );
          }
          return full;
        },
      );
      expect(written, 0);
      final Map<String, VideoContentFingerprintRow> after = await db
          .allVideoContentFingerprints();
      expect(after['video/01']!.fingerprint, before['video/01']!.fingerprint);
      expect(after['video/02']!.fingerprint, 'osh:0000000000000001');
    });

    test('内容指纹：名单外的目录名连着两层撞上、内容不同——不改指', () async {
      final FushiDatabase db = _memDb();
      addTearDown(db.close);
      // `Batch/Remux` 不在通用名单里，旧判据会当成目录链证据。
      final String aFile = p.join(
        tmp.path,
        'ShowA',
        'Batch',
        'Remux',
        '01.mkv',
      );
      _video(aFile, fill: 1);
      final SourceLibraryRow source = await _source(db, tmp.path);
      await _scan(db, source);
      await _setProgress(db, 'video/01', 2024);

      Directory(p.join(tmp.path, 'ShowA')).deleteSync(recursive: true);
      final String bFile = p.join(
        tmp.path,
        'ShowB',
        'Batch',
        'Remux',
        '01.mkv',
      );
      _video(bFile, fill: 2);
      await _scan(db, source);

      final Map<String, VideoBookRow> rows = await _rowsByUid(db);
      expect(rows.keys.toSet(), <String>{'video/01', 'video/01 (2)'});
      expect(rows['video/01']!.videoPath, aFile, reason: 'A 行没被改指到 B 的文件');
      expect(rows['video/01']!.lastPositionMs, 2024);
    });

    test('内容指纹压过规格缓存与目录链：同尾段同大小但内容不同不算搬家', () async {
      final FushiDatabase db = _memDb();
      addTearDown(db.close);
      final String oldFile = p.join(tmp.path, 'old', 'Show', 'Arc', '01.mkv');
      _video(oldFile, bytes: 10, fill: 1);
      await _scan(db, await _source(db, p.join(tmp.path, 'old')));
      await _recordSpec(db, oldFile, 10);
      File(oldFile).deleteSync();

      final String newFile = p.join(tmp.path, 'new', 'Show', 'Arc', '01.mkv');
      _video(newFile, bytes: 10, fill: 2);
      await _scan(db, await _source(db, p.join(tmp.path, 'new')));

      final Map<String, VideoBookRow> rows = await _rowsByUid(db);
      expect(rows.keys.toSet(), <String>{'video/01', 'video/01 (2)'});
      expect(rows['video/01']!.videoPath, oldFile);
    });

    test('手动导入的行没有指纹：书架补算后搬家同样认得出', () async {
      final FushiDatabase db = _memDb();
      addTearDown(db.close);
      final String oldFile = p.join(tmp.path, 'manual', 'Inbox', '01.mkv');
      _video(oldFile, fill: 5);
      final VideoBookRepository repo = VideoBookRepository(db);
      await repo.saveVideoBook(
        VideoBooksCompanion(
          bookUid: const Value<String>('video/01'),
          title: const Value<String>('01'),
          videoPath: Value<String>(oldFile),
        ),
      );
      await _setProgress(db, 'video/01', 4500);
      expect(await db.allVideoContentFingerprints(), isEmpty);

      expect(await backfillVideoContentFingerprints(db), 1);
      expect(
        (await db.allVideoContentFingerprints())['video/01']?.fingerprint,
        startsWith('sha256:'),
        reason: '不足 128 KiB 整份 SHA-256',
      );

      final String newFile = p.join(tmp.path, 'lib', 'Sorted', '01.mkv');
      Directory(p.dirname(newFile)).createSync(recursive: true);
      File(oldFile).renameSync(newFile);
      await _scan(db, await _source(db, p.join(tmp.path, 'lib')));

      final Map<String, VideoBookRow> rows = await _rowsByUid(db);
      expect(rows.keys, <String>['video/01']);
      expect(rows['video/01']!.videoPath, newFile);
      expect(rows['video/01']!.lastPositionMs, 4500);
    });

    test('文件原地换掉：重扫复查到大小变了就重算指纹', () async {
      final FushiDatabase db = _memDb();
      addTearDown(db.close);
      final String file = p.join(tmp.path, 'Show', '01.mkv');
      _video(file, bytes: 10, fill: 1);
      final SourceLibraryRow source = await _source(db, tmp.path);
      await _scan(db, source);
      final String before =
          (await db.allVideoContentFingerprints())['video/01']!.fingerprint;

      _video(file, bytes: 20, fill: 2);
      await _scan(db, source);

      final VideoContentFingerprintRow after = (await db
          .allVideoContentFingerprints())['video/01']!;
      expect(after.fingerprint, isNot(before));
      expect(after.fileSizeBytes, 20);
    });

    test('computeVideoContentFingerprint：同内容同指纹，不是文件为 null', () async {
      final File a = _video(p.join(tmp.path, 'a.mkv'), bytes: 200 * 1024);
      final File b = _video(p.join(tmp.path, 'b.mkv'), bytes: 200 * 1024);
      final File c = _video(
        p.join(tmp.path, 'c.mkv'),
        bytes: 200 * 1024,
        fill: 9,
      );
      final VideoContentFingerprint fa = (await computeVideoContentFingerprint(
        a.path,
      ))!;
      final VideoContentFingerprint fb = (await computeVideoContentFingerprint(
        b.path,
      ))!;
      final VideoContentFingerprint fc = (await computeVideoContentFingerprint(
        c.path,
      ))!;
      expect(fa.value, fb.value);
      expect(fa.value, isNot(fc.value));
      expect(fa.sizeBytes, 200 * 1024);
      expect(
        await computeVideoContentFingerprint(p.join(tmp.path, 'missing.mkv')),
        isNull,
      );
      expect(await computeVideoContentFingerprint(tmp.path), isNull);
    });

    test('isGenericVideoDirectoryName：季 / 分盘 / 特典目录是通用名，作品名不是', () {
      for (final String name in <String>[
        'Season 01',
        'season1',
        'S01',
        's2',
        '第2季',
        '01',
        'Disc 1',
        'CD2',
        'Vol.3',
        'Specials',
        'Extras',
        'BDMV',
        'STREAM',
        '特典',
      ]) {
        expect(isGenericVideoDirectoryName(name), isTrue, reason: name);
      }
      for (final String name in <String>[
        'ShowA',
        'Show',
        'Steins;Gate 0',
        '[Group] Title S2 [1080p]',
        'Season 01 Extras Collection',
      ]) {
        expect(isGenericVideoDirectoryName(name), isFalse, reason: name);
      }
    });
  });

  group('系统 / 垃圾条目与读不了的子目录（BUG-4831）', () {
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
      // 与引擎卷归组 / 页图枚举共用一份判据后，macOS 压缩包残渣目录也算。
      expect(junk('Manga/__MACOSX/Vol1/001.jpg'), isTrue);

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

  group('远端书：单本失败隔离与临时目录（BUG-4835）', () {
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

  group('远端书：连接断了整轮结束（BUG-4835）', () {
    setUp(() {
      EpubStorage.debugBaseDirectoryOverride = p.join(tmp.path, 'bookroot');
      Directory(p.join(tmp.path, 'bookroot')).createSync();
      debugSourceScanTempRoot = Directory(p.join(tmp.path, 'scan_tmp'));
    });
    tearDown(() {
      EpubStorage.debugBaseDirectoryOverride = null;
    });

    // 逐本隔离只该隔离「这一本坏」。连接断了还逐本试，剩下的每本书都要各自等一次
    // 下载失败，期间来源锁一直占着。
    test('第一本下载失败后来源根也列不出来：不再碰后面的书，临时目录已删', () async {
      final FushiDatabase db = _memDb();
      addTearDown(db.close);
      final String fixture = p.join(tmp.path, 'fixture.epub');
      File(fixture).writeAsBytesSync(<int>[1, 2, 3]);
      final _RemoteBookFs fs = _RemoteBookFs(
        <String, String>{
          '/srv/books/a.epub': fixture,
          '/srv/books/b.epub': fixture,
          '/srv/books/c.epub': fixture,
        },
        failing: <String>{'/srv/books/a.epub'},
        dropsConnectionOnFailure: true,
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

      expect(fs.destDirs, hasLength(1), reason: '连接断了：b / c 不再各自下载一次');
      expect(Directory(fs.destDirs.single).existsSync(), isFalse);
      expect(summary.error, contains('connection reset'));
      expect(
        (await db.getMediaSourceById(source.id))!.lastScanError,
        contains('connection reset'),
      );
    });
  });

  group('被杀进程留下的残留（BUG-4835）', () {
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

    // 拍板台 design-nmv-fyi-tail ③：首页首帧的清扫不在任何来源锁里，以前只靠扫描入口
    // 传 keep 排除「自己正在扫的那条」，首帧后对残留行发起的重扫会被清扫删掉脚下的行。
    test('正被扫描（持有来源锁）的残留临时行不删，锁放开后的下一次清扫才删', () async {
      final FushiDatabase db = _memDb();
      addTearDown(db.close);
      final int stale = await db.insertMediaSource(
        MediaSourcesCompanion.insert(
          label: 'temp',
          mediaKind: 'video',
          rootPath: p.join(tmp.path, 'stale'),
          configJson: Value<String?>(oneShotSourceConfig(null)),
          createdAt: 1000,
        ),
      );
      final SourceScanActivity activity = SourceScanActivity();
      final Completer<void> scanning = Completer<void>();
      final Completer<void> release = Completer<void>();
      final Future<void> scan = activity.run<void>(stale, () async {
        scanning.complete();
        await release.future;
      });
      await scanning.future;

      expect(await sweepStaleOneShotSources(db, activity: activity), 0);
      expect(await db.getMediaSourceById(stale), isNotNull);

      release.complete();
      await scan;
      expect(await sweepStaleOneShotSources(db, activity: activity), 1);
      expect(await db.getMediaSourceById(stale), isNull);
    });

    test('扫描等锁期间来源行被删：拿到锁后不扫，返回 sourceRemoved', () async {
      final FushiDatabase db = _memDb();
      addTearDown(db.close);
      _video(p.join(tmp.path, 'gone', '01.mkv'));
      final SourceLibraryRow source = await _source(
        db,
        p.join(tmp.path, 'gone'),
      );
      final Completer<void> held = Completer<void>();
      final Completer<void> release = Completer<void>();
      final Future<void> holder = sourceScanActivity.run<void>(
        source.id,
        () async {
          held.complete();
          await release.future;
        },
      );
      await held.future;
      final Future<SourceScanSummary> waiting = _scan(db, source);
      await db.deleteMediaSource(source.id);
      release.complete();
      await holder;

      final SourceScanSummary summary = await waiting;
      expect(summary.blocked, SourceScanBlock.sourceRemoved);
      expect(summary.importedMediaCount, 0);
      expect(await _rowsByUid(db), isEmpty);
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
