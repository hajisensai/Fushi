import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/focus/hibiki_focus_scroll.dart';

void main() {
  group('HibikiFocusScroll.signedFractionFor', () {
    test('down/right 为正、up/left 为负', () {
      expect(HibikiFocusScroll.signedFractionFor(TraversalDirection.down, 0.8),
          0.8);
      expect(HibikiFocusScroll.signedFractionFor(TraversalDirection.right, 0.8),
          0.8);
      expect(HibikiFocusScroll.signedFractionFor(TraversalDirection.up, 0.8),
          -0.8);
      expect(HibikiFocusScroll.signedFractionFor(TraversalDirection.left, 0.8),
          -0.8);
    });
  });

  group('HibikiFocusScroll.scrollByViewportFraction', () {
    testWidgets('无 Scrollable 祖先返回 false', (WidgetTester tester) async {
      late BuildContext ctx;
      await tester.pumpWidget(MaterialApp(
        home: Builder(builder: (BuildContext c) {
          ctx = c;
          return const SizedBox();
        }),
      ));
      expect(
          HibikiFocusScroll.scrollByViewportFraction(ctx, null, 0.8), isFalse);
    });

    testWidgets('有 Scrollable 时滚动并返回 true；已到底返回 false',
        (WidgetTester tester) async {
      final ScrollController controller = ScrollController();
      addTearDown(controller.dispose);
      late BuildContext itemCtx;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ListView(
            controller: controller,
            children: <Widget>[
              for (int i = 0; i < 60; i++)
                SizedBox(
                  height: 100,
                  child: i == 0
                      ? Builder(builder: (BuildContext x) {
                          itemCtx = x;
                          return const Text('first');
                        })
                      : Text('$i'),
                ),
            ],
          ),
        ),
      ));
      final double vp = controller.position.viewportDimension;
      expect(
          HibikiFocusScroll.scrollByViewportFraction(
              itemCtx, AxisDirection.down, 0.8),
          isTrue);
      await tester.pumpAndSettle();
      expect(controller.offset, closeTo(vp * 0.8, 1.0));

      controller.jumpTo(controller.position.maxScrollExtent);
      await tester.pump();
      expect(
          HibikiFocusScroll.scrollByViewportFraction(
              itemCtx, AxisDirection.down, 0.8),
          isFalse);
    });

    testWidgets('scrollPrimary 翻 PrimaryScrollController 一个 viewport 比例',
        (WidgetTester tester) async {
      final ScrollController controller = ScrollController();
      addTearDown(controller.dispose);
      late BuildContext ctx;
      await tester.pumpWidget(MaterialApp(
        home: PrimaryScrollController(
          controller: controller,
          child: Builder(builder: (BuildContext c) {
            ctx = c;
            return Scaffold(
              body: CustomScrollView(
                slivers: <Widget>[
                  SliverList(
                    delegate: SliverChildBuilderDelegate(
                      (BuildContext _, int i) =>
                          SizedBox(height: 100, child: Text('$i')),
                      childCount: 60,
                    ),
                  ),
                ],
              ),
            );
          }),
        ),
      ));
      final double vp = controller.position.viewportDimension;
      expect(HibikiFocusScroll.scrollPrimary(ctx, 0.9), isTrue);
      await tester.pumpAndSettle();
      expect(controller.offset, closeTo(vp * 0.9, 1.0));
    });

    testWidgets('scrollPrimary 无 PrimaryScrollController 返回 false',
        (WidgetTester tester) async {
      late BuildContext ctx;
      await tester.pumpWidget(MaterialApp(
        home: Builder(builder: (BuildContext c) {
          ctx = c;
          return const SizedBox();
        }),
      ));
      expect(HibikiFocusScroll.scrollPrimary(ctx, 0.9), isFalse);
    });

    testWidgets('wantAxis 与 position.axis 不匹配返回 false（垂直页 left/right 不误翻）',
        (WidgetTester tester) async {
      final ScrollController controller = ScrollController();
      addTearDown(controller.dispose);
      late BuildContext itemCtx;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ListView(
            controller: controller,
            children: <Widget>[
              for (int i = 0; i < 60; i++)
                SizedBox(
                  height: 100,
                  child: i == 0
                      ? Builder(builder: (BuildContext x) {
                          itemCtx = x;
                          return const Text('first');
                        })
                      : Text('$i'),
                ),
            ],
          ),
        ),
      ));
      expect(
          HibikiFocusScroll.scrollByViewportFraction(
              itemCtx, AxisDirection.right, 0.8),
          isFalse);
    });
  });
}
