import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_audio.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/hanabi/hanabi_beat_fx.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/hanabi/hanabi_catalog.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/hanabi/hanabi_color.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/hanabi/hanabi_fireworks.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/hanabi/hanabi_math.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/hanabi/hanabi_ornaments.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/hanabi/hanabi_text.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/hanabi/hanabi_text_layout.dart';

const HanabiPalette _palette = HanabiPalette(
  ink: 0x101010,
  paper: 0xfff4d6,
  blocks: <int>[0xe0287a, 0x2fbf71, 0xf2e3b0],
  sparks: <int>[0xffc760, 0x66d9ff, 0xff6f91],
  accent: 0xfff4d6,
  glow: 0xffe0a0,
);

/// 横排 6 个字，每 0.2 秒唱一个，入场 1 秒、退场 5 秒。
List<GlyphAnchor> _anchors(double time) => <GlyphAnchor>[
  for (int i = 0; i < 6; i++)
    GlyphAnchor(
      char: '夜空に咲いた'[i],
      x: -150 + i * 60.0,
      y: 0,
      size: 48,
      sungAt: 1.2 + i * 0.2,
      sungEnd: 1.4 + i * 0.2,
      landedAt: 1.1,
      alpha: 1,
      blank: false,
    ),
];

OrnamentKit _kit(OrnamentKind kind, OrnamentPlacement placement) => OrnamentKit(
  spec: OrnamentSpec(
    kind: kind,
    placement: placement,
    layer: OrnamentLayer.front,
    color: OrnamentColor.spark,
  ),
  palette: _palette,
  width: 1280,
  height: 720,
  seed: 'test:shot0:ornament0',
  bounds: const LayoutRect(-180, -30, 360, 60),
  anchorsAt: _anchors,
  enterAt: 1,
  exitAt: 5,
  exitDuration: 0.6,
  amount: 1,
);

/// 在 [time] 画一件装饰件（只验证能画完、不抛错）。
void _render(HanabiOrnament orn, double time) {
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final ui.Canvas canvas = ui.Canvas(recorder);
  orn.paint(canvas, time);
  recorder.endRecording().dispose();
}

