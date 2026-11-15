// 首页「添加小组件」面板（spec 2026-11-15）：只列可用组件、已在首页的置灰且不能
// 再加、分类与搜索筛选、选尺寸后添加返回对应组件。交互全部经焦点 + 按键。
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

  testWidgets('尺寸档按网格给：窄网格没有 4×2', (WidgetTester tester) async {
    await _pump(tester, grid: HomeGridKind.compact);
    expect(
      find.byKey(
        homeWidgetAddSizeKey(
          HomeWidgetKind.continueHero,
          const HomeWidgetSize(4, 2),
        ),
      ),
      findsNothing,
    );
    expect(
      find.byKey(
        homeWidgetAddSizeKey(
          HomeWidgetKind.continueHero,
          const HomeWidgetSize(2, 3),
        ),
      ),
      findsOneWidget,
    );
  });

  testWidgets('选尺寸再添加：返回所选组件与尺寸（默认是第一档）', (WidgetTester tester) async {
    final List<HomeWidgetItem> added = await _pump(tester);
    await _activate(
      tester,
      find.descendant(
        of: find.byKey(homeWidgetAddButtonKey(HomeWidgetKind.week)),
        matching: find.text(t.home_widget_add_confirm),
      ),
    );
    expect(
      added.single,
      const HomeWidgetItem(HomeWidgetKind.week, HomeWidgetSize(2, 1)),
    );

    await _activate(
      tester,
      find.descendant(
        of: find.byKey(
          homeWidgetAddSizeKey(
            HomeWidgetKind.panorama,
            const HomeWidgetSize(4, 2),
          ),
        ),
        matching: find.text('4×2'),
      ),
    );
    await _activate(
      tester,
      find.descendant(
        of: find.byKey(homeWidgetAddButtonKey(HomeWidgetKind.panorama)),
        matching: find.text(t.home_widget_add_confirm),
      ),
    );
    expect(
      added.last,
      const HomeWidgetItem(HomeWidgetKind.panorama, HomeWidgetSize(4, 2)),
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
