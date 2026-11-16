// 首页小组件的尺寸选择网格（spec 2026-11-15「改尺寸」）：画出当前网格允许的最大
// 范围、打开时焦点在当前尺寸那格、方向键移焦时标签实时跟随、Enter 选定；低于下限的
// 格子选中时钳到下限。全部经焦点 + 按键驱动。
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/home_widget_layout.dart';
import 'package:fushi/src/pages/implementations/home_widget_size_picker.dart';
import 'package:material_ui/material_ui.dart';

Future<List<HomeWidgetSize>> _pump(
  WidgetTester tester, {
  required HomeWidgetKind kind,
  required HomeGridKind grid,
  required HomeWidgetSize current,
}) async {
  final List<HomeWidgetSize> picked = <HomeWidgetSize>[];
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: HomeWidgetSizePicker(
            kind: kind,
            grid: grid,
            current: current,
            onSelected: picked.add,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return picked;
}

String? _label(WidgetTester tester) => tester
    .widget<Text>(
      find.byKey(const ValueKey<String>('home-widget-size-picker-label')),
    )
    .data;

Future<void> _key(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await tester.pumpAndSettle();
}

bool _focused(WidgetTester tester, HomeWidgetSize size) => Focus.of(
  tester.element(
    find.descendant(
      of: find.byKey(homeWidgetSizeCellKey(size)),
      matching: find.byType(AnimatedContainer),
    ),
  ),
).hasPrimaryFocus;

void main() {
  testWidgets('宽网格：画出 6×3 的格子，焦点在当前尺寸，方向键移焦标签跟随，Enter 选定', (
    WidgetTester tester,
  ) async {
    final List<HomeWidgetSize> picked = await _pump(
      tester,
      kind: HomeWidgetKind.week,
      grid: HomeGridKind.wide,
      current: const HomeWidgetSize(2, 2),
    );
    // 近 7 天上限 6×3：6 列 3 行全画出来，没有第 4 行 / 第 7 列。
    expect(
      find.byKey(homeWidgetSizeCellKey(const HomeWidgetSize(6, 3))),
      findsOneWidget,
    );
    expect(
      find.byKey(homeWidgetSizeCellKey(const HomeWidgetSize(1, 4))),
      findsNothing,
    );
    expect(
      find.byKey(homeWidgetSizeCellKey(const HomeWidgetSize(7, 1))),
      findsNothing,
    );
    expect(_focused(tester, const HomeWidgetSize(2, 2)), isTrue);
    expect(_label(tester), '2×2');
    expect(
      find.text(t.home_widget_size_range(min: '1×1', max: '6×3')),
      findsOneWidget,
    );

    await _key(tester, LogicalKeyboardKey.arrowRight);
    expect(_focused(tester, const HomeWidgetSize(3, 2)), isTrue);
    expect(_label(tester), '3×2');
    await _key(tester, LogicalKeyboardKey.arrowRight);
    await _key(tester, LogicalKeyboardKey.arrowDown);
    expect(_label(tester), '4×3');
    expect(picked, isEmpty, reason: '移焦不选定');

    await _key(tester, LogicalKeyboardKey.enter);
    expect(picked, <HomeWidgetSize>[const HomeWidgetSize(4, 3)]);
  });

  testWidgets('低于下限的格子：标签显示钳后的尺寸，选定钳到下限', (WidgetTester tester) async {
    final List<HomeWidgetSize> picked = await _pump(
      tester,
      kind: HomeWidgetKind.recentlyAdded,
      grid: HomeGridKind.wide,
      current: const HomeWidgetSize(1, 2),
    );
    await _key(tester, LogicalKeyboardKey.arrowUp);
    expect(_focused(tester, const HomeWidgetSize(1, 1)), isTrue);
    expect(_label(tester), '1×2');
    await _key(tester, LogicalKeyboardKey.enter);
    expect(picked, <HomeWidgetSize>[const HomeWidgetSize(1, 2)]);
  });

  testWidgets('半栏：近 7 天能在网格里选到 1×1', (WidgetTester tester) async {
    final List<HomeWidgetSize> picked = await _pump(
      tester,
      kind: HomeWidgetKind.week,
      grid: HomeGridKind.compact,
      current: const HomeWidgetSize(2, 1),
    );
    await _key(tester, LogicalKeyboardKey.arrowLeft);
    expect(_label(tester), '1×1');
    await _key(tester, LogicalKeyboardKey.enter);
    expect(picked, <HomeWidgetSize>[const HomeWidgetSize(1, 1)]);
  });

  testWidgets('窄网格只画到 2 列；当前尺寸超出范围时焦点落在钳后的格子', (WidgetTester tester) async {
    final List<HomeWidgetSize> picked = await _pump(
      tester,
      kind: HomeWidgetKind.continueHero,
      grid: HomeGridKind.compact,
      current: const HomeWidgetSize(4, 2),
    );
    expect(
      find.byKey(homeWidgetSizeCellKey(const HomeWidgetSize(3, 1))),
      findsNothing,
    );
    expect(
      find.byKey(homeWidgetSizeCellKey(const HomeWidgetSize(2, 4))),
      findsOneWidget,
    );
    expect(_focused(tester, const HomeWidgetSize(2, 2)), isTrue);
    await _key(tester, LogicalKeyboardKey.arrowDown);
    await _key(tester, LogicalKeyboardKey.arrowDown);
    expect(_label(tester), '2×4');
    await _key(tester, LogicalKeyboardKey.space);
    expect(picked, <HomeWidgetSize>[const HomeWidgetSize(2, 4)]);
  });
}
