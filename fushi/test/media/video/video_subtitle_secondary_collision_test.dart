import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_player_controller.dart';
import 'package:fushi/src/media/video/video_subtitle_overlay.dart';
import 'package:fushi_audio/fushi_audio.dart';

/// 副字幕锚点组让开定位字幕 / 主字幕（BanG Dream! S2E13 真值形状）。
///
/// 英文字幕组轨作副字幕：罗马音是 `\pos` 顶部定位行，英文对白是底部样式行、被「副字幕
/// 对侧置顶」拽到顶部——两者硬叠在一起；控制条一出现英文行又单独下移（一个动一个不动）。
/// 修复：副字幕锚点组摆放时让开已在屏的定位盒与主字幕盒（[resolveCueYieldOffset]）。
AudioCue _cue(String text, {SubtitleMarkup? markup}) => AudioCue()
  ..bookKey = 'b'
  ..chapterHref = 'ch'
  ..sentenceIndex = 0
  ..textFragmentId = ''
  ..text = text
  ..markup = markup
  ..startMs = 0
  ..endMs = 6000
  ..audioFileIndex = 0;

/// 顶部居中 `\an8\pos(640,10)`（PlayRes 1280×720）的罗马音行。
AudioCue _romaji(String text) => _cue(
  text,
  markup: SubtitleMarkup(
    plainText: text,
    spans: const <SubtitleSpan>[],
    anchor: const SubtitleAnchor(SubtitleVAlign.top, SubtitleHAlign.center),
    posFraction: const SubtitlePos(0.5, 10 / 720),
    playResY: 720,
  ),
);

Rect _textRect(WidgetTester tester, String text) {
  final Finder f = find.byWidgetPredicate(
    (Widget w) => w is Text && w.data == text && w.style?.foreground == null,
  );
  if (f.evaluate().isNotEmpty) return tester.getRect(f.first);
  // 逐字渲染：取该行全部非空白字形（各行用互不相交的字母，不会串行）的并集。
  final Set<String> chars = text.split('').toSet()..remove(' ');
  final Finder glyphs = find.byWidgetPredicate(
    (Widget w) =>
        w is Text && chars.contains(w.data) && w.style?.foreground == null,
  );
  final List<Rect> rects = <Rect>[
    for (final Element e in glyphs.evaluate())
      tester.getRect(find.byElementPredicate((Element x) => x == e)),
  ];
  expect(rects, isNotEmpty, reason: '找不到「$text」的字形');
  return rects.reduce((Rect a, Rect b) => a.expandToInclude(b));
}

