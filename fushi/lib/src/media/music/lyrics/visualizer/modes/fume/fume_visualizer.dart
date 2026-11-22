/// 全屏歌词动画样式「浮名」（移植自 folia-major `src/components/visualizer/fume/`）。
///
/// 整首歌词先排成一张多栏「报纸」（几句挑作大标题），镜头在纸上追着正在唱的字移动：换句时
/// 近处直飞、远处经全景方向拉高再落下；字逐个「打印」上纸（落下的发光方块 + 颜色拖尾），
/// 唱过的字按停留比例淡去；最后一句唱到一半时拉成全景。纸外围散落着随节拍呼吸的几何物体。
///
/// 文件分工（对照 folia）：排版 `fume_article_layout.dart`、时序 `fume_timeline.dart`、
/// 镜头 `fume_camera.dart`、世界背景 `fume_background.dart`、逐帧绘制 `fume_stage.dart`。
library;

import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_frame.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_runtime.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/fume/fume_article_layout.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/fume/fume_background.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/fume/fume_camera.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/fume/fume_stage.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/fume/fume_timeline.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

/// 参数 key（落库，冻结；与 folia `FumeTuning` 字段同名）。
abstract final class FumeTuningKeys {
  static const String hidePrintSymbols = 'hidePrintSymbols';
  static const String backgroundObjectOpacity = 'backgroundObjectOpacity';
  static const String textHoldRatio = 'textHoldRatio';
  static const String cameraTrackingMode = 'cameraTrackingMode';
  static const String cameraSpeed = 'cameraSpeed';
  static const String glowIntensity = 'glowIntensity';
  static const String heroScale = 'heroScale';
}

/// folia `DEFAULT_FUME_TUNING` 与 `tuning.ts` 的取值范围。
final List<LyricVisualizerTuningSpec> fumeTunings = <LyricVisualizerTuningSpec>[
  LyricVisualizerToggleSpec(
    key: FumeTuningKeys.hidePrintSymbols,
    label: () => t.music_visualizer_fume_hide_print_symbols,
    initial: false,
  ),
  LyricVisualizerSliderSpec(
    key: FumeTuningKeys.backgroundObjectOpacity,
    label: () => t.music_visualizer_fume_background_object_opacity,
    min: 0,
    max: 1,
    initial: 0.5,
  ),
  LyricVisualizerSliderSpec(
    key: FumeTuningKeys.textHoldRatio,
    label: () => t.music_visualizer_fume_text_hold_ratio,
    min: 0,
    max: 1,
    initial: 1,
  ),
  LyricVisualizerChoiceSpec(
    key: FumeTuningKeys.cameraTrackingMode,
    label: () => t.music_visualizer_fume_camera_tracking,
    options: <(String, String Function())>[
      ('stepped', () => t.music_visualizer_fume_camera_tracking_stepped),
      ('smooth', () => t.music_visualizer_fume_camera_tracking_smooth),
    ],
    initial: 'smooth',
  ),
  LyricVisualizerSliderSpec(
    key: FumeTuningKeys.cameraSpeed,
    label: () => t.music_visualizer_fume_camera_speed,
    min: 0.55,
    max: 1.85,
    initial: 1,
  ),
  LyricVisualizerSliderSpec(
    key: FumeTuningKeys.glowIntensity,
    label: () => t.music_visualizer_fume_glow_intensity,
    min: 0,
    max: 1.8,
    initial: 1,
  ),
  LyricVisualizerSliderSpec(
    key: FumeTuningKeys.heroScale,
    label: () => t.music_visualizer_fume_hero_scale,
    min: 0.82,
    max: 1.32,
    initial: 1,
  ),
];

/// 注册项。folia 的浮名下面铺用户选的共享背景（自己的几何物体另画），底部字幕也用共享的。
final LyricVisualizerEntry fumeVisualizerEntry = LyricVisualizerEntry(
  mode: LyricVisualizerMode.fume,
  label: () => t.music_visualizer_mode_fume,
  description: () => t.music_visualizer_fume_description,
  icon: FushiIcons.blur,
  tunings: fumeTunings,
  background: (LyricVisualizerTuning _) =>
      LyricVisualizerBackgroundRequest.selected,
  sharedSubtitle: true,
  builder: (LyricVisualizerContext c) => FumeVisualizer(context: c),
);

/// 运行时的行 → 浮名的行（按运行时实例缓存）。
List<FumeLine> fumeLinesOf(LyricVisualizerRuntime runtime) => <FumeLine>[
  for (int i = 0; i < runtime.lines.length; i++)
    fumeLineFrom(runtime.lines[i], i),
];

