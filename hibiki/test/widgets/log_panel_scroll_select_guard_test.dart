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
    // BUG-423 / TODO-806：日志行不换行（softWrap:false），降低单行选区命中成本
    // 兼修框选坐标错位。改回 softWrap:true 会重新放大拖拽命中成本。
    expect(panel, contains('softWrap: false'),
        reason: '日志行必须 softWrap:false（BUG-423 拖拽命中成本 / TODO-806 坐标错位）');
    expect(panel, isNot(contains('softWrap: true')),
        reason: 'softWrap:true 会把一行拆成多视觉行，放大 SelectionArea 单行命中成本');
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

  // —— BUG-119 拽回 + BUG-423 防卡死 + TODO-934 恢复边缘自动滚动 判据纯函数守卫 ——
  // 复核 ③：旧的结构守卫即使把 _allowProgrammaticScroll 掏空（恒 return true）也全绿。
  // 把判据下沉成纯函数 logSelectionScrollDecision 后，这组单测直接钉死它的真值表：
  // 掏空（恒 true）或退化拦截逻辑都会让某条断言转红。
  //
  // TODO-934（调试日志框选拖到边区不响应）：BUG-423 当年一刀切「拖拽期一律拦掉程序化
  // 滚动」止住了卡死，代价是边缘自动滚动也被拦——拖到边区不再滚动延伸选区。SDK 证据
  // 表明纯 SelectionArea + ListView.builder(Text) 结构下，拖拽框选期间唯一的程序化滚动
  // 来源是 EdgeDraggingAutoScroller 的 animateTo（边缘自动滚动，每帧 ≤20px 有界一小步）；
  // 而键盘 granular/directional 扩展选区的 _jumpToEdge 拽回走 jumpTo。离屏行被
  // ListView 回收时其 Selectable 从 SelectionContainer remove 掉，selectables 大小被钉在
  // 视口 + cacheExtent 内有界、不随滚动膨胀，卡死放大器（softWrap:true 长行）已由
  // BUG-423 softWrap:false + BUG-448 宽度约束消除。故按 API 区分：放行 animateTo（边缘
  // 自动滚动）、仍拦 jumpTo（拽回）。本组真值表把「animated 放行 / 非 animated 拦」钉死。
  group(
      'logSelectionScrollDecision (BUG-119 pull-back + TODO-934 edge auto-scroll, pure)',
      () {
    test('drag inactive -> always allow (non-selection scroll untouched)', () {
      expect(
        logSelectionScrollDecision(
          pointerSelectionActive: false,
          delta: -200,
          animated: false,
        ),
        isTrue,
      );
      expect(
        logSelectionScrollDecision(
          pointerSelectionActive: false,
          delta: 200,
          animated: true,
        ),
        isTrue,
      );
    });

    test('negligible delta (<=0.5) -> allow (no real scroll to gate)', () {
      expect(
        logSelectionScrollDecision(
          pointerSelectionActive: true,
          delta: 0.4,
          animated: false,
        ),
        isTrue,
      );
      expect(
        logSelectionScrollDecision(
          pointerSelectionActive: true,
          delta: -0.5,
          animated: true,
        ),
        isTrue,
      );
    });

    // TODO-934 核心：拖拽选区期间，动画滚动（animateTo = 边缘自动滚动）必须放行——
    // 这正是「拖到边区继续滚动延伸选区」的来源。任何人把它改回拦掉（恢复 BUG-423
    // 一刀切）都会让本组 ALLOW 断言转红。
    test(
        'drag active + downward ANIMATED scroll -> ALLOW '
        '(edge auto-scroll extends selection)', () {
      expect(
        logSelectionScrollDecision(
          pointerSelectionActive: true,
          delta: 200,
          animated: true,
        ),
        isTrue,
      );
    });

    test(
        'drag active + upward ANIMATED scroll -> ALLOW '
        '(edge auto-scroll extends selection)', () {
      expect(
        logSelectionScrollDecision(
          pointerSelectionActive: true,
          delta: -200,
          animated: true,
        ),
        isTrue,
      );
    });

    test('drag active + small-but-real ANIMATED delta -> ALLOW', () {
      expect(
        logSelectionScrollDecision(
          pointerSelectionActive: true,
          delta: 5,
          animated: true,
        ),
        isTrue,
      );
    });

    // BUG-119 不变式：拖拽选区期间，瞬跳滚动（jumpTo = 键盘 _jumpToEdge 拽回）一律拦。
    // 任何人把它改成放行都会重新引入「把视口往选区 extent 拽回」的 BUG-119。
    test(
        'drag active + downward JUMP scroll -> BLOCK '
        '(keyboard _jumpToEdge pull-back)', () {
      expect(
        logSelectionScrollDecision(
          pointerSelectionActive: true,
          delta: 200,
          animated: false,
        ),
        isFalse,
      );
    });

    test(
        'drag active + upward JUMP scroll -> BLOCK '
        '(keyboard _jumpToEdge pull-back / no pull-back)', () {
      expect(
        logSelectionScrollDecision(
          pointerSelectionActive: true,
          delta: -200,
          animated: false,
        ),
        isFalse,
      );
    });

    test('drag active + small-but-real JUMP delta -> BLOCK', () {
      expect(
        logSelectionScrollDecision(
          pointerSelectionActive: true,
          delta: 5,
          animated: false,
        ),
        isFalse,
      );
      expect(
        logSelectionScrollDecision(
          pointerSelectionActive: true,
          delta: -5,
          animated: false,
        ),
        isFalse,
      );
    });
  });

  // —— BUG-448：点击 / 选中超长单行日志不崩 ——
  // 根因：行 Text(softWrap:false) 无宽度上限 → ListView 只纵向滚动、水平无约束收口 →
  // SelectionArea 对无界单行宽度的 Selectable 做命中测试 / getBoxesForSelection 时落到
  // 超出视口的极端横坐标越界（同族 BUG-413/423、TODO-806/822）。修复 = 每行 Text 包
  // ClipRect + ConstrainedBox(maxWidth: 视口宽) 把布局宽度钉死视口内，Selectable 矩形
  // 不再越界。真实命中越界几何要真机/真渲染，headless 难稳定复现，故在最强可落地层守住：
  // ① widget 行为——含超长单行时构建 / 点击 / 选中不抛异常；② 源码守卫——每行 Text 受
  // 宽度约束（ConstrainedBox + ClipRect 在场，softWrap:false 仍在）。
  testWidgets(
      'BUG-448: tapping/selecting a log with an extremely long single line does '
      'not throw (line Text width is bounded)', (WidgetTester tester) async {
    // 一行远超视口宽度（400px）的超长 monospace 单行日志。
    final String longLine = 'X' * 20000;
    final String log = 'head\n$longLine\ntail';
    await tester.pumpWidget(
      buildSubject(HibikiLogPanel(log: log, shareAction: (_) {})),
    );
    await tester.pump();

    // 超长行已渲染（在视口内），且其 Text 的祖先链上有把宽度收口到视口的约束。
    final Finder longText = find.text(longLine);
    expect(longText, findsOneWidget);
    final Finder boundedAncestor = find.ancestor(
      of: longText,
      matching: find.byType(ConstrainedBox),
    );
    expect(boundedAncestor, findsWidgets,
        reason: '超长行 Text 必须被宽度约束包裹（消除无界单行宽度根因）');

    // 点击超长行触发 selection 命中测试：修复前对无界宽度 Selectable 求交会越界崩溃。
    await tester.tapAt(tester.getCenter(longText));
    await tester.pump();

    // 在超长行内部做一次拖选（横向超视口）也不得抛异常。
    final Rect r = tester.getRect(longText);
    final TestGesture g = await tester.startGesture(
      Offset(r.left + 5, r.center.dy),
    );
    await tester.pump(const Duration(milliseconds: 20));
    await g.moveTo(Offset(r.left + 380, r.center.dy));
    await tester.pump(const Duration(milliseconds: 20));
    await g.up();
    await tester.pump();

    // 走到这里没抛异常即通过；显式断言无 Flutter 错误。
    expect(tester.takeException(), isNull,
        reason: '点击 / 框选超长单行日志不应抛异常（BUG-448 越界崩溃）');
  });

  test(
      'BUG-448 source guard: each log line Text is width-bounded (ConstrainedBox '
      '+ ClipRect) so SelectionArea hit-test cannot go out of bounds', () {
    final String source = File(
      'lib/src/utils/components/hibiki_material_components.dart',
    ).readAsStringSync();
    final String panel = source.substring(
      source.indexOf('class _HibikiLogPanelState'),
      source.indexOf('class _LogSelectionScrollController'),
    );
    // 行 Text 必须被宽度约束 + 裁切包裹（消除无界单行宽度）。
    expect(panel, contains('ConstrainedBox('),
        reason: '每行 Text 必须被 ConstrainedBox 收口宽度（BUG-448）');
    expect(panel, contains('ClipRect('),
        reason: '超视口长行需 ClipRect 裁切溢出（BUG-448）');
    expect(panel, contains('maxWidth: constraints.maxWidth'),
        reason: '行宽度上限必须取自外层 LayoutBuilder 的视口宽度');
    // softWrap:false 仍在（BUG-423/TODO-806 命中成本），但现在配宽度约束不再无界。
    expect(panel, contains('softWrap: false'));
    // 复制全部的 setData 加了平台异常降级 try（Windows 剪贴板通道兜底）。
    expect(panel, contains('copy-all to clipboard failed'),
        reason: '复制全部的 Clipboard.setData 必须有平台异常降级，不让异常逃逸');
  });

  // —— TODO-934：边缘自动滚动恢复 + Selectable 集合有界（防 BUG-423 卡死回归） ——
  // 用户诉求：拖拽框选时拖到面板边区，列表应继续自动滚动并延伸选区。BUG-423 当年
  // 一刀切禁掉了边缘自动滚动（拖到边区不响应），TODO-934 按滚动 API 区分恢复它。
  //
  // 核心矛盾的验收硬线：恢复边缘自动滚动 ⇄ 绝不重引 BUG-423 卡死（Selectable 集合
  // 无界膨胀）。真实的「拖到边缘触发 EdgeDraggingAutoScroller」几何在 headless
  // flutter_test 里不可靠复现（选区拖拽手势 + scrollable 选区容器的边缘带命中需要真
  // 设备/真渲染，见文件头说明），故这里把不变式拆成可确定性落地的两条：
  //   ① 行为层——直接驱动 ListView 滚过很多屏（边缘自动滚动每帧就是一次有界 animateTo
  //      / 位置推进），断言渲染的行 Text 数（≈ SelectionArea 跟踪的 Selectable 数，每行
  //      注册一个 _SelectableFragment）始终有界 ≈ 视口容量，而非 ∝ 已滚过总行数。这正面
  //      钉死 BUG-423 误判的「Selectable 集合单调膨胀」——只要 ListView 正常回收离屏行
  //      （其 Selectable 从 SelectionContainer remove 掉），集合就有界，卡死链路不复活。
  //      若有人改坏回收（addAutomaticKeepAlives:true / shrinkWrap 撑开全部行 / 换回一次性
  //      渲染），渲染行数随滚动膨胀 → 本测试转红。
  //   ② 判据层——拖拽激活期间放行 animateTo（边缘自动滚动）由上面纯函数真值表钉死。
  testWidgets(
      'TODO-934: scrolling many screens keeps the rendered line count (≈ tracked '
      'Selectables) bounded — ListView recycles off-screen rows (no BUG-423 bloat)',
      (WidgetTester tester) async {
    // 远超视口容纳行数的大日志。
    final List<String> lines =
        List<String>.generate(5000, (int i) => 'log-line-$i');
    final String log = lines.join('\n');
    await tester.pumpWidget(
      buildSubject(HibikiLogPanel(log: log, shareAction: (_) {})),
    );
    await tester.pump();

    int renderedLineCount() => tester
        .widgetList<Text>(
          find.descendant(
            of: find.byType(ListView),
            matching: find.byType(Text),
          ),
        )
        .length;

    final int initialRendered = renderedLineCount();
    expect(initialRendered, greaterThan(0));
    // 起始视口只渲染少量行（虚拟化生效，测试前提）。
    expect(initialRendered, lessThan(500));

    final ScrollableState scrollable =
        tester.state<ScrollableState>(find.byType(Scrollable).first);

    // 模拟边缘自动滚动：每帧把视口往下推进一个有界小步（SDK 的边缘自动滚动每帧 ≤20px，
    // 这里用 16px 步进逐帧 jumpTo 模拟其位置推进效果），滚过很多屏。
    int maxRenderedDuringScroll = initialRendered;
    final double maxExtent = scrollable.position.maxScrollExtent;
    expect(maxExtent, greaterThan(2000), reason: '5000 行应产生远超视口的可滚动范围（虚拟化前提）');
    double target = 0;
    while (target < maxExtent) {
      target += 16;
      scrollable.position.jumpTo(target.clamp(0, maxExtent));
      await tester.pump(const Duration(milliseconds: 16));
      final int now = renderedLineCount();
      if (now > maxRenderedDuringScroll) maxRenderedDuringScroll = now;
    }

    // ① 确实滚过了很多屏（滚到底）。
    expect(scrollable.position.pixels, greaterThan(2000),
        reason: '应滚过很多屏（滚到接近底部）');

    // ② 防 BUG-423 卡死回归：滚过很多屏的整个过程里，渲染行数（≈ 跟踪的 Selectable 数）
    //    始终有界 ≈ 视口容量，绝不随已滚过的总行数膨胀。给一个宽松但远小于 5000 的上界。
    expect(maxRenderedDuringScroll, lessThan(500),
        reason: '滚动期间渲染行数（≈ Selectable 数）必须有界；接近已滚过总行数说明'
            '离屏行未回收 = Selectable 集合膨胀 = BUG-423 卡死回归');

    expect(tester.takeException(), isNull);
  });

  // 源码守卫：判据按滚动 API 区分（animated 参数在场），且 controller / position 的
  // animateTo 传 animated:true（放行边缘自动滚动）、jumpTo 传 animated:false（拦拽回）。
  // 防止有人把 animated 维度删掉退回 BUG-423 一刀切。
  test(
      'TODO-934 source guard: decision is API-aware (animated param); animateTo '
      'passes animated:true (edge auto-scroll allowed), jumpTo animated:false',
      () {
    final String source = File(
      'lib/src/utils/components/hibiki_material_components.dart',
    ).readAsStringSync();
    // 判据带 animated 维度。
    expect(source, contains('required bool animated'),
        reason: '判据必须按滚动 API 区分（animated 参数），否则无法只放行边缘自动滚动');
    // 边缘自动滚动（animateTo）放行：两处 animateTo 闸门都传 animated:true。
    expect(source, contains('_allowProgrammaticScroll(offset, animated: true)'),
        reason: 'controller.animateTo 必须 animated:true（放行边缘自动滚动）');
    expect(source,
        contains('controller._allowProgrammaticScroll(to, animated: true)'),
        reason: 'position.animateTo 必须 animated:true（放行边缘自动滚动）');
    // 拽回（jumpTo）拦掉：两处 jumpTo 闸门都传 animated:false。
    expect(source, contains('_allowProgrammaticScroll(value, animated: false)'),
        reason: 'jumpTo 必须 animated:false（拦键盘 _jumpToEdge 拽回，BUG-119）');
    expect(source,
        contains('controller._allowProgrammaticScroll(value, animated: false)'),
        reason: 'position.jumpTo 必须 animated:false（拦拽回）');
  });
}
