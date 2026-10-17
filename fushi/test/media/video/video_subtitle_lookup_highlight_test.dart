import 'package:material_ui/material_ui.dart';
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

/// 同一样式（带描边）、整句 span 级静态缩放 `\fscx50\fscy200` 的 cue。
const String _kAssScaled = r'''
[Script Info]
ScriptType: v4.00+
PlayResX: 1280
PlayResY: 720

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,Trebuchet MS,45,&H00FFFFFF,&H000000FF,&H00020713,&H00000000,-1,0,0,0,100,100,0,0,1,1.7,0,2,10,10,15,1

[Events]
Format: Layer, Start, End, Style, Actor, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:02:23.10,0:02:24.47,Default,,0,0,0,,{\fscx50\fscy200}Scaled
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

/// 高亮盒里包着的 Text（BUG-3287 起带描边的 cue 里是描边遍那份）。
List<Text> _highlightedTexts(WidgetTester tester) {
  return tester
      .widgetList<SubtitleLookupHighlightBox>(
          find.byType(SubtitleLookupHighlightBox))
      .map((SubtitleLookupHighlightBox box) => tester.widget<Text>(find
          .descendant(of: find.byWidget(box), matching: find.byType(Text))
          .first))
      .toList();
}

/// 高亮盒里包着的字符。
List<String> _highlightedChars(WidgetTester tester) =>
    _highlightedTexts(tester).map((Text t) => t.data!).toList();

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

  // BUG-3287：带 .ass 描边的字幕，高亮底色必须画在描边遍（最底层）并按描边可见宽
  // 外扩——此前挂在填充遍上，整个填充遍压在描边遍之上，描边外缘露在底色外面。
  testWidgets('带描边的 cue：底色在描边层之下并外扩盖住描边', (WidgetTester tester) async {
    await _pump(
      tester,
      highlight: SubtitleLookupHighlight(
        sentence: "She's not going for it…",
        cueStartMs: c0StartMs(),
        graphemeStart: 0,
        graphemeCount: 5,
      ),
    );
    // 每个高亮盒只包描边遍的字（foreground 是描边画笔），不再包填充遍的字。
    final List<Text> texts = _highlightedTexts(tester);
    expect(texts, hasLength(5));
    for (final Text t in texts) {
      expect(t.style?.foreground?.style, PaintingStyle.stroke);
    }
    final List<SubtitleLookupHighlightBox> boxes = tester
        .widgetList<SubtitleLookupHighlightBox>(
            find.byType(SubtitleLookupHighlightBox))
        .toList();
    final double strokeWidth = texts.first.style!.foreground!.strokeWidth;
    expect(strokeWidth, greaterThan(0));
    // 外扩 = 可见描边宽（居中 stroke 的外半边）；Paint.strokeWidth 以 float32 存。
    expect(boxes.first.bleedX, closeTo(strokeWidth / 2, 1e-4));
    expect(boxes.first.bleedY, closeTo(strokeWidth / 2, 1e-4));
    // 上下每个字都外扩；左右只在首 / 尾外扩（中间相接不叠色）。
    expect(boxes.first.paintOutsets.left, boxes.first.bleedX);
    expect(boxes.first.paintOutsets.right, 0);
    expect(boxes[2].paintOutsets,
        EdgeInsets.fromLTRB(0, boxes[2].bleedY, 0, boxes[2].bleedY));
    expect(boxes.last.paintOutsets.right, boxes.last.bleedX);
  });

  // 审查 PR #2083：`\fscx` / `\fscy` 把字形连同描边一起缩放（_applySpanScale），
  // 高亮外扩必须按同一缩放分轴：左右 × sx、上下 × sy。
  testWidgets('带 span 缩放的 cue：外扩随缩放分轴', (WidgetTester tester) async {
    final List<AudioCue> cues =
        AssParser.parseString(content: _kAssScaled, bookKey: 'scaled');
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
          lookupHighlight: SubtitleLookupHighlight(
            sentence: 'Scaled',
            cueStartMs: c0StartMs(),
            graphemeStart: 0,
            graphemeCount: 3,
          ),
        ),
      ),
    ));
    await tester.pump();
    expect(c.currentCue?.text, 'Scaled');
    final List<Text> texts = _highlightedTexts(tester);
    expect(texts, hasLength(3));
    final double strokeWidth = texts.first.style!.foreground!.strokeWidth;
    expect(strokeWidth, greaterThan(0));
    final List<SubtitleLookupHighlightBox> boxes = tester
        .widgetList<SubtitleLookupHighlightBox>(
            find.byType(SubtitleLookupHighlightBox))
        .toList();
    for (final SubtitleLookupHighlightBox b in boxes) {
      expect(b.bleedX, closeTo(strokeWidth / 2 * 0.5, 1e-4));
      expect(b.bleedY, closeTo(strokeWidth / 2 * 2.0, 1e-4));
    }
    expect(boxes.first.paintOutsets.left, boxes.first.bleedX);
    expect(boxes.first.paintOutsets.top, boxes.first.bleedY);
  });

  testWidgets('不尊重 .ass（软投影外观）不外扩', (WidgetTester tester) async {
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
          lookupHighlight: SubtitleLookupHighlight(
            sentence: "She's not going for it…",
            cueStartMs: c0StartMs(),
            graphemeStart: 0,
            graphemeCount: 5,
          ),
        ),
      ),
    ));
    await tester.pump();
    final List<SubtitleLookupHighlightBox> boxes = tester
        .widgetList<SubtitleLookupHighlightBox>(
            find.byType(SubtitleLookupHighlightBox))
        .toList();
    expect(boxes, hasLength(5));
    expect(
        boxes.every(
            (SubtitleLookupHighlightBox b) => b.bleedX == 0 && b.bleedY == 0),
        isTrue);
  });
}

/// 该 .ass 首条 cue 的起点毫秒（0:02:23.10）。
int c0StartMs() => 143100;
