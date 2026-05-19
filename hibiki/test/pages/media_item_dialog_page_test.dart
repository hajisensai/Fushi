import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/media_item_dialog_page.dart';

void main() {
  Widget buildApp(Widget child) {
    return MaterialApp(home: Scaffold(body: Center(child: child)));
  }

  testWidgets('media item dialog frame fits compact title and actions', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 240);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      buildApp(
        MediaItemDialogFrame(
          title: const SelectableText(
            'Very long media title used to test compact Windows media item dialog layout',
            maxLines: 1,
          ),
          content: const SizedBox(width: 260, height: 640),
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
    expect(find.text('Read'), findsOneWidget);
  });
}
