/// 全屏歌词动画样式「町景」（移植自 folia-major `src/components/visualizer/machi/`）。
///
/// 程序化生成的日本街角微缩模型（约 12m×12m 底座，正交斜俯视），歌词是场景里的招牌和屏幕：
/// 当前行在 LED 屏上逐字点亮，下一句在跑马灯 / 出租车顶灯 / 全息投影上滚，曲名、歌手写在店招
/// 上。三个场景（便利店街角、加油站停车场、城寨酒吧），时间与天气（都可以“自动”）渐变，
/// 雨夜湿路面映灯、副歌开头打雷；可选运镜、景深与移轴。folia 用 three.js；这里用 Canvas 的
/// 正交投影 + 仿射贴花复刻（`machi_render.dart`），天空自己画，不挂共享背景。纯展示，不接手势。
library;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_frame.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/machi/machi_runtime.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/machi/machi_tuning.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

/// 注册项。
final LyricVisualizerEntry machiVisualizerEntry = LyricVisualizerEntry(
  mode: LyricVisualizerMode.machi,
  label: () => t.music_visualizer_mode_machi,
  description: () => t.music_visualizer_machi_description,
  icon: FushiIcons.home,
  tunings: machiTuningSpecs,
  // 天空自己画（folia `background: false`）：不要共享背景。
  background: (LyricVisualizerTuning _) =>
      LyricVisualizerBackgroundRequest.none,
  // 底部字幕照常（folia 里通用字号只影响底部字幕，场景里的字按屏幕大小排）。
  sharedSubtitle: true,
  builder: (LyricVisualizerContext c) => MachiVisualizer(context: c),
);

/// 町景样式本体。
class MachiVisualizer extends StatefulWidget {
  const MachiVisualizer({super.key, required this.context});

  final LyricVisualizerContext context;

  @override
  State<MachiVisualizer> createState() => _MachiVisualizerState();
}

class _MachiVisualizerState extends State<MachiVisualizer> {
  final MachiRuntime _runtime = MachiRuntime();

  @override
  void dispose() {
    _runtime.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _runtime.configure(widget.context, DefaultTextStyle.of(context).style);
    return LyricVisualizerFrame(
      context: widget.context,
      builder: (BuildContext c, LyricVisualizerTicks ticks) => RepaintBoundary(
        child: CustomPaint(
          size: Size.infinite,
          painter: _MachiPainter(
            ticks: ticks,
            runtime: _runtime,
            input: widget.context,
          ),
        ),
      ),
    );
  }
}

class _MachiPainter extends CustomPainter {
  _MachiPainter({
    required this.ticks,
    required this.runtime,
    required this.input,
  }) : super(repaint: ticks);

  final LyricVisualizerTicks ticks;
  final MachiRuntime runtime;
  final LyricVisualizerContext input;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    runtime.step(ticks.value, size);
    runtime.paint(canvas, size);
  }

  @override
  bool shouldRepaint(covariant _MachiPainter oldDelegate) =>
      !identical(oldDelegate.input, input) || oldDelegate.runtime != runtime;
}
