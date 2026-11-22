/// 一首歌在雾笺上的全部安排（folia `nebbiaScene.ts` + `nebbiaWipe.ts` + `nebbiaBreath.ts` 的几何）：
/// 每个字的位置、变形后的字形、擦痕边的水珠和下淌的水珠、出现方式（手写或透出）；每句的淡出方式和
/// 「让位」时刻（后面某句要写到这句的位置、而这句还没被雾吞掉时，这句提前快速起雾，屏上满了来不及的
/// 就哈一口气盖掉）。只由歌词、参数和屏幕尺寸决定；每帧怎么画在 nebbia_painter.dart。
library;

import 'dart:math' as math;
import 'dart:ui' show Offset;

import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_runtime.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/nebbia/nebbia_chars.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/nebbia/nebbia_glyphs.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/nebbia/nebbia_layout.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/nebbia/nebbia_tuning.dart';

/// 擦痕边的一颗小水珠（字内 em 坐标 + 法线）。
class NebbiaBead {
  NebbiaBead(this.s, this.x, this.y, this.nx, this.ny, this.r, this.j);
  final double s;
  final double x;
  final double y;
  final double nx;
  final double ny;
  final double r;
  final double j;
}

/// 一颗往下淌的水珠。
class NebbiaDrip {
  NebbiaDrip(this.delay, this.len, this.dur, this.r, this.seed);
  final double delay;
  final double len;
  final double dur;
  final double r;
  final double seed;
}

class NebbiaLaidChar {
  NebbiaLaidChar(this.c, this.x, this.y, this.s, this.rot);
  final NebbiaChar c;
  String get ch => c.ch;
  double get t => c.t;
  double get d => c.d;
  final double x;
  final double y;
  final double s;
  final double rot;
  NebbiaGlyph? glyph;
  List<List<NebbiaBead>> beads = const <List<NebbiaBead>>[];
  List<NebbiaDrip?> drips = const <NebbiaDrip?>[];
  List<({double h, double j})> ends = const <({double h, double j})>[];

  /// 慢慢显现用几秒；0 = 手指书写。
  double appearDur = 0;

  /// 手指书写的开始时刻和用时。
  double wt = 0;
  double wd = 0;

  /// 字内 em 坐标 → 屏幕坐标。
  Offset toScreen(double u, double v) {
    final double cs = math.cos(rot);
    final double sn = math.sin(rot);
    final double lx = (u - 0.5) * s;
    final double ly = (v - 0.5) * s;
    return Offset(x + cs * lx - sn * ly, y + sn * lx + cs * ly);
  }
}

/// 手指来回搓的一下（一根手指）。
class NebbiaWipeStreak {
  NebbiaWipeStreak(this.pts, this.w, this.a, this.b);
  final List<Offset> pts;
  final double w;
  final double a;
  final double b;
}

class NebbiaWipe {
  NebbiaWipe(this.streaks, this.beads, this.dur);
  final List<NebbiaWipeStreak> streaks;
  final List<({Offset p, double r})> beads;
  final double dur;
}

/// 哈气的一团。
class NebbiaLobe {
  NebbiaLobe(this.x, this.y, this.rx, this.ry);
  final double x;
  final double y;
  final double rx;
  final double ry;
}

class NebbiaBreathShape {
  NebbiaBreathShape(this.lobes, this.cx, this.cy, this.ry);
  final List<NebbiaLobe> lobes;
  final double cx;
  final double cy;
  final double ry;
}

class NebbiaLaidLine {
  NebbiaLaidLine({
    required this.chars,
    required this.t,
    required this.end,
    required this.next,
    required this.mode,
    required this.fogAt,
    this.credits,
  });
  final List<NebbiaLaidChar> chars;
  final double t;
  final double end;
  final double next;
  final NebbiaFade mode;
  final NebbiaCredits? credits;

