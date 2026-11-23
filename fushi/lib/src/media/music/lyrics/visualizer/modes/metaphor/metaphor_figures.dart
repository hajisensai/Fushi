/// 隐喻的线稿（纯函数，移植 folia `metaphor/metaphorFigures.ts`）：用细线、弧、波浪线、点和注记
/// 小字画出来的图，像论文和演算纸上的插图。
/// 1. 图（[planMetaphorFigures]）：天体物理、晶体、分子、粒子物理实验、费曼图、路径积分、演算草稿
///    和十张高能物理草稿图，一共十九种。一个 cue 挑几张摆在字外面空着的地方，一笔一笔隔 0.2 秒冒出来；
///    另有一张大的垫在字后面，只进半调。
/// 2. 版面（[planMetaphorBackdrop]）：字后面的一层网点（色带、方格纸、同心弧、点阵），和贴着字块的
///    规线、裁切标记、行号与时间码。
/// 注记（公式、标签）用另一种字体画成细的墨字；这里只管放在哪，字宽由外面量。
library;

import 'dart:math' as math;

import 'package:characters/characters.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/modes/metaphor/metaphor_layout.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/metaphor/metaphor_program.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/metaphor/metaphor_shapes.dart';

class MetaphorNote {
  const MetaphorNote({
    required this.text,
    required this.x,
    required this.y,
    required this.size,
    required this.rot,
    required this.align,
    required this.born,
  });

  final String text;

  /// 锚点：align 0 是左端，0.5 中点，1 右端；竖直方向是字的中线。
  final double x;
  final double y;
  final double size;
  final double rot;
  final double align;
  final double born;
}

class MetaphorNoteGlyph {
  const MetaphorNoteGlyph({
    required this.char,
    required this.x,
    required this.y,
    required this.size,
    required this.rot,
    required this.born,
  });

  final String char;
  final double x;
  final double y;
  final double size;
  final double rot;
  final double born;
}

class MetaphorFigures {
  MetaphorFigures(this.shapes, this.notes);

  final List<MetaphorShape> shapes;
  final List<MetaphorNote> notes;
}

/// 十九种图。
enum MetaphorFigureKind {
  orbit,
  starmap,
  lattice,
  cell,
  molecule,
  detector,
  feynman,
  paths,
  draft,
  shower,
  decay,
  bubble,
  spectrum,
  penguin,
  box,
  collider,
  potential,
  running,
  cherenkov,
}

const int _figureLimit = 240;
const int _backdropLimit = 48;
const double _tau = math.pi * 2;

/// 线的半宽（世界单位）。
const double metaphorStroke = 0.016;

/// 融球阈值以上的那块是它半轴的多少。
const double _blobCore = 0.55;

/// 弧画在它那一格的多少处。
const double metaphorArcAt = 0.9;

/// 波浪线的振幅是它那一格半高的多少。
const double metaphorWaveAmp = 0.75;

typedef _Mix = ({double ink, double tone, double accent});

const _Mix _inkMix = (ink: 1, tone: 0, accent: 0);

/// 一支笔：在一张图自己的坐标里画（图大约占半径 1），落到世界里时平移、缩放、转一个角度。
class _Pen {
  _Pen(
    this.cx,
    this.cy,
    this.scale,
    this.rot,
    this.delay, [
    this.mix = _inkMix,
    this.heavy = 1,
  ]) : _cos = math.cos(rot),
       _sin = math.sin(rot);

  final double cx;
  final double cy;
  final double scale;
  final double rot;
  final double delay;
  final _Mix mix;
  final double heavy;
  final double _cos;
  final double _sin;
  final List<MetaphorShape> shapes = <MetaphorShape>[];
  final List<MetaphorNote> notes = <MetaphorNote>[];
  int _stroke = 0;

  (double, double) _at(double x, double y) =>
      (cx + (x * _cos - y * _sin) * scale, cy + (x * _sin + y * _cos) * scale);

  /// 三笔一组，一组比上一组晚 0.2 秒。
  double _born() {
    final double born = delay + (_stroke ~/ 3) * 0.2;
    _stroke += 1;
    return born;
  }

  void line(
    double x0,
    double y0,
    double x1,
    double y1, [
    double dashes = 0,
    double weight = 1,
  ]) {
    final (double ax, double ay) = _at(x0, y0);
    final (double bx, double by) = _at(x1, y1);
    shapes.add(
      MetaphorShape(
        shape: metaphorShapeBar,
        x: (ax + bx) / 2,
        y: (ay + by) / 2,
        sx: _hypot(bx - ax, by - ay) / 2,
        sy: metaphorStroke * weight * heavy,
        rot: math.atan2(by - ay, bx - ax),
        param: dashes,
        born: _born(),
        ink: mix.ink,
        tone: mix.tone,
        accent: mix.accent,
      ),
    );
  }

  void wave(
    double x0,
    double y0,
    double x1,
    double y1,
    double halfWaves,
    double amp,
  ) {
    final (double ax, double ay) = _at(x0, y0);
    final (double bx, double by) = _at(x1, y1);
    shapes.add(
      MetaphorShape(
        shape: metaphorShapeWave,
        x: (ax + bx) / 2,
        y: (ay + by) / 2,
        sx: _hypot(bx - ax, by - ay) / 2,
        sy: (amp * scale) / metaphorWaveAmp + metaphorStroke * 3,
        rot: math.atan2(by - ay, bx - ax),
        param: halfWaves,
        born: _born(),
        ink: mix.ink,
        tone: mix.tone + (heavy > 1 ? 0.2 : 0),
        accent: mix.accent,
      ),
    );
  }

  void arc(
    double x,
    double y,
    double radius, [
    double mid = 0,
    double half = math.pi,
    double weight = 1,
  ]) {
    final (double ax, double ay) = _at(x, y);
    shapes.add(
      MetaphorShape(
        shape: metaphorShapeArc,
        x: ax,
        y: ay,
        sx: (radius * scale) / metaphorArcAt,
        sy: weight * heavy,
        rot: mid + rot,
        param: math.min(1, half / math.pi),
        born: _born(),
        ink: mix.ink,
        tone: mix.tone,
        accent: mix.accent,
      ),
    );
  }

  void dot(double x, double y, double radius) {
    final (double ax, double ay) = _at(x, y);
    final double size = (radius * scale) / _blobCore;
    shapes.add(
      MetaphorShape(
        shape: metaphorShapeBlob,
        x: ax,
        y: ay,
        sx: size,
        sy: size,
        born: _born(),
        ink: mix.ink,
        tone: mix.tone,
        accent: mix.accent,
      ),
    );
  }

  /// 绕着一个点匀速转的点（行星）。
  void orbiter(
    double x,
    double y,
    double orbit,
    double radius,
    double speed,
    double phase,
  ) {
    final (double ax, double ay) = _at(x, y);
    final double size = (radius * scale) / _blobCore;
    shapes.add(
      MetaphorShape(
        shape: metaphorShapeBlob,
        x: ax,
        y: ay,
        sx: size,
        sy: size,
        orbit: orbit * scale,
        orbitSpeed: speed,
        p1: phase,
        steady: true,
        born: _born(),
        ink: mix.ink,
        tone: mix.tone,
        accent: mix.accent,
      ),
    );
  }

