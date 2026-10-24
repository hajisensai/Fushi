import 'dart:ui' show Canvas, PictureRecorder;

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/lyrics/karaoke/karaoke_appearance.dart';
import 'package:fushi/src/media/music/lyrics/karaoke/karaoke_line_layout.dart';
import 'package:fushi/src/media/music/lyrics/karaoke/karaoke_lyrics_view.dart';
import 'package:fushi/src/utils/components/fushi_m3e_player.dart'
    show FushiPlaybackClock;
import 'package:fushi_music/fushi_music.dart';
import 'package:material_ui/material_ui.dart';

class _Clock implements FushiPlaybackClock {
  int ms = 0;

  @override
  Duration get position => Duration(milliseconds: ms);

  @override
  Duration get duration => const Duration(minutes: 4);
}

LyricLine _syllables(
  int start,
  List<(String, int)> parts, {
  int? agent,
  LyricRole role = LyricRole.main,
}) {
  final List<LyricSyllable> s = <LyricSyllable>[];
  int t = start;
  for (final (String text, int dur) in parts) {
    s.add(LyricSyllable(text: text, startMs: t, endMs: t + dur));
    t += dur;
  }
  return LyricLine(
    startMs: start,
    endMs: t,
    syllables: s,
    agent: agent,
    role: role,
  );
}

LyricTimeline _timeline() => LyricTimeline(
  format: 'ttml',
  timingQuality: LyricTimingQuality.syllable,
  agents: const <LyricAgent>[
    LyricAgent(id: 'v1'),
    LyricAgent(id: 'v2'),
  ],
  lines: <LyricLine>[
    _syllables(1000, <(String, int)>[('abc', 600), ('de', 400)], agent: 0),
    _syllables(
      1500,
      <(String, int)>[('oo', 800)],
      role: LyricRole.background,
      agent: 0,
    ),
    _syllables(3000, <(String, int)>[('fgh', 500), ('ij', 500)], agent: 1),
    _syllables(5000, <(String, int)>[('klm', 1500)]),
    for (int i = 0; i < 8; i++)
      _syllables(7000 + i * 1000, <(String, int)>[('n$i', 900)]),
  ],
);

KaraokeResolvedStyle _style() => const KaraokeResolvedStyle(
  main: TextStyle(fontSize: 20, height: 1),
  background: TextStyle(fontSize: 12, height: 1),
  ruby: TextStyle(fontSize: 8, height: 1),
  sub: TextStyle(fontSize: 10, height: 1),
  active: Color(0xFFFFFFFF),
  inactive: Color(0x66FFFFFF),
  secondary: Color(0xAAFFFFFF),
  textScaler: TextScaler.noScaling,
  showRuby: true,
  showTranslation: true,
  showRomanization: true,
  glow: true,
);

Finder _row(String text) => find.byWidgetPredicate(
  (Widget w) => w is Semantics && w.properties.label == text,
);