  /// 开始起雾（或手指抹除）的时刻。
  double fogAt;
  double yieldAt = double.infinity;
  double breathAt = double.infinity;
  double breathUntil = double.infinity;
  double breathDur = NebbiaFixed.breathSpread;
  double appearBreathAt = double.infinity;
  double appearBreathUntil = double.infinity;

  NebbiaWipe? _wipe;
  bool _wipeBuilt = false;
  NebbiaBreathShape? _breath;
  bool _breathBuilt = false;
  NebbiaLineRect? _rect;
  double? _done;

  NebbiaLineRect get rect => _rect ??= _lineRect(this);

  NebbiaWipe? wipe(int idx) {
    if (!_wipeBuilt) {
      _wipe = buildNebbiaWipe(this, idx);
      _wipeBuilt = true;
    }
    return _wipe;
  }

  NebbiaBreathShape? breath(int idx) {
    if (!_breathBuilt) {
      _breath = buildNebbiaBreath(this, idx);
      _breathBuilt = true;
    }
    return _breath;
  }

  /// 全部出现完的时刻，不早于唱完。
  double get doneAt {
    if (_done != null) return _done!;
    double end = this.end;
    for (final NebbiaLaidChar c in chars) {
      if (c.glyph != null) {
        end = math.max(
          end,
          nebbiaStartOf(c) + (c.appearDur > 0 ? c.appearDur : c.wd),
        );
      }
    }
    return _done = end;
  }
}

/// 一个字开始出现的时刻：手指书写按 wt，慢慢显现按 t。
double nebbiaStartOf(NebbiaLaidChar c) => c.appearDur > 0 ? c.t : c.wt;

class NebbiaLineRect {
  const NebbiaLineRect(this.x0, this.x1, this.y0, this.y1, this.s);
  final double x0;
  final double x1;
  final double y0;
  final double y1;
  final double s;
  bool get isFinite => x0.isFinite;
}

NebbiaLineRect _lineRect(NebbiaLaidLine line) {
  double x0 = double.infinity;
  double x1 = -double.infinity;
  double y0 = double.infinity;
  double y1 = -double.infinity;
  double s = 0;
  for (final NebbiaLaidChar c in line.chars) {
    if (c.glyph == null) continue;
    x0 = math.min(x0, c.x - c.s / 2);
    x1 = math.max(x1, c.x + c.s / 2);
    y0 = math.min(y0, c.y - c.s / 2);
    y1 = math.max(y1, c.y + c.s / 2);
    s = math.max(s, c.s);
  }
  return NebbiaLineRect(x0, x1, y0, y1, s);
}

/// 写完后开始起雾的时刻：下一句开始（最多唱完 6 秒）后再保持 hold 秒。
double nebbiaFogStartOf(double end, double next, double hold) =>
    math.min(next, end + 6) + hold;

const double _lingerMax = 16;
const int _lingerLines = 3;
const double _yieldLead = 0.6;
const double _yieldRead = 0.3;

/// 哈气盖掉的旧字在擦痕上留下的浅印子。
const double kNebbiaBreathGhost = 0.08;

/// 自然书写一个字要几秒。
double nebbiaNaturalWriteTime(NebbiaGlyph g, double speed) =>
    (g.total * 0.28 + (g.strokes.length - 1) * 0.06) / speed;

