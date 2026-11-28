// 网页档播放页的全屏键（Windows，BUG-5613）：站点流媒体书以「制卡优先」档打开、起播并静音后，
// ① Flutter 持焦时按 F11（真实按键事件）进 / 出窗口全屏；② WebView2 持 OS 键盘焦点时按键只进
// DOM——往页面派发 F11 keydown（键盘桥看到的就是这一下），同样要进 / 出窗口全屏。每一步都断言
// 播放页还在、站点地址没变、runner 全屏态与页面的全屏标志一致。
//
// 修前 ② 两次派发后 runner 一直不在全屏（F11 不在键盘桥的 token 表里）。离屏窗口即可。
// 依赖网络（默认 YouTube，`FUSHI_WEB_VIDEO_URL` 可换），默认 skip，仅在
// FUSHI_WEB_VIDEO_F11_ITEST=1 时跑：
//   $env:FUSHI_WEB_VIDEO_F11_ITEST=1; .\tool\run_windows_itest.ps1 `
//     -RunId web-video-f11 integration_test\web_video_f11_itest.dart
import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart' show FlutterExceptionHandler;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/window_caption_channel.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:integration_test/integration_test.dart';

import 'package:fushi/src/media/video/url_stream_video.dart';
import 'package:fushi/src/media/video/web_video_bridge.dart'
    show kWebVideoPlayerEnabled;
import 'package:fushi/src/media/video/web_video_hosting.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/home_page.dart'
    show HomePage, HomeTab;
import 'package:fushi/src/pages/implementations/home_video_page.dart'
    show openLocalVideoBook;
import 'package:fushi/src/pages/implementations/tag_filter_sheet.dart'
    show filteredVideoBookUidsProvider;
import 'package:fushi/src/pages/implementations/video_fushi_page.dart'
    show VideoFushiPage, VideoFushiTestHooks;
import 'package:fushi_engine/media/video/video_book_repository.dart';

import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

bool get _enabled => Platform.environment['FUSHI_WEB_VIDEO_F11_ITEST'] == '1';

String get _url =>
    Platform.environment['FUSHI_WEB_VIDEO_URL'] ??
    'https://www.youtube.com/watch?v=aqz-KE-bpKQ';

VideoFushiTestHooks? _hooks(WidgetTester tester) {
  final Finder page = find.byType(VideoFushiPage);
  if (page.evaluate().isEmpty) return null;
  return tester.state<State<VideoFushiPage>>(page) as VideoFushiTestHooks;
}

Future<bool> _waitUntil(
  WidgetTester tester,
  bool Function(VideoFushiTestHooks h) predicate, {
  required Duration timeout,
  required String what,
}) async {
  final int ticks = timeout.inMilliseconds ~/ 500;
  for (int i = 0; i < ticks; i++) {
    await tester.pump(const Duration(milliseconds: 500));
    final VideoFushiTestHooks? h = _hooks(tester);
    if (h != null && predicate(h)) return true;
  }
  debugPrint('[web-video-f11-itest] timeout waiting for $what');
  return false;
}

