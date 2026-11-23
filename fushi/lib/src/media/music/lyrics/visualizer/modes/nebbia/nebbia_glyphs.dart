/// 雾笺的字形（folia `nebbiaGlyphs.ts` + `nebbiaSkeleton.ts`）：字形 = 按书写顺序的几笔中线
/// （em 坐标 0..1，y 向下，基线在 0.8）。来源依次是：自己画的图标线稿、主题字体的骨架追踪
/// （把字画出来，Zhang-Suen 细化成单像素骨架，追踪成折线、化简、磨圆，笔顺按从上到下、从左到右估）。
///
/// 骨架要读像素，Flutter 里只能异步（`Picture.toImage` → `toByteData`），所以整首的字一次画进一张
/// 图集、在后台 isolate 里细化；没追踪好之前（以及 `flutter test` 里）每个字用「扫笔」字形：
/// 几道横扫的笔画当作书写顺序，画的时候用它去显出真正的字（nebbia_painter.dart），字照样认得出。
/// folia 中日文优先用 AnimCJK 笔顺数据（APL 授权，不进仓库），这里没有，全走骨架。
library;

import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_runtime.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/nebbia/nebbia_chars.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/nebbia/nebbia_layout.dart'
    show nebbiaClamp;

/// 一笔：折线、累计弧长、总长。
class NebbiaStroke {
  NebbiaStroke(this.pts, this.cum, this.len);
  final List<Offset> pts;
  final List<double> cum;
  final double len;
}

/// 一个字的几笔。[sweep] 为 true 时是扫笔字形（还没有骨架），笔画只决定书写顺序和进度。
class NebbiaGlyph {
  NebbiaGlyph(this.strokes, this.total, {this.sweep = false});
  final List<NebbiaStroke> strokes;
  final double total;
  final bool sweep;
}

/// 量出每一笔的累计弧长；太短的笔画丢掉。
NebbiaGlyph? nebbiaMeasureGlyph(
  List<List<Offset>> polys, {
  bool sweep = false,
}) {
  double total = 0;
  final List<NebbiaStroke> strokes = <NebbiaStroke>[];
  for (final List<Offset> pts in polys) {
    if (pts.length < 2) continue;
    final List<double> cum = <double>[0];
    for (int i = 1; i < pts.length; i++) {
      cum.add(cum[i - 1] + (pts[i] - pts[i - 1]).distance);
    }
    if (cum.last <= 0.005) continue;
    total += cum.last;
    strokes.add(NebbiaStroke(pts, cum, cum.last));
  }
  return strokes.isEmpty ? null : NebbiaGlyph(strokes, total, sweep: sweep);
}

/// Catmull-Rom 细分（图标线稿的稀疏点变顺滑）。
List<Offset> nebbiaCatmull(List<Offset> pts, int n) {
  if (pts.length < 3) return pts;
  final List<Offset> out = <Offset>[];
  for (int i = 0; i < pts.length - 1; i++) {
    final Offset p0 = pts[math.max(0, i - 1)];
    final Offset p1 = pts[i];
    final Offset p2 = pts[i + 1];
    final Offset p3 = pts[math.min(pts.length - 1, i + 2)];
    for (int k = 0; k < n; k++) {
      final double t = k / n;
      final double t2 = t * t;
      final double t3 = t2 * t;
      double at(double a0, double a1, double a2, double a3) =>
          0.5 *
          (2 * a1 +
              (-a0 + a2) * t +
              (2 * a0 - 5 * a1 + 4 * a2 - a3) * t2 +
              (-a0 + 3 * a1 - 3 * a2 + a3) * t3);
      out.add(
        Offset(at(p0.dx, p1.dx, p2.dx, p3.dx), at(p0.dy, p1.dy, p2.dy, p3.dy)),
      );
    }
  }
  out.add(pts.last);
  return out;
}