void _decorate(
  NebbiaLaidChar c,
  NebbiaGlyph base,
  LyricVisualizerRandom rnd,
  double warp,
) {
  final NebbiaGlyph g = nebbiaWarpGlyph(
    base,
    LyricVisualizerRandom((rnd.next() * 1e9).floor()),
    warp,
  );
  c.glyph = g;
  c.beads = <List<NebbiaBead>>[
    for (final NebbiaStroke st in g.strokes)
      () {
        final List<NebbiaBead> out = <NebbiaBead>[];
        // 扫笔字形的笔画不在字的墨上：不挂擦痕边的小水珠。
        if (g.sweep) return out;
        final double step = 7 / c.s;
        for (
          double s = step * rnd.next();
          s < st.len;
          s += step * (0.5 + rnd.next())
        ) {
          if (rnd.next() > NebbiaFixed.beads) continue;
          final ({Offset p, Offset n}) pt = nebbiaPointAt(st, s);
          final double side = rnd.next() < 0.5 ? -1 : 1;
          out.add(
            NebbiaBead(
              s,
              pt.p.dx,
              pt.p.dy,
              pt.n.dx * side,
              pt.n.dy * side,
              1.6 + math.pow(rnd.next(), 2.2) * 3.6,
              rnd.next(),
            ),
          );
        }
        return out;
      }(),
  ];
  c.drips = <NebbiaDrip?>[
    for (int i = 0; i < g.strokes.length; i++)
      rnd.next() < NebbiaFixed.drip * 0.22
          ? NebbiaDrip(
              0.3 + rnd.next() * 1.6,
              30 + rnd.next() * 130,
              2 + rnd.next() * 3.5,
              3.2 + rnd.next() * 2.6,
              rnd.next() * 100,
            )
          : null,
  ];
  c.ends = <({double h, double j})>[
    for (int i = 0; i < g.strokes.length; i++) (h: rnd.next(), j: rnd.next()),
  ];
}

({List<double> starts, double end}) _scheduleWrite(
  List<NebbiaLaidChar> cs,
  List<double> nat,
  double k,
) {
  double end = -double.infinity;
  final List<double> starts = <double>[];
  for (int i = 0; i < cs.length; i++) {
    final double t0 = math.max(cs[i].t, end);
    end = t0 + nat[i] * k;
    starts.add(t0);
  }
  return (starts: starts, end: end);
}

/// 一句的出现方式和书写节奏：字一个接一个写，不早于开唱；整句统一一个速度系数正好写到下一句开唱
/// （或这句唱完，取晚的），最慢是自然速度、最快压到 0.3 倍；压到 0.3 倍都写不完且开着慢慢显现的改成显现。
void _applyAppear(
  NebbiaLaidLine line,
  NebbiaSettings tuning,
  int idx,
  int seed,
) {
  final List<NebbiaAppear> kinds = tuning.appear
      .where((NebbiaAppear a) => a != NebbiaAppear.fade)
      .toList();
  final bool canFade = tuning.appear.contains(NebbiaAppear.fade);
  final NebbiaAppear? kind = kinds.isEmpty
      ? null
      : kinds[(LyricVisualizerRandom(
                      (seed + idx * 613 + 11) & 0xFFFFFFFF,
                    ).next() *
                    kinds.length)
                .floor() %
            kinds.length];
  final List<NebbiaLaidChar> cs = line.chars
      .where((NebbiaLaidChar c) => c.glyph != null)
      .toList();
  final List<double> nat = <double>[
    for (final NebbiaLaidChar c in cs)
      nebbiaNaturalWriteTime(c.glyph!, tuning.writeSpeed),
  ];
  final double until = math.max(line.next, line.end);
  double k = 1;
  if (_scheduleWrite(cs, nat, 1).end > until) {
    double lo = 0.3;
    double hi = 1;
    for (int n = 0; n < 14; n++) {
      final double m = (lo + hi) / 2;
      if (_scheduleWrite(cs, nat, m).end > until) {
        hi = m;
      } else {
        lo = m;
      }
    }
    k = lo;
  }
  final ({List<double> starts, double end}) plan = _scheduleWrite(cs, nat, k);
  final bool fade =
      kind == null || (canFade && cs.isNotEmpty && plan.end > until + 1e-3);
  for (int i = 0; i < cs.length; i++) {
    cs[i].wt = plan.starts[i];
    cs[i].wd = nat[i] * k;
  }
  if (kind == NebbiaAppear.breath && !fade && cs.isNotEmpty) {
    line.appearBreathAt = cs.first.wt - NebbiaFixed.breathSpread - 0.3;
    line.appearBreathUntil = line.end + NebbiaFixed.breathHold;
  }
  for (final NebbiaLaidChar c in line.chars) {
    c.appearDur = fade ? nebbiaClamp(c.d * 3, 0.35, 1.2) : 0;
  }
}

