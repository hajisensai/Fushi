/// 全屏歌词动画样式「凝彩」（移植自 folia-major `src/components/visualizer/tempera/`）。
///
/// 一段歌词是一个场景，每半句一个分镜：121 种由大色块、网点、细线拼成的构图（分割 / 色带 /
/// 框窗 / 海报 / 稀疏 / 遮幅 / 圆滑 / 镂空 / 仪表 / 通道 / 巨构 / 地形 / 物语过场卡）沿 flow
/// 方向推来推去，字逐个飞入落位；压在色块上的字按底色翻成 ink / paper 中对比更大的那个。
/// 段落之间用整块擦除、镜头平移、形状带走三种转场；最后一段唱完后换成片尾海报。
/// 译文 / 下一句交给宿主的共享字幕。用户自定义的图层图片不移植，图层只用封面。
library;

import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_frame.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_runtime.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/tempera/tempera_palette.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/tempera/tempera_program.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/tempera/tempera_scene.dart';
import 'package:fushi/src/pages/implementations/music/music_lyrics_backdrop.dart'
    show musicLyricsBackdropCoverProvider;
import 'package:fushi/src/utils/fushi_icons.dart';

/// 参数键（落库，冻结；与 folia `TemperaTuning` 同名，封面图层是本移植新增）。
const String kTemperaCameraIntensity = 'cameraIntensity';
const String kTemperaGlyphMotion = 'glyphMotion';
const String kTemperaWholeLine = 'wholeLineLyrics';
const String kTemperaSettleStretch = 'glyphSettleStretch';
const String kTemperaColorMode = 'colorMode';
const String kTemperaShowBlocks = 'showBlocks';
const String kTemperaShowDecor = 'showDecor';
const String kTemperaCornerMarks = 'showCornerMarks';
const String kTemperaTextInversion = 'textInversion';
const String kTemperaTransitions = 'enableTransitions';
const String kTemperaCoverLayer = 'coverLayer';
const String kTemperaLayerFrequency = 'layerImageFrequency';
const String kTemperaLayerDepth = 'layerImageDepth';
const String kTemperaLayerScale = 'layerImageScale';
const String kTemperaLayerOpacity = 'layerImageOpacity';
const String kTemperaDepth = 'depth';
const String kTemperaDepthOfField = 'depthOfField';
const String kTemperaDepthPan = 'depthPan';
const String kTemperaGlyphDepth = 'glyphDepth';
const String kTemperaPostProcess = 'postProcessEnabled';
const String kTemperaGrain = 'postProcessGrain';
const String kTemperaContrast = 'postProcessContrast';
const String kTemperaVignette = 'postProcessVignette';

