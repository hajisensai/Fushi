import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/sync/sync_message_dialog.dart';

void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  Widget buildApp(Widget child) {
    return TranslationProvider(
      child: MaterialApp(home: Scaffold(body: Center(child: child))),
    );
  }

  testWidgets('sync message dialog fits a compact desktop window', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 220);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      buildApp(
        SyncMessageDialog(
          message:
              'Sync failed because the remote service returned a long status '
              'message that must wrap without overflowing the compact dialog.',
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text(t.dialog_done), findsOneWidget);
  });
}