Widget _host({
  required LyricTimeline timeline,
  required _Clock clock,
  required bool playing,
  ValueChanged<int>? onSeek,
  ValueChanged<KaraokeLookupHit>? onLookup,
  bool disableAnimations = false,
}) => MaterialApp(
  home: MediaQuery(
    data: MediaQueryData(
      size: const Size(800, 600),
      disableAnimations: disableAnimations,
    ),
    child: Scaffold(
      body: SizedBox(
        width: 800,
        height: 600,
        child: KaraokeLyricsView(
          timeline: timeline,
          clock: clock,
          playing: playing,
          onSeek: onSeek,
          onLookup: onLookup,
          appearance: const KaraokeLyricsAppearance(fontSize: 24),
        ),
      ),
    ),
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('KaraokeLineLayout', () {
    test('音节级命中测试：字形框内命中对应音节与字，框外为 null', () {
      final LyricLine line = _syllables(0, <(String, int)>[
        ('abc', 500),
        ('de', 500),
      ]);
      final KaraokeLineLayout l = KaraokeLineLayout.build(
        line: line,
        width: 400,
        style: _style().main,
        resolved: _style(),
        align: TextAlign.left,
        lineLevel: false,
      );
      // 测试字体每个字宽 = 字号（20）。
      final double y = l.syllables[0].boxes.first.center.dy;
      expect(l.hitTest(Offset(5, y)), (syllable: 0, charIndex: 0));
      expect(l.hitTest(Offset(45, y)), (syllable: 0, charIndex: 2));
      expect(l.hitTest(Offset(65, y)), (syllable: 1, charIndex: 3));
      expect(l.hitTest(Offset(95, y)), (syllable: 1, charIndex: 4));
      expect(l.hitTest(Offset(300, y)), isNull, reason: '行尾空白');
      expect(l.hitTest(Offset(5, y + 200)), isNull);
      l.dispose();
    });

    test('右对齐（对唱 v2）字形框落在右侧；ruby 预留顶部空间', () {
      final LyricLine line = LyricLine(
        startMs: 0,
        endMs: 1000,
        syllables: const <LyricSyllable>[
          LyricSyllable(text: '夜', startMs: 0, endMs: 500, ruby: 'よる'),
          LyricSyllable(text: 'に', startMs: 500, endMs: 1000),
        ],
        translations: const <LyricTranslation>[LyricTranslation('zh', '在夜里')],
      );
      final KaraokeLineLayout l = KaraokeLineLayout.build(
        line: line,
        width: 400,
        style: _style().main,
        resolved: _style(),
        align: TextAlign.right,
        lineLevel: false,
      );
      expect(l.syllables[1].boxes.first.right, closeTo(400, 0.5));
      expect(l.textTop, greaterThan(0));
      expect(l.syllables[0].rubyInactive, isNotNull);
      expect(
        l.syllables[0].rubyOffset.dy,
        lessThan(l.syllables[0].boxes.first.top),
      );
      expect(
        l.size.height,
        greaterThan(l.syllables[0].boxes.first.bottom),
        reason: '翻译副行在下方',
      );
      l.dispose();
    });

    test('绘制不触发重排（每帧只改裁剪 / 渐变）', () {
      final LyricLine line = _syllables(0, <(String, int)>[
        ('ab', 500),
        ('cd', 1500),
      ]);
      final int before = KaraokeLineLayout.debugLayoutCount;
      final KaraokeLineLayout l = KaraokeLineLayout.build(
        line: line,
        width: 400,
        style: _style().main,
        resolved: _style(),
        align: TextAlign.left,
        lineLevel: false,
      );
      expect(KaraokeLineLayout.debugLayoutCount, before + 1);
      final PictureRecorder rec = PictureRecorder();
      final Canvas c = Canvas(rec);
      for (int t = 0; t < 2400; t += 8) {
        l.paintActive(
          c,
          timeMs: t,
          motion: true,
          lineLevelSweep: true,
          liftPx: 3,
        );
      }
      rec.endRecording().dispose();
      expect(KaraokeLineLayout.debugLayoutCount, before + 1);
      l.dispose();
    });
  });

  group('KaraokeLyricsView', () {
    testWidgets('假时钟推进后当前行变化并弹簧居中', (WidgetTester tester) async {
      final _Clock clock = _Clock()..ms = 1100;
      await tester.pumpWidget(
        _host(timeline: _timeline(), clock: clock, playing: true),
      );
      await tester.pump();
      final double y0 = tester
          .getTopLeft(
            _row(
              'abc'
              'de',
            ),
          )
          .dy;
      expect(y0, closeTo(600 * 0.38, 1), reason: '当前行停在锚点');
      clock.ms = 3100;
      await tester.pump(const Duration(milliseconds: 16));
      // Ticker 在起动后的第一帧才记起点：逐帧推进让弹簧真正走完。
      for (int i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(tester.getTopLeft(_row('fghij')).dy, closeTo(600 * 0.38, 1));
      // 停播放：卸载前停 Ticker。
      await tester.pumpWidget(
        _host(timeline: _timeline(), clock: clock, playing: false),
      );
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('点行跳到该行起点', (WidgetTester tester) async {
      final _Clock clock = _Clock()..ms = 1100;
      final List<int> seeks = <int>[];
      await tester.pumpWidget(
        _host(
          timeline: _timeline(),
          clock: clock,
          playing: false,
          onSeek: seeks.add,
        ),
      );
      await tester.pump();
      await tester.tap(_row('fghij'));
      await tester.pump(const Duration(seconds: 4));
      expect(seeks, <int>[3000]);
    });

    testWidgets('长按命中音节回调查词', (WidgetTester tester) async {
      final _Clock clock = _Clock()..ms = 1100;
      final List<KaraokeLookupHit> hits = <KaraokeLookupHit>[];
      await tester.pumpWidget(
        _host(
          timeline: _timeline(),
          clock: clock,
          playing: false,
          onLookup: hits.add,
        ),
      );
      await tester.pump();
      final Offset tl = tester.getTopLeft(_row('abcde'));
      // 字宽 24：第 4 个字（d，第二个音节）。
      await tester.longPressAt(tl + const Offset(24 * 3 + 6, 12));
      await tester.pump(const Duration(seconds: 4));
      expect(hits, hasLength(1));
      expect(hits.single.lineIndex, 0);
      expect(hits.single.syllableIndex, 1);
      expect(hits.single.charIndexInLine, 3);
      expect(hits.single.lineText, 'abcde');
      expect(hits.single.globalRect.left, closeTo(tl.dx + 72, 1));
    });

    testWidgets('减弱动态效果：暂停时不再有逐帧动画、换行直接跳', (WidgetTester tester) async {
      final _Clock clock = _Clock()..ms = 1100;
      await tester.pumpWidget(
        _host(
          timeline: _timeline(),
          clock: clock,
          playing: false,
          disableAnimations: true,
        ),
      );
      await tester.pump();
      expect(tester.binding.hasScheduledFrame, isFalse);
      clock.ms = 3100;
      await tester.pumpWidget(
        _host(
          timeline: _timeline(),
          clock: clock,
          playing: false,
          disableAnimations: true,
        ),
      );
      await tester.pump();
      expect(
        tester.getTopLeft(_row('fghij')).dy,
        closeTo(600 * 0.38, 1),
        reason: '无弹簧，一帧到位',
      );
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('逐帧只重绘当前行组且不重排；600 帧 @120Hz 绘制成本度量', (
      WidgetTester tester,
    ) async {
      final _Clock clock = _Clock()..ms = 1000;
      await tester.pumpWidget(
        _host(timeline: _timeline(), clock: clock, playing: true),
      );
      await tester.pump(const Duration(seconds: 2));
      final int layouts = KaraokeLineLayout.debugLayoutCount;
      final int paints0 = karaokeDebugRowPaintCount;
      final Stopwatch sw = Stopwatch()..start();
      // 1000 → 1600 ms 都在第一行组内：600 帧 × 1 ms（时钟）每帧一次 pump(8ms)。
      for (int i = 0; i < 600; i++) {
        clock.ms = 1000 + i;
        await tester.pump(const Duration(microseconds: 8333));
      }
      sw.stop();
      final int paints = karaokeDebugRowPaintCount - paints0;
      expect(KaraokeLineLayout.debugLayoutCount, layouts, reason: '逐帧不重排');
      expect(paints, lessThanOrEqualTo(600 + 4), reason: '只有当前行组逐帧重绘');
      // ignore: avoid_print
      print(
        'karaoke 600 frames: ${sw.elapsedMicroseconds / 600} us/frame (build+layout+paint, test binding), row paints=$paints',
      );
      await tester.pumpWidget(
        _host(timeline: _timeline(), clock: clock, playing: false),
      );
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('无时间歌词：静态显示、点行不跳转', (WidgetTester tester) async {
      final List<int> seeks = <int>[];
      final LyricTimeline t = LyricTimeline(
        format: 'txt',
        timingQuality: LyricTimingQuality.unsynced,
        lines: const <LyricLine>[
          LyricLine(
            startMs: 0,
            endMs: 0,
            syllables: <LyricSyllable>[
              LyricSyllable(text: 'one', startMs: 0, endMs: 0),
            ],
          ),
          LyricLine(
            startMs: 0,
            endMs: 0,
            syllables: <LyricSyllable>[
              LyricSyllable(text: 'two', startMs: 0, endMs: 0),
            ],
          ),
        ],
      );
      await tester.pumpWidget(
        _host(timeline: t, clock: _Clock(), playing: true, onSeek: seeks.add),
      );
      await tester.pump();
      expect(tester.binding.hasScheduledFrame, isFalse, reason: '无时间不起 Ticker');
      await tester.tap(_row('one'));
      await tester.pump(const Duration(seconds: 4));
      expect(seeks, isEmpty);
    });
  });
}
