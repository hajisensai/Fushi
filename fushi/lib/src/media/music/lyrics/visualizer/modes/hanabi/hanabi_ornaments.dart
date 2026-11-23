/// MG 装饰件：一比一移植 folia `hanabi/mg/ornamentKit.ts`（布点 / 取色 / 时序）、`ornamentShapes.ts`
/// （圆环、集中线、轨道、角括号、虚线圆、同心方框、旭日放射、印章、网点）、`ornamentParticles.ts`
/// （四角星闪、＋号、彩纸、樱花瓣、三角碎片、速度线、箭头、字边光点）、`ornamentLines.ts`（锯齿线、波浪线、
/// 下划线、点线）与 `ornaments.ts`（可见时间窗）。
///
/// folia 的件是 Pixi 的 Graphics（白色几何 × tint）与共享纹理的 Sprite（`mg/textures.ts` 的 Canvas 2D 程序纹理
/// × tint）；这里 Graphics 直接用 Canvas 描边 / 填充（Pixi 默认 butt 端点、miter 拐角、miterLimit 10），
/// Sprite 用同样画法生成的白色纹理图集，按 tint × alpha 做 modulate（等宽高的走 drawRawAtlas 一批画完，
/// 拉伸的单独变换后画）。每件只由时间决定。
library;

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/modes/hanabi/hanabi_catalog.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/hanabi/hanabi_color.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/hanabi/hanabi_math.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/hanabi/hanabi_text.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/hanabi/hanabi_text_layout.dart';

// ─── 共享纹理（folia mg/textures.ts，按 2× 渲染倍率画） ─────────────────────

/// 装饰件用到的精灵纹理（folia `HanabiTextures`）。
enum OrnamentTexture { dot, glow, star4, streak, ring, square, triangle, petal }

/// 白色纹理图集：每种纹理一格，格间留透明缝防双线性采样串色。
class OrnamentTextures {
  OrnamentTextures._(this.image, this.sources);

  final ui.Image image;
  final List<ui.Rect> sources;

  static OrnamentTextures? _instance;

  /// 进程内共享一份（与 folia「整个单元共享」一致）。
  static OrnamentTextures get instance => _instance ??= _create();

  /// folia `createHanabiTextures` 的 resolution（这里固定 2×，导出不糊）。
  static const double scale = 2;

  static ui.Color _white(double a) =>
      ui.Color.fromRGBO(255, 255, 255, a.clamp(0.0, 1.0));

  static int _px(double base) =>
      math.max(4, math.min(1024, (base * scale).round()));

  static OrnamentTextures _create() {
    // 尺寸照 textures.ts：dot 32、glow 96、star4 96、streak 16×128、ring 160、square 8、triangle 48、petal 32×44。
    final List<(int, int)> sizes = <(int, int)>[
      (_px(32), _px(32)),
      (_px(96), _px(96)),
      (_px(96), _px(96)),
      (_px(16), _px(128)),
      (_px(160), _px(160)),
      (_px(8), _px(8)),
      (_px(48), _px(48)),
      (_px(32), _px(44)),
    ];
    const int gap = 4;
    int x = gap;
    int height = 0;
    final List<ui.Rect> sources = <ui.Rect>[];
    for (final (int w, int h) in sizes) {
      sources.add(
        ui.Rect.fromLTWH(x.toDouble(), gap.toDouble(), w.toDouble(), h + 0.0),
      );
      x += w + gap;
      height = math.max(height, h);
    }
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final ui.Canvas canvas = ui.Canvas(recorder);
    for (int i = 0; i < sizes.length; i++) {
      final ui.Rect r = sources[i];
      canvas.save();
      canvas.translate(r.left, r.top);
      canvas.clipRect(ui.Rect.fromLTWH(0, 0, r.width, r.height));
      _drawTexture(canvas, OrnamentTexture.values[i], r.width, r.height);
      canvas.restore();
    }
    final ui.Picture picture = recorder.endRecording();
    final ui.Image image = picture.toImageSync(x, height + gap * 2);
    picture.dispose();
    return OrnamentTextures._(image, sources);
  }

  static void _drawTexture(
    ui.Canvas canvas,
    OrnamentTexture tex,
    double width,
    double height,
  ) {
    final ui.Rect all = ui.Rect.fromLTWH(0, 0, width, height);
    switch (tex) {
      case OrnamentTexture.dot:
        // 实心小圆：边缘留一像素的软边抗锯齿。
        final double r = width / 2;
        canvas.drawRect(
          all,
          ui.Paint()
            ..shader = ui.Gradient.radial(
              ui.Offset(r, r),
              r,
              <ui.Color>[_white(1), _white(1), _white(0)],
              <double>[0, math.max(0, 1 - 2 / r), 1],
            ),
        );
      case OrnamentTexture.glow:
        final double r = width / 2;
        canvas.drawRect(
          all,
          ui.Paint()
            ..shader = ui.Gradient.radial(
              ui.Offset(r, r),
              r,
              <ui.Color>[
                _white(1),
                _white(0.95),
                _white(0.55),
                _white(0.18),
                _white(0.05),
                _white(0),
              ],
              const <double>[0, 0.1, 0.22, 0.42, 0.7, 1],
            ),
        );
      case OrnamentTexture.star4:
        final double c = width / 2;
        final double r = width * 0.48;
        canvas.drawRect(
          all,
          ui.Paint()
            ..shader = ui.Gradient.radial(ui.Offset(c, c), r * 0.5, <ui.Color>[
              _white(0.9),
              _white(0),
            ]),
        );
        final double pinch = r * 0.1;
        canvas.drawPath(
          ui.Path()
            ..moveTo(c, c - r)
            ..quadraticBezierTo(c + pinch, c - pinch, c + r, c)
            ..quadraticBezierTo(c + pinch, c + pinch, c, c + r)
            ..quadraticBezierTo(c - pinch, c + pinch, c - r, c)
            ..quadraticBezierTo(c - pinch, c - pinch, c, c - r)
            ..close(),
          ui.Paint()..color = _white(1),
        );
      case OrnamentTexture.streak:
        // 纵向上亮下暗（不到零），再 destination-in 横向软边。
        canvas.saveLayer(all, ui.Paint());
        canvas.drawRect(
          all,
          ui.Paint()
            ..shader = ui.Gradient.linear(
              ui.Offset.zero,
              ui.Offset(0, height),
              <ui.Color>[_white(1), _white(0.6), _white(0.28)],
              const <double>[0, 0.6, 1],
            ),
        );
        canvas.drawRect(
          all,
          ui.Paint()
            ..blendMode = ui.BlendMode.dstIn
            ..shader = ui.Gradient.linear(
              ui.Offset.zero,
              ui.Offset(width, 0),
              <ui.Color>[
                _white(0),
                _white(0.85),
                _white(1),
                _white(0.85),
                _white(0),
              ],
              const <double>[0, 0.3, 0.5, 0.7, 1],
            ),
        );
        canvas.restore();
      case OrnamentTexture.ring:
        final double c = width / 2;
        final double line = math.max(1.5, width * 0.05);
        canvas.drawCircle(
          ui.Offset(c, c),
          c - line,
          ui.Paint()
            ..style = ui.PaintingStyle.stroke
            ..strokeWidth = line
            ..color = _white(1),
        );
      case OrnamentTexture.square:
        canvas.drawRect(all, ui.Paint()..color = _white(1));
      case OrnamentTexture.triangle:
        final double c = width / 2;
        final double r = width * 0.48;
        final ui.Path path = ui.Path();
        for (int i = 0; i < 3; i++) {
          final double a = -math.pi / 2 + (i * math.pi * 2) / 3;
          final double px = c + math.cos(a) * r;
          final double py = c + math.sin(a) * r + r * 0.12;
          if (i == 0) {
            path.moveTo(px, py);
          } else {
            path.lineTo(px, py);
          }
        }
        path.close();
        canvas.drawPath(path, ui.Paint()..color = _white(1));
      case OrnamentTexture.petal:
        final double cx = width / 2;
        final double top = height * 0.06;
        final double bottom = height * 0.96;
        final double notch = height * 0.16;
        canvas.drawPath(
          ui.Path()
            ..moveTo(cx, bottom)
            ..cubicTo(
              cx - width * 0.62,
              height * 0.62,
              cx - width * 0.5,
              top,
              cx - width * 0.14,
              top,
            )
            ..lineTo(cx, top + notch)
            ..lineTo(cx + width * 0.14, top)
            ..cubicTo(
              cx + width * 0.5,
              top,
              cx + width * 0.62,
              height * 0.62,
              cx,
              bottom,
            )
            ..close(),
          ui.Paint()..color = _white(1),
        );
    }
  }
}

/// 一帧里装饰件的画笔：等宽高的精灵攒成一批 drawRawAtlas（保持绘制次序：画几何前先 flush）。
class OrnamentCanvas {
  OrnamentCanvas(this._canvas) : _tex = OrnamentTextures.instance;

  final ui.Canvas _canvas;
  final OrnamentTextures _tex;
  final List<double> _xf = <double>[];
  final List<double> _rects = <double>[];
  final List<int> _colors = <int>[];

  /// 画几何用的 Canvas（先把攒着的精灵画掉，保持 Pixi 子节点的先后）。
  ui.Canvas get canvas {
    flush();
    return _canvas;
  }

  static int _argb(int rgb, double alpha) =>
      (((clamp01(alpha) * 255).round()) << 24) | (rgb & 0xFFFFFF);

  /// 一个居中锚点的精灵（Pixi `Sprite`：anchor 0.5、width / height、rotation、alpha、tint）。
  void sprite(
    OrnamentTexture tex,
    double x,
    double y,
    double width,
    double height,
    double rotation,
    double alpha,
    int tint,
  ) {
    if (alpha <= 0.002 || width.abs() <= 1e-3 || height.abs() <= 1e-3) return;
    if (tex == OrnamentTexture.square) {
      // 白方块拉伸 = 硬边矩形：直接画矩形（纹理双线性放大会把边糊开）。
      final ui.Canvas c = canvas;
      c.save();
      c.translate(x, y);
      if (rotation != 0) c.rotate(rotation);
      c.drawRect(
        ui.Rect.fromCenter(
          center: ui.Offset.zero,
          width: width.abs(),
          height: height.abs(),
        ),
        ui.Paint()..color = rgbColor(tint, alpha),
      );
      c.restore();
      return;
    }
    final ui.Rect src = _tex.sources[tex.index];
    final double sx = width / src.width;
    final double sy = height / src.height;
    if ((sx - sy).abs() <= 1e-4 * math.max(sx.abs(), sy.abs())) {
      final double sc = sx * math.cos(rotation);
      final double ss = sx * math.sin(rotation);
      final double ax = src.width / 2;
      final double ay = src.height / 2;
      _xf
        ..add(sc)
        ..add(ss)
        ..add(x - sc * ax + ss * ay)
        ..add(y - ss * ax - sc * ay);
      _rects
        ..add(src.left)
        ..add(src.top)
        ..add(src.right)
        ..add(src.bottom);
      _colors.add(_argb(tint, alpha));
      return;
    }
    final ui.Canvas c = canvas;
    c.save();
    c.translate(x, y);
    if (rotation != 0) c.rotate(rotation);
    c.scale(sx, sy);
    c.drawImageRect(
      _tex.image,
      src,
      ui.Rect.fromCenter(
        center: ui.Offset.zero,
        width: src.width,
        height: src.height,
      ),
      ui.Paint()
        ..filterQuality = ui.FilterQuality.low
        ..colorFilter = ui.ColorFilter.mode(
          rgbColor(tint, alpha),
          ui.BlendMode.modulate,
        ),
    );
    c.restore();
  }

  void flush() {
    if (_colors.isEmpty) return;
    _canvas.drawRawAtlas(
      _tex.image,
      Float32List.fromList(_xf),
      Float32List.fromList(_rects),
      Int32List.fromList(_colors),
      ui.BlendMode.modulate,
      null,
      ui.Paint()..filterQuality = ui.FilterQuality.low,
    );
    _xf.clear();
    _rects.clear();
    _colors.clear();
  }
}

/// Pixi Graphics 的描边（白 × tint）：默认 butt 端点、miter 拐角、miterLimit 10。
ui.Paint _stroke(
  int color,
  double alpha,
  double width, {
  StrokeCap cap = StrokeCap.butt,
  StrokeJoin join = StrokeJoin.miter,
}) => ui.Paint()
  ..color = rgbColor(color, alpha)
  ..style = ui.PaintingStyle.stroke
  ..strokeWidth = width
  ..strokeCap = cap
  ..strokeJoin = join
  ..strokeMiterLimit = 10;

ui.Paint _fill(int color, double alpha) =>
    ui.Paint()..color = rgbColor(color, alpha);

// ─── 公共底座（ornamentKit.ts） ─────────────────────────────────────────

/// 装饰件的一个落点：中心、半宽半高、朝外的方向；glyph ≥ 0 时每帧跟着那个字走。
class OrnamentSite {
  OrnamentSite(
    this.x,
    this.y,
    this.w,
    this.h,
    this.angle, {
    this.glyph = -1,
    required this.start,
    this.hollow = false,
  });
  final double x;
  final double y;
  final double w;
  final double h;
  final double angle;
  final int glyph;
  final double start;
  final bool hollow;
}

/// 静止排好时的一个（非空白）字。
class OrnamentGlyph {
  const OrnamentGlyph(
    this.index,
    this.char,
    this.x,
    this.y,
    this.size,
    this.sungAt,
    this.sungEnd,
    this.landedAt,
  );
  final int index;
  final String char;
  final double x;
  final double y;
  final double size;
  final double sungAt;
  final double sungEnd;
  final double landedAt;
}

