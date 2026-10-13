import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/sync/interconnect_graphic_subtitle_export.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/ffmpeg_backend.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:fushi_engine/sync/graphic_subtitle_track_export.dart';

/// 互联 host 回传图形字幕整轨（`GET /api/library/videos/<id>/graphicsubtitle`）：
/// host 有原文件，在本机抽好那一条字幕轨回传几百 KB；client 不为字幕把整片再读一遍。
///
/// 端点契约：Basic 鉴权；`embeddedStreamIndex` 与 `/subtitle` 同义（ffmpeg `0:s:N`）；
/// 只接图形轨；没注入抽取实现 501；编码不支持 415；`part=header` 回轨头。
class _FakeLibraryService implements FushiLibraryHostService {
  _FakeLibraryService() {
    final Directory tmp = Directory.systemTemp.createTempSync('gfx_host_lib');
    videoFile = File('${tmp.path}/show.mkv')..writeAsBytesSync(<int>[1, 2, 3]);
    ep1File = File('${tmp.path}/show_ep1.mkv')..writeAsBytesSync(<int>[4, 5]);
  }

  static const String videoId = 'video/show';
  late final File videoFile;
  late final File ep1File;

  @override
  Future<File?> resolveVideoFile(String id, {int episodeIndex = 0}) async {
    if (id != videoId) return null;
    if (episodeIndex == 0) return videoFile;
    if (episodeIndex == 1) return ep1File;
    return null;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

/// ffprobe 轨表替身：s:0 文本、s:1 PGS、s:2 VobSub。
class _TrackListingFfmpeg implements FfmpegBackend {
  @override
  Future<FfmpegRunResult> runQuery(List<String> args, Duration timeout) =>
      run(args, timeout);

  @override
  Future<FfmpegRunResult> runProbe(List<String> args, Duration timeout) async =>
      const FfmpegRunResult(returnCode: 0, output: '{"format":{}}');

  @override
  Future<FfmpegRunResult> run(List<String> args, Duration timeout) async {
    if (args.contains('-hide_banner')) {
      return const FfmpegRunResult(
        returnCode: 1,
        output: '''
  Stream #0:0: Video: h264
  Stream #0:1(jpn): Subtitle: subrip (srt) (default)
  Stream #0:2(jpn): Subtitle: hdmv_pgs_subtitle
  Stream #0:3(eng): Subtitle: dvd_subtitle
''',
      );
    }
    return const FfmpegRunResult(returnCode: 0, output: '');
  }
}

/// 记录调用、回传固定字节的抽取实现替身。
class _RecordingExporter {
  final List<({String videoPath, int streamIndex, String codec})> calls =
      <({String videoPath, int streamIndex, String codec})>[];
  late final Directory dir = Directory.systemTemp.createTempSync('gfx_export');
  bool withHeader = true;
  Exception? error;

  Future<GraphicSubtitleTrackExport?> call({
    required String videoPath,
    required int streamIndex,
    required String codec,
  }) async {
    calls.add((videoPath: videoPath, streamIndex: streamIndex, codec: codec));
    final Exception? e = error;
    if (e != null) throw e;
    final File payload = File('${dir.path}/p_$streamIndex.bin')
      ..writeAsBytesSync(<int>[0x50, 0x47, 9, 9]);
    final File header = File('${dir.path}/p_$streamIndex.bin.header.json')
      ..writeAsStringSync('{"codec":"$codec"}');
    return GraphicSubtitleTrackExport(
      file: payload,
      format: 'sup',
      headerFile: withHeader ? header : null,
    );
  }
}

FushiDatabase _testDb() =>
    FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));

Future<InterconnectSyncBackend> _buildBackend({
  required String base,
  required String token,
}) async {
  final FushiDatabase db = _testDb();
  addTearDown(() async => db.close());
  final SyncRepository repo = SyncRepository(db);
  await repo.setFushiClientUrls(<FushiClientUrl>[
    FushiClientUrl(url: base, enabled: true),
  ]);
  await repo.setFushiClientToken(token);
  final InterconnectSyncBackend backend = InterconnectSyncBackend.withProbe(
    (String url, String tok) async => true,
  );
  await backend.restoreAuth(repo);
  await backend.authenticate(repo: repo);
  return backend;
}

