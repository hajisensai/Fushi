import 'package:fushi_engine/tts/manga_audio/manga_audio_script.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_timeline.dart';
import 'package:test/test.dart';

MangaTimedLine _l(
  int page,
  int durationMs, {
  String speaker = 'A',
  CastLineKind kind = CastLineKind.spoken,
  int beatMs = 0,
}) => MangaTimedLine(
  page: page,
  speaker: speaker,
  kind: kind,
  durationMs: durationMs,
  beatMs: beatMs,
);

MangaPageSegment _seg(int page, int start, int end, {bool spoken = true}) =>
    MangaPageSegment(page: page, startMs: start, endMs: end, spoken: spoken);

MangaLineTiming _t(int start, int end, int gap) =>
    MangaLineTiming(startMs: start, endMs: end, gapAfterMs: gap);

/// 页 0 一句、页 1 无台词、页 2 一句（换人 + 一拍 100）。
final List<MangaTimedLine> _gapped = <MangaTimedLine>[
  _l(0, 1000),
  _l(2, 2000, speaker: 'B', beatMs: 100),
];

void _expectContiguous(MangaTimeline t) {
  for (int i = 1; i < t.segments.length; i++) {
    expect(t.segments[i].startMs, t.segments[i - 1].endMs);
  }
  expect(t.segments.last.endMs, t.totalMs);
}