/// 装饰件的公共布点与时序。
class OrnamentKit {
  OrnamentKit({
    required this.spec,
    required this.palette,
    required this.width,
    required this.height,
    required String seed,
    required LayoutRect bounds,
    required this.anchorsAt,
    required double enterAt,
    required this.exitAt,
    required this.exitDuration,
    required double amount,
  }) : rng = hanabiRng(
         '$seed:ornament:${_kindKey(spec.kind)}:${_placementKey(spec.placement)}',
       ),
       start = enterAt + spec.delay,
       end = exitAt + math.max(0, exitDuration),
       cx = bounds.cx,
       cy = bounds.cy,
       hw = math.max(1, bounds.width / 2),
       hh = math.max(1, bounds.height / 2) {
    // 静止排好的字：先取入场时的 landedAt，再在全部落定之后（退场之前）取一次位置。
    final List<GlyphAnchor> initial = anchorsAt(enterAt);
    final double landed = initial.fold(
      enterAt,
      (double m, GlyphAnchor a) => math.max(m, a.landedAt),
    );
    final double settle = math.min(exitAt - 1e-3, landed + 0.05);
    final List<GlyphAnchor> settled = settle > enterAt
        ? anchorsAt(settle)
        : initial;
    _cached = settled;
    for (int i = 0; i < settled.length; i++) {
      final GlyphAnchor a = settled[i];
      if (a.blank) continue;
      glyphs.add(
        OrnamentGlyph(
          i,
          a.char,
          a.x,
          a.y,
          a.size,
          a.sungAt,
          a.sungEnd,
          a.landedAt,
        ),
      );
    }
    final List<double> sizes = glyphs.map((OrnamentGlyph g) => g.size).toList()
      ..sort();
    base = sizes.isNotEmpty
        ? sizes[sizes.length ~/ 2]
        : math.max(
            12,
            math.max(math.min(hw, hh) * 0.8, math.min(width, height) * 0.06),
          );
    size = base * math.max(0.1, spec.scale);
    if (glyphs.length > 1) {
      final List<double> xs = glyphs.map((OrnamentGlyph g) => g.x).toList();
      final List<double> ys = glyphs.map((OrnamentGlyph g) => g.y).toList();
      vertical =
          ys.reduce(math.max) - ys.reduce(math.min) >
          (xs.reduce(math.max) - xs.reduce(math.min)) * 1.3;
    }
    _sung = glyphs.map((OrnamentGlyph g) => g.sungAt).toList()..sort();
    factor = math.max(0, amount) * (0.35 + 0.9 * clamp01(spec.density));
    firstSung = glyphs.fold(
      double.infinity,
      (double m, OrnamentGlyph g) => math.min(m, g.sungAt),
    );
  }

  final OrnamentSpec spec;
  final HanabiPalette palette;
  final double width;
  final double height;
  final HanabiRng rng;
  final List<GlyphAnchor> Function(double time) anchorsAt;
  final double exitAt;
  final double exitDuration;

  /// 入场开始（enterAt + delay）与完全退场的时刻。
  final double start;
  final double end;

  /// 字组包围盒的中心与半宽半高。
  final double cx;
  final double cy;
  final double hw;
  final double hh;
  final List<OrnamentGlyph> glyphs = <OrnamentGlyph>[];

  /// 静止时字号的中位数（未乘 spec.scale）与参考尺寸（已乘）。
  late final double base;
  late final double size;
  bool vertical = false;
  late final double factor;
  late final double firstSung;
  late final List<double> _sung;
  double _cachedTime = double.nan;
  List<GlyphAnchor> _cached = const <GlyphAnchor>[];

  /// base × 密度 × 数量倍率（至少 min，倍率为 0 时为 0）。
  int count(double baseCount, [int min = 1]) =>
      factor <= 0 ? 0 : math.max(min, (baseCount * factor).round());

  int _pick(List<int> list, int i, int fallback) => list.isEmpty
      ? fallback
      : list[((i % list.length) + list.length) % list.length];

  int color(int i) => switch (spec.color) {
    OrnamentColor.spark => _pick(palette.sparks, i, palette.accent),
    OrnamentColor.block => _pick(palette.blocks, i, palette.accent),
    OrnamentColor.paper => palette.paper,
    OrnamentColor.glow => palette.glow,
    OrnamentColor.accent => palette.accent,
  };

  /// [scatter] = folia 的 `'scatter'` 模式（around 时散布避开字组）。
  List<OrnamentSite> sites(bool scatter, int maxGlyphSites) {
    final double pad = base * 0.35;
    switch (spec.placement) {
      case OrnamentPlacement.behind:
        return <OrnamentSite>[
          OrnamentSite(cx, cy, hw, hh, -math.pi / 2, start: start),
        ];
      case OrnamentPlacement.around:
        return <OrnamentSite>[
          OrnamentSite(
            cx,
            cy,
            hw + pad,
            hh + pad,
            -math.pi / 2,
            start: start,
            hollow: scatter,
          ),
        ];
      case OrnamentPlacement.corners:
        return <OrnamentSite>[
          for (int k = 0; k < 4; k++)
            OrnamentSite(
              cx + _cornerSigns[k].$1 * (hw + pad * 0.6),
              cy + _cornerSigns[k].$2 * (hh + pad * 0.6),
              base * 0.6,
              base * 0.6,
              math.atan2(_cornerSigns[k].$2, _cornerSigns[k].$1),
              start: start + k * 0.07,
            ),
        ];
      case OrnamentPlacement.lineStart:
        return <OrnamentSite>[
          vertical
              ? OrnamentSite(
                  cx,
                  cy - hh - pad,
                  base * 0.7,
                  base * 0.7,
                  -math.pi / 2,
                  start: start,
                )
              : OrnamentSite(
                  cx - hw - pad,
                  cy,
                  base * 0.7,
                  base * 0.7,
                  math.pi,
                  start: start,
                ),
        ];
      case OrnamentPlacement.lineEnd:
        return <OrnamentSite>[
          vertical
              ? OrnamentSite(
                  cx,
                  cy + hh + pad,
                  base * 0.7,
                  base * 0.7,
                  math.pi / 2,
                  start: start,
                )
              : OrnamentSite(
                  cx + hw + pad,
                  cy,
                  base * 0.7,
                  base * 0.7,
                  0,
                  start: start,
                ),
        ];
      case OrnamentPlacement.screen:
        return <OrnamentSite>[
          OrnamentSite(
            0,
            0,
            width * 0.55,
            height * 0.55,
            -math.pi / 2,
            start: start,
          ),
        ];
      case OrnamentPlacement.glyphs:
        if (glyphs.isEmpty) {
          return <OrnamentSite>[
            OrnamentSite(cx, cy, hw, hh, -math.pi / 2, start: start),
          ];
        }
        final int limit = math.max(1, math.min(glyphs.length, maxGlyphSites));
        return <OrnamentSite>[
          for (int i = 0; i < limit; i++)
            () {
              final OrnamentGlyph g =
                  glyphs[((i + 0.5) * glyphs.length / limit).floor()];
              return OrnamentSite(
                g.x,
                g.y,
                g.size * 0.55,
                g.size * 0.55,
                -math.pi / 2,
                glyph: g.index,
                start: math.max(start, g.sungAt),
              );
            }(),
        ];
    }
  }

  /// 此刻的字位置（同一时刻只取一次）。
  List<GlyphAnchor> anchors(double time) {
    if (time != _cachedTime) {
      _cachedTime = time;
      _cached = anchorsAt(time);
    }
    return _cached;
  }

  /// 布点此刻的位置（字上的点跟着字走）：(x, y, alpha, size)。
  (double, double, double, double) pos(
    OrnamentSite site,
    List<GlyphAnchor> anchors,
  ) {
    if (site.glyph >= 0 && site.glyph < anchors.length) {
      final GlyphAnchor a = anchors[site.glyph];
      return (a.x, a.y, a.alpha, a.size);
    }
    return (site.x, site.y, 1, math.max(site.w, site.h));
  }

  /// 退场进度 0..1（stagger 秒让不同件错开）。
  double exit(double time, [double stagger = 0]) {
    final double span = math.max(0.05, exitDuration);
    return clamp01((time - exitAt - stagger) / math.max(0.05, span - stagger));
  }

  /// 散布点（相对落点中心的偏移）。
  (double, double) scatter(OrnamentSite site) {
    if (!site.hollow) {
      return ((rng() * 2 - 1) * site.w, (rng() * 2 - 1) * site.h);
    }
    // 围绕：落在包围盒外的一圈里。
    final double ow = site.w + base * 1.3;
    final double oh = site.h + base * 1.0;
    for (int tries = 0; tries < 12; tries++) {
      final double x = (rng() * 2 - 1) * ow;
      final double y = (rng() * 2 - 1) * oh;
      if (x.abs() > site.w || y.abs() > site.h) return (x, y);
    }
    final double a = rng() * kTau;
    return (math.cos(a) * ow, math.sin(a) * oh);
  }

  /// 最近一个在 time 之前被唱到的字的时刻（没有则 −∞）。
  double lastSung(double time) {
    double result = double.negativeInfinity;
    for (final double at in _sung) {
      if (at > time) break;
      result = at;
    }
    return result;
  }

  bool get _oneShot => spec.placement == OrnamentPlacement.glyphs;

  bool get _big =>
      spec.placement == OrnamentPlacement.behind ||
      spec.placement == OrnamentPlacement.around ||
      spec.placement == OrnamentPlacement.screen;
}

const List<(double, double)> _cornerSigns = <(double, double)>[
  (-1, -1),
  (1, -1),
  (1, 1),
  (-1, 1),
];

/// folia OrnamentKind 的字符串（随机种子用）。
String _kindKey(OrnamentKind kind) => switch (kind) {
  OrnamentKind.dashCircle => 'dash-circle',
  OrnamentKind.dotsLine => 'dots-line',
  _ => kind.name,
};

/// folia OrnamentPlacement 的字符串（随机种子用）。
String _placementKey(OrnamentPlacement placement) => switch (placement) {
  OrnamentPlacement.lineStart => 'line-start',
  OrnamentPlacement.lineEnd => 'line-end',
  _ => placement.name,
};

typedef OrnamentPainter = void Function(OrnamentCanvas out, double time);

/// 一个装饰件（布点在构造时定好；folia `createOrnament`）。
class HanabiOrnament {
  HanabiOrnament(this.kit)
    : _paint = kit.factor <= 0 ? null : _builders[kit.spec.kind]!(kit) {
    // 跟字触发的件可能比 enterAt + delay 更早开始：以两者中较早的为窗口起点。
    _from = math.min(kit.start, kit.firstSung) - 0.05;
  }

  final OrnamentKit kit;
  final OrnamentPainter? _paint;
  late final double _from;

  void paint(ui.Canvas canvas, double time) {
    if (_paint == null || time < _from || time > kit.end) return;
    final OrnamentCanvas out = OrnamentCanvas(canvas);
    _paint(out, time);
    out.flush();
  }
}

final Map<OrnamentKind, OrnamentPainter Function(OrnamentKit kit)> _builders =
    <OrnamentKind, OrnamentPainter Function(OrnamentKit kit)>{
      OrnamentKind.ring: _ring,
      OrnamentKind.spokes: _spokes,
      OrnamentKind.sparkle: _sparkle,
      OrnamentKind.orbit: _orbit,
      OrnamentKind.chevrons: _chevrons,
      OrnamentKind.brackets: _brackets,
      OrnamentKind.cross: _cross,
      OrnamentKind.zigzag: _zigzag,
      OrnamentKind.wave: _wave,
      OrnamentKind.halftone: _halftone,
      OrnamentKind.confetti: _confetti,
      OrnamentKind.shards: _shards,
      OrnamentKind.dashCircle: _dashCircle,
      OrnamentKind.squares: _squares,
      OrnamentKind.streaks: _streaks,
      OrnamentKind.petals: _petals,
      OrnamentKind.stamp: _stamp,
      OrnamentKind.rays: _rays,
      OrnamentKind.underline: _underline,
      OrnamentKind.dotsLine: _dotsLine,
      OrnamentKind.glints: _glints,
    };

// ─── 形状类（ornamentShapes.ts） ────────────────────────────────────────

/// 落点的「大件」半径：behind / around 围住字组，其余是小件。
double _siteRadius(OrnamentPlacement placement, OrnamentSite site, double fb) {
  if (placement == OrnamentPlacement.behind) {
    return math.sqrt(site.w * site.w + site.h * site.h) * 0.8;
  }
  if (placement == OrnamentPlacement.around) {
    return math.sqrt(site.w * site.w + site.h * site.h) * 0.95;
  }
  if (placement == OrnamentPlacement.screen) {
    return math.min(site.w, site.h) * 0.75;
  }
  return math.max(site.w, fb) * 1.3;
}

/// 在 (x, y) 处按 Pixi 的 position / rotation / scale 变换后画。
void _at(
  ui.Canvas c,
  double x,
  double y,
  double rotation,
  double sx,
  double sy,
  void Function() draw,
) {
  c.save();
  c.translate(x, y);
  if (rotation != 0) c.rotate(rotation);
  if (sx != 1 || sy != 1) c.scale(sx, sy);
  draw();
  c.restore();
}