/// 可调参数（folia `tuning.ts`；镜头畸变、RGB 偏移、贴图分辨率不移植）。
final List<LyricVisualizerTuningSpec> temperaTunings =
    <LyricVisualizerTuningSpec>[
      LyricVisualizerSliderSpec(
        key: kTemperaCameraIntensity,
        label: () => t.music_visualizer_tempera_camera_intensity,
        min: 0,
        max: 2,
        initial: 1,
      ),
      LyricVisualizerSliderSpec(
        key: kTemperaGlyphMotion,
        label: () => t.music_visualizer_tempera_glyph_motion,
        min: 0,
        max: 2,
        initial: 1,
      ),
      LyricVisualizerToggleSpec(
        key: kTemperaWholeLine,
        label: () => t.music_visualizer_tempera_whole_line,
        initial: false,
      ),
      LyricVisualizerSliderSpec(
        key: kTemperaSettleStretch,
        label: () => t.music_visualizer_tempera_settle_stretch,
        min: 0,
        max: 1,
        initial: 0.5,
      ),
      LyricVisualizerChoiceSpec(
        key: kTemperaColorMode,
        label: () => t.music_visualizer_tempera_color_mode,
        options: <(String, String Function())>[
          ('duo', () => t.music_visualizer_tempera_color_duo),
          ('mono', () => t.music_visualizer_tempera_color_mono),
          ('gradient', () => t.music_visualizer_tempera_color_gradient),
        ],
        initial: 'duo',
      ),
      LyricVisualizerToggleSpec(
        key: kTemperaShowBlocks,
        label: () => t.music_visualizer_tempera_show_blocks,
        initial: true,
      ),
      LyricVisualizerToggleSpec(
        key: kTemperaShowDecor,
        label: () => t.music_visualizer_tempera_show_decor,
        initial: true,
      ),
      LyricVisualizerToggleSpec(
        key: kTemperaCornerMarks,
        label: () => t.music_visualizer_tempera_corner_marks,
        initial: true,
      ),
      LyricVisualizerToggleSpec(
        key: kTemperaTextInversion,
        label: () => t.music_visualizer_tempera_text_inversion,
        initial: true,
      ),
      LyricVisualizerToggleSpec(
        key: kTemperaTransitions,
        label: () => t.music_visualizer_tempera_transitions,
        initial: true,
      ),
      LyricVisualizerToggleSpec(
        key: kTemperaCoverLayer,
        label: () => t.music_visualizer_tempera_cover_layer,
        initial: false,
      ),
      LyricVisualizerSliderSpec(
        key: kTemperaLayerFrequency,
        label: () => t.music_visualizer_tempera_layer_frequency,
        min: 0,
        max: 1,
        initial: 0.6,
      ),
      LyricVisualizerChoiceSpec(
        key: kTemperaLayerDepth,
        label: () => t.music_visualizer_tempera_layer_depth,
        options: <(String, String Function())>[
          ('back', () => t.music_visualizer_tempera_layer_back),
          ('front', () => t.music_visualizer_tempera_layer_front),
        ],
        initial: 'back',
      ),
      LyricVisualizerSliderSpec(
        key: kTemperaLayerScale,
        label: () => t.music_visualizer_tempera_layer_scale,
        min: 0.1,
        max: 1.5,
        initial: 0.7,
      ),
      LyricVisualizerSliderSpec(
        key: kTemperaLayerOpacity,
        label: () => t.music_visualizer_tempera_layer_opacity,
        min: 0,
        max: 1,
        initial: 1,
      ),
      LyricVisualizerToggleSpec(
        key: kTemperaDepth,
        label: () => t.music_visualizer_tempera_depth,
        initial: false,
      ),
      LyricVisualizerSliderSpec(
        key: kTemperaDepthOfField,
        label: () => t.music_visualizer_tempera_depth_of_field,
        min: 0,
        max: 2,
        initial: 1,
      ),
      LyricVisualizerSliderSpec(
        key: kTemperaDepthPan,
        label: () => t.music_visualizer_tempera_depth_pan,
        min: 0,
        max: 2,
        initial: 1,
      ),
      LyricVisualizerSliderSpec(
        key: kTemperaGlyphDepth,
        label: () => t.music_visualizer_tempera_glyph_depth,
        min: 0,
        max: 2,
        initial: 1,
      ),
      LyricVisualizerToggleSpec(
        key: kTemperaPostProcess,
        label: () => t.music_visualizer_tempera_post_process,
        initial: true,
      ),
      LyricVisualizerSliderSpec(
        key: kTemperaGrain,
        label: () => t.music_visualizer_tempera_grain,
        min: 0,
        max: 1,
        initial: 0.2,
      ),
      LyricVisualizerSliderSpec(
        key: kTemperaContrast,
        label: () => t.music_visualizer_tempera_contrast,
        min: 0,
        max: 1,
        initial: 0,
      ),
      LyricVisualizerSliderSpec(
        key: kTemperaVignette,
        label: () => t.music_visualizer_tempera_vignette,
        min: 0,
        max: 2,
        initial: 0.85,
      ),
    ];

/// 注册项。
final LyricVisualizerEntry temperaVisualizerEntry = LyricVisualizerEntry(
  mode: LyricVisualizerMode.tempera,
  label: () => t.music_visualizer_mode_tempera,
  description: () => t.music_visualizer_tempera_description,
  icon: FushiIcons.formatShapes,
  tunings: temperaTunings,
  sharedBackdrop: true,
  sharedSubtitle: true,
  builder: (LyricVisualizerContext c) => TemperaVisualizer(context: c),
);