/// 折线上弧长 s 处的点和法线。
({Offset p, Offset n}) nebbiaPointAt(NebbiaStroke st, double s) {
  final List<Offset> pts = st.pts;
  final List<double> cum = st.cum;
  int i = 1;
  while (i < pts.length - 1 && cum[i] < s) {
    i++;
  }
  final Offset a = pts[i - 1];
  final Offset b = pts[i];
  final double l = math.max(1e-6, cum[i] - cum[i - 1]);
  final double k = nebbiaClamp((s - cum[i - 1]) / l);
  final double dx = (b.dx - a.dx) / l;
  final double dy = (b.dy - a.dy) / l;
  return (
    p: Offset(a.dx + (b.dx - a.dx) * k, a.dy + (b.dy - a.dy) * k),
    n: Offset(-dy, dx),
  );
}

/// 手写变形：整字有点斜、有点扁或瘦、带一点弯；每一笔各自偏一点、转一点、长短不一，沿笔画还有一点手抖。
NebbiaGlyph nebbiaWarpGlyph(
  NebbiaGlyph g,
  LyricVisualizerRandom rnd,
  double j,
) {
  if (j <= 0) return g;
  double r() => rnd.next() * 2 - 1;
  final double shear = r() * 0.16 * j;
  final double sx = 1 + r() * 0.1 * j;
  final double sy = 1 + r() * 0.1 * j;
  final double bx = r() * 0.035 * j;
  final double by = r() * 0.035 * j;
  final double px = rnd.next() * 6.28;
  final double py = rnd.next() * 6.28;
  Offset whole(Offset p) {
    double u = (p.dx - 0.5) * sx;
    double v = (p.dy - 0.5) * sy;
    u += v * shear;
    u += bx * math.sin(v * math.pi * 1.6 + px);
    v += by * math.sin(u * math.pi * 1.6 + py);
    return Offset(u + 0.5, v + 0.5);
  }

  // 扫笔字形只决定显出的顺序，不变形笔画本身（真正的字形不动），只整体斜切。
  final double sj = nebbiaClamp(8 / g.strokes.length, 0.35, 1);
  final List<List<Offset>> polys = <List<Offset>>[];
  for (final NebbiaStroke st in g.strokes) {
    final List<Offset> pts = st.pts;
    final int n = pts.length;
    double cx = 0;
    double cy = 0;
    for (final Offset p in pts) {
      cx += p.dx;
      cy += p.dy;
    }
    cx /= n;
    cy /= n;
    final double rot = r() * 0.09 * j * sj;
    final double len = 1 + r() * 0.1 * j * sj;
    final double ox = r() * 0.022 * j * sj;
    final double oy = r() * 0.022 * j * sj;
    final double cr = math.cos(rot);
    final double sr = math.sin(rot);
    final Offset p0 = pts.first;
    final double tremor = 0.006 * j;
    final double tf = 18 + rnd.next() * 14;
    final double tp = rnd.next() * 6.28;
    if (g.sweep) {
      polys.add(<Offset>[for (final Offset p in pts) whole(p)]);
      continue;
    }
    polys.add(<Offset>[
      for (int i = 0; i < n; i++)
        () {
          double u = p0.dx + (pts[i].dx - p0.dx) * len;
          double v = p0.dy + (pts[i].dy - p0.dy) * len;
          final double du = u - cx;
          final double dv = v - cy;
          u = cx + du * cr - dv * sr + ox;
          v = cy + du * sr + dv * cr + oy;
          final Offset a = pts[math.max(0, i - 1)];
          final Offset b = pts[math.min(n - 1, i + 1)];
          final double tx = b.dx - a.dx;
          final double ty = b.dy - a.dy;
          final double tl = math.sqrt(tx * tx + ty * ty) == 0
              ? 1
              : math.sqrt(tx * tx + ty * ty);
          final double k = math.sin(st.cum[i] * tf + tp) * tremor;
          return whole(Offset(u - ty / tl * k, v + tx / tl * k));
        }(),
    ]);
  }
  return nebbiaMeasureGlyph(polys, sweep: g.sweep) ?? g;
}