  /// 带箭头的线：箭头在线上 at 处，朝终点。
  void arrow(double x0, double y0, double x1, double y1, [double at = 0.55]) {
    line(x0, y0, x1, y1);
    final double angle = math.atan2(y1 - y0, x1 - x0);
    final double hx = x0 + (x1 - x0) * at;
    final double hy = y0 + (y1 - y0) * at;
    for (final double side in const <double>[0.45, -0.45]) {
      line(
        hx,
        hy,
        hx - math.cos(angle + side) * 0.11,
        hy - math.sin(angle + side) * 0.11,
      );
    }
  }

  void note(
    String text,
    double x,
    double y,
    double size, [
    double align = 0,
    double r = 0,
  ]) {
    final (double ax, double ay) = _at(x, y);
    notes.add(
      MetaphorNote(
        text: text,
        x: ax,
        y: ay,
        size: size * scale,
        rot: r + rot,
        align: align,
        born: _born(),
      ),
    );
  }
}

double _hypot(double a, double b) => math.sqrt(a * a + b * b);
double _span(MetaphorRng rng, double min, double max) =>
    min + rng() * (max - min);
T _choose<T>(MetaphorRng rng, List<T> items) =>
    items[math.min(items.length - 1, (rng() * items.length).floor())];
List<T> _shuffle<T>(MetaphorRng rng, List<T> items) {
  final List<T> list = List<T>.of(items);
  for (int index = list.length - 1; index > 0; index--) {
    final int other = (rng() * (index + 1)).floor();
    final T tmp = list[index];
    list[index] = list[other];
    list[other] = tmp;
  }
  return list;
}

double _pow15(double r) => r * math.sqrt(r);

void _drawOrbit(_Pen pen, MetaphorRng rng) {
  final int rings = 3 + (rng() * 2).floor();
  pen.dot(0, 0, 0.085);
  for (int index = 0; index < rings; index++) {
    final double radius = 0.3 + (index * 0.7) / (rings - 1);
    pen.arc(0, 0, radius);
    final double size = _span(rng, 0.03, 0.055);
    final double speed = ((rng() < 0.85 ? 1 : -1) * 0.1) / _pow15(radius);
    pen.orbiter(0, 0, radius, size, speed, rng() * _tau);
  }
  final double angle = _span(rng, 0.2, 1.2);
  pen.line(0, 0, math.cos(angle), math.sin(angle), 9);
  pen.arc(0, 0, 0.16, angle / 2, angle / 2);
  pen.note(
    _choose(rng, <String>['T² ∝ a³', 'a = 1.52 AU', 'e = 0.0167', 'v² = GM/r']),
    math.cos(angle) * 1.08,
    math.sin(angle) * 1.08,
    0.15,
  );
  final double cx = _span(rng, -0.4, 0.4);
  final double cy = _span(rng, 0.9, 1.3);
  pen.arc(cx, cy, 1.5, -math.pi / 2, 0.55);
}

void _drawStarmap(_Pen pen, MetaphorRng rng) {
  final List<(double, double)> stars = <(double, double)>[];
  for (int tries = 0; stars.length < 7 && tries < 60; tries++) {
    final double angle = rng() * _tau;
    final double radius = math.sqrt(rng()) * 0.85;
    final double x = math.cos(angle) * radius;
    final double y = math.sin(angle) * radius;
    if (stars.every(
      ((double, double) s) => _hypot(s.$1 - x, s.$2 - y) > 0.32,
    )) {
      stars.add((x, y));
    }
  }
  stars.sort(((double, double) a, (double, double) b) => a.$1.compareTo(b.$1));
  for (int index = 0; index < stars.length; index++) {
    final (double x, double y) = stars[index];
    pen.dot(x, y, _span(rng, 0.03, 0.07));
    if (index > 0) pen.line(stars[index - 1].$1, stars[index - 1].$2, x, y);
  }
  final (double, double) named = stars.length > 1 ? stars[1] : stars[0];
  final (double, double) crossed = stars.last;
  pen
    ..arc(named.$1, named.$2, 0.14)
    ..note(
      _choose(rng, <String>['α', 'β', 'γ', 'δ']),
      named.$1 + 0.18,
      named.$2 + 0.14,
      0.17,
    );
  for (final (int, int) d in const <(int, int)>[
    (1, 0),
    (-1, 0),
    (0, 1),
    (0, -1),
  ]) {
    pen.line(
      crossed.$1 + d.$1 * 0.1,
      crossed.$2 + d.$2 * 0.1,
      crossed.$1 + d.$1 * 0.24,
      crossed.$2 + d.$2 * 0.24,
    );
  }
  final double mid = _span(rng, 0.9, 2.2);
  pen.arc(0, 0, 1.08, mid, 0.5);
  for (int tick = -2; tick <= 2; tick++) {
    final double angle = mid + tick * 0.22;
    pen.line(
      math.cos(angle) * 1.08,
      math.sin(angle) * 1.08,
      math.cos(angle) * 1.16,
      math.sin(angle) * 1.16,
    );
  }
  pen.note(
    _choose(rng, <String>[
      'δ −05° 23′',
      'RA 05h 35m',
      'z = 0.0073',
      'd = 4.2 ly',
    ]),
    -0.95,
    -1.05,
    0.14,
  );
}

void _drawLattice(_Pen pen, MetaphorRng rng) {
  final double gamma = _choose(rng, <double>[math.pi / 3, math.pi / 2, 1.3]);
  const double pitch = 0.46;
  final double bx = math.cos(gamma) * pitch;
  final double by = math.sin(gamma) * pitch;
  (double, double) at(int column, int row) =>
      ((column - 1.5) * pitch + (row - 1) * bx, (row - 1) * by);
  for (int row = 0; row < 3; row++) {
    for (int column = 0; column < 4; column++) {
      final (double x, double y) = at(column, row);
      if (column < 3) {
        final (double nx, double ny) = at(column + 1, row);
        pen.line(x, y, nx, ny);
      }
      if (row < 2) {
        final (double nx, double ny) = at(column, row + 1);
        pen.line(x, y, nx, ny);
      }
      pen.dot(x, y, 0.045);
    }
  }
  final (double ox, double oy) = at(1, 0);
  final (double ax, double ay) = at(2, 0);
  final (double cx, double cy) = at(1, 1);
  pen
    ..line(ox, oy, ax, ay, 0, 2.2)
    ..line(ox, oy, cx, cy, 0, 2.2)
    ..note('a', ox + pitch / 2, oy - 0.14, 0.16, 0.5)
    ..note('b', ox + bx / 2 - 0.14, oy + by / 2, 0.16, 0.5);
  for (int column = 0; column < 3; column++) {
    final (double x, double y) = at(column, 1);
    pen.arc(x + (pitch + bx) / 2, y + by / 2, 0.05);
  }
  pen.note(
    _choose(rng, <String>[
      'nλ = 2d sinθ',
      'a = 5.43 Å',
      '(1 1 1)',
      'G · R = 2πn',
    ]),
    -0.9,
    -0.82,
    0.15,
  );
}

