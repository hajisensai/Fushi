// 首页小组件网格（HomeWidgetGrid，spec 2026-11-15）：装箱几何、编辑态的焦点驱动
// 操作（Enter 拿起 / 方向键移动 / [ ] 换尺寸 / Delete 移除 / Esc 退出）、RTL 镜像。
// 全部经焦点与按键驱动，不点坐标。
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/home_widget_layout.dart';
import 'package:fushi/src/pages/implementations/home_widget_grid.dart';
import 'package:fushi/src/utils/components/fushi_cover_block_layout.dart'
    show kFushiCoverBlockSpacing;
import 'package:material_ui/material_ui.dart';

const double _kWidth = 400;

/// 持有列表、把网格回调落成真实编辑操作的宿主（与首页同一组纯函数）。
class _Host extends StatefulWidget {
  const _Host({
    required this.initial,
    required this.grid,
    required this.editing,
    required this.log,
  });

  final List<HomeWidgetItem> initial;
  final HomeGridKind grid;
  final bool editing;
  final List<String> log;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  late List<HomeWidgetItem> items = widget.initial;
  late bool editing = widget.editing;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    child: SizedBox(
      width: _kWidth,
      child: HomeWidgetGrid(
        items: items,
        grid: widget.grid,
        editing: editing,
        cellBuilder: (BuildContext context, HomeWidgetItem item, bool dense) =>
            ColoredBox(
              key: ValueKey<String>('cell/${item.kind.id}/$dense'),
              color: const Color(0xFF8899AA),
            ),
        labelOf: (HomeWidgetKind kind) => kind.id,
        onEnterEdit: () {
          widget.log.add('enter');
          setState(() => editing = true);
        },
        onExitEdit: () {
          widget.log.add('exit');
          setState(() => editing = false);
        },
        onMove: (int from, int to) {
          widget.log.add('move $from>$to');
          setState(() => items = moveHomeWidget(items, from, to));
        },
        onRemove: (int index) {
          widget.log.add('remove $index');
          setState(() => items = removeHomeWidgetAt(items, index));
        },
        onCycleSize: (int index, int step) {
          widget.log.add('size $index $step');
          setState(
            () => items = cycleHomeWidgetSize(
              items,
              index,
              widget.grid,
              step: step,
            ),
          );
        },
      ),
    ),
  );
}

const List<HomeWidgetItem> _items = <HomeWidgetItem>[
  HomeWidgetItem(HomeWidgetKind.continueHero, HomeWidgetSize(2, 2)),
  HomeWidgetItem(HomeWidgetKind.today, HomeWidgetSize(1, 1)),
  HomeWidgetItem(HomeWidgetKind.srsReview, HomeWidgetSize(1, 1)),
  HomeWidgetItem(HomeWidgetKind.week, HomeWidgetSize(2, 1)),
];

