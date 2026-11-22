/// 全屏歌词动画样式「商籁」（移植自 folia-major `src/components/visualizer/sonnet/`）。
///
/// 一位确定性的「日式 MG 歌词 PV 导演」：歌词按停顿切段、段再切成 ≤4 行的镜头，每个镜头按
/// 种子挑一种构图（编辑栏、字效冲击、碎片拼贴、追踪丝带、遮罩揭示、海报块、静物），主角词
/// 加粗放大、陪衬词细排、超大描边字做装饰；逐字 ExpoOut 入场，镜头推拉跟焦并手持呼吸，
/// 段间做模糊 / 故障条 / 推拉转场，MG 线框与粒子按镜头生长；末句后歌词失焦、片尾海报升起。
library;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_frame.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_runtime.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/sonnet/sonnet_beat_fx.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/sonnet/sonnet_painter.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/sonnet/sonnet_program.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/sonnet/sonnet_scene.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

/// 参数（folia `SonnetTuning` 中在 Fushi 有意义的部分；键名沿用 folia 字段名）。
final List<LyricVisualizerTuningSpec> sonnetTuningSpecs =
    <LyricVisualizerTuningSpec>[
      LyricVisualizerSliderSpec(
        key: 'cameraIntensity',
        label: () => t.music_visualizer_sonnet_camera_intensity,
        min: 0,
        max: 2,
        initial: 1,
      ),
      LyricVisualizerSliderSpec(
        key: 'typographyMotion',
        label: () => t.music_visualizer_sonnet_typography_motion,
        min: 0,
        max: 2,
        initial: 1,
      ),
      LyricVisualizerSliderSpec(
        key: 'mgDensity',
        label: () => t.music_visualizer_sonnet_mg_density,
        min: 0,
        max: 2,
        initial: 1,
      ),
      LyricVisualizerToggleSpec(
        key: 'showOnlyText',
        label: () => t.music_visualizer_sonnet_show_only_text,
        initial: false,
      ),
      LyricVisualizerToggleSpec(
        key: 'showGuide',
        label: () => t.music_visualizer_sonnet_show_guide,
        initial: true,
      ),
      LyricVisualizerToggleSpec(
        key: 'showBackgroundMg',
        label: () => t.music_visualizer_sonnet_show_background_mg,
        initial: true,
      ),
      LyricVisualizerToggleSpec(
        key: 'showFixedGeo',
        label: () => t.music_visualizer_sonnet_show_fixed_geo,
        initial: true,
      ),
      LyricVisualizerToggleSpec(
        key: 'showGiantDecorativeText',
        label: () => t.music_visualizer_sonnet_show_giant_decorative_text,
        initial: true,
      ),
      LyricVisualizerToggleSpec(
        key: 'showBackgroundDecor',
        label: () => t.music_visualizer_sonnet_show_background_decor,
        initial: true,
      ),
      LyricVisualizerToggleSpec(
        key: 'enableTransitions',
        label: () => t.music_visualizer_sonnet_enable_transitions,
        initial: true,
      ),
      LyricVisualizerChoiceSpec(
        key: 'outerFrameMode',
        label: () => t.music_visualizer_sonnet_outer_frame_mode,
        options: <(String, String Function())>[
          ('none', () => t.music_visualizer_sonnet_outer_frame_none),
          ('frame', () => t.music_visualizer_sonnet_outer_frame_frame),
          ('full', () => t.music_visualizer_sonnet_outer_frame_full),
        ],
        initial: 'full',
      ),
      LyricVisualizerToggleSpec(
        key: 'postProcessEnabled',
        label: () => t.music_visualizer_sonnet_post_process_enabled,
        initial: false,
      ),
      LyricVisualizerSliderSpec(
        key: 'postProcessGrain',
        label: () => t.music_visualizer_sonnet_post_process_grain,
        min: 0,
        max: 1,
        initial: 0.2,
      ),
      LyricVisualizerSliderSpec(
        key: 'postProcessContrast',
        label: () => t.music_visualizer_sonnet_post_process_contrast,
        min: 0,
        max: 1,
        initial: 0,
      ),
      LyricVisualizerSliderSpec(
        key: 'postProcessRgbShift',
        label: () => t.music_visualizer_sonnet_post_process_rgb_shift,
        min: 0,
        max: 1,
        initial: 0,
      ),
      LyricVisualizerSliderSpec(
        key: 'postProcessHalftone',
        label: () => t.music_visualizer_sonnet_post_process_halftone,
        min: 0,
        max: 1,
        initial: 0,
      ),
      LyricVisualizerSliderSpec(
        key: 'postProcessVignette',
        label: () => t.music_visualizer_sonnet_post_process_vignette,
        min: 0,
        max: 2,
        initial: 0.85,
      ),
      LyricVisualizerSliderSpec(
        key: 'postProcessLensDistortion',
        label: () => t.music_visualizer_sonnet_post_process_lens_distortion,
        min: 0,
        max: 2,
        initial: 0.3,
      ),
      LyricVisualizerSliderSpec(
        key: 'postProcessLensDispersion',
        label: () => t.music_visualizer_sonnet_post_process_lens_dispersion,
        min: 0,
        max: 1,
        initial: 0.6,
      ),
    ];