void _drawCell(_Pen pen, MetaphorRng rng) {
  const double half = 0.52;
  const List<(double, double)> front = <(double, double)>[
    (-half - 0.2, -half - 0.14),
    (half - 0.2, -half - 0.14),
    (half - 0.2, half - 0.14),
    (-half - 0.2, half - 0.14),
  ];
  final List<(double, double)> back = <(double, double)>[
    for (final (double x, double y) in front) (x + 0.44, y + 0.32),
  ];
  for (int index = 0; index < 4; index++) {
    final int next = (index + 1) % 4;
    pen
      ..line(front[index].$1, front[index].$2, front[next].$1, front[next].$2)
      ..line(
        back[index].$1,
        back[index].$2,
        back[next].$1,
        back[next].$2,
        index == 0 || index == 3 ? 7 : 0,
      )
      ..line(
        front[index].$1,
        front[index].$2,
        back[index].$1,
        back[index].$2,
        index == 0 ? 5 : 0,
      )
      ..dot(front[index].$1, front[index].$2, 0.055)
      ..dot(back[index].$1, back[index].$2, 0.045);
  }
  final bool faceCentred = rng() < 0.5;
  if (faceCentred) {
    for (final List<(double, double)> face in <List<(double, double)>>[
      front,
      back,
    ]) {
      pen.arc(
        (face[0].$1 + face[2].$1) / 2,
        (face[0].$2 + face[2].$2) / 2,
        0.06,
      );
    }
    for (int index = 0; index < 4; index++) {
      final int next = (index + 1) % 4;
      pen.arc(
        (front[index].$1 + back[next].$1) / 2,
        (front[index].$2 + back[next].$2) / 2,
        0.05,
      );
    }
  } else {
    pen
      ..dot(0.02, 0.02, 0.075)
      ..line(front[0].$1, front[0].$2, back[2].$1, back[2].$2, 9);
  }
  pen
    ..note(faceCentred ? 'fcc' : 'bcc', -half - 0.2, half + 0.38, 0.18)
    ..note(
      _choose(rng, <String>['a = 3.61 Å', 'a = 2.87 Å', '[1 0 0]', 'Z = 4']),
      -half - 0.2,
      -half - 0.36,
      0.14,
    );
}

void _drawMolecule(_Pen pen, MetaphorRng rng) {
  if (rng() < 0.55) {
    (double, double) vertex(int index, double radius) => (
      math.cos(math.pi / 6 + (index * math.pi) / 3) * radius,
      math.sin(math.pi / 6 + (index * math.pi) / 3) * radius,
    );
    for (int index = 0; index < 6; index++) {
      final (double ax0, double ay0) = vertex(index, 0.5);
      final (double bx0, double by0) = vertex(index + 1, 0.5);
      pen.line(ax0, ay0, bx0, by0);
      if (index.isEven) {
        final (double ax, double ay) = vertex(index, 0.39);
        final (double bx, double by) = vertex(index + 1, 0.39);
        pen.line(
          ax + (bx - ax) * 0.12,
          ay + (by - ay) * 0.12,
          bx + (ax - bx) * 0.12,
          by + (ay - by) * 0.12,
        );
      }
    }
    final List<String> groups = _shuffle(rng, <String>[
      'OH',
      'NH₂',
      'CH₃',
      'Cl',
      'COOH',
    ]);
    final List<int> picks = _shuffle(rng, <int>[0, 1, 2, 3, 4, 5]);
    final int take = 1 + (rng() * 2).floor();
    for (int order = 0; order < take; order++) {
      final int index = picks[order];
      final (double x, double y) = vertex(index, 0.5);
      final (double ex, double ey) = vertex(index, 0.86);
      final (double nx, double ny) = vertex(index, 1.02);
      pen
        ..line(x, y, ex, ey)
        ..note(groups[order], nx, ny, 0.16, 0.5);
    }
    pen.note(
      _choose(rng, <String>['C₆H₆', 'sp²', 'π', '1.39 Å']),
      0,
      -1.05,
      0.15,
      0.5,
    );
    return;
  }
  final (int arms, double angle, String formula) = _choose(
    rng,
    const <(int, double, String)>[
      (2, 104.5, 'H₂O'),
      (3, 120, 'BF₃'),
      (4, 109.5, 'CH₄'),
      (2, 180, 'CO₂'),
    ],
  );
  final double spread = arms == 2 ? (angle * math.pi) / 180 : _tau / arms;
  final double start = math.pi / 2 - (arms == 2 ? spread / 2 : 0);
  pen.dot(0, 0, 0.13);
  for (int index = 0; index < arms; index++) {
    final double d = start + index * spread;
    pen
      ..line(
        math.cos(d) * 0.14,
        math.sin(d) * 0.14,
        math.cos(d) * 0.62,
        math.sin(d) * 0.62,
        0,
        1.6,
      )
      ..dot(math.cos(d) * 0.7, math.sin(d) * 0.7, 0.08);
  }
  if (angle < 180) {
    final String label = angle == angle.roundToDouble()
        ? '${angle.round()}°'
        : '$angle°';
    pen
      ..arc(0, 0, 0.3, start + spread / 2, spread / 2)
      ..note(
        label,
        math.cos(start + spread / 2) * 0.42,
        math.sin(start + spread / 2) * 0.42,
        0.13,
        0.5,
      );
  }
  pen.note(formula, 0, -0.95, 0.18, 0.5);
}

void _drawDetector(_Pen pen, MetaphorRng rng) {
  pen
    ..arc(0, 0, 0.32)
    ..arc(0, 0, 0.62)
    ..arc(0, 0, 1, 0, math.pi, 1.6)
    ..dot(0, 0, 0.035);
  for (int track = 5 + (rng() * 4).floor(); track > 0; track--) {
    final double bend = _span(rng, 0.55, 2.4);
    final double direction = rng() * _tau;
    final int side = rng() < 0.5 ? 1 : -1;
    final double reach = rng() < 0.3 ? 0.62 : 1;
    final double centre = direction + (side * math.pi) / 2;
    final double half = math.asin(math.min(1, reach / (2 * bend)));
    pen.arc(
      math.cos(centre) * bend,
      math.sin(centre) * bend,
      bend,
      centre + math.pi + side * half,
      half,
    );
  }
  final List<double> jets = <double>[rng() * _tau, rng() * _tau];
  for (int tower = 7 + (rng() * 4).floor(); tower > 0; tower--) {
    final double angle = _choose(rng, jets) + _span(rng, -0.35, 0.35);
    final double height = _span(rng, 0.05, 0.3);
    pen.line(
      math.cos(angle) * 1.04,
      math.sin(angle) * 1.04,
      math.cos(angle) * (1.04 + height),
      math.sin(angle) * (1.04 + height),
      0,
      2.4,
    );
  }
  pen.note(
    _choose(rng, <String>[
      '√s = 13 TeV',
      'pT > 20 GeV',
      '|η| < 2.5',
      'B = 3.8 T',
    ]),
    -1,
    -1.3,
    0.14,
  );
}