void main() {
  group('转场停顿', () {
    test('同一人接着下一个气泡 300', () {
      expect(mangaGapAfter(_l(0, 1), _l(0, 1)), 300);
    });

    test('换人说话 450', () {
      expect(mangaGapAfter(_l(0, 1), _l(0, 1, speaker: 'B')), 450);
    });

    test('内心与说出口切换 900（同一人也算，且优先于换人）', () {
      expect(
        mangaGapAfter(_l(0, 1, kind: CastLineKind.thought), _l(0, 1)),
        900,
      );
      expect(
        mangaGapAfter(
          _l(0, 1),
          _l(0, 1, speaker: 'B', kind: CastLineKind.mutter),
        ),
        900,
      );
      expect(
        mangaGapAfter(
          _l(0, 1, kind: CastLineKind.monologue),
          _l(0, 1, speaker: 'B', kind: CastLineKind.thought),
        ),
        450,
      );
    });

    test('叙述与喊不算内心', () {
      expect(
        mangaGapAfter(
          _l(0, 1, kind: CastLineKind.narration),
          _l(0, 1, kind: CastLineKind.shout),
        ),
        300,
      );
    });

    test('翻页再加 450，再加该句一拍', () {
      expect(mangaGapAfter(_l(0, 1, beatMs: 120), _l(1, 1)), 300 + 450 + 120);
      expect(
        mangaGapAfter(
          _l(0, 1, kind: CastLineKind.thought, beatMs: 50),
          _l(3, 1, speaker: 'B'),
        ),
        900 + 450 + 50,
      );
    });

    test('最后一句用收尾值加一拍；参数对象可覆盖默认值', () {
      expect(mangaGapAfter(_l(0, 1, beatMs: 10), null), 610);
      expect(
        mangaGapAfter(
          _l(0, 1),
          _l(0, 1),
          params: const MangaTimingParams(sameSpeakerMs: 111),
        ),
        111,
      );
    });
  });

  group('页段（边看边听）', () {
    test('中间夹的无台词页产出自己的页段', () {
      final MangaTimeline t = computeMangaTimeline(
        lines: _gapped,
        pageCount: 3,
      );
      expect(t.segments, <MangaPageSegment>[
        _seg(0, 0, 5000),
        _seg(1, 5000, 9000, spoken: false),
        _seg(2, 9000, 14000),
      ]);
      expect(t.lines, <MangaLineTiming>[
        _t(700, 1700, 900),
        _t(9700, 11700, 700),
      ]);
      expect(t.totalMs, 14000);
      _expectContiguous(t);
    });

    test('只有一句的页补到最短停留', () {
      final MangaTimeline t = computeMangaTimeline(
        lines: <MangaTimedLine>[_l(0, 500)],
        pageCount: 1,
      );
      expect(t.lines.single, _t(700, 1200, 600));
      expect(t.segments.single, _seg(0, 0, 5000));
    });

    test('台词超过最短停留时不截短', () {
      final MangaTimeline t = computeMangaTimeline(
        lines: <MangaTimedLine>[
          _l(0, 3000),
          _l(0, 3000, speaker: 'B'),
        ],
        pageCount: 1,
      );
      expect(t.lines, <MangaLineTiming>[
        _t(700, 3700, 450),
        _t(4150, 7150, 600),
      ]);
      expect(t.segments.single, _seg(0, 0, 7750));
    });

    test('开头、结尾的无台词页与全无台词都产出页段', () {
      final MangaTimeline t = computeMangaTimeline(
        lines: <MangaTimedLine>[_l(1, 1000)],
        pageCount: 4,
      );
      expect(
        t.segments.map((MangaPageSegment s) => (s.page, s.spoken)),
        <(int, bool)>[(0, false), (1, true), (2, false), (3, false)],
      );
      expect(t.lines.single.startMs, 4000 + 700);
      expect(t.totalMs, 4000 + 5000 + 4000 + 4000);
      _expectContiguous(t);

      final MangaTimeline empty = computeMangaTimeline(
        lines: const <MangaTimedLine>[],
        pageCount: 2,
      );
      expect(empty.segments, <MangaPageSegment>[
        _seg(0, 0, 4000, spoken: false),
        _seg(1, 4000, 8000, spoken: false),
      ]);
    });

    test('startPage 之前的页不产出', () {
      final MangaTimeline t = computeMangaTimeline(
        lines: <MangaTimedLine>[_l(3, 1000)],
        pageCount: 4,
        startPage: 2,
      );
      expect(t.segments.map((MangaPageSegment s) => s.page), <int>[2, 3]);
    });

    test('逐页 hold / lead 覆盖默认值', () {
      final MangaTimeline t = computeMangaTimeline(
        lines: _gapped,
        pageCount: 3,
        pages: const <int, MangaPageDirective>{
          1: MangaPageDirective(holdMs: 1000),
          2: MangaPageDirective(leadMs: 0),
        },
      );
      expect(t.segments, <MangaPageSegment>[
        _seg(0, 0, 5000),
        _seg(1, 5000, 6000, spoken: false),
        _seg(2, 6000, 11000),
      ]);
      expect(t.lines.last, _t(6000, 8000, 700));
    });

    test('自定义参数对象生效', () {
      final MangaTimeline t = computeMangaTimeline(
        lines: <MangaTimedLine>[_l(1, 1000)],
        pageCount: 2,
        params: const MangaTimingParams(
          silentPageHoldMs: 1500,
          pageLeadMs: 200,
          spokenPageMinMs: 0,
          finalGapMs: 0,
        ),
      );
      expect(t.segments, <MangaPageSegment>[
        _seg(0, 0, 1500, spoken: false),
        _seg(1, 1500, 2700),
      ]);
    });
  });

  group('纯听形态', () {
    test('页停留与 lead 为 0，只留句间停顿；无台词页仍有零长页段', () {
      final MangaTimeline t = computeMangaTimeline(
        lines: _gapped,
        pageCount: 3,
        mode: MangaPlaybackMode.listenOnly,
        pages: const <int, MangaPageDirective>{
          1: MangaPageDirective(holdMs: 3000),
          2: MangaPageDirective(leadMs: 900),
        },
      );
      expect(t.segments, <MangaPageSegment>[
        _seg(0, 0, 1900),
        _seg(1, 1900, 1900, spoken: false),
        _seg(2, 1900, 4600),
      ]);
      expect(t.lines, <MangaLineTiming>[_t(0, 1000, 900), _t(1900, 3900, 700)]);
      _expectContiguous(t);
    });
  });

  group('看图节奏倍率', () {
    test('只缩放页停留与 lead，不动句间停顿', () {
      final MangaTimeline t = computeMangaTimeline(
        lines: _gapped,
        pageCount: 3,
        pacing: 0.5,
      );
      expect(t.segments, <MangaPageSegment>[
        _seg(0, 0, 2500),
        _seg(1, 2500, 4500, spoken: false),
        _seg(2, 4500, 7550),
      ]);
      expect(t.lines, <MangaLineTiming>[
        _t(350, 1350, 900),
        _t(4850, 6850, 700),
      ]);
    });

    test('倍率同样缩放逐页覆盖值', () {
      final MangaTimeline t = computeMangaTimeline(
        lines: const <MangaTimedLine>[],
        pageCount: 1,
        pacing: 2,
        pages: const <int, MangaPageDirective>{
          0: MangaPageDirective(holdMs: 1000),
        },
      );
      expect(t.segments.single, _seg(0, 0, 2000, spoken: false));
    });
  });

  group('输入契约', () {
    test('页乱序、越界、不读行、负倍率抛 ArgumentError', () {
      expect(
        () => computeMangaTimeline(
          lines: <MangaTimedLine>[_l(1, 1), _l(0, 1)],
          pageCount: 2,
        ),
        throwsArgumentError,
      );
      expect(
        () => computeMangaTimeline(
          lines: <MangaTimedLine>[_l(2, 1)],
          pageCount: 2,
        ),
        throwsArgumentError,
      );
      expect(
        () => computeMangaTimeline(
          lines: <MangaTimedLine>[_l(0, 1, kind: CastLineKind.skip)],
          pageCount: 1,
        ),
        throwsArgumentError,
      );
      expect(
        () => computeMangaTimeline(
          lines: const <MangaTimedLine>[],
          pageCount: 1,
          pacing: -1,
        ),
        throwsArgumentError,
      );
    });

    test('fromScriptLine 取页、说话人、类型与一拍', () {
      final MangaTimedLine t = MangaTimedLine.fromScriptLine(
        MangaScriptLine(
          page: 4,
          blocks: <int>[0],
          speaker: 'B',
          kind: CastLineKind.shout,
          beatMs: 80,
        ),
        durationMs: 1234,
      );
      expect(
        (t.page, t.speaker, t.kind, t.beatMs, t.durationMs),
        (4, 'B', CastLineKind.shout, 80, 1234),
      );
    });
  });
}
