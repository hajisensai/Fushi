import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

  // —— TODO-762 复核回归：「全选→复制 / 复制全部」必须给全量日志，不能退化成
  // 只复制视口内行 —— SelectionArea 配 ListView.builder 拿不到视口外行的
  // Selectable（复核 af417805 实测 5000 行只复制到 38 行）。修复让「复制全部」
  // 直走 widget.log 全量、绕开 SelectionArea。本组守卫把「复制全部覆盖全量」钉死：
  // 若有人把入口改回读视口选区（_selectedText / SelectionArea），复制内容就拿不到
  // 末行 → 本测试转红。
  testWidgets(
      'Copy-all copies the full widget.log (first AND last line), not just the '
      'viewport (TODO-762 viewport-only-copy regression guard)',
      (WidgetTester tester) async {
    // 远超 400px 视口容纳行数的大日志：视口只渲染前几十行，末行恒在视口外。
    final List<String> lines =
        List<String>.generate(5000, (int i) => 'log-line-$i');
    final String log = lines.join('\n');
    final String firstLine = lines.first; // log-line-0
    final String lastLine = lines.last; // log-line-4999

    // 拦截平台剪贴板通道，捕获 Clipboard.setData 真正写入的文本。
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (MethodCall call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map<Object?, Object?>)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    });

    await tester.pumpWidget(
      buildSubject(HibikiLogPanel(log: log, shareAction: (_) {})),
    );
    await tester.pump();

    // 末行确实在视口外（没被 ListView 构造）——证明「只能复制视口」一旦发生就丢末行。
    expect(find.text(lastLine), findsNothing,
        reason: '末行应在视口外未渲染；若被渲染说明列表没虚拟化，测试前提不成立');

    // 点「复制全部」入口。
    await tester.tap(find.byIcon(Icons.copy_all_outlined));
    await tester.pump();

    expect(copied, isNotNull, reason: '「复制全部」应写穿剪贴板');
    expect(copied, contains(firstLine), reason: '复制全部必须含首行');
    expect(copied, contains(lastLine),
        reason: '复制全部必须含末行（视口外）；只含首行段 = 退化成只复制视口（TODO-762 回归）');
    expect(copied, equals(log), reason: '复制全部应等于整段 widget.log');
  });

  // 源码守卫：复制全部 / 分享必须走全量 widget.log，绝不能读 SelectionArea 视口选区
  // （_selectedText）。复核 ③ 指出「掏空拦截逻辑守卫仍全绿」——这里直接锁住数据来源，
  // 把「退化成视口复制」钉死在源码层。
  test(
      'copy-all / share route through full widget.log, not the viewport '
      'selection (no _selectedText), and there is a Copy-All entry', () {
    final String source = File(
      'lib/src/utils/components/hibiki_material_components.dart',
    ).readAsStringSync();
    final String panel = source.substring(
      source.indexOf('class _HibikiLogPanelState'),
      source.indexOf('class _LogSelectionScrollController'),
    );

    // 复制全部走全量。
    expect(
        panel, contains('Clipboard.setData(ClipboardData(text: widget.log))'),
        reason: '复制全部必须复制 widget.log 全量');
    // 始终可见的「复制全部」入口存在。
    expect(panel, contains('t.log_copy_all'),
        reason: '面板必须有「复制全部」入口（菜单项 + 角落按钮）');
    expect(panel, contains('_copyAllToClipboard'));
    // 分享走全量 widget.log（不再是视口选区文本）。
    expect(panel, contains('widget.shareAction(widget.log)'),
        reason: '分享必须用 widget.log 全量');
    // 视口选区缓存彻底退场——不允许再用 _selectedText 当复制/分享数据来源。
    expect(panel, isNot(contains('_selectedText')),
        reason: '复制/分享一旦读 _selectedText 就只拿视口选区（TODO-762 回归）');
  });

  // —— BUG-119 拽回判据纯函数守卫 ——
  // 复核 ③：旧的结构守卫即使把 _allowProgrammaticScroll 掏空（恒 return true）也全绿。
  // 把判据下沉成纯函数 logSelectionScrollDecision 后，这组单测直接钉死它的真值表：
  // 掏空（恒 true）或退化拦截逻辑都会让某条断言转红。
  group('logSelectionScrollDecision (BUG-119 pull-back gate, pure)', () {
    test('drag inactive -> always allow (non-selection scroll untouched)', () {
      expect(
        logSelectionScrollDecision(
          pointerSelectionActive: false,
          delta: -200,
          pointerY: 200,
          viewportHeight: 400,
          userScrolledDuringSelection: false,
        ),
        isTrue,
      );
    });

    test('negligible delta (<=0.5) -> allow', () {
      expect(
        logSelectionScrollDecision(
          pointerSelectionActive: true,
          delta: 0.4,
          pointerY: 200,
          viewportHeight: 400,
          userScrolledDuringSelection: false,
        ),
        isTrue,
      );
    });

    test('near-bottom edge moving DOWN (outward) -> allow (edge auto-scroll)',
        () {
      // viewportHeight 400, edgeBand=clamp(48,72,96)=72 -> bottom band y>=328.
      expect(
        logSelectionScrollDecision(
          pointerSelectionActive: true,
          delta: 50, // downward
          pointerY: 390,
          viewportHeight: 400,
          userScrolledDuringSelection: false,
        ),
        isTrue,
      );
    });

    test('near-top edge moving UP (outward) -> allow (edge auto-scroll)', () {
      expect(
        logSelectionScrollDecision(
          pointerSelectionActive: true,
          delta: -50, // upward
          pointerY: 10,
          viewportHeight: 400,
          userScrolledDuringSelection: false,
        ),
        isTrue,
      );
    });

    test('near-bottom edge moving UP (inward) -> BLOCK (pull-back direction)',
        () {
      expect(
        logSelectionScrollDecision(
          pointerSelectionActive: true,
          delta: -50, // upward while pinned at bottom edge = bring-into-view
          pointerY: 390,
          viewportHeight: 400,
          userScrolledDuringSelection: false,
        ),
        isFalse,
      );
    });

    test('not near any edge, no manual scroll -> allow (no fight to gate)', () {
      expect(
        logSelectionScrollDecision(
          pointerSelectionActive: true,
          delta: -120,
          pointerY: 200, // middle of 400px viewport, outside both edge bands
          viewportHeight: 400,
          userScrolledDuringSelection: false,
        ),
        isTrue,
      );
    });

    test(
        'not near edge but user manually scrolled -> BLOCK (do not override '
        'the user manual scroll)', () {
      expect(
        logSelectionScrollDecision(
          pointerSelectionActive: true,
          delta: -120,
          pointerY: 200,
          viewportHeight: 400,
          userScrolledDuringSelection: true,
        ),
        isFalse,
      );
    });

    test('missing pointer geometry, user manually scrolled -> BLOCK', () {
      expect(
        logSelectionScrollDecision(
          pointerSelectionActive: true,
          delta: -120,
          pointerY: null,
          viewportHeight: null,
          userScrolledDuringSelection: true,
        ),
        isFalse,
      );
    });

    test('missing pointer geometry, no manual scroll -> allow', () {
      expect(
        logSelectionScrollDecision(
          pointerSelectionActive: true,
          delta: -120,
          pointerY: null,
          viewportHeight: null,
          userScrolledDuringSelection: false,
        ),
        isTrue,
      );
    });
  });
}
