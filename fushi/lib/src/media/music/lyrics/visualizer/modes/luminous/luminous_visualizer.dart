/// 全屏歌词动画样式「流光」（移植自 folia-major `src/components/visualizer/classic/`）。
///
/// 单行大字：每个词按行起点做确定性随机偏移 / 旋转 / 缩放，flex-wrap 排开；词按自己的时间
/// waiting → active → passed（弹簧放大点亮、逐字扫光、唱完回落并慢慢转开），整句入场
/// 模糊放大、离场放大模糊淡出，整片歌词随呼吸轻浮。译文 / 下一句走宿主共享字幕。
library;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_frame.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/luminous/luminous_layout.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/luminous/luminous_scene.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/luminous/luminous_timing.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

/// 落库键（冻结；与 folia `ClassicTuning` 字段同名）。
abstract final class LuminousTuningKeys {
  static const String enableWordRotation = 'enableWordRotation';
  static const String breathingFloatMultiplier = 'breathingFloatMultiplier';
  static const String layoutMode = 'layoutMode';
  static const String wordSpacing = 'wordSpacing';
  static const String avoidOverlap = 'avoidOverlap';
  static const String animationIntensity = 'animationIntensity';
}

/// 参数声明（folia `classic/tuning.ts` + 主题的动画强度）。
final List<LyricVisualizerTuningSpec> luminousTunings =
    <LyricVisualizerTuningSpec>[
      LyricVisualizerToggleSpec(
        key: LuminousTuningKeys.enableWordRotation,
        label: () => t.music_visualizer_luminous_word_rotation,
        initial: true,
      ),
      LyricVisualizerSliderSpec(
        key: LuminousTuningKeys.breathingFloatMultiplier,
        label: () => t.music_visualizer_luminous_breathing_float,
        min: 0,
        max: 2,
        initial: 1,
        divisions: 20,
        format: (double v) => '${v.toStringAsFixed(1)}×',
      ),
      LyricVisualizerChoiceSpec(
        key: LuminousTuningKeys.layoutMode,
        label: () => t.music_visualizer_luminous_layout_mode,
        options: <(String, String Function())>[
          ('adaptive', () => t.music_visualizer_luminous_layout_adaptive),
          ('legacy', () => t.music_visualizer_luminous_layout_legacy),
        ],
        initial: 'adaptive',
      ),
      LyricVisualizerSliderSpec(
        key: LuminousTuningKeys.wordSpacing,
        label: () => t.music_visualizer_luminous_word_spacing,
        min: 0,
        max: 2,
        initial: 0.7,
        divisions: 20,
        format: (double v) => '${v.toStringAsFixed(1)}×',
      ),
      LyricVisualizerToggleSpec(
        key: LuminousTuningKeys.avoidOverlap,
        label: () => t.music_visualizer_luminous_avoid_overlap,
        initial: false,
      ),
      LyricVisualizerChoiceSpec(
        key: LuminousTuningKeys.animationIntensity,
        label: () => t.music_visualizer_luminous_intensity,
        options: <(String, String Function())>[
          ('calm', () => t.music_visualizer_luminous_intensity_calm),
          ('normal', () => t.music_visualizer_luminous_intensity_normal),
          ('chaotic', () => t.music_visualizer_luminous_intensity_chaotic),
        ],
        initial: 'normal',
      ),
    ];

/// 当前参数 → 排版参数。
LuminousLayoutParams luminousParamsOf(LyricVisualizerTuning tuning) {
  final String intensity = tuning.choice(
    LuminousTuningKeys.animationIntensity,
    'normal',
  );
  return LuminousLayoutParams(
    intensity: switch (intensity) {
      'calm' => LuminousIntensity.calm,
      'chaotic' => LuminousIntensity.chaotic,
      _ => LuminousIntensity.normal,
    },
    rotation: tuning.flag(LuminousTuningKeys.enableWordRotation, true),
    legacy:
        tuning.choice(LuminousTuningKeys.layoutMode, 'adaptive') == 'legacy',
    wordSpacing: tuning.number(LuminousTuningKeys.wordSpacing, 0.7),
    avoidOverlap: tuning.flag(LuminousTuningKeys.avoidOverlap, false),
  );
}

/// 注册项。
final LyricVisualizerEntry luminousVisualizerEntry = LyricVisualizerEntry(
  mode: LyricVisualizerMode.luminous,
  label: () => t.music_visualizer_mode_luminous,
  description: () => t.music_visualizer_luminous_description,
  icon: FushiIcons.lightbulb,
  tunings: luminousTunings,
  sharedBackdrop: true,
  builder: (LyricVisualizerContext c) => LuminousVisualizer(context: c),
);

/// 流光本体。
class LuminousVisualizer extends StatefulWidget {
  const LuminousVisualizer({super.key, required this.context});

  final LyricVisualizerContext context;

  @override
  State<LuminousVisualizer> createState() => _LuminousVisualizerState();
}

class _LuminousVisualizerState extends State<LuminousVisualizer> {
  final LuminousScene _scene = LuminousScene();

  @override
  void didUpdateWidget(covariant LuminousVisualizer oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 换歌（时间轴变了）：旧句子的排版按下标缓存，必须作废。
    if (!identical(oldWidget.context.runtime, widget.context.runtime)) {
      _scene.reset();
    }
  }

  @override
  void dispose() {
    _scene.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext buildContext) {
    final LyricVisualizerContext c = widget.context;
    final TextStyle inherited = DefaultTextStyle.of(buildContext).style;
    return RepaintBoundary(
      child: LyricVisualizerFrame(
        context: c,
        builder: (BuildContext bc, LyricVisualizerTicks ticks) => CustomPaint(
          size: Size.infinite,
          painter: _LuminousPainter(
            scene: _scene,
            context: c,
            ticks: ticks,
            fontFamily: inherited.fontFamily,
            fontFamilyFallback: inherited.fontFamilyFallback,
          ),
        ),
      ),
    );
  }
}

class _LuminousPainter extends CustomPainter {
  _LuminousPainter({
    required this.scene,
    required this.context,
    required this.ticks,
    required this.fontFamily,
    required this.fontFamilyFallback,
  }) : super(repaint: ticks);

  final LuminousScene scene;
  final LyricVisualizerContext context;
  final LyricVisualizerTicks ticks;
  final String? fontFamily;
  final List<String>? fontFamilyFallback;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final LyricVisualizerContext c = context;
    final LyricVisualizerTick tick = ticks.value;
    scene.paint(
      canvas,
      LuminousSceneConfig(
        size: size,
        fontScale: c.fontScale,
        params: luminousParamsOf(c.tuning),
        baseColor: c.palette.text,
        activeColor: c.palette.accent,
        fontFamily: fontFamily,
        fontFamilyFallback: fontFamilyFallback,
      ),
      c.runtime,
      t: tick.timeMs / 1000,
      elapsed: tick.elapsed,
      motion: c.motion,
      breathingMultiplier: c.tuning.number(
        LuminousTuningKeys.breathingFloatMultiplier,
        1,
      ),
    );
  }

  @override
  bool shouldRepaint(covariant _LuminousPainter old) =>
      old.context != context ||
      old.ticks != ticks ||
      old.fontFamily != fontFamily ||
      old.scene != scene;
}
