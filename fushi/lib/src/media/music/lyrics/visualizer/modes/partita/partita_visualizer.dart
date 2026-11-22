/// 全屏歌词动画样式「云阶」（移植自 folia-major `src/components/visualizer/partita/`）。
///
/// 一句歌词先切成若干 layout unit（CJK 语义分组 + 标点粘滞），再按可用高度切成不均匀的
/// chunk，每个 chunk 是一级「台阶」：左右交替错位、沿引导线滑入；chunk 里的词逐个
/// 放大、变色、发光，唱完后缓慢转一点角度留下余影。整句进出场带缩放与模糊，歌词区缓慢漂浮。
///
/// 文件分工（对照 folia）：
/// - `partita_layout.dart` ← `partitaLayout.ts` / `partitaOverlap.ts` / `cjkSemanticLayout.ts`
/// - `partita_timing.dart` ← `glowWordTiming.ts` / `renderHints.ts`
/// - `partita_line_cache.dart` ← 布局缓存与预热
/// - `partita_painter.dart` ← `VisualizerPartita.tsx` / `PartitaChunk.tsx` / `GlowWord.tsx`
library;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_frame.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/partita/partita_layout.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/partita/partita_line_cache.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/partita/partita_painter.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

String _px(double v) => '${v.round()} px';

/// 参数（folia `tuning.ts` 的五项 + 主题里的动画强度）。
final List<LyricVisualizerTuningSpec> partitaTuningSpecs =
    <LyricVisualizerTuningSpec>[
      LyricVisualizerToggleSpec(
        key: PartitaTuningKeys.showGuideLines,
        label: () => t.music_visualizer_partita_guide_lines,
        initial: true,
      ),
      LyricVisualizerToggleSpec(
        key: PartitaTuningKeys.useSemanticLayout,
        label: () => t.music_visualizer_partita_semantic_layout,
        initial: true,
      ),
      const LyricVisualizerSliderSpec(
        key: PartitaTuningKeys.staggerMin,
        label: _staggerMinLabel,
        min: 0,
        max: 180,
        initial: 20,
        divisions: 180,
        format: _px,
      ),
      const LyricVisualizerSliderSpec(
        key: PartitaTuningKeys.staggerMax,
        label: _staggerMaxLabel,
        min: 0,
        max: 180,
        initial: 100,
        divisions: 180,
        format: _px,
      ),
      LyricVisualizerToggleSpec(
        key: PartitaTuningKeys.avoidOverlap,
        label: () => t.music_visualizer_partita_avoid_overlap,
        initial: false,
      ),
      LyricVisualizerChoiceSpec(
        key: PartitaTuningKeys.intensity,
        label: () => t.music_visualizer_partita_intensity,
        options: <(String, String Function())>[
          (
            PartitaIntensity.calm.key,
            () => t.music_visualizer_partita_intensity_calm,
          ),
          (
            PartitaIntensity.normal.key,
            () => t.music_visualizer_partita_intensity_normal,
          ),
          (
            PartitaIntensity.chaotic.key,
            () => t.music_visualizer_partita_intensity_chaotic,
          ),
        ],
        initial: PartitaIntensity.normal.key,
      ),
    ];

String _staggerMinLabel() => t.music_visualizer_partita_stagger_min;
String _staggerMaxLabel() => t.music_visualizer_partita_stagger_max;

/// 注册项。
final LyricVisualizerEntry partitaVisualizerEntry = LyricVisualizerEntry(
  mode: LyricVisualizerMode.partita,
  label: () => t.music_visualizer_mode_partita,
  description: () => t.music_visualizer_partita_description,
  icon: FushiIcons.sort,
  tunings: partitaTuningSpecs,
  // folia 的云阶用共享背景 + 底部译文 / 下一句字幕（VisualizerShell + SubtitleOverlay）。
  sharedBackdrop: true,
  sharedSubtitle: true,
  builder: (LyricVisualizerContext c) => PartitaVisualizer(context: c),
);

/// 云阶本体：一个 CustomPaint，逐帧由 [LyricVisualizerFrame] 的 ticks 驱动重绘。
class PartitaVisualizer extends StatefulWidget {
  const PartitaVisualizer({super.key, required this.context});

  final LyricVisualizerContext context;

  @override
  State<PartitaVisualizer> createState() => _PartitaVisualizerState();
}

class _PartitaVisualizerState extends State<PartitaVisualizer> {
  final PartitaLineCache _cache = PartitaLineCache();

  @override
  void dispose() {
    _cache.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final LyricVisualizerContext c = widget.context;
    // 换了一首（新的运行时）就丢掉旧句子的排版。
    _cache.bindTo(c.runtime);
    final TextStyle style = DefaultTextStyle.of(
      context,
    ).style.copyWith(decoration: TextDecoration.none);
    return LyricVisualizerFrame(
      context: c,
      builder: (BuildContext _, LyricVisualizerTicks ticks) => CustomPaint(
        size: Size.infinite,
        isComplex: true,
        willChange: true,
        painter: PartitaPainter(
          ticks: ticks,
          visualizer: c,
          cache: _cache,
          textStyle: style,
        ),
      ),
    );
  }
}
