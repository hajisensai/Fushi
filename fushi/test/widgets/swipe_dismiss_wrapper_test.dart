import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/lookup/swipe_dismiss_wrapper.dart';

void main() {
  Widget buildApp({required VoidCallback onDismiss, double sensitivity = 0.3}) {
    return MaterialApp(
      home: Scaffold(
        body: SwipeDismissWrapper(
          sensitivity: sensitivity,
          onDismiss: onDismiss,
          child: const SizedBox(
            width: 300,
            height: 100,
            child: ColoredBox(color: Colors.blue),
          ),
        ),
      ),
    );
  }

  group('SwipeDismissWrapper', () {
    testWidgets('renders child', (tester) async {
      await tester.pumpWidget(buildApp(onDismiss: () {}));

      expect(
        find.byWidgetPredicate(
          (w) => w is ColoredBox && w.color == Colors.blue,
        ),
        findsOneWidget,
      );
    });

    testWidgets('horizontal swipe past threshold calls onDismiss', (
      tester,
    ) async {
      bool dismissed = false;
      await tester.pumpWidget(buildApp(onDismiss: () => dismissed = true));

      // Default sensitivity 0.3 → threshold = 30 + 0.7*160 = 142
      final center = tester.getCenter(find.byType(SizedBox).first);
      final gesture = await tester.startGesture(center);
      await gesture.moveBy(const Offset(200, 0));
      await gesture.up();
      await tester.pumpAndSettle();

      expect(dismissed, isTrue);
    });

    testWidgets('small horizontal drag does not dismiss', (tester) async {
      bool dismissed = false;
      await tester.pumpWidget(buildApp(onDismiss: () => dismissed = true));

      final center = tester.getCenter(find.byType(SizedBox).first);
      final gesture = await tester.startGesture(center);
      await gesture.moveBy(const Offset(30, 0));
      await gesture.up();
      await tester.pumpAndSettle();

      expect(dismissed, isFalse);
    });

    testWidgets('vertical drag does not dismiss', (tester) async {
      bool dismissed = false;
      await tester.pumpWidget(buildApp(onDismiss: () => dismissed = true));

      final center = tester.getCenter(find.byType(SizedBox).first);
      final gesture = await tester.startGesture(center);
      await gesture.moveBy(const Offset(0, 200));
      await gesture.up();
      await tester.pumpAndSettle();

      expect(dismissed, isFalse);
    });
  });

  // BUG-051: SwipeDismissWrapper 基于 Listener（onPointerMove/Up），指针事件会
  // 派发到 hit-test 路径上的所有祖先 Listener。因此把一个嵌套层（自带 wrapper）
  // 套进一个外层 wrapper 时，横滑嵌套层会同时驱动外层 → 整张卡片连带平移/关闭。
  // 这两个测试锁住该机制（危害）与修复模式（祖先 wrapper 必须在嵌套时移除/不渲染）。
  group('SwipeDismissWrapper nesting hazard (BUG-051)', () {
    Widget buildNested({
      required VoidCallback onOuterDismiss,
      required VoidCallback onInnerDismiss,
      required bool includeOuter,
    }) {
      final Widget inner = SwipeDismissWrapper(
        sensitivity: 0.9, // 阈值 46，100px 横滑必触发
        onDismiss: onInnerDismiss,
        child: const SizedBox(
          key: ValueKey<String>('inner-child'),
          width: 200,
          height: 80,
          child: ColoredBox(color: Colors.red),
        ),
      );
      final Widget body = includeOuter
          ? SwipeDismissWrapper(
              sensitivity: 0.9,
              onDismiss: onOuterDismiss,
              child: inner,
            )
          : inner;
      return MaterialApp(
        home: Scaffold(body: Center(child: body)),
      );
    }

    Future<void> dragInner(WidgetTester tester) async {
      final center = tester.getCenter(
        find.byKey(const ValueKey<String>('inner-child')),
      );
      final gesture = await tester.startGesture(center);
      await gesture.moveBy(const Offset(120, 0));
      await gesture.up();
      await tester.pumpAndSettle();
    }

    testWidgets(
      'with an ancestor wrapper present, a swipe on the nested layer fires '
      'BOTH dismiss callbacks (the bug mechanism)',
      (tester) async {
        bool outer = false;
        bool inner = false;
        await tester.pumpWidget(
          buildNested(
            onOuterDismiss: () => outer = true,
            onInnerDismiss: () => inner = true,
            includeOuter: true,
          ),
        );

        await dragInner(tester);

        expect(inner, isTrue, reason: '嵌套层自身应被横滑');
        expect(outer, isTrue, reason: 'Listener 冒泡使外层也被驱动——这正是「滑动子弹窗连带整卡」的根因');
      },
    );

    testWidgets(
      'gating out the ancestor wrapper makes the same swipe fire ONLY the '
      'nested dismiss (the fix pattern)',
      (tester) async {
        bool outer = false;
        bool inner = false;
        await tester.pumpWidget(
          buildNested(
            onOuterDismiss: () => outer = true,
            onInnerDismiss: () => inner = true,
            includeOuter: false, // 镜像 _buildCard: 栈深>1 时不渲染外层 wrapper
          ),
        );

        await dragInner(tester);

        expect(inner, isTrue);
        expect(outer, isFalse, reason: '外层 wrapper 被移除后，横滑嵌套层不再连带平移/关闭整卡');
      },
    );
  });

  group('SwipeDismissWrapper sensitivity changes dismiss threshold', () {
    Widget buildSingle({
      required Key childKey,
      required VoidCallback onDismiss,
      required double sensitivity,
    }) {
      return MaterialApp(
        home: Scaffold(
          body: SwipeDismissWrapper(
            sensitivity: sensitivity,
            onDismiss: onDismiss,
            child: SizedBox(
              key: childKey,
              width: 300,
              height: 100,
              child: const ColoredBox(color: Colors.green),
            ),
          ),
        ),
      );
    }

    // 纯水平拖动 100px：高灵敏 0.9 阈值 46 → 触发；低灵敏 0.1 阈值 174 → 不触发。
    const double dragDistance = 100;

    Future<bool> dragAndReportDismiss(
      WidgetTester tester, {
      required double sensitivity,
    }) async {
      bool dismissed = false;
      const childKey = ValueKey<String>('swipe-child');
      await tester.pumpWidget(
        buildSingle(
          childKey: childKey,
          onDismiss: () => dismissed = true,
          sensitivity: sensitivity,
        ),
      );

      final center = tester.getCenter(find.byKey(childKey));
      final gesture = await tester.startGesture(center);
      await gesture.moveBy(const Offset(dragDistance, 0));
      await gesture.up();
      await tester.pumpAndSettle();
      return dismissed;
    }

    testWidgets('high sensitivity (0.9) dismisses on a 100px horizontal drag', (
      tester,
    ) async {
      final dismissed = await dragAndReportDismiss(tester, sensitivity: 0.9);
      expect(dismissed, isTrue);
    });

    testWidgets(
      'low sensitivity (0.1) does NOT dismiss on the same 100px drag',
      (tester) async {
        final dismissed = await dragAndReportDismiss(tester, sensitivity: 0.1);
        expect(dismissed, isFalse);
      },
    );

    testWidgets('same drag distance: high sensitivity fires, low does not', (
      tester,
    ) async {
      final highFired = await dragAndReportDismiss(tester, sensitivity: 0.9);
      final lowFired = await dragAndReportDismiss(tester, sensitivity: 0.1);
      expect(highFired, isTrue);
      expect(lowFired, isFalse);
      expect(highFired, isNot(equals(lowFired)));
    });
  });

  // 用户 2026-11-06：横滑关弹窗时弹窗一动不动，抬手过阈值当帧关（与点 × 同一条路径）。
  // 录屏里 Android 混合合成把跟手平移只作用在原生 WebView 上，顶栏 / 卡框原地不动，
  // 看起来是「正文在框里横着滚」。这组用例锁住：拖动期间零位移、不挂 Transform /
  // Opacity、抬手当帧 onDismiss（没有补间帧要等）、未过阈值不残留判定状态。
  group('SwipeDismissWrapper 拖动期间弹窗不动', () {
    testWidgets('跟手期卡片位移恒为 0，也不挂 Transform / Opacity', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(buildApp(onDismiss: () {}));
      final Finder card = find.byType(SizedBox).first;
      final Offset before = tester.getTopLeft(card);
      final TestGesture gesture = await tester.startGesture(
        tester.getCenter(card),
      );
      await gesture.moveBy(const Offset(-200, 0));
      await tester.pump();

      expect(tester.getTopLeft(card), before);
      expect(
        find.descendant(
          of: find.byType(SwipeDismissWrapper),
          matching: find.byType(Transform),
        ),
        findsNothing,
      );
      expect(
        find.descendant(
          of: find.byType(SwipeDismissWrapper),
          matching: find.byType(Opacity),
        ),
        findsNothing,
      );
      await gesture.up();
    });

    testWidgets('过阈值：抬手当帧就 onDismiss（不等任何补间）', (WidgetTester tester) async {
      int dismissed = 0;
      await tester.pumpWidget(buildApp(onDismiss: () => dismissed++));
      final TestGesture gesture = await tester.startGesture(
        tester.getCenter(find.byType(SizedBox).first),
      );
      await gesture.moveBy(const Offset(200, 0));
      await gesture.up();

      // 抬手后一帧都没 pump 就已关：没有补间帧要等。
      expect(dismissed, 1);
    });

    testWidgets('未过阈值的一划不残留判定：接着纵向拖不误关', (WidgetTester tester) async {
      int dismissed = 0;
      await tester.pumpWidget(buildApp(onDismiss: () => dismissed++));
      final Offset center = tester.getCenter(find.byType(SizedBox).first);

      final TestGesture g1 = await tester.startGesture(center);
      await g1.moveBy(const Offset(60, 0));
      await g1.up();
      final TestGesture g2 = await tester.startGesture(center);
      await g2.moveBy(const Offset(0, 200));
      await g2.up();

      expect(dismissed, 0);
    });
  });
}
