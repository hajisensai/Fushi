import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:hibiki/src/pages/implementations/media_item_dialog_page.dart';

/// The long-press dialog quick actions are equal-width chips laid out below the
/// cover: a single Expanded row when they fit, degrading to full-width vertical
/// rows on a narrow dialog. Labels must render without overflow on both wide and
/// narrow dialogs, and on a wide dialog the chips must share the row equally.
void main() {
  // Three Japanese labels of differing length, the real
  // view_illustrations / audiobook_import / tag_label set.
  final List<DialogQuickAction> threeActions = <DialogQuickAction>[
    DialogQuickAction(
      label: '査看插画',
      icon: Icons.image_outlined,
      onPressed: () {},
    ),
    DialogQuickAction(
      label: '导入有声书',
      icon: Icons.headphones_outlined,
      onPressed: () {},
    ),
    DialogQuickAction(
      label: '标签',
      icon: Icons.sell_outlined,
      onPressed: () {},
    ),
  ];

  Future<void> pumpFrame(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: MediaItemDialogFrame(
              cover: const SizedBox(width: 260, height: 200),
              title: 'こころ',
              launchLabel: 'Read',
              onLaunch: () {},
              quickActions: threeActions,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('renders every quick-action label as a button',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await pumpFrame(tester);

    expect(find.text('査看插画'), findsOneWidget);
    expect(find.text('导入有声书'), findsOneWidget);
    expect(find.text('标签'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a wide dialog lays the quick-action chips out equal-width',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await pumpFrame(tester);

    final double w1 = _chipWidth(tester, '査看插画');
    final double w2 = _chipWidth(tester, '导入有声书');
    final double w3 = _chipWidth(tester, '标签');
    // Equal-width parity: the three chips share the row evenly regardless of
    // their intrinsic label lengths.
    expect((w1 - w2).abs(), lessThan(1.0));
    expect((w2 - w3).abs(), lessThan(1.0));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a narrow dialog stacks the action chips without overflowing',
      (WidgetTester tester) async {
    // Narrow enough that the three chips cannot sit on a single row; the layout
    // degrades to full-width vertical rows without throwing or clipping.
    tester.view.physicalSize = const Size(360, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await pumpFrame(tester);

    expect(find.text('査看插画'), findsOneWidget);
    expect(find.text('导入有声书'), findsOneWidget);
    expect(find.text('标签'), findsOneWidget);
    // No render-overflow exceptions on the narrow layout.
    expect(tester.takeException(), isNull);
  });

  testWidgets('tapping a quick-action fires its callback',
      (WidgetTester tester) async {
    int tapped = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MediaItemDialogFrame(
            cover: const SizedBox(width: 260, height: 200),
            title: 'こころ',
            launchLabel: 'Read',
            onLaunch: () {},
            quickActions: <DialogQuickAction>[
              DialogQuickAction(
                label: 'Tag',
                icon: Icons.sell_outlined,
                onPressed: () => tapped++,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Tag'));
    await tester.pump();
    expect(tapped, 1);
    expect(tester.takeException(), isNull);
  });

  test('quick, list, and danger action groups keep explicit vertical rhythm',
      () {
    final String source =
        File('lib/src/pages/implementations/media_item_dialog_page.dart')
            .readAsStringSync();
    final int frameStart = source.indexOf('class MediaItemDialogFrame');
    expect(frameStart, isNonNegative);
    final String build = _methodSource(
      source.substring(frameStart),
      '  @override\n  Widget build(BuildContext context) {',
    );

    expect(build, contains('leading: Icon(action.icon)'));
    expect(
      RegExp(r'SizedBox\(height: tokens\.spacing\.gap\)')
          .allMatches(build)
          .length,
      greaterThanOrEqualTo(2),
      reason: 'quick/list/danger groups need clear MD3 spacing',
    );
  });
}

/// Width of the chip wrapping the given label (the OutlinedButton ancestor).
double _chipWidth(WidgetTester tester, String label) {
  final Finder button = find.ancestor(
    of: find.text(label),
    matching: find.byType(OutlinedButton),
  );
  expect(button, findsOneWidget, reason: 'chip for "$label" not found');
  return tester.getSize(button).width;
}

String _methodSource(String source, String signature) {
  final int start = source.indexOf(signature);
  expect(start, isNonNegative, reason: 'missing $signature');
  int depth = 0;
  final int bodyStart = source.indexOf('{', start);
  for (int i = bodyStart; i < source.length; i++) {
    if (source[i] == '{') depth++;
    if (source[i] == '}') {
      depth--;
      if (depth == 0) return source.substring(start, i + 1);
    }
  }
  throw StateError('unterminated method: $signature');
}
