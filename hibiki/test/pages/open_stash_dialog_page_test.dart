import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/pages/implementations/open_stash_dialog_page.dart';

void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  Widget buildApp(Widget child) {
    return TranslationProvider(
      child: MaterialApp(home: Scaffold(body: Center(child: child))),
    );
  }

  testWidgets('open stash dialog frame fits a compact desktop window', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 240);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      buildApp(
        OpenStashDialogFrame(
          content: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              for (int index = 0; index < 12; index++)
                Text('very long saved stash segment $index'),
            ],
          ),
          actions: const <Widget>[
            TextButton(onPressed: null, child: Text('Clear')),
            TextButton(onPressed: null, child: Text('Share')),
            TextButton(onPressed: null, child: Text('Search')),
            TextButton(onPressed: null, child: Text('Select')),
          ],
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('Select'), findsOneWidget);
  });

  testWidgets('open stash clear dialog fits a compact desktop window', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 240);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      buildApp(OpenStashClearDialog(onConfirm: () {})),
    );

    expect(tester.takeException(), isNull);
    expect(find.text(t.stash_clear_title), findsOneWidget);
    expect(find.text(t.dialog_clear), findsOneWidget);
  });
}
