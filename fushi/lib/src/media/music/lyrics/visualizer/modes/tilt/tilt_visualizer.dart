/// 全屏歌词动画样式「倾诉」（移植自 folia-major `src/components/visualizer/tilt/`）。
///
/// 长句按语义自动断成 1–4 行（概率由「分行概率」调），随机挑一行改成大号细斜体、字上下
/// 交错，像有人凑近低声说话；各行按唱到的位置逐行浮现、逐字错峰淡入，正在唱的字鼓起再
/// 留一点余辉。译文与下一句交给宿主的共享字幕。
library;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_frame.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/tilt/tilt_scene.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/tilt/tilt_tuning.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

/// 注册项。
final LyricVisualizerEntry tiltVisualizerEntry = LyricVisualizerEntry(
  mode: LyricVisualizerMode.tilt,
  label: () => t.music_visualizer_mode_tilt,
  description: () => t.music_visualizer_tilt_description,
  icon: FushiIcons.screenRotation,
  tunings: tiltTuningSpecs,
  sharedBackdrop: true,
  sharedSubtitle: true,
  builder: (LyricVisualizerContext c) => TiltVisualizer(context: c),
);

/// 倾诉样式本体。纯展示，不接手势（点按退出归宿主）。
class TiltVisualizer extends StatefulWidget {
  const TiltVisualizer({super.key, required this.context});

  final LyricVisualizerContext context;

  @override
  State<TiltVisualizer> createState() => _TiltVisualizerState();
}

class _TiltVisualizerState extends State<TiltVisualizer> {
  final TiltScene _scene = TiltScene();

  @override
  void dispose() {
    _scene.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final TextStyle base = DefaultTextStyle.of(
      context,
    ).style.copyWith(decoration: TextDecoration.none, shadows: null);
    _scene.update(widget.context, base);
    return LyricVisualizerFrame(
      context: widget.context,
      builder: (BuildContext c, LyricVisualizerTicks ticks) => RepaintBoundary(
        child: CustomPaint(
          size: Size.infinite,
          painter: _TiltPainter(
            scene: _scene,
            ticks: ticks,
            input: widget.context,
          ),
        ),
      ),
    );
  }
}

class _TiltPainter extends CustomPainter {
  _TiltPainter({required this.scene, required this.ticks, required this.input})
    : super(repaint: ticks);

  final TiltScene scene;
  final LyricVisualizerTicks ticks;
  final LyricVisualizerContext input;

  @override
  void paint(Canvas canvas, Size size) =>
      scene.paint(canvas, size, ticks.value.timeMs);

  @override
  bool shouldRepaint(covariant _TiltPainter old) =>
      !identical(old.scene, scene) ||
      !identical(old.ticks, ticks) ||
      !identical(old.input, input);
}
