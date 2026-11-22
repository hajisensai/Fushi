import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_runtime.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/nebbia/nebbia_chars.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/nebbia/nebbia_glass.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/nebbia/nebbia_glyphs.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/nebbia/nebbia_layout.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/nebbia/nebbia_painter.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/nebbia/nebbia_scene.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/nebbia/nebbia_tuning.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/nebbia/nebbia_visualizer.dart';

import '../visualizer_test_helpers.dart';

List<String> _chars(String s) => s.split('');

List<NebbiaSourceLine> _source(LyricVisualizerRuntime rt) =>
    buildNebbiaLines(rt.lines, 1234, 0);

List<NebbiaLaidLine> _scene(
  NebbiaSettings s, {
  double w = 1280,
  double h = 720,
  LyricVisualizerRuntime? rt,
}) {
  final LyricVisualizerRuntime runtime =
      rt ?? LyricVisualizerRuntime(sampleWordTimeline());
  return buildNebbiaScene(
    appendNebbiaCredits(_source(runtime), 'Title', 'Artist'),
    nebbiaSweepGlyphOrNull,
    s,
    width: w,
    height: h,
    fontScale: 1,
    seed: 99,
  );
}

NebbiaGlyph? nebbiaSweepGlyphOrNull(String ch) =>
    ch.trim().isEmpty ? null : nebbiaSweepGlyph(ch);