// ring：扩散的描边圆环。
OrnamentPainter _ring(OrnamentKit kit) {
  final bool oneShot = kit._oneShot;
  final int layers = oneShot ? 1 : math.min(3, kit.count(2.4, 1));
  final double line = math.max(1.5, kit.size * 0.055);
  final List<(OrnamentSite, double, int)> units = <(OrnamentSite, double, int)>[
    for (final (int si, OrnamentSite site) in kit.sites(false, 8).indexed)
      (
        site,
        _siteRadius(kit.spec.placement, site, kit.size * 0.5) *
            (oneShot ? 1.3 : 1),
        si,
      ),
  ];
  return (OrnamentCanvas o, double time) {
    final List<GlyphAnchor> anchors = kit.anchors(time);
    final ui.Canvas c = o.canvas;
    for (final (OrnamentSite site, double radius, int si) in units) {
      final (double px, double py, double pa, _) = kit.pos(site, anchors);
      final double e = time - site.start;
      for (int j = 0; j < layers; j++) {
        final double local = e - j * 0.09;
        final double x = kit.exit(time, j * 0.05);
        if (local < 0 || x >= 1) continue;
        double scale;
        double alpha;
        if (oneShot) {
          final double k = clamp01(local / 0.8);
          scale = 0.3 + 1.1 * easeOutExpo(k);
          alpha = math.pow(1 - k, 1.5).toDouble();
        } else {
          scale =
              lerpD(0.2, 1, easeOutBack(local / 0.55, 2.4)) *
              (1 + 0.025 * math.sin(kTau * (time * 0.5 + j / 3)));
          alpha = clamp01(local / 0.08);
          scale *= 1 - easeInBack(x, 2);
          alpha *= 1 - x;
        }
        if (!(alpha > 0.005 && scale > 0.001)) continue;
        final double s = math.max(0.001, scale);
        _at(c, px, py, 0, s, s, () {
          c.drawCircle(
            ui.Offset.zero,
            radius * (1 + 0.14 * j),
            _stroke(kit.color(si + j), alpha * pa, line * (j == 0 ? 1.6 : 0.8)),
          );
        });
      }
      if (!oneShot) {
        final double q = fract((e - 0.6) / 1.8);
        final double x = kit.exit(time);
        if (e > 0.6 && x < 1) {
          final double s = 1 + 0.55 * easeOutCubic(q);
          _at(c, px, py, 0, s, s, () {
            c.drawCircle(
              ui.Offset.zero,
              radius,
              _stroke(
                kit.color(si + 1),
                0.55 * (1 - q) * (1 - q) * (1 - x) * pa,
                line * 0.6,
              ),
            );
          });
        }
      }
    }
  };
}

class _Spoke {
  _Spoke(
    this.cos,
    this.sin,
    this.inner,
    this.angle,
    this.tint,
    this.length,
    this.thick,
    this.delay,
    this.salt,
  );
  final double cos;
  final double sin;
  final double inner;
  final double angle;
  final int tint;
  final double length;
  final double thick;
  final double delay;
  final double salt;
}

// spokes：集中线（streak 精灵）。
OrnamentPainter _spokes(OrnamentKit kit) {
  final bool oneShot = kit._oneShot;
  final bool big = kit._big;
  final double pad = kit.size * 0.45;
  final List<(OrnamentSite, List<_Spoke>)> units =
      <(OrnamentSite, List<_Spoke>)>[];
  for (final (int si, OrnamentSite site) in kit.sites(false, 6).indexed) {
    final int n = oneShot ? 8 : kit.count(big ? 28 : 10, 6);
    final List<_Spoke> spokes = <_Spoke>[];
    for (int i = 0; i < n; i++) {
      final double angle = kTau * i / n + (kit.rng() - 0.5) * (kTau / n) * 0.7;
      final double cos = math.cos(angle);
      final double sin = math.sin(angle);
      // 大件：内缘贴着字组的椭圆包络，线从字组外面向外放射。
      final double inner = big
          ? 1 /
                math.sqrt(
                  math.pow(cos / (site.w + pad), 2) +
                      math.pow(sin / (site.h + pad), 2),
                )
          : site.w * 1.1;
      final double length =
          kit.size * (oneShot ? 0.5 + kit.rng() * 0.5 : 0.7 + kit.rng() * 1.7);
      final double thick = math.max(1.2, kit.size * (0.035 + kit.rng() * 0.05));
      spokes.add(
        _Spoke(
          cos,
          sin,
          inner,
          angle + math.pi / 2,
          kit.color(si + i),
          length,
          thick,
          (i % 6) * 0.015,
          (si * 97 + i).toDouble(),
        ),
      );
    }
    units.add((site, spokes));
  }
  return (OrnamentCanvas o, double time) {
    final List<GlyphAnchor> anchors = kit.anchors(time);
    final double beat = (time * 12).floorToDouble();
    final double x = kit.exit(time);
    for (final (OrnamentSite site, List<_Spoke> spokes) in units) {
      final (double px, double py, double pa, _) = kit.pos(site, anchors);
      final double e = time - site.start;
      for (final _Spoke s in spokes) {
        final double local = e - s.delay;
        if (local < 0 || x >= 1) continue;
        final double grow = easeOutExpo(local / 0.25);
        // 一拍一格的抖动：漫画集中线的「颤」。
        final double jitter = 0.72 + 0.45 * mgHash01(beat, s.salt);
        double length = s.length * grow * jitter * (1 - x);
        double push = kit.size * 2.5 * easeInCubic(x);
        double alpha = (0.55 + 0.45 * mgHash01(beat + 7, s.salt)) * pa;
        if (oneShot) {
          final double k = clamp01((local - 0.3) / 0.35);
          push += kit.size * 0.8 * easeOutCubic(k);
          length *= 1 - k;
          alpha *= 1 - k;
        }
        if (!(length > 0.5 && alpha > 0.01)) continue;
        final double r = s.inner + push + length / 2;
        o.sprite(
          OrnamentTexture.streak,
          px + s.cos * r,
          py + s.sin * r,
          s.thick * (1 - x * 0.5),
          length,
          s.angle,
          alpha,
          s.tint,
        );
      }
    }
  };
}

class _OrbitDot {
  _OrbitDot(
    this.leader,
    this.tint,
    this.theta,
    this.omega,
    this.rx,
    this.ry,
    this.size,
    this.delay,
  );
  final bool leader;
  final int tint;
  final double theta;
  final double omega;
  final double rx;
  final double ry;
  final double size;
  final double delay;
}

// orbit：绕字组旋转的点阵（带一点纵深）。
OrnamentPainter _orbit(OrnamentKit kit) {
  final bool big = kit._big;
  const double tilt = -0.18;
  final List<
    (OrnamentSite, List<(double, double, int, double)>, List<_OrbitDot>)
  >
  units =
      <(OrnamentSite, List<(double, double, int, double)>, List<_OrbitDot>)>[];
  for (final (int si, OrnamentSite site) in kit.sites(false, 4).indexed) {
    final double rx = big ? site.w + kit.size * 0.5 : site.w * 1.5;
    final double ry = big ? site.h + kit.size * 0.6 : site.h * 0.8;
    // 每圈几列「车厢」：一颗领头的四角星 + 后面渐小的一串点，两圈反向转。
    final int trains = big ? math.max(2, math.min(6, kit.count(4, 2))) : 2;
    final int cars = big ? 5 : 3;
    final List<(double, double, int)> rings = <(double, double, int)>[
      (0.55, 1, trains),
      (-0.85, 1.2, math.max(1, trains - 1)),
    ];
    final List<(double, double, int, double)> paths =
        <(double, double, int, double)>[
          for (final (int r, (double, double, int) ring) in rings.indexed)
            (rx * ring.$2, ry * ring.$2, kit.color(si + r), r * 0.12),
        ];
    final List<_OrbitDot> dots = <_OrbitDot>[];
    for (final (int r, (double, double, int) ring) in rings.indexed) {
      for (int index = 0; index < ring.$3 * cars; index++) {
        final int train = index ~/ cars;
        final int car = index % cars;
        final bool leader = car == 0;
        dots.add(
          _OrbitDot(
            leader,
            kit.color(si + r + train),
            (kTau * train) / ring.$3 + r * 0.5 - ring.$1.sign * car * 0.11,
            ring.$1,
            rx * ring.$2,
            ry * ring.$2,
            kit.size * (leader ? 0.34 : 0.14 * (1 - car / (cars + 1))),
            train * 0.06 + car * 0.03 + r * 0.12,
          ),
        );
      }
    }
    units.add((site, paths, dots));
  }
  final double line = math.max(1, kit.size * 0.02);
  final double cosT = math.cos(tilt);
  final double sinT = math.sin(tilt);
  return (OrnamentCanvas o, double time) {
    final List<GlyphAnchor> anchors = kit.anchors(time);
    for (final (
          OrnamentSite site,
          List<(double, double, int, double)> paths,
          List<_OrbitDot> dots,
        )
        in units) {
      final (double px, double py, double pa, _) = kit.pos(site, anchors);
      final double e = time - site.start;
      final ui.Canvas c = o.canvas;
      for (final (double erx, double ery, int tint, double delay) in paths) {
        final double local = e - delay;
        final double x = kit.exit(time);
        if (!(local >= 0 && x < 1)) continue;
        final double s = math.max(
          0.001,
          easeOutBack(local / 0.5, 1.8) * (1 + 1.2 * easeInCubic(x)),
        );
        final double alpha = 0.3 * clamp01(local / 0.1) * (1 - x) * pa;
        _at(c, px, py, tilt, s, s, () {
          c.drawOval(
            ui.Rect.fromCenter(
              center: ui.Offset.zero,
              width: erx * 2,
              height: ery * 2,
            ),
            _stroke(tint, alpha, line),
          );
        });
      }
      for (final (int i, _OrbitDot d) in dots.indexed) {
        final double local = e - d.delay;
        final double x = kit.exit(time, (i % 8) * 0.02);
        if (local < 0 || x >= 1) continue;
        final double reach =
            springEase(local, 1.6, 5.5) * (1 + 1.2 * easeInCubic(x));
        final double theta =
            d.theta +
            d.omega * time -
            d.omega.sign * 2.2 * (1 - easeOutCubic(local / 0.9));
        final double ox = math.cos(theta) * d.rx * reach;
        final double oy = math.sin(theta) * d.ry * reach;
        // 椭圆下半圈在前、上半圈在后：后面的小一点、暗一点。
        final double near = 0.5 + 0.5 * math.sin(theta);
        final double s = d.size * (0.65 + 0.35 * near);
        o.sprite(
          d.leader ? OrnamentTexture.star4 : OrnamentTexture.dot,
          px + ox * cosT - oy * sinT,
          py + ox * sinT + oy * cosT,
          s,
          s,
          theta,
          clamp01(local / 0.05) * (0.45 + 0.55 * near) * (1 - x) * pa,
          d.tint,
        );
      }
    }
  };
}

/// 四个角：(sx, sy, rotation)：TL 0、TR π/2、BR π、BL 3π/2。
const List<(double, double, double)> _bracketCorners =
    <(double, double, double)>[
      (-1, -1, 0),
      (1, -1, math.pi / 2),
      (1, 1, math.pi),
      (-1, 1, math.pi * 1.5),
    ];

// brackets：「」角括号 / 四角取景框 / 跟着唱到的字跳的准星。
OrnamentPainter _brackets(OrnamentKit kit) {
  final OrnamentPlacement placement = kit.spec.placement;
  final double thick = math.max(2, kit.size * 0.08);
  final double pad = kit.size * 0.4;
  void corner(
    ui.Canvas c,
    double x,
    double y,
    double a,
    double b,
    double rotation,
    int color,
    double alpha,
  ) {
    _at(c, x, y, rotation, 1, 1, () {
      c.drawPath(
        ui.Path()
          ..moveTo(a, 0)
          ..lineTo(0, 0)
          ..lineTo(0, b),
        _stroke(color, alpha, thick, cap: StrokeCap.square),
      );
    });
  }

  if (placement == OrnamentPlacement.glyphs && kit.glyphs.isNotEmpty) {
    final double arm = kit.size * 0.28;
    final List<OrnamentGlyph> order = <OrnamentGlyph>[
      ...kit.glyphs,
    ]..sort((OrnamentGlyph p, OrnamentGlyph q) => p.sungAt.compareTo(q.sungAt));
    return (OrnamentCanvas o, double time) {
      final double x = kit.exit(time);
      int current = -1;
      for (int i = 0; i < order.length; i++) {
        if (order[i].sungAt <= time) current = i;
      }
      if (!(current >= 0 && time >= kit.start && x < 1)) return;
      final List<GlyphAnchor> anchors = kit.anchors(time);
      final OrnamentGlyph cur = order[current];
      final OrnamentGlyph prev = order[math.max(0, current - 1)];
      final GlyphAnchor? a = cur.index < anchors.length
          ? anchors[cur.index]
          : null;
      final GlyphAnchor? b = prev.index < anchors.length
          ? anchors[prev.index]
          : null;
      final double k = current == 0
          ? 1
          : easeOutBack((time - cur.sungAt) / 0.2, 1.8);
      final double px = lerpD(b?.x ?? prev.x, a?.x ?? cur.x, k);
      final double py = lerpD(b?.y ?? prev.y, a?.y ?? cur.y, k);
      final double half =
          lerpD(b?.size ?? prev.size, a?.size ?? cur.size, k) * 0.62;
      final double snap = 1 + 0.35 * math.exp(-(time - cur.sungAt) / 0.08);
      final ui.Canvas c = o.canvas;
      for (final (int ci, (double sx, double sy, double rot))
          in _bracketCorners.indexed) {
        corner(
          c,
          px + sx * half * snap * (1 + x),
          py + sy * half * snap * (1 + x),
          arm,
          arm,
          rot,
          kit.color(ci),
          (1 - x) * (a?.alpha ?? 1),
        );
      }
    };
  }

  double rw = kit.hw + pad;
  double rh = kit.hh + pad * 0.7;
  double cx = kit.cx;
  double cy = kit.cy;
  if (placement == OrnamentPlacement.screen) {
    rw = kit.width * 0.42;
    rh = kit.height * 0.38;
    cx = 0;
    cy = 0;
  }
  List<(double, double, double)> chosen = _bracketCorners;
  double armA = math.min(rw * 0.35, kit.size * 0.9);
  double armB = armA;
  if (placement == OrnamentPlacement.behind ||
      placement == OrnamentPlacement.around ||
      placement == OrnamentPlacement.lineStart ||
      placement == OrnamentPlacement.lineEnd) {
    // 「」：横臂短、竖臂长（竖排时反过来）。
    chosen = placement == OrnamentPlacement.lineStart
        ? <(double, double, double)>[_bracketCorners[0]]
        : placement == OrnamentPlacement.lineEnd
        ? <(double, double, double)>[_bracketCorners[2]]
        : <(double, double, double)>[_bracketCorners[0], _bracketCorners[2]];
    armA = kit.vertical ? rw * 1.2 : kit.size * 0.55;
    armB = kit.vertical ? kit.size * 0.55 : rh * 1.2;
  }
  final List<(double, double, double, double, double, int, double)> pieces =
      <(double, double, double, double, double, int, double)>[
        for (final (int k, (double sx, double sy, double rot))
            in chosen.indexed)
          () {
            // 旋转过的角：臂长按旋转后的方向交换。
            final bool swap = k.isOdd && chosen.length == 4;
            return (
              sx,
              sy,
              rot,
              swap ? armB : armA,
              swap ? armA : armB,
              kit.color(k),
              k * 0.06,
            );
          }(),
      ];
  return (OrnamentCanvas o, double time) {
    final double beat = math.exp(-(time - kit.lastSung(time)) / 0.12);
    final ui.Canvas c = o.canvas;
    for (final (
          int k,
          (
            double sx,
            double sy,
            double rot,
            double a,
            double b,
            int color,
            double delay,
          ),
        )
        in pieces.indexed) {
      final double local = time - kit.start - delay;
      final double x = kit.exit(time, k * 0.04);
      if (local < 0 || x >= 1) continue;
      double off = (1 - easeOutBack(local / 0.45, 2.6)) * kit.size * 1.4;
      off +=
          kit.size * 0.06 * math.sin(kTau * time * 0.7) -
          kit.size * 0.15 * beat;
      off += easeInCubic(x) * kit.size * 2;
      // 入场前 0.12 秒像信号不稳一样闪两下。
      final double flick = local < 0.12
          ? ((local * 40).floor() % 2 == 0 ? 1 : 0.25)
          : 1;
      corner(
        c,
        cx + sx * (rw + off),
        cy + sy * (rh + off),
        a,
        b,
        rot,
        color,
        flick * (1 - x),
      );
    }
  };
}

