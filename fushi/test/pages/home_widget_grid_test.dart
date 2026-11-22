// 首页小组件网格（HomeWidgetGrid，spec 2026-11-15）：装箱几何、编辑态的焦点驱动
// 操作（Enter 拿起 / 方向键移动 / Shift+方向键逐格改尺寸 / Delete 移除 / Esc 退出）、
// 手柄（GamepadButtonIntent：LB RB 改宽、LT RT 改高）、拖右下角改尺寸（吸附预览、
// 其余块让位、松手提交）、RTL 镜像。键盘 / 手柄部分全部经焦点驱动，不点坐标；拖角
// 是纯指针手势，按柄的 finder 拖。
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/home_widget_layout.dart';
import 'package:fushi/src/pages/implementations/home_widget_grid.dart';
import 'package:fushi/src/shortcuts/gamepad_service.dart'
    show GamepadButtonIntent;
import 'package:fushi/src/shortcuts/input_binding.dart' show GamepadButton;
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
        cellBuilder: (BuildContext context, HomeWidgetItem item) => ColoredBox(
          key: ValueKey<String>('cell/${item.slot}'),
          color: const Color(0xFF8899AA),
        ),
        labelOf: (HomeWidgetItem item) => item.slot,
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
        onResize: (int index, HomeWidgetSize size) {
          widget.log.add('size $index $size');
          setState(
            () => items = setHomeWidgetSize(items, index, widget.grid, size),
          );
        },
        onConfigure: (int index) {
          widget.log.add('configure $index');
          setState(() => items = setHomeWidgetLanguage(items, index, 'en'));
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
  List<HomeWidgetItem> items = _items,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Directionality(
        textDirection: direction,
        child: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: _Host(
              initial: items,
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

HomeWidgetSize _sizeOf(_HostState host, HomeWidgetKind kind) =>
    host.items.firstWhere((HomeWidgetItem e) => e.kind == kind).size;

Future<void> _key(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await tester.pumpAndSettle();
}

/// Shift+[key]（按住 Shift 再按方向键）。
Future<void> _shift(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyEvent(key);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  await tester.pumpAndSettle();
}

/// 走与手柄轮询同一条派发路径：从焦点节点上溯 [GamepadButtonIntent]。
Future<Object?> _pad(WidgetTester tester, GamepadButton button) async {
  final BuildContext focused = FocusManager.instance.primaryFocus!.context!;
  final Object? result = Actions.maybeInvoke<GamepadButtonIntent>(
    focused,
    GamepadButtonIntent(button),
  );
  await tester.pumpAndSettle();
  return result;
}

void main() {
  testWidgets('可重复的「语言目标」格：按语言各占一格，编辑态有配置角标 / 菜单键 / 手柄 Y', (
    WidgetTester tester,
  ) async {
    final List<String> log = <String>[];
    final _HostState host = await _pump(
      tester,
      log: log,
      items: const <HomeWidgetItem>[
        HomeWidgetItem(HomeWidgetKind.today, HomeWidgetSize(1, 1)),
        HomeWidgetItem(
          HomeWidgetKind.languageGoals,
          HomeWidgetSize(1, 1),
          language: 'ja',
        ),
        HomeWidgetItem(
          HomeWidgetKind.languageGoals,
          HomeWidgetSize(1, 1),
          language: 'ko',
        ),
      ],
    );
    expect(
      find.byKey(
        homeWidgetTileKey(HomeWidgetKind.languageGoals, language: 'ja'),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(
        homeWidgetTileKey(HomeWidgetKind.languageGoals, language: 'ko'),
      ),
      findsOneWidget,
    );
    // 只有可重复（可配置）的组件有配置角标。
    expect(
      find.byKey(const ValueKey<String>('home-widget-configure/today')),
      findsNothing,
    );
    await tester.tap(
      find.byKey(
        const ValueKey<String>('home-widget-configure/language_goals:ja'),
      ),
    );
    await tester.pumpAndSettle();
    expect(log, contains('configure 1'));
    expect(host.items[1].language, 'en');
    expect(host.items[1].slot, 'language_goals:en');
    expect(
      find.byKey(
        homeWidgetTileKey(HomeWidgetKind.languageGoals, language: 'en'),
      ),
      findsOneWidget,
    );

    // 键盘菜单键：焦点落在「语言目标」格上时改配置。
    for (int i = 0; i < 8; i++) {
      if (_focusedLabel() == 'home-widget/language_goals:ko') break;
      await _key(tester, LogicalKeyboardKey.tab);
    }
    expect(_focusedLabel(), 'home-widget/language_goals:ko');
    await _key(tester, LogicalKeyboardKey.contextMenu);
    expect(log, contains('configure 2'));
    // 换成的语言已经有格子了：不变（一种语言只占一格）。
    expect(host.items[2].language, 'ko');

    // 「今日」格上菜单键 / 手柄 Y 不改配置。
    log.clear();
    for (int i = 0; i < 8; i++) {
      if (_focusedLabel() == 'home-widget/today') break;
      await _key(tester, LogicalKeyboardKey.tab);
    }
    expect(_focusedLabel(), 'home-widget/today');
    await _key(tester, LogicalKeyboardKey.contextMenu);
    await _pad(tester, GamepadButton.y);
    expect(log.where((String e) => e.startsWith('configure')), isEmpty);
  });

  testWidgets('装箱几何：窄网格两列、按行高与间距排位', (WidgetTester tester) async {
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
    // 内容拿到的就是格子的紧约束（按实际宽高排版）。
    expect(
      tester.getSize(find.byKey(const ValueKey<String>('cell/today'))),
      today.size,
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
    expect(
      find.byKey(const ValueKey<String>('home-widget-resize/today')),
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
    // 每种组件都有可调范围，都有右下角改尺寸柄。
    for (final HomeWidgetItem e in _items) {
      expect(
        find.byKey(ValueKey<String>('home-widget-resize/${e.kind.id}')),
        findsOneWidget,
      );
    }

    await _key(tester, LogicalKeyboardKey.tab);
    expect(_focusedLabel(), 'home-widget/continue');
    await _key(tester, LogicalKeyboardKey.tab);
    expect(_focusedLabel(), 'home-widget/today');

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

  testWidgets('Shift+方向键逐格改宽 / 高，到范围边界停住；其余块按装箱让位', (
    WidgetTester tester,
  ) async {
    final List<String> log = <String>[];
    final _HostState host = await _pump(tester, log: log);
    await _key(tester, LogicalKeyboardKey.tab);
    await _key(tester, LogicalKeyboardKey.tab);
    expect(_focusedLabel(), 'home-widget/today');
    final double weekTop = tester.getRect(_tile(HomeWidgetKind.week)).top;

    // 今日 1×1 → 2×1（变宽把复习挤到下一行）。
    await _shift(tester, LogicalKeyboardKey.arrowRight);
    expect(_sizeOf(host, HomeWidgetKind.today), const HomeWidgetSize(2, 1));
    expect(
      tester.getRect(_tile(HomeWidgetKind.srsReview)).top,
      greaterThan(tester.getRect(_tile(HomeWidgetKind.today)).top),
    );
    // 窄网格 2 列已是上限：再加宽不变、不记操作。
    final int logged = log.length;
    await _shift(tester, LogicalKeyboardKey.arrowRight);
    expect(_sizeOf(host, HomeWidgetKind.today), const HomeWidgetSize(2, 1));
    expect(log.length, logged);

    // 变高 → 2×2，下面的块往下让。
    await _shift(tester, LogicalKeyboardKey.arrowDown);
    expect(_sizeOf(host, HomeWidgetKind.today), const HomeWidgetSize(2, 2));
    expect(
      tester.getRect(_tile(HomeWidgetKind.week)).top,
      greaterThan(weekTop),
    );
    // 今日最高 2 行。
    await _shift(tester, LogicalKeyboardKey.arrowDown);
    expect(_sizeOf(host, HomeWidgetKind.today), const HomeWidgetSize(2, 2));

    await _shift(tester, LogicalKeyboardKey.arrowUp);
    await _shift(tester, LogicalKeyboardKey.arrowLeft);
    expect(_sizeOf(host, HomeWidgetKind.today), const HomeWidgetSize(1, 1));
    // 下限 1×1 再缩不变。
    await _shift(tester, LogicalKeyboardKey.arrowLeft);
    expect(_sizeOf(host, HomeWidgetKind.today), const HomeWidgetSize(1, 1));
    // 改尺寸后焦点留在这块上；没拿起，所以顺序没变。
    expect(_focusedLabel(), 'home-widget/today');
    expect(_order(host)[1], HomeWidgetKind.today);
    expect(
      log,
      containsAllInOrder(<String>[
        'size 1 2×1',
        'size 1 2×2',
        'size 1 2×1',
        'size 1 1×1',
      ]),
    );
  });

  testWidgets('手柄：LB / RB 改宽、LT / RT 改高，A 拿起、X 移除；不认的键交还祖先', (
    WidgetTester tester,
  ) async {
    final _HostState host = await _pump(tester);
    await _key(tester, LogicalKeyboardKey.tab);
    await _key(tester, LogicalKeyboardKey.tab);
    expect(_focusedLabel(), 'home-widget/today');

    expect(await _pad(tester, GamepadButton.rb), isTrue);
    expect(_sizeOf(host, HomeWidgetKind.today), const HomeWidgetSize(2, 1));
    expect(await _pad(tester, GamepadButton.rt), isTrue);
    expect(_sizeOf(host, HomeWidgetKind.today), const HomeWidgetSize(2, 2));
    expect(await _pad(tester, GamepadButton.lt), isTrue);
    expect(_sizeOf(host, HomeWidgetKind.today), const HomeWidgetSize(2, 1));
    expect(await _pad(tester, GamepadButton.lb), isTrue);
    expect(_sizeOf(host, HomeWidgetKind.today), const HomeWidgetSize(1, 1));

    // Y 不归网格：转发给祖先（这里没有祖先处理 → null）。
    expect(await _pad(tester, GamepadButton.y), isNull);
    // 没拿起时十字键交还祖先（焦点导航兜底）。
    expect(await _pad(tester, GamepadButton.dpadRight), isNull);

    // A 拿起后十字键移动。
    expect(await _pad(tester, GamepadButton.a), isTrue);
    expect(await _pad(tester, GamepadButton.dpadRight), isTrue);
    expect(_order(host)[2], HomeWidgetKind.today);
    expect(await _pad(tester, GamepadButton.a), isTrue);

    expect(await _pad(tester, GamepadButton.x), isTrue);
    expect(_tile(HomeWidgetKind.today), findsNothing);
  });

  testWidgets('非编辑态：手柄键全部交还祖先（首页 LT/RT 换 tab 不被吞）', (
    WidgetTester tester,
  ) async {
    await _pump(tester, editing: false);
    // 非编辑态块不可聚焦：直接从块的上下文上溯。
    final BuildContext tile = tester.element(
      find.byKey(const ValueKey<String>('cell/today')),
    );
    expect(
      Actions.maybeInvoke<GamepadButtonIntent>(
        tile,
        const GamepadButtonIntent(GamepadButton.rt),
      ),
      isNull,
    );
  });

  testWidgets('拖右下角：按格吸附、实时预览「2×2」、其余块让位，松手提交', (WidgetTester tester) async {
    final List<String> log = <String>[];
    final _HostState host = await _pump(tester, log: log);
    const double gap = kFushiCoverBlockSpacing;
    final double row = homeWidgetRowExtent(HomeGridKind.compact, _kWidth, gap);
    final Finder handle = find.byKey(
      const ValueKey<String>('home-widget-resize/today'),
    );
    final double weekTop = tester.getRect(_tile(HomeWidgetKind.week)).top;

    final TestGesture g = await tester.startGesture(tester.getCenter(handle));
    await g.moveBy(const Offset(0, 30));
    await g.moveBy(Offset(0, row + gap - 30 + 8));
    await tester.pumpAndSettle();
    // 拖动中：预览框 + 标签，今日格子已按目标尺寸装箱，近 7 天往下让。
    expect(
      find.byKey(const ValueKey<String>('home-widget-resize-preview')),
      findsOneWidget,
    );
    expect(
      tester
          .widget<Text>(
            find.byKey(const ValueKey<String>('home-widget-resize-label')),
          )
          .data,
      '1×2',
    );
    expect(
      tester.getRect(_tile(HomeWidgetKind.week)).top,
      greaterThan(weekTop),
    );
    expect(log, isNot(contains(startsWith('size'))), reason: '松手前不提交');

    await g.moveBy(Offset((_kWidth - gap) / 2 + gap, 0));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<Text>(
            find.byKey(const ValueKey<String>('home-widget-resize-label')),
          )
          .data,
      '2×2',
    );
    await g.up();
    await tester.pumpAndSettle();
    expect(_sizeOf(host, HomeWidgetKind.today), const HomeWidgetSize(2, 2));
    expect(log.where((String l) => l.startsWith('size')), <String>[
      'size 1 2×2',
    ]);
    expect(
      find.byKey(const ValueKey<String>('home-widget-resize-preview')),
      findsNothing,
    );
    // 拖柄不触发换位。
    expect(_order(host), _items.map((HomeWidgetItem e) => e.kind).toList());
  });

  testWidgets('拖角拖过头钳在范围里；拖回原尺寸松手不记操作', (WidgetTester tester) async {
    final List<String> log = <String>[];
    final _HostState host = await _pump(tester, log: log);
    final Finder handle = find.byKey(
      const ValueKey<String>('home-widget-resize/week'),
    );
    final TestGesture g = await tester.startGesture(tester.getCenter(handle));
    await g.moveBy(const Offset(0, 40));
    await g.moveBy(const Offset(400, 2000));
    await tester.pumpAndSettle();
    // 近 7 天窄网格上限 2×3。
    expect(
      tester
          .widget<Text>(
            find.byKey(const ValueKey<String>('home-widget-resize-label')),
          )
          .data,
      '2×3',
    );
    await g.moveBy(const Offset(-400, -2040));
    await tester.pumpAndSettle();
    await g.up();
    await tester.pumpAndSettle();
    expect(_sizeOf(host, HomeWidgetKind.week), const HomeWidgetSize(2, 1));
    expect(log.where((String l) => l.startsWith('size')), isEmpty);
  });

  testWidgets('半栏：Shift+← 与拖角都能把近 7 天缩到 1 列，旁边空出的半格可回填', (
    WidgetTester tester,
  ) async {
    final List<String> log = <String>[];
    final _HostState host = await _pump(tester, log: log);
    // 焦点走到近 7 天（第 4 块）。
    for (int i = 0; i < 4; i++) {
      await _key(tester, LogicalKeyboardKey.tab);
    }
    expect(_focusedLabel(), 'home-widget/week');
    await _shift(tester, LogicalKeyboardKey.arrowLeft);
    expect(_sizeOf(host, HomeWidgetKind.week), const HomeWidgetSize(1, 1));
    expect(
      tester.getSize(_tile(HomeWidgetKind.week)).width,
      closeTo((_kWidth - kFushiCoverBlockSpacing) / 2, 0.01),
    );
    // 1×1 是下限。
    await _shift(tester, LogicalKeyboardKey.arrowLeft);
    expect(_sizeOf(host, HomeWidgetKind.week), const HomeWidgetSize(1, 1));
    // 放回 2×1，再用拖角缩回半栏。
    await _shift(tester, LogicalKeyboardKey.arrowRight);
    expect(_sizeOf(host, HomeWidgetKind.week), const HomeWidgetSize(2, 1));
    final Finder handle = find.byKey(
      const ValueKey<String>('home-widget-resize/week'),
    );
    final TestGesture g = await tester.startGesture(tester.getCenter(handle));
    await g.moveBy(const Offset(-30, 0));
    await g.moveBy(
      const Offset(
        -(_kWidth - kFushiCoverBlockSpacing) / 2 - kFushiCoverBlockSpacing + 30,
        0,
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<Text>(
            find.byKey(const ValueKey<String>('home-widget-resize-label')),
          )
          .data,
      '1×1',
    );
    await g.up();
    await tester.pumpAndSettle();
    expect(_sizeOf(host, HomeWidgetKind.week), const HomeWidgetSize(1, 1));
    expect(log.last, 'size 3 1×1');
  });

  testWidgets('编辑态：Delete 移除后焦点交给下一块，Esc 退出编辑', (WidgetTester tester) async {
    final List<String> log = <String>[];
    final _HostState host = await _pump(tester, log: log);
    await _key(tester, LogicalKeyboardKey.tab);
    expect(_focusedLabel(), 'home-widget/continue');

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

  testWidgets('RTL：起始侧在右，方向键按视觉方向移动、Shift+← 加宽', (WidgetTester tester) async {
    final _HostState host = await _pump(tester, direction: TextDirection.rtl);
    final Rect today = tester.getRect(_tile(HomeWidgetKind.today));
    final Rect srs = tester.getRect(_tile(HomeWidgetKind.srsReview));
    expect(today.left, greaterThan(srs.left), reason: '第一列在右侧');

    await _key(tester, LogicalKeyboardKey.tab);
    await _key(tester, LogicalKeyboardKey.tab);
    expect(_focusedLabel(), 'home-widget/today');
    // 视觉上往左 = 朝结束侧 = 加宽。
    await _shift(tester, LogicalKeyboardKey.arrowLeft);
    expect(_sizeOf(host, HomeWidgetKind.today), const HomeWidgetSize(2, 1));
    await _shift(tester, LogicalKeyboardKey.arrowRight);
    expect(_sizeOf(host, HomeWidgetKind.today), const HomeWidgetSize(1, 1));

    await _key(tester, LogicalKeyboardKey.enter);
    // 视觉上往左 = 列表里往后。
    await _key(tester, LogicalKeyboardKey.arrowLeft);
    expect(_order(host)[2], HomeWidgetKind.today);
  });
}
