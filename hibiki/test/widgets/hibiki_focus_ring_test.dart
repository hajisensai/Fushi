import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/components/hibiki_focus_ring.dart';

void main() {
  test('HibikiFocusRing uses design token radius', () {
    final String source =
        File('lib/src/utils/components/hibiki_focus_ring.dart')
            .readAsStringSync();

    expect(source, contains('HibikiDesignTokens.of(context)'));
    expect(source, contains('tokens.radii.chipRadius'));
    expect(source, contains('HibikiFocusScroll.ensureVisibleIfHidden'));
    expect(source, isNot(contains('BorderRadius.circular(8)')));
    expect(source, isNot(contains('Scrollable.ensureVisible')));
  });

  testWidgets('HibikiFocusRing builds and overlays its child',
      (WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home: HibikiFocusRing(
        child: Scaffold(
          body: Center(
            child: ElevatedButton(onPressed: () {}, child: const Text('x')),
          ),
        ),
      ),
    ));
    await tester.pump();
    expect(find.text('x'), findsOneWidget);
    expect(find.byType(HibikiFocusRing), findsOneWidget);
  });

  testWidgets(
      'does not throw when a focused sibling is removed while the ring '
      'rebuilds in the same frame (desktop startup regression)',
      (WidgetTester tester) async {
    // Desktop defaults to the traditional (keyboard) highlight mode from
    // launch, so the focus-ring geometry path runs immediately — unlike mobile
    // (touch mode), where it is skipped. Reading the focused element's geometry
    // during build crashed with "Cannot get renderObject of inactive element".
    //
    // Reproduction: the focused widget is a sibling placed BEFORE the ring in
    // the parent's children, and the ring's child changes with the toggle so
    // the ring rebuilds in the same pass. When the parent rebuilds, the focused
    // sibling is reconciled (deactivated) first while it is still the primary
    // focus (the focus change is only applied on a later microtask); the ring
    // then builds in the same pass — the moment a build-time findRenderObject()
    // would hit the inactive element.
    final FocusManager fm = FocusManager.instance;
    final FocusHighlightStrategy previous = fm.highlightStrategy;
    fm.highlightStrategy = FocusHighlightStrategy.alwaysTraditional;
    addTearDown(() => fm.highlightStrategy = previous);

    final FocusNode node = FocusNode();
    addTearDown(node.dispose);

    late StateSetter setOuter;
    bool show = true;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(
          builder: (BuildContext context, StateSetter setState) {
            setOuter = setState;
            return Column(
              children: <Widget>[
                if (show)
                  Focus(
                    focusNode: node,
                    autofocus: true,
                    child: const SizedBox(width: 30, height: 30),
                  ),
                HibikiFocusRing(
                  // Child identity changes with `show`, forcing the ring to
                  // rebuild in the same pass that removes the focused sibling.
                  child: SizedBox(
                      key: ValueKey<bool>(show), width: 10, height: 10),
                ),
              ],
            );
          },
        ),
      ),
    ));
    await tester.pump();
    expect(node.hasFocus, isTrue);

    setOuter(() => show = false);
    await tester.pump();
    await tester.pump();

    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'renders a focus ring for a stable focused widget in '
      'traditional mode', (WidgetTester tester) async {
    final FocusManager fm = FocusManager.instance;
    final FocusHighlightStrategy previous = fm.highlightStrategy;
    fm.highlightStrategy = FocusHighlightStrategy.alwaysTraditional;
    addTearDown(() => fm.highlightStrategy = previous);

    final FocusNode node = FocusNode();
    addTearDown(node.dispose);

    await tester.pumpWidget(MaterialApp(
      home: HibikiFocusRing(
        child: Scaffold(
          body: Center(
            child: Focus(
              focusNode: node,
              autofocus: true,
              child: const SizedBox(width: 40, height: 40),
            ),
          ),
        ),
      ),
    ));
    await tester.pump(); // post-frame rect computation
    await tester.pump(); // setState -> ring drawn

    expect(tester.takeException(), isNull);
    // The ring is an IgnorePointer-wrapped DecoratedBox positioned over focus.
    expect(find.byType(IgnorePointer), findsWidgets);
  });
}
