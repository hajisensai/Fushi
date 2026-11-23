/// 一个镜头的歌词文字（移植 folia `hanabi/text/lyricText.ts` + `blocks.ts` + `glyphs.ts`）：排字、逐字入场 /
/// 强调 / 退场、字底色块、硬阴影、描边、辉光、乱码、分身、擦出、打字光标、下划线。
///
/// 字形先画成白色小图（PictureRecorder → toImageSync，按字号缓存），画的时候用 modulate 颜色滤镜着色，
/// 所以每帧只是一串 drawImageRect，不重新排版。
library;

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/modes/hanabi/hanabi_catalog.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/hanabi/hanabi_color.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/hanabi/hanabi_math.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/hanabi/hanabi_program.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/hanabi/hanabi_text_anim.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/hanabi/hanabi_text_layout.dart';

const double _outlineWidth = 0.085;
const double _shadowOffsetX = 0.07;
const double _shadowOffsetY = 0.085;
const double _shadowLag = 0.045;

/// 一个字某一时刻的位置（文字本地坐标）。
class GlyphAnchor {
  const GlyphAnchor({
    required this.char,
    required this.x,
    required this.y,
    required this.size,
    required this.sungAt,
    required this.sungEnd,
    required this.landedAt,
    required this.alpha,
    required this.blank,
  });
  final String char;
  final double x;
  final double y;
  final double size;
  final double sungAt;
  final double sungEnd;
  final double landedAt;
  final double alpha;
  final bool blank;
}

// ─── 色块参数（blocks.ts）──────────────────────────────────────────────

class BlockLayoutParams {
  const BlockLayoutParams(
    this.tracking,
    this.wordGap,
    this.lineHeight,
    this.minAdvance,
    this.stairStep,
    this.padding,
  );
  final double tracking;
  final double wordGap;
  final double lineHeight;
  final double minAdvance;
  final double stairStep;
  final double padding;
}

const Map<BlockStyle, BlockLayoutParams> _blockParams =
    <BlockStyle, BlockLayoutParams>{
      BlockStyle.none: BlockLayoutParams(0.02, 0.12, 1.12, 0, 0, 0.1),
      BlockStyle.tile: BlockLayoutParams(0.14, 0.12, 1.3, 0.86, 0, 0.1),
      BlockStyle.band: BlockLayoutParams(0.04, 0.14, 1.42, 0, 0, 0.3),
      BlockStyle.slant: BlockLayoutParams(0.04, 0.72, 1.42, 0, 0, 0.36),
      BlockStyle.double: BlockLayoutParams(0.04, 0.68, 1.5, 0, 0, 0.4),
      BlockStyle.pill: BlockLayoutParams(0.04, 0.6, 1.42, 0, 0, 0.4),
      BlockStyle.split: BlockLayoutParams(0.04, 0.58, 1.42, 0, 0, 0.3),
      BlockStyle.ticket: BlockLayoutParams(0.05, 0.72, 1.48, 0, 0, 0.45),
      BlockStyle.marker: BlockLayoutParams(0.03, 0.14, 1.3, 0, 0, 0.14),
      BlockStyle.outline: BlockLayoutParams(0.04, 0.3, 1.55, 0, 0, 0.32),
      BlockStyle.circle: BlockLayoutParams(0.24, 0.14, 1.4, 0.95, 0, 0.12),
      BlockStyle.stair: BlockLayoutParams(0.06, 0.12, 1.6, 0.82, 0.16, 0.3),
    };

BlockLayoutParams blockLayoutParams(BlockStyle style, bool hardShadow) {
  final BlockLayoutParams p = _blockParams[style]!;
  return BlockLayoutParams(
    p.tracking,
    p.wordGap,
    p.lineHeight,
    p.minAdvance,
    p.stairStep,
    p.padding + (hardShadow ? 0.08 : 0),
  );
}

/// 色块上的字用墨色，没有色块（或只是描边 / 荧光笔）的用纸白。
bool blockUsesInk(BlockStyle style) =>
    !(style == BlockStyle.none ||
        style == BlockStyle.outline ||
        style == BlockStyle.marker);

class RunFrame {
  RunFrame(
    this.cx,
    this.cy,
    this.angle,
    this.length,
    this.thickness,
    this.curved,
    this.points,
  );
  final double cx;
  final double cy;
  final double angle;
  final double length;
  final double thickness;
  final bool curved;
  final List<(double, double, double, double, double)> points;
}

/// 一串字的外框：沿平均方向的长度、厚度；弧形时带一条脊线。
RunFrame? runFrame(
  List<PlacedGlyph> glyphs,
  List<int> indices,
  double padL,
  double padT,
) {
  final List<PlacedGlyph> members = <PlacedGlyph>[
    for (final int i in indices)
      if (!glyphs[i].blank) glyphs[i],
  ];
  if (members.isEmpty) return null;
  double sin = 0;
  double cos = 0;
  for (final PlacedGlyph g in members) {
    sin += math.sin(g.angle);
    cos += math.cos(g.angle);
  }
  final double angle = math.atan2(sin, cos);
  final double tx = math.cos(angle);
  final double ty = math.sin(angle);
  final double nx = -ty;
  final double ny = tx;
  final PlacedGlyph origin = members.first;
  double minT = double.infinity;
  double maxT = double.negativeInfinity;
  double minN = double.infinity;
  double maxN = double.negativeInfinity;
  bool curved = false;
  for (final PlacedGlyph g in members) {
    if (math.atan2(math.sin(g.angle - angle), math.cos(g.angle - angle)).abs() >
        0.08) {
      curved = true;
    }
    final double px = g.x - origin.x;
    final double py = g.y - origin.y;
    final double pt = px * tx + py * ty;
    final double pn = px * nx + py * ny;
    minT = math.min(minT, pt - g.advance / 2);
    maxT = math.max(maxT, pt + g.advance / 2);
    minN = math.min(minN, pn - g.size * 0.56);
    maxN = math.max(maxN, pn + g.size * 0.56);
  }
  final double midT = (minT + maxT) / 2;
  final double midN = (minN + maxN) / 2;
  final List<(double, double, double, double, double)> points =
      <(double, double, double, double, double)>[];
  if (curved) {
    (double, double, double, double) edge(
      PlacedGlyph g,
      int side,
      double extra,
    ) => (
      g.x + math.cos(g.angle) * (g.advance / 2 + extra) * side,
      g.y + math.sin(g.angle) * (g.advance / 2 + extra) * side,
      -math.sin(g.angle),
      math.cos(g.angle),
    );
    final List<(double, double, double, double)> raw =
        <(double, double, double, double)>[edge(members.first, -1, padL)];
    for (int k = 1; k < members.length; k++) {
      final (double ax, double ay, double anx, double any) = edge(
        members[k - 1],
        1,
        0,
      );
      final (double bx, double by, double bnx, double bny) = edge(
        members[k],
        -1,
        0,
      );
      raw.add(((ax + bx) / 2, (ay + by) / 2, (anx + bnx) / 2, (any + bny) / 2));
    }
    raw.add(edge(members.last, 1, padL));
    double s = 0;
    for (int i = 0; i < raw.length; i++) {
      if (i > 0) {
        final double dx = raw[i].$1 - raw[i - 1].$1;
        final double dy = raw[i].$2 - raw[i - 1].$2;
        s += math.sqrt(dx * dx + dy * dy);
      }
      final double len = math.sqrt(
        raw[i].$3 * raw[i].$3 + raw[i].$4 * raw[i].$4,
      );
      final double l = len == 0 ? 1 : len;
      points.add((raw[i].$1, raw[i].$2, raw[i].$3 / l, raw[i].$4 / l, s));
    }
  }
  return RunFrame(
    origin.x + tx * midT + nx * midN,
    origin.y + ty * midT + ny * midN,
    angle,
    maxT - minT + padL * 2,
    maxN - minN + padT * 2,
    curved,
    points,
  );
}

enum _Anchor { center, start, bottom }

class _Part {
  _Part(
    this.color, {
    this.lag = 0,
    this.ox = 0,
    this.oy = 0,
    this.slide = 0,
    this.alpha = 1,
    this.back = false,
  });
  final int color;

  /// 画在后层（folia blocks.ts 的 `back` 容器：double 的影子层整体压在所有色块下面）。
  final bool back;
  final double lag;
  final double ox;
  final double oy;
  final double slide;
  final double alpha;
  ui.Path? path;
  List<(ui.Path, int, double)> extras = <(ui.Path, int, double)>[];
}

