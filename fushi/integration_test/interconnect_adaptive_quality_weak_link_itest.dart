// 互联自适应画质在**真 app + 真 libmpv + 真 ffmpeg host** 上的差网降档取证
// （BUG-4459 及其取舍 T4）。
//
// 判据本身由 `test/sync/interconnect_adaptive_quality_test.dart` 按拍钉死；这里验的是
// 判据的输入在真播放器上长什么样、以及整条链路（1 Hz 采样 → 决策 → 释放旧流 → 重新
// 取流 → 回到原位置）在限速链路上真能把画质降下来并继续播：
//
//   A 段  不限速（回环 = 局域网），每 4 秒往前 seek 一次，持续 40 秒
//         → 一直是原画（高频 seek 不误伤局域网）。
//   B 段  限速到源码率的 0.8 倍，seek 节奏不变
//         → 降档。每次 seek 只缓冲两三拍，缓冲没见底就又 seek 走了，没有一拍「真卡顿」：
//           只看拍数的旧判据在这里永不降档（取舍 T4）。
//   C 段  限速到 2.5 Mbit/s，不再 seek
//         → 一路降到最低档（720p·2 Mbps），之后位置继续前进。
//
// 每秒打一行 `[weak-link-itest]`：位置、是否缓冲、缓冲深度、当前档。
//
// host 用 `packages/fushi_engine/tool/interconnect_video_host_probe.dart` 起（真 ffmpeg，
// 能转码）；限速由本测试进程内的 TCP 转发代理做（只转字节，TLS 与指纹钉扎照常）。
// 样片要 ≥ 200 秒、码率恒定在 `FUSHI_REMOTE_SOURCE_BITRATE` 附近（默认 8 Mbps）。
//
// 跑法（Windows 离屏）：
//   $env:FUSHI_FFMPEG = '<ffmpeg.exe>'; $env:FUSHI_FFPROBE = '<ffprobe.exe>'
//   dart run tool/interconnect_video_host_probe.dart --video <clip.mp4> --port 45777
//   .\fushi\tool\run_windows_itest.ps1 integration_test\interconnect_adaptive_quality_weak_link_itest.dart `
//     -DartDefine @('FUSHI_REMOTE_HOST_URL=https://127.0.0.1:45777',
//                   'FUSHI_REMOTE_HOST_FP=<探针打印的 fingerprint>',
//                   'FUSHI_REMOTE_HOST_TOKEN=<探针打印的 token>',
//                   'FUSHI_REMOTE_VIDEO_ID=video/probe-clip')
import 'dart:async';
import 'dart:io';
import 'dart:math' show min;

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:fushi/src/models/app_model.dart' show AppModel;
import 'package:fushi/src/pages/implementations/video_fushi_page.dart';
import 'package:fushi/src/sync/interconnect_adaptive_quality.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi/src/sync/interconnect_video_quality.dart';
import 'package:fushi/src/sync/remote_video_client.dart'
    show kRemoteVideoQualityAuto;
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';

import 'helpers/library_fixture.dart' show readyAppModel;
import 'support/itest_startup_guard.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

const String _hostUrl = String.fromEnvironment('FUSHI_REMOTE_HOST_URL');
const String _hostFingerprint = String.fromEnvironment('FUSHI_REMOTE_HOST_FP');
const String _hostToken = String.fromEnvironment('FUSHI_REMOTE_HOST_TOKEN');
const String _videoId = String.fromEnvironment(
  'FUSHI_REMOTE_VIDEO_ID',
  defaultValue: 'video/probe-clip',
);
const int _sourceBitrate = int.fromEnvironment(
  'FUSHI_REMOTE_SOURCE_BITRATE',
  defaultValue: 8000000,
);

/// C 段的链路带宽：只撑得住最低档（720p·2 Mbps + 音频）。
const int _weakLinkBitsPerSecond = 2500000;