void main() {
  group('words', () {
    test('Chinese han runs pair up, particles stand alone', () {
      final List<List<int>> w = nebbiaGroupWords(_chars('我们的夜空'));
      expect(w, <List<int>>[
        <int>[0, 1],
        <int>[2],
        <int>[3, 4],
      ]);
    });

    test('Japanese keeps okurigana and splits case particles', () {
      final List<List<int>> w = nebbiaGroupWords(_chars('夜空に光る'));
      expect(w, <List<int>>[
        <int>[0, 1],
        <int>[2],
        <int>[3, 4],
      ]);
    });

    test('Latin words split on spaces, punctuation sticks', () {
      final List<List<int>> w = nebbiaGroupWords(_chars('Hello, world'));
      expect(w, <List<int>>[
        <int>[0, 1, 2, 3, 4, 5],
        <int>[7, 8, 9, 10, 11],
      ]);
    });
  });

  group('layout', () {
    test('roles pick one hero by length and duration', () {
      final List<NebbiaChar> chars = <NebbiaChar>[
        for (int i = 0; i < 6; i++) NebbiaChar('ab cdef'[i], i * 0.2, 0.2),
      ];
      final List<NebbiaRole> roles = nebbiaAssignRoles(chars, <List<int>>[
        <int>[0, 1],
        <int>[3, 4, 5],
      ]);
      expect(roles, <NebbiaRole>[NebbiaRole.support, NebbiaRole.hero]);
    });

    test('every composition places every block char exactly once', () {
      final List<NebbiaChar> chars = <NebbiaChar>[
        for (int i = 0; i < 10; i++) NebbiaChar('春夏秋冬朝昼夜雨雪風'[i], i * 0.3, 0.3),
      ];
      final List<List<int>> words = <List<int>>[
        <int>[0, 1],
        <int>[2],
        <int>[3, 4],
        <int>[5, 6],
        <int>[7],
        <int>[8, 9],
      ];
      final List<NebbiaBlock> blocks = nebbiaMakeBlocks(
        chars,
        words,
        nebbiaAssignRoles(chars, words),
        kNebbiaRoleScale,
        5,
      );
      expect(blocks.length, lessThanOrEqualTo(5));
      final NebbiaCompositionContext ctx = NebbiaCompositionContext(
        blocks,
        0,
        chars,
      );
      for (final MapEntry<String, dynamic> e in kNebbiaCompositions.entries) {
        final NebbiaCompositionResult? r =
            (e.value
                as NebbiaCompositionResult? Function(NebbiaCompositionContext))(
              ctx,
            );
        if (r == null) continue;
        expect(
          r.items.map((NebbiaPlaced p) => p.k).toSet().length,
          10,
          reason: e.key,
        );
      }
    });

    for (final Size size in <Size>[
      const Size(390, 844),
      const Size(1280, 720),
    ]) {
      test('song layout stays on screen at $size', () {
        final LyricVisualizerRuntime rt = LyricVisualizerRuntime(
          sampleLineTimeline(),
        );
        final List<List<NebbiaCharPos>> pos = layoutNebbiaSong(
          _source(rt),
          NebbiaLayoutOptions(
            width: size.width,
            height: size.height,
            jitter: 0.6,
            layouts: kNebbiaLayouts,
            fontScale: 1,
            visibleUntil: (int i) => 100,
            fogAt: (int i) => 50,
          ),
        );
        for (final List<NebbiaCharPos> line in pos) {
          for (final NebbiaCharPos p in line) {
            expect(p.x, inInclusiveRange(-p.s, size.width + p.s));
            expect(p.y, inInclusiveRange(-p.s, size.height + p.s));
            expect(p.s, greaterThan(4));
          }
        }
      });
    }
  });

  group('scene', () {
    test('writing is sequential, never before the sung time', () {
      final List<NebbiaLaidLine> laid = _scene(NebbiaSettings.defaults());
      for (final NebbiaLaidLine line in laid) {
        double prevEnd = -1;
        for (final NebbiaLaidChar c in line.chars) {
          if (c.glyph == null || c.appearDur > 0) continue;
          expect(c.wt, greaterThanOrEqualTo(c.t - 1e-9));
          expect(c.wt, greaterThanOrEqualTo(prevEnd - 1e-9));
          prevEnd = c.wt + c.wd;
        }
      }
      // 片尾两句不起雾。
      expect(laid.last.credits, NebbiaCredits.artist);
      expect(laid.last.fogAt, double.infinity);
    });

    test('fade-only appear makes every char fade in', () {
      final NebbiaSettings s = NebbiaSettings.from(
        LyricVisualizerTuning(nebbiaTuningSpecs, const <String, Object?>{
          'appear': 'fade',
        }),
      );
      for (final NebbiaLaidLine line in _scene(s)) {
        for (final NebbiaLaidChar c in line.chars) {
          if (c.glyph != null) expect(c.appearDur, greaterThan(0));
        }
      }
    });

    test('fog start waits for next line plus hold', () {
      expect(nebbiaFogStartOf(10, 12, 1.2), closeTo(13.2, 1e-9));
      expect(nebbiaFogStartOf(10, 30, 1), closeTo(17, 1e-9));
    });

    test('finger wipe sweeps beads it has passed', () {
      final List<NebbiaLaidLine> laid = _scene(
        NebbiaSettings.from(
          LyricVisualizerTuning(nebbiaTuningSpecs, const <String, Object?>{
            'fade': 'fingers',
          }),
        ),
      );
      final NebbiaLaidLine line = laid.first;
      final NebbiaWipe wipe = line.wipe(0)!;
      expect(wipe.dur, inInclusiveRange(0.48, 1.6));
      final Offset mid = wipe.streaks.first.pts[6];
      expect(nebbiaIsSwept(wipe, 0, mid), isFalse);
      expect(nebbiaIsSwept(wipe, 1, mid), isTrue);
    });

    test('spot follows the char being written', () {
      final List<NebbiaLaidLine> laid = _scene(NebbiaSettings.defaults());
      final NebbiaLaidChar first = laid.first.chars.first;
      final ({Offset target, double radius, double intensity}) s = nebbiaSpotAt(
        laid,
        nebbiaStartOf(first) + 0.01,
        smooth: false,
      );
      expect(s.intensity, 1);
      expect((s.target - Offset(first.x, first.y)).distance, lessThan(first.s));
      expect(nebbiaSpotAt(laid, -5, smooth: true).intensity, 0);
    });
  });

  group('skeleton', () {
    test('thins a thick L into one stroke from top-left', () {
      const int n = 40;
      final Uint8List img = Uint8List(n * n);
      for (int y = 5; y < 35; y++) {
        for (int x = 5; x < 11; x++) {
          img[y * n + x] = 1;
        }
      }
      for (int y = 29; y < 35; y++) {
        for (int x = 5; x < 35; x++) {
          img[y * n + x] = 1;
        }
      }
      final List<List<Offset>>? polys = nebbiaSkeletonPolys(img, n);
      expect(polys, isNotNull);
      final List<Offset> main = polys!.reduce(
        (List<Offset> a, List<Offset> b) => a.length >= b.length ? a : b,
      );
      // 从左上起笔，收在右下。
      expect(main.first.dy, lessThan(0.4));
      expect(main.last.dx, greaterThan(0.6));
      final NebbiaGlyph? g = nebbiaMeasureGlyph(polys);
      expect(g!.total, greaterThan(0.8));
    });

    test('rdp keeps the corner of a polyline', () {
      final List<Offset> pts = <Offset>[
        for (int i = 0; i <= 10; i++) Offset(i.toDouble(), 0),
        for (int i = 1; i <= 10; i++) Offset(10, i.toDouble()),
      ];
      expect(nebbiaRdp(pts, 0.5), <Offset>[
        Offset.zero,
        const Offset(10, 0),
        const Offset(10, 10),
      ]);
    });

    test('warp keeps glyph measurable and deterministic', () {
      final NebbiaGlyph g = nebbiaSweepGlyph('夜');
      final NebbiaGlyph a = nebbiaWarpGlyph(g, LyricVisualizerRandom(7), 1);
      final NebbiaGlyph b = nebbiaWarpGlyph(g, LyricVisualizerRandom(7), 1);
      expect(a.strokes.length, g.strokes.length);
      expect(a.total, b.total);
    });
  });

  group('glass', () {
    test('small hits are deterministic per bucket and scale with density', () {
      double e(double _) => 0.8;
      final List<NebbiaHit> a = nebbiaSmallHits(20, 5, 1, e, 1280, 720, 3);
      final List<NebbiaHit> b = nebbiaSmallHits(20, 5, 1, e, 1280, 720, 3);
      expect(a.length, b.length);
      expect(a.map((NebbiaHit h) => h.x), b.map((NebbiaHit h) => h.x));
      expect(nebbiaSmallHits(20, 5, 0, e, 1280, 720, 3), isEmpty);
      for (final NebbiaHit h in a) {
        expect(h.t, inInclusiveRange(15 - 0.02, 20));
      }
    });

    test('bumps shake then settle', () {
      final NebbiaBumps bumps = NebbiaBumps(5);
      final NebbiaBump first = bumps.between(0, 30).first;
      expect(first.t, inInclusiveRange(3, 12));
      expect(bumps.shakeAt(first.t + 0.05, 1).distance, greaterThan(0.1));
      expect(bumps.shakeAt(first.t - 0.01 + 0, 0), Offset.zero);
    });

    test('snow flakes melt into water', () {
      final NebbiaSettings s = NebbiaSettings.defaults();
      final List<NebbiaFlakeState> f = nebbiaFlakesAt(
        40,
        const Size(1280, 720),
        s,
      );
      expect(f, isNotEmpty);
      expect(f.any((NebbiaFlakeState x) => x.melt > 0), isTrue);
    });
  });

  test('settings read presets and fall back when all layouts are off', () {
    final NebbiaSettings s = NebbiaSettings.from(
      LyricVisualizerTuning(nebbiaTuningSpecs, <String, Object?>{
        'appear': 'breath',
        'fade': 'mix',
        for (final String l in kNebbiaLayouts) 'layout_$l': false,
        'behind': 'aquarium',
        'jellies': 99.0,
      }),
    );
    expect(s.appear, <NebbiaAppear>[NebbiaAppear.fade, NebbiaAppear.breath]);
    expect(s.fade, <NebbiaFade>[NebbiaFade.fog, NebbiaFade.fingers]);
    expect(s.layouts, kNebbiaLayouts);
    expect(s.behind, NebbiaBehind.aquarium);
    expect(s.jellies, kNebbiaMaxJellies);
  });

  group('widget', () {
    testWidgets('default tuning', (WidgetTester tester) async {
      await pumpVisualizerAcross(tester, nebbiaVisualizerEntry);
    });

    testWidgets('aquarium, dew, finger wipe, breath', (
      WidgetTester tester,
    ) async {
      await pumpVisualizerAcross(
        tester,
        nebbiaVisualizerEntry,
        tuning: const <String, Object?>{
          'behind': 'aquarium',
          'glass': 'dew',
          'fade': 'fingers',
          'appear': 'breath',
          'jellies': 24.0,
          'bubbles': 1.0,
        },
      );
    });

    testWidgets('backdrop, snow, straight rain, write only', (
      WidgetTester tester,
    ) async {
      await pumpVisualizerAcross(
        tester,
        nebbiaVisualizerEntry,
        tuning: const <String, Object?>{
          'behind': 'backdrop',
          'glass': 'snow',
          'rain': 'straight',
          'appear': 'write',
          'fade': 'mix',
          'snow': 3.0,
          'credits': false,
          'layout_ribbon': false,
          'scenery_road': false,
        },
      );
    });

    testWidgets('line-level timeline', (WidgetTester tester) async {
      await pumpVisualizerAcross(
        tester,
        nebbiaVisualizerEntry,
        timeline: sampleLineTimeline(),
        timesMs: const <int>[0, 600, 1500, 2900, 3500, 5000, 9000, 20000],
      );
    });

    testWidgets('motion off', (WidgetTester tester) async {
      await pumpVisualizerAcross(
        tester,
        nebbiaVisualizerEntry,
        motion: false,
        playing: false,
      );
    });

    testWidgets('narrow phone', (WidgetTester tester) async {
      await pumpVisualizerAcross(
        tester,
        nebbiaVisualizerEntry,
        size: const Size(390, 844),
        tuning: const <String, Object?>{'busSpeed': 3.0, 'bump': 2.5},
      );
    });
  });
}