/// 从参数读出设置。
TemperaSettings temperaSettingsOf(LyricVisualizerTuning tuning) {
  const TemperaSettings d = TemperaSettings();
  final String mode = tuning.choice(kTemperaColorMode, 'duo');
  return TemperaSettings(
    cameraIntensity: tuning.number(kTemperaCameraIntensity, d.cameraIntensity),
    glyphMotion: tuning.number(kTemperaGlyphMotion, d.glyphMotion),
    wholeLine: tuning.flag(kTemperaWholeLine, d.wholeLine),
    settleStretch: tuning.number(kTemperaSettleStretch, d.settleStretch),
    colorMode: TemperaColorMode.values.firstWhere(
      (TemperaColorMode m) => m.name == mode,
      orElse: () => TemperaColorMode.duo,
    ),
    showBlocks: tuning.flag(kTemperaShowBlocks, d.showBlocks),
    showDecor: tuning.flag(kTemperaShowDecor, d.showDecor),
    cornerMarks: tuning.flag(kTemperaCornerMarks, d.cornerMarks),
    textInversion: tuning.flag(kTemperaTextInversion, d.textInversion),
    transitions: tuning.flag(kTemperaTransitions, d.transitions),
    coverLayer: tuning.flag(kTemperaCoverLayer, d.coverLayer),
    layerFrequency: tuning.number(kTemperaLayerFrequency, d.layerFrequency),
    layerFront: tuning.choice(kTemperaLayerDepth, 'back') == 'front',
    layerScale: tuning.number(kTemperaLayerScale, d.layerScale),
    layerOpacity: tuning.number(kTemperaLayerOpacity, d.layerOpacity),
    depth: tuning.flag(kTemperaDepth, d.depth),
    depthOfField: tuning.number(kTemperaDepthOfField, d.depthOfField),
    depthPan: tuning.number(kTemperaDepthPan, d.depthPan),
    glyphDepth: tuning.number(kTemperaGlyphDepth, d.glyphDepth),
    postProcess: tuning.flag(kTemperaPostProcess, d.postProcess),
    grain: tuning.number(kTemperaGrain, d.grain),
    contrast: tuning.number(kTemperaContrast, d.contrast),
    vignette: tuning.number(kTemperaVignette, d.vignette),
  );
}

/// 封面取色（gradient 模式用）：粗量化成 512 桶，按像素数取最多 4 个彼此拉得开的颜色。
List<Color> temperaCoverColors(Uint8List rgba, int width, int height) {
  if (width <= 0 || height <= 0 || rgba.length < width * height * 4) {
    return const <Color>[];
  }
  final int total = width * height;
  final int stride = total > 4096 ? (total / 4096).ceil() : 1;
  final Map<int, List<int>> buckets = <int, List<int>>{};
  for (int i = 0; i < total; i += stride) {
    final int o = i * 4;
    if (rgba[o + 3] < 128) continue;
    final int r = rgba[o], g = rgba[o + 1], b = rgba[o + 2];
    final int key = (r >> 5) << 6 | (g >> 5) << 3 | (b >> 5);
    final List<int> acc = buckets.putIfAbsent(key, () => <int>[0, 0, 0, 0]);
    acc[0] += r;
    acc[1] += g;
    acc[2] += b;
    acc[3] += 1;
  }
  final List<List<int>> ranked = buckets.values.toList()
    ..sort((List<int> a, List<int> b) => b[3].compareTo(a[3]));
  final List<Color> out = <Color>[];
  for (final List<int> acc in ranked) {
    final Color c = Color.fromARGB(
      255,
      acc[0] ~/ acc[3],
      acc[1] ~/ acc[3],
      acc[2] ~/ acc[3],
    );
    final bool distinct = out.every((Color o) {
      final double dr = (o.r - c.r) * 255,
          dg = (o.g - c.g) * 255,
          db = (o.b - c.b) * 255;
      return dr * dr + dg * dg + db * db > 48 * 48;
    });
    if (distinct) out.add(c);
    if (out.length == 4) break;
  }
  return out;
}

/// 凝彩样式本体：纯展示，不接手势（点按退出由宿主处理）。
class TemperaVisualizer extends StatefulWidget {
  const TemperaVisualizer({super.key, required this.context});

  final LyricVisualizerContext context;

  @override
  State<TemperaVisualizer> createState() => _TemperaVisualizerState();
}

class _TemperaVisualizerState extends State<TemperaVisualizer> {
  late TemperaEngine _engine;
  int _revision = 0;

  LyricVisualizerRuntime? _programFor;
  bool? _programWholeLine;
  TemperaProgram? _program;
  Object? _paletteKey;
  TemperaPalette? _palette;

  ImageStream? _coverStream;
  ImageStreamListener? _coverListener;
  ImageInfo? _coverInfo;
  String? _coverPath;
  List<Color> _coverColors = const <Color>[];
  int _coverToken = 0;