/// 全曲末尾拉全景的时刻：最后一句唱到一半。
double fumeOverviewStartTime(List<FumeLine> lines) {
  for (int i = lines.length - 1; i >= 0; i--) {
    final FumeLine l = lines[i];
    if (l.text.trim().isEmpty) continue;
    return l.start + math.max(l.renderEnd - l.start, 0) * 0.5;
  }
  return double.infinity;
}

class FumeVisualizer extends StatefulWidget {
  const FumeVisualizer({super.key, required this.context});

  final LyricVisualizerContext context;

  @override
  State<FumeVisualizer> createState() => _FumeVisualizerState();
}

class _FumeVisualizerState extends State<FumeVisualizer> {
  final FumeStage _stage = FumeStage();
  LyricVisualizerRuntime? _linesFor;
  List<FumeLine> _lines = const <FumeLine>[];
  FumeScene? _scene;
  Object? _sceneKey;

  @override
  void dispose() {
    _stage.dispose();
    super.dispose();
  }

  FumeScene _sceneFor(Size size) {
    final LyricVisualizerContext c = widget.context;
    if (!identical(_linesFor, c.runtime)) {
      _linesFor = c.runtime;
      _lines = fumeLinesOf(c.runtime);
    }
    final Object key = (
      c.runtime,
      size,
      c.fontScale,
      c.tuning,
      c.palette,
      c.motion,
      c.seed,
      c.theme,
      c.intensity,
      c.audio,
      c.offsetMs,
    );
    final FumeScene? cached = _scene;
    if (cached != null && _sceneKey == key) return cached;

    final LyricVisualizerTuning tu = c.tuning;
    final double heroScale = tu.number(FumeTuningKeys.heroScale, 1);
    final double hold = tu.number(FumeTuningKeys.textHoldRatio, 1);
    final String seedKey = 'fume:${c.seed}';
    final FumeFont font = FumeFont(
      weight: c.theme?.fontWeight,
      family: c.theme?.fontFamily,
    );
    final FumeArticle? article = FumeArticleCache.resolve(
      FumeArticleCache.keyOf(
        lines: _lines,
        viewport: size,
        fontScale: c.fontScale,
        heroScale: heroScale,
        seedKey: seedKey,
        textScale: 1,
        font: font,
      ),
      () => buildFumeArticle(
        lines: _lines,
        viewport: size,
        measurer: FumeTextPainterMeasurer(font: font),
        fontScale: c.fontScale,
        heroScale: heroScale,
        seedKey: seedKey,
      ),
    );
    final FumeScene scene = FumeScene(
      runtime: c.runtime,
      lines: _lines,
      article: article,
      viewport: size,
      background: buildFumeBackgroundScene(
        viewport: size,
        world: article == null
            ? Size(size.width * 1.8, size.height * 1.8)
            : Size(article.width, article.height),
        paperBounds: article?.paperBounds,
        seed: seedKey,
      ),
      overview: article == null
          ? null
          : fumeArticleOverviewCamera(article, size),
      overviewStartTime: fumeOverviewStartTime(_lines),
      passedFadeDuration: fumePassedFadeDuration(_lines, hold),
      text: c.palette.text,
      secondary: c.palette.secondary,
      accent: c.palette.accent,
      cameraSpeed: tu.number(FumeTuningKeys.cameraSpeed, 1),
      tracking:
          tu.choice(FumeTuningKeys.cameraTrackingMode, 'smooth') == 'stepped'
          ? FumeTrackingMode.stepped
          : FumeTrackingMode.smooth,
      glowIntensity: tu.number(FumeTuningKeys.glowIntensity, 1),
      backgroundObjectOpacity: tu.number(
        FumeTuningKeys.backgroundObjectOpacity,
        0.5,
      ),
      showPrintStamp: !tu.flag(FumeTuningKeys.hidePrintSymbols, false),
      textHoldRatio: hold,
      motion: c.motion,
      font: font,
      theme: c.theme,
      intensity: c.intensity,
      audioAt: c.audioFrameAt,
    );
    _stage.attach(scene);
    _scene = scene;
    _sceneKey = key;
    return scene;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext bc, BoxConstraints box) {
        final Size size = box.biggest;
        if (!size.isFinite || size.isEmpty) return const SizedBox.expand();
        final FumeScene scene = _sceneFor(size);
        return LyricVisualizerFrame(
          context: widget.context,
          builder: (BuildContext fc, LyricVisualizerTicks ticks) =>
              RepaintBoundary(
                child: CustomPaint(
                  size: size,
                  painter: FumePainter(
                    stage: _stage,
                    scene: scene,
                    ticks: ticks,
                  ),
                ),
              ),
        );
      },
    );
  }
}
