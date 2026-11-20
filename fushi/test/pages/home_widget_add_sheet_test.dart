// 首页「添加小组件」面板（spec 2026-11-15）：只列可用组件、已在首页的置灰且不能
// 再加、分类与搜索筛选、每项显示默认尺寸与可调范围、添加按默认尺寸返回。交互全部经
// 焦点 + 按键。
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/home_widget_layout.dart';
import 'package:fushi/src/pages/implementations/home_widget_add_sheet.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:material_ui/material_ui.dart';

Future<List<HomeWidgetItem>> _pump(
  WidgetTester tester, {
  HomeGridKind grid = HomeGridKind.wide,
  List<HomeWidgetKind> available = HomeWidgetKind.values,
  Set<HomeWidgetKind> present = const <HomeWidgetKind>{},
}) async {
  tester.view.physicalSize = const Size(900, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final List<HomeWidgetItem> added = <HomeWidgetItem>[];
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: HomeWidgetAddSheet(
          grid: grid,
          available: available,
          present: present,
          labelOf: homeWidgetLabel,
          descriptionOf: homeWidgetDescription,
          onAdd: added.add,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return added;
}

/// 把焦点交给 [finder] 所在的可聚焦控件并按 Enter 激活它。
Future<void> _activate(WidgetTester tester, Finder finder) async {
  Focus.of(tester.element(finder)).requestFocus();
  await tester.pump();
  await tester.sendKeyEvent(LogicalKeyboardKey.enter);
  await tester.pumpAndSettle();
}

Finder _item(HomeWidgetKind kind) => find.byKey(homeWidgetAddItemKey(kind));

void main() {
  testWidgets('只列可用组件；已在首页的标注并禁用添加', (WidgetTester tester) async {
    await _pump(
      tester,
      available: <HomeWidgetKind>[
        HomeWidgetKind.continueHero,
        HomeWidgetKind.today,
        HomeWidgetKind.week,
      ],
      present: <HomeWidgetKind>{HomeWidgetKind.today},
    );
    expect(_item(HomeWidgetKind.continueHero), findsOneWidget);
    expect(_item(HomeWidgetKind.aiAgent), findsNothing);
    expect(
      find.text('${t.stat_today} · ${t.home_widget_already_added}'),
      findsOneWidget,
    );
    expect(
      tester
          .widget<FushiFilledButton>(
            find.byKey(homeWidgetAddButtonKey(HomeWidgetKind.today)),
          )
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<FushiFilledButton>(
            find.byKey(homeWidgetAddButtonKey(HomeWidgetKind.week)),
          )
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('每项显示默认尺寸 + 可调范围，按网格给（窄网格宽度封顶 2 列）', (WidgetTester tester) async {
    await _pump(tester, grid: HomeGridKind.compact);
    expect(
      find.byKey(
        homeWidgetAddSizeKey(
          HomeWidgetKind.continueHero,
          const HomeWidgetSize(2, 2),
        ),
      ),
      findsOneWidget,
    );
    // 只显示默认尺寸一块，不再列一排可选档。
    expect(
      find.byKey(
        homeWidgetAddSizeKey(
          HomeWidgetKind.continueHero,
          const HomeWidgetSize(2, 3),
        ),
      ),
      findsNothing,
    );
    expect(
      find.text(t.home_widget_size_range(min: '1×2', max: '2×4')),
      findsWidgets,
    );
    expect(
      tester
          .widget<Text>(
            find.byKey(const ValueKey<String>('home-widget-add-range/today')),
          )
          .data,
      t.home_widget_size_range(min: '1×1', max: '2×2'),
    );
  });

  testWidgets('宽网格范围到 6 列；添加按默认尺寸返回', (WidgetTester tester) async {
    final List<HomeWidgetItem> added = await _pump(tester);
    expect(
      tester
          .widget<Text>(
            find.byKey(
              const ValueKey<String>('home-widget-add-range/continue'),
            ),
          )
          .data,
      t.home_widget_size_range(min: '1×2', max: '6×4'),
    );
    expect(
      find.byKey(
        homeWidgetAddSizeKey(
          HomeWidgetKind.continueHero,
          const HomeWidgetSize(4, 2),
        ),
      ),
      findsOneWidget,
    );
    await _activate(
      tester,
      find.descendant(
        of: find.byKey(homeWidgetAddButtonKey(HomeWidgetKind.week)),
        matching: find.text(t.home_widget_add_confirm),
      ),
    );
    expect(
      added.single,
      const HomeWidgetItem(HomeWidgetKind.week, HomeWidgetSize(2, 2)),
    );
    await _activate(
      tester,
      find.descendant(
        of: find.byKey(homeWidgetAddButtonKey(HomeWidgetKind.recentlyAdded)),
        matching: find.text(t.home_widget_add_confirm),
      ),
    );
    expect(
      added.last,
      const HomeWidgetItem(HomeWidgetKind.recentlyAdded, HomeWidgetSize(4, 2)),
    );
  });

  testWidgets('分类筛选与搜索；没有匹配时给说明', (WidgetTester tester) async {
    await _pump(tester);
    await _activate(tester, find.text(t.home_widget_category_tools));
    expect(_item(HomeWidgetKind.tracking), findsOneWidget);
    expect(_item(HomeWidgetKind.aiAgent), findsOneWidget);
    expect(_item(HomeWidgetKind.today), findsNothing);
    expect(_item(HomeWidgetKind.continueHero), findsNothing);

    await _activate(tester, find.text(t.home_widget_category_all));
    final Finder search = find.byKey(
      const ValueKey<String>('home-widget-add-search'),
    );
    await tester.enterText(search, t.stat_week_past.toLowerCase());
    await tester.pumpAndSettle();
    expect(_item(HomeWidgetKind.week), findsOneWidget);
    expect(_item(HomeWidgetKind.today), findsNothing);

    await tester.enterText(search, 'zzzz-no-such-widget');
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('home-widget-add-empty')),
      findsOneWidget,
    );
  });
}
