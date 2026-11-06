// Apple Music 网页桥真 app 探针（Windows / Android，MusicKit 方案 P3 / P4）。
//
// 证明三件事（不需要 Apple ID）：
// 1. 隐藏 WebView 能加载托管页 https://rank.fushi.moe/musickit/、MusicKit JS configure 成功，
//    账号状态可读（未登录 → notDetermined）；
// 2. `fushi-apple-music://song/<id>` 曲目经音乐引擎 → 路由后端 → AppleMusicOutputBackend → 网页桥
//    真的出声推进（未登录时 MusicKit 放 30 秒试听，同一条链路；整曲只差 DRM 授权）；
// 3. 登录页能把 MusicKit `authorize()` 开的 Apple ID 弹窗接成页内第二个 WebView。
//
// 跑：fushi/ 下 `.\tool\run_windows_itest.ps1 integration_test/apple_music_web_bridge_itest.dart`
// （runner 隔离 APPDATA / WebView2 profile；这里改的偏好在 finally 里还原）。
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi_engine/media/music/apple_music/apple_music_catalog_client.dart';
import 'package:fushi_engine/media/music/server/music_server.dart';

import 'package:fushi/src/media/music/apple_music/apple_music_bridge.dart';
import 'package:fushi/src/media/music/apple_music/apple_music_web_bridge.dart';
import 'package:fushi/src/media/music/apple_music/apple_music_web_login_page.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/music_player_engine.dart';
import 'package:fushi/src/media/music/server/music_servers.dart';
import 'package:fushi/src/models/app_model.dart';

import 'helpers/library_fixture.dart';
import 'helpers/observe_capture.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

Future<bool> _pumpUntil(
  WidgetTester tester,
  bool Function() done, {
  Duration timeout = const Duration(seconds: 40),
}) async {
  final DateTime end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    if (done()) return true;
    await tester.pump(const Duration(milliseconds: 250));
  }
  return done();
}

/// 一边泵帧一边等 [f]（隐藏 WebView 在 Windows 上要等帧才构造）。
Future<T> _await<T>(
  WidgetTester tester,
  Future<T> f, {
  Duration timeout = const Duration(seconds: 60),
}) async {
  bool done = false;
  late T value;
  Object? error;
  f.then(
    (T v) {
      value = v;
      done = true;
    },
    onError: (Object e) {
      error = e;
      done = true;
    },
  );
  final bool ok = await _pumpUntil(tester, () => done, timeout: timeout);
  if (!ok) throw StateError('timed out');
  if (error case final Object e) {
    Error.throwWithStackTrace(e, StackTrace.current);
  }
  return value;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Apple Music web bridge: configure, engine playback, login popup', (
    WidgetTester tester,
  ) async {
    await launchFushiTestApp();
    expect(await waitForHome(tester), isTrue, reason: '主页应在 90s 内出现');
    await tester.pump(const Duration(seconds: 2));
    final AppModel app = await readyAppModel(tester);

    final bool wasEnabled = app.prefsRepo.musicAppleMusicEnabled;
    await app.prefsRepo.setMusicAppleMusicEnabled(true);
    try {
      final AppleMusicBridge? bridge = app.appleMusicAccount.bridge;
      expect(bridge, isA<AppleMusicWebBridge>());

      // 1. 托管页 + configure + 账号状态。
      final AppleMusicAccountState state = await _await(
        tester,
        bridge!.accountState(),
      );
      debugPrint(
        '[apple-music-itest] account state: ${state.status} '
        'canPlay=${state.canPlayCatalogContent} sf=${state.storefront}',
      );
      expect(state.status, AppleMusicAuthStatus.notDetermined);

      // 2. 找一首有试听的曲目，走引擎 → 路由 → MusicKit 后端。
      final AppleMusicCatalogClient catalog = AppleMusicCatalogClient(
        tokens: appleMusicTokenSource,
        storefront: 'jp',
      );
      final MusicServerSearchResult found = await _await(
        tester,
        catalog.search('YOASOBI 夜に駆ける'),
      );
      expect(found.tracks, isNotEmpty);
      final MusicServerTrack track = found.tracks.first;
      debugPrint('[apple-music-itest] song ${track.id} ${track.title}');
      final MusicPlayItem item = MusicPlayItem(
        trackUid: 'apple-music-itest-${track.id}',
        path: appleMusicSongUri(track.id).toString(),
        title: track.title,
        artist: track.artist,
        durationMs: track.durationMs,
      );
      final MusicPlayerEngine engine = app.musicSession.engine;
      await _await(tester, engine.playQueue(<MusicPlayItem>[item]));
      final bool advanced = await _pumpUntil(
        tester,
        () => engine.isPlaying && engine.position > const Duration(seconds: 3),
        timeout: const Duration(seconds: 60),
      );
      debugPrint(
        '[apple-music-itest] playing=${engine.isPlaying} '
        'position=${engine.position} caps.signalPath='
        '${engine.capabilities.signalPath} caps.abLoop=${engine.capabilities.abLoop}',
      );
      expect(advanced, isTrue, reason: 'MusicKit 曲目应真的出声推进');
      expect(engine.capabilities.signalPath, isFalse);
      expect(engine.capabilities.abLoop, isFalse);

      await _await(tester, engine.pause());
      expect(
        await _pumpUntil(
          tester,
          () => !engine.isPlaying,
          timeout: const Duration(seconds: 10),
        ),
        isTrue,
      );
      final Duration pausedAt = engine.position;
      await tester.pump(const Duration(seconds: 2));
      debugPrint(
        '[apple-music-itest] paused at $pausedAt, after 2s ${engine.position}',
      );
      expect(
        (engine.position - pausedAt).abs() < const Duration(milliseconds: 600),
        isTrue,
        reason: '暂停后位置不应再走',
      );
      await _await(tester, engine.stop());

      // 3. 登录页：authorize() 开的 Apple ID 弹窗接成第二个 WebView。
      final NavigatorState nav = Navigator.of(
        tester.element(find.byType(Scaffold).first),
      );
      final Future<bool?> loginF = nav.push<bool>(
        MaterialPageRoute<bool>(
          builder: (BuildContext _) => const AppleMusicWebLoginPage(),
        ),
      );
      final bool popup = await _pumpUntil(
        tester,
        () => find.byType(InAppWebView).evaluate().length >= 2,
        timeout: const Duration(seconds: 60),
      );
      await tester.pump(const Duration(seconds: 6));
      await captureFlutterFrame(tester, 'apple-music-login');
      debugPrint(
        '[apple-music-itest] login popup webviews='
        '${find.byType(InAppWebView).evaluate().length}',
      );
      expect(popup, isTrue, reason: 'authorize() 的 Apple ID 弹窗应接成页内 WebView');
      nav.pop(false);
      await tester.pump(const Duration(seconds: 1));
      expect(await _await(tester, loginF), isFalse);
      catalog.close();
    } finally {
      await app.prefsRepo.setMusicAppleMusicEnabled(wasEnabled);
    }
  });
}