/// seek 循环的周期（秒）与每次往前跳的距离（毫秒，跳出已缓冲的范围）。
const int _seekPeriodSeconds = 4;
const int _seekJumpMs = 20000;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('adaptive quality steps down on a throttled interconnect link', (
    WidgetTester tester,
  ) async {
    await runFushiItest(
      label: 'interconnect-adaptive-quality-weak-link',
      body: () async {
        if (_hostUrl.isEmpty ||
            _hostFingerprint.isEmpty ||
            _hostToken.isEmpty) {
          fail(
            '本测试要一台带真 ffmpeg 的外部互联 host：给齐 FUSHI_REMOTE_HOST_URL / '
            'FUSHI_REMOTE_HOST_FP / FUSHI_REMOTE_HOST_TOKEN（见文件头）',
          );
        }
        await launchFushiTestApp();
        expect(await waitForHome(tester), isTrue);
        final AppModel appModel = await readyAppModel(tester);
        final SyncRepository repo = SyncRepository(appModel.database);
        final List<FushiClientUrl> oldUrls = await repo.getFushiClientUrls();
        final String? oldToken = await repo.getFushiClientToken();
        final NavigatorState navigator = tester.state<NavigatorState>(
          find.byType(Navigator).first,
        );
        final int oldQuality =
            appModel.prefsRepo.interconnectQualityPresetIndex;
        final _ThrottledTcpProxy proxy = await _ThrottledTcpProxy.start(
          Uri.parse(_hostUrl).port,
        );
        try {
          final String baseUrl = 'https://127.0.0.1:${proxy.port}';
          await appModel.prefsRepo.setInterconnectQualityPresetIndex(
            kRemoteVideoQualityAuto,
          );
          await repo.setFushiClientUrls(<FushiClientUrl>[
            FushiClientUrl(
              url: baseUrl,
              fingerprintSha256: _hostFingerprint,
              token: _hostToken,
            ),
          ]);
          await repo.setFushiClientToken(_hostToken);
          final InterconnectSyncBackend backend =
              InterconnectSyncBackend.withProbe(
                (String url, String tok) async => true,
              );
          expect(await backend.restoreAuth(repo), isTrue);
          await backend.authenticate(repo: repo);

          unawaited(
            navigator.push<void>(
              MaterialPageRoute<void>(
                builder: (_) => VideoFushiPage.neutralizedRemote(
                  info: const RemoteVideoInfo(
                    id: _videoId,
                    title: 'weak link clip',
                  ),
                  repo: VideoBookRepository(appModel.database),
                  client: backend,
                ),
              ),
            ),
          );

          VideoFushiTestHooks? readHooks() {
            if (find.byType(VideoFushiPage).evaluate().isEmpty) return null;
            return tester.state<State<VideoFushiPage>>(
                  find.byType(VideoFushiPage),
                )
                as VideoFushiTestHooks;
          }

          bool ready = false;
          for (int i = 0; i < 240; i++) {
            await tester.pump(const Duration(milliseconds: 250));
            if (readHooks()?.debugPositionMs != null) {
              ready = true;
              break;
            }
          }
          expect(ready, isTrue, reason: '远端流控制器应就绪');
          expect(
            backend.hostTranscodeAvailable,
            isTrue,
            reason: 'host 要能转码（探针要带 FUSHI_FFMPEG / FUSHI_FFPROBE）',
          );
          await readHooks()!.debugPlay();

          final Stopwatch wall = Stopwatch()..start();
          // 跑 [seconds] 秒（或 [until] 成立），逐秒留痕；[seek] 时按周期往前 seek。
          // 每秒重新取 hooks：换档会重建 controller，页面 State 不变但读数来源变了。
          Future<int> run(
            String phase,
            int seconds, {
            required bool seek,
            bool Function()? until,
          }) async {
            int bufferingSeconds = 0;
            for (int s = 0; s < seconds; s++) {
              for (int i = 0; i < 4; i++) {
                await tester.pump(const Duration(milliseconds: 250));
              }
              final VideoFushiTestHooks hooks = readHooks()!;
              final int pos = hooks.debugPositionMs ?? 0;
              final int dur = hooks.debugDurationMs ?? 0;
              final bool buffering = hooks.debugIsBuffering;
              if (buffering) bufferingSeconds++;
              bool didSeek = false;
              if (seek && s % _seekPeriodSeconds == _seekPeriodSeconds - 1) {
                // 离片尾留足余量：缓冲铺到片尾后的读数不算（另有单测）。
                final int target = pos + _seekJumpMs < dur - 60000
                    ? pos + _seekJumpMs
                    : 10000;
                await hooks.debugSeekMs(target);
                didSeek = true;
              }
              debugPrint(
                '[weak-link-itest] $phase t=${wall.elapsed.inSeconds}s '
                'pos=${(pos / 1000).toStringAsFixed(1)} '
                'buf=${buffering ? 1 : 0} '
                'cache=${hooks.debugNetworkCacheSeconds?.toStringAsFixed(2)} '
                'index=${backend.adaptiveQualityIndex} '
                'limit=${proxy.bytesPerSecond}'
                '${didSeek ? ' SEEK' : ''}',
              );
              if (until != null && until()) break;
            }
            return bufferingSeconds;
          }

          // A：局域网，高频 seek。跑过冷却期（30 拍）再多 10 秒。
          await run('A', kAdaptiveCooldownTicks + 10, seek: true);
          expect(
            backend.adaptiveQualityIndex,
            -1,
            reason: '不限速的回环链路上高频 seek 不该降档',
          );

          // B：0.8 倍源码率，seek 节奏不变。
          proxy.bytesPerSecond = (_sourceBitrate * 0.8 / 8).round();
          final Stopwatch toDrop = Stopwatch()..start();
          await run(
            'B',
            75,
            seek: true,
            until: () => backend.adaptiveQualityIndex != -1,
          );
          debugPrint(
            '[weak-link-itest] B dropped=${backend.adaptiveQualityIndex} '
            'after=${toDrop.elapsed.inSeconds}s',
          );
          expect(
            backend.adaptiveQualityIndex,
            isNot(-1),
            reason: '吞吐只有源码率 0.8 倍的链路上高频 seek 应降档（取舍 T4）',
          );

          // C：只撑得住最低档的链路，不 seek。
          proxy.bytesPerSecond = _weakLinkBitsPerSecond ~/ 8;
          final int lowest = kInterconnectQualityPresets.length - 1;
          await run(
            'C',
            170,
            seek: false,
            until: () => backend.adaptiveQualityIndex == lowest,
          );
          expect(
            backend.adaptiveQualityIndex,
            lowest,
            reason: '2.5 Mbit/s 的链路只撑得住最低档',
          );
          // 换到最低档后先让它起播稳定，再量 20 秒墙钟里位置前进多少。
          await run('C-settle', 12, seek: false);
          final int before = readHooks()!.debugPositionMs ?? 0;
          final int stalled = await run('C-play', 20, seek: false);
          final int advanced = (readHooks()!.debugPositionMs ?? 0) - before;
          debugPrint(
            '[weak-link-itest] FINAL index=${backend.adaptiveQualityIndex} '
            'advancedMs=$advanced bufferingSeconds=$stalled '
            'forwardedBytes=${proxy.forwardedBytes}',
          );
          expect(
            advanced,
            greaterThan(14000),
            reason: '降到撑得住的档之后应基本连续播放（20 秒里前进 >14 秒）',
          );
          expect(readHooks()!.debugLoadFailed, isFalse);
        } finally {
          await navigator.maybePop();
          for (int i = 0; i < 40; i++) {
            await tester.pump(const Duration(milliseconds: 100));
            if (find.byType(VideoFushiPage).evaluate().isEmpty) break;
          }
          await proxy.close();
          await repo.setFushiClientUrls(oldUrls);
          await repo.setFushiClientToken(oldToken);
          await appModel.prefsRepo.setInterconnectQualityPresetIndex(
            oldQuality,
          );
        }
      },
    );
  }, timeout: const Timeout(Duration(minutes: 12)));
}

