// BUG-2766：移动端「添加网络来源」对话框顶部的协议分段控制器（SFTP / FTP /
// WebDAV / AList）文字被逐字断行成竖排。
//
// 根因：对话框用了裸 SegmentedButton。手机上 AlertDialog 内容区只有 ~230dp，
// Material 把每段宽度钳到「可用宽 / 段数」，标签放不下就断行。修法改走共享的
// FushiSegmentedStrip（BUG-1184：段宽不小于最宽标签，装不下横向滚动）。
//
// 本测试在 360dp 手机宽度下走真实入口打开表单，断言每个协议标签都横排单行。
import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/pages/implementations/media_sources_view.dart';
import 'package:fushi_core/fushi_core.dart';

import '../helpers/test_platform_services.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'BUG-2766: network source transport labels stay on one line at phone width',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final AppModel appModel = AppModel(testPlatformServices())
      ..wireDatabaseForTesting(db);
    final GlobalKey<MediaSourcesViewState> viewKey =
        GlobalKey<MediaSourcesViewState>();

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          appProvider.overrideWith((ref) => appModel),
        ],
        child: MaterialApp(
          home: Scaffold(
            // book 域开放全部 4 个协议，最容易挤。
            body: MediaSourcesView(key: viewKey, mediaKind: 'book'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    viewKey.currentState!.addSource();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Network'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    for (final String label in <String>['SFTP', 'FTP', 'WebDAV', 'AList']) {
      final Finder text = find.text(label);
      expect(text, findsOneWidget, reason: label);
      final Size size = tester.getSize(text);
      // 竖排时文字框窄而高；横排单行必然宽大于高。
      expect(size.width, greaterThan(size.height), reason: '$label: $size');
    }
  });
}
