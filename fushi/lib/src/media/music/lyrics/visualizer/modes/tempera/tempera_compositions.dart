/// 凝彩构图注册表 + 每个分镜共享的两层装饰（folia `temperaCompositions.ts`），以及分割 / 色带 /
/// 框窗 / 海报 / 稀疏 / 遮幅 / 物语过场卡七族构图（folia `compositions/*`，逐项照搬）。
/// 圆滑 / 镂空 / 仪表 / 通道 / 巨构 / 地形六族在 `tempera_compositions_cut.dart`。
library;

import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/modes/tempera/tempera_compositions_cut.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/tempera/tempera_geometry.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/tempera/tempera_profiles.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/tempera/tempera_random.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/tempera/tempera_shapes.dart';

/// 一种构图的绘制函数。
typedef TemperaCompositionDrawer = void Function(TemperaComposer c);

TemperaBlockOptions _o({
  double alpha = 1,
  double enterDX = 0,
  double enterDY = 0,
  double delay = 0,
  double span = 0.45,
  bool drift = false,
  bool grow = false,
}) => TemperaBlockOptions(
  alpha: alpha,
  enterDX: enterDX,
  enterDY: enterDY,
  delay: delay,
  span: span,
  drift: drift,
  grow: grow,
);

List<double> _full(TemperaComposer c) => rectPolygon(
  -c.bleed,
  -c.bleed,
  c.width + c.bleed * 2,
  c.height + c.bleed * 2,
);

void _ground(TemperaComposer c, Color tone, [double alpha = 0.9]) =>
    c.add(drawPolygonFill(_full(c), tone, alpha, c.gradient), _o(span: 0.5));

// ---------------------------------------------------------------------------
// 分割族
// ---------------------------------------------------------------------------

typedef _Panel = ({List<double> polygon, Color tone, double dx, double dy});

void _addPanels(TemperaComposer c, List<_Panel> panels, int hatchIndex) {
  final TemperaHatchSpec hatch = temperaHatchSpec(c.seed, 5);
  for (int i = 0; i < panels.length; i++) {
    final _Panel p = panels[i];
    c.add(
      drawPolygonFill(p.polygon, p.tone, 0.96, c.gradient),
      _o(delay: i * 0.05, span: 0.5, enterDX: p.dx, enterDY: p.dy),
    );
    if (i != hatchIndex) continue;
    c.add(
      drawHatchFill(p.polygon, hatch, c.palette.tone4, 0.5),
      _o(delay: i * 0.05 + 0.06, span: 0.5, grow: true),
    );
  }
}

void _addSeam(TemperaComposer c, List<double> polygon, double delay) => c.add(
  drawPolygonFill(polygon, c.palette.ink, 0.85, c.gradient),
  _o(delay: delay, span: 0.5),
);

void _duoSplit(TemperaComposer c) {
  final double w = c.width, h = c.height, b = c.bleed;
  final bool horizontal = temperaHash01(c.seed, 1, 3) > 0.5;
  _addPanels(
    c,
    horizontal
        ? <_Panel>[
            (
              polygon: rectPolygon(-b, -b, w + b * 2, h * 0.52 + b),
              tone: c.palette.tone1,
              dx: 0,
              dy: -h * 0.55,
            ),
            (
              polygon: rectPolygon(-b, h * 0.52, w + b * 2, h * 0.48 + b),
              tone: c.palette.tone3,
              dx: 0,
              dy: h * 0.55,
            ),
          ]
        : <_Panel>[
            (
              polygon: rectPolygon(-b, -b, w * 0.5 + b, h + b * 2),
              tone: c.palette.tone1,
              dx: -w * 0.5,
              dy: 0,
            ),
            (
              polygon: rectPolygon(w * 0.5, -b, w * 0.5 + b, h + b * 2),
              tone: c.palette.tone3,
              dx: w * 0.5,
              dy: 0,
            ),
          ],
    0,
  );
  _addSeam(
    c,
    horizontal
        ? rectPolygon(-b, h * 0.52 - 1.5, w + b * 2, 3)
        : rectPolygon(w * 0.5 - 1.5, -b, 3, h + b * 2),
    0.16,
  );
}

void _quadSplit(TemperaComposer c) {
  final double w = c.width, h = c.height, b = c.bleed;
  final double sx = w * (0.42 + temperaHash01(c.seed, 2, 7) * 0.16);
  final double sy = h * (0.42 + temperaHash01(c.seed, 3, 11) * 0.16);
  _addPanels(c, <_Panel>[
    (
      polygon: rectPolygon(-b, -b, sx + b, sy + b),
      tone: c.palette.tone1,
      dx: -w * 0.3,
      dy: -h * 0.3,
    ),
    (
      polygon: rectPolygon(sx, -b, w - sx + b, sy + b),
      tone: c.palette.tone4,
      dx: w * 0.3,
      dy: -h * 0.3,
    ),
    (
      polygon: rectPolygon(-b, sy, sx + b, h - sy + b),
      tone: c.palette.tone3,
      dx: -w * 0.3,
      dy: h * 0.3,
    ),
    (
      polygon: rectPolygon(sx, sy, w - sx + b, h - sy + b),
      tone: c.palette.tone2,
      dx: w * 0.3,
      dy: h * 0.3,
    ),
  ], 3);
  _addSeam(c, rectPolygon(sx - 1.5, -b, 3, h + b * 2), 0.2);
  _addSeam(c, rectPolygon(-b, sy - 1.5, w + b * 2, 3), 0.24);
}

void _triColumn(TemperaComposer c) {
  final double w = c.width, h = c.height, b = c.bleed;
  final double edge = w * (0.26 + temperaHash01(c.seed, 4, 13) * 0.06);
  _addPanels(c, <_Panel>[
    (
      polygon: rectPolygon(-b, -b, edge + b, h + b * 2),
      tone: c.palette.tone1,
      dx: -w * 0.25,
      dy: 0,
    ),
    (
      polygon: rectPolygon(edge, -b, w - edge * 2, h + b * 2),
      tone: c.palette.tone4,
      dx: 0,
      dy: -h * 0.3,
    ),
    (
      polygon: rectPolygon(w - edge, -b, edge + b, h + b * 2),
      tone: c.palette.tone1,
      dx: w * 0.25,
      dy: 0,
    ),
  ], 0);
}

void _thirdsStack(TemperaComposer c) {
  final double w = c.width, h = c.height, b = c.bleed;
  final double band = h * 0.34;
  _addPanels(c, <_Panel>[
    (
      polygon: rectPolygon(-b, -b, w + b * 2, band + b),
      tone: c.palette.tone2,
      dx: -w * 0.2,
      dy: 0,
    ),
    (
      polygon: rectPolygon(-b, band, w + b * 2, band),
      tone: c.palette.tone4,
      dx: w * 0.2,
      dy: 0,
    ),
    (
      polygon: rectPolygon(-b, band * 2, w + b * 2, h - band * 2 + b),
      tone: c.palette.tone1,
      dx: -w * 0.2,
      dy: 0,
    ),
  ], 0);
}

void _checkerQuad(TemperaComposer c) {
  final double w = c.width, h = c.height, b = c.bleed;
  final double sx = w * 0.5, sy = h * 0.5;
  _addPanels(c, <_Panel>[
    (
      polygon: rectPolygon(-b, -b, sx + b, sy + b),
      tone: c.palette.tone4,
      dx: 0,
      dy: -h * 0.35,
    ),
    (
      polygon: rectPolygon(sx, -b, w - sx + b, sy + b),
      tone: c.palette.tone1,
      dx: 0,
      dy: -h * 0.35,
    ),
    (
      polygon: rectPolygon(-b, sy, sx + b, h - sy + b),
      tone: c.palette.tone1,
      dx: 0,
      dy: h * 0.35,
    ),
    (
      polygon: rectPolygon(sx, sy, w - sx + b, h - sy + b),
      tone: c.palette.tone4,
      dx: 0,
      dy: h * 0.35,
    ),
  ], 1);
}

