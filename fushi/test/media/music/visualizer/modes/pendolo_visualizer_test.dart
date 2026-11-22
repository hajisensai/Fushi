import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_music/fushi_music.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_runtime.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/pendolo/pendolo_beat_fx.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/pendolo/pendolo_geometry.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/pendolo/pendolo_text.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/pendolo/pendolo_tuning.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/pendolo/pendolo_visualizer.dart';

import '../visualizer_test_helpers.dart';

/// 两句，第一句来源标成副歌（folia `isChorus`）。
LyricTimeline _chorusTimeline() => const LyricTimeline(
  format: 'ttml',
  timingQuality: LyricTimingQuality.word,
  lines: <LyricLine>[
    LyricLine(
      startMs: 1000,
      endMs: 3000,
      songPart: 'Chorus',
      syllables: <LyricSyllable>[
        LyricSyllable(text: '夜', startMs: 1000, endMs: 1500),
        LyricSyllable(text: '空', startMs: 1500, endMs: 2000),
        LyricSyllable(text: 'に', startMs: 2000, endMs: 2500),
        LyricSyllable(text: '光', startMs: 2500, endMs: 3000),
      ],
    ),
    LyricLine(
      startMs: 4000,
      endMs: 6000,
      songPart: 'Verse',
      syllables: <LyricSyllable>[
        LyricSyllable(text: 'ま', startMs: 4000, endMs: 5000),
        LyricSyllable(text: 'た', startMs: 5000, endMs: 6000),
      ],
    ),
  ],
);

/// 只有鼓击的音频（每 500ms 一下满强度）；[ready] 为 false 时鼓击没就绪。
class _DrumAudio implements LyricVisualizerAudio {
  _DrumAudio({this.ready = true});

  final bool ready;

  @override
  bool get envelopeReady => true;

  @override
  bool get beatsReady => false;

  @override
  List<int> get beatTimesMs => const <int>[];

  @override
  List<int> get downbeatTimesMs => const <int>[];

  @override
  double? get bpm => null;

  @override
  List<LyricVisualizerBeat> get beats => const <LyricVisualizerBeat>[];

  @override
  bool get hasBeatAccents => false;

  @override
  double get trackScale => 1;

  /// 每 500 ms 一下：底鼓 / 军鼓 / 底鼓 / 镲片轮着来。
  @override
  List<LyricVisualizerDrumHit> get drumHits => ready
      ? <LyricVisualizerDrumHit>[
          for (int i = 0; i < 120; i++)
            LyricVisualizerDrumHit(
              timeMs: i * 500,
              kind: const <LyricVisualizerDrumKind>[
                LyricVisualizerDrumKind.kick,
                LyricVisualizerDrumKind.snare,
                LyricVisualizerDrumKind.kick,
                LyricVisualizerDrumKind.hat,
              ][i % 4],
              strength: 1,
            ),
        ]
      : const <LyricVisualizerDrumHit>[];

  @override
  bool get drumsReady => ready;

  @override
  List<int> get vocalOnsetsMs => const <int>[];

  @override
  int? get vocalCoveredUntilMs => null;

  @override
  LyricVisualizerAudioFrame frameAt(int audioMs) => LyricVisualizerAudioFrame(
    power: 0.4,
    low: 0.9,
    mid: 0.3,
    high: 0.2,
    vocal: 0.3,
    onset: 0,
    beatImpact: 0,
    downbeatImpact: 0,
    drumImpact: ready
        ? lyricVisualizerImpactAt(<int>[
            for (int t = 0; t < 60000; t += 500) t,
          ], audioMs)
        : 0,
    envelopeReady: true,
    drumsReady: ready,
  );
}

