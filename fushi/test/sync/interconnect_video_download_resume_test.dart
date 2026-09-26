import 'dart:async';
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

/// 互联视频下载（peer → 本机）的续传 / 取消 / 原片端到端：真 [FushiSyncServer]
/// 进程内起在 127.0.0.1，client 走真 [InterconnectSyncBackend]。

const String _videoId = 'v1';

/// 视频方法真实、其余存根的库服务（对照 `fushi_sync_server_transcode_test.dart`）。
class _FakeLibraryService implements FushiLibraryHostService {
  _FakeLibraryService(Uint8List bytes) {
    final Directory tmp = Directory.systemTemp.createTempSync('hbk_vdl_src');
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
      throw UnimplementedError('${invocation.memberName} 不该被下载用例触达');
}

/// ffprobe / ffmpeg 替身：探得出时长（转码闸门之一），没有内嵌字幕轨。
class _ProbeBackend implements FfmpegBackend {
  @override
  Future<FfmpegRunResult> run(List<String> args, Duration timeout) async =>
      FfmpegRunResult(returnCode: 0, output: '');

  @override
  Future<FfmpegRunResult> runProbe(List<String> args, Duration timeout) async =>
      FfmpegRunResult(
        returnCode: 0,
        output: jsonEncode(<String, Object?>{
          'format': <String, Object?>{'duration': '15.5'},
          'streams': <Object?>[],
        }),
      );
}

Uint8List _pattern(int length, {int seed = 0}) => Uint8List.fromList(
  List<int>.generate(length, (int i) => (i * 31 + seed) & 0xff),
);

void main() {
  late FushiSyncServer server;
  late _FakeLibraryService lib;
  late String base;
  late Directory work;
  const String token = 'video-dl-resume-token';

  Future<void> startServer(Uint8List bytes, {bool transcode = false}) async {
    setFfmpegBackendForTesting(_ProbeBackend());
    if (transcode) {
      // runner 替身会清掉可用性覆写，所以先设 runner 再钉可用。
      setTranscodeSegmentRunnerForTesting(
        (List<String> args) async => Uint8List.fromList(<int>[0x47]),
      );
      setTranscodeAvailableForTesting(true);
    } else {
      setTranscodeAvailableForTesting(false);
    }
    lib = _FakeLibraryService(bytes);
    server = FushiSyncServer(
      syncDataDir: Directory.systemTemp.createTempSync('hbk_vdl_srv').path,
      port: 0,
      token: token,
      allowLan: false,
      libraryService: lib,
    );
    await server.start();
    base = 'http://127.0.0.1:${server.port}';
  }

  Future<InterconnectSyncBackend> buildBackend() async {
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
    return backend;
  }

  setUp(() {
    work = Directory.systemTemp.createTempSync('hbk_vdl_dst');
  });

  tearDown(() async {
    setFfmpegBackendForTesting(null);
    setTranscodeSegmentRunnerForTesting(null);
    setTranscodeAvailableForTesting(null);
    await server.stop();
    try {
      work.deleteSync(recursive: true);
    } catch (_) {
      // best-effort
    }
  });

  File partOf(File dest) => File('${dest.path}.part');
  File etagOf(File dest) => File('${dest.path}.part.etag');

  test('中断后从 .part 续传：Range 206，字节级进度从断点起算，终稿与源一致', () async {
    final Uint8List source = _pattern(256 * 1024);
    await startServer(source);
    final InterconnectSyncBackend backend = await buildBackend();
    final File dest = File('${work.path}/sample.mp4');
    partOf(dest).writeAsBytesSync(source.sublist(0, 1000));
    etagOf(dest).writeAsStringSync(videoFileEtag(lib.videoFile));

    final List<int> received = <int>[];
    final List<int?> totals = <int?>[];
    final List<double> ratios = <double>[];
    await backend.downloadRemoteVideo(
      _videoId,
      dest,
      onProgress: ratios.add,
      onBytes: (int r, int? t) {
        received.add(r);
        totals.add(t);
      },
    );

    // 首个进度就是断点偏移：只有 host 回 206 且起点对上，才会从 1000 起算。
    expect(received.first, 1000);
    expect(received.last, source.length);
    expect(totals.last, source.length);
    expect(ratios.last, 1.0);
    expect(dest.readAsBytesSync(), source);
    expect(partOf(dest).existsSync(), isFalse);
    expect(etagOf(dest).existsSync(), isFalse, reason: '成功后必须清验证器侧车');
  });

  test('host 文件已换（ETag 不符）：丢弃旧 part 整包重下，不拼坏', () async {
    final Uint8List source = _pattern(64 * 1024, seed: 7);
    await startServer(source);
    final InterconnectSyncBackend backend = await buildBackend();
    final File dest = File('${work.path}/sample.mp4');
    partOf(dest).writeAsBytesSync(List<int>.filled(1000, 0xEE));
    etagOf(dest).writeAsStringSync('"vid-1000-1"');

    final List<int> received = <int>[];
    await backend.downloadRemoteVideo(
      _videoId,
      dest,
      onBytes: (int r, int? t) => received.add(r),
    );

    expect(received.first, 0, reason: 'If-Range 不匹配 → 200 全量，从 0 写');
    expect(dest.readAsBytesSync(), source);
    expect(etagOf(dest).existsSync(), isFalse);
  });

  test('没有验证器侧车的旧 part 不续传（视频流接受盲 Range，续了可能拼坏）', () async {
    final Uint8List source = _pattern(64 * 1024, seed: 3);
    await startServer(source);
    final InterconnectSyncBackend backend = await buildBackend();
    final File dest = File('${work.path}/sample.mp4');
    partOf(dest).writeAsBytesSync(List<int>.filled(1000, 0xEE));

    final List<int> received = <int>[];
    await backend.downloadRemoteVideo(
      _videoId,
      dest,
      onBytes: (int r, int? t) => received.add(r),
    );

    expect(received.first, 0);
    expect(dest.readAsBytesSync(), source);
  });

  test('下载恒取原片：播放画质档会让 host 转 HLS，下载不带档', () async {
    final Uint8List source = _pattern(32 * 1024, seed: 11);
    await startServer(source, transcode: true);
    final InterconnectSyncBackend backend = await buildBackend();
    backend.qualityPresetIndex = 0;

    // 前提：同一个 backend 播放取流确实会拿到转码 playlist。
    final RemoteVideoStreamUrls playback = await backend.remoteVideoStreamUrls(
      _videoId,
    );
    expect(playback.streamUrl, contains('hls.m3u8'));
    expect(playback.streamIsOriginalContainer, isFalse);

    final File dest = File('${work.path}/sample.mp4');
    await backend.downloadRemoteVideo(_videoId, dest);
    expect(dest.readAsBytesSync(), source);
  });

  test('cancelSignal：抛 RemoteDownloadCancelled、保留 part，下次从断点续上', () async {
    final Uint8List source = _pattern(8 * 1024 * 1024, seed: 5);
    await startServer(source);
    final InterconnectSyncBackend backend = await buildBackend();
    final File dest = File('${work.path}/sample.mp4');

    final Completer<void> cancel = Completer<void>();
    await expectLater(
      backend.downloadRemoteVideo(
        _videoId,
        dest,
        cancelSignal: cancel.future,
        onBytes: (int r, int? t) {
          if (r > 0 && !cancel.isCompleted) cancel.complete();
        },
      ),
      throwsA(isA<RemoteDownloadCancelled>()),
    );
    expect(dest.existsSync(), isFalse);
    expect(partOf(dest).existsSync(), isTrue);
    final int partLength = partOf(dest).lengthSync();
    expect(partLength, greaterThan(0));
    expect(partLength, lessThan(source.length));
    expect(etagOf(dest).readAsStringSync(), videoFileEtag(lib.videoFile));

    final List<int> received = <int>[];
    await backend.downloadRemoteVideo(
      _videoId,
      dest,
      onBytes: (int r, int? t) => received.add(r),
    );
    expect(received.first, partLength);
    expect(dest.readAsBytesSync(), source);
    expect(partOf(dest).existsSync(), isFalse);
    expect(etagOf(dest).existsSync(), isFalse);
  });

  test('开始前已取消：直接抛 RemoteDownloadCancelled，不落盘', () async {
    await startServer(_pattern(1024));
    final InterconnectSyncBackend backend = await buildBackend();
    final File dest = File('${work.path}/sample.mp4');

    await expectLater(
      backend.downloadRemoteVideo(
        _videoId,
        dest,
        cancelSignal: Future<void>.value(),
      ),
      throwsA(isA<RemoteDownloadCancelled>()),
    );
    expect(dest.existsSync(), isFalse);
  });

  group('host /stream 验证器', () {
    final HttpClient http = HttpClient();
    tearDownAll(() => http.close(force: true));

    Future<String> streamUrl() async {
      final HttpClientRequest req = await http.getUrl(
        Uri.parse('$base/api/library/videos/$_videoId/streamurl'),
      );
      req.headers.set(
        'authorization',
        'Basic ${base64Encode(utf8.encode('hibiki:$token'))}',
      );
      final HttpClientResponse res = await req.close();
      final Map<String, dynamic> json =
          jsonDecode(await res.transform(utf8.decoder).join())
              as Map<String, dynamic>;
      return json['url'] as String;
    }

    Future<HttpClientResponse> get(
      String url, {
      Map<String, String> headers = const <String, String>{},
    }) async {
      final HttpClientRequest req = await http.getUrl(Uri.parse(url));
      headers.forEach(req.headers.set);
      return req.close();
    }

    test('带 ETag；If-Range 匹配 206、不匹配 200 全量、缺省（播放器 seek）照常 206', () async {
      final Uint8List source = _pattern(4096);
      await startServer(source);
      final String url = await streamUrl();
      final String etag = videoFileEtag(lib.videoFile);

      final HttpClientResponse full = await get(url);
      expect(full.statusCode, 200);
      expect(full.headers.value(HttpHeaders.etagHeader), etag);
      await full.drain<void>();

      final HttpClientResponse matched = await get(
        url,
        headers: <String, String>{'range': 'bytes=100-', 'if-range': etag},
      );
      expect(matched.statusCode, 206);
      expect(
        matched.headers.value(HttpHeaders.contentRangeHeader),
        'bytes 100-4095/4096',
      );
      await matched.drain<void>();

      final HttpClientResponse stale = await get(
        url,
        headers: <String, String>{
          'range': 'bytes=100-',
          'if-range': '"vid-4096-1"',
        },
      );
      expect(stale.statusCode, 200);
      expect(stale.headers.contentLength, 4096);
      await stale.drain<void>();

      final HttpClientResponse blind = await get(
        url,
        headers: <String, String>{'range': 'bytes=100-'},
      );
      expect(blind.statusCode, 206);
      await blind.drain<void>();
    });
  });
}
