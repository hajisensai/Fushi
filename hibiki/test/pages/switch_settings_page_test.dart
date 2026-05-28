import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/src/pages/implementations/switch_settings_page.dart';
import 'package:hibiki/src/utils/spacing.dart';

import '../helpers/test_platform_services.dart';

void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  Widget buildApp(Widget home) {
    return ProviderScope(
      overrides: [
        appProvider.overrideWith((ref) => AppModel(testPlatformServices())),
      ],
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

  testWidgets('switch settings dialog lays out compact rows', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 240);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      buildApp(
        SwitchSettingsPage<String>(
          items: const {
            'first': true,
            'second': false,
          },
          generateLabel: (value) => 'Setting $value',
          onSave: (_) {},
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.byType(Switch), findsNWidgets(2));
  });
}
