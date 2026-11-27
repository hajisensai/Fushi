/// 全屏歌词动画样式「绘光」（移植自 folia-major `src/components/visualizer/lumiere/`）。
///
/// 一首歌先编成节目单（段落 → 镜头 → 100 个光位里挑一个），每个镜头是一套舞台光：体积光束穿过烟雾与浮尘，
/// 线稿一笔笔画出，歌词在文字区里被光一个字一个字照亮，唱完的行崩解成光尘。译文与下一句交给宿主的共享字幕。
library;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/state_resource_scope.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_frame.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/lumiere/lumiere_audio.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/lumiere/lumiere_glyph_atlas.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/lumiere/lumiere_scene.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

abstract final class LumiereTuningKeys {
  static const String lightIntensity = 'lightIntensity';
  static const String audioResponse = 'audioResponse';
  static const String fogDensity = 'fogDensity';
  static const String darkField = 'darkField';
  static const String moteAmount = 'moteAmount';
  static const String bloom = 'bloom';
  static const String textBloom = 'textBloom';
  static const String unlitOpacity = 'unlitOpacity';
  static const String windowNeighbors = 'windowNeighbors';
  static const String decay = 'decay';
  static const String echo = 'echo';
  static const String fogOctaves = 'fogOctaves';
  static const String lineArt = 'lineArt';
  static const String themeIcons = 'themeIcons';
  static const String frontBokeh = 'frontBokeh';
  static const String trails = 'trails';
  static const String hideTrails = 'hideTrails';
  static const String seamlessTransitions = 'seamlessTransitions';
  static const String overlayFrame = 'overlayFrame';
  static const String textOnly = 'textOnly';
  static const String themeColorMix = 'themeColorMix';
  static const String renderQuality = 'renderQuality';
  static const String keywordColors = 'keywordColors';
}

String _times(double v) => '${v.toStringAsFixed(1)}×';
String _percent(double v) => '${(v * 100).round()}%';

LyricVisualizerSliderSpec _slider(
  String key,
  String Function() label,
  double min,
  double max,
  double initial,
  String Function(double) format,
) => LyricVisualizerSliderSpec(
  key: key,
  label: label,
  min: min,
  max: max,
  initial: initial,
  divisions: ((max - min) * 20).round(),
  format: format,
);

