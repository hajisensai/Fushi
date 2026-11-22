/// 绘光的歌词窗口（folia `lumiere/text/*`）：当前行 + 上一行 + 下一行排在文字区里，换行时整组滑到新槽位；
/// 当前行的字从四周沿曲线飞来聚拢，唱到的字被点亮，唱完的行在光里崩解飘散。纯函数（不画），时间单位秒。
library;

import 'dart:math' as math;

import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_runtime.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/lumiere/lumiere_math.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/lumiere/lumiere_profile.dart';

/// 行比开唱提前多久成为当前行。
const double kLead = 1.2;

/// 换行时整组滑到新槽位的时长。
const double kSlide = 1.5;

/// 各槽位的滑动滞后（按新的相对行号）。
const Map<int, double> kSlideLag = <int, double>{
  -3: 0,
  -2: 0,
  -1: 0.15,
  0: 0.3,
  1: 0.5,
  2: 0.6,
};

/// 字被唱到后点亮的时长。
const double kLightUp = 0.3;

/// 当前行的字提前多久开始飞来、聚拢用多久。
const double kGatherLead = 1.6;
const double kGather = 1.8;

/// 崩解：唱完 delay 秒后开始，再过 DISSOLVE_FROM 秒开始淡出，SPAN 秒淡完。
const double kDissolveFrom = 1;
const double kDissolveSpan = 2;

/// 唱过的行逐渐压暗到多少、压暗用多久。
const double kPassedDim = 0.75;
const double kPassedDimTime = 2.5;

/// 呼吸幅度（字号的倍数）。
const double kBreath = 0.022;

/// 闪光包络。
const double kFlashAttack = 0.15;
const double kFlashDecay = 0.45;

/// 单行最多压缩到多少再换行。
const double kSingleMinFit = 0.8;

/// 换行后行距、竖排列距（字号的倍数）。
const double kRowPitch = 1.6;
const double kColumnPitch = 1.6;

const Set<String> _functionWords = <String>{
  'a',
  'an',
  'the',
  'of',
  'to',
  'in',
  'on',
  'at',
  'by',
  'for',
  'and',
  'or',
  'but',
  'is',
  'are',
  'was',
  'be', //
  'it',
  'i',
  'you',
  'me',
  'my',
  'we',
  'so',
  'as',
  'with',
  'from',
  'that',
  'this',
  'do',
  'oh', //
  'の',
  'は',
  'が',
  'を',
  'に',
  'で',
  'と',
  'も',
  'へ',
  'や',
  'て',
  'た',
  'な',
  'ね',
  'よ',
  'か', //
  '的', '了', '着', '是', '在', '和', '吗', '呢', '吧', //
};

/// 字形尺寸来源：一个字的步进宽度（字号的倍数）。
typedef GlyphAdvance = double Function(String char);

/// 一行在自己坐标里的排法（单位：字号，中心在原点）。
class LineShape {
  const LineShape(
    this.xs,
    this.ys,
    this.scales,
    this.width,
    this.height,
    this.vertical,
  );
  final List<double> xs;
  final List<double> ys;
  final List<double> scales;
  final double width;
  final double height;
  final bool vertical;
}

/// 每个词的字号倍数：关键词放大，虚词缩小，其余随机一点（folia `wordStyle.ts`）。
List<double> glyphScalesOf(LyricVisualizerLine line, String seed) {
  final List<double> out = List<double>.filled(line.glyphs.length, 1);
  if (line.words.length < 2) return out;
  final LumiereRng random = lumiereRng('$seed:${line.index}:words');
  int key = -1;
  int keyLength = 0;
  for (int w = 0; w < line.words.length; w++) {
    final LyricVisualizerWord word = line.words[w];
    final String text = word.text.trim().toLowerCase();
    if (text.isEmpty || _functionWords.contains(text)) continue;
    if (word.glyphCount > keyLength) {
      keyLength = word.glyphCount;
      key = w;
    }
  }
  for (int w = 0; w < line.words.length; w++) {
    final LyricVisualizerWord word = line.words[w];
    final String text = word.text.trim().toLowerCase();
    final double scale = w == key
        ? 1.45
        : (_functionWords.contains(text) ? 0.62 : 0.85 + 0.35 * random());
    for (
      int g = word.firstGlyph;
      g < word.firstGlyph + word.glyphCount && g < out.length;
      g++
    ) {
      out[g] = scale;
    }
  }
  return out;
}

