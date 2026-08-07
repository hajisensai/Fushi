import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/fushi_focusable.dart';

void main() {
  testWidgets('FushiFocusable activates onTap via gameButtonA/Enter',
      (WidgetTester tester) async {
    int taps = 0;
    final FocusNode node = FocusNode();
    addTearDown(node.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: FushiFocusable(
          focusNode: node,
          autofocus: true,
          onTap: () => taps++,
          child: const Text('btn'),
        ),
      ),
    ));
    await tester.pump();
    expect(node.hasFocus, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonA);
    await tester.pump();
    expect(taps, 1);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(taps, 2);
  });

  testWidgets('FushiFocusable still works on pointer tap',
      (WidgetTester tester) async {
    int taps = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: FushiFocusable(onTap: () => taps++, child: const Text('btn')),
      ),
    ));
    await tester.tap(find.text('btn'));
    await tester.pump();
    expect(taps, 1);
  });
}
