import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_player_controller.dart';
import 'package:fushi/src/media/video/video_subtitle_overlay.dart';
import 'package:fushi_audio/fushi_audio.dart';

/// BUG-2091：视频字幕查词后，被查词在字幕上垫底色高亮（与阅读器正文查词高亮同语义）。
/// 高亮按 cue 身份（句文本 + 起点毫秒）+ grapheme 区间匹配；区间外 / 别的 cue /
/// 传 null 一律不画；首尾字位各自收圆角、中间方角。
const String _kAss = r'''
[Script Info]
ScriptType: v4.00+
PlayResX: 1280
PlayResY: 720

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,Trebuchet MS,45,&H00FFFFFF,&H000000FF,&H00020713,&H00000000,-1,0,0,0,100,100,0,0,1,1.7,0,2,10,10,15,1

[Events]
Format: Layer, Start, End, Style, Actor, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:02:23.10,0:02:24.47,Default,,0,0,0,,{\i1}She's not going for it…{\i0}
''';

const int _kPosMs = 143500;

Future<VideoPlayerController> _pump(
  WidgetTester tester, {
  required SubtitleLookupHighlight? highlight,
}) async {
  final List<AudioCue> cues =
      AssParser.parseString(content: _kAss, bookKey: 'komi');
  final VideoPlayerController c = VideoPlayerController();
  addTearDown(c.dispose);
  c.setCues(cues);
  c.debugSetPositionForTesting(_kPosMs);
  c.debugUpdateCueForPosition(_kPosMs);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: VideoSubtitleOverlay(
        controller: c,
        respectAssStyle: true,
        lookupHighlight: highlight,
      ),
    ),
  ));
  await tester.pump();
  return c;
}

/// 高亮盒里包着的字符（fill 层 Text 的文本）。
List<String> _highlightedChars(WidgetTester tester) {
  return tester
      .widgetList<SubtitleLookupHighlightBox>(
          find.byType(SubtitleLookupHighlightBox))
      .map((SubtitleLookupHighlightBox box) {
    final Finder texts = find.descendant(
      of: find.byWidget(box),
      matching: find.byType(Text),
    );
    return tester
        .widgetList<Text>(texts)
        .firstWhere((Text t) => t.style?.foreground == null)
        .data!;
  }).toList();
}

void main() {
  testWidgets('区间内的字位垫底色，首尾收圆角、中间方角', (WidgetTester tester) async {
    final VideoPlayerController c = await _pump(
      tester,
      highlight: SubtitleLookupHighlight(
        sentence: "She's not going for it…",
        cueStartMs: c0StartMs(),
        graphemeStart: 0,
        graphemeCount: 5,
      ),
    );
    expect(c.currentCue?.text, "She's not going for it…");
    expect(_highlightedChars(tester), <String>['S', 'h', 'e', "'", 's']);
    final List<SubtitleLookupHighlightBox> boxes = tester
        .widgetList<SubtitleLookupHighlightBox>(
            find.byType(SubtitleLookupHighlightBox))
        .toList();
    expect(boxes.map((SubtitleLookupHighlightBox b) => b.first).toList(),
        <bool>[true, false, false, false, false]);
    expect(boxes.map((SubtitleLookupHighlightBox b) => b.last).toList(),
        <bool>[false, false, false, false, true]);
  });

  testWidgets('高亮不改字符布局几何（逐字命中矩形零位移）', (WidgetTester tester) async {
    await _pump(tester, highlight: null);
    final Rect plain = tester.getRect(find.text('S').first);
    await _pump(
      tester,
      highlight: SubtitleLookupHighlight(
        sentence: "She's not going for it…",
        cueStartMs: c0StartMs(),
        graphemeStart: 0,
        graphemeCount: 5,
      ),
    );
    expect(tester.getRect(find.text('S').first), plain);
  });

  testWidgets('cue 身份不匹配（别的句 / 别的起点）或 null 一律不画', (WidgetTester tester) async {
    await _pump(tester, highlight: null);
    expect(find.byType(SubtitleLookupHighlightBox), findsNothing);

    await _pump(
      tester,
      highlight: SubtitleLookupHighlight(
        sentence: "She's not going for it…",
        cueStartMs: c0StartMs() + 1,
        graphemeStart: 0,
        graphemeCount: 5,
      ),
    );
    expect(find.byType(SubtitleLookupHighlightBox), findsNothing);

    await _pump(
      tester,
      highlight: SubtitleLookupHighlight(
        sentence: 'Another line',
        cueStartMs: c0StartMs(),
        graphemeStart: 0,
        graphemeCount: 5,
      ),
    );
    expect(find.byType(SubtitleLookupHighlightBox), findsNothing);
  });

  testWidgets('词中间的区间只亮那一段', (WidgetTester tester) async {
    await _pump(
      tester,
      highlight: SubtitleLookupHighlight(
        sentence: "She's not going for it…",
        cueStartMs: c0StartMs(),
        graphemeStart: 10,
        graphemeCount: 5,
      ),
    );
    expect(_highlightedChars(tester), <String>['g', 'o', 'i', 'n', 'g']);
  });
}

/// 该 .ass 首条 cue 的起点毫秒（0:02:23.10）。
int c0StartMs() => 143100;
