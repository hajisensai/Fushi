import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/focus/hibiki_focus_controller.dart';
import 'package:hibiki/src/focus/hibiki_focus_scroll.dart';
import 'package:hibiki/src/focus/page_scroll_registry.dart';
import 'package:hibiki/src/utils/components/hibiki_material_components.dart';

import 'widget_test_helpers.dart';

void main() {
  testWidgets(
      'HibikiPageScaffold page-scrolls its body from a header-area context '
      '(where the gamepad focus actually sits) via PrimaryScrollController',
      (WidgetTester tester) async {
    // The gamepad dispatch context is the focused control — on a page WITH a
    // focusable header button that is a header/AppBar icon button, which sits
    // OUTSIDE the body scroll view but INSIDE the scaffold PrimaryScrollController.
    late BuildContext headerCtx;
    await tester.pumpWidget(buildTestApp(
      HibikiPageScaffold(
        title: 'Stats',
        actions: <Widget>[
          Builder(builder: (BuildContext c) {
            headerCtx = c;
            return const SizedBox.shrink();
          }),
        ],
        body: CustomScrollView(
          slivers: <Widget>[
            SliverList(
              delegate: SliverChildBuilderDelegate(
                (BuildContext _, int i) =>
                    SizedBox(height: 100, child: Text('row $i')),
                childCount: 60,
              ),
            ),
          ],
        ),
      ),
    ));
    await tester.pump();
    expect(find.text('row 0'), findsOneWidget);

    final bool scrolled = HibikiFocusScroll.scrollPrimary(headerCtx, 0.9);
    expect(scrolled, isTrue,
        reason: 'header-area context reaches the scaffold '
            'PrimaryScrollController the body attached to');
    await tester.pumpAndSettle();
    expect(find.text('row 0'), findsNothing,
        reason: 'page-scroll moved the page ~0.9 viewport down');
  });

  testWidgets(
      'gamepad page-scroll reaches a PURE-DISPLAY page body via PageScrollRegistry '
      'even when focus is the top-level fallback node (regression: C1)',
      (WidgetTester tester) async {
    PageScrollRegistry.debugClear();
    await tester.pumpWidget(buildTestApp(
      HibikiFocusRoot(
        child: HibikiPageScaffold(
          title: 'Stats',
          // Nothing focusable anywhere -> focus rests on the fallback node,
          // which is the real dispatch context on a pure-display page.
          body: CustomScrollView(
            slivers: <Widget>[
              SliverList(
                delegate: SliverChildBuilderDelegate(
                  (BuildContext _, int i) =>
                      SizedBox(height: 100, child: Text('row $i')),
                  childCount: 60,
                ),
              ),
            ],
          ),
        ),
      ),
    ));
    await tester.pump();
    expect(find.text('row 0'), findsOneWidget);

    final HibikiFocusController controller = HibikiFocusRoot.controllerOf(
      tester.element(find.text('row 0')),
    );
    controller.ensureFocus();
    await tester.pump();
    expect(controller.fallbackNode.hasPrimaryFocus, isTrue,
        reason: 'pure-display page: focus is the top-level fallback node');

    // C1: a context lookup from the fallback node (an ANCESTOR of the scaffold
    // PrimaryScrollController) can NEVER find the page controller — this is the
    // exact bug.
    expect(
      HibikiFocusScroll.scrollPrimary(controller.fallbackNode.context!, 0.9),
      isFalse,
      reason: 'context lookup from the fallback node cannot reach the page '
          'controller (the root cause of C1)',
    );

    // Fix: the scaffold registered its body controller, reachable regardless of
    // where focus sits.
    final ScrollController? page = PageScrollRegistry.current;
    expect(page, isNotNull,
        reason: 'HibikiPageScaffold registered its body scroll controller');
    expect(HibikiFocusScroll.scrollController(page!, 0.9), isTrue);
    await tester.pumpAndSettle();
    expect(find.text('row 0'), findsNothing,
        reason: 'LB/RB now page-scrolls the pure-display page');
  });

  testWidgets('PageScrollRegistry pops when the scaffold is disposed',
      (WidgetTester tester) async {
    PageScrollRegistry.debugClear();
    await tester.pumpWidget(buildTestApp(
      HibikiPageScaffold(
        title: 'Stats',
        body: ListView(
          children: <Widget>[
            for (int i = 0; i < 30; i++)
              SizedBox(height: 80, child: Text('$i')),
          ],
        ),
      ),
    ));
    await tester.pump();
    expect(PageScrollRegistry.debugDepth, 1);

    // Replace with an empty page -> scaffold disposed -> controller popped.
    await tester.pumpWidget(buildTestApp(const SizedBox()));
    await tester.pump();
    expect(PageScrollRegistry.debugDepth, 0,
        reason: 'the scaffold must pop its controller on dispose (no leak)');
  });
}
