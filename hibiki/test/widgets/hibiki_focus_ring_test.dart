import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/components/hibiki_focus_ring.dart';

void main() {
  testWidgets('HibikiFocusRing builds and overlays its child',
      (WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home: HibikiFocusRing(
        child: Scaffold(
          body: Center(
            child: ElevatedButton(onPressed: () {}, child: const Text('x')),
          ),
        ),
      ),
    ));
    await tester.pump();
    expect(find.text('x'), findsOneWidget);
    expect(find.byType(HibikiFocusRing), findsOneWidget);
  });
}
