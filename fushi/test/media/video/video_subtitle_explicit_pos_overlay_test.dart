import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_player_controller.dart';
import 'package:fushi/src/media/video/video_subtitle_overlay.dart';
import 'package:fushi_audio/fushi_audio.dart';

/// BUG-4351：ASS 卡拉 OK 歌词作副字幕时顶部多行叠加、光晕残影（反馈 WWUuaXulfG）。
///
/// 卡拉 OK 特效把一句拆成同一 `\pos` 上的多条同时事件（整行底字 + 逐音节高亮 / 光晕
/// 拷贝）。libass 对显式定位事件不做碰撞（`detect_collisions = !explicit`），它们原地
/// 叠画成一行；旧 overlay 按位置键把它们塞进一个竖排堆叠组，排成上下好几行。另一半是
/// 「刷新率」：渲染活动集只由 125ms tick 重算，几十毫秒一条的逐音节事件晚上屏、多留屏。
AudioCue _cue(
  String text, {
  SubtitleMarkup? markup,
  int startMs = 0,
  int endMs = 6000,
  int index = 0,
}) => AudioCue()
  ..bookKey = 'b'
  ..chapterHref = 'ch'
  ..sentenceIndex = index
  ..textFragmentId = ''
  ..text = text
  ..markup = markup
  ..startMs = startMs
  ..endMs = endMs
  ..audioFileIndex = 0;