void _cornerWedge(TemperaComposer c) {
  final double w = c.width, h = c.height, b = c.bleed;
  final bool fromLeft = temperaHash01(c.seed, 5, 17) > 0.5;
  final double apexX = fromLeft ? w * 0.78 : w * 0.22;
  _addPanels(c, <_Panel>[
    (
      polygon: rectPolygon(-b, -b, w + b * 2, h + b * 2),
      tone: c.palette.tone1,
      dx: 0,
      dy: 0,
    ),
    (
      polygon: fromLeft
          ? <double>[-b, -b, apexX, -b, -b, h + b]
          : <double>[w + b, -b, apexX, -b, w + b, h + b],
      tone: c.palette.tone4,
      dx: fromLeft ? -w * 0.4 : w * 0.4,
      dy: 0,
    ),
  ], 1);
}

void _diagonalHalves(TemperaComposer c) {
  final double w = c.width, h = c.height, b = c.bleed;
  final double lean = h * (0.2 + temperaHash01(c.seed, 6, 19) * 0.3);
  _addPanels(c, <_Panel>[
    (
      polygon: <double>[-b, -b, w + b, -b, w + b, lean, -b, h - lean],
      tone: c.palette.tone2,
      dx: 0,
      dy: -h * 0.4,
    ),
    (
      polygon: <double>[-b, h - lean, w + b, lean, w + b, h + b, -b, h + b],
      tone: c.palette.tone4,
      dx: 0,
      dy: h * 0.4,
    ),
  ], 1);
}

void _crossAxis(TemperaComposer c) {
  final double w = c.width, h = c.height, b = c.bleed;
  final double barX = w * 0.11, barY = h * 0.13;
  _ground(c, c.palette.tone1);
  c.add(
    drawPolygonFill(
      rectPolygon((w - barX) / 2, -b, barX, h + b * 2),
      c.palette.tone4,
      0.95,
    ),
    _o(delay: 0.06, span: 0.5, enterDY: -h * 0.5),
  );
  c.add(
    drawPolygonFill(
      rectPolygon(-b, (h - barY) / 2, w + b * 2, barY),
      c.palette.tone3,
      0.95,
    ),
    _o(delay: 0.12, span: 0.5, enterDX: w * 0.5),
  );
}

void _offsetHalves(TemperaComposer c) {
  final double w = c.width, h = c.height, b = c.bleed;
  final double step = h * (0.06 + temperaHash01(c.seed, 7, 23) * 0.06);
  final double seam = w * 0.48;
  _addPanels(c, <_Panel>[
    (
      polygon: rectPolygon(-b, -b, seam + b, h * 0.5 + step + b),
      tone: c.palette.tone1,
      dx: -w * 0.3,
      dy: 0,
    ),
    (
      polygon: rectPolygon(seam, -b, w - seam + b, h * 0.5 - step + b),
      tone: c.palette.tone3,
      dx: w * 0.3,
      dy: 0,
    ),
    (
      polygon: rectPolygon(-b, h * 0.5 + step, seam + b, h * 0.5 - step + b),
      tone: c.palette.tone4,
      dx: -w * 0.2,
      dy: 0,
    ),
    (
      polygon: rectPolygon(
        seam,
        h * 0.5 - step,
        w - seam + b,
        h * 0.5 + step + b,
      ),
      tone: c.palette.tone2,
      dx: w * 0.2,
      dy: 0,
    ),
  ], 2);
}

void _stairBlocks(TemperaComposer c) {
  final double w = c.width, h = c.height;
  final List<Color> tones = <Color>[
    c.palette.tone1,
    c.palette.tone2,
    c.palette.tone3,
    c.palette.tone4,
  ];
  _ground(c, c.palette.tone1);
  for (int i = 0; i < tones.length; i++) {
    c.add(
      drawPolygonFill(
        rectPolygon(
          w * (0.06 + i * 0.2),
          h * (0.1 + i * 0.16),
          w * 0.3,
          h * 0.34,
        ),
        tones[i],
        0.94,
        c.gradient,
      ),
      _o(delay: i * 0.06, span: 0.5, enterDX: -w * 0.2, enterDY: h * 0.12),
    );
  }
}

void _pillarGap(TemperaComposer c) {
  final double w = c.width, h = c.height, b = c.bleed;
  final double gap = w * (0.26 + temperaHash01(c.seed, 8, 29) * 0.08);
  final double side = (w - gap) / 2;
  _addPanels(c, <_Panel>[
    (
      polygon: rectPolygon(-b, -b, side + b, h + b * 2),
      tone: c.palette.tone4,
      dx: -w * 0.3,
      dy: 0,
    ),
    (
      polygon: rectPolygon(w - side, -b, side + b, h + b * 2),
      tone: c.palette.tone4,
      dx: w * 0.3,
      dy: 0,
    ),
  ], 1);
}

void _cornerQuad(TemperaComposer c) {
  final double w = c.width, h = c.height, b = c.bleed;
  final double sx = w * (0.6 + temperaHash01(c.seed, 9, 31) * 0.12);
  final double sy = h * (0.62 + temperaHash01(c.seed, 10, 37) * 0.1);
  _addPanels(c, <_Panel>[
    (
      polygon: rectPolygon(-b, -b, sx + b, sy + b),
      tone: c.palette.tone2,
      dx: 0,
      dy: -h * 0.25,
    ),
    (
      polygon: rectPolygon(sx, -b, w - sx + b, sy + b),
      tone: c.palette.tone4,
      dx: w * 0.25,
      dy: 0,
    ),
    (
      polygon: rectPolygon(-b, sy, sx + b, h - sy + b),
      tone: c.palette.tone1,
      dx: -w * 0.25,
      dy: 0,
    ),
    (
      polygon: rectPolygon(sx, sy, w - sx + b, h - sy + b),
      tone: c.palette.tone3,
      dx: 0,
      dy: h * 0.25,
    ),
  ], 0);
}

void _sliverStack(TemperaComposer c) {
  final double w = c.width, h = c.height, b = c.bleed;
  final bool fromLeft = temperaHash01(c.seed, 11, 41) > 0.5;
  final double slab = w * 0.46;
  final double left = fromLeft ? -b : w - slab;
  _ground(c, c.palette.tone1);
  const int count = 9;
  final double sliver = (h + b * 2) / count;
  for (int i = 0; i < count; i += 2) {
    c.add(
      drawPolygonFill(
        rectPolygon(left, -b + sliver * i, slab + b, sliver),
        c.palette.tone4,
        0.92,
        c.gradient,
      ),
      _o(delay: i * 0.02, span: 0.5, enterDX: (fromLeft ? -1 : 1) * w * 0.2),
    );
  }
}

// ---------------------------------------------------------------------------
// 色带族
// ---------------------------------------------------------------------------

void _bandStrip(TemperaComposer c) {
  final double w = c.width, h = c.height, b = c.bleed;
  final double bandY = h * 0.37, bandH = h * 0.3;
  c.add(
    drawPolygonFill(
      rectPolygon(-b, bandY, w + b * 2, bandH),
      c.palette.tone3,
      0.96,
      c.gradient,
    ),
    _o(span: 0.55, enterDX: -w * 0.5),
  );
  c.add(
    drawLines(
      <TemperaLine>[
        TemperaLine(-b, bandY - 10, w + b, bandY - 22),
        TemperaLine(-b, bandY + bandH + 22, w + b, bandY + bandH + 10),
      ],
      c.palette.tone4,
      1.4,
      0.75,
    ),
    _o(delay: 0.12, enterDX: w * 0.25),
  );
  if (!c.showDecor) return;
  c.add(
    drawCrossMarks(
      temperaCrossRow(c.seed, 17, w * 0.06, bandY - h * 0.16, 4, w * 0.055, 9),
      c.palette.ink,
      2,
      0.8,
    ),
    _o(delay: 0.2, span: 0.5),
  );
  c.add(
    drawSquareMarks(
      temperaDotRow(
        c.seed,
        19,
        w * 0.94,
        bandY + bandH + h * 0.06,
        3,
        h * 0.05,
        6,
      ),
      c.palette.ink,
      0.75,
    ),
    _o(delay: 0.26, drift: true),
  );
}

