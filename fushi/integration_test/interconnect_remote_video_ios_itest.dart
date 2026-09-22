// 互联远端视频在**宿主平台真实 libmpv** 上真播放的集成测试（iOS 首要）。
//
// 用户 2026-09-22 报「iOS 的 Fushi 互联又没办法播放远端 Fushi 的视频」。这条链路
// 此前没有任何自动化覆盖：`fushi_client_live_video_test.dart` 只验到 stream URL 与
// `nativePlaybackUri` 的字符串形态，`video_https_stream_native_tls_itest.dart` 播的是
// 公网非钉扎 https，`interconnect_remote_audio_tls_ios_itest.dart` 只验查词音频。
//
// 本测试在 app 进程内起一台**真 `FushiSyncServer`**（自签 TLS + 指纹 + per-peer
// token），挂一个只提供一条 mp4 的最小 host 库服务，再用真 `InterconnectSyncBackend`
// 配对解析 → `VideoFushiPage.remote` 起播 → 断言 libmpv 的位置真实前进。字节从
// host 到播放器要走：钉扎 https `/streamurl`（Basic）→ `nativePlaybackUri` 降级 →
// loopback 中继按指纹升回 https → `/stream?token=`（豁免 Basic）→ Range 直传。
//
// 跑法（目标须先提交，Mac 从提交历史构建）：
//   Windows 离屏：.\fushi\tool\run_windows_itest.ps1 integration_test\interconnect_remote_video_ios_itest.dart
//   iOS 模拟器：Mac 上 `flutter test integration_test/interconnect_remote_video_ios_itest.dart -d <udid> --no-pub`
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:fushi/src/models/app_model.dart' show AppModel;
import 'package:fushi/src/pages/implementations/video_fushi_page.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/utils/net/app_native_proxy.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:fushi_engine/sync/tls/fushi_tls_identity.dart';

import 'helpers/h264_test_clip.dart';
import 'helpers/library_fixture.dart' show readyAppModel;
import 'support/itest_startup_guard.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

const String _token = 'ios-interconnect-video-itest-token';
const String _videoId = 'video/itest-clip';

