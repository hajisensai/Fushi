/// 绘光的场景：按节目单取当前镜头的光位，把体积光（烟雾网格 + 逐束光网格）、眩光、焦散 / 干涉、线稿、
/// 星空与光雨、浮尘、背景歌词、歌词窗口、十字爆闪、前景散景、画框与片尾卡画到一张画布上。
/// folia 用 Pixi + 片元着色器逐像素算光场；这里在 CPU 上按网格顶点算同一个光场公式，用 drawVertices 插值，
/// 小精灵（光点、星芒、散景、光丝）与字形都拼成图集用 drawRawAtlas 一次画完。
library;

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_runtime.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_theme.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/lumiere/lumiere_catalog.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/lumiere/lumiere_glyph_atlas.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/lumiere/lumiere_line_art.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/lumiere/lumiere_math.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/lumiere/lumiere_profile.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/lumiere/lumiere_program.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/lumiere/lumiere_rig.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/lumiere/lumiere_text.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/lumiere/lumiere_theme_icons.dart';

// ---------------------------------------------------------------------------
// 调色
// ---------------------------------------------------------------------------

const Rgb _unlitCool = Rgb(0.62, 0.68, 0.8);

/// 主题色换算成光色：按最亮的通道拉满（太暗的颜色退回香槟金）。
Rgb _glowOf(Rgb c) {
  final double p = c.peak;
  return p < 0.04 ? kChampagne : c.scale(1 / p);
}

class LumierePalette {
  const LumierePalette({
    required this.light,
    required this.lit,
    required this.unlit,
    required this.field,
  });

  /// folia `resolveLumierePalette`：themeMix 为主题色占比。
  factory LumierePalette.resolve({
    required Color accent,
    required Color primary,
    required Color secondary,
    required Color background,
    required double themeMix,
  }) {
    final double mix = clamp01(themeMix);
    Rgb light = kChampagne
        .mix(Rgb.of(accent), 0.18)
        .mix(_glowOf(Rgb.of(accent)), mix);
    light = light.scale(1 / math.max(light.peak, 1e-3));
    final Rgb warmLit = light.mix(kWhite, 0.2);
    final Rgb lit = warmLit.mix(_glowOf(Rgb.of(primary)).mix(kWhite, 0.2), mix);
    final Rgb unlit = light
        .mix(_unlitCool, 0.55)
        .mix(_glowOf(Rgb.of(secondary)).mix(_unlitCool, 0.35), mix);
    return LumierePalette(
      light: light,
      lit: lit,
      unlit: unlit,
      field: Rgb.of(background),
    );
  }

  final Rgb light;
  final Rgb lit;
  final Rgb unlit;
  final Rgb field;
}

// ---------------------------------------------------------------------------
// 每帧参数
// ---------------------------------------------------------------------------

enum LumiereQuality { full, balanced, low }

class LumiereSettings {
  const LumiereSettings({
    this.lightIntensity = 1,
    this.audioResponse = 1,
    this.fogDensity = 1,
    this.darkField = 0.75,
    this.moteAmount = 1,
    this.bloom = 1,
    this.textBloom = 1,
    this.unlitOpacity = 0.22,
    this.neighbors = 2,
    this.decay = 1,
    this.echo = 1,
    this.fogOctaves = 5,
    this.lineArt = true,
    this.themeIcons = true,
    this.frontBokeh = true,
    this.trails = true,
    this.hideTrails = false,
    this.overlayFrame = true,
    this.textOnly = false,
    this.quality = LumiereQuality.full,
  });
  final double lightIntensity;
  final double audioResponse;
  final double fogDensity;
  final double darkField;
  final double moteAmount;
  final double bloom;
  final double textBloom;
  final double unlitOpacity;
  final int neighbors;
  final double decay;
  final double echo;
  final int fogOctaves;
  final bool lineArt;

  /// 主题图标（folia `themeIcons`，独立于线稿开关；只画文字时不画）。
  final bool themeIcons;
  final bool frontBokeh;
  final bool trails;
  final bool hideTrails;
  final bool overlayFrame;
  final bool textOnly;
  final LumiereQuality quality;
}

class LumiereFrame {
  const LumiereFrame({
    required this.time,
    required this.animTime,
    required this.motion,
    required this.palette,
    required this.settings,
    required this.fontScale,
    required this.lightBackground,
    this.bass = 0,
    this.treble = 0,
    this.power = 0,
    this.cameraMotion = 1,
    this.keywords,
    this.devicePixelRatio = 1,
  });

  /// 物理像素 / 逻辑像素：字形图集按物理字号选档。
  final double devicePixelRatio;

  /// 歌曲时间（秒）。
  final double time;

  /// 动画时间（秒）：开着动态效果时随墙钟走，关掉时为 0（静止画面）。
  final double animTime;
  final bool motion;

  /// 平滑后的音频（0..1，见 `LumiereAudioSampler`）：低频推光束、响度抬烟雾、高频点亮浮尘。
  final double bass;
  final double treble;
  final double power;

  /// 主题强度对运镜浮动的倍数（0.6 / 1 / 1.4）。
  final double cameraMotion;

  /// 按词着色的主题；null = 不着色（没有主题或关了「关键字着色」）。
  final LyricVisualizerTheme? keywords;
  final LumierePalette palette;
  final LumiereSettings settings;
  final double fontScale;
  final bool lightBackground;
}

// ---------------------------------------------------------------------------
// 关键字着色（folia `text/keywordColors.ts`）
// ---------------------------------------------------------------------------

/// 各处关键字色的占比（其余是光色）：字身、光晕、闪点、十字爆闪、背景碎片。
abstract final class LumiereKeywordMix {
  static const double glyph = 0.6;
  static const double halo = 0.75;
  static const double star = 0.55;
  static const double burst = 0.7;
  static const double echo = 0.3;
}

/// 闪点在关键字光色之上再掺多少白（普通字是 0.5）。
const double kLumiereKeywordStarWhite = 0.35;

/// 关键字的光晕比普通字亮一点，颜色才看得出来。
const double kLumiereKeywordHaloGain = 1.25;

/// 关键字色与光色按 [amount] 混合，最亮通道拉回光色的亮度：只取关键字的色相与饱和度，深色关键字
/// 照样能在光里读出颜色（folia `keywordLight`）。
Rgb lumiereKeywordLight(Rgb light, Rgb keyword, double amount) {
  final double kp = keyword.peak;
  final Rgb hue = kp > 1e-4 ? keyword.scale(1 / kp) : kWhite;
  final Rgb mixed = light.mix(hue, amount);
  final double peak = mixed.peak;
  return peak > 1e-4 ? mixed.scale(light.peak / peak) : light;
}

Rgb _tint(Rgb light, Rgb? keyword, double amount) =>
    keyword == null ? light : lumiereKeywordLight(light, keyword, amount);

/// 十字爆闪落在关键字上：以关键字光色为主，保留一点光位的 tint（folia `keywordBurstColor`）。
Rgb _burstColor(Rgb burst, Rgb light, Rgb? keyword) => keyword == null
    ? burst
    : burst.mix(
        lumiereKeywordLight(light, keyword, LumiereKeywordMix.burst),
        0.8,
      );

/// 一行逐字（[glyphs] 为字形文本，按 UTF-16 长度累计偏移）的关键字色；不是关键字为 null。
List<Rgb?> lumiereGlyphKeywordColors(
  List<String> glyphs,
  List<LyricVisualizerWordColorRange> ranges,
) {
  final List<Rgb?> out = List<Rgb?>.filled(glyphs.length, null);
  if (ranges.isEmpty) return out;
  int offset = 0;
  for (int i = 0; i < glyphs.length; i++) {
    final int end = offset + glyphs[i].length;
    if (glyphs[i].trim().isNotEmpty) {
      final Color? c = LyricVisualizerTheme.colorForSpan(ranges, offset, end);
      if (c != null) out[i] = Rgb.of(c);
    }
    offset = end;
  }
  return out;
}

// ---------------------------------------------------------------------------
// 精灵
// ---------------------------------------------------------------------------

const double _spriteCell = 64;

enum _Sprite { dot, star, bokeh, streak }

