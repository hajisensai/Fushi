import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:hibiki/src/media/video/video_player_controller.dart';
import 'package:hibiki/src/media/video/video_subtitle_overlay.dart';

VideoPlayerController _stubWithCue(AudioCue cue) {
  final VideoPlayerController c = VideoPlayerController();
  c.setCues(<AudioCue>[cue]);
  c.debugUpdateCueForPosition(cue.startMs + 1); // 命中该 cue
  return c;
}

AudioCue _cue(String raw, {int start = 0, int end = 5000}) {
  final SubtitleMarkup m = parseSubtitleMarkup(raw);
  return AudioCue()
    ..bookKey = 'b'
    ..chapterHref = 'c'
    ..sentenceIndex = 0
    ..textFragmentId = '[data-cue-id="0"]'
    ..text = m.plainText
    ..markup = m
    ..startMs = start
    ..endMs = end
    ..audioFileIndex = 0;
}

void main() {
  testWidgets('an8 anchor aligns subtitle to top + lookup keeps plain text',
      (WidgetTester tester) async {
    final VideoPlayerController c = _stubWithCue(_cue(r'{\an8}トップ'));
    String? tappedSentence;
    int? tappedIndex;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: VideoSubtitleOverlay(
          controller: c,
          onCharTap: (String s, int i, Rect r) {
            tappedSentence = s;
            tappedIndex = i;
          },
        ),
      ),
    ));
    await tester.pump();

    // 顶部锚点：字幕盒落在 overlay 上半部。
    final Rect overlayRect = tester.getRect(find.byType(VideoSubtitleOverlay));
    // BUG-323/TODO-569：每字渲染为 stroke+fill 双层，取 .first（两层同位置）。
    final Offset boxCenter = tester.getCenter(find.text('プ').first);
    expect(boxCenter.dy, lessThan(overlayRect.center.dy));

    // 逐字查词仍传纯文本 + 正确 grapheme 索引。
    await tester.tap(find.text('ト').first);
    expect(tappedSentence, 'トップ');
    expect(tappedIndex, 0);
  });

  testWidgets('italic span renders italic; sibling stays upright',
      (WidgetTester tester) async {
    final VideoPlayerController c = _stubWithCue(_cue(r'{\i1}A{\i0}B'));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: VideoSubtitleOverlay(controller: c)),
    ));
    await tester.pump();
    // BUG-323/TODO-569：每字 stroke+fill 双层，取填充层（foreground==null）断言样式。
    final Text a = tester
        .widgetList<Text>(find.text('A'))
        .firstWhere((Text t) => t.style?.foreground == null);
    final Text b = tester
        .widgetList<Text>(find.text('B'))
        .firstWhere((Text t) => t.style?.foreground == null);
    expect(a.style?.fontStyle, FontStyle.italic);
    expect(b.style?.fontStyle, isNot(FontStyle.italic));
  });

  testWidgets('no markup falls back to bottom-center (backward compatible)',
      (WidgetTester tester) async {
    final AudioCue plain = AudioCue()
      ..bookKey = 'b'
      ..chapterHref = 'c'
      ..sentenceIndex = 0
      ..textFragmentId = '[data-cue-id="0"]'
      ..text = 'そこ'
      ..startMs = 0
      ..endMs = 5000
      ..audioFileIndex = 0; // markup 为 null
    final VideoPlayerController c = _stubWithCue(plain);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: VideoSubtitleOverlay(controller: c)),
    ));
    await tester.pump();
    final Rect overlayRect = tester.getRect(find.byType(VideoSubtitleOverlay));
    // 双层重叠，取 .first（BUG-323/TODO-569）。
    final Offset boxCenter = tester.getCenter(find.text('そ').first);
    expect(boxCenter.dy, greaterThan(overlayRect.center.dy)); // 底部
  });
  testWidgets(
      'respectAssStyle ON: inline c/fn/3c apply; OFF: unified style wins',
      (WidgetTester tester) async {
    // Cue with inline primary color (red \c), font (\fnArial) and outline blue (\3c).
    AudioCue buildCue() => _cue(r'{\c&H0000FF&\fnArial\3c&HFF0000&}A');

    // OFF: fill color follows widget.textColor; \fn/\3c NOT applied (font stays null).
    final VideoPlayerController cOff = _stubWithCue(buildCue());
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: VideoSubtitleOverlay(
          controller: cOff,
          textColor: const Color(0xFF112233),
          fontFamily: 'UnifiedFont',
          respectAssStyle: false,
        ),
      ),
    ));
    await tester.pump();
    // Fill layer: foreground == null (BUG-323/TODO-569 dual layer).
    Text fillOff = tester
        .widgetList<Text>(find.text('A'))
        .firstWhere((Text t) => t.style?.foreground == null);
    // Inline \c red is a legacy span style -> applies even when off.
    expect(fillOff.style?.color, const Color(0xFFFF0000));
    // \fn is gated by respectAssStyle -> off keeps unified font family.
    expect(fillOff.style?.fontFamily, 'UnifiedFont');

    // ON: \fn applies (Arial), \c red still applies.
    final VideoPlayerController cOn = _stubWithCue(buildCue());
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: VideoSubtitleOverlay(
          controller: cOn,
          textColor: const Color(0xFF112233),
          fontFamily: 'UnifiedFont',
          shadowColor: const Color(0xFF000000),
          shadowThickness: 5,
          respectAssStyle: true,
        ),
      ),
    ));
    await tester.pump();
    Text fillOn = tester
        .widgetList<Text>(find.text('A'))
        .firstWhere((Text t) => t.style?.foreground == null);
    expect(fillOn.style?.color, const Color(0xFFFF0000)); // inline \c red
    expect(fillOn.style?.fontFamily, 'Arial'); // \fn respected

    // Stroke layer uses ASS outline color \3c blue when respectAssStyle on.
    final Text strokeOn = tester
        .widgetList<Text>(find.text('A'))
        .firstWhere((Text t) => t.style?.foreground != null);
    expect(strokeOn.style?.foreground?.color, const Color(0xFF0000FF));
  });

  testWidgets('respectAssStyle ON: cueStyle default font/color/outline applied',
      (WidgetTester tester) async {
    // No inline overrides; style comes from V4+ Styles (cueStyle).
    const SubtitleMarkup markup = SubtitleMarkup(
      plainText: 'B',
      spans: <SubtitleSpan>[],
      cueStyle: SubtitleCueStyle(
        fontName: 'CueFont',
        primaryColorArgb: 0xFF00FF00, // green
        outlineColorArgb: 0xFF0000FF, // blue
        outlineWidthPx: 4,
      ),
    );
    final AudioCue cue = AudioCue()
      ..bookKey = 'b'
      ..chapterHref = 'c'
      ..sentenceIndex = 0
      ..textFragmentId = '[data-cue-id="0"]'
      ..text = 'B'
      ..markup = markup
      ..startMs = 0
      ..endMs = 5000
      ..audioFileIndex = 0;
    final VideoPlayerController c = _stubWithCue(cue);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: VideoSubtitleOverlay(
          controller: c,
          textColor: const Color(0xFF112233),
          fontFamily: 'UnifiedFont',
          shadowColor: const Color(0xFF000000),
          shadowThickness: 5,
          respectAssStyle: true,
        ),
      ),
    ));
    await tester.pump();
    final Text fill = tester
        .widgetList<Text>(find.text('B'))
        .firstWhere((Text t) => t.style?.foreground == null);
    expect(fill.style?.color, const Color(0xFF00FF00)); // cueStyle primary
    expect(fill.style?.fontFamily, 'CueFont'); // cueStyle font
    final Text stroke = tester
        .widgetList<Text>(find.text('B'))
        .firstWhere((Text t) => t.style?.foreground != null);
    expect(stroke.style?.foreground?.color, const Color(0xFF0000FF)); // outline
  });
}
