import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart'
    show kFushiFloatingTopBarOverflowHysteresis;
import 'package:fushi/utils.dart';
import 'package:material_ui/material_ui.dart';

/// 页头 / 顶栏动作的统一自适应收纳（[fushiResolveHeaderActions]）：
///
/// * 按该行**实际约束宽**逐级降级：药丸 → 纯图标 → 从最低优先级起逐颗收进 ⋯；
/// * ⋯ 只在至少收进一颗时出现，且它自身宽度计入判定；
/// * [FushiIconButton.alwaysVisible] / 选中态的动作永不收；
/// * ⋯ 菜单项由被收动作派生、共用原 onTap、禁用态同步置灰；
/// * 焦点顺序：外露动作在前、⋯ 最后，Tab 能到 ⋯、Enter 打开菜单。
void main() {
  // 5 个动作：A（默认 0）、B（优先级 2，最重要）、C（永不收）、D（默认 0）、
  // E（优先级 -1，最先收）。期望收纳顺序：E → D → A → B（C 永不收）。
  const List<IconData> icons = <IconData>[
    Icons.looks_one_outlined,
    Icons.looks_two_outlined,
    Icons.looks_3_outlined,
    Icons.looks_4_outlined,
    Icons.looks_5_outlined,
  ];
  const List<String> names = <String>['A', 'B', 'C', 'D', 'E'];

  List<Widget> buildActions(
    List<String> tapped, {
    bool disableD = false,
  }) => <Widget>[
    FushiIconButton(icon: icons[0], tooltip: 'A', onTap: () => tapped.add('A')),
    FushiIconButton(
      icon: icons[1],
      tooltip: 'B',
      overflowPriority: 2,
      onTap: () => tapped.add('B'),
    ),
    FushiIconButton(
      icon: icons[2],
      tooltip: 'C',
      alwaysVisible: true,
      onTap: () => tapped.add('C'),
    ),
    FushiIconButton(
      icon: icons[3],
      tooltip: 'D',
      enabled: !disableD,
      onTap: () => tapped.add('D'),
    ),
    FushiIconButton(
      icon: icons[4],
      tooltip: 'E',
      overflowPriority: -1,
      onTap: () => tapped.add('E'),
    ),
  ];

  Widget host({required double width, required List<Widget> actions}) {
    return MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: width,
            child: FushiPageHeader(title: '标题', actions: actions),
          ),
        ),
      ),
    );
  }

  Set<String> visibleNames() => <String>{
    for (int i = 0; i < icons.length; i++)
      if (find.byIcon(icons[i]).evaluate().isNotEmpty) names[i],
  };

  bool hasOverflow() =>
      find.byKey(kFushiHeaderOverflowMenuKey).evaluate().isNotEmpty;

  group('纯函数', () {
    test('收纳顺序：低优先级先收，同优先级越靠后越先收，永不收 / 选中 / 无回调不参与', () {
      final List<Widget> actions = <Widget>[
        ...buildActions(<String>[]),
        FushiIconButton(
          icon: Icons.check_box_outlined,
          tooltip: 'selected',
          selected: true,
          onTap: () {},
        ),
        const FushiIconButton(icon: Icons.info_outline, tooltip: 'deco'),
        const SizedBox(width: 48),
      ];
      expect(fushiHeaderCollapseOrder(actions), <int>[4, 3, 0, 1]);
    });

    test('收纳颗数：取放得下的最小值；全收仍放不下但更窄就全收，否则不收', () {
      double widthWith(int k) => <double>[200, 170, 140, 110][k];
      expect(
        fushiHeaderCollapseCount(
          collapsible: 3,
          widthWith: widthWith,
          budget: 500,
        ),
        0,
      );
      expect(
        fushiHeaderCollapseCount(
          collapsible: 3,
          widthWith: widthWith,
          budget: 150,
        ),
        2,
      );
      expect(
        fushiHeaderCollapseCount(
          collapsible: 3,
          widthWith: widthWith,
          budget: 50,
        ),
        3,
      );
      // 只有一颗可收：收了换成等宽的 ⋯，省不出宽度 → 不收。
      expect(
        fushiHeaderCollapseCount(
          collapsible: 1,
          widthWith: (int k) => 100,
          budget: 50,
        ),
        0,
      );
    });

    test('回差：展开方向要多出回差宽度才放出来', () {
      final FushiHeaderOverflowFit fit = FushiHeaderOverflowFit();
      double widthWith(int k) => <double>[200, 170, 140][k];
      expect(
        fit.collapsedFor(
          collapsible: 2,
          widthWith: widthWith,
          budget: 150,
          signature: 1,
        ),
        2,
      );
      // 刚好放得下 k=1（170），但没多出回差 → 维持 2。
      expect(
        fit.collapsedFor(
          collapsible: 2,
          widthWith: widthWith,
          budget: 175,
          signature: 1,
        ),
        2,
      );
      expect(
        fit.collapsedFor(
          collapsible: 2,
          widthWith: widthWith,
          budget: 170 + kFushiFloatingTopBarOverflowHysteresis,
          signature: 1,
        ),
        1,
      );
      // 动作集合变了：参照作废，直接取当场结果。
      expect(
        fit.collapsedFor(
          collapsible: 2,
          widthWith: widthWith,
          budget: 500,
          signature: 2,
        ),
        0,
      );
    });
  });

  testWidgets('逐档缩小行宽：外露数单调递减、按优先级从低到高逐颗进 ⋯', (WidgetTester tester) async {
    final List<Set<String>> history = <Set<String>>[];
    final List<bool> overflowHistory = <bool>[];
    for (double width = 800; width >= 160; width -= 8) {
      await tester.pumpWidget(
        host(width: width, actions: buildActions(<String>[])),
      );
      await tester.pump();
      expect(tester.takeException(), isNull, reason: 'width=$width');
      history.add(visibleNames());
      overflowHistory.add(hasOverflow());
    }

    expect(history.first, names.toSet(), reason: '宽到全放得下时一个不收');
    expect(overflowHistory.first, isFalse, reason: '一个都没收时不画 ⋯');
    expect(history.last, <String>{'C'}, reason: '极窄时只剩永不收纳的 C');

    // 期望收纳顺序；一档里可能同时收进几颗（收 1 颗换成等宽的 ⋯ 省不出宽度，
    // 首次收纳至少 2 颗），但每档收走的必须恰好是顺序里接下来的那几颗。
    const List<String> expectedOrder = <String>['E', 'D', 'A', 'B'];
    int next = 0;
    for (int i = 0; i < history.length; i++) {
      expect(history[i], contains('C'), reason: '永不收纳项始终外露');
      expect(
        overflowHistory[i],
        history[i].length < names.length,
        reason: '⋯ 仅在至少收进一颗时出现（第 $i 档）',
      );
      if (i == 0) continue;
      expect(
        history[i].length <= history[i - 1].length,
        isTrue,
        reason: '外露动作数随行宽单调递减（第 $i 档）',
      );
      expect(
        history[i - 1].containsAll(history[i]),
        isTrue,
        reason: '缩窄时只收不放（第 $i 档）',
      );
      final Set<String> gone = history[i - 1].difference(history[i]);
      if (gone.isEmpty) continue;
      expect(
        gone,
        expectedOrder.sublist(next, next + gone.length).toSet(),
        reason:
            '从最低优先级起逐颗收：E(-1) → D(0,靠后) → A(0) → B(2)'
            '（第 $i 档收走 $gone）',
      );
      next += gone.length;
    }
    expect(next, expectedOrder.length, reason: '可收纳的四颗最终都收进了 ⋯');
    // 逐颗：存在「只收了一部分」的中间档。
    expect(
      history.any((Set<String> v) => v.length > 1 && v.length < names.length),
      isTrue,
      reason: '不是一次全收',
    );
  });

  testWidgets('⋯ 菜单项点击触发原回调，禁用动作在菜单里置灰', (WidgetTester tester) async {
    final List<String> tapped = <String>[];
    await tester.pumpWidget(
      host(width: 200, actions: buildActions(tapped, disableD: true)),
    );
    await tester.pump();
    expect(hasOverflow(), isTrue);

    await tester.tap(find.byKey(kFushiHeaderOverflowMenuKey));
    await tester.pumpAndSettle();
    final PopupMenuItem<FushiIconButton> disabled = tester
        .widget<PopupMenuItem<FushiIconButton>>(
          find.ancestor(
            of: find.text('D'),
            matching: find.byType(PopupMenuItem<FushiIconButton>),
          ),
        );
    expect(disabled.enabled, isFalse, reason: '禁用态同步置灰');

    await tester.tap(find.text('E'));
    await tester.pumpAndSettle();
    expect(tapped, <String>['E'], reason: '菜单项共用被收动作的 onTap');
  });

  testWidgets('焦点：外露动作在前、⋯ 最后；Tab 能到 ⋯，Enter 打开菜单', (
    WidgetTester tester,
  ) async {
    final List<String> tapped = <String>[];
    await tester.pumpWidget(host(width: 260, actions: buildActions(tapped)));
    await tester.pump();
    expect(hasOverflow(), isTrue);
    final Set<String> shown = visibleNames();
    expect(shown.length, inInclusiveRange(1, 4));

    final Element overflow = tester.element(
      find.byKey(kFushiHeaderOverflowMenuKey),
    );
    bool focusIn(Element root) {
      final BuildContext? focused = FocusManager.instance.primaryFocus?.context;
      if (focused == null) return false;
      bool inside = identical(focused, root);
      (focused as Element).visitAncestorElements((Element e) {
        if (identical(e, root)) inside = true;
        return !inside;
      });
      return inside;
    }

    String? focusedName() {
      for (int i = 0; i < icons.length; i++) {
        final Finder f = find.byIcon(icons[i]);
        if (f.evaluate().isEmpty) continue;
        final Element iconElement = tester.element(f);
        Element? button;
        iconElement.visitAncestorElements((Element e) {
          if (e.widget is FushiIconButton) {
            button = e;
            return false;
          }
          return true;
        });
        if (button != null && focusIn(button!)) return names[i];
      }
      return null;
    }

    final List<String> order = <String>[];
    bool reached = false;
    for (int step = 0; step < 12 && !reached; step++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      if (focusIn(overflow)) {
        reached = true;
        break;
      }
      final String? name = focusedName();
      if (name != null && !order.contains(name)) order.add(name);
    }
    expect(reached, isTrue, reason: 'Tab 必须能到 ⋯');
    expect(order.toSet(), shown, reason: '到 ⋯ 之前已依次经过全部外露动作');

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    final Set<String> hidden = names.toSet().difference(shown);
    for (final String name in hidden) {
      expect(find.text(name), findsOneWidget, reason: 'Enter 打开 ⋯ 菜单');
    }
  });

  testWidgets('宽窗：药丸放得下就带字；文字放大到放不下时先降成纯图标', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Widget labeled({required double textScale}) => MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(
          size: const Size(1200, 800),
          textScaler: TextScaler.linear(textScale),
        ),
        child: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 1000,
              child: FushiPageHeader(
                title: '标题',
                actions: <Widget>[
                  for (int i = 0; i < 3; i++)
                    FushiIconButton(
                      icon: icons[i],
                      tooltip: 'tip$i',
                      label: '动作标签文字$i',
                      onTap: () {},
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    await tester.pumpWidget(labeled(textScale: 1));
    await tester.pump();
    expect(find.text('动作标签文字0'), findsOneWidget, reason: '宽窗放得下：药丸形态零变化');
    expect(hasOverflow(), isFalse);

    await tester.pumpWidget(labeled(textScale: 4));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('动作标签文字0'), findsNothing, reason: '估算随文字缩放走：药丸放不下先降成纯图标');
    for (int i = 0; i < 3; i++) {
      expect(find.byIcon(icons[i]), findsOneWidget, reason: '纯图标放得下就不收');
    }
    expect(hasOverflow(), isFalse);
  });

  testWidgets('外壳动作组（FushiShellHeaderActions）走同一判据', (
    WidgetTester tester,
  ) async {
    Future<Set<String>> at(double width) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: width,
                child: FushiShellHeaderActions(
                  actions: buildActions(<String>[]),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      return visibleNames();
    }

    expect(await at(600), names.toSet());
    expect(hasOverflow(), isFalse);
    final Set<String> mid = await at(160);
    expect(hasOverflow(), isTrue);
    expect(mid, contains('C'));
    expect(
      mid.length,
      inExclusiveRange(1, names.length),
      reason: '逐颗收，而不是全有或全无',
    );
    expect(mid.contains('E'), isFalse, reason: '最低优先级先收');
  });
}
