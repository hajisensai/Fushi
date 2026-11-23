/// 雾笺的整首排版（folia `nebbiaBlocks.ts` + `nebbiaCompositions.ts` + `nebbiaLayout.ts`）：
/// 照商籁的主词 / 副主词 / 虚词给词分角色、并成几块，按横条、两三行错落、十字、竖柱、刊头、徽章、
/// 竖排几列、环绕这几种构图摆一句；再在屏上几个候选位置、几档字号里找一个不压住「这句出现时还没
/// 消失的句子」、字又够大的地方。结果只由歌词、时间和屏幕尺寸决定（拖进度、重建都一样）。
library;

import 'dart:math' as math;

import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_runtime.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/nebbia/nebbia_chars.dart';

double nebbiaClamp(double v, [double lo = 0, double hi = 1]) =>
    v < lo ? lo : (v > hi ? hi : v);

double nebbiaSmooth(double t) => t * t * (3 - 2 * t);

final RegExp _cjk = RegExp('[぀-ヿ㐀-鿿豈-﫿가-힯]');
final RegExp _punct = RegExp(r'^[，。、！？!?,.・…]$');
final RegExp _turnInVertical = RegExp(r'^[ー—～〜…-]$');

enum NebbiaRole { hero, semi, support, particle }

const Map<NebbiaRole, double> kNebbiaRoleScale = <NebbiaRole, double>{
  NebbiaRole.hero: 2.0,
  NebbiaRole.semi: 1.35,
  NebbiaRole.support: 1,
  NebbiaRole.particle: 0.78,
};

/// 快歌的主次差小一点。
const Map<NebbiaRole, double> kNebbiaRoleScaleFast = <NebbiaRole, double>{
  NebbiaRole.hero: 1.55,
  NebbiaRole.semi: 1.18,
  NebbiaRole.support: 1,
  NebbiaRole.particle: 0.85,
};

const double _flowGap = 0.3;
const double _stackGap = 0.32;

bool nebbiaIsWide(String ch) {
  if (ch.isEmpty) return false;
  final int c = ch.runes.first;
  return (c >= 0x3000 && c <= 0x9FFF) || (c >= 0xFF00 && c <= 0xFFEF);
}

/// 横排时一个字占的宽度（× 字号）。
double nebbiaAdvanceOf(String ch) {
  if (nebbiaIsIcon(ch)) return 1.1;
  if (ch == ' ') return 0.32;
  if (RegExp('[，。、・．]').hasMatch(ch)) return 0.5;
  if (nebbiaIsWide(ch)) return 1;
  if (RegExp(r"[il.,'!|:;]").hasMatch(ch)) return 0.3;
  if (RegExp('[mwMW]').hasMatch(ch)) return 0.72;
  return 0.5;
}

/// 标点粘到前一个词上；被切开的一串片假名再并回去。
List<List<int>> nebbiaMergeWords(
  List<NebbiaChar> chars,
  List<List<int>> words,
) {
  final List<List<int>> out = <List<int>>[];
  bool kata(List<int> w) =>
      w.every((int k) => RegExp('^[゠-ヿ]\$').hasMatch(chars[k].ch));
  for (final List<int> w in words) {
    final List<int>? last = out.isEmpty ? null : out.last;
    if (last != null &&
        (w.every((int k) => _punct.hasMatch(chars[k].ch)) ||
            (kata(w) && kata(last) && w.first == last.last + 1))) {
      last.addAll(w);
    } else {
      out.add(<int>[...w]);
    }
  }
  return out;
}

double _scoreWord(List<NebbiaChar> chars, List<int> w) {
  final int len = w.where((int k) => chars[k].ch.trim().isNotEmpty).length;
  final double t0 = chars[w.first].t;
  final NebbiaChar last = chars[w.last];
  return math.min(len, 8) * 14 + nebbiaClamp(last.t + last.d - t0, 0, 2.5) * 18;
}

/// 每个词的角色：主词一个；词数 ≥ 4 时挑一个离主词至少隔一个词、分数 ≥ 主词 35% 的副主词；单字虚词缩小。
List<NebbiaRole> nebbiaAssignRoles(
  List<NebbiaChar> chars,
  List<List<int>> words,
) {
  final List<double> scores = <double>[
    for (final List<int> w in words) _scoreWord(chars, w),
  ];
  int hero = 0;
  for (int i = 0; i < scores.length; i++) {
    if (scores[i] > scores[hero]) hero = i;
  }
  int semi = -1;
  if (words.length >= 4) {
    for (int i = 0; i < words.length; i++) {
      if (i == hero ||
          (i - hero).abs() < 2 ||
          words[i].length < 2 ||
          scores[i] < scores[hero] * 0.35) {
        continue;
      }
      if (semi < 0 || scores[i] > scores[semi]) semi = i;
    }
  }
  return <NebbiaRole>[
    for (int i = 0; i < words.length; i++)
      if (i == hero && words.length > 1)
        NebbiaRole.hero
      else if (i == semi)
        NebbiaRole.semi
      else if (words[i].length == 1 &&
          kNebbiaParticles.contains(chars[words[i].first].ch))
        NebbiaRole.particle
      else
        NebbiaRole.support,
  ];
}

