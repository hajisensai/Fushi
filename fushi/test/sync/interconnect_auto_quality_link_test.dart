import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi/src/sync/remote_video_client.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/ffmpeg_backend.dart';
import 'package:fushi_engine/media/video/live_transcode.dart';
import 'package:fushi_engine/sync/aggregate_snapshot.dart';
import 'package:fushi_engine/sync/collection_manifest.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';

/// 反馈 uaBRMzK_WM「缺少高画质选项，内网甚至可以看 BD 满码率」端到端：真
/// [FushiSyncServer] 起在 127.0.0.1，client 走真 [InterconnectSyncBackend]。
///
/// 回环地址字面上就是局域网，会直接走「原画、不测」；要验证经域名 / 公网 IPv6
/// 回家这条路（地址字面上不是私网），把 [InterconnectSyncBackend.privateNetworkHostJudge]
/// 换成恒 false，让起点真的去签原画票、测链路、按源码率决定。

const String _videoId = 'v1';

class _FakeLibraryService implements FushiLibraryHostService {
  _FakeLibraryService(Uint8List bytes) {
    final Directory tmp = Directory.systemTemp.createTempSync('hbk_aql_src');
    videoFile = File('${tmp.path}/sample.mp4')..writeAsBytesSync(bytes);
  }

  late File videoFile;

  @override
  Future<List<RemoteVideoInfo>> listVideos() async => <RemoteVideoInfo>[
    RemoteVideoInfo(
      id: _videoId,
      title: 'Sample',
      sizeBytes: videoFile.lengthSync(),
    ),
  ];

  @override
  Future<File?> resolveVideoFile(String id, {int episodeIndex = 0}) async =>
      id == _videoId ? videoFile : null;

  @override
  Future<File?> resolveVideoSubtitle(
    String id, {
    String langCode = '',
    int episodeIndex = 0,
  }) async => null;

  @override
  Future<AggregateSnapshot> getAggregateSnapshot() async =>
      const AggregateSnapshot();

  @override
  Future<CollectionManifest> getCollectionManifest() async =>
      CollectionManifest.empty;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} 不该被画质用例触达');
}

/// ffprobe 替身：回固定时长（决定 host 报的源码率），没有内嵌字幕轨。
class _ProbeBackend implements FfmpegBackend {
  _ProbeBackend(this.durationSeconds);

  final String durationSeconds;

  @override
  Future<FfmpegRunResult> runQuery(List<String> args, Duration timeout) =>
      run(args, timeout);

  @override
  Future<FfmpegRunResult> run(List<String> args, Duration timeout) async =>
      FfmpegRunResult(returnCode: 0, output: '');

  @override
  Future<FfmpegRunResult> runProbe(List<String> args, Duration timeout) async =>
      FfmpegRunResult(
        returnCode: 0,
        output: jsonEncode(<String, Object?>{
          'format': <String, Object?>{'duration': durationSeconds},
          'streams': <Object?>[],
        }),
      );
}

Uint8List _pattern(int length) =>
    Uint8List.fromList(List<int>.generate(length, (int i) => (i * 31) & 0xff));

