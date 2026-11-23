/// 全屏歌词动画样式「花火」（移植自 folia-major `src/components/visualizer/hanabi/`）。
///
/// 日系歌词 PV：一首歌先编成节目单（段落 → 镜头 → 50 种镜头配方里挑一个），每个镜头的字带着色块逐字蹦出来，
/// 周围开烟花、贴 MG 装饰件；镜头一个接一个往上走，世界绕画面中心慢慢转，副歌整屏泛光，歌词唱完放片尾卡。
/// 译文与下一句交给宿主的共享字幕。
library;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_frame.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_runtime.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/hanabi/hanabi_beat_fx.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/hanabi/hanabi_color.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/hanabi/hanabi_program.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/hanabi/hanabi_scene.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

abstract final class HanabiTuningKeys {
  static const String colorMode = 'colorMode';
  static const String sparkAmount = 'sparkAmount';
  static const String ornamentAmount = 'ornamentAmount';
  static const String textMotion = 'textMotion';
  static const String blockOpacity = 'blockOpacity';
  static const String riseSpeed = 'riseSpeed';
  static const String spin = 'spin';
  static const String ambient = 'ambient';
  static const String glow = 'glow';
  static const String bloom = 'bloom';
  static const String chorusBloom = 'chorusBloom';
  static const String launches = 'launches';
  static const String overlayFrame = 'overlayFrame';
  static const String textOnly = 'textOnly';
  static const String sky = 'sky';
  static const String collage = 'collage';
  static const String renderQuality = 'renderQuality';
  static const String beatBursts = 'beatBursts';
  static const String beatPulse = 'beatPulse';
}

String _times(double v) => '${v.toStringAsFixed(1)}×';
String _percent(double v) => '${(v * 100).round()}%';

LyricVisualizerSliderSpec _slider(
  String key,
  String Function() label,
  double max,
  double initial, [
  String Function(double) format = _times,
]) => LyricVisualizerSliderSpec(
  key: key,
  label: label,
  min: 0,
  max: max,
  initial: initial,
  divisions: (max * 20).round(),
  format: format,
);

final List<LyricVisualizerTuningSpec>
hanabiTunings = <LyricVisualizerTuningSpec>[
  LyricVisualizerChoiceSpec(
    key: HanabiTuningKeys.colorMode,
    label: () => t.music_visualizer_hanabi_color_mode,
    options: <(String, String Function())>[
      ('mixed', () => t.music_visualizer_hanabi_color_mode_mixed),
      ('vivid', () => t.music_visualizer_hanabi_color_mode_vivid),
      ('theme', () => t.music_visualizer_hanabi_color_mode_theme),
    ],
    initial: 'mixed',
  ),
  _slider(
    HanabiTuningKeys.sparkAmount,
    () => t.music_visualizer_hanabi_spark_amount,
    2,
    1,
  ),
  _slider(
    HanabiTuningKeys.ornamentAmount,
    () => t.music_visualizer_hanabi_ornament_amount,
    2,
    1,
  ),
  _slider(
    HanabiTuningKeys.textMotion,
    () => t.music_visualizer_hanabi_text_motion,
    2,
    1,
  ),
  _slider(
    HanabiTuningKeys.blockOpacity,
    () => t.music_visualizer_hanabi_block_opacity,
    1,
    1,
    _percent,
  ),
  _slider(
    HanabiTuningKeys.riseSpeed,
    () => t.music_visualizer_hanabi_rise_speed,
    2,
    1,
  ),
  _slider(HanabiTuningKeys.spin, () => t.music_visualizer_hanabi_spin, 2, 1),
  _slider(
    HanabiTuningKeys.ambient,
    () => t.music_visualizer_hanabi_ambient,
    2,
    1,
  ),
  _slider(HanabiTuningKeys.glow, () => t.music_visualizer_hanabi_glow, 2, 1),
  _slider(
    HanabiTuningKeys.bloom,
    () => t.music_visualizer_hanabi_bloom,
    2,
    0.8,
  ),
  _slider(
    HanabiTuningKeys.chorusBloom,
    () => t.music_visualizer_hanabi_chorus_bloom,
    2,
    1.3,
  ),
  LyricVisualizerToggleSpec(
    key: HanabiTuningKeys.launches,
    label: () => t.music_visualizer_hanabi_launches,
    initial: true,
  ),
  LyricVisualizerToggleSpec(
    key: HanabiTuningKeys.overlayFrame,
    label: () => t.music_visualizer_hanabi_overlay_frame,
    initial: true,
  ),
  LyricVisualizerToggleSpec(
    key: HanabiTuningKeys.textOnly,
    label: () => t.music_visualizer_hanabi_text_only,
    initial: false,
  ),
  _slider(
    HanabiTuningKeys.sky,
    () => t.music_visualizer_hanabi_sky,
    1,
    0.85,
    _percent,
  ),
  _slider(
    HanabiTuningKeys.collage,
    () => t.music_visualizer_hanabi_collage,
    2,
    1,
  ),
  // folia 智能动感模式的两个效果（强度在 folia 是全局设置，这里收成本样式的两项；0 = 关）。
  _slider(
    HanabiTuningKeys.beatBursts,
    () => t.music_visualizer_hanabi_beat_bursts,
    2,
    1,
  ),
  _slider(
    HanabiTuningKeys.beatPulse,
    () => t.music_visualizer_hanabi_beat_pulse,
    2,
    1,
  ),
  LyricVisualizerChoiceSpec(
    key: HanabiTuningKeys.renderQuality,
    label: () => t.music_visualizer_hanabi_render_quality,
    options: <(String, String Function())>[
      ('full', () => t.music_visualizer_hanabi_render_quality_full),
      ('balanced', () => t.music_visualizer_hanabi_render_quality_balanced),
      ('low', () => t.music_visualizer_hanabi_render_quality_low),
    ],
    initial: 'full',
  ),
];

