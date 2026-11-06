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

/// BUG-3691：特效字幕把同一句拆成两层同文本、同起点的事件同位叠画（Layer 0 金色底、
/// Layer 1 白字）。查词高亮按「句文本 + 起点」认 cue，两层都会命中。
const String _kAssTwoLayers = r'''
[Script Info]
ScriptType: v4.00+
PlayResX: 1280
PlayResY: 720

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Gold,Trebuchet MS,45,&H0040C0F0,&H000000FF,&H00104060,&H00000000,-1,0,0,0,100,100,0,0,1,3,0,2,10,10,15,1
Style: White,Trebuchet MS,45,&H00FFFFFF,&H000000FF,&H00020713,&H00000000,-1,0,0,0,100,100,0,0,1,1.7,0,2,10,10,15,1

[Events]
Format: Layer, Start, End, Style, Actor, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:02:23.10,0:02:24.47,Gold,,0,0,0,,Knocking
Dialogue: 1,0:02:23.10,0:02:24.47,White,,0,0,0,,Knocking
''';

/// 左右分屏卡拉 OK（BUG-1775 形态）：两条同文本事件各 `\clip` 半边、不同 Layer 同位拼成一行。
const String _kAssSplitClip = r'''
[Script Info]
ScriptType: v4.00+
PlayResX: 1280
PlayResY: 720

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,Trebuchet MS,45,&H00FFFFFF,&H000000FF,&H00020713,&H00000000,-1,0,0,0,100,100,0,0,1,1.7,0,2,10,10,15,1

[Events]
Format: Layer, Start, End, Style, Actor, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:02:23.10,0:02:24.47,Default,,0,0,0,,{\clip(0,0,640,720)}Knocking
Dialogue: 1,0:02:23.10,0:02:24.47,Default,,0,0,0,,{\clip(640,0,1280,720)}Knocking
''';

Future<List<AudioCue>> _pumpAss(
  WidgetTester tester,
  String ass, {
  required SubtitleLookupHighlight? Function(List<AudioCue> cues) highlight,
}) async {
  final List<AudioCue> cues = AssParser.parseString(
    content: ass,
    bookKey: 'layers',
  );
  final VideoPlayerController c = VideoPlayerController();
  addTearDown(c.dispose);
  c.setCues(cues);
  c.debugSetPositionForTesting(_kPosMs);
  c.debugUpdateCueForPosition(_kPosMs);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: VideoSubtitleOverlay(
          controller: c,
          respectAssStyle: true,
          lookupHighlight: highlight(cues),
        ),
      ),
    ),
  );
  await tester.pump();
  return cues;
}

Future<VideoPlayerController> _pump(
  WidgetTester tester, {
  required SubtitleLookupHighlight? highlight,
}) async {
  final List<AudioCue> cues = AssParser.parseString(
    content: _kAss,
    bookKey: 'komi',
  );
  final VideoPlayerController c = VideoPlayerController();
  addTearDown(c.dispose);
  c.setCues(cues);
  c.debugSetPositionForTesting(_kPosMs);
  c.debugUpdateCueForPosition(_kPosMs);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: VideoSubtitleOverlay(
          controller: c,
          respectAssStyle: true,
          lookupHighlight: highlight,
        ),
      ),
    ),
  );
  await tester.pump();
  return c;
}

