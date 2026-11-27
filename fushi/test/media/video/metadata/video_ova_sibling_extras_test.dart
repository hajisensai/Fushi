import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/source_library/add_local_folder_source.dart';
import 'package:fushi/src/media/source_library/source_library_scanner.dart';
import 'package:fushi/src/media/video/metadata/video_local_index_rebuild.dart';
import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/source_library/source_library_row.dart';
import 'package:fushi_engine/media/video/ffmpeg_backend.dart';
import 'package:path/path.dart' as p;

import '../../../helpers/engine_storage_sandbox.dart';

class _NoFfmpeg implements FfmpegBackend {
  @override
  Future<FfmpegRunResult> runQuery(List<String> args, Duration timeout) =>
      run(args, timeout);

  @override
  Future<FfmpegRunResult> run(List<String> args, Duration timeout) async =>
      const FfmpegRunResult(returnCode: 1, output: 'stub');

  @override
  Future<FfmpegRunResult> runProbe(List<String> args, Duration timeout) async =>
      const FfmpegRunResult(returnCode: 1, output: 'stub');
}

/// 反馈 yMd0aT-fLN 的样本目录（附件 f0）：VCB-Studio「To LOVE-Ru」BD 合集。与
/// BUG-5418 夹具的结构差异：根目录里正片 26 集之外还并排着 OVA01～06（集号写成
/// `[OVA01]`），每集都带 `.nfo`，`SPs\` 里是 13 个 NCOP / NCED / Menu，另有 CDs / Scans。
const String _show = '[VCB-Studio] To LOVE-Ru [Ma10p_1080p]';

void _touch(String path) {
  File(path)
    ..createSync(recursive: true)
    ..writeAsBytesSync(const <int>[0]);
}

void _writeRelease(String show) {
  for (int i = 1; i <= 26; i++) {
    final String n = i.toString().padLeft(2, '0');
    final String codec =
        const <int>{1, 3, 8, 11, 12, 16, 18, 21, 26}.contains(i)
        ? 'x265_flac_aac'
        : 'x265_flac';
    final String stem = '[VCB-Studio] To LOVE-Ru [$n][Ma10p_1080p][$codec]';
    _touch(p.join(show, '$stem.mkv'));
    _touch(p.join(show, '$stem.nfo'));
    _touch(p.join(show, '$stem.jpg'));
    _touch(p.join(show, '$stem.srt'));
  }
  for (int i = 1; i <= 6; i++) {
    final String stem =
        '[VCB-Studio] To LOVE-Ru [OVA0$i][Ma10p_1080p][x265_flac]';
    _touch(p.join(show, '$stem.mkv'));
    _touch(p.join(show, '$stem.nfo'));
    _touch(p.join(show, '$stem-poster.jpg'));
  }
  for (final String marker in <String>[
    'Menu01',
    'Menu02',
    'Menu03',
    'Menu04',
    'Menu05',
    'NCED01',
    'NCED02',
    'NCED03',
    'NCED04',
    'NCED05',
    'NCED06',
    'NCOP01',
    'NCOP02',
  ]) {
    _touch(
      p.join(
        show,
        'SPs',
        '[VCB-Studio] To LOVE-Ru [$marker][Ma10p_1080p][x265_flac].mkv',
      ),
    );
  }
  _touch(
    p.join(
      show,
      'CDs',
      '[080725] Original Soundtrack 1 (flac)',
      'GNCA-1190.flac',
    ),
  );
  _touch(p.join(show, 'Scans', 'BK_01.webp'));
}

/// 与 app 开库同口径打开外键：临时来源行删掉后 `video_books.source_id` 靠 FK setNull
/// 归 NULL，视频才落进无来源范围。
FushiDatabase _openDb() => FushiDatabase.forTesting(
  NativeDatabase.memory(
    setup: (dynamic rawDb) => rawDb.execute('PRAGMA foreign_keys = ON'),
  ),
);