void main() {
  late FushiSyncServer server;
  late String base;
  const String token = 'auto-quality-link-token';
  // 4 MiB：探测要读到 [kInterconnectLinkProbeMinBytes] 以上才作数，回环上一瞬间读完。
  final Uint8List source = _pattern(4 * 1024 * 1024);

  Future<void> startServer({
    required String durationSeconds,
    bool transcode = true,
  }) async {
    setFfmpegBackendForTesting(_ProbeBackend(durationSeconds));
    if (transcode) {
      setTranscodeSegmentRunnerForTesting(
        (List<String> args) async => Uint8List.fromList(<int>[0x47]),
      );
      setTranscodeAvailableForTesting(true);
    } else {
      setTranscodeAvailableForTesting(false);
    }
    server = FushiSyncServer(
      syncDataDir: Directory.systemTemp.createTempSync('hbk_aql_srv').path,
      port: 0,
      token: token,
      allowLan: false,
      libraryService: _FakeLibraryService(source),
    );
    await server.start();
    base = 'http://127.0.0.1:${server.port}';
  }

  Future<InterconnectSyncBackend> buildBackend({
    bool literalLan = false,
  }) async {
    final FushiDatabase db = FushiDatabase.forTesting(
      DatabaseConnection(NativeDatabase.memory()),
    );
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
    if (!literalLan) backend.privateNetworkHostJudge = (String? _) => false;
    return backend;
  }

  tearDown(() async {
    setFfmpegBackendForTesting(null);
    setTranscodeSegmentRunnerForTesting(null);
    setTranscodeAvailableForTesting(null);
    await server.stop();
  });

  test('地址不是私网、但链路撑得住源码率 → 自动档起播就是原画直传', () async {
    // 4 MiB / 600 s ≈ 56 kbps：任何能跑的链路都远超 1.5 倍。
    await startServer(durationSeconds: '600');
    final InterconnectSyncBackend backend = await buildBackend();

    final RemoteVideoStreamUrls urls = await backend.remoteVideoStreamUrls(
      _videoId,
    );
    expect(urls.streamUrl, contains('/stream?'), reason: '原文件直传，不是 HLS');
    expect(urls.streamIsOriginalContainer, isTrue);
    expect(backend.adaptiveQualityIndex, -1);
    expect(backend.sourceBitrate, source.length * 8 * 1000 ~/ 600000);
  });

  test('源码率高到链路撑不住 → 按带宽挑转码档', () async {
    // 4 MiB / 1 ms ≈ 33 Gbps：回环也跑不到 1.5 倍。
    await startServer(durationSeconds: '0.001');
    final InterconnectSyncBackend backend = await buildBackend();

    final RemoteVideoStreamUrls urls = await backend.remoteVideoStreamUrls(
      _videoId,
    );
    expect(urls.streamUrl, contains('hls.m3u8'));
    expect(backend.adaptiveQualityIndex, isNotNull);
    expect(backend.adaptiveQualityIndex, greaterThanOrEqualTo(0));
  });

  test('同一个源换档重取流：沿用自适应定下的档，不重新起步', () async {
    await startServer(durationSeconds: '600');
    final InterconnectSyncBackend backend = await buildBackend();
    await backend.remoteVideoStreamUrls(_videoId);
    expect(backend.adaptiveQualityIndex, -1);

    // 自适应降到第 2 档后按同一集重取流（_applyAdaptiveQuality 的路径）。
    backend.adaptiveQualityIndex = 2;
    final RemoteVideoStreamUrls again = await backend.remoteVideoStreamUrls(
      _videoId,
    );
    expect(again.streamUrl, contains('hls.m3u8'));
    expect(backend.adaptiveQualityIndex, 2);

    // 换一集 = 换一个源：重新按链路对源码率起步。
    final RemoteVideoStreamUrls next = await backend.remoteVideoStreamUrls(
      _videoId,
      episodeIndex: 1,
    );
    expect(next.streamUrl, contains('/stream?'));
    expect(backend.adaptiveQualityIndex, -1);
  });

  test('用户选「原画」：即使链路判成公网也恒直传，不碰自适应', () async {
    await startServer(durationSeconds: '0.001');
    final InterconnectSyncBackend backend = await buildBackend();
    backend.qualityPresetIndex = kRemoteVideoQualityOriginal;

    final RemoteVideoStreamUrls urls = await backend.remoteVideoStreamUrls(
      _videoId,
    );
    expect(urls.streamUrl, contains('/stream?'));
    expect(backend.adaptiveQualityIndex, isNull);
  });

  test('字面量局域网：原画、不测', () async {
    await startServer(durationSeconds: '0.001');
    final InterconnectSyncBackend backend = await buildBackend(
      literalLan: true,
    );
    final RemoteVideoStreamUrls urls = await backend.remoteVideoStreamUrls(
      _videoId,
    );
    expect(urls.streamUrl, contains('/stream?'));
    expect(backend.adaptiveQualityIndex, -1);
  });

  test('host 转不了码：原画票原样返回，不定档（菜单不出现）', () async {
    await startServer(durationSeconds: '600', transcode: false);
    final InterconnectSyncBackend backend = await buildBackend();
    final RemoteVideoStreamUrls urls = await backend.remoteVideoStreamUrls(
      _videoId,
    );
    expect(urls.streamUrl, contains('/stream?'));
    expect(backend.qualityPresets, isEmpty);
    expect(backend.adaptiveQualityIndex, isNull);
  });
}