void _drawFeynman(_Pen pen, MetaphorRng rng) {
  final int variant = (rng() * 3).floor();
  if (variant == 0) {
    final List<String> names = _choose(rng, const <List<String>>[
      <String>['e⁻', 'e⁺', 'γ', 'μ⁻', 'μ⁺'],
      <String>['u', 'd', 'W', 'e', 'ν'],
      <String>['q', 'q', 'g', 't', 't'],
    ]);
    pen
      ..arrow(-1, 0.6, -0.35, 0)
      ..arrow(-0.35, 0, -1, -0.6)
      ..wave(-0.35, 0, 0.35, 0, 7, 0.07)
      ..arrow(0.35, 0, 1, 0.6)
      ..arrow(1, -0.6, 0.35, 0)
      ..dot(-0.35, 0, 0.04)
      ..dot(0.35, 0, 0.04)
      ..note(names[0], -1.02, 0.78, 0.17, 0.5)
      ..note(names[1], -1.02, -0.78, 0.17, 0.5)
      ..note(names[2], 0, 0.22, 0.17, 0.5)
      ..note(names[3], 1.02, 0.78, 0.17, 0.5)
      ..note(names[4], 1.02, -0.78, 0.17, 0.5);
  } else if (variant == 1) {
    for (final double y in const <double>[0.45, -0.45]) {
      pen
        ..arrow(-1, y, 0, y)
        ..arrow(0, y, 1, y)
        ..dot(0, y, 0.04);
    }
    pen
      ..wave(0, 0.45, 0, -0.45, 9, 0.07)
      ..note('e⁻', -1.02, 0.64, 0.17, 0.5)
      ..note('p', -1.02, -0.66, 0.17, 0.5)
      ..note('γ', 0.2, 0, 0.17, 0.5)
      ..note('−ie γμ', 0.2, 0.68, 0.13);
  } else {
    pen
      ..wave(-1, 0, -0.4, 0, 7, 0.07)
      ..arc(0, 0, 0.4)
      ..wave(0.4, 0, 1, 0, 7, 0.07)
      ..dot(-0.4, 0, 0.04)
      ..dot(0.4, 0, 0.04)
      ..line(0, 0.4, -0.1, 0.46)
      ..line(0, 0.4, -0.1, 0.34)
      ..line(0, -0.4, 0.1, -0.34)
      ..line(0, -0.4, 0.1, -0.46)
      ..note('γ', -0.72, 0.2, 0.17, 0.5)
      ..note('k', 0, 0.6, 0.15, 0.5)
      ..note('O(α²)', 0.5, -0.66, 0.14);
  }
  pen
    ..line(-0.9, -1, 0.9, -1, 0, 0.8)
    ..line(0.9, -1, 0.8, -0.95, 0, 0.8)
    ..line(0.9, -1, 0.8, -1.05, 0, 0.8)
    ..note('t', 1, -1, 0.14);
}

void _drawPaths(_Pen pen, MetaphorRng rng) {
  pen
    ..dot(-0.9, 0, 0.06)
    ..dot(0.9, 0, 0.06)
    ..line(-0.9, 0, 0.9, 0, 0, 1.5);
  for (int halfWaves = 1; halfWaves <= 6; halfWaves++) {
    pen.wave(
      -0.9,
      0,
      0.9,
      0,
      halfWaves.toDouble(),
      _span(rng, 0.12, 0.6) / math.sqrt(halfWaves),
    );
  }
  pen
    ..note('A', -1.08, 0, 0.17, 0.5)
    ..note('B', 1.08, 0, 0.17, 0.5)
    ..note(
      _choose(rng, <String>[
        'Z = ∫Dφ exp(iS/ħ)',
        'δS = 0',
        'S = ∫ L dt',
        '⟨B|A⟩ = Σ exp(iS/ħ)',
      ]),
      -0.9,
      -0.85,
      0.15,
    );
}

const List<String> _formulas = <String>[
  'E² = p²c² + m²c⁴',
  'S = ∫ L d⁴x',
  '∇·E = ρ/ε₀',
  'Δx Δp ≥ ħ/2',
  'r = 2GM/c²',
  '1/(p² − m² + iε)',
  '∫ d⁴k/(2π)⁴',
  'α ≈ 1/137',
  'Σ 1/n² = π²/6',
  'H ψ = E ψ',
  '∂μ Fμν = Jν',
  'T = 2.725 K',
  'F = G m₁m₂/r²',
  'dS ≥ 0',
  'β = −11 + 2n/3',
];

void _drawDraft(_Pen pen, MetaphorRng rng) {
  final List<String> lines = _shuffle(rng, _formulas).sublist(0, 4);
  final int struck = (rng() * 2).floor();
  const int boxed = 3;
  for (int row = 0; row < lines.length; row++) {
    final String text = lines[row];
    final double y = 0.85 - row * 0.3;
    final double width = text.runes.length * 0.085;
    pen.note(text, -1, y, 0.16);
    if (row == struck) pen.line(-1.04, y - 0.03, -1 + width + 0.04, y + 0.04);
    if (row == 2) pen.line(-1, y - 0.12, -1 + width, y - 0.12);
    if (row == boxed) {
      const double x0 = -1.08;
      final double x1 = -1 + width + 0.08;
      final double y0 = y - 0.14;
      final double y1 = y + 0.14;
      pen
        ..line(x0, y0, x1, y0)
        ..line(x1, y0, x1, y1)
        ..line(x1, y1, x0, y1)
        ..line(x0, y1, x0, y0);
    }
  }
  const double ox = -0.2;
  const double oy = -1.1;
  pen
    ..line(ox, oy, ox + 1.2, oy)
    ..line(ox, oy, ox, oy + 0.62);
  final double peak = _span(rng, 0.45, 0.8);
  for (int index = 0; index < 11; index++) {
    final double x = 0.08 + index * 0.1;
    final double offset = (x - peak) / 0.11;
    pen.dot(
      ox + x,
      oy + 0.06 + 0.5 / (1 + offset * offset) + _span(rng, -0.025, 0.025),
      0.022,
    );
  }
  pen
    ..line(ox + peak, oy, ox + peak, oy + 0.6, 7)
    ..note(
      _choose(rng, <String>['m = 125 GeV', 'Γ', 'm₀', 'σ(E)']),
      ox + peak + 0.06,
      oy + 0.64,
      0.13,
    )
    ..note(
      _choose(rng, <String>['∴', '= 0 ?', '→ ∞', '+ h.c.', 'QED']),
      0.55,
      0.55,
      0.2,
    );
}

void _drawShower(_Pen pen, MetaphorRng rng) {
  pen
    ..arrow(-1.05, 0, -0.6, 0)
    ..note('e⁻', -1.05, 0.16, 0.16);
  List<(double, double, bool)> layer = <(double, double, bool)>[
    (-0.6, 0, false),
  ];
  for (int generation = 0; generation < 4; generation++) {
    final double spread = 0.42 / math.pow(2, generation);
    final List<(double, double, bool)> next = <(double, double, bool)>[];
    if (generation > 0) pen.line(layer[0].$1, -0.95, layer[0].$1, 0.95, 11);
    for (final (double nx, double ny, bool photon) in layer) {
      pen.dot(nx, ny, 0.022);
      for (final int side in const <int>[1, -1]) {
        final double cx = nx + 0.38;
        final double cy = ny + side * spread * _span(rng, 0.8, 1.15);
        final bool childPhoton = photon ? false : side > 0;
        if (childPhoton) {
          pen.wave(nx, ny, cx, cy, 5, 0.028);
        } else {
          pen.line(nx, ny, cx, cy);
        }
        next.add((cx, cy, childPhoton));
      }
    }
    layer = next;
  }
  pen
    ..note('X₀', -0.22, -1.08, 0.15, 0.5)
    ..note(
      _choose(rng, <String>['N ≈ 2ⁿ', 'E/2ⁿ < Ec', 'tmax ∝ ln E']),
      0.2,
      1.1,
      0.14,
    );
}