  @override
  void initState() {
    super.initState();
    _engine = TemperaEngine(_buildConfig());
    _loadCover();
  }

  @override
  void didUpdateWidget(covariant TemperaVisualizer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.context.coverPath != _coverPath) _loadCover();
    _engine.config = _buildConfig();
    _revision++;
  }

  @override
  void dispose() {
    _detachCover();
    _coverInfo?.dispose();
    _engine.dispose();
    super.dispose();
  }

  TemperaSceneConfig _buildConfig() {
    final LyricVisualizerContext c = widget.context;
    final TemperaSettings settings = temperaSettingsOf(c.tuning);
    final String programSeed = '${c.seed}';
    if (!identical(_programFor, c.runtime) ||
        _programWholeLine != settings.wholeLine) {
      _programFor = c.runtime;
      _programWholeLine = settings.wholeLine;
      _program = compileTemperaProgram(
        c.runtime.lines,
        seed: programSeed,
        wholeLineLyrics: settings.wholeLine,
      );
    }
    final Object key = (c.palette, settings.colorMode, _coverColors);
    if (key != _paletteKey) {
      _paletteKey = key;
      _palette = resolveTemperaPalette(
        background: c.palette.background,
        primary: c.palette.text,
        secondary: c.palette.secondary,
        accent: c.palette.accent,
        mode: settings.colorMode,
        coverColors: _coverColors,
      );
    }
    return TemperaSceneConfig(
      program: _program!,
      programSeed: programSeed,
      palette: _palette!,
      settings: settings,
      motion: c.motion,
      fontScale: c.fontScale,
      cornerColor: c.palette.text,
      cover: _coverInfo?.image,
      title: c.title,
      artist: c.artist,
      album: c.album,
    );
  }

  void _detachCover() {
    final ImageStreamListener? l = _coverListener;
    if (l != null) _coverStream?.removeListener(l);
    _coverStream = null;
    _coverListener = null;
  }

  void _loadCover() {
    _coverPath = widget.context.coverPath;
    _detachCover();
    _coverInfo?.dispose();
    _coverInfo = null;
    _coverColors = const <Color>[];
    _coverToken++;
    final ImageProvider? provider = musicLyricsBackdropCoverProvider(
      _coverPath,
    );
    if (provider == null) return;
    final ImageStream stream = provider.resolve(ImageConfiguration.empty);
    final ImageStreamListener listener = ImageStreamListener(
      (ImageInfo info, bool _) {
        if (!mounted) {
          info.dispose();
          return;
        }
        _coverInfo?.dispose();
        _coverInfo = info;
        _refresh();
        unawaited(_extractColors(info.image.clone(), _coverToken));
      },
      onError: (Object _, StackTrace? _) {
        // 封面读不出来就只用主题色，不报错。
      },
    );
    _coverStream = stream;
    _coverListener = listener;
    stream.addListener(listener);
  }

  Future<void> _extractColors(ui.Image image, int token) async {
    try {
      final ByteData? data = await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      );
      if (!mounted || token != _coverToken || data == null) return;
      _coverColors = temperaCoverColors(
        data.buffer.asUint8List(),
        image.width,
        image.height,
      );
      _refresh();
    } finally {
      image.dispose();
    }
  }

  void _refresh() {
    if (!mounted) return;
    setState(() {
      _engine.config = _buildConfig();
      _revision++;
    });
  }

  @override
  Widget build(BuildContext context) => LyricVisualizerFrame(
    context: widget.context,
    builder: (BuildContext bc, LyricVisualizerTicks ticks) => RepaintBoundary(
      child: CustomPaint(
        size: Size.infinite,
        painter: _TemperaPainter(
          engine: _engine,
          ticks: ticks,
          revision: _revision,
        ),
      ),
    ),
  );
}

class _TemperaPainter extends CustomPainter {
  _TemperaPainter({
    required this.engine,
    required this.ticks,
    required this.revision,
  }) : super(repaint: ticks);

  final TemperaEngine engine;
  final LyricVisualizerTicks ticks;
  final int revision;

  @override
  void paint(Canvas canvas, Size size) {
    final LyricVisualizerTick tick = ticks.value;
    engine.paint(canvas, size, tick.timeMs / 1000, tick.elapsed);
  }

  @override
  bool shouldRepaint(covariant _TemperaPainter oldDelegate) =>
      oldDelegate.revision != revision ||
      !identical(oldDelegate.engine, engine);
}
