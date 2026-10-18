// 底层合成真机验证（Windows）：4K 窗口宿主档的 WebView2 垫在 Flutter 下面。
//
// 跑一本网页站流媒体书（默认 YouTube，无 DRM，桌面截图能看到画面；FUSHI_WEB_VIDEO_URL 换
// Netflix），宿主档写成 windowed → 页面开底层合成 → 断言：引擎接受了底层合成、视频起播、
// Flutter 字幕层 / 控件在这一档照常挂载（不再走 DOM 字幕层）。起播后停 40 s 打印 HOLD，
// 外部从桌面截图（DWM 合成后的真实画面：WebView 画面 + 上面的 Flutter 层）并用
// WindowFromPoint 核对画面中心的输入落在 Flutter 视图而不是 WebView 子窗口。
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
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:integration_test/integration_test.dart';

import 'package:fushi/src/media/video/underlay_composition.dart';
import 'package:fushi/src/media/video/url_stream_video.dart';
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
import 'package:fushi/src/pages/implementations/web_video_fushi_page.dart';

import 'helpers/observe_capture.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

bool get _enabled =>
    Platform.environment['FUSHI_WEB_VIDEO_UNDERLAY_ITEST'] == '1';

String get _url =>
    Platform.environment['FUSHI_WEB_VIDEO_URL'] ??
    'https://www.youtube.com/watch?v=aqz-KE-bpKQ';

Future<WebVideoDebugSnapshot?> _waitFor(
  WidgetTester tester,
  bool Function(WebVideoDebugSnapshot s) predicate, {
  required Duration timeout,
  required String what,
}) async {
  final int ticks = timeout.inMilliseconds ~/ 500;
  WebVideoDebugSnapshot? last;
  for (int i = 0; i < ticks; i++) {
    await tester.pump(const Duration(milliseconds: 500));
    final WebVideoDebugSnapshot Function()? read =
        WebVideoFushiPage.debugSnapshot;
    if (read == null) continue;
    last = read();
    if (predicate(last)) return last;
  }
  debugPrint('[underlay-itest] timeout waiting for $what; last=$last');
  return null;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('窗口宿主档 WebView2 垫在 Flutter 下面（底层合成）', (
    WidgetTester tester,
  ) async {
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
    bool pageUp = false;
    for (int i = 0; i < 40 && !pageUp; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      pageUp = find.byType(WebVideoFushiPage).evaluate().isNotEmpty;
    }
    expect(pageUp, isTrue, reason: '网页站流媒体书应分流到 WebVideoFushiPage');

    bool underlay = false;
    for (int i = 0; i < 20 && !underlay; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      underlay = underlayCompositionActive.value;
    }
    debugPrint('[underlay-itest] underlay active=$underlay');
    expect(
      underlay,
      isTrue,
      reason: '打了补丁的引擎应接受底层合成（原版引擎上恒 false）',
    );

    final WebVideoDebugSnapshot? playing = await _waitFor(
      tester,
      (WebVideoDebugSnapshot s) =>
          s.hasVideo && s.playing && (s.positionMs ?? 0) > 0,
      timeout: const Duration(seconds: 90),
      what: 'video playing',
    );
    final String? page = await WebVideoFushiPage.debugEvalJs?.call(
      "(() => { const v = document.querySelector('video'); return JSON.stringify("
      '{href: location.href.slice(0, 80), vw: v && v.videoWidth, vh: v && v.videoHeight, '
      "domSubs: !!document.getElementById('fushi-dom-subtitle')}); })()",
    );
    debugPrint('[underlay-itest] playing=$playing page=$page');
    expect(playing, isNotNull, reason: '视频应在 90s 内起播');
    expect(
      page?.contains('"domSubs":true') ?? false,
      isFalse,
      reason: '底层合成下不该再注入 DOM 字幕层（字幕归 Flutter）',
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
    final WebVideoDebugSnapshot after = WebVideoFushiPage.debugSnapshot!();
    debugPrint('[underlay-itest] HOLD end; after=$after');
    expect(
      (after.positionMs ?? 0) > (playing!.positionMs ?? 0),
      isTrue,
      reason: '停留期间视频应一直在播',
    );
  });
}
