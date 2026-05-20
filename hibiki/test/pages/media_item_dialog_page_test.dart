import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/media_item_dialog_page.dart';

void main() {
  Widget buildApp(Widget child) {
    return MaterialApp(home: Scaffold(body: Center(child: child)));
  }

  testWidgets('media item dialog frame renders all sections', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      buildApp(
        MediaItemDialogFrame(
          cover: const SizedBox(width: 260, height: 100),
          title: 'Test title',
          author: 'Test author',
          launchLabel: 'READ',
          onLaunch: () {},
          quickActions: [
            DialogQuickAction(
              label: 'Illustrations',
              icon: Icons.image_outlined,
              onPressed: () {},
            ),
            DialogQuickAction(
              label: 'Audiobook',
              icon: Icons.headphones_outlined,
              onPressed: () {},
            ),
          ],
          listActions: [
            DialogListAction(label: 'Book Profile', onPressed: () {}),
            DialogListAction(label: 'Edit CSS', onPressed: () {}),
          ],
          dangerActions: [
            DialogDangerAction(label: 'Delete', onPressed: () {}),
            DialogDangerAction(label: 'Clear', onPressed: () {}, muted: true),
          ],
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('Test title'), findsOneWidget);
    expect(find.text('Test author'), findsOneWidget);
    expect(find.text('READ'), findsOneWidget);
    expect(find.text('Illustrations'), findsOneWidget);
    expect(find.text('Audiobook'), findsOneWidget);
    expect(find.text('Book Profile'), findsOneWidget);
    expect(find.text('Edit CSS'), findsOneWidget);
    expect(find.text('Delete'), findsOneWidget);
    expect(find.text('Clear'), findsOneWidget);
  });

  testWidgets('dialog frame hides cover section when cover is null', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      buildApp(
        MediaItemDialogFrame(
          title: 'No cover',
          launchLabel: 'READ',
          onLaunch: () {},
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('No cover'), findsOneWidget);
    final containerFinder = find.byWidgetPredicate(
      (w) => w is Container && w.color != null,
    );
    expect(containerFinder, findsNothing);
  });

  testWidgets('dialog frame hides author when null', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      buildApp(
        MediaItemDialogFrame(
          cover: const SizedBox(width: 260, height: 100),
          title: 'Title only',
          launchLabel: 'READ',
          onLaunch: () {},
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('Title only'), findsOneWidget);
    expect(find.text('READ'), findsOneWidget);
    expect(find.byType(ListTile), findsNothing);
  });
}