final List<LyricVisualizerTuningSpec> lumiereTunings =
    <LyricVisualizerTuningSpec>[
      _slider(
        LumiereTuningKeys.lightIntensity,
        () => t.music_visualizer_lumiere_light_intensity,
        0.3,
        2,
        1,
        _times,
      ),
      _slider(
        LumiereTuningKeys.audioResponse,
        () => t.music_visualizer_lumiere_audio_response,
        0,
        2,
        1,
        _times,
      ),
      _slider(
        LumiereTuningKeys.fogDensity,
        () => t.music_visualizer_lumiere_fog_density,
        0,
        2,
        1,
        _times,
      ),
      _slider(
        LumiereTuningKeys.darkField,
        () => t.music_visualizer_lumiere_dark_field,
        0,
        1,
        0.75,
        _percent,
      ),
      _slider(
        LumiereTuningKeys.moteAmount,
        () => t.music_visualizer_lumiere_mote_amount,
        0,
        2,
        1,
        _times,
      ),
      _slider(
        LumiereTuningKeys.bloom,
        () => t.music_visualizer_lumiere_bloom,
        0,
        2,
        1,
        _times,
      ),
      _slider(
        LumiereTuningKeys.textBloom,
        () => t.music_visualizer_lumiere_text_bloom,
        0,
        2,
        1,
        _times,
      ),
      _slider(
        LumiereTuningKeys.unlitOpacity,
        () => t.music_visualizer_lumiere_unlit_opacity,
        0.05,
        0.6,
        0.22,
        _percent,
      ),
      LyricVisualizerChoiceSpec(
        key: LumiereTuningKeys.windowNeighbors,
        label: () => t.music_visualizer_lumiere_neighbors,
        options: <(String, String Function())>[
          ('1', () => t.music_visualizer_lumiere_neighbors_one),
          ('2', () => t.music_visualizer_lumiere_neighbors_two),
        ],
        initial: '2',
      ),
      _slider(
        LumiereTuningKeys.decay,
        () => t.music_visualizer_lumiere_decay,
        0,
        2,
        1,
        _times,
      ),
      _slider(
        LumiereTuningKeys.echo,
        () => t.music_visualizer_lumiere_echo,
        0,
        2,
        1,
        _times,
      ),
      LyricVisualizerSliderSpec(
        key: LumiereTuningKeys.fogOctaves,
        label: () => t.music_visualizer_lumiere_fog_octaves,
        min: 2,
        max: 6,
        initial: 5,
        divisions: 4,
        format: (double v) => '${v.round()}',
      ),
      LyricVisualizerToggleSpec(
        key: LumiereTuningKeys.lineArt,
        label: () => t.music_visualizer_lumiere_line_art,
        initial: true,
      ),
      // folia `themeIcons`：AI 主题的图标散落在文字区外，独立于线稿开关。
      LyricVisualizerToggleSpec(
        key: LumiereTuningKeys.themeIcons,
        label: () => t.music_visualizer_lumiere_theme_icons,
        initial: true,
      ),
      LyricVisualizerToggleSpec(
        key: LumiereTuningKeys.frontBokeh,
        label: () => t.music_visualizer_lumiere_front_bokeh,
        initial: true,
      ),
      LyricVisualizerToggleSpec(
        key: LumiereTuningKeys.trails,
        label: () => t.music_visualizer_lumiere_trails,
        initial: true,
      ),
      LyricVisualizerToggleSpec(
        key: LumiereTuningKeys.hideTrails,
        label: () => t.music_visualizer_lumiere_hide_trails,
        initial: false,
      ),
      LyricVisualizerToggleSpec(
        key: LumiereTuningKeys.seamlessTransitions,
        label: () => t.music_visualizer_lumiere_seamless,
        initial: true,
      ),
      LyricVisualizerToggleSpec(
        key: LumiereTuningKeys.overlayFrame,
        label: () => t.music_visualizer_lumiere_overlay_frame,
        initial: true,
      ),
      LyricVisualizerToggleSpec(
        key: LumiereTuningKeys.textOnly,
        label: () => t.music_visualizer_lumiere_text_only,
        initial: false,
      ),
      _slider(
        LumiereTuningKeys.themeColorMix,
        () => t.music_visualizer_lumiere_theme_mix,
        0,
        1,
        0.3,
        _percent,
      ),
      // folia `keywordColors`：AI 主题的关键字在字身、光晕、闪点、爆闪、背景碎片上带色。
      LyricVisualizerToggleSpec(
        key: LumiereTuningKeys.keywordColors,
        label: () => t.music_visualizer_lumiere_keyword_colors,
        initial: true,
      ),
      LyricVisualizerChoiceSpec(
        key: LumiereTuningKeys.renderQuality,
        label: () => t.music_visualizer_lumiere_quality,
        options: <(String, String Function())>[
          ('full', () => t.music_visualizer_lumiere_quality_full),
          ('balanced', () => t.music_visualizer_lumiere_quality_balanced),
          ('low', () => t.music_visualizer_lumiere_quality_low),
        ],
        initial: 'full',
      ),
    ];

