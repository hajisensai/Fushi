/// 全屏歌词动画样式「镜台」（移植自 folia-major `src/components/visualizer/diorama/`）。
///
/// 歌词是摆在一条蜿蜒走廊里的立体文字，相机沿路径飞行，每句一种运镜（推、拉、环绕、横移、
/// 升降、螺旋……），四周是按运镜生长的点云阵列与背景尘埃；当前行逐字（CJK）/ 逐词显现，
/// 带辉光、灵魂出窍、渐变三种跟唱效果。切歌时新走廊生在雾外，相机一镜到底飞过去。
///
/// three.js 场景在这里是 2.5D：自带的四元数相机做透视投影，文字平面按局部仿射画到 Canvas，
/// 点云在 CPU 上逐点算位移后用 `drawRawAtlas` 一次画完。译文与下一句交给宿主的共享字幕（folia
/// 同样叠 `VisualizerSubtitleOverlay`）。纯观赏，不接手势。
library;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_frame.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/diorama/diorama_scene.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/diorama/diorama_tuning.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

/// 注册项。
final LyricVisualizerEntry dioramaVisualizerEntry = LyricVisualizerEntry(
  mode: LyricVisualizerMode.diorama,
  label: () => t.music_visualizer_mode_diorama,
  description: () => t.music_visualizer_diorama_description,
  icon: FushiIcons.viewColumn,
  tunings: dioramaTuningSpecs,
  sharedBackdrop: true,
  sharedSubtitle: true,
  builder: (LyricVisualizerContext c) => DioramaVisualizer(context: c),
);

class DioramaVisualizer extends StatefulWidget {
  const DioramaVisualizer({super.key, required this.context});

  final LyricVisualizerContext context;

  @override
  State<DioramaVisualizer> createState() => _DioramaVisualizerState();
}

class _DioramaVisualizerState extends State<DioramaVisualizer> {
  final DioramaScene _scene = DioramaScene();

  @override
  void dispose() {
    _scene.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _scene
      ..pixelRatio = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1
      ..update(widget.context);
    return LyricVisualizerFrame(
      context: widget.context,
      builder: (BuildContext bc, LyricVisualizerTicks ticks) => RepaintBoundary(
        child: CustomPaint(
          size: Size.infinite,
          painter: _DioramaPainter(_scene, ticks, widget.context),
        ),
      ),
    );
  }
}

class _DioramaPainter extends CustomPainter {
  _DioramaPainter(this.scene, this.ticks, this.input) : super(repaint: ticks);

  final DioramaScene scene;
  final LyricVisualizerTicks ticks;

  /// 输入变了（换歌 / 改参数）也要重画，哪怕时钟没动。
  final LyricVisualizerContext input;

  @override
  void paint(Canvas canvas, Size size) =>
      scene.paint(canvas, size, ticks.value);

  @override
  bool shouldRepaint(covariant _DioramaPainter oldDelegate) =>
      !identical(oldDelegate.scene, scene) ||
      !identical(oldDelegate.ticks, ticks) ||
      !identical(oldDelegate.input, input);
}