/// 回环上的 TCP 转发代理：client ↔ 127.0.0.1:[_targetPort] 原样转字节，host → client
/// 方向按 [bytesPerSecond] 限速（全部连接共用一个令牌桶；null = 不限）。
class _ThrottledTcpProxy {
  _ThrottledTcpProxy._(this._server, this._targetPort);

  final ServerSocket _server;
  final int _targetPort;
  final Set<Socket> _sockets = <Socket>{};
  final Stopwatch _clock = Stopwatch()..start();
  double _tokens = 0;
  int _lastRefillMicros = 0;

  /// host → client 的字节上限；null = 不限。
  int? bytesPerSecond;

  /// 已转给 client 的字节数。
  int forwardedBytes = 0;

  int get port => _server.port;

  static Future<_ThrottledTcpProxy> start(int targetPort) async {
    final ServerSocket server = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final _ThrottledTcpProxy proxy = _ThrottledTcpProxy._(server, targetPort);
    server.listen((Socket client) => unawaited(proxy._accept(client)));
    return proxy;
  }

  Future<void> close() async {
    await _server.close();
    for (final Socket s in _sockets.toList()) {
      s.destroy();
    }
    _sockets.clear();
  }

  Future<void> _accept(Socket client) async {
    final Socket upstream;
    try {
      upstream = await Socket.connect(
        InternetAddress.loopbackIPv4,
        _targetPort,
      );
    } on SocketException {
      client.destroy();
      return;
    }
    _sockets
      ..add(client)
      ..add(upstream);
    bool closed = false;
    StreamSubscription<Uint8List>? down;
    void closeBoth() {
      if (closed) return;
      closed = true;
      unawaited(down?.cancel());
      client.destroy();
      upstream.destroy();
      _sockets
        ..remove(client)
        ..remove(upstream);
    }

    // 对端掐连接时 `done` 以 SocketException 结束：这是播放器 seek / 换档的常态。
    unawaited(client.done.then<void>((_) {}, onError: (Object _) {}));
    unawaited(upstream.done.then<void>((_) {}, onError: (Object _) {}));

    client.listen(
      (Uint8List data) {
        if (!closed) upstream.add(data);
      },
      onError: (Object _) => closeBoth(),
      onDone: closeBoth,
      cancelOnError: true,
    );
    down = upstream.listen(
      (Uint8List data) {
        down?.pause(_forward(client, data, () => closed));
      },
      onError: (Object _) => closeBoth(),
      onDone: closeBoth,
      cancelOnError: true,
    );
  }

  Future<void> _forward(
    Socket client,
    Uint8List data,
    bool Function() isClosed,
  ) async {
    const int chunk = 4096;
    for (int offset = 0; offset < data.length; offset += chunk) {
      final int end = min(offset + chunk, data.length);
      await _take(end - offset);
      if (isClosed()) return;
      client.add(Uint8List.sublistView(data, offset, end));
      forwardedBytes += end - offset;
    }
  }

  Future<void> _take(int bytes) async {
    while (true) {
      final int? rate = bytesPerSecond;
      if (rate == null) return;
      final int now = _clock.elapsedMicroseconds;
      // 桶深 0.25 秒：突发有限，长期速率就是 [rate]。
      _tokens = min(
        rate * 0.25,
        _tokens + (now - _lastRefillMicros) * rate / 1000000,
      );
      _lastRefillMicros = now;
      if (_tokens >= bytes) {
        _tokens -= bytes;
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }
}