// ---------------------------------------------------------------------------
// 图标线稿（folia 用 lucide 图标；这里自己画几种，每个元素一笔，24 格坐标）
// ---------------------------------------------------------------------------

List<Offset> _arc(
  double cx,
  double cy,
  double r,
  double a0,
  double a1, [
  int n = 16,
]) => <Offset>[
  for (int i = 0; i <= n; i++)
    Offset(
      (cx + r * math.cos(a0 + (a1 - a0) * i / n)) / 24,
      (cy + r * math.sin(a0 + (a1 - a0) * i / n)) / 24,
    ),
];

List<Offset> _pts(List<double> xy) => <Offset>[
  for (int i = 0; i + 1 < xy.length; i += 2) Offset(xy[i] / 24, xy[i + 1] / 24),
];

List<List<Offset>>? _iconPolys(String name) {
  switch (name) {
    case 'heart':
      return <List<Offset>>[
        nebbiaCatmull(
          _pts(<double>[
            12,
            20,
            5,
            13.5,
            3.5,
            9,
            5.5,
            5.5,
            9,
            5,
            12,
            8,
            15,
            5,
            18.5,
            5.5,
            20.5,
            9,
            19,
            13.5,
            12,
            20,
          ]),
          4,
        ),
      ];
    case 'star':
      return <List<Offset>>[
        _pts(<double>[
          12,
          3,
          14.6,
          9,
          21,
          9.3,
          16,
          13.5,
          17.6,
          20,
          12,
          16.4,
          6.4,
          20,
          8,
          13.5,
          3,
          9.3,
          9.4,
          9,
          12,
          3,
        ]),
      ];
    case 'moon':
      return <List<Offset>>[
        <Offset>[
          ..._arc(12, 12, 8.5, -1.2, 3.6),
          ..._arc(15.5, 9.5, 6.5, 2.7, -0.7),
        ],
      ];
    case 'sun':
      return <List<Offset>>[
        _arc(12, 12, 4, -math.pi / 2, math.pi * 1.5, 20),
        for (int i = 0; i < 8; i++)
          <Offset>[
            Offset(
              (12 + 6.5 * math.cos(i * math.pi / 4)) / 24,
              (12 + 6.5 * math.sin(i * math.pi / 4)) / 24,
            ),
            Offset(
              (12 + 9 * math.cos(i * math.pi / 4)) / 24,
              (12 + 9 * math.sin(i * math.pi / 4)) / 24,
            ),
          ],
      ];
    case 'music':
      return <List<Offset>>[
        _arc(7, 18, 3, 0, math.pi * 2),
        _pts(<double>[10, 18, 10, 5, 20, 3, 20, 16]),
        _arc(17, 16, 3, 0, math.pi * 2),
      ];
    case 'flower':
      return <List<Offset>>[
        _arc(12, 11, 2.5, 0, math.pi * 2),
        for (int i = 0; i < 5; i++)
          _arc(
            12 + 5 * math.cos(i * 1.2566 - 1.57),
            11 + 5 * math.sin(i * 1.2566 - 1.57),
            2.8,
            0,
            math.pi * 2,
            12,
          ),
        _pts(<double>[12, 16, 12, 22]),
      ];
    case 'sparkles':
      return <List<Offset>>[
        nebbiaCatmull(
          _pts(<double>[
            10,
            3,
            11,
            8,
            16,
            10,
            11,
            12,
            10,
            17,
            9,
            12,
            4,
            10,
            9,
            8,
            10,
            3,
          ]),
          3,
        ),
        _pts(<double>[19, 3, 19, 7]),
        _pts(<double>[17, 5, 21, 5]),
      ];
    case 'umbrella':
      return <List<Offset>>[
        <Offset>[
          ..._arc(12, 12, 9, math.pi, math.pi * 2, 18),
          Offset(3 / 24, 12 / 24),
        ],
        nebbiaCatmull(_pts(<double>[12, 12, 12, 19, 13.5, 21, 15, 19.5]), 3),
      ];
    case 'smile':
      return <List<Offset>>[
        _arc(12, 12, 9, -math.pi / 2, math.pi * 1.5, 24),
        _arc(12, 12, 5, 0.5, math.pi - 0.5, 10),
        _pts(<double>[9, 9, 9, 10]),
        _pts(<double>[15, 9, 15, 10]),
      ];
    case 'leaf':
      return <List<Offset>>[
        nebbiaCatmull(
          _pts(<double>[4, 20, 6, 10, 13, 5, 20, 4, 19, 11, 14, 18, 4, 20]),
          3,
        ),
        _pts(<double>[4, 20, 14, 10]),
      ];
  }
  return null;
}

