import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/app_ui_scale.dart';
import 'package:hibiki/src/utils/misc/platform_utils.dart';

/// BUG-401 behavioural guard.
///
/// The home shell decides between the phone bottom-bar layout (compact) and the
/// desktop nav-rail layout (medium/expanded) from a [LayoutBuilder] that lives
/// **inside** [HibikiAppUiScale]. The scaler lays its subtree out against a
/// virtual canvas of `realViewport / scale`, so the [BoxConstraints] handed to
/// that builder are an INFLATED logical width. Reading it directly kept the
/// desktop locked to the nav-rail layout: at a real 560px-wide desktop window
/// the auto-scale (~0.92) inflated the logical width past 600 into the medium
/// band, so the bottom-bar layout was unreachable however narrow the real
/// window was dragged.
///
/// This reproduces the production decision widget (the real broken path) and
/// asserts it now classifies on the real physical width via
/// [windowSizeClassReal].
void main() {
  /// Mirror of the home shell's layout decision: a real [HibikiAppUiScale] with
  /// automatic desktop scale wrapping a [LayoutBuilder] that classifies via
  /// [windowSizeClassReal]. Renders a distinct marker per layout class so the
  /// test can assert which branch the real geometry takes.
  Widget buildHarness({required Size physicalSize}) {
    return Builder(
      builder: (BuildContext context) {
        final double scale = HibikiAppUiScale.automaticScaleForViewport(
          viewport: physicalSize,
          platform: TargetPlatform.windows,
        );
        return HibikiAppUiScale(
          scale: scale,
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              final WindowSizeClass sizeClass = windowSizeClassReal(
                constraints.maxWidth,
                HibikiAppUiScale.of(context),
              );
              return sizeClass == WindowSizeClass.compact
                  ? const Text(
                      'bottom-bar',
                      key: ValueKey<String>('layout-bottom-bar'),
                      textDirection: TextDirection.ltr,
                    )
                  : const Text(
                      'nav-rail',
                      key: ValueKey<String>('layout-nav-rail'),
                      textDirection: TextDirection.ltr,
                    );
            },
          ),
        );
      },
    );
  }

  Future<void> pumpAt(WidgetTester tester, Size physicalSize) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = physicalSize;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: MediaQuery(
          data: MediaQueryData(size: physicalSize),
          child: SizedBox(
            width: physicalSize.width,
            height: physicalSize.height,
            child: buildHarness(physicalSize: physicalSize),
          ),
        ),
      ),
    );
  }

  group('home shell layout class on real desktop viewport width (BUG-401)', () {
    testWidgets('real 480px-wide desktop window uses the bottom-bar layout', (
      WidgetTester tester,
    ) async {
      await pumpAt(tester, const Size(480, 900));
      expect(find.byKey(const ValueKey<String>('layout-bottom-bar')),
          findsOneWidget);
      expect(
          find.byKey(const ValueKey<String>('layout-nav-rail')), findsNothing);
    });

    testWidgets(
      'real 560px-wide desktop window uses the bottom-bar layout '
      '(old logical-width path mislabeled this medium)',
      (WidgetTester tester) async {
        // At 560 real width the desktop auto-scale (~0.92) inflates the logical
        // canvas past 600; the pre-fix code read that and stayed on the nav-rail
        // layout. The real width is the discriminator.
        await pumpAt(tester, const Size(560, 900));
        expect(find.byKey(const ValueKey<String>('layout-bottom-bar')),
            findsOneWidget);
        expect(find.byKey(const ValueKey<String>('layout-nav-rail')),
            findsNothing);
      },
    );

    testWidgets('real 1280px-wide desktop window uses the nav-rail layout', (
      WidgetTester tester,
    ) async {
      await pumpAt(tester, const Size(1280, 800));
      expect(find.byKey(const ValueKey<String>('layout-nav-rail')),
          findsOneWidget);
      expect(find.byKey(const ValueKey<String>('layout-bottom-bar')),
          findsNothing);
    });
  });
}