bool _isExtraFile(String path) => p.basename(p.dirname(path)) == 'SPs';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  useEngineStorageSandbox();

  late Directory tmp;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('ova_extras_');
    setFfmpegBackendForTesting(_NoFfmpeg());
    AppPaths.debugResetDocumentsLayoutCache();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (MethodCall call) async => switch (call.method) {
            'getApplicationDocumentsDirectory' => p.join(tmp.path, 'documents'),
            'getTemporaryDirectory' => p.join(tmp.path, 'systemp'),
            'getApplicationSupportDirectory' => p.join(tmp.path, 'support'),
            _ => null,
          },
        );
  });
  tearDown(() {
    setFfmpegBackendForTesting(null);
    AppPaths.debugResetDocumentsLayoutCache();
    try {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows 上句柄可能还没放开；临时目录残留不影响结论。
    }
  });

  /// 断言：`SPs` 的 13 个特典全部挂到正片所在的那部作品下（系列墙因此不再把它们
  /// 各自列成卡），正片与 OVA 自身不被当成特典。
  Future<void> expectExtrasBound(FushiDatabase db) async {
    final List<VideoBookRow> books = await db.allVideoBooks();
    expect(
      books.where((VideoBookRow b) => _isExtraFile(b.videoPath)),
      hasLength(13),
    );
    final VideoBookRow episode1 = books.firstWhere(
      (VideoBookRow b) => p.basename(b.videoPath).contains('[01]'),
    );
    final MediaCollectionItemRow? item = (await db.getAllCollectionItems())
        .where((MediaCollectionItemRow i) => i.entryKey == episode1.bookUid)
        .firstOrNull;
    expect(item, isNotNull, reason: '正片没进合集');
    final VideoMetadataWorkRow? work = await db
        .getVideoMetadataWorkByCollection(item!.collectionId);
    expect(work, isNotNull, reason: '正片合集没有规范作品');
    for (final VideoBookRow book in books) {
      final VideoMetadataExtraRow? extra = await db.getVideoMetadataExtraByBook(
        book.bookUid,
      );
      if (_isExtraFile(book.videoPath)) {
        expect(
          extra?.workId,
          work!.id,
          reason: '${p.basename(book.videoPath)} 没挂到正片作品下',
        );
      } else {
        expect(extra, isNull, reason: '${p.basename(book.videoPath)} 不是特典');
      }
    }
  }

  test('导入文件夹（仅此一次）：根目录并排 OVA 时 SPs 特典仍挂到正片作品下', () async {
    final FushiDatabase db = _openDb();
    addTearDown(db.close);
    final String show = p.join(
      tmp.path,
      'Anime',
      '[VCB-Studio] To LOVE-Ru',
      _show,
    );
    _writeRelease(show);

    final SourceScanSummary? summary = await importLocalFolderOnceAt(
      db: db,
      transcribeAudiobook: null,
      mediaKind: 'video',
      path: p.dirname(show),
    );

    expect(summary?.error, isNull);
    await expectExtrasBound(db);
  });

  test('常驻来源：根目录并排 OVA 时 SPs 特典仍挂到正片作品下', () async {
    final FushiDatabase db = _openDb();
    addTearDown(db.close);
    final String show = p.join(
      tmp.path,
      'Anime',
      '[VCB-Studio] To LOVE-Ru',
      _show,
    );
    _writeRelease(show);
    final int id = await db.insertMediaSource(
      MediaSourcesCompanion.insert(
        label: 'Anime',
        mediaKind: 'video',
        rootPath: p.join(tmp.path, 'Anime'),
        createdAt: 1000,
      ),
    );
    final SourceLibraryRow source = (await db.getMediaSourceById(id))!;

    await SourceLibraryScanner(db, transcribeAudiobook: null).scan(source);

    await expectExtrasBound(db);
  });

  test('同一层两部剧集作品：特典仍判二义、不随便挂到其中一部', () async {
    final FushiDatabase db = _openDb();
    addTearDown(db.close);
    final String root = p.join(tmp.path, 'Anime', 'Mixed');
    for (final String show in <String>['Alpha Show', 'Beta Show']) {
      for (int i = 1; i <= 3; i++) {
        _touch(p.join(root, '[Grp] $show [0$i][1080p].mkv'));
      }
    }
    final String ncop = p.join(
      root,
      'SPs',
      '[Grp] Alpha Show [NCOP][1080p].mkv',
    );
    _touch(ncop);
    final int id = await db.insertMediaSource(
      MediaSourcesCompanion.insert(
        label: 'Anime',
        mediaKind: 'video',
        rootPath: p.join(tmp.path, 'Anime'),
        createdAt: 1000,
      ),
    );
    final SourceLibraryRow source = (await db.getMediaSourceById(id))!;

    await SourceLibraryScanner(db, transcribeAudiobook: null).scan(source);

    final Set<int> episodicWorks = <int>{
      for (final MediaCollectionRow c in await db.getAllMediaCollections())
        if ((await db.getVideoMetadataWorkByCollection(c.id))
            case final VideoMetadataWorkRow w)
          w.id,
    };
    expect(episodicWorks, hasLength(2), reason: '夹具前提：两部剧集作品同根');
    final VideoBookRow extra = (await db.allVideoBooks()).firstWhere(
      (VideoBookRow b) => p.equals(b.videoPath, ncop),
    );
    expect(await db.getVideoMetadataExtraByBook(extra.bookUid), isNull);
  });
}