void _drawDecay(_Pen pen, MetaphorRng rng) {
  final List<String> v = _choose(rng, const <List<String>>[
    <String>['H', 'Z', 'μ⁺', 'μ⁻', 'e⁺', 'e⁻', 'm = 125 GeV'],
    <String>['H', 'W', 'ℓ', 'ν', 'q', 'q', 'BR ≈ 21%'],
    <String>['t t', 'W', 'b', 'ℓν', 'b', 'jj', 'm = 173 GeV'],
  ]);
  pen
    ..dot(-0.95, 0, 0.07)
    ..line(-0.95, 0, -0.4, 0, 5)
    ..dot(-0.4, 0, 0.035)
    ..note(v[0], -0.95, 0.2, 0.18, 0.5);
  final List<List<String>> leaves = <List<String>>[
    <String>[v[2], v[3]],
    <String>[v[4], v[5]],
  ];
  const List<int> sides = <int>[1, -1];
  for (int branch = 0; branch < 2; branch++) {
    final int side = sides[branch];
    final double y = side * 0.52;
    pen
      ..wave(-0.4, 0, 0.2, y, 7, 0.045)
      ..dot(0.2, y, 0.035)
      ..note(v[1], -0.16, y * 0.5 + side * 0.2, 0.16, 0.5);
    for (int leaf = 0; leaf < 2; leaf++) {
      final double end = y + sides[leaf] * 0.3;
      pen
        ..arrow(0.2, y, 0.9, end)
        ..note(leaves[branch][leaf], 1.04, end, 0.16, 0.5);
    }
  }
  pen.note(v[6], -1, -1, 0.14);
}

void _spiral(
  _Pen pen,
  double x,
  double y,
  double radius,
  double shrink,
  double direction,
  double flip,
) {
  for (int turn = 0; turn < 5 && radius - turn * shrink > 0.03; turn++) {
    final double centre = x + direction * (radius - (turn.isEven ? 0 : shrink));
    pen.arc(
      centre,
      y,
      radius - turn * shrink,
      (turn.isEven ? 1 : -1) * flip * (math.pi / 2),
      math.pi / 2,
    );
  }
}

void _drawBubble(_Pen pen, MetaphorRng rng) {
  final double vx = _span(rng, -0.15, 0.15);
  final double vy = _span(rng, -0.25, 0.05);
  pen
    ..line(-1.1, vy - 0.25, vx, vy, 9)
    ..dot(vx, vy, 0.03);
  _spiral(pen, vx, vy, _span(rng, 0.3, 0.42), 0.07, -1, 1);
  _spiral(pen, vx, vy, _span(rng, 0.36, 0.5), 0.085, 1, -1);
  for (int track = 2 + (rng() * 2).floor(); track > 0; track--) {
    final double angle = _span(rng, -0.5, 0.5);
    pen.line(vx, vy, vx + math.cos(angle) * 1.1, vy + math.sin(angle) * 1.1);
  }
  for (int bubble = 0; bubble < 7; bubble++) {
    pen.dot(
      -0.95 + bubble * (0.2 - bubble * 0.012),
      0.75 + bubble * 0.03,
      0.02,
    );
  }
  for (final (double, double) c in const <(double, double)>[
    (-0.85, -0.85),
    (0.85, 0.8),
  ]) {
    pen
      ..line(c.$1 - 0.1, c.$2, c.$1 + 0.1, c.$2)
      ..line(c.$1, c.$2 - 0.1, c.$1, c.$2 + 0.1);
  }
  pen
    ..note('γ → e⁺e⁻', vx - 0.5, vy - 0.62, 0.15)
    ..note(
      _choose(rng, <String>['B = 2 T', 'p = 0.3 B r', 'Λ → p π⁻']),
      0.3,
      -1,
      0.14,
    );
}

void _drawSpectrum(_Pen pen, MetaphorRng rng) {
  const double ox = -0.9;
  const double oy = -0.8;
  pen
    ..line(ox, oy, 1, oy)
    ..line(ox, oy, ox, 0.85);
  final int peak = 6 + (rng() * 4).floor();
  const int bins = 14;
  const double width = 1.8 / bins;
  for (int bin = 0; bin < bins; bin++) {
    final double offset = (bin - peak) / 0.9;
    final double height =
        1.35 * math.exp(-bin * 0.2) + 0.3 * math.exp(-offset * offset) + 0.05;
    final double x = ox + 0.05 + bin * width;
    pen.line(x, oy + height, x + width, oy + height);
    final double point = oy + height + _span(rng, -0.06, 0.06);
    pen
      ..dot(x + width / 2, point, 0.022)
      ..line(x + width / 2, point - 0.07, x + width / 2, point + 0.07);
  }
  final double px = ox + 0.05 + (peak + 0.5) * width;
  pen
    ..line(px, oy, px, oy + 0.95, 7)
    ..note(
      _choose(rng, <String>['125', '91.2', '3.1']),
      px,
      oy - 0.14,
      0.14,
      0.5,
    )
    ..note(
      _choose(rng, <String>['m(γγ)  GeV', 'm(μμ)  GeV', 'm(4ℓ)  GeV']),
      1,
      oy - 0.14,
      0.14,
      1,
    )
    ..note('Events', ox - 0.14, 0.85, 0.14, 1, math.pi / 2)
    ..note(
      _choose(rng, <String>['5σ', 'S/√B', 'χ²/ndf = 1.1']),
      px + 0.12,
      oy + 1.02,
      0.16,
    );
}

void _drawPenguin(_Pen pen, MetaphorRng rng) {
  pen
    ..arrow(-1.05, 0.15, -0.45, 0.15)
    ..arrow(-0.45, 0.15, 0.45, 0.15, 0.3)
    ..arrow(0.45, 0.15, 1.05, 0.15)
    ..arc(0, 0.15, 0.45, math.pi / 2, math.pi / 2)
    ..dot(-0.45, 0.15, 0.035)
    ..dot(0.45, 0.15, 0.035)
    ..dot(0, 0.15, 0.035)
    ..wave(0, 0.15, 0, -0.5, 9, 0.05)
    ..dot(0, -0.5, 0.035)
    ..arrow(0, -0.5, 0.75, -0.3)
    ..arrow(0.75, -0.8, 0, -0.5)
    ..note('b', -1.05, 0.33, 0.17, 0.5)
    ..note('s', 1.05, 0.33, 0.17, 0.5)
    ..note('W', 0, 0.76, 0.17, 0.5)
    ..note(_choose(rng, <String>['t', 'u, c, t']), -0.22, 0.02, 0.14, 0.5)
    ..note('g', 0.18, -0.2, 0.16, 0.5)
    ..note('q', 0.88, -0.28, 0.15, 0.5)
    ..note('q', 0.88, -0.84, 0.15, 0.5)
    ..note(
      _choose(rng, <String>['b → s g', 'Vtb V*ts', 'O(GF αs)']),
      -1,
      -0.95,
      0.14,
    );
}

void _drawBox(_Pen pen, MetaphorRng rng) {
  final List<String> v = _choose(rng, const <List<String>>[
    <String>['K⁰', 's', 'd'],
    <String>['B⁰', 'b', 'd'],
    <String>['D⁰', 'c', 'u'],
  ]);
  pen
    ..arrow(-1.05, 0.38, -0.42, 0.38)
    ..arrow(-0.42, 0.38, 0.42, 0.38)
    ..arrow(0.42, 0.38, 1.05, 0.38)
    ..arrow(1.05, -0.38, 0.42, -0.38)
    ..arrow(0.42, -0.38, -0.42, -0.38)
    ..arrow(-0.42, -0.38, -1.05, -0.38)
    ..wave(-0.42, 0.38, -0.42, -0.38, 7, 0.05)
    ..wave(0.42, 0.38, 0.42, -0.38, 7, 0.05);
  for (final double x in const <double>[-0.42, 0.42]) {
    pen
      ..dot(x, 0.38, 0.035)
      ..dot(x, -0.38, 0.035);
  }
  pen
    ..note(v[1], -0.75, 0.56, 0.16, 0.5)
    ..note(v[2], -0.75, -0.58, 0.16, 0.5)
    ..note(v[2], 0.75, 0.56, 0.16, 0.5)
    ..note(v[1], 0.75, -0.58, 0.16, 0.5)
    ..note('u, c, t', 0, 0.56, 0.13, 0.5)
    ..note('W', -0.62, 0, 0.16, 0.5)
    ..note('W', 0.62, 0, 0.16, 0.5)
    ..note(v[0], -1.25, 0, 0.18, 0.5)
    ..note(
      _choose(rng, <String>['Δm', 'ΔF = 2', 'ε ≈ 2.2×10⁻³']),
      -0.3,
      -1,
      0.15,
    );
}

