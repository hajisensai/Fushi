import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/video/bluray/aacs_media_session.dart';
import 'package:fushi_engine/media/video/bluray/bluray_remote_title.dart';
import 'package:fushi_engine/media/video/ffmpeg_backend.dart';
import 'package:fushi_engine/media/video/live_transcode.dart';
import 'package:fushi_engine/sync/aggregate_snapshot.dart';
import 'package:fushi_engine/sync/bluray_clip_relay_pool.dart';
import 'package:fushi_engine/sync/collection_manifest.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:path/path.dart' as p;

import '../media/video/bluray_fixture.dart';

// 互联 client 播放蓝光标题：host 下发段表 + 按段供流（加密段经解密回环转发），
// 转码分段经共享蓝光输入改写。过去 host 把几 KB 的 `.mpls` 当视频直传。

/// 一张合成盘：标题 = 00001 [10.4,11.6) + 00002 [11.2,12.8) + 00001 [10.4,11.0)。
class _Disc {
  _Disc() {
    root = Directory.systemTemp.createTempSync('hbk_bd_srv');
    final Directory streams = Directory(p.join(root.path, 'BDMV', 'STREAM'))
      ..createSync(recursive: true);
    final Directory lists = Directory(p.join(root.path, 'BDMV', 'PLAYLIST'))
      ..createSync(recursive: true);
    // 小于一个 AACS 对齐单元：判为未加密，原样直出。
    clip1 = File(p.join(streams.path, '00001.m2ts'))
      ..writeAsBytesSync(List<int>.generate(64, (int i) => i));
    clip2 = File(p.join(streams.path, '00002.m2ts'))
      ..writeAsBytesSync(List<int>.generate(64, (int i) => 255 - i));
    playlist = File(p.join(lists.path, '00001.mpls'))
      ..writeAsBytesSync(
        buildMplsFixture(
          playItems: const <FixturePlayItem>[
            FixturePlayItem(
              clipId: '00001',
              inTimeTicks: 468000,
              outTimeTicks: 522000,
            ),
            FixturePlayItem(
              clipId: '00002',
              inTimeTicks: 504000,
              outTimeTicks: 576000,
            ),
            FixturePlayItem(
              clipId: '00001',
              inTimeTicks: 468000,
              outTimeTicks: 495000,
            ),
          ],
          marks: const <FixtureMark>[
            FixtureMark(playItemIndex: 0, timestampTicks: 468000),
            FixtureMark(playItemIndex: 1, timestampTicks: 504000),
          ],
        ),
      );
    plainVideo = File(p.join(root.path, 'plain.mp4'))
      ..writeAsBytesSync(<int>[1, 2, 3]);
  }

  late final Directory root;
  late final File clip1;
  late final File clip2;
  late final File playlist;
  late final File plainVideo;
}

class _FakeLibraryService implements FushiLibraryHostService {
  _FakeLibraryService(this.disc);

  final _Disc disc;

  @override
  Future<File?> resolveVideoFile(String id, {int episodeIndex = 0}) async =>
      switch (id) {
        'disc' => disc.playlist,
        'plain' => disc.plainVideo,
        _ => null,
      };

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
      throw UnimplementedError('${invocation.memberName} 不该被蓝光用例触达');
}

/// 探测替身：内嵌字幕枚举等 ffprobe 调用一律无流。
class _EmptyProbeBackend implements FfmpegBackend {
  @override
  Future<FfmpegRunResult> run(List<String> args, Duration timeout) async =>
      FfmpegRunResult(returnCode: 0, output: '');

  @override
  Future<FfmpegRunResult> runQuery(List<String> args, Duration timeout) =>
      run(args, timeout);

  @override
  Future<FfmpegRunResult> runProbe(List<String> args, Duration timeout) async =>
      FfmpegRunResult(
        returnCode: 0,
        output: jsonEncode(<String, Object?>{'streams': <Object?>[]}),
      );
}

/// 解密回环替身：00002 视为加密段，交给一个本机 HTTP 回环（返回「明文」字节）；
/// 其余段原样返回路径（未加密）。
class _FakeAacsSession extends AacsMediaSession {
  _FakeAacsSession(this.relayUrl, this.onClose);

  final String relayUrl;
  final void Function() onClose;

  @override
  Future<String> resolve(String path) async =>
      path.endsWith('00002.m2ts') ? relayUrl : path;

  @override
  Future<void> close() async => onClose();
}