void _horizonBand(TemperaComposer c) {
  final double w = c.width, h = c.height, b = c.bleed;
  final double waterline = h * (0.5 + temperaHash01(c.seed, 1, 23) * 0.12);
  c.add(
    drawPolygonFill(
      rectPolygon(-b, -b, w + b * 2, waterline + b),
      c.palette.tone1,
      0.94,
      c.gradient,
    ),
    _o(span: 0.55, enterDY: -h * 0.3),
  );
  final List<double> water = rectPolygon(
    -b,
    waterline,
    w + b * 2,
    h - waterline + b,
  );
  c.add(
    drawPolygonFill(water, c.palette.tone3, 0.95, c.gradient),
    _o(delay: 0.05, span: 0.55, enterDY: h * 0.3),
  );
  c.add(
    drawHatchFill(
      water,
      temperaHatchSpec(c.seed, 29).copyWith(angle: 0),
      c.palette.tone4,
      0.55,
    ),
    _o(delay: 0.1, span: 0.55, grow: true),
  );
  c.add(
    drawPolyline(
      temperaWavyPath(c.seed, 31, -b, w + b, waterline, h * 0.012, 30),
      c.palette.ink,
      2.2,
      0.85,
    ),
    _o(delay: 0.16, span: 0.5),
  );
}

void _deepDive(TemperaComposer c) {
  final double w = c.width, h = c.height, b = c.bleed;
  final List<Color> tones = <Color>[
    c.palette.tone1,
    c.palette.tone2,
    c.palette.tone3,
    c.palette.tone4,
  ];
  final double bandH = (h + b * 2) / tones.length;
  for (int i = 0; i < tones.length; i++) {
    final double top = -b + bandH * i;
    c.add(
      drawPolygonFill(
        rectPolygon(-b, top, w + b * 2, bandH + 1),
        tones[i],
        0.95,
        c.gradient,
      ),
      _o(delay: i * 0.06, span: 0.55, enterDY: h * 0.3),
    );
    if (i == 0) continue;
    c.add(
      drawPolyline(
        temperaWavyPath(c.seed, 37 + i, -b, w + b, top, h * 0.008, 24),
        c.palette.paper,
        1.6,
        0.5,
      ),
      _o(delay: i * 0.06 + 0.05, span: 0.5),
    );
  }
}

void _toneRamp(TemperaComposer c) {
  final double w = c.width, h = c.height, b = c.bleed;
  final TemperaHatchSpec spec = temperaHatchSpec(c.seed, 41);
  _ground(c, c.palette.tone1, 0.92);
  const int steps = 4;
  final double colW = (w + b * 2) / steps;
  for (int i = 0; i < steps; i++) {
    c.add(
      drawHatchFill(
        rectPolygon(-b + colW * i, -b, colW, h + b * 2),
        spec.copyWith(spacing: spec.spacing * (1.6 - i * 0.32)),
        c.palette.tone4,
        0.6,
      ),
      _o(delay: i * 0.06, span: 0.55, grow: true),
    );
  }
}

void _doubleBand(TemperaComposer c) {
  final double w = c.width, h = c.height, b = c.bleed;
  final double slot = h * (0.2 + temperaHash01(c.seed, 51, 43) * 0.08);
  final double rail = h * 0.3;
  final double top = (h - slot) / 2 - rail;
  c.add(
    drawPolygonFill(
      rectPolygon(-b, top, w + b * 2, rail),
      c.palette.tone3,
      0.95,
      c.gradient,
    ),
    _o(span: 0.55, enterDX: -w * 0.4),
  );
  c.add(
    drawPolygonFill(
      rectPolygon(-b, top + rail + slot, w + b * 2, rail),
      c.palette.tone4,
      0.95,
      c.gradient,
    ),
    _o(delay: 0.07, span: 0.55, enterDX: w * 0.4),
  );
}

void _tiltBand(TemperaComposer c) {
  final double w = c.width, h = c.height, b = c.bleed;
  final double lean = h * (0.14 + temperaHash01(c.seed, 53, 47) * 0.14);
  final double half = h * 0.17;
  final List<double> band = <double>[
    -b,
    h / 2 + lean - half,
    w + b,
    h / 2 - lean - half,
    w + b,
    h / 2 - lean + half,
    -b,
    h / 2 + lean + half,
  ];
  _ground(c, c.palette.tone1);
  c.add(
    drawPolygonFill(band, c.palette.tone4, 0.95, c.gradient),
    _o(delay: 0.06, span: 0.55, enterDX: -w * 0.35),
  );
  c.add(
    drawHatchFill(
      band,
      temperaHatchSpec(c.seed, 59).copyWith(angle: math.pi / 2),
      c.palette.paper,
      0.3,
    ),
    _o(delay: 0.12, span: 0.55, grow: true),
  );
}

void _edgeRails(TemperaComposer c) {
  final double w = c.width, h = c.height, b = c.bleed;
  final double rail = h * (0.16 + temperaHash01(c.seed, 61, 53) * 0.06);
  c.add(
    drawPolygonFill(
      rectPolygon(-b, -b, w + b * 2, rail + b),
      c.palette.tone3,
      0.94,
      c.gradient,
    ),
    _o(span: 0.55, enterDY: -h * 0.2),
  );
  c.add(
    drawPolygonFill(
      rectPolygon(-b, h - rail, w + b * 2, rail + b),
      c.palette.tone3,
      0.94,
      c.gradient,
    ),
    _o(delay: 0.06, span: 0.55, enterDY: h * 0.2),
  );
  if (!c.showDecor) return;
  c.add(
    drawLines(
      <TemperaLine>[
        TemperaLine(-b, rail + 8, w + b, rail + 8),
        TemperaLine(-b, h - rail - 8, w + b, h - rail - 8),
      ],
      c.palette.tone4,
      1.2,
      0.6,
    ),
    _o(delay: 0.16, span: 0.5, enterDX: w * 0.2),
  );
}

void _gradientWall(TemperaComposer c) {
  final double w = c.width, h = c.height, b = c.bleed;
  final TemperaHatchSpec spec = temperaHatchSpec(c.seed, 67);
  final bool downward = temperaHash01(c.seed, 71, 59) > 0.5;
  _ground(c, c.palette.tone2, 0.94);
  const int steps = 5;
  final double bandH = h / steps;
  for (int i = 0; i < steps; i++) {
    final int rank = downward ? i : steps - 1 - i;
    final double top = bandH * i - (i == 0 ? b : 0);
    final double bottom = bandH * (i + 1) + (i == steps - 1 ? b : 0);
    c.add(
      drawHatchFill(
        rectPolygon(-b, top, w + b * 2, bottom - top),
        spec.copyWith(spacing: spec.spacing * (1.9 - rank * 0.34)),
        c.palette.tone4,
        0.55,
      ),
      _o(delay: i * 0.05, span: 0.55, grow: true),
    );
  }
}

void _terrace(TemperaComposer c) {
  final double w = c.width, h = c.height, b = c.bleed;
  final List<Color> tones = <Color>[
    c.palette.tone1,
    c.palette.tone2,
    c.palette.tone3,
    c.palette.tone4,
  ];
  final double bandH = h / tones.length;
  _ground(c, c.palette.tone1);
  for (int i = 0; i < tones.length; i++) {
    final double left = w * i * 0.14 - b;
    final double top = bandH * i - (i == 0 ? b : 0);
    final double bottom = bandH * (i + 1) + (i == tones.length - 1 ? b : 1);
    c.add(
      drawPolygonFill(
        rectPolygon(left, top, w + b * 2 - left - b, bottom - top),
        tones[i],
        0.94,
        c.gradient,
      ),
      _o(delay: i * 0.06, span: 0.55, enterDX: -w * 0.25),
    );
  }
}

// ---------------------------------------------------------------------------
// 框窗族
// ---------------------------------------------------------------------------

void _frameWindow(TemperaComposer c) {
  final double w = c.width, h = c.height;
  final double cx = w / 2, cy = h / 2, rx = w * 0.42, ry = h * 0.44;
  c.add(
    drawHatchFill(
      diamondPolygon(cx, cy, rx * 0.78, ry * 0.78),
      temperaHatchSpec(c.seed, 23, 1.4),
      c.palette.tone2,
      0.45,
    ),
    _o(grow: true, span: 0.6),
  );
  c.add(
    drawConcentricDiamonds(cx, cy, rx, ry, 3, c.palette.ink, 0.9),
    _o(delay: 0.08, enterDY: h * 0.06, span: 0.55),
  );
  if (!c.showDecor) return;
  c.add(
    drawCrossMarks(
      temperaCrossRow(c.seed, 29, w * 0.08, h * 0.14, 3, w * 0.045, 8),
      c.palette.tone4,
      1.8,
      0.85,
    ),
    _o(delay: 0.22),
  );
  c.add(
    drawSquareMarks(
      temperaDotRow(c.seed, 37, w * 0.92, h * 0.62, 4, h * 0.06, 7),
      c.palette.tone4,
      0.8,
    ),
    _o(delay: 0.28),
  );
}