/// 外部 host 模式（取证用）：指向一台已经跑着的互联 host（例如
/// `packages/fushi_engine/tool/interconnect_video_host_probe.dart` 起的那台，带真
/// ffmpeg、能按档转码），不在进程内起服务。iOS 模拟器与宿主 Mac 共用网络栈，
/// `https://127.0.0.1:<port>` 就能连到 Mac 上的 host。
///   --dart-define=FUSHI_REMOTE_HOST_URL=https://127.0.0.1:45777
///   --dart-define=FUSHI_REMOTE_HOST_FP=<sha256 指纹>
///   --dart-define=FUSHI_REMOTE_HOST_TOKEN=<token>
///   --dart-define=FUSHI_REMOTE_VIDEO_ID=video/probe-clip
///   --dart-define=FUSHI_REMOTE_QUALITY=2   （画质档下标；-1 = 自动）
const String _externalHostUrl = String.fromEnvironment('FUSHI_REMOTE_HOST_URL');
const String _externalHostFingerprint = String.fromEnvironment(
  'FUSHI_REMOTE_HOST_FP',
);
const String _externalHostToken = String.fromEnvironment(
  'FUSHI_REMOTE_HOST_TOKEN',
);
const String _externalVideoId = String.fromEnvironment(
  'FUSHI_REMOTE_VIDEO_ID',
  defaultValue: _videoId,
);
const int _externalQuality = int.fromEnvironment(
  'FUSHI_REMOTE_QUALITY',
  defaultValue: -1,
);
const bool _useExternalHost = _externalHostUrl != '';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'iOS plays a pinned interconnect video stream on the real libmpv',
    (WidgetTester tester) async {
      await runFushiItest(
        label: 'interconnect-remote-video-ios',
        body: () async {
          // 外部 host 模式的三个参数缺一不可：缺指纹会走到空指纹分支注销钉扎、自签
          // https 握手失败；缺 token 是 401——两者最终都只在「远端流控制器应就绪」
          // 上以与根因无关的理由红。前置直接说清缺什么。
          if (_useExternalHost) {
            if (_externalHostFingerprint.isEmpty) {
              fail('给了 FUSHI_REMOTE_HOST_URL 但缺 FUSHI_REMOTE_HOST_FP');
            }
            if (_externalHostToken.isEmpty) {
              fail('给了 FUSHI_REMOTE_HOST_URL 但缺 FUSHI_REMOTE_HOST_TOKEN');
            }
          }
          await launchFushiTestApp();
          expect(await waitForHome(tester), isTrue);
          final AppModel appModel = await readyAppModel(tester);
          final SyncRepository repo = SyncRepository(appModel.database);
          final List<FushiClientUrl> oldUrls = await repo.getFushiClientUrls();
          final String? oldToken = await repo.getFushiClientToken();
          // 可能抛的查找都放在建临时目录 / 覆写全局 sink 之前：否则 finally 还没
          // 接管，临时目录与两个覆写就泄漏了。
          final NavigatorState navigator = tester.state<NavigatorState>(
            find.byType(Navigator).first,
          );
          final int oldQuality =
              appModel.prefsRepo.interconnectQualityPresetIndex;
          final Directory hostRoot = await Directory.systemTemp.createTemp(
            'fushi_itest_remote_video_',
          );
          final List<String> relayLog = <String>[];
          final List<String> loadLog = <String>[];
          final void Function(String) oldRelaySink = appNativeProxyLogSink;
          final DebugPrintCallback oldDebugPrint = debugPrint;
          appNativeProxyLogSink = (String message) {
            relayLog.add(message);
            oldRelaySink(message);
          };
          debugPrint = (String? message, {int? wrapWidth}) {
            if (message != null && message.contains('[video-load]')) {
              loadLog.add(message);
            }
            oldDebugPrint(message, wrapWidth: wrapWidth);
          };
          FushiSyncServer? server;
          try {
            final String baseUrl;
            final String fingerprint;
            final String token;
            final String videoId;
            if (_useExternalHost) {
              baseUrl = _externalHostUrl;
              fingerprint = _externalHostFingerprint;
              token = _externalHostToken;
              videoId = _externalVideoId;
              await appModel.prefsRepo.setInterconnectQualityPresetIndex(
                _externalQuality,
              );
            } else {
              final File clip = File('${hostRoot.path}/clip.mp4');
              await clip.writeAsBytes(h264TestClipBytes(), flush: true);
              final FushiTlsIdentity identity = await FushiTlsIdentityStore(
                dataDir: hostRoot.path,
              ).loadOrCreate();
              final SecurityContext context = SecurityContext()
                ..useCertificateChainBytes(utf8.encode(identity.certificatePem))
                ..usePrivateKeyBytes(utf8.encode(identity.privateKeyPem));
              server = FushiSyncServer(
                syncDataDir: hostRoot.path,
                port: 0,
                token: _token,
                libraryService: _SingleClipLibraryService(clip),
                securityContext: context,
                hostFingerprint: identity.fingerprintSha256,
              );
              await server.start();
              baseUrl = 'https://127.0.0.1:${server.port}';
              fingerprint = identity.fingerprintSha256;
              token = _token;
              videoId = _videoId;
            }
            debugPrint(
              '[remote-video-itest] host at $baseUrl external=$_useExternalHost '
              'quality=$_externalQuality',
            );
            await repo.setFushiClientUrls(<FushiClientUrl>[
              FushiClientUrl(
                url: baseUrl,
                fingerprintSha256: fingerprint,
                token: token,
              ),
            ]);
            await repo.setFushiClientToken(token);

            final InterconnectSyncBackend backend =
                InterconnectSyncBackend.withProbe(
                  (String url, String tok) async => true,
                );
            expect(await backend.restoreAuth(repo), isTrue);
            await backend.authenticate(repo: repo);

            final Stopwatch guard = Stopwatch()..start();
            unawaited(
              navigator.push<void>(
                MaterialPageRoute<void>(
                  builder: (_) => VideoFushiPage.neutralizedRemote(
                    info: RemoteVideoInfo(id: videoId, title: 'itest clip'),
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
            for (int i = 0; i < 240 && guard.elapsed.inSeconds < 90; i++) {
              await tester.pump(const Duration(milliseconds: 250));
              if (readHooks()?.debugPositionMs != null) {
                ready = true;
                break;
              }
            }
            debugPrint(
              '[remote-video-itest] ready=$ready at ${guard.elapsed} '
              'hostTranscodeAvailable=${backend.hostTranscodeAvailable} '
              'load=$loadLog relay=$relayLog',
            );
            expect(
              ready,
              isTrue,
              reason: '远端流控制器应就绪（load 后 debugPositionMs 非 null）',
            );
            expect(
              loadLog.any((String l) => l.contains('http://127.0.0.1:')),
              isTrue,
              reason: '交给 native 的必须是降级后的明文中继形态：$loadLog',
            );

            final VideoFushiTestHooks hooks = readHooks()!;
            await hooks.debugPlay();
            int played = 0;
            for (int i = 0; i < 240 && guard.elapsed.inSeconds < 90; i++) {
              await tester.pump(const Duration(milliseconds: 250));
              played = hooks.debugPositionMs ?? 0;
              if (i % 8 == 0) {
                debugPrint(
                  '[remote-video-itest] t=${i * 250}ms posMs=$played '
                  'durMs=${hooks.debugDurationMs}',
                );
              }
              if (played > 1500) break;
            }
            debugPrint(
              '[remote-video-itest] FINAL playedMs=$played '
              'durMs=${hooks.debugDurationMs} elapsed=${guard.elapsed} '
              'relay=$relayLog',
            );
            expect(
              played,
              greaterThan(1500),
              reason: 'libmpv 应真实播放前进 >1.5s（实测=$played）；relay=$relayLog',
            );
            expect(
              hooks.debugDurationMs,
              greaterThan(5000),
              reason: '6 秒样片的时长应被 libmpv 识别',
            );
            expect(
              relayLog.where((String l) => l.contains('->')),
              isEmpty,
              reason: '中继不应报任何上游失败：$relayLog',
            );
          } finally {
            await navigator.maybePop();
            for (int i = 0; i < 40; i++) {
              await tester.pump(const Duration(milliseconds: 100));
              if (find.byType(VideoFushiPage).evaluate().isEmpty) break;
            }
            appNativeProxyLogSink = oldRelaySink;
            debugPrint = oldDebugPrint;
            await server?.stop();
            await repo.setFushiClientUrls(oldUrls);
            await repo.setFushiClientToken(oldToken);
            await appModel.prefsRepo.setInterconnectQualityPresetIndex(
              oldQuality,
            );
            if (await hostRoot.exists()) {
              await hostRoot.delete(recursive: true);
            }
          }
        },
      );
    },
  );
}

/// 最小 host 库服务：只有一条视频，其余能力一律 [noSuchMethod]（本测试不会碰）。
class _SingleClipLibraryService implements FushiLibraryHostService {
  _SingleClipLibraryService(this.clip);

  final File clip;
  ({int positionMs, int updatedAtMs}) _position = (
    positionMs: 0,
    updatedAtMs: 0,
  );

  @override
  Future<List<RemoteVideoInfo>> listVideos() async => <RemoteVideoInfo>[
    RemoteVideoInfo(
      id: _videoId,
      title: 'itest clip',
      sizeBytes: clip.lengthSync(),
    ),
  ];

  @override
  Future<bool> videoExists(String id) async => id == _videoId;

  @override
  Future<File?> resolveVideoFile(String id, {int episodeIndex = 0}) async =>
      id == _videoId ? clip : null;

  @override
  Future<File?> resolveVideoSubtitle(
    String id, {
    String langCode = 'ja',
    int episodeIndex = 0,
  }) async => null;

  @override
  Future<String?> videoCoverPath(String id) async => null;

  @override
  Future<List<RemoteActivityEvent>> listActivityEvents({
    int limit = 100,
  }) async => const <RemoteActivityEvent>[];

  @override
  Future<({int positionMs, int updatedAtMs})> getVideoPosition(
    String id, {
    int episodeIndex = 0,
  }) async => _position;

  @override
  Future<void> putVideoPosition(
    String id,
    int positionMs,
    int updatedAtMs, {
    int episodeIndex = 0,
  }) async {
    _position = (positionMs: positionMs, updatedAtMs: updatedAtMs);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not used here');
}
