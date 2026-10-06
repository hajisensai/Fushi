import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:fushi/pages.dart';

import 'helpers/library_fixture.dart';
import 'helpers/observe_capture.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

/// 「浏览」模块（2026-09-27，原「下载」）真 app 取证：底栏标签与四个页签真的渲染、
/// 各页签的内容域条在、视频库不再有「发现」分区。
///
/// 只截图 + 打印可见文案做证据；切页签用 TabController（取证用，不是交互断言）。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  List<String> visibleTexts(WidgetTester tester) => <String>{
    for (final Element e in find.byType(Text).evaluate())
      if ((e.widget as Text).data case final String s when s.trim().isNotEmpty)
        s.trim(),
  }.toList();

  testWidgets('浏览页签与内容域在真 app 里渲染', (WidgetTester tester) async {
    await launchFushiTestApp();
    expect(await waitForHome(tester), isTrue, reason: '主页应在 90s 内出现');
    await tester.pump(const Duration(seconds: 2));
    await readyAppModel(tester);

    HomePage.debugSelectTab?.call(HomeTab.browse);
    await tester.pump(const Duration(seconds: 3));
    expect(find.byType(BrowsePage), findsOneWidget);

    final Element tabView = find.byType(TabBarView).evaluate().first;
    final TabController controller = DefaultTabController.of(tabView);
    debugPrint('[browse-probe] tab count=${controller.length}');
    for (int i = 0; i < controller.length; i++) {
      controller.index = i;
      await tester.pump(const Duration(seconds: 3));
      final ObserveShot shot = await captureFlutterFrame(
        tester,
        'browse-tab-$i',
      );
      expect(shot.saved, isTrue);
      debugPrint('[browse-probe] tab $i texts: ${visibleTexts(tester)}');
    }

    HomePage.debugSelectTab?.call(HomeTab.video);
    await tester.pump(const Duration(seconds: 3));
    final ObserveShot video = await captureFlutterFrame(tester, 'video-library');
    expect(video.saved, isTrue);
    debugPrint('[browse-probe] video texts: ${visibleTexts(tester)}');
  });
}