Future<String?> _evalJs(WidgetTester tester, String js) async {
  final VideoFushiTestHooks? h = _hooks(tester);
  if (h == null) return null;
  String? result;
  bool done = false;
  unawaited(
    h.debugWebEvalJs(js).then((String? v) {
      result = v;
      done = true;
    }),
  );
  for (int i = 0; i < 40 && !done; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  return result;
}

Future<T?> _await<T>(WidgetTester tester, Future<T> f) async {
  T? result;
  bool done = false;
  unawaited(
    f.then((T v) {
      result = v;
      done = true;
    }),
  );
  for (int i = 0; i < 60 && !done; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  return result;
}

Future<({bool page, bool? webFs, bool? runnerFs, String? href})> _snap(
  WidgetTester tester,
  String label,
) async {
  final VideoFushiTestHooks? h = _hooks(tester);
  final bool? fs = await _await(tester, WindowCaptionChannel.isFullscreen());
  final String? href = await _evalJs(tester, 'location.href');
  debugPrint(
    '[web-video-f11-itest] $label page=${h != null} webFs=${h?.debugWebWindowFullscreen} '
    'hasVideo=${h?.debugWebHasVideo} runnerFs=$fs href=$href '
    'focus=${FocusManager.instance.primaryFocus}',
  );
  return (
    page: h != null,
    webFs: h?.debugWebWindowFullscreen,
    runnerFs: fs,
    href: href,
  );
}

void main() {
  final IntegrationTestWidgetsFlutterBinding binding =
      IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('网页档播放页：Flutter 持焦与 WebView 持焦时 F11 都进 / 出窗口全屏，页面不退（BUG-5613）', (
    WidgetTester tester,
  ) async {
    if (!kWebVideoPlayerEnabled || !_enabled || !Platform.isWindows) {
      debugPrint('[web-video-f11-itest] skip');
      return;
    }
    final FlutterExceptionHandler? errorHandler = FlutterError.onError;
    addTearDown(() => FlutterError.onError = errorHandler);
    await launchFushiTestApp();
    expect(await waitForHome(tester), isTrue);
    await tester.pump(const Duration(seconds: 2));
    final ProviderContainer container = ProviderScope.containerOf(
      tester.element(find.byType(MaterialApp).first),
    );
    final AppModel appModel = container.read(appProvider);
    final VideoBookRepository repo = VideoBookRepository(appModel.database);
    final String uid = streamVideoBookUid(_url);
    await repo.saveVideoBook(
      VideoBooksCompanion(
        bookUid: Value(uid),
        title: const Value('F11 itest'),
        videoPath: Value(_url),
      ),
    );
    container.invalidate(filteredVideoBookUidsProvider);
    await appModel.prefsRepo.setPref(
      kWebVideoHostingPrefKey,
      WebVideoHosting.builtin.name,
    );
    HomePage.debugSelectTab!(HomeTab.video);
    await tester.pump(const Duration(seconds: 1));
    final BuildContext ctx = tester.element(find.byType(HomePage));
    // ignore: use_build_context_synchronously
    unawaited(openLocalVideoBook(context: ctx, repo: repo, bookUid: uid));
    expect(
      await _waitUntil(
        tester,
        (VideoFushiTestHooks h) =>
            h.debugIsWebBackend && h.debugWebHasVideo && h.debugIsPlaying,
        timeout: const Duration(seconds: 90),
        what: 'video playing',
      ),
      isTrue,
    );
    const String mute =
        "(() => { for (const v of document.querySelectorAll('video')) "
        '{ v.muted = true; v.volume = 0; } return 1; })()';
    await _evalJs(tester, mute);
    for (int i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    await _evalJs(tester, mute);
    await _snap(tester, 'before');

    // A: Flutter focus, real key event.
    await tester.sendKeyEvent(LogicalKeyboardKey.f11);
    for (int i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    {
      final r = await _snap(tester, 'after-F11-1');
      expect(r.page, isTrue, reason: 'after-F11-1: page popped');
      expect(r.href, _url, reason: 'after-F11-1: site navigated');
      expect(r.runnerFs, true, reason: 'after-F11-1: runner fullscreen');
      expect(r.webFs, true, reason: 'after-F11-1: page flag');
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.f11);
    for (int i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    {
      final r = await _snap(tester, 'after-F11-2');
      expect(r.page, isTrue, reason: 'after-F11-2: page popped');
      expect(r.href, _url, reason: 'after-F11-2: site navigated');
      expect(r.runnerFs, false, reason: 'after-F11-2: runner fullscreen');
      expect(r.webFs, false, reason: 'after-F11-2: page flag');
    }

    // B: the key arriving through the WebView DOM (WebView2 holds OS focus):
    // the page's key bridge listener sees exactly this keydown.
    await _evalJs(
      tester,
      "(() => { const e = new KeyboardEvent('keydown', {key: 'F11', code: 'F11', "
      'keyCode: 122, bubbles: true, cancelable: true}); '
      'const r = document.dispatchEvent(e); return String(r); })()',
    );
    for (int i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    {
      final r = await _snap(tester, 'after-DOM-F11-1');
      expect(r.page, isTrue, reason: 'after-DOM-F11-1: page popped');
      expect(r.href, _url, reason: 'after-DOM-F11-1: site navigated');
      expect(r.runnerFs, true, reason: 'after-DOM-F11-1: runner fullscreen');
      expect(r.webFs, true, reason: 'after-DOM-F11-1: page flag');
    }
    await _evalJs(
      tester,
      "(() => { const e = new KeyboardEvent('keydown', {key: 'F11', code: 'F11', "
      'keyCode: 122, bubbles: true, cancelable: true}); '
      'const r = document.dispatchEvent(e); return String(r); })()',
    );
    for (int i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    {
      final r = await _snap(tester, 'after-DOM-F11-2');
      expect(r.page, isTrue, reason: 'after-DOM-F11-2: page popped');
      expect(r.href, _url, reason: 'after-DOM-F11-2: site navigated');
      expect(r.runnerFs, false, reason: 'after-DOM-F11-2: runner fullscreen');
      expect(r.webFs, false, reason: 'after-DOM-F11-2: page flag');
    }
    // Leave the window windowed.
    if (await _await(tester, WindowCaptionChannel.isFullscreen()) == true) {
      await _await(tester, WindowCaptionChannel.setFullscreen(false));
    }
  });
}
