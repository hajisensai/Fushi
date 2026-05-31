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

    expect(moved, isFalse);
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

  testWidgets('focus root moves geometrically in a two-column grid',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: HibikiFocusRoot(
          child: GridView.count(
            crossAxisCount: 2,
            childAspectRatio: 1,
            children: <Widget>[
              for (final String id in <String>[
                'top-left',
                'top-right',
                'bottom-left',
                'bottom-right',
              ])
                HibikiFocusTarget(
                  id: HibikiFocusId(id),
                  child: TextButton(
                    onPressed: () {},
                    child: Text(id),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    final BuildContext context = tester.element(find.byType(GridView));
    final HibikiFocusController controller =
        HibikiFocusRoot.controllerOf(context);

    expect(controller.requestById(const HibikiFocusId('top-left')), isTrue);
    await tester.pump();

    expect(controller.move(HibikiFocusDirection.down), isTrue);
    await tester.pump();

    expect(
      controller.activeId,
      const HibikiFocusId('bottom-left'),
      reason: 'D-pad down in a shelf grid must move to the row below, not the '
          'next item in reading order',
    );

    expect(controller.move(HibikiFocusDirection.right), isTrue);
    await tester.pump();

    expect(controller.activeId, const HibikiFocusId('bottom-right'));

    expect(controller.move(HibikiFocusDirection.down), isFalse);
    await tester.pump();

    expect(
      controller.activeId,
      const HibikiFocusId('bottom-right'),
      reason: 'D-pad down at the grid edge must stop instead of sliding '
          'sideways through reading order',
    );
  });

  testWidgets('gamepad escapes a focus root edge to sibling controls',
      (WidgetTester tester) async {
    final FocusNode rail = FocusNode(debugLabel: 'rail');
    addTearDown(rail.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Row(
            children: <Widget>[
              Focus(
                focusNode: rail,
                child: const SizedBox(width: 96, height: 320),
              ),
              Expanded(
                child: HibikiFocusRoot(
                  child: GridView.count(
                    crossAxisCount: 2,
                    childAspectRatio: 1,
                    children: <Widget>[
                      for (final String id in <String>[
                        'top-left',
                        'top-right',
                        'bottom-left',
                        'bottom-right',
                      ])
                        HibikiFocusTarget(
                          id: HibikiFocusId(id),
                          child: TextButton(
                            onPressed: () {},
                            child: Text(id),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    final BuildContext context = tester.element(find.byType(GridView));
    final HibikiFocusController controller =
        HibikiFocusRoot.controllerOf(context);

    expect(controller.requestById(const HibikiFocusId('top-left')), isTrue);
    await tester.pump();

    final bool moved = gamepadMoveFocusInDirection(
      context,
      TraversalDirection.left,
    );
    await tester.pump();

    expect(moved, isTrue);
    expect(rail.hasPrimaryFocus, isTrue,
        reason: 'left from the shelf edge must leave the book grid and focus '
            'the side navigation layer');
  });

  testWidgets('gamepad escapes a focus root top edge to top controls',
      (WidgetTester tester) async {
    final FocusNode top = FocusNode(debugLabel: 'top');
    addTearDown(top.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: <Widget>[
              Focus(
                focusNode: top,
                child: const SizedBox(width: 320, height: 72),
              ),
              Expanded(
                child: HibikiFocusRoot(
                  child: GridView.count(
                    crossAxisCount: 2,
                    childAspectRatio: 1,
                    children: <Widget>[
                      for (final String id in <String>[
                        'top-left',
                        'top-right',
                        'bottom-left',
                        'bottom-right',
                      ])
                        HibikiFocusTarget(
                          id: HibikiFocusId(id),
                          child: TextButton(
                            onPressed: () {},
                            child: Text(id),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    final BuildContext context = tester.element(find.byType(GridView));
    final HibikiFocusController controller =
        HibikiFocusRoot.controllerOf(context);

    expect(controller.requestById(const HibikiFocusId('top-left')), isTrue);
    await tester.pump();

    final bool moved = gamepadMoveFocusInDirection(
      context,
      TraversalDirection.up,
    );
    await tester.pump();

    expect(moved, isTrue);
    expect(top.hasPrimaryFocus, isTrue,
        reason: 'up from the shelf top edge must leave the book grid and focus '
            'the top options layer');
  });

  testWidgets('gamepad does not reading-order slide at a focus root edge',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: HibikiFocusRoot(
          child: GridView.count(
            crossAxisCount: 2,
            childAspectRatio: 1,
            children: <Widget>[
              for (final String id in <String>[
                'top-left',
                'top-right',
                'bottom-left',
                'bottom-right',
              ])
                HibikiFocusTarget(
                  id: HibikiFocusId(id),
                  child: TextButton(
                    onPressed: () {},
                    child: Text(id),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    final BuildContext context = tester.element(find.byType(GridView));
    final HibikiFocusController controller =
        HibikiFocusRoot.controllerOf(context);

    expect(controller.requestById(const HibikiFocusId('bottom-right')), isTrue);
    // Settle the reveal: focusing bottom-right centres it, scrolling the grid
    // to its max extent. Once settled there, a down press can neither scroll
    // further (already at the extent) nor slide sideways through reading order.
    await tester.pumpAndSettle();

    final bool moved = gamepadMoveFocusInDirection(
      context,
      TraversalDirection.down,
    );
    await tester.pump();

    expect(moved, isFalse);
    expect(controller.activeId, const HibikiFocusId('bottom-right'),
        reason: 'down at the bottom edge must not turn into a sideways '
            'reading-order move inside the shelf');
  });

  testWidgets(
      'D-pad edge takeover scrolls the focused list when no target in direction',
      (WidgetTester tester) async {
    // One registered target at the top of a long scroll view: down has no
    // lower focus target, so the gamepad must take over and scroll the list
    // instead of dead-ending.
    final ScrollController scrollCtrl = ScrollController();
    addTearDown(scrollCtrl.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: HibikiFocusRoot(
          child: SingleChildScrollView(
            controller: scrollCtrl,
            child: Column(
              children: <Widget>[
                HibikiFocusTarget(
                  id: const HibikiFocusId('only-target'),
                  child: const SizedBox(
                      width: 200, height: 80, child: Text('only')),
                ),
                for (int i = 0; i < 40; i++)
                  SizedBox(width: 200, height: 80, child: Text('filler $i')),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final BuildContext context =
        tester.element(find.byType(SingleChildScrollView));
    final HibikiFocusController controller =
        HibikiFocusRoot.controllerOf(context);
    expect(controller.requestById(const HibikiFocusId('only-target')), isTrue);
    await tester.pumpAndSettle();

    final double before = scrollCtrl.offset;
    final bool moved =
        gamepadMoveFocusInDirection(context, TraversalDirection.down);
    expect(moved, isTrue,
        reason: 'down with no lower target takes over and scrolls');
    await tester.pumpAndSettle();
    expect(scrollCtrl.offset, greaterThan(before),
        reason: 'the focused list scrolled ~0.8 viewport down');
  });

  testWidgets(
      'D-pad edge takeover returns false at the scroll extent (no dead loop)',
      (WidgetTester tester) async {
    final ScrollController scrollCtrl = ScrollController();
    addTearDown(scrollCtrl.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: HibikiFocusRoot(
          child: SingleChildScrollView(
            controller: scrollCtrl,
            child: Column(
              children: <Widget>[
                HibikiFocusTarget(
                  id: const HibikiFocusId('only-target'),
                  child: const SizedBox(
                      width: 200, height: 80, child: Text('only')),
                ),
                for (int i = 0; i < 40; i++)
                  SizedBox(width: 200, height: 80, child: Text('filler $i')),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final BuildContext context =
        tester.element(find.byType(SingleChildScrollView));
    final HibikiFocusController controller =
        HibikiFocusRoot.controllerOf(context);
    expect(controller.requestById(const HibikiFocusId('only-target')), isTrue);
    await tester.pumpAndSettle();

    scrollCtrl.jumpTo(scrollCtrl.position.maxScrollExtent);
    await tester.pump();

    final bool moved =
        gamepadMoveFocusInDirection(context, TraversalDirection.down);
    expect(moved, isFalse,
        reason:
            'already at the bottom: edge takeover must not report movement');
    expect(
        scrollCtrl.offset, closeTo(scrollCtrl.position.maxScrollExtent, 0.5));
  });
}
