import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

// The home desktop layout wraps the navigation rail and the content pane each in
// a FocusTraversalGroup so Tab / Shift+Tab walk one region fully before the next
// (visual order, by block) instead of zig-zagging between rail and content
// row-by-row. This verifies that grouping behaviour.

void main() {
  String? focusedLabel(List<FocusNode> nodes) {
    for (final FocusNode n in nodes) {
      if (n.hasPrimaryFocus) return n.debugLabel;
    }
    return null;
  }

  testWidgets('Tab finishes the rail group before the content group', (
    tester,
  ) async {
    final rail = <FocusNode>[
      FocusNode(debugLabel: 'rail0'),
      FocusNode(debugLabel: 'rail1'),
      FocusNode(debugLabel: 'rail2'),
    ];
    final content = <FocusNode>[
      FocusNode(debugLabel: 'content0'),
      FocusNode(debugLabel: 'content1'),
    ];
    final all = <FocusNode>[...rail, ...content];
    addTearDown(() {
      for (final FocusNode n in all) {
        n.dispose();
      }
    });

    Widget group(List<FocusNode> nodes) => FocusTraversalGroup(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final FocusNode n in nodes)
                Focus(
                  focusNode: n,
                  child: const SizedBox(width: 120, height: 40),
                ),
            ],
          ),
        );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          // Rail-like column on the left, content-like column on the right, at
          // overlapping y-coordinates — the case that interleaves without groups.
          body: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [group(rail), const VerticalDivider(), group(content)],
          ),
        ),
      ),
    );

    rail.first.requestFocus();
    await tester.pump();

    final seen = <String?>[focusedLabel(all)];
    for (int i = 0; i < all.length - 1; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      seen.add(focusedLabel(all));
    }

    expect(seen, <String>['rail0', 'rail1', 'rail2', 'content0', 'content1'],
        reason: 'Tab should finish the whole rail group before the content');
  });

  testWidgets('Shift+Tab walks the same visual order in reverse', (
    tester,
  ) async {
    final rail = <FocusNode>[
      FocusNode(debugLabel: 'rail0'),
      FocusNode(debugLabel: 'rail1'),
    ];
    final content = <FocusNode>[
      FocusNode(debugLabel: 'content0'),
      FocusNode(debugLabel: 'content1'),
    ];
    final all = <FocusNode>[...rail, ...content];
    addTearDown(() {
      for (final FocusNode n in all) {
        n.dispose();
      }
    });

    Widget group(List<FocusNode> nodes) => FocusTraversalGroup(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final FocusNode n in nodes)
                Focus(
                  focusNode: n,
                  child: const SizedBox(width: 120, height: 40),
                ),
            ],
          ),
        );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [group(rail), const VerticalDivider(), group(content)],
          ),
        ),
      ),
    );

    content.last.requestFocus();
    await tester.pump();

    final seen = <String?>[focusedLabel(all)];
    for (int i = 0; i < all.length - 1; i++) {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      seen.add(focusedLabel(all));
    }

    expect(seen, <String>['content1', 'content0', 'rail1', 'rail0'],
        reason: 'Shift+Tab reverses the same block order');
  });
}