/// 调节项 → 每帧设置。
HanabiSettings hanabiSettingsOf(LyricVisualizerTuning tuning) => HanabiSettings(
  colorMode: switch (tuning.choice(HanabiTuningKeys.colorMode, 'mixed')) {
    'vivid' => HanabiColorMode.vivid,
    'theme' => HanabiColorMode.theme,
    _ => HanabiColorMode.mixed,
  },
  sparkAmount: tuning.number(HanabiTuningKeys.sparkAmount, 1),
  ornamentAmount: tuning.number(HanabiTuningKeys.ornamentAmount, 1),
  textMotion: tuning.number(HanabiTuningKeys.textMotion, 1),
  blockOpacity: tuning.number(HanabiTuningKeys.blockOpacity, 1),
  riseSpeed: tuning.number(HanabiTuningKeys.riseSpeed, 1),
  spin: tuning.number(HanabiTuningKeys.spin, 1),
  ambient: tuning.number(HanabiTuningKeys.ambient, 1),
  glow: tuning.number(HanabiTuningKeys.glow, 1),
  bloom: tuning.number(HanabiTuningKeys.bloom, 0.8),
  chorusBloom: tuning.number(HanabiTuningKeys.chorusBloom, 1.3),
  launches: tuning.flag(HanabiTuningKeys.launches, true),
  overlayFrame: tuning.flag(HanabiTuningKeys.overlayFrame, true),
  textOnly: tuning.flag(HanabiTuningKeys.textOnly, false),
  sky: tuning.number(HanabiTuningKeys.sky, 0.85),
  collage: tuning.number(HanabiTuningKeys.collage, 1),
  quality: switch (tuning.choice(HanabiTuningKeys.renderQuality, 'full')) {
    'balanced' => HanabiQuality.balanced,
    'low' => HanabiQuality.low,
    _ => HanabiQuality.full,
  },
);

/// 运行时歌词 → 花火节目单。
HanabiProgram compileHanabiProgramFor(
  LyricVisualizerRuntime runtime,
  String seed,
  double durationSeconds,
) {
  final List<HanabiLine> lines = <HanabiLine>[
    for (final LyricVisualizerLine l in runtime.lines) ?hanabiLineOf(l),
  ];
  return compileHanabiProgram(lines, seed, duration: durationSeconds);
}

/// 关键字色（folia `keywordColorOf`）：主题 wordColors 里的词，整词命中或包含关键字（不分大小写）就用它的颜色
/// （RGB）；没有关键字返回 null。
int? Function(String text)? hanabiKeywordColorOf(LyricVisualizerTheme? theme) {
  if (theme == null || !theme.hasWordColors) return null;
  final List<(String, int)> entries = <(String, int)>[
    for (final MapEntry<String, Color> e in theme.wordColors.entries)
      if (e.key.trim().isNotEmpty)
        (e.key.trim().toLowerCase(), e.value.toARGB32() & 0xFFFFFF),
  ];
  if (entries.isEmpty) return null;
  return (String text) {
    final String key = text.trim().toLowerCase();
    if (key.isEmpty) return null;
    for (final (String word, int color) in entries) {
      if (key == word || key.contains(word)) return color;
    }
    return null;
  };
}

/// 注册项。
final LyricVisualizerEntry hanabiVisualizerEntry = LyricVisualizerEntry(
  mode: LyricVisualizerMode.hanabi,
  label: () => t.music_visualizer_mode_hanabi,
  description: () => t.music_visualizer_hanabi_description,
  icon: FushiIcons.celebration,
  tunings: hanabiTunings,
  // folia 花火没有指定背景：画在用户选的共享背景上（自己的夜空按「夜空」参数盖一层）。
  background: (LyricVisualizerTuning _) =>
      LyricVisualizerBackgroundRequest.selected,
  sharedSubtitle: true,
  builder: (LyricVisualizerContext c) => HanabiVisualizer(context: c),
);

class HanabiVisualizer extends StatefulWidget {
  const HanabiVisualizer({super.key, required this.context});

  final LyricVisualizerContext context;