// dash-circle：虚线圆 + 点线内圈，反向旋转。
OrnamentPainter _dashCircle(OrnamentKit kit) {
  final bool oneShot = kit._oneShot;
  final double line = math.max(1.5, kit.size * 0.05);
  final List<(OrnamentSite, ui.Path, ui.Path, int, int)> units =
      <(OrnamentSite, ui.Path, ui.Path, int, int)>[];
  for (final (int si, OrnamentSite site) in kit.sites(false, 6).indexed) {
    final double r1 = oneShot
        ? site.w * 1.35
        : _siteRadius(kit.spec.placement, site, kit.size * 0.6) * 1.05;
    final double r2 = r1 * 0.84;
    final ui.Path outer = ui.Path();
    final int dashes = r1 > kit.size * 2 ? 36 : 18;
    final ui.Rect oval = ui.Rect.fromCircle(center: ui.Offset.zero, radius: r1);
    for (int k = 0; k < dashes; k++) {
      final double a0 = (k * kTau) / dashes;
      outer.addArc(oval, a0, (kTau / dashes) * 0.55);
    }
    final ui.Path inner = ui.Path();
    final int dots = dashes * 2;
    for (int k = 0; k < dots; k++) {
      final double a = (k * kTau) / dots;
      inner.addOval(
        ui.Rect.fromCircle(
          center: ui.Offset(math.cos(a) * r2, math.sin(a) * r2),
          radius: line * 0.7,
        ),
      );
    }
    units.add((site, outer, inner, kit.color(si), kit.color(si + 1)));
  }
  return (OrnamentCanvas o, double time) {
    final List<GlyphAnchor> anchors = kit.anchors(time);
    final double x = kit.exit(time);
    final ui.Canvas c = o.canvas;
    for (final (OrnamentSite site, ui.Path outer, ui.Path inner, int c0, int c1)
        in units) {
      final (double px, double py, double pa, _) = kit.pos(site, anchors);
      final double local = time - site.start;
      // 贴字时只陪着这个字转一会儿（1.4 秒后淡出），不在整行上堆满圆。
      final double fadeOut = oneShot ? clamp01((local - 1) / 0.4) : 0;
      if (!(local >= 0 && x < 1 && fadeOut < 1)) continue;
      final double scale =
          lerpD(0.55, 1, easeOutBack(local / 0.5, 2)) *
          (1 + 0.3 * easeInCubic(x));
      final double spinIn = (1 - easeOutCubic(local / 0.9)) * math.pi * 1.2;
      final double alpha = clamp01(local / 0.1) * (1 - x) * (1 - fadeOut) * pa;
      _at(c, px, py, 0.35 * time + spinIn + x * x * 3, scale, scale, () {
        c.drawPath(outer, _stroke(c0, alpha, line, cap: StrokeCap.round));
      });
      // 内圈一拍一格地转。
      final double innerRot =
          -beatSteps((time - site.start) / 0.5) * (math.pi / 18) - spinIn;
      _at(c, px, py, innerRot, scale, scale, () {
        c.drawPath(inner, _fill(c1, alpha * 0.85));
      });
    }
  };
}

// squares：同心方框，交错旋转。
OrnamentPainter _squares(OrnamentKit kit) {
  final bool big = kit._big;
  final bool oneShot = kit._oneShot;
  final int layers = math.min(4, math.max(2, kit.count(3.2, 2)));
  final double line = math.max(1.5, kit.size * 0.05);
  final double pad = kit.size * 0.35;
  final List<(OrnamentSite, List<(double, double, int)>)> units =
      <(OrnamentSite, List<(double, double, int)>)>[
        for (final (int si, OrnamentSite site) in kit.sites(false, 5).indexed)
          (
            site,
            <(double, double, int)>[
              for (int j = 0; j < layers; j++)
                () {
                  // 大件跟着字组的长宽比，只小角度来回摆；小件是正方形，一拍转 45°。
                  final double w = big
                      ? site.w + pad * (j + 1)
                      : site.w * (1.1 + 0.3 * j);
                  final double h = big ? site.h + pad * (j + 1) : w;
                  return (w, h, kit.color(si + j));
                }(),
            ],
          ),
      ];
  return (OrnamentCanvas o, double time) {
    final List<GlyphAnchor> anchors = kit.anchors(time);
    final ui.Canvas c = o.canvas;
    for (final (OrnamentSite site, List<(double, double, int)> squares)
        in units) {
      final (double px, double py, double pa, _) = kit.pos(site, anchors);
      for (final (int j, (double w, double h, int tint)) in squares.indexed) {
        final double dir = j.isEven ? 1 : -1;
        final double local = time - site.start - j * 0.07;
        // 贴字时唱完就转着收掉（一拍半），退场时整组收掉。
        final double x = math.max(
          kit.exit(time, (layers - 1 - j) * 0.05),
          oneShot ? clamp01((local - 1.1) / 0.4) : 0,
        );
        if (local < 0 || x >= 1) continue;
        final double beats = local / 1.0 + j * 0.25;
        double rotation;
        if (big) {
          final double phase = beats.floor() % 2 == 0 ? 1 : -1;
          rotation =
              dir *
              0.09 *
              lerpD(-phase, phase, easeOutBack(fract(beats) / 0.35, 2));
        } else {
          rotation = dir * beatSteps(beats) * (math.pi / 4);
        }
        final double scale =
            easeOutBack(local / 0.4, 2.2) * (1 - easeInBack(x, 2));
        if (!(scale.abs() > 0.001)) continue;
        final double s = math.max(0.001, scale);
        final double alpha = clamp01(local / 0.06) * (1 - x) * pa;
        _at(c, px, py, rotation, s, s, () {
          c.drawRect(
            ui.Rect.fromLTRB(-w, -h, w, h),
            _stroke(tint, alpha, line * (j == 0 ? 1.5 : 1)),
          );
        });
      }
    }
  };
}

// rays：字组背后的放射扇形（旭日）。
OrnamentPainter _rays(OrnamentKit kit) {
  final bool oneShot = kit._oneShot;
  final OrnamentPlacement placement = kit.spec.placement;
  final bool faint =
      placement == OrnamentPlacement.behind ||
      placement == OrnamentPlacement.screen;
  final List<(OrnamentSite, ui.Path, int, double)> units =
      <(OrnamentSite, ui.Path, int, double)>[];
  for (final (int si, OrnamentSite site) in kit.sites(false, 3).indexed) {
    final double radius = placement == OrnamentPlacement.screen
        ? math.sqrt(kit.width * kit.width + kit.height * kit.height) * 0.6
        : placement == OrnamentPlacement.behind ||
              placement == OrnamentPlacement.around
        ? math.sqrt(site.w * site.w + site.h * site.h) * 1.7
        : site.w * 2.4;
    final int wedges = oneShot ? 8 : math.max(6, kit.count(12, 6));
    final ui.Path g = ui.Path();
    for (int k = 0; k < wedges; k++) {
      final double a0 = (k * kTau) / wedges;
      final double a1 = a0 + (kTau / wedges) * 0.5;
      g
        ..moveTo(0, 0)
        ..lineTo(math.cos(a0) * radius, math.sin(a0) * radius)
        ..lineTo(math.cos(a1) * radius, math.sin(a1) * radius)
        ..close();
    }
    units.add((site, g, kit.color(si), si.isEven ? 1 : -1));
  }
  final double baseAlpha = faint ? 0.26 : 0.45;
  return (OrnamentCanvas o, double time) {
    final List<GlyphAnchor> anchors = kit.anchors(time);
    final double x = kit.exit(time);
    final double tick = math.exp(-(time - kit.lastSung(time)) / 0.15);
    final ui.Canvas c = o.canvas;
    for (final (OrnamentSite site, ui.Path g, int tint, double dir) in units) {
      final (double px, double py, double pa, _) = kit.pos(site, anchors);
      final double local = time - site.start;
      if (local < 0 || x >= 1 || (oneShot && local > 1.2)) continue;
      double scale =
          easeOutBack(local / 0.6, 1.6) *
          (1 + 0.03 * math.sin(kTau * time * 0.8) + 0.04 * tick) *
          (1 + 0.25 * x);
      double alpha = baseAlpha * clamp01(local / 0.1) * (1 - x);
      if (oneShot) {
        final double k = clamp01((local - 0.5) / 0.7);
        alpha *= 1 - k;
        scale *= 1 + 0.3 * k;
      }
      final double s = math.max(0.001, scale);
      final double rotation =
          dir *
          (time * 0.12 - 0.8 * (1 - easeOutCubic(local / 0.8)) + x * x * 1.5);
      _at(c, px, py, rotation, s, s, () {
        c.drawPath(g, _fill(tint, alpha * pa));
      });
    }
  };
}

const List<String> _stampChars = <String>['花', '火', '夏', '夜', '空', '光'];

/// folia `STAMP_FONT`（明朝系，字重 900）。
const List<String> _stampFonts = <String>[
  'Hiragino Mincho ProN',
  'Yu Mincho',
  'Noto Serif JP',
  'Noto Serif SC',
  'Songti SC',
  'serif',
];

// stamp：圆框印章里一个字，盖下去时回弹。
OrnamentPainter _stamp(OrnamentKit kit) {
  final OrnamentPlacement placement = kit.spec.placement;
  final double pad = kit.size * 0.6;
  double radius = kit.size * 0.72;
  double x0;
  double y0;
  bool faint = false;
  final int corner = (kit.rng() * 4).floor();
  final double sx = corner == 0 || corner == 3 ? -1 : 1;
  final double sy = corner < 2 ? -1 : 1;
  switch (placement) {
    case OrnamentPlacement.behind:
      radius = math.min(kit.hw, kit.hh) * 1.1 + kit.size * 0.3;
      x0 = kit.cx;
      y0 = kit.cy;
      faint = true;
    case OrnamentPlacement.screen:
      x0 = sx * kit.width * 0.36;
      y0 = sy * kit.height * 0.32;
      radius = math.min(kit.width, kit.height) * 0.08 * kit.spec.scale;
    case OrnamentPlacement.lineStart:
      x0 = kit.vertical ? kit.cx : kit.cx - kit.hw - pad - radius;
      y0 = kit.vertical ? kit.cy - kit.hh - pad - radius : kit.cy;
    case OrnamentPlacement.lineEnd:
    case OrnamentPlacement.glyphs:
      x0 = kit.vertical ? kit.cx : kit.cx + kit.hw + pad * 0.6 + radius;
      y0 = kit.vertical
          ? kit.cy + kit.hh + pad * 0.6 + radius
          : kit.cy + kit.hh * 0.4;
    case OrnamentPlacement.around:
    case OrnamentPlacement.corners:
      x0 = kit.cx + sx * (kit.hw + radius * 0.6);
      y0 = kit.cy + sy * (kit.hh + radius * 0.5);
  }
  final String char =
      _stampChars[(kit.rng() * _stampChars.length).floor() %
          _stampChars.length];
  final int tint = kit.color(0);
  final int shockTint = kit.color(1);
  final ui.ParagraphBuilder builder =
      ui.ParagraphBuilder(
          ui.ParagraphStyle(
            textAlign: TextAlign.center,
            textDirection: TextDirection.ltr,
          ),
        )
        ..pushStyle(
          ui.TextStyle(
            color: rgbColor(tint),
            fontSize: math.max(8, radius * 1.02),
            fontWeight: FontWeight.w900,
            fontFamily: _stampFonts.first,
            fontFamilyFallback: _stampFonts,
          ),
        )
        ..addText(char);
  final ui.Paragraph text = builder.build()
    ..layout(const ui.ParagraphConstraints(width: double.infinity));
  final double textW = text.maxIntrinsicWidth;
  final double textH = text.height;
  final double tilt = (kit.rng() - 0.5) * 0.3;
  const double slam = 0.18;
  return (OrnamentCanvas o, double time) {
    final double local = time - kit.start;
    final double x = kit.exit(time);
    if (local < 0 || x >= 1) return;
    double scale;
    double rotation;
    if (local < slam) {
      // 从 2.4 倍加速砸下。
      final double k = easeInCubic(local / slam);
      scale = lerpD(2.4, 1, k);
      rotation = lerpD(-0.5, tilt, k);
    } else {
      final double after = local - slam;
      scale = 1 + 0.14 * math.exp(-after * 9) * math.cos(after * 38);
      rotation = tilt + 0.02 * math.sin(time * 0.6);
    }
    scale *= 1 - easeInBack(x, 2.4);
    final double s = math.max(0.001, scale);
    final double alpha =
        clamp01(local / 0.06) *
        (faint ? 0.3 : 1) *
        (x > 0.6 ? ((x * 20).floor() % 2 == 0 ? 1 : 0.3) : 1);
    final ui.Canvas c = o.canvas;
    if (alpha > 0.002) {
      _at(c, x0, y0, rotation, s, s, () {
        c.drawCircle(
          ui.Offset.zero,
          radius,
          _stroke(tint, alpha, radius * 0.1),
        );
        c.drawCircle(
          ui.Offset.zero,
          radius * 0.8,
          _stroke(tint, alpha, radius * 0.035),
        );
        // Text 的 anchor (0.5, 0.54)。
        final ui.Offset at = ui.Offset(-textW * 0.5, -textH * 0.54);
        if (alpha >= 0.999) {
          c.drawParagraph(text, at);
        } else {
          c.saveLayer(
            ui.Rect.fromLTWH(at.dx - 2, at.dy - 2, textW + 4, textH + 4),
            ui.Paint()..color = ui.Color.fromRGBO(0, 0, 0, alpha),
          );
          c.drawParagraph(text, at);
          c.restore();
        }
      });
    }
    final double impact = local - slam;
    final double k = clamp01(impact / 0.45);
    if (impact >= 0 && k < 1) {
      final double size = radius * 2 * (1 + 0.9 * easeOutCubic(k));
      o.sprite(
        OrnamentTexture.ring,
        x0,
        y0,
        size,
        size,
        0,
        (1 - k) * (1 - k) * (faint ? 0.3 : 0.8),
        shockTint,
      );
    }
  };
}