/// 调节项 → 每帧设置。
LumiereSettings lumiereSettingsOf(LyricVisualizerTuning tuning) =>
    LumiereSettings(
      lightIntensity: tuning.number(LumiereTuningKeys.lightIntensity, 1),
      audioResponse: tuning.number(LumiereTuningKeys.audioResponse, 1),
      fogDensity: tuning.number(LumiereTuningKeys.fogDensity, 1),
      darkField: tuning.number(LumiereTuningKeys.darkField, 0.75),
      moteAmount: tuning.number(LumiereTuningKeys.moteAmount, 1),
      bloom: tuning.number(LumiereTuningKeys.bloom, 1),
      textBloom: tuning.number(LumiereTuningKeys.textBloom, 1),
      unlitOpacity: tuning.number(LumiereTuningKeys.unlitOpacity, 0.22),
      neighbors: tuning.choice(LumiereTuningKeys.windowNeighbors, '2') == '1'
          ? 1
          : 2,
      decay: tuning.number(LumiereTuningKeys.decay, 1),
      echo: tuning.number(LumiereTuningKeys.echo, 1),
      fogOctaves: tuning
          .number(LumiereTuningKeys.fogOctaves, 5)
          .round()
          .clamp(2, 6),
      lineArt: tuning.flag(LumiereTuningKeys.lineArt, true),
      themeIcons: tuning.flag(LumiereTuningKeys.themeIcons, true),
      frontBokeh: tuning.flag(LumiereTuningKeys.frontBokeh, true),
      trails: tuning.flag(LumiereTuningKeys.trails, true),
      hideTrails: tuning.flag(LumiereTuningKeys.hideTrails, false),
      overlayFrame: tuning.flag(LumiereTuningKeys.overlayFrame, true),
      textOnly: tuning.flag(LumiereTuningKeys.textOnly, false),
      quality: switch (tuning.choice(LumiereTuningKeys.renderQuality, 'full')) {
        'balanced' => LumiereQuality.balanced,
        'low' => LumiereQuality.low,
        _ => LumiereQuality.full,
      },
    );

/// 注册项。
final LyricVisualizerEntry lumiereVisualizerEntry = LyricVisualizerEntry(
  mode: LyricVisualizerMode.lumiere,
  label: () => t.music_visualizer_mode_lumiere,
  description: () => t.music_visualizer_lumiere_description,
  icon: FushiIcons.flash,
  tunings: lumiereTunings,
  // folia 绘光不指定背景：光与雾画在用户选的共享背景上。
  background: (LyricVisualizerTuning _) =>
      LyricVisualizerBackgroundRequest.selected,
  sharedSubtitle: true,
  builder: (LyricVisualizerContext c) => LumiereVisualizer(context: c),
);

class LumiereVisualizer extends StatefulWidget {
  const LumiereVisualizer({super.key, required this.context});

  final LyricVisualizerContext context;

  @override
  State<LumiereVisualizer> createState() => LumiereVisualizerState();
}