  @override
  State<HanabiVisualizer> createState() => _HanabiVisualizerState();
}

class _HanabiVisualizerState extends State<HanabiVisualizer> {
  HanabiScene? _scene;
  Object? _sceneKey;
  List<HanabiBeatEvent> _beats = const <HanabiBeatEvent>[];
  Object? _beatsKey;

  /// 节拍表（分析就绪 / 换歌 / 改偏移时重算）。
  List<HanabiBeatEvent> _beatsFor(LyricVisualizerContext c) {
    final LyricVisualizerBeats key = LyricVisualizerBeats.of(c);
    if (!identical(key, _beatsKey)) {
      _beatsKey = key;
      _beats = hanabiBeatEventsOf(c);
    }
    return _beats;
  }

  HanabiScene _sceneFor(LyricVisualizerContext c) {
    final int durationMs = c.clock.duration.inMilliseconds;
    final Object key = Object.hash(
      identityHashCode(c.runtime),
      c.seed,
      durationMs,
      c.title,
      c.artist,
      c.album,
    );
    final HanabiScene? existing = _scene;
    if (existing != null && key == _sceneKey) return existing;
    existing?.dispose();
    _sceneKey = key;
    final String seed = 'hanabi:${c.seed}';
    return _scene = HanabiScene(
      program: compileHanabiProgramFor(c.runtime, seed, durationMs / 1000),
      seed: seed,
      title: c.title,
      artist: c.artist,
      album: c.album,
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
    final HanabiScene scene = _sceneFor(c);
    final LyricVisualizerPalette p = c.palette;
    final HanabiTheme theme = HanabiTheme(
      primary: p.primary.toARGB32() & 0xFFFFFF,
      accent: p.accent.toARGB32() & 0xFFFFFF,
      secondary: p.secondary.toARGB32() & 0xFFFFFF,
      background: p.background.toARGB32() & 0xFFFFFF,
    );
    final TextStyle inherited = DefaultTextStyle.of(buildContext).style;
    final TextStyle baseStyle = c.applyThemeFont(
      TextStyle(
        fontFamily: inherited.fontFamily,
        fontFamilyFallback: inherited.fontFamilyFallback,
      ),
    );
    return RepaintBoundary(
      child: LyricVisualizerFrame(
        context: c,
        builder: (BuildContext bc, LyricVisualizerTicks ticks) => CustomPaint(
          size: Size.infinite,
          painter: _HanabiPainter(
            scene: scene,
            context: c,
            ticks: ticks,
            theme: theme,
            settings: hanabiSettingsOf(c.tuning),
            baseStyle: baseStyle,
            beats: _beatsFor(c),
            keywordColor: hanabiKeywordColorOf(c.theme),
          ),
        ),
      ),
    );
  }
}

class _HanabiPainter extends CustomPainter {
  _HanabiPainter({
    required this.scene,
    required this.context,
    required this.ticks,
    required this.theme,
    required this.settings,
    required this.baseStyle,
    required this.beats,
    required this.keywordColor,
  }) : super(repaint: ticks);

  final HanabiScene scene;
  final LyricVisualizerContext context;
  final LyricVisualizerTicks ticks;
  final HanabiTheme theme;
  final HanabiSettings settings;
  final TextStyle baseStyle;
  final List<HanabiBeatEvent> beats;
  final int? Function(String text)? keywordColor;

  @override
  void paint(Canvas canvas, Size size) {
    final LyricVisualizerTick tick = ticks.value;
    final LyricVisualizerTuning tuning = context.tuning;
    final bool beatOn = context.motion && !settings.textOnly;
    final ({double scale, double rotation}) pulse = beatOn
        ? hanabiBeatPulseAt(
            context,
            tick.timeMs,
            tuning.number(HanabiTuningKeys.beatPulse, 1),
          )
        : (scale: 1.0, rotation: 0.0);
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    scene.paint(
      canvas,
      size,
      HanabiFrame(
        time: tick.timeMs / 1000,
        motion: context.motion,
        theme: theme,
        settings: settings,
        fontScale: context.fontScale,
        baseStyle: baseStyle,
        intensityMotion: context.intensity.pick(0.6, 1, 1.4),
        keywordColor: keywordColor,
        keywordKey: context.theme == null
            ? null
            : Object.hashAll(
                context.theme!.wordColors.entries.map(
                  (MapEntry<String, Color> e) => Object.hash(e.key, e.value),
                ),
              ),
        beatEvents: beats,
        beatBursts: tuning.number(HanabiTuningKeys.beatBursts, 1),
        pulseScale: pulse.scale,
        pulseRotation: pulse.rotation,
      ),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _HanabiPainter old) =>
      !identical(old.scene, scene) ||
      !identical(old.context, context) ||
      old.theme.primary != theme.primary ||
      old.theme.accent != theme.accent ||
      old.theme.secondary != theme.secondary ||
      old.theme.background != theme.background ||
      old.settings != settings ||
      old.baseStyle != baseStyle ||
      !identical(old.beats, beats);
}
