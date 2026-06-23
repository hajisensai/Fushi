import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/components/hibiki_material_components.dart';

// BUG-119 守卫（TODO-762 起从 TextField 迁到 ListView.builder 后更新）：
// 日志页（错误日志 / 调试日志）按住鼠标拖拽选区想往上滑复制时，视口曾被「拽回」。
// 旧的最早实现是「整段 SelectableText + 外层 SingleChildScrollView」，拖拽选区时内层
// EditableText 对祖先 Scrollable 调 bringIntoView 把视口拽回光标 → 与手动滚动打架。
// 中间版改成「单个只读 TextField」让 EditableText 自己当唯一滚动器。
//
// TODO-762 又把整段 TextField 换成 `ListView.builder` 懒加载（修首帧 ~512KB 全量
// TextPainter.layout 卡顿），选区改由 `SelectionArea` 跨行提供。BUG-119 的防线随之
// 平移到 ListView 的 ScrollController：仍用 [_LogSelectionScrollController] 当
// controller，在拖拽选区期间拦掉「把视口往光标拽回」的程序化 jumpTo/animateTo，只放行
// 指针贴边的合法边缘自动滚动。这套 gate 是不变式，本守卫锁住它不被换回会被拽回的结构。
//
// 真实的选区+滚动几何需要设备/真渲染拖拽，headless 难以稳定复现，故这里在「最强可
// 落地层」守住两条结构不变式：① widget 行为——面板用 SelectionArea + ListView.builder
// 懒加载（不再有 TextField / SelectableText / 包整段内容的 SingleChildScrollView），
// 且 ListView 挂的是带 BUG-119 拽回拦截的自定义 ScrollController；② 源码守卫——防止
// 有人改回会被拽回的「整段一次性渲染」结构，且保证 ListView 仍接 _LogSelectionScrollController。
void main() {
  Widget buildSubject(Widget child) {
    return MaterialApp(
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
      ),
      home: Scaffold(
        body: SizedBox(
          width: 400,
          height: 400,
          child: child,
        ),
      ),
    );
  }

  testWidgets(
      'HibikiLogPanel lazy-renders log lines in a ListView.builder wrapped in a '
      'SelectionArea (no TextField/SelectableText/SingleChildScrollView pull-back)',
      (WidgetTester tester) async {
    const String log = 'line-1\nline-2\nline-3';
    await tester.pumpWidget(
      buildSubject(
        HibikiLogPanel(log: log, shareAction: (_) {}),
      ),
    );
    await tester.pump();

    // 选区/复制：SelectionArea 包裹懒加载列表。
    expect(
      find.descendant(
        of: find.byType(HibikiLogPanel),
        matching: find.byType(SelectionArea),
      ),
      findsOneWidget,
    );

    // 懒加载渲染：ListView.builder。控制器必须是带 BUG-119 拽回拦截的自定义类型——
    // 它对 ScrollPosition 的 jumpTo/animateTo 做闸门，是「拖拽选区不被拽回」的核心。
    final Finder listFinder = find.descendant(
      of: find.byType(HibikiLogPanel),
      matching: find.byType(ListView),
    );
    expect(listFinder, findsOneWidget);
    final ListView list = tester.widget<ListView>(listFinder);
    expect(list.controller, isNotNull);
    // ListView.builder 的 childrenDelegate 是 SliverChildBuilderDelegate（懒构造），
    // 不是 SliverChildListDelegate（一次性 build 全部 child）。
    expect(list.childrenDelegate, isA<SliverChildBuilderDelegate>());

    // 旧的「会被拽回 / 整段一次性渲染」结构必须全部消失。
    for (final Type banned in <Type>[
      TextField,
      SelectableText,
      SingleChildScrollView,
    ]) {
      expect(
        find.descendant(
          of: find.byType(HibikiLogPanel),
          matching:
              find.byWidgetPredicate((Widget w) => w.runtimeType == banned),
        ),
        findsNothing,
        reason: '$banned 会让整段日志一次性渲染（卡顿）或重新引入 BUG-119 拽回',
      );
    }
  });

  testWidgets(
      'HibikiLogPanel does not eagerly build off-screen lines (lazy virtualization)',
      (WidgetTester tester) async {
    // 大日志（远超 400px 视口容纳的行数）只应构造视口内的少量 Text，证明虚拟化生效。
    // 旧的单 TextField/整段 SelectableText 会把全部 ~512KB 一次性 layout，正是卡顿根因。
    final String log =
        List<String>.generate(5000, (int i) => 'log-line-$i').join('\n');
    await tester.pumpWidget(
      buildSubject(
        HibikiLogPanel(log: log, shareAction: (_) {}),
      ),
    );
    await tester.pump();

    // 视口 ~400px、每行 monospace 行高约十几 px，最多容纳几十行；断言「远小于全部 5000
    // 行」即可证明 ListView.builder 没有一次性构造全部行（不依赖具体行高的精确值）。
    final int builtLines = tester
        .widgetList<Text>(
          find.descendant(
            of: find.byType(ListView),
            matching: find.byType(Text),
          ),
        )
        .length;
    expect(builtLines, lessThan(500),
        reason: '懒加载下视口内行数应远小于 5000；接近 5000 说明退回一次性全量渲染');
    expect(builtLines, greaterThan(0));
  });

  test(
      'HibikiLogPanel source uses ListView.builder + SelectionArea on the '
      'BUG-119-gating scroll controller (no eager full-text render)', () {
    final String source = File(
      'lib/src/utils/components/hibiki_material_components.dart',
    ).readAsStringSync();
    final String panel = source.substring(
      source.indexOf('class _HibikiLogPanelState'),
      source.indexOf('class _LogSelectionScrollController'),
    );

    // 懒加载 + 选区结构。
    expect(panel, contains('ListView.builder('));
    expect(panel, contains('SelectionArea('));
    // BUG-119 防线仍在：ListView 挂自定义拽回拦截 controller。
    expect(panel, contains('_LogSelectionScrollController'));
    expect(panel, contains('controller: _scrollController'));
    // 旧的「会被拽回 / 整段一次性渲染」构造调用消失（ASCII 括号形避免误伤注释里提到
    // 这些类名的说明文字）。
    expect(panel, isNot(contains('TextField(')));
    expect(panel, isNot(contains('SelectableText(')));
    expect(panel, isNot(contains('SingleChildScrollView(')));
  });
}