double _writtenAt(NebbiaLaidLine line) {
  double done = line.t;
  for (final NebbiaLaidChar c in line.chars) {
    if (c.glyph == null) continue;
    done = math.max(
      done,
      c.wd > 0 ? c.wt + c.wd : c.t + math.min(c.appearDur, 0.5),
    );
  }
  return done;
}

/// 这句最早什么时候让位：后面那句开写，但不早于这句写完再留一会儿。
double nebbiaYieldMoment(double nextT, NebbiaLaidLine line) =>
    math.max(nextT, _writtenAt(line) + _yieldRead + _yieldLead);

/// 让位系数：让位的句子在后面那句开写前 0.6 秒起用 1 秒快速起雾；被哈气盖掉的在白气鼓开时没了。
double nebbiaYieldFactor(NebbiaLaidLine line, double t) =>
    line.breathAt < double.infinity
    ? 1 -
          nebbiaSmooth(
            nebbiaClamp(((t - line.breathAt) / line.breathDur - 0.15) / 0.7),
          )
    : 1 - nebbiaSmooth(nebbiaClamp((t - line.yieldAt + _yieldLead) / 1));

/// 擦痕用的让位系数：哈气盖掉的不降到 0，留个浅印子。
double nebbiaYieldMask(NebbiaLaidLine line, double t) {
  final double yf = nebbiaYieldFactor(line, t);
  return line.breathAt < double.infinity
      ? math.max(yf, kNebbiaBreathGhost)
      : yf;
}

NebbiaFade _lineModeOf(List<NebbiaFade> fade, int idx, int seed) =>
    fade.length == 1
    ? fade.first
    : (LyricVisualizerRandom((seed + idx * 977 + 3) & 0xFFFFFFFF).next() < 0.5
          ? NebbiaFade.fog
          : NebbiaFade.fingers);

