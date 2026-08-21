/// 互联视频 live push 外挂字幕同步（BUG-964）守卫。
///
/// 覆盖整条上传链：
/// 1. 纯函数 [listSidecarSubtitles] / [isSidecarSubtitleSuffix] 的匹配与白名单规则。
/// 2. host [AppModelLibraryHostService.importVideoSubtitle]：sidecar 落视频同目录
///    `<stem><suffix>`、行语义镜像下载路径（subtitleSource/format、内嵌轨置 null、
///    cue 落库）、未知视频/非法后缀拒收。
/// 3. 端到端（真实 server/host/client/orchestrator）：视频与其全部 sidecar 一并
///    推送、重复 sweep 幂等、host 已有视频缺字幕时只补推字幕不重传视频。
/// 4. 老 host 无字幕端点（404/405）：client 返回 false 优雅降级，不抛异常。
library;

import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_sidecar.dart';
import 'package:fushi/src/sync/app_model_library_host_service.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi/src/sync/fushi_library_host_service.dart';
import 'package:fushi/src/sync/fushi_sync_server.dart';
import 'package:fushi/src/sync/sync_asset_package_service.dart';
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/src/sync/sync_orchestrator.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

const String _srtContent = '1\n'
    '00:00:01,000 --> 00:00:02,000\n'
    'こんにちは\n'
    '\n'
    '2\n'
    '00:00:03,000 --> 00:00:04,000\n'
    'さようなら\n';

FushiDatabase _memDb() =>
    FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));

AppModelLibraryHostService _hostService({
  required FushiDatabase db,
  required Directory work,
  Directory? uploads,
}) =>
    AppModelLibraryHostService(
      db: db,
      dictionaryResourceRoot: work,
      packages: SyncAssetPackageService(db: db),
      refreshDictionaryCache: () async {},
      runExclusive: (Future<void> Function() body) => body(),
      uploadedVideoRoot: uploads,
      videoSubtitleLangCode: 'ja',
    );

Future<InterconnectSyncBackend> _clientBackend({
  required String base,
  required String token,
}) async {
  final FushiDatabase db = _memDb();
  final SyncRepository repo = SyncRepository(db);
  await repo.setFushiClientUrls(<FushiClientUrl>[
    FushiClientUrl(url: base, enabled: true),
  ]);
  await repo.setFushiClientToken(token);
  final InterconnectSyncBackend backend =
      InterconnectSyncBackend.withProbe((String u, String t) async => true);
  await backend.restoreAuth(repo);
  await backend.authenticate(repo: repo);
  return backend;
}

SyncOrchestrator _orchestrator({
  required FushiDatabase db,
  required SyncBackend backend,
  required Directory tmp,
}) =>
    SyncOrchestrator(
      db: db,
      backend: backend,
      dictionaryResourceRoot: tmp,
      audioDatabaseRoot: tmp,
      tempDir: tmp,
      syncStats: false,
      syncAudioBookPosition: false,
      syncContent: false,
      syncAudioBookFiles: false,
      syncVideoFiles: true,
      syncDictionary: false,
    );