Future<_HostState> _pump(
  WidgetTester tester, {
  bool editing = true,
  TextDirection direction = TextDirection.ltr,
  List<String>? log,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Directionality(
        textDirection: direction,
        child: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: _Host(
              initial: _items,
              grid: HomeGridKind.compact,
              editing: editing,
              log: log ?? <String>[],
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return tester.state<_HostState>(find.byType(_Host));
}

Finder _tile(HomeWidgetKind kind) => find.byKey(homeWidgetTileKey(kind));

String? _focusedLabel() => FocusManager.instance.primaryFocus?.debugLabel;

List<HomeWidgetKind> _order(_HostState host) => <HomeWidgetKind>[
  for (final HomeWidgetItem e in host.items) e.kind,
];

Future<void> _key(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('装箱几何：窄网格两列、按行高与间距排位，一行高的格子是 dense', (WidgetTester tester) async {
    await _pump(tester, editing: false);
    const double gap = kFushiCoverBlockSpacing;
    final double row = homeWidgetRowExtent(HomeGridKind.compact, _kWidth, gap);
    const double col = (_kWidth - gap) / 2;
    final Rect hero = tester.getRect(_tile(HomeWidgetKind.continueHero));
    final Rect today = tester.getRect(_tile(HomeWidgetKind.today));
    final Rect srs = tester.getRect(_tile(HomeWidgetKind.srsReview));
    final Rect week = tester.getRect(_tile(HomeWidgetKind.week));
    expect(hero.size, Size(_kWidth, row * 2 + gap));
    expect(
      today.topLeft.dy - hero.topLeft.dy,
      closeTo(row * 2 + gap * 2, 0.01),
    );
    expect(today.width, closeTo(col, 0.01));
    expect(srs.left - today.left, closeTo(col + gap, 0.01));
    expect(week.top - today.top, closeTo(row + gap, 0.01));
    expect(
      find.byKey(const ValueKey<String>('cell/today/true')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('cell/continue/false')),
      findsOneWidget,
    );
  });

  testWidgets('非编辑态：块不进焦点遍历、没有编辑角标', (WidgetTester tester) async {
    await _pump(tester, editing: false);
    await _key(tester, LogicalKeyboardKey.tab);
    expect(_focusedLabel() ?? '', isNot(startsWith('home-widget/')));
    expect(
      find.byKey(const ValueKey<String>('home-widget-remove/today')),
      findsNothing,
    );
  });

  testWidgets('编辑态：Tab 走到块；Enter 拿起、方向键移动、再 Enter 放下', (
    WidgetTester tester,
  ) async {
    final List<String> log = <String>[];
    final _HostState host = await _pump(tester, log: log);
    expect(
      find.byKey(const ValueKey<String>('home-widget-remove/today')),
      findsOneWidget,
    );
    // 只有一档的组件没有换尺寸角标（这里四种都有多档）。
    expect(
      find.byKey(const ValueKey<String>('home-widget-resize/week')),
      findsOneWidget,
    );

    await _key(tester, LogicalKeyboardKey.tab);
    expect(_focusedLabel(), 'home-widget/continue');
    await _key(tester, LogicalKeyboardKey.tab);
    expect(_focusedLabel(), 'home-widget/today');

    // 没拿起时方向键不移动（交给焦点遍历）。
    await _key(tester, LogicalKeyboardKey.enter);
    await _key(tester, LogicalKeyboardKey.arrowRight);
    expect(_order(host), <HomeWidgetKind>[
      HomeWidgetKind.continueHero,
      HomeWidgetKind.srsReview,
      HomeWidgetKind.today,
      HomeWidgetKind.week,
    ]);
    // 拿着时焦点不跑。
    expect(_focusedLabel(), 'home-widget/today');
    await _key(tester, LogicalKeyboardKey.arrowUp);
    expect(_order(host).first, HomeWidgetKind.today);
    await _key(tester, LogicalKeyboardKey.enter);
    await _key(tester, LogicalKeyboardKey.arrowRight);
    expect(_order(host).first, HomeWidgetKind.today, reason: '放下后不再移动');
    expect(log, containsAllInOrder(<String>['move 1>2', 'move 2>0']));
  });

  testWidgets('编辑态：[ ] 换尺寸，Delete 移除后焦点交给下一块，Esc 退出编辑', (
    WidgetTester tester,
  ) async {
    final List<String> log = <String>[];
    final _HostState host = await _pump(tester, log: log);
    await _key(tester, LogicalKeyboardKey.tab);
    expect(_focusedLabel(), 'home-widget/continue');

    final double before = tester
        .getSize(_tile(HomeWidgetKind.continueHero))
        .height;
    await _key(tester, LogicalKeyboardKey.bracketRight);
    expect(host.items.first.size, const HomeWidgetSize(2, 3));
    expect(
      tester.getSize(_tile(HomeWidgetKind.continueHero)).height,
      greaterThan(before),
    );
    await _key(tester, LogicalKeyboardKey.bracketLeft);
    expect(host.items.first.size, const HomeWidgetSize(2, 2));

    await _key(tester, LogicalKeyboardKey.delete);
    expect(_order(host), <HomeWidgetKind>[
      HomeWidgetKind.today,
      HomeWidgetKind.srsReview,
      HomeWidgetKind.week,
    ]);
    expect(_tile(HomeWidgetKind.continueHero), findsNothing);
    expect(_focusedLabel(), 'home-widget/today');

    await _key(tester, LogicalKeyboardKey.escape);
    expect(log.last, 'exit');
    expect(host.editing, isFalse);
    expect(
      find.byKey(const ValueKey<String>('home-widget-remove/today')),
      findsNothing,
    );
  });

  testWidgets('Esc 先放下拿着的块，再按一次才退出编辑', (WidgetTester tester) async {
    final List<String> log = <String>[];
    final _HostState host = await _pump(tester, log: log);
    await _key(tester, LogicalKeyboardKey.tab);
    await _key(tester, LogicalKeyboardKey.enter);
    await _key(tester, LogicalKeyboardKey.escape);
    expect(host.editing, isTrue);
    expect(log, isNot(contains('exit')));
    await _key(tester, LogicalKeyboardKey.escape);
    expect(log.last, 'exit');
  });

  testWidgets('RTL：起始侧在右，方向键按视觉方向移动', (WidgetTester tester) async {
    final _HostState host = await _pump(tester, direction: TextDirection.rtl);
    final Rect today = tester.getRect(_tile(HomeWidgetKind.today));
    final Rect srs = tester.getRect(_tile(HomeWidgetKind.srsReview));
    expect(today.left, greaterThan(srs.left), reason: '第一列在右侧');

    await _key(tester, LogicalKeyboardKey.tab);
    await _key(tester, LogicalKeyboardKey.tab);
    expect(_focusedLabel(), 'home-widget/today');
    await _key(tester, LogicalKeyboardKey.enter);
    // 视觉上往左 = 列表里往后。
    await _key(tester, LogicalKeyboardKey.arrowLeft);
    expect(_order(host)[2], HomeWidgetKind.today);
  });
}
