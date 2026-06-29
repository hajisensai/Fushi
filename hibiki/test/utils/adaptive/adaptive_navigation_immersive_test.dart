import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/adaptive/adaptive_navigation.dart';

/// TODO-973 guard: the global navigation chrome (bottom bar / side rail) hides
/// while gamepad auto-immersive is active and renders normally otherwise.
void main() {
  const List<AdaptiveNavItem> items = <AdaptiveNavItem>[
    AdaptiveNavItem(icon: Icons.menu_book_outlined, label: '书架'),
    AdaptiveNavItem(icon: Icons.movie_outlined, label: '视频'),
    AdaptiveNavItem(icon: Icons.search_outlined, label: '查词'),
  ];

  group('navigationVisibleUnderGamepadImmersive (pure truth table)', () {
    test('immersive active -> navigation hidden', () {
      expect(navigationVisibleUnderGamepadImmersive(true), isFalse);
    });

    test('immersive inactive -> navigation visible', () {
      expect(navigationVisibleUnderGamepadImmersive(false), isTrue);
    });
  });

  Widget bottomBarHarness({required bool immersive}) => MaterialApp(
        home: Scaffold(
          bottomNavigationBar: Builder(
            builder: (BuildContext context) => adaptiveBottomBar(
              context: context,
              currentIndex: 0,
              onTap: (_) {},
              items: items,
              gamepadImmersiveActive: immersive,
            ),
          ),
        ),
      );

  Widget railHarness({required bool immersive}) => MaterialApp(
        home: Scaffold(
          body: Row(
            children: <Widget>[
              Builder(
                builder: (BuildContext context) => adaptiveNavRail(
                  context: context,
                  currentIndex: 0,
                  onTap: (_) {},
                  items: items,
                  gamepadImmersiveActive: immersive,
                ),
              ),
              const Expanded(child: SizedBox.shrink()),
            ],
          ),
        ),
      );

  testWidgets('bottom bar: visible when not immersive', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(bottomBarHarness(immersive: false));
    await tester.pump();
    expect(find.byKey(hibikiMaterialNavKey), findsOneWidget);
  });

  testWidgets('bottom bar: hidden when gamepad immersive active', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(bottomBarHarness(immersive: true));
    await tester.pump();
    expect(find.byKey(hibikiMaterialNavKey), findsNothing,
        reason: 'gamepad immersive must collapse the bottom bar');
  });

  testWidgets('side rail: visible when not immersive', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(railHarness(immersive: false));
    await tester.pump();
    expect(find.byKey(hibikiMaterialNavKey), findsOneWidget);
  });

  testWidgets('side rail: hidden when gamepad immersive active', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(railHarness(immersive: true));
    await tester.pump();
    expect(find.byKey(hibikiMaterialNavKey), findsNothing,
        reason: 'gamepad immersive must collapse the side rail');
  });
}
