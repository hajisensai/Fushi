/// 全屏歌词动画样式「隐喻」（移植自 folia-major `src/components/visualizer/metaphor/`）。
///
/// 概念化的实验动画：歌词和它周围的装饰都是不定形的墨——融球和字形画进同一个墨场再切阈值，
/// 所以它们会融在一起又分开；墨场经流场推歪、半调网点和砂纸颗粒显影出来。画面靠剪辑动，不靠补间：
/// 按歌编好的分镜表在唱到的词上硬切机位（全景、特写、跟字、大特写、倾斜、留白远景、拉远、冲镜），
/// 机位永远正对画面；墨不往下滴，墨球像加速器里的束流那样对撞、碎片沿螺旋轨迹甩出去。
/// 画面完全由播放时间决定（不积分），拖进度、暂停都对。
///
/// 文件分工（对应 folia）：`metaphor_program`（分镜表）、`metaphor_layout`（排版）、
/// `metaphor_camera`（机位）、`metaphor_shapes`（融球 / 对撞）、`metaphor_figures`（线稿与版面）、
/// `metaphor_glyphs`（字形图集）、`metaphor_palette`（配色）、`metaphor_textures`（固定贴图）、
/// `metaphor_scene`（每个 cue 的那套东西）、`metaphor_painter`（墨场与显影）。
library;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_frame.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/metaphor/metaphor_painter.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/metaphor/metaphor_scene.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/metaphor/metaphor_tuning.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

/// 注册项。画面自己铺纸（不要共用背景）；译文 / 下一句交给宿主的共享字幕（folia 也是底部字幕层）。
final LyricVisualizerEntry metaphorVisualizerEntry = LyricVisualizerEntry(
  mode: LyricVisualizerMode.metaphor,
  label: () => t.music_visualizer_mode_metaphor,
  description: () => t.music_visualizer_metaphor_description,
  icon: FushiIcons.ambientMotion,
  tunings: metaphorTuningSpecs,
  sharedBackdrop: false,
  builder: (LyricVisualizerContext c) => MetaphorVisualizer(context: c),
);

class MetaphorVisualizer extends StatefulWidget {
  const MetaphorVisualizer({super.key, required this.context});

  final LyricVisualizerContext context;

  @override
  State<MetaphorVisualizer> createState() => _MetaphorVisualizerState();
}

class _MetaphorVisualizerState extends State<MetaphorVisualizer> {
  late final MetaphorScene _scene = MetaphorScene(widget.context);
  late final MetaphorRenderer _renderer = MetaphorRenderer(_scene);
  _TimeOnly? _time;

  @override
  void didUpdateWidget(covariant MetaphorVisualizer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.context, widget.context)) {
      _scene.update(widget.context);
    }
  }

  @override
  void dispose() {
    _time?.dispose();
    _renderer.dispose();
    _scene.dispose();
    super.dispose();
  }

  /// 只在歌词时间变了时重画：暂停时 Ticker 还在走墙钟，画面却完全由播放时间决定。
  _TimeOnly _timeFor(LyricVisualizerTicks ticks) {
    final _TimeOnly? current = _time;
    if (current != null && identical(current.source, ticks)) return current;
    current?.dispose();
    return _time = _TimeOnly(ticks);
  }

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: LyricVisualizerFrame(
      context: widget.context,
      builder: (BuildContext bc, LyricVisualizerTicks ticks) => CustomPaint(
        size: Size.infinite,
        painter: MetaphorPainter(
          renderer: _renderer,
          ticks: _timeFor(ticks),
          context: widget.context,
        ),
      ),
    ),
  );
}

/// [LyricVisualizerTicks] 的过滤：只有 timeMs 变了才通知。
class _TimeOnly extends ChangeNotifier
    implements ValueListenable<LyricVisualizerTick> {
  _TimeOnly(this.source) : _last = source.value.timeMs {
    source.addListener(_onTick);
  }

  final LyricVisualizerTicks source;
  int _last;

  void _onTick() {
    final int now = source.value.timeMs;
    if (now == _last) return;
    _last = now;
    notifyListeners();
  }

  @override
  LyricVisualizerTick get value => source.value;

  @override
  void dispose() {
    source.removeListener(_onTick);
    super.dispose();
  }
}