bool lineIsCjk(LyricVisualizerLine line) {
  int cjk = 0;
  int total = 0;
  for (final LyricVisualizerGlyph g in line.glyphs) {
    if (g.isSpace) continue;
    total++;
    if (lyricVisualizerIsCjk(g.text)) cjk++;
  }
  return total > 0 && cjk * 2 >= total;
}

/// 横排：放得下就一行（最多压到 [kSingleMinFit]），放不下按词换行。
LineShape shapeHorizontal(
  LyricVisualizerLine line,
  GlyphAdvance advance,
  List<double> scales,
  double maxWidth,
) {
  final int n = line.glyphs.length;
  final List<double> adv = <double>[
    for (int i = 0; i < n; i++) advance(line.glyphs[i].text) * scales[i],
  ];
  final double total = adv.fold(0, (double a, double b) => a + b);
  final List<List<int>> rows = <List<int>>[];
  double fit = 1;
  if (total <= maxWidth / kSingleMinFit || n == 0) {
    rows.add(<int>[for (int i = 0; i < n; i++) i]);
    fit = total > maxWidth ? maxWidth / total : 1;
  } else {
    List<int> row = <int>[];
    double width = 0;
    int i = 0;
    while (i < n) {
      // 一个词（或一个 CJK 字）作为不可拆的单位
      int j = i + 1;
      if (!lyricVisualizerIsCjk(line.glyphs[i].text)) {
        while (j < n &&
            !line.glyphs[j].isSpace &&
            !lyricVisualizerIsCjk(line.glyphs[j].text) &&
            !line.glyphs[j - 1].isSpace) {
          j++;
        }
      }
      double unit = 0;
      for (int k = i; k < j; k++) {
        unit += adv[k];
      }
      if (row.isNotEmpty && width + unit > maxWidth) {
        rows.add(row);
        row = <int>[];
        width = 0;
      }
      for (int k = i; k < j; k++) {
        if (row.isEmpty && line.glyphs[k].isSpace) continue;
        row.add(k);
        width += adv[k];
      }
      i = j;
    }
    if (row.isNotEmpty) rows.add(row);
  }
  final List<double> xs = List<double>.filled(n, 0);
  final List<double> ys = List<double>.filled(n, 0);
  final List<double> ss = <double>[for (int i = 0; i < n; i++) scales[i] * fit];
  double widest = 0;
  final double height = rows.isEmpty
      ? 1
      : (rows.length - 1) * kRowPitch * 0.75 + 1;
  for (int r = 0; r < rows.length; r++) {
    double width = 0;
    for (final int i in rows[r]) {
      width += adv[i] * fit;
    }
    widest = math.max(widest, width);
    double x = -width / 2;
    final double y = -height / 2 + 0.5 + r * kRowPitch * 0.75;
    for (final int i in rows[r]) {
      xs[i] = x + adv[i] * fit / 2;
      ys[i] = y;
      x += adv[i] * fit;
    }
  }
  return LineShape(xs, ys, ss, math.max(widest, 0.5), height, false);
}