void main() {
  const String token = 'test-token-bluray';
  late _Disc disc;
  late FushiSyncServer server;
  late String base;
  late HttpServer relay;
  late List<String?> relayRanges;
  late int closedSessions;
  late List<List<String>> runnerCalls;
  late bool stopped;
  final Uint8List decrypted = Uint8List.fromList(
    List<int>.generate(32, (int i) => 0x40 + i),
  );
  final HttpClient client = HttpClient();

  String authHeader() => 'Basic ${base64Encode(utf8.encode('hibiki:$token'))}';

  setUp(() async {
    disc = _Disc();
    stopped = false;
    relayRanges = <String?>[];
    closedSessions = 0;
    runnerCalls = <List<String>>[];
    relay = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    relay.listen((HttpRequest request) async {
      final String? range = request.headers.value(HttpHeaders.rangeHeader);
      relayRanges.add(range);
      final Match m = RegExp(r'bytes=(\d+)-(\d+)').firstMatch(range!)!;
      final int start = int.parse(m.group(1)!);
      final int end = int.parse(m.group(2)!);
      request.response
        ..statusCode = HttpStatus.partialContent
        ..headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-$end/${decrypted.length}',
        )
        ..contentLength = end - start + 1
        ..add(decrypted.sublist(start, end + 1));
      await request.response.close();
    });
    setFfmpegBackendForTesting(_EmptyProbeBackend());
    setTranscodeSegmentRunnerForTesting((List<String> args) async {
      runnerCalls.add(args);
      return Uint8List.fromList(<int>[0x47]);
    });
    server = FushiSyncServer(
      syncDataDir: Directory.systemTemp.createTempSync('hbk_bd_sync').path,
      port: 0,
      token: token,
      libraryService: _FakeLibraryService(disc),
      blurayClipRelays: BlurayClipRelayPool(
        openSession: () => _FakeAacsSession(
          'http://127.0.0.1:${relay.port}/relay/stream.m2ts',
          () => closedSessions++,
        ),
      ),
    );
    await server.start();
    base = 'http://127.0.0.1:${server.port}';
  });

  tearDown(() async {
    if (!stopped) await server.stop();
    await relay.close(force: true);
    setFfmpegBackendForTesting(null);
    setTranscodeSegmentRunnerForTesting(null);
    setTranscodeAvailableForTesting(null);
    disc.root.deleteSync(recursive: true);
  });

  Future<HttpClientResponse> get(
    String pathOrUrl, {
    bool withAuth = true,
    String? range,
  }) async {
    final Uri uri = pathOrUrl.startsWith('http')
        ? Uri.parse(pathOrUrl)
        : Uri.parse('$base$pathOrUrl');
    final HttpClientRequest req = await client.getUrl(uri);
    if (withAuth) req.headers.set('authorization', authHeader());
    if (range != null) req.headers.set(HttpHeaders.rangeHeader, range);
    return req.close();
  }

  Future<Map<String, dynamic>> streamUrl(String id, [String query = '']) async {
    final HttpClientResponse res = await get(
      '/api/library/videos/$id/streamurl$query',
    );
    expect(res.statusCode, 200);
    return jsonDecode(await res.transform(utf8.decoder).join())
        as Map<String, dynamic>;
  }

  Future<List<int>> body(HttpClientResponse res) async => <int>[
    for (final List<int> chunk in await res.toList()) ...chunk,
  ];

  test('光盘标题下发段表与 EDL（而不是把 .mpls 当视频直传）', () async {
    setTranscodeAvailableForTesting(false);
    final Map<String, dynamic> json = await streamUrl('disc');
    final BlurayRemoteTitle title = BlurayRemoteTitle.fromJson(
      json['discTitle'],
    )!;
    expect(title.duration, const Duration(milliseconds: 3400));
    expect(title.chapters, const <Duration>[
      Duration.zero,
      Duration(milliseconds: 1200),
    ]);
    expect(
      <String?>[
        for (final BlurayRemoteClip c in title.clips)
          Uri.parse(c.url).queryParameters['n'],
      ],
      <String>['0', '1', '0'],
      reason: '同一码流在段表里出现两次，只占一个分段号',
    );
    expect(title.clips.map((BlurayRemoteClip c) => c.inTimeTicks), <int>[
      468000,
      504000,
      468000,
    ]);
    for (final BlurayRemoteClip clip in title.clips) {
      expect(Uri.parse(clip.url).path, endsWith('/disc/bdclip.m2ts'));
    }
    // 旧 client 不认 discTitle，原样把 url 交给 libmpv：给它同一份 EDL。
    expect(json['url'], title.edlUri());
    expect(json['url'], startsWith('edl://'));
    expect(json['url'], isNot(contains('/stream?')));
    expect(json['transcoded'], isFalse);
    expect(json.containsKey('miningVideoUrl'), isFalse, reason: '转不了码就不给');
  });

  test('普通视频的 streamurl 不带 discTitle（老行为不变）', () async {
    final Map<String, dynamic> json = await streamUrl('plain');
    expect(json.containsKey('discTitle'), isFalse);
    expect(json['url'], contains('/stream?'));
  });

  test('未加密分段：豁免 Basic、按 token 直出且支持 Range', () async {
    final BlurayRemoteTitle title = BlurayRemoteTitle.fromJson(
      (await streamUrl('disc'))['discTitle'],
    )!;
    final HttpClientResponse res = await get(
      title.clips[0].url,
      withAuth: false,
      range: 'bytes=2-5',
    );
    expect(res.statusCode, HttpStatus.partialContent);
    expect(await body(res), <int>[2, 3, 4, 5]);
    expect(relayRanges, isEmpty, reason: '未加密段不经解密回环');
  });

  test('加密分段：经本次播放的解密回环转发，Range 原样透传', () async {
    final BlurayRemoteTitle title = BlurayRemoteTitle.fromJson(
      (await streamUrl('disc'))['discTitle'],
    )!;
    final HttpClientResponse res = await get(
      title.clips[1].url,
      withAuth: false,
      range: 'bytes=3-6',
    );
    expect(res.statusCode, HttpStatus.partialContent);
    expect(
      res.headers.value(HttpHeaders.contentRangeHeader),
      'bytes 3-6/${decrypted.length}',
    );
    expect(await body(res), decrypted.sublist(3, 7));
    expect(relayRanges, <String>['bytes=3-6']);

    // 同一次播放的后续请求复用同一个解密会话。
    await body(
      await get(title.clips[1].url, withAuth: false, range: 'bytes=0-1'),
    );
    expect(closedSessions, 0);
    stopped = true;
    await server.stop();
    expect(closedSessions, 1, reason: 'host 停机关掉解密回环、释放盘文件句柄');
  });

  test('分段端点的门：缺 token / 别的视频的 token / 越界段号 / 非光盘标题', () async {
    final BlurayRemoteTitle title = BlurayRemoteTitle.fromJson(
      (await streamUrl('disc'))['discTitle'],
    )!;
    final Uri clip = Uri.parse(title.clips[0].url);
    Future<int> status(Uri uri) async {
      final HttpClientResponse res = await get(uri.toString(), withAuth: false);
      await res.drain<void>();
      return res.statusCode;
    }

    expect(
      await status(clip.replace(queryParameters: <String, String>{'n': '0'})),
      401,
    );
    expect(
      await status(clip.replace(path: '/api/library/videos/plain/bdclip.m2ts')),
      403,
    );
    expect(
      await status(
        clip.replace(
          queryParameters: <String, String>{...clip.queryParameters, 'n': '2'},
        ),
      ),
      404,
    );
    final Map<String, dynamic> plain = await streamUrl('plain');
    final String plainToken = Uri.parse(
      plain['url'] as String,
    ).queryParameters['token']!;
    expect(
      await status(
        Uri.parse(
          '$base/api/library/videos/plain/bdclip.m2ts?token=$plainToken&n=0',
        ),
      ),
      404,
    );
  });

  test('光盘标题转码：时长取 MPLS，分段命令经蓝光输入改写', () async {
    final Map<String, dynamic> json = await streamUrl(
      'disc',
      '?maxWidth=1280&maxBitrate=3000000',
    );
    expect(json['transcoded'], isTrue);
    expect(json.containsKey('discTitle'), isFalse, reason: 'HLS 由 host 转出');
    final String playlist = await (await get(
      json['url'] as String,
      withAuth: false,
    )).transform(utf8.decoder).join();
    expect(playlist, contains('#EXTINF:3.400000,'));
    final String segment = RegExp(
      r'^hlsseg\.ts\?.*$',
      multiLine: true,
    ).firstMatch(playlist)!.group(0)!;
    final Uri playlistUri = Uri.parse(json['url'] as String);
    final HttpClientResponse seg = await get(
      playlistUri.resolve(segment).toString(),
      withAuth: false,
    );
    expect(seg.statusCode, 200);
    await seg.drain<void>();
    final List<String> args = runnerCalls.single;
    expect(args, isNot(contains(disc.playlist.path)));
    expect(args.join(' '), contains('-f concat'));
  });

  test('能转码的 host 给光盘标题附低清制卡流', () async {
    final Map<String, dynamic> json = await streamUrl('disc');
    expect(json['discTitle'], isNotNull);
    expect(json['miningVideoHasAudio'], isTrue);
    final Uri mining = Uri.parse(json['miningVideoUrl'] as String);
    expect(mining.path, endsWith('/disc/hls.m3u8'));
    final HttpClientResponse res = await get(
      mining.toString(),
      withAuth: false,
    );
    expect(res.statusCode, 200);
    expect(
      await res.transform(utf8.decoder).join(),
      contains('#EXT-X-ENDLIST'),
    );
  });
}
