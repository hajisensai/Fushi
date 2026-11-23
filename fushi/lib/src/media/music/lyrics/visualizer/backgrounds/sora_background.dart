/// 背景「空」（移植 folia `backgrounds/sora/`）：夜间纯黑 / 日间纯白底上 150 颗横向缓缓漂过、
/// 闪烁的星点（10% 用强调色）。folia 用 WebGL GL_POINTS 画；150 个点在 Canvas 上很便宜，直接按
/// 它的顶点着色器逐点算位置 / 大小 / 闪烁。暂停与减弱动态效果时星空停住。
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/backgrounds/background_scene.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_frame.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

/// 落库键（冻结）。
abstract final class SoraBackgroundKeys {
  static const String blank = 'blank';
}

final List<LyricVisualizerTuningSpec> soraBackgroundTunings =
    <LyricVisualizerTuningSpec>[
      LyricVisualizerToggleSpec(
        key: SoraBackgroundKeys.blank,
        label: () => t.music_visualizer_background_sora_blank,
        initial: false,
      ),
    ];

final LyricVisualizerBackgroundEntry soraBackgroundEntry =
    LyricVisualizerBackgroundEntry(
      id: 'sora',
      label: () => t.music_visualizer_background_sora,
      icon: FushiIcons.star,
      tunings: soraBackgroundTunings,
      builder: (LyricVisualizerContext c, LyricVisualizerTuning tu) =>
          LyricVisualizerBackgroundView(
            context: c,
            tuning: tu,
            create: SoraBackgroundScene.new,
          ),
    );

/// 星点数（folia `PARTICLE_COUNT`）。
const int kSoraParticleCount = 150;

/// 一颗星在某一时刻（folia 顶点着色器的输出）。坐标是逻辑像素，[diameter] 也是。
typedef SoraStar = ({
  Offset center,
  double diameter,
  double intensity,
  bool accent,
});

/// folia `VERTEX_SHADER` 的 CPU 版：第 [index] 颗星在 [time] 秒、画布 [size] 下的位置 / 大小 / 闪烁。
/// [minDiameter] 是 `gl_PointSize` 的 2 设备像素下限（换成逻辑像素）。
SoraStar soraStarAt(int index, double time, Size size, double minDiameter) {
  final double seed = index * 123.456;
  final double speedRand = lyricBgHash2(seed, 1.1);
  final double sizeRand = lyricBgHash2(seed, 2.2);
  final double yRand = lyricBgHash2(seed, 3.3);
  final double xRand = lyricBgHash2(seed, 4.4);
  final double blinkRand = lyricBgHash2(seed, 5.5);
  final double colorRand = lyricBgHash2(seed, 6.6);
  final double aspect = size.width / size.height;
  final double speed = 0.008 + speedRand * 0.024;
  final double starSize = 0.0006 + 0.0032 * math.pow(sizeRand, 3.8);
  final double y = -0.45 + yRand * 0.9;
  const double margin = 0.05;
  final double width = aspect + margin * 2;
  double x = xRand + time * speed;
  x = x - x.floorToDouble();
  x = x * width - (aspect * 0.5 + margin);
  final double wave = math.sin(time * 0.3 + yRand * 6.283) * 0.005;
  // 世界坐标以画布高为 1：x 映射到 w/2 + x·h，y 向上。
  final Offset center = Offset(
    size.width / 2 + x * size.height,
    size.height / 2 - (y + wave) * size.height,
  );
  final double blink =
      0.3 + 0.7 * math.sin(time * (1 + blinkRand * 2.5) + xRand * 6.283);
  return (
    center: center,
    diameter: math.max(minDiameter, starSize * size.height * 3.5),
    intensity: blink,
    accent: colorRand > 0.9,
  );
}

class SoraBackgroundScene extends LyricVisualizerBackgroundScene {
  late LyricVisualizerContext _c;
  late LyricVisualizerTuning _tu;
  LyricBgColorBlend? _primary;
  LyricBgColorBlend? _accent;
  double _dpr = 1;
  double _time = 0;

  @override
  void configure(
    LyricVisualizerContext context,
    LyricVisualizerTuning tuning,
    double devicePixelRatio,
  ) {
    _c = context;
    _tu = tuning;
    _dpr = devicePixelRatio;
    (_primary ??= LyricBgColorBlend(
      context.palette.primary,
    )).target(context.palette.primary, immediate: !context.motion);
    (_accent ??= LyricBgColorBlend(
      context.palette.accent,
    )).target(context.palette.accent, immediate: !context.motion);
  }

  @override
  void advance(LyricVisualizerTick tick) {
    _primary!.advance(tick.dt);
    _accent!.advance(tick.dt);
    // folia：暂停或静态模式冻结星空。
    if (_c.playing && _c.motion) _time += tick.dt;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final bool daylight = _c.palette.brightness == Brightness.light;
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..color = daylight ? const Color(0xFFFFFFFF) : const Color(0xFF000000),
    );
    if (_tu.flag(SoraBackgroundKeys.blank, false)) return;
    final Color primary = _primary!.value.withValues(alpha: 1);
    final Color accent = _accent!.value.withValues(alpha: 1);
    final Paint paint = Paint();
    for (int i = 0; i < kSoraParticleCount; i++) {
      final SoraStar s = soraStarAt(i, _time, size, 2 / _dpr);
      if (s.intensity < 0.01) continue;
      final double r = s.diameter / 2;
      final Color c = s.accent ? accent : primary;
      // 片元着色器 `smoothstep(0.5, 0.1, dist) * intensity`：中心 0.2 半径内全亮，到边缘落到 0。
      paint.shader = ui.Gradient.radial(
        s.center,
        r,
        <Color>[
          c.withValues(alpha: s.intensity),
          c.withValues(alpha: s.intensity),
          c.withValues(alpha: s.intensity * 0.5),
          c.withValues(alpha: 0),
        ],
        const <double>[0, 0.2, 0.6, 1],
      );
      canvas.drawCircle(s.center, r, paint);
    }
  }
}
