/// 全屏歌词动画样式「镜台」（移植自 folia-major `src/components/visualizer/diorama/`）。
///
/// 歌词是摆在一条蜿蜒走廊里的立体文字，相机沿路径飞行，每句一种运镜（推、拉、环绕、横移、
/// 升降、螺旋……），四周是按运镜生长的点云阵列与背景尘埃；当前行逐字（CJK）/ 逐词显现，
/// 带辉光、灵魂出窍、渐变三种跟唱效果。切歌时新走廊生在雾外，相机一镜到底飞过去。
///
/// three.js 场景在这里是真 3D：Flutter GPU 渲染器（`diorama_gpu.dart`）把文字平面、点云着色器、
/// 尘埃和雾画进离屏纹理，再贴到画面上。拿不到 Flutter GPU 上下文的平台 / 设备退回 Canvas 后备
/// 实现（2.5D：局部仿射文字平面 + CPU 逐点投影），平台边界的说明与清理条件见 `diorama_gpu.dart`。
/// 译文与下一句交给宿主的共享字幕（folia 同样叠 `VisualizerSubtitleOverlay`）。纯观赏，不接手势。
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_frame.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/diorama/diorama_gpu.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/diorama/diorama_render_frame.dart';
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
  /// 判完 Flutter GPU 可用性之前为 null（只在进程里第一次挂载时等一个微任务）。
  DioramaScene? _scene;
  DioramaGpuRenderer? _renderer;

  @override
  void initState() {
    super.initState();
    if (DioramaGpu.resolved) {
      _setup(DioramaGpu.pipelines);
    } else {
      DioramaGpu.load().then((DioramaGpuPipelines? p) {
        if (mounted) setState(() => _setup(p));
      });
    }
  }

  void _setup(DioramaGpuPipelines? pipelines) {
    _renderer = pipelines == null ? null : DioramaGpuRenderer(pipelines);
    _scene = DioramaScene(forGpu: pipelines != null);
  }

  @override
  void dispose() {
    _scene?.dispose();
    _renderer?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final DioramaScene? scene = _scene;
    if (scene == null) return const SizedBox.expand();
    final double dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1;
    scene
      ..pixelRatio = dpr
      ..update(widget.context);
    final DioramaGpuRenderer? renderer = _renderer;
    return LyricVisualizerFrame(
      context: widget.context,
      builder: (BuildContext bc, LyricVisualizerTicks ticks) => RepaintBoundary(
        child: CustomPaint(
          size: Size.infinite,
          painter: renderer == null
              ? _DioramaPainter(scene, ticks, widget.context)
              : _DioramaGpuPainter(scene, renderer, dpr, ticks, widget.context),
        ),
      ),
    );
  }
}

/// Canvas 后备实现。
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

/// Flutter GPU：每帧把场景画进离屏纹理（设备像素），再整张贴上来。
class _DioramaGpuPainter extends CustomPainter {
  _DioramaGpuPainter(
    this.scene,
    this.renderer,
    this.devicePixelRatio,
    this.ticks,
    this.input,
  ) : super(repaint: ticks);

  final DioramaScene scene;
  final DioramaGpuRenderer renderer;
  final double devicePixelRatio;
  final LyricVisualizerTicks ticks;
  final LyricVisualizerContext input;

  /// 离屏目标的最长边（4K 屏的 1:1 以内）。
  static const double _maxSide = 4096;

  @override
  void paint(Canvas canvas, Size size) {
    final DioramaRenderFrame? frame = scene.step(size, ticks.value);
    if (frame == null) return;
    double k = devicePixelRatio;
    final double longest = math.max(size.width, size.height) * k;
    if (longest > _maxSide) k *= _maxSide / longest;
    final int w = math.max(1, (size.width * k).round());
    final int h = math.max(1, (size.height * k).round());
    final ui.Image? image = renderer.render(frame, w, h);
    if (image == null) return;
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
      Offset.zero & size,
      Paint()..filterQuality = FilterQuality.low,
    );
    image.dispose();
  }

  @override
  bool shouldRepaint(covariant _DioramaGpuPainter oldDelegate) =>
      !identical(oldDelegate.scene, scene) ||
      !identical(oldDelegate.renderer, renderer) ||
      oldDelegate.devicePixelRatio != devicePixelRatio ||
      !identical(oldDelegate.ticks, ticks) ||
      !identical(oldDelegate.input, input);
}
