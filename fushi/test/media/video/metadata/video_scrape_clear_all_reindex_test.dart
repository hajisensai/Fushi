// BUG-5354（反馈 fUW6_kx9Rw）：「清除全部刮削记录」删掉全部规范作品，本地特典
// 绑定（video_metadata_extras）随外键级联一起没了；修前没人立刻重建，`SPs\` 子目录
// 里的 NCOP / NCED / CM / PV 在系列墙上各自成卡，要等下次启动回填或重扫才归回系列。
// 这里用真 Drift 库 + 真临时目录铺出用户的发布组目录，走完整条「扫描 → 清除」，
// 钉住清除提交后特典立刻挂回正片作品。

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/source_library/source_library_scanner.dart';
import 'package:fushi/src/media/video/metadata/video_scrape_cleanup_action.dart';
import 'package:fushi/src/media/video/metadata/video_scrape_cleanup_service.dart';
import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/source_library/source_library_row.dart';
import 'package:fushi_engine/media/video/ffmpeg_backend.dart';
import 'package:path/path.dart' as p;

import '../../../helpers/engine_storage_sandbox.dart';

/// 立刻失败的 ffmpeg 后端：扫描不该真起 ffmpeg 抽封面。
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

/// 用户反馈里的目录：正片 01-12 在作品根，特典在 `SPs\`，另有 Menus / Music / Scans。
void _writeRelease(String show) {
  void touch(String path) {
    File(path)
      ..createSync(recursive: true)
      ..writeAsBytesSync(const <int>[0]);
  }

  for (int i = 1; i <= 12; i++) {
    final String n = i.toString().padLeft(2, '0');
    touch(p.join(show, '[Nekomoe kissaten] Tonikaku Kawaii [$n]$_tag.mkv'));
    touch(p.join(show, '[Nekomoe kissaten] Tonikaku Kawaii [$n]$_tag.jpg'));
  }
  for (final String marker in <String>[
    '[CM]',
    '[NCED]',
    '[NCOP]',
    '[PV][01]',
    '[PV][02]',
    'OVA [PV][01]',
  ]) {
    final String stem = '[Nekomoe kissaten] Tonikaku Kawaii $marker$_tag';
    touch(p.join(show, 'SPs', '$stem.mkv'));
    touch(p.join(show, 'SPs', '$stem.JPSC.ass'));
  }
  touch(p.join(show, 'Music', 'OPED', '01. OP.flac'));
  touch(p.join(show, 'Scans', '01.jpg'));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  useEngineStorageSandbox();

  late Directory tmp;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('clear_all_reindex_');
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
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    AppPaths.debugResetDocumentsLayoutCache();
    try {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows 偶有句柄未放：临时目录留给系统清理。
    }
  });

  /// SPs 里每个特典视频 → 它挂在哪个作品下（null = 没挂）。
  Future<Map<String, int?>> spsExtraWorks(FushiDatabase db) async {
    final Map<String, int?> result = <String, int?>{};
    for (final VideoBookRow book in await db.allVideoBooks()) {
      if (p.basename(p.dirname(book.videoPath)) != 'SPs') continue;
      result[p.basename(book.videoPath)] =
          (await db.getVideoMetadataExtraByBook(book.bookUid))?.workId;
    }
    return result;
  }

  for (final VideoScrapeCleanupMode mode in VideoScrapeCleanupMode.values) {
    test('清除全部刮削记录（${mode.name}）后，SPs 子目录特典立刻挂回正片作品', () async {
      final FushiDatabase db = FushiDatabase.forTesting(
        NativeDatabase.memory(),
      );
      addTearDown(db.close);
      final String libRoot = p.join(tmp.path, 'Anime');
      _writeRelease(p.join(libRoot, _show));
      final int id = await db.insertMediaSource(
        MediaSourcesCompanion.insert(
          label: 'Anime',
          mediaKind: 'video',
          rootPath: libRoot,
          createdAt: 1000,
        ),
      );
      final SourceLibraryRow source = (await db.getMediaSourceById(id))!;
      final SourceScanSummary scan = await SourceLibraryScanner(
        db,
        transcribeAudiobook: null,
      ).scan(source);
      expect(scan.succeeded, isTrue, reason: scan.error ?? '');

      // 扫描后的本地索引：12 集归成一个合集作品，6 个特典都挂在它下面。
      final MediaCollectionRow collection =
          (await db.getAllMediaCollections()).single;
      final int workBefore = (await db.getVideoMetadataWorkByCollection(
        collection.id,
      ))!.id;
      final Map<String, int?> before = await spsExtraWorks(db);
      expect(before, hasLength(6));
      expect(before.values.toSet(), <int?>{workBefore});

      await clearAllVideoScrapeRecords(db, mode: mode);

      final VideoMetadataWorkRow? workAfter = await db
          .getVideoMetadataWorkByCollection(collection.id);
      expect(workAfter, isNotNull, reason: '本地作品要随清除立刻重建，不等下次启动');
      final Map<String, int?> after = await spsExtraWorks(db);
      expect(after, hasLength(6));
      expect(after.values.toSet(), <int?>{
        workAfter!.id,
      }, reason: '特典绑定随作品级联删除后必须立刻重建，否则系列墙上各自成卡');
      // 重建的只是本地索引（启动回填同一条路径）：资料行全部是本地来源。
      expect(
        (await db.getAllVideoScrapeMeta())
            .map((VideoScrapeMetaRow r) => r.source)
            .toSet(),
        <String>{'local'},
      );
    });
  }
}