void _doubleFrame(TemperaComposer c) {
  final double w = c.width, h = c.height;
  final double offset = w * 0.05;
  final List<double> box = rectPolygon(w * 0.16, h * 0.2, w * 0.68, h * 0.6);
  final List<double> shifted = rectPolygon(
    w * 0.16 + offset,
    h * 0.2 + offset * 0.6,
    w * 0.68,
    h * 0.6,
  );
  _ground(c, c.palette.tone1);
  c.add(
    drawPolygonFill(shifted, c.palette.tone3, 0.8, c.gradient),
    _o(delay: 0.06, span: 0.55, enterDX: offset * 3),
  );
  c.add(
    drawHatchFill(shifted, temperaHatchSpec(c.seed, 43), c.palette.tone4, 0.4),
    _o(delay: 0.1, span: 0.55, grow: true),
  );
  c.add(
    drawPolygonOutline(box, c.palette.ink, 3.5, 0.9),
    _o(delay: 0.14, span: 0.5, enterDY: -h * 0.08),
  );
}

void _circleWindow(TemperaComposer c) {
  final double w = c.width, h = c.height;
  final double radius = math.min(w, h) * 0.34;
  final List<double> circle = circlePolygon(w / 2, h / 2, radius);
  _ground(c, c.palette.tone3, 0.92);
  c.add(
    drawHatchFill(_full(c), temperaHatchSpec(c.seed, 47), c.palette.tone4, 0.4),
    _o(delay: 0.04, span: 0.6, grow: true),
  );
  c.add(
    drawPolygonFill(circle, c.palette.paper, 0.95, c.gradient),
    _o(delay: 0.08, span: 0.55),
  );
  c.add(
    drawPolygonOutline(circle, c.palette.ink, 3, 0.9),
    _o(delay: 0.14, span: 0.5),
  );
  if (!c.showDecor) return;
  c.add(
    drawPolygonOutline(
      circlePolygon(w / 2, h / 2, radius * 1.12),
      c.palette.ink,
      1.2,
      0.55,
    ),
    _o(delay: 0.2, drift: true),
  );
}

void _ladderFrame(TemperaComposer c) {
  final double w = c.width, h = c.height, b = c.bleed;
  final double left = w * 0.14;
  _ground(c, c.palette.tone1);
  for (int i = 0; i < 5; i++) {
    final double y = h * (0.18 + i * 0.14);
    final double run = w * (0.06 + i * 0.03);
    c.add(
      drawLines(
        <TemperaLine>[
          TemperaLine(left, y, left + run, y),
          TemperaLine(left, y, left, y + h * 0.14),
        ],
        c.palette.tone4,
        i.isEven ? 3 : 1.4,
        0.85,
      ),
      _o(delay: i * 0.05, span: 0.5, enterDX: -w * 0.1),
    );
  }
  c.add(
    drawLines(
      <TemperaLine>[TemperaLine(w * 0.9, -b, w * 0.9, h + b)],
      c.palette.tone4,
      1.4,
      0.6,
    ),
    _o(delay: 0.28, span: 0.5, enterDY: h * 0.2),
  );
}

void _cornerBrackets(TemperaComposer c) {
  final double w = c.width, h = c.height;
  final double inset = math.min(w, h) * 0.12;
  final double arm = math.min(w, h) * 0.16;
  _ground(c, c.palette.tone2);
  final List<(double, double, double, double)> corners =
      <(double, double, double, double)>[
        (inset, inset, 1, 1),
        (w - inset, inset, -1, 1),
        (inset, h - inset, 1, -1),
        (w - inset, h - inset, -1, -1),
      ];
  for (int i = 0; i < corners.length; i++) {
    final (double x, double y, double sx, double sy) = corners[i];
    c.add(
      drawLines(
        <TemperaLine>[
          TemperaLine(x, y, x + sx * arm, y),
          TemperaLine(x, y, x, y + sy * arm),
        ],
        c.palette.ink,
        3.5,
        0.9,
      ),
      _o(
        delay: i * 0.05,
        span: 0.5,
        enterDX: sx * w * 0.06,
        enterDY: sy * h * 0.06,
      ),
    );
  }
  if (!c.showDecor) return;
  final bool dotted = temperaHash01(c.seed, 2, 53) > 0.5;
  c.add(
    dotted
        ? drawSquareMarks(
            temperaDotRow(c.seed, 59, w * 0.5, h * 0.16, 3, w * 0.03, 6, 0),
            c.palette.tone4,
            0.8,
          )
        : drawCrossMarks(
            temperaCrossRow(c.seed, 61, w * 0.44, h * 0.84, 3, w * 0.04, 7),
            c.palette.tone4,
            1.8,
            0.8,
          ),
    _o(delay: 0.24, drift: true),
  );
}

void _insetBox(TemperaComposer c) {
  final double w = c.width, h = c.height;
  final List<double> box = rectPolygon(w * 0.14, h * 0.2, w * 0.72, h * 0.6);
  _ground(c, c.palette.tone1);
  c.add(
    drawPolygonFill(box, c.palette.tone3, 0.55, c.gradient),
    _o(delay: 0.05, span: 0.55, enterDY: h * 0.06),
  );
  c.add(
    drawPolygonOutline(box, c.palette.ink, 2.4, 0.85),
    _o(delay: 0.1, span: 0.5),
  );
}

void _bracketPair(TemperaComposer c) {
  final double w = c.width, h = c.height;
  final double inset = w * 0.16,
      arm = w * 0.09,
      top = h * 0.26,
      bottom = h * 0.74;
  _ground(c, c.palette.tone2);
  const List<double> sides = <double>[1, -1];
  for (int i = 0; i < 2; i++) {
    final double side = sides[i];
    final double x = side == 1 ? inset : w - inset;
    c.add(
      drawLines(
        <TemperaLine>[
          TemperaLine(x, top, x + side * arm, top),
          TemperaLine(x, top, x, bottom),
          TemperaLine(x, bottom, x + side * arm, bottom),
        ],
        c.palette.ink,
        4,
        0.9,
      ),
      _o(delay: i * 0.07, span: 0.5, enterDX: side * w * 0.08),
    );
  }
}

void _archWindow(TemperaComposer c) {
  final double w = c.width, h = c.height;
  final double radius = w * 0.24, cx = w / 2, shoulder = h * 0.42;
  _ground(c, c.palette.tone3, 0.92);
  final List<double> arch = circlePolygon(cx, shoulder, radius, 48);
  final List<double> body = rectPolygon(
    cx - radius,
    shoulder,
    radius * 2,
    h * 0.4,
  );
  c.add(
    drawPolygonFill(arch, c.palette.paper, 0.95, c.gradient),
    _o(delay: 0.05, span: 0.55, enterDY: -h * 0.08),
  );
  c.add(
    drawPolygonFill(body, c.palette.paper, 0.95, c.gradient),
    _o(delay: 0.05, span: 0.55, enterDY: h * 0.08),
  );
  c.add(
    drawPolygonOutline(arch, c.palette.ink, 2.4, 0.8),
    _o(delay: 0.12, span: 0.5),
  );
  c.add(
    drawPolygonOutline(body, c.palette.ink, 2.4, 0.8),
    _o(delay: 0.12, span: 0.5),
  );
}

void _gridCells(TemperaComposer c) {
  final double w = c.width, h = c.height;
  _ground(c, c.palette.tone1);
  final double left = w * 0.12, top = h * 0.18;
  final double cw = (w * 0.76) / 3, ch = (h * 0.64) / 3;
  for (int row = 0; row < 3; row++) {
    for (int col = 0; col < 3; col++) {
      final List<double> cell = rectPolygon(
        left + cw * col,
        top + ch * row,
        cw,
        ch,
      );
      final int index = row * 3 + col;
      if (row == 1 && col == 1) {
        c.add(
          drawPolygonFill(cell, c.palette.tone4, 0.75, c.gradient),
          _o(delay: index * 0.03, span: 0.5),
        );
      }
      c.add(
        drawPolygonOutline(cell, c.palette.tone4, 1.2, 0.6),
        _o(delay: index * 0.03, span: 0.5),
      );
    }
  }
}

