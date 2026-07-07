import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/stat_ring.dart';

void main() {
  Widget host(Widget child) => MaterialApp(
        home: Scaffold(body: Center(child: child)),
      );

  testWidgets('StatRing renders value, detail and caption', (tester) async {
    await tester.pumpWidget(host(
      const StatRing(
        fraction: 0.62,
        color: Colors.blue,
        trackColor: Colors.grey,
        value: '62%',
        detail: '3100/5000',
        caption: '字数',
      ),
    ));
    expect(find.text('62%'), findsOneWidget);
    expect(find.text('3100/5000'), findsOneWidget);
    expect(find.text('字数'), findsOneWidget);
    // painter mounted
    expect(find.byType(CustomPaint), findsWidgets);
  });

  testWidgets('StatRing omits detail when null', (tester) async {
    await tester.pumpWidget(host(
      const StatRing(
        fraction: 0.0,
        color: Colors.blue,
        trackColor: Colors.grey,
        value: '0%',
        caption: '时长',
      ),
    ));
    expect(find.text('0%'), findsOneWidget);
    expect(find.text('时长'), findsOneWidget);
  });

  group('StatRingPainter', () {
    test('shouldRepaint reacts to fraction/color changes', () {
      final StatRingPainter a = StatRingPainter(
        fraction: 0.5,
        color: Colors.blue,
        trackColor: Colors.grey,
        strokeWidth: 9,
      );
      final StatRingPainter same = StatRingPainter(
        fraction: 0.5,
        color: Colors.blue,
        trackColor: Colors.grey,
        strokeWidth: 9,
      );
      final StatRingPainter diff = StatRingPainter(
        fraction: 0.8,
        color: Colors.blue,
        trackColor: Colors.grey,
        strokeWidth: 9,
      );
      expect(a.shouldRepaint(same), isFalse);
      expect(a.shouldRepaint(diff), isTrue);
    });
  });
}
