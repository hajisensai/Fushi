import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/pages/implementations/anki_settings_page.dart';

void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  Widget buildApp(Widget child) {
    return TranslationProvider(
      child: MaterialApp(home: child),
    );
  }

  testWidgets('anki handlebar picker fits a compact desktop window', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 240);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      buildApp(
        AnkiHandlebarPickerDialog(
          title: 'Select value for Expression',
          initialValue: '{expression}',
          options: List<String>.generate(
            24,
            (index) => '{single-glossary-long-dictionary-name-$index}',
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.byType(TextField), findsOneWidget);
  });
}
