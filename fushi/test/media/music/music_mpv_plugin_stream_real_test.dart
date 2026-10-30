import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/mpv_music_output_backend.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/plugin/music_plugins.dart';
import 'package:fushi_engine/media/video/ffmpeg_backend.dart';
import 'package:fushi_music/fushi_music.dart' show MusicPluginStream;
import 'package:media_kit/media_kit.dart';

/// 在线插件曲目在**真 libmpv** 上的取流边界：取流失败直接抛、连切时晚回来的取流作废、
/// 取流期间旧曲停掉且不冒充新曲上报位置、流地址 403 原位重取、预排下一首到期前重取。
///
/// 流由本机回环 HTTP 服务提供（`/ok/<文件>` 正常给，`/expired/<文件>` 回 403）。需要真实
/// libmpv（同 `music_mpv_backend_real_test.dart`：`FUSHI_TEST_LIBMPV` 或 Windows Debug 构建）。
String? _libmpvPath() {
  final String? override = Platform.environment['FUSHI_TEST_LIBMPV'];
  final String path = override ?? 'build/windows/x64/runner/Debug/libmpv-2.dll';
  return File(path).existsSync() ? File(path).absolute.path : null;
}

Future<String> _tone(Directory dir, String name, double seconds) async {
  final String out = '${dir.path}${Platform.pathSeparator}$name';
  final FfmpegRunResult r = await resolveFfmpegBackend().run(<String>[
    '-y',
    '-f',
    'lavfi',
    '-i',
    'sine=frequency=440:sample_rate=44100:duration=$seconds',
    '-ac',
    '2',
    '-c:a',
    'flac',
    out,
  ], const Duration(seconds: 60));
  if (!r.isSuccess) throw StateError('ffmpeg failed: ${r.failureSummary}');
  return out;
}

MusicPlayItem _plugin(String id, {int durationMs = 3000}) => MusicPlayItem(
  trackUid: 'plg-$id',
  path: musicPluginTrackPath('moe.test', id),
  title: id,
  durationMs: durationMs,
);

class _Recorder {
  _Recorder(MusicOutputBackend backend) {
    _sub = backend.events.listen(events.add);
  }

  final List<MusicBackendEvent> events = <MusicBackendEvent>[];
  late final StreamSubscription<MusicBackendEvent> _sub;