void _keyhole(TemperaComposer c) {
  final double w = c.width, h = c.height;
  final double radius = math.min(w, h) * 0.19, cx = w / 2, cy = h * 0.36;
  _ground(c, c.palette.tone4, 0.94);
  final List<double> head = circlePolygon(cx, cy, radius, 48);
  final List<double> shaft = rectPolygon(
    cx - radius * 0.55,
    cy,
    radius * 1.1,
    h * 0.46,
  );
  c.add(
    drawPolygonFill(head, c.palette.paper, 0.96, c.gradient),
    _o(delay: 0.05, span: 0.55),
  );
  c.add(
    drawPolygonFill(shaft, c.palette.paper, 0.96, c.gradient),
    _o(delay: 0.08, span: 0.55, enterDY: h * 0.1),
  );
  c.add(
    drawPolygonOutline(head, c.palette.ink, 2, 0.7),
    _o(delay: 0.14, span: 0.5),
  );
}

// ---------------------------------------------------------------------------
// 海报族
// ---------------------------------------------------------------------------

void _posterPanel(TemperaComposer c) {
  final double w = c.width, h = c.height;
  final TemperaGroup poster = c.createGroup(-0.06, w / 2, h / 2);
  final List<double> solid = diamondPolygon(-w * 0.12, 0, w * 0.42, h * 0.66);
  final List<double> hatched = diamondPolygon(
    w * 0.2,
    -h * 0.06,
    w * 0.3,
    h * 0.48,
  );
  c.add(
    drawPolygonFill(solid, c.palette.ink, 0.92, c.gradient),
    _o(enterDX: -w * 0.6, span: 0.55),
    poster,
  );
  c.add(
    drawHatchFill(hatched, temperaHatchSpec(c.seed, 41), c.palette.tone4, 0.7),
    _o(delay: 0.08, grow: true, span: 0.55),
    poster,
  );
  c.add(
    drawPolygonOutline(hatched, c.palette.ink, 2, 0.8),
    _o(delay: 0.12, span: 0.55),
    poster,
  );
  c.add(
    drawPolyline(
      temperaWavyPath(c.seed, 43, -w * 0.6, w * 0.6, h * 0.42, h * 0.02),
      c.palette.tone4,
      2,
      0.7,
    ),
    _o(delay: 0.2, enterDY: h * 0.1),
    poster,
  );
}

void _diamondStack(TemperaComposer c) {
  final double w = c.width, h = c.height;
  _ground(c, c.palette.tone1);
  final List<Color> tones = <Color>[
    c.palette.ink,
    c.palette.tone4,
    c.palette.tone3,
  ];
  for (int i = 0; i < tones.length; i++) {
    final double scale = 1 - i * 0.28;
    c.add(
      drawPolygonFill(
        diamondPolygon(
          w * (0.34 + i * 0.24),
          h * (0.52 - i * 0.14),
          w * 0.3 * scale,
          h * 0.46 * scale,
        ),
        tones[i],
        0.93,
        c.gradient,
      ),
      _o(delay: i * 0.07, span: 0.55, enterDX: w * 0.25, enterDY: -h * 0.12),
    );
  }
}

void _slashPoster(TemperaComposer c) {
  final double w = c.width, h = c.height, b = c.bleed;
  final double lean = h * 0.34;
  final List<double> band = <double>[
    -b,
    h * 0.24 + lean,
    w + b,
    h * 0.24 - lean,
    w + b,
    h * 0.72 - lean,
    -b,
    h * 0.72 + lean,
  ];
  _ground(c, c.palette.tone1);
  c.add(
    drawPolygonFill(band, c.palette.tone4, 0.94, c.gradient),
    _o(delay: 0.05, span: 0.55, enterDX: -w * 0.4),
  );
  c.add(
    drawHatchFill(
      band,
      temperaHatchSpec(c.seed, 67).copyWith(angle: math.pi / 3),
      c.palette.paper,
      0.3,
    ),
    _o(delay: 0.1, span: 0.55, grow: true),
  );
  c.add(
    drawPolygonOutline(band, c.palette.ink, 2.2, 0.8),
    _o(delay: 0.14, span: 0.5),
  );
}

void _arrowWedge(TemperaComposer c) {
  final double w = c.width, h = c.height, b = c.bleed;
  final double apex = h * (0.24 + temperaHash01(c.seed, 3, 71) * 0.14);
  final double thickness = h * 0.2;
  final List<double> chevron = <double>[
    -b,
    h + b,
    w * 0.5,
    apex,
    w + b,
    h + b,
    w + b,
    h + b,
    w * 0.5,
    apex + thickness,
    -b,
    h + b,
  ];
  _ground(c, c.palette.tone1);
  c.add(
    drawPolygonFill(
      <double>[-b, h + b, w * 0.5, apex, w + b, h + b],
      c.palette.tone4,
      0.94,
      c.gradient,
    ),
    _o(delay: 0.05, span: 0.55, enterDY: h * 0.3),
  );
  c.add(
    drawHatchFill(
      chevron,
      temperaHatchSpec(c.seed, 73).copyWith(angle: -math.pi / 4),
      c.palette.paper,
      0.35,
    ),
    _o(delay: 0.1, span: 0.55, grow: true),
  );
  c.add(
    drawPolyline(
      <double>[-b, h * 0.9, w * 0.5, apex - thickness * 0.4, w + b, h * 0.9],
      c.palette.ink,
      2,
      0.7,
    ),
    _o(delay: 0.16, span: 0.5, enterDY: -h * 0.1),
  );
}

void _edgeBleed(TemperaComposer c) {
  final double w = c.width, h = c.height, b = c.bleed;
  final bool fromLeft = temperaHash01(c.seed, 4, 79) > 0.5;
  final double cover = w * 0.42;
  final List<double> mass = fromLeft
      ? rectPolygon(-b, -b, cover + b, h + b * 2)
      : rectPolygon(w - cover, -b, cover + b, h + b * 2);
  _ground(c, c.palette.tone1);
  c.add(
    drawPolygonFill(mass, c.palette.ink, 0.93, c.gradient),
    _o(delay: 0.05, span: 0.55, enterDX: (fromLeft ? -1 : 1) * w * 0.4),
  );
  c.add(
    drawHatchFill(mass, temperaHatchSpec(c.seed, 83), c.palette.paper, 0.22),
    _o(delay: 0.12, span: 0.55, grow: true),
  );
}

void _triangleMass(TemperaComposer c) {
  final double w = c.width, h = c.height, b = c.bleed;
  final bool fromLeft = temperaHash01(c.seed, 91, 89) > 0.5;
  final double apexX = fromLeft ? w * 1.02 : -w * 0.02;
  final List<double> triangle = <double>[
    fromLeft ? -b : w + b,
    -b,
    fromLeft ? -b : w + b,
    h + b,
    apexX,
    h * (0.3 + temperaHash01(c.seed, 93, 97) * 0.3),
  ];
  _ground(c, c.palette.tone1);
  c.add(
    drawPolygonFill(triangle, c.palette.tone4, 0.94, c.gradient),
    _o(delay: 0.05, span: 0.55, enterDX: (fromLeft ? -1 : 1) * w * 0.35),
  );
  c.add(
    drawHatchFill(
      triangle,
      temperaHatchSpec(c.seed, 101),
      c.palette.paper,
      0.24,
    ),
    _o(delay: 0.12, span: 0.55, grow: true),
  );
}

void _ribbonCross(TemperaComposer c) {
  final double w = c.width, h = c.height, b = c.bleed;
  final double half = h * 0.14, lean = h * 0.3;
  List<double> ribbon(double sign) => <double>[
    -b,
    h / 2 + sign * lean - half,
    w + b,
    h / 2 - sign * lean - half,
    w + b,
    h / 2 - sign * lean + half,
    -b,
    h / 2 + sign * lean + half,
  ];
  _ground(c, c.palette.tone1);
  c.add(
    drawPolygonFill(ribbon(1), c.palette.tone3, 0.8, c.gradient),
    _o(delay: 0.05, span: 0.55, enterDX: -w * 0.3),
  );
  c.add(
    drawPolygonFill(ribbon(-1), c.palette.tone4, 0.8, c.gradient),
    _o(delay: 0.11, span: 0.55, enterDX: w * 0.3),
  );
}