void main() {
  group('轮盘布局', () {
    const PendoloTuning tuning = PendoloTuning();

    test('焦点句在刻度针方向（角度 0），后面的句子往下排', () {
      final List<PendoloLineItem> items = calculatePendoloWheelLayout(
        lineCount: 20,
        targetLineIndex: 5,
        viewportWidth: 1280,
        viewportHeight: 720,
        tuning: tuning,
      );
      final PendoloLineItem focal = items.firstWhere(
        (PendoloLineItem i) => i.index == 5,
      );
      expect(focal.isActive, isTrue);
      expect(focal.angleRad, 0);
      expect(focal.scale, tuning.activeScale);
      expect(focal.x, closeTo(720 * 0.42, 1e-9));
      expect(focal.y, closeTo(360, 1e-9));
      final PendoloLineItem next = items.firstWhere(
        (PendoloLineItem i) => i.index == 6,
      );
      expect(next.angleRad, closeTo(pendoloAngleStepRad(100), 1e-9));
      expect(next.y, greaterThan(focal.y));
      expect(next.alpha, lessThan(focal.alpha));
      // 只排在右半圆内。
      for (final PendoloLineItem i in items) {
        expect(i.angleRad.abs(), lessThan(math.pi / 2));
      }
    });

    test('块高度大时间距撑开', () {
      final List<PendoloLineItem> tight = calculatePendoloWheelLayout(
        lineCount: 10,
        targetLineIndex: 2,
        viewportWidth: 1280,
        viewportHeight: 720,
        tuning: tuning,
      );
      final List<PendoloLineItem> wide = calculatePendoloWheelLayout(
        lineCount: 10,
        targetLineIndex: 2,
        viewportWidth: 1280,
        viewportHeight: 720,
        tuning: tuning,
        lineBlockHeights: List<double>.filled(10, 200),
      );
      double angleOf(List<PendoloLineItem> l, int i) =>
          l.firstWhere((PendoloLineItem x) => x.index == i).angleRad;
      expect(angleOf(wide, 3), greaterThan(angleOf(tight, 3)));
      expect(
        angleOf(wide, 3),
        closeTo((200 + 200 + 24) / (2 * 720 * 0.42), 1e-9),
      );
    });

    test('镜像：轮心在右，弧朝左', () {
      const PendoloTuning mirrored = PendoloTuning(mirrored: true);
      final List<PendoloLineItem> items = calculatePendoloWheelLayout(
        lineCount: 5,
        targetLineIndex: 0,
        viewportWidth: 1000,
        viewportHeight: 800,
        tuning: mirrored,
      );
      expect(pendoloWheelCenterX(1000, mirrored), 1000);
      expect(items.first.x, lessThan(1000));
    });

    test('间奏里锚点在两句之间：没有焦点句，两边对称', () {
      final List<PendoloLineItem> items = calculatePendoloWheelLayout(
        lineCount: 6,
        targetLineIndex: 2.5,
        viewportWidth: 1280,
        viewportHeight: 720,
        tuning: tuning,
      );
      expect(items.any((PendoloLineItem i) => i.isActive), isFalse);
      final double a2 = items
          .firstWhere((PendoloLineItem i) => i.index == 2)
          .angleRad;
      final double a3 = items
          .firstWhere((PendoloLineItem i) => i.index == 3)
          .angleRad;
      expect(a2, closeTo(-a3, 1e-9));
    });
  });

  group('时间线', () {
    test('锚点：焦点 / 间奏 / 开头之前 / 全曲唱完', () {
      final LyricVisualizerRuntime rt = LyricVisualizerRuntime(
        sampleWordTimeline(),
      );
      expect(pendoloTargetIndexAt(rt, 500), -1);
      expect(pendoloTargetIndexAt(rt, 2000), 0);
      expect(pendoloTargetIndexAt(rt, 3300), 0.5);
      expect(pendoloTargetIndexAt(rt, 3600), 1);
      expect(pendoloTargetIndexAt(rt, 8000), 1.5);
      expect(pendoloTargetIndexAt(rt, 60000), rt.lines.length.toDouble());
    });

    test('没有歌词时每 5 秒走一格', () {
      final LyricVisualizerRuntime rt = LyricVisualizerRuntime(
        const LyricTimeline(format: 'lrc', lines: <LyricLine>[]),
      );
      expect(pendoloTargetIndexAt(rt, 12000), 2);
    });

    test('可见弧：110° 外看不见，边缘 28° 淡入', () {
      expect(pendoloRotatingLineOpacity(100, 15, 1), 0);
      expect(pendoloRotatingLineOpacity(0, 0, 0.8), 0.8);
      expect(pendoloRotatingLineOpacity(96, 0, 1), closeTo(0.5, 1e-9));
      expect(pendoloStandEdgeFade(70), closeTo(0.5, 1e-9));
      expect(pendoloStandSideLineAlpha(1), closeTo(0.18, 1e-9));
      expect(pendoloStandSideLineAlpha(4), 1);
    });
  });

  group('擒纵与机芯', () {
    test('弹簧趋向目标并停稳', () {
      final PendoloSpring spring = PendoloSpring(0);
      double peak = 0;
      for (int i = 0; i < 120; i++) {
        spring.step(1, 1 / 60, 2);
        peak = math.max(peak, spring.value);
      }
      expect(spring.value, closeTo(1, 1e-3));
      expect(peak, lessThan(1.2));
    });

    test('秒齿轮每秒走一齿；暂停冻结相位', () {
      final PendoloClockworkMotion m = PendoloClockworkMotion();
      for (int i = 0; i < 150; i++) {
        m.step(1 / 60, 0.2, paused: false);
      }
      expect(m.secondGearStep, 2);
      expect(m.secondGearAngle, greaterThan(0));
      final double phase = m.phase;
      m.step(0.05, 0.2, paused: true);
      expect(m.phase, phase);
    });
  });

  group('音频与动画强度', () {
    test('档位：calm / normal / chaotic 的倍率照 folia', () {
      expect(
        PendoloMotionProfile.of(LyricVisualizerIntensity.normal).bassResponse,
        1,
      );
      final PendoloMotionProfile calm = PendoloMotionProfile.of(
        LyricVisualizerIntensity.calm,
      );
      final PendoloMotionProfile chaotic = PendoloMotionProfile.of(
        LyricVisualizerIntensity.chaotic,
      );
      expect(calm.balanceAmplitude, 0.58);
      expect(chaotic.balanceSpeed, 1.3);
      expect(chaotic.chorusHaloOpacity, 0.5);
      expect(calm.chorusTransitionSeconds, 0.52);
    });

    test('副歌强调只给正在唱的副歌句', () {
      const PendoloMotionProfile p = PendoloMotionProfile.normal;
      final PendoloChorusLook on = PendoloChorusLook.of(true, true, p);
      expect(on.accentMix, 0.58);
      expect(on.haloOpacity, 0.34);
      expect(on.glow, 1);
      final PendoloChorusLook paused = PendoloChorusLook.of(true, false, p);
      expect(paused.active, isFalse);
      expect(paused.accentMix, 0.32);
      expect(paused.glow, 0);
      expect(PendoloChorusLook.of(false, true, p).haloScale, 1);
    });

    test('副歌强调按档位时长缓入缓出', () {
      final PendoloChorusRamp r = PendoloChorusRamp();
      r.step(true, 0.21, 0.42);
      expect(r.progress, closeTo(0.5, 1e-9));
      expect(r.eased, greaterThan(0.5));
      r.step(true, 1, 0.42);
      expect(r.eased, 1);
      r.step(false, 0.42, 0.42);
      expect(r.idle, isTrue);
    });

    test('摆轮：低频越强摆得越快越大；chaotic 比 calm 更猛', () {
      double swing(double bass, PendoloMotionProfile p) {
        final PendoloClockworkMotion m = PendoloClockworkMotion();
        double peak = 0;
        for (int i = 0; i < 600; i++) {
          m.step(
            1 / 60,
            bass,
            paused: false,
            bassResponse: p.bassResponse,
            balanceSpeed: p.balanceSpeed,
            balanceAmplitude: p.balanceAmplitude,
          );
          peak = math.max(peak, m.bassOscillation.abs());
        }
        return peak;
      }

      const PendoloMotionProfile n = PendoloMotionProfile.normal;
      expect(swing(0.9, n), greaterThan(swing(0.1, n) + 0.3));
      expect(
        swing(0.6, PendoloMotionProfile.chaotic),
        greaterThan(swing(0.6, PendoloMotionProfile.calm) * 1.8),
      );
    });

    test('鼓击按分贝读：弱击暗、强击满；强度 0 什么都不亮', () {
      expect(pendoloWavePunch(1, 1), 1);
      expect(pendoloWavePunch(kPendoloWeakBeatFloor, 1), closeTo(0.0316, 1e-3));
      expect(pendoloWavePunch(0.8, 0), 0);
      expect(pendoloWavePunch(0.8, 2), greaterThan(pendoloWavePunch(0.8, 1)));
    });

    test('鼓面：底鼓点亮并鼓起、强的抖屏；军鼓往敲下的方向歪；镲片只亮刻度圈；然后归静', () {
      final PendoloDrumhead d = PendoloDrumhead();
      expect(d.step(1 / 60, kPendoloNoDrums, strength: 1), isFalse);
      expect(d.glow, 0);
      // 强底鼓。
      expect(
        d.step(1 / 60, (kick: 0.9, snare: 0, hat: 0), strength: 1),
        isTrue,
      );
      expect(d.glow, greaterThan(0.5));
      expect(d.jewelFlare, d.glow);
      expect(d.tickDialLight, greaterThan(0.5));
      expect(d.outerDialLight, greaterThan(0.5));
      expect(d.shake, greaterThan(0.5));
      expect(d.haloScale, greaterThan(0.8));
      expect(d.tilt, Offset.zero);
      d.step(1 / 60, kPendoloNoDrums, strength: 1);
      expect(d.breath, isNot(1));
      expect(d.shakeOffset(math.Random(1)), isNot(Offset.zero));
      for (int i = 0; i < 120; i++) {
        d.step(1 / 60, kPendoloNoDrums, strength: 1);
      }
      expect(d.idle, isTrue);
      // 强军鼓：歪向敲下的方向（这里朝右），不鼓起、不抖屏。
      expect(
        d.step(1 / 60, (kick: 0, snare: 0.8, hat: 0), strength: 1),
        isTrue,
      );
      expect(d.tilt.dx, greaterThan(5));
      expect(d.tilt.dy.abs(), lessThan(1e-9));
      expect(d.shake, 0);
      expect(d.breath, 1);
      expect(d.shakeOffset(math.Random(1)), d.tilt);
      for (int i = 0; i < 120; i++) {
        d.step(1 / 60, kPendoloNoDrums, strength: 1);
      }
      expect(d.idle, isTrue);
      // 镲片：只亮刻度圈，光晕 / 外圈不亮。
      expect(d.step(1 / 60, (kick: 0, snare: 0, hat: 1), strength: 1), isFalse);
      expect(d.tickDialLight, closeTo(0.7, 1e-9));
      expect(d.glow, 0);
      expect(d.outerDialLight, 0);
      // 弱底鼓不抖屏；强度 0 什么都不亮。
      d.reset();
      d.step(1 / 60, (kick: 0.4, snare: 0, hat: 0), strength: 1);
      expect(d.glow, greaterThan(0));
      expect(d.shake, 0);
      d.reset();
      expect(d.step(1 / 60, (kick: 1, snare: 1, hat: 1), strength: 0), isFalse);
      expect(d.idle, isTrue);
    });

    test('鼓面只读共享鼓击表：按类取一帧里最强的一下；没就绪 / 没音频什么都没有', () {
      LyricVisualizerContext ctx(LyricVisualizerAudio? audio) =>
          visualizerContextFor(
            pendoloVisualizerEntry,
            clock: FakeVisualizerClock(),
            audio: audio,
          );
      // _DrumAudio：0 底鼓、500 军鼓、1000 底鼓、1500 镲片……
      final PendoloDrumFrame f = pendoloDrumFrameOf(
        LyricVisualizerBeats.of(ctx(_DrumAudio())),
        -1,
        1500,
      );
      expect(f, (kick: 1.0, snare: 1.0, hat: 1.0));
      expect(
        pendoloDrumFrameOf(LyricVisualizerBeats.of(ctx(_DrumAudio())), 0, 500),
        (kick: 0.0, snare: 1.0, hat: 0.0),
      );
      expect(
        pendoloDrumFrameOf(
          LyricVisualizerBeats.of(ctx(_DrumAudio(ready: false))),
          -1,
          5000,
        ),
        kPendoloNoDrums,
      );
      expect(
        pendoloDrumFrameOf(LyricVisualizerBeats.of(ctx(null)), -1, 5000),
        kPendoloNoDrums,
      );
    });

    test('效果色：强调色提亮提饱和；灰色主题用金色', () {
      final HSLColor c = HSLColor.fromColor(
        pendoloBeatFxColor(const Color(0xFF203060)),
      );
      expect(c.saturation, greaterThanOrEqualTo(0.58));
      expect(c.lightness, greaterThanOrEqualTo(0.68));
      expect(
        pendoloBeatFxColor(const Color(0xFF808080)),
        const Color(0xFFF3C46B),
      );
    });

    test('宝石：两颗大的（轮心、摆轮）+ 六颗小的', () {
      final List<PendoloJewel> j = pendoloJewels(
        PendoloClockworkAnchors(300, 340),
        0,
      );
      expect(j.length, 8);
      expect(j.where((PendoloJewel e) => !e.small).length, 2);
      expect(pendoloFlareRadius(1, false), 64);
    });
  });

  group('主题与副歌', () {
    test('wordColors 拆成同色段（只给扫亮层用）', () {
      final List<InlineSpan>? runs = pendoloColorRuns(
        '夜空に光',
        const LyricVisualizerTheme(
          wordColors: <String, Color>{'空': Color(0xFFFF0000)},
        ),
        const Color(0xFFEEEEEE),
      );
      expect(runs, isNotNull);
      final List<(String, Color?)> parts = <(String, Color?)>[
        for (final InlineSpan s in runs!)
          ((s as TextSpan).text!, s.style?.color),
      ];
      expect(parts, <(String, Color?)>[
        ('夜', const Color(0xFFEEEEEE)),
        ('空', const Color(0xFFFF0000)),
        ('に光', const Color(0xFFEEEEEE)),
      ]);
      expect(pendoloColorRuns('夜空', null, const Color(0xFFEEEEEE)), isNull);
    });

    testWidgets('副歌句的扫亮层带光晕，字体跟主题', (WidgetTester tester) async {
      final LyricVisualizerRuntime rt = LyricVisualizerRuntime(
        _chorusTimeline(),
      );
      expect(rt.lines[0].isChorus, isTrue);
      final PendoloLineBlock chorus = PendoloLineBlock.build(
        line: rt.lines[0],
        focal: true,
        fontScale: 1,
        maxWidth: 600,
        align: PendoloAlign.left,
        primary: const Color(0xFFFFFFFF),
        fillColor: const Color(0xFFFF8080),
        secondary: const Color(0xFFAAAAAA),
        baseStyle: const TextStyle(fontWeight: FontWeight.w800),
        chorusGlow: 1.42,
      );
      expect(chorus.glow, isNotNull);
      expect(chorus.glow!.padding, closeTo(28 * 0.7 * 1.42 + 10, 1e-9));
      expect(chorus.main.text!.style!.fontWeight, FontWeight.w800);
      final PendoloLineBlock plain = PendoloLineBlock.build(
        line: rt.lines[1],
        focal: true,
        fontScale: 1,
        maxWidth: 600,
        align: PendoloAlign.left,
        primary: const Color(0xFFFFFFFF),
        fillColor: const Color(0xFFFF8080),
        secondary: const Color(0xFFAAAAAA),
      );
      expect(plain.glow, isNull);
      chorus.dispose();
      plain.dispose();
    });

    test('最后一句过了视觉结束才转出去', () {
      final LyricVisualizerRuntime rt = LyricVisualizerRuntime(
        _chorusTimeline(),
      );
      final int end = rt.lines.last.renderEndMs;
      expect(pendoloTargetIndexAt(rt, end - 1), isNot(2));
      expect(pendoloTargetIndexAt(rt, end + 1), 2);
    });
  });

  group('投影', () {
    test('不倾斜是单位阵；倾斜时轮心不动', () {
      final PendoloDialProjection flat = buildPendoloTiltProjection(
        0,
        0,
        1280,
        720,
      );
      expect(flat.flat, isTrue);
      final ({double x, double y, double depthScale}) p = flat.project(30, -40);
      expect(p.x, 30);
      expect(p.y, -40);
      final PendoloDialProjection tilted = buildPendoloTiltProjection(
        40,
        0,
        1280,
        720,
      );
      expect(tilted.flat, isFalse);
      final ({double x, double y, double depthScale}) hub = tilted.project(
        0,
        0,
      );
      expect(hub.x, 0);
      expect(hub.y, 0);
      // 水平轴前后俯仰：轴上方往里退（缩小），下方朝外（放大）。
      expect(tilted.project(0, -100).depthScale, lessThan(1));
      expect(tilted.project(0, 100).depthScale, greaterThan(1));
    });

    test('镜像翻转横坐标；平放时分层高度不起作用', () {
      final PendoloDialProjection flat = buildPendoloTiltProjection(
        0,
        0,
        1280,
        720,
      );
      final PendoloDialProjection mirror = buildPendoloDialProjection(
        flat,
        mirrored: true,
      );
      expect(mirror.project(50, 10).x, -50);
      expect(identical(buildPendoloLayerProjection(flat, 40), flat), isTrue);
    });

    test('轮心视角把焦点句投到屏幕固定位置', () {
      final PendoloDialProjection hub = buildPendoloHubViewProjection(
        cameraHeightPx: 400,
        backDistancePx: 300,
        targetDistancePx: 350,
        side: 1,
        hubX: 0,
        hubY: 360,
        viewportWidth: 1280,
        viewportHeight: 720,
      );
      final ({double x, double y, double depthScale}) p = hub.project(350, 0);
      expect(p.x, closeTo(640, 1e-6));
      expect(p.y, closeTo(720 * 0.42 - 360, 1e-6));
      expect(p.depthScale, closeTo(1, 1e-9));
      expect(hub.frontHalfPlane(0.08, 1000)!.minX, lessThan(0));
    });
  });

  group('逐字扫光', () {
    const PendoloSweepRow row = PendoloSweepRow(
      left: 0,
      right: 60,
      top: 0,
      bottom: 30,
      glyphs: <PendoloSweepGlyph>[
        PendoloSweepGlyph(left: 0, right: 30, startMs: 1000, endMs: 1400),
        PendoloSweepGlyph(left: 30, right: 60, startMs: 1600, endMs: 2000),
      ],
    );

    test('起唱前不亮，字内线性推进，字间停在下一字左端，唱完到行尾', () {
      expect(pendoloSweepEdge(row, 900, 2000), isNull);
      expect(pendoloSweepEdge(row, 1200, 2000), closeTo(15, 1e-9));
      expect(pendoloSweepEdge(row, 1500, 2000), 30);
      expect(pendoloSweepEdge(row, 5000, 2000), 60);
    });

    testWidgets('焦点句按字形分行：CJK 与英文都拿到每个非空白字', (WidgetTester tester) async {
      final LyricVisualizerRuntime rt = LyricVisualizerRuntime(
        sampleWordTimeline(),
      );
      for (final LyricVisualizerLine line in rt.lines) {
        final PendoloLineBlock block = PendoloLineBlock.build(
          line: line,
          focal: true,
          fontScale: 1,
          maxWidth: 120,
          align: PendoloAlign.left,
          primary: Colors.white,
          fillColor: Colors.amber,
          secondary: Colors.grey,
        );
        final int glyphs = block.rows.fold<int>(
          0,
          (int n, PendoloSweepRow r) => n + r.glyphs.length,
        );
        expect(
          glyphs,
          line.glyphs.where((LyricVisualizerGlyph g) => !g.isSpace).length,
        );
        expect(block.width, lessThanOrEqualTo(120.5));
        block.dispose();
      }
    });
  });

  group('字幕偏好与预设', () {
    LyricVisualizerLine dual() => LyricVisualizerRuntime(
      const LyricTimeline(
        format: 'ttml',
        timingQuality: LyricTimingQuality.line,
        lines: <LyricLine>[
          LyricLine(
            startMs: 0,
            endMs: 2000,
            syllables: <LyricSyllable>[
              LyricSyllable(text: '夜空', startMs: 0, endMs: 2000),
            ],
            romanization: 'yozora',
            translations: <LyricTranslation>[LyricTranslation('zh', '夜空中的光')],
          ),
        ],
      ),
    ).lines.single;

    test('双行：罗马音在前，第二行退一级；字号乘字幕倍数；隐藏时没有', () {
      final List<PendoloSubtitleTrack> both = pendoloSubtitleTracks(
        dual(),
        subtitle: const LyricVisualizerSubtitleSettings(
          content: LyricVisualizerSubtitleContent.both,
          fontScale: 1.5,
        ),
        focal: true,
        fontScale: 1,
      );
      expect(both.map((PendoloSubtitleTrack t) => t.text), <String>[
        'yozora',
        '夜空中的光',
      ]);
      expect(both[0].fontPx, 24);
      expect(both[1].fontPx, (24 * 0.88).roundToDouble());
      expect(both[1].opacityFactor, 0.82);
      expect(both[1].weightFallback, FontWeight.w400);
      expect(
        pendoloSubtitleTracks(
          dual(),
          subtitle: const LyricVisualizerSubtitleSettings(
            hideTranslation: true,
          ),
          focal: true,
          fontScale: 1,
        ),
        isEmpty,
      );
      // 焦点高度按两行留够。
      final double one = pendoloFocalBlockHeight(
        dual(),
        fontScale: 1,
        measureWidth: 400,
        activeScale: 1,
      );
      final double two = pendoloFocalBlockHeight(
        dual(),
        fontScale: 1,
        measureWidth: 400,
        activeScale: 1,
        subtitle: const LyricVisualizerSubtitleSettings(
          content: LyricVisualizerSubtitleContent.both,
        ),
      );
      expect(two, greaterThan(one));
    });

    testWidgets('排版块按偏好出两行，字体单独选时换字族', (WidgetTester tester) async {
      final PendoloLineBlock block = PendoloLineBlock.build(
        line: dual(),
        focal: true,
        fontScale: 1,
        maxWidth: 400,
        align: PendoloAlign.left,
        primary: Colors.white,
        fillColor: Colors.amber,
        secondary: Colors.grey,
        subtitle: const LyricVisualizerSubtitleSettings(
          content: LyricVisualizerSubtitleContent.both,
          font: LyricVisualizerSubtitleFont.serif,
        ),
      );
      expect(block.subtitles, hasLength(2));
      expect(block.subtitles[1].text!.style!.fontFamily, 'serif');
      block.dispose();
    });

    test('预设保留用户当前的左右镜像', () {
      for (final LyricVisualizerTuningPreset p in pendoloTuningPresets) {
        final Map<String, Object> on = p.apply(
          pendoloVisualizerEntry.tunings,
          current: const <String, Object?>{
            PendoloTuningKeys.mirrorLayout: true,
          },
        );
        expect(on[PendoloTuningKeys.mirrorLayout], true, reason: p.id);
      }
    });
  });

  group('冒烟', () {
    testWidgets('默认参数', (WidgetTester tester) async {
      await pumpVisualizerAcross(tester, pendoloVisualizerEntry);
    });

    testWidgets('主题图标画在摆轮上 + 双行字幕（含镜像）', (WidgetTester tester) async {
      for (final bool mirrored in <bool>[false, true]) {
        await pumpVisualizerAcross(
          tester,
          pendoloVisualizerEntry,
          theme: const LyricVisualizerTheme(
            lyricsIcons: <LyricVisualizerThemeIcon>[
              LyricVisualizerThemeIcon.flower,
              LyricVisualizerThemeIcon.moon,
            ],
          ),
          subtitle: const LyricVisualizerSubtitleSettings(
            content: LyricVisualizerSubtitleContent.both,
          ),
          tuning: <String, Object?>{
            PendoloTuningKeys.mirrorLayout: mirrored,
            PendoloTuningKeys.showGearDecor: 'full',
          },
        );
      }
    });

    testWidgets('镜像 + 倾斜 + 完整饰线 + 发光', (WidgetTester tester) async {
      await pumpVisualizerAcross(
        tester,
        pendoloVisualizerEntry,
        tuning: <String, Object?>{
          PendoloTuningKeys.mirrorLayout: true,
          PendoloTuningKeys.tiltDeg: 35.0,
          PendoloTuningKeys.tiltAxisDeg: 20.0,
          PendoloTuningKeys.parallaxDepth: 1.65,
          PendoloTuningKeys.showGearDecor: 'full',
          PendoloTuningKeys.enableLineGlow: true,
          PendoloTuningKeys.showCoverOnWatchFace: true,
          PendoloTuningKeys.wheelCenterX: 0.1,
          PendoloTuningKeys.activeScale: 1.5,
        },
      );
    });

    testWidgets('轮心视角 + 无饰线 + 无渐变', (WidgetTester tester) async {
      await pumpVisualizerAcross(
        tester,
        pendoloVisualizerEntry,
        tuning: <String, Object?>{
          PendoloTuningKeys.hubView: true,
          PendoloTuningKeys.hubViewHeight: 0.6,
          PendoloTuningKeys.hubViewBack: 0.2,
          PendoloTuningKeys.showGearDecor: 'none',
          PendoloTuningKeys.showCenterGradient: false,
        },
      );
    });

    testWidgets('行级歌词', (WidgetTester tester) async {
      await pumpVisualizerAcross(
        tester,
        pendoloVisualizerEntry,
        timeline: sampleLineTimeline(),
      );
    });

    testWidgets('减弱动态 + 暂停', (WidgetTester tester) async {
      await pumpVisualizerAcross(
        tester,
        pendoloVisualizerEntry,
        motion: false,
        playing: false,
      );
    });

    testWidgets('真鼓击 + 副歌 + 主题 + chaotic', (WidgetTester tester) async {
      await pumpVisualizerAcross(
        tester,
        pendoloVisualizerEntry,
        timeline: _chorusTimeline(),
        audio: _DrumAudio(),
        intensity: LyricVisualizerIntensity.chaotic,
        theme: const LyricVisualizerTheme(
          wordColors: <String, Color>{'空': Color(0xFFFF0000)},
          fontWeight: FontWeight.w700,
        ),
        tuning: const <String, Object?>{
          PendoloTuningKeys.tiltDeg: 40.0,
          PendoloTuningKeys.showCoverOnWatchFace: true,
        },
      );
    });

    testWidgets('轮心视角 + 鼓击 + 副歌（calm）', (WidgetTester tester) async {
      await pumpVisualizerAcross(
        tester,
        pendoloVisualizerEntry,
        timeline: _chorusTimeline(),
        audio: SyntheticVisualizerAudio(),
        intensity: LyricVisualizerIntensity.calm,
        tuning: const <String, Object?>{PendoloTuningKeys.hubView: true},
      );
    });

    test('预设：三套都在默认值上只改各自那几项', () {
      expect(
        pendoloVisualizerEntry.tuningPresets.map(
          (LyricVisualizerTuningPreset p) => p.id,
        ),
        <String>['tiltForward', 'tilt', 'hubView'],
      );
      final Map<String, Object> hub = pendoloVisualizerEntry.tuningPresets.last
          .apply(pendoloVisualizerEntry.tunings);
      expect(hub[PendoloTuningKeys.hubView], isTrue);
      expect(hub[PendoloTuningKeys.arcRadius], 0.42);
      final PendoloTuning tilt = PendoloTuning.read(
        LyricVisualizerTuning(
          pendoloVisualizerEntry.tunings,
          pendoloVisualizerEntry.tuningPresets[1].values,
        ),
      );
      expect(tilt.tiltDeg, -53);
      expect(tilt.tiltAxisDeg, 66);
      expect(tilt.parallaxDepth, 1.65);
      expect(tilt.wheelCenterX, 0.3);
    });

    test('背景请求用户选的共享背景；轮心视角时藏起倾斜滑块', () {
      final LyricVisualizerTuning defaults = LyricVisualizerTuning.defaults(
        pendoloVisualizerEntry.tunings,
      );
      expect(
        pendoloVisualizerEntry.backgroundFor(defaults),
        LyricVisualizerBackgroundRequest.selected,
      );
      final LyricVisualizerTuningSpec tiltSpec = pendoloVisualizerEntry.tunings
          .firstWhere(
            (LyricVisualizerTuningSpec s) => s.key == PendoloTuningKeys.tiltDeg,
          );
      final LyricVisualizerTuning hub = LyricVisualizerTuning(
        pendoloVisualizerEntry.tunings,
        const <String, Object?>{PendoloTuningKeys.hubView: true},
      );
      expect(tiltSpec.visibleWhen!(defaults), isTrue);
      expect(tiltSpec.visibleWhen!(hub), isFalse);
    });

    testWidgets('窄屏竖屏', (WidgetTester tester) async {
      await pumpVisualizerAcross(
        tester,
        pendoloVisualizerEntry,
        size: const Size(390, 844),
      );
    });

    test('参数声明：默认值与 folia 一致', () {
      final LyricVisualizerTuning defaults = LyricVisualizerTuning.defaults(
        pendoloVisualizerEntry.tunings,
      );
      final PendoloTuning tu = PendoloTuning.read(defaults);
      expect(tu.arcRadius, 0.42);
      expect(tu.arcAngleDeg, 100);
      expect(tu.tickSnappiness, 2);
      expect(tu.activeScale, 1.25);
      expect(tu.gearDecor, PendoloGearDecor.subtle);
      expect(tu.showCenterGradient, isTrue);
      expect(tu.drumheadStrength, 1);
      expect(pendoloVisualizerEntry.sharedSubtitle, isFalse);
    });
  });
}