/// 排一首歌。
List<NebbiaLaidLine> buildNebbiaScene(
  List<NebbiaSourceLine> source,
  NebbiaGlyph? Function(String ch) glyphs,
  NebbiaSettings tuning, {
  required double width,
  required double height,
  required double fontScale,
  required int seed,
}) {
  final List<NebbiaFade> modes = <NebbiaFade>[
    for (int i = 0; i < source.length; i++)
      source[i].credits != null
          ? NebbiaFade.fog
          : _lineModeOf(tuning.fade, i, seed),
  ];
  double fadeOf(int i) => tuning.refog + (modes[i] == NebbiaFade.fog ? 0 : 2.5);
  final double creditsAt = source
      .firstWhere(
        (NebbiaSourceLine l) => l.credits != null,
        orElse: () => NebbiaSourceLine(
          chars: const <NebbiaChar>[],
          words: const <List<int>>[],
          t: double.infinity,
          end: double.infinity,
          next: double.infinity,
        ),
      )
      .t;
  double beforeCredits(int i) =>
      math.max(source[i].end + 0.5, creditsAt - fadeOf(i) * 0.6);
  double fogAt(int i) => source[i].credits != null
      ? double.infinity
      : math.min(
          nebbiaFogStartOf(source[i].end, source[i].next, tuning.hold),
          beforeCredits(i),
        );
  double lingerAt(int i) => math.max(
    fogAt(i),
    <double>[
      fogAt(i) + _lingerMax,
      (i + _lingerLines < source.length
              ? source[i + _lingerLines].t
              : double.infinity) +
          tuning.hold,
      beforeCredits(i),
    ].reduce(math.min),
  );
  double goneAt(int i) => fogAt(i) + fadeOf(i);
  final List<List<NebbiaCharPos>> pos = layoutNebbiaSong(
    source,
    NebbiaLayoutOptions(
      width: width,
      height: height,
      jitter: tuning.jitter,
      layouts: tuning.layouts,
      fontScale: fontScale,
      visibleUntil: goneAt,
      fogAt: fogAt,
      lingerUntil: (int i) => lingerAt(i) + fadeOf(i),
    ),
  );
  final List<NebbiaLaidLine> laid = <NebbiaLaidLine>[];
  for (int li = 0; li < source.length; li++) {
    final NebbiaSourceLine line = source[li];
    final List<NebbiaLaidChar> chars = <NebbiaLaidChar>[];
    for (int i = 0; i < line.chars.length; i++) {
      final NebbiaChar c = line.chars[i];
      final NebbiaCharPos p = pos[li][i];
      final bool wide = nebbiaIsWide(c.ch) || nebbiaIsIcon(c.ch);
      final NebbiaLaidChar out = NebbiaLaidChar(
        c,
        p.x,
        p.y,
        p.s * (wide ? 1 : 1.15),
        p.rot,
      )..wt = c.t;
      final NebbiaGlyph? base = glyphs(c.ch);
      if (base != null) {
        _decorate(
          out,
          base,
          LyricVisualizerRandom((li * 131 + i * 17 + 5) & 0xFFFFFFFF),
          tuning.warp,
        );
      }
      chars.add(out);
    }
    laid.add(
      NebbiaLaidLine(
        chars: chars,
        t: line.t,
        end: line.end,
        next: line.next,
        mode: modes[li],
        fogAt: fogAt(li),
        credits: line.credits,
      ),
    );
  }
  for (int li = 0; li < laid.length; li++) {
    _applyAppear(laid[li], tuning, li, seed);
  }
  // 片尾的歌手等曲名写完再写。
  final int ti = source.indexWhere(
    (NebbiaSourceLine l) => l.credits == NebbiaCredits.title,
  );
  final int ai = source.indexWhere(
    (NebbiaSourceLine l) => l.credits == NebbiaCredits.artist,
  );
  if (ti >= 0 && ai >= 0) {
    final List<NebbiaLaidChar> written = laid[ti].chars
        .where((NebbiaLaidChar c) => c.glyph != null)
        .toList();
    if (written.isNotEmpty) {
      final NebbiaLaidChar last = written.last;
      NebbiaLaidChar? first;
      for (final NebbiaLaidChar c in laid[ai].chars) {
        if (c.glyph != null) {
          first = c;
          break;
        }
      }
      final double shift = first == null
          ? 0
          : math.max(0, last.wt + last.wd + 0.4 - first.wt);
      for (final NebbiaLaidChar c in laid[ai].chars) {
        c.wt += shift;
      }
    }
  }
  // 让位与多留：后面第一句和这句重叠、且在这句消失前开始的，记下让位时刻；屏上还空着就晚点起雾；
  // 到让位时还消失不了的，在那句开写前哈一口气把这句盖掉。
  for (int i = 0; i < laid.length; i++) {
    final NebbiaLaidLine line = laid[i];
    if (source[i].credits != null) continue;
    final double gone = lingerAt(i) + fadeOf(i);
    int by = -1;
    for (int j = i + 1; j < laid.length && laid[j].t < gone; j++) {
      final NebbiaLineRect a = line.rect;
      final NebbiaLineRect b = laid[j].rect;
      if (math.min(a.x1, b.x1) > math.max(a.x0, b.x0) &&
          math.min(a.y1, b.y1) > math.max(a.y0, b.y0)) {
        line.yieldAt = nebbiaYieldMoment(laid[j].t, line);
        by = j;
        break;
      }
    }
    line.fogAt = math.max(
      fogAt(i),
      math.min(lingerAt(i), line.yieldAt - fadeOf(i)),
    );
    if (by >= 0 &&
        source[by].credits == null &&
        line.yieldAt < line.fogAt + fadeOf(i)) {
      final double from = math.max(
        line.yieldAt - NebbiaFixed.breathSpread - 0.3,
        _writtenAt(line) + _yieldRead,
      );
      line
        ..breathAt = from
        ..breathDur = math.max(0.3, line.yieldAt - 0.3 - from)
        ..breathUntil = laid[by].end + NebbiaFixed.breathHold;
    } else if (by >= 0 && line.mode == NebbiaFade.fingers) {
      laid[by].appearBreathAt = double.infinity;
    }
  }
  return laid;
}

