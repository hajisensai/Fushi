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
  });
}
