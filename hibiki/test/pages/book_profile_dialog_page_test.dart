import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/pages/implementations/reader_hoshi_history_page.dart';
import 'package:hibiki_core/hibiki_core.dart';

void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  Widget buildApp(Widget home) {
    return TranslationProvider(
      child: MaterialApp(home: home),
    );
  }

  ProfileRow profile(int index) {
    return ProfileRow(
      id: index,
      name: 'Very long profile name used for compact window testing $index',
      createdAt: index,
      updatedAt: index,
    );
  }

  testWidgets('book profile dialog content fits a compact desktop window', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 240);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      buildApp(
        BookProfileDialogContent(
          activeProfileName:
              'Very long active profile name used for compact windows',
          profiles: List.generate(16, profile),
          selectedProfileId: null,
          onChanged: (_) {},
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.byType(RadioListTile<int?>), findsWidgets);
  });
}
