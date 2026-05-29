import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/utils/misc/update_checker.dart';

void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  Widget buildApp(Widget child) {
    return TranslationProvider(
      child: MaterialApp(home: Scaffold(body: Center(child: child))),
    );
  }

  testWidgets('update available dialog fits a compact desktop window', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 240);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      buildApp(
        UpdateAvailableDialog(
          version: '9.9.9',
          releaseNotes: [
            '## Changes',
            '',
            '- Very long release note item that wraps in a compact dialog.',
            '- Another item with [a link](https://example.com).',
          ].join('\n'),
          primaryLabel: t.update_download,
          onPrimary: () {},
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text(t.update_available), findsOneWidget);
    expect(find.text(t.update_download), findsOneWidget);
  });
}
