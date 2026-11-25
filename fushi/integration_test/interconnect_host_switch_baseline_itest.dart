// 互联「换了一台 host」之后开播位置的真 app 取证（BUG-4434：基线按 host 分槽）。
//
// 进程内起两台**真 `FushiSyncServer`**（各自的 TLS 身份、各自签发的凭据），库里是
// 同一个视频 id；真 `InterconnectSyncBackend` + 真播放页 + 真 libmpv：
//
//   1. 只有 A 可达：打开视频、seek 到 20 秒播几秒、退出
//      → 本机断点与 A 的断点都在 20 多秒，与 A 达成基线。
//   2. A 下线、只有 B 可达（B 上这个视频停在 60 秒）：再打开同一个视频
//      → 起播在本机断点（20 多秒），不是 B 的 60 秒；播几秒退出后 B 仍是 60 秒
//        （冲突留给用户裁决，本次播放不向 B 上报）；A 的基线还在，B 名下没有基线。
//
// 修复前基线不分 host：与 A 达成的基线被拿去判 B——本机停在基线、B 不同，判成
// 「对端单边改动」，起播直接跳到 60 秒，本机断点被 B 的值静默覆盖。
//
// 两种候选各跑一遍：两台都带 hostId（按 hostId 分槽）；两台都是认不出 hostId 的老
// 条目（按配对凭据分槽，取舍 T6）。
//
// 样片要 ≥ 80 秒（低于 5 秒的断点不落库，见 `_persistRemotePosition`）：
//   .\fushi\tool\run_windows_itest.ps1 integration_test\interconnect_host_switch_baseline_itest.dart `
//     -DartDefine @('FUSHI_ITEST_VIDEO_FILE=D:/path/clip90.mp4')
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:fushi/src/models/app_model.dart' show AppModel;
import 'package:fushi/src/pages/implementations/video_fushi_page.dart';
import 'package:fushi/src/sync/interconnect_playback_position_sync.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi/src/sync/sync_baseline_scope.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:fushi_engine/sync/tls/fushi_tls_identity.dart';

import 'helpers/library_fixture.dart' show readyAppModel;
import 'support/itest_startup_guard.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

const String _videoFile = String.fromEnvironment('FUSHI_ITEST_VIDEO_FILE');