/// `\anN\pos(x,y)`（PlayRes 1280×720）的定位行。
AudioCue _posCue(
  String text, {
  required SubtitleVAlign vertical,
  required double x,
  required double y,
  int index = 0,
  int layer = 0,
}) => _cue(
  text,
  index: index,
  markup: SubtitleMarkup(
    plainText: text,
    spans: const <SubtitleSpan>[],
    anchor: SubtitleAnchor(vertical, SubtitleHAlign.center),
    posFraction: SubtitlePos(x / 1280, y / 720),
    playResY: 720,
    layer: layer,
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

Future<void> _pump(WidgetTester tester, VideoPlayerController c) async {
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
            bottomPadding: 12,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

VideoPlayerController _controller() {
  final VideoPlayerController c = VideoPlayerController();
  c.debugVideoWidthOverride = 1280;
  c.debugVideoHeightOverride = 720;
  return c;
}

void main() {
  group('isExplicitlyPositionedCue', () {
    const SubtitleMarkup plain = SubtitleMarkup(
      plainText: 'a',
      spans: <SubtitleSpan>[],
      anchor: SubtitleAnchor(SubtitleVAlign.top, SubtitleHAlign.center),
    );
    const SubtitleMarkup pos = SubtitleMarkup(
      plainText: 'a',
      spans: <SubtitleSpan>[],
      posFraction: SubtitlePos(0.5, 0.1),
    );
    const SubtitleMarkup move = SubtitleMarkup(
      plainText: 'a',
      spans: <SubtitleSpan>[],
      move: SubtitleMove(0.5, 0.1, 0.5, 0.2),
    );

    test('\\pos 恒为显式定位', () {
      expect(isExplicitlyPositionedCue(pos, respectAssStyle: true), isTrue);
      expect(isExplicitlyPositionedCue(pos, respectAssStyle: false), isTrue);
    });

    test('\\move 只在尊重 ASS 样式时算显式定位（纯字幕模式不参与定位）', () {
      expect(isExplicitlyPositionedCue(move, respectAssStyle: true), isTrue);
      expect(isExplicitlyPositionedCue(move, respectAssStyle: false), isFalse);
    });

    test('只有 \\an 锚点 / 无 markup 不是显式定位（仍走碰撞堆叠）', () {
      expect(isExplicitlyPositionedCue(plain, respectAssStyle: true), isFalse);
      expect(isExplicitlyPositionedCue(null, respectAssStyle: true), isFalse);
    });
  });

  group('overlay 真布局：同一 \\pos 上的多条事件原地叠画', () {
    testWidgets('副字幕顶部卡拉 OK：整行底字与单音节高亮同位叠画，不排成两行', (tester) async {
      final VideoPlayerController c = _controller();
      addTearDown(c.dispose);
      c.setSecondaryCues(<AudioCue>[
        _posCue(
          'LLLLL MMMMM',
          vertical: SubtitleVAlign.top,
          x: 640,
          y: 20,
          index: 0,
        ),
        _posCue('QQ', vertical: SubtitleVAlign.top, x: 640, y: 20, index: 1),
      ]);
      c.debugUpdateCueForPosition(1000);

      await _pump(tester, c);

      final Rect line = _textRect(tester, 'LLLLL MMMMM');
      final Rect syllable = _textRect(tester, 'QQ');
      expect(
        syllable.top,
        moreOrLessEquals(line.top, epsilon: 1),
        reason: '同一 \\an8\\pos 的两条事件盒顶都落在作者位（libass 显式定位不碰撞）',
      );
      expect(syllable.top, lessThan(line.bottom), reason: '原地叠画，不竖排成两行');
    });

    testWidgets('主字幕底锚 \\an2\\pos：多条同位事件盒底都落在作者位', (tester) async {
      final VideoPlayerController c = _controller();
      addTearDown(c.dispose);
      c.setCues(<AudioCue>[
        _posCue(
          'LLLLL MMMMM',
          vertical: SubtitleVAlign.bottom,
          x: 640,
          y: 600,
          index: 0,
        ),
        _posCue(
          'QQ',
          vertical: SubtitleVAlign.bottom,
          x: 640,
          y: 600,
          index: 1,
          layer: 0,
        ),
      ]);
      c.debugUpdateCueForPosition(1000);

      await _pump(tester, c);

      final Rect line = _textRect(tester, 'LLLLL MMMMM');
      final Rect syllable = _textRect(tester, 'QQ');
      expect(syllable.bottom, moreOrLessEquals(line.bottom, epsilon: 1));
      expect(line.bottom, lessThanOrEqualTo(600 + 1));
    });

    testWidgets('无 \\pos 的同锚点对白照旧竖排堆叠（libass 碰撞语义不回归）', (tester) async {
      final VideoPlayerController c = _controller();
      addTearDown(c.dispose);
      SubtitleMarkup top(String text) => SubtitleMarkup(
        plainText: text,
        spans: const <SubtitleSpan>[],
        anchor: const SubtitleAnchor(SubtitleVAlign.top, SubtitleHAlign.center),
        playResY: 720,
      );
      c.setCues(<AudioCue>[
        _cue('LLLLL MMMMM', markup: top('LLLLL MMMMM'), index: 0),
        _cue('QQ', markup: top('QQ'), index: 1),
      ]);
      c.debugUpdateCueForPosition(1000);

      await _pump(tester, c);

      final Rect first = _textRect(tester, 'LLLLL MMMMM');
      final Rect second = _textRect(tester, 'QQ');
      expect(second.top, greaterThanOrEqualTo(first.bottom - 0.5));
    });
  });

  group('渲染活动集跟着时钟走（字幕刷新率）', () {
    test('位置更新即重算副字幕活动集，不等 125ms tick', () {
      final VideoPlayerController c = _controller();
      addTearDown(c.dispose);
      final AudioCue a = _cue('A', startMs: 0, endMs: 40, index: 0);
      final AudioCue b = _cue('B', startMs: 40, endMs: 80, index: 1);
      final AudioCue tail = _cue('C', startMs: 80, endMs: 2000, index: 2);
      c.setSecondaryCues(<AudioCue>[a, b, tail]);
      c.debugUpdateCueForPosition(10);
      expect(c.secondaryActiveCues, <AudioCue>[a]);

      c.debugSetPositionForTesting(50);
      c.debugSyncRenderActivityToClock();
      expect(c.secondaryActiveCues, <AudioCue>[
        b,
      ], reason: '已结束的 A 不再多留屏，B 即时上屏');

      c.debugSetPositionForTesting(90);
      c.debugSyncRenderActivityToClock();
      expect(c.secondaryActiveCues, <AudioCue>[tail]);
    });

    test('主字幕渲染集同样随位置更新，代表 cue 仍归 tick 管', () {
      final VideoPlayerController c = _controller();
      addTearDown(c.dispose);
      final AudioCue line = _cue('LINE', startMs: 0, endMs: 2000, index: 0);
      final AudioCue s1 = _cue('S1', startMs: 0, endMs: 40, index: 1);
      final AudioCue s2 = _cue('S2', startMs: 40, endMs: 80, index: 2);
      c.setCues(<AudioCue>[line, s1, s2]);
      c.debugUpdateCueForPosition(10);
      expect(c.activeCues, containsAll(<AudioCue>[line, s1]));
      final AudioCue? representative = c.currentCue;

      c.debugSetPositionForTesting(50);
      c.debugSyncRenderActivityToClock();
      expect(c.activeCues, contains(s2));
      // 已结束的 S1 不再留屏——除非它恰是代表 cue（代表 cue 恒并入渲染集，等下一拍 tick 换）。
      if (!identical(representative, s1)) {
        expect(c.activeCues, isNot(contains(s1)));
      }
      expect(c.currentCue, same(representative));
    });
  });
}
