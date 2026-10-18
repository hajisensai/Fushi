// 底层合成真机验证（Windows）：网页站流媒体书在**原生播放器页**里播放——4K 窗口宿主档的
// WebView2 垫在 Flutter 下面，控制条 / 字幕 / 查词是原生播放器页自己的那一套。
//
// 跑一本网页站流媒体书（默认 YouTube，无 DRM，桌面截图能看到画面；FUSHI_WEB_VIDEO_URL 换
// Netflix），宿主档写成 windowed → 断言：书架入口分流到 VideoFushiPage（不再是
// WebVideoFushiPage）、引擎接受了底层合成、controller 跑在网页后端上、原生控制条挂着、
// 视频起播、页面只留画面（videoOnly style）。起播后停 40 s 打印 HOLD，外部从桌面截图
// （DWM 合成后的真实画面：WebView 画面 + 上面的 Flutter 层）并用 WindowFromPoint 核对画面
// 中心的输入落在 Flutter 视图而不是 WebView 子窗口；停留结束时站点解码高度应高于 720。
//
// 依赖打了 engine-underlay-composition.patch 的 flutter_windows.dll（原版引擎上
// underlayCompositionActive 恒 false，本测试按失败报出）。默认 skip，仅在
// FUSHI_WEB_VIDEO_UNDERLAY_ITEST=1 时跑：
//   $env:FUSHI_WEB_VIDEO_UNDERLAY_ITEST=1; .\tool\run_windows_itest.ps1 -Visible -KeepUserDirs `
//     -RunId web-video-underlay integration_test\web_video_underlay_itest.dart
// Netflix 另需 FUSHI_WEB_VIDEO_4K_USER_DATA_FOLDER 指向 %LOCALAPPDATA% 下已登录的 profile。
import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit_video/media_kit_video.dart' show Video;

import 'package:fushi/src/media/video/underlay_composition.dart';
import 'package:fushi/src/media/video/url_stream_video.dart';
import 'package:fushi/src/media/video/video_subtitle_overlay.dart'
    show VideoSubtitleOverlay;
import 'package:fushi_engine/media/video/video_book_repository.dart';
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
import 'package:fushi/src/pages/implementations/web_video_fushi_page.dart'
    show WebVideoFushiPage;

import 'helpers/observe_capture.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

bool get _enabled =>
    Platform.environment['FUSHI_WEB_VIDEO_UNDERLAY_ITEST'] == '1';

String get _url =>
    Platform.environment['FUSHI_WEB_VIDEO_URL'] ??
    'https://www.youtube.com/watch?v=aqz-KE-bpKQ';

/// 原生播放器页的状态快照（读 [VideoFushiTestHooks]，不从控件图标推断）。
typedef _PageSnapshot = ({
  bool webBackend,
  bool hasVideo,
  bool playing,
  int? positionMs,
  int videoHeight,
});

VideoFushiTestHooks? _hooks(WidgetTester tester) {
  final Finder page = find.byType(VideoFushiPage);
  if (page.evaluate().isEmpty) return null;
  return tester.state<State<VideoFushiPage>>(page) as VideoFushiTestHooks;
}

_PageSnapshot? _snapshot(WidgetTester tester) {
  final VideoFushiTestHooks? h = _hooks(tester);
  if (h == null) return null;
  return (
    webBackend: h.debugIsWebBackend,
    hasVideo: h.debugWebHasVideo,
    playing: h.debugIsPlaying,
    positionMs: h.debugPositionMs,
    videoHeight: h.debugWebVideoHeight,
  );
}

Future<_PageSnapshot?> _waitFor(
  WidgetTester tester,
  bool Function(_PageSnapshot s) predicate, {
  required Duration timeout,
  required String what,
}) async {
  final int ticks = timeout.inMilliseconds ~/ 500;
  _PageSnapshot? last;
  for (int i = 0; i < ticks; i++) {
    await tester.pump(const Duration(milliseconds: 500));
    final _PageSnapshot? s = _snapshot(tester);
    if (s == null) continue;
    last = s;
    if (predicate(s)) return s;
  }
  debugPrint('[underlay-itest] timeout waiting for $what; last=$last');
  return null;
}

