import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/src/sync/desktop_lookup_service.dart';
import 'package:hibiki/src/pages/implementations/desktop_lookup_overlay.dart';
import 'package:hibiki/src/pages/implementations/popup_dictionary_page.dart';
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
      'idle listener renders zero layout and pushes a full lookup page with a '
      'top-left back button when clipboard text arrives', (tester) async {
    final AppModel appModel = AppModel(testPlatformServices());
    await tester.pumpWidget(_buildTestApp(
      appModel: appModel,
      home: const Scaffold(body: DesktopLookupOverlay()),
    ));
    await tester.pump();

    // 平时（无 pendingText）监听器零布局，不渲染任何查词界面 / 不 push 任何页面。
    expect(find.byType(PopupDictionaryPage), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('desktop_lookup_back_button')),
      findsNothing,
    );

    // 剪贴板文本到达：push 一个完整查词页面（复用 PopupDictionaryPage），
    // 左上角带返回按钮；auto-search 因 AppModel 未初始化被守卫跳过（不触 WebView/DB）。
    DesktopLookupService.instance.submitText('見る');
    await tester.pump(); // 触发 _onPending → push
    await tester.pump(const Duration(milliseconds: 350)); // 排空路由过渡动画
    expect(find.byType(PopupDictionaryPage), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('desktop_lookup_back_button')),
      findsOneWidget,
    );
    // push 后 pendingText 已清，避免重复 push。
    expect(DesktopLookupService.instance.pendingText, isNull);

    // 左上角返回按钮可关闭整页，回到首页。
    await tester.tap(
      find.byKey(const ValueKey<String>('desktop_lookup_back_button')),
    );
    await tester.pumpAndSettle();
    expect(find.byType(PopupDictionaryPage), findsNothing);
  });
}