Future<void> _pump(
  WidgetTester tester,
  VideoPlayerController c, {
  ValueNotifier<bool>? controlsVisible,
}) async {
  tester.view.physicalSize = const Size(1280, 720);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 1280,
          height: 720,
          child: VideoSubtitleOverlay(
            controller: c,
            respectAssStyle: true,
            controlsVisible: controlsVisible,
            controlsTopReserve: 40,
            bottomPadding: 12,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('resolveCueYieldOffset（纯函数）', () {
    const Rect box = Rect.fromLTWH(500, 12, 280, 40);

    test('顶锚组撞上定位盒 → 整组让到障碍物下缘', () {
      final r = resolveCueYieldOffset(
        box: box,
        obstacles: const <Rect>[Rect.fromLTWH(400, 5, 480, 50)],
        down: true,
        limit: 360,
      );
      expect(r.dy, 43); // 盒顶 12 → 55
      expect(r.edge, 55);
    });

    test('水平不相交 → 不让', () {
      final r = resolveCueYieldOffset(
        box: box,
        obstacles: const <Rect>[Rect.fromLTWH(0, 5, 300, 50)],
        down: true,
        limit: 360,
      );
      expect(r.dy, 0);
      expect(r.edge, isNull);
    });

    test('链式障碍物逐个越过', () {
      final r = resolveCueYieldOffset(
        box: box,
        obstacles: const <Rect>[
          Rect.fromLTWH(600, 70, 100, 30),
          Rect.fromLTWH(400, 5, 480, 50),
        ],
        down: true,
        limit: 360,
      );
      expect(r.edge, 100);
      expect(r.dy, 88);
    });

    test('要越过中线才躲得开的障碍物不躲（全屏底板）', () {
      final r = resolveCueYieldOffset(
        box: box,
        obstacles: const <Rect>[Rect.fromLTWH(0, 0, 1280, 700)],
        down: true,
        limit: 360,
      );
      expect(r.dy, 0);
    });

    test('让位线粘住：障碍物先走一步，字幕不弹回', () {
      final r = resolveCueYieldOffset(
        box: box,
        obstacles: const <Rect>[],
        down: true,
        limit: 360,
        stickyEdge: 55,
      );
      expect(r.dy, 43);
    });

    test('控制条避让把原盒压得更低时取下限、不叠加', () {
      final r = resolveCueYieldOffset(
        box: box.translate(0, 60), // 顶栏避让后盒顶 72 > 让位线 55
        obstacles: const <Rect>[Rect.fromLTWH(400, 5, 480, 50)],
        down: true,
        limit: 360,
        stickyEdge: 55,
      );
      expect(r.dy, 0);
    });

    test('底锚组往上让', () {
      final r = resolveCueYieldOffset(
        box: const Rect.fromLTWH(500, 660, 280, 40),
        obstacles: const <Rect>[Rect.fromLTWH(400, 650, 480, 60)],
        down: false,
        limit: 360,
      );
      expect(r.dy, -50); // 盒底 700 → 650
      expect(r.edge, 650);
    });
  });

  group('overlay 真布局', () {
    testWidgets('强制置顶的英文副字幕让开同轨顶部定位罗马音、不叠字', (tester) async {
      final VideoPlayerController c = VideoPlayerController();
      addTearDown(c.dispose);
      c.debugVideoWidthOverride = 1280;
      c.debugVideoHeightOverride = 720;
      c.setCues(<AudioCue>[_cue('振り返る何度と前だけを見て走るんだ')]);
      c.setSecondaryCues(<AudioCue>[
        _romaji('ZZZZ ZZZZ ZZZZ ZZZZ ZZZZ'),
        _cue('QQQ QQQ QQQ QQQ'),
      ]);
      c.debugUpdateCueForPosition(1000);

      await _pump(tester, c);

      final Rect romaji = _textRect(tester, 'ZZZZ ZZZZ ZZZZ ZZZZ ZZZZ');
      final Rect english = _textRect(tester, 'QQQ QQQ QQQ QQQ');
      // 定位行逐像素在作者位（\pos y=10，an8 盒顶贴 10）。
      expect(romaji.top, lessThan(30), reason: '定位字幕不随避让移动');
      expect(
        english.top,
        greaterThanOrEqualTo(romaji.bottom - 0.5),
        reason: '副字幕锚点组必须让到定位行下方，不再叠字',
      );
      expect(english.top, lessThan(360), reason: '仍在上半屏');
    });

    testWidgets('控制条显隐时不再「一个动一个不动」：让位后的行不被顶栏避让再推一段', (tester) async {
      final ValueNotifier<bool> controls = ValueNotifier<bool>(false);
      addTearDown(controls.dispose);
      final VideoPlayerController c = VideoPlayerController();
      addTearDown(c.dispose);
      c.debugVideoWidthOverride = 1280;
      c.debugVideoHeightOverride = 720;
      c.setSecondaryCues(<AudioCue>[
        _romaji('ZZZZ ZZZZ ZZZZ ZZZZ ZZZZ'),
        _cue('QQQ QQQ QQQ QQQ'),
      ]);
      c.debugUpdateCueForPosition(1000);

      await _pump(tester, c, controlsVisible: controls);
      final double hiddenTop = _textRect(tester, 'QQQ QQQ QQQ QQQ').top;

      controls.value = true; // 顶栏避让 40 < 罗马音下缘：取下限，不叠加
      await tester.pumpAndSettle();
      final double shownTop = _textRect(tester, 'QQQ QQQ QQQ QQQ').top;
      expect(shownTop, moreOrLessEquals(hiddenTop, epsilon: 0.5));
    });

    testWidgets('主字幕锚点组不让位（libass 同构）', (tester) async {
      final VideoPlayerController c = VideoPlayerController();
      addTearDown(c.dispose);
      c.debugVideoWidthOverride = 1280;
      c.debugVideoHeightOverride = 720;
      c.setCues(<AudioCue>[
        _romaji('XXXX XXXX XXXX'),
        _cue(
          'WWW WWW WWW',
          markup: const SubtitleMarkup(
            plainText: 'WWW WWW WWW',
            spans: <SubtitleSpan>[],
            anchor: SubtitleAnchor(SubtitleVAlign.top, SubtitleHAlign.center),
            playResY: 720,
          ),
        ),
      ]);
      c.debugUpdateCueForPosition(1000);

      await _pump(tester, c);

      final Rect pos = _textRect(tester, 'XXXX XXXX XXXX');
      final Rect line = _textRect(tester, 'WWW WWW WWW');
      expect(line.top, lessThan(pos.bottom), reason: '主字幕照 libass 不做碰撞，与定位行同带');
    });
  });
}