void _drawCollider(_Pen pen, MetaphorRng rng) {
  pen
    ..arc(0.15, 0.1, 0.85, 0, math.pi, 1.4)
    ..arc(0.15, 0.1, 0.79)
    ..arc(-0.52, -0.68, 0.27)
    ..arc(-0.92, -0.9, 0.1)
    ..line(-1.3, -1.02, -1, -0.96, 0, 2.2)
    ..line(-0.84, -0.84, -0.72, -0.86)
    ..line(-0.33, -0.49, -0.42, -0.52);
  final double turn = rng() * 0.6;
  const List<int> ips = <int>[1, 2, 5, 8];
  for (int point = 0; point < 4; point++) {
    final double angle = turn + (point * math.pi) / 2;
    final double cos = math.cos(angle);
    final double sin = math.sin(angle);
    pen
      ..dot(0.15 + cos * 0.82, 0.1 + sin * 0.82, 0.05)
      ..line(
        0.15 + cos * 0.7,
        0.1 + sin * 0.7,
        0.15 + cos * 0.95,
        0.1 + sin * 0.95,
        0,
        1.6,
      )
      ..note('IP${ips[point]}', 0.15 + cos * 1.12, 0.1 + sin * 1.12, 0.13, 0.5);
  }
  for (final (double angle, double radius, int way) in <(double, double, int)>[
    (turn + 0.8, 0.85, 1),
    (turn + 0.8 + math.pi, 0.79, -1),
  ]) {
    final double x = 0.15 + math.cos(angle) * radius;
    final double y = 0.1 + math.sin(angle) * radius;
    final double along = angle + (way * math.pi) / 2;
    for (final double side in const <double>[0.5, -0.5]) {
      pen.line(
        x,
        y,
        x - math.cos(along + side) * 0.12,
        y - math.sin(along + side) * 0.12,
      );
    }
  }
  pen
    ..note(
      _choose(rng, <String>['27 km', 'C = 26.7 km', '2808 bunches']),
      0.15,
      0.1,
      0.16,
      0.5,
    )
    ..note(
      _choose(rng, <String>['√s = 13.6 TeV', 'L = 2×10³⁴', 'B = 8.3 T']),
      0.15,
      -0.14,
      0.13,
      0.5,
    )
    ..note('LINAC', -1.3, -1.18, 0.12);
}

void _drawPotential(_Pen pen, MetaphorRng rng) {
  double curve(double x) {
    final double k = x * x - 0.5;
    return 3.2 * k * k - 0.6;
  }

  pen
    ..line(-1.15, -0.78, 1.15, -0.78)
    ..line(0, -0.9, 0, 0.9);
  const int steps = 22;
  for (int step = 0; step < steps; step++) {
    final double x0 = -1.05 + (step * 2.1) / steps;
    final double x1 = -1.05 + ((step + 1) * 2.1) / steps;
    pen.line(x0, curve(x0), x1, curve(x1), 0, 1.3);
  }
  final int side = rng() < 0.5 ? 1 : -1;
  final double valley = side * math.sqrt1_2;
  pen
    ..arc(0, curve(0) + 0.07, 0.06)
    ..dot(valley, curve(valley) + 0.07, 0.065)
    ..line(
      side * 0.1,
      curve(0) + 0.02,
      valley - side * 0.12,
      curve(valley) + 0.24,
      6,
    )
    ..line(valley, -0.78, valley, curve(valley), 5)
    ..note('V(φ)', 0.08, 0.92, 0.16)
    ..note('φ', 1.2, -0.92, 0.16, 0.5)
    ..note('v', valley, -0.92, 0.15, 0.5)
    ..note(
      _choose(rng, <String>[
        'v = 246 GeV',
        'μ² < 0',
        'V = μ²φ² + λφ⁴',
        'mH² = 2λv²',
      ]),
      -1.1,
      -1.12,
      0.14,
    );
}

void _drawRunning(_Pen pen, MetaphorRng rng) {
  const double ox = -0.9;
  const double oy = -0.8;
  pen
    ..line(ox, oy, 1.05, oy)
    ..line(ox, oy, ox, 0.85);
  for (int tick = 1; tick <= 6; tick++) {
    pen.line(
      ox + tick * 0.28,
      oy,
      ox + tick * 0.28,
      oy + (tick.isEven ? 0.08 : 0.05),
    );
  }
  final double meet = _span(rng, 0.5, 0.7);
  final double gap = rng() < 0.5 ? 0.09 : 0.02;
  const List<double> starts = <double>[0.62, 0.05, -0.5];
  const List<String> subs = <String>['₁', '₂', '₃'];
  for (int index = 0; index < starts.length; index++) {
    final double start = starts[index];
    final double end = -0.02 + (index - 1) * -gap;
    final double slope = (end - start) / (meet - ox);
    pen
      ..line(ox, start, 1, start + slope * (1 - ox), 0, index == 2 ? 1.6 : 1)
      ..note('α${subs[index]}⁻¹', ox + 0.08, start + 0.13, 0.15);
  }
  pen
    ..line(meet, oy, meet, 0.6, 9)
    ..note(
      _choose(rng, <String>['10¹⁶ GeV', 'MGUT', 'Λ']),
      meet,
      oy - 0.14,
      0.14,
      0.5,
    )
    ..note('log Q', 1.05, oy - 0.14, 0.14, 1)
    ..note(
      _choose(rng, <String>['β₀ = 11 − 2n/3', 'dα/d ln Q = β(α)', 'SUSY ?']),
      0,
      0.92,
      0.14,
    );
}

void _drawCherenkov(_Pen pen, MetaphorRng rng) {
  final double sine = _span(rng, 0.42, 0.6);
  final double angle = math.asin(sine);
  pen.arrow(-1.1, 0, 1.05, 0, 0.92);
  for (int wave = 0; wave < 6; wave++) {
    final double x = -0.85 + wave * 0.3;
    pen
      ..arc(x, 0, (0.9 - x) * sine)
      ..dot(x, 0, 0.02);
  }
  final double reach = 1.75 * math.cos(angle);
  for (final int side in const <int>[1, -1]) {
    pen.line(
      0.9,
      0,
      0.9 - math.cos(angle) * reach,
      side * math.sin(angle) * reach,
      0,
      1.5,
    );
    final double fx = 0.9 - math.cos(angle) * reach * 0.55;
    final double fy = side * math.sin(angle) * reach * 0.55;
    pen.wave(
      fx,
      fy,
      fx + math.sin(angle) * 0.5,
      fy + side * math.cos(angle) * 0.5,
      6,
      0.035,
    );
  }
  pen
    ..arc(0.9, 0, 0.3, math.pi - angle / 2, angle / 2)
    ..note('θ', 0.5, 0.1, 0.15, 0.5)
    ..note('cos θ = 1/nβ', -1.1, -1.12, 0.15)
    ..note(
      _choose(rng, <String>['β > 1/n', 'n = 1.33', 'v > c/n']),
      0.35,
      1.02,
      0.14,
    );
}

