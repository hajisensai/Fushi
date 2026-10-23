// DVD 入库（交接文档第一期第 2 项）：扫描器认出 `VIDEO_TS`，整张盘一个合集，盘内
// VOB 不再拆成散装条目；`VIDEO_TS` 之外的 `.vob` 照旧按普通视频。真 Drift 库 + 真
// 临时目录，盘是 `dvd_fixture.dart` 合成的最小 IFO。

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/source_library/source_file_system.dart';
import 'package:fushi/src/media/source_library/source_library_scanner.dart';
import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/source_library/source_library_row.dart';
import 'package:fushi_engine/media/video/dvd/dvd_disc.dart';
import 'package:fushi_engine/media/video/ffmpeg_backend.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi_engine/media/video/video_local_files.dart';
import 'package:path/path.dart' as p;

import '../video/dvd_fixture.dart';

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

SourceFileEntry _file(String path) =>
    SourceFileEntry(name: p.basename(path), path: path, isDirectory: false);

FushiDatabase _memDb() => FushiDatabase.forTesting(NativeDatabase.memory());

Future<SourceLibraryRow> _videoSource(FushiDatabase db, String root) async {
  final int id = await db.insertMediaSource(
    MediaSourcesCompanion.insert(
      label: 'Vids',
      mediaKind: 'video',
      rootPath: root,
      createdAt: 1000,
    ),
  );
  return (await db.getMediaSourceById(id))!;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('扫描规划认 DVD', () {
    final List<SourceFileEntry> discFiles = <SourceFileEntry>[
      _file('/lib/Show/VIDEO_TS/VIDEO_TS.IFO'),
      _file('/lib/Show/VIDEO_TS/VIDEO_TS.BUP'),
      _file('/lib/Show/VIDEO_TS/VIDEO_TS.VOB'),
      _file('/lib/Show/VIDEO_TS/VTS_01_0.IFO'),
      _file('/lib/Show/VIDEO_TS/VTS_01_1.VOB'),
      _file('/lib/Show/VIDEO_TS/VTS_01_2.VOB'),
      _file('/lib/Show/AUDIO_TS/.keep'),
    ];

    test('盘被认出来，VIDEO_TS 里的 VOB 不再各自成为散装视频', () {
      final ScanPlan plan = planScanFromFileList(
        discFiles,
        detectDvdDiscs: true,
      );
      expect(plan.dvdDiscs.map((ScanDvdDiscItem d) => d.discRootPath), <String>[
        p.normalize('/lib/Show'),
      ]);
      expect(plan.videos, isEmpty);
    });

    test('VIDEO_TS 之外的 .vob 照旧按普通视频', () {
      final ScanPlan plan = planScanFromFileList(<SourceFileEntry>[
        ...discFiles,
        _file('/lib/Show/extra.vob'),
        _file('/lib/rip/movie.vob'),
      ], detectDvdDiscs: true);
      expect(
        plan.videos.map((ScanVideoItem v) => p.basename(v.videoPath)),
        <String>['extra.vob', 'movie.vob'],
      );
      expect(plan.dvdDiscs, hasLength(1));
    });

    test('关掉盘识别（网络来源）时 VOB 退回散装视频', () {
      final ScanPlan plan = planScanFromFileList(discFiles);
      expect(plan.dvdDiscs, isEmpty);
      expect(plan.videos, hasLength(3));
    });

    test('没有 VIDEO_TS.IFO 的 VIDEO_TS 不算盘，也不吃掉里面的 VOB', () {
      final ScanPlan plan = planScanFromFileList(<SourceFileEntry>[
        _file('/lib/Broken/VIDEO_TS/VTS_01_1.VOB'),
      ], detectDvdDiscs: true);
      expect(plan.dvdDiscs, isEmpty);
      expect(plan.videos, hasLength(1));
    });
  });

  test('DVD 标题不给出「可删的本地文件」（成员路径是虚拟的）', () {
    expect(
      localVideoFileCandidates(
        videoPath: dvdTitlePath(p.normalize('/lib/Show'), 2),
      ),
      isEmpty,
    );
  });

  group('完整扫描入库', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('scan_dvd_');
      setFfmpegBackendForTesting(_NoFfmpeg());
      AppPaths.debugResetDocumentsLayoutCache();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (MethodCall call) async => switch (call.method) {
              'getApplicationDocumentsDirectory' => p.join(
                tmp.path,
                'documents',
              ),
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
      } catch (_) {}
    });

    Future<Map<String, List<String>>> membersByCollection(
      FushiDatabase db,
    ) async {
      final VideoBookRepository repo = VideoBookRepository(db);
      final Map<String, List<String>> result = <String, List<String>>{};
      for (final MediaCollectionRow c in await repo.getAllMediaCollections()) {
        if (c.collectionType != 'playlist') continue;
        result[c.name] = <String>[
          for (final MediaCollectionItemRow item
              in await repo.getCollectionItems(c.id))
            if (await repo.getByBookUid(item.entryKey)
                case final VideoBookRow row)
              p.normalize(row.videoPath),
        ];
      }
      return result;
    }

    test('一张盘一个合集，成员是入选 title；VOB 不入库；重扫幂等', () async {
      final FushiDatabase db = _memDb();
      addTearDown(db.close);
      final String disc = p.join(tmp.path, 'Show Vol.1');
      writeTvDvdFixture(disc);

      final SourceLibraryScanner scanner = SourceLibraryScanner(db);
      final SourceScanSummary first = await scanner.scan(
        await _videoSource(db, tmp.path),
      );
      expect(first.succeeded, isTrue, reason: first.error ?? '');

      final Map<String, List<String>> members = await membersByCollection(db);
      expect(members.keys, <String>['Show Vol.1']);
      expect(members['Show Vol.1'], <String>[
        for (final int n in <int>[2, 3, 4, 5])
          p.normalize(dvdTitlePath(disc, n)),
      ]);
      final List<VideoBookRow> all = await VideoBookRepository(db).listAll();
      expect(
        all.where(
          (VideoBookRow r) => r.videoPath.toLowerCase().endsWith('.vob'),
        ),
        isEmpty,
      );
      expect(all, hasLength(4));

      final SourceScanSummary second = await scanner.scan(
        await _videoSource(db, tmp.path),
      );
      expect(second.succeeded, isTrue, reason: second.error ?? '');
      expect(await membersByCollection(db), members);
      expect(await VideoBookRepository(db).listAll(), hasLength(4));
    });

    test('IFO 全坏的盘明确报错，其它盘照常入库', () async {
      final FushiDatabase db = _memDb();
      addTearDown(db.close);
      writeTvDvdFixture(p.join(tmp.path, 'Good'));
      final String bad = p.join(tmp.path, 'Bad');
      writeTvDvdFixture(bad);
      for (final String name in <String>['VIDEO_TS.IFO', 'VIDEO_TS.BUP']) {
        File(p.join(bad, 'VIDEO_TS', name)).writeAsBytesSync(Uint8List(64));
      }
      final SourceScanSummary summary = await SourceLibraryScanner(
        db,
      ).scan(await _videoSource(db, tmp.path));
      expect(summary.error, contains('DVD'));
      expect(summary.error, contains('Bad'));
      expect((await membersByCollection(db)).keys, <String>['Good']);
    });
  });
}
