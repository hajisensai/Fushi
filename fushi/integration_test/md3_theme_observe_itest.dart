import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:fushi/models.dart';
import 'package:fushi/pages.dart';

import 'helpers/library_fixture.dart';
import 'helpers/observe_capture.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

/// MD3 主题收敛的真 app 取证：首页 / 书架 / 视频首页 / 设置，浅色与深色各一帧。
///
/// 只截图 + 打印 ColorScheme 关键角色做证据；改前改后用同一份脚本跑、逐帧对比。
/// 明暗用 `setBrightnessMode` 切，结束时还原成进入时的值。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const List<(HomeTab, String)> pages = <(HomeTab, String)>[
    (HomeTab.home, 'dashboard'),
    (HomeTab.books, 'bookshelf'),
    (HomeTab.video, 'video-home'),
    (HomeTab.settings, 'settings'),
  ];

  testWidgets('MD3 主题：四个库页浅色/深色取证', (WidgetTester tester) async {
    await launchFushiTestApp();
    expect(await waitForHome(tester), isTrue, reason: '主页应在 90s 内出现');
    await tester.pump(const Duration(seconds: 2));
    final AppModel appModel = await readyAppModel(tester);

    await seedReaderBook(tester);
    await seedVideo(tester);

    final String original = appModel.themeNotifier.brightnessMode;
    try {
      for (final String mode in <String>['light', 'dark']) {
        await appModel.setBrightnessMode(mode);
        await tester.pump(const Duration(seconds: 2));
        for (final (HomeTab tab, String name) in pages) {
          HomePage.debugSelectTab?.call(tab);
          await tester.pump(const Duration(seconds: 3));
          final ObserveShot shot =
              await captureFlutterFrame(tester, '$name-$mode');
          expect(shot.saved, isTrue, reason: '$name-$mode 应抓到帧');
        }
        final ColorScheme cs = Theme.of(
          tester.element(find.byType(Scaffold).first),
        ).colorScheme;
        debugPrint('[md3-probe] $mode brightness=${cs.brightness} '
            'surface=${cs.surface} primary=${cs.primary}');
      }
    } finally {
      await appModel.setBrightnessMode(original);
      await tester.pump(const Duration(seconds: 1));
    }
  });
}