class LumiereVisualizerState extends State<LumiereVisualizer>
    with StateResourceScope<LumiereVisualizer> {
  LumiereScene? _scene;
  Object? _sceneKey;
  final LumiereAudioSampler _audio = LumiereAudioSampler();

  @visibleForTesting
  LumiereScene? get debugScene => _scene;

  @override
  void initState() {
    super.initState();
    // 自定义字体是异步注册的：注册表一变（字体加载完）就让图集重画，不停在回落字体上。
    listenTo(PaintingBinding.instance.systemFonts, _onSystemFontsChanged);
  }

  void _onSystemFontsChanged() => _scene?.glyphs.reload();

  /// 场景只随歌词 / 种子 / 标题这些节目单输入重建；字体不在键里，换字体走
  /// [LumiereGlyphs.requestStyle] 在后台重画图集，不重编节目单、不卡 UI 线程。
  LumiereScene _sceneFor(LyricVisualizerContext c, LumiereGlyphStyle style) {
    final bool seamless = c.tuning.flag(
      LumiereTuningKeys.seamlessTransitions,
      true,
    );
    final Object key = Object.hash(
      identityHashCode(c.runtime),
      c.seed,
      seamless,
      c.title,
      c.artist,
      c.album,
    );
    final LumiereScene? existing = _scene;
    if (existing != null && key == _sceneKey) {
      existing.glyphs.requestStyle(style);
      return existing;
    }
    existing?.dispose();
    _sceneKey = key;
    return _scene = LumiereScene(
      runtime: c.runtime,
      seed: 'lumiere:${c.seed}',
      seamless: seamless,
      title: c.title,
      artist: c.artist,
      album: c.album,
      glyphStyle: style,
    );
  }

  @override
  void dispose() {
    _scene?.dispose();
    _scene = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext buildContext) {
    final LyricVisualizerContext c = widget.context;
    final LumiereScene scene = _sceneFor(
      c,
      LumiereGlyphStyle.of(
        c.applyThemeFont(DefaultTextStyle.of(buildContext).style),
      ),
    );
    final double devicePixelRatio = MediaQuery.devicePixelRatioOf(buildContext);
    final LyricVisualizerTheme? theme = c.theme;
    scene.themeIcons = theme?.glyphIcons ?? const <IconData>[];
    final bool keywords =
        theme != null &&
        theme.hasWordColors &&
        c.tuning.flag(LumiereTuningKeys.keywordColors, true);
    final LyricVisualizerPalette p = c.palette;
    final LumierePalette palette = LumierePalette.resolve(
      accent: p.accent,
      primary: p.primary,
      secondary: p.secondary,
      background: p.background,
      themeMix: c.tuning.number(LumiereTuningKeys.themeColorMix, 0.3),
    );
    final double bgLuminance = p.background.computeLuminance();
    return RepaintBoundary(
      child: LyricVisualizerFrame(
        context: c,
        builder: (BuildContext bc, LyricVisualizerTicks ticks) => CustomPaint(
          size: Size.infinite,
          painter: _LumierePainter(
            scene: scene,
            context: c,
            ticks: ticks,
            palette: palette,
            settings: lumiereSettingsOf(c.tuning),
            lightBackground: bgLuminance > 0.18,
            audio: _audio,
            cameraMotion: lumiereCameraMotion(c.intensity),
            keywords: keywords ? theme : null,
            devicePixelRatio: devicePixelRatio,
          ),
        ),
      ),
    );
  }
}

class _LumierePainter extends CustomPainter {
  _LumierePainter({
    required this.scene,
    required this.context,
    required this.ticks,
    required this.palette,
    required this.settings,
    required this.lightBackground,
    required this.audio,
    required this.cameraMotion,
    required this.keywords,
    required this.devicePixelRatio,
  }) : super(
         repaint: Listenable.merge(<Listenable>[ticks, scene.glyphs.changed]),
       );

  final LumiereScene scene;
  final LyricVisualizerContext context;
  final LyricVisualizerTicks ticks;
  final LumierePalette palette;
  final LumiereSettings settings;
  final bool lightBackground;
  final LumiereAudioSampler audio;
  final double cameraMotion;
  final LyricVisualizerTheme? keywords;
  final double devicePixelRatio;

  @override
  void paint(Canvas canvas, Size size) {
    final LyricVisualizerTick tick = ticks.value;
    final bool motion = context.motion;
    // 暂停 / 关动态时整帧归零（folia：场景当作安静）。
    audio.sample(
      motion && context.playing ? context.audioFrameAt(tick.timeMs) : null,
      tick.dt,
    );
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    scene.paint(
      canvas,
      size,
      LumiereFrame(
        time: tick.timeMs / 1000,
        animTime: motion ? tick.elapsed : 0,
        motion: motion,
        bass: audio.bass,
        treble: audio.treble,
        power: audio.power,
        cameraMotion: cameraMotion,
        keywords: keywords,
        palette: palette,
        settings: settings,
        fontScale: context.fontScale,
        lightBackground: lightBackground,
        devicePixelRatio: devicePixelRatio,
      ),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _LumierePainter old) =>
      !identical(old.scene, scene) ||
      !identical(old.context, context) ||
      old.palette != palette ||
      old.settings != settings ||
      old.lightBackground != lightBackground ||
      old.cameraMotion != cameraMotion ||
      old.devicePixelRatio != devicePixelRatio ||
      !identical(old.keywords, keywords);
}