// halftone：网点渐变块（在色块后）。
OrnamentPainter _halftone(OrnamentKit kit) {
  final OrnamentPlacement placement = kit.spec.placement;
  final int perSite = placement == OrnamentPlacement.glyphs
      ? 25
      : placement == OrnamentPlacement.corners
      ? 36
      : kit.count(170, 40);
  final List<(OrnamentSite, List<(double, double, double)>, double, int)>
  units = <(OrnamentSite, List<(double, double, double)>, double, int)>[];
  for (final (int si, OrnamentSite site) in kit.sites(false, 6).indexed) {
    double w = site.w;
    double h = site.h;
    if (placement == OrnamentPlacement.around) {
      w = w * 1.2 + kit.size * 0.4;
      h = h * 1.35 + kit.size * 0.6;
    } else if (placement == OrnamentPlacement.behind) {
      // 网点块比字组宽一圈、上下更高，斜着露出来。
      w = w * 1.15 + kit.size * 0.3;
      h = h * 1.6 + kit.size * 0.4;
    } else if (placement == OrnamentPlacement.glyphs) {
      w *= 1.4;
      h *= 1.4;
    }
    final double spacing = math.max(
      kit.size * 0.18,
      math.sqrt((4 * w * h) / math.min(260, perSite)),
    );
    final int cols = math.max(2, ((2 * w) / spacing).round());
    final int rows = math.max(2, ((2 * h) / spacing).round());
    // 渐变方向：沿对角线，按种子选四个方向之一。
    final double dirA = ((kit.rng() * 4).floor() * math.pi) / 2 + math.pi / 4;
    final double dx = math.cos(dirA);
    final double dy = math.sin(dirA);
    final double diag = 2 * math.sqrt(w * w + h * h);
    final List<(double, double, double)> dots = <(double, double, double)>[];
    for (int r = 0; r < rows; r++) {
      for (int col = 0; col < cols; col++) {
        final double ox =
            (col - (cols - 1) / 2) * spacing + (r.isEven ? 0 : spacing * 0.5);
        final double oy = (r - (rows - 1) / 2) * spacing;
        final double proj = clamp01(0.5 + (ox * dx + oy * dy) / diag * 1.4);
        dots.add((ox, oy, proj));
      }
    }
    units.add((site, dots, spacing, kit.color(si)));
  }
  return (OrnamentCanvas o, double time) {
    final List<GlyphAnchor> anchors = kit.anchors(time);
    final double x = kit.exit(time);
    for (final (
          OrnamentSite site,
          List<(double, double, double)> dots,
          double spacing,
          int tint,
        )
        in units) {
      final (double px, double py, double pa, _) = kit.pos(site, anchors);
      final double local = time - site.start;
      for (final (double ox, double oy, double proj) in dots) {
        // 入场沿渐变方向扫进来，退场反向扫掉。
        final double reveal = local - proj * 0.55;
        final double leave = x * 1.6 - (1 - proj) * 0.6;
        final double pop =
            easeOutBack(reveal / 0.22, 2.5) * (1 - clamp01(leave / 0.4));
        final double wave = 0.22 * math.sin(kTau * (proj * 1.5 - time * 0.4));
        final double value = clamp01(1 - proj * 0.9 + wave);
        final double size = spacing * 0.92 * value * pop;
        if (!(size > 0.4 && reveal > 0)) continue;
        o.sprite(
          OrnamentTexture.dot,
          px + ox,
          py + oy,
          size,
          size,
          0,
          0.75 * pa,
          tint,
        );
      }
    }
  };
}

// ─── 粒子类（ornamentParticles.ts） ──────────────────────────────────────

/// 字被唱到的触发时刻列表；没有字（间奏）时按入场到退场均匀排。
List<(double, OrnamentGlyph?)> _triggers(OrnamentKit kit, int count) {
  if (kit.glyphs.isNotEmpty) {
    final int limit = math.max(1, math.min(kit.glyphs.length, count));
    return <(double, OrnamentGlyph?)>[
      for (int i = 0; i < limit; i++)
        () {
          final OrnamentGlyph g =
              kit.glyphs[((i + 0.5) * kit.glyphs.length / limit).floor()];
          return (math.max(kit.start, g.sungAt), g);
        }(),
    ];
  }
  final double span = math.max(0.5, kit.exitAt - kit.start);
  return <(double, OrnamentGlyph?)>[
    for (int i = 0; i < count; i++) (kit.start + (span * i) / count, null),
  ];
}

/// 字此刻的 (x, y, size, alpha)（取不到 anchor 时用静止位置）。
(double, double, double, double) _glyphNow(
  OrnamentGlyph g,
  List<GlyphAnchor> anchors,
) {
  if (g.index < anchors.length) {
    final GlyphAnchor a = anchors[g.index];
    return (a.x, a.y, a.size, a.alpha);
  }
  return (g.x, g.y, g.size, 1);
}

class _Sparkle {
  _Sparkle(
    this.at,
    this.glyph,
    this.site,
    this.side,
    this.ox,
    this.oy,
    this.size,
    this.spin,
    this.t0,
    this.t1,
    this.t2,
  );
  final double at;
  final OrnamentGlyph? glyph;
  final OrnamentSite site;
  final double side;
  final double ox;
  final double oy;
  final double size;
  final double spin;
  final int t0;
  final int t1;
  final int t2;
}

// sparkle：四角星，贴着被唱到的字闪。
OrnamentPainter _sparkle(OrnamentKit kit) {
  final bool onGlyph = kit._oneShot;
  final List<OrnamentSite> sites = kit.sites(true, 1);
  final List<_Sparkle> items = <_Sparkle>[];
  for (final (int i, (double at, OrnamentGlyph? glyph)) in _triggers(
    kit,
    kit.count(14, 3),
  ).indexed) {
    final double side = kit.rng() < 0.5 ? -1 : 1;
    final OrnamentSite site = sites[i % sites.length];
    final (double sx, double sy) = kit.scatter(site);
    final double ox = onGlyph ? side * 0.48 : sx;
    final double oy = onGlyph ? -0.45 - kit.rng() * 0.1 : sy;
    final double size = kit.size * (0.55 + kit.rng() * 0.35);
    final double spin = (kit.rng() - 0.5) * 1.2;
    items.add(
      _Sparkle(
        at,
        glyph,
        site,
        side,
        ox,
        oy,
        size,
        spin,
        kit.color(i),
        kit.color(i + 1),
        kit.color(i + 2),
      ),
    );
  }
  return (OrnamentCanvas o, double time) {
    final List<GlyphAnchor> anchors = kit.anchors(time);
    for (final (int i, _Sparkle it) in items.indexed) {
      final double local = time - it.at;
      final double x = kit.exit(time, (i % 6) * 0.03);
      if (local < 0 || x >= 1) continue;
      double cx;
      double cy;
      double alpha = 1;
      if (onGlyph && it.glyph != null) {
        final (double gx, double gy, double gs, double ga) = _glyphNow(
          it.glyph!,
          anchors,
        );
        cx = gx + it.ox * gs;
        cy = gy + it.oy * gs;
        alpha = ga;
      } else {
        final (double px, double py, _, _) = kit.pos(it.site, anchors);
        cx = px + it.ox;
        cy = py + it.oy;
      }
      // 弹出 → 0.7 秒后缩成一颗小星，余下时间慢慢闪。
      final double pop = springEase(local, 3.2, 8);
      final double settle = clamp01((local - 0.45) / 0.35);
      final double idle = 0.32 + 0.1 * math.sin(time * 5 + i * 1.7);
      final double scale =
          lerpD(1.25 * pop, idle, easeOutCubic(settle)) * (1 - easeInCubic(x));
      final double s = it.size * math.max(0, scale);
      if (s > 0.5) {
        o.sprite(
          OrnamentTexture.star4,
          cx,
          cy,
          s,
          s,
          -math.pi / 4 * (1 - easeOutCubic(local / 0.3)) +
              it.spin * local +
              x * 3,
          alpha * (1 - x),
          it.t0,
        );
      }
      void sat(
        OrnamentTexture tex,
        int tint,
        double delay,
        double dx,
        double dy,
        double sizeK,
      ) {
        final double l = local - delay;
        final double k = clamp01(l / 0.5);
        if (!(l >= 0 && k < 1)) return;
        final double ss = it.size * sizeK * math.sin(math.pi * k);
        o.sprite(
          tex,
          cx + dx * it.size,
          cy + dy * it.size,
          ss,
          ss,
          0,
          alpha,
          tint,
        );
      }

      sat(OrnamentTexture.star4, it.t1, 0.08, it.side * 0.55, 0.35, 0.45);
      sat(OrnamentTexture.dot, it.t2, 0.15, -it.side * 0.4, -0.5, 0.16);
    }
  };
}

class _Cross {
  _Cross(
    this.site,
    this.ox,
    this.oy,
    this.size,
    this.delay,
    this.offset,
    this.rise,
    this.tint,
  );
  final OrnamentSite site;
  final double ox;
  final double oy;
  final double size;
  final double delay;
  final double offset;
  final double rise;
  final int tint;
}

/// ＋号的形状（10 × 10，臂宽 2.8）。
final ui.Path _crossShape = ui.Path()
  ..addRect(const ui.Rect.fromLTWH(-5, -1.4, 10, 2.8))
  ..addRect(const ui.Rect.fromLTWH(-1.4, -5, 2.8, 10));

// cross：＋号散布，一拍转 90°。
OrnamentPainter _cross(OrnamentKit kit) {
  final bool oneShot = kit._oneShot;
  final List<OrnamentSite> sites = kit.sites(true, 8);
  final int n = oneShot ? sites.length * 2 : kit.count(12, 4);
  final List<_Cross> items = <_Cross>[];
  for (int i = 0; i < n; i++) {
    final OrnamentSite site = sites[i % sites.length];
    double ox;
    double oy;
    if (oneShot) {
      ox = (kit.rng() - 0.5) * site.w * 3;
      oy = -site.h * (0.9 + kit.rng() * 0.6);
    } else {
      (ox, oy) = kit.scatter(site);
    }
    final double size = kit.size * (0.18 + kit.rng() * 0.22) / 10;
    final double delay = oneShot ? (i >= sites.length ? 0.08 : 0) : i * 0.06;
    final double offset = kit.rng();
    final double rise = kit.size * (0.1 + kit.rng() * 0.2);
    items.add(_Cross(site, ox, oy, size, delay, offset, rise, kit.color(i)));
  }
  return (OrnamentCanvas o, double time) {
    final List<GlyphAnchor> anchors = kit.anchors(time);
    final ui.Canvas c = o.canvas;
    for (final (int i, _Cross it) in items.indexed) {
      final double local = time - it.site.start - it.delay;
      final double x = kit.exit(time, (i % 8) * 0.03);
      if (local < 0 || x >= 1 || (oneShot && local > 1.4)) continue;
      final (double px, double py, double pa, _) = kit.pos(it.site, anchors);
      double scale = easeOutBack(local / 0.3, 3) * (1 - easeInCubic(x));
      double alpha = pa * (1 - x);
      if (oneShot) {
        final double k = clamp01((local - 0.6) / 0.8);
        scale *= 1 - k;
        alpha *= 1 - k;
      }
      if (!(scale > 0.01)) continue;
      final double s = math.max(0.001, it.size * scale);
      _at(
        c,
        px + it.ox,
        py + it.oy - it.rise * math.sin(time * 0.8 + it.offset * kTau),
        beatSteps(local / 1.2 + it.offset) * (math.pi / 2) + x * 4,
        s,
        s,
        () => c.drawPath(_crossShape, _fill(it.tint, alpha)),
      );
    }
  };
}

