import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/media_item_dialog_page.dart';

/// The long-press "book settings" dialog shows the cover complete at the top and
/// a column of full-width action buttons below it: a primary "read" launch
/// button, quick actions, list actions, and (muted) destructive actions. The
/// buttons live in their own below-cover column instead of translucent chips
/// stacked over the cover, so the artwork is never eaten by the controls.
void main() {
  Widget buildApp(Widget child) {
    return MaterialApp(home: Scaffold(body: Center(child: child)));
  }

  List<DialogQuickAction> quick() => <DialogQuickAction>[
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
      ];

  List<DialogListAction> list() => <DialogListAction>[
        DialogListAction(label: 'Book Profile', onPressed: () {}),
        DialogListAction(label: 'Edit CSS', onPressed: () {}),
      ];

  testWidgets('a full-width launch button reads the book below the cover',
      (WidgetTester tester) async {
    int launched = 0;
    await tester.pumpWidget(
      buildApp(
        MediaItemDialogFrame(
          cover: const SizedBox(width: 260, height: 100),
          title: 'Test title',
          author: 'Test author',
          launchLabel: 'READ',
          onLaunch: () => launched++,
          quickActions: quick(),
          listActions: list(),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    // The launch action is a real labelled FilledButton, not a cover tap.
    expect(find.widgetWithText(FilledButton, 'READ'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'READ'));
    await tester.pump();
    expect(launched, 1, reason: 'tapping READ should invoke onLaunch');
  });

  testWidgets('the cover is rendered complete and is not a read affordance',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      buildApp(
        MediaItemDialogFrame(
          cover: const SizedBox(
            key: ValueKey<String>('cover-image'),
            width: 260,
            height: 100,
          ),
          title: 'Test title',
          launchLabel: 'READ',
          onLaunch: () {},
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    // The cover widget is shown directly (no InkWell read wrapper over it); the
    // read affordance is the separate FilledButton, not the cover.
    expect(find.byKey(const ValueKey<String>('cover-image')), findsOneWidget);
    final Finder coverInkWell = find.ancestor(
      of: find.byKey(const ValueKey<String>('cover-image')),
      matching: find.byType(InkWell),
    );
    expect(coverInkWell, findsNothing,
        reason: 'the cover must not be the tap-to-read target');
  });

  testWidgets('all non-destructive actions render as labelled buttons',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      buildApp(
        MediaItemDialogFrame(
          cover: const SizedBox(width: 260, height: 100),
          title: 'Test title',
          author: 'Test author',
          launchLabel: 'READ',
          onLaunch: () {},
          quickActions: quick(),
          listActions: list(),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('Test title'), findsOneWidget);
    expect(find.text('Test author'), findsOneWidget);
    expect(find.text('Illustrations'), findsOneWidget);
    expect(find.text('Audiobook'), findsOneWidget);
    expect(find.text('Book Profile'), findsOneWidget);
    expect(find.text('Edit CSS'), findsOneWidget);
  });

  testWidgets('destructive actions render as visible (muted) buttons',
      (WidgetTester tester) async {
    int deleted = 0;
    await tester.pumpWidget(
      buildApp(
        MediaItemDialogFrame(
          cover: const SizedBox(width: 260, height: 100),
          title: 'Test title',
          launchLabel: 'READ',
          onLaunch: () {},
          dangerActions: <DialogDangerAction>[
            DialogDangerAction(label: 'Delete', onPressed: () => deleted++),
            DialogDangerAction(label: 'Clear', onPressed: () {}, muted: true),
          ],
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    // Danger actions are plain visible buttons below the cover, not hidden
    // behind an overflow menu.
    expect(find.byType(PopupMenuButton<DialogDangerAction>), findsNothing);
    expect(find.text('Delete'), findsOneWidget);
    expect(find.text('Clear'), findsOneWidget);
    await tester.tap(find.text('Delete'));
    await tester.pump();
    expect(deleted, 1);
  });

  testWidgets('renders the title with no cover and no exceptions',
      (WidgetTester tester) async {
    int launched = 0;
    await tester.pumpWidget(
      buildApp(
        MediaItemDialogFrame(
          title: 'No cover',
          launchLabel: 'READ',
          onLaunch: () => launched++,
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('No cover'), findsOneWidget);
    // The launch button is still the read affordance even without a cover.
    await tester.tap(find.widgetWithText(FilledButton, 'READ'));
    await tester.pump();
    expect(launched, 1);
  });
}
