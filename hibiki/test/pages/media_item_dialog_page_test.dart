import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/media_item_dialog_page.dart';

void main() {
  Widget buildApp(Widget child) {
    return MaterialApp(home: Scaffold(body: Center(child: child)));
  }

  testWidgets('media item dialog frame shows all actions', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      buildApp(
        MediaItemDialogFrame(
          title: const SelectableText('Test title'),
          content: const SizedBox(width: 260, height: 100),
          actions: const [
            TextButton(onPressed: null, child: Text('Clear')),
            TextButton(onPressed: null, child: Text('Extra')),
            TextButton(onPressed: null, child: Text('Edit')),
            FilledButton(onPressed: null, child: Text('Read')),
          ],
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('Clear'), findsOneWidget);
    expect(find.text('Extra'), findsOneWidget);
    expect(find.text('Edit'), findsOneWidget);
    expect(find.text('Read'), findsOneWidget);
  });
}
