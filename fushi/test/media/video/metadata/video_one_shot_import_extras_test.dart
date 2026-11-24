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

const String _show = '[Nekomoe kissaten] Tonikaku Kawaii [BDRip]';
const String _tag = '[BDRip 1080p HEVC-10bit FLAC]';

void _writeRelease(String show) {
  void touch(String path) {
    File(path)
      ..createSync(recursive: true)
      ..writeAsBytesSync(const <int>[0]);
  }

  for (int i = 1; i <= 13; i++) {
    final String n = i.toString().padLeft(2, '0');
    touch(p.join(show, '[Nekomoe kissaten] Tonikaku Kawaii [$n]$_tag.mkv'));
    touch(
      p.join(
        show,
        'Subs',
        '[Nekomoe kissaten] Tonikaku Kawaii [$n]$_tag.JPSC.ass',
      ),
    );
  }
  for (final String marker in <String>[
    '[CM]',
    '[NCED]',
    '[NCOP]',
    '[PV][01]',
    '[PV][02]',
    '[PV][03]',
    '[PV][04]',
    '[PV][05]',
    '[PV][06]',
    'OVA [PV][01]',
    'OVA [PV][02]',
  ]) {
    final String stem = '[Nekomoe kissaten] Tonikaku Kawaii $marker$_tag';
    touch(p.join(show, 'SPs', '$stem.mkv'));
    touch(p.join(show, 'SPs', '$stem.JPSC.ass'));
  }
  touch(
    p.join(
      show,
      'Menus',
      '[Nekomoe kissaten] Tonikaku Kawaii [Menu][01][BDRip 1080p HEVC-10bit].mkv',
    ),
  );
  touch(
    p.join(
      show,
      'Menus',
      '[Nekomoe kissaten] Tonikaku Kawaii [Menu][02][BDRip 1080p HEVC-10bit].mkv',
    ),
  );
  touch(p.join(show, 'Music', 'OPED', '01. OP.flac'));
  touch(p.join(show, 'Scans', '01.jpg'));
}

/// 与 app 开库同口径打开外键：临时来源行删掉后 `video_books.source_id` 靠 FK setNull
/// 归 NULL，视频才落进无来源范围。
FushiDatabase _openDb() => FushiDatabase.forTesting(
  NativeDatabase.memory(
    setup: (dynamic rawDb) => rawDb.execute('PRAGMA foreign_keys = ON'),
  ),
);

/// 反馈 aBGenWuGns 样本目录里 `SPs\` 与 `Menus\` 下的特典（11 + 2）。
bool _isExtraFile(String path) {
  final String dir = p.basename(p.dirname(path));
  return dir == 'SPs' || dir == 'Menus';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  useEngineStorageSandbox();

  late Directory tmp;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('one_shot_extras_');
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

  /// 断言：正片 13 集进同一合集、挂着同一部规范作品；`SPs` / `Menus` 的 13 个特典
  /// 全部挂到这部作品下（而不是在系列墙上各自成卡），正片自身不被当成特典。
  Future<void> expectExtrasBound(FushiDatabase db) async {
    final List<VideoBookRow> books = await db.allVideoBooks();
    expect(books, hasLength(26));
    final List<MediaCollectionRow> collections = await db
        .getAllMediaCollections();
    expect(collections, hasLength(1));
    final VideoMetadataWorkRow? work = await db
        .getVideoMetadataWorkByCollection(collections.single.id);
    expect(work, isNotNull, reason: '正片合集没有规范作品');
    int extras = 0;
    for (final VideoBookRow book in books) {
      final VideoMetadataExtraRow? extra = await db.getVideoMetadataExtraByBook(
        book.bookUid,
      );
      if (_isExtraFile(book.videoPath)) {
        extras++;
        expect(
          extra?.workId,
          work!.id,
          reason: '${p.basename(book.videoPath)} 没挂到作品下',
        );
      } else {
        expect(extra, isNull, reason: '${p.basename(book.videoPath)} 是正片');
      }
    }
    expect(extras, 13);
  }

  test('导入文件夹（仅此一次）：SPs / Menus 特典挂到正片作品下（BUG-5418）', () async {
    final FushiDatabase db = _openDb();
    addTearDown(db.close);
    final String show = p.join(tmp.path, 'Anime', _show);
    _writeRelease(show);

    final SourceScanSummary? summary = await importLocalFolderOnceAt(
      db: db,
      transcribeAudiobook: null,
      mediaKind: 'video',
      path: show,
    );

    expect(summary?.error, isNull);
    expect(await db.getMediaSourcesByKind('video'), isEmpty);
    for (final VideoBookRow book in await db.allVideoBooks()) {
      expect(book.sourceId, isNull);
    }
    await expectExtrasBound(db);
  });

  test('启动回填覆盖无来源范围：修前一次性导入、没有作品的库也补上绑定', () async {
    final FushiDatabase db = _openDb();
    addTearDown(db.close);
    final String show = p.join(tmp.path, 'Anime', _show);
    _writeRelease(show);
    await importLocalFolderOnceAt(
      db: db,
      transcribeAudiobook: null,
      mediaKind: 'video',
      path: show,
    );
    // 修前状态：无来源视频从没被本地索引过，没有作品、没有特典绑定（FK 级联删 extras）。
    await db.customStatement('DELETE FROM video_metadata_works');
    expect(
      await db.getVideoMetadataExtraByBook(
        (await db.allVideoBooks())
            .firstWhere((VideoBookRow b) => _isExtraFile(b.videoPath))
            .bookUid,
      ),
      isNull,
    );

    final bool changed = await reindexLocalVideoSources(
      db,
      logSource: 'test.reindex',
    );

    expect(changed, isTrue);
    await expectExtrasBound(db);
    // 幂等：什么都没变时零写入。
    expect(
      await reindexLocalVideoSources(db, logSource: 'test.reindex'),
      isFalse,
    );
  });

  test('常驻来源对照：同一目录登记成来源扫描，特典照常挂到作品下', () async {
    final FushiDatabase db = _openDb();
    addTearDown(db.close);
    final String show = p.join(tmp.path, 'Anime', _show);
    _writeRelease(show);
    final int id = await db.insertMediaSource(
      MediaSourcesCompanion.insert(
        label: 'Anime',
        mediaKind: 'video',
        rootPath: show,
        createdAt: 1000,
      ),
    );
    final SourceLibraryRow source = (await db.getMediaSourceById(id))!;

    await SourceLibraryScanner(db, transcribeAudiobook: null).scan(source);

    await expectExtrasBound(db);
  });
}
