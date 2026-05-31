import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/focus/hibiki_focus_scroll.dart';
import 'package:hibiki/src/utils/components/hibiki_material_components.dart';

import 'widget_test_helpers.dart';

void main() {
  testWidgets(
      'HibikiPageScaffold page-scrolls its body from a header-area context '
      '(where the gamepad focus actually sits) via PrimaryScrollController',
      (WidgetTester tester) async {
    // The gamepad dispatch context is the focused control — on a pure-display
    // page that is a header/AppBar icon button, which sits OUTSIDE the body
    // scroll view but INSIDE the scaffold PrimaryScrollController. (A context
    // INSIDE the scroll view is shadowed by PrimaryScrollController.none, which
    // ScrollView wraps its own descendants in — that is by design.)
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

    // Exactly what GamepadService._tryScrollPage calls for LB/RB.
    final bool scrolled = HibikiFocusScroll.scrollPrimary(headerCtx, 0.9);
    expect(scrolled, isTrue,
        reason: 'header-area context reaches the scaffold '
            'PrimaryScrollController the body attached to');
    await tester.pumpAndSettle();
    expect(find.text('row 0'), findsNothing,
        reason: 'page-scroll moved the pure-display page ~0.9 viewport down');
  });
}