class NebbiaBlockWord {
  NebbiaBlockWord(this.idx, this.scale, this.cjk);
  final List<int> idx;
  final double scale;
  final bool cjk;
}

class NebbiaBlock {
  NebbiaBlock(this.role, this.words);
  final NebbiaRole role;
  final List<NebbiaBlockWord> words;
  int get length =>
      words.fold<int>(0, (int s, NebbiaBlockWord w) => s + w.idx.length);
  bool get strong => role == NebbiaRole.hero || role == NebbiaRole.semi;
}

bool _isCjkWord(List<NebbiaChar> chars, List<int> w) => w.every(
  (int k) => _cjk.hasMatch(chars[k].ch) || _punct.hasMatch(chars[k].ch),
);

/// 把词并成至多 [maxBlocks] 块：虚词先并到前一块；还多就把相邻、都不是主次词、合起来最短的两块并起来。
List<NebbiaBlock> nebbiaMakeBlocks(
  List<NebbiaChar> chars,
  List<List<int>> words,
  List<NebbiaRole> roles,
  Map<NebbiaRole, double> scales,
  int maxBlocks,
) {
  final List<NebbiaBlock> blocks = <NebbiaBlock>[];
  for (int i = 0; i < words.length; i++) {
    final NebbiaRole role = roles[i];
    final NebbiaBlockWord word = NebbiaBlockWord(
      words[i],
      scales[role]!,
      _isCjkWord(chars, words[i]),
    );
    final NebbiaBlock? last = blocks.isEmpty ? null : blocks.last;
    if (role == NebbiaRole.particle && last != null && !last.strong) {
      last.words.add(word);
    } else {
      blocks.add(NebbiaBlock(role, <NebbiaBlockWord>[word]));
    }
  }
  while (blocks.length > maxBlocks) {
    int bi = -1;
    int bl = 1 << 30;
    for (int i = 0; i < blocks.length - 1; i++) {
      if (blocks[i].strong || blocks[i + 1].strong) continue;
      final int l = blocks[i].length + blocks[i + 1].length;
      if (l < bl) {
        bl = l;
        bi = i;
      }
    }
    if (bi < 0) break;
    blocks[bi] = NebbiaBlock(NebbiaRole.support, <NebbiaBlockWord>[
      ...blocks[bi].words,
      ...blocks[bi + 1].words,
    ]);
    blocks.removeAt(bi + 1);
  }
  return blocks;
}

class _MeasureItem {
  _MeasureItem(this.k, this.off, this.s, this.rot, this.punct);
  final int k;
  final double off;
  final double s;
  final double rot;
  final bool punct;
}

class _Measured {
  _Measured(this.vertical, this.items, this.w, this.h);
  final bool vertical;
  final List<_MeasureItem> items;
  final double w;
  final double h;
  int get turned => items.any((_MeasureItem it) => it.rot != 0) ? 1 : 0;
}

/// 一个字在构图里的位置（基准字号 1）。
class NebbiaPlaced {
  NebbiaPlaced(this.k, this.x, this.y, this.s, this.rot);
  final int k;
  final double x;
  final double y;
  final double s;
  final double rot;
}

double _gapOf(NebbiaBlockWord a, NebbiaBlockWord b) =>
    a.cjk && b.cjk ? 0.04 : 0.24;

_Measured _measure(NebbiaBlock block, List<NebbiaChar> chars, bool vertical) {
  final List<_MeasureItem> items = <_MeasureItem>[];
  double pen = 0;
  double thick = 0;
  for (int wi = 0; wi < block.words.length; wi++) {
    final NebbiaBlockWord w = block.words[wi];
    if (wi > 0) {
      pen += _gapOf(block.words[wi - 1], w) * (vertical && w.cjk ? 0 : 1);
    }
    for (final int k in w.idx) {
      final String ch = chars[k].ch;
      final bool vertCjk = vertical && w.cjk;
      final double a = vertCjk
          ? (_punct.hasMatch(ch) ? 0.55 : 1.02)
          : nebbiaAdvanceOf(ch);
      final double rot = vertical && (!w.cjk || _turnInVertical.hasMatch(ch))
          ? math.pi / 2
          : 0;
      final double s = w.scale;
      items.add(
        _MeasureItem(
          k,
          pen + a * s / 2,
          s,
          rot,
          vertCjk && _punct.hasMatch(ch),
        ),
      );
      pen += a * s;
      thick = math.max(thick, s);
    }
  }
  return vertical
      ? _Measured(true, items, thick, pen)
      : _Measured(false, items, pen, thick);
}

