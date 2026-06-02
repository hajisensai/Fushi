import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/focus/focus_geometry.dart';
import 'package:hibiki/src/focus/hibiki_focus_controller.dart';
import 'package:hibiki/src/focus/hibiki_focus_target.dart';
import 'package:hibiki/src/utils/app_ui_scale.dart';

void main() {
  // The shared primitive every focus geometry consumer depends on. The bug it
  // fixes: `box.localToGlobal(Offset.zero) & box.size` pairs a SCALED top-left
  // with an UNSCALED size, so under HibikiAppUiScale's Transform the returned
  // rect had the right position but the wrong (un-zoomed) size.
  group('globalRectOfBox', () {
    const Key target = ValueKey<String>('geometry-target');

    Future<RenderBox> pumpScaled(WidgetTester tester, double scale) async {
      await tester.pumpWidget(MaterialApp(
        home: HibikiAppUiScale(
          scale: scale,
          child: const Scaffold(
            body: Center(
              child: SizedBox(key: target, width: 40, height: 20),
            ),
          ),
        ),
      ));
      await tester.pump();
      return tester.renderObject<RenderBox>(find.byKey(target));
    }

    testWidgets('carries the on-screen (scaled) size at scale 1.0',
        (WidgetTester tester) async {
      final RenderBox box = await pumpScaled(tester, 1.0);
      final Rect rect = globalRectOfBox(box);
      expect(rect.width, closeTo(40, 0.01));
      expect(rect.height, closeTo(20, 0.01));
      // Equals the naive `topLeft & size` exactly when there is no transform.
      expect(rect, box.localToGlobal(Offset.zero) & box.size);
    });

    testWidgets('doubles the rect under a 2.0x UI scale',
        (WidgetTester tester) async {
      final RenderBox box = await pumpScaled(tester, 2.0);
      final Rect rect = globalRectOfBox(box);
      // Local size stays 40x20 (the Transform does not relayout the child) but
      // the on-screen rect must be 80x40.
      expect(box.size, const Size(40, 20));
      expect(rect.width, closeTo(80, 0.5),
          reason: 'on-screen width must scale with the UI scale');
      expect(rect.height, closeTo(40, 0.5),
          reason: 'on-screen height must scale with the UI scale');
    });

    testWidgets('halves the rect under a 0.5x UI scale',
        (WidgetTester tester) async {
      final RenderBox box = await pumpScaled(tester, 0.5);
      final Rect rect = globalRectOfBox(box);
      expect(rect.width, closeTo(20, 0.5));
      expect(rect.height, closeTo(10, 0.5));
    });
  });

  group('globalRectOfContext', () {
    testWidgets('returns null for an unmounted context',
        (WidgetTester tester) async {
      late BuildContext captured;
      await tester.pumpWidget(MaterialApp(
        home: Builder(builder: (BuildContext c) {
          captured = c;
          return const SizedBox.shrink();
        }),
      ));
      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
      expect(globalRectOfContext(captured), isNull);
    });
  });

  // Directional navigation reads every candidate rect through the same helper,
  // so a non-1.0 scale must not break which control "down"/"up" lands on.
  testWidgets('directional nav still lands correctly under a 2.0x UI scale',
      (WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home: HibikiAppUiScale(
        scale: 2.0,
        child: HibikiFocusRoot(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              for (final ({String id, Alignment align}) row
                  in <({String id, Alignment align})>[
                (id: 'top-right', align: Alignment.centerRight),
                (id: 'mid-left', align: Alignment.centerLeft),
                (id: 'bottom-right', align: Alignment.centerRight),
              ])
                Align(
                  alignment: row.align,
                  child: HibikiFocusTarget(
                    id: HibikiFocusId(row.id),
                    child: TextButton(
                      onPressed: () {},
                      child: Text(row.id),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    ));
    await tester.pump();

    final BuildContext context = tester.element(find.byType(Column));
    final HibikiFocusController controller =
        HibikiFocusRoot.controllerOf(context);

    expect(controller.requestById(const HibikiFocusId('top-right')), isTrue);
    await tester.pump();

    expect(controller.move(HibikiFocusDirection.down), isTrue);
    await tester.pump();
    expect(controller.activeId, const HibikiFocusId('mid-left'),
        reason: 'down must reach the immediately-next row even under 2.0x');

    expect(controller.move(HibikiFocusDirection.down), isTrue);
    await tester.pump();
    expect(controller.activeId, const HibikiFocusId('bottom-right'));

    expect(controller.move(HibikiFocusDirection.up), isTrue);
    await tester.pump();
    expect(controller.activeId, const HibikiFocusId('mid-left'),
        reason: 'up is symmetric under scale too');
  });
}