void main() {
  const String token = 'gfx-token';
  late FushiSyncServer server;
  late String base;
  late _RecordingExporter exporter;
  final String encodedId = Uri.encodeFull(_FakeLibraryService.videoId);
  String auth() => 'Basic ${base64Encode(utf8.encode('hibiki:$token'))}';

  Future<HttpClientResponse> get(
    String pathAndQuery, {
    bool authed = true,
  }) async {
    final HttpClient c = HttpClient();
    addTearDown(c.close);
    final HttpClientRequest req = await c.getUrl(
      Uri.parse('$base$pathAndQuery'),
    );
    if (authed) req.headers.set('authorization', auth());
    return req.close();
  }

  Future<List<int>> bytesOf(HttpClientResponse res) =>
      res.fold<List<int>>(<int>[], (List<int> a, List<int> b) => a..addAll(b));

  setUp(() async {
    setFfmpegBackendForTesting(_TrackListingFfmpeg());
    exporter = _RecordingExporter();
    server = FushiSyncServer(
      syncDataDir: Directory.systemTemp.createTempSync('gfx_srv').path,
      port: 0,
      token: token,
      allowLan: false,
      libraryService: _FakeLibraryService(),
    )..graphicSubtitleTrackExporter = exporter.call;
    await server.start();
    base = 'http://127.0.0.1:${server.port}';
  });

  tearDown(() async {
    setFfmpegBackendForTesting(null);
    await server.stop();
  });

  group('GET /api/library/videos/<id>/graphicsubtitle', () {
    test('回传 host 抽好的整轨载荷（按 host 流号 + ffprobe 编码交给抽取实现）', () async {
      final HttpClientResponse res = await get(
        '/api/library/videos/$encodedId/graphicsubtitle?embeddedStreamIndex=1',
      );
      expect(res.statusCode, 200);
      expect(res.headers.contentType?.mimeType, 'application/octet-stream');
      expect(res.headers.value('x-fushi-graphic-subtitle-format'), 'sup');
      expect(await bytesOf(res), <int>[0x50, 0x47, 9, 9]);
      expect(exporter.calls.single.streamIndex, 1);
      expect(exporter.calls.single.codec, 'hdmv_pgs_subtitle');
    });

    test('part=header 回轨头 JSON（VobSub 调色板等 extradata）', () async {
      final HttpClientResponse res = await get(
        '/api/library/videos/$encodedId/graphicsubtitle'
        '?embeddedStreamIndex=2&part=header',
      );
      expect(res.statusCode, 200);
      expect(res.headers.contentType?.mimeType, 'application/json');
      expect(utf8.decode(await bytesOf(res)), '{"codec":"dvd_subtitle"}');
    });

    test('这条轨没有轨头（PGS）→ part=header 404，载荷照常', () async {
      exporter.withHeader = false;
      final HttpClientResponse res = await get(
        '/api/library/videos/$encodedId/graphicsubtitle'
        '?embeddedStreamIndex=1&part=header',
      );
      expect(res.statusCode, 404);
      await res.drain<void>();
    });

    test('?episode=N 按集反查文件', () async {
      final HttpClientResponse res = await get(
        '/api/library/videos/$encodedId/graphicsubtitle'
        '?embeddedStreamIndex=1&episode=1',
      );
      expect(res.statusCode, 200);
      await res.drain<void>();
      expect(exporter.calls.single.videoPath, endsWith('show_ep1.mkv'));
    });

    test('文本轨走 /subtitle，这里 404；未知视频 404；缺流号 400', () async {
      final HttpClientResponse text = await get(
        '/api/library/videos/$encodedId/graphicsubtitle?embeddedStreamIndex=0',
      );
      expect(text.statusCode, 404);
      await text.drain<void>();
      final HttpClientResponse missing = await get(
        '/api/library/videos/video%2Fnope/graphicsubtitle?embeddedStreamIndex=1',
      );
      expect(missing.statusCode, 404);
      await missing.drain<void>();
      final HttpClientResponse noIndex = await get(
        '/api/library/videos/$encodedId/graphicsubtitle',
      );
      expect(noIndex.statusCode, 400);
      await noIndex.drain<void>();
      expect(exporter.calls, isEmpty);
    });

    test('未鉴权 401（不在 /stream 豁免名单）', () async {
      final HttpClientResponse res = await get(
        '/api/library/videos/$encodedId/graphicsubtitle?embeddedStreamIndex=1',
        authed: false,
      );
      expect(res.statusCode, 401);
      await res.drain<void>();
    });

    test('编码不支持 415；抽取失败 500', () async {
      exporter.error = const GraphicSubtitleTrackExportUnsupported('xsub');
      final HttpClientResponse unsupported = await get(
        '/api/library/videos/$encodedId/graphicsubtitle?embeddedStreamIndex=1',
      );
      expect(unsupported.statusCode, 415);
      await unsupported.drain<void>();
      exporter.error = const FileSystemException('ffmpeg died');
      final HttpClientResponse failed = await get(
        '/api/library/videos/$encodedId/graphicsubtitle?embeddedStreamIndex=1',
      );
      expect(failed.statusCode, 500);
      await failed.drain<void>();
    });

    test('没注入抽取实现 → 501，能力位 videoGraphicSubtitleTrack 跟着走', () async {
      Future<Object?> capability() async {
        final HttpClientResponse res = await get('/api/capabilities');
        final Map<String, dynamic> json =
            jsonDecode(utf8.decode(await bytesOf(res))) as Map<String, dynamic>;
        return (json['liveLibrary']
            as Map<String, dynamic>)['videoGraphicSubtitleTrack'];
      }

      expect(await capability(), isTrue);
      server.graphicSubtitleTrackExporter = null;
      expect(await capability(), isFalse);
      final HttpClientResponse res = await get(
        '/api/library/videos/$encodedId/graphicsubtitle?embeddedStreamIndex=1',
      );
      expect(res.statusCode, 501);
      await res.drain<void>();
    });
  });

  group('InterconnectSyncBackend 取整轨（client 端）', () {
    test('载荷与轨头经鉴权通道落盘；按集请求', () async {
      final InterconnectSyncBackend backend = await _buildBackend(
        base: base,
        token: token,
      );
      final Directory tmp = Directory.systemTemp.createTempSync('gfx_client');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final File payload = File('${tmp.path}/t.bin');
      final File header = File('${tmp.path}/t.header.json');
      await backend.getRemoteVideoGraphicSubtitleTrack(
        _FakeLibraryService.videoId,
        payload,
        embeddedStreamIndex: 2,
        episodeIndex: 1,
      );
      await backend.getRemoteVideoGraphicSubtitleTrackHeader(
        _FakeLibraryService.videoId,
        header,
        embeddedStreamIndex: 2,
        episodeIndex: 1,
      );
      expect(payload.readAsBytesSync(), <int>[0x50, 0x47, 9, 9]);
      expect(header.readAsStringSync(), '{"codec":"dvd_subtitle"}');
      expect(
        exporter.calls.map((e) => e.videoPath),
        everyElement(endsWith('show_ep1.mkv')),
      );
    });

    test('老 host / 没接入抽取 → 抛错（调用方退回边播边记）', () async {
      server.graphicSubtitleTrackExporter = null;
      final InterconnectSyncBackend backend = await _buildBackend(
        base: base,
        token: token,
      );
      final Directory tmp = Directory.systemTemp.createTempSync('gfx_client');
      addTearDown(() => tmp.deleteSync(recursive: true));
      await expectLater(
        backend.getRemoteVideoGraphicSubtitleTrack(
          _FakeLibraryService.videoId,
          File('${tmp.path}/t.bin'),
          embeddedStreamIndex: 1,
        ),
        throwsA(isA<SyncBackendError>()),
      );
    });
  });

  group('InterconnectGraphicSubtitleExporter（互联 host 的抽取实现，住在引擎）', () {
    late Directory cache;
    late File video;

    setUp(() {
      cache = Directory.systemTemp.createTempSync('gfx_export_cache');
      video = File('${cache.path}/v.mkv')..writeAsBytesSync(<int>[1, 2, 3, 4]);
    });

    tearDown(() {
      if (cache.existsSync()) cache.deleteSync(recursive: true);
    });

    test('抽一次：轨头随载荷进缓存，第二次与并发请求都命中同一份', () async {
      int runs = 0;
      final Completer<void> gate = Completer<void>();
      final InterconnectGraphicSubtitleExporter exporter =
          InterconnectGraphicSubtitleExporter(
            cacheDir: Directory('${cache.path}/c'),
            extract:
                ({
                  required String videoPath,
                  required int streamIndex,
                  required String outputPath,
                  required String codec,
                }) async {
                  runs++;
                  await gate.future;
                  File(outputPath).writeAsBytesSync(<int>[0x47, 1, 2]);
                  File(
                    '$outputPath.header.json',
                  ).writeAsStringSync('{"codec":"$codec"}');
                  return true;
                },
          );
      final Future<GraphicSubtitleTrackExport?> a = exporter.export(
        videoPath: video.path,
        streamIndex: 3,
        codec: 'dvd_subtitle',
      );
      final Future<GraphicSubtitleTrackExport?> b = exporter.export(
        videoPath: video.path,
        streamIndex: 3,
        codec: 'dvd_subtitle',
      );
      gate.complete();
      final GraphicSubtitleTrackExport first = (await a)!;
      expect((await b)!.file.path, first.file.path);
      expect(first.format, 'mpegts');
      expect(first.file.readAsBytesSync(), <int>[0x47, 1, 2]);
      expect(first.headerFile!.readAsStringSync(), '{"codec":"dvd_subtitle"}');
      final GraphicSubtitleTrackExport again = (await exporter.export(
        videoPath: video.path,
        streamIndex: 3,
        codec: 'dvd_subtitle',
      ))!;
      expect(again.file.path, first.file.path);
      expect(runs, 1);
    });

    test('抽取失败不留缓存，下次重抽', () async {
      int runs = 0;
      final InterconnectGraphicSubtitleExporter exporter =
          InterconnectGraphicSubtitleExporter(
            cacheDir: Directory('${cache.path}/c'),
            extract:
                ({
                  required String videoPath,
                  required int streamIndex,
                  required String outputPath,
                  required String codec,
                }) async {
                  runs++;
                  File(outputPath).writeAsBytesSync(<int>[1]);
                  return false;
                },
          );
      expect(
        await exporter.export(
          videoPath: video.path,
          streamIndex: 1,
          codec: 'hdmv_pgs_subtitle',
        ),
        isNull,
      );
      expect(
        await exporter.export(
          videoPath: video.path,
          streamIndex: 1,
          codec: 'hdmv_pgs_subtitle',
        ),
        isNull,
      );
      expect(runs, 2);
    });

    test('解码不了的编码 → GraphicSubtitleTrackExportUnsupported（端点 415）', () {
      final InterconnectGraphicSubtitleExporter exporter =
          InterconnectGraphicSubtitleExporter(
            cacheDir: Directory('${cache.path}/c'),
            extract:
                ({
                  required String videoPath,
                  required int streamIndex,
                  required String outputPath,
                  required String codec,
                }) async => fail('不该抽'),
          );
      expect(
        () => exporter.export(
          videoPath: video.path,
          streamIndex: 0,
          codec: 'xsub',
        ),
        throwsA(isA<GraphicSubtitleTrackExportUnsupported>()),
      );
    });
  });

  group('装配：app host 与无头服务端注入同一份引擎实现', () {
    test('抽取实现住在引擎（纯 Dart，无头服务端可用），app 不再有副本', () {
      expect(
        File(
          '../packages/fushi_engine/lib/sync/interconnect_graphic_subtitle_export.dart',
        ).existsSync(),
        isTrue,
      );
      expect(
        File(
          'lib/src/sync/interconnect_graphic_subtitle_export.dart',
        ).existsSync(),
        isFalse,
      );
    });

    test('fushi_server 的 HeadlessHost 给 FushiSyncServer 注入整轨抽取', () {
      final String src = File(
        '../packages/fushi_server/lib/src/headless_host.dart',
      ).readAsStringSync();
      expect(
        RegExp(
          r'\.\.graphicSubtitleTrackExporter\s*=\s*InterconnectGraphicSubtitleExporter\(',
        ).hasMatch(src),
        isTrue,
        reason: '没注入时无头服务端对 /graphicsubtitle 回 501，远端图形字幕没有逐句时间',
      );
    });

    test('app 的 FushiSyncServerController 缺省注入同一份', () {
      final String src = File(
        'lib/src/sync/fushi_server_controller.dart',
      ).readAsStringSync();
      expect(src.contains('exportGraphicSubtitleTrackForInterconnect'), isTrue);
      expect(
        src.contains(
          '..graphicSubtitleTrackExporter = _graphicSubtitleTrackExporter',
        ),
        isTrue,
      );
    });
  });
}