/// 量好的块放到中心 (cx, cy)：横排底边对齐，竖排中线对齐，竖排的句读点放在格子右上。
void _emit(_Measured m, double cx, double cy, List<NebbiaPlaced> out) {
  for (final _MeasureItem it in m.items) {
    if (!m.vertical) {
      out.add(
        NebbiaPlaced(
          it.k,
          cx - m.w / 2 + it.off,
          cy + m.h / 2 - it.s / 2,
          it.s,
          0,
        ),
      );
    } else {
      out.add(
        NebbiaPlaced(
          it.k,
          cx + (it.punct ? it.s * 0.3 : 0),
          cy - m.h / 2 + it.off - (it.punct ? it.s * 0.2 : 0),
          it.s,
          it.rot,
        ),
      );
    }
  }
}

class NebbiaCompositionContext {
  NebbiaCompositionContext(this.blocks, this.h, this.chars);
  final List<NebbiaBlock> blocks;
  final int h;
  final List<NebbiaChar> chars;
  _Measured m(int i, bool vertical) => _measure(blocks[i], chars, vertical);
}

class NebbiaCompositionResult {
  NebbiaCompositionResult(this.items, this.vRot);
  final List<NebbiaPlaced> items;
  final int vRot;
}

typedef _Composition =
    NebbiaCompositionResult? Function(NebbiaCompositionContext ctx);

NebbiaCompositionResult _flowRows(
  NebbiaCompositionContext ctx,
  List<List<int>> rows,
  List<double> shifts,
) {
  final List<NebbiaPlaced> out = <NebbiaPlaced>[];
  final List<List<_Measured>> rowMs = <List<_Measured>>[
    for (final List<int> r in rows)
      <_Measured>[for (final int i in r) ctx.m(i, false)],
  ];
  final List<double> rowW = <double>[
    for (final List<_Measured> ms in rowMs)
      ms.fold<double>(0, (double s, _Measured m) => s + m.w) +
          _flowGap * (ms.length - 1),
  ];
  final double widest = rowW.reduce(math.max);
  double y = 0;
  for (int ri = 0; ri < rowMs.length; ri++) {
    final List<_Measured> ms = rowMs[ri];
    final double rh = ms.map((_Measured m) => m.h).reduce(math.max);
    double x = -rowW[ri] / 2 + shifts[ri] * widest;
    for (final _Measured m in ms) {
      _emit(m, x + m.w / 2, y + rh - m.h / 2, out);
      x += m.w + _flowGap;
    }
    y += rh + _stackGap;
  }
  return NebbiaCompositionResult(out, 0);
}

NebbiaCompositionResult? _ribbon(NebbiaCompositionContext ctx) => _flowRows(
  ctx,
  <List<int>>[List<int>.generate(ctx.blocks.length, (int i) => i)],
  <double>[0],
);

NebbiaCompositionResult? _lines2(NebbiaCompositionContext ctx) {
  final int n = ctx.blocks.length;
  if (n < 2) return null;
  final List<_Measured> ms = <_Measured>[
    for (int i = 0; i < n; i++) ctx.m(i, false),
  ];
  final double total = ms.fold<double>(0, (double s, _Measured m) => s + m.w);
  double acc = 0;
  int cut = 1;
  double best = double.infinity;
  for (int i = 0; i < n; i++) {
    acc += ms[i].w;
    if (i < n - 1 && (acc - total / 2).abs() < best) {
      best = (acc - total / 2).abs();
      cut = i + 1;
    }
  }
  return _flowRows(
    ctx,
    <List<int>>[
      List<int>.generate(cut, (int i) => i),
      List<int>.generate(n - cut, (int i) => i + cut),
    ],
    <double>[-0.12, 0.12],
  );
}

NebbiaCompositionResult? _lines3(NebbiaCompositionContext ctx) {
  final int n = ctx.blocks.length;
  if (n < 3) return null;
  final List<_Measured> ms = <_Measured>[
    for (int i = 0; i < n; i++) ctx.m(i, false),
  ];
  final double total = ms.fold<double>(0, (double s, _Measured m) => s + m.w);
  final List<List<int>> rows = <List<int>>[<int>[]];
  double acc = 0;
  for (int i = 0; i < n; i++) {
    final _Measured m = ms[i];
    if (rows.last.isNotEmpty &&
        rows.length < 3 &&
        (acc + m.w / 2 > total / 3 * rows.length || n - i <= 3 - rows.length)) {
      rows.add(<int>[]);
    }
    rows.last.add(i);
    acc += m.w;
  }
  return rows.length == 3
      ? _flowRows(ctx, rows, <double>[-0.14, 0.1, -0.04])
      : null;
}