ui.Image _buildSprites() {
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final Canvas canvas = Canvas(recorder);
  const double h = _spriteCell / 2;
  Paint radial(Offset c, double r, List<Color> colors, [List<double>? stops]) =>
      Paint()..shader = ui.Gradient.radial(c, r, colors, stops);
  // 光点
  const Offset dot = Offset(h, h);
  canvas.drawCircle(
    dot,
    h,
    radial(
      dot,
      h,
      const <Color>[Color(0xFFFFFFFF), Color(0x66FFFFFF), Color(0x00FFFFFF)],
      const <double>[0, 0.25, 1],
    ),
  );
  // 星芒：十字两道光丝 + 小核
  const Offset star = Offset(_spriteCell + h, h);
  for (final bool vertical in <bool>[false, true]) {
    canvas
      ..save()
      ..translate(star.dx, star.dy)
      ..scale(vertical ? 0.07 : 1, vertical ? 1 : 0.07);
    canvas.drawCircle(
      Offset.zero,
      h,
      radial(Offset.zero, h, const <Color>[
        Color(0xFFFFFFFF),
        Color(0x00FFFFFF),
      ]),
    );
    canvas.restore();
  }
  canvas.drawCircle(
    star,
    h * 0.3,
    radial(star, h * 0.3, const <Color>[Color(0xFFFFFFFF), Color(0x00FFFFFF)]),
  );
  // 散景：亮边的软圆盘
  const Offset bokeh = Offset(_spriteCell * 2 + h, h);
  canvas.drawCircle(
    bokeh,
    h * 0.96,
    radial(
      bokeh,
      h * 0.96,
      const <Color>[
        Color(0x55FFFFFF),
        Color(0x77FFFFFF),
        Color(0xAAFFFFFF),
        Color(0x00FFFFFF),
      ],
      const <double>[0, 0.7, 0.88, 1],
    ),
  );
  // 光丝：横向
  canvas
    ..save()
    ..translate(_spriteCell * 3 + h, h)
    ..scale(1, 0.12);
  canvas.drawCircle(
    Offset.zero,
    h,
    radial(Offset.zero, h, const <Color>[Color(0xFFFFFFFF), Color(0x00FFFFFF)]),
  );
  canvas.restore();
  final ui.Picture picture = recorder.endRecording();
  final ui.Image image = picture.toImageSync(
    (_spriteCell * 4).toInt(),
    _spriteCell.toInt(),
  );
  picture.dispose();
  return image;
}

/// drawRawAtlas 的一批（缓冲每帧复用）。
class _Batch {
  final List<double> _xf = <double>[];
  final List<double> _rects = <double>[];
  final List<int> _colors = <int>[];

  bool get isEmpty => _colors.isEmpty;

  void add(
    Rect source,
    double cx,
    double cy,
    double sizePx,
    double rotation,
    int argb, {
    double aspect = 1,
  }) {
    final double scale = sizePx / source.height;
    final double c = math.cos(rotation) * scale;
    final double s = math.sin(rotation) * scale;
    final double w = source.width;
    final double h = source.height;
    _xf
      ..add(c)
      ..add(s)
      ..add(cx - c * w / 2 + s * h / 2)
      ..add(cy - s * w / 2 - c * h / 2);
    _rects
      ..add(source.left)
      ..add(source.top)
      ..add(source.right)
      ..add(source.bottom);
    _colors.add(argb);
  }

  void flush(Canvas canvas, ui.Image image, Paint paint) {
    if (_colors.isEmpty) return;
    canvas.drawRawAtlas(
      image,
      Float32List.fromList(_xf),
      Float32List.fromList(_rects),
      Int32List.fromList(_colors),
      BlendMode.modulate,
      null,
      paint,
    );
    _xf.clear();
    _rects.clear();
    _colors.clear();
  }
}

Rect _spriteRect(_Sprite s) =>
    Rect.fromLTWH(s.index * _spriteCell, 0, _spriteCell, _spriteCell);

// ---------------------------------------------------------------------------
// 每个镜头的光位实例
// ---------------------------------------------------------------------------

class _ShotRig {
  _ShotRig(
    this.shot,
    this.profile,
    this.rig,
    this.art,
    this.motes,
    this.front,
    this.stars,
  );
  final LumiereShot shot;
  final LumiereProfile profile;
  final LightRig rig;
  final LineArtSpec art;
  final Float64List motes;
  final Float64List? front;
  final Float64List? stars;
}

Float64List _seeded(String key, int count, int stride) {
  final LumiereRng r = lumiereRng(key);
  return Float64List.fromList(<double>[
    for (int i = 0; i < count * stride; i++) r(),
  ]);
}

// ---------------------------------------------------------------------------
// 场景
// ---------------------------------------------------------------------------

class LumiereScene {
  LumiereScene({
    required this.runtime,
    required this.seed,
    required bool seamless,
    this.title,
    this.artist,
    this.album,
    LumiereGlyphStyle glyphStyle = const LumiereGlyphStyle(),
  }) : lines = <LumiereLine>[
         for (int i = 0; i < runtime.lines.length; i++)
           LumiereLine.of(
             runtime.lines[i],
             sourced: runtime.hasSourceSongParts,
             index: i,
           ),
       ] {
    program = compileLumiereProgram(lines, seed, seamless: seamless);
    glyphs = LumiereGlyphs(<String>[
      for (final LyricVisualizerLine l in runtime.lines)
        for (final LyricVisualizerGlyph g in l.glyphs) g.text,
      ...?title?.characters,
      ...?artist?.characters,
      ...?album?.characters,
    ], glyphStyle);
    _sprites = _buildSprites();
    _echoWords = _fragmentsOf(runtime.lines);
  }

  final LyricVisualizerRuntime runtime;
  final String seed;
  final String? title;
  final String? artist;
  final String? album;
  final List<LumiereLine> lines;
  late final LumiereProgram program;

  /// 字形图集（按物理字号分档；补档 / 换字体都在后台，见 [LumiereGlyphs]）。
  late final LumiereGlyphs glyphs;

  /// 当前这套图集。
  LumiereGlyphAtlases get atlas => glyphs.current;
  late final ui.Image _sprites;
  late final List<(LyricVisualizerLine, int, List<String>)> _echoWords;

  final Map<String, _ShotRig> _rigs = <String, _ShotRig>{};
  double _rigAspect = -1;

  /// 主题图标（每帧由样式写入；变了清掉各镜头的落点）。
  List<IconData> _themeIcons = const <IconData>[];
  final Map<String, List<LumierePlacedIcon>> _iconsByShot =
      <String, List<LumierePlacedIcon>>{};
  double _iconAspect = -1;

  List<IconData> get themeIcons => _themeIcons;
  set themeIcons(List<IconData> icons) {
    if (listEquals(icons, _themeIcons)) return;
    _themeIcons = icons;
    _iconsByShot.clear();
  }

  /// 镜头 [shotIndex]（段内序号）的主题图标落点（folia `buildShotIconArts`：按
  /// `种子:镜头:光位:icons` 播种，各镜头从第 `序号 × 2` 个图标开始轮流取，避开该光位的文字区）。
  List<LumierePlacedIcon> _iconsOf(
    LumiereShot shot,
    int shotIndex,
    _ShotRig rig,
    double aspect,
  ) {
    if (_themeIcons.isEmpty) return const <LumierePlacedIcon>[];
    if ((aspect - _iconAspect).abs() > 1e-3) {
      _iconsByShot.clear();
      _iconAspect = aspect;
    }
    return _iconsByShot.putIfAbsent(shot.id, () {
      final TextRegion r = rig.profile.region;
      return placeLumiereThemeIcons(
        icons: _themeIcons,
        aspect: aspect,
        avoid: TextRegion(r.cx * aspect, r.cy, r.w * aspect, r.h),
        random: lumiereRng('$seed:$shotIndex:${shot.kind}:icons'),
        offset: shotIndex * 2,
      );
    });
  }

  final Map<int, (String, LineShape)> _shapes = <int, (String, LineShape)>{};
  final Map<int, List<double>> _scales = <int, List<double>>{};
  final Map<int, GlyphRandoms> _randoms = <int, GlyphRandoms>{};
  LyricVisualizerTheme? _keywordTheme;
  final Map<LyricVisualizerLine, List<Rgb?>> _keywordLines =
      Map<LyricVisualizerLine, List<Rgb?>>.identity();

  /// [line] 逐字的关键字色（不是关键字为 null）；按主题缓存。
  List<Rgb?> keywordColorsOf(
    LyricVisualizerTheme theme,
    LyricVisualizerLine line,
  ) {
    if (!identical(theme, _keywordTheme)) {
      _keywordTheme = theme;
      _keywordLines.clear();
    }
    return _keywordLines.putIfAbsent(
      line,
      () => lumiereGlyphKeywordColors(
        line.glyphs.map((LyricVisualizerGlyph g) => g.text).toList(),
        theme.colorRangesFor(line.text),
      ),
    );
  }

  Rgb? _keywordAt(LumiereFrame f, LyricVisualizerLine? line, int glyphIndex) {
    final LyricVisualizerTheme? theme = f.keywords;
    if (theme == null || line == null) return null;
    final List<Rgb?> colors = keywordColorsOf(theme, line);
    return glyphIndex >= 0 && glyphIndex < colors.length
        ? colors[glyphIndex]
        : null;
  }

  final _Batch _batch = _Batch();
  final LumiereGlyphBatch _glyphBatch = LumiereGlyphBatch();
  double _devicePixelRatio = 1;