class _Piece {
  _Piece(
    this.parts,
    this.anchor,
    this.x,
    this.y,
    this.angle,
    this.length,
    this.thickness,
    this.unit,
    this.enterStart,
    this.enterDur,
    this.exitStart,
    this.exitEnd,
    this.rand,
    this.toCenterX,
    this.toCenterY,
  );
  final List<_Part> parts;
  final _Anchor anchor;
  final double x;
  final double y;
  final double angle;
  final double length;
  final double thickness;
  final double unit;
  final double enterStart;
  final double enterDur;
  final double exitStart;
  final double exitEnd;
  final List<double> rand;
  final double toCenterX;
  final double toCenterY;

  /// 动态形状（弧形色带、描边框）：按 a..b 的范围现画。
  void Function(
    ui.Canvas canvas,
    ui.Paint paint,
    double a,
    double b,
    double thick,
  )?
  redraw;
}

// ─── 字形小图 ───────────────────────────────────────────────────────────

/// 字宽（em），按字缓存。
final Map<String, double> _advanceCache = <String, double>{};

/// 字重：主题给了就用主题的，否则 800（folia `resolveThemeFontWeight(theme, 800)`）。
FontWeight hanabiGlyphWeight(TextStyle base) =>
    base.fontWeight ?? FontWeight.w800;

