import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/focus/fushi_focus_scroll.dart';
import 'package:fushi/src/focus/page_scroll_registry.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/misc/platform_utils.dart';

import 'widget_test_helpers.dart';

void main() {
  testWidgets(
      'FushiPageScaffold page-scrolls its body from a header-area context '
      '(where the gamepad focus actually sits) via PrimaryScrollController',
      (WidgetTester tester) async {
    // The gamepad dispatch context is the focused control — on a page WITH a
    // focusable header button that is a header/AppBar icon button, which sits
    // OUTSIDE the body scroll view but INSIDE the scaffold PrimaryScrollController.
    late BuildContext headerCtx;
    await tester.pumpWidget(buildTestApp(
      FushiPageScaffold(
        title: 'Stats',
        actions: <Widget>[
          Builder(builder: (BuildContext c) {
            headerCtx = c;
            return const SizedBox.shrink();
          }),
        ],
        body: CustomScrollView(
          slivers: <Widget>[
            SliverList(
              delegate: SliverChildBuilderDelegate(
                (BuildContext _, int i) =>
                    SizedBox(height: 100, child: Text('row $i')),
                childCount: 60,
              ),
            ),
          ],
        ),
      ),
    ));
    await tester.pump();
    expect(find.text('row 0'), findsOneWidget);

    final bool scrolled = FushiFocusScroll.scrollPrimary(headerCtx, 0.9);
    expect(scrolled, isTrue,
        reason: 'header-area context reaches the scaffold '
            'PrimaryScrollController the body attached to');
    await tester.pumpAndSettle();
    expect(find.text('row 0'), findsNothing,
        reason: 'page-scroll moved the page ~0.9 viewport down');
  });

  testWidgets(
      'gamepad page-scroll reaches a PURE-DISPLAY page body via PageScrollRegistry '
      'even when focus is the top-level fallback node (regression: C1)',
      (WidgetTester tester) async {
    PageScrollRegistry.debugClear();
    await tester.pumpWidget(buildTestApp(
      FushiFocusRoot(
        child: FushiPageScaffold(
          title: 'Stats',
          // Nothing focusable anywhere -> focus rests on the fallback node,
          // which is the real dispatch context on a pure-display page.
          body: CustomScrollView(
            slivers: <Widget>[
              SliverList(
                delegate: SliverChildBuilderDelegate(
                  (BuildContext _, int i) =>
                      SizedBox(height: 100, child: Text('row $i')),
                  childCount: 60,
                ),
              ),
            ],
          ),
        ),
      ),
    ));
    await tester.pump();
    expect(find.text('row 0'), findsOneWidget);

    final FushiFocusController controller = FushiFocusRoot.controllerOf(
      tester.element(find.text('row 0')),
    );
    controller.ensureFocus();
    await tester.pump();
    expect(controller.fallbackNode.hasPrimaryFocus, isTrue,
        reason: 'pure-display page: focus is the top-level fallback node');

    // C1: a context lookup from the fallback node (an ANCESTOR of the scaffold
    // PrimaryScrollController) can NEVER find the page controller — this is the
    // exact bug.
    expect(
      FushiFocusScroll.scrollPrimary(controller.fallbackNode.context!, 0.9),
      isFalse,
      reason: 'context lookup from the fallback node cannot reach the page '
          'controller (the root cause of C1)',
    );

    // Fix: the scaffold registered its body controller, reachable regardless of
    // where focus sits.
    final ScrollController? page = PageScrollRegistry.current;
    expect(page, isNotNull,
        reason: 'FushiPageScaffold registered its body scroll controller');
    expect(FushiFocusScroll.scrollController(page!, 0.9), isTrue);
    await tester.pumpAndSettle();
    expect(find.text('row 0'), findsNothing,
        reason: 'LB/RB now page-scrolls the pure-display page');
  });

  testWidgets('PageScrollRegistry pops when the scaffold is disposed',
      (WidgetTester tester) async {
    PageScrollRegistry.debugClear();
    await tester.pumpWidget(buildTestApp(
      FushiPageScaffold(
        title: 'Stats',
        body: ListView(
          children: <Widget>[
            for (int i = 0; i < 30; i++)
              SizedBox(height: 80, child: Text('$i')),
          ],
        ),
      ),
    ));
    await tester.pump();
    expect(PageScrollRegistry.debugDepth, 1);

    // Replace with an empty page -> scaffold disposed -> controller popped.
    await tester.pumpWidget(buildTestApp(const SizedBox()));
    await tester.pump();
    expect(PageScrollRegistry.debugDepth, 0,
        reason: 'the scaffold must pop its controller on dispose (no leak)');
  });

  testWidgets('BUG-1959：粗鼠标滚轮不再一格跳过完整原始 delta',
      (WidgetTester tester) async {
    PageScrollRegistry.debugClear();
    await tester.pumpWidget(buildTestApp(
      FushiPageScaffold(
        title: 'Wheel',
        body: ListView.builder(
          itemCount: 60,
          itemBuilder: (BuildContext context, int index) =>
              SizedBox(height: 100, child: Text('wheel row $index')),
        ),
      ),
    ));
    await tester.pump();

    final ScrollController controller = PageScrollRegistry.current!;
    final TestPointer wheel = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(
      wheel.hover(tester.getCenter(find.text('wheel row 0'))),
    );
    await tester.sendEventToBinding(wheel.scroll(const Offset(0, 120)));
    // 先空 pump 一帧把 Ticker 起起来：AnimationController 第一次 tick 拿到的
    // elapsed 恒为 0（起始时间就在那一帧上设），所以直接 `pump(40ms)` 落在的是
    // 「动画刚开始、位移还是 0」那一帧，下面 `greaterThan(0)` 必然失败——那测的是
    // Ticker 的记时约定，不是滚动行为。起完之后再推进 40ms 才是真的动画中途。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    if (Platform.isWindows || Platform.isLinux) {
      expect(
        controller.offset,
        allOf(
          greaterThan(0),
          lessThan(refinedDesktopPointerScrollDelta(120)),
        ),
        reason: '粗滚轮应在多帧内逐步到达目标，而不是第一帧瞬移',
      );
    } else {
      expect(controller.offset, 120, reason: 'macOS 保持平台原生 pointer delta');
    }
    await tester.pumpAndSettle();
    expect(controller.offset, refinedDesktopPointerScrollDelta(120));

    await tester.sendEventToBinding(wheel.scroll(const Offset(0, 12)));
    await tester.pump();
    expect(
      controller.offset,
      refinedDesktopPointerScrollDelta(120) + 12,
      reason: '小 delta 不得跟着粗滚轮一起打折',
    );

    controller.jumpTo(0);
    await tester.sendEventToBinding(wheel.scroll(const Offset(0, 120)));
    await tester.pump(const Duration(milliseconds: 40));
    await tester.sendEventToBinding(wheel.scroll(const Offset(0, 120)));
    await tester.pumpAndSettle();
    expect(
      controller.offset,
      refinedDesktopPointerScrollDelta(120) * 2,
      reason: '连续同向滚轮必须累积目标，不能因重启动画吃掉滚动距离',
    );
  });
}