NebbiaCompositionResult? _cross(NebbiaCompositionContext ctx) {
  final int n = ctx.blocks.length;
  final int h = ctx.h;
  if (n < 3 || n > 7) return null;
  final int top = h ~/ 2;
  final int right = ((n - 1 - h) / 2).ceil();
  if (top == 0 && h + right + 1 >= n) return null;
  final List<NebbiaPlaced> out = <NebbiaPlaced>[];
  final _Measured hm = ctx.m(h, false);
  _emit(hm, 0, 0, out);
  int vRot = 0;
  double x = -hm.w / 2 - _stackGap;
  for (int i = h - 1; i >= top; i--) {
    final _Measured m = ctx.m(i, false);
    _emit(m, x - m.w / 2, (hm.h - m.h) / 2, out);
    x -= m.w + _flowGap;
  }
  double y = -hm.h / 2 - _stackGap;
  for (int i = top - 1; i >= 0; i--) {
    final _Measured m = ctx.m(i, true);
    vRot += m.turned;
    _emit(m, 0, y - m.h / 2, out);
    y -= m.h + _stackGap;
  }
  x = hm.w / 2 + _stackGap;
  for (int i = h + 1; i <= h + right && i < n; i++) {
    final _Measured m = ctx.m(i, false);
    _emit(m, x + m.w / 2, (hm.h - m.h) / 2, out);
    x += m.w + _flowGap;
  }
  y = hm.h / 2 + _stackGap;
  for (int i = h + right + 1; i < n; i++) {
    final _Measured m = ctx.m(i, true);
    vRot += m.turned;
    _emit(m, 0, y + m.h / 2, out);
    y += m.h + _stackGap;
  }
  return NebbiaCompositionResult(out, vRot);
}

NebbiaCompositionResult? _pillar(NebbiaCompositionContext ctx) {
  final int n = ctx.blocks.length;
  final int h = ctx.h;
  if (n < 2 || n > 6) return null;
  final List<NebbiaPlaced> out = <NebbiaPlaced>[];
  final _Measured hm = ctx.m(h, true);
  int vRot = hm.turned;
  _emit(hm, 0, 0, out);
  final double top = -hm.h / 2 + 0.15;
  void side(int from, int to, double dirX) {
    final List<List<_Measured>> cols = <List<_Measured>>[<_Measured>[]];
    double y = top;
    for (int i = from; i != to; i++) {
      final _Measured m = ctx.m(i, true);
      vRot += m.turned;
      if (y + m.h > hm.h / 2 + 0.6 && cols.last.isNotEmpty) {
        cols.add(<_Measured>[]);
        y = top;
      }
      cols.last.add(m);
      y += m.h + _stackGap;
    }
    double colX = dirX * (hm.w / 2 + _flowGap);
    for (final List<_Measured> col in dirX > 0 ? cols : cols.reversed) {
      y = top;
      for (final _Measured m in col) {
        _emit(m, colX + dirX * m.w / 2, y + m.h / 2, out);
        y += m.h + _stackGap;
      }
      colX +=
          dirX *
          (col.fold<double>(0, (double s, _Measured m) => math.max(s, m.w)) +
              _flowGap);
    }
  }

  side(0, h, -1);
  side(h + 1, n, 1);
  return NebbiaCompositionResult(out, vRot);
}

NebbiaCompositionResult? _header(NebbiaCompositionContext ctx) {
  final int n = ctx.blocks.length;
  final int h = ctx.h;
  if (n < 3 || n - 1 - h < 2) return null;
  final List<NebbiaPlaced> out = <NebbiaPlaced>[];
  final _Measured hm = ctx.m(h, false);
  _emit(hm, 0, 0, out);
  if (h > 0) {
    final List<_Measured> ms = <_Measured>[
      for (int i = 0; i < h; i++) ctx.m(i, false),
    ];
    final double rowW =
        ms.fold<double>(0, (double s, _Measured m) => s + m.w) +
        _flowGap * (h - 1);
    final double rowH = ms.map((_Measured m) => m.h).reduce(math.max);
    double x = -rowW / 2;
    final double y = -hm.h / 2 - _stackGap - rowH / 2;
    for (final _Measured m in ms) {
      _emit(m, x + m.w / 2, y + (rowH - m.h) / 2, out);
      x += m.w + _flowGap;
    }
  }
  double y = hm.h / 2 + _stackGap;
  final double l = -hm.w * 0.22 - _flowGap / 2;
  final double r = hm.w * 0.22 + _flowGap / 2;
  for (int i = h + 1; i < n; i += 2) {
    final _Measured a = ctx.m(i, false);
    final _Measured? b = i + 1 < n ? ctx.m(i + 1, false) : null;
    final double rh = math.max(a.h, b?.h ?? 0);
    _emit(a, l - a.w / 2, y + rh - a.h / 2, out);
    if (b != null) _emit(b, r + b.w / 2, y + rh - b.h / 2, out);
    y += rh + _stackGap;
  }
  return NebbiaCompositionResult(out, 0);
}