double measureGlyphAdvance(String char, TextStyle base) {
  if (char.trim().isEmpty) return char == '　' ? 1 : 0.3;
  if (isUprightGlyph(char)) return 1;
  final FontWeight weight = hanabiGlyphWeight(base);
  final String key = '${base.fontFamily}|${weight.value}|$char';
  final double? hit = _advanceCache[key];
  if (hit != null) return hit;
  final TextPainter tp = TextPainter(
    text: TextSpan(
      text: char,
      style: base.copyWith(fontSize: 100, fontWeight: weight, height: 1),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  final double advance = tp.width / 100;
  tp.dispose();
  if (_advanceCache.length > 4000) _advanceCache.clear();
  _advanceCache[key] = advance;
  return advance;
}

class GlyphEntry {
  GlyphEntry(this.px, this.side, this.fill, this.fat, this.glow);
  final double px;

  /// 小图在 px 字号下的边长（逻辑像素）。
  final double side;
  final ui.Image fill;
  final ui.Image? fat;
  final ui.Image? glow;

  void dispose() {
    fill.dispose();
    fat?.dispose();
    glow?.dispose();
  }
}

/// 超采样倍数（小图按 2× 画，放大时不糊）。
const double _supersample = 2;

GlyphEntry _paintGlyph(
  String char,
  double px,
  TextStyle base, {
  required double outline,
  required bool glow,
}) {
  // 一格的边长：字框 1.3 倍 + 描边 / 光晕的外扩，取整（folia glyphs.ts `cellSide`）。
  final double side =
      (px * 1.3 + 2 * math.max(outline * px, glow ? px * 0.32 : 0) + 4)
          .ceilToDouble();
  final FontWeight weight = hanabiGlyphWeight(base);
  final double ss = side * _supersample > 1024 ? 1024 / side : _supersample;
  final int pixels = math.max(1, (side * ss).ceil());
  ui.Image draw(void Function(ui.Canvas canvas) body) {
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final ui.Canvas canvas = ui.Canvas(recorder);
    canvas.scale(ss);
    body(canvas);
    final ui.Picture picture = recorder.endRecording();
    final ui.Image image = picture.toImageSync(pixels, pixels);
    picture.dispose();
    return image;
  }

  void text(ui.Canvas canvas, TextStyle style) {
    final TextPainter tp = TextPainter(
      text: TextSpan(
        text: char,
        style: base
            .merge(style)
            .copyWith(fontSize: px, height: 1, fontWeight: weight),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset((side - tp.width) / 2, (side - tp.height) / 2));
    tp.dispose();
  }

  final ui.Image fill = draw(
    (ui.Canvas c) => text(c, const TextStyle(color: Color(0xFFFFFFFF))),
  );
  final ui.Image? fat = outline > 0
      ? draw((ui.Canvas c) {
          text(
            c,
            TextStyle(
              foreground: Paint()
                ..style = PaintingStyle.stroke
                ..strokeWidth = outline * px * 2
                ..strokeJoin = StrokeJoin.round
                ..color = const Color(0xFFFFFFFF),
            ),
          );
          text(c, const TextStyle(color: Color(0xFFFFFFFF)));
        })
      : null;
  // 光晕字：Canvas 2D 的 fillText 带 shadowBlur = 0.22 px（高斯 σ = shadowBlur / 2）、shadowColor 白、
  // globalAlpha 0.85，画两遍。每遍先出模糊的影子再出实心字，两者都乘 0.85。
  final ui.Image? glowImage = glow
      ? draw((ui.Canvas c) {
          for (int i = 0; i < 2; i++) {
            text(
              c,
              TextStyle(
                foreground: Paint()
                  ..color = const Color(0xD9FFFFFF)
                  ..maskFilter = ui.MaskFilter.blur(
                    BlurStyle.normal,
                    px * 0.22 / 2,
                  ),
              ),
            );
            text(c, const TextStyle(color: Color(0xD9FFFFFF)));
          }
        })
      : null;
  return GlyphEntry(px, side, fill, fat, glowImage);
}

/// 画一张白色字形小图（中心在原点，单位是它自己的 px）。
void drawGlyphImage(
  ui.Canvas canvas,
  ui.Image image,
  double side,
  int color,
  double alpha, {
  ui.BlendMode blend = ui.BlendMode.srcOver,
  int half = 0,
  bool vertical = false,
}) {
  if (alpha <= 0.002) return;
  final double w = image.width.toDouble();
  final double h = image.height.toDouble();
  Rect src = Rect.fromLTWH(0, 0, w, h);
  Rect dst = Rect.fromCenter(center: Offset.zero, width: side, height: side);
  if (half != 0) {
    if (vertical) {
      src = half < 0
          ? Rect.fromLTWH(0, 0, w, h / 2)
          : Rect.fromLTWH(0, h / 2, w, h / 2);
      dst = half < 0
          ? Rect.fromLTRB(-side / 2, -side / 2, side / 2, 0)
          : Rect.fromLTRB(-side / 2, 0, side / 2, side / 2);
    } else {
      src = half < 0
          ? Rect.fromLTWH(0, 0, w / 2, h)
          : Rect.fromLTWH(w / 2, 0, w / 2, h);
      dst = half < 0
          ? Rect.fromLTRB(-side / 2, -side / 2, 0, side / 2)
          : Rect.fromLTRB(0, -side / 2, side / 2, side / 2);
    }
  }
  canvas.drawImageRect(
    image,
    src,
    dst,
    Paint()
      ..colorFilter = ColorFilter.mode(rgbColor(color), BlendMode.modulate)
      ..color = Color.fromRGBO(255, 255, 255, clamp01(alpha))
      ..blendMode = blend
      ..filterQuality = FilterQuality.medium,
  );
}

// ─── 一个字 ─────────────────────────────────────────────────────────────

class _Rig {
  _Rig({
    required this.index,
    required this.char,
    required this.x,
    required this.y,
    required this.size,
    required this.rotation,
    required this.angle,
    required this.tint,
    required this.sungTint,
    required this.flashTint,
    required this.backTint,
    required this.shadowTint,
    required this.outlineTint,
    required this.enterStart,
    required this.landed,
    required this.exitStart,
    required this.exitEnd,
    required this.sungAt,
    required this.sungEnd,
    required this.ctx,
  });
  final int index;
  final String char;
  final double x;
  final double y;
  final double size;
  final double rotation;
  final double angle;
  final int tint;
  final int sungTint;
  final int flashTint;
  final int backTint;
  final int shadowTint;
  final int outlineTint;
  final double enterStart;
  final double landed;
  final double exitStart;
  final double exitEnd;
  final double sungAt;
  final double sungEnd;
  final FxContext ctx;
  final GlyphPose pose = GlyphPose();
  final SingPose sing = SingPose();
  bool visible = false;
}

class _Underline {
  _Underline(
    this.members,
    this.x,
    this.y,
    this.angle,
    this.length,
    this.thick,
    this.from,
    this.to,
    this.color,
  );
  final List<_Rig> members;
  final double x;
  final double y;
  final double angle;
  final double length;
  final double thick;
  final double from;
  final double to;
  final int color;
}

/// 一个镜头的文字（本地坐标原点 = 文字区中心）。
class HanabiText {
  HanabiText({
    required HanabiLine line,
    required this.spec,
    required this.palette,
    required double regionWidth,
    required double regionHeight,
    required double unit,
    required String seed,
    required double enterAt,
    required double exitAt,
    required double exitDuration,
    required double motion,
    required double blockOpacity,
    required this.baseStyle,
    int? Function(String text)? keywordColor,
  }) : _motion = math.max(0, motion),
       _blockOpacity = clamp01(blockOpacity),
       _enterAt = enterAt {
    final HanabiRng rng = hanabiRng('$seed:text');
    final List<String> chars = line.chars;
    final List<LayoutWordInput> words = <LayoutWordInput>[
      for (final HanabiSegment s in line.segments)
        LayoutWordInput(
          text: chars.sublist(s.start, s.end).join(),
          start: s.start,
          end: s.end,
          blank: s.space || !s.wordLike,
          space: s.space,
        ),
    ];
    final List<double> scales = wordScales(words, spec.emphasis, seed);
    for (int i = 0; i < words.length; i++) {
      words[i].scale = scales[i];
    }
    final List<int> glyphWord = List<int>.filled(chars.length, 0);
    for (int w = 0; w < words.length; w++) {
      for (int g = words[w].start; g < words[w].end; g++) {
        glyphWord[g] = w;
      }
    }
    final List<LayoutGlyphInput> inputs = <LayoutGlyphInput>[
      for (int i = 0; i < chars.length; i++)
        LayoutGlyphInput(
          char: chars[i],
          advance: measureGlyphAdvance(chars[i], baseStyle),
          blank: chars[i].trim().isEmpty,
          upright: isUprightGlyph(chars[i]),
          word: glyphWord[i],
        ),
    ];
    final BlockLayoutParams lp = blockLayoutParams(spec.block, spec.hardShadow);
    placement = layoutText(
      inputs,
      words,
      LayoutParams(
        layout: spec.layout,
        regionWidth: regionWidth,
        regionHeight: regionHeight,
        fontPx: spec.heroSize * unit,
        tilt: spec.tilt,
        seed: seed,
        tracking: lp.tracking,
        wordGap: lp.wordGap,
        lineHeight: lp.lineHeight,
        minAdvance: lp.minAdvance,
        stairStep: lp.stairStep,
        padding: lp.padding,
      ),
    );
    final List<PlacedGlyph> glyphs = placement.glyphs;
    final double centerX = placement.bounds.cx;
    final double centerY = placement.bounds.cy;
    final List<int> visible = <int>[
      for (int i = 0; i < glyphs.length; i++)
        if (!glyphs[i].blank) i,
    ];
    final List<double> orderRanks = enterOrder(spec.enter, visible.length, rng);
    final List<double> enterRanks = List<double>.filled(chars.length, -1);
    for (int o = 0; o < visible.length; o++) {
      enterRanks[visible[o]] = orderRanks[o];
    }
    double firstSung = double.infinity;
    for (final int i in visible) {
      firstSung = math.min(firstSung, line.charStart[i]);
    }
    final double deadline = firstSung.isFinite ? firstSung : line.startTime;
    _enter = scheduleEnter(
      spec.enter,
      enterRanks,
      enterAt,
      spec.stagger,
      deadline,
    );
    final List<double> exitRanks = List<double>.filled(chars.length, -1);
    final List<double> exitShuffle =
        spec.exit == ExitFx.scatter || spec.exit == ExitFx.dissolve
        ? enterOrder(
            EnterFx.scramble,
            visible.length,
            hanabiRng('$seed:exit-order'),
          )
        : <double>[for (int o = 0; o < visible.length; o++) o.toDouble()];
    for (int o = 0; o < visible.length; o++) {
      exitRanks[visible[o]] = exitShuffle[o];
    }
    final ExitSchedule exit = scheduleExit(exitRanks, exitAt, exitDuration);
    final double arrival = _enter.duration * kEnterArrival[spec.enter]!;
    _buildBlocks(
      seed: seed,
      words: words,
      enterStart: <double>[for (final double s in _enter.start) s + arrival],
      exitStart: exit.start,
      exitEnd: exit.end,
      centerX: centerX,
      centerY: centerY,
    );
    _halves = spec.enter == EnterFx.split ? (placement.vertical ? 2 : 1) : 0;
    _scrambleChars = spec.enter == EnterFx.scramble
        ? pickScrambleChars(line.text, 14, hanabiRng('$seed:scramble'))
        : const <String>[];
    final int baseInk = blockUsesInk(spec.block) ? palette.ink : palette.paper;
    final int firstBlock = palette.blocks.isNotEmpty
        ? palette.blocks.first
        : palette.accent;
    final int backdrop = hanabiBackdropOf(palette);
    final double slideDistance =
        (math.max(regionWidth, regionHeight) * 0.8) /
            math.max(1, placement.fontPx) +
        3;
    for (int o = 0; o < visible.length; o++) {
      final int index = visible[o];
      final PlacedGlyph g = glyphs[index];
      final int? under = _glyphColor[index];
      // 关键字色（主题 wordColors）：先按字所在的词找，再按这个字找（folia lyricText.ts）。
      final int? keyword = keywordColor == null
          ? null
          : (keywordColor(
                  g.word >= 0 && g.word < words.length
                      ? words[g.word].text
                      : g.char,
                ) ??
                keywordColor(g.char));
      final HanabiGlyphColors colors = resolveHanabiGlyphColors(
        palette,
        keyword ?? baseInk,
        under ?? backdrop,
      );
      final int tint = colors.ink;
      final int outlineTint = tint == palette.paper || under == palette.paper
          ? firstBlock
          : palette.paper;
      final int shadowTint = under != null
          ? darkenRgb(under, 0.42)
          : spec.outline && outlineTint == firstBlock
          ? (palette.blocks.length > 1
                ? palette.blocks[1]
                : darkenRgb(firstBlock, 0.45))
          : firstBlock;
      _rigs.add(
        _Rig(
          index: index,
          char: g.char,
          x: g.x,
          y: g.y,
          size: g.size,
          rotation: g.rotation,
          angle: g.angle,
          tint: tint,
          sungTint: colors.sung,
          flashTint: colors.flash,
          backTint: colors.back,
          shadowTint: shadowTint,
          outlineTint: outlineTint,
          enterStart: _enter.start[index],
          landed: _enter.landed[index],
          exitStart: exit.start[index],
          exitEnd: exit.end[index],
          sungAt: line.charStart[index],
          sungEnd: line.charEnd[index],
          ctx: FxContext(
            rand: <double>[rng(), rng(), rng(), rng()],
            toCenterX: (centerX - g.x) / math.max(1, g.size),
            toCenterY: (centerY - g.y) / math.max(1, g.size),
            dirX: math.cos(g.angle),
            dirY: math.sin(g.angle),
            motion: _motion,
            slideDistance: slideDistance,
          ),
        ),
      );
      _rigOf[index] = _rigs.last;
    }
    _timesByIndex = <(double, double, double)>[
      for (int i = 0; i < glyphs.length; i++)
        (line.charStart[i], line.charEnd[i], _enter.landed[i]),
    ];
    if (spec.enter == EnterFx.stamp) {
      final Set<int> seen = <int>{};
      for (final _Rig rig in _rigs) {
        final int word = glyphs[rig.index].word;
        if (!seen.add(word)) continue;
        _impacts.add(rig.enterStart + _enter.duration * kStampImpact);
      }
    }
    _shakeAmplitude = placement.fontPx * 0.05 * _motion;
    if (spec.sing == SingFx.underline) _buildUnderlines(glyphs);
    _firstStart = _rigs.fold(
      double.infinity,
      (double m, _Rig r) => math.min(m, r.enterStart),
    );
    _lastLanded = _rigs.fold(
      double.negativeInfinity,
      (double m, _Rig r) => math.max(m, r.landed),
    );
    _exitFrom = _rigs.fold(
      double.infinity,
      (double m, _Rig r) => math.min(m, r.exitStart),
    );
  }

  final TextSpec spec;
  final HanabiPalette palette;
  final TextStyle baseStyle;
  final double _motion;
  final double _blockOpacity;
  final double _enterAt;
  late final TextPlacement placement;
  late final EnterSchedule _enter;
  late final List<(double, double, double)> _timesByIndex;
  final List<_Rig> _rigs = <_Rig>[];
  final Map<int, _Rig> _rigOf = <int, _Rig>{};
  final Map<int, int> _glyphColor = <int, int>{};
  final List<_Piece> _pieces = <_Piece>[];
  final List<double> _impacts = <double>[];
  final List<_Underline> _underlines = <_Underline>[];
  late final int _halves;
  late final List<String> _scrambleChars;
  late final double _shakeAmplitude;
  late final double _firstStart;
  late final double _lastLanded;
  late final double _exitFrom;
  final GlyphPose _scratchEnter = GlyphPose();
  final GlyphPose _scratchExit = GlyphPose();
  final GlyphPose _scratchShadow = GlyphPose();

  Map<String, GlyphEntry>? _atlas;
  List<GlyphEntry> _scramble = <GlyphEntry>[];
  double _evaluatedAt = double.nan;
  (double, double) _shake = (0, 0);
  double _anchorsAt = double.nan;
  List<GlyphAnchor> _anchorsCache = <GlyphAnchor>[];
  bool _disposed = false;

  /// 静止排好时的包围盒（本地坐标）。
  LayoutRect get bounds => placement.bounds;

  bool get prepared => _atlas != null;

  /// 画字形小图；已经画过返回 false。
  bool prepare() {
    if (_atlas != null || _disposed) return false;
    final Map<String, double> charPx = <String, double>{};
    double maxPx = 0;
    for (final _Rig rig in _rigs) {
      final double px = (rig.size * 1.12).ceilToDouble();
      charPx[rig.char] = math.max(charPx[rig.char] ?? 0, px);
      maxPx = math.max(maxPx, px);
    }
    final double outline = spec.outline ? _outlineWidth : 0;
    final bool glow = spec.sing == SingFx.glow;
    _atlas = <String, GlyphEntry>{
      for (final MapEntry<String, double> e in charPx.entries)
        e.key: _paintGlyph(
          e.key,
          math.max(4, e.value),
          baseStyle,
          outline: outline,
          glow: glow,
        ),
    };
    _scramble = <GlyphEntry>[
      for (final String c in _scrambleChars)
        _paintGlyph(
          c,
          math.max(4, maxPx),
          baseStyle,
          outline: outline,
          glow: false,
        ),
    ];
    return true;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final GlyphEntry e in _atlas?.values ?? const <GlyphEntry>[]) {
      e.dispose();
    }
    for (final GlyphEntry e in _scramble) {
      e.dispose();
    }
    _atlas = null;
    _scramble = <GlyphEntry>[];
  }

  // ─── 色块 ───

  void _buildBlocks({
    required String seed,
    required List<LayoutWordInput> words,
    required List<double> enterStart,
    required List<double> exitStart,
    required List<double> exitEnd,
    required double centerX,
    required double centerY,
  }) {
    final BlockStyle style = spec.block;
    if (style == BlockStyle.none) return;
    final List<int> colors = palette.blocks.isNotEmpty
        ? palette.blocks
        : <int>[palette.accent];
    int colorAt(int i) =>
        colors[((i % colors.length) + colors.length) % colors.length];
    int second(int i) =>
        colors.length > 1 ? colorAt(i + 1) : darkenRgb(colorAt(i), 0.35);
    final HanabiRng rng = hanabiRng('$seed:blocks');
    final List<PlacedGlyph> glyphs = placement.glyphs;
    final double fontPx = placement.fontPx;

    (double, double, double, double) timesOf(List<int> indices) {
      double first = double.infinity;
      double last = double.negativeInfinity;
      double xs = double.infinity;
      double xe = double.negativeInfinity;
      for (final int i in indices) {
        final double s = enterStart[i];
        if (!s.isFinite) continue;
        first = math.min(first, s);
        last = math.max(last, s);
        xs = math.min(xs, exitStart[i]);
        xe = math.max(xe, exitEnd[i]);
      }
      return (first, last, xs, xe);
    }

    _Piece piece(
      List<_Part> parts,
      _Anchor anchor,
      double x,
      double y,
      double angle,
      double length,
      double thickness,
      double unit,
      double es,
      double ed,
      double xs,
      double xe,
    ) {
      final _Piece p = _Piece(
        parts,
        anchor,
        x,
        y,
        angle,
        length,
        thickness,
        unit,
        es,
        ed,
        xs,
        xe,
        <double>[rng(), rng(), rng(), rng()],
        (centerX - x) / math.max(1, unit),
        (centerY - y) / math.max(1, unit),
      );
      _pieces.add(p);
      return p;
    }

    final bool perGlyph =
        style == BlockStyle.tile ||
        style == BlockStyle.circle ||
        style == BlockStyle.stair ||
        style == BlockStyle.marker;
    final Map<int, double> stairDrop = <int, double>{};
    if (style == BlockStyle.stair) {
      final Map<String, List<int>> groups = <String, List<int>>{};
      for (int i = 0; i < glyphs.length; i++) {
        if (glyphs[i].blank) continue;
        groups
            .putIfAbsent('${glyphs[i].row}:${glyphs[i].word}', () => <int>[])
            .add(i);
      }
      for (final List<int> indices in groups.values) {
        final PlacedGlyph first = glyphs[indices.first];
        final double nx = -math.sin(first.angle);
        final double ny = math.cos(first.angle);
        final List<double> bottoms = <double>[
          for (final int i in indices)
            (glyphs[i].x - first.x) * nx +
                (glyphs[i].y - first.y) * ny +
                glyphs[i].size * 0.56,
        ];
        final double lowest = bottoms.reduce(math.max);
        for (int k = 0; k < indices.length; k++) {
          stairDrop[indices[k]] = lowest - bottoms[k];
        }
      }
    }
    if (perGlyph) {
      int ordinal = 0;
      for (int index = 0; index < glyphs.length; index++) {
        final PlacedGlyph g = glyphs[index];
        if (g.blank || !enterStart[index].isFinite) continue;
        final int color = style == BlockStyle.marker
            ? colorAt(g.word)
            : colorAt(ordinal);
        ordinal++;
        final double es =
            enterStart[index] - (style == BlockStyle.marker ? 0 : 0.05);
        final double ed = style == BlockStyle.marker ? 0.28 : 0.34;
        final double size = g.size;
        _glyphColor[index] = color;
        if (style == BlockStyle.tile || style == BlockStyle.circle) {
          final _Part part = _Part(color);
          if (style == BlockStyle.tile) {
            final double inset = size * 0.035;
            part.path = ui.Path()
              ..addRRect(
                RRect.fromLTRBR(
                  -g.boxW / 2 + inset,
                  -g.boxH / 2,
                  g.boxW / 2 - inset,
                  g.boxH / 2,
                  Radius.circular(size * 0.06),
                ),
              );
          } else {
            part.path = ui.Path()
              ..addOval(
                Rect.fromCircle(
                  center: Offset.zero,
                  radius: math.max(size * 0.64, math.max(g.boxW, g.boxH) * 0.5),
                ),
              );
          }
          piece(
            <_Part>[part],
            _Anchor.center,
            g.x,
            g.y,
            g.rotation,
            g.boxW,
            g.boxH,
            size,
            es,
            ed,
            exitStart[index],
            exitEnd[index],
          );
          continue;
        }
        final double tx = math.cos(g.angle);
        final double ty = math.sin(g.angle);
        final double nx = -ty;
        final double ny = tx;
        if (style == BlockStyle.stair) {
          final double h = size * 1.12;
          final double depth = size * 0.3 + (stairDrop[index] ?? 0);
          final _Part part = _Part(color)
            ..path = (ui.Path()
              ..addRect(
                Rect.fromLTWH(
                  -g.advance / 2,
                  -(h + depth),
                  g.advance,
                  h + depth,
                ),
              ));
          // 台阶的顶面一条亮边（白 α 0.45，经 tint 后是同色叠一层 0.45）。
          part.extras.add((
            ui.Path()..addRect(
              Rect.fromLTWH(
                -g.advance / 2,
                -(h + depth),
                g.advance,
                size * 0.07,
              ),
            ),
            color,
            0.45,
          ));
          piece(
            <_Part>[part],
            _Anchor.bottom,
            g.x + nx * (h / 2 + depth),
            g.y + ny * (h / 2 + depth),
            g.angle,
            g.advance,
            h + depth,
            size,
            es,
            ed,
            exitStart[index],
            exitEnd[index],
          );
          continue;
        }
        final double l = g.advance + size * 0.08;
        final double top = size * 0.06;
        final double bottom = size * 0.58;
        final double wob = size * 0.06;
        final _Part part = _Part(color, alpha: 0.92)
          ..path = (ui.Path()
            ..moveTo(wob, top + wob * 0.5)
            ..lineTo(l, top)
            ..lineTo(l - wob, bottom)
            ..lineTo(0, bottom - wob * 0.4)
            ..close());
        piece(
          <_Part>[part],
          _Anchor.start,
          g.x - tx * l / 2,
          g.y - ty * l / 2,
          g.angle,
          l,
          size * 0.5,
          size,
          es,
          ed,
          exitStart[index],
          exitEnd[index],
        );
      }
    }
    final bool perWord =
        style == BlockStyle.slant ||
        style == BlockStyle.double ||
        style == BlockStyle.pill ||
        style == BlockStyle.split ||
        style == BlockStyle.ticket;
    if (perWord) {
      final List<(List<int>, int)> groups = <(List<int>, int)>[];
      for (int index = 0; index < glyphs.length; index++) {
        final PlacedGlyph g = glyphs[index];
        if (g.blank) continue;
        final bool punct = g.word < words.length && words[g.word].blank;
        if (groups.isNotEmpty) {
          final PlacedGlyph lastGlyph = glyphs[groups.last.$1.last];
          if (lastGlyph.row == g.row && (groups.last.$2 == g.word || punct)) {
            groups.last.$1.add(index);
            continue;
          }
        }
        groups.add((<int>[index], g.word));
      }
      for (int ordinal = 0; ordinal < groups.length; ordinal++) {
        final List<int> indices = groups[ordinal].$1;
        final RunFrame? frame = runFrame(
          glyphs,
          indices,
          fontPx * (style == BlockStyle.pill ? 0.26 : 0.2),
          fontPx * 0.1,
        );
        if (frame == null) continue;
        final (double first, double last, double xs, double xe) = timesOf(
          indices,
        );
        if (!first.isFinite) continue;
        final int color = colorAt(ordinal);
        final int color2 = second(ordinal);
        final double l = frame.length;
        final double t = frame.thickness;
        final double tx = math.cos(frame.angle);
        final double ty = math.sin(frame.angle);
        final bool sweep =
            style == BlockStyle.slant || style == BlockStyle.double;
        final double es = first - 0.08;
        final double ed = sweep ? last - first + 0.42 : 0.44;
        final double bx = sweep ? frame.cx - tx * l / 2 : frame.cx;
        final double by = sweep ? frame.cy - ty * l / 2 : frame.cy;
        for (final int i in indices) {
          _glyphColor[i] = color;
        }
        switch (style) {
          case BlockStyle.slant:
            final double sk = t * 0.36;
            final _Part part = _Part(color)
              ..path = (ui.Path()
                ..moveTo(sk / 2, -t / 2)
                ..lineTo(l + sk / 2, -t / 2)
                ..lineTo(l - sk / 2, t / 2)
                ..lineTo(-sk / 2, t / 2)
                ..close());
            piece(
              <_Part>[part],
              _Anchor.start,
              bx,
              by,
              frame.angle,
              l,
              t,
              t / 1.3,
              es,
              ed,
              xs,
              xe,
            );
          case BlockStyle.double:
            final double off = t * 0.13;
            final ui.Path rect = ui.Path()
              ..addRect(Rect.fromLTWH(0, -t / 2, l, t));
            piece(
              <_Part>[
                _Part(color2, lag: 0.09, ox: off, oy: off * 1.1, back: true)
                  ..path = rect,
                _Part(color)..path = rect,
              ],
              _Anchor.start,
              bx,
              by,
              frame.angle,
              l,
              t,
              t / 1.3,
              es,
              ed,
              xs,
              xe,
            );
          case BlockStyle.pill:
            final _Part part = _Part(color)
              ..path = (ui.Path()
                ..addRRect(
                  RRect.fromLTRBR(
                    -l / 2,
                    -t / 2,
                    l / 2,
                    t / 2,
                    Radius.circular(t / 2),
                  ),
                ));
            piece(
              <_Part>[part],
              _Anchor.center,
              bx,
              by,
              frame.angle,
              l,
              t,
              t / 1.3,
              es,
              ed,
              xs,
              xe,
            );
          case BlockStyle.split:
            piece(
              <_Part>[
                _Part(color, slide: -1)
                  ..path = (ui.Path()
                    ..addRect(Rect.fromLTWH(-l / 2, -t / 2, l, t / 2 + 0.5))),
                _Part(color2, slide: 1)
                  ..path = (ui.Path()
                    ..addRect(Rect.fromLTWH(-l / 2, 0, l, t / 2))),
              ],
              _Anchor.center,
              bx,
              by,
              frame.angle,
              l,
              t,
              t / 1.3,
              es,
              ed,
              xs,
              xe,
            );
          case BlockStyle.ticket:
            final double r = t * 0.2;
            final ui.Path path = ui.Path()
              ..moveTo(-l / 2, -t / 2)
              ..lineTo(l / 2, -t / 2)
              ..lineTo(l / 2, -r)
              ..arcToPoint(
                Offset(l / 2, r),
                radius: Radius.circular(r),
                clockwise: false,
              )
              ..lineTo(l / 2, t / 2)
              ..lineTo(-l / 2, t / 2)
              ..lineTo(-l / 2, r)
              ..arcToPoint(
                Offset(-l / 2, -r),
                radius: Radius.circular(r),
                clockwise: false,
              )
              ..close();
            final _Part part = _Part(color)..path = path;
            final double stubX = l / 2 - math.min(t * 0.62, l * 0.2);
            final ui.Path dots = ui.Path();
            for (
              double y = -t / 2 + t * 0.14;
              y < t / 2 - t * 0.1;
              y += t * 0.16
            ) {
              dots.addOval(
                Rect.fromCircle(
                  center: Offset(stubX, y),
                  radius: math.max(0.8, t * 0.028),
                ),
              );
            }
            part.extras.add((dots, 0x000000, 0.28));
            piece(
              <_Part>[part],
              _Anchor.center,
              bx,
              by,
              frame.angle,
              l,
              t,
              t / 1.3,
              es,
              ed,
              xs,
              xe,
            );
          default:
            break;
        }
      }
    }
    if (style == BlockStyle.band || style == BlockStyle.outline) {
      for (int rowIndex = 0; rowIndex < placement.rows.length; rowIndex++) {
        final List<int> row = placement.rows[rowIndex];
        final double padL = fontPx * (style == BlockStyle.band ? 0.32 : 0.26);
        final double padT = fontPx * (style == BlockStyle.band ? 0.12 : 0.16);
        final RunFrame? frame = runFrame(glyphs, row, padL, padT);
        if (frame == null) continue;
        final (double first, double last, double xs, double xe) = timesOf(row);
        if (!first.isFinite) continue;
        final int color = colorAt(rowIndex);
        for (final int i in row) {
          if (!glyphs[i].blank) _glyphColor[i] = color;
        }
        final double l = frame.length;
        final double t = frame.thickness;
        final double tx = math.cos(frame.angle);
        final double ty = math.sin(frame.angle);
        final double es = first - 0.1;
        final double ed = last - first + 0.45;
        if (style == BlockStyle.band && frame.curved) {
          final _Piece p = piece(
            <_Part>[_Part(color)],
            _Anchor.center,
            0,
            0,
            0,
            l,
            t,
            t / 1.3,
            es,
            ed,
            xs,
            xe,
          );
          final List<(double, double, double, double, double)> points =
              frame.points;
          final double total = points.last.$5 == 0 ? 1 : points.last.$5;
          p.redraw =
              (
                ui.Canvas canvas,
                ui.Paint paint,
                double a,
                double b,
                double thick,
              ) {
                if (b <= a) return;
                final double sa = a * total;
                final double sb = b * total;
                (double, double, double, double) at(double s) {
                  int k = 1;
                  while (k < points.length - 1 && points[k].$5 < s) {
                    k++;
                  }
                  final (double, double, double, double, double) p0 =
                      points[k - 1];
                  final (double, double, double, double, double) p1 = points[k];
                  final double f = p1.$5 > p0.$5
                      ? clamp01((s - p0.$5) / (p1.$5 - p0.$5))
                      : 0;
                  return (
                    p0.$1 + (p1.$1 - p0.$1) * f,
                    p0.$2 + (p1.$2 - p0.$2) * f,
                    p0.$3 + (p1.$3 - p0.$3) * f,
                    p0.$4 + (p1.$4 - p0.$4) * f,
                  );
                }

                final List<(double, double, double, double)> spine =
                    <(double, double, double, double)>[
                      at(sa),
                      for (final (double, double, double, double, double) pt
                          in points)
                        if (pt.$5 > sa && pt.$5 < sb)
                          (pt.$1, pt.$2, pt.$3, pt.$4),
                      at(sb),
                    ];
                final double half = (t / 2) * thick;
                final ui.Path path = ui.Path();
                for (int k = 0; k < spine.length; k++) {
                  final double x = spine[k].$1 - spine[k].$3 * half;
                  final double y = spine[k].$2 - spine[k].$4 * half;
                  if (k == 0) {
                    path.moveTo(x, y);
                  } else {
                    path.lineTo(x, y);
                  }
                }
                for (int k = spine.length - 1; k >= 0; k--) {
                  path.lineTo(
                    spine[k].$1 + spine[k].$3 * half,
                    spine[k].$2 + spine[k].$4 * half,
                  );
                }
                path.close();
                canvas.drawPath(path, paint);
              };
          continue;
        }
        if (style == BlockStyle.band) {
          final _Part part = _Part(color)
            ..path = (ui.Path()..addRect(Rect.fromLTWH(0, -t / 2, l, t)));
          if (colors.length > 1) {
            part.extras.add((
              ui.Path()..addRect(Rect.fromLTWH(0, t / 2 - t * 0.1, l, t * 0.1)),
              second(rowIndex),
              1,
            ));
          }
          piece(
            <_Part>[part],
            _Anchor.start,
            frame.cx - tx * l / 2,
            frame.cy - ty * l / 2,
            frame.angle,
            l,
            t,
            t / 1.3,
            es,
            ed,
            xs,
            xe,
          );
          continue;
        }
        final _Piece p = piece(
          <_Part>[_Part(color)],
          _Anchor.center,
          frame.cx,
          frame.cy,
          frame.angle,
          l,
          t,
          t / 1.3,
          es,
          ed,
          xs,
          xe,
        );
        final double stroke = math.max(1.5, t * 0.07);
        final double perimeter = 2 * (l + t);
        final List<(double, double)> corners = <(double, double)>[
          (-l / 2, -t / 2),
          (l / 2, -t / 2),
          (l / 2, t / 2),
          (-l / 2, t / 2),
        ];
        void trace(ui.Path path, int startCorner, double from, double to) {
          double travelled = 0;
          bool started = false;
          for (int k = 0; k < 4 && travelled < to * perimeter; k++) {
            final (double ax, double ay) = corners[(startCorner + k) % 4];
            final (double bx2, double by2) = corners[(startCorner + k + 1) % 4];
            final double seg = math.sqrt(
              (bx2 - ax) * (bx2 - ax) + (by2 - ay) * (by2 - ay),
            );
            final double s0 = math.max(from * perimeter, travelled);
            final double s1 = math.min(to * perimeter, travelled + seg);
            if (s1 > s0) {
              final double f0 = (s0 - travelled) / seg;
              final double f1 = (s1 - travelled) / seg;
              if (!started) {
                path.moveTo(ax + (bx2 - ax) * f0, ay + (by2 - ay) * f0);
                started = true;
              }
              path.lineTo(ax + (bx2 - ax) * f1, ay + (by2 - ay) * f1);
            }
            travelled += seg;
          }
        }

        p.redraw =
            (
              ui.Canvas canvas,
              ui.Paint paint,
              double a,
              double b,
              double thick,
            ) {
              if (b <= a) return;
              final ui.Path path = ui.Path();
              trace(path, 0, a / 2, b / 2);
              trace(path, 2, a / 2, b / 2);
              canvas.drawPath(
                path,
                paint
                  ..style = PaintingStyle.stroke
                  ..strokeWidth = stroke
                  ..strokeJoin = StrokeJoin.miter
                  ..strokeCap = StrokeCap.square,
              );
            };
      }
    }
  }

  static const Set<BlockStyle> _sweep = <BlockStyle>{
    BlockStyle.band,
    BlockStyle.slant,
    BlockStyle.double,
    BlockStyle.marker,
    BlockStyle.outline,
  };

  final GlyphPose _blockPose = GlyphPose();

  /// 字底色块。
  void paintBlocks(ui.Canvas canvas, double time) {
    if (_pieces.isEmpty) return;
    _evaluateAll(time);
    final BlockStyle style = spec.block;
    final bool perGlyph =
        style == BlockStyle.tile ||
        style == BlockStyle.circle ||
        style == BlockStyle.stair ||
        style == BlockStyle.marker;
    canvas.save();
    canvas.translate(_shake.$1, _shake.$2);
    for (int layer = 0; layer < 2; layer++) {
      _paintBlockLayer(canvas, time, style, perGlyph, back: layer == 0);
    }
    canvas.restore();
  }

  void _paintBlockLayer(
    ui.Canvas canvas,
    double time,
    BlockStyle style,
    bool perGlyph, {
    required bool back,
  }) {
    for (final _Piece piece in _pieces) {
      for (final _Part part in piece.parts) {
        if (part.back != back) continue;
        final double t = time - part.lag;
        if (t < piece.enterStart || t >= piece.exitEnd) continue;
        final double q = clamp01(
          (t - piece.enterStart) / math.max(1e-3, piece.enterDur),
        );
        final double xq = piece.exitEnd > piece.exitStart
            ? clamp01((t - piece.exitStart) / (piece.exitEnd - piece.exitStart))
            : 0;
        final double tx = math.cos(piece.angle);
        final double ty = math.sin(piece.angle);
        double sx = 1;
        double sy = 1;
        double rot = 0;
        double alpha = 1;
        double dx = 0;
        double dy = 0;
        double a = 0;
        double b = 1;
        switch (style) {
          case BlockStyle.tile:
            final double s = easeOutBack(q, 2.2);
            sx = s;
            sy = s;
            rot = (piece.rand[0] - 0.5) * 0.6 * (1 - easeOutCubic(q));
            alpha = clamp01(q * 5);
          case BlockStyle.circle:
            final double s = q >= 1
                ? 1
                : 1 - math.cos(q * math.pi * 3.5) * math.exp(-5 * q) * (1 - q);
            sx = s;
            sy = s;
            alpha = clamp01(q * 5);
          case BlockStyle.stair:
            sy = math.max(0, easeOutBack(q, 1.8));
            alpha = clamp01(q * 6);
          case BlockStyle.marker:
            b = easeOutCubic(q);
          case BlockStyle.band:
            b = easeOutQuart(q);
            sy = q < 0.22
                ? 0.14
                : 0.14 + 0.86 * easeOutBack((q - 0.22) / 0.78, 1.8);
          case BlockStyle.slant:
          case BlockStyle.double:
            b = easeOutExpo(q);
          case BlockStyle.outline:
            b = easeInOutCubic(q);
          case BlockStyle.pill:
            sx = 0.2 + 0.8 * easeOutBack(q, 1.4);
            sy = math.max(0, easeOutBack(clamp01(q * 1.5), 2.2));
            alpha = clamp01(q * 4);
          case BlockStyle.split:
            final double e = easeOutExpo(q);
            dx = tx * part.slide * (1 - e) * piece.length * 0.7;
            dy = ty * part.slide * (1 - e) * piece.length * 0.7;
            alpha = clamp01(q * 4);
          case BlockStyle.ticket:
            sy = math.max(0, easeOutBack(q, 2.5));
            sx = 0.7 + 0.3 * easeOutCubic(q);
            rot = -0.25 * (1 - easeOutCubic(q));
            alpha = clamp01(q * 4);
          case BlockStyle.none:
            break;
        }
        if (xq > 0) {
          final FxContext ctx = FxContext(
            rand: piece.rand,
            toCenterX: piece.toCenterX,
            toCenterY: piece.toCenterY,
            dirX: tx,
            dirY: ty,
            motion: _motion,
          )..time = t - piece.exitStart;
          if (_sweep.contains(style)) {
            a = math.max(a, easeInOutCubic(xq));
            if (spec.exit == ExitFx.blink || spec.exit == ExitFx.dissolve) {
              exitPose(spec.exit, xq, ctx, _blockPose);
              alpha *= _blockPose.alpha;
            } else {
              alpha *= 1 - clamp01((xq - 0.85) / 0.15);
            }
          } else {
            exitPose(spec.exit, xq, ctx, _blockPose);
            dx += _blockPose.dx * piece.unit;
            dy += _blockPose.dy * piece.unit;
            rot += _blockPose.rotation * (perGlyph ? 1 : 0.4);
            sx *= _blockPose.scaleX;
            sy *= _blockPose.scaleY;
            alpha *= _blockPose.alpha;
          }
        }
        if (b <= a || alpha <= 0.001) continue;
        final double opacity = alpha * _blockOpacity * part.alpha;
        final ui.Paint paint = ui.Paint()
          ..color = rgbColor(part.color, opacity);
        canvas.save();
        final ui.Path? path = part.path;
        if (piece.redraw != null) {
          canvas.translate(piece.x + dx, piece.y + dy);
          canvas.rotate(piece.angle + rot);
          canvas.scale(sx, style == BlockStyle.outline ? sy : 1);
          piece.redraw!(canvas, paint, a, b, sy);
          canvas.restore();
          continue;
        }
        double px = piece.x + dx + part.ox;
        double py = piece.y + dy + part.oy;
        if (piece.anchor == _Anchor.start) {
          px += tx * piece.length * a;
          py += ty * piece.length * a;
          sx *= b - a;
        }
        canvas.translate(px, py);
        canvas.rotate(piece.angle + rot);
        canvas.scale(sx, sy);
        if (path != null) canvas.drawPath(path, paint);
        for (final (ui.Path extra, int color, double extraAlpha)
            in part.extras) {
          canvas.drawPath(
            extra,
            ui.Paint()..color = rgbColor(color, opacity * extraAlpha),
          );
        }
        canvas.restore();
      }
    }
  }

  // ─── 逐字 ───

  bool _evaluate(
    _Rig rig,
    double time,
    double lag,
    GlyphPose out,
    SingPose? singOut,
  ) {
    final double t = time - lag;
    if (!(t >= rig.enterStart) || t >= rig.exitEnd) {
      out.reset();
      out.alpha = 0;
      singOut?.reset();
      return false;
    }
    rig.ctx.time = t - rig.enterStart;
    enterPose(
      spec.enter,
      (t - rig.enterStart) / math.max(1e-3, _enter.duration),
      rig.ctx,
      _scratchEnter,
    );
    rig.ctx.time = t - rig.exitStart;
    final double span = rig.exitEnd - rig.exitStart;
    exitPose(
      spec.exit,
      span > 0 ? (t - rig.exitStart) / span : 0,
      rig.ctx,
      _scratchExit,
    );
    combinePoses(_scratchEnter, _scratchExit, out);
    if (singOut != null) {
      if (t >= rig.landed) {
        singPose(
          spec.sing,
          t - rig.sungAt,
          rig.sungEnd - rig.sungAt,
          rig.ctx.rand[3],
          _motion,
          singOut,
        );
      } else {
        singOut.reset();
      }
    }
    return out.alpha > 0.002;
  }

  void _evaluateAll(double time) {
    if (time == _evaluatedAt) return;
    _evaluatedAt = time;
    _shake = _impacts.isNotEmpty
        ? stampShake(time, _impacts, _shakeAmplitude)
        : (0, 0);
    for (final _Rig rig in _rigs) {
      rig.visible = _evaluate(rig, time, 0, rig.pose, rig.sing);
    }
  }

  void _withTransform(
    ui.Canvas canvas,
    double x,
    double y,
    double rotation,
    double sx,
    double sy,
    double skew,
    void Function() body,
  ) {
    canvas.save();
    canvas.translate(x, y);
    if (rotation != 0) canvas.rotate(rotation);
    // Pixi 的 skew.x：x' = x + sin(k)·y，y' = cos(k)·y（矩阵 c = sin k、d = cos k）。
    if (skew != 0) canvas.transform(_skewMatrix(skew));
    canvas.scale(sx == 0 ? 1e-4 : sx, sy == 0 ? 1e-4 : sy);
    body();
    canvas.restore();
  }

  static Float64List _skewMatrix(double skew) {
    final Float64List m = Float64List(16);
    m[0] = 1;
    m[4] = math.sin(skew);
    m[5] = math.cos(skew);
    m[10] = 1;
    m[15] = 1;
    return m;
  }

  /// 字（阴影 → 描边 → 辉光 → 分身 → 正文 → 光标 / 下划线）。
  void paintGlyphs(ui.Canvas canvas, double time) {
    if (_rigs.isEmpty || _disposed) return;
    prepare();
    final Map<String, GlyphEntry> atlas = _atlas!;
    _evaluateAll(time);
    canvas.save();
    canvas.translate(_shake.$1, _shake.$2);
    final bool wiping =
        spec.enter == EnterFx.wipe && time >= _firstStart && time < _lastLanded;
    if (wiping) {
      final ui.Path clip = ui.Path();
      for (final _Rig rig in _rigs) {
        if (!rig.visible) continue;
        final GlyphPose pose = rig.pose;
        final double size = rig.size;
        final PlacedGlyph g = placement.glyphs[rig.index];
        final double tx = math.cos(rig.angle);
        final double ty = math.sin(rig.angle);
        final double nx = -ty;
        final double ny = tx;
        final double margin = size * 0.2;
        final double along = g.advance + margin * 2;
        final double t0 = -along / 2;
        final double t1 = t0 + along * pose.reveal;
        if (t1 <= t0) continue;
        final double n0 = -size * 0.85;
        final double n1 = size * 0.85;
        final double cx = rig.x + pose.dx * size;
        final double cy = rig.y + pose.dy * size;
        clip
          ..moveTo(cx + tx * t0 + nx * n0, cy + ty * t0 + ny * n0)
          ..lineTo(cx + tx * t1 + nx * n0, cy + ty * t1 + ny * n0)
          ..lineTo(cx + tx * t1 + nx * n1, cy + ty * t1 + ny * n1)
          ..lineTo(cx + tx * t0 + nx * n1, cy + ty * t0 + ny * n1)
          ..close();
      }
      canvas.save();
      canvas.clipPath(clip);
    }
    // 每层按顺序画一遍（与 folia 的分层容器一致）。
    for (int layer = 0; layer < 5; layer++) {
      for (final _Rig rig in _rigs) {
        if (!rig.visible) continue;
        final GlyphPose pose = rig.pose;
        final SingPose sing = rig.sing;
        final GlyphEntry entry0 = atlas[rig.char]!;
        final GlyphEntry? scrambled = pose.scramble >= 0 && _scramble.isNotEmpty
            ? _scramble[pose.scramble % _scramble.length]
            : null;
        final GlyphEntry entry = scrambled ?? entry0;
        final double size = rig.size;
        final double base = size / entry0.px;
        final double scrambleScale = scrambled != null
            ? entry0.px / scrambled.px
            : 1;
        final double x = rig.x + (pose.dx + sing.dx) * size;
        final double y = rig.y + (pose.dy + sing.dy) * size;
        final double rotation = rig.rotation + pose.rotation + sing.rotation;
        final double sx = base * pose.scaleX * sing.scale * sing.scaleX;
        final double sy = base * pose.scaleY * sing.scale * sing.scaleY;
        final bool splitting = pose.split > 0.001 && _halves != 0;
        final double attach = splitting ? 1 - clamp01(pose.split * 3) : 1;
        switch (layer) {
          case 0: // 硬阴影（比正文晚一点点，拖出层次）
            if (!spec.hardShadow) break;
            final GlyphPose lagged =
                _evaluate(rig, time, _shadowLag, _scratchShadow, null)
                ? _scratchShadow
                : pose;
            final double lx =
                rig.x + (lagged.dx + sing.dx) * size + _shadowOffsetX * size;
            final double ly =
                rig.y + (lagged.dy + sing.dy) * size + _shadowOffsetY * size;
            final double a = math.min(pose.alpha, lagged.alpha) * attach;
            _withTransform(
              canvas,
              lx,
              ly,
              rig.rotation + lagged.rotation + sing.rotation,
              base * lagged.scaleX * sing.scale * sing.scaleX * scrambleScale,
              base * lagged.scaleY * sing.scale * sing.scaleY * scrambleScale,
              lagged.skew,
              () => drawGlyphImage(
                canvas,
                entry.fat ?? entry.fill,
                entry.side,
                rig.shadowTint,
                a,
              ),
            );
          case 1: // 描边
            if (!spec.outline || entry.fat == null) break;
            _withTransform(
              canvas,
              x,
              y,
              rotation,
              sx * scrambleScale,
              sy * scrambleScale,
              pose.skew,
              () => drawGlyphImage(
                canvas,
                entry.fat!,
                entry.side,
                rig.outlineTint,
                pose.alpha * attach,
              ),
            );
          case 2: // 唱到时的辉光
            if (entry0.glow == null || sing.glow <= 0.001) break;
            final double k = 1 + 0.14 * sing.glow;
            _withTransform(
              canvas,
              x,
              y,
              rotation,
              sx * k,
              sy * k,
              0,
              () => drawGlyphImage(
                canvas,
                entry0.glow!,
                entry0.side,
                palette.glow,
                pose.alpha * sing.glow * 0.95,
                blend: ui.BlendMode.plus,
              ),
            );
          case 3: // 分身：分裂、色差、残影
            int tint = mixRgb(rig.tint, rig.sungTint, sing.color);
            tint = mixRgb(tint, rig.flashTint, sing.flash);
            // 残影与正文同色（folia 在设 fx 着色前已按背面换色）。
            if (pose.backside) tint = rig.backTint;
            if (splitting) {
              final double sep = pose.split;
              final double c = math.cos(rotation);
              final double s = math.sin(rotation);
              final (double ax, double ay) = _halves == 1
                  ? (-1.3 * sep, -0.45 * sep)
                  : (-0.45 * sep, -1.3 * sep);
              final double ox = (ax * c - ay * s) * size;
              final double oy = (ax * s + ay * c) * size;
              for (final int half in const <int>[-1, 1]) {
                _withTransform(
                  canvas,
                  x + ox * half,
                  y + oy * half,
                  rotation,
                  sx,
                  sy,
                  pose.skew,
                  () => drawGlyphImage(
                    canvas,
                    entry0.fill,
                    entry0.side,
                    rig.tint,
                    pose.alpha,
                    half: half,
                    vertical: _halves == 2,
                  ),
                );
              }
            } else if (pose.rgbSplit > 0.001) {
              final double d = pose.rgbSplit * size;
              _withTransform(
                canvas,
                x - d,
                y,
                rotation,
                sx * scrambleScale,
                sy * scrambleScale,
                pose.skew,
                () => drawGlyphImage(
                  canvas,
                  entry.fill,
                  entry.side,
                  0xff2850,
                  pose.alpha * 0.9,
                  blend: ui.BlendMode.plus,
                ),
              );
              _withTransform(
                canvas,
                x + d,
                y + d * 0.2,
                rotation,
                sx * scrambleScale,
                sy * scrambleScale,
                pose.skew,
                () => drawGlyphImage(
                  canvas,
                  entry.fill,
                  entry.side,
                  0x20e8ff,
                  pose.alpha * 0.9,
                  blend: ui.BlendMode.plus,
                ),
              );
            } else if (pose.blur > 0.01) {
              final double k1 = 1 + 0.16 * pose.blur;
              final double k2 = 1 + 0.38 * pose.blur;
              _withTransform(
                canvas,
                x,
                y,
                rotation,
                sx * k1,
                sy * k1,
                pose.skew,
                () => drawGlyphImage(
                  canvas,
                  entry.fill,
                  entry.side,
                  tint,
                  pose.alpha * 0.4 * pose.blur,
                ),
              );
              _withTransform(
                canvas,
                x,
                y,
                rotation,
                sx * k2,
                sy * k2,
                pose.skew,
                () => drawGlyphImage(
                  canvas,
                  entry.fill,
                  entry.side,
                  tint,
                  pose.alpha * 0.22 * pose.blur,
                ),
              );
            }
          case 4: // 正文
            if (splitting) break;
            int tint = mixRgb(rig.tint, rig.sungTint, sing.color);
            tint = mixRgb(tint, rig.flashTint, sing.flash);
            if (pose.backside) tint = rig.backTint;
            _withTransform(
              canvas,
              x,
              y,
              rotation,
              sx * scrambleScale,
              sy * scrambleScale,
              pose.skew,
              () => drawGlyphImage(
                canvas,
                entry.fill,
                entry.side,
                tint,
                pose.alpha,
              ),
            );
        }
      }
    }
    if (wiping) canvas.restore();
    _paintCursor(canvas, time);
    _paintUnderlines(canvas, time);
    canvas.restore();
  }

  void _paintCursor(ui.Canvas canvas, double time) {
    if (spec.enter != EnterFx.type || _rigs.isEmpty) return;
    _Rig? current;
    for (final _Rig rig in _rigs) {
      if (time >= rig.enterStart &&
          (current == null || rig.enterStart >= current.enterStart)) {
        current = rig;
      }
    }
    final bool typing = time < _lastLanded;
    final double visibleFrom = _enterAt - 0.25;
    final double hideAt = math.min(_lastLanded + 1.2, _exitFrom);
    final bool blinkOn = typing || ((time - _lastLanded) / 0.28).floor().isEven;
    final _Rig target = current ?? _rigs.first;
    if (time < visibleFrom || time >= hideAt || !blinkOn) return;
    final PlacedGlyph g = placement.glyphs[target.index];
    final double tx = math.cos(target.angle);
    final double ty = math.sin(target.angle);
    final double side = current != null ? 1 : -1;
    final double offset = (g.advance / 2 + target.size * 0.1) * side;
    canvas.save();
    canvas.translate(target.x + tx * offset, target.y + ty * offset);
    canvas.rotate(target.angle);
    final double w = math.max(2, target.size * 0.09);
    final double h = target.size * 0.95;
    canvas.drawRect(
      Rect.fromCenter(center: Offset.zero, width: w, height: h),
      ui.Paint()..color = rgbColor(palette.accent),
    );
    canvas.restore();
  }

  void _buildUnderlines(List<PlacedGlyph> glyphs) {
    final Map<int, List<int>> groups = <int, List<int>>{};
    for (final _Rig rig in _rigs) {
      final PlacedGlyph g = glyphs[rig.index];
      final List<int> list = groups.putIfAbsent(g.word, () => <int>[]);
      if (list.isEmpty || glyphs[list.first].row == g.row) list.add(rig.index);
    }
    for (final List<int> indices in groups.values) {
      final RunFrame? frame = runFrame(glyphs, indices, 0, 0);
      if (frame == null) continue;
      final List<_Rig> members = <_Rig>[
        for (final int i in indices) _rigOf[i]!,
      ];
      final double tx = math.cos(frame.angle);
      final double ty = math.sin(frame.angle);
      final double nx = -ty;
      final double ny = tx;
      final double avgSize =
          members.fold(0.0, (double s, _Rig r) => s + r.size) / members.length;
      final double thick = math.max(3, avgSize * 0.15);
      final double offset = frame.thickness / 2 + thick * 0.4;
      _underlines.add(
        _Underline(
          members,
          frame.cx - tx * frame.length / 2 + nx * offset,
          frame.cy - ty * frame.length / 2 + ny * offset,
          frame.angle,
          frame.length,
          thick,
          members.map((_Rig r) => r.sungAt).reduce(math.min),
          members.map((_Rig r) => r.sungEnd).reduce(math.max),
          members.first.sungTint,
        ),
      );
    }
  }

  void _paintUnderlines(ui.Canvas canvas, double time) {
    for (final _Underline line in _underlines) {
      final bool landed = line.members.every((_Rig r) => time >= r.landed);
      final double grow = clamp01(
        (time - line.from) / math.max(0.12, line.to - line.from),
      );
      final double retract = clamp01((time - line.to - 0.12) / 0.28);
      final double head = 1 - math.pow(1 - grow, 3).toDouble();
      final double tail = retract * retract * retract;
      final double alpha = line.members.fold(
        1.0,
        (double m, _Rig r) => math.min(m, r.visible ? r.pose.alpha : 0),
      );
      if (!landed || time < line.from || head <= tail || alpha <= 0.002) {
        continue;
      }
      final double tx = math.cos(line.angle);
      final double ty = math.sin(line.angle);
      final double thick =
          line.thick * (1 + 0.5 * (1 - clamp01((time - line.from) / 0.12)));
      canvas.save();
      canvas.translate(
        line.x + tx * line.length * tail,
        line.y + ty * line.length * tail,
      );
      canvas.rotate(line.angle);
      canvas.drawRect(
        Rect.fromLTWH(0, -thick / 2, line.length * (head - tail), thick),
        ui.Paint()..color = rgbColor(line.color, alpha),
      );
      canvas.restore();
    }
  }

  /// 各字此刻的位置（烟花、装饰件跟着字走）。
  List<GlyphAnchor> anchors(double time) {
    if (time == _anchorsAt) return _anchorsCache;
    _evaluateAll(time);
    _anchorsAt = time;
    final List<PlacedGlyph> glyphs = placement.glyphs;
    _anchorsCache = <GlyphAnchor>[
      for (int index = 0; index < glyphs.length; index++)
        () {
          final _Rig? rig = _rigOf[index];
          final PlacedGlyph g = glyphs[index];
          final (double sungAt, double sungEnd, double landed) =
              _timesByIndex[index];
          if (rig == null) {
            return GlyphAnchor(
              char: g.char,
              x: g.x + _shake.$1,
              y: g.y + _shake.$2,
              size: g.size,
              sungAt: sungAt,
              sungEnd: sungEnd,
              landedAt: landed.isFinite ? landed : _enterAt,
              alpha: 0,
              blank: true,
            );
          }
          final GlyphPose pose = rig.pose;
          final SingPose sing = rig.sing;
          final double scale =
              (((pose.scaleX * sing.scaleX).abs() +
                      (pose.scaleY * sing.scaleY).abs()) /
                  2) *
              sing.scale;
          return GlyphAnchor(
            char: g.char,
            x: rig.x + (pose.dx + sing.dx) * rig.size + _shake.$1,
            y: rig.y + (pose.dy + sing.dy) * rig.size + _shake.$2,
            size: rig.size * scale,
            sungAt: rig.sungAt,
            sungEnd: rig.sungEnd,
            landedAt: rig.landed,
            alpha: rig.visible ? clamp01(pose.alpha) : 0,
            blank: false,
          );
        }(),
    ];
    return _anchorsCache;
  }
}
