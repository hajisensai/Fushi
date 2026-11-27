/// 全屏歌词动画样式「雾笺」（移植自 folia-major `src/components/visualizer/nebbia/`）。
///
/// 下雨天公交车起雾的车窗上，手指一笔一笔写歌词，写过的地方透出窗外的雨夜街景（或水族箱、
/// 共用背景），擦痕边凝出水珠、偶尔淌下一颗，过一会儿重新起雾；雨点打在玻璃上，两盏聚光灯从
/// 街上追着正在写的字。排版照商籁的主词 / 构图，字的笔画来自字体骨架追踪。
///
/// 文件：`nebbia_tuning.dart`（参数）、`nebbia_chars.dart`（逐字序列、分词、片尾）、
/// `nebbia_layout.dart`（构图与整首排版）、`nebbia_glyphs.dart`（字形 / 骨架追踪）、
/// `nebbia_scene.dart`（书写节奏、起雾、让位、手指抹除、哈气）、`nebbia_window.dart`（窗外）、
/// `nebbia_glass.dart`（玻璃上的水、颠簸、雨点）、`nebbia_painter.dart`（每帧合成）。
library;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/state_resource_scope.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_frame.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/nebbia/nebbia_glyphs.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/nebbia/nebbia_painter.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/nebbia/nebbia_tuning.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

/// 注册项。窗外选「共用背景」时请求用户选的共享背景（擦开处透出它），街景 / 水族箱自己画满全屏、
/// 不要共享背景（folia `nebbiaBackgroundConfig`）；雾笺不画译文，底部字幕交给宿主。
final LyricVisualizerEntry nebbiaVisualizerEntry = LyricVisualizerEntry(
  mode: LyricVisualizerMode.nebbia,
  label: () => t.music_visualizer_mode_nebbia,
  description: () => t.music_visualizer_nebbia_description,
  icon: FushiIcons.blurLinear,
  tunings: nebbiaTuningSpecs,
  background: (LyricVisualizerTuning tuning) =>
      tuning.choice('behind', 'night') == 'backdrop'
      ? LyricVisualizerBackgroundRequest.selected
      : LyricVisualizerBackgroundRequest.none,
  builder: (LyricVisualizerContext c) => NebbiaVisualizer(context: c),
);

class NebbiaVisualizer extends StatefulWidget {
  const NebbiaVisualizer({super.key, required this.context});

  final LyricVisualizerContext context;

  @override
  State<NebbiaVisualizer> createState() => _NebbiaVisualizerState();
}

class _NebbiaVisualizerState extends State<NebbiaVisualizer>
    with StateResourceScope<NebbiaVisualizer> {
  final NebbiaController _controller = NebbiaController();

  @override
  void initState() {
    super.initState();
    listenTo(NebbiaGlyphCache.instance, _onGlyphs);
  }

  /// 骨架追踪好一批：重画（场景按字形版本号自己重排）。
  void _onGlyphs() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final LyricVisualizerContext c = widget.context;
    final NebbiaSettings s = NebbiaSettings.from(c.tuning);
    final TextStyle font = DefaultTextStyle.of(context).style;
    return LyricVisualizerFrame(
      context: c,
      builder: (BuildContext bc, LyricVisualizerTicks ticks) => RepaintBoundary(
        child: CustomPaint(
          size: Size.infinite,
          painter: NebbiaPainter(
            c: c,
            s: s,
            ticks: ticks,
            controller: _controller,
            // 主题字体 / 字重（AI 主题）套到书写的字形上。
            font: TextStyle(
              fontFamily: c.theme?.fontFamily ?? font.fontFamily,
              fontFamilyFallback: font.fontFamilyFallback,
              fontWeight: c.theme?.fontWeight ?? FontWeight.w500,
              locale: font.locale,
            ),
          ),
        ),
      ),
    );
  }
}
