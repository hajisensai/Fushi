import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/pages/implementations/reader_hibiki_history_page.dart';

void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  Widget buildApp(Widget child) {
    return TranslationProvider(
      child: MaterialApp(home: Scaffold(body: Center(child: child))),
    );
  }

  testWidgets('batch tag dialog frame fits a compact desktop window', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 240);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      buildApp(
        ReaderHistoryBatchTagDialogFrame(
          canApply: true,
          onApply: () {},
          body: ListView(
            shrinkWrap: true,
            children: <Widget>[
              for (int index = 0; index < 12; index++)
                ListTile(
                  leading: const Icon(Icons.sell_outlined),
                  title: Text(
                    'Very long tag name used for compact layout $index',
                  ),
                ),
            ],
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text(t.batch_tag_title), findsOneWidget);
    expect(find.text(t.batch_tag_apply), findsOneWidget);
  });
}