/// 「手指来回搓掉」的几何：食指中指并拢，手从句子左头往右走，边走边快速上下来回搓。
NebbiaWipe? buildNebbiaWipe(NebbiaLaidLine line, int idx) {
  final LyricVisualizerRandom rnd = LyricVisualizerRandom(
    (idx * 4241 + 77) & 0xFFFFFFFF,
  );
  final NebbiaLineRect r = line.rect;
  if (!r.isFinite) return null;
  final double fw = math.max(14, r.s * 0.28);
  const int n = 2;
  final double gap = fw * 0.8;
  final double handW = gap + fw;
  final double cy = (r.y0 + r.y1) / 2;
  final double pad = r.s * 0.3;
  final List<({double w, double lenK})> fingers = <({double w, double lenK})>[
    (w: fw * (0.92 + rnd.next() * 0.08), lenK: 0.88 + rnd.next() * 0.04),
    (w: fw * (0.97 + rnd.next() * 0.08), lenK: 1),
  ];
  final double bowDir = rnd.next() < 0.5 ? 1 : -1;
  final double phase = rnd.next() * math.pi * 2;
  final double swing = 0.45 + rnd.next() * 0.15;
  final double len = (r.y1 - r.y0) + pad * 2;
  final double slant = math.sin(swing) * len * 0.5;
  final double xs = r.x0 - pad - slant;
  final double xe = r.x1 + pad + slant;
  final int rubs = math.max(6, ((xe - xs) / (handW * 0.5)).ceil());
  final List<NebbiaWipeStreak> streaks = <NebbiaWipeStreak>[];
  for (int k = 0; k < rubs; k++) {
    final double hx = xs + (xe - xs) * (k + 0.5) / rubs;
    final double down = k.isEven ? 1 : -1;
    final int pair = k ~/ 2;
    final double ang =
        swing * math.sin(phase + pair * 0.5) + (rnd.next() - 0.5) * 0.06;
    final double ca = math.cos(ang);
    final double sa = math.sin(ang);
    final double l = len * (0.95 + rnd.next() * 0.1);
    final double bow = bowDir * r.s * (0.08 + rnd.next() * 0.03);
    final double a = k / rubs * 0.96;
    final double b = math.min(1, (k + 1) / rubs * 0.96 + 0.04);
    for (int f = 0; f < n; f++) {
      final double off = (f - (n - 1) / 2) * gap;
      final List<Offset> pts = <Offset>[];
      for (int i = 0; i <= 12; i++) {
        final double t = i / 12;
        final double u = 2 * t - 1;
        final double v = down * (t - 0.5) * l * fingers[f].lenK;
        final double w = off + bow * (1 - u * u);
        pts.add(Offset(hx + sa * v + ca * w, cy + ca * v - sa * w));
      }
      streaks.add(NebbiaWipeStreak(pts, fingers[f].w, a, b));
    }
  }
  final List<({Offset p, double r})> beads = <({Offset p, double r})>[];
  for (final NebbiaWipeStreak st in streaks.sublist(streaks.length - n)) {
    final Offset e = st.pts.last;
    beads.add((p: e, r: st.w * 0.22 + 1.5 * rnd.next()));
    if (rnd.next() < 0.6) {
      final Offset d = st.pts[1] - st.pts[0];
      beads.add((
        p: Offset(
          e.dx - d.dx * 0.6 + (rnd.next() - 0.5) * st.w * 0.6,
          e.dy - d.dy * 0.6,
        ),
        r: 1.5 + rnd.next() * 2.5,
      ));
    }
  }
  return NebbiaWipe(streaks, beads, math.min(0.08 * rubs, 1.6));
}

