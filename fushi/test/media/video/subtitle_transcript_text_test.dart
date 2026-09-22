import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/subtitle_transcript_text.dart';

void main() {
  test('shared suffix preserves grapheme positions and Latin word starts', () {
    const String text = '😀 日本語と日本語 hello world';
    expect(subtitleGraphemeStartOffsets(text).take(3), <int>[0, 2, 3]);
    expect(subtitleTranscriptLookupSpan(text, 2), (
      start: 2,
      term: '日本語と日本語 hello world',
    ));
    expect(subtitleTranscriptLookupSpan(text, 6), (
      start: 6,
      term: '日本語 hello world',
    ));
    expect(subtitleTranscriptLookupSpan(text, 12), (
      start: 10,
      term: 'hello world',
    ));
  });

  testWidgets('caret handles key down and up before ancestor game controls', (
    WidgetTester tester,
  ) async {
    final List<LogicalKeyboardKey> escaped = <LogicalKeyboardKey>[];
    final List<int> lookups = <int>[];
    const Key paragraph = ValueKey<String>('paragraph');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Focus(
            onKeyEvent: (_, KeyEvent event) {
              escaped.add(event.logicalKey);
              return KeyEventResult.ignored;
            },
            child: SubtitleTranscriptText(
              text: '😀日本語',
              textKey: paragraph,
              style: subtitleTranscriptTextStyle(fontSize: 14, selected: true),
              keyboardLookup: true,
              onLookup: (int index, Rect _) => lookups.add(index),
            ),
          ),
        ),
      ),
    );
    Focus.of(tester.element(find.byKey(paragraph))).requestFocus();
    await tester.pump();
    for (final LogicalKeyboardKey key in <LogicalKeyboardKey>[
      LogicalKeyboardKey.arrowRight,
      LogicalKeyboardKey.arrowLeft,
      LogicalKeyboardKey.end,
      LogicalKeyboardKey.enter,
      LogicalKeyboardKey.home,
      LogicalKeyboardKey.numpadEnter,
      LogicalKeyboardKey.space,
    ]) {
      await tester.sendKeyEvent(key);
      await tester.pump();
    }
    expect(lookups, <int>[3, 0, 0]);
    expect(escaped, isEmpty);
    expect(
      tester.widget<RichText>(find.byKey(paragraph)).text.toPlainText(),
      '😀日本語',
    );
  });
}