void _halfDisc(TemperaComposer c) {
  final double w = c.width, h = c.height;
  final bool fromRight = temperaHash01(c.seed, 103, 107) > 0.5;
  final double radius = math.sqrt(w * w + h * h) * 0.62;
  final List<double> disc = circlePolygon(
    fromRight ? w + radius * 0.55 : -radius * 0.55,
    h * 0.5,
    radius,
    64,
  );
  _ground(c, c.palette.tone1);
  c.add(
    drawPolygonFill(disc, c.palette.tone4, 0.94, c.gradient),
    _o(delay: 0.05, span: 0.55, enterDX: (fromRight ? 1 : -1) * w * 0.3),
  );
  c.add(
    drawPolygonOutline(disc, c.palette.ink, 2, 0.6),
    _o(delay: 0.12, span: 0.5),
  );
}

void _stackedSlabs(TemperaComposer c) {
  final double w = c.width, h = c.height;
  _ground(c, c.palette.tone1);
  final List<Color> tones = <Color>[
    c.palette.tone2,
    c.palette.tone3,
    c.palette.tone4,
  ];
  for (int i = 0; i < tones.length; i++) {
    final TemperaGroup group = c.createGroup(-0.09 + i * 0.08, w / 2, h / 2);
    final List<double> slab = rectPolygon(
      -w * (0.42 - i * 0.05),
      -h * (0.3 - i * 0.03),
      w * (0.84 - i * 0.1),
      h * (0.6 - i * 0.06),
    );
    c.add(
      drawPolygonFill(slab, tones[i], 0.93, c.gradient),
      _o(delay: i * 0.07, span: 0.55, enterDX: w * 0.2, enterDY: h * 0.12),
      group,
    );
  }
}

void _wedgePair(TemperaComposer c) {
  final double w = c.width, h = c.height, b = c.bleed;
  final double waist = w * (0.2 + temperaHash01(c.seed, 109, 113) * 0.1);
  _ground(c, c.palette.tone1);
  c.add(
    drawPolygonFill(
      <double>[-b, -b, (w - waist) / 2, h / 2, -b, h + b],
      c.palette.tone4,
      0.94,
      c.gradient,
    ),
    _o(delay: 0.05, span: 0.55, enterDX: -w * 0.25),
  );
  c.add(
    drawPolygonFill(
      <double>[w + b, -b, (w + waist) / 2, h / 2, w + b, h + b],
      c.palette.tone4,
      0.94,
      c.gradient,
    ),
    _o(delay: 0.11, span: 0.55, enterDX: w * 0.25),
  );
}

// ---------------------------------------------------------------------------
// 稀疏族
// ---------------------------------------------------------------------------

void _quietLine(TemperaComposer c) {
  final double w = c.width, h = c.height;
  final double gw = w * 0.7, gx = (w - gw) / 2;
  const List<double> ratios = <double>[0.38, 0.5, 0.62];
  for (int i = 0; i < ratios.length; i++) {
    c.add(
      drawPolygonFill(
        rectPolygon(gx, h * ratios[i], gw, 1),
        c.palette.line,
        1,
        c.gradient,
      ),
      _o(delay: i * 0.08, span: 0.6, enterDX: (i.isEven ? -1 : 1) * w * 0.2),
    );
  }
  if (!c.showDecor) return;
  c.add(
    drawPolyline(
      temperaScribblePath(
        c.decor.scribbleSeed,
        47,
        w * 0.2,
        h * 0.26,
        math.min(w, h) * 0.09,
        2,
      ),
      c.palette.tone4,
      1.6,
      0.7,
    ),
    _o(delay: 0.24, span: 0.6),
  );
  final double tx = w * 0.82, ty = h * 0.74;
  c.add(
    drawLines(
      <TemperaLine>[
        for (int i = 0; i < 6; i++)
          TemperaLine(
            tx + i * 7,
            ty,
            tx +
                i * 7 +
                (temperaHash01(c.decor.scribbleSeed, i, 59) - 0.5) * 34,
            ty - 24 - i * 3,
          ),
      ],
      c.palette.tone4,
      1.4,
      0.7,
    ),
    _o(delay: 0.3, span: 0.55),
  );
}

void _starfieldDots(TemperaComposer c) {
  final double w = c.width, h = c.height, b = c.bleed;
  final double spacing = math.max(24, math.sqrt((w * h) / 900));
  final List<TemperaMark> marks = temperaDotGrid(w + b, h + b, spacing, 2.6);
  final List<TemperaMark> dense = marks
      .where((TemperaMark m) => m.y > h * 0.45)
      .toList();
  final List<TemperaMark> sparse = marks
      .where((TemperaMark m) => m.y <= h * 0.45 && (m.x + m.y) % 3 < 1)
      .toList();
  c.add(
    drawSquareMarks(dense, c.palette.tone4, 0.45),
    _o(span: 0.6, enterDY: h * 0.2),
  );
  c.add(
    drawSquareMarks(sparse, c.palette.tone4, 0.25),
    _o(delay: 0.08, span: 0.6, enterDY: -h * 0.15),
  );
  if (!c.showDecor) return;
  c.add(
    drawLines(
      <TemperaLine>[TemperaLine(-b, h * 0.45, w + b, h * 0.45)],
      c.palette.tone4,
      1.2,
      0.5,
    ),
    _o(delay: 0.2, span: 0.5, enterDX: w * 0.2),
  );
}

void _rippleLines(TemperaComposer c) {
  final double w = c.width, h = c.height, b = c.bleed;
  for (int i = 0; i < 7; i++) {
    c.add(
      drawPolyline(
        temperaWavyPath(
          c.seed,
          89 + i,
          -b,
          w + b,
          h * (0.16 + i * 0.11),
          h * (0.006 + i * 0.004),
          26,
        ),
        c.palette.tone4,
        i % 3 == 0 ? 2 : 1.1,
        0.55,
      ),
      _o(delay: i * 0.045, span: 0.6, enterDX: (i.isEven ? -1 : 1) * w * 0.15),
    );
  }
}

void _hairGrid(TemperaComposer c) {
  final double w = c.width, h = c.height, b = c.bleed;
  const int columns = 6, rows = 4;
  c.add(
    drawLines(
      <TemperaLine>[
        for (int i = 0; i <= columns; i++)
          TemperaLine(w / columns * i, -b, w / columns * i, h + b),
      ],
      c.palette.line,
      1,
      0.8,
    ),
    _o(span: 0.6, enterDY: -h * 0.1),
  );
  c.add(
    drawLines(
      <TemperaLine>[
        for (int i = 0; i <= rows; i++)
          TemperaLine(-b, h / rows * i, w + b, h / rows * i),
      ],
      c.palette.line,
      1,
      0.8,
    ),
    _o(delay: 0.08, span: 0.6, enterDX: w * 0.1),
  );
}

void _marginRule(TemperaComposer c) {
  final double w = c.width, h = c.height, b = c.bleed;
  final bool fromLeft = temperaHash01(c.seed, 121, 127) > 0.5;
  final double x = fromLeft ? w * 0.12 : w * 0.88;
  c.add(
    drawPolygonFill(
      rectPolygon(x - 3, -b, 6, h + b * 2),
      c.palette.tone4,
      0.9,
      c.gradient,
    ),
    _o(span: 0.6, enterDY: h * 0.15),
  );
  if (!c.showDecor) return;
  c.add(
    drawSquareMarks(
      <TemperaMark>[
        for (int i = 0; i < 3; i++)
          TemperaMark(x + (fromLeft ? 22 : -22), h * (0.32 + i * 0.18), 7, 0),
      ],
      c.palette.tone4,
      0.8,
    ),
    _o(delay: 0.22, drift: true),
  );
}

void _dotDrift(TemperaComposer c) {
  final double w = c.width, h = c.height, b = c.bleed;
  final double spacing = math.max(22, math.sqrt((w * h) / 1200));
  final List<TemperaMark> marks = temperaDotGrid(w + b, h + b, spacing, 2.4);
  final double span = w + h;
  final List<TemperaMark> near = marks
      .where((TemperaMark m) => m.x + m.y > span * 0.5)
      .toList();
  final List<TemperaMark> far = marks
      .where((TemperaMark m) => m.x + m.y <= span * 0.5 && (m.x + m.y) % 2 < 1)
      .toList();
  c.add(
    drawSquareMarks(near, c.palette.tone4, 0.5),
    _o(span: 0.6, enterDX: w * 0.12),
  );
  c.add(
    drawSquareMarks(far, c.palette.tone4, 0.24),
    _o(delay: 0.08, span: 0.6, enterDX: -w * 0.12),
  );
}

