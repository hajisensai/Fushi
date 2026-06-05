import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/misc/swipe_dismiss_wrapper.dart';

void main() {
  Widget buildApp({
    required VoidCallback onDismiss,
    double sensitivity = 0.3,
  }) {
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

    testWidgets('horizontal swipe past threshold calls onDismiss',
        (tester) async {
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

    // 闪回回归守卫：松手命中阈值的那一帧，浮层必须保持「已滑走」状态
    // （Opacity 归 0、Transform 位移不回弹到 0），由上层负责移除——绝不能回弹到
    // 原位且满不透明（那一帧的回弹＝用户看到的「闪回一下再关闭」）。
    testWidgets('dismiss frame does NOT snap back: opacity 0, offset held',
        (tester) async {
      // onDismiss 不移除子树（模拟 reader 的 Visibility 保留 / 上层尚未移除的一帧），
      // 这样才能观察退场帧 wrapper 自身的视觉，而非被移除。
      await tester.pumpWidget(buildApp(onDismiss: () {}));

      final center = tester.getCenter(find.byType(SizedBox).first);
      final gesture = await tester.startGesture(center);
      // 默认灵敏度 0.3 → 阈值 142；拖 200px 命中。
      await gesture.moveBy(const Offset(200, 0));
      await tester.pump();
      await gesture.up();
      // 松手当帧（不 settle）：观察退场态视觉。
      await tester.pump();

      final Opacity opacity = tester.widget<Opacity>(
        find.ancestor(
          of: find.byType(ColoredBox),
          matching: find.byType(Opacity),
        ),
      );
      expect(opacity.opacity, 0.0, reason: '退场帧必须透明（视觉已滑出），不得回弹到满不透明＝闪回');

      final Transform transform = tester.widget<Transform>(
        find.ancestor(
          of: find.byType(Opacity),
          matching: find.byType(Transform),
        ),
      );
      final double dx = transform.transform.getTranslation().x;
      expect(dx, isNot(0.0), reason: '退场帧位移不得归零回弹（应停在滑走位置，由上层移除）');
    });

    // 复用守卫：reader 复用同一浮层位置（onDismiss 后换新 child 再次显示）时，
    // 退场态必须被清掉，否则复用后的浮层会被永久压到 opacity 0＝不可见。
    testWidgets('reused popup resets dismiss state (not stuck invisible)',
        (tester) async {
      Widget buildWith(Widget child) {
        return MaterialApp(
          home: Scaffold(
            body: SwipeDismissWrapper(onDismiss: () {}, child: child),
          ),
        );
      }

      const Widget first = SizedBox(
        width: 300,
        height: 100,
        child: ColoredBox(color: Colors.blue),
      );
      await tester.pumpWidget(buildWith(first));

      // 滑动关闭 → 进入退场态（opacity 0）。
      final center = tester.getCenter(find.byType(SizedBox).first);
      final gesture = await tester.startGesture(center);
      await gesture.moveBy(const Offset(200, 0));
      await gesture.up();
      await tester.pump();

      // 上层用新 child 复用同一 wrapper 位置（State 复用）。
      const Widget reused = SizedBox(
        width: 300,
        height: 100,
        child: ColoredBox(color: Colors.red),
      );
      await tester.pumpWidget(buildWith(reused));
      await tester.pump();

      final Opacity opacity = tester.widget<Opacity>(
        find.ancestor(
          of: find.byType(ColoredBox),
          matching: find.byType(Opacity),
        ),
      );
      expect(opacity.opacity, 1.0, reason: '复用同一 wrapper 后退场态必须复位，浮层须重新完全可见');
    });
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

    testWidgets('high sensitivity (0.9) dismisses on a 100px horizontal drag',
        (tester) async {
      final dismissed = await dragAndReportDismiss(tester, sensitivity: 0.9);
      expect(dismissed, isTrue);
    });

    testWidgets('low sensitivity (0.1) does NOT dismiss on the same 100px drag',
        (tester) async {
      final dismissed = await dragAndReportDismiss(tester, sensitivity: 0.1);
      expect(dismissed, isFalse);
    });

    testWidgets('same drag distance: high sensitivity fires, low does not',
        (tester) async {
      final highFired = await dragAndReportDismiss(tester, sensitivity: 0.9);
      final lowFired = await dragAndReportDismiss(tester, sensitivity: 0.1);
      expect(highFired, isTrue);
      expect(lowFired, isFalse);
      expect(highFired, isNot(equals(lowFired)));
    });
  });
}
