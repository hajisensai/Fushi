// 「制卡优先」档截取链路真机验证（Windows，BUG-5611）：网页站流媒体书交给原生播放器页、
// 档位固定为「制卡优先」（composition 宿主 + WGC 离屏截取进 Flutter 纹理），起播后读 fork
// 纹理桥的只读体检（[VideoFushiTestHooks.debugWebCaptureStats]：累计收到的 WGC 帧数 + 最近
// 一帧 5 个采样点），断言纹理**持续**收到**非空、非纯白、有变化**的帧。
//
// BUG-5611 的症状正是「网页在播、字幕在出、纹理一帧没有 → 露出白底」，所以只看 `<video>` 在播
// 抓不住它，必须看纹理桥。离屏窗口即可（WGC 截的是 WebView2 的 visual，不依赖窗口上屏）。
//
// 依赖网络（默认 YouTube，`FUSHI_WEB_VIDEO_URL` 可换），默认 skip，仅在
// FUSHI_WEB_VIDEO_BUILTIN_CAPTURE_ITEST=1 时跑：
//   $env:FUSHI_WEB_VIDEO_BUILTIN_CAPTURE_ITEST=1; .\tool\run_windows_itest.ps1 `
//     -RunId web-video-builtin-capture integration_test\web_video_builtin_capture_itest.dart
// 回归验证（应当红）：再设 FUSHI_WEB_VIDEO_CAPTURABLE_ARGS 为修复前的参数
// `--autoplay-policy=no-user-gesture-required --disable-direct-composition`（纹理只进 1 帧、
// 全透明），或去掉 `--disable_direct_composition_video_overlays`（加密样例截到一片黑）。
//
// 加密视频（Widevine 软件解密）：同一会话里再把页面换到 FUSHI_WEB_VIDEO_PROBE_URL（如 dash.js
// 的 Widevine 样例 `https://reference.dashif.org/dash.js/latest/samples/drm/widevine.html`），
// 把 `<video>` 铺满页面，断言截到的仍是有变化的画面（BUG-5611：Chromium 默认把加密视频放进
// DISPLAY_ONLY 的 overlay 交换链，WGC 只截到黑）。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart' show FlutterExceptionHandler;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:integration_test/integration_test.dart';

import 'package:fushi/src/media/video/url_stream_video.dart';
import 'package:fushi/src/media/video/web_video_bridge.dart'
    show kWebVideoPlayerEnabled;
import 'package:fushi/src/media/video/web_video_capture_stats.dart';
import 'package:fushi/src/media/video/web_video_hosting.dart';
import 'package:fushi/src/media/video/web_video_session.dart'
    show debugWebVideoCapturableBrowserArgumentsOverride;
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

bool get _enabled =>
    Platform.environment['FUSHI_WEB_VIDEO_BUILTIN_CAPTURE_ITEST'] == '1';

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
  debugPrint('[builtin-capture-itest] timeout waiting for $what');
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