Future<String?> _evalJs(WidgetTester tester, String js) async =>
    _hooks(tester)?.debugWebEvalJs(js);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('网页站流媒体书在原生播放器页播放（底层合成，原生控件）', (WidgetTester tester) async {
    if (!kWebVideoPlayerEnabled || !_enabled) {
      debugPrint('[underlay-itest] FUSHI_WEB_VIDEO_UNDERLAY_ITEST != 1, skip');
      return;
    }
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
        title: const Value('Underlay itest'),
        videoPath: Value(_url),
      ),
    );
    container.invalidate(filteredVideoBookUidsProvider);
    await appModel.prefsRepo.setPref(
      kWebVideoHostingPrefKey,
      WebVideoHosting.windowed.name,
    );
    debugPrint('[underlay-itest] seeded uid=$uid url=$_url');

    expect(HomePage.debugSelectTab, isNotNull);
    HomePage.debugSelectTab!(HomeTab.video);
    await tester.pump(const Duration(seconds: 1));
    final BuildContext ctx = tester.element(find.byType(HomePage));
    // ignore: use_build_context_synchronously — 测试里刚从树上取的 element，同帧使用。
    unawaited(openLocalVideoBook(context: ctx, repo: repo, bookUid: uid));
    final _PageSnapshot? opened = await _waitFor(
      tester,
      (_PageSnapshot s) => s.webBackend,
      timeout: const Duration(seconds: 30),
      what: 'VideoFushiPage on the web backend',
    );
    expect(opened, isNotNull, reason: '网页站流媒体书应在 VideoFushiPage 里以网页后端打开');
    expect(
      find.byType(WebVideoFushiPage),
      findsNothing,
      reason: '底层合成可用时不该再分流到内置网页播放器页',
    );

    bool underlay = false;
    for (int i = 0; i < 20 && !underlay; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      underlay = underlayCompositionActive.value;
    }
    debugPrint('[underlay-itest] underlay active=$underlay');
    expect(underlay, isTrue, reason: '打了补丁的引擎应接受底层合成（原版引擎上恒 false）');

    final _PageSnapshot? playing = await _waitFor(
      tester,
      (_PageSnapshot s) => s.hasVideo && s.playing && (s.positionMs ?? 0) > 0,
      timeout: const Duration(seconds: 90),
      what: 'video playing',
    );
    final String? page = await _evalJs(
      tester,
      "(() => { const v = document.querySelector('video'); return JSON.stringify("
      '{href: location.href.slice(0, 80), vw: v && v.videoWidth, vh: v && v.videoHeight, '
      "domSubs: !!document.getElementById('fushi-dom-subtitle'), "
      "videoOnly: !!document.getElementById('fushi-video-only-style')}); })()",
    );
    debugPrint('[underlay-itest] playing=$playing page=$page');
    expect(playing, isNotNull, reason: '视频应在 90s 内起播');
    expect(
      page?.contains('"domSubs":true') ?? false,
      isFalse,
      reason: '底层合成下不该再注入 DOM 字幕层（字幕归 Flutter）',
    );
    expect(
      page?.contains('"videoOnly":true') ?? false,
      isTrue,
      reason: '底层合成下页面只留画面（侧栏 / 评论等站点 UI 隐藏）',
    );

    // 原生播放器页自己的控件：media_kit Video + 本页的 controls builder（不是手写控制条；
    // 可点字幕层只在那个 builder 里挂）。
    expect(
      find.byType(Video),
      findsOneWidget,
      reason: '有视频时应挂上原生播放器页的 Video + 控制条',
    );
    expect(
      find.byType(VideoSubtitleOverlay),
      findsWidgets,
      reason: '原生播放器页的 controls builder（控制条 + 可点字幕层）应挂在 Video 上',
    );

    final ObserveShot frame = await captureFlutterFrame(
      tester,
      'observe-web-video-underlay-flutter',
    );
    debugPrint('[underlay-itest] flutter frame ${frame.path}');

    // 外部取证窗口：桌面截图 + WindowFromPoint。
    debugPrint('[underlay-itest] HOLD begin');
    for (int i = 0; i < 80; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    // 铺满后站点按全屏尺寸重新选码率：停留结束时实际解码高度应高于 720（窗口 2560x1440）。
    final String? dims = await _evalJs(
      tester,
      "(() => { const v = document.querySelector('video'); "
      "return v ? String(v.videoHeight) : '0'; })()",
    );
    debugPrint('[underlay-itest] decoded height after hold=$dims');
    expect(
      int.tryParse((dims ?? '0').replaceAll('"', '')) ?? 0,
      greaterThan(720),
      reason: '铺满后应升到高于 720p 的码率',
    );
    final _PageSnapshot? after = _snapshot(tester);
    debugPrint('[underlay-itest] HOLD end; after=$after');
    expect(
      (after?.positionMs ?? 0) > (playing!.positionMs ?? 0),
      isTrue,
      reason: '停留期间视频应一直在播',
    );
  });
}
