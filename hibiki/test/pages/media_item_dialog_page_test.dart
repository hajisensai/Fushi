import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/media_item_dialog_page.dart';

/// TODO-293 redesign: the long-press "book settings" dialog dropped the big
/// "continue reading" FilledButton (it fought the tap-outside-to-dismiss
/// barrier). Now the cover is the hero — tapping it opens the book — and the
/// actions are translucent buttons layered over the cover. Destructive actions
/// live behind a translucent overflow menu so they cannot be mis-tapped.
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

  testWidgets(
      'cover is the tap-to-read affordance — no big launch button is rendered',
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
    // The redesigned dialog must NOT show a big "READ" FilledButton anymore.
    expect(find.text('READ'), findsNothing);
    expect(find.byType(FilledButton), findsNothing);

    // Tapping the cover opens the book (= read). The cover hero is wrapped in
    // an InkWell carrying a [Semantics] button labelled with [launchLabel].
    final Finder coverTap = find.descendant(
      of: find.bySemanticsLabel('READ'),
      matching: find.byType(InkWell),
    );
    expect(coverTap, findsWidgets);
    await tester.tap(coverTap.first);
    await tester.pump();
    expect(launched, 1, reason: 'tapping the cover should invoke onLaunch');
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

  testWidgets(
      'destructive actions are hidden behind a translucent overflow menu',
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
    // Danger actions must NOT be flat buttons sitting in the dialog — they live
    // behind the overflow menu and are not visible until it is opened.
    expect(find.text('Delete'), findsNothing);
    expect(find.text('Clear'), findsNothing);
    expect(find.byType(PopupMenuButton<DialogDangerAction>), findsOneWidget);

    // Opening the overflow reveals them and selecting fires the callback.
    await tester.tap(find.byType(PopupMenuButton<DialogDangerAction>));
    await tester.pumpAndSettle();
    expect(find.text('Delete'), findsOneWidget);
    expect(find.text('Clear'), findsOneWidget);
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(deleted, 1);
  });

  testWidgets('with no danger actions, no overflow menu is shown',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      buildApp(
        MediaItemDialogFrame(
          cover: const SizedBox(width: 260, height: 100),
          title: 'No danger',
          launchLabel: 'READ',
          onLaunch: () {},
          quickActions: quick(),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.byType(PopupMenuButton<DialogDangerAction>), findsNothing);
  });

  testWidgets('renders a tappable placeholder hero when cover is null',
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
    // Even without a cover image the hero stays tappable (= read).
    final Finder coverTap = find.descendant(
      of: find.bySemanticsLabel('READ'),
      matching: find.byType(InkWell),
    );
    expect(coverTap, findsWidgets);
    await tester.tap(coverTap.first);
    await tester.pump();
    expect(launched, 1);
  });
}