/// 还没有骨架的字：几道横扫的笔（中日文三道、其余一道），从左上往右下。
NebbiaGlyph nebbiaSweepGlyph(String ch) {
  final bool wide = nebbiaIsWideGlyph(ch);
  final List<List<Offset>> polys = wide
      ? <List<Offset>>[
          for (int r = 0; r < 3; r++)
            <Offset>[Offset(0.1, 0.2 + r * 0.25), Offset(0.9, 0.24 + r * 0.25)],
        ]
      : <List<Offset>>[
          <Offset>[const Offset(0.15, 0.45), const Offset(0.85, 0.5)],
        ];
  return nebbiaMeasureGlyph(polys, sweep: true)!;
}

bool nebbiaIsWideGlyph(String ch) {
  if (ch.isEmpty) return false;
  final int c = ch.runes.first;
  return lyricVisualizerIsCjk(ch) || (c >= 0x3000 && c <= 0x9FFF);
}

// ---------------------------------------------------------------------------
// 骨架追踪（纯函数，可单测）
// ---------------------------------------------------------------------------

/// 骨架图的边长（像素）。
const int kNebbiaSkeletonSize = 96;

/// Zhang-Suen 细化：两遍交替剥掉边界像素，直到只剩一像素宽的骨架。[img] 原地改。
void nebbiaThin(Uint8List img, int size) {
  int at(int x, int y) =>
      x < 0 || y < 0 || x >= size || y >= size ? 0 : img[y * size + x];
  bool changed = true;
  final List<int> n = List<int>.filled(8, 0);
  while (changed) {
    changed = false;
    for (int pass = 0; pass < 2; pass++) {
      final List<int> del = <int>[];
      for (int y = 0; y < size; y++) {
        for (int x = 0; x < size; x++) {
          if (img[y * size + x] == 0) continue;
          n[0] = at(x, y - 1);
          n[1] = at(x + 1, y - 1);
          n[2] = at(x + 1, y);
          n[3] = at(x + 1, y + 1);
          n[4] = at(x, y + 1);
          n[5] = at(x - 1, y + 1);
          n[6] = at(x - 1, y);
          n[7] = at(x - 1, y - 1);
          final int b = n[0] + n[1] + n[2] + n[3] + n[4] + n[5] + n[6] + n[7];
          if (b < 2 || b > 6) continue;
          int a = 0;
          for (int i = 0; i < 8; i++) {
            if (n[i] == 0 && n[(i + 1) % 8] == 1) a++;
          }
          if (a != 1) continue;
          final bool keep = pass == 0
              ? (n[0] * n[2] * n[4] != 0 || n[2] * n[4] * n[6] != 0)
              : (n[0] * n[2] * n[6] != 0 || n[0] * n[4] * n[6] != 0);
          if (keep) continue;
          del.add(y * size + x);
        }
      }
      for (final int i in del) {
        img[i] = 0;
      }
      if (del.isNotEmpty) changed = true;
    }
  }
}

