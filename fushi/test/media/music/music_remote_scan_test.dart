// 反馈 QAondMh4M5：SFTP / WebDAV / AList 音乐来源经来源访问层列目录、按区间取字节，
// 分类 / CUE / 标签 / uid 在 Rust 远程游标里——经真原生库扫 native/fushi_music 的 fixture
// 曲库（与 Rust golden 同一份样本），远程地址 `https://dav.test/m/…`。
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/music_library_scanner.dart';
import 'package:fushi/src/media/source_library/source_file_system.dart';
import 'package:fushi/src/media/source_library/source_library_scanner.dart';
import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/source_library/source_library_row.dart';
import 'package:path/path.dart' as p;

const String _root = 'https://dav.test/m';

String _fixtureLibrary() {
  Directory dir = Directory.current.absolute;
  for (int i = 0; i < 6; i++) {
    final Directory c = Directory(
      p.join(dir.path, 'native', 'fushi_music', 'tests', 'fixtures', 'library'),
    );
    if (c.existsSync()) return c.path;
    dir = dir.parent;
  }
  throw StateError('fixture library not found from ${Directory.current.path}');
}

/// 把本地 fixture 目录摊成远程来源：条目地址 `$_root/<相对路径>`（正斜杠、解码态，与
/// WebDAV 真实实现给出的形状一致），字节按区间从本地文件读。
class _FixtureRemoteFs implements SourceFileSystem, SourceByteReader {
  _FixtureRemoteFs(String localRoot) {
    for (final FileSystemEntity e in Directory(
      localRoot,
    ).listSync(recursive: true)) {
      if (e is! File) continue;
      final String rel = p
          .relative(e.path, from: localRoot)
          .replaceAll(r'\', '/');
      files['$_root/$rel'] = e.path;
    }
  }

  /// 远程地址 → 本地文件。
  final Map<String, String> files = <String, String>{};
  int rangeReads = 0;
  final List<String> bytesReads = <String>[];
  bool failRanges = false;

  @override
  bool get isLocal => false;

  @override
  Future<List<SourceFileEntry>> listFiles(
    String dirPath, {
    bool recursive = false,
  }) async => <SourceFileEntry>[
    for (final MapEntry<String, String> f in files.entries)
      SourceFileEntry(
        name: f.key.substring(f.key.lastIndexOf('/') + 1),
        path: f.key,
        isDirectory: false,
        sizeBytes: File(f.value).lengthSync(),
        modifiedAt: File(f.value).lastModifiedSync().millisecondsSinceEpoch,
      ),
  ];

  @override
  Future<Uint8List> readRange(String filePath, int offset, int length) async {
    rangeReads++;
    if (failRanges) throw const SocketException('network is down');
    final Uint8List all = File(files[filePath]!).readAsBytesSync();
    if (offset >= all.length) return Uint8List(0);
    final int end = (offset + length).clamp(0, all.length);
    return Uint8List.sublistView(all, offset, end);
  }

  @override
  Future<Uint8List> readBytes(String filePath) async {
    bytesReads.add(filePath);
    return File(files[filePath]!).readAsBytesSync();
  }

  @override
  Future<List<String>> listSiblingNames(String filePath) async =>
      const <String>[];

  @override
  Future<String> readText(String filePath) => throw UnimplementedError();

  @override
  Future<String> copyToLocal(String filePath, String destDir) =>
      throw UnimplementedError();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FushiDatabase db;
  late Directory covers;
  late _FixtureRemoteFs fs;
  late int sourceId;

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    covers = Directory.systemTemp.createTempSync('music_remote_covers_');
    // 经 SourceLibraryScanner 的路径用默认封面目录（AppPaths 文档根）。
    AppPaths.debugResetDocumentsLayoutCache();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (MethodCall call) async => switch (call.method) {
            'getApplicationDocumentsDirectory' => p.join(covers.path, 'docs'),
            'getTemporaryDirectory' => p.join(covers.path, 'tmp'),
            'getApplicationSupportDirectory' => p.join(covers.path, 'support'),
            _ => null,
          },
        );
    fs = _FixtureRemoteFs(_fixtureLibrary());
    sourceId = await db.insertMediaSource(
      MediaSourcesCompanion.insert(
        label: 'NAS music',
        mediaKind: 'music',
        transport: const Value<String>('webdav'),
        rootPath: _root,
        createdAt: 1,
      ),
    );
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    AppPaths.debugResetDocumentsLayoutCache();
    await db.close();
    covers.deleteSync(recursive: true);
  });

  MusicLibraryScanner scanner() =>
      MusicLibraryScanner(db, coverDirectory: () async => covers);

  Future<MusicScanSummary> scan() async => scanner().scanRemoteSource(
    sourceId: sourceId,
    rootPath: _root,
    entries: await fs.listFiles(_root, recursive: true),
    bytes: fs,
  );

  test('remote tracks land in the same table with tags, CUE splits and '
      'a cached folder cover', () async {
    final MusicScanSummary summary = await scan();
    expect(summary.errors, isEmpty);
    final List<MusicTrackRow> tracks = await db.listMusicTracks();
    // 与 Rust golden 同 11 首（隐藏文件跳过、Shift_JIS CUE 拆 3 首、内嵌 CUESHEET 拆 2 首）。
    expect(tracks, hasLength(11));
    expect(
      tracks.every((MusicTrackRow t) => t.path.startsWith('$_root/')),
      isTrue,
    );
    expect(tracks.every((MusicTrackRow t) => t.sourceId == sourceId), isTrue);
    expect(
      tracks.map((MusicTrackRow t) => t.title),
      containsAll(<String>['First Song', '夜に駆ける', '二曲目', 'Inner Two']),
      reason: 'CUE bytes are handed over raw; Rust decodes Shift_JIS itself',
    );
    // 远程文件之后读不了内嵌封面：不留 hasEmbeddedCover。
    expect(tracks.any((MusicTrackRow t) => t.hasEmbeddedCover), isFalse);

    final MusicAlbumRow albumA = (await db.listMusicAlbums()).singleWhere(
      (MusicAlbumRow a) => a.title == 'Album A',
    );
    final String cover = albumA.coverPath!;
    expect(p.isWithin(covers.path, cover), isTrue, reason: cover);
    expect(
      File(cover).readAsBytesSync(),
      File(fs.files['$_root/Album A/cover.png']!).readAsBytesSync(),
    );
    expect(fs.bytesReads, contains('$_root/Cue Album/full.cue'));
  });

  test('a rescan with unchanged files fetches no bytes; a vanished file is '
      'soft-deleted, the rest stay', () async {
    await scan();
    fs.rangeReads = 0;
    final MusicScanSummary again = await scan();
    expect(again.parsedTrackCount, 0);
    expect(again.trackCount, 11);
    expect(fs.rangeReads, 0);

    fs.files.remove('$_root/Album A/02 Second Song.mp3');
    final MusicScanSummary third = await scan();
    expect(third.removedTrackCount, 1);
    expect(await db.listMusicTracks(), hasLength(10));
  });

  test(
    'a network failure aborts the scan without soft-deleting anything',
    () async {
      await scan();
      // 文件都「变了」：要重新取字节，此时断网。
      for (final MapEntry<String, String> f in fs.files.entries) {
        File(f.value).setLastModifiedSync(DateTime.now());
      }
      fs.failRanges = true;
      await expectLater(scan(), throwsA(isA<SocketException>()));
      expect(await db.listMusicTracks(), hasLength(11));
    },
  );

  testWidgets('SourceLibraryScanner routes a WebDAV music source to the remote '
      'scan and records the count; FTP is refused', (
    WidgetTester tester,
  ) async {
    final SourceLibraryRow source = (await db.getMediaSourceById(sourceId))!;
    late SourceScanSummary summary;
    await tester.runAsync(() async {
      summary = await SourceLibraryScanner(db).scan(source, fs: fs);
    });
    expect(summary.error, isNull);
    expect(summary.importedMediaCount, 11);

    final int ftpId = await db.insertMediaSource(
      MediaSourcesCompanion.insert(
        label: 'FTP music',
        mediaKind: 'music',
        transport: const Value<String>('ftp'),
        rootPath: '/music',
        createdAt: 1,
      ),
    );
    late SourceScanSummary ftp;
    await tester.runAsync(() async {
      ftp = await SourceLibraryScanner(
        db,
      ).scan((await db.getMediaSourceById(ftpId))!);
    });
    expect(ftp.error, contains('SFTP/WebDAV/AList'));
  });
}
