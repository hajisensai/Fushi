import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/components/clipboard_lookup_text_panel.dart';

void main() {
  Widget buildSubject({
    required String text,
    required void Function(String query, Rect rect) onLookup,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: ClipboardLookupTextPanel(
          text: text,
          onLookup: onLookup,
        ),
      ),
    );
  }

  testWidgets('tapping a character looks up the suffix from that character',
      (WidgetTester tester) async {
    String? query;
    Rect? rect;

    await tester.pumpWidget(
      buildSubject(
        text: 'abcdef',
        onLookup: (String value, Rect localRect) {
          query = value;
          rect = localRect;
        },
      ),
    );

    await tester.tap(find.text('c'));

    expect(query, 'cdef');
    expect(rect, isNotNull);
    expect(rect, isNot(Rect.zero));
  });

  testWidgets('tap rect is reported in the nearest stack coordinate space',
      (WidgetTester tester) async {
    Rect? rect;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: <Widget>[
              Positioned(
                left: 40,
                top: 30,
                child: ClipboardLookupTextPanel(
                  text: 'abc',
                  onLookup: (_, Rect localRect) {
                    rect = localRect;
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );

    await tester.tap(find.text('a'));

    expect(rect, isNotNull);
    expect(rect!.left, greaterThan(40));
    expect(rect!.top, greaterThan(30));
  });

  testWidgets('blank text renders nothing and cannot trigger lookup',
      (WidgetTester tester) async {
    bool called = false;

    await tester.pumpWidget(
      buildSubject(
        text: '   ',
        onLookup: (_, __) => called = true,
      ),
    );

    expect(find.byType(ClipboardLookupTextPanel), findsOneWidget);
    expect(find.byType(GestureDetector), findsNothing);
    expect(called, isFalse);
  });
}
