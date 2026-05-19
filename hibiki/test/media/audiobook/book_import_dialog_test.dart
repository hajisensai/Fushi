import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/audiobook/book_import_dialog.dart';

void main() {
  Widget buildApp(Widget child) {
    return MaterialApp(home: Scaffold(body: Center(child: child)));
  }

  testWidgets('book import dialog frame fits compact form content', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 240);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      buildApp(
        BookImportDialogFrame(
          title: const Text('Import Book'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: const [
              TextField(decoration: InputDecoration(labelText: 'EPUB')),
              TextField(decoration: InputDecoration(labelText: 'Subtitle')),
              TextField(decoration: InputDecoration(labelText: 'Audio')),
              TextField(decoration: InputDecoration(labelText: 'Cover')),
              TextField(decoration: InputDecoration(labelText: 'Title')),
              TextField(decoration: InputDecoration(labelText: 'Author')),
            ],
          ),
          actions: const [
            TextButton(onPressed: null, child: Text('Cancel')),
            FilledButton(onPressed: null, child: Text('Import')),
          ],
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('Import'), findsWidgets);
  });
}