final Map<MetaphorFigureKind, void Function(_Pen, MetaphorRng)> _draw =
    <MetaphorFigureKind, void Function(_Pen, MetaphorRng)>{
      MetaphorFigureKind.orbit: _drawOrbit,
      MetaphorFigureKind.starmap: _drawStarmap,
      MetaphorFigureKind.lattice: _drawLattice,
      MetaphorFigureKind.cell: _drawCell,
      MetaphorFigureKind.molecule: _drawMolecule,
      MetaphorFigureKind.detector: _drawDetector,
      MetaphorFigureKind.feynman: _drawFeynman,
      MetaphorFigureKind.paths: _drawPaths,
      MetaphorFigureKind.draft: _drawDraft,
      MetaphorFigureKind.shower: _drawShower,
      MetaphorFigureKind.decay: _drawDecay,
      MetaphorFigureKind.bubble: _drawBubble,
      MetaphorFigureKind.spectrum: _drawSpectrum,
      MetaphorFigureKind.penguin: _drawPenguin,
      MetaphorFigureKind.box: _drawBox,
      MetaphorFigureKind.collider: _drawCollider,
      MetaphorFigureKind.potential: _drawPotential,
      MetaphorFigureKind.running: _drawRunning,
      MetaphorFigureKind.cherenkov: _drawCherenkov,
    };

/// 垫在字后面的那张：只进半调，线粗到网点画得出来。
const _Mix _toneMix = (ink: 0, tone: 0.75, accent: 0);
const double _toneHeavy = 2.6;

/// 一张图单独画出来：中心在 (x, y)，大小 scale。toned 时画成垫在字后面的那种（只进半调、粗线、不带注记）。
MetaphorFigures drawMetaphorFigure(
  MetaphorFigureKind kind,
  MetaphorRng rng, {
  double x = 0,
  double y = 0,
  double scale = 1,
  double rot = 0,
  double delay = 0,
  bool toned = false,
}) {
  final _Pen pen = toned
      ? _Pen(x, y, scale, rot, delay, _toneMix, _toneHeavy)
      : _Pen(x, y, scale, rot, delay);
  _draw[kind]!(pen, rng);
  return MetaphorFigures(
    pen.shapes,
    toned ? const <MetaphorNote>[] : pen.notes,
  );
}

const List<(double, double)> _stageSlots = <(double, double)>[
  (-0.72, 0.3),
  (0.72, -0.3),
  (0, -0.1),
];
const double _figureReach = 1.35;
const double _wideMargin = 1.1;
const double _frameSpill = 1.15;

class _Cell {
  const _Cell(this.x, this.y, this.scale);

  final double x;
  final double y;
  final double scale;
}

/// 全景镜头看得见的那块切成几个大格，去掉碰到字的，打乱。
List<_Cell> _freeCells(
  double halfW,
  double halfH,
  double aspect,
  MetaphorRng rng,
) {
  final double frameH =
      math.max(math.max(halfH, 0.6), math.max(halfW, 0.8) / aspect) *
      _wideMargin *
      _frameSpill;
  final double frameW = frameH * aspect;
  final double cell = math.min(
    5,
    math.max(2.4, math.min(frameW, frameH) / 1.1),
  );
  final int columns = math.max(1, ((frameW * 2) / cell).round());
  final int rows = math.max(1, ((frameH * 2) / cell).round());
  final double cellW = (frameW * 2) / columns;
  final double cellH = (frameH * 2) / rows;
  final List<_Cell> cells = <_Cell>[];
  for (int row = 0; row < rows; row++) {
    for (int column = 0; column < columns; column++) {
      final double x0 = -frameW + column * cellW;
      final double y0 = -frameH + row * cellH;
      if (x0 < halfW + 0.15 &&
          x0 + cellW > -halfW - 0.15 &&
          y0 < halfH + 0.15 &&
          y0 + cellH > -halfH - 0.15) {
        continue;
      }
      cells.add(
        _Cell(
          x0 + cellW / 2,
          y0 + cellH / 2,
          math.min(2.4, math.min(cellW, cellH) / (2 * _figureReach)),
        ),
      );
    }
  }
  return _shuffle(rng, cells);
}

/// 一个 cue 的几张图。歌词：摆在字外面、画面里空着的地方。间奏：在舞台里排开。
/// amount 是「融球」的倍数（0 就没有）。
MetaphorFigures planMetaphorFigures(
  MetaphorRect bounds,
  MetaphorRng rng,
  double amount,
  bool interlude, [
  double aspect = 1.6,
]) {
  final MetaphorFigures figures = MetaphorFigures(
    <MetaphorShape>[],
    <MetaphorNote>[],
  );
  if (amount <= 0) return figures;
  final double halfW = (bounds.x1 - bounds.x0) / 2;
  final double halfH = (bounds.y1 - bounds.y0) / 2;
  final double reach = math.max(math.max(halfW, halfH), 2);
  final List<_Cell> cells = interlude
      ? const <_Cell>[]
      : _freeCells(halfW, halfH, math.min(4, math.max(0.25, aspect)), rng);
  final double wanted = cells.isNotEmpty
      ? cells.length * 0.5 * math.min(1.5, amount) + rng() * 0.6
      : 1.6 * amount + rng() * 0.9;
  final int total = interlude
      ? math.min(_stageSlots.length, 1 + amount.round())
      : math.min(4, math.max(1, wanted.round()));
  final List<MetaphorFigureKind> kinds = _shuffle(
    rng,
    MetaphorFigureKind.values,
  );
  final List<int> sides = _shuffle(rng, <int>[0, 1, 2, 3]);
  final double ux = _span(rng, -0.35, 0.35) * halfW;
  final double uy = _span(rng, -0.35, 0.35) * halfH;
  final double us = reach * (interlude ? 0.6 : 0.85) * _span(rng, 0.85, 1.2);
  final double ur = _span(rng, -0.3, 0.3);
  final MetaphorFigures under = drawMetaphorFigure(
    kinds[total],
    rng,
    x: ux,
    y: uy,
    scale: us,
    rot: ur,
    toned: true,
  );
  figures.shapes.addAll(under.shapes);
  for (int index = 0; index < total; index++) {
    double scale =
        (interlude ? 1.2 : math.min(2, math.max(1, reach * 0.36))) *
        _span(rng, 0.85, 1.15);
    double x;
    double y;
    if (interlude) {
      final (double slotX, double slotY) =
          _stageSlots[index % _stageSlots.length];
      x = slotX * halfW + _span(rng, -0.25, 0.25);
      y = slotY * halfH + _span(rng, -0.3, 0.3);
    } else if (index < cells.length) {
      final _Cell cell = cells[index];
      final double fit = _span(rng, 0.7, 0.95);
      scale = math.max(0.8, cell.scale * fit);
      x = cell.x + _span(rng, -1, 1) * cell.scale * (1 - fit) * _figureReach;
      y = cell.y + _span(rng, -1, 1) * cell.scale * (1 - fit) * _figureReach;
    } else {
      final double out = scale * _figureReach + 0.2;
      final int side = sides[index];
      final double along = _span(rng, -0.7, 0.7);
      x = side < 2 ? along * halfW : (side == 2 ? -1 : 1) * (halfW + out);
      y = side < 2 ? (side == 0 ? 1 : -1) * (halfH + out) : along * halfH;
    }
    final double rot = _span(rng, -0.12, 0.12);
    final MetaphorFigures figure = drawMetaphorFigure(
      kinds[index % kinds.length],
      rng,
      x: x,
      y: y,
      scale: scale,
      rot: rot,
      delay: 0.3 + index * 0.7,
    );
    figures.shapes.addAll(figure.shapes);
    figures.notes.addAll(figure.notes);
  }
  if (figures.shapes.length > _figureLimit) {
    figures.shapes.removeRange(_figureLimit, figures.shapes.length);
  }
  return figures;
}