/// 高亮盒里包着的 Text（BUG-3287 起带描边的 cue 里是描边遍那份）。
List<Text> _highlightedTexts(WidgetTester tester) {
  return tester
      .widgetList<SubtitleLookupHighlightBox>(
        find.byType(SubtitleLookupHighlightBox),
      )
      .map(
        (SubtitleLookupHighlightBox box) => tester.widget<Text>(
          find
              .descendant(of: find.byWidget(box), matching: find.byType(Text))
              .first,
        ),
      )
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
          find.byType(SubtitleLookupHighlightBox),
        )
        .toList();
    expect(
      boxes.map((SubtitleLookupHighlightBox b) => b.first).toList(),
      <bool>[true, false, false, false, false],
    );
    expect(boxes.map((SubtitleLookupHighlightBox b) => b.last).toList(), <bool>[
      false,
      false,
      false,
      false,
      true,
    ]);
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
          find.byType(SubtitleLookupHighlightBox),
        )
        .toList();
    final double strokeWidth = texts.first.style!.foreground!.strokeWidth;
    expect(strokeWidth, greaterThan(0));
    // 外扩 = 可见描边宽（居中 stroke 的外半边）；Paint.strokeWidth 以 float32 存。
    expect(boxes.first.bleedX, closeTo(strokeWidth / 2, 1e-4));
    expect(boxes.first.bleedY, closeTo(strokeWidth / 2, 1e-4));
    // 上下每个字都外扩；左右只在首 / 尾外扩（中间相接不叠色）。
    expect(boxes.first.paintOutsets.left, boxes.first.bleedX);
    expect(boxes.first.paintOutsets.right, 0);
    expect(
      boxes[2].paintOutsets,
      EdgeInsets.fromLTRB(0, boxes[2].bleedY, 0, boxes[2].bleedY),
    );
    expect(boxes.last.paintOutsets.right, boxes.last.bleedX);
  });

  // 审查 PR #2083：`\fscx` / `\fscy` 把字形连同描边一起缩放（_applySpanScale），
  // 高亮外扩必须按同一缩放分轴：左右 × sx、上下 × sy。
  testWidgets('带 span 缩放的 cue：外扩随缩放分轴', (WidgetTester tester) async {
    final List<AudioCue> cues = AssParser.parseString(
      content: _kAssScaled,
      bookKey: 'scaled',
    );
    final VideoPlayerController c = VideoPlayerController();
    addTearDown(c.dispose);
    c.setCues(cues);
    c.debugSetPositionForTesting(_kPosMs);
    c.debugUpdateCueForPosition(_kPosMs);
    await tester.pumpWidget(
      MaterialApp(
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
      ),
    );
    await tester.pump();
    expect(c.currentCue?.text, 'Scaled');
    final List<Text> texts = _highlightedTexts(tester);
    expect(texts, hasLength(3));
    final double strokeWidth = texts.first.style!.foreground!.strokeWidth;
    expect(strokeWidth, greaterThan(0));
    final List<SubtitleLookupHighlightBox> boxes = tester
        .widgetList<SubtitleLookupHighlightBox>(
          find.byType(SubtitleLookupHighlightBox),
        )
        .toList();
    for (final SubtitleLookupHighlightBox b in boxes) {
      expect(b.bleedX, closeTo(strokeWidth / 2 * 0.5, 1e-4));
      expect(b.bleedY, closeTo(strokeWidth / 2 * 2.0, 1e-4));
    }
    expect(boxes.first.paintOutsets.left, boxes.first.bleedX);
    expect(boxes.first.paintOutsets.top, boxes.first.bleedY);
  });

  testWidgets('不尊重 .ass（软投影外观）不外扩', (WidgetTester tester) async {
    final List<AudioCue> cues = AssParser.parseString(
      content: _kAss,
      bookKey: 'komi',
    );
    final VideoPlayerController c = VideoPlayerController();
    addTearDown(c.dispose);
    c.setCues(cues);
    c.debugSetPositionForTesting(_kPosMs);
    c.debugUpdateCueForPosition(_kPosMs);
    await tester.pumpWidget(
      MaterialApp(
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
      ),
    );
    await tester.pump();
    final List<SubtitleLookupHighlightBox> boxes = tester
        .widgetList<SubtitleLookupHighlightBox>(
          find.byType(SubtitleLookupHighlightBox),
        )
        .toList();
    expect(boxes, hasLength(5));
    expect(
      boxes.every(
        (SubtitleLookupHighlightBox b) => b.bleedX == 0 && b.bleedY == 0,
      ),
      isTrue,
    );
  });
  // BUG-3691：两层同文本事件各自认领高亮时，底色在每层描边遍各画一次——半透明叠成
  // 近乎不透明，且上层那份画在下层填充遍之上，把下层字形整块盖住（用户截图）。
  testWidgets('多层同文本事件：高亮只画一份，且归最底层', (WidgetTester tester) async {
    final List<AudioCue> cues = await _pumpAss(
      tester,
      _kAssTwoLayers,
      highlight: (List<AudioCue> cues) => SubtitleLookupHighlight(
        sentence: 'Knocking',
        cueStartMs: cues.first.startMs,
        graphemeStart: 2,
        graphemeCount: 1,
      ),
    );
    expect(cues, hasLength(2));
    // 两层都在屏上（各 8 个字形的填充遍 'o'）。
    expect(find.text('o'), findsNWidgets(4));
    final List<Text> texts = _highlightedTexts(tester);
    expect(texts.map((Text t) => t.data).toList(), <String>['o']);
    // 认领的是 Layer 0（金色样式：描边色 &H00104060）——它的描边遍在整组最底。
    expect(texts.single.style?.foreground?.color.toARGB32(), 0xFF604010);
  });

  testWidgets('左右分屏 clip：每个裁剪窗各画自己那半，拼成整段', (WidgetTester tester) async {
    await _pumpAss(
      tester,
      _kAssSplitClip,
      highlight: (List<AudioCue> cues) => SubtitleLookupHighlight(
        sentence: 'Knocking',
        cueStartMs: cues.first.startMs,
        graphemeStart: 0,
        graphemeCount: 8,
      ),
    );
    // 两个互不重叠的裁剪窗各认领一次（只认一条会只剩半边高亮）。
    expect(find.byType(SubtitleLookupHighlightBox), findsNWidgets(16));
  });

  group('resolveLookupHighlightOwners', () {
    AudioCue cue(int i, {String text = 'A', int start = 100}) => AudioCue()
      ..text = text
      ..startMs = start
      ..endMs = start + 1000
      ..sentenceIndex = i;
    const SubtitleLookupHighlight h = SubtitleLookupHighlight(
      sentence: 'A',
      cueStartMs: 100,
      graphemeStart: 0,
      graphemeCount: 1,
    );

    test('无裁剪：只认绘制顺序里最先画的那条同身份 cue', () {
      final AudioCue a = cue(0), b = cue(1), other = cue(2, text: 'B');
      final Set<AudioCue> owners = resolveLookupHighlightOwners(
        highlight: h,
        cuesInPaintOrder: <AudioCue>[other, a, b],
        clipKeyOf: (_) => null,
      );
      expect(owners, hasLength(1));
      expect(identical(owners.single, a), isTrue);
    });

    test('全带裁剪：不同裁剪窗各认一条，同裁剪窗只认最底那条', () {
      final AudioCue l0 = cue(0), r0 = cue(1), l1 = cue(2);
      final Map<AudioCue, String> clip = <AudioCue, String>{
        l0: 'left',
        r0: 'right',
        l1: 'left',
      };
      final Set<AudioCue> owners = resolveLookupHighlightOwners(
        highlight: h,
        cuesInPaintOrder: <AudioCue>[l0, r0, l1],
        clipKeyOf: (AudioCue c) => clip[c],
      );
      expect(owners.length, 2);
      expect(owners.contains(l0) && owners.contains(r0), isTrue);
      expect(owners.contains(l1), isFalse);
    });

    test('有无裁剪的同身份 cue：只认那一条（它覆盖整段）', () {
      final AudioCue clipped = cue(0), full = cue(1);
      final Set<AudioCue> owners = resolveLookupHighlightOwners(
        highlight: h,
        cuesInPaintOrder: <AudioCue>[clipped, full],
        clipKeyOf: (AudioCue c) => identical(c, clipped) ? 'left' : null,
      );
      expect(owners, hasLength(1));
      expect(identical(owners.single, full), isTrue);
    });

    test('null / 空区间 / 起点不同：谁都不认', () {
      expect(
        resolveLookupHighlightOwners(
          highlight: null,
          cuesInPaintOrder: <AudioCue>[cue(0)],
          clipKeyOf: (_) => null,
        ),
        isEmpty,
      );
      expect(
        resolveLookupHighlightOwners(
          highlight: h,
          cuesInPaintOrder: <AudioCue>[cue(0, start: 101)],
          clipKeyOf: (_) => null,
        ),
        isEmpty,
      );
    });
  });
}

/// 该 .ass 首条 cue 的起点毫秒（0:02:23.10）。
int c0StartMs() => 143100;
