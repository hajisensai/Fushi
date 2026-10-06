import 'dart:ui' show SemanticsAction;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show SemanticsNode;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/focus/fushi_focus_target.dart';
import 'package:fushi/src/utils/adaptive/adaptive_navigation.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

const List<AdaptiveNavItem> _items = <AdaptiveNavItem>[
  AdaptiveNavItem(icon: FushiIcons.home, label: 'Home'),
  AdaptiveNavItem(icon: FushiIcons.search, label: 'Search'),
];

// These controls replace descendant semantics, so pointer/keyboard tests alone
// cannot detect a missing accessibility activation action.
Future<void> _semanticsTap(WidgetTester tester, String label) async {
  final SemanticsNode node = tester.getSemantics(find.bySemanticsLabel(label));
  expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
  tester.binding.pipelineOwner.semanticsOwner!.performAction(
    node.id,
    SemanticsAction.tap,
  );
  await tester.pumpAndSettle();
}

Widget _app(Widget child) => MaterialApp(
  theme: ThemeData(splashFactory: NoSplash.splashFactory),
  home: FushiFocusRoot(child: Scaffold(body: child)),
);

void main() {
  testWidgets('screen reader expands and collapses the navigation rail', (
    WidgetTester tester,
  ) async {
    final SemanticsHandle semantics = tester.ensureSemantics();
    try {
      bool expanded = false;
      int activations = 0;
      await tester.pumpWidget(
        _app(
          StatefulBuilder(
            builder: (BuildContext context, StateSetter setState) => Row(
              children: <Widget>[
                adaptiveNavRail(
                  context: context,
                  currentIndex: 0,
                  onTap: (int _) {},
                  items: _items,
                  extended: expanded,
                  onToggleExtended: () => setState(() {
                    expanded = !expanded;
                    activations++;
                  }),
                ),
                const Expanded(child: SizedBox()),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await _semanticsTap(tester, 'Expand navigation');
      expect(expanded, isTrue);
      expect(activations, 1);
      await _semanticsTap(tester, 'Collapse navigation');
      expect(expanded, isFalse);
      expect(activations, 2);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('screen reader activates the floating bar primary action', (
    WidgetTester tester,
  ) async {
    final SemanticsHandle semantics = tester.ensureSemantics();
    try {
      int activations = 0;
      await tester.pumpWidget(
        _app(
          Align(
            alignment: Alignment.bottomCenter,
            child: Builder(
              builder: (BuildContext context) => adaptiveBottomBar(
                context: context,
                currentIndex: 0,
                onTap: (int _) {},
                items: _items,
                materialFab: AdaptiveNavFab(
                  icon: FushiIcons.search,
                  label: 'Primary action',
                  onPressed: () => activations++,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await _semanticsTap(tester, 'Primary action');
      expect(activations, 1);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('screen reader expands the minimized bar without switching tab', (
    WidgetTester tester,
  ) async {
    final SemanticsHandle semantics = tester.ensureSemantics();
    try {
      bool minimized = true;
      int expansions = 0;
      int selections = 0;
      await tester.pumpWidget(
        _app(
          Column(
            children: <Widget>[
              // The real page has a content focus target. Without one, auto-home
              // enters the mini bar during the initial pump and expands it before
              // this test can exercise the screen reader's tap action.
              const FushiFocusTarget(
                id: FushiFocusId('page-content'),
                child: SizedBox(width: 200, height: 100),
              ),
              Expanded(
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: StatefulBuilder(
                    builder: (BuildContext context, StateSetter setState) =>
                        adaptiveBottomBar(
                          context: context,
                          currentIndex: 0,
                          onTap: (int _) => selections++,
                          items: _items,
                          glassMinimized: minimized,
                          onGlassExpand: () => setState(() {
                            minimized = false;
                            expansions++;
                          }),
                        ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(minimized, isTrue);
      expect(expansions, 0);
      await _semanticsTap(tester, 'Home');
      expect(minimized, isFalse);
      expect(expansions, 1);
      expect(selections, 0);
    } finally {
      semantics.dispose();
    }
  });
}