/// 彩纸 / 花瓣共用的循环下落参数。
class _Faller {
  _Faller({
    required this.tex,
    required this.tint,
    required this.site,
    required this.x0,
    required this.period,
    required this.offset,
    required this.sway,
    required this.swayFreq,
    required this.flip,
    required this.spin,
    required this.size,
    required this.aspect,
    required this.delay,
    required this.vx,
    required this.vy,
  });
  final OrnamentTexture tex;
  final int tint;
  final OrnamentSite site;
  final double x0;
  final double period;
  final double offset;
  final double sway;
  final double swayFreq;
  final double flip;
  final double spin;
  final double size;
  final double aspect;
  final double delay;

  /// 入场时从中心炸开的初速度（px/s）。
  final double vx;
  final double vy;
}

// confetti：彩纸片炸开后翻飞下落，之后循环飘落。
OrnamentPainter _confetti(OrnamentKit kit) {
  final List<OrnamentSite> sites = kit.sites(true, 6);
  final int n = kit.count(26, 8);
  final List<_Faller> pieces = <_Faller>[];
  for (int i = 0; i < n; i++) {
    final OrnamentSite site = sites[i % sites.length];
    final double angle = -math.pi / 2 + (kit.rng() - 0.5) * 2.4;
    final double speed = kit.size * (3 + kit.rng() * 4);
    final double x0 = (kit.rng() * 2 - 1) * (site.w + kit.size);
    final double period = 3 + kit.rng() * 2.5;
    final double offset = kit.rng();
    final double sway = kit.size * (0.2 + kit.rng() * 0.35);
    final double swayFreq = 0.4 + kit.rng() * 0.5;
    final double flip = 3 + kit.rng() * 6;
    final double spin = (kit.rng() - 0.5) * 6;
    final double size = kit.size * (0.2 + kit.rng() * 0.14);
    final double aspect = i % 3 == 2 ? 1 : 0.5 + kit.rng() * 0.3;
    pieces.add(
      _Faller(
        tex: i % 3 == 2 ? OrnamentTexture.triangle : OrnamentTexture.square,
        tint: kit.color(i),
        site: site,
        x0: x0,
        period: period,
        offset: offset,
        sway: sway,
        swayFreq: swayFreq,
        flip: flip,
        spin: spin,
        size: size,
        aspect: aspect,
        delay: (i % 5) * 0.02,
        vx: math.cos(angle) * speed,
        vy: math.sin(angle) * speed,
      ),
    );
  }
  const double burstLife = 2.2;
  return (OrnamentCanvas o, double time) {
    final List<GlyphAnchor> anchors = kit.anchors(time);
    final double x = kit.exit(time);
    for (final _Faller it in pieces) {
      final double local = time - it.site.start - it.delay;
      if (local < 0 || x >= 1) continue;
      final (double px, double py, double pa, _) = kit.pos(it.site, anchors);
      final double top = -it.site.h - kit.size * 2;
      final double bottom = it.site.h + kit.size * 1.5;
      double ox;
      double oy;
      double alpha = 1;
      if (local < burstLife) {
        // 第一程：从落点中心炸开，阻尼 + 重力的闭式解，渐隐交给循环。
        const double drag = 2.6;
        final double fall = kit.size * 1.6;
        final double e = math.exp(-drag * local);
        final double f = (1 - e) / drag;
        ox =
            it.vx * f +
            math.sin(local * it.swayFreq * kTau) * it.sway * (1 - e);
        oy = it.vy * f + fall * (local - f);
        alpha = 1 - clamp01((local - burstLife + 0.4) / 0.4);
      } else {
        final double cycle = fract((local - burstLife) / it.period + it.offset);
        ox = it.x0 + math.sin(local * it.swayFreq * kTau) * it.sway;
        oy = lerpD(top, bottom, cycle);
        alpha = clamp01(cycle / 0.1) * clamp01((1 - cycle) / 0.15);
      }
      oy += kit.size * 3 * x * x;
      final double flip = math.cos(local * it.flip);
      if (!(alpha > 0.01)) continue;
      o.sprite(
        it.tex,
        px + ox,
        py + oy,
        it.size * math.max(0.08, flip.abs()),
        it.size * it.aspect,
        local * it.spin,
        alpha * (1 - x) * pa * (0.75 + 0.25 * flip.abs()),
        it.tint,
      );
    }
  };
}

// petals：樱花瓣斜着飘。
OrnamentPainter _petals(OrnamentKit kit) {
  final List<OrnamentSite> sites = kit.sites(true, 4);
  final int n = kit.count(16, 5);
  final List<_Faller> petals = <_Faller>[];
  for (int i = 0; i < n; i++) {
    final OrnamentSite site = sites[i % sites.length];
    final double x0 = (kit.rng() * 2 - 1) * (site.w + kit.size * 1.5);
    final double period = 4.5 + kit.rng() * 3;
    final double offset = kit.rng();
    final double sway = kit.size * (0.3 + kit.rng() * 0.4);
    final double swayFreq = 0.25 + kit.rng() * 0.3;
    final double flip = 1.5 + kit.rng() * 2.5;
    final double spin = (kit.rng() - 0.5) * 2;
    final double size = kit.size * (0.22 + kit.rng() * 0.16);
    petals.add(
      _Faller(
        tex: OrnamentTexture.petal,
        tint: kit.color(i),
        site: site,
        x0: x0,
        period: period,
        offset: offset,
        sway: sway,
        swayFreq: swayFreq,
        flip: flip,
        spin: spin,
        size: size,
        aspect: 1.35,
        delay: i * 0.05,
        vx: 0,
        vy: 0,
      ),
    );
  }
  return (OrnamentCanvas o, double time) {
    final List<GlyphAnchor> anchors = kit.anchors(time);
    final double x = kit.exit(time);
    for (final _Faller it in petals) {
      final double local = time - it.site.start - it.delay;
      if (local < 0 || x >= 1) continue;
      final (double px, double py, double pa, _) = kit.pos(it.site, anchors);
      final double top = -it.site.h - kit.size * 2;
      final double bottom = it.site.h + kit.size * 1.5;
      final double cycle = fract(local / it.period + it.offset);
      final double span = it.site.w + kit.size * 2;
      // 风从左往右：横向随下落漂移，在落点宽度里循环；退场时被一阵风吹走。
      final double drift =
          wrapD(it.x0 + span + cycle * kit.size * 2.5 + span, span * 2) - span;
      final double ox =
          drift +
          math.sin(local * it.swayFreq * kTau) * it.sway +
          kit.size * 6 * x * x;
      final double oy = lerpD(top, bottom, cycle);
      final double flip = math.cos(local * it.flip);
      final double alpha =
          clamp01(cycle / 0.1) *
          clamp01((1 - cycle) / 0.15) *
          clamp01(local / 0.3);
      final double pop = easeOutBack(local / 0.35, 2);
      if (!(alpha > 0.01)) continue;
      o.sprite(
        OrnamentTexture.petal,
        px + ox,
        py + oy,
        it.size * math.max(0.1, flip.abs()) * pop,
        it.size * it.aspect * pop,
        0.6 +
            math.sin(local * 0.9 + it.offset * kTau) * 0.7 +
            local * it.spin * 0.2,
        alpha * (1 - x) * pa * 0.9,
        it.tint,
      );
    }
  };
}

class _Shard {
  _Shard(
    this.site,
    this.cos,
    this.sin,
    this.edge,
    this.tint,
    this.reach,
    this.size,
    this.rot,
    this.spin,
    this.stretch,
  );
  final OrnamentSite site;
  final double cos;
  final double sin;
  final double edge;
  final int tint;
  final double reach;
  final double size;
  final double rot;
  final double spin;
  final double stretch;
}

// shards：三角碎片从字组边缘向外飞，悬停漂移。
OrnamentPainter _shards(OrnamentKit kit) {
  final bool oneShot = kit._oneShot;
  final bool big = kit._big;
  final List<OrnamentSite> sites = kit.sites(false, 8);
  final int per = oneShot
      ? 4
      : math.max(3, (kit.count(18, 5) / sites.length).round());
  final List<_Shard> shards = <_Shard>[];
  for (final (int si, OrnamentSite site) in sites.indexed) {
    for (int i = 0; i < per; i++) {
      final double angle = (kTau * (i + kit.rng() * 0.8)) / per + si;
      final double cos = math.cos(angle);
      final double sin = math.sin(angle);
      final double edge = big
          ? 1 /
                math.sqrt(
                  math.pow(cos / (site.w + kit.size * 0.2), 2) +
                      math.pow(sin / (site.h + kit.size * 0.2), 2),
                )
          : site.w * 0.8;
      final double reach =
          kit.size * (oneShot ? 0.6 + kit.rng() * 0.6 : 0.8 + kit.rng() * 1.6);
      final double size =
          kit.size *
          (oneShot ? 0.14 + kit.rng() * 0.1 : 0.18 + kit.rng() * 0.22);
      final double rot = kit.rng() * kTau;
      final double spin = (kit.rng() - 0.5) * 10;
      final double stretch = 1.3 + kit.rng() * 0.8;
      shards.add(
        _Shard(
          site,
          cos,
          sin,
          edge,
          kit.color(si + i),
          reach,
          size,
          rot,
          spin,
          stretch,
        ),
      );
    }
  }
  return (OrnamentCanvas o, double time) {
    final List<GlyphAnchor> anchors = kit.anchors(time);
    final double x = kit.exit(time);
    for (final _Shard s in shards) {
      final double local = time - s.site.start;
      if (local < 0 || x >= 1 || (oneShot && local > 1.1)) continue;
      final (double px, double py, double pa, _) = kit.pos(s.site, anchors);
      // 迅速冲出去（阻尼），之后以很小的速度继续向外漂。
      final double out =
          s.reach * (1 - math.exp(-5 * local)) +
          kit.size * 0.08 * local +
          kit.size * 4 * easeInCubic(x);
      final double r = s.edge + out;
      double scale =
          easeOutBack(local / 0.2, 2) *
          lerpD(1, 0.7, clamp01(local / 3)) *
          (1 - x);
      double alpha = pa * (1 - x);
      if (oneShot) {
        final double k = clamp01((local - 0.4) / 0.7);
        scale *= 1 - k;
        alpha *= 1 - k;
      }
      if (!(scale > 0.01)) continue;
      o.sprite(
        OrnamentTexture.triangle,
        px + s.cos * r,
        py + s.sin * r,
        s.size * scale,
        s.size * scale * s.stretch,
        s.rot + s.spin * (1 - math.exp(-2 * local)) + 0.2 * local,
        alpha,
        s.tint,
      );
    }
  };
}

class _Streak {
  _Streak(
    this.site,
    this.ox,
    this.tint,
    this.y0,
    this.length,
    this.thick,
    this.speed,
    this.delay,
    this.salt,
  );
  final OrnamentSite site;
  final double ox;
  final int tint;
  final double y0;
  final double length;
  final double thick;
  final double speed;
  final double delay;
  final double salt;
}

// streaks：纵向速度线（强调上升）。
OrnamentPainter _streaks(OrnamentKit kit) {
  final List<OrnamentSite> sites = kit.sites(true, 6);
  final int n = kit.count(
    kit.spec.placement == OrnamentPlacement.screen ? 30 : 20,
    6,
  );
  final List<_Streak> lines = <_Streak>[];
  for (int i = 0; i < n; i++) {
    final OrnamentSite site = sites[i % sites.length];
    final (double ox, _) = kit.scatter(site);
    final double y0 = kit.rng();
    final double length = kit.size * (1.4 + kit.rng() * 2.6);
    final double thick = math.max(1, kit.size * (0.025 + kit.rng() * 0.05));
    final double speed = kit.size * (5 + kit.rng() * 7);
    final double delay = kit.rng() * 0.3;
    lines.add(
      _Streak(
        site,
        ox,
        kit.color(i),
        y0,
        length,
        thick,
        speed,
        delay,
        (i * 13 + 1).toDouble(),
      ),
    );
  }
  return (OrnamentCanvas o, double time) {
    final List<GlyphAnchor> anchors = kit.anchors(time);
    final double x = kit.exit(time);
    for (final _Streak l in lines) {
      final double local = time - l.site.start - l.delay;
      if (local < 0 || x >= 1) continue;
      final (double px, double py, double pa, _) = kit.pos(l.site, anchors);
      final double top = -l.site.h - kit.size * 2 - l.length;
      final double span = l.site.h * 2 + kit.size * 4 + l.length * 2;
      // 入场时加速，退场时再猛冲一下。
      final double travel = l.speed * (local + 2 * x * x);
      final double y = top + wrapD(l.y0 * span + travel, span);
      final double cycle = (y - top) / span;
      final double window = clamp01(cycle / 0.15) * clamp01((1 - cycle) / 0.15);
      final double flicker = mgHash01((time * 15).floorToDouble(), l.salt) < 0.2
          ? 0.3
          : 1;
      if (!(window > 0.01)) continue;
      // 纹理上亮下暗；线往下掠过（世界在上升），亮头朝下（旋转 π）。
      o.sprite(
        OrnamentTexture.streak,
        px + l.ox,
        py + y,
        l.thick,
        l.length * (1 + x),
        math.pi,
        window * flicker * clamp01(local / 0.25) * (1 - x) * pa * 0.85,
        l.tint,
      );
    }
  };
}

/// ^ 箭头的形状（folia `moveTo(-5, 3).lineTo(0, -2).lineTo(5, 3)`，线宽 2.4）。
final ui.Path _chevronShape = ui.Path()
  ..moveTo(-5, 3)
  ..lineTo(0, -2)
  ..lineTo(5, 3);