NebbiaCompositionResult? _badge(NebbiaCompositionContext ctx) {
  final int n = ctx.blocks.length;
  if (n < 3 || n > 7 || ctx.h != 0) return null;
  final List<NebbiaPlaced> out = <NebbiaPlaced>[];
  final _Measured hm = ctx.m(0, true);
  final List<_Measured> ms = <_Measured>[
    for (int i = 1; i < n; i++) ctx.m(i, false),
  ];
  final double colW = math.max(
    ms.map((_Measured m) => m.w).reduce(math.max),
    hm.h * 0.9,
  );
  _emit(hm, hm.w / 2, hm.h / 2, out);
  double x = hm.w + _flowGap;
  double y = 0;
  double rowH = 0;
  double left() => y < hm.h ? hm.w + _flowGap : 0;
  for (final _Measured m in ms) {
    if (x > left() && x + m.w > hm.w + _flowGap + colW) {
      y += rowH + _stackGap;
      x = left();
      rowH = 0;
    }
    _emit(m, x + m.w / 2, y + m.h / 2, out);
    x += m.w + _flowGap;
    rowH = math.max(rowH, m.h);
  }
  return NebbiaCompositionResult(out, hm.turned);
}

NebbiaCompositionResult? _columns(NebbiaCompositionContext ctx) {
  final int n = ctx.blocks.length;
  if (n < 2 ||
      n > 5 ||
      ctx.blocks.any(
        (NebbiaBlock b) => b.words.any((NebbiaBlockWord w) => !w.cjk),
      )) {
    return null;
  }
  final List<NebbiaPlaced> out = <NebbiaPlaced>[];
  double x = 0;
  for (int i = 0; i < n; i++) {
    final _Measured m = ctx.m(i, true);
    _emit(m, x + m.w / 2, m.h / 2 + (i % 2) * 0.5, out);
    x += m.w + _stackGap;
  }
  return NebbiaCompositionResult(out, 0);
}

class _Rect {
  _Rect(this.x0, this.x1, this.y0, this.y1);
  final double x0;
  final double x1;
  final double y0;
  final double y1;
}

NebbiaCompositionResult? _orbit(NebbiaCompositionContext ctx) {
  final int n = ctx.blocks.length;
  final int h = ctx.h;
  if (n < 4 || n > 7) return null;
  final List<NebbiaPlaced> out = <NebbiaPlaced>[];
  final _Measured hm = ctx.m(h, false);
  _emit(hm, 0, 0, out);
  final List<_Rect> rects = <_Rect>[
    _Rect(-hm.w / 2, hm.w / 2, -hm.h / 2, hm.h / 2),
  ];
  double sep(_Rect a, _Rect b) => <double>[
    a.x0 - b.x1,
    b.x0 - a.x1,
    a.y0 - b.y1,
    b.y0 - a.y1,
  ].reduce(math.max);
  double ang = -math.pi * 0.75;
  int vRot = 0;
  final double base = math.sqrt(hm.w * hm.w + hm.h * hm.h) / 2 + _stackGap;
  for (int i = 0; i < n; i++) {
    if (i == h) continue;
    double r = base;
    double a = ang;
    _Rect? rect;
    _Measured m = ctx.m(i, false);
    for (int tries = 0; tries < 600 && rect == null; tries++) {
      m = ctx.m(i, math.cos(a).abs() > 0.75);
      final double cx = math.cos(a) * r * 1.25;
      final double cy = math.sin(a) * r * 0.8;
      final _Rect c = _Rect(
        cx - m.w / 2,
        cx + m.w / 2,
        cy - m.h / 2,
        cy + m.h / 2,
      );
      if (rects.every((_Rect q) => sep(q, c) >= _flowGap)) {
        rect = c;
      } else {
        a += 0.08;
        if (tries % 80 == 79) r += 0.5;
      }
    }
    if (rect == null) return null;
    rects.add(rect);
    vRot += m.turned;
    _emit(m, (rect.x0 + rect.x1) / 2, (rect.y0 + rect.y1) / 2, out);
    ang = a + 0.5;
  }
  return NebbiaCompositionResult(out, vRot);
}

/// 构图表（顺序同 folia）。
final Map<String, _Composition> kNebbiaCompositions = <String, _Composition>{
  'ribbon': _ribbon,
  'lines2': _lines2,
  'lines3': _lines3,
  'cross': _cross,
  'pillar': _pillar,
  'header': _header,
  'badge': _badge,
  'columns': _columns,
  'orbit': _orbit,
};

