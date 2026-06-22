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

  group('windowSizeClassReal (BUG-401)', () {
    // Breakpoints must classify on the REAL physical viewport width, not the
    // virtually-inflated logical width handed down inside HibikiAppUiScale.
    // realW = logicalWidth * appUiScale.
    test('scale=1 is identity across all bands (regression guard)', () {
      expect(windowSizeClassReal(599, 1.0), WindowSizeClass.compact);
      expect(windowSizeClassReal(600, 1.0), WindowSizeClass.medium);
      expect(windowSizeClassReal(839, 1.0), WindowSizeClass.medium);
      expect(windowSizeClassReal(840, 1.0), WindowSizeClass.expanded);
    });

    test(
        'a logical 960 canvas at scale 0.88 is no longer expanded once it '
        'shrinks (real width drives the class)', () {
      // The desktop auto-scale floor is 0.88. With the window minimum width
      // relaxed, dragging the real window narrow lowers the LOGICAL canvas
      // width (canvas = realViewport / scale). A 600-logical canvas at 0.88
      // is really ~528px -> compact. The old code read the logical 600 and
      // mislabeled it medium, keeping the phone layout unreachable.
      expect(windowSizeClassReal(600, 0.88), WindowSizeClass.compact);
      // 960 logical at 0.88 = 844.8 real -> expanded (a genuinely wide one).
      expect(windowSizeClassReal(960, 0.88), WindowSizeClass.expanded);
    });

    test('logical 480 at scale 1.0 is compact', () {
      expect(windowSizeClassReal(480, 1.0), WindowSizeClass.compact);
    });

    test('desktop >=1280 real width stays expanded at scale ~1.0', () {
      expect(windowSizeClassReal(1280, 1.0), WindowSizeClass.expanded);
    });

    test('tablet ~800 real width stays medium at scale 1.05', () {
      // logical 762 * 1.05 = 800.1 -> medium (>=600, <840)
      expect(windowSizeClassReal(762, 1.05), WindowSizeClass.medium);
      expect(windowSizeClassReal(800, 1.0), WindowSizeClass.medium);
    });

    test('windowSizeClassForWidth holds the single threshold definition', () {
      expect(windowSizeClassForWidth(599), WindowSizeClass.compact);
      expect(windowSizeClassForWidth(600), WindowSizeClass.medium);
      expect(windowSizeClassForWidth(839), WindowSizeClass.medium);
      expect(windowSizeClassForWidth(840), WindowSizeClass.expanded);
    });

    test('non-finite / non-positive scale degrades to identity', () {
      expect(windowSizeClassReal(700, double.nan), WindowSizeClass.medium);
      expect(windowSizeClassReal(700, 0), WindowSizeClass.medium);
      expect(windowSizeClassReal(700, -1), WindowSizeClass.medium);
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