const List<(int, int)> _nb = <(int, int)>[
  (1, 0),
  (0, 1),
  (-1, 0),
  (0, -1),
  (1, 1),
  (-1, 1),
  (-1, -1),
  (1, -1),
];

/// 骨架 → 折线（像素坐标）：先从端点出发走，再收拾剩下的环；每步优先沿原方向。
List<List<Offset>> nebbiaTraceSkeleton(Uint8List img, int size) {
  bool on(int x, int y) =>
      x >= 0 && y >= 0 && x < size && y < size && img[y * size + x] == 1;
  int deg(int x, int y) {
    int s = 0;
    for (final (int dx, int dy) in _nb) {
      if (on(x + dx, y + dy)) s++;
    }
    return s;
  }

  final Uint8List seen = Uint8List(size * size);
  final List<List<Offset>> polys = <List<Offset>>[];
  bool isolated(List<(int, int)> p) => p.every(
    ((int, int) q) => _nb.every(
      ((int, int) d) =>
          !on(q.$1 + d.$1, q.$2 + d.$2) ||
          p.any(((int, int) o) => o.$1 == q.$1 + d.$1 && o.$2 == q.$2 + d.$2),
    ),
  );
  void walk(int sx, int sy) {
    int x = sx;
    int y = sy;
    final List<(int, int)> p = <(int, int)>[(x, y)];
    seen[y * size + x] = 1;
    (int, int)? dir;
    for (;;) {
      (int, int, int, int)? best;
      double bestScore = -9;
      for (final (int dx, int dy) in _nb) {
        final int nx = x + dx;
        final int ny = y + dy;
        if (!on(nx, ny) || seen[ny * size + nx] == 1) continue;
        final double score = dir == null
            ? 0
            : (dx * dir.$1 + dy * dir.$2) / math.sqrt(dx * dx + dy * dy);
        if (score > bestScore) {
          bestScore = score;
          best = (nx, ny, dx, dy);
        }
      }
      if (best == null) break;
      x = best.$1;
      y = best.$2;
      dir = (best.$3, best.$4);
      seen[y * size + x] = 1;
      p.add((x, y));
    }
    if (p.length >= 4) {
      polys.add(<Offset>[
        for (final (int, int) q in p) Offset(q.$1.toDouble(), q.$2.toDouble()),
      ]);
    } else if (isolated(p)) {
      // 不连着别的笔画的一个点（粗字重的点画细化后只剩几个像素）留下。
      final Offset a = Offset(p.first.$1.toDouble(), p.first.$2.toDouble());
      polys.add(
        p.length > 1
            ? <Offset>[
                for (final (int, int) q in p)
                  Offset(q.$1.toDouble(), q.$2.toDouble()),
              ]
            : <Offset>[a, a + const Offset(1, 1)],
      );
    }
  }

  for (int y = 0; y < size; y++) {
    for (int x = 0; x < size; x++) {
      if (img[y * size + x] == 1 && deg(x, y) == 1 && seen[y * size + x] == 0) {
        walk(x, y);
      }
    }
  }
  for (int y = 0; y < size; y++) {
    for (int x = 0; x < size; x++) {
      if (img[y * size + x] == 1 && seen[y * size + x] == 0) walk(x, y);
    }
  }
  return polys;
}

/// Ramer-Douglas-Peucker 化简。
List<Offset> nebbiaRdp(List<Offset> pts, double eps) {
  if (pts.length < 3) return pts;
  final Offset a = pts.first;
  final Offset b = pts.last;
  final double l = (b - a).distance == 0 ? 1 : (b - a).distance;
  int idx = 0;
  double dmax = 0;
  for (int i = 1; i < pts.length - 1; i++) {
    final double d =
        ((b.dx - a.dx) * (a.dy - pts[i].dy) -
                (a.dx - pts[i].dx) * (b.dy - a.dy))
            .abs() /
        l;
    if (d > dmax) {
      dmax = d;
      idx = i;
    }
  }
  if (dmax <= eps) return <Offset>[a, b];
  final List<Offset> left = nebbiaRdp(pts.sublist(0, idx + 1), eps);
  final List<Offset> right = nebbiaRdp(pts.sublist(idx), eps);
  return <Offset>[...left.sublist(0, left.length - 1), ...right];
}