/// 第一段在 A 上 seek 到的位置、B 上预置的断点。
const int _seekOnAMs = 20000;
const int _positionOnBMs = 60000;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'switching to another interconnect host does not adopt its position '
    'through the first host baseline',
    (WidgetTester tester) async {
      await runFushiItest(
        label: 'interconnect-host-switch-baseline',
        body: () async {
          if (_videoFile.isEmpty || !File(_videoFile).existsSync()) {
            fail('给 FUSHI_ITEST_VIDEO_FILE 指一条 ≥ 80 秒的 mp4（见文件头）');
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
          final Directory work = await Directory.systemTemp.createTemp(
            'fushi_itest_host_switch_',
          );
          final List<_Host> hosts = <_Host>[];
          try {
            for (final bool withHostIds in <bool>[true, false]) {
              final String videoId = withHostIds
                  ? 'video/switch-hostid'
                  : 'video/switch-legacy';
              final _Host a = await _Host.start(
                work,
                name: 'a-$withHostIds',
                videoId: videoId,
              );
              final _Host b = await _Host.start(
                work,
                name: 'b-$withHostIds',
                videoId: videoId,
              );
              hosts
                ..add(a)
                ..add(b);
              final int seededAt = DateTime.now().millisecondsSinceEpoch;
              b.library.position = (
                positionMs: _positionOnBMs,
                updatedAtMs: seededAt - 60000,
              );
              await repo.setFushiClientUrls(<FushiClientUrl>[
                a.candidate(hostId: withHostIds ? 'itest-host-a' : null),
                b.candidate(hostId: withHostIds ? 'itest-host-b' : null),
              ]);
              // 全局凭据留空：两条地址各用各的凭据。
              await repo.setFushiClientToken(null);

              Future<InterconnectSyncBackend> connectTo(_Host only) async {
                final InterconnectSyncBackend backend =
                    InterconnectSyncBackend.withProbe(
                      (String url, String tok) async => url == only.baseUrl,
                    );
                expect(await backend.restoreAuth(repo), isTrue);
                await backend.authenticate(repo: repo);
                return backend;
              }

              VideoFushiTestHooks? readHooks() {
                if (find.byType(VideoFushiPage).evaluate().isEmpty) return null;
                return tester.state<State<VideoFushiPage>>(
                      find.byType(VideoFushiPage),
                    )
                    as VideoFushiTestHooks;
              }

              // 打开播放页，等到播放器就绪并真的开始走；返回起播后第一次稳定读到的位置。
              Future<int> openAndPlay(InterconnectSyncBackend backend) async {
                unawaited(
                  navigator.push<void>(
                    MaterialPageRoute<void>(
                      builder: (_) => VideoFushiPage.neutralizedRemote(
                        info: RemoteVideoInfo(id: videoId, title: 'switch'),
                        repo: VideoBookRepository(appModel.database),
                        client: backend,
                      ),
                    ),
                  ),
                );
                bool ready = false;
                for (int i = 0; i < 240; i++) {
                  await tester.pump(const Duration(milliseconds: 250));
                  if (readHooks()?.debugPositionMs != null) {
                    ready = true;
                    break;
                  }
                }
                expect(ready, isTrue, reason: '远端流控制器应就绪');
                final VideoFushiTestHooks hooks = readHooks()!;
                await hooks.debugPlay();
                // 续播位置由播放器异步落地：等位置连续两次采样都在前进再读。
                int previous = -1;
                int current = hooks.debugPositionMs ?? 0;
                for (int i = 0; i < 80; i++) {
                  await tester.pump(const Duration(milliseconds: 250));
                  previous = current;
                  current = hooks.debugPositionMs ?? 0;
                  if (i >= 8 && current > previous) break;
                }
                return current;
              }

              Future<void> closePage() async {
                await navigator.maybePop();
                for (int i = 0; i < 80; i++) {
                  await tester.pump(const Duration(milliseconds: 100));
                  if (find.byType(VideoFushiPage).evaluate().isEmpty) break;
                }
              }

              Future<void> pumpUntil(bool Function() done) async {
                for (int i = 0; i < 80 && !done(); i++) {
                  await tester.pump(const Duration(milliseconds: 250));
                }
              }

              // ── 1. 连 A：seek 到 20 秒、播几秒、退出 ─────────────────────────
              final InterconnectSyncBackend onA = await connectTo(a);
              final int startOnA = await openAndPlay(onA);
              await readHooks()!.debugSeekMs(_seekOnAMs);
              await pumpUntil(
                () => (readHooks()!.debugPositionMs ?? 0) > _seekOnAMs + 2000,
              );
              final int leftAAt = readHooks()!.debugPositionMs ?? 0;
              await closePage();
              await pumpUntil(
                () => a.library.position.positionMs >= _seekOnAMs,
              );
              final InterconnectHostScope scopeA = await onA.liveHostScope();
              final String dimensionA = baselineStorageDimension(
                kInterconnectVideoPositionDimension,
                scopeA.pin.tag,
              );
              final Map<String, int> baselinesA = await appModel.database
                  .getSyncBaselinesForDimension(dimensionA);
              debugPrint(
                '[host-switch-itest] hostIds=$withHostIds A: start=$startOnA '
                'left=$leftAAt hostA=${a.library.position.positionMs} '
                'scope=${scopeA.pin} baselines=$baselinesA',
              );
              expect(
                a.library.position.positionMs,
                greaterThanOrEqualTo(_seekOnAMs),
                reason: '退出时的断点应上报到 A',
              );
              expect(baselinesA, isNotEmpty, reason: '与 A 达成的基线记在 A 名下');
              expect(
                baselinesA.values.single,
                a.library.position.positionMs,
                reason: '基线 = 两端一致的那个位置',
              );
              expect(b.library.puts, 0, reason: '这一段没连过 B');

              // ── 2. A 下线，只连得上 B ────────────────────────────────────────
              await a.stop();
              final InterconnectSyncBackend onB = await connectTo(b);
              final int startOnB = await openAndPlay(onB);
              final InterconnectHostScope scopeB = await onB.liveHostScope();
              final String dimensionB = baselineStorageDimension(
                kInterconnectVideoPositionDimension,
                scopeB.pin.tag,
              );
              await pumpUntil(
                () => (readHooks()!.debugPositionMs ?? 0) > startOnB + 2000,
              );
              final int leftBAt = readHooks()!.debugPositionMs ?? 0;
              await closePage();
              // 给退出时的落库 / 上报留出时间（修复前会在这里把位置写到 B）。
              for (int i = 0; i < 12; i++) {
                await tester.pump(const Duration(milliseconds: 250));
              }
              final Map<String, int> baselinesB = await appModel.database
                  .getSyncBaselinesForDimension(dimensionB);
              debugPrint(
                '[host-switch-itest] hostIds=$withHostIds B: start=$startOnB '
                'left=$leftBAt hostB=${b.library.position.positionMs} '
                'puts=${b.library.puts} scope=${scopeB.pin} '
                'baselinesB=$baselinesB',
              );
              expect(
                scopeB.pin.tag,
                isNot(scopeA.pin.tag),
                reason: '两台 host 各有各的基线作用域',
              );
              expect(
                startOnB,
                allOf(
                  greaterThanOrEqualTo(_seekOnAMs),
                  lessThan(_positionOnBMs - 10000),
                ),
                reason:
                    '换到 B 后从本机断点（约 $leftAAt）起播；跳到 $_positionOnBMs = '
                    '拿 A 的基线判了 B',
              );
              expect(
                b.library.position.positionMs,
                _positionOnBMs,
                reason: '冲突未裁决：本次播放不向 B 上报',
              );
              expect(b.library.puts, 0);
              expect(baselinesB, isEmpty, reason: '没与 B 达成过一致，B 名下不该有基线');
              expect(
                await appModel.database.getSyncBaselinesForDimension(
                  dimensionA,
                ),
                baselinesA,
                reason: 'A 名下的基线不动',
              );
              await b.stop();
            }
          } finally {
            await navigator.maybePop();
            for (int i = 0; i < 40; i++) {
              await tester.pump(const Duration(milliseconds: 100));
              if (find.byType(VideoFushiPage).evaluate().isEmpty) break;
            }
            for (final _Host h in hosts) {
              await h.stop();
            }
            await repo.setFushiClientUrls(oldUrls);
            await repo.setFushiClientToken(oldToken);
            if (await work.exists()) {
              await work.delete(recursive: true);
            }
          }
        },
      );
    },
    timeout: const Timeout(Duration(minutes: 8)),
  );
}

