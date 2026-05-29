import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/components/hibiki_focus_ring.dart';

void main() {
  test('HibikiFocusRing uses design token radius', () {
    final String source =
        File('lib/src/utils/components/hibiki_focus_ring.dart')
            .readAsStringSync();

    expect(source, contains('HibikiDesignTokens.of(context)'));
    expect(source, contains('tokens.radii.chipRadius'));
    expect(source, isNot(contains('BorderRadius.circular(8)')));
  });

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
