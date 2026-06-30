// 离屏观察验收：启动真 app，抓 Flutter UI 帧 + 阅读器 WebView 正文，断言两路都落盘且为
// 「非空白」真实像素。经 tool/run_windows_itest.ps1 跑——纯 Flutter UI 离屏可抓；阅读器
// 经 openMedia 打开（会初始化音频处理器），media_kit 在纯离屏 parked 窗口下初始化会挂，
// 故含 openMedia 的用例用 -Visible（屏幕内非激活窗，DWM 合成）跑，全程不抢焦点。
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/main.dart' as app;
import 'package:hibiki/src/media/sources/reader_hibiki_source.dart';
import 'package:hibiki/src/pages/implementations/reader_hibiki_history_page.dart'
    show ReaderHibikiHistoryPage;
import 'package:integration_test/integration_test.dart';

import 'helpers/library_fixture.dart';
import 'helpers/observe_capture.dart';
import 'test_helpers.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('离屏观察：Flutter UI + 阅读器正文都抓到非空白像素', (WidgetTester tester) async {
    // 收集启动期 FlutterError（如离线 GitHub 更新检查的 Handshake/Socket 异常），
    // 否则 pending error 会撞上后面的 expect() 触发 binding 守卫。范式同 reader_caret_test。
    final List<FlutterErrorDetails> errors = <FlutterErrorDetails>[];
    final FlutterExceptionHandler? oldHandler = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      errors.add(details);
      debugPrint('[observe] FlutterError: ${details.exceptionAsString()}');
    };

    try {
      app.main();
      expect(await waitForHome(tester), isTrue, reason: '主页应在 90s 内出现');
      await tester.pump(const Duration(seconds: 2));

      // 1) Flutter UI（主页）必须非空白
      final ObserveShot home =
          await captureFlutterFrame(tester, 'observe-home');
      expect(home.saved, isTrue, reason: 'Flutter 帧应落盘');
      expect(home.nonBlank, isTrue,
          reason: 'Flutter 抓图不应是白屏（${home.path}, ${home.bytes}B）');

      // 2) 确定性打开阅读器 fixture：焦点卡激活在离屏/非焦点下偶发不触发书卡 onTap，
      //    故用书架页测试钩子按 mediaIdentifier 走书卡同路径 appModel.openMedia。
      final String bookKey = await seedReaderBook(tester);
      final String mediaId = ReaderHibikiSource.mediaIdentifierFor(bookKey);
      final Finder seededEntry =
          find.byKey(ValueKey<String>('book_entry_$mediaId'));
      for (int i = 0; i < 40 && seededEntry.evaluate().isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      expect(seededEntry, findsOneWidget, reason: '播种的书应出现在书架');
      expect(ReaderHibikiHistoryPage.debugOpenBook, isNotNull,
          reason: '书架页打开书测试钩子应已注册（debug/profile build）');
      // openMedia 会初始化音频处理器；纯离屏会挂，-Visible 下能完成。加超时兜底
      // fail-fast，绝不让测试无限挂起。
      try {
        await ReaderHibikiHistoryPage.debugOpenBook!(mediaId)
            .timeout(const Duration(seconds: 30));
      } on TimeoutException {
        debugPrint('[observe] openMedia 超时（音频处理器初始化在纯离屏阻塞？改用 -Visible）');
      }
      await tester.pump(const Duration(seconds: 3));

      // 等阅读器 WebView 创建钩子就绪（onWebViewCreated 注册，跨章节/歌词模式可靠）。
      bool readerReady = false;
      for (int i = 0; i < 120; i++) {
        await tester.pump(const Duration(milliseconds: 500));
        if (readerWebViewReady()) {
          readerReady = true;
          break;
        }
      }
      expect(readerReady, isTrue,
          reason: '阅读器 WebView 应已创建（debugCaptureWebView 钩子就绪）');
      // 等正文 ready（best-effort）。
      for (int i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 500));
        if (find
            .byKey(const ValueKey<String>('hoshi_content_ready'))
            .evaluate()
            .isNotEmpty) {
          break;
        }
      }
      await tester.pump(const Duration(seconds: 1));

      // 3) 阅读器正文（WebView，CDP 抓）必须非空白
      final ObserveShot body =
          await captureReaderWebView('observe-reader-body');
      expect(body.saved, isTrue, reason: 'WebView 正文应落盘（钩子注册成功）');
      expect(body.nonBlank, isTrue,
          reason: '阅读器正文不应是白屏（${body.path}, ${body.bytes}B）');

      debugPrint('[observe] home=${home.path} (${home.bytes}B) '
          'body=${body.path} (${body.bytes}B)');

      // 网络层（离线 GitHub 更新检查）以外的 FlutterError 一律视为失败。
      assertStrictErrors(errors);
    } finally {
      FlutterError.onError = oldHandler;
    }
  });
}
