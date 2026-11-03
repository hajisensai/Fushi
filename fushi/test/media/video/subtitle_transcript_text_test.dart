import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
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

  test('lookup highlight grapheme range maps to UTF-16 and clamps', () {
    // '😀' is two UTF-16 units: grapheme 1 starts at offset 2.
    expect(
      subtitleTranscriptHighlightUtf16Range('😀日本語', (start: 1, count: 2)),
      (start: 2, count: 2),
    );
    expect(
      subtitleTranscriptHighlightUtf16Range('😀日本語', (start: 0, count: 9)),
      (start: 0, count: 5),
    );
    expect(subtitleTranscriptHighlightUtf16Range('日本語', null), isNull);
    expect(
      subtitleTranscriptHighlightUtf16Range('日本語', (start: 3, count: 1)),
      isNull,
    );
    expect(
      subtitleTranscriptHighlightUtf16Range('日本語', (start: 0, count: 0)),
      isNull,
    );
  });

  testWidgets('lookup highlight paints under the text without moving it', (
    WidgetTester tester,
  ) async {
    const Key paragraph = ValueKey<String>('paragraph');
    const Key highlight = ValueKey<String>(
      'subtitle-transcript-lookup-highlight',
    );
    final List<(int, Rect)> lookups = <(int, Rect)>[];
    Widget app(SubtitleTranscriptHighlightRange? range) => MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 120,
          child: SubtitleTranscriptText(
            text: '今日はいい天気ですね。明日も晴れるかな',
            textKey: paragraph,
            style: subtitleTranscriptTextStyle(fontSize: 20, selected: false),
            lookupHighlight: range,
            onLookup: (int index, Rect anchor) => lookups.add((index, anchor)),
          ),
        ),
      ),
    );
    await tester.pumpWidget(app(null));
    // No highlight: the widget tree is exactly as before (no painter layer).
    expect(find.byKey(highlight), findsNothing);
    final Rect before = tester.getRect(find.byKey(paragraph));

    await tester.pumpWidget(app((start: 5, count: 2)));
    expect(find.byKey(highlight), findsOneWidget);
    expect(tester.getRect(find.byKey(paragraph)), before);
    final CustomPaint paint = tester.widget<CustomPaint>(find.byKey(highlight));
    expect(paint.painter, isNotNull);
    expect(paint.foregroundPainter, isNull);

    // Hit testing still resolves the tapped glyph through the highlight layer.
    final RenderParagraph render = tester.renderObject<RenderParagraph>(
      find.byKey(paragraph),
    );
    final Offset local = render
        .getBoxesForSelection(
          const TextSelection(baseOffset: 5, extentOffset: 6),
        )
        .first
        .toRect()
        .center;
    await tester.tapAt(render.localToGlobal(local));
    await tester.pump();
    expect(lookups.single.$1, 5);
    expect(lookups.single.$2.contains(render.localToGlobal(local)), isTrue);
  });

  testWidgets('an owner-driven caret shows without focus and clamps', (
    WidgetTester tester,
  ) async {
    const Key paragraph = ValueKey<String>('paragraph');
    Future<void> pumpCaret(int? caret) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SubtitleTranscriptText(
            text: '😀日本語',
            textKey: paragraph,
            style: subtitleTranscriptTextStyle(fontSize: 14, selected: true),
            keyboardLookup: true,
            caret: caret,
            onLookup: (int index, Rect _) {},
          ),
        ),
      ),
    );
    List<String> spans() {
      final InlineSpan text = tester
          .widget<RichText>(find.byKey(paragraph))
          .text;
      final List<String> parts = <String>[];
      text.visitChildren((InlineSpan span) {
        if (span is TextSpan && span.text != null) parts.add(span.text!);
        return true;
      });
      return parts;
    }

    await pumpCaret(null);
    expect(spans(), <String>['😀日本語'], reason: 'No caret without focus');

    await pumpCaret(2);
    expect(spans(), <String>['😀日', '本', '語']);

    await pumpCaret(99);
    expect(spans(), <String>['😀日本', '語', '']);
  });

  testWidgets('a controlled caret leaves movement to its owner and looks up '
      'at the owner caret', (WidgetTester tester) async {
    const Key paragraph = ValueKey<String>('paragraph');
    final FocusNode lineFocus = FocusNode();
    addTearDown(lineFocus.dispose);
    final List<LogicalKeyboardKey> bubbled = <LogicalKeyboardKey>[];
    final List<int> lookups = <int>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Focus(
            onKeyEvent: (FocusNode node, KeyEvent event) {
              if (event is KeyDownEvent) bubbled.add(event.logicalKey);
              return KeyEventResult.handled;
            },
            child: Focus(
              focusNode: lineFocus,
              child: SubtitleTranscriptText(
                text: '日本語',
                textKey: paragraph,
                style: subtitleTranscriptTextStyle(
                  fontSize: 14,
                  selected: true,
                ),
                keyboardLookup: true,
                caret: 1,
                onLookup: (int index, Rect _) => lookups.add(index),
              ),
            ),
          ),
        ),
      ),
    );
    // Focus the line's own Focus (the one keyboardLookup adds).
    final Element inner = tester.element(find.byKey(paragraph));
    Focus.of(inner).requestFocus();
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.end);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(bubbled, <LogicalKeyboardKey>[
      LogicalKeyboardKey.arrowRight,
      LogicalKeyboardKey.end,
    ]);
    expect(lookups, <int>[1], reason: 'Enter looks up at the owner caret');
    final List<String> parts = <String>[];
    tester.widget<RichText>(find.byKey(paragraph)).text.visitChildren((
      InlineSpan span,
    ) {
      if (span is TextSpan && span.text != null) parts.add(span.text!);
      return true;
    });
    expect(parts, <String>['日', '本', '語'], reason: 'Caret stays at 1');
  });
}