/// 构图的偏好分（越小越常用）。
const Map<String, double> _compositionBias = <String, double>{
  'ribbon': 12,
  'lines2': 10,
  'lines3': 14,
  'cross': 0,
  'pillar': 1,
  'header': 1,
  'badge': 4,
  'columns': 2,
  'orbit': 4,
};
const Set<String> _simpleCompositions = <String>{'ribbon', 'lines2', 'lines3'};

/// 一个字落到屏幕上的位置。
class NebbiaCharPos {
  const NebbiaCharPos(this.x, this.y, this.s, this.rot);
  final double x;
  final double y;
  final double s;
  final double rot;
}

class NebbiaBox {
  const NebbiaBox(this.x0, this.x1, this.y0, this.y1);
  final double x0;
  final double x1;
  final double y0;
  final double y1;
  double get w => x1 - x0;
  double get h => y1 - y0;
}

NebbiaBox _bboxOf(List<NebbiaPlaced> items) {
  double x0 = double.infinity;
  double x1 = -double.infinity;
  double y0 = double.infinity;
  double y1 = -double.infinity;
  for (final NebbiaPlaced it in items) {
    x0 = math.min(x0, it.x - it.s / 2);
    x1 = math.max(x1, it.x + it.s / 2);
    y0 = math.min(y0, it.y - it.s / 2);
    y1 = math.max(y1, it.y + it.s / 2);
  }
  return NebbiaBox(x0, x1, y0, y1);
}

double _overlap(NebbiaBox a, NebbiaBox b) =>
    math.max(0, math.min(a.x1, b.x1) - math.max(a.x0, b.x0)) *
    math.max(0, math.min(a.y1, b.y1) - math.max(a.y0, b.y0));

class _Candidate {
  _Candidate(
    this.score,
    this.name,
    this.items,
    this.bb,
    this.s,
    this.cx,
    this.cy,
    this.box,
  );
  final double score;
  final String name;
  final List<NebbiaPlaced> items;
  final NebbiaBox bb;
  final double s;
  final double cx;
  final double cy;
  final NebbiaBox box;
}

/// 多留着的句子占地方的权重：有空地就别压上去，但不为它缩小字号。
const double _lingerWeight = 0.03;

/// 排版参数。
class NebbiaLayoutOptions {
  NebbiaLayoutOptions({
    required this.width,
    required this.height,
    required this.jitter,
    required this.layouts,
    required this.fontScale,
    required this.visibleUntil,
    required this.fogAt,
    this.lingerUntil,
  });
  final double width;
  final double height;
  final double jitter;
  final List<String> layouts;
  final double fontScale;
  final double Function(int i) visibleUntil;
  final double Function(int i) fogAt;
  final double Function(int i)? lingerUntil;
}

class _Busy {
  _Busy(this.box, this.until, this.fogAt, this.linger);
  final NebbiaBox box;
  final double until;
  final double fogAt;
  final double linger;
}

