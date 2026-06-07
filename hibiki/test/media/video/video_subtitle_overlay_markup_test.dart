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
    final Offset boxCenter = tester.getCenter(find.text('プ'));
    expect(boxCenter.dy, lessThan(overlayRect.center.dy));

    // 逐字查词仍传纯文本 + 正确 grapheme 索引。
    await tester.tap(find.text('ト'));
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
    final Text a = tester.widget<Text>(find.text('A'));
    final Text b = tester.widget<Text>(find.text('B'));
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
    final Offset boxCenter = tester.getCenter(find.text('そ'));
    expect(boxCenter.dy, greaterThan(overlayRect.center.dy)); // 底部
  });
}
