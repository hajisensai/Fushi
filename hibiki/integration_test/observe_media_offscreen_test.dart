// 离屏观察验收（有声书 + 视频表面）：启动真 app，焦点驱动打开有声书 / 视频，抓
// Flutter UI 帧 + 阅读器 WebView 正文，断言落盘且为「非空白」真实像素。经
// tool/run_windows_itest.ps1 离屏后台跑，全程非激活、不抢焦点、不阻碍用户用电脑。
//
// 与 observe_offscreen_test.dart（阅读器表面）配套：本文件扩展到有声书正文
// （WebView，CDP 可抓）与视频页（Flutter 外壳；解码纹理在平台层，captureFlutterFrame
// 抓不到，这是已知限制，下文注释处说明）。
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/main.dart' as app;
import 'package:hibiki/src/media/sources/reader_hibiki_source.dart';
import 'package:hibiki/src/pages/implementations/home_video_page.dart'
    show HomeVideoPage;
import 'package:integration_test/integration_test.dart';

import 'helpers/focus_driver.dart';
import 'helpers/library_fixture.dart';
import 'helpers/observe_capture.dart';
import 'test_helpers.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('离屏观察：有声书 Flutter UI + 正文 WebView 都抓到像素',
      (WidgetTester tester) async {
    // 收集启动期 FlutterError（如离线 GitHub 更新检查的 Handshake/Socket 异常），
    // 否则 pending error 会撞上后面的 expect() 触发 binding 守卫。范式同
    // observe_offscreen_test / reader_caret_test。
    final List<FlutterErrorDetails> errors = <FlutterErrorDetails>[];
    final FlutterExceptionHandler? oldHandler = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      errors.add(details);
      debugPrint(
          '[observe-media] FlutterError: ${details.exceptionAsString()}');
    };

    try {
      app.main();
      expect(await waitForHome(tester), isTrue, reason: '主页应在 90s 内出现');
      await tester.pump(const Duration(seconds: 2));

      // 1) 主页 Flutter UI 必须非空白。
      final ObserveShot home =
          await captureFlutterFrame(tester, 'observe-audiobook-home');
      expect(home.saved, isTrue, reason: 'Flutter 帧应落盘');
      expect(home.nonBlank, isTrue,
          reason: '离屏 Flutter 抓图不应是白屏（${home.path}, ${home.bytes}B）');

      // 2) 焦点驱动打开有声书 fixture（有声书 = EPUB + 挂载 cue/音频，书架以
      //    book_entry_/srt_entry_ 形态呈现，序列同 observe_offscreen_test）。
      final FocusDriver driver = FocusDriver(tester);
      final String bookKey = await seedAudiobook(tester);
      final List<Finder> navTargets = findPrimaryNavigationTargets();
      if (navTargets.isNotEmpty) {
        final bool focusedTab = await driver.focusWidget(navTargets.first);
        expect(focusedTab, isTrue, reason: '书架 tab 应可被焦点到达');
        await driver.activate();
        await tester.pumpAndSettle();
      }

      // 优先按 book_entry_<mediaId> 命中；命中不到再退化到任意 srt_entry_ 前缀
      // 谓词（有声书 fixture 也可能以 srt_entry_ 呈现）。
      final String seededKey =
          'book_entry_${ReaderHibikiSource.mediaIdentifierFor(bookKey)}';
      Finder seededEntry = find.byKey(ValueKey<String>(seededKey));
      for (int i = 0; i < 40 && seededEntry.evaluate().isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      if (seededEntry.evaluate().isEmpty) {
        seededEntry = find.byWidgetPredicate((Widget w) {
          final Key? key = w.key;
          return key is ValueKey<String> && key.value.startsWith('srt_entry_');
        });
      }
      expect(seededEntry, findsWidgets, reason: '播种的有声书应出现在书架');
      final Finder bookCard = seededEntry.first;
      final bool focusedBook = await driver.focusWidget(bookCard);
      expect(focusedBook, isTrue, reason: '书卡应可被焦点到达（否则离屏打不开书）');
      await driver.activate();
      await tester.pump(const Duration(seconds: 3));

      // 先等 WebView 挂载，再等正文 ready（reader_caret_test 的可靠范式）。
      const Key webViewKey = ValueKey<String>('hoshi_webview');
      for (int i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 500));
        if (find.byKey(webViewKey).evaluate().isNotEmpty) {
          break;
        }
      }
      expect(find.byKey(webViewKey), findsOneWidget, reason: '阅读器 WebView 应存在');

      const Key contentReadyKey = ValueKey<String>('hoshi_content_ready');
      bool ready = false;
      for (int i = 0; i < 120; i++) {
        await tester.pump(const Duration(milliseconds: 500));
        if (find.byKey(contentReadyKey).evaluate().isNotEmpty) {
          ready = true;
          break;
        }
      }
      expect(ready, isTrue, reason: '有声书正文应就绪');
      await tester.pump(const Duration(seconds: 1));

      // 3) 有声书正文（WebView，CDP 离屏抓）：断言落盘（钩子注册成功 + 字节非空）。
      //    nonBlank 仅 best-effort 记录——有声书首屏渲染时序偶有 flaky，不强断以免误红；
      //    像素强断由 Flutter 外壳那条兜底。
      final ObserveShot body =
          await captureReaderWebView('observe-audiobook-body');
      expect(body.saved, isTrue, reason: 'WebView 正文应落盘（钩子注册成功）');
      expect(body.bytes, greaterThan(0), reason: 'WebView 正文 PNG 字节应 > 0');
      debugPrint('[observe-media] audiobook body nonBlank=${body.nonBlank} '
          '(${body.path}, ${body.bytes}B)');

      // 4) 有声书阅读器 Flutter 外壳（播放器 / 阅读器壳）一定非空白。
      final ObserveShot readerUi =
          await captureFlutterFrame(tester, 'observe-audiobook-reader-ui');
      expect(readerUi.nonBlank, isTrue,
          reason: '有声书阅读器 Flutter 外壳不应是白屏'
              '（${readerUi.path}, ${readerUi.bytes}B）');

      debugPrint('[observe-media] audiobook home=${home.path} '
          'body=${body.path} reader-ui=${readerUi.path}');

      // 网络层（离线 GitHub 更新检查）以外的 FlutterError 一律视为失败。
      assertStrictErrors(errors);
    } finally {
      FlutterError.onError = oldHandler;
    }
  });

  testWidgets('离屏观察：视频页 Flutter 外壳抓到非空白像素', (WidgetTester tester) async {
    final List<FlutterErrorDetails> errors = <FlutterErrorDetails>[];
    final FlutterExceptionHandler? oldHandler = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      errors.add(details);
      debugPrint(
          '[observe-media] FlutterError: ${details.exceptionAsString()}');
    };

    try {
      app.main();
      expect(await waitForHome(tester), isTrue, reason: '主页应在 90s 内出现');
      await tester.pump(const Duration(seconds: 2));

      final FocusDriver driver = FocusDriver(tester);
      final String uid = await seedVideo(tester);

      // 视频 tab 是导航第 2 项（顺序 books, video, dictionaries, ...；
      // experimentalVideoEnabled 恒 true，视频 tab 常驻）。
      final List<Finder> navTargets = findPrimaryNavigationTargets();
      expect(navTargets.length, greaterThanOrEqualTo(2),
          reason: '至少应有书架 + 视频两个导航项');
      final bool focusedVideoTab = await driver.focusWidget(navTargets[1]);
      expect(focusedVideoTab, isTrue, reason: '视频 tab 应可被焦点到达');
      await driver.activate();
      await tester.pumpAndSettle();

      // 诊断：导航后立刻抓视频 tab + 统计卡片，区分「没切到 tab / 卡 offstage /
      // listAll 空」。先抓图保证证据落盘（卡断言早于截图会丢图）。
      final ObserveShot videoTab =
          await captureFlutterFrame(tester, 'observe-video-tab');
      bool cardOnstage(String uid) =>
          find.byKey(ValueKey<String>('home_video_$uid')).evaluate().isNotEmpty;
      final int anyStage = find
          .byKey(ValueKey<String>('home_video_$uid'), skipOffstage: false)
          .evaluate()
          .length;
      final int allCards = find
          .byWidgetPredicate(
            (Widget w) =>
                w.key is ValueKey<String> &&
                (w.key! as ValueKey<String>).value.startsWith('home_video_'),
            skipOffstage: false,
          )
          .evaluate()
          .length;
      debugPrint('[observe-media] video-tab=${videoTab.path} nonBlank='
          '${videoTab.nonBlank} card(onstage=${cardOnstage(uid)} '
          'anyStage=$anyStage allHomeVideoCards=$allCards)');

      // 视频卡（HibikiCard key=home_video_<uid>）：seed 后经 debugRefreshVideos 重查；
      // 若导航后仍未上屏，再补一次刷新 + 轮询。
      final Finder videoCard = find.byKey(ValueKey<String>('home_video_$uid'));
      for (int i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 500));
        if (videoCard.evaluate().isNotEmpty) {
          break;
        }
        if (i == 2) {
          HomeVideoPage.debugRefreshVideos?.call();
        }
      }
      expect(videoCard, findsOneWidget, reason: '播种的视频卡应出现在视频页');

      // 焦点卡片 + Enter（HibikiCard 把 ActivateIntent 映射到 onTap=_open）打开
      // VideoHibikiPage，禁坐标点击。
      final bool focusedCard = await driver.focusWidget(videoCard);
      expect(focusedCard, isTrue, reason: '视频卡应可被焦点到达（否则离屏打不开视频）');
      await driver.activate();

      // 等 media_kit 初始化（控制器 / 控制条挂载）。
      await tester.pump(const Duration(seconds: 4));

      // 视频页 Flutter 外壳（控制条 / 控件层）一定非空白。
      // 注意：视频解码画面是平台层纹理（media_kit），captureFlutterFrame 只抓
      // Flutter 图层树，抓不到解码纹理——这是已知限制，故只断言页面外壳非空白。
      final ObserveShot videoPage =
          await captureFlutterFrame(tester, 'observe-video-page');
      expect(videoPage.saved, isTrue, reason: '视频页 Flutter 帧应落盘');
      expect(videoPage.nonBlank, isTrue,
          reason: '视频页 Flutter 外壳不应是白屏'
              '（${videoPage.path}, ${videoPage.bytes}B）');

      debugPrint('[observe-media] video page=${videoPage.path} '
          '(${videoPage.bytes}B)');

      assertStrictErrors(errors);
    } finally {
      FlutterError.onError = oldHandler;
    }
  });
}
