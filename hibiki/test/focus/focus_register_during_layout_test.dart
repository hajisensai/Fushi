import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/focus/hibiki_focus_controller.dart';
import 'package:hibiki/src/focus/hibiki_focus_target.dart';

void main() {
  // Regression: a HibikiFocusTarget first mounts (and register()s) as a
  // lazily-built SliverList child inside a layout callback
  // (RenderSliverMultiBoxAdaptor.createChild → didChangeDependencies). When an
  // off-screen sibling that still holds primary focus is being recycled in the
  // SAME layout pass, it is deactivated (still mounted, but inactive) and not
  // yet unregistered. register()'s synchronous _handleFocusChange() then walked
  // that inactive entry and called ModalRoute.of() on its deactivated context —
  // an ancestor lookup the framework forbids ("Looking up a deactivated
  // widget's ancestor is unsafe" / markNeedsBuild during build). Focus
  // recomputation must be deferred to the post-frame repair, never run
  // synchronously inside register().
  testWidgets(
      'recycling a focused list row while new rows register does not throw '
      'during layout', (WidgetTester tester) async {
    final ScrollController controller = ScrollController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: HibikiFocusRoot(
          child: ListView.builder(
            controller: controller,
            itemExtent: 80,
            itemCount: 600,
            itemBuilder: (BuildContext context, int index) {
              return HibikiFocusTarget(
                id: HibikiFocusId('row-$index'),
                child: TextButton(
                  onPressed: () {},
                  child: Text('Row $index'),
                ),
              );
            },
          ),
        ),
      ),
    ));

    final HibikiFocusController focus = HibikiFocusRoot.controllerOf(
      tester.element(find.byType(ListView)),
    );
    // Focus a row that is currently on-screen so its node becomes primary.
    focus.requestById(const HibikiFocusId('row-0'));
    await tester.pump();
    expect(tester.takeException(), isNull);

    // Jump far past row-0 so it is recycled (deactivated) in the very layout
    // pass that lazily builds and registers the new on-screen rows.
    controller.jumpTo(12000);
    await tester.pump();
    expect(tester.takeException(), isNull);

    // Jump back up, recycling the now-focused rows the other direction.
    controller.jumpTo(0);
    await tester.pump();
    expect(tester.takeException(), isNull);

    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