String _pad2(double v) => math.max(0, v.floor()).toString().padLeft(2, '0');
String _timecode(double seconds) =>
    '${_pad2(seconds / 60)}:${_pad2(seconds % 60)}';

/// 一个 cue 的版面：字后面的一层网点，和贴着字块的规线、裁切标记、行号与时间码（只有歌词有）。
/// [index] 是第几句（从 1 数，间奏是 0），[time] 是开唱的时刻（秒）。
MetaphorFigures planMetaphorBackdrop(
  MetaphorRect bounds,
  MetaphorRng rng,
  double amount,
  bool interlude, {
  required int index,
  required double time,
}) {
  final double halfW = (bounds.x1 - bounds.x0) / 2;
  final double halfH = (bounds.y1 - bounds.y0) / 2;
  final double reach = math.max(math.max(halfW, halfH), 2);
  final List<MetaphorShape> shapes = <MetaphorShape>[];

  if (amount > 0) {
    final String layer = _choose(rng, <String>[
      'band',
      'band',
      'grid',
      'arcs',
      'dots',
      'plain',
    ]);
    if (layer == 'band') {
      final bool upright = rng() < 0.3;
      final double half = (upright ? halfW : halfH) * _span(rng, 0.3, 0.75);
      final double shift = (upright ? halfW : halfH) * _span(rng, -0.7, 0.7);
      final double tone = _span(rng, 0.3, 0.5);
      final double tilt = rng() < 0.4 ? _span(rng, -0.2, 0.2) : 0;
      shapes.add(
        MetaphorShape(
          shape: metaphorShapeBar,
          x: upright ? shift : 0,
          y: upright ? 0 : shift,
          sx: reach * 9,
          sy: half,
          tone: tone,
          rot: (upright ? math.pi / 2 : 0) + tilt,
        ),
      );
    } else if (layer == 'grid') {
      final double pitch = math.max(1, reach / 3.5);
      final int columns = math.min(7, ((halfW + pitch * 2) / pitch).ceil());
      final int rows = math.min(5, ((halfH + pitch * 2) / pitch).ceil());
      for (int column = -columns; column <= columns; column++) {
        shapes.add(
          MetaphorShape(
            shape: metaphorShapeBar,
            x: column * pitch,
            sx: rows * pitch,
            sy: 0.022,
            rot: math.pi / 2,
            tone: column == 0 ? 0.8 : 0.4,
          ),
        );
      }
      for (int row = -rows; row <= rows; row++) {
        shapes.add(
          MetaphorShape(
            shape: metaphorShapeBar,
            y: row * pitch,
            sx: columns * pitch,
            sy: 0.022,
            tone: row == 0 ? 0.8 : 0.4,
          ),
        );
      }
    } else if (layer == 'arcs') {
      final double cx = (rng() < 0.5 ? -1 : 1) * (halfW + reach * 0.6);
      final double cy = (rng() < 0.5 ? -1 : 1) * (halfH + reach * 0.4);
      for (int ring = 1; ring <= 5; ring++) {
        shapes.add(
          MetaphorShape(
            shape: metaphorShapeArc,
            x: cx,
            y: cy,
            sx: (reach * 0.7 * ring) / metaphorArcAt,
            sy: 2.5,
            param: 1,
            tone: 0.55,
          ),
        );
      }
    } else if (layer == 'dots') {
      final double pitch = math.max(0.9, reach / 3);
      final double skew = rng() < 0.5 ? 0.5 : 0;
      for (int row = -2; row <= 2; row++) {
        for (int column = -3; column <= 3; column++) {
          shapes.add(
            MetaphorShape(
              shape: metaphorShapeBlob,
              x: (column + (row.isEven ? 0 : skew)) * pitch,
              y: row * pitch * 0.87,
              sx: 0.2,
              sy: 0.2,
              tone: 1,
            ),
          );
        }
      }
    }
  }
  if (shapes.length > _backdropLimit) {
    shapes.removeRange(_backdropLimit, shapes.length);
  }
  if (interlude) return MetaphorFigures(shapes, const <MetaphorNote>[]);

  // 版面零件：贴着字块，画成墨线，开头就在
  final _Pen pen = _Pen(0, 0, 1, 0, 0);
  final String furniture = _choose(rng, <String>[
    'rules',
    'rules',
    'crop',
    'margin',
    'none',
  ]);
  final double left = -halfW - 0.1;
  final double right = halfW + 0.1;
  final double size = math.min(0.34, math.max(0.2, reach * 0.07));
  if (furniture == 'rules') {
    pen
      ..line(left, halfH + 0.3, right, halfH + 0.3, 0, 2.6)
      ..line(left, -halfH - 0.3, right, -halfH - 0.3)
      ..note(_pad2(index.toDouble()), left, halfH + 0.3 + size * 0.95, size)
      ..note(_timecode(time), right, -halfH - 0.3 - size * 0.95, size, 1);
  } else if (furniture == 'crop') {
    for (final int sx in const <int>[-1, 1]) {
      for (final int sy in const <int>[-1, 1]) {
        final double x = sx * (halfW + 0.3);
        final double y = sy * (halfH + 0.3);
        pen
          ..line(x + sx * 0.12, y, x + sx * 0.5, y)
          ..line(x, y + sy * 0.12, x, y + sy * 0.5);
      }
    }
    pen.note(
      '${_pad2(index.toDouble())} — ${_timecode(time)}',
      0,
      -halfH - 0.3 - size * 1.1,
      size,
      0.5,
    );
  } else if (furniture == 'margin') {
    final double x = left - 0.3;
    pen.line(x, -halfH, x, halfH, 0, 1.8);
    for (int tick = 0; tick <= 4; tick++) {
      final double y = -halfH + (tick * halfH) / 2;
      pen.line(x, y, x + (tick.isEven ? 0.22 : 0.12), y);
    }
    pen.note(
      '${_pad2(index.toDouble())} / ${_timecode(time)}',
      x - size * 0.9,
      halfH,
      size,
      1,
      math.pi / 2,
    );
  }
  return MetaphorFigures(<MetaphorShape>[...shapes, ...pen.shapes], pen.notes);
}

/// 注记排成一个个字：按量出来的字宽沿注记的方向排开。
List<MetaphorNoteGlyph> layoutMetaphorNotes(
  List<MetaphorNote> notes,
  MetaphorMeasure measure,
) {
  final List<MetaphorNoteGlyph> glyphs = <MetaphorNoteGlyph>[];
  for (final MetaphorNote note in notes) {
    final List<String> chars = note.text.characters.toList();
    final List<double> advances = <double>[
      for (final String c in chars) measure(c) * note.size,
    ];
    final double total = advances.fold(0, (double s, double a) => s + a);
    final double cos = math.cos(note.rot);
    final double sin = math.sin(note.rot);
    double pen = -total * note.align;
    for (int index = 0; index < chars.length; index++) {
      final double along = pen + advances[index] / 2;
      pen += advances[index];
      if (chars[index].trim().isEmpty) continue;
      glyphs.add(
        MetaphorNoteGlyph(
          char: chars[index],
          x: note.x + along * cos,
          y: note.y + along * sin,
          size: note.size,
          rot: note.rot,
          born: note.born,
        ),
      );
    }
  }
  return glyphs;
}
