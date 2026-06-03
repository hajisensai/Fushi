import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/focus/hibiki_focus_controller.dart';
import 'package:hibiki/src/focus/hibiki_focus_target.dart';
import 'package:hibiki/src/utils/adaptive/adaptive_navigation.dart';

import 'widget_test_helpers.dart';

// The Material bottom bar / side rail render each destination as its OWN
// gamepad/keyboard focus target, so the app focus ring hugs the single selected
// item instead of wrapping the whole bar. Directional focus steps between
// adjacent tiles through the normal HibikiFocus geometry; A/Enter selects.
void main() {
  const List<AdaptiveNavItem> items = <AdaptiveNavItem>[
    AdaptiveNavItem(icon: Icons.menu_book_outlined, label: 'Books'),
    AdaptiveNavItem(icon: Icons.search, label: 'Dict'),
    AdaptiveNavItem(icon: Icons.tune, label: 'Settings'),
  ];

  Widget contentThenBar({
    required int index,
    required ValueChanged<int> onTap,
    bool rail = false,
  }) {
    final Widget nav = Builder(
      builder: (BuildContext context) => rail
          ? adaptiveNavRail(
              context: context,
              currentIndex: index,
              onTap: onTap,
              items: items,
            )
          : adaptiveBottomBar(
              context: context,
              currentIndex: index,
              onTap: onTap,
              items: items,
            ),
    );
    return HibikiFocusRoot(
      child: SizedBox(
        width: 320,
        height: 600,
        child: Column(
          children: <Widget>[
            const HibikiFocusTarget(
              id: HibikiFocusId('content'),
              child: SizedBox(width: 320, height: 120),
            ),
            // The rail fills the remaining height (as it does inside the app's
            // Scaffold Row); the bottom bar keeps its intrinsic height.
            if (rail) Expanded(child: nav) else nav,
          ],
        ),
      ),
    );
  }

  testWidgets('bottom bar registers one focus target per destination',
      (WidgetTester tester) async {
    int index = 0;
    await tester.pumpWidget(buildTestApp(
      StatefulBuilder(
        builder: (BuildContext c, StateSetter setState) => contentThenBar(
          index: index,
          onTap: (int i) => setState(() => index = i),
        ),
      ),
    ));
    await tester.pump();
    final HibikiFocusController controller = HibikiFocusRoot.controllerOf(
      tester.element(find.byType(Column).first),
    );

    controller.requestById(const HibikiFocusId('content'));
    await tester.pump();

    // Down from the content lands on a single destination tile (not the bar).
    expect(controller.move(HibikiFocusDirection.down), isTrue);
    await tester.pump();
    final HibikiFocusId? onTile = controller.activeId;
    expect(onTile, isNotNull);
    expect(onTile!.value, startsWith('nav-bar-'));
    expect(index, 0, reason: 'moving focus onto a tile must NOT switch tabs');
  });

  testWidgets('along-axis moves the ring between tiles without switching tabs',
      (WidgetTester tester) async {
    int index = 1;
    await tester.pumpWidget(buildTestApp(
      StatefulBuilder(
        builder: (BuildContext c, StateSetter setState) => contentThenBar(
          index: index,
          onTap: (int i) => setState(() => index = i),
        ),
      ),
    ));
    await tester.pump();
    final HibikiFocusController controller = HibikiFocusRoot.controllerOf(
      tester.element(find.byType(Column).first),
    );

    // Focus the middle tile directly, then step right to the next one.
    controller.requestById(const HibikiFocusId('nav-bar-1'));
    await tester.pump();
    expect(controller.move(HibikiFocusDirection.right), isTrue);
    await tester.pump();
    expect(controller.activeId, const HibikiFocusId('nav-bar-2'));
    expect(index, 1, reason: 'stepping focus does not select; A/Enter does');
  });

  testWidgets('ActivateIntent on a focused tile selects that destination',
      (WidgetTester tester) async {
    int index = 0;
    await tester.pumpWidget(buildTestApp(
      StatefulBuilder(
        builder: (BuildContext c, StateSetter setState) => contentThenBar(
          index: index,
          onTap: (int i) => setState(() => index = i),
        ),
      ),
    ));
    await tester.pump();
    final HibikiFocusController controller = HibikiFocusRoot.controllerOf(
      tester.element(find.byType(Column).first),
    );

    controller.requestById(const HibikiFocusId('nav-bar-2'));
    await tester.pump();
    // The gamepad/keyboard path dispatches ActivateIntent at the focused
    // context; the tile maps it to onSelect (the action returns null, so assert
    // the observable effect, not the invoke result).
    Actions.maybeInvoke<ActivateIntent>(
      controller.activeContext!,
      const ActivateIntent(),
    );
    await tester.pump();
    expect(index, 2);
    expect(controller.activeId, const HibikiFocusId('nav-bar-2'),
        reason: 'focus stays on the tile after selecting');
  });

  testWidgets('Enter key on a focused tile selects it (keyboard activation)',
      (WidgetTester tester) async {
    int index = 0;
    await tester.pumpWidget(buildTestApp(
      StatefulBuilder(
        builder: (BuildContext c, StateSetter setState) => contentThenBar(
          index: index,
          onTap: (int i) => setState(() => index = i),
        ),
      ),
    ));
    await tester.pump();
    final HibikiFocusController controller = HibikiFocusRoot.controllerOf(
      tester.element(find.byType(Column).first),
    );

    controller.requestById(const HibikiFocusId('nav-bar-2'));
    await tester.pump();
    // Keyboard activation: a focused tile must select on Enter, not just on a
    // direct Actions.invoke or a gamepad A. This guards desktop keyboard a11y
    // (gameButtonA can't be synthesized on Windows; Enter must work).
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(index, 2,
        reason: 'Enter on a focused nav tile must select that destination');
  });

  testWidgets('a tap selects the destination', (WidgetTester tester) async {
    int index = 0;
    await tester.pumpWidget(buildTestApp(
      StatefulBuilder(
        builder: (BuildContext c, StateSetter setState) => contentThenBar(
          index: index,
          onTap: (int i) => setState(() => index = i),
        ),
      ),
    ));
    await tester.pump();
    await tester.tap(find.text('Settings'));
    await tester.pump();
    expect(index, 2);
  });

  testWidgets('rail registers one focus target per destination',
      (WidgetTester tester) async {
    int index = 0;
    await tester.pumpWidget(buildTestApp(
      StatefulBuilder(
        builder: (BuildContext c, StateSetter setState) => contentThenBar(
          index: index,
          rail: true,
          onTap: (int i) => setState(() => index = i),
        ),
      ),
    ));
    await tester.pump();
    final HibikiFocusController controller = HibikiFocusRoot.controllerOf(
      tester.element(find.byType(Column).first),
    );

    controller.requestById(const HibikiFocusId('nav-rail-0'));
    await tester.pump();
    // Down steps to the next rail tile (vertical axis); no tab switch.
    expect(controller.move(HibikiFocusDirection.down), isTrue);
    await tester.pump();
    expect(controller.activeId, const HibikiFocusId('nav-rail-1'));
    expect(index, 0);
  });
}
