import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_music/fushi_music.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_frame.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_runtime.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/hanabi/hanabi_beat_fx.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/hanabi/hanabi_catalog.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/hanabi/hanabi_color.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/hanabi/hanabi_fireworks.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/hanabi/hanabi_program.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/hanabi/hanabi_scene.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/hanabi/hanabi_text_layout.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/hanabi/hanabi_timeline.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/hanabi/hanabi_math.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/hanabi/hanabi_visualizer.dart';

import '../visualizer_test_helpers.dart';

HanabiLine _line(String text, double start, double perChar) {
  final List<String> chars = text.split('');
  return HanabiLine(
    chars: chars,
    charStart: <double>[
      for (int i = 0; i < chars.length; i++) start + i * perChar,
    ],
    charEnd: <double>[
      for (int i = 0; i < chars.length; i++) start + (i + 1) * perChar,
    ],
    startTime: start,
    endTime: start + chars.length * perChar,
  );
}

List<HanabiLine> _song() => <HanabiLine>[
  _line('夜空に咲いた花火', 2, 0.25),
  _line('君の声が聞こえる', 5, 0.25),
  _line('hello summer night', 8, 0.15),
  _line('夜空に咲いた花火', 14, 0.25),
  _line('君の声が聞こえる', 17, 0.3),
  _line('夜空に咲いた花火', 30, 0.25),
];

const HanabiTheme _theme = HanabiTheme(
  primary: 0x6750a4,
  accent: 0xff8a65,
  secondary: 0x4db6ac,
  background: 0x101018,
);

Future<void> _mount(WidgetTester tester, Widget child) async {
  await tester.binding.setSurfaceSize(const Size(1280, 720));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        backgroundColor: Colors.black,
        body: SizedBox.expand(child: child),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 16));
  await tester.pump(const Duration(milliseconds: 16));
}

