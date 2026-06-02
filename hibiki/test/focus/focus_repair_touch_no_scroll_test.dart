import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/focus/hibiki_focus_controller.dart';
import 'package:hibiki/src/focus/hibiki_focus_target.dart';

// User report: on a pure-touch phone, fast-scrolling a long settings list rolls
// back to a centred control. Mechanism: as rows recycle, the active focus
// target unregisters → scheduleRepair → ensureFocus() re-homes focus onto a
// visible control and reveals (centres) it via HibikiFocusScroll.ensureVisible
// (alignment 0.5), fighting the scroll. This PASSIVE repair reveal must be
// suppressed in touch highlight mode (no focus cursor → nothing to follow),
// while explicit gamepad/keyboard navigation (requestById/move) must still
// reveal — that input IS the traditional-mode cursor.

Widget _list(ScrollController controller) {
  return MaterialApp(
    theme: ThemeData(useMaterial3: true, platform: TargetPlatform.android),
    home: Scaffold(
      body: SizedBox(
        height: 240,
        child: HibikiFocusRoot(
          child: ListView.builder(
            controller: controller,
            itemExtent: 56,
            itemCount: 60,
            itemBuilder: (BuildContext context, int index) {
              return HibikiFocusTarget(
                id: HibikiFocusId('row-$index'),
                child: TextButton(onPressed: () {}, child: Text('Row $index')),
              );
            },
          ),
        ),
      ),
    ),
  );
}

void main() {
  tearDown(() {
    FocusManager.instance.highlightStrategy = FocusHighlightStrategy.automatic;
  });

  testWidgets('touch: passive focus repair does not roll the list back',
      (WidgetTester tester) async {
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTouch;

    final ScrollController controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(_list(controller));
    await tester.pumpAndSettle();

    final HibikiFocusController focus =
        HibikiFocusRoot.controllerOf(tester.element(find.byType(ListView)));

    // User scrolled deep into the list; the originally-focused top row has
    // recycled away, so focus has fallen off its target.
    controller.jumpTo(1000);
    await tester.pump();
    expect(controller.offset, 1000);

    // Passive repair re-homes focus onto a now-visible control. In touch mode
    // this must NOT scroll the viewport to centre that control.
    focus.ensureFocus();
    await tester.pumpAndSettle();

    expect(
      controller.offset,
      1000,
      reason: 'touch-mode passive repair recentred the list (rolled from 1000 '
          'to ${controller.offset})',
    );
  });

  testWidgets('traditional: directional move still reveals the target',
      (WidgetTester tester) async {
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTraditional;

    final ScrollController controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(_list(controller));
    await tester.pumpAndSettle();

    final HibikiFocusController focus =
        HibikiFocusRoot.controllerOf(tester.element(find.byType(ListView)));
    focus.requestById(const HibikiFocusId('row-0'));
    await tester.pump();
    for (int i = 0; i < 8; i++) {
      focus.move(HibikiFocusDirection.down);
      await tester.pump();
    }
    await tester.pumpAndSettle();

    expect(controller.offset, greaterThan(0),
        reason: 'directional move must scroll the focused target into view');
  });
}
