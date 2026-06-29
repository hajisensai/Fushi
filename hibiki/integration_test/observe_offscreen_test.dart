// 离屏观察验收：启动真 app，抓 Flutter UI 帧 + 阅读器 WebView 正文，断言两路都落盘且为
// 「非空白」真实像素。经 tool/run_windows_itest.ps1 离屏后台跑，全程非激活、不抢焦点、
// 不阻碍用户用电脑。
import 'package:flutter/material.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/main.dart' as app;
import 'package:hibiki/src/media/sources/reader_hibiki_source.dart';
import 'package:integration_test/integration_test.dart';

import 'helpers/focus_driver.dart';
import 'helpers/library_fixture.dart';
import 'helpers/observe_capture.dart';
import 'test_helpers.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('离屏观察：Flutter UI + 阅读器正文都抓到非空白像素',
      (WidgetTester tester) async {
    app.main();
    expect(await waitForHome(tester), isTrue, reason: '主页应在 90s 内出现');
    await tester.pump(const Duration(seconds: 2));

    // 1) Flutter UI（主页）必须非空白
    final ObserveShot home = await captureFlutterFrame(tester, 'observe-home');
    expect(home.saved, isTrue, reason: 'Flutter 帧应落盘');
    expect(home.nonBlank, isTrue,
        reason: '离屏 Flutter 抓图不应是白屏（${home.path}, ${home.bytes}B）');

    // 2) 焦点驱动打开阅读器 fixture（与 reader_caret_test 同序列）
    final FocusDriver driver = FocusDriver(tester);
    final String bookKey = await seedReaderBook(tester);
    final List<Finder> navTargets = findPrimaryNavigationTargets();
    if (navTargets.isNotEmpty) {
      await driver.focusWidget(navTargets.first);
      await driver.activate();
      await tester.pumpAndSettle();
    }
    final String seededKey =
        'book_entry_${ReaderHibikiSource.mediaIdentifierFor(bookKey)}';
    final Finder seededEntry = find.byKey(ValueKey<String>(seededKey));
    for (int i = 0; i < 40 && seededEntry.evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    expect(seededEntry, findsOneWidget, reason: '播种的书应出现在书架');
    await driver.focusWidget(seededEntry);
    await driver.activate();
    await tester.pump(const Duration(seconds: 3));

    const Key contentReadyKey = ValueKey<String>('hoshi_content_ready');
    bool ready = false;
    for (int i = 0; i < 120; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      if (find.byKey(contentReadyKey).evaluate().isNotEmpty) {
        ready = true;
        break;
      }
    }
    expect(ready, isTrue, reason: '阅读器正文应就绪');
    await tester.pump(const Duration(seconds: 1));

    // 3) 阅读器正文（WebView，CDP 离屏抓）必须非空白
    final ObserveShot body = await captureReaderWebView('observe-reader-body');
    expect(body.saved, isTrue, reason: 'WebView 正文应落盘（钩子注册成功）');
    expect(body.nonBlank, isTrue,
        reason: '离屏 WebView 正文不应是白屏（${body.path}, ${body.bytes}B）');

    debugPrint('[observe] home=${home.path} (${home.bytes}B) '
        'body=${body.path} (${body.bytes}B)');
  });
}
