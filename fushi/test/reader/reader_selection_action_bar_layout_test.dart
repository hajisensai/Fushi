import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/reader_fushi_page.dart'
    show ReaderSelectionActionBar, ReaderSelectionActionItem;

/// 2026-10 体验优化：移动端选区操作条不再 FittedBox 等比缩小，而是按宽度降级
/// （带文字 → 只图标 → 前 3 颗 + ⋮），每颗按钮命中区 ≥ 48×48。
void main() {
  final List<String> tapped = <String>[];
  const List<IconData> icons = <IconData>[
    Icons.search_outlined,
    Icons.copy_outlined,
    Icons.share_outlined,
    Icons.travel_explore,
    Icons.star_border,
    Icons.movie_creation_outlined,
  ];

  List<ReaderSelectionActionItem> items(int n) => <ReaderSelectionActionItem>[
    for (int i = 0; i < n; i++)
      ReaderSelectionActionItem(
        icon: icons[i],
        label: 'Action label number $i',
        onPressed: () => tapped.add('a$i'),
      ),
  ];

  Future<void> pump(WidgetTester tester, double width, int n) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: width,
              child: ReaderSelectionActionBar(items: items(n)),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  void expectNoScaleDown() {
    expect(
      find.descendant(
        of: find.byType(ReaderSelectionActionBar),
        matching: find.byType(FittedBox),
      ),
      findsNothing,
    );
  }

  setUp(tapped.clear);

  testWidgets('wide: labels shown at full size', (WidgetTester tester) async {
    // 测试字体 Ahem 每字 14dp 宽：两颗带文字按钮约 690dp，放得下 790。
    await pump(tester, 790, 2);
    expect(tester.takeException(), isNull);
    expect(find.text('Action label number 0'), findsOneWidget);
    expectNoScaleDown();
    await tester.tap(find.text('Action label number 1'));
    expect(tapped, <String>['a1']);
  });

  testWidgets('medium: icon-only with tooltips and 48dp targets', (
    WidgetTester tester,
  ) async {
    await pump(tester, 6 * 48 + 10, 6);
    expect(tester.takeException(), isNull);
    expect(find.text('Action label number 0'), findsNothing);
    expect(find.byType(IconButton), findsNWidgets(6));
    expect(find.byTooltip('Action label number 5'), findsOneWidget);
    for (int i = 0; i < 6; i++) {
      final Size s = tester.getSize(
        find.ancestor(
          of: find.byIcon(icons[i]),
          matching: find.byType(IconButton),
        ),
      );
      expect(s.width, greaterThanOrEqualTo(kMinInteractiveDimension));
      expect(s.height, greaterThanOrEqualTo(kMinInteractiveDimension));
    }
    expectNoScaleDown();
  });

  testWidgets('narrow: first 3 pinned, rest in overflow menu', (
    WidgetTester tester,
  ) async {
    await pump(tester, 220, 6);
    expect(tester.takeException(), isNull);
    expect(find.byTooltip('Action label number 0'), findsOneWidget);
    expect(find.byTooltip('Action label number 2'), findsOneWidget);
    expect(find.byTooltip('Action label number 3'), findsNothing);
    final Finder more = find.byKey(
      const ValueKey<String>('reader_selection_action_more'),
    );
    expect(more, findsOneWidget);
    expect(
      tester.getSize(more).width,
      greaterThanOrEqualTo(kMinInteractiveDimension),
    );

    await tester.tap(more);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Action label number 4'));
    await tester.pumpAndSettle();
    expect(tapped, <String>['a4']);
    expectNoScaleDown();
  });
}