void _arcSweep(TemperaComposer c) {
  final double w = c.width, h = c.height;
  final double cx = w * (temperaHash01(c.seed, 131, 137) > 0.5 ? 1.15 : -0.15);
  final double cy = h * 1.05;
  final double base = math.sqrt(w * w + h * h) * 0.42;
  for (int i = 0; i < 5; i++) {
    c.add(
      drawPolygonOutline(
        circlePolygon(cx, cy, base + i * base * 0.22, 72),
        c.palette.tone4,
        i.isEven ? 1.8 : 1,
        0.55,
      ),
      _o(delay: i * 0.05, span: 0.6, enterDY: h * 0.08),
    );
  }
}

void _blankPage(TemperaComposer c) {
  final double w = c.width, h = c.height;
  c.add(
    drawLines(
      <TemperaLine>[TemperaLine(w * 0.18, h * 0.7, w * 0.36, h * 0.7)],
      c.palette.line,
      1.4,
      0.8,
    ),
    _o(span: 0.6, enterDX: -w * 0.12),
  );
  if (!c.showDecor) return;
  c.add(
    drawPolyline(
      temperaScribblePath(
        c.decor.scribbleSeed,
        139,
        w * 0.82,
        h * 0.26,
        math.min(w, h) * 0.06,
        2,
      ),
      c.palette.tone4,
      1.4,
      0.6,
    ),
    _o(delay: 0.28, span: 0.6),
  );
}

// ---------------------------------------------------------------------------
// 遮幅族（按真实像素比例 aspect-fit，「正方形」在任何画幅下都是方的）
// ---------------------------------------------------------------------------

Rect _fitWindow(double w, double h, double aspect, double fill) {
  final double ww = math.min(w * fill, h * fill * aspect);
  final double wh = ww / aspect;
  return Rect.fromLTWH((w - ww) / 2, (h - wh) / 2, ww, wh);
}

void _addMatte(TemperaComposer c, Rect hole, Color tone) {
  final double w = c.width, h = c.height, b = c.bleed;
  final List<(List<double>, double, double)> bars =
      <(List<double>, double, double)>[
        (rectPolygon(-b, -b, w + b * 2, hole.top + b), 0, -h * 0.2),
        (
          rectPolygon(-b, hole.bottom, w + b * 2, h - hole.bottom + b),
          0,
          h * 0.2,
        ),
        (rectPolygon(-b, hole.top, hole.left + b, hole.height), -w * 0.2, 0),
        (
          rectPolygon(hole.right, hole.top, w - hole.right + b, hole.height),
          w * 0.2,
          0,
        ),
      ];
  for (int i = 0; i < bars.length; i++) {
    final (List<double> poly, double dx, double dy) = bars[i];
    c.add(
      drawPolygonFill(poly, tone, 0.96, c.gradient),
      _o(delay: i * 0.04, span: 0.5, enterDX: dx, enterDY: dy),
    );
  }
  c.add(
    drawPolygonOutline(
      rectPolygon(hole.left, hole.top, hole.width, hole.height),
      c.palette.ink,
      1.6,
      0.5,
    ),
    _o(delay: 0.2, span: 0.5),
  );
}

TemperaCompositionDrawer _matte(double aspect, double baseFill) =>
    (TemperaComposer c) {
      final double fill =
          baseFill + (temperaHash01(c.seed, 157, 163) - 0.5) * 0.06;
      final Rect hole = _fitWindow(c.width, c.height, aspect, fill);
      final List<double> poly = rectPolygon(
        hole.left,
        hole.top,
        hole.width,
        hole.height,
      );
      c.add(
        drawPolygonFill(poly, c.palette.tone1, 0.35, c.gradient),
        _o(span: 0.55),
      );
      c.add(
        drawHatchFill(
          poly,
          temperaHatchSpec(c.seed, 149, 1.5),
          c.palette.tone4,
          0.2,
        ),
        _o(delay: 0.1, span: 0.6, grow: true),
      );
      _addMatte(c, hole, c.palette.tone4);
      if (!c.showDecor) return;
      c.add(
        drawLines(
          <TemperaLine>[
            TemperaLine(
              hole.left,
              hole.top - c.height * 0.05,
              hole.left,
              hole.top - c.height * 0.02,
            ),
            TemperaLine(
              hole.right,
              hole.bottom + c.height * 0.02,
              hole.right,
              hole.bottom + c.height * 0.05,
            ),
          ],
          c.palette.paper,
          2,
          0.6,
        ),
        _o(delay: 0.26, span: 0.5),
      );
    };

void _cinemaTwin(TemperaComposer c) {
  final double w = c.width, h = c.height;
  final double inset = h * 0.16, gutter = w * 0.04;
  final Rect left = Rect.fromLTWH(w * 0.08, inset, w * 0.5, h - inset * 2);
  final Rect right = Rect.fromLTWH(
    left.right + gutter,
    inset + h * 0.1,
    w * 0.28,
    h - inset * 2 - h * 0.2,
  );
  _ground(c, c.palette.tone4, 0.96);
  final List<Rect> holes = <Rect>[left, right];
  for (int i = 0; i < 2; i++) {
    final List<double> poly = rectPolygon(
      holes[i].left,
      holes[i].top,
      holes[i].width,
      holes[i].height,
    );
    c.add(
      drawPolygonFill(poly, c.palette.tone1, i == 0 ? 0.4 : 0.85, c.gradient),
      _o(delay: i * 0.08, span: 0.55, enterDX: (i == 0 ? -1 : 1) * w * 0.14),
    );
    c.add(
      drawPolygonOutline(poly, c.palette.ink, 1.6, 0.5),
      _o(delay: 0.16 + i * 0.05, span: 0.5),
    );
  }
  if (!c.showDecor) return;
  c.add(
    drawHatchFill(
      rectPolygon(right.left, right.top, right.width, right.height),
      temperaHatchSpec(c.seed, 151),
      c.palette.tone4,
      0.35,
    ),
    _o(delay: 0.24, span: 0.6, grow: true),
  );
}

// ---------------------------------------------------------------------------
// 物语过场卡：整屏单色平涂，字就是整个画面
// ---------------------------------------------------------------------------

void _mgField(TemperaComposer c, Color tone) =>
    c.add(drawPolygonFill(_full(c), tone, 1, c.gradient), _o(span: 0.45));

Color _mgPick(TemperaComposer c) =>
    temperaHash01(c.seed, 167, 173) > 0.5 ? c.palette.tone4 : c.palette.tone1;

void _monogatariCard(TemperaComposer c) {
  _mgField(c, _mgPick(c));
  if (!c.showDecor) return;
  c.add(
    drawLines(
      <TemperaLine>[
        TemperaLine(
          c.width * 0.12,
          c.height * 0.9,
          c.width * 0.88,
          c.height * 0.9,
        ),
      ],
      c.palette.paper,
      1.2,
      0.45,
    ),
    _o(delay: 0.22, span: 0.6, enterDX: c.width * 0.15),
  );
}

void _monogatariRule(TemperaComposer c) {
  final double w = c.width, h = c.height, b = c.bleed;
  _mgField(c, _mgPick(c));
  final double y = h * (0.62 + temperaHash01(c.seed, 179, 181) * 0.08);
  c.add(
    drawPolygonFill(
      rectPolygon(-b, y, w + b * 2, h * 0.012),
      c.palette.paper,
      0.85,
      c.gradient,
    ),
    _o(delay: 0.12, span: 0.55, enterDX: -w * 0.3),
  );
  if (!c.showDecor) return;
  c.add(
    drawLines(
      <TemperaLine>[TemperaLine(-b, y + h * 0.05, w + b, y + h * 0.05)],
      c.palette.paper,
      1,
      0.35,
    ),
    _o(delay: 0.2, span: 0.6, enterDX: w * 0.2),
  );
}