// chevrons：^^^ 箭头沿上升方向一拍一格地流动。
OrnamentPainter _chevrons(OrnamentKit kit) {
  final OrnamentPlacement placement = kit.spec.placement;
  final List<OrnamentSite> sites = kit.sites(false, 6);
  // 每列：(site, dx, scale, alpha)。
  List<(OrnamentSite, double, double, double)> columns;
  if (placement == OrnamentPlacement.around) {
    final OrnamentSite site = sites[0];
    columns = <(OrnamentSite, double, double, double)>[
      for (final double side in <double>[-1, 1])
        (site, side * (site.w + kit.size * 0.8), 1, 1),
    ];
  } else if (placement == OrnamentPlacement.screen) {
    final OrnamentSite site = sites[0];
    columns = <(OrnamentSite, double, double, double)>[
      for (final double k in <double>[-0.4, -0.2, 0.2, 0.4])
        (site, k * kit.width, 1.2, 0.7),
    ];
  } else if (placement == OrnamentPlacement.behind) {
    columns = <(OrnamentSite, double, double, double)>[
      (sites[0], 0, 2.2, 0.35),
    ];
  } else {
    columns = <(OrnamentSite, double, double, double)>[
      for (final OrnamentSite site in sites)
        (site, 0, placement == OrnamentPlacement.glyphs ? 0.6 : 1, 1),
    ];
  }
  final int perColumn = math.max(2, math.min(6, kit.count(4, 2)));
  final bool oneShot = kit._oneShot;
  final double spacing = kit.size * 0.42;
  final List<((OrnamentSite, double, double, double), int, int)> items =
      <((OrnamentSite, double, double, double), int, int)>[
        for (final (int ci, (OrnamentSite, double, double, double) col)
            in columns.indexed)
          for (int j = 0; j < perColumn; j++) (col, j, kit.color(ci + j)),
      ];
  return (OrnamentCanvas o, double time) {
    final List<GlyphAnchor> anchors = kit.anchors(time);
    final double x = kit.exit(time);
    final ui.Canvas c = o.canvas;
    for (final (
          (OrnamentSite site, double dx, double colScale, double colAlpha),
          int j,
          int tint,
        )
        in items) {
      final double local = time - site.start - j * 0.05;
      if (local < 0 || x >= 1 || (oneShot && local > 1.6)) continue;
      final (double px, double py, double pa, double ps) = kit.pos(
        site,
        anchors,
      );
      final double s = spacing * colScale;
      final double total = perColumn * s;
      // 一拍一格往上走，每格落定时有过冲。
      final double travel =
          beatSteps(local * 3.2, 0.4) * s * 0.5 + x * x * s * 6;
      final double y = wrapD(j * s - travel, total);
      final double k = y / total;
      final double fade = math.sin(math.pi * clamp01(k));
      final double pop = easeOutBack(local / 0.3, 2.4);
      final double baseY = oneShot
          ? py - ps * 0.8 - total * 0.5
          : py - total / 2;
      final double scale = math.max(0.001, (kit.size * 0.06) * colScale * pop);
      double alpha = fade * colAlpha * (1 - x) * pa;
      if (oneShot) alpha *= 1 - clamp01((local - 1) / 0.6);
      if (alpha <= 0.002) continue;
      _at(
        c,
        px + dx,
        baseY + y,
        0,
        scale,
        scale,
        () => c.drawPath(
          _chevronShape,
          _stroke(tint, alpha, 2.4, cap: StrokeCap.square),
        ),
      );
    }
  };
}

/// 方框周长参数化：u ∈ [0, 1) → 边上的点（从左上角顺时针）。
(double, double) aroundBox(double u, double halfW, double halfH) {
  final double perimeter = 4 * (halfW + halfH);
  double d = fract(u) * perimeter;
  if (d < 2 * halfW) return (-halfW + d, -halfH);
  d -= 2 * halfW;
  if (d < 2 * halfH) return (halfW, -halfH + d);
  d -= 2 * halfH;
  if (d < 2 * halfW) return (halfW - d, halfH);
  d -= 2 * halfW;
  return (-halfW, halfH - d);
}

// glints：字被唱到时，一粒光点沿字的轮廓跑一圈。
OrnamentPainter _glints(OrnamentKit kit) {
  final bool onGlyph = kit._oneShot || kit.glyphs.isEmpty;
  const double run = 0.55;
  if (onGlyph) {
    final List<(double, OrnamentGlyph?, int, double)> items =
        <(double, OrnamentGlyph?, int, double)>[
          for (final (int i, (double at, OrnamentGlyph? glyph)) in _triggers(
            kit,
            kit.count(16, 4),
          ).indexed)
            (at, glyph, kit.color(i), (kit.rng() * 4).floor() / 4),
        ];
    final OrnamentSite site = kit.sites(false, 1)[0];
    return (OrnamentCanvas o, double time) {
      final List<GlyphAnchor> anchors = kit.anchors(time);
      final double x = kit.exit(time);
      for (final (double at, OrnamentGlyph? glyph, int tint, double corner)
          in items) {
        final double local = time - at;
        if (local < 0 || x >= 1) continue;
        double gx;
        double gy;
        double size;
        double alpha = 1;
        if (glyph != null) {
          (gx, gy, size, alpha) = _glyphNow(glyph, anchors);
        } else {
          final (double px, double py, _, _) = kit.pos(site, anchors);
          gx = px;
          gy = py;
          size = kit.size;
        }
        final double half = size * 0.56;
        final double k = clamp01(local / run);
        final bool running = k < 1;
        final double u = easeOutCubic(k);
        final double hs = kit.size * 0.35;
        if (running) {
          final (double hx, double hy) = aroundBox(u, half, half);
          final (double tx, double ty) = aroundBox(
            math.max(0, u - 0.08),
            half,
            half,
          );
          o.sprite(
            OrnamentTexture.glow,
            gx + hx,
            gy + hy,
            hs,
            hs,
            0,
            alpha,
            tint,
          );
          o.sprite(
            OrnamentTexture.dot,
            gx + tx,
            gy + ty,
            hs * 0.25,
            hs * 0.25,
            0,
            alpha * 0.7,
            tint,
          );
        }
        // 跑完一圈：在某个角上留下一颗闪着的小星。
        final (double cx, double cy) = aroundBox(corner, half, half);
        final double after = local - run;
        final double twinkle = after < 0
            ? 0
            : springEase(after, 2.5, 6) *
                  (0.55 + 0.45 * math.sin(time * 7 + corner * 20));
        final double ss = kit.size * 0.4 * twinkle * (1 - easeInCubic(x));
        if (ss > 0.5) {
          o.sprite(
            OrnamentTexture.star4,
            gx + cx,
            gy + cy,
            ss,
            ss,
            0,
            alpha * (1 - x),
            tint,
          );
        }
      }
    };
  }
  // 不贴字：一粒光点绕着落点的方框循环跑，每个字被唱到时加速、变亮。
  final List<(OrnamentSite, double, int)> runners =
      <(OrnamentSite, double, int)>[
        for (final (int si, OrnamentSite site) in kit.sites(false, 1).indexed)
          for (final (int r, double phase) in <double>[0, 0.5].indexed)
            (site, phase, kit.color(si + r)),
      ];
  return (OrnamentCanvas o, double time) {
    final List<GlyphAnchor> anchors = kit.anchors(time);
    final double x = kit.exit(time);
    final double boost = math.exp(-(time - kit.lastSung(time)) / 0.2);
    for (final (OrnamentSite site, double phase, int tint) in runners) {
      final double local = time - site.start;
      if (local < 0 || x >= 1) continue;
      final (double px, double py, double pa, _) = kit.pos(site, anchors);
      final double halfW = site.w + kit.size * 0.15;
      final double halfH = site.h + kit.size * 0.15;
      final double u =
          phase + local / 2.8 + 0.1 * beatSteps(local * 1.2, 0.3) / 1.2;
      final double alpha = clamp01(local / 0.2) * (1 - x) * pa;
      final (double hx, double hy) = aroundBox(u, halfW, halfH);
      final double hs = kit.size * (0.3 + 0.25 * boost);
      o.sprite(OrnamentTexture.glow, px + hx, py + hy, hs, hs, 0, alpha, tint);
      for (int k = 0; k < 3; k++) {
        final (double tx, double ty) = aroundBox(
          u - 0.012 * (k + 1),
          halfW,
          halfH,
        );
        final double ts = hs * 0.3 * (1 - k * 0.25);
        o.sprite(
          OrnamentTexture.dot,
          px + tx,
          py + ty,
          ts,
          ts,
          0,
          alpha * (0.7 - k * 0.2),
          tint,
        );
      }
    }
  };
}

// ─── 线类（ornamentLines.ts） ────────────────────────────────────────────

/// 一条线的走向：起点、方向、长度。
class _Track {
  const _Track(this.x, this.y, this.dx, this.dy, this.length, this.start);
  final double x;
  final double y;
  final double dx;
  final double dy;
  final double length;
  final double start;
}

/// 按 placement 给出线的走向：around / behind / glyphs 从字组两侧往外，line-* 从一端往外，corners 从四角斜出，
/// screen 横贯全屏；[across] 时沿字组下缘（竖排时右缘）横穿。
List<_Track> _tracksFor(OrnamentKit kit, double reach, bool across) {
  final double pad = kit.size * 0.35;
  final double cx = kit.cx;
  final double cy = kit.cy;
  final double hw = kit.hw;
  final double hh = kit.hh;
  final bool vertical = kit.vertical;
  final double start = kit.start;
  _Track along(double sign) => vertical
      ? _Track(cx, cy + sign * (hh + pad), 0, sign, reach, start)
      : _Track(cx + sign * (hw + pad), cy, sign, 0, reach, start);
  switch (kit.spec.placement) {
    case OrnamentPlacement.lineStart:
      return <_Track>[along(-1)];
    case OrnamentPlacement.lineEnd:
      return <_Track>[along(1)];
    case OrnamentPlacement.corners:
      return <_Track>[
        for (final (int k, (double sx, double sy)) in _cornerSigns.indexed)
          _Track(
            cx + sx * (hw + pad * 0.5),
            cy + sy * (hh + pad * 0.5),
            sx * math.sqrt1_2,
            sy * math.sqrt1_2,
            reach * 0.6,
            start + k * 0.06,
          ),
      ];
    case OrnamentPlacement.screen:
      final double w = kit.width * 0.55;
      final double h = kit.height * 0.55;
      return vertical
          ? <_Track>[
              _Track(cx - hw - pad * 2, -h, 0, 1, h * 2, start),
              _Track(cx + hw + pad * 2, h, 0, -1, h * 2, start + 0.1),
            ]
          : <_Track>[
              _Track(-w, cy - hh - pad * 2, 1, 0, w * 2, start),
              _Track(w, cy + hh + pad * 2, -1, 0, w * 2, start + 0.1),
            ];
    case OrnamentPlacement.behind:
    case OrnamentPlacement.around:
    case OrnamentPlacement.glyphs:
      if (across) {
        return vertical
            ? <_Track>[
                _Track(
                  cx + hw + pad,
                  cy - hh - reach * 0.5,
                  0,
                  1,
                  hh * 2 + reach,
                  start,
                ),
              ]
            : <_Track>[
                _Track(
                  cx - hw - reach * 0.5,
                  cy + hh + pad,
                  1,
                  0,
                  hw * 2 + reach,
                  start,
                ),
              ];
      }
      return <_Track>[along(-1), along(1)];
  }
}

/// 画出 track 上 [from, to]（0..1）这一段，offset(s) 给出沿法线的偏移。
bool _strokeTrack(
  ui.Path path,
  _Track track,
  double from,
  double to,
  int steps,
  double Function(double s) offset, [
  double ox = 0,
  double oy = 0,
]) {
  if (to - from <= 1e-4) return false;
  final double nx = -track.dy;
  final double ny = track.dx;
  for (int i = 0; i <= steps; i++) {
    final double s = lerpD(from, to, i / steps);
    final double d = s * track.length;
    final double o = offset(s);
    final double x = track.x + ox + track.dx * d + nx * o;
    final double y = track.y + oy + track.dy * d + ny * o;
    if (i == 0) {
      path.moveTo(x, y);
    } else {
      path.lineTo(x, y);
    }
  }
  return true;
}

// zigzag：锯齿线从字组两侧抽出。
OrnamentPainter _zigzag(OrnamentKit kit) {
  final double reach = kit.size * (2.6 + kit.rng() * 1.4);
  final List<_Track> tracks = _tracksFor(kit, reach, false);
  final int c0 = kit.color(0);
  final int c1 = kit.color(1);
  final double amp = kit.size * 0.18;
  final double width = math.max(1.5, kit.size * 0.06);
  return (OrnamentCanvas o, double time) {
    final ui.Path g = ui.Path();
    final ui.Path echo = ui.Path();
    final double x = kit.exit(time);
    bool any = false;
    // 锯齿一拍翻一次相位（阶梯），幅度随拍子跳。
    final double flip = (time * 6).floor() % 2 == 0 ? 0 : 0.5;
    final double pump = 1 + 0.3 * ((time * 3).floor() % 3 == 0 ? 1 : 0);
    for (final _Track track in tracks) {
      final double local = time - track.start;
      if (local < 0 || x >= 1) continue;
      final int teeth = math.max(3, (track.length / (kit.size * 0.34)).round());
      final double to = easeOutCubic(local / 0.5);
      final double from = easeInCubic(x);
      final int steps = teeth * 2;
      // 折线：只在齿尖取点，所以 steps = 齿数 × 2，偏移交替 ±amp。
      double zig(double s) {
        final int k = ((s * teeth + flip) * 2).round();
        return (k.isEven ? 1 : -1) * amp * pump * math.min(1, s * 6);
      }

      any = _strokeTrack(g, track, from, to, steps, zig) || any;
      _strokeTrack(
        echo,
        track,
        from,
        to * 0.8,
        steps,
        (double s) => zig(s) * 0.6,
        -track.dy * amp * 1.8,
        track.dx * amp * 1.8,
      );
    }
    if (!any) return;
    final ui.Canvas c = o.canvas;
    c.drawPath(g, _stroke(c0, 1 - x, width, cap: StrokeCap.square));
    c.drawPath(echo, _stroke(c1, 0.6 * (1 - x), width * 0.5));
  };
}

