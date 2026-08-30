import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/misc/platform_utils.dart';

void main() {
  Widget buildList(ScrollController controller) {
    return MaterialApp(
      home: ListView(
        controller: controller,
        children: const <Widget>[SizedBox(height: 3000)],
      ),
    );
  }

  Future<void> scroll(WidgetTester tester, double delta) async {
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: const Offset(20, 20),
        scrollDelta: Offset(0, delta),
      ),
    );
    await tester.pump();
  }

  testWidgets('scales a coarse Windows wheel gesture without animation', (
    WidgetTester tester,
  ) async {
    final DesktopWheelScrollController controller =
        DesktopWheelScrollController(scaleCoarseWheelDeltas: true);
    addTearDown(controller.dispose);
    await tester.pumpWidget(buildList(controller));

    await scroll(tester, 120);

    expect(controller.offset, 120 * 0.48);
  });

  testWidgets('keeps fine deltas 1:1 for the whole latched gesture', (
    WidgetTester tester,
  ) async {
    final DesktopWheelScrollController controller =
        DesktopWheelScrollController(scaleCoarseWheelDeltas: true);
    addTearDown(controller.dispose);
    await tester.pumpWidget(buildList(controller));

    await scroll(tester, 12);
    await scroll(tester, 120);

    expect(controller.offset, 132);
  });

  testWidgets('keeps coarse scale for small tail frames in one gesture', (
    WidgetTester tester,
  ) async {
    final DesktopWheelScrollController controller =
        DesktopWheelScrollController(scaleCoarseWheelDeltas: true);
    addTearDown(controller.dispose);
    await tester.pumpWidget(buildList(controller));

    await scroll(tester, 120);
    await scroll(tester, 12);

    expect(controller.offset, closeTo((120 + 12) * 0.48, 0.000001));
  });

  testWidgets('resets classification after 200ms idle', (
    WidgetTester tester,
  ) async {
    final DesktopWheelScrollController controller =
        DesktopWheelScrollController(scaleCoarseWheelDeltas: true);
    addTearDown(controller.dispose);
    await tester.pumpWidget(buildList(controller));

    await scroll(tester, 120);
    await tester.pump(const Duration(milliseconds: 201));
    await scroll(tester, 12);

    expect(controller.offset, 120 * 0.48 + 12);
  });

  testWidgets('inertia cancel resets classification before another device', (
    WidgetTester tester,
  ) async {
    final DesktopWheelScrollController controller =
        DesktopWheelScrollController(scaleCoarseWheelDeltas: true);
    addTearDown(controller.dispose);
    await tester.pumpWidget(buildList(controller));

    await scroll(tester, 12);
    controller.position.pointerScroll(0);
    await scroll(tester, 120);

    expect(controller.offset, 12 + 120 * 0.48);
  });

  testWidgets('disabled mode preserves native deltas and boundary clamping', (
    WidgetTester tester,
  ) async {
    final DesktopWheelScrollController controller =
        DesktopWheelScrollController(scaleCoarseWheelDeltas: false);
    addTearDown(controller.dispose);
    await tester.pumpWidget(buildList(controller));

    await scroll(tester, -120);
    expect(controller.offset, 0);

    await scroll(tester, 120);
    expect(controller.offset, 120);
  });
}