/// 竖排（右起）：每个字一格，放不下换列。
LineShape shapeVertical(
  LyricVisualizerLine line,
  List<double> scales,
  double maxHeight,
) {
  final int n = line.glyphs.length;
  final List<int> visible = <int>[
    for (int i = 0; i < n; i++)
      if (!line.glyphs[i].isSpace) i,
  ];
  final int perColumn = math.max(1, (maxHeight / 1.05).floor());
  final int columns = math.max(1, (visible.length / perColumn).ceil());
  final int rows = math.min(perColumn, visible.length);
  final List<double> xs = List<double>.filled(n, 0);
  final List<double> ys = List<double>.filled(n, 0);
  final double width = (columns - 1) * kColumnPitch * 0.75 + 1;
  final double height = math.max(1, rows * 1.05);
  for (int k = 0; k < visible.length; k++) {
    final int c = k ~/ perColumn;
    final int r = k % perColumn;
    xs[visible[k]] = width / 2 - 0.5 - c * kColumnPitch * 0.75;
    ys[visible[k]] = -height / 2 + 0.525 + r * 1.05;
  }
  // 空格挂在前一个字上（不显示）
  for (int i = 0; i < n; i++) {
    if (line.glyphs[i].isSpace && i > 0) {
      xs[i] = xs[i - 1];
      ys[i] = ys[i - 1];
    }
  }
  return LineShape(
    xs,
    ys,
    <double>[for (int i = 0; i < n; i++) math.min(scales[i], 1.15)],
    width,
    height,
    true,
  );
}

/// 一个字在一帧里的状态（屏幕像素，未加运镜）。
class GlyphPlacement {
  GlyphPlacement({
    required this.char,
    required this.x,
    required this.y,
    required this.size,
    required this.rotation,
    required this.alpha,
    required this.lit,
    required this.flash,
    required this.flying,
    required this.current,
    this.line,
    this.glyphIndex = -1,
    this.trackX,
    this.trackY,
  });
  final String char;

  /// 所在歌词行与行内字下标：按词着色用。
  final LyricVisualizerLine? line;
  final int glyphIndex;
  final double x;
  final double y;

  /// 字号（像素）。
  final double size;
  final double rotation;
  final double alpha;
  final double lit;
  final double flash;
  final double flying;
  final bool current;

  /// 飞行轨迹上剩下的点（轨迹线）；不飞时为 null。
  final List<double>? trackX;
  final List<double>? trackY;
}

/// 每个字的随机参数（飞入、崩解）。
class GlyphRandoms {
  GlyphRandoms(String key, int count) : values = _fill(key, count);

  static List<double> _fill(String key, int count) {
    final LumiereRng r = lumiereRng(key);
    return <double>[for (int i = 0; i < count * 8; i++) r()];
  }

  final List<double> values;
  double at(int glyph, int k) => values[glyph * 8 + k];
}

double flashEnvelope(double dt) {
  if (dt < 0) return 0;
  if (dt < kFlashAttack) return dt / kFlashAttack;
  return math.exp(-(dt - kFlashAttack) / kFlashDecay);
}

/// 窗口的输入（每帧一份）。
class WindowInput {
  const WindowInput({
    required this.lines,
    required this.shapes,
    required this.randoms,
    required this.time,
    required this.animTime,
    required this.motion,
    required this.typography,
    required this.regionCx,
    required this.regionCy,
    required this.regionW,
    required this.regionH,
    required this.heroPx,
    required this.neighbors,
    required this.unlitAlpha,
    required this.decay,
    required this.decayGain,
    required this.trails,
    this.curvedSlides = true,
  });

  /// 这个单元里按时间排序的行。
  final List<LyricVisualizerLine> lines;
  final List<LineShape> shapes;
  final List<GlyphRandoms> randoms;
  final double time;
  final double animTime;
  final bool motion;
  final WindowTypography typography;
  final double regionCx;
  final double regionCy;
  final double regionW;
  final double regionH;
  final double heroPx;

  /// 1：上一行 + 当前行；2：再加下一行。
  final int neighbors;
  final double unlitAlpha;
  final DecaySpec decay;
  final double decayGain;
  final bool trails;

  /// 换位时沿弧线滑过去（「所有换位都走轨迹线」）。
  final bool curvedSlides;
}

