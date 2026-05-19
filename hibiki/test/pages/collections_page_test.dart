import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/pages/implementations/collections_page.dart';

void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  Widget buildApp(Widget child) {
    return TranslationProvider(
      child: MaterialApp(home: child),
    );
  }

  testWidgets('collection delete dialog fits a compact desktop window', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 240);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      buildApp(
        CollectionDeleteDialog(
          message:
              '${t.collection_bookmark}: Very long collected sentence or bookmark label used to test compact Windows delete confirmation layout',
          onConfirm: _noop,
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text(t.dialog_delete), findsOneWidget);
  });
}

void _noop() {}
