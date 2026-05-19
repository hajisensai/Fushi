import 'package:flutter/widgets.dart';
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
        760,
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
  });
}
