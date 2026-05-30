import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/models/anki_integration.dart';

void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  Widget buildApp(Widget child) {
    return TranslationProvider(
      child: MaterialApp(home: Scaffold(body: Center(child: child))),
    );
  }

  testWidgets('Anki API message dialog fits a compact desktop window', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 240);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      buildApp(AnkiApiMessageDialog(onLaunch: () {})),
    );

    expect(tester.takeException(), isNull);
    expect(find.text(t.error_ankidroid_api), findsOneWidget);
    expect(find.text(t.dialog_launch_ankidroid), findsOneWidget);
  });

  testWidgets('Anki default model dialog fits a compact desktop window', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 240);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      buildApp(AnkiDefaultModelDialog(onClose: () {})),
    );

    expect(tester.takeException(), isNull);
    expect(find.text(t.info_standard_model), findsOneWidget);
    expect(find.text(t.dialog_close), findsOneWidget);
  });
}
