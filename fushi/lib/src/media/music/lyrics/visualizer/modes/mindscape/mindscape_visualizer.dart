/// 全屏歌词动画样式「心象」（移植自 folia-major `src/components/visualizer/cadenza/`）。
///
/// 整句拆成词 / 字散落在焦点四周：最有分量的一个词放大居中当「主角」，其余绕开它、
/// 互不重叠地排开；未唱的词缩小、倾斜、模糊着隐身，唱到时放大 1.3 倍、上色并发光，
/// 唱过的词保留残影慢慢向外漂、转一个小角度。整行进出场带缩放与模糊。
/// 布局在 `mindscape_layout.dart`，时序包络在 `mindscape_timing.dart`，逐帧绘制在
/// `mindscape_scene.dart`。
library;

import 'package:fushi/i18n/strings.g.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_frame.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/mindscape/mindscape_scene.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

/// 可调参数（folia `DEFAULT_CADENZA_TUNING` + 主题的动画强度）。
final List<LyricVisualizerTuningSpec> mindscapeTunings =
    <LyricVisualizerTuningSpec>[
      LyricVisualizerSliderSpec(
        key: MindscapeTuningKeys.fontScale,
        label: () => t.music_visualizer_mindscape_font_scale,
        min: 0.6,
        max: 1.8,
        initial: 1.12,
        divisions: 24,
      ),
      LyricVisualizerSliderSpec(
        key: MindscapeTuningKeys.widthRatio,
        label: () => t.music_visualizer_mindscape_width_ratio,
        min: 0.4,
        max: 1,
        initial: 0.72,
        divisions: 30,
      ),
      LyricVisualizerSliderSpec(
        key: MindscapeTuningKeys.motionAmount,
        label: () => t.music_visualizer_mindscape_motion_amount,
        min: 0,
        max: 2,
        initial: 1,
        divisions: 20,
      ),
      LyricVisualizerSliderSpec(
        key: MindscapeTuningKeys.glowIntensity,
        label: () => t.music_visualizer_mindscape_glow_intensity,
        min: 0,
        max: 2,
        initial: 1,
        divisions: 20,
      ),
      LyricVisualizerChoiceSpec(
        key: MindscapeTuningKeys.intensity,
        label: () => t.music_visualizer_mindscape_intensity,
        options: <(String, String Function())>[
          ('calm', () => t.music_visualizer_mindscape_intensity_calm),
          ('normal', () => t.music_visualizer_mindscape_intensity_normal),
          ('chaotic', () => t.music_visualizer_mindscape_intensity_chaotic),
        ],
        initial: 'normal',
      ),
    ];

/// 注册项。
final LyricVisualizerEntry mindscapeVisualizerEntry = LyricVisualizerEntry(
  mode: LyricVisualizerMode.mindscape,
  label: () => t.music_visualizer_mode_mindscape,
  description: () => t.music_visualizer_mindscape_description,
  icon: FushiIcons.hub,
  tunings: mindscapeTunings,
  sharedBackdrop: true,
  sharedSubtitle: true,
  builder: (LyricVisualizerContext c) => MindscapeVisualizer(context: c),
);

/// 心象样式本体：纯展示，不接手势（点按退出归宿主）。
class MindscapeVisualizer extends StatefulWidget {
  const MindscapeVisualizer({super.key, required this.context});

  final LyricVisualizerContext context;

  @override
  State<MindscapeVisualizer> createState() => _MindscapeVisualizerState();
}

class _MindscapeVisualizerState extends State<MindscapeVisualizer> {
  final MindscapeScene _scene = MindscapeScene();

  @override
  void dispose() {
    _scene.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final MindscapeConfig config = MindscapeConfig.of(
      widget.context,
      DefaultTextStyle.of(context).style,
    );
    return RepaintBoundary(
      child: LyricVisualizerFrame(
        context: widget.context,
        builder: (BuildContext _, LyricVisualizerTicks ticks) => CustomPaint(
          size: Size.infinite,
          painter: _MindscapePainter(
            scene: _scene,
            config: config,
            ticks: ticks,
          ),
        ),
      ),
    );
  }
}

class _MindscapePainter extends CustomPainter {
  _MindscapePainter({
    required this.scene,
    required this.config,
    required this.ticks,
  }) : super(repaint: ticks);

  final MindscapeScene scene;
  final MindscapeConfig config;
  final LyricVisualizerTicks ticks;

  @override
  void paint(Canvas canvas, Size size) {
    final LyricVisualizerTick tick = ticks.value;
    scene.paint(canvas, size, config, tick.timeMs, tick.elapsed);
  }

  @override
  bool shouldRepaint(_MindscapePainter old) =>
      !identical(old.config, config) || !identical(old.ticks, ticks);
}