  /// 词形缓存按哪套图集的步进算的；图集换了（换字体）就作废。
  LumiereGlyphAtlases? _shapesAtlas;
  Float32List? _gridPositions;
  Uint16List? _gridIndices;
  String _gridKey = '';
  bool _disposed = false;

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    glyphs.dispose();
    _sprites.dispose();
  }

  /// 词碎片：(行, 起始字下标, 字)。
  static List<(LyricVisualizerLine, int, List<String>)> _fragmentsOf(
    List<LyricVisualizerLine> lines,
  ) {
    final List<(LyricVisualizerLine, int, List<String>)> out =
        <(LyricVisualizerLine, int, List<String>)>[];
    for (final LyricVisualizerLine l in lines) {
      List<String> current = <String>[];
      int from = 0;
      for (int gi = 0; gi < l.glyphs.length; gi++) {
        final LyricVisualizerGlyph g = l.glyphs[gi];
        if (g.isSpace || current.length >= 4) {
          if (current.isNotEmpty) out.add((l, from, current));
          current = <String>[];
          if (g.isSpace) continue;
        }
        if (current.isEmpty) from = gi;
        current.add(g.text);
      }
      if (current.isNotEmpty) out.add((l, from, current));
    }
    return out;
  }

  _ShotRig _rigOf(LumiereShot shot, double aspect) {
    if ((aspect - _rigAspect).abs() > 1e-3) {
      _rigs.clear();
      _rigAspect = aspect;
    }
    return _rigs.putIfAbsent(shot.id, () {
      final LumiereProfile profile = profileOf(shot.kind);
      final LightRig rig = profile.light(
        RigContext(aspect, lumiereRng('$seed:${shot.id}:rig')),
      );
      final LineArtSpec art = profile.lineArt(
        RigContext(aspect, lumiereRng('$seed:${shot.id}:art')),
      );
      final MotesSpec? front = profile.front;
      final StarfallSpec? starfall = profile.starfall;
      return _ShotRig(
        shot,
        profile,
        rig,
        art,
        _seeded('$seed:${shot.id}:motes', profile.motes.count, 6),
        front == null
            ? null
            : _seeded('$seed:${shot.id}:front', front.count, 6),
        starfall == null
            ? null
            : _seeded(
                '$seed:${shot.id}:stars',
                starfall.stars + starfall.rain,
                4,
              ),
      );
    });
  }

  // -------------------------------------------------------------------------
  // 帧
  // -------------------------------------------------------------------------

  void paint(Canvas canvas, Size size, LumiereFrame f) {
    if (_disposed || size.isEmpty || program.paragraphs.isEmpty) return;
    _devicePixelRatio = f.devicePixelRatio;
    if (!identical(_shapesAtlas, atlas)) {
      _shapesAtlas = atlas;
      _shapes.clear();
    }
    _paintFrame(canvas, size, f);
    // 这一帧出现了比已有各档都大的字：后台补那一档。
    glyphs.afterFrame();
  }

  void _paintFrame(Canvas canvas, Size size, LumiereFrame f) {
    final double w = size.width;
    final double h = size.height;
    final double aspect = w / h;
    final double t = f.time;
    final LumiereSettings s = f.settings;

    _paintDarkField(canvas, size, f);

    final int pi = program.paragraphIndexAt(t);
    final LumiereParagraph unit = program.paragraphs[pi];
    final List<LumiereShot> shots = unit.shots;
    int si = 0;
    for (int i = 0; i < shots.length; i++) {
      if (t >= shots[i].start) si = i;
    }
    final _ShotRig? cur = shots.isEmpty ? null : _rigOf(shots[si], aspect);
    final _ShotRig? prev = si > 0 ? _rigOf(shots[si - 1], aspect) : null;
    final double handoff = prev == null || !f.motion
        ? 1
        : smooth((t - shots[si].start) / 0.9);

    // 片尾卡：最后一行唱完之后
    final double? lyricEnd = program.lyricEnd;
    final bool hasCredits =
        lyricEnd != null &&
        (title?.trim().isNotEmpty ?? false) &&
        t > lyricEnd + 0.5;
    final double creditsAge = hasCredits
        ? (f.motion ? t - lyricEnd - 0.5 : 99)
        : -1;

    // 转场（按段落切单元时）
    LumiereTransitionFrame frame = LumiereTransitionFrame.identity;
    if (f.motion) {
      final LumiereTransitionOut? out = unit.transitionOut;
      if (out != null && t >= out.start) {
        frame = transitionFrame(
          out.kind,
          exit: true,
          progress: (t - out.start) / math.max(out.end - out.start, 1e-3),
        );
      } else if (pi > 0) {
        final LumiereTransitionOut? before =
            program.paragraphs[pi - 1].transitionOut;
        if (before != null) {
          final double enter = transitionEnterDuration(
            before.kind,
            before.start,
            before.end,
          );
          if (t < unit.start + enter) {
            frame = transitionFrame(
              before.kind,
              exit: false,
              progress: (t - unit.start) / enter,
            );
          }
        }
      }
    }

    final bool layered = frame.alpha < 0.999 || frame.blur > 0.3;
    if (layered) {
      final Paint layer = Paint()
        ..color = Color.fromRGBO(255, 255, 255, clamp01(frame.alpha));
      if (frame.blur > 0.3) {
        layer.imageFilter = ui.ImageFilter.blur(
          sigmaX: frame.blur,
          sigmaY: frame.blur,
        );
      }
      canvas.saveLayer(Offset.zero & size, layer);
    }
    canvas.save();
    _applyCamera(canvas, size, f, cur, prev, handoff, si, frame.scale);

    // 光场：当前与上一个镜头按交接权重叠加
    final List<ResolvedBeam> beams = <ResolvedBeam>[];
    final List<(List<ResolvedBeam>, double)> beamSets =
        <(List<ResolvedBeam>, double)>[];
    final double local = t - (cur?.shot.start ?? 0);
    final double unitLocal = t - unit.start;
    for (final (_ShotRig rig, double weight) in <(_ShotRig, double)>[
      if (prev != null && handoff < 1) (prev, 1 - handoff),
      if (cur != null) (cur, handoff),
    ]) {
      double gain = weight * s.lightIntensity;
      final StarfallSpec? starfall = rig.profile.starfall;
      if (f.motion &&
          starfall != null &&
          unit.opening &&
          identical(rig.shot, shots.first)) {
        gain *= smooth((unitLocal - starfallIgnition(starfall)) / 0.8);
      }
      if (hasCredits) gain *= 1 - 0.6 * smooth(creditsAge / 1.6);
      final List<ResolvedBeam> resolved = resolveBeams(
        rig.rig,
        f.animTime,
        aspect,
        LightDrive(
          intensity: gain,
          bass: math.min(1, f.bass) * s.audioResponse,
          color: f.palette.light,
          local: f.motion ? t - rig.shot.start : null,
        ),
      );
      beams.addAll(resolved);
      beamSets.add((resolved, weight));
    }

    if (!s.textOnly && cur != null) {
      _paintField(canvas, size, f, cur, prev, handoff, beams);
      for (final (List<ResolvedBeam> set, double _) in beamSets) {
        for (final ResolvedBeam b in set) {
          _paintBeam(canvas, size, f, b, cur.rig.fog, cur.rig.caustic);
        }
      }
      _paintGlare(canvas, size, f, cur, prev, handoff, t);
      if (s.lineArt) {
        if (prev != null && handoff < 1) {
          _paintLineArt(canvas, size, f, prev, 1 - handoff, local + 99);
        }
        _paintLineArt(canvas, size, f, cur, handoff, local);
      }
      if (s.themeIcons && _themeIcons.isNotEmpty) {
        if (prev != null && handoff < 1) {
          _paintThemeIcons(
            canvas,
            size,
            f,
            _iconsOf(shots[si - 1], si - 1, prev, aspect),
            prev,
            1 - handoff,
            local + 99,
          );
        }
        _paintThemeIcons(
          canvas,
          size,
          f,
          _iconsOf(shots[si], si, cur, aspect),
          cur,
          handoff,
          local,
        );
      }
      if (f.motion) {
        _paintStars(canvas, size, f, cur, handoff, unit, shots, unitLocal);
        if (prev != null && handoff < 1) {
          _paintMotes(canvas, size, f, prev, 1 - handoff, beams, front: false);
        }
        _paintMotes(canvas, size, f, cur, handoff, beams, front: false);
        if (s.echo > 0) _paintEcho(canvas, size, f, cur, beams);
      }
    }

    // 歌词窗口
    final double textFade = hasCredits ? 1 - smooth(creditsAge / 1.6) : 1;
    if (cur != null && textFade > 0.002) {
      _paintWindow(canvas, size, f, unit, cur, prev, handoff, beams, textFade);
    }

    if (!s.textOnly && cur != null && f.motion && s.frontBokeh) {
      _paintMotes(canvas, size, f, cur, handoff, beams, front: true);
    }
    canvas.restore();
    if (layered) canvas.restore();

    if (!s.textOnly && s.overlayFrame) _paintOverlayFrame(canvas, size, f);
    if (hasCredits) _paintCredits(canvas, size, f, creditsAge);
  }

  // -------------------------------------------------------------------------
  // 暗场与运镜
  // -------------------------------------------------------------------------

  void _paintDarkField(Canvas canvas, Size size, LumiereFrame f) {
    double alpha = f.settings.darkField;
    if (f.lightBackground) alpha = math.max(alpha, 0.94);
    if (alpha <= 0) return;
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = f.palette.field.scale(0.06).toColor(alpha),
    );
  }

  void _applyCamera(
    Canvas canvas,
    Size size,
    LumiereFrame f,
    _ShotRig? cur,
    _ShotRig? prev,
    double handoff,
    int shotIndex,
    double extraScale,
  ) {
    final double w = size.width;
    final double h = size.height;
    double scale = extraScale;
    double tx = 0;
    double ty = 0;
    double rotation = 0;
    if (f.motion && cur != null) {
      final LumiereShot shot = cur.shot;
      final double p = clamp01(
        (f.time - shot.start) / math.max(shot.end - shot.start, 0.1),
      );
      double k = easeInOutSine(p);
      // 相邻镜头推拉往返：镜头交界处连续
      if (shotIndex.isOdd) k = 1 - k;
      final CameraSpec a = cur.profile.camera;
      final CameraSpec b = prev?.profile.camera ?? a;
      final double push = lerpD(b.push, a.push, handoff);
      final double driftX = lerpD(b.driftX, a.driftX, handoff);
      final double driftY = lerpD(b.driftY, a.driftY, handoff);
      final double at = f.animTime;
      final double m = f.cameraMotion;
      scale *= 1 + push * k + 0.008 * m * math.sin(at * kTau / 9);
      tx = driftX * h * k * 4 + 0.006 * m * h * math.sin(at * kTau / 13);
      ty = driftY * h * k * 4 + 0.006 * m * h * math.cos(at * kTau / 17);
      rotation = 0.004 * m * math.sin(at * kTau / 21);
    }
    if (scale == 1 && tx == 0 && ty == 0 && rotation == 0) return;
    canvas
      ..translate(w / 2, h / 2)
      ..rotate(rotation)
      ..scale(scale)
      ..translate(-w / 2 + tx, -h / 2 + ty);
  }

  // -------------------------------------------------------------------------
  // 光场
  // -------------------------------------------------------------------------

  (int, int) _gridSize(double aspect, LumiereQuality q) {
    final double cells = switch (q) {
      LumiereQuality.full => 3000,
      LumiereQuality.balanced => 1800,
      LumiereQuality.low => 900,
    };
    final int gx = math.max(8, math.sqrt(cells * aspect).round());
    final int gy = math.max(8, (cells / gx).round());
    return (gx, gy);
  }

  double _fogAt(FogSpec fog, double x, double y, double at, int octaves) {
    final double ux = (x - fog.driftX * at) * fog.scale;
    final double uy = (y - fog.driftY * at) * fog.scale;
    final double warp =
        fog.warp * 0.35 * (valueNoise2(ux * 0.5 + 5.2, uy * 0.5 + 1.3) - 0.5);
    final double n = fbm(ux + warp, uy - warp, octaves);
    return clamp01(0.3 + (n - 0.5) * 1.8);
  }

  double _causticAt(CausticSpec c, double x, double y, double at) {
    final double sx = x * c.scale * 3;
    final double sy = y * c.scale * 3;
    final double n = valueNoise2(sx + at * c.speed, sy - at * c.speed * 0.7);
    final double m = valueNoise2(
      sx * 1.7 - at * c.speed * 1.3 + 3.1,
      sy * 1.7 + 7.3,
    );
    final double ridge = 1 - (n + m - 1).abs();
    return math.pow(ridge, 6).toDouble();
  }

  double _waveAt(WaveSpec wv, double x, double y, double aspect, double at) {
    final double cx = wv.cx * aspect;
    final double dx = x - cx;
    final double dy = y - wv.cy;
    final double r = math.sqrt(dx * dx + dy * dy);
    if (r > wv.radius * 1.1) return 0;
    final double mask =
        (1 - smoothstep(wv.radius * 0.7, wv.radius, r)) *
        lerpD(1 - wv.shield, 1, smoothstep(0, wv.radius * 0.5, r));
    final double k = wv.frequency * kTau / math.max(wv.radius, 1e-3);
    final double phase = at * wv.speed * kTau;
    final double pattern = switch (wv.mode) {
      WaveMode.rings => 0.5 + 0.5 * math.cos(r * k * 1.6 - phase),
      WaveMode.slits =>
        (0.5 + 0.5 * math.cos(dx * k * 2 - phase * 0.3)) *
            smoothstep(-0.05, 0.1, dy + wv.radius * 0.6),
      WaveMode.sources => () {
        final double d1 = math.sqrt(
          (dx - wv.separation / 2) * (dx - wv.separation / 2) + dy * dy,
        );
        final double d2 = math.sqrt(
          (dx + wv.separation / 2) * (dx + wv.separation / 2) + dy * dy,
        );
        final double v =
            (math.cos(d1 * k * 1.6 - phase) + math.cos(d2 * k * 1.6 - phase)) /
            2;
        return v * v;
      }(),
      WaveMode.airy => () {
        final double c = math.cos(r * k);
        return c * c * math.exp(-r / math.max(wv.radius, 1e-3) * 2.5);
      }(),
    };
    return pattern * mask * wv.strength;
  }

  /// 全屏网格：烟里的环境光、地上的焦散光斑、干涉条纹。
  void _paintField(
    Canvas canvas,
    Size size,
    LumiereFrame f,
    _ShotRig cur,
    _ShotRig? prev,
    double handoff,
    List<ResolvedBeam> beams,
  ) {
    final double w = size.width;
    final double h = size.height;
    final double aspect = w / h;
    final LumiereSettings s = f.settings;
    final (int gx, int gy) = _gridSize(aspect, s.quality);
    final String key = '$w:$h:$gx:$gy';
    if (key != _gridKey) {
      _gridKey = key;
      final Float32List pos = Float32List((gx + 1) * (gy + 1) * 2);
      for (int j = 0; j <= gy; j++) {
        for (int i = 0; i <= gx; i++) {
          final int v = (j * (gx + 1) + i) * 2;
          pos[v] = i / gx * w;
          pos[v + 1] = j / gy * h;
        }
      }
      final Uint16List idx = Uint16List(gx * gy * 6);
      int n = 0;
      for (int j = 0; j < gy; j++) {
        for (int i = 0; i < gx; i++) {
          final int a = j * (gx + 1) + i;
          final int b = a + 1;
          final int c = a + gx + 1;
          final int d = c + 1;
          idx[n++] = a;
          idx[n++] = b;
          idx[n++] = c;
          idx[n++] = b;
          idx[n++] = d;
          idx[n++] = c;
        }
      }
      _gridPositions = pos;
      _gridIndices = idx;
    }
    final FogSpec fog = prev == null || handoff >= 1
        ? cur.rig.fog
        : FogSpec.lerp(prev.rig.fog, cur.rig.fog, handoff);
    final CausticSpec? caustic = cur.rig.caustic?.faded(handoff);
    final CausticSpec? prevCaustic = prev != null && handoff < 1
        ? prev.rig.caustic?.faded(1 - handoff)
        : null;
    final WaveSpec? wave = cur.rig.wave?.withStrength(
      (cur.rig.wave?.strength ?? 0) * handoff,
    );
    final WaveSpec? prevWave = prev != null && handoff < 1
        ? prev.rig.wave?.withStrength(
            (prev.rig.wave?.strength ?? 0) * (1 - handoff),
          )
        : null;
    final double at = f.animTime;
    final double density = fog.density * s.fogDensity;
    final Rgb light = f.palette.light;
    final double gain =
        s.lightIntensity * (1 + 0.2 * math.min(1, f.power) * s.audioResponse);
    final Int32List colors = Int32List((gx + 1) * (gy + 1));
    for (int j = 0; j <= gy; j++) {
      final double y = j / gy;
      for (int i = 0; i <= gx; i++) {
        final double x = i / gx * aspect;
        final double fogV = _fogAt(fog, x, y, at, s.fogOctaves) * density;
        double v = fog.ambient * fogV * 1.6 * gain;
        for (final CausticSpec? c in <CausticSpec?>[caustic, prevCaustic]) {
          final CausticFloor? floor = c?.floor;
          if (c == null || floor == null) continue;
          final double ex =
              (x - floor.cx * aspect) / math.max(floor.rx * aspect, 1e-3);
          final double ey = (y - floor.cy) / math.max(floor.ry, 1e-3);
          final double e = 1 - smoothstep(0.55, 1, ex * ex + ey * ey);
          if (e > 0) {
            v +=
                floor.strength *
                e *
                (0.25 + 1.4 * _causticAt(c, x * 0.6, y * 0.6, at)) *
                gain;
          }
        }
        for (final WaveSpec? wv in <WaveSpec?>[wave, prevWave]) {
          if (wv != null && wv.strength > 0) {
            v +=
                _waveAt(wv, x, y, aspect, at) *
                gain *
                (0.6 + 0.4 * lightAt(beams, x, y));
          }
        }
        colors[j * (gx + 1) + i] = light.scale(compressLight(v)).argb(1);
      }
    }
    canvas.drawVertices(
      ui.Vertices.raw(
        ui.VertexMode.triangles,
        _gridPositions!,
        colors: colors,
        indices: _gridIndices,
      ),
      BlendMode.modulate,
      Paint()
        ..color = const Color(0xFFFFFFFF)
        ..blendMode = BlendMode.plus,
    );
  }

  /// 一束光：在光束自己的坐标里铺网格，逐顶点算截面强度 × 丁达尔（烟越浓越亮）× 焦散。
  void _paintBeam(
    Canvas canvas,
    Size size,
    LumiereFrame f,
    ResolvedBeam b,
    FogSpec fog,
    CausticSpec? caustic,
  ) {
    if (b.intensity <= 0.002) return;
    final double h = size.height;
    final LumiereSettings s = f.settings;
    final double q = switch (s.quality) {
      LumiereQuality.full => 1,
      LumiereQuality.balanced => 0.75,
      LumiereQuality.low => 0.5,
    };
    double maxAlong = math.min(b.length * 4, 2.6);
    if (b.reach > 0) maxAlong = math.min(maxAlong, b.reach + 0.02);
    int across = 9;
    if (b.streaks > 0) across = (b.streakFreq * 1.4 + 7).clamp(9, 33).round();
    final GoboSpec? gobo = b.gobo;
    if (gobo != null) {
      across = math.max(
        across,
        (gobo.frequency * 1.6 + 9).clamp(9, 41).round(),
      );
    }
    across = math.max(7, (across * q).round()) | 1;
    int along = math.max(10, (28 * q).round());
    if (gobo != null &&
        (gobo.pattern == GoboPattern.lattice ||
            gobo.pattern == GoboPattern.leaves)) {
      along = (along * 1.6).round();
    }
    final int count = (along + 1) * across;
    final Float32List pos = Float32List(count * 2);
    final Int32List colors = Int32List(count);
    final double at = f.animTime;
    final double density = fog.density * s.fogDensity;
    final double nx = -b.dy;
    final double ny = b.dx;
    final double bloomBoost = 1 + 0.15 * s.bloom;
    for (int i = 0; i <= along; i++) {
      final double u = i / along;
      final double d = maxAlong * math.pow(u, 1.5);
      final double half = (b.halfWidth + d * b.tanSpread).abs() + 1e-4;
      for (int k = 0; k < across; k++) {
        final double sv = -1 + 2 * k / (across - 1);
        final double x = b.ox + b.dx * d + nx * sv * half;
        final double y = b.oy + b.dy * d + ny * sv * half;
        final int vi = i * across + k;
        pos[vi * 2] = x * h;
        pos[vi * 2 + 1] = y * h;
        double m = beamMaskAt(b, sv, d);
        if (m <= 0) {
          colors[vi] = 0xFF000000;
          continue;
        }
        final double fogV =
            _fogAt(fog, x, y, at, math.max(2, s.fogOctaves - 1)) * density;
        m *= fog.tyndallBase + (1 - fog.tyndallBase) * fogV;
        if (caustic != null && caustic.inBeam > 0) {
          m *= 1 + caustic.inBeam * 1.6 * _causticAt(caustic, x, y, at);
        }
        Rgb color = b.color;
        if (b.spectrum > 0) {
          color = color.times(kWhite.mix(spectrumColor(sv), b.spectrum));
        }
        colors[vi] = color.scale(compressLight(m * bloomBoost)).argb(1);
      }
    }
    final Uint16List idx = Uint16List(along * (across - 1) * 6);
    int n = 0;
    for (int i = 0; i < along; i++) {
      for (int k = 0; k < across - 1; k++) {
        final int a = i * across + k;
        final int c = a + across;
        idx[n++] = a;
        idx[n++] = a + 1;
        idx[n++] = c;
        idx[n++] = a + 1;
        idx[n++] = c + 1;
        idx[n++] = c;
      }
    }
    canvas.drawVertices(
      ui.Vertices.raw(
        ui.VertexMode.triangles,
        pos,
        colors: colors,
        indices: idx,
      ),
      BlendMode.modulate,
      Paint()
        ..color = const Color(0xFFFFFFFF)
        ..blendMode = BlendMode.plus,
    );
  }

  void _paintGlare(
    Canvas canvas,
    Size size,
    LumiereFrame f,
    _ShotRig cur,
    _ShotRig? prev,
    double handoff,
    double t,
  ) {
    final GlareSpec? a = prev?.rig.glare;
    final GlareSpec? b = cur.rig.glare;
    GlareSpec? g;
    double weight = 1;
    if (b != null && a != null && f.motion) {
      final double k = easeInOutCubic((t - cur.shot.start) / 1.6);
      g = GlareSpec(
        x: lerpD(a.x, b.x, k),
        y: lerpD(a.y, b.y, k),
        radius: lerpD(a.radius, b.radius, k),
        intensity: lerpD(a.intensity, b.intensity, k),
        streak: lerpD(a.streak, b.streak, k),
      );
    } else if (b != null) {
      g = b;
      weight = prev == null ? 1 : handoff;
    } else if (a != null && handoff < 1) {
      g = a;
      weight = 1 - handoff;
    }
    if (g == null) return;
    final double h = size.height;
    final double aspect = size.width / h;
    final LumiereSettings s = f.settings;
    final double intensity =
        g.intensity * weight * s.lightIntensity * (0.7 + 0.3 * s.bloom);
    if (intensity <= 0.002) return;
    final Offset c = Offset(g.x * aspect * h, g.y * h);
    final double r = g.radius * h * 2.4 * (1 + 0.25 * s.bloom);
    final Color core = f.palette.light
        .mix(kWhite, 0.4)
        .toColor(clamp01(intensity * 0.85));
    final Paint plus = Paint()..blendMode = BlendMode.plus;
    plus.shader = ui.Gradient.radial(
      c,
      r,
      <Color>[
        core,
        core.withValues(alpha: core.a * 0.25),
        core.withValues(alpha: 0),
      ],
      const <double>[0, 0.3, 1],
    );
    canvas.drawCircle(c, r, plus);
    if (g.streak > 0.01) {
      canvas
        ..save()
        ..translate(c.dx, c.dy)
        ..scale(1 + 7 * g.streak, 0.05);
      plus.shader = ui.Gradient.radial(Offset.zero, r, <Color>[
        core.withValues(alpha: core.a * 0.6),
        core.withValues(alpha: 0),
      ]);
      canvas.drawCircle(Offset.zero, r, plus);
      canvas.restore();
    }
  }

  // -------------------------------------------------------------------------
  // 线稿
  // -------------------------------------------------------------------------

  void _paintLineArt(
    Canvas canvas,
    Size size,
    LumiereFrame f,
    _ShotRig rig,
    double weight,
    double local,
  ) {
    if (weight <= 0.01 || rig.art.paths.isEmpty && rig.art.nodes.isEmpty) {
      return;
    }
    final double h = size.height;
    // 镜头开始前 0.6 秒开始画，1.2 秒淡入，按 3.6 秒的进度一笔笔画出
    final double drawT = f.motion ? (local + 0.6) / 3.6 : 99;
    final double fade = f.motion ? smooth((local + 0.6) / 1.2) * weight : 1;
    final double gain = math.min(1.6, rig.profile.artGain);
    final Rgb color = f.palette.lit;
    final Paint core = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final Paint glow = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..blendMode = BlendMode.plus;
    for (final LinePath path in rig.art.paths) {
      final double p = smooth((drawT - path.delay) / math.max(path.span, 0.01));
      if (p <= 0 || path.points.length < 2) continue;
      final double alpha = clamp01(path.alpha * gain * fade * 0.8);
      if (alpha <= 0.004) continue;
      final Path out = _partialPath(path, p, h);
      final double width = math.max(0.6, path.width * h);
      if (f.settings.bloom > 0) {
        glow
          ..strokeWidth = width * 3.2
          ..color = color.toColor(alpha * 0.12 * f.settings.bloom);
        canvas.drawPath(out, glow);
      }
      core
        ..strokeWidth = width
        ..color = color.toColor(alpha);
      canvas.drawPath(out, core);
    }
    for (final LineNode node in rig.art.nodes) {
      final double p = smooth((drawT - node.delay) / 0.3);
      if (p <= 0) continue;
      final double tw = f.motion
          ? 0.65 + 0.35 * math.sin(f.animTime * 2.2 + node.twinklePhase * kTau)
          : 0.8;
      _batch.add(
        _spriteRect(_Sprite.star),
        node.at.$1 * h,
        node.at.$2 * h,
        math.max(4, node.size * h * 3),
        0,
        color.argb(clamp01(p * tw * fade * 0.8)),
      );
    }
    _batch.flush(canvas, _sprites, Paint()..blendMode = BlendMode.plus);
  }

  /// 主题图标：与线稿同色同节奏（镜头开始前 0.6 秒起、1.2 秒淡入），每枚错开 0.12 秒、0.32 秒
  /// 显出（folia `themeIconsArt` 的描线时序，这里画字形整枚淡入而非逐笔描），透明度 0.5。
  void _paintThemeIcons(
    Canvas canvas,
    Size size,
    LumiereFrame f,
    List<LumierePlacedIcon> icons,
    _ShotRig rig,
    double weight,
    double local,
  ) {
    if (weight <= 0.01 || icons.isEmpty) return;
    final double h = size.height;
    final double drawT = f.motion ? (local + 0.6) / 3.6 : 99;
    final double fade = f.motion ? smooth((local + 0.6) / 1.2) * weight : 1;
    final double gain = math.min(1.6, rig.profile.artGain);
    final Rgb color = f.palette.lit;
    for (int i = 0; i < icons.length; i++) {
      final LumierePlacedIcon icon = icons[i];
      final double p = smooth((drawT - 0.18 - i * 0.12) / 0.32);
      final double alpha = clamp01(0.5 * gain * fade * 0.8 * p);
      if (alpha <= 0.004) continue;
      canvas.save();
      canvas.translate(icon.cx * h, icon.cy * h);
      canvas.rotate(icon.rotation);
      paintLyricVisualizerIconGlyph(
        canvas,
        icon.icon,
        Offset.zero,
        icon.size * h,
        color.toColor(alpha),
      );
      canvas.restore();
    }
  }

  Path _partialPath(LinePath path, double progress, double h) {
    final Path out = Path();
    final double limit = path.total * progress;
    final (double, double)? dash = path.dash;
    final List<Pt> pts = path.points;
    final List<double> lengths = path.lengths;
    if (dash == null) {
      out.moveTo(pts.first.$1 * h, pts.first.$2 * h);
      for (int i = 1; i < pts.length; i++) {
        if (lengths[i] <= limit) {
          out.lineTo(pts[i].$1 * h, pts[i].$2 * h);
        } else {
          final double seg = lengths[i] - lengths[i - 1];
          final double k = seg <= 0 ? 0 : (limit - lengths[i - 1]) / seg;
          out.lineTo(
            lerpD(pts[i - 1].$1, pts[i].$1, k) * h,
            lerpD(pts[i - 1].$2, pts[i].$2, k) * h,
          );
          break;
        }
      }
      return out;
    }
    final double period = math.max(dash.$1 + dash.$2, 1e-4);
    for (int i = 1; i < pts.length; i++) {
      final double l0 = lengths[i - 1];
      final double l1 = math.min(lengths[i], limit);
      if (l0 >= limit) break;
      final double seg = lengths[i] - l0;
      if (seg <= 0) continue;
      double d = l0;
      while (d < l1) {
        final double phase = d % period;
        final double end = phase < dash.$1
            ? math.min(l1, d + dash.$1 - phase)
            : math.min(l1, d + period - phase);
        if (phase < dash.$1) {
          final double k0 = (d - l0) / seg;
          final double k1 = (end - l0) / seg;
          out
            ..moveTo(
              lerpD(pts[i - 1].$1, pts[i].$1, k0) * h,
              lerpD(pts[i - 1].$2, pts[i].$2, k0) * h,
            )
            ..lineTo(
              lerpD(pts[i - 1].$1, pts[i].$1, k1) * h,
              lerpD(pts[i - 1].$2, pts[i].$2, k1) * h,
            );
        }
        d = end + 1e-6;
      }
    }
    return out;
  }

  // -------------------------------------------------------------------------
  // 星空、光雨、浮尘、背景歌词
  // -------------------------------------------------------------------------

  void _paintStars(
    Canvas canvas,
    Size size,
    LumiereFrame f,
    _ShotRig rig,
    double weight,
    LumiereParagraph unit,
    List<LumiereShot> shots,
    double unitLocal,
  ) {
    final StarfallSpec? sf = rig.profile.starfall;
    final Float64List? data = rig.stars;
    if (sf == null || data == null) return;
    final double h = size.height;
    final double aspect = size.width / h;
    final double at = f.animTime;
    final bool opening = unit.opening && identical(rig.shot, shots.first);
    final double local = opening ? unitLocal : 99;
    final Rgb color = f.palette.lit;
    final double bright =
        sf.brightness * weight * (0.6 + 0.4 * f.settings.bloom);
    for (int i = 0; i < sf.stars; i++) {
      final double r0 = data[i * 4];
      final double r1 = data[i * 4 + 1];
      final double r2 = data[i * 4 + 2];
      final double r3 = data[i * 4 + 3];
      final double x = r0 * aspect;
      final double y = math.pow(r1, 1.5) * 0.92;
      final double start = r2 * sf.opening * 0.6;
      final double fall = clamp01((local - start) / 0.9);
      if (fall <= 0) continue;
      final double yy = y - 0.35 * (1 - easeOutCubic(fall));
      final double flash = fall >= 1
          ? math.exp(-(local - start - 0.9) / 0.3)
          : 0;
      final double tw = 0.7 + 0.3 * math.sin(at * (1.2 + r3 * 2) + r3 * 40);
      final double a = clamp01(
        (0.18 + 0.5 * r3) * tw * bright + flash * 0.8 * bright,
      );
      final double sizePx = (0.004 + 0.008 * r3) * h * (1 + flash);
      _batch.add(
        _spriteRect(_Sprite.dot),
        x * h,
        yy * h,
        sizePx * 2.4,
        0,
        color.argb(a),
      );
    }
    // 光雨：开场倾泻之后
    final double rainGate = smooth((local - sf.opening * 0.6) / 1.2);
    if (rainGate > 0) {
      final double angle = math.pi / 2 + (sf.rainSpread * 0.25);
      for (int i = 0; i < sf.rain; i++) {
        final int o = (sf.stars + i) * 4;
        final double r0 = data[o];
        final double r1 = data[o + 1];
        final double r2 = data[o + 2];
        final double speed = sf.rainSpeed * (0.7 + 0.6 * r2);
        final double prog = fract(r1 + at * speed / 1.3);
        final double y = prog * 1.3 - 0.15;
        final double x =
            r0 * (aspect + 0.4) - 0.2 + (y * math.cos(angle) * sf.rainSpread);
        final double a = clamp01(
          0.35 * bright * rainGate * math.sin(prog * math.pi),
        );
        _batch.add(
          _spriteRect(_Sprite.streak),
          x * h,
          y * h,
          0.006 * h * 2,
          angle,
          color.argb(a),
        );
      }
    }
    _batch.flush(canvas, _sprites, Paint()..blendMode = BlendMode.plus);
  }

  void _paintMotes(
    Canvas canvas,
    Size size,
    LumiereFrame f,
    _ShotRig rig,
    double weight,
    List<ResolvedBeam> beams, {
    required bool front,
  }) {
    final MotesSpec? spec = front ? rig.profile.front : rig.profile.motes;
    final Float64List? data = front ? rig.front : rig.motes;
    if (spec == null || data == null || weight <= 0.01) return;
    final double h = size.height;
    final double aspect = size.width / h;
    final double at = f.animTime;
    final LumiereSettings s = f.settings;
    final double quality = switch (s.quality) {
      LumiereQuality.full => 1,
      LumiereQuality.balanced => 0.75,
      LumiereQuality.low => 0.5,
    };
    final int count = front
        ? spec.count
        : (spec.count * s.moteAmount * quality).round().clamp(
            0,
            spec.count * 2,
          );
    const double margin = 0.08;
    final double spanX = aspect + margin * 2;
    const double spanY = 1 + margin * 2;
    final Rgb color = f.palette.lit;
    // 高频点亮浮尘（folia 只作用在主浮尘层，前景虚化不随）。
    final double trebleLift = front
        ? 1
        : 1 + 0.5 * math.min(1, f.treble) * s.audioResponse;
    for (int i = 0; i < count; i++) {
      final int o = (i % spec.count) * 6;
      final double r0 = fract(data[o] + (i ~/ spec.count) * 0.618);
      final double r1 = data[o + 1];
      final double r2 = data[o + 2];
      final double r3 = data[o + 3];
      final double r4 = data[o + 4];
      final double swirl = spec.swirl * (0.5 + r4);
      final double ph = r3 * kTau;
      double x =
          r0 * spanX +
          spec.driftX * at * (0.6 + 0.8 * r2) +
          swirl * math.sin(at * kTau / spec.swirlPeriod + ph);
      double y =
          r1 * spanY +
          spec.driftY * at * (0.6 + 0.8 * r2) +
          swirl * math.cos(at * kTau / spec.swirlPeriod * 0.8 + ph);
      x = (x % spanX + spanX) % spanX - margin;
      y = (y % spanY + spanY) % spanY - margin;
      final double light = compressLight(lightAt(beams, x, y));
      final double twinkle =
          1 -
          spec.twinkle * 0.5 * (1 + math.sin(at * 2.3 * (0.6 + r2) + r4 * 40));
      final double bright =
          (spec.ambient + spec.gain * light) * twinkle * weight * trebleLift;
      if (bright <= 0.01) continue;
      final double sz =
          (spec.sizeMin + (spec.sizeMax - spec.sizeMin) * r2 * r2) * h;
      if (front) {
        _batch.add(
          _spriteRect(_Sprite.bokeh),
          x * h,
          y * h,
          sz * 2,
          0,
          color.argb(clamp01(bright * 0.45)),
        );
      } else {
        _batch.add(
          _spriteRect(_Sprite.dot),
          x * h,
          y * h,
          sz * 2.4 * (1 + 0.2 * s.bloom),
          0,
          color.argb(clamp01(bright)),
        );
      }
    }
    _batch.flush(canvas, _sprites, Paint()..blendMode = BlendMode.plus);
  }

  /// 背景歌词：别的行的词碎片沿主光束缓缓漂过，越靠近光越清楚。
  void _paintEcho(
    Canvas canvas,
    Size size,
    LumiereFrame f,
    _ShotRig rig,
    List<ResolvedBeam> beams,
  ) {
    if (_echoWords.isEmpty || beams.isEmpty) return;
    final ResolvedBeam beam = beams.last.intensity > 0
        ? beams.last
        : beams.first;
    final double h = size.height;
    final double at = f.animTime;
    const double life = 7;
    const double every = 1.4;
    final int k0 = (at / every).floor();
    final Rgb color = f.palette.lit;
    for (int k = k0 - (life / every).ceil(); k <= k0; k++) {
      final double age = at - k * every;
      if (age < 0 || age > life) continue;
      final LumiereRng r = lumiereRng('$seed:${rig.shot.id}:echo:$k');
      final (LyricVisualizerLine echoLine, int echoFrom, List<String> word) =
          _echoWords[(r() * _echoWords.length).floor().clamp(
            0,
            _echoWords.length - 1,
          )];
      final double along = 0.08 + r() * 0.5 + 0.075 * age;
      final double side = (r() - 0.5) * 0.6;
      final double half =
          (beam.halfWidth + along * beam.tanSpread).abs() + 0.02;
      final double x = beam.ox + beam.dx * along - beam.dy * side * half;
      final double y = beam.oy + beam.dy * along + beam.dx * side * half;
      final double presence =
          smooth(age / 1.2) * (1 - smooth((age - life + 1.8) / 1.8));
      final double lit = compressLight(lightAt(beams, x, y));
      final double alpha = clamp01(
        presence * (0.05 + 0.4 * lit) * f.settings.echo * 0.6,
      );
      if (alpha <= 0.004) continue;
      final double px = rig.profile.echoSize * h * (0.25 + 0.5 * r());
      double width = 0;
      for (final String c in word) {
        width += atlas.advance(c);
      }
      double cx = x * h - width * px / 2;
      final double split = 0.05 * math.pow(age, 1.3);
      for (int i = 0; i < word.length; i++) {
        final int? slot = atlas.slotOf(word[i]);
        final double adv = atlas.advance(word[i]) * px;
        if (slot != null) {
          final double sx = (r() - 0.5) * split * px * 2;
          final double sy = (r() - 0.5) * split * px * 2;
          _glyph(
            slot,
            cx + adv / 2 + sx,
            y * h + sy,
            px,
            (r() - 0.5) * split,
            _tint(
              color,
              _keywordAt(f, echoLine, echoFrom + i),
              LumiereKeywordMix.echo,
            ).argb(alpha),
          );
        }
        cx += adv;
      }
    }
    _glyphBatch.flush(canvas);
  }

  /// 字 [slot] 加进字形批（按物理字号选档）。
  void _glyph(
    int slot,
    double cx,
    double cy,
    double px,
    double rotation,
    int argb,
  ) => _glyphBatch.add(
    atlas,
    slot,
    cx,
    cy,
    px,
    rotation,
    argb,
    devicePixelRatio: _devicePixelRatio,
  );

  // -------------------------------------------------------------------------
  // 歌词窗口
  // -------------------------------------------------------------------------

  void _paintWindow(
    Canvas canvas,
    Size size,
    LumiereFrame f,
    LumiereParagraph unit,
    _ShotRig cur,
    _ShotRig? prev,
    double handoff,
    List<ResolvedBeam> beams,
    double textFade,
  ) {
    final double w = size.width;
    final double h = size.height;
    final LumiereSettings s = f.settings;
    final List<LyricVisualizerLine> unitLines = <LyricVisualizerLine>[
      for (final int i in unit.lineIndices) runtime.lines[i],
    ];
    if (unitLines.isEmpty) return;
    final LumiereProfile a = cur.profile;
    final LumiereProfile b = prev?.profile ?? a;
    final double k = handoff;
    final double rcx = lerpD(b.region.cx, a.region.cx, k) * w;
    final double rcy = lerpD(b.region.cy, a.region.cy, k) * h;
    final double rw = lerpD(b.region.w, a.region.w, k) * w;
    final double rh = lerpD(b.region.h, a.region.h, k) * h;
    double hero = lerpD(b.heroSize, a.heroSize, k) * h * f.fontScale;
    hero = math.min(hero, rw / 3.2);
    final WindowTypography typography = k < 0.5 ? b.typography : a.typography;
    final int focus = math.max(0, focusOf(unitLines, f.time));
    final bool vertical =
        typography == WindowTypography.vertical && lineIsCjk(unitLines[focus]);
    final List<LineShape> shapes = <LineShape>[];
    final List<GlyphRandoms> randoms = <GlyphRandoms>[];
    for (int i = 0; i < unitLines.length; i++) {
      final LyricVisualizerLine line = unitLines[i];
      final int gi = unit.lineIndices[i];
      final bool v =
          vertical ||
          (typography == WindowTypography.crossed &&
              i != focus &&
              lineIsCjk(line));
      final String key = '$v:${hero.round()}:${rw.round()}:${rh.round()}';
      final (String, LineShape)? cached = _shapes[gi];
      if (cached != null && cached.$1 == key) {
        shapes.add(cached.$2);
      } else {
        final List<double> scales = _scales.putIfAbsent(
          gi,
          () => glyphScalesOf(line, seed),
        );
        final LineShape shape = v
            ? shapeVertical(line, scales, rh / hero)
            : shapeHorizontal(line, atlas.advance, scales, rw / hero);
        _shapes[gi] = (key, shape);
        shapes.add(shape);
      }
      randoms.add(
        _randoms.putIfAbsent(
          gi,
          () => GlyphRandoms('$seed:$gi:glyphs', line.glyphs.length),
        ),
      );
    }
    final List<GlyphPlacement> glyphs = layoutWindow(
      WindowInput(
        lines: unitLines,
        shapes: shapes,
        randoms: randoms,
        time: f.time,
        animTime: f.animTime,
        motion: f.motion,
        typography: typography,
        regionCx: rcx,
        regionCy: rcy,
        regionW: rw,
        regionH: rh,
        heroPx: hero,
        neighbors: s.neighbors,
        unlitAlpha: s.unlitOpacity,
        decay: a.decay,
        decayGain: s.decay,
        trails: !s.hideTrails && f.motion,
        curvedSlides: s.trails,
      ),
      vertical: vertical,
    );
    if (glyphs.isEmpty) return;
    final LumierePalette pal = f.palette;
    // 当前行脚下的一团光斑
    if (!s.textOnly) {
      _batch.add(
        _spriteRect(_Sprite.dot),
        rcx,
        rcy,
        hero * 10,
        0,
        pal.light.argb(0.07 * textFade * s.lightIntensity.clamp(0, 1.5)),
      );
    }
    // 轨迹线
    if (!s.hideTrails && f.motion) {
      final Paint track = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..blendMode = BlendMode.plus;
      for (final GlyphPlacement g in glyphs) {
        final List<double>? xs = g.trackX;
        final List<double>? ys = g.trackY;
        if (xs == null || ys == null || g.flying <= 0) continue;
        final Path p = Path()..moveTo(xs.first, ys.first);
        for (int i = 1; i < xs.length; i++) {
          p.lineTo(xs[i], ys[i]);
        }
        track.color = pal.lit.toColor(0.3 * g.flying * textFade);
        canvas.drawPath(p, track);
      }
    }
    // 辉光（文字辉光）与星芒
    final List<double> illum = <double>[
      for (final GlyphPlacement g in glyphs)
        compressLight(lightAt(beams, g.x / h, g.y / h)),
    ];
    if (s.textBloom > 0) {
      for (int i = 0; i < glyphs.length; i++) {
        final GlyphPlacement g = glyphs[i];
        final Rgb? kw = _keywordAt(f, g.line, g.glyphIndex);
        final double a0 =
            g.lit *
            (0.03 + 0.14 * illum[i] + 0.08 * g.flash) *
            s.textBloom *
            g.alpha *
            textFade *
            (kw == null ? 1 : kLumiereKeywordHaloGain);
        if (a0 > 0.003) {
          _batch.add(
            _spriteRect(_Sprite.dot),
            g.x,
            g.y,
            g.size * 2.6,
            0,
            _tint(pal.lit, kw, LumiereKeywordMix.halo).argb(clamp01(a0)),
          );
        }
        if (f.motion && g.flash > 0.05) {
          _batch.add(
            _spriteRect(_Sprite.star),
            g.x,
            g.y,
            g.size * 1.8,
            0,
            (kw == null
                    ? pal.lit.mix(kWhite, 0.5)
                    : lumiereKeywordLight(
                        pal.lit,
                        kw,
                        LumiereKeywordMix.star,
                      ).mix(kWhite, kLumiereKeywordStarWhite))
                .argb(clamp01(g.flash * 0.55 * g.alpha * textFade)),
          );
        }
      }
    }
    _batch.flush(canvas, _sprites, Paint()..blendMode = BlendMode.plus);
    // 字
    final double unlitAlpha = s.unlitOpacity;
    for (int i = 0; i < glyphs.length; i++) {
      final GlyphPlacement g = glyphs[i];
      final int? slot = atlas.slotOf(g.char);
      if (slot == null) continue;
      final double revealed = math.min(
        1,
        unlitAlpha + illum[i] * 0.45 + g.flying * 0.4,
      );
      final double heat = g.flash;
      final double alpha =
          g.alpha *
          textFade *
          (revealed * (1 - g.lit) +
              g.lit *
                  math.min(
                    1,
                    0.55 + 0.4 * heat + 0.3 * g.flying + 0.3 * illum[i],
                  ));
      if (alpha <= 0.003) continue;
      final Rgb lit = _tint(
        pal.lit,
        _keywordAt(f, g.line, g.glyphIndex),
        LumiereKeywordMix.glyph,
      );
      final Rgb color = pal.unlit.mix(lit, g.lit).mix(kWhite, 0.3 * heat);
      _glyph(slot, g.x, g.y, g.size, g.rotation, color.argb(clamp01(alpha)));
    }
    _glyphBatch.flush(canvas);
    // 十字爆闪
    final BurstSpec? burst = a.burst;
    if (burst != null && f.motion && !s.textOnly) {
      _paintBursts(canvas, f, burst, unitLines, focus, glyphs, hero);
    }
  }

  void _paintBursts(
    Canvas canvas,
    LumiereFrame f,
    BurstSpec burst,
    List<LyricVisualizerLine> unitLines,
    int focus,
    List<GlyphPlacement> glyphs,
    double hero,
  ) {
    final LyricVisualizerLine line = unitLines[focus];
    final double t = f.time;
    final LumiereRng r = lumiereRng('$seed:${line.position}:burst');
    int shown = 0;
    int visible = 0;
    final List<GlyphPlacement> current = glyphs
        .where((GlyphPlacement g) => g.current)
        .toList();
    for (int g = 0; g < line.glyphs.length && shown < 14; g++) {
      final LyricVisualizerGlyph glyph = line.glyphs[g];
      final double roll = r();
      if (glyph.isSpace) continue;
      final int vi = visible++;
      if ((vi + burst.offset) % math.max(1, burst.every) != 0 ||
          roll > burst.density + 0.25) {
        continue;
      }
      final double at = burst.mode == BurstMode.sung
          ? glyph.startMs / 1000
          : line.startMs / 1000 + vi * 0.07;
      final double age = t - at;
      if (age < 0 || age > 0.6 || vi >= current.length) continue;
      final GlyphPlacement p = current[vi];
      final double alpha = math.exp(-age / 0.15) * 0.9;
      final double sz = hero * burst.size * 0.5 * (0.6 + age);
      _batch.add(
        _spriteRect(_Sprite.star),
        p.x,
        p.y,
        sz,
        0,
        _burstColor(
          burst.tint.times(f.palette.lit.mix(kWhite, 0.5)),
          f.palette.lit,
          _keywordAt(f, line, g),
        ).argb(clamp01(alpha)),
      );
      shown++;
    }
    _batch.flush(canvas, _sprites, Paint()..blendMode = BlendMode.plus);
  }

  // -------------------------------------------------------------------------
  // 画框与片尾卡
  // -------------------------------------------------------------------------

  void _paintOverlayFrame(Canvas canvas, Size size, LumiereFrame f) {
    final double w = size.width;
    final double h = size.height;
    final double unit = math.min(w, h);
    final double arm = unit * 0.045;
    final double inset = unit * 0.05;
    final Paint p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = f.palette.lit.toColor(0.5);
    final Path path = Path();
    for (final (double x, double y, double sx, double sy)
        in <(double, double, double, double)>[
          (inset, inset, 1, 1),
          (w - inset, inset, -1, 1),
          (inset, h - inset, 1, -1),
          (w - inset, h - inset, -1, -1),
        ]) {
      path
        ..moveTo(x, y + sy * arm)
        ..lineTo(x, y)
        ..lineTo(x + sx * arm, y);
    }
    // 两侧十字准星
    for (final double x in <double>[inset, w - inset]) {
      path
        ..moveTo(x - arm * 0.3, h / 2)
        ..lineTo(x + arm * 0.3, h / 2)
        ..moveTo(x, h / 2 - arm * 0.3)
        ..lineTo(x, h / 2 + arm * 0.3);
    }
    // 顶部刻度
    for (int i = -3; i <= 3; i++) {
      final double x = w / 2 + i * arm * 0.6;
      path
        ..moveTo(x, inset)
        ..lineTo(x, inset + (i == 0 ? arm * 0.4 : arm * 0.2));
    }
    canvas.drawPath(path, p);
  }

  void _paintCredits(Canvas canvas, Size size, LumiereFrame f, double e) {
    final double w = size.width;
    final double h = size.height;
    final String name = title!.trim();
    final List<String> chars = name.characters.toList();
    final Rgb color = f.palette.lit;
    double widthEm = 0;
    for (final String c in chars) {
      widthEm += atlas.advance(c);
    }
    final double px = math.min(h * 0.07, w * 0.8 / math.max(widthEm, 1));
    final double poster = smooth((e - 0.5) / 1.4);
    if (poster <= 0) return;
    final double step = math.min(0.14, 2.4 / math.max(chars.length, 1));
    double x = w / 2 - widthEm * px / 2;
    final double y = h * 0.44;
    for (int i = 0; i < chars.length; i++) {
      final double adv = atlas.advance(chars[i]) * px;
      final int? slot = atlas.slotOf(chars[i]);
      final double a = smooth((e - 1.5 - i * step) / 0.4);
      if (slot != null && a > 0) {
        _glyph(slot, x + adv / 2, y + (1 - a) * px * 0.3, px, 0, color.argb(a));
      }
      x += adv;
    }
    final double after = 1.5 + chars.length * step;
    for (final (String? text, double scale, double dy, double delay)
        in <(String?, double, double, double)>[
          (artist, 0.42, 1.3, 0),
          (album, 0.34, 1.95, 0.3),
        ]) {
      final String? v = text?.trim();
      if (v == null || v.isEmpty) continue;
      final List<String> cs = v.characters.toList();
      final double sp = px * scale;
      double wEm = 0;
      for (final String c in cs) {
        wEm += atlas.advance(c);
      }
      final double a = smooth((e - after - delay) / 0.8) * 0.8;
      if (a <= 0) continue;
      double cx = w / 2 - wEm * sp / 2;
      for (final String c in cs) {
        final double adv = atlas.advance(c) * sp;
        final int? slot = atlas.slotOf(c);
        if (slot != null) {
          _glyph(
            slot,
            cx + adv / 2,
            y + px * dy,
            sp,
            0,
            f.palette.unlit.argb(a),
          );
        }
        cx += adv;
      }
    }
    _glyphBatch.flush(canvas);
    // 量角器光环 + 取景框
    final double aspect = w / h;
    final LineArtSpec art = mergeArt(<LineArtSpec>[
      protractorHalo(cx: aspect * 0.5, cy: 0.44, radius: 0.3, alpha: 0.4),
      viewfinderFrame(
        aspect: aspect,
        left: 0.12,
        top: 0.28,
        right: 0.88,
        bottom: 0.66,
        delay: 0.1,
        alpha: 0.3,
      ),
    ]);
    final Paint stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (final LinePath path in art.paths) {
      final double p = smooth(
        ((e - 0.5) / 3 - path.delay) / math.max(path.span, 0.01),
      );
      if (p <= 0 || path.points.length < 2) continue;
      stroke.color = color.toColor(clamp01(path.alpha * poster * 0.7));
      canvas.drawPath(_partialPath(path, p, h), stroke);
    }
  }
}