void _monogatariEdge(TemperaComposer c) {
  final double w = c.width, h = c.height, b = c.bleed;
  final Color field = _mgPick(c);
  _mgField(c, field);
  final double band = w * (0.1 + temperaHash01(c.seed, 191, 193) * 0.05);
  final bool fromLeft = temperaHash01(c.seed, 197, 199) > 0.5;
  final List<double> spine = rectPolygon(
    fromLeft ? -b : w - band,
    -b,
    band + b,
    h + b * 2,
  );
  c.add(
    drawPolygonFill(
      spine,
      field == c.palette.tone4 ? c.palette.tone1 : c.palette.tone4,
      0.95,
      c.gradient,
    ),
    _o(delay: 0.1, span: 0.55, enterDX: (fromLeft ? -1 : 1) * w * 0.2),
  );
  if (!c.showDecor) return;
  c.add(
    drawHatchFill(spine, temperaHatchSpec(c.seed, 211), c.palette.paper, 0.2),
    _o(delay: 0.18, span: 0.6, grow: true),
  );
}

void _monogatariStack(TemperaComposer c) {
  final double w = c.width, h = c.height, b = c.bleed;
  _mgField(c, _mgPick(c));
  final double column = w * 0.5;
  c.add(
    drawLines(
      <TemperaLine>[
        TemperaLine((w - column) / 2, -b, (w - column) / 2, h + b),
        TemperaLine((w + column) / 2, -b, (w + column) / 2, h + b),
      ],
      c.palette.paper,
      1.1,
      0.4,
    ),
    _o(delay: 0.14, span: 0.6, enterDY: h * 0.12),
  );
}

void _monogatariFlash(TemperaComposer c) {
  final double w = c.width, h = c.height;
  _mgField(c, c.palette.tone4);
  if (!c.showDecor) return;
  c.add(
    drawCrossMarks(
      temperaCrossRow(c.seed, 223, w * 0.1, h * 0.18, 4, w * 0.05, 10),
      c.palette.paper,
      2.4,
      0.6,
    ),
    _o(delay: 0.2, span: 0.5, enterDX: -w * 0.1),
  );
}

// ---------------------------------------------------------------------------
// 注册表 + 共享装饰
// ---------------------------------------------------------------------------

final Map<String, TemperaCompositionDrawer> temperaCompositions =
    <String, TemperaCompositionDrawer>{
      'duo-split': _duoSplit,
      'quad-split': _quadSplit,
      'tri-column': _triColumn,
      'thirds-stack': _thirdsStack,
      'checker-quad': _checkerQuad,
      'corner-wedge': _cornerWedge,
      'diagonal-halves': _diagonalHalves,
      'cross-axis': _crossAxis,
      'offset-halves': _offsetHalves,
      'stair-blocks': _stairBlocks,
      'pillar-gap': _pillarGap,
      'corner-quad': _cornerQuad,
      'sliver-stack': _sliverStack,
      'band-strip': _bandStrip,
      'horizon-band': _horizonBand,
      'deep-dive': _deepDive,
      'tone-ramp': _toneRamp,
      'double-band': _doubleBand,
      'tilt-band': _tiltBand,
      'edge-rails': _edgeRails,
      'gradient-wall': _gradientWall,
      'terrace': _terrace,
      'frame-window': _frameWindow,
      'double-frame': _doubleFrame,
      'circle-window': _circleWindow,
      'ladder-frame': _ladderFrame,
      'corner-brackets': _cornerBrackets,
      'inset-box': _insetBox,
      'bracket-pair': _bracketPair,
      'arch-window': _archWindow,
      'grid-cells': _gridCells,
      'keyhole': _keyhole,
      'poster-panel': _posterPanel,
      'diamond-stack': _diamondStack,
      'slash-poster': _slashPoster,
      'arrow-wedge': _arrowWedge,
      'edge-bleed': _edgeBleed,
      'triangle-mass': _triangleMass,
      'ribbon-cross': _ribbonCross,
      'half-disc': _halfDisc,
      'stacked-slabs': _stackedSlabs,
      'wedge-pair': _wedgePair,
      'quiet-line': _quietLine,
      'starfield-dots': _starfieldDots,
      'ripple-lines': _rippleLines,
      'hair-grid': _hairGrid,
      'margin-rule': _marginRule,
      'dot-drift': _dotDrift,
      'arc-sweep': _arcSweep,
      'blank-page': _blankPage,
      'cinema-scope': _matte(2.39, 0.88),
      'cinema-wide': _matte(1.85, 0.84),
      'cinema-academy': _matte(1.33, 0.78),
      'cinema-square': _matte(1, 0.72),
      'cinema-portrait': _matte(0.75, 0.72),
      'cinema-tall': _matte(0.5625, 0.72),
      'cinema-twin': _cinemaTwin,
      ...temperaCutCompositions,
      'monogatari-card': _monogatariCard,
      'monogatari-rule': _monogatariRule,
      'monogatari-edge': _monogatariEdge,
      'monogatari-stack': _monogatariStack,
      'monogatari-flash': _monogatariFlash,
    };

/// 贯穿每个分镜的浅斜引导线，把视线从一个分镜带到下一个。
void _addCrossingLines(TemperaComposer c) {
  final List<TemperaLine> lines = temperaCrossingLines(
    c.seed,
    31,
    c.width,
    c.height,
    c.decor.crossCount,
  );
  if (lines.isEmpty) return;
  c.add(
    drawLines(lines, c.palette.tone4, 1.3, 0.6),
    _o(delay: 0.14, span: 0.6, enterDX: c.width * 0.25),
  );
}

/// 编译期选定的角落 motif。
void _addMotif(TemperaComposer c) {
  final double w = c.width, h = c.height;
  final double cornerX = temperaHash01(c.seed, 61, 7) > 0.5
      ? w * 0.14
      : w * 0.86;
  final double cornerY = temperaHash01(c.seed, 63, 7) > 0.5
      ? h * 0.18
      : h * 0.82;
  switch (c.decor.motif) {
    case 'diamonds':
      c.add(
        drawConcentricDiamonds(
          cornerX,
          cornerY,
          34,
          34,
          3,
          c.palette.tone4,
          0.8,
        ),
        _o(delay: 0.34, drift: true),
      );
    case 'hatch-twin':
      final TemperaHatchSpec spec = temperaHatchSpec(
        c.seed,
        67,
      ).copyWith(angle: c.decor.hatchAngle);
      for (int i = 0; i < 2; i++) {
        final List<double> box = rectPolygon(
          cornerX - 34 + i * 46,
          cornerY - 26,
          38,
          38,
        );
        c.add(
          drawHatchFill(
            box,
            i == 0 ? spec : spec.copyWith(spacing: spec.spacing * 0.55),
            c.palette.tone4,
            0.75,
          ),
          _o(delay: 0.34 + i * 0.05, grow: true),
        );
        c.add(
          drawPolygonOutline(box, c.palette.tone4, 1.2, 0.6),
          _o(delay: 0.38 + i * 0.05),
        );
      }
    case 'band-cross':
      c.add(
        drawCrossMarks(
          temperaCrossRow(
            c.seed,
            71,
            cornerX - w * 0.1,
            cornerY,
            5,
            w * 0.05,
            8,
            c.decor.hatchAngle * 0.4,
          ),
          c.palette.tone4,
          2,
          0.8,
        ),
        _o(delay: 0.34, span: 0.5),
      );
    case 'poster-diamond':
      c.add(
        drawPolygonFill(
          diamondPolygon(
            cornerX < w / 2 ? -w * 0.04 : w * 1.04,
            cornerY,
            w * 0.14,
            h * 0.2,
          ),
          c.palette.tone3,
          0.85,
        ),
        _o(
          delay: 0.32,
          span: 0.55,
          enterDX: (cornerX < w / 2 ? -1 : 1) * w * 0.1,
        ),
      );
    default:
      c.add(
        drawPolyline(
          temperaScribblePath(
            c.decor.scribbleSeed,
            73,
            cornerX,
            cornerY,
            math.min(w, h) * 0.08,
            3,
          ),
          c.palette.tone4,
          1.5,
          0.72,
        ),
        _o(delay: 0.34, span: 0.6),
      );
  }
}

/// 画一个分镜的构图（含共享装饰）。
void drawTemperaComposition(TemperaComposer c) {
  (temperaCompositions[c.kind] ?? _duoSplit)(c);
  if (!temperaShotProfile(c.kind).sharedDecor) return;
  _addCrossingLines(c);
  if (c.showDecor) _addMotif(c);
}