/// 从参数表读出生效设置。
SonnetSettings sonnetSettingsOf(LyricVisualizerTuning u) => SonnetSettings(
  cameraIntensity: u.number('cameraIntensity', 1),
  typographyMotion: u.number('typographyMotion', 1),
  mgDensity: u.number('mgDensity', 1),
  showOnlyText: u.flag('showOnlyText', false),
  showGuide: u.flag('showGuide', true),
  showBackgroundMg: u.flag('showBackgroundMg', true),
  showFixedGeo: u.flag('showFixedGeo', true),
  showGiantDecorativeText: u.flag('showGiantDecorativeText', true),
  showBackgroundDecor: u.flag('showBackgroundDecor', true),
  enableTransitions: u.flag('enableTransitions', true),
  outerFrameMode: u.choice('outerFrameMode', 'full'),
  postProcessEnabled: u.flag('postProcessEnabled', false),
  postProcessGrain: u.number('postProcessGrain', 0.2),
  postProcessContrast: u.number('postProcessContrast', 0),
  postProcessRgbShift: u.number('postProcessRgbShift', 0),
  postProcessHalftone: u.number('postProcessHalftone', 0),
  postProcessVignette: u.number('postProcessVignette', 0.85),
  postProcessLensDistortion: u.number('postProcessLensDistortion', 0.3),
  postProcessLensDispersion: u.number('postProcessLensDispersion', 0.6),
);

/// 注册项。
final LyricVisualizerEntry sonnetVisualizerEntry = LyricVisualizerEntry(
  mode: LyricVisualizerMode.sonnet,
  label: () => t.music_visualizer_mode_sonnet,
  description: () => t.music_visualizer_sonnet_description,
  icon: FushiIcons.quote,
  tunings: sonnetTuningSpecs,
  // folia 商籁不指定背景：画在用户选的共享背景上。
  background: (LyricVisualizerTuning _) =>
      LyricVisualizerBackgroundRequest.selected,
  sharedSubtitle: true,
  builder: (LyricVisualizerContext c) => SonnetVisualizer(context: c),
);

/// 商籁样式本体。纯展示，不接手势（点按退出归宿主）。
class SonnetVisualizer extends StatefulWidget {
  const SonnetVisualizer({super.key, required this.context});

  final LyricVisualizerContext context;

  @override
  State<SonnetVisualizer> createState() => _SonnetVisualizerState();
}

class _SonnetVisualizerState extends State<SonnetVisualizer> {
  SonnetDirector? _director;
  LyricVisualizerRuntime? _runtime;
  int? _seed;
  String? _meta;
  final SonnetBeatFxReader _beatReader = SonnetBeatFxReader();

  @override
  void initState() {
    super.initState();
    ensureSonnetPostProgram();
  }

  SonnetDirector _directorFor(LyricVisualizerContext c) {
    final String meta =
        '${c.title}\u0000${c.artist}\u0000${c.album}\u0000'
        '${c.theme?.fontFamily}\u0000${c.theme?.fontWeight}';
    final SonnetDirector? current = _director;
    if (current != null &&
        identical(_runtime, c.runtime) &&
        _seed == c.seed &&
        _meta == meta) {
      return current;
    }
    current?.dispose();
    _runtime = c.runtime;
    _seed = c.seed;
    _meta = meta;
    return _director = SonnetDirector(
      runtime: c.runtime,
      program: compileSonnetProgram(
        sonnetSourceLinesOf(c.runtime),
        '${c.seed}',
      ),
      title: c.title,
      artist: c.artist,
      album: c.album,
      fontFamily: c.theme?.fontFamily,
      fontWeight: c.theme?.fontWeight,
    );
  }

  @override
  void dispose() {
    _director?.dispose();
    _director = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final LyricVisualizerContext c = widget.context;
    final SonnetDirector director = _directorFor(c);
    final SonnetSettings settings = sonnetSettingsOf(c.tuning);
    final SonnetColors colors = SonnetColors(
      primary: c.palette.text,
      secondary: c.palette.secondary,
      accent: c.palette.accent,
      background: c.palette.background,
      keywords: <String, Color>{
        for (final MapEntry<String, Color> e
            in (c.theme?.wordColors ?? const <String, Color>{}).entries)
          e.key.toLowerCase(): e.value,
      },
    );
    final double dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1;
    return LyricVisualizerFrame(
      context: c,
      builder: (BuildContext _, LyricVisualizerTicks ticks) => RepaintBoundary(
        child: CustomPaint(
          size: Size.infinite,
          painter: SonnetPainter(
            director: director,
            ticks: ticks,
            settings: settings,
            colors: colors,
            fontScale: c.fontScale,
            motion: c.motion,
            devicePixelRatio: dpr,
            visualizer: c,
            beatReader: _beatReader,
            animationScale: sonnetAnimationScale(c.intensity),
          ),
        ),
      ),
    );
  }
}