/// 拖痕在整体进度 ue 下画到哪：0..1。
double nebbiaStreakProgress(NebbiaWipeStreak st, double ue) =>
    nebbiaClamp((ue - st.a) / (st.b - st.a));

/// (x, y) 处的水珠是否已经被手指带走。
bool nebbiaIsSwept(NebbiaWipe wipe, double ue, Offset q) {
  for (final NebbiaWipeStreak st in wipe.streaks) {
    final double lp = nebbiaStreakProgress(st, ue);
    if (lp <= 0) continue;
    final double last = lp * (st.pts.length - 1);
    final double r2 = (st.w * 0.7) * (st.w * 0.7);
    for (int i = 0; i < last; i++) {
      final Offset a = st.pts[i];
      final double f = math.min(1, last - i);
      final Offset d = (st.pts[i + 1] - a) * f;
      final double dd = d.dx * d.dx + d.dy * d.dy;
      final double t = nebbiaClamp(
        ((q.dx - a.dx) * d.dx + (q.dy - a.dy) * d.dy) / (dd == 0 ? 1 : dd),
      );
      final Offset e = q - a - d * t;
      if (e.dx * e.dx + e.dy * e.dy < r2) return true;
    }
  }
  return false;
}

/// 一句的白气：贴着整句外框的椭圆，再在四周叠几团大圆。
NebbiaBreathShape? buildNebbiaBreath(NebbiaLaidLine line, int idx) {
  final LyricVisualizerRandom rnd = LyricVisualizerRandom(
    (idx * 6151 + 29) & 0xFFFFFFFF,
  );
  final NebbiaLineRect r = line.rect;
  if (!r.isFinite) return null;
  final double cx = (r.x0 + r.x1) / 2;
  final double cy = (r.y0 + r.y1) / 2;
  final double rx = (r.x1 - r.x0) / 2 + r.s * 0.3;
  final double ry = (r.y1 - r.y0) / 2 + r.s * 0.3;
  final List<NebbiaLobe> lobes = <NebbiaLobe>[
    NebbiaLobe(cx, cy, rx * 0.95, ry * 0.95),
  ];
  final int n = 5 + (rnd.next() * 2).floor();
  final double r0 = math.min(rx, ry);
  for (int k = 0; k < n; k++) {
    final double a = (k + rnd.next() * 0.6) / n * math.pi * 2;
    final double rr = r0 * (0.45 + rnd.next() * 0.25);
    lobes.add(
      NebbiaLobe(
        cx + math.cos(a) * rx * 0.6,
        cy + math.sin(a) * ry * 0.6,
        rr,
        rr,
      ),
    );
  }
  return NebbiaBreathShape(lobes, cx, cy, ry);
}

/// 当前正在写的字和同一句里它后面的下一个字（聚光灯追它）。两句同时在写时只跟后一句。
({NebbiaLaidChar c, NebbiaLaidChar? next})? nebbiaWritingChar(
  List<NebbiaLaidLine> laid,
  double t,
) {
  for (int li = laid.length - 1; li >= 0; li--) {
    final NebbiaLaidLine line = laid[li];
    if (t < line.t - 0.05 || t > line.doneAt + 0.8) continue;
    int k = -1;
    for (int i = 0; i < line.chars.length; i++) {
      final NebbiaLaidChar c = line.chars[i];
      if (c.glyph != null &&
          nebbiaStartOf(c) <= t &&
          (k < 0 || nebbiaStartOf(c) >= nebbiaStartOf(line.chars[k]))) {
        k = i;
      }
    }
    if (k < 0) continue;
    NebbiaLaidChar? next;
    for (int i = k + 1; i < line.chars.length && next == null; i++) {
      if (line.chars[i].glyph != null) next = line.chars[i];
    }
    return (c: line.chars[k], next: next);
  }
  return null;
}
