import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/foundation/pref_store.dart';
import 'package:fushi_engine/media/video/ffmpeg_backend.dart';
import 'package:fushi_engine/media/video/live_transcode.dart';
import 'package:fushi_engine/sync/aggregate_snapshot.dart';
import 'package:fushi_engine/sync/collection_manifest.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:fushi_engine/sync/interconnect_transcode_prefs.dart';

/// 视频方法真实、其余存根的库服务（对照 `fushi_sync_server_video_test.dart`）。
class _FakeLibraryService implements FushiLibraryHostService {
  _FakeLibraryService() {
    final Directory tmp = Directory.systemTemp.createTempSync('hbk_tc_test');
    videoFile = File('${tmp.path}/sample.mp4')
      ..writeAsBytesSync(<int>[1, 2, 3, 4, 5, 6, 7, 8]);
  }

  late final File videoFile;

  @override
  Future<List<RemoteVideoInfo>> listVideos() async => <RemoteVideoInfo>[
    RemoteVideoInfo(id: 'v1', title: 'Sample', sizeBytes: 8),
  ];

  @override
  Future<File?> resolveVideoFile(String id, {int episodeIndex = 0}) async =>
      id == 'v1' ? videoFile : null;

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
      throw UnimplementedError('${invocation.memberName} 不该被转码用例触达');
}

/// ffprobe 替身：只回一个固定时长，让 playlist 的段数可预期。
class _FixedDurationBackend implements FfmpegBackend {
  _FixedDurationBackend(this.durationSeconds);

  final double? durationSeconds;

  @override
  Future<FfmpegRunResult> run(List<String> args, Duration timeout) async =>
      FfmpegRunResult(returnCode: 0, output: '');

  @override
  Future<FfmpegRunResult> runProbe(List<String> args, Duration timeout) async {
    final double? d = durationSeconds;
    if (d == null) return FfmpegRunResult(returnCode: 1, output: '');
    return FfmpegRunResult(
      returnCode: 0,
      output: jsonEncode(<String, Object?>{
        'format': <String, Object?>{'duration': '$d'},
        'streams': <Object?>[],
      }),
    );
  }
}

class _MemoryPrefs implements PrefStore {
  _MemoryPrefs([Map<String, Object?>? seed])
    : _values = <String, Object?>{...?seed};

  final Map<String, Object?> _values;

  @override
  dynamic getPref(String key, {dynamic defaultValue}) =>
      _values.containsKey(key) ? _values[key] : defaultValue;

  @override
  Future<void> setPref(String key, dynamic value) async => _values[key] = value;
}

// ── 合成分段（假 ffmpeg 的产物）─────────────────────────────────────────────
//
// TS 分段是自描述的，host 对 ffmpeg 产物**零改写**（BUG-2630：时间轴由
// `-output_ts_offset` 平移，不再有 fMP4 时代的剥 ftyp/moov + 改 tfdt）。所以假
// 产物只要能被逐字节认出来：三个 188 字节的 TS 包，同步字节 0x47 起头。
Uint8List _syntheticSegment() => Uint8List.fromList(
  List<int>.generate(188 * 3, (int i) => i % 188 == 0 ? 0x47 : i & 0xff),
);