class _Slot {
  const _Slot(this.dx, this.dy, this.scale, this.alpha);
  final double dx;
  final double dy;
  final double scale;
  final double alpha;
}

/// 当前行在单元里的位置：开唱前 [kLead] 秒就算当前行；还没到第一行为 -1。
int focusOf(List<LyricVisualizerLine> lines, double time) {
  int found = -1;
  for (int k = 0; k < lines.length; k++) {
    if (lines[k].startMs / 1000 - kLead <= time) {
      found = k;
    } else {
      break;
    }
  }
  return found;
}

double _slotAlpha(int rel, int neighbors) => switch (rel) {
  -2 => 0.5,
  -1 => 1,
  0 => 1,
  1 => neighbors >= 2 ? 0.95 : 0,
  _ => 0,
};

/// focus 为 a 时各相对行的槽位（相对文字区中心，像素）。
Map<int, _Slot> _slots(WindowInput input, int a, bool vertical) {
  final Map<int, _Slot> out = <int, _Slot>{};
  final double hero = input.heroPx;
  LineShape? shapeAt(int k) =>
      k >= 0 && k < input.shapes.length ? input.shapes[k] : null;
  final LineShape? cur = shapeAt(a);
  final double curW = (cur?.width ?? 1) * hero;
  final double curH = (cur?.height ?? 1) * hero;
  final bool crossed =
      input.typography == WindowTypography.crossed &&
      curW < input.regionW * 0.8;
  final double near = vertical ? 0.58 : 0.52;
  final double far = vertical ? 0.48 : 0.44;
  out[0] = _Slot(0, 0, 1, 1);
  if (crossed) {
    // 当前行横排，周围的行落在两侧
    final double side = math.max(curW / 2 + hero * 0.6, input.regionW * 0.3);
    double extent(int k, double scale) =>
        (shapeAt(k)?.width ?? 1) * hero * scale / 2;
    out[-1] = _Slot(
      -(side + extent(a - 1, near)),
      -curH * 0.4,
      near,
      _slotAlpha(-1, input.neighbors),
    );
    out[-2] = _Slot(
      -(side + extent(a - 1, near) * 2 + extent(a - 2, far) + hero * 0.4),
      -curH * 0.9,
      far,
      _slotAlpha(-2, input.neighbors),
    );
    out[-3] = _Slot(out[-2]!.dx - hero, out[-2]!.dy - hero, far * 0.9, 0);
    out[1] = _Slot(
      side + extent(a + 1, near),
      curH * 0.4,
      near,
      _slotAlpha(1, input.neighbors),
    );
    out[2] = _Slot(out[1]!.dx + hero, out[1]!.dy + hero, far, 0);
    return out;
  }
  if (vertical) {
    double half(int k, double scale) =>
        (shapeAt(k)?.width ?? 1) * hero * scale / 2;
    final double gapPrev = hero * 0.5;
    final double prevX = curW / 2 + gapPrev + half(a - 1, near);
    final double farX =
        prevX + half(a - 1, near) + gapPrev * 0.8 + half(a - 2, far);
    out[-1] = _Slot(prevX, 0, near, _slotAlpha(-1, input.neighbors));
    out[-2] = _Slot(farX, 0, far, _slotAlpha(-2, input.neighbors));
    out[-3] = _Slot(farX + hero, 0, far, 0);
    final double nextX = -(curW / 2 + gapPrev + half(a + 1, near));
    out[1] = _Slot(nextX, 0, near, _slotAlpha(1, input.neighbors));
    out[2] = _Slot(nextX - hero * 1.2, 0, far, 0);
    return out;
  }
  double half(int k, double scale) =>
      (shapeAt(k)?.height ?? 1) * hero * scale / 2;
  final double gap = hero * 0.35;
  final double prevY = -(curH / 2 + gap + half(a - 1, near));
  final double farY = prevY - half(a - 1, near) - gap * 0.8 - half(a - 2, far);
  out[-1] = _Slot(0, prevY, near, _slotAlpha(-1, input.neighbors));
  out[-2] = _Slot(0, farY, far, _slotAlpha(-2, input.neighbors));
  out[-3] = _Slot(0, farY - hero, far, 0);
  final double nextY = curH / 2 + gap + half(a + 1, near);
  out[1] = _Slot(0, nextY, near, _slotAlpha(1, input.neighbors));
  out[2] = _Slot(0, nextY + hero, far, 0);
  return out;
}

