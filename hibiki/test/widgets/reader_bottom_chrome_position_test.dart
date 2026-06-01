import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// Regression guard for: reader bottom control bar (play / settings) rendering at
// the TOP of the screen.
//
// Root cause (reader_hibiki_page.dart, commit 1038e899a): the bottom chrome's
// `Positioned(bottom: 0)` was wrapped in a `FocusScope` that was itself the direct
// child of the reader `Stack`:
//
//     Stack(children: [..., FocusScope(node, child: Positioned(bottom: 0, ...))])
//
// `FocusScope` interposes a render node between the `Stack` and the `Positioned`,
// so the `Positioned`'s `StackParentData` can no longer attach to the `Stack`. The
// bar then falls back to the Stack's default top-start alignment (or throws an
// "Incorrect use of ParentDataWidget" error in debug).
//
// The invariant: the `Positioned` must be the DIRECT child of the `Stack`; the
// `FocusScope` (chrome focus scoping) must live INSIDE the `Positioned`.

void main() {
  const Key barKey = Key('chrome-bar');
  const Key bgKey = Key('stack-bg');
  const double barHeight = 56;

  Future<void> pumpStack(WidgetTester tester, Widget stackChild) {
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              const Positioned.fill(
                child: ColoredBox(key: bgKey, color: Colors.white),
              ),
              stackChild,
            ],
          ),
        ),
      ),
    );
  }

  Widget bar() => Container(
        key: barKey,
        height: barHeight,
        color: Colors.blue,
      );

  testWidgets(
    'BUGGY pattern: FocusScope wrapping Positioned detaches it from the Stack',
    (WidgetTester tester) async {
      final FocusScopeNode node = FocusScopeNode(debugLabel: 'chrome');
      addTearDown(node.dispose);

      await pumpStack(
        tester,
        FocusScope(
          node: node,
          child: Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: bar(),
          ),
        ),
      );

      final Object? error = tester.takeException();
      if (error != null) {
        // Debug builds assert "Incorrect use of ParentDataWidget" — that already
        // proves the Positioned is detached from the Stack.
        expect(error.toString(), contains('ParentDataWidget'));
        return;
      }

      // Release/profile builds silently mis-place the bar: it falls back to the
      // Stack's top-start alignment instead of the bottom.
      final Rect stack = tester.getRect(find.byKey(bgKey));
      final Rect rect = tester.getRect(find.byKey(barKey));
      final bool atBottom = (rect.bottom - stack.bottom).abs() < 0.5;
      expect(atBottom, isFalse,
          reason: 'Expected the buggy pattern to mis-place the bar away from '
              'the bottom; if this fails the detachment no longer reproduces.');
    },
  );

  testWidgets(
    'FIXED pattern: Positioned wrapping FocusScope keeps the bar at the bottom',
    (WidgetTester tester) async {
      final FocusScopeNode node = FocusScopeNode(debugLabel: 'chrome');
      addTearDown(node.dispose);

      await pumpStack(
        tester,
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: FocusScope(
            node: node,
            child: bar(),
          ),
        ),
      );

      expect(tester.takeException(), isNull);

      final Rect stack = tester.getRect(find.byKey(bgKey));
      final Rect rect = tester.getRect(find.byKey(barKey));
      expect(rect.bottom, moreOrLessEquals(stack.bottom, epsilon: 0.5),
          reason: 'Bottom chrome must be anchored to the bottom of the stack.');
      expect(
          rect.top, moreOrLessEquals(stack.bottom - barHeight, epsilon: 0.5));
    },
  );
}
