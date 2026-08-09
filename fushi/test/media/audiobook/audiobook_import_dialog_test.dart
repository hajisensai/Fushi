import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/audiobook/audiobook_import_dialog.dart';

void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  Widget buildApp(Widget child) {
    return TranslationProvider(
      child: MaterialApp(home: Scaffold(body: Center(child: child))),
    );
  }

  testWidgets('audiobook import dialog frame fits compact form content', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 480);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      buildApp(
        AudiobookImportDialogFrame(
          title: t.audiobook_import,
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: const <Widget>[
              TextField(decoration: InputDecoration(labelText: 'Audio')),
              TextField(decoration: InputDecoration(labelText: 'Alignment')),
              TextField(decoration: InputDecoration(labelText: 'Window')),
              TextField(decoration: InputDecoration(labelText: 'Threshold')),
            ],
          ),
          actions: const <Widget>[
            TextButton(onPressed: null, child: Text('Cancel')),
            FilledButton(onPressed: null, child: Text('Import')),
          ],
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text(t.audiobook_import), findsOneWidget);
    expect(find.text('Import'), findsOneWidget);
  });

  testWidgets('audiobook remove confirmation fits compact desktop window', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 480);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      buildApp(AudiobookRemoveConfirmationDialog(onConfirm: () {})),
    );

    expect(tester.takeException(), isNull);
    expect(find.text(t.audiobook_delete_confirm), findsOneWidget);
    expect(find.text(t.audiobook_delete), findsOneWidget);
    expect(find.text(t.dialog_delete), findsOneWidget);
  });
}
