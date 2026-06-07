import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/src/sync/desktop_lookup_service.dart';
import 'package:hibiki/src/pages/implementations/desktop_lookup_overlay.dart';
import 'package:hibiki/src/utils/spacing.dart';

import '../helpers/test_platform_services.dart';

Widget _buildTestApp({required AppModel appModel, required Widget home}) {
  return ProviderScope(
    overrides: <Override>[appProvider.overrideWith((ref) => appModel)],
    child: TranslationProvider(
      child: MaterialApp(
        builder: (context, child) => Spacing(
          dataBuilder: (context) => SpacingData.generate(10),
          child: child ?? const SizedBox.shrink(),
        ),
        home: home,
      ),
    ),
  );
}

void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
    DesktopLookupService.instance.debugReset();
  });

  testWidgets(
      'idle overlay takes zero layout; pending clipboard text seeds the '
      'editable search field and is closeable', (tester) async {
    final AppModel appModel = AppModel(testPlatformServices());
    await tester.pumpWidget(_buildTestApp(
      appModel: appModel,
      home: const Scaffold(body: DesktopLookupOverlay()),
    ));
    await tester.pump();
    // 平时（无 pendingText）overlay 不渲染任何查词界面，只是 SizedBox.shrink。
    expect(find.byType(TextField), findsNothing);
    expect(find.byIcon(Icons.close), findsNothing);

    // 剪贴板文本到达：顶部搜索框预填该文本（与正式查词窗一致的可编辑搜索框），
    // 并出现关闭按钮。auto-search 因 AppModel 未初始化被守卫跳过（不触 WebView/DB）。
    DesktopLookupService.instance.submitText('見る');
    await tester.pump();
    await tester.pump(); // 排空 _maybeAutoSearch 的 postFrameCallback。
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('見る'), findsOneWidget); // EditableText 渲染 controller 值。
    expect(find.byIcon(Icons.close), findsOneWidget);

    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();
    expect(find.byType(TextField), findsNothing);
    expect(find.byIcon(Icons.close), findsNothing);
  });
}
