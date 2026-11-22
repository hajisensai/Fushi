import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_music/fushi_music.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_runtime.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/machi/machi_board_layout.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/machi/machi_director.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/machi/machi_lens.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/machi/machi_math.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/machi/machi_palette.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/machi/machi_render.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/machi/machi_runtime.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/machi/machi_screen.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/machi/machi_tuning.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/machi/machi_visualizer.dart';

import '../visualizer_test_helpers.dart';

/// 假测量：中日韩字 100、其余 55（参考字号 100）。
double _measure(String s) {
  double w = 0;
  for (final String c in s.split('')) {
    w += lyricVisualizerIsCjk(c) ? 100 : 55;
  }
  return w;
}

LyricVisualizerLine _line(
  String text,
  int start,
  int end, {
  int index = 0,
  bool chorus = false,
}) {
  final LyricLine l = LyricLine(
    startMs: start,
    endMs: end,
    syllables: <LyricSyllable>[
      LyricSyllable(text: text, startMs: start, endMs: end),
    ],
  );
  final List<LyricVisualizerGlyph> g = buildLyricVisualizerGlyphs(l);
  return LyricVisualizerLine(
    index: index,
    source: l,
    text: text,
    startMs: start,
    endMs: end,
    glyphs: g,
    words: buildLyricVisualizerWords(g),
    backgroundLines: const <LyricLine>[],
    isChorus: chorus,
  );
}

LyricVisualizerPalette _palette(Color seed, Brightness b) =>
    LyricVisualizerPalette.fromScheme(
      ColorScheme.fromSeed(seedColor: seed, brightness: b),
    );