void main() {
  late FushiSyncServer server;
  late _FakeLibraryService lib;
  late String base;
  late List<List<String>> runnerCalls;
  const String token = 'test-token-transcode';

  String authHeader() => 'Basic ${base64Encode(utf8.encode('hibiki:$token'))}';

  Future<void> startServer({
    PrefStore? prefs,
    double? durationSeconds = 15.5,
    bool transcodeAvailable = true,
  }) async {
    setFfmpegBackendForTesting(_FixedDurationBackend(durationSeconds));
    runnerCalls = <List<String>>[];
    if (transcodeAvailable) {
      setTranscodeSegmentRunnerForTesting((List<String> args) async {
        runnerCalls.add(args);
        return _syntheticSegment();
      });
    } else {
      setTranscodeSegmentRunnerForTesting(null);
      setTranscodeAvailableForTesting(false);
    }
    lib = _FakeLibraryService();
    server = FushiSyncServer(
      syncDataDir: Directory.systemTemp.createTempSync('hbk_tc_srv').path,
      port: 0,
      token: token,
      allowLan: false,
      libraryService: lib,
      prefs: prefs,
    );
    await server.start();
    base = 'http://127.0.0.1:${server.port}';
  }

  tearDown(() async {
    setFfmpegBackendForTesting(null);
    setTranscodeSegmentRunnerForTesting(null);
    setTranscodeAvailableForTesting(null);
    await server.stop();
  });

  final HttpClient client = HttpClient();

  Future<HttpClientResponse> get(String path, {bool withAuth = true}) async {
    final HttpClientRequest req = await client.getUrl(Uri.parse('$base$path'));
    if (withAuth) req.headers.set('authorization', authHeader());
    return req.close();
  }

  Future<Map<String, dynamic>> getJson(String path) async {
    final HttpClientResponse res = await get(path);
    return jsonDecode(await res.transform(utf8.decoder).join())
        as Map<String, dynamic>;
  }

  Future<List<int>> getBytes(String path, {bool withAuth = false}) async {
    final HttpClientResponse res = await get(path, withAuth: withAuth);
    return <int>[for (final List<int> chunk in await res.toList()) ...chunk];
  }

  group('能力协商', () {
    test('能转码的 host 报 videoTranscode: true', () async {
      await startServer();
      final Map<String, dynamic> caps = await getJson('/api/capabilities');
      expect(
        (caps['liveLibrary'] as Map<String, dynamic>)['videoTranscode'],
        isTrue,
      );
    });

    test('跑不了 ffmpeg 子进程的 host（移动端）如实报 false', () async {
      await startServer(transcodeAvailable: false);
      final Map<String, dynamic> caps = await getJson('/api/capabilities');
      expect(
        (caps['liveLibrary'] as Map<String, dynamic>)['videoTranscode'],
        isFalse,
      );
    });

    test('用户关掉开关后报 false（实时读偏好，不必重启互联服务）', () async {
      final _MemoryPrefs prefs = _MemoryPrefs(<String, Object?>{
        kInterconnectTranscodeEnabledPref: false,
      });
      await startServer(prefs: prefs);
      expect(
        ((await getJson('/api/capabilities'))['liveLibrary']
            as Map<String, dynamic>)['videoTranscode'],
        isFalse,
      );
      await prefs.setPref(kInterconnectTranscodeEnabledPref, true);
      expect(
        ((await getJson('/api/capabilities'))['liveLibrary']
            as Map<String, dynamic>)['videoTranscode'],
        isTrue,
      );
    });
  });

  group('streamurl 画质协商', () {
    test('不报画质档 → 老行为逐字不变（整文件直传）', () async {
      await startServer();
      final Map<String, dynamic> json = await getJson(
        '/api/library/videos/v1/streamurl',
      );
      expect(json['transcoded'], isFalse);
      expect(json['streamIsOriginalContainer'], isTrue);
      expect(json['url'], contains('/stream?'));
      expect(runnerCalls, isEmpty);
    });

    test('报了画质档 → 指向 HLS playlist，并如实说容器已换', () async {
      await startServer();
      final Map<String, dynamic> json = await getJson(
        '/api/library/videos/v1/streamurl?maxWidth=854&maxBitrate=800000',
      );
      expect(json['transcoded'], isTrue);
      // BUG-2590 的既有语义：转码把容器整个换掉，内嵌字幕不能再指望播放器自绘。
      expect(json['streamIsOriginalContainer'], isFalse);
      expect(json['url'], contains('/hls.m3u8?token='));
    });

    test('host 关了开关 → 静默退回直传（不是报错）', () async {
      await startServer(
        prefs: _MemoryPrefs(<String, Object?>{
          kInterconnectTranscodeEnabledPref: false,
        }),
      );
      final Map<String, dynamic> json = await getJson(
        '/api/library/videos/v1/streamurl?maxWidth=854&maxBitrate=800000',
      );
      expect(json['transcoded'], isFalse);
      expect(json['url'], contains('/stream?'));
    });

    test('探不出时长 → 退回直传（HLS 要按时长切段，没时长就没法生成）', () async {
      await startServer(durationSeconds: null);
      final Map<String, dynamic> json = await getJson(
        '/api/library/videos/v1/streamurl?maxWidth=854&maxBitrate=800000',
      );
      expect(json['transcoded'], isFalse);
      expect(json['url'], contains('/stream?'));
    });
  });

  group('HLS 端点', () {
    late String tokenQuery;

    Future<void> issue() async {
      final Map<String, dynamic> json = await getJson(
        '/api/library/videos/v1/streamurl?maxWidth=854&maxBitrate=800000',
      );
      tokenQuery = Uri.parse(json['url'] as String).query;
    }

    test('playlist：VOD + 无 MAP + 按时长切段，且相对 URI', () async {
      await startServer();
      await issue();
      final HttpClientResponse res = await get(
        '/api/library/videos/v1/hls.m3u8?$tokenQuery',
        withAuth: false,
      );
      expect(res.statusCode, 200);
      expect(
        res.headers.contentType?.mimeType,
        'application/vnd.apple.mpegurl',
      );
      final String text = await res.transform(utf8.decoder).join();
      expect(text, contains('#EXT-X-PLAYLIST-TYPE:VOD'));
      // BUG-2630：TS 分段没有初始化段；有 MAP 就是又回到了 FFmpeg 6.1 客户端
      // seek 必坏的 fMP4 形态。
      expect(text, isNot(contains('#EXT-X-MAP')));
      // 15.5 秒 → 6+6+3.5
      expect(RegExp('hlsseg\\.ts\\?').allMatches(text).length, 3);
      expect(text, contains('#EXTINF:3.500000,'));
      // 相对 URI：不重建 host/端口，反代与多网卡后面才不会拼出连不上的地址。
      expect(text, isNot(contains('http://')));
    });

    test('分段原样透传 ffmpeg 的 TS 产物，时间轴平移交给 -output_ts_offset', () async {
      await startServer();
      await issue();
      runnerCalls.clear();
      final HttpClientResponse res = await get(
        '/api/library/videos/v1/hlsseg.ts?$tokenQuery&n=2',
        withAuth: false,
      );
      expect(res.statusCode, 200);
      expect(res.headers.contentType?.mimeType, 'video/mp2t');
      final List<int> seg2 = await res.fold<List<int>>(
        <int>[],
        (List<int> acc, List<int> chunk) => acc..addAll(chunk),
      );
      expect(seg2, _syntheticSegment(), reason: 'host 不改写 TS 分段的一个字节');
      // 第 2 段起点 12 秒：不平移的话三段时间戳全落在 0..段长 上互相重叠，播放器
      // 只认得第一段（首版 fMP4 是在字节层改 tfdt，TS 交给 muxer 自己平移）。
      final List<String> args = runnerCalls.single;
      expect(args[args.indexOf('-output_ts_offset') + 1], '12.000');
      expect(args[args.indexOf('-f') + 1], 'mpegts');
    });

    test('每段按自己的时间范围调 ffmpeg（输入 seek，不从头解码）', () async {
      await startServer();
      await issue();
      runnerCalls.clear();
      await getBytes('/api/library/videos/v1/hlsseg.ts?$tokenQuery&n=2');
      expect(runnerCalls, hasLength(1));
      final List<String> args = runnerCalls.single;
      expect(args[args.indexOf('-ss') + 1], '12.000');
      // 末段按真实时长收尾，不越过片尾。
      expect(args[args.indexOf('-to') + 1], '15.500');
      expect(args.indexOf('-ss'), lessThan(args.indexOf('-i')));
    });

    test('query 改不动已签发 token 上的画质档（不是「在 host 上起任意 ffmpeg」）', () async {
      await startServer();
      await issue(); // 854 / 800 kbps
      runnerCalls.clear();
      // 拿着合法 token 追加一组更高的档位参数：实际 ffmpeg 参数必须仍是签发时那一档。
      // 这几条路径按设计豁免 Basic，档位若能从 query 取，就等于把「在 host 上起一个
      // 任意参数的 ffmpeg」敞开给 URL 持有者。
      await getBytes(
        '/api/library/videos/v1/hlsseg.ts?$tokenQuery&n=0'
        '&maxWidth=7680&maxBitrate=99999999',
      );
      expect(runnerCalls, hasLength(1));
      final List<String> args = runnerCalls.single;
      expect(args.join(' '), contains('854'), reason: '档位来自 token，不是 query');
      expect(args.join(' '), isNot(contains('7680')));
      expect(args.join(' '), isNot(contains('99999999')));
    });

    test('ffmpeg 失败 → 503（不装作成功返回空段：空段在播放器那头是黑屏转圈）', () async {
      await startServer();
      await issue();
      setTranscodeSegmentRunnerForTesting((List<String> args) async {
        throw TranscodeFailure(1, 'boom');
      });
      expect(
        (await get(
          '/api/library/videos/v1/hlsseg.ts?$tokenQuery&n=0',
          withAuth: false,
        )).statusCode,
        503,
      );
    });

    test('并发闸门：同时在跑的转码不超过上限，排空后名额不泄漏', () async {
      // runner override 在取名额**之前**就 return，所以闸门本身（队列交棒、排空
      // 回零）只能由 runGuardedTranscodeForTesting 直接验。
      int live = 0;
      int peak = 0;
      final List<Completer<void>> gates = <Completer<void>>[];
      final List<Future<void>> runs = <Future<void>>[];
      for (int i = 0; i < kMaxConcurrentTranscodes + 2; i++) {
        final Completer<void> gate = Completer<void>();
        gates.add(gate);
        runs.add(
          runGuardedTranscodeForTesting(() async {
            live++;
            if (live > peak) peak = live;
            await gate.future;
            live--;
          }),
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(peak, kMaxConcurrentTranscodes, reason: '多出来的必须排队');
      expect(liveTranscodeCount, kMaxConcurrentTranscodes);
      for (final Completer<void> gate in gates) {
        gate.complete();
        await Future<void>.delayed(Duration.zero);
      }
      await Future.wait(runs);
      expect(liveTranscodeCount, 0, reason: '排空后计数回零，名额不泄漏');
    });

    test('段下标越界 → 404', () async {
      await startServer();
      await issue();
      expect(
        (await get(
          '/api/library/videos/v1/hlsseg.ts?$tokenQuery&n=3',
          withAuth: false,
        )).statusCode,
        404,
      );
      expect(
        (await get(
          '/api/library/videos/v1/hlsseg.ts?$tokenQuery&n=-1',
          withAuth: false,
        )).statusCode,
        404,
      );
      expect(
        (await get(
          '/api/library/videos/v1/hlsseg.ts?$tokenQuery',
          withAuth: false,
        )).statusCode,
        404,
      );
    });
  });

  group('鉴权', () {
    test('缺 token → 401；错 token → 403', () async {
      await startServer();
      expect(
        (await get(
          '/api/library/videos/v1/hls.m3u8',
          withAuth: false,
        )).statusCode,
        401,
      );
      expect(
        (await get(
          '/api/library/videos/v1/hls.m3u8?token=bogus',
          withAuth: false,
        )).statusCode,
        403,
      );
    });

    test('直传 token 点不动转码端点（画质档绑在 token 上，不从 query 取）', () async {
      await startServer();
      // 不带画质档签发 → token 上没有 profile。
      final Map<String, dynamic> plain = await getJson(
        '/api/library/videos/v1/streamurl',
      );
      final String q = Uri.parse(plain['url'] as String).query;
      expect(
        (await get(
          '/api/library/videos/v1/hls.m3u8?$q',
          withAuth: false,
        )).statusCode,
        404,
      );
      expect(
        (await get(
          '/api/library/videos/v1/hlsseg.ts?$q&n=0',
          withAuth: false,
        )).statusCode,
        404,
      );
      // 一次 ffmpeg 都不该被点起来。
      expect(runnerCalls, isEmpty);
    });

    test('token 只对签发它的那个视频有效', () async {
      await startServer();
      final Map<String, dynamic> json = await getJson(
        '/api/library/videos/v1/streamurl?maxWidth=854&maxBitrate=800000',
      );
      final String q = Uri.parse(json['url'] as String).query;
      expect(
        (await get(
          '/api/library/videos/other/hls.m3u8?$q',
          withAuth: false,
        )).statusCode,
        403,
      );
    });
  });
}