void main() {
  group('sidecar 纯函数', () {
    test('listSidecarSubtitles 匹配同 stem 的全部字幕（含语言标记，忽略大小写）', () {
      final List<String> files = <String>[
        'Movie.mkv',
        'movie.srt',
        'Movie.ja.ASS',
        'movie.zh-Hans.vtt',
        'movie2.srt', // 别的 stem
        'movie.txt', // 非字幕扩展
        'movie.mkv.bak', // 非字幕扩展
      ];
      expect(listSidecarSubtitles('Movie', files),
          <String>['movie.srt', 'Movie.ja.ASS', 'movie.zh-Hans.vtt']);
      expect(listSidecarSubtitles('other', files), isEmpty);
    });

    test('isSidecarSubtitleSuffix 白名单：拒路径穿越与陌生扩展', () {
      expect(isSidecarSubtitleSuffix('.srt'), isTrue);
      expect(isSidecarSubtitleSuffix('.ja.srt'), isTrue);
      expect(isSidecarSubtitleSuffix('.zh-Hans.ass'), isTrue);
      expect(isSidecarSubtitleSuffix('.SSA'), isTrue);
      expect(isSidecarSubtitleSuffix(''), isFalse);
      expect(isSidecarSubtitleSuffix('srt'), isFalse);
      expect(isSidecarSubtitleSuffix('..srt'), isFalse);
      expect(isSidecarSubtitleSuffix('.exe'), isFalse);
      expect(isSidecarSubtitleSuffix('./x.srt'), isFalse);
      expect(isSidecarSubtitleSuffix('.a/b.srt'), isFalse);
      expect(isSidecarSubtitleSuffix('.a\\b.srt'), isFalse);
    });
  });

  group('host importVideoSubtitle', () {
    late Directory work;
    late FushiDatabase db;

    setUp(() async {
      work = await Directory.systemTemp.createTemp('subtitle_import_');
      db = _memDb();
    });

    tearDown(() async {
      await db.close();
      if (work.existsSync()) await work.delete(recursive: true);
    });

    test('sidecar 落视频同目录 <stem><suffix>；行语义镜像下载路径；cue 落库', () async {
      final Directory vidDir = Directory(p.join(work.path, 'vids'))
        ..createSync(recursive: true);
      final File vid = File(p.join(vidDir.path, 'movie.mp4'))
        ..writeAsBytesSync(<int>[1, 2, 3]);
      await db.upsertVideoBook(VideoBooksCompanion.insert(
        bookUid: 'video/movie',
        title: 'Movie',
        videoPath: vid.path,
        embeddedSubtitleTrack: const Value<int?>(0),
      ));
      final File upload = File(p.join(work.path, 'upload.tmp'))
        ..writeAsStringSync(_srtContent);

      final AppModelLibraryHostService svc = _hostService(db: db, work: work);
      await svc.importVideoSubtitle(upload,
          id: 'video/movie', suffix: '.ja.srt');

      final File landed = File(p.join(vidDir.path, 'movie.ja.srt'));
      expect(landed.existsSync(), isTrue,
          reason: 'sidecar 必须落视频同目录同 stem，resolveVideoSubtitle 才能看见');
      expect(landed.readAsStringSync(), _srtContent);

      final VideoBookRow row = (await db.getVideoBookByBookUid('video/movie'))!;
      expect(row.subtitleSource, landed.path);
      expect(row.subtitleFormat, 'srt');
      expect(row.embeddedSubtitleTrack, isNull,
          reason: '外挂字幕就位后播放应走外挂（与 client 下载路径同语义）');
      expect((await db.getCuesForBook('video/movie')).length, 2,
          reason: '字幕 cue 应解析落库（查词/句导航可用）');

      // resolveVideoSubtitle / listVideos 可见性。
      expect(
          (await svc.resolveVideoSubtitle('video/movie'))?.path, landed.path);
      final RemoteVideoInfo info = (await svc.listVideos()).single;
      expect(info.hasSubtitle, isTrue);
    });

    test('未知视频 StateError；非法后缀 ArgumentError（文件不落盘）', () async {
      final File upload = File(p.join(work.path, 'upload.tmp'))
        ..writeAsStringSync(_srtContent);
      final AppModelLibraryHostService svc = _hostService(db: db, work: work);
      expect(
          () =>
              svc.importVideoSubtitle(upload, id: 'video/nope', suffix: '.srt'),
          throwsStateError);
      expect(
          () => svc.importVideoSubtitle(upload,
              id: 'video/nope', suffix: '../../evil.srt'),
          throwsArgumentError);
    });
  });

  group('端到端 live push', () {
    late Directory work;
    late FushiSyncServer server;
    late FushiDatabase hostDb;
    late Directory hostUploads;
    late String base;
    const String token = 'subtitle-sync-token';

    setUp(() async {
      work = await Directory.systemTemp.createTemp('subtitle_sync_e2e_');
      hostDb = _memDb();
      hostUploads = Directory(p.join(work.path, 'host_uploads'))
        ..createSync(recursive: true);
      server = FushiSyncServer(
        syncDataDir: p.join(work.path, 'server_data'),
        port: 0,
        token: token,
        allowLan: false,
        libraryService:
            _hostService(db: hostDb, work: work, uploads: hostUploads),
      );
      await server.start();
      base = 'http://127.0.0.1:${server.port}';
    });

    tearDown(() async {
      await server.stop();
      await hostDb.close();
      if (work.existsSync()) await work.delete(recursive: true);
    });

    test('视频连同全部 sidecar 一并推送；重复 sweep 幂等', () async {
      final FushiDatabase localDb = _memDb();
      addTearDown(localDb.close);
      final Directory vidDir = Directory(p.join(work.path, 'local_vids'))
        ..createSync(recursive: true);
      final File vid = File(p.join(vidDir.path, 'movie.mp4'))
        ..writeAsBytesSync(<int>[9, 8, 7, 6]);
      File(p.join(vidDir.path, 'movie.srt')).writeAsStringSync(_srtContent);
      File(p.join(vidDir.path, 'movie.ja.ass'))
          .writeAsStringSync('[Script Info]\n');
      await localDb.upsertVideoBook(VideoBooksCompanion.insert(
        bookUid: 'video/movie',
        title: 'Movie',
        videoPath: vid.path,
      ));

      final InterconnectSyncBackend backend =
          await _clientBackend(base: base, token: token);
      final SyncRunReport report =
          await _orchestrator(db: localDb, backend: backend, tmp: work).run();
      expect(report.videosExported, 1);
      expect(
          report.errors.where((String e) => e.contains('subtitle')), isEmpty);

      final VideoBookRow hosted = (await hostDb.allVideoBooks()).single;
      final String hostedDir = p.dirname(hosted.videoPath);
      final String hostedStem = p.basenameWithoutExtension(hosted.videoPath);
      expect(File(p.join(hostedDir, '$hostedStem.srt')).existsSync(), isTrue);
      expect(
          File(p.join(hostedDir, '$hostedStem.ja.ass')).existsSync(), isTrue);
      // host 端首选 sidecar 按学习语言（ja）解析并落行：.ja.ass 优先于 .srt。
      expect(hosted.subtitleSource, endsWith('.ja.ass'));
      expect(hosted.subtitleFormat, 'ass');
      expect(hosted.embeddedSubtitleTrack, isNull);

      // 幂等：再跑一次，不重传视频、不重推字幕（host 已有 sidecar）。
      final int subMtime = File(p.join(hostedDir, '$hostedStem.srt'))
          .lastModifiedSync()
          .millisecondsSinceEpoch;
      final SyncRunReport report2 =
          await _orchestrator(db: localDb, backend: backend, tmp: work).run();
      expect(report2.videosExported, 0);
      expect(
          File(p.join(hostedDir, '$hostedStem.srt'))
              .lastModifiedSync()
              .millisecondsSinceEpoch,
          subMtime,
          reason: 'host 已有 sidecar 时不得重复上传覆盖');
    });

    test('host 已有视频但缺字幕：只补推字幕，不重传视频', () async {
      final FushiDatabase localDb = _memDb();
      addTearDown(localDb.close);
      final Directory vidDir = Directory(p.join(work.path, 'local_vids2'))
        ..createSync(recursive: true);
      final File vid = File(p.join(vidDir.path, 'ep1.mp4'))
        ..writeAsBytesSync(<int>[1, 1, 2, 3, 5]);
      await localDb.upsertVideoBook(VideoBooksCompanion.insert(
        bookUid: 'video/ep1',
        title: 'Ep1',
        videoPath: vid.path,
      ));

      final InterconnectSyncBackend backend =
          await _clientBackend(base: base, token: token);
      // 第一轮：本地还没有字幕 → host 只有视频。
      await _orchestrator(db: localDb, backend: backend, tmp: work).run();
      final VideoBookRow hosted = (await hostDb.allVideoBooks()).single;
      final int videoMtime =
          File(hosted.videoPath).lastModifiedSync().millisecondsSinceEpoch;

      // 本地补了字幕后再 sweep：字幕补推、视频不重传。
      File(p.join(vidDir.path, 'ep1.ja.srt')).writeAsStringSync(_srtContent);
      final SyncRunReport report2 =
          await _orchestrator(db: localDb, backend: backend, tmp: work).run();
      expect(report2.videosExported, 0, reason: '同尺寸视频不得重传');
      final String hostedStem = p.basenameWithoutExtension(hosted.videoPath);
      expect(
          File(p.join(p.dirname(hosted.videoPath), '$hostedStem.ja.srt'))
              .existsSync(),
          isTrue,
          reason: 'host 缺字幕时后续 sweep 必须补推');
      expect(File(hosted.videoPath).lastModifiedSync().millisecondsSinceEpoch,
          videoMtime);
    });

    test('老 host 无字幕端点（405）：client 返回 false 不抛', () async {
      // 裸 HttpServer 模拟老 host：suffix PUT 一律 405。
      final HttpServer old = await HttpServer.bind('127.0.0.1', 0);
      addTearDown(() => old.close(force: true));
      old.listen((HttpRequest req) {
        req.drain<void>().then((_) {
          req.response.statusCode = req.method == 'PUT' ? 405 : 200;
          req.response.close();
        });
      });
      final InterconnectSyncBackend backend = await _clientBackend(
          base: 'http://127.0.0.1:${old.port}', token: token);
      final File sub = File(p.join(work.path, 'x.srt'))
        ..writeAsStringSync(_srtContent);
      expect(
          await backend.putRemoteVideoSubtitle('video/x', sub, suffix: '.srt'),
          isFalse);
    });
  });
}
