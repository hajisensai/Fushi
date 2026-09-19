import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/pages/implementations/media_item_dialog_page.dart';

/// The long-press dialog quick actions are equal-width chips laid out below the
/// cover: a single row when they fit, otherwise fewer columns per row (down to
/// full-width vertical rows) — the column count is decided from the chips'
/// real intrinsic widths, never from a guessed minimum (BUG-2603). Labels must
/// render without ellipsis on both wide and narrow dialogs, and chips sharing a
/// row must share it equally.
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

  Future<void> pumpFrame(WidgetTester tester,
      {List<DialogQuickAction>? actions}) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: MediaItemDialogFrame(
              cover: const SizedBox(width: 260, height: 200),
              title: 'こころ',
              launchLabel: 'Read',
              onLaunch: () {},
              quickActions: actions ?? threeActions,
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

  // BUG-2603: the real shelf book set on upstream — view_illustrations /
  // audiobook_import / remote_book_audiobook_download (zh-CN). Inside the
  // 420-wide dialog cap the old layout split the row into three ~124 px chips
  // (>= its guessed 96 px minimum) while the widest label needs ~190 px, so the
  // labels rendered as 「查…」「导…」「从…」. Ellipsis throws no exception, so the
  // narrow-dialog test above never caught it; assert on the paragraph itself.
  final List<DialogQuickAction> shelfActions = <DialogQuickAction>[
    DialogQuickAction(
      label: '查看插画',
      icon: Icons.image_outlined,
      onPressed: () {},
    ),
    DialogQuickAction(
      label: '导入有声书',
      icon: Icons.headphones_outlined,
      onPressed: () {},
    ),
    DialogQuickAction(
      label: '从互联对端下载有声书',
      icon: Icons.cloud_download_outlined,
      onPressed: () {},
    ),
  ];

  // Both the dialog at its 420 px cap (the reported tablet-width case) and a
  // phone-width dialog.
  for (final Size screen in <Size>[
    const Size(1200, 1600),
    const Size(390, 844)
  ]) {
    testWidgets(
        'real shelf labels are never ellipsised on a ${screen.width.round()}-wide screen',
        (WidgetTester tester) async {
      tester.view.physicalSize = screen;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await pumpFrame(tester, actions: shelfActions);

      for (final DialogQuickAction action in shelfActions) {
        expect(_didEllipsise(tester, action.label), isFalse,
            reason: '"${action.label}" was cut short');
      }
      // The three chips cannot share one row at this width, so the layout must
      // have wrapped — and every chip still uses the same column width.
      final List<Rect> rects = <Rect>[
        for (final DialogQuickAction action in shelfActions)
          _chipRect(tester, action.label),
      ];
      expect(rects.map((Rect r) => r.top).toSet().length, greaterThan(1),
          reason: 'chips should wrap onto more than one row');
      expect(rects.map((Rect r) => r.width.round()).toSet().length, 1,
          reason: 'all chips share one column width');
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('chips wrap to fewer columns per row instead of shrinking',
      (WidgetTester tester) async {
    // Widest label fits two-per-row but not three-per-row inside the 420-wide
    // dialog: expect a 2 + 1 grid, equal widths, no ellipsis.
    final List<DialogQuickAction> actions = <DialogQuickAction>[
      DialogQuickAction(
        label: '查看插画',
        icon: Icons.image_outlined,
        onPressed: () {},
      ),
      DialogQuickAction(
        label: '导入有声书',
        icon: Icons.headphones_outlined,
        onPressed: () {},
      ),
      DialogQuickAction(
        label: '打开文件位置',
        icon: Icons.folder_open_outlined,
        onPressed: () {},
      ),
    ];
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await pumpFrame(tester, actions: actions);

    final Rect r1 = _chipRect(tester, '查看插画');
    final Rect r2 = _chipRect(tester, '导入有声书');
    final Rect r3 = _chipRect(tester, '打开文件位置');
    expect(r1.top, r2.top, reason: 'first two chips share a row');
    expect(r3.top, greaterThan(r1.bottom), reason: 'third chip wraps');
    expect(r1.left, r3.left, reason: 'wrapped chip starts a new row');
    expect((r1.width - r2.width).abs(), lessThan(1.0));
    expect((r2.width - r3.width).abs(), lessThan(1.0));
    for (final DialogQuickAction action in actions) {
      expect(_didEllipsise(tester, action.label), isFalse,
          reason: '"${action.label}" was cut short');
    }
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
double _chipWidth(WidgetTester tester, String label) =>
    _chipRect(tester, label).width;

/// Screen rect of the chip wrapping the given label.
Rect _chipRect(WidgetTester tester, String label) {
  final Finder button = find.ancestor(
    of: find.text(label),
    matching: find.byType(OutlinedButton),
  );
  expect(button, findsOneWidget, reason: 'chip for "$label" not found');
  return tester.getRect(button);
}

/// Whether the label paragraph was cut to its single line with an ellipsis.
/// `TextOverflow.ellipsis` never throws, so this is the only observable signal
/// that a chip was too narrow for its label.
bool _didEllipsise(WidgetTester tester, String label) {
  final RenderParagraph paragraph =
      tester.renderObject<RenderParagraph>(find.text(label));
  return paragraph.didExceedMaxLines;
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