// wave：正弦波线横穿。
OrnamentPainter _wave(OrnamentKit kit) {
  final double reach = kit.size * 4;
  final List<_Track> tracks = _tracksFor(kit, reach, true);
  final int layers = math.min(3, math.max(2, kit.count(2.4, 2)));
  final List<(int, double, double, double, double)> waves =
      <(int, double, double, double, double)>[
        for (int j = 0; j < layers; j++)
          (
            kit.color(j),
            j * 1.9,
            kit.size * (0.22 - j * 0.05),
            0.6 + j * 0.25,
            math.max(1.2, kit.size * (0.06 - j * 0.015)),
          ),
      ];
  final double wavelength = kit.size * 1.6;
  return (OrnamentCanvas o, double time) {
    final double x = kit.exit(time);
    final double bump = 1 + 0.6 * math.exp(-(time - kit.lastSung(time)) / 0.25);
    for (final (
          int j,
          (int tint, double phase, double amp, double speed, double width),
        )
        in waves.indexed) {
      final ui.Path g = ui.Path();
      bool any = false;
      for (final _Track track in tracks) {
        final double local = time - track.start - j * 0.08;
        if (local < 0 || x >= 1) continue;
        final double to = easeOutCubic(local / 0.7);
        final double from = easeInCubic(x);
        final int steps = math.min(
          140,
          math.max(16, (track.length / (kit.size * 0.12)).round()),
        );
        final double cycles = track.length / wavelength;
        any =
            _strokeTrack(
              g,
              track,
              from,
              to,
              steps,
              (double s) =>
                  math.sin((s * cycles - time * speed) * kTau + phase) *
                  amp *
                  bump *
                  math.sin(math.pi * s),
            ) ||
            any;
      }
      if (!any) continue;
      o.canvas.drawPath(
        g,
        _stroke(
          tint,
          (1 - x) * (j == 0 ? 1 : 0.65),
          width,
          cap: StrokeCap.round,
          join: StrokeJoin.round,
        ),
      );
    }
  };
}

// underline：被唱到的字下方的粗下划线，唱完收起。
OrnamentPainter _underline(OrnamentKit kit) {
  final OrnamentPlacement placement = kit.spec.placement;
  double thick(double size) => math.max(2, size * 0.09 * kit.spec.scale);
  final bool vertical = kit.vertical;

  /// 一根条：from..to 是沿文字方向的两端（0..1 的比例），画在 (x, y) 起、长 length 的线上。
  void bar(
    OrnamentCanvas o,
    int tint,
    double x,
    double y,
    double length,
    double from,
    double to,
    double height,
    double alpha,
  ) {
    if (!(to - from > 0.002 && alpha > 0.01)) return;
    final double mid = (from + to) / 2 * length;
    final double len = (to - from) * length;
    if (vertical) {
      o.sprite(OrnamentTexture.square, x, y + mid, height, len, 0, alpha, tint);
    } else {
      o.sprite(OrnamentTexture.square, x + mid, y, len, height, 0, alpha, tint);
    }
  }

  if (placement == OrnamentPlacement.glyphs ||
      placement == OrnamentPlacement.corners ||
      kit.glyphs.isEmpty) {
    final List<(OrnamentGlyph, int, int)> items = <(OrnamentGlyph, int, int)>[
      for (final (int i, OrnamentGlyph g) in kit.glyphs.indexed)
        (g, kit.color(i), kit.color(i + 1)),
    ];
    return (OrnamentCanvas o, double time) {
      final List<GlyphAnchor> anchors = kit.anchors(time);
      final double x = kit.exit(time);
      for (final (OrnamentGlyph g, int mainTint, int echoTint) in items) {
        final (double gx, double gy, double size, double ga) = _glyphNow(
          g,
          anchors,
        );
        final double alpha = ga * (1 - x);
        final double local = time - g.sungAt;
        // 唱到时从头拉出，唱完 0.1 秒后从头收起。
        final double retract = easeInCubic((time - g.sungEnd - 0.1) / 0.25);
        final double grow = easeOutExpo(local / 0.18);
        final double length = size * 1.04;
        final double ox = vertical ? gx + size * 0.6 : gx - length / 2;
        final double oy = vertical ? gy - length / 2 : gy + size * 0.6;
        bar(
          o,
          mainTint,
          ox,
          oy,
          length,
          retract,
          local < 0 ? 0 : grow,
          thick(size),
          alpha,
        );
        final double growEcho = easeOutExpo((local - 0.06) / 0.2);
        final double retractEcho = easeInCubic(
          (time - g.sungEnd - 0.16) / 0.25,
        );
        bar(
          o,
          echoTint,
          ox + (vertical ? thick(size) * 1.6 : 0),
          oy + (vertical ? 0 : thick(size) * 1.6),
          length,
          retractEcho,
          local < 0.06 ? 0 : growEcho,
          thick(size) * 0.35,
          alpha * 0.9,
        );
      }
    };
  }

  // 整行一根：长度跟着「唱到第几个字」走，最后一个字唱完后收起。
  final List<OrnamentGlyph> order = <OrnamentGlyph>[...kit.glyphs]
    ..sort((OrnamentGlyph a, OrnamentGlyph b) => a.sungAt.compareTo(b.sungAt));
  final OrnamentGlyph first = order.first;
  final OrnamentGlyph last = order.last;
  final double pad = kit.size * 0.3;
  final bool lineStart = placement == OrnamentPlacement.lineStart;
  final bool lineEnd = placement == OrnamentPlacement.lineEnd;
  final int mainTint = kit.color(0);
  final int echoTint = kit.color(1);
  final double length = vertical ? kit.hh * 2 : kit.hw * 2;
  final double short = kit.size * 1.2;
  return (OrnamentCanvas o, double time) {
    final double x = kit.exit(time);
    double progress = 0;
    for (final OrnamentGlyph glyph in order) {
      if (time >= glyph.sungAt) {
        progress += clamp01(
          (time - glyph.sungAt) / math.max(0.08, glyph.sungEnd - glyph.sungAt),
        );
      }
    }
    final double k = easeOutCubic(progress / order.length);
    final double retract = easeInCubic((time - last.sungEnd - 0.15) / 0.35);
    final double pulse =
        1 + 0.5 * math.exp(-(time - kit.lastSung(time)) / 0.15);
    final double height =
        thick(kit.size / kit.spec.scale) * (lineStart || lineEnd ? pulse : 1.2);
    final double alpha = (1 - x) * (time >= first.sungAt ? 1 : 0);
    if (lineStart || lineEnd) {
      // 行首 / 行尾的短横：唱到时一下下地「跳」。
      final double bx = vertical
          ? kit.cx - short / 2
          : lineStart
          ? kit.cx - kit.hw - pad - short
          : kit.cx + kit.hw + pad;
      final double by = vertical
          ? (lineStart ? kit.cy - kit.hh - pad - short : kit.cy + kit.hh + pad)
          : kit.cy - short / 2;
      final double grow = easeOutBack((time - first.sungAt) / 0.3, 2);
      bar(
        o,
        mainTint,
        vertical ? kit.cx : bx,
        vertical ? by : kit.cy,
        short,
        retract,
        grow,
        height,
        alpha,
      );
      return;
    }
    final double bx = vertical ? kit.cx + kit.hw + pad : kit.cx - kit.hw;
    final double by = vertical ? kit.cy - kit.hh : kit.cy + kit.hh + pad;
    bar(o, mainTint, bx, by, length, retract, k, height, alpha);
    bar(
      o,
      echoTint,
      bx + (vertical ? height * 1.6 : 0),
      by + (vertical ? 0 : height * 1.6),
      length,
      retract,
      math.max(0, k - 0.04),
      height * 0.35,
      alpha * 0.9,
    );
  };
}

class _LineDot {
  _LineDot(
    this.tint,
    this.x,
    this.y,
    this.glyph,
    this.order,
    this.litAt,
    this.size,
  );
  final int tint;
  final double x;
  final double y;
  final OrnamentGlyph? glyph;
  final double order;
  final double litAt;
  final double size;
}

// dots-line：沿文字方向的点线，逐点亮起。
OrnamentPainter _dotsLine(OrnamentKit kit) {
  final OrnamentPlacement placement = kit.spec.placement;
  final bool vertical = kit.vertical;
  final double spacing = kit.size * 0.3;
  final List<_LineDot> dots = <_LineDot>[];
  double litOf(double along) {
    // 字的位置投到这条线上：最近的那个字被唱到时，这颗点跟着亮。
    double best = double.infinity;
    double at = kit.start + 0.6;
    for (final OrnamentGlyph glyph in kit.glyphs) {
      final double d = ((vertical ? glyph.y : glyph.x) - along).abs();
      if (d < best) {
        best = d;
        at = glyph.sungAt;
      }
    }
    return at;
  }

  void push(
    double x,
    double y,
    double order,
    double litAt,
    double size, [
    OrnamentGlyph? glyph,
  ]) {
    dots.add(_LineDot(kit.color(dots.length), x, y, glyph, order, litAt, size));
  }

  final double pad = kit.size * 0.45;
  void lineAlong(
    double fromX,
    double fromY,
    double dx,
    double dy,
    double length,
    bool fade,
  ) {
    final int n = math.max(
      3,
      math.min(kit.count(48, 8), (length / spacing).round()),
    );
    for (int i = 0; i < n; i++) {
      final double s = n == 1 ? 0 : i / (n - 1);
      final double x = fromX + dx * s * length;
      final double y = fromY + dy * s * length;
      push(
        x,
        y,
        s,
        litOf(vertical ? y : x),
        kit.size * (fade ? 0.14 * (1 - s * 0.7) : 0.12),
      );
    }
  }

  if (placement == OrnamentPlacement.glyphs) {
    for (final (int i, OrnamentGlyph glyph) in kit.glyphs.indexed) {
      push(
        vertical ? glyph.size * 0.62 : 0,
        vertical ? 0 : glyph.size * 0.62,
        i / math.max(1, kit.glyphs.length - 1),
        glyph.sungAt,
        kit.size * 0.16,
        glyph,
      );
    }
  } else if (placement == OrnamentPlacement.lineStart ||
      placement == OrnamentPlacement.lineEnd) {
    final double sign = placement == OrnamentPlacement.lineStart ? -1 : 1;
    final double length = kit.size * 3;
    if (vertical) {
      lineAlong(kit.cx, kit.cy + sign * (kit.hh + pad), 0, sign, length, true);
    } else {
      lineAlong(kit.cx + sign * (kit.hw + pad), kit.cy, sign, 0, length, true);
    }
  } else if (placement == OrnamentPlacement.screen) {
    final double w = kit.width * 0.5;
    if (vertical) {
      lineAlong(
        kit.cx + kit.hw + pad * 2,
        -kit.height * 0.5,
        0,
        1,
        kit.height,
        false,
      );
    } else {
      lineAlong(-w, kit.cy + kit.hh + pad * 1.8, 1, 0, w * 2, false);
    }
  } else if (placement == OrnamentPlacement.corners) {
    final double arm = kit.size * 1.5;
    for (final (double sx, double sy) in _cornerSigns) {
      final double x0 = kit.cx + sx * (kit.hw + pad);
      final double y0 = kit.cy + sy * (kit.hh + pad);
      lineAlong(x0, y0, -sx, 0, arm, true);
      lineAlong(x0, y0, 0, -sy, arm * 0.7, true);
    }
  } else {
    // around / behind：字组下方一条（竖排在右侧），around 再在上方反向一条。
    if (vertical) {
      lineAlong(
        kit.cx + kit.hw + pad,
        kit.cy - kit.hh,
        0,
        1,
        kit.hh * 2,
        false,
      );
    } else {
      lineAlong(
        kit.cx - kit.hw,
        kit.cy + kit.hh + pad,
        1,
        0,
        kit.hw * 2,
        false,
      );
    }
    if (placement == OrnamentPlacement.around) {
      if (vertical) {
        lineAlong(
          kit.cx - kit.hw - pad,
          kit.cy + kit.hh,
          0,
          -1,
          kit.hh * 2,
          false,
        );
      } else {
        lineAlong(
          kit.cx + kit.hw,
          kit.cy - kit.hh - pad,
          -1,
          0,
          kit.hw * 2,
          false,
        );
      }
    }
  }
  return (OrnamentCanvas o, double time) {
    final List<GlyphAnchor> anchors = kit.anchors(time);
    final double x = kit.exit(time);
    final double runner = fract((time - kit.start) / 2.4);
    for (final _LineDot d in dots) {
      // 入场逐点出现（暗），被唱到时亮起并弹一下；退场从头逐点熄灭（阶梯）。
      final double appear = time - kit.start - d.order * 0.5;
      final bool off = x * 1.4 - d.order * 0.4 >= 0.5;
      if (appear < 0 || off) continue;
      double px = d.x;
      double py = d.y;
      double alpha = 1;
      if (d.glyph != null) {
        final (double gx, double gy, _, double ga) = _glyphNow(
          d.glyph!,
          anchors,
        );
        px += gx;
        py += gy;
        alpha = ga;
      }
      final bool lit = time >= d.litAt;
      final double pop = lit ? 1 + 0.8 * math.exp(-(time - d.litAt) / 0.12) : 1;
      final double run = math.max(0, 1 - (runner - d.order).abs() * 12);
      final double size =
          d.size *
          (lit ? 1 : 0.6) *
          pop *
          easeOutBack(appear / 0.2, 2.5) *
          (1 + run * 0.6);
      if (!(size > 0.3)) continue;
      o.sprite(
        OrnamentTexture.dot,
        px,
        py,
        size,
        size,
        0,
        alpha * (lit ? 1 : 0.35 + run * 0.5),
        d.tint,
      );
    }
  };
}