void main() {
  group('BUG-5446 暂停时停帧', () {
    testWidgets('花火暂停（开着动态效果）时不再逐帧要帧，播放时照常逐帧', (WidgetTester tester) async {
      final FakeVisualizerClock clock = FakeVisualizerClock(3000);
      await _mount(
        tester,
        hanabiVisualizerEntry.builder(
          visualizerContextFor(
            hanabiVisualizerEntry,
            clock: clock,
            playing: false,
          ),
        ),
      );
      expect(tester.binding.hasScheduledFrame, isFalse);

      await _mount(
        tester,
        hanabiVisualizerEntry.builder(
          visualizerContextFor(hanabiVisualizerEntry, clock: clock),
        ),
      );
      expect(tester.binding.hasScheduledFrame, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('驱动器：有闲置动画的样式暂停时照常逐帧（默认），声明没有的停帧', (WidgetTester tester) async {
      final LyricVisualizerContext paused = visualizerContextFor(
        hanabiVisualizerEntry,
        clock: FakeVisualizerClock(3000),
        playing: false,
      );
      int built = 0;
      Widget frame({required bool idle}) => LyricVisualizerFrame(
        context: paused,
        idleAnimation: idle,
        builder: (BuildContext c, LyricVisualizerTicks ticks) =>
            ValueListenableBuilder<LyricVisualizerTick>(
              valueListenable: ticks,
              builder: (BuildContext c, LyricVisualizerTick t, Widget? _) {
                built++;
                return const SizedBox.expand();
              },
            ),
      );
      await _mount(tester, frame(idle: true));
      expect(tester.binding.hasScheduledFrame, isTrue);

      await tester.pumpWidget(const SizedBox.shrink());
      await _mount(tester, frame(idle: false));
      expect(tester.binding.hasScheduledFrame, isFalse);
      final int before = built;
      await tester.pump(const Duration(milliseconds: 100));
      expect(built, before);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  group('节目单', () {
    test('同种子同结果，镜头覆盖每一行、种类都在配方表里', () {
      final HanabiProgram a = compileHanabiProgram(
        _song(),
        'seed-1',
        duration: 40,
      );
      final HanabiProgram b = compileHanabiProgram(
        _song(),
        'seed-1',
        duration: 40,
      );
      expect(a.paragraphs, isNotEmpty);
      expect(
        <String>[
          for (final HanabiParagraph p in a.paragraphs)
            for (final HanabiShot s in p.shots) s.kind,
        ],
        <String>[
          for (final HanabiParagraph p in b.paragraphs)
            for (final HanabiShot s in p.shots) s.kind,
        ],
      );
      final Set<int> covered = <int>{
        for (final HanabiParagraph p in a.paragraphs)
          for (final HanabiShot s in p.shots)
            for (final HanabiSlice slice in s.slices) slice.lineIndex,
      };
      expect(covered, containsAll(<int>[0, 1, 2, 3, 4, 5]));
      for (final HanabiParagraph p in a.paragraphs) {
        expect(p.endTime, greaterThanOrEqualTo(p.startTime));
        for (final HanabiShot s in p.shots) {
          expect(hanabiKinds, contains(s.kind));
          expect(s.endTime, greaterThanOrEqualTo(s.startTime));
        }
      }
      for (int i = 1; i < a.paragraphs.length; i++) {
        expect(
          a.paragraphs[i].startTime,
          greaterThanOrEqualTo(a.paragraphs[i - 1].startTime),
        );
      }
      expect(a.lyricEndTime, isNotNull);
    });

    test('没有歌词时编成纯器乐节目单', () {
      final HanabiProgram p = compileHanabiProgram(
        <HanabiLine>[],
        'seed',
        duration: 60,
      );
      expect(p.instrumental, isTrue);
      expect(p.paragraphs, isNotEmpty);
      expect(p.lyricEndTime, isNull);
    });

    test('副歌取运行时的 isChorus（folia 启发式：重复最多的行）', () {
      final LyricVisualizerRuntime runtime = LyricVisualizerRuntime(
        LyricTimeline(
          format: 'lrc',
          lines: <LyricLine>[
            for (final HanabiLine l in _song())
              LyricLine(
                startMs: (l.startTime * 1000).round(),
                endMs: (l.endTime * 1000).round(),
                syllables: <LyricSyllable>[
                  LyricSyllable(
                    text: l.text,
                    startMs: (l.startTime * 1000).round(),
                    endMs: (l.endTime * 1000).round(),
                  ),
                ],
              ),
          ],
        ),
      );
      final List<HanabiLine> lines = <HanabiLine>[
        for (final LyricVisualizerLine l in runtime.lines) hanabiLineOf(l)!,
      ];
      expect(lines.map((HanabiLine l) => l.isChorus), <bool>[
        true,
        false,
        false,
        true,
        false,
        true,
      ]);
      expect(lines[0].slice(0, 2).isChorus, isTrue);
      final List<HanabiChorusSpan> spans = resolveHanabiChorusSpans(lines);
      expect(spans, isNotEmpty);
      expect(resolveHanabiChorusWeight(const <HanabiChorusSpan>[], 3), 0);
    });

    test('关转场时只画当前段落、不套帧', () {
      final HanabiProgram p = compileHanabiProgram(
        _song(),
        'seed-2',
        duration: 40,
      );
      for (final double t in <double>[0, 3, 9, 15, 31]) {
        final HanabiSceneFrames frames = resolveHanabiSceneFrames(p, t, false);
        expect(frames.layers, hasLength(1));
        expect(frames.layers.single.frame.alpha, 1);
        expect(frames.layers.single.frame.blur, 0);
      }
    });

    test('片尾卡：歌词结束前不出现，之后淡入', () {
      expect(resolveHanabiCreditsFrame(10, 12).active, isFalse);
      final HanabiCreditsFrame late = resolveHanabiCreditsFrame(20, 12);
      expect(late.active, isTrue);
      expect(late.lyricAlpha, closeTo(0, 1e-6));
      expect(late.posterAlpha, closeTo(1, 1e-6));
    });
  });

  group('共享框架', () {
    test('分词走共享分词：汉字 + 送假名成词、助词单独、标点拆出来不算词', () {
      final HanabiLine l = _line('夜空に光を！ hello, world', 0, 0.1);
      final List<String> parts = <String>[
        for (final HanabiSegment s in l.segments)
          '${l.chars.sublist(s.start, s.end).join()}${s.wordLike ? '' : '*'}',
      ];
      expect(parts, <String>[
        '夜空',
        'に',
        '光',
        'を',
        '！*',
        ' *',
        'hello',
        ',*',
        ' *',
        'world',
      ]);
      // 段首尾相接、覆盖整行
      int at = 0;
      for (final HanabiSegment s in l.segments) {
        expect(s.start, at);
        at = s.end;
      }
      expect(at, l.chars.length);
    });

    test('随拍开花：节拍表、每拍一朵、没节奏不开、强度 0 不开', () {
      final LyricVisualizerContext c = visualizerContextFor(
        hanabiVisualizerEntry,
        clock: FakeVisualizerClock(),
        audio: SyntheticVisualizerAudio(),
      );
      final List<HanabiBeatEvent> events = hanabiBeatEventsOf(c);
      expect(events, isNotEmpty);
      expect(events.first.downbeat, isTrue);
      expect(events[1].downbeat, isFalse);
      expect(
        hanabiBeatEventsOf(
          visualizerContextFor(
            hanabiVisualizerEntry,
            clock: FakeVisualizerClock(),
          ),
        ),
        isEmpty,
      );
      final HanabiBeatShell big = resolveHanabiBeatShell(events[0], 's', 1)!;
      final HanabiBeatShell small = resolveHanabiBeatShell(events[1], 's', 1)!;
      expect(big.launch, isTrue);
      expect(small.launch, isFalse);
      expect(big.spec.radius, greaterThan(small.spec.radius));
      expect(big.sx, inInclusiveRange(0.2, 0.8));
      expect(small.sy, inInclusiveRange(0.07, 0.43));
      // 同一拍同一种子永远一样
      expect(resolveHanabiBeatShell(events[1], 's', 1)!.sx, small.sx);
      expect(resolveHanabiBeatShell(events[1], 's', 0), isNull);
      expect(
        resolveHanabiBeatShell(
          const HanabiBeatEvent(t: 1, downbeat: false, gain: 0),
          's',
          1,
        ),
        isNull,
      );
      expect(firstHanabiBeatAtOrAfter(events, 0.6), 2);
    });

    test('随拍推镜：拍上推近、重拍更深、每拍换边；没有节拍网格不推', () {
      final LyricVisualizerContext c = visualizerContextFor(
        hanabiVisualizerEntry,
        clock: FakeVisualizerClock(),
        audio: SyntheticVisualizerAudio(),
      );
      final ({double scale, double rotation}) down = hanabiBeatPulseAt(
        c,
        2000,
        1,
      );
      final ({double scale, double rotation}) beat = hanabiBeatPulseAt(
        c,
        2500,
        1,
      );
      expect(down.scale, greaterThan(beat.scale));
      expect(beat.scale, greaterThan(1));
      expect(down.rotation.sign, -beat.rotation.sign);
      expect(hanabiBeatPulseAt(c, 2000, 0).scale, 1);
      final LyricVisualizerContext none = visualizerContextFor(
        hanabiVisualizerEntry,
        clock: FakeVisualizerClock(),
      );
      expect(hanabiBeatPulseAt(none, 2000, 1).scale, 1);
    });

    test('关键字色：整词命中或包含关键字，不分大小写', () {
      expect(hanabiKeywordColorOf(null), isNull);
      expect(hanabiKeywordColorOf(const LyricVisualizerTheme()), isNull);
      final int? Function(String) of = hanabiKeywordColorOf(
        const LyricVisualizerTheme(
          wordColors: <String, Color>{
            '花火': Color(0xFFE53935),
            'Summer': Color(0xFF1E88E5),
          },
        ),
      )!;
      expect(of('花火'), 0xE53935);
      expect(of('花火を'), 0xE53935);
      expect(of('summer'), 0x1E88E5);
      expect(of('夜空'), isNull);
    });

    test('背景：用户选的共享背景', () {
      expect(
        hanabiVisualizerEntry.backgroundFor(
          LyricVisualizerTuning.defaults(hanabiVisualizerEntry.tunings),
        ),
        LyricVisualizerBackgroundRequest.selected,
      );
    });
  });

  group('时间轴', () {
    test('镜头按顺序进出场，世界只往上走', () {
      final List<TimelineShot> shots = <TimelineShot>[
        for (int i = 0; i < 4; i++)
          TimelineShot(
            startTime: i * 3.0,
            endTime: i * 3.0 + 3,
            firstSung: i * 3.0 + 0.5,
            lastSungEnd: i * 3.0 + 2.5,
            isBridge: false,
            camera: const HanabiCamera(
              rise: 0.5,
              push: 0.05,
              roll: 0.02,
              punch: 0.5,
            ),
          ),
      ];
      final HanabiTimeline timeline = buildTimeline(
        shots,
        unitEnd: 12,
        height: 800,
        riseSpeed: 1,
        motion: 1,
      );
      expect(timeline.shots, hasLength(4));
      for (int i = 0; i < 4; i++) {
        final ShotTiming t = timeline.shots[i];
        expect(t.exitAt, greaterThan(t.enterAt));
        if (i > 0) {
          expect(t.enterAt, greaterThan(timeline.shots[i - 1].enterAt));
          expect(t.worldY, lessThan(timeline.shots[i - 1].worldY));
        }
      }
      expect(timeline.rise(11), greaterThan(timeline.rise(0.5)));
      expect(timeline.shotAt(7), 2);
    });

    test('转角为 0 时世界不转', () {
      final SpinPlan plan = planSpin(
        <double>[3, 3, 3],
        amount: 0,
        direction: 1,
        random: hanabiRng('x'),
      );
      expect(plan.angles.every((double a) => a == 0), isTrue);
    });
  });

  group('排字', () {
    test('均分成连续的若干段', () {
      final List<(double, bool)> units = <(double, bool)>[
        for (int i = 0; i < 10; i++) (1.0, i == 4),
      ];
      final List<List<int>> runs = partitionRuns(
        units,
        List<double>.filled(10, 0.3),
        3,
      );
      expect(runs, hasLength(3));
      final List<int> flat = <int>[for (final List<int> r in runs) ...r];
      expect(flat, <int>[for (int i = 0; i < flat.length; i++) flat.first + i]);
    });

    test('长行在文字区里放得下', () {
      const String text = 'the summer night sky is full of fireworks tonight';
      final List<String> chars = text.split('');
      final List<LayoutWordInput> words = <LayoutWordInput>[];
      final List<int> glyphWord = List<int>.filled(chars.length, 0);
      int start = 0;
      for (int i = 0; i <= chars.length; i++) {
        if (i == chars.length || chars[i] == ' ') {
          if (i > start) {
            words.add(
              LayoutWordInput(
                text: text.substring(start, i),
                start: start,
                end: i,
                blank: false,
                space: false,
              ),
            );
            for (int g = start; g < i; g++) {
              glyphWord[g] = words.length - 1;
            }
          }
          if (i < chars.length) {
            words.add(
              LayoutWordInput(
                text: ' ',
                start: i,
                end: i + 1,
                blank: true,
                space: true,
              ),
            );
            glyphWord[i] = words.length - 1;
          }
          start = i + 1;
        }
      }
      for (final TextLayoutKind kind in <TextLayoutKind>[
        TextLayoutKind.center,
        TextLayoutKind.stagger,
        TextLayoutKind.left,
      ]) {
        final TextPlacement placement = layoutText(
          <LayoutGlyphInput>[
            for (int i = 0; i < chars.length; i++)
              LayoutGlyphInput(
                char: chars[i],
                advance: chars[i] == ' ' ? 0.3 : 0.6,
                blank: chars[i] == ' ',
                upright: false,
                word: glyphWord[i],
              ),
          ],
          words,
          LayoutParams(
            layout: kind,
            regionWidth: 300,
            regionHeight: 280,
            fontPx: 60,
            tilt: 0,
            seed: 'layout',
            tracking: 0,
            wordGap: 0.3,
            lineHeight: 1.2,
            minAdvance: 0.4,
            stairStep: 0,
            padding: 0.1,
          ),
        );
        expect(placement.glyphs, hasLength(chars.length), reason: '$kind');
        expect(
          placement.bounds.width,
          lessThanOrEqualTo(300 * 1.1),
          reason: '$kind',
        );
        expect(
          placement.bounds.height,
          lessThanOrEqualTo(280 * 1.1),
          reason: '$kind',
        );
        expect(placement.fontPx, lessThanOrEqualTo(60), reason: '$kind');
      }
    });
  });

  group('烟花', () {
    final HanabiPalette palette = resolveHanabiPalette(
      PaletteRole.festival,
      _theme,
      HanabiColorMode.vivid,
    );
    test('每种烟花都能排出星点，粒子量为 0 时什么都没有', () {
      for (final BurstKind kind in BurstKind.values) {
        final BurstPlan plan = planBurst(
          BurstEvent(
            x: 0,
            y: 0,
            at: 1,
            spec: burstPreset(kind),
            seed: 'k:${kind.name}',
          ),
          palette,
          unit: 800,
          amount: 1,
        );
        expect(plan.stars, isNotEmpty, reason: kind.name);
        expect(plan.end, greaterThan(plan.at), reason: kind.name);
        final BurstPlan again = planBurst(
          BurstEvent(
            x: 0,
            y: 0,
            at: 1,
            spec: burstPreset(kind),
            seed: 'k:${kind.name}',
          ),
          palette,
          unit: 800,
          amount: 1,
        );
        expect(again.stars.length, plan.stars.length, reason: kind.name);
      }
      final BurstPlan none = planBurst(
        BurstEvent(
          x: 0,
          y: 0,
          at: 1,
          spec: burstPreset(BurstKind.kiku),
          seed: 'none',
        ),
        palette,
        unit: 800,
        amount: 0,
      );
      expect(
        none.stars.where((StarPlan s) => s.life > 0 && s.size > 0).length,
        lessThanOrEqualTo(none.stars.length),
      );
    });

    test('调色板三种模式都给出可读的字色', () {
      for (final HanabiColorMode mode in HanabiColorMode.values) {
        for (final PaletteRole role in PaletteRole.values) {
          final HanabiPalette p = resolveHanabiPalette(role, _theme, mode);
          expect(p.sparks, isNotEmpty);
          expect(p.blocks, isNotEmpty);
          for (final int b in p.blocks) {
            expect(
              contrastRatio(b, p.ink),
              greaterThan(2.5),
              reason: '$mode $role',
            );
          }
        }
      }
    });
  });

  group('调节项', () {
    test('默认值与 folia 一致', () {
      final HanabiSettings s = hanabiSettingsOf(
        LyricVisualizerTuning.defaults(hanabiVisualizerEntry.tunings),
      );
      expect(s, const HanabiSettings());
      expect(
        hanabiVisualizerEntry.tunings
            .map((LyricVisualizerTuningSpec t) => t.key)
            .toSet(),
        hasLength(19),
      );
    });
  });

  group('widget', () {
    testWidgets('有音频分析：随拍开花 + 推镜拉满、AI 主题关键字与字重、激烈', (
      WidgetTester tester,
    ) async {
      await pumpVisualizerAcross(
        tester,
        hanabiVisualizerEntry,
        audio: SyntheticVisualizerAudio(),
        intensity: LyricVisualizerIntensity.chaotic,
        theme: const LyricVisualizerTheme(
          wordColors: <String, Color>{'夜空': Color(0xFFE53935)},
          fontWeight: FontWeight.w700,
        ),
        tuning: const <String, Object?>{'beatBursts': 2.0, 'beatPulse': 2.0},
        timesMs: const <int>[0, 1100, 1500, 2000, 2900, 3600, 5000, 12300],
      );
    });

    testWidgets('只有节拍、没有包络 + 平静 + 关随拍', (WidgetTester tester) async {
      await pumpVisualizerAcross(
        tester,
        hanabiVisualizerEntry,
        audio: SyntheticVisualizerAudio(envelopeReady: false),
        intensity: LyricVisualizerIntensity.calm,
        tuning: const <String, Object?>{'beatBursts': 0.0, 'beatPulse': 0.0},
      );
    });

    testWidgets('默认参数', (WidgetTester tester) async {
      await pumpVisualizerAcross(tester, hanabiVisualizerEntry);
    });

    testWidgets('仅文字 + 低画质 + 主题色 + 关升空 / 画面框 / 转动', (
      WidgetTester tester,
    ) async {
      await pumpVisualizerAcross(
        tester,
        hanabiVisualizerEntry,
        tuning: <String, Object?>{
          HanabiTuningKeys.textOnly: true,
          HanabiTuningKeys.renderQuality: 'low',
          HanabiTuningKeys.colorMode: 'theme',
          HanabiTuningKeys.launches: false,
          HanabiTuningKeys.overlayFrame: false,
          HanabiTuningKeys.spin: 0.0,
        },
      );
    });

    testWidgets('均衡 + 鲜艳 + 满量火花与装饰 + 无夜空', (WidgetTester tester) async {
      await pumpVisualizerAcross(
        tester,
        hanabiVisualizerEntry,
        tuning: <String, Object?>{
          HanabiTuningKeys.renderQuality: 'balanced',
          HanabiTuningKeys.colorMode: 'vivid',
          HanabiTuningKeys.sparkAmount: 2.0,
          HanabiTuningKeys.ornamentAmount: 2.0,
          HanabiTuningKeys.ambient: 2.0,
          HanabiTuningKeys.sky: 0.0,
          HanabiTuningKeys.collage: 0.0,
          HanabiTuningKeys.chorusBloom: 2.0,
        },
      );
    });

    testWidgets('行级歌词', (WidgetTester tester) async {
      await pumpVisualizerAcross(
        tester,
        hanabiVisualizerEntry,
        timeline: sampleLineTimeline(),
      );
    });

    testWidgets('减弱动态效果', (WidgetTester tester) async {
      await pumpVisualizerAcross(tester, hanabiVisualizerEntry, motion: false);
    });

    testWidgets('竖屏窄画幅', (WidgetTester tester) async {
      await pumpVisualizerAcross(
        tester,
        hanabiVisualizerEntry,
        size: const Size(390, 844),
      );
    });
  });
}