/// Chaikin 磨角。
List<Offset> nebbiaChaikin(List<Offset> input, int iterations) {
  List<Offset> pts = input;
  for (int k = 0; k < iterations && pts.length > 2; k++) {
    final List<Offset> o = <Offset>[pts.first];
    for (int i = 0; i < pts.length - 1; i++) {
      final Offset p = pts[i];
      final Offset q = pts[i + 1];
      o
        ..add(p * 0.75 + q * 0.25)
        ..add(p * 0.25 + q * 0.75);
    }
    o.add(pts.last);
    pts = o;
  }
  return pts;
}

/// 一格二值图（1 = 墨）→ 按书写顺序的骨架笔画（em 坐标）；没有墨时 null。
List<List<Offset>>? nebbiaSkeletonPolys(Uint8List img, int size) {
  nebbiaThin(img, size);
  final List<List<Offset>> polys = <List<Offset>>[
    for (final List<Offset> p in nebbiaTraceSkeleton(img, size))
      <Offset>[
        for (final Offset q in nebbiaChaikin(nebbiaRdp(p, 1.2), 2))
          q / size.toDouble(),
      ],
  ];
  // 每条线从更靠左上的一端开始；整体从上到下、从左到右。
  for (int i = 0; i < polys.length; i++) {
    final Offset a = polys[i].first;
    final Offset b = polys[i].last;
    if (a.dy + a.dx * 0.6 > b.dy + b.dx * 0.6) {
      polys[i] = polys[i].reversed.toList();
    }
  }
  double minOf(List<Offset> p, bool y) => p.fold<double>(
    double.infinity,
    (double m, Offset q) => math.min(m, y ? q.dy : q.dx),
  );
  polys.sort(
    (List<Offset> a, List<Offset> b) =>
        ((minOf(a, true) - minOf(b, true)) * 0.6 +
                (minOf(a, false) - minOf(b, false)))
            .sign
            .toInt(),
  );
  return polys.isEmpty ? null : polys;
}

/// 一张 RGBA 图集（[cols] 列，每格 [kNebbiaSkeletonSize]）→ 每格的骨架（isolate 里跑）。
List<List<List<Offset>>?> nebbiaTraceAtlas(
  Uint8List rgba,
  int cols,
  int count,
) {
  const int sk = kNebbiaSkeletonSize;
  final int stride = cols * sk;
  final List<List<List<Offset>>?> out = <List<List<Offset>>?>[];
  for (int i = 0; i < count; i++) {
    final int ox = (i % cols) * sk;
    final int oy = (i ~/ cols) * sk;
    final Uint8List img = Uint8List(sk * sk);
    for (int y = 0; y < sk; y++) {
      for (int x = 0; x < sk; x++) {
        // 白字画在透明底上：看 alpha。
        img[y * sk + x] = rgba[((oy + y) * stride + ox + x) * 4 + 3] > 110
            ? 1
            : 0;
      }
    }
    out.add(nebbiaSkeletonPolys(img, sk));
  }
  return out;
}

// ---------------------------------------------------------------------------
// 字形缓存
// ---------------------------------------------------------------------------

/// 字形缓存：全局一份（换歌不重算），按字体分开。骨架追踪好一批就 [notifyListeners]，
/// 用到的场景据此重排。
class NebbiaGlyphCache extends ChangeNotifier {
  NebbiaGlyphCache._();

  static final NebbiaGlyphCache instance = NebbiaGlyphCache._();

  final Map<String, NebbiaGlyph?> _traced = <String, NebbiaGlyph?>{};
  final Set<String> _pending = <String>{};
  String _font = '';
  bool _busy = false;
  final List<(Set<String>, TextStyle)> _queue = <(Set<String>, TextStyle)>[];

