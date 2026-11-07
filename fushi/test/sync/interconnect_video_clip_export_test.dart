import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/ffmpeg_backend.dart';
import 'package:fushi_engine/media/video/video_clip_exporter.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';

/// 反馈 6nBmSBj_2W：互联远端视频的片段导出——host 裁无字幕原料段（`clipvideo`
/// 端点 + `videoClipExport` 能力位），client 下载后在本机烧字幕。
///
/// 这里锁协议与服务层：能力位如实声明、端点参数原样传到 host 服务、原料字节完整
/// 回传且临时目录传完即清、老 host 给出可识别的「不支持」而不是普通失败。

const List<int> _clipBytes = <int>[
  0x00,
  0x00,
  0x00,
  0x18,
  0x66,
  0x74,
  0x79,
  0x70,
];

/// 只实现本测试触达的方法；其余经 noSuchMethod 抛（触达即说明协议走偏）。
class _LegacyHost implements FushiLibraryHostService {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ClipHost extends _LegacyHost implements VideoClipExportHost {
  final List<Map<String, Object?>> calls = <Map<String, Object?>>[];
  Directory? lastDir;
  bool returnNull = false;

  @override
  Future<File?> clipVideoSegment(
    String id, {
    required int startMs,
    required int endMs,
    int episodeIndex = 0,
    int? audioStreamIndex,
    int? audioStreamCount,
  }) async {
    calls.add(<String, Object?>{
      'id': id,
      'startMs': startMs,
      'endMs': endMs,
      'episode': episodeIndex,
      'audioStreamIndex': audioStreamIndex,
      'audioStreamCount': audioStreamCount,
    });
    if (returnNull) return null;
    final Directory dir = Directory.systemTemp.createTempSync('hbk_clip_seg');
    lastDir = dir;
    return File('${dir.path}/clip.mp4')..writeAsBytesSync(_clipBytes);
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

Future<({int status, String body})> _rawGet(
  String base,
  String token,
  String pathAndQuery,
) async {
  final HttpClient c = HttpClient();
  try {
    final HttpClientRequest req = await c.getUrl(
      Uri.parse('$base$pathAndQuery'),
    );
    req.headers.set(
      'authorization',
      'Basic ${base64Encode(utf8.encode('hibiki:$token'))}',
    );
    final HttpClientResponse res = await req.close();
    return (status: res.statusCode, body: await utf8.decodeStream(res));
  } finally {
    c.close();
  }
}

Future<FushiSyncServer> _startServer(
  FushiLibraryHostService library,
  String token,
) async {
  final FushiSyncServer server = FushiSyncServer(
    syncDataDir: Directory.systemTemp.createTempSync('hbk_clip_srv').path,
    port: 0,
    token: token,
    allowLan: false,
    libraryService: library,
  );
  await server.start();
  addTearDown(server.stop);
  return server;
}

class _RecordingFfmpeg implements FfmpegBackend {
  final List<List<String>> runs = <List<String>>[];

  @override
  Future<FfmpegRunResult> run(List<String> args, Duration timeout) async {
    runs.add(args);
    File(args.last).writeAsBytesSync(_clipBytes);
    return const FfmpegRunResult(returnCode: 0, output: '');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  const String token = 'clip-export-token';

  group('host 支持 clipvideo', () {
    late _ClipHost host;
    late String base;

    setUp(() async {
      host = _ClipHost();
      final FushiSyncServer server = await _startServer(host, token);
      base = 'http://127.0.0.1:${server.port}';
    });

    test('能力位声明 videoClipExport', () async {
      final ({int status, String body}) res = await _rawGet(
        base,
        token,
        '/api/capabilities',
      );
      expect(res.status, 200);
      final Object? live = (jsonDecode(res.body) as Map)['liveLibrary'];
      expect((live as Map)[kVideoClipExportCapability], isTrue);
    });

    test('client 下到完整原料，参数原样到 host，host 临时目录传完即清', () async {
      final InterconnectSyncBackend backend = await _buildBackend(
        base: base,
        token: token,
      );
      expect(await backend.hostSupportsVideoClipExport(), isTrue);
      final Directory out = Directory.systemTemp.createTempSync('hbk_clip_dl');
      addTearDown(() => out.deleteSync(recursive: true));
      final File dest = File('${out.path}/source.mp4');

      await backend.getRemoteVideoClip(
        'video/ep 1',
        dest,
        startMs: 61000,
        endMs: 64500,
        episodeIndex: 2,
        audioStreamIndex: 1,
        audioStreamCount: 2,
      );

      expect(dest.readAsBytesSync(), _clipBytes);
      expect(host.calls, <Map<String, Object?>>[
        <String, Object?>{
          'id': 'video/ep 1',
          'startMs': 61000,
          'endMs': 64500,
          'episode': 2,
          'audioStreamIndex': 1,
          'audioStreamCount': 2,
        },
      ]);
      expect(host.lastDir!.existsSync(), isFalse);
    });

    test('区间非法 → 400，不调 host 服务', () async {
      final ({int status, String body}) res = await _rawGet(
        base,
        token,
        '/api/library/videos/v1/clipvideo?startMs=5000&endMs=5000',
      );
      expect(res.status, 400);
      expect(host.calls, isEmpty);
    });

    test('host 裁不出（没有本地文件 / ffmpeg 失败）→ 404，client 抛普通错误', () async {
      host.returnNull = true;
      final InterconnectSyncBackend backend = await _buildBackend(
        base: base,
        token: token,
      );
      final Directory out = Directory.systemTemp.createTempSync('hbk_clip_dl');
      addTearDown(() => out.deleteSync(recursive: true));
      await expectLater(
        backend.getRemoteVideoClip(
          'v1',
          File('${out.path}/source.mp4'),
          startMs: 0,
          endMs: 1000,
        ),
        throwsA(isNot(isA<RemoteVideoClipUnsupported>())),
      );
    });
  });

  group('老 host（未实现 VideoClipExportHost）', () {
    late String base;

    setUp(() async {
      final FushiSyncServer server = await _startServer(_LegacyHost(), token);
      base = 'http://127.0.0.1:${server.port}';
    });

    test(
      '端点 404、能力位 false，client 抛 RemoteVideoClipUnsupported 且不发裁切请求',
      () async {
        final ({int status, String body}) raw = await _rawGet(
          base,
          token,
          '/api/library/videos/v1/clipvideo?startMs=0&endMs=1000',
        );
        expect(raw.status, 404);

        final InterconnectSyncBackend backend = await _buildBackend(
          base: base,
          token: token,
        );
        expect(await backend.hostSupportsVideoClipExport(), isFalse);
        final Directory out = Directory.systemTemp.createTempSync(
          'hbk_clip_dl',
        );
        addTearDown(() => out.deleteSync(recursive: true));
        final File dest = File('${out.path}/source.mp4');
        await expectLater(
          backend.getRemoteVideoClip('v1', dest, startMs: 0, endMs: 1000),
          throwsA(isA<RemoteVideoClipUnsupported>()),
        );
        expect(dest.existsSync(), isFalse);
      },
    );
  });

  group('host 端裁原料的 ffmpeg 参数', () {
    test('逐帧精确重编码（不走 -c copy），只取所选音轨，区间从片段起点算', () async {
      final Directory dir = Directory.systemTemp.createTempSync('hbk_clip_ff');
      addTearDown(() => dir.deleteSync(recursive: true));
      final File input = File('${dir.path}/in.mkv')..writeAsBytesSync(<int>[1]);
      final _RecordingFfmpeg ffmpeg = _RecordingFfmpeg();

      final String? out = await exportVideoClipSourceSegmentViaFfmpeg(
        inputPath: input.path,
        startMs: 61000,
        endMs: 64500,
        outputPath: '${dir.path}/clip.mp4',
        audioStreamIndex: 1,
        audioStreamCount: 2,
        backend: ffmpeg,
      );

      expect(out, '${dir.path}/clip.mp4');
      expect(ffmpeg.runs, hasLength(1));
      final List<String> args = ffmpeg.runs.single;
      String after(String flag) => args[args.indexOf(flag) + 1];
      expect(after('-ss'), '61.000');
      expect(after('-t'), '3.500');
      expect(after('-c:v'), 'libx264');
      expect(args, isNot(contains('copy')));
      expect(args.join(' '), contains('0:a:1'));
    });

    test('区间非法 / 源不存在 → null，不跑 ffmpeg', () async {
      final _RecordingFfmpeg ffmpeg = _RecordingFfmpeg();
      expect(
        await exportVideoClipSourceSegmentViaFfmpeg(
          inputPath: '/definitely/missing.mkv',
          startMs: 0,
          endMs: 1000,
          outputPath: '${Directory.systemTemp.path}/never.mp4',
          backend: ffmpeg,
        ),
        isNull,
      );
      expect(ffmpeg.runs, isEmpty);
    });
  });
}