void main() {
  group('歌词屏排版', () {
    const MachiBoardBox box = MachiBoardBox(width: 560, height: 230);

    test('短句排一行、居中，字号按单行上限', () {
      final MachiBoardLayout l = layoutMachiBoardLine(
        _line('夜空', 0, 1000).glyphs,
        box,
        _measure,
      );
      expect(l.rows, hasLength(1));
      expect(l.fontPx, closeTo(230 * 0.56, 1e-6));
      final MachiBoardRow row = l.rows.single;
      expect(row.left + row.width / 2, closeTo(280, 1e-6));
      expect(row.glyphs.first.x0, closeTo(row.left, 1e-6));
    });

    test('长句折成多行（最多三行），每行都在字面里', () {
      final MachiBoardLayout l = layoutMachiBoardLine(
        _line(
          'A line level lyric that is rather long to force wrapping',
          0,
          3000,
        ).glyphs,
        box,
        _measure,
      );
      expect(l.rows.length, inInclusiveRange(2, 3));
      for (final MachiBoardRow r in l.rows) {
        expect(r.left, greaterThanOrEqualTo(560 * 0.05 - 1e-6));
        expect(r.left + r.width, lessThanOrEqualTo(560 * 0.95 + 1e-6));
        expect(r.top, greaterThanOrEqualTo(-1e-6));
        expect(r.bottom, lessThanOrEqualTo(230 + 1e-6));
      }
    });

    test('行首禁则标点并到前一个字上', () {
      final List<List<LyricVisualizerGlyph>> t = machiBoardTokens(
        _line('夜、空', 0, 900).glyphs,
      );
      expect(t, hasLength(2));
      expect(t.first.map((LyricVisualizerGlyph g) => g.text).join(), '夜、');
    });

    test('点亮位置随时间单调不减，唱完全亮，没开始时停在行首', () {
      final MachiBoardLayout l = layoutMachiBoardLine(
        _line('夜空に光', 1000, 2000).glyphs,
        box,
        _measure,
      );
      double last = -1;
      for (int t = 0; t <= 2400; t += 50) {
        final double x = resolveMachiBoardReveal(l, t.toDouble()).first;
        expect(x, greaterThanOrEqualTo(last - 1e-9));
        last = x;
      }
      final MachiBoardRow row = l.rows.single;
      expect(resolveMachiBoardReveal(l, 0).first, closeTo(row.left, 1e-6));
      expect(
        resolveMachiBoardReveal(l, 2500).first,
        closeTo(row.glyphs.last.x1, 1e-6),
      );
      // 一半时间亮到大约一半。
      expect(
        resolveMachiBoardReveal(l, 1500).first,
        closeTo(row.left + row.width / 2, 1),
      );
    });

    test('曲名卡：主标题加小一号的副标题，一直全亮', () {
      final MachiBoardLayout l = layoutMachiBoardCard(
        'Title',
        'Artist',
        box,
        _measure,
      );
      expect(l.rows, hasLength(2));
      expect(l.rows[1].fontPx, lessThan(l.rows[0].fontPx));
      final List<double> reveal = resolveMachiBoardReveal(l, 0);
      expect(reveal[0], closeTo(l.rows[0].glyphs.single.x1, 1e-6));
    });
  });

  group('编排', () {
    final List<LyricVisualizerLine> lines = <LyricVisualizerLine>[
      _line('サビの歌詞', 1000, 3000, index: 0, chorus: true),
      _line('別の歌詞', 3500, 5000, index: 1),
      _line('サビの歌詞', 20000, 22000, index: 2, chorus: true),
      _line('♪', 23000, 24000, index: 3),
    ];

    test('牌面：提前 0.12 秒亮出，唱完留 2.6 秒，长空隙与间奏是曲名卡', () {
      expect(resolveMachiBoardTarget(lines, 0.5).isCard, isTrue);
      expect(resolveMachiBoardTarget(lines, 0.9).lineIndex, 0);
      expect(resolveMachiBoardTarget(lines, 6).lineIndex, 1);
      expect(resolveMachiBoardTarget(lines, 5 + 2.7).isCard, isTrue);
      expect(resolveMachiBoardTarget(lines, 23.5).isCard, isTrue);
    });

    test('副歌取运行时 isChorus；闪电落在每段副歌开头，一秒多收尽', () {
      final List<double> times = buildMachiLightningTimes(lines);
      expect(times, <double>[1, 20]);
      expect(resolveMachiLightning(times, 1.04), greaterThan(0.8));
      expect(resolveMachiLightning(times, 2.5), 0);
      expect(resolveMachiChorus(lines, const MachiBoardTarget.line(2)), 1);
      expect(resolveMachiChorus(lines, const MachiBoardTarget.line(1)), 0);
      expect(resolveMachiChorus(lines, const MachiBoardTarget.card()), 0);
    });

    test('霓虹随拍（真节拍）：按拍序轮组、重拍更亮带暖灯与辉光；没节奏不亮；强度 0 回常态', () {
      final LyricVisualizerContext c = visualizerContextFor(
        machiVisualizerEntry,
        clock: FakeVisualizerClock(),
        audio: SyntheticVisualizerAudio(),
      );
      final List<MachiBeatEvent> events = machiBeatEventsOf(c);
      expect(events, isNotEmpty);
      expect(events.first.downbeat, isTrue);
      expect(events[1].downbeat, isFalse);
      expect(
        machiBeatEventsOf(
          visualizerContextFor(
            machiVisualizerEntry,
            clock: FakeVisualizerClock(),
          ),
        ),
        isEmpty,
      );
      final MachiBeatFrame f = MachiBeatFrame();
      // 第 5 拍（2.5 秒）刚过 0.4 秒：第 5 % 3 组最亮
      resolveMachiNeonPulse(events, events[5].t + 0.4, 1, f);
      const int lit = 5 % machiNeonGroups;
      for (int g = 0; g < machiNeonGroups; g++) {
        if (g != lit) expect(f.neonGroups[lit], greaterThan(f.neonGroups[g]));
      }
      expect(f.bloom, greaterThan(1));
      // 小节第一拍（第 4 拍）后暖灯起来
      resolveMachiNeonPulse(events, events[4].t + 0.6, 1, f);
      expect(f.warm, greaterThan(1));
      resolveMachiNeonPulse(events, events[4].t + 0.6, 0, f);
      expect(f.neonGroups, everyElement(1.0));
      expect(f.bloom, 1);
      const List<MachiBeatEvent> silent = <MachiBeatEvent>[
        MachiBeatEvent(t: 0, downbeat: true, gain: 0),
      ];
      resolveMachiNeonPulse(silent, 0.4, 1, f);
      expect(f.neonGroups, everyElement(1.0));
      expect(f.warm, 1);
    });

    test('跑马灯：下一句加译文；曲名卡是曲名与歌手', () {
      expect(
        resolveMachiTickerText(
          const MachiBoardTarget.line(0),
          lines,
          title: 'T',
          artist: 'A',
        ),
        startsWith('NEXT ▸ 別の歌詞'),
      );
      expect(
        resolveMachiTickerText(
          const MachiBoardTarget.card(),
          lines,
          title: 'T',
          artist: 'A',
        ),
        contains('T — A'),
      );
    });

    test('招牌闪烁只在 0.5..1 之间', () {
      for (double t = 0; t < 120; t += 0.013) {
        final double v = resolveMachiFlicker(t, 7);
        expect(v, inInclusiveRange(0.5, 1));
      }
    });

    test('白天程度跟本地时钟：深夜 0、正午 1、黄昏约 0.45', () {
      expect(resolveMachiDaylightAt(2), 0);
      expect(resolveMachiDaylightAt(12), 1);
      expect(resolveMachiDaylightAt(17.5), closeTo(machiDaylightDusk, 1e-9));
      expect(resolveMachiDaylight('dusk', DateTime(2026)), machiDaylightDusk);
    });

    test('自动场景、天气按 seed 固定；选了就用选的', () {
      expect(resolveMachiSceneId('auto', 42), resolveMachiSceneId('auto', 42));
      expect(resolveMachiSceneId('kowloon', 42), MachiSceneId.kowloon);
      expect(
        resolveMachiWeatherKind('auto', 9),
        resolveMachiWeatherKind('auto', 9),
      );
      expect(resolveMachiWeatherKind('snow', 9), MachiWeatherKind.snow);
      final Set<MachiSceneId> seen = <MachiSceneId>{
        for (int s = 0; s < 60; s++) resolveMachiSceneId('auto', s),
      };
      expect(seen, hasLength(3));
    });

    test('环境渐变：雨停后路面过一阵才干，积雪慢慢积起', () {
      MachiEnvironmentState s = MachiEnvironmentState.settled(
        MachiEnvironmentTarget.of(0, MachiWeatherKind.rain),
      );
      final MachiEnvironmentTarget clear = MachiEnvironmentTarget.of(
        0,
        MachiWeatherKind.clear,
      );
      for (int i = 0; i < 50; i++) {
        s = stepMachiEnvironment(s, clear, 0.1);
      }
      expect(s.rain, lessThan(0.05));
      expect(s.wetness, greaterThan(0.6));
      final MachiEnvironmentTarget snow = MachiEnvironmentTarget.of(
        1,
        MachiWeatherKind.snow,
      );
      for (int i = 0; i < 20; i++) {
        s = stepMachiEnvironment(s, snow, 0.1);
      }
      expect(s.snow, greaterThan(0.6));
      expect(s.snowCover, lessThan(s.snow));
      final MachiEnvironmentLook look = resolveMachiEnvironmentLook(s);
      expect(look.stars, 0);
    });

    test('固定节拍：三组霓虹轮流亮，平均不掉；大屏每两拍亮一处', () {
      final MachiBeatFrame f = MachiBeatFrame();
      resolveMachiSteadyNeonPulse(0.75 * 5 + 0.4, 1, f);
      const int lit = 5 % machiNeonGroups;
      for (int g = 0; g < machiNeonGroups; g++) {
        if (g != lit) expect(f.neonGroups[lit], greaterThan(f.neonGroups[g]));
      }
      expect(f.neon, greaterThanOrEqualTo(1));
      resolveMachiSteadyScreenFlash(0.75 + 0.25, 1, f);
      expect(f.swellAmp.first, closeTo(0.6, 1e-6));
      expect(f.swellAt.first, inInclusiveRange(0.15, 0.85));
      resolveMachiSteadyNeonPulse(10, 0, f);
      expect(f.neonGroups, everyElement(1.0));
    });

    test('路上的车：同一时刻同一辆、最多一辆，开在车道上', () {
      const List<MachiLane> lanes = <MachiLane>[
        MachiLane(-8, 3, 8, 3),
        MachiLane(8, 4.7, -8, 4.7),
      ];
      int seen = 0;
      for (double t = 0; t < 200; t += 0.5) {
        final MachiCarPass? a = resolveMachiCar(t, 11, lanes);
        final MachiCarPass? b = resolveMachiCar(t, 11, lanes);
        expect(a?.distance, b?.distance);
        if (a != null) {
          seen++;
          expect(a.distance, inInclusiveRange(0, lanes[a.lane].length));
        }
      }
      expect(seen, greaterThan(0));
    });

    test('运镜幅度：转角 ±20°、俯仰 ±4°、缩放 ±8%、平移半米以内', () {
      for (double t = 0; t < 400; t += 1.7) {
        final MachiViewOffset d = resolveMachiDrift(t);
        expect(d.azimuth.abs(), lessThanOrEqualTo(20 + 1e-9));
        expect(d.elevation.abs(), lessThanOrEqualTo(4 + 1e-9));
        expect(
          d.zoom,
          inInclusiveRange(math.exp(-0.08) - 1e-9, math.exp(0.08) + 1e-9),
        );
        expect(d.panX.abs(), lessThanOrEqualTo(0.45 + 1e-9));
      }
    });

    test('自动门在段落开头开、几秒后关', () {
      final List<double> starts = buildMachiParagraphStarts(lines);
      expect(starts, <double>[1, 20]);
      expect(resolveMachiDoorOpen(starts, 1.5), 1);
      expect(resolveMachiDoorOpen(starts, 10), 0);
    });
  });

  group('镜头与景深', () {
    test('构图：歌词屏中心在画面里（宽屏与竖屏），面朝镜头才看得见', () {
      for (final MachiSceneId id in MachiSceneId.values) {
        final MachiPalette p = resolveMachiPalette(
          _palette(const Color(0xFF6750A4), Brightness.dark),
          1,
        );
        final (double w, double h) = machiScreenSizeOf(id);
        final MachiSceneModel scene = buildMachiScene(
          id,
          p,
          1,
          MachiLyricScreen(w, h),
        );
        for (final Size size in <Size>[
          const Size(1280, 720),
          const Size(390, 844),
        ]) {
          final MachiCamera cam = machiFitCamera(
            framing: scene.framing,
            home: scene.home,
            size: size,
            focus: scene.focus,
          );
          final Offset f = cam.project(scene.focus);
          expect(f.dx, inInclusiveRange(0, size.width), reason: '$id $size');
          expect(f.dy, inInclusiveRange(0, size.height), reason: '$id $size');
          expect(cam.faces(const MachiV3(0, 1, 0)), isTrue);
          expect(cam.faces(const MachiV3(0, 0, -1)), isFalse);
        }
      }
    });

    test('自定义视角夹在限内', () {
      final MachiCamera cam = machiFitCamera(
        framing: const <MachiV3>[MachiV3(-6, 0, -6), MachiV3(6, 0, 6)],
        home: const MachiHomeView(azimuth: 0.5, elevation: 0.5, zoom: 1),
        size: const Size(800, 600),
        focus: MachiV3.zero,
        offset: const MachiViewOffset(azimuth: 300, elevation: 300, zoom: 99),
      );
      expect(cam.azimuth, closeTo(0.5 + machiMaxAzimuthRange, 1e-9));
      expect(cam.elevation, closeTo(machiMaxElevation, 1e-9));
    });

    test('景深：对焦处清楚、离得越远越虚；光圈开大更虚；全关没有横带', () {
      double blur(double y, {double aperture = 8}) => resolveMachiBlurAt(
        y: y,
        height: 800,
        focusY: 400,
        aperture: aperture,
        dof: 1,
        dofRange: 1,
        tiltShift: 0,
      );
      expect(blur(400), 0);
      expect(blur(50), greaterThan(blur(250)));
      expect(blur(50, aperture: 1.4), greaterThan(blur(50)));
      expect(
        resolveMachiLensBands(
          height: 800,
          focusY: 400,
          aperture: 8,
          dof: 0,
          dofRange: 1,
          tiltShift: 0,
        ),
        isEmpty,
      );
      final List<MachiLensBand> tilt = resolveMachiLensBands(
        height: 800,
        focusY: 400,
        aperture: 8,
        dof: 0,
        dofRange: 1,
        tiltShift: 1,
      );
      expect(tilt, isNotEmpty);
      expect(
        tilt.every((MachiLensBand b) => b.top < 250 || b.bottom > 550),
        isTrue,
      );
    });
  });

  group('调色板与设置', () {
    test('AI 主题关键字色进店招候选与商品色最前面', () {
      final LyricVisualizerPalette theme = _palette(
        const Color(0xFF2E7D32),
        Brightness.dark,
      );
      final MachiPalette plain = resolveMachiPalette(theme, 3);
      final MachiPalette keyed = resolveMachiPalette(
        theme,
        3,
        keywordColors: const <Color>[Color(0xFFE53935)],
      );
      final HSLColor first = HSLColor.fromColor(keyed.products.first);
      expect(
        first.hue,
        closeTo(HSLColor.fromColor(const Color(0xFFE53935)).hue, 2),
      );
      // 灰的关键字不进
      expect(
        resolveMachiPalette(
          theme,
          3,
          keywordColors: const <Color>[Color(0xFF808080)],
        ).products.first,
        plain.products.first,
      );
    });

    test('自定义视角每个场景各一份，只在选了自定义且场景是自动或本场景时显示', () {
      final MachiSettings s = MachiSettings(
        LyricVisualizerTuning(machiTuningSpecs, const <String, Object?>{
          'camera': 'custom',
          'view_konbini_azimuth': -60.0,
          'view_station_zoom': 2.0,
        }),
      );
      expect(s.customView, isTrue);
      expect(s.viewOf(MachiSceneId.konbini).azimuth, -60);
      expect(s.viewOf(MachiSceneId.konbini).zoom, 1);
      expect(s.viewOf(MachiSceneId.station).zoom, 2);
      expect(s.viewOf(MachiSceneId.kowloon).azimuth, 0);
      expect(s.neonPulse, 1);

      LyricVisualizerTuningSpec spec(String key) => machiTuningSpecs.firstWhere(
        (LyricVisualizerTuningSpec x) => x.key == key,
      );
      bool visible(String key, Map<String, Object?> values) => spec(
        key,
      ).visibleWhen!(LyricVisualizerTuning(machiTuningSpecs, values));
      expect(
        visible('view_konbini_azimuth', const <String, Object?>{}),
        isFalse,
      );
      expect(
        visible('view_konbini_azimuth', const <String, Object?>{
          'camera': 'custom',
        }),
        isTrue,
      );
      expect(
        visible('view_konbini_azimuth', const <String, Object?>{
          'camera': 'custom',
          'scene': 'station',
        }),
        isFalse,
      );
      expect(
        visible('view_station_pan_z', const <String, Object?>{
          'camera': 'custom',
          'scene': 'station',
        }),
        isTrue,
      );
      expect(spec('view_kowloon_zoom').section!.parent!.key, 'machi_view');
    });

    test('背景：不用共享背景（自己画整座城）', () {
      expect(
        machiVisualizerEntry.backgroundFor(
          LyricVisualizerTuning.defaults(machiVisualizerEntry.tunings),
        ),
        LyricVisualizerBackgroundRequest.none,
      );
    });
  });

  group('调色板', () {
    test('亮色主题是白底彩字的屏幕，字与底对比够', () {
      final MachiPalette p = resolveMachiPalette(
        _palette(const Color(0xFF2E7D32), Brightness.light),
        3,
      );
      expect(p.boardIsLight, isTrue);
      expect(
        machiContrast(p.boardLit, p.boardBase),
        greaterThanOrEqualTo(machiBoardMinContrast - 1e-6),
      );
    });

    test('深色主题：屏幕深底亮字；偏灰的封面按 seed 选经典配色', () {
      final MachiPalette p = resolveMachiPalette(
        _palette(const Color(0xFFE040FB), Brightness.dark),
        3,
      );
      expect(p.boardIsLight, isFalse);
      expect(
        machiContrast(p.boardLit, p.boardBase),
        greaterThanOrEqualTo(machiBoardMinContrast - 1e-6),
      );
      const LyricVisualizerPalette gray = LyricVisualizerPalette(
        background: Color(0xFF111111),
        primary: Color(0xFF888888),
        secondary: Color(0xFF777777),
        accent: Color(0xFF999999),
        text: Color(0xFFFFFFFF),
        dimText: Color(0x88FFFFFF),
        brightness: Brightness.dark,
      );
      expect(
        resolveMachiPalette(gray, 5).brand,
        resolveMachiPalette(gray, 5).brand,
      );
      expect(resolveMachiPalette(gray, 5).brand[1], machiHex(0xf4f1ea));
    });
  });

  group('挂载', () {
    testWidgets('默认参数逐字时间轴', (WidgetTester tester) async {
      await pumpVisualizerAcross(tester, machiVisualizerEntry);
    });

    testWidgets('有音频分析：霓虹随拍拉满、AI 主题关键字与字重、激烈', (WidgetTester tester) async {
      await pumpVisualizerAcross(
        tester,
        machiVisualizerEntry,
        audio: SyntheticVisualizerAudio(),
        intensity: LyricVisualizerIntensity.chaotic,
        theme: const LyricVisualizerTheme(
          wordColors: <String, Color>{'夜空': Color(0xFFE53935)},
          fontWeight: FontWeight.w700,
        ),
        tuning: const <String, Object?>{
          'neon_pulse': 2.0,
          'weather': 'rain',
          'motion': true,
        },
      );
    });

    testWidgets('只有节拍、没有包络 + 平静 + 关霓虹随拍', (WidgetTester tester) async {
      await pumpVisualizerAcross(
        tester,
        machiVisualizerEntry,
        audio: SyntheticVisualizerAudio(envelopeReady: false),
        intensity: LyricVisualizerIntensity.calm,
        tuning: const <String, Object?>{'neon_pulse': 0.0, 'weather': 'snow'},
      );
    });

    for (final String scene in <String>['konbini', 'station', 'kowloon']) {
      testWidgets('场景 $scene：雨夜、运镜、景深', (WidgetTester tester) async {
        await pumpVisualizerAcross(
          tester,
          machiVisualizerEntry,
          tuning: <String, Object?>{
            'scene': scene,
            'time_of_day': 'night',
            'weather': 'rain',
            'motion': true,
            'motion_speed': 3.0,
            'aperture': 1.4,
            'dof': 2.0,
            'tilt_shift': 1.0,
            'focus': 'lyrics',
          },
        );
      });
    }

    testWidgets('白天下雪、自定义视角、手动对焦、关倒影与辉光', (WidgetTester tester) async {
      await pumpVisualizerAcross(
        tester,
        machiVisualizerEntry,
        tuning: <String, Object?>{
          'scene': 'station',
          'time_of_day': 'day',
          'weather': 'snow',
          'camera': 'custom',
          'view_station_azimuth': -60.0,
          'view_station_elevation': 30.0,
          'view_station_zoom': 2.5,
          'view_station_pan_x': 3.0,
          'focus': 'manual',
          'focus_offset': -6.0,
          'reflections': false,
          'glow': false,
          'simulated_beat': false,
        },
      );
    });

    testWidgets('黄昏起雾、行级歌词', (WidgetTester tester) async {
      await pumpVisualizerAcross(
        tester,
        machiVisualizerEntry,
        timeline: sampleLineTimeline(),
        tuning: <String, Object?>{
          'scene': 'kowloon',
          'time_of_day': 'dusk',
          'weather': 'fog',
        },
      );
    });

    testWidgets('减弱动态效果（静态帧）', (WidgetTester tester) async {
      await pumpVisualizerAcross(
        tester,
        machiVisualizerEntry,
        motion: false,
        tuning: <String, Object?>{'scene': 'konbini', 'weather': 'rain'},
      );
    });

    testWidgets('窄屏 390x844，暂停', (WidgetTester tester) async {
      await pumpVisualizerAcross(
        tester,
        machiVisualizerEntry,
        size: const Size(390, 844),
        playing: false,
        tuning: <String, Object?>{'scene': 'kowloon', 'time_of_day': 'night'},
      );
    });
  });
}
