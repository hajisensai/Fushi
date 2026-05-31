import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:hibiki/src/focus/hibiki_focus_controller.dart';
import 'package:hibiki/src/focus/hibiki_focus_target.dart';
import 'package:hibiki/src/shortcuts/gamepad_service.dart';

void main() {
  // Three vertically-stacked focusables (clean geometric up/down graph).
  Future<BuildContext> pumpColumn(
    WidgetTester tester,
    List<FocusNode> nodes,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: <Widget>[
              for (final FocusNode n in nodes)
                Focus(
                  focusNode: n,
                  child: const SizedBox(width: 100, height: 60),
                ),
            ],
          ),
        ),
      ),
    );
    return tester.element(find.byType(Scaffold));
  }

  testWidgets('bootstraps onto the first focusable when nothing is focused',
      (tester) async {
    final nodes = List.generate(3, (i) => FocusNode(debugLabel: 'n$i'));
    addTearDown(() {
      for (final n in nodes) {
        n.dispose();
      }
    });
    final ctx = await pumpColumn(tester, nodes);
    expect(FocusManager.instance.primaryFocus?.debugLabel, isNot('n0'));

    gamepadMoveFocusInDirection(ctx, TraversalDirection.down);
    await tester.pump();

    expect(nodes[0].hasPrimaryFocus, isTrue,
        reason: 'first directional press with nothing focused lands on n0');
  });

  testWidgets('uses HibikiFocusController when a focus root is available',
      (WidgetTester tester) async {
    final FocusNode raw = FocusNode(debugLabel: 'raw-unregistered');
    final FocusNode target = FocusNode(debugLabel: 'registered-target');
    addTearDown(raw.dispose);
    addTearDown(target.dispose);

    await tester.pumpWidget(MaterialApp(
      home: HibikiFocusRoot(
        child: Column(
          children: <Widget>[
            Focus(
              focusNode: raw,
              child: const SizedBox(width: 80, height: 60),
            ),
            HibikiFocusTarget(
              id: const HibikiFocusId('registered-target'),
              focusNode: target,
              child: const SizedBox(width: 80, height: 60),
            ),
          ],
        ),
      ),
    ));
    await tester.pump();

    final BuildContext context = tester.element(find.byType(Column));
    final bool moved = gamepadMoveFocusInDirection(
      context,
      TraversalDirection.down,
    );
    await tester.pump();

    expect(moved, isTrue);
    expect(raw.hasPrimaryFocus, isFalse);
    expect(target.hasPrimaryFocus, isTrue);
    expect(
      HibikiFocusRoot.controllerOf(context).activeId,
      const HibikiFocusId('registered-target'),
    );
  });

  testWidgets('moves geometrically down then up between stacked controls',
      (tester) async {
    final nodes = List.generate(3, (i) => FocusNode(debugLabel: 'n$i'));
    addTearDown(() {
      for (final n in nodes) {
        n.dispose();
      }
    });
    final ctx = await pumpColumn(tester, nodes);

    nodes[0].requestFocus();
    await tester.pump();

    gamepadMoveFocusInDirection(ctx, TraversalDirection.down);
    await tester.pump();
    expect(nodes[1].hasPrimaryFocus, isTrue, reason: 'down → next row');

    gamepadMoveFocusInDirection(ctx, TraversalDirection.up);
    await tester.pump();
    expect(nodes[0].hasPrimaryFocus, isTrue, reason: 'up → previous row');
  });

  testWidgets(
      'a focused skip-traversal wrapper is bypassed onto a real control',
      (tester) async {
    // Mirrors the home page: a full-page Focus that only sinks shortcut keys
    // (skipTraversal) must never keep focus when navigating — the press jumps
    // to the first real control so the ring lands on something specific.
    final wrapper = FocusNode(debugLabel: 'wrapper');
    final real = FocusNode(debugLabel: 'real');
    addTearDown(wrapper.dispose);
    addTearDown(real.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Focus(
            focusNode: wrapper,
            skipTraversal: true,
            child: Focus(
              focusNode: real,
              child: const SizedBox(width: 80, height: 80),
            ),
          ),
        ),
      ),
    );
    final ctx = tester.element(find.byType(Scaffold));

    wrapper.requestFocus();
    await tester.pump();
    expect(wrapper.hasPrimaryFocus, isTrue);

    gamepadMoveFocusInDirection(ctx, TraversalDirection.down);
    await tester.pump();
    expect(real.hasPrimaryFocus, isTrue,
        reason: 'a press from the skip-traversal wrapper lands on the control');
  });

  testWidgets(
      'reading-order fallback: a blocked direction advances via next/previous',
      (tester) async {
    // A horizontal row has no vertical neighbours, so up/down fail
    // geometrically and must fall back to previous/next focus (predictable,
    // never a random jump).
    final left = FocusNode(debugLabel: 'left');
    final right = FocusNode(debugLabel: 'right');
    addTearDown(left.dispose);
    addTearDown(right.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Row(
            children: <Widget>[
              Focus(
                  focusNode: left,
                  child: const SizedBox(width: 80, height: 80)),
              Focus(
                  focusNode: right,
                  child: const SizedBox(width: 80, height: 80)),
            ],
          ),
        ),
      ),
    );
    final ctx = tester.element(find.byType(Scaffold));

    left.requestFocus();
    await tester.pump();

    // "down" has no vertical target → reading-order next → right.
    gamepadMoveFocusInDirection(ctx, TraversalDirection.down);
    await tester.pump();
    expect(right.hasPrimaryFocus, isTrue,
        reason: 'blocked down falls back to nextFocus');

    // "up" has no vertical target → reading-order previous → left.
    gamepadMoveFocusInDirection(ctx, TraversalDirection.up);
    await tester.pump();
    expect(left.hasPrimaryFocus, isTrue,
        reason: 'blocked up falls back to previousFocus');
  });
}