/// 排整首歌：每句一个数组，和 chars 一一对应（空格也有位置，但不画）。
List<List<NebbiaCharPos>> layoutNebbiaSong(
  List<NebbiaSourceLine> lines,
  NebbiaLayoutOptions opts,
) {
  final double w = opts.width;
  final double h = opts.height;
  final double mx = w * 0.05;
  final double my = h * 0.07;
  final double sMin = math.max(26, h * 0.065) * opts.fontScale;
  final double sMax = h * 0.14 * opts.fontScale;
  final List<_Busy> placed = <_Busy>[];
  final List<String> recent = <String>[];
  _Candidate? prev;
  NebbiaBox? titleBox;

  NebbiaCompositionResult pickWide(NebbiaCompositionContext ctx) {
    final NebbiaCompositionResult one = _ribbon(ctx)!;
    final NebbiaBox bb = _bboxOf(one.items);
    final bool fits = math.min(sMax * 1.15, (w - mx * 2) * 0.8 / bb.w) >= sMin;
    return (fits ? null : _lines2(ctx)) ?? one;
  }

  _Candidate creditsCandidate(
    NebbiaCompositionContext ctx,
    NebbiaCredits kind,
  ) {
    final NebbiaCompositionResult res = kind == NebbiaCredits.title
        ? pickWide(ctx)
        : (_ribbon(ctx) ?? pickWide(ctx));
    final NebbiaBox bb = _bboxOf(res.items);
    final double cap = kind == NebbiaCredits.title ? sMax * 1.15 : sMax * 0.55;
    final double s = <double>[
      cap,
      (w - mx * 2) * 0.8 / bb.w,
      h * 0.32 / bb.h,
    ].reduce(math.min);
    final double bw = bb.w * s;
    final double bh = bb.h * s;
    final double cy = kind == NebbiaCredits.title || titleBox == null
        ? h * 0.42
        : titleBox!.y1 + bh / 2 + s * 0.6;
    final NebbiaBox box = NebbiaBox(
      w / 2 - bw / 2,
      w / 2 + bw / 2,
      cy - bh / 2,
      cy + bh / 2,
    );
    if (kind == NebbiaCredits.title) titleBox = box;
    return _Candidate(0, 'ribbon', res.items, bb, s, w / 2, cy, box);
  }

  final List<List<NebbiaCharPos>> result = <List<NebbiaCharPos>>[];
  for (int li = 0; li < lines.length; li++) {
    final NebbiaSourceLine line = lines[li];
    final List<NebbiaChar> chars = line.chars;
    final LyricVisualizerRandom rnd = LyricVisualizerRandom(
      (lyricVisualizerSeedOf(chars.map((NebbiaChar c) => c.ch).join()) +
              li * 7919) &
          0xFFFFFFFF,
    );
    final int visible = chars
        .where((NebbiaChar c) => c.ch.trim().isNotEmpty)
        .length;
    final bool fast = visible > 0 && (line.end - line.t) / visible < 0.22;
    final List<List<int>> words = nebbiaMergeWords(chars, line.words);
    if (words.isEmpty) {
      result.add(<NebbiaCharPos>[
        for (int i = 0; i < chars.length; i++)
          NebbiaCharPos(w / 2, h / 2, sMin, 0),
      ]);
      continue;
    }
    final List<NebbiaRole> roles = nebbiaAssignRoles(chars, words);
    final Map<NebbiaRole, double> rs = fast
        ? kNebbiaRoleScaleFast
        : kNebbiaRoleScale;
    final List<(NebbiaBox, double)> busy = <(NebbiaBox, double)>[
      for (final _Busy p in placed)
        if (p.linger > line.t - 0.3)
          (
            p.box,
            p.until <= line.t - 0.3
                ? _lingerWeight
                : line.t <= p.fogAt
                ? 1
                : 0.6 +
                      0.4 *
                          nebbiaClamp(
                            (p.until - line.t) /
                                math.max(1e-3, p.until - p.fogAt),
                          ),
          ),
    ];

    _Candidate? best = line.credits == null
        ? null
        : creditsCandidate(
            NebbiaCompositionContext(
              nebbiaMakeBlocks(
                chars,
                words,
                <NebbiaRole>[
                  for (final List<int> _ in words) NebbiaRole.support,
                ],
                kNebbiaRoleScale,
                9,
              ),
              0,
              chars,
            ),
            line.credits!,
          );
    if (best == null) {
      for (final int maxBlocks in <int>[5, 7]) {
        final List<NebbiaBlock> blocks = nebbiaMakeBlocks(
          chars,
          words,
          roles,
          rs,
          maxBlocks,
        );
        final int hero = blocks.indexWhere(
          (NebbiaBlock b) => b.role == NebbiaRole.hero,
        );
        final NebbiaCompositionContext ctx = NebbiaCompositionContext(
          blocks,
          math.max(0, hero),
          chars,
        );
        for (final MapEntry<String, _Composition> e
            in kNebbiaCompositions.entries) {
          final String name = e.key;
          if (!opts.layouts.contains(name)) continue;
          final NebbiaCompositionResult? res = e.value(ctx);
          if (res == null || res.items.isEmpty) continue;
          final NebbiaBox bb = _bboxOf(res.items);
          final double maxH = h * (name == 'ribbon' ? 0.28 : 0.5);
          final double maxW =
              (w - mx * 2) * (_simpleCompositions.contains(name) ? 0.94 : 0.68);
          final double sFit = <double>[
            maxW / bb.w,
            maxH / bb.h,
            sMax,
          ].reduce(math.min);
          if (sFit < sMin * 0.75) continue;
          final List<double> sizes = <double>[
            sFit,
            for (final double k in <double>[0.8, 0.64, 0.5])
              if (sFit * k >= sMin * 0.75) sFit * k,
          ];
          for (final double s in sizes) {
            final double bw = bb.w * s;
            final double bh = bb.h * s;
            for (final double fx in <double>[0.5, 0.3, 0.7]) {
              for (final double fy in <double>[0.25, 0.42, 0.58, 0.75]) {
                final double cx = _clampRange(
                  fx * w,
                  mx + bw / 2,
                  w - mx - bw / 2,
                );
                final double cy = _clampRange(
                  fy * h,
                  my + bh / 2,
                  h - my - bh / 2,
                );
                final NebbiaBox box = NebbiaBox(
                  cx - bw / 2,
                  cx + bw / 2,
                  cy - bh / 2,
                  cy + bh / 2,
                );
                final double pad = s * 0.3;
                final NebbiaBox padBox = NebbiaBox(
                  box.x0 - pad,
                  box.x1 + pad,
                  box.y0 - pad,
                  box.y1 + pad,
                );
                double score = 0;
                for (final (NebbiaBox b, double bw8) in busy) {
                  score += _overlap(padBox, b) / (bw * bh) * 1000 * bw8;
                }
                score -= s / h * 100;
                if (s < sMin) score += 40 + (sMin - s) / sMin * 200;
                score += _compositionBias[name]!;
                score += res.vRot * (fast ? 10 : 4);
                if (fast && !_simpleCompositions.contains(name)) score += 6;
                if (maxBlocks == 7 && blocks.length <= 5) score += 100;
                final int rep = recent.lastIndexOf(name);
                if (rep >= 0) {
                  score += <double>[18, 9, 4][recent.length - 1 - rep];
                }
                if (prev != null &&
                    (prev.cx - cx).abs() < w * 0.08 &&
                    (prev.cy - cy).abs() < h * 0.08) {
                  score += 8;
                }
                score += (cy - h * 0.5).abs() / h * 8;
                score += rnd.next() * 8;
                if (best == null || score < best.score) {
                  best = _Candidate(score, name, res.items, bb, s, cx, cy, box);
                }
              }
            }
          }
        }
      }
    }
    if (best == null) {
      final List<NebbiaBlock> blocks = nebbiaMakeBlocks(
        chars,
        words,
        roles,
        kNebbiaRoleScaleFast,
        9,
      );
      final NebbiaCompositionContext ctx = NebbiaCompositionContext(
        blocks,
        0,
        chars,
      );
      final NebbiaCompositionResult res =
          _lines3(ctx) ?? _lines2(ctx) ?? _ribbon(ctx)!;
      final NebbiaBox bb = _bboxOf(res.items);
      final double s = <double>[
        sMax,
        (w - mx * 2) / bb.w,
        (h - my * 2) / bb.h,
      ].reduce(math.min);
      best = _Candidate(
        0,
        'lines3',
        res.items,
        bb,
        s,
        w / 2,
        h / 2,
        NebbiaBox(
          w / 2 - bb.w * s / 2,
          w / 2 + bb.w * s / 2,
          h / 2 - bb.h * s / 2,
          h / 2 + bb.h * s / 2,
        ),
      );
    }
    final _Candidate chosen = best;
    placed.add(
      _Busy(
        chosen.box,
        opts.visibleUntil(li),
        opts.fogAt(li),
        math.max(opts.visibleUntil(li), opts.lingerUntil?.call(li) ?? 0),
      ),
    );
    recent.add(chosen.name);
    if (recent.length > 3) recent.removeAt(0);
    prev = chosen;

    // 落到屏幕坐标，再加一点手写歪斜（幅度小，不至于撞到别的字）。
    final NebbiaBox bb = chosen.bb;
    final double s = chosen.s;
    final double tilt = (rnd.next() - 0.5) * 0.04 * opts.jitter;
    final Map<int, NebbiaPlaced> byK = <int, NebbiaPlaced>{
      for (final NebbiaPlaced it in chosen.items) it.k: it,
    };
    NebbiaCharPos lastPos = NebbiaCharPos(chosen.cx, chosen.cy, s, 0);
    final List<NebbiaCharPos> row = <NebbiaCharPos>[];
    for (int k = 0; k < chars.length; k++) {
      final NebbiaPlaced? it = byK[k];
      if (it == null) {
        row.add(NebbiaCharPos(lastPos.x, lastPos.y, lastPos.s, 0));
        continue;
      }
      final double x = chosen.cx + (it.x - (bb.x0 + bb.x1) / 2) * s;
      final double y0 = chosen.cy + (it.y - (bb.y0 + bb.y1) / 2) * s;
      final double cs =
          it.s * s * (1 + (rnd.next() - 0.5) * 0.08 * opts.jitter);
      lastPos = NebbiaCharPos(
        x + (rnd.next() - 0.5) * s * 0.04 * opts.jitter,
        y0 +
            (x - chosen.cx) * tilt +
            (rnd.next() - 0.5) * s * 0.05 * opts.jitter,
        cs,
        it.rot + (rnd.next() - 0.5) * 0.08 * opts.jitter + tilt,
      );
      row.add(lastPos);
    }
    result.add(row);
  }
  return result;
}

/// clamp，下界大于上界时取中点（folia 的 clamp 在那种情况取下界；放不下时居中更稳）。
double _clampRange(double v, double lo, double hi) {
  if (lo > hi) return (lo + hi) / 2;
  return v < lo ? lo : (v > hi ? hi : v);
}
