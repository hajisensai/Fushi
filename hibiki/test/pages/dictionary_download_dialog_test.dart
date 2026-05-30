import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/pages/implementations/dictionary_dialog_page.dart';

void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  Widget buildApp(Widget child) {
    return TranslationProvider(
      child: MaterialApp(home: Scaffold(body: Center(child: child))),
    );
  }

  testWidgets('dictionary download selection dialog fits a compact window', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 240);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      buildApp(
        DictionaryDownloadSelectionDialogFrame(
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Text('Language'),
              for (int index = 0; index < 12; index++)
                Text('Recommended dictionary with a long label $index'),
            ],
          ),
          actions: const <Widget>[
            TextButton(onPressed: null, child: Text('Cancel')),
            FilledButton(onPressed: null, child: Text('Download 12')),
          ],
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('Download 12'), findsOneWidget);
  });

  testWidgets('dictionary download progress dialog fits a compact window', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 240);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      buildApp(
        DictionaryDownloadProgressDialog(
          message:
              'Downloading a recommended dictionary with a long visible name',
          progressListenable: ValueNotifier<double>(0.42),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
  });
}