  /// 改了多少次（场景按它判断要不要重排）。
  int version = 0;

  /// 一个字的字形：图标线稿、追踪好的骨架，或扫笔字形；空白 null。
  NebbiaGlyph? get(String ch) {
    if (nebbiaIsIcon(ch)) {
      final List<List<Offset>>? polys = _iconPolys(
        ch.substring(kNebbiaIconPrefix.length),
      );
      return polys == null ? null : nebbiaMeasureGlyph(polys);
    }
    if (ch.trim().isEmpty) return null;
    final NebbiaGlyph? hit = _traced[ch];
    if (hit != null) return hit;
    return nebbiaSweepGlyph(ch);
  }

  /// 有没有已经追踪好的骨架（单测 / 调试用）。
  bool hasSkeleton(String ch) => _traced[ch] != null;

  /// 排队追踪这些字（按 [style] 的字体）。
  void request(Iterable<String> chars, TextStyle style) {
    final String font = '${style.fontFamily}|${style.fontWeight}';
    if (font != _font) {
      _font = font;
      _traced.clear();
      _pending.clear();
      version++;
    }
    final Set<String> want = <String>{
      for (final String ch in chars)
        if (ch.trim().isNotEmpty &&
            !nebbiaIsIcon(ch) &&
            !_traced.containsKey(ch) &&
            !_pending.contains(ch))
          ch,
    };
    if (want.isEmpty) return;
    _pending.addAll(want);
    _queue.add((want, style));
    unawaited(_drain());
  }

  Future<void> _drain() async {
    if (_busy) return;
    _busy = true;
    try {
      while (_queue.isNotEmpty) {
        final (Set<String> chars, TextStyle style) = _queue.removeAt(0);
        await _traceBatch(chars.toList(), style);
      }
    } finally {
      _busy = false;
    }
  }

  Future<void> _traceBatch(List<String> chars, TextStyle style) async {
    const int sk = kNebbiaSkeletonSize;
    final String font = _font;
    const int cols = 16;
    final int rows = (chars.length / cols).ceil();
    final ui.PictureRecorder rec = ui.PictureRecorder();
    final Canvas canvas = Canvas(rec);
    for (int i = 0; i < chars.length; i++) {
      final TextPainter tp = TextPainter(
        text: TextSpan(
          text: chars[i],
          style: style.copyWith(
            fontSize: sk * 0.78,
            color: const Color(0xFFFFFFFF),
            height: 1,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final double base = tp.computeDistanceToActualBaseline(
        TextBaseline.alphabetic,
      );
      tp.paint(
        canvas,
        Offset(
          (i % cols) * sk + sk / 2 - tp.width / 2,
          (i ~/ cols) * sk + sk * 0.8 - base,
        ),
      );
      tp.dispose();
    }
    final ui.Picture picture = rec.endRecording();
    try {
      final ui.Image image = await picture.toImage(cols * sk, rows * sk);
      final ByteData? data = await image.toByteData();
      image.dispose();
      if (data == null) return;
      final Uint8List bytes = data.buffer.asUint8List();
      final int count = chars.length;
      final List<List<List<Offset>>?> polys = await Isolate.run(
        () => nebbiaTraceAtlas(bytes, cols, count),
      );
      if (font != _font) return;
      for (int i = 0; i < chars.length; i++) {
        final List<List<Offset>>? p = polys[i];
        _traced[chars[i]] = p == null ? null : nebbiaMeasureGlyph(p);
        _pending.remove(chars[i]);
      }
      version++;
      notifyListeners();
    } catch (e) {
      // 拿不到像素（无 GPU / 测试环境）：照旧用扫笔字形。
      debugPrint('Nebbia: skeleton tracing failed: $e');
    } finally {
      picture.dispose();
    }
  }
}