/// 一台进程内的真互联 host：自签 TLS、自己的凭据、只有一条视频的库。
class _Host {
  _Host._(this._server, this.library, this.fingerprint, this.token);

  final FushiSyncServer _server;
  final _SingleClipLibraryService library;
  final String fingerprint;
  final String token;
  bool _stopped = false;

  String get baseUrl => 'https://127.0.0.1:${_server.port}';

  static Future<_Host> start(
    Directory work, {
    required String name,
    required String videoId,
  }) async {
    final Directory dataDir = await Directory(
      '${work.path}/$name',
    ).create(recursive: true);
    final FushiTlsIdentity identity = await FushiTlsIdentityStore(
      dataDir: dataDir.path,
    ).loadOrCreate();
    final SecurityContext context = SecurityContext()
      ..useCertificateChainBytes(utf8.encode(identity.certificatePem))
      ..usePrivateKeyBytes(utf8.encode(identity.privateKeyPem));
    final _SingleClipLibraryService library = _SingleClipLibraryService(
      File(_videoFile),
      videoId,
    );
    final String token = FushiSyncServer.generateToken();
    final FushiSyncServer server = FushiSyncServer(
      syncDataDir: dataDir.path,
      port: 0,
      token: token,
      libraryService: library,
      securityContext: context,
      hostFingerprint: identity.fingerprintSha256,
    );
    await server.start();
    return _Host._(server, library, identity.fingerprintSha256, token);
  }

  FushiClientUrl candidate({required String? hostId}) => FushiClientUrl(
    url: baseUrl,
    fingerprintSha256: fingerprint,
    token: token,
    hostId: hostId,
  );

  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    await _server.stop();
  }
}

/// 最小 host 库服务：只有一条视频，其余能力一律 [noSuchMethod]（本测试不会碰）。
class _SingleClipLibraryService implements FushiLibraryHostService {
  _SingleClipLibraryService(this.clip, this.videoId);

  final File clip;
  final String videoId;

  ({int positionMs, int updatedAtMs}) position = (
    positionMs: 0,
    updatedAtMs: 0,
  );

  /// client 写断点的次数。
  int puts = 0;

  @override
  Future<List<RemoteVideoInfo>> listVideos() async => <RemoteVideoInfo>[
    RemoteVideoInfo(
      id: videoId,
      title: 'switch',
      sizeBytes: clip.lengthSync(),
      positionMs: position.positionMs,
    ),
  ];

  @override
  Future<bool> videoExists(String id, {int episodeIndex = 0}) async =>
      id == videoId;

  @override
  Future<File?> resolveVideoFile(String id, {int episodeIndex = 0}) async =>
      id == videoId ? clip : null;

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
  }) async => position;

  @override
  Future<void> putVideoPosition(
    String id,
    int positionMs,
    int updatedAtMs, {
    int episodeIndex = 0,
  }) async {
    puts++;
    position = (positionMs: positionMs, updatedAtMs: updatedAtMs);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not used here');
}