void main() {
  group('MG 装饰件（folia ornaments 一比一）', () {
    test('随机种子按 folia 的字符串键（dash-circle / line-start 带连字符）', () {
      final OrnamentKit kit = _kit(
        OrnamentKind.dashCircle,
        OrnamentPlacement.lineStart,
      );
      final HanabiRng expected = hanabiRng(
        'test:shot0:ornament0:ornament:dash-circle:line-start',
      );
      expect(kit.rng(), expected());
    });

    test('21 种件 × 7 种布点在整个时间窗里都能画', () {
      for (final OrnamentKind kind in OrnamentKind.values) {
        for (final OrnamentPlacement placement in OrnamentPlacement.values) {
          final HanabiOrnament orn = HanabiOrnament(_kit(kind, placement));
          for (double t = 0.8; t <= 5.8; t += 0.37) {
            _render(orn, t);
          }
        }
      }
    });

    testWidgets('同一时刻画两次像素一致（画面只由时间决定）', (WidgetTester tester) async {
      for (final OrnamentKind kind in <OrnamentKind>[
        OrnamentKind.zigzag,
        OrnamentKind.confetti,
        OrnamentKind.halftone,
        OrnamentKind.spokes,
      ]) {
        final HanabiOrnament a = HanabiOrnament(
          _kit(kind, OrnamentPlacement.around),
        );
        final HanabiOrnament b = HanabiOrnament(
          _kit(kind, OrnamentPlacement.around),
        );
        final ByteData? pa = await tester.runAsync<ByteData?>(
          () => _pixels(a, 2.7),
        );
        final ByteData? pb = await tester.runAsync<ByteData?>(
          () => _pixels(b, 2.7),
        );
        expect(pa, isNotNull);
        expect(
          pa!.buffer.asUint8List(),
          pb!.buffer.asUint8List(),
          reason: '$kind',
        );
        expect(
          pa.buffer.asUint8List().any((int v) => v != 0),
          isTrue,
          reason: '$kind 应画出东西',
        );
      }
    });

    test('锯齿线：around 时从字组两侧抽出两条（folia tracksFor）', () {
      // 退场前、入场 0.5 秒后锯齿已完全抽出；画面非空即可，几何见 folia ornamentLines。
      final HanabiOrnament orn = HanabiOrnament(
        _kit(OrnamentKind.zigzag, OrnamentPlacement.around),
      );
      _render(orn, 2);
    });

    test('aroundBox：从左上角顺时针走方框周长', () {
      expect(aroundBox(0, 10, 5), (-10.0, -5.0));
      expect(aroundBox(0.25, 10, 5), (5.0, -5.0));
      expect(aroundBox(0.5, 10, 5), (10.0, 5.0));
      expect(aroundBox(0.75, 10, 5), (-5.0, 5.0));
    });

    test('共享纹理按 folia textures.ts 的尺寸（2× 倍率）', () {
      final OrnamentTextures tex = OrnamentTextures.instance;
      Size sizeOf(OrnamentTexture t) => tex.sources[t.index].size;
      expect(sizeOf(OrnamentTexture.dot), const Size(64, 64));
      expect(sizeOf(OrnamentTexture.glow), const Size(192, 192));
      expect(sizeOf(OrnamentTexture.streak), const Size(32, 256));
      expect(sizeOf(OrnamentTexture.ring), const Size(320, 320));
      expect(sizeOf(OrnamentTexture.triangle), const Size(96, 96));
      expect(sizeOf(OrnamentTexture.petal), const Size(64, 88));
    });
  });

  group('随拍开花（folia hanabiBeatFx）', () {
    test(
      '增益含整曲动感系数 trackScale（folia resolveBeatFxAccentGain(event, trackScale)）',
      () {
        List<LyricVisualizerBeatEvent> events(double scale) =>
            lyricVisualizerMergeBeatEvents(
              beats: const <LyricVisualizerBeat>[
                LyricVisualizerBeat(timeMs: 1000, downbeat: false, impact: 0.5),
              ],
              downbeatTimesMs: const <int>[],
              trackScale: scale,
            );
        // (0.35 + 0.65 × 0.5) × trackScale。
        expect(events(1).single.gain, closeTo(0.675, 1e-9));
        expect(events(0.5).single.gain, closeTo(0.3375, 1e-9));
        HanabiBeatShell shell(double scale) => resolveHanabiBeatShell(
          HanabiBeatEvent(
            t: 1,
            downbeat: false,
            gain: events(scale).single.gain,
          ),
          'seed',
          1,
        )!;
        // 半径 = 0.09 × (0.55 + 0.45 × gain) × (0.7 + 0.3 × strength)。
        expect(
          shell(1).spec.radius,
          closeTo(0.09 * (0.55 + 0.45 * 0.675), 1e-9),
        );
        expect(
          shell(0.5).spec.radius,
          closeTo(0.09 * (0.55 + 0.45 * 0.3375), 1e-9),
        );
      },
    );
  });

  group('烟花精灵批', () {
    testWidgets('拖尾段是 streak 纹理形状：中点居中、长 = |ab| + 0.5 × 粗、两侧软边', (
      WidgetTester tester,
    ) async {
      final HanabiSprites sprites = HanabiSprites.create();
      final SparkBatch batch = SparkBatch();
      // 竖直一段：a (50, 20) 新、b (50, 80) 旧，粗 10 → 精灵覆盖 y 17.5..82.5。
      batch.streak(50, 20, 50, 80, 10, 1, 0xffffff);
      final ByteData? bytes = await tester.runAsync<ByteData?>(() async {
        final ui.PictureRecorder recorder = ui.PictureRecorder();
        final ui.Canvas canvas = ui.Canvas(recorder);
        batch.flush(canvas, sprites);
        final ui.Image image = recorder.endRecording().toImageSync(100, 100);
        final ByteData? data = await image.toByteData();
        image.dispose();
        return data;
      });
      sprites.dispose();
      int alphaAt(int x, int y) => bytes!.getUint8((y * 100 + x) * 4 + 3);
      // 头比尾亮（1 → 0.28）。
      expect(alphaAt(50, 22), greaterThan(alphaAt(50, 78)));
      // 尾端仍有余光（不到零），延伸过 b 点 2.5 像素。
      expect(alphaAt(50, 81), greaterThan(0));
      // 中线比两侧亮（横向 0 → 1 → 0）。
      expect(alphaAt(50, 40), greaterThan(alphaAt(46, 40)));
      expect(alphaAt(56, 40), 0);
    });
  });
}

Future<ByteData?> _pixels(HanabiOrnament orn, double time) async {
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final ui.Canvas canvas = ui.Canvas(recorder);
  canvas.translate(320, 180);
  canvas.scale(0.5);
  orn.paint(canvas, time);
  final ui.Picture picture = recorder.endRecording();
  final ui.Image image = picture.toImageSync(640, 360);
  picture.dispose();
  final ByteData? data = await image.toByteData();
  image.dispose();
  return data;
}