/// 体检读数；通道调用在测试 binding 下要边 pump 边等。
Future<WebVideoCaptureStats?> _stats(WidgetTester tester) async {
  final VideoFushiTestHooks? h = _hooks(tester);
  if (h == null) return null;
  final Future<WebVideoCaptureStats?> f = h.debugWebCaptureStats();
  WebVideoCaptureStats? result;
  bool done = false;
  unawaited(
    f.then((WebVideoCaptureStats? v) {
      result = v;
      done = true;
    }),
  );
  for (int i = 0; i < 40 && !done; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  return result;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('「制卡优先」档：纹理持续收到有内容的帧（BUG-5611）', (WidgetTester tester) async {
    if (!kWebVideoPlayerEnabled || !_enabled || !Platform.isWindows) {
      debugPrint(
        '[builtin-capture-itest] FUSHI_WEB_VIDEO_BUILTIN_CAPTURE_ITEST != 1, skip',
      );
      return;
    }
    final String? argsOverride =
        Platform.environment['FUSHI_WEB_VIDEO_CAPTURABLE_ARGS'];
    if (argsOverride != null && argsOverride.isNotEmpty) {
      debugWebVideoCapturableBrowserArgumentsOverride = argsOverride;
      debugPrint('[builtin-capture-itest] capturable args := $argsOverride');
    }
    // app 启动时接管 FlutterError.onError（播放页里与本测试无关的调试断言照常进错误日志、不判
    // 本测试红）；收尾还给测试 binding，否则断言失败后 binding 卡住、进程不退出。
    final FlutterExceptionHandler? errorHandler = FlutterError.onError;
    addTearDown(() => FlutterError.onError = errorHandler);
    await launchFushiTestApp();
    expect(await waitForHome(tester), isTrue, reason: '主页应在 90s 内出现');
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
        title: const Value('Builtin capture itest'),
        videoPath: Value(_url),
      ),
    );
    container.invalidate(filteredVideoBookUidsProvider);
    // 旧全局偏好 = 对所有站点的手动选择（隔离数据根里，不碰用户偏好）。
    await appModel.prefsRepo.setPref(
      kWebVideoHostingPrefKey,
      WebVideoHosting.builtin.name,
    );
    debugPrint('[builtin-capture-itest] seeded uid=$uid url=$_url');

    expect(HomePage.debugSelectTab, isNotNull);
    HomePage.debugSelectTab!(HomeTab.video);
    await tester.pump(const Duration(seconds: 1));
    final BuildContext ctx = tester.element(find.byType(HomePage));
    // ignore: use_build_context_synchronously — 测试里刚从树上取的 element，同帧使用。
    unawaited(openLocalVideoBook(context: ctx, repo: repo, bookUid: uid));
    expect(
      await _waitUntil(
        tester,
        (VideoFushiTestHooks h) => h.debugIsWebBackend,
        timeout: const Duration(seconds: 30),
        what: 'web backend',
      ),
      isTrue,
      reason: '网页站流媒体书应在 VideoFushiPage 里以网页后端打开',
    );

    expect(
      _hooks(tester)?.debugWebHosting,
      WebVideoHosting.builtin,
      reason: '本测试固定在「制卡优先」档',
    );
    expect(
      await _waitUntil(
        tester,
        (VideoFushiTestHooks h) =>
            h.debugWebHasVideo &&
            h.debugIsPlaying &&
            (h.debugPositionMs ?? 0) > 0,
        timeout: const Duration(seconds: 90),
        what: 'video playing',
      ),
      isTrue,
      reason: '视频应在 90s 内起播',
    );
    // 让页面套上只留画面的样式、码率爬上来。
    for (int i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }

    final WebVideoCaptureStats? first = await _stats(tester);
    debugPrint('[builtin-capture-itest] first=$first');
    expect(first, isNotNull, reason: '「制卡优先」档应有截取链路（纹理桥）可体检');
    for (int i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    final WebVideoCaptureStats? second = await _stats(tester);
    debugPrint('[builtin-capture-itest] second=$second');
    expect(second, isNotNull);
    expect(
      second!.frames - first!.frames,
      greaterThanOrEqualTo(30),
      reason: '起播后 5 s 内纹理桥应持续收到 WGC 帧（BUG-5611：一帧都没有）',
    );
    expect(
      second.hasNonWhiteContent,
      isTrue,
      reason: '截到的帧不应是一片白（BUG-5611 症状）',
    );
    expect(
      second.hasVariedContent || first.hasVariedContent,
      isTrue,
      reason: '采样点之间应有差异（真画面，不是纯色底）',
    );
    // 取证：同一会话里把页面换到受保护（EME）样例，量「制卡优先」档实际截到什么。
    final String? probe = Platform.environment['FUSHI_WEB_VIDEO_PROBE_URL'];
    if (probe == null || probe.isEmpty) return;
    await _evalJs(tester, 'location.href = ${jsonEncode(probe)}; "ok"');
    for (int i = 0; i < 50; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    await _evalJs(
      tester,
      "(() => { const v = document.querySelector('video'); "
      'if (v) { v.muted = true; v.play(); '
      "document.documentElement.style.background = 'rgb(255,0,255)'; "
      "document.body.style.background = 'rgb(255,0,255)'; "
      "v.style.cssText = 'position:fixed;left:0;top:0;width:100vw;height:100vh;"
      "z-index:2147483647;object-fit:fill;background:rgb(255,0,255)'; } "
      'return 1; })()',
    );
    for (int i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    final WebVideoCaptureStats? p1 = await _stats(tester);
    for (int i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    final WebVideoCaptureStats? p2 = await _stats(tester);
    final String? page = await _evalJs(
      tester,
      "(() => { const v = document.querySelector('video'); return JSON.stringify("
      '{href: location.href.slice(0, 80), keys: !!(v && v.mediaKeys), '
      'w: v && v.videoWidth, t: v && v.currentTime, paused: v && v.paused}); })()',
    );
    debugPrint('[builtin-capture-itest] PROBE page=$page p1=$p1 p2=$p2');
    expect(
      page?.contains('"keys":true') ?? false,
      isTrue,
      reason: '取证页应是加密播放（<video>.mediaKeys 已挂上）',
    );
    expect(p1, isNotNull);
    expect(p2, isNotNull);
    expect(
      p2!.frames - p1!.frames,
      greaterThanOrEqualTo(10),
      reason: '加密视频播放时纹理桥仍应持续收到帧',
    );
    expect(
      p1.hasVariedContent && p2.hasVariedContent,
      isTrue,
      reason: '铺满页面的加密视频应截到真画面（BUG-5611：一片黑）',
    );
  });
}
