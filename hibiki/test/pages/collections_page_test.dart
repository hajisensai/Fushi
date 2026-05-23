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

  testWidgets('collection item dialog shows all actions', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      buildApp(
        CollectionItemDialogFrame(
          title: const SelectableText(
            'Very long favorite sentence used to test compact Windows collection item dialog layout',
            maxLines: 3,
          ),
          content: const Text(
            'Very long book title used to test compact collection dialog content',
          ),
          actions: const [
            TextButton(onPressed: null, child: Text('Play')),
            TextButton(onPressed: null, child: Text('Copy')),
            TextButton(onPressed: null, child: Text('Delete')),
            FilledButton(onPressed: null, child: Text('Read')),
          ],
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('Play'), findsOneWidget);
    expect(find.text('Copy'), findsOneWidget);
    expect(find.text('Delete'), findsOneWidget);
    expect(find.text('Read'), findsOneWidget);
  });
}

void _noop() {}
