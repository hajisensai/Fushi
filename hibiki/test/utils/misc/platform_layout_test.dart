import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/misc/platform_utils.dart';

void main() {
  group('windowSizeClassOf', () {
    test('uses compact/medium/expanded Material breakpoints', () {
      expect(
        windowSizeClassOf(const BoxConstraints(maxWidth: 599)),
        WindowSizeClass.compact,
      );
      expect(
        windowSizeClassOf(const BoxConstraints(maxWidth: 600)),
        WindowSizeClass.medium,
      );
      expect(
        windowSizeClassOf(const BoxConstraints(maxWidth: 839)),
        WindowSizeClass.medium,
      );
      expect(
        windowSizeClassOf(const BoxConstraints(maxWidth: 840)),
        WindowSizeClass.expanded,
      );
    });
  });

  group('desktop layout metrics', () {
    const ValueKey<String> childKey = ValueKey<String>('content-child');
    const ValueKey<String> primaryKey = ValueKey<String>('primary-pane');
    const ValueKey<String> supportingKey = ValueKey<String>('supporting-pane');

    test('keeps mobile layouts unconstrained', () {
      expect(
        desktopContentMaxWidth(
          WindowSizeClass.compact,
          DesktopContentKind.readerShelf,
        ),
        isNull,
      );
    });

    test('uses wider settings content on Windows-sized expanded layouts', () {
      expect(
        desktopContentMaxWidth(
          WindowSizeClass.expanded,
          DesktopContentKind.settings,
        ),
        // MD3 list-detail: widened 760 -> 960 so the detail pane breathes after
        // the 280px nav pane (Phase 1 ④).
        960,
      );
    });

    test('keeps dictionary readable without wasting full desktop width', () {
      expect(
        desktopContentMaxWidth(
          WindowSizeClass.expanded,
          DesktopContentKind.dictionary,
        ),
        1040,
      );
    });

    test('sizes reader shelf cards from available content width', () {
      expect(readerShelfGridExtentForWidth(520), 150);
      expect(readerShelfGridExtentForWidth(760), 180);
      expect(readerShelfGridExtentForWidth(1100), 190);
      expect(readerShelfGridExtentForWidth(1450), 210);
    });

    test('sizes reader shelf cards from constrained content width', () {
      expect(
        readerShelfGridExtentForLayout(
          mediaWidth: 1600,
          contentWidth: 760,
        ),
        180,
      );
      expect(
        readerShelfGridExtentForLayout(
          mediaWidth: 1600,
          contentWidth: 1100,
        ),
        190,
      );
    });

    test('adds desktop breathing room without changing compact padding', () {
      expect(
        desktopContentPadding(WindowSizeClass.compact),
        EdgeInsets.zero,
      );
      expect(
        desktopContentPadding(WindowSizeClass.medium),
        const EdgeInsets.symmetric(horizontal: 16),
      );
      expect(
        desktopContentPadding(WindowSizeClass.expanded),
        const EdgeInsets.symmetric(horizontal: 24),
      );
    });

    test('keeps compact dialog fields usable', () {
      expect(desktopDialogContentWidth(320), 256);
      expect(desktopDialogContentWidth(1200), 420);
    });

    testWidgets('keeps compact AlertDialog content inside screen insets', (
      WidgetTester tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 240);
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          home: AlertDialog(
            content: SizedBox(
              key: childKey,
              width: desktopDialogContentWidth(320),
              height: 40,
            ),
          ),
        ),
      );

      expect(tester.takeException(), isNull);

      final Rect contentRect = tester.getRect(find.byKey(childKey));
      expect(contentRect.left, greaterThanOrEqualTo(0));
      expect(contentRect.right, lessThanOrEqualTo(320));
    });

    testWidgets('constrains expanded desktop content to max width', (
      WidgetTester tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1600, 200);
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            width: double.infinity,
            height: double.infinity,
            child: DesktopContentLayout(
              kind: DesktopContentKind.dictionary,
              child: SizedBox.expand(key: childKey),
            ),
          ),
        ),
      );

      expect(tester.getSize(find.byKey(childKey)).width, 992);
    });

    testWidgets('keeps compact content full width without desktop padding', (
      WidgetTester tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(500, 200);
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            width: double.infinity,
            height: double.infinity,
            child: DesktopContentLayout(
              kind: DesktopContentKind.dictionary,
              child: SizedBox.expand(key: childKey),
            ),
          ),
        ),
      );

      expect(tester.getSize(find.byKey(childKey)).width, 500);
    });

    testWidgets('collapses supporting pane layouts below expanded width', (
      WidgetTester tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(500, 300);
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox.expand(
            child: MaterialSupportingPaneLayout(
              primary: SizedBox.expand(key: primaryKey),
              supporting: SizedBox.expand(key: supportingKey),
            ),
          ),
        ),
      );

      expect(find.byKey(primaryKey), findsOneWidget);
      expect(find.byKey(supportingKey), findsNothing);
      expect(tester.getSize(find.byKey(primaryKey)).width, 500);
    });

    testWidgets('uses 70/30 split for expanded supporting pane layouts', (
      WidgetTester tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1000, 300);
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox.expand(
            child: MaterialSupportingPaneLayout(
              primary: SizedBox.expand(key: primaryKey),
              supporting: SizedBox.expand(key: supportingKey),
            ),
          ),
        ),
      );

      expect(tester.getSize(find.byKey(primaryKey)).width, 699);
      expect(tester.getSize(find.byKey(supportingKey)).width, 300);
    });

    testWidgets('caps supporting pane width on very wide layouts', (
      WidgetTester tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 300);
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox.expand(
            child: MaterialSupportingPaneLayout(
              primary: SizedBox.expand(key: primaryKey),
              supporting: SizedBox.expand(key: supportingKey),
            ),
          ),
        ),
      );

      expect(tester.getSize(find.byKey(supportingKey)).width, 360);
      expect(tester.getSize(find.byKey(primaryKey)).width, 919);
    });

    testWidgets('uses an explicit supporting pane width when provided', (
      WidgetTester tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(900, 300);
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox.expand(
            child: MaterialSupportingPaneLayout(
              minSplitWidth: 640,
              supportingWidth: 248,
              primary: SizedBox.expand(key: primaryKey),
              supporting: SizedBox.expand(key: supportingKey),
            ),
          ),
        ),
      );

      expect(tester.getSize(find.byKey(supportingKey)).width, 248);
      expect(tester.getSize(find.byKey(primaryKey)).width, 651);
    });

    testWidgets(
      'top-aligns short primary pane content instead of centering it',
      (WidgetTester tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(1000, 600);
        addTearDown(tester.view.reset);

        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: SizedBox.expand(
              child: MaterialSupportingPaneLayout(
                supportingSide: SupportingPaneSide.start,
                minSplitWidth: 720,
                // Mirrors the production detail pane: an own-scrolling
                // SingleChildScrollView whose content is shorter than the pane
                // (e.g. the audiobook settings destination with only a couple of
                // visible toggles on desktop).
                primary: SingleChildScrollView(
                  child: SizedBox(height: 80, key: childKey),
                ),
                supporting: const SizedBox.expand(),
              ),
            ),
          ),
        );

        // Short content must hug the top of the pane (y == 0), not float to the
        // vertical center the default Row CrossAxisAlignment.center produced.
        expect(tester.getTopLeft(find.byKey(childKey)).dy, 0);
      },
    );
  });
}