_Slot _lerpSlot(_Slot a, _Slot b, double k) => _Slot(
  lerpD(a.dx, b.dx, k),
  lerpD(a.dy, b.dy, k),
  lerpD(a.scale, b.scale, k),
  lerpD(a.alpha, b.alpha, k),
);

/// 一帧的窗口：每个可见的字的位置、字号、透明度、点亮程度。
List<GlyphPlacement> layoutWindow(WindowInput input, {required bool vertical}) {
  final List<GlyphPlacement> out = <GlyphPlacement>[];
  final List<LyricVisualizerLine> lines = input.lines;
  if (lines.isEmpty) return out;
  final double t = input.time;
  final int a = focusOf(lines, t);
  final double change = a >= 0 ? lines[a].startMs / 1000 - kLead : -1e9;
  final Map<int, _Slot> now = _slots(input, a, vertical);
  final Map<int, _Slot> before = _slots(input, a - 1, vertical);
  final double hero = input.heroPx;

  for (
    int k = math.max(0, a - 3);
    k <= math.min(lines.length - 1, a + 2);
    k++
  ) {
    final int rel = k - a;
    final _Slot? target = now[rel];
    if (target == null) continue;
    final _Slot? from = before[rel + 1];
    final double lag = kSlideLag[rel] ?? 0;
    final double p = input.motion
        ? easeInOutCubic((t - change - lag) / kSlide)
        : 1;
    _Slot slot = from == null ? target : _lerpSlot(from, target, p);
    if (from != null && input.curvedSlides && p > 0 && p < 1) {
      final double dx = target.dx - from.dx;
      final double dy = target.dy - from.dy;
      final double len = math.sqrt(dx * dx + dy * dy);
      if (len > 1) {
        final double bulge =
            math.sin(p * math.pi) * math.min(len * 0.35, hero * 1.2);
        slot = _Slot(
          slot.dx - dy / len * bulge,
          slot.dy + dx / len * bulge,
          slot.scale,
          slot.alpha,
        );
      }
    }
    if (slot.alpha <= 0.002) continue;
    final LyricVisualizerLine line = lines[k];
    final LineShape shape = input.shapes[k];
    final GlyphRandoms rnd = input.randoms[k];
    final double lineStart = line.startMs / 1000;
    final double lineEnd = line.endMs / 1000;
    final double scale = slot.scale;
    final double cx = input.regionCx + slot.dx;
    final double cy = input.regionCy + slot.dy;
    final bool isCurrent = rel == 0;
    // 先前没露面的行（下一行不显示，或单元的第一行）聚拢飞入
    final bool gathers =
        input.motion && isCurrent && (input.neighbors < 2 || a == 0);
    final double gatherU = (t - (lineStart - kGatherLead)) / kGather;
    // 唱完后的崩解
    final double age = t - lineEnd - input.decay.delay;
    final double passed = t > lineEnd
        ? 1 - (1 - kPassedDim) * clamp01((t - lineEnd) / kPassedDimTime)
        : 1;
    final double strength = input.decay.strength * input.decayGain;
    final double decayAmount = input.motion && age > 0
        ? strength * 0.08 * math.pow(age, 1.5)
        : 0;
    final double dissolve = age > 0 && strength > 0
        ? 1 - smooth((age - kDissolveFrom) / kDissolveSpan)
        : 1;
    if (dissolve <= 0.002) continue;
    final double breath = input.motion
        ? 1 + kBreath * math.sin(input.animTime * kTau / 4.2 + k)
        : 1;

    for (int g = 0; g < line.glyphs.length; g++) {
      final LyricVisualizerGlyph glyph = line.glyphs[g];
      if (glyph.isSpace) continue;
      final double size = hero * scale * shape.scales[g] * breath;
      double x = cx + shape.xs[g] * hero * scale;
      double y = cy + shape.ys[g] * hero * scale;
      double rotation = 0;
      double flying = 0;
      double alpha = slot.alpha * dissolve;
      List<double>? trackX;
      List<double>? trackY;
      if (gathers && gatherU < 1.4) {
        final double dur = 0.45 + 0.4 * rnd.at(g, 0);
        final double delay = rnd.at(g, 1) * (1 - dur);
        final double q = clamp01((gatherU - delay) / dur);
        if (q < 1) {
          final double c1 = rnd.at(g, 2) * kTau;
          final double m1 = hero * (1.6 + 3.2 * rnd.at(g, 3));
          final double m2 = hero * (1 + 2.6 * rnd.at(g, 4));
          final double p0x = x + math.cos(c1) * m1;
          final double p0y = y + math.sin(c1) * m1;
          final double p1x = x + math.cos(c1 + 1.2) * m2;
          final double p1y = y + math.sin(c1 + 1.2) * m2;
          final double p2x = x + math.cos(c1 - 0.6) * m2 * 0.3;
          final double p2y = y + math.sin(c1 - 0.6) * m2 * 0.3;
          (double, double) bez(double u) {
            final double v = 1 - u;
            return (
              v * v * v * p0x +
                  3 * v * v * u * p1x +
                  3 * v * u * u * p2x +
                  u * u * u * x,
              v * v * v * p0y +
                  3 * v * v * u * p1y +
                  3 * v * u * u * p2y +
                  u * u * u * y,
            );
          }

          final double e = easeOutCubic(q);
          if (input.trails && q > 0) {
            trackX = <double>[];
            trackY = <double>[];
            for (int s = 0; s <= 8; s++) {
              final (double tx, double ty) = bez(e + (1 - e) * s / 8);
              trackX.add(tx);
              trackY.add(ty);
            }
          }
          final (double bx, double by) = bez(e);
          x = bx;
          y = by;
          flying = 1 - q;
          rotation = (rnd.at(g, 5) - 0.5) * 2.4 * (1 - e);
          alpha *= math.sqrt(q);
        }
      }
      if (decayAmount > 0) {
        final double angle = -math.pi / 2 + (rnd.at(g, 6) - 0.5) * 2.2;
        final double speed = 0.6 + 0.9 * rnd.at(g, 7);
        final double scatter = 0.6 + 1.4 * rnd.at(g, 0);
        final double d = hero * decayAmount * speed * scatter * 4;
        x +=
            math.cos(angle) * d +
            math.sin(input.animTime * 1.3 + g) * hero * 0.03 * decayAmount * 10;
        y += math.sin(angle) * d;
        rotation += (rnd.at(g, 5) - 0.5) * decayAmount * 3;
      }
      final double dt = t - glyph.startMs / 1000;
      double lit;
      if (rel < 0 || t >= lineEnd) {
        lit = 1;
      } else if (rel > 0 || t < lineStart) {
        lit = 0;
      } else {
        lit = clamp01(dt / kLightUp);
      }
      final double flash = rel == 0 || (rel == -1 && t < lineEnd + 1)
          ? flashEnvelope(dt)
          : 0;
      out.add(
        GlyphPlacement(
          char: glyph.text,
          x: x,
          y: y,
          size: size,
          rotation: rotation,
          alpha: alpha * (lit >= 1 ? passed : 1),
          lit: lit,
          flash: flash,
          flying: flying,
          current: isCurrent,
          line: line,
          glyphIndex: g,
          trackX: trackX,
          trackY: trackY,
        ),
      );
    }
  }
  return out;
}