  Future<void> waitFor(
    bool Function() done, {
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final Stopwatch sw = Stopwatch()..start();
    while (!done()) {
      if (sw.elapsed > timeout) {
        throw TimeoutException('condition not met; events: $events');
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  bool positionPast(Duration d) => events.any(
    (MusicBackendEvent e) => e is MusicBackendPosition && e.position > d,
  );

  Future<void> cancel() => _sub.cancel();
}

void main() {
  final String? libmpv = _libmpvPath();
  final String? skip = libmpv == null
      ? 'Build Windows Debug or set FUSHI_TEST_LIBMPV to libmpv-2.dll'
      : null;
  Directory? tempDir;
  HttpServer? server;
  late String base;
  final List<String> served = <String>[];

  setUpAll(() async {
    if (libmpv == null) return;
    MediaKit.ensureInitialized(libmpv: libmpv);
    final Directory dir = tempDir = Directory.systemTemp.createTempSync(
      'fushi_music_plugin_',
    );
    await _tone(dir, 'a.flac', 3);
    await _tone(dir, 'b.flac', 3);
    final HttpServer s = server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    base = 'http://127.0.0.1:${s.port}';
    s.listen((HttpRequest req) async {
      served.add(req.uri.path);
      final List<String> seg = req.uri.pathSegments;
      if (seg.length != 2 || seg.first == 'expired') {
        req.response.statusCode = HttpStatus.forbidden;
        await req.response.close();
        return;
      }
      final File f = File('${dir.path}${Platform.pathSeparator}${seg.last}');
      final List<int> bytes = f.readAsBytesSync();
      req.response.headers
        ..contentType = ContentType('audio', 'flac')
        ..contentLength = bytes.length;
      req.response.add(bytes);
      await req.response.close();
    });
  });
  tearDownAll(() async {
    await server?.close(force: true);
    tempDir?.deleteSync(recursive: true);
  });
  setUp(served.clear);

  MpvMusicOutputBackend backend(
    MusicPluginStreamResolver resolver, {
    int Function()? nowMs,
  }) => MpvMusicOutputBackend(
    configuration: const PlayerConfiguration(
      vo: 'null',
      title: 'Fushi Music plugin test',
      logLevel: MPVLogLevel.warn,
    ),
    initialProperties: const <String, String>{'ao': 'null'},
    pluginStreamResolver: resolver,
    nowMs: nowMs,
  );

  const MusicOutputSettings settings = MusicOutputSettings(
    gapless: true,
    replayGain: MusicReplayGainMode.off,
  );

  test(
    '取流失败：openPair 直接抛「拿不到流」（带曲目），不上报事件',
    () async {
      final MpvMusicOutputBackend b = backend(
        (String path) async =>
            throw const MusicPluginStreamUnavailable('该曲目需要会员'),
      );
      final _Recorder rec = _Recorder(b);
      try {
        await b.applySettings(settings);
        await expectLater(
          b.openPair(_plugin('vip'), null, play: true),
          throwsA(
            isA<MusicTrackOpenException>().having(
              (MusicTrackOpenException e) =>
                  (e.failure.reason, e.failure.trackUid, e.failure.message),
              'failure',
              (MusicPlaybackFailure.trackUnavailable, 'plg-vip', '该曲目需要会员'),
            ),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 200));
        expect(rec.events.whereType<MusicBackendFailed>(), isEmpty);
      } finally {
        await rec.cancel();
        await b.dispose();
      }
    },
    skip: skip,
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    '连切：先发起、后回来的取流作废；出声的是最后选的那首；取流期间旧曲停、不报位置',
    () async {
      final Completer<void> slowA = Completer<void>();
      final MpvMusicOutputBackend b = backend((String path) async {
        final String id = parseMusicPluginTrackPath(path)!.trackId;
        if (id == 'a') await slowA.future;
        return MusicPluginStream(url: '$base/ok/$id.flac');
      });
      final _Recorder rec = _Recorder(b);
      try {
        await b.applySettings(settings);
        // 先放 b，确认在出声。
        await b.openPair(_plugin('b'), null, play: true);
        await rec.waitFor(
          () => rec.positionPast(const Duration(milliseconds: 300)),
        );
        // 切到 a：取流卡住。旧曲 b 应已停下，这段时间不再有位置上报。
        final Future<void> toA = b.openPair(_plugin('a'), null, play: true);
        await Future<void>.delayed(const Duration(milliseconds: 150));
        rec.events.clear();
        await Future<void>.delayed(const Duration(milliseconds: 600));
        expect(
          rec.events.whereType<MusicBackendPosition>().where(
            (MusicBackendPosition p) => p.position > Duration.zero,
          ),
          isEmpty,
          reason: '取流期间旧曲不能冒充新曲上报位置',
        );
        // 再切回 b（立即取到）：之后 a 的取流才回来，必须作废。
        await b.openPair(_plugin('b'), null, play: true);
        slowA.complete();
        await toA;
        await Future<void>.delayed(const Duration(milliseconds: 300));
        final List<Media> medias = b.debugPlayer.state.playlist.medias;
        expect(medias.map((Media m) => m.uri), <String>['$base/ok/b.flac']);
        expect(served.where((String p) => p.endsWith('/a.flac')), isEmpty);
      } finally {
        await rec.cancel();
        await b.dispose();
      }
    },
    skip: skip,
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    '流地址 403：原位重取一次接着放，不报失败；再被拒才按拿不到流报',
    () async {
      int calls = 0;
      bool alwaysExpired = false;
      final MpvMusicOutputBackend b = backend((String path) async {
        calls++;
        final String kind = alwaysExpired || calls == 1 ? 'expired' : 'ok';
        return MusicPluginStream(url: '$base/$kind/a.flac');
      });
      final _Recorder rec = _Recorder(b);
      try {
        await b.applySettings(settings);
        await b.openPair(_plugin('a'), null, play: true);
        await rec.waitFor(
          () => rec.positionPast(const Duration(milliseconds: 300)),
        );
        expect(calls, 2);
        expect(rec.events.whereType<MusicBackendFailed>(), isEmpty);

        alwaysExpired = true;
        calls = 0;
        rec.events.clear();
        await b.openPair(_plugin('a'), null, play: true);
        await rec.waitFor(
          () => rec.events.whereType<MusicBackendFailed>().isNotEmpty,
        );
        final MusicBackendFailed f = rec.events
            .whereType<MusicBackendFailed>()
            .single;
        expect(f.reason, MusicPlaybackFailure.trackUnavailable);
        expect(f.trackUid, 'plg-a');
        expect(calls, 2, reason: '只重取一次');
      } finally {
        await rec.cancel();
        await b.dispose();
      }
    },
    skip: skip,
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    '预排的插件下一首：起播后异步补进播放列表；流地址到期前重取并换掉那一项',
    () async {
      final Map<String, int> calls = <String, int>{};
      // 墙钟钉住：b 的地址在「现在 + 余量 + 400 ms」过期 → 约 400 ms 后重取。
      const int now = 1000000;
      final MpvMusicOutputBackend b = backend((String path) async {
        final String id = parseMusicPluginTrackPath(path)!.trackId;
        final int n = calls[id] = (calls[id] ?? 0) + 1;
        return MusicPluginStream(
          url: '$base/ok/$id.flac?v=$n',
          // 只有第一次给的地址会到期：重取后不再循环重取。
          expiresAt: id == 'b' && n == 1
              ? now + kMusicPluginStreamRefreshMargin.inMilliseconds + 400
              : null,
        );
      }, nowMs: () => now);
      final _Recorder rec = _Recorder(b);
      try {
        await b.applySettings(settings);
        await b.openPair(_plugin('a'), _plugin('b'), play: false);
        await rec.waitFor(
          () => b.debugPlayer.state.playlist.medias.length == 2,
        );
        expect(b.debugPlayer.state.playlist.medias.last.uri, endsWith('?v=1'));
        await rec.waitFor(() => (calls['b'] ?? 0) >= 2);
        await rec.waitFor(
          () =>
              b.debugPlayer.state.playlist.medias.length == 2 &&
              b.debugPlayer.state.playlist.medias.last.uri.endsWith('?v=2'),
        );
        expect(
          b.debugPlayer.state.playlist.medias.first.uri,
          '$base/ok/a.flac?v=1',
          reason: '当前曲不动',
        );
        // 暂停着也到点重取（长暂停后续播不会拿过期地址），之后照常无缝推进到 b。
        await b.play();
        await rec.waitFor(
          () => rec.events.any(
            (MusicBackendEvent e) =>
                e is MusicBackendAdvanced && e.trackUid == 'plg-b',
          ),
        );
      } finally {
        await rec.cancel();
        await b.dispose();
      }
    },
    skip: skip,
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
