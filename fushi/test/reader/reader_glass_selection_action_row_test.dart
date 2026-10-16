import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/reader_fushi_page.dart'
    show ReaderGlassSelectionActionRow, ReaderSelectionActionItem;
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart'
    show FushiPlainButton;
import 'package:material_ui/material_ui.dart';

/// Apple（iOS 26 编辑菜单）选区工具条：与 Material 的 [ReaderSelectionActionBar] 同一套
/// 三级降级（带文字 → 只图标 + Tooltip → 前 3 颗 + 「⋯」），命中区不小于 48，
/// 不再整排 FittedBox 等比缩小。
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
              child: ReaderGlassSelectionActionRow(
                items: items(n),
                maxWidth: width,
                barHeight: kMinInteractiveDimension,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  setUp(tapped.clear);

  testWidgets('宽：带文字，没有 FittedBox / 溢出菜单', (WidgetTester tester) async {
    await pump(tester, 790, 2);
    expect(tester.takeException(), isNull);
    expect(find.text('Action label number 0'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(ReaderGlassSelectionActionRow),
        matching: find.byType(FittedBox),
      ),
      findsNothing,
    );
    await tester.tap(find.text('Action label number 1'));
    expect(tapped, <String>['a1']);
  });

  testWidgets('中：只图标 + Tooltip，命中区 >=48', (WidgetTester tester) async {
    await pump(tester, 6 * 48 + 10, 6);
    expect(tester.takeException(), isNull);
    expect(find.text('Action label number 0'), findsNothing);
    expect(find.byType(FushiPlainButton), findsNWidgets(6));
    expect(find.byTooltip('Action label number 5'), findsOneWidget);
    for (final Element e in find.byType(FushiPlainButton).evaluate()) {
      final Size s = e.size!;
      expect(s.width, greaterThanOrEqualTo(48));
      expect(s.height, greaterThanOrEqualTo(48));
    }
  });

  testWidgets('窄：前 3 颗常驻，其余折进「⋯」，点菜单项触发回调', (WidgetTester tester) async {
    await pump(tester, 4 * 48 + 10, 6);
    expect(tester.takeException(), isNull);
    expect(find.byType(FushiPlainButton), findsNWidgets(3));
    final Finder more = find.byKey(
      const ValueKey<String>('reader_selection_action_more'),
    );
    expect(more, findsOneWidget);
    await tester.tap(more);
    await tester.pumpAndSettle();
    expect(find.text('Action label number 5'), findsOneWidget);
    await tester.tap(find.text('Action label number 5'));
    await tester.pumpAndSettle();
    expect(tapped, <String>['a5']);
  });
}
