/// 凝彩的圆滑 / 镂空 / 仪表 / 通道 / 巨构 / 地形六族构图（folia `compositions/*`，逐项照搬）。
///
/// 镂空族的洞真的透明：露出宿主的共享背景。字永远不压在洞上（版式区域是固定数据，洞避开它）。
library;

import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/modes/tempera/tempera_geometry.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/tempera/tempera_random.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/tempera/tempera_shapes.dart';

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

// ---------------------------------------------------------------------------
// 镂空公用件（folia temperaCutout.ts）
// ---------------------------------------------------------------------------

List<double> _fieldPolygon(TemperaComposer c) => rectPolygon(
  -c.bleed,
  -c.bleed,
  c.width + c.bleed * 2,
  c.height + c.bleed * 2,
);

void _addField(TemperaComposer c, Color color, [double alpha = 0.92]) => c.add(
  drawPolygonFill(_fieldPolygon(c), color, alpha, c.gradient),
  _o(span: 0.5),
);

void _addCutField(
  TemperaComposer c,
  Color color,
  List<List<double>> holes, {
  double alpha = 0.94,
  double delay = 0,
  double span = 0.5,
}) => c.add(
  drawPolygonFillWithHoles(_fieldPolygon(c), holes, color, alpha, c.gradient),
  _o(delay: delay, span: span),
);

void _addHoleLip(
  TemperaComposer c,
  List<double> hole, [
  double width = 2.4,
  double alpha = 0.85,
  double delay = 0.1,
]) => c.add(
  drawPolygonOutline(hole, c.palette.ink, width, alpha),
  _o(delay: delay, span: 0.5),
);

/// 以 (cx, cy) 为中心、沿 [angle] 长 [length]、横向宽 [width] 的矩形。
List<double> temperaAxisRect(
  double cx,
  double cy,
  double length,
  double width,
  double angle,
) => rotatePolygon(
  rectPolygon(cx - length / 2, cy - width / 2, length, width),
  cx,
  cy,
  angle,
);

/// flow 角向自身竖轴拉回一半：通道仍平行于推移方向，两端横向游移减半，不会滑到字下面。
double temperaChannelAxis(double flowAngle) {
  final double axis = (math.sin(flowAngle) >= 0 ? 1 : -1) * math.pi / 2;
  return axis + (flowAngle - axis) * 0.5;
}

/// 垂直于通道轴的单位向量，恒指向画面 +x 一侧（「偏移 +n」永远是向右）。
Offset temperaAcrossFlow(double angle) {
  final double across = angle + math.pi / 2;
  final double sign = math.cos(across) >= 0 ? 1 : -1;
  return Offset(math.cos(across) * sign, math.sin(across) * sign);
}

Offset _acrossPoint(TemperaComposer c, double offset) {
  final Offset across = temperaAcrossFlow(temperaChannelAxis(c.flowAngle));
  return Offset(
    c.width / 2 + across.dx * offset,
    c.height / 2 + across.dy * offset,
  );
}

Offset _flowPoint(TemperaComposer c, double distance, double offset) {
  final Offset base = _acrossPoint(c, offset);
  final double angle = temperaChannelAxis(c.flowAngle);
  return Offset(
    base.dx + math.cos(angle) * distance,
    base.dy + math.sin(angle) * distance,
  );
}

double _flowSpan(TemperaComposer c) =>
    math.sqrt(c.width * c.width + c.height * c.height) * 1.6;

TemperaLine _seg(Offset a, Offset b) => TemperaLine(a.dx, a.dy, b.dx, b.dy);

// ---------------------------------------------------------------------------
// 巨构公用件（folia temperaMonolithKit.ts）
// ---------------------------------------------------------------------------

void _addMass(
  TemperaComposer c,
  List<double> polygon,
  Color color, {
  double alpha = 0.95,
  double delay = 0.04,
  double span = 0.6,
  double enterDX = 0,
  double enterDY = 0,
  bool edge = true,
  double edgeWidth = 2.4,
}) {
  c.add(
    drawPolygonFill(polygon, color, alpha, c.gradient),
    _o(delay: delay, span: span, enterDX: enterDX, enterDY: enterDY),
  );
  if (!edge) return;
  c.add(
    drawPolygonOutline(polygon, c.palette.ink, edgeWidth, 0.8),
    _o(
      delay: delay + 0.06,
      span: 0.5,
      enterDX: enterDX * 0.6,
      enterDY: enterDY * 0.6,
    ),
  );
}

void _addGround(TemperaComposer c, Color color, [double alpha = 0.94]) =>
    _addField(c, color, alpha);

void _addFaceRuling(
  TemperaComposer c,
  List<double> face,
  int salt, [
  Color? color,
  double alpha = 0.5,
]) => c.add(
  drawHatchFill(
    face,
    temperaHatchSpec(c.seed, salt, 0.7),
    color ?? c.palette.tone4,
    alpha,
  ),
  _o(delay: 0.16, span: 0.65, grow: true),
);

void _addSurveyLines(TemperaComposer c, [int count = 3, int salt = 211]) {
  final double w = c.width, h = c.height, b = c.bleed;
  final List<TemperaLine> lines = <TemperaLine>[
    for (int i = 0; i < math.max(1, count); i++)
      () {
        final double anchor =
            h * (0.16 + ((i * 0.31 + (c.seed % 7) * 0.04) % 0.7));
        final double lean = h * (i.isEven ? 0.22 : -0.16);
        return TemperaLine(-b, anchor - lean, w + b, anchor + lean);
      }(),
  ];
  c.add(
    drawLines(lines, c.palette.paper, 1, 0.45),
    _o(delay: 0.2 + (salt % 3) * 0.02, span: 0.7, enterDX: w * 0.2),
  );
}

void _addCornerTicks(TemperaComposer c) {
  final double w = c.width, h = c.height;
  final double inset = math.min(w, h) * 0.06;
  final double arm = math.min(w, h) * 0.05;
  const List<double> signs = <double>[1, -1];
  for (int i = 0; i < 2; i++) {
    final double s = signs[i];
    final double x = s > 0 ? inset : w - inset;
    final double y = s > 0 ? inset : h - inset;
    c.add(
      drawLines(
        <TemperaLine>[
          TemperaLine(x, y, x + s * arm, y),
          TemperaLine(x, y, x, y + s * arm),
        ],
        c.palette.paper,
        1.6,
        0.6,
      ),
      _o(delay: 0.26 + i * 0.04, span: 0.5),
    );
  }
}

void _addWireTrace(TemperaComposer c, double cx, double cy, double radius) {
  final TemperaGroup group = c.createGroup(0, cx, cy);
  c.add(
    drawPolyline(
      temperaScribblePath(c.decor.scribbleSeed, 199, 0, 0, radius, 1),
      c.palette.paper,
      1.2,
      0.4,
    ),
    _o(delay: 0.3, span: 0.6, drift: true),
    group,
  );
}

// ---------------------------------------------------------------------------
// 圆滑族（charm）
// ---------------------------------------------------------------------------

void _bubbleDrift(TemperaComposer c) {
  final double w = c.width, h = c.height, unit = math.min(w, h);
  _addField(c, c.palette.tone1);
  final List<TemperaDisc> big = temperaDiscField(
    c.seed,
    11,
    w,
    h,
    8,
    unit * 0.115,
  );
  final List<TemperaDisc> small = temperaDiscField(
    c.seed,
    17,
    w,
    h,
    13,
    unit * 0.042,
  );
  c.add(
    drawDiscs(big, c.palette.tone3, 0.88, c.gradient),
    _o(delay: 0.05, span: 0.6, enterDY: h * 0.16, drift: true),
  );
  c.add(
    drawRings(big, c.palette.ink, 2, 0.55),
    _o(delay: 0.12, span: 0.55, enterDY: h * 0.12),
  );
  c.add(
    drawDiscs(small, c.palette.tone4, 0.7),
    _o(delay: 0.18, span: 0.6, enterDY: h * 0.22, drift: true),
  );
  if (!c.showDecor) return;
  c.add(
    drawDiscs(
      <TemperaDisc>[
        for (final TemperaDisc d in big.take(2))
          TemperaDisc(
            d.x - d.radius * 0.36,
            d.y - d.radius * 0.36,
            d.radius * 0.16,
          ),
      ],
      c.palette.paper,
      0.85,
    ),
    _o(delay: 0.28, drift: true),
  );
}

void _cloudWindow(TemperaComposer c) {
  final double w = c.width, h = c.height, unit = math.min(w, h);
  final double cx = w / 2, cy = h * 0.52, rx = w * 0.3, ry = h * 0.3;
  _addField(c, c.palette.tone3);
  final List<double> cloud = lobedPolygon(cx, cy, rx, ry, 9, 0.1);
  c.add(
    drawPolygonFill(
      lobedPolygon(cx, cy + h * 0.025, rx * 1.05, ry * 1.05, 9, 0.1),
      c.palette.tone4,
      0.5,
    ),
    _o(delay: 0.04, span: 0.6),
  );
  c.add(
    drawPolygonFill(cloud, c.palette.paper, 0.96, c.gradient),
    _o(delay: 0.08, span: 0.55),
  );
  c.add(
    drawPolygonOutline(cloud, c.palette.ink, 2.4, 0.85),
    _o(delay: 0.12, span: 0.5),
  );
  if (!c.showDecor) return;
  c.add(
    drawDiscs(
      <TemperaDisc>[
        TemperaDisc(cx - rx * 1.16, cy + ry * 0.66, unit * 0.035),
        TemperaDisc(cx - rx * 1.32, cy + ry * 0.9, unit * 0.02),
      ],
      c.palette.paper,
      0.92,
      c.gradient,
    ),
    _o(delay: 0.22, drift: true),
  );
}

void _heartBurst(TemperaComposer c) {
  final double w = c.width, h = c.height;
  final double lean = temperaHash01(c.seed, 3, 83) > 0.5 ? 1 : -1;
  final double cx = w * 0.5, cy = h * 0.52, rx = w * 0.32, ry = h * 0.4;
  _addField(c, c.palette.tone4, 0.94);
  final List<double> main = rotatePolygon(
    heartPolygon(cx, cy, rx, ry),
    cx,
    cy,
    lean * 0.06,
  );
  c.add(
    drawPolygonFill(
      rotatePolygon(
        heartPolygon(cx + lean * w * 0.022, cy + h * 0.025, rx, ry),
        cx,
        cy,
        lean * 0.06,
      ),
      c.palette.tone2,
      0.6,
    ),
    _o(delay: 0.04, span: 0.6),
  );
  c.add(
    drawPolygonFill(main, c.palette.paper, 0.95, c.gradient),
    _o(delay: 0.08, span: 0.55, enterDY: h * 0.1),
  );
  c.add(
    drawPolygonOutline(main, c.palette.ink, 3, 0.9),
    _o(delay: 0.14, span: 0.5, enterDY: h * 0.08),
  );
  const List<double> scales = <double>[0.4, 0.24];
  for (int i = 0; i < scales.length; i++) {
    final double x = lean > 0 ? w * (0.88 + i * 0.08) : w * (0.12 - i * 0.08);
    final double y = h * (0.24 + i * 0.42);
    final TemperaGroup group = c.createGroup(0, x, y);
    c.add(
      drawPolygonFill(
        rotatePolygon(
          heartPolygon(0, 0, rx * scales[i], ry * scales[i]),
          0,
          0,
          -lean * 0.22,
        ),
        c.palette.tone2,
        0.9,
        c.gradient,
      ),
      _o(
        delay: 0.2 + i * 0.06,
        span: 0.5,
        enterDX: lean * w * 0.12,
        drift: true,
      ),
      group,
    );
  }
}

void _sparkleField(TemperaComposer c) {
  final double w = c.width, h = c.height, unit = math.min(w, h);
  _addField(c, c.palette.tone1, 0.88);
  final List<TemperaDisc> seeds = temperaDiscField(
    c.seed,
    23,
    w,
    h,
    9,
    unit * 0.07,
  );
  for (int i = 0; i < math.min(5, seeds.length); i++) {
    final TemperaDisc d = seeds[i];
    final List<double> star = starPolygon(
      0,
      0,
      d.radius,
      d.radius * 0.16,
      4,
      temperaHash01(c.seed, i, 29) * 0.9,
    );
    final TemperaGroup group = c.createGroup(0, d.x, d.y);
    c.add(
      drawPolygonFill(star, c.palette.tone4, 0.9, c.gradient),
      _o(delay: 0.06 + i * 0.05, span: 0.5, drift: true),
      group,
    );
  }
  c.add(
    drawDiscs(
      <TemperaDisc>[
        for (final TemperaDisc d in seeds.skip(5))
          TemperaDisc(d.x, d.y, d.radius * 0.22),
      ],
      c.palette.tone4,
      0.7,
    ),
    _o(delay: 0.24, span: 0.55, drift: true),
  );
  c.add(
    drawLines(
      <TemperaLine>[TemperaLine(w * 0.08, h * 0.74, w * 0.92, h * 0.72)],
      c.palette.tone4,
      1.2,
      0.5,
    ),
    _o(delay: 0.3, span: 0.5, enterDX: -w * 0.12),
  );
}

void _petalArc(TemperaComposer c) {
  final double w = c.width, h = c.height;
  final bool fromLeft = temperaHash01(c.seed, 5, 89) > 0.5;
  final double hubX = fromLeft ? -w * 0.1 : w * 1.1;
  final double hubY = h * 0.12;
  final double rx = w * 0.26, ry = h * 0.085;
  _addField(c, c.palette.tone2);
  for (int i = 0; i < 5; i++) {
    final List<double> base = ellipsePolygon(
      hubX + (fromLeft ? rx : -rx),
      hubY,
      rx,
      ry,
      28,
    );
    final List<double> petal = rotatePolygon(
      base,
      hubX,
      hubY,
      (fromLeft ? 1 : -1) * (0.18 + i * 0.3),
    );
    c.add(
      drawPolygonFill(
        petal,
        i.isEven ? c.palette.tone3 : c.palette.tone1,
        0.9,
        c.gradient,
      ),
      _o(delay: i * 0.05, span: 0.55, enterDY: -h * 0.1),
    );
    c.add(
      drawPolygonOutline(petal, c.palette.ink, 1.6, 0.5),
      _o(delay: 0.06 + i * 0.05, span: 0.5),
    );
  }
  final TemperaGroup hub = c.createGroup(0, hubX, hubY);
  c.add(
    drawPolygonFill(
      lobedPolygon(0, 0, w * 0.11, w * 0.11, 6, 0.34),
      c.palette.tone4,
      0.9,
      c.gradient,
    ),
    _o(delay: 0.28, span: 0.5, drift: true),
    hub,
  );
  if (!c.showDecor) return;
  c.add(
    drawDiscs(
      <TemperaDisc>[
        for (int i = 0; i < 3; i++)
          TemperaDisc(
            fromLeft ? w * (0.78 + i * 0.07) : w * (0.22 - i * 0.07),
            h * (0.7 + i * 0.1),
            h * (0.03 - i * 0.006),
          ),
      ],
      c.palette.tone4,
      0.75,
      c.gradient,
    ),
    _o(delay: 0.32, span: 0.5, drift: true),
  );
}

void _scallopBand(TemperaComposer c) {
  final double w = c.width, h = c.height, b = c.bleed;
  _addField(c, c.palette.tone1, 0.9);
  final List<double> top = scallopBandPolygon(-b, w + b, -b, h * 0.28, 9);
  final List<double> bottom = scallopBandPolygon(-b, w + b, h + b, h * 0.72, 9);
  c.add(
    drawPolygonFill(top, c.palette.tone3, 0.92, c.gradient),
    _o(delay: 0.04, span: 0.55, enterDY: -h * 0.18),
  );
  c.add(
    drawPolygonFill(bottom, c.palette.tone4, 0.92, c.gradient),
    _o(delay: 0.1, span: 0.55, enterDY: h * 0.18),
  );
  c.add(
    drawPolygonOutline(top, c.palette.ink, 2, 0.75),
    _o(delay: 0.14, span: 0.5, enterDY: -h * 0.12),
  );
  c.add(
    drawPolygonOutline(bottom, c.palette.ink, 2, 0.75),
    _o(delay: 0.18, span: 0.5, enterDY: h * 0.12),
  );
  if (!c.showDecor) return;
  final double pitch = (w + b * 2) / 9;
  c.add(
    drawDiscs(
      <TemperaDisc>[
        for (int i = 0; i < 5; i++)
          TemperaDisc(-b + pitch * (i + 2), h * 0.28, math.min(w, h) * 0.018),
      ],
      c.palette.ink,
      0.7,
    ),
    _o(delay: 0.26, drift: true),
  );
}

void _ribbonLoop(TemperaComposer c) {
  final double w = c.width, h = c.height, b = c.bleed;
  final double sag =
      h *
      (0.06 + temperaHash01(c.seed, 7, 97) * 0.05) *
      (temperaHash01(c.seed, 9, 97) > 0.5 ? 1 : -1);
  _addField(c, c.palette.tone2);
  final List<double> band = arcRibbonPolygon(-b, w + b, h * 0.5, h * 0.3, sag);
  final List<double> echo = arcRibbonPolygon(
    -b,
    w + b,
    h * 0.68,
    h * 0.06,
    -sag,
  );
  c.add(
    drawPolygonFill(echo, c.palette.tone4, 0.7, c.gradient),
    _o(delay: 0.04, span: 0.6, enterDX: -w * 0.16),
  );
  c.add(
    drawPolygonFill(band, c.palette.paper, 0.95, c.gradient),
    _o(delay: 0.08, span: 0.55, enterDX: w * 0.18),
  );
  c.add(
    drawPolygonOutline(band, c.palette.ink, 2.6, 0.85),
    _o(delay: 0.14, span: 0.5, enterDX: w * 0.14),
  );
  final double knotX = w * (temperaHash01(c.seed, 11, 97) > 0.5 ? 0.24 : 0.76);
  final double knotY =
      h * 0.5 + math.sin((knotX + b) / (w + b * 2) * math.pi) * sag;
  final TemperaGroup bow = c.createGroup(0, knotX, knotY);
  const List<double> sides = <double>[-1, 1];
  for (int i = 0; i < 2; i++) {
    final double side = sides[i];
    final List<double> loop = rotatePolygon(
      ellipsePolygon(side * w * 0.055, 0, w * 0.05, h * 0.07, 26),
      0,
      0,
      side * 0.3,
    );
    c.add(
      drawPolygonFill(loop, c.palette.tone4, 0.92, c.gradient),
      _o(delay: 0.2 + i * 0.04, span: 0.5, enterDX: side * w * 0.06),
      bow,
    );
    c.add(
      drawPolygonOutline(loop, c.palette.ink, 2, 0.8),
      _o(delay: 0.24 + i * 0.04, span: 0.5),
      bow,
    );
  }
  final List<double> knot = roundedRectPolygon(
    -w * 0.018,
    -h * 0.035,
    w * 0.036,
    h * 0.07,
    h * 0.02,
  );
  c.add(
    drawPolygonFill(knot, c.palette.tone4, 0.95, c.gradient),
    _o(delay: 0.28, span: 0.5),
    bow,
  );
  c.add(
    drawPolygonOutline(knot, c.palette.ink, 2, 0.85),
    _o(delay: 0.3, span: 0.5),
    bow,
  );
}

void _roundPlate(TemperaComposer c) {
  final double w = c.width, h = c.height, unit = math.min(w, h);
  _addField(c, c.palette.tone3);
  final List<double> plate = roundedRectPolygon(
    w * 0.16,
    h * 0.24,
    w * 0.68,
    h * 0.52,
    unit * 0.11,
  );
  final List<double> inner = roundedRectPolygon(
    w * 0.19,
    h * 0.29,
    w * 0.62,
    h * 0.42,
    unit * 0.08,
  );
  c.add(
    drawPolygonFill(plate, c.palette.paper, 0.95, c.gradient),
    _o(delay: 0.05, span: 0.55, enterDY: h * 0.06),
  );
  c.add(
    drawHatchFill(
      inner,
      temperaHatchSpec(c.seed, 101, 1.3),
      c.palette.tone2,
      0.35,
    ),
    _o(delay: 0.1, span: 0.6, grow: true),
  );
  c.add(
    drawPolygonOutline(plate, c.palette.ink, 3, 0.9),
    _o(delay: 0.12, span: 0.5),
  );
  c.add(
    drawPolygonOutline(inner, c.palette.tone4, 1.2, 0.55),
    _o(delay: 0.16, span: 0.5),
  );
  if (!c.showDecor) return;
  c.add(
    drawDiscs(
      <TemperaDisc>[
        TemperaDisc(w * 0.22, h * 0.3, unit * 0.016),
        TemperaDisc(w * 0.78, h * 0.3, unit * 0.016),
        TemperaDisc(w * 0.22, h * 0.7, unit * 0.016),
        TemperaDisc(w * 0.78, h * 0.7, unit * 0.016),
      ],
      c.palette.ink,
      0.75,
    ),
    _o(delay: 0.22, span: 0.5),
  );
}

void _haloBurst(TemperaComposer c) {
  final double w = c.width, h = c.height, unit = math.min(w, h);
  final double cx = w * (0.44 + temperaHash01(c.seed, 13, 103) * 0.12);
  final double cy = h * 0.5;
  final double reach = math.sqrt(w * w + h * h) * 0.7;
  const int wedges = 14;
  _addField(c, c.palette.tone1);
  for (int i = 0; i < wedges; i += 2) {
    final double angle =
        (i / wedges) * math.pi * 2 + temperaHash01(c.seed, i, 107) * 0.09;
    const double spread = 0.11;
    c.add(
      drawPolygonFill(
        <double>[
          cx,
          cy,
          cx + math.cos(angle - spread) * reach,
          cy + math.sin(angle - spread) * reach,
          cx + math.cos(angle + spread) * reach,
          cy + math.sin(angle + spread) * reach,
        ],
        c.palette.tone3,
        0.55,
        c.gradient,
      ),
      _o(delay: 0.04 + i * 0.012, span: 0.6),
    );
  }
  c.add(
    drawPolygonFill(
      ellipsePolygon(cx, cy, unit * 0.34, unit * 0.34, 48),
      c.palette.paper,
      0.94,
      c.gradient,
    ),
    _o(delay: 0.14, span: 0.55),
  );
  const List<(double, double)> rings = <(double, double)>[
    (0.34, 3),
    (0.44, 1.4),
  ];
  for (int i = 0; i < rings.length; i++) {
    c.add(
      drawRings(
        <TemperaDisc>[TemperaDisc(cx, cy, unit * rings[i].$1)],
        c.palette.ink,
        rings[i].$2,
        0.75,
      ),
      _o(delay: 0.2 + i * 0.06, span: 0.5, drift: true),
    );
  }
}

// ---------------------------------------------------------------------------
// 镂空族（aperture）
// ---------------------------------------------------------------------------

void _irisHole(TemperaComposer c) {
  final double w = c.width, h = c.height, unit = math.min(w, h);
  final double cx = w * 0.68, cy = h * 0.42, radius = unit * 0.3;
  final List<double> hole = circlePolygon(cx, cy, radius, 56);
  _addCutField(c, c.palette.tone3, <List<double>>[hole]);
  _addHoleLip(c, hole, 3, 0.9, 0.08);
  c.add(
    drawPolygonFill(
      rectPolygon(
        -c.bleed,
        cy - unit * 0.035,
        cx - radius * 0.7 + c.bleed,
        unit * 0.07,
      ),
      c.palette.tone4,
      0.9,
      c.gradient,
    ),
    _o(delay: 0.14, span: 0.55, enterDX: -w * 0.12),
  );
  if (!c.showDecor) return;
  c.add(
    drawRings(
      <TemperaDisc>[TemperaDisc(cx, cy, radius * 1.14)],
      c.palette.tone4,
      1.4,
      0.6,
    ),
    _o(delay: 0.2, span: 0.5, drift: true),
  );
}

void _slotRail(TemperaComposer c) {
  final double w = c.width, h = c.height, b = c.bleed;
  final double top = h * 0.22;
  final List<double> slot = rectPolygon(-b, top, w + b * 2, h * 0.16);
  _addCutField(c, c.palette.tone4, <List<double>>[slot]);
  _addHoleLip(c, slot, 2.4, 0.8, 0.1);
  c.add(
    drawPolygonFill(
      rectPolygon(w * 0.66, top - h * 0.06, w * 0.12, h * 0.28),
      c.palette.tone2,
      0.95,
      c.gradient,
    ),
    _o(delay: 0.16, span: 0.55, enterDY: -h * 0.1),
  );
  c.add(
    drawLines(
      <TemperaLine>[TemperaLine(-b, top + h * 0.22, w + b, top + h * 0.22)],
      c.palette.tone2,
      1.4,
      0.55,
    ),
    _o(delay: 0.22, span: 0.5, enterDX: w * 0.14),
  );
}

void _punchRow(TemperaComposer c) {
  final double w = c.width, h = c.height;
  final double radius = math.min(w, h) * 0.028;
  final List<List<double>> holes = <List<double>>[];
  for (int i = 0; i < 9; i++) {
    final double x = w * (0.08 + i * 0.105);
    holes
      ..add(circlePolygon(x, h * 0.14, radius, 20))
      ..add(circlePolygon(x, h * 0.86, radius, 20));
  }
  _addCutField(c, c.palette.tone3, holes);
  const List<double> ys = <double>[0.22, 0.78];
  for (int i = 0; i < 2; i++) {
    c.add(
      drawLines(
        <TemperaLine>[TemperaLine(0, h * ys[i], w, h * ys[i])],
        c.palette.tone4,
        1.6,
        0.6,
      ),
      _o(
        delay: 0.12 + i * 0.04,
        span: 0.5,
        enterDX: (i == 0 ? 1 : -1) * w * 0.12,
      ),
    );
  }
}

void _filmGate(TemperaComposer c) {
  final double w = c.width, h = c.height;
  final List<double> gate = rectPolygon(w * 0.2, h * 0.1, w * 0.6, h * 0.52);
  final List<List<double>> holes = <List<double>>[gate];
  for (int i = 0; i < 4; i++) {
    final double y = h * (0.14 + i * 0.13);
    holes
      ..add(rectPolygon(w * 0.08, y, w * 0.05, h * 0.06))
      ..add(rectPolygon(w * 0.87, y, w * 0.05, h * 0.06));
  }
  _addCutField(c, c.palette.tone4, holes);
  _addHoleLip(c, gate, 3, 0.9, 0.08);
  c.add(
    drawHatchFill(
      rectPolygon(w * 0.2, h * 0.68, w * 0.6, h * 0.1),
      temperaHatchSpec(c.seed, 131, 1.2),
      c.palette.tone2,
      0.5,
    ),
    _o(delay: 0.18, span: 0.6, grow: true),
  );
}

void _crossVent(TemperaComposer c) {
  final double w = c.width, h = c.height;
  final double cx = w * 0.5, cy = h * 0.38;
  final double arm = math.min(w, h) * 0.3, bar = math.min(w, h) * 0.1;
  final List<double> cross = <double>[
    cx - bar,
    cy - arm,
    cx + bar,
    cy - arm,
    cx + bar,
    cy - bar,
    cx + arm,
    cy - bar,
    cx + arm,
    cy + bar,
    cx + bar,
    cy + bar,
    cx + bar,
    cy + arm,
    cx - bar,
    cy + arm,
    cx - bar,
    cy + bar,
    cx - arm,
    cy + bar,
    cx - arm,
    cy - bar,
    cx - bar,
    cy - bar,
  ];
  _addCutField(c, c.palette.tone3, <List<double>>[cross]);
  _addHoleLip(c, cross, 2.6, 0.85, 0.1);
  if (!c.showDecor) return;
  c.add(
    drawRings(
      <TemperaDisc>[TemperaDisc(cx, cy, arm * 1.24)],
      c.palette.tone4,
      1.2,
      0.5,
    ),
    _o(delay: 0.2, span: 0.5),
  );
}

void _louvre(TemperaComposer c) {
  final double w = c.width, h = c.height, b = c.bleed;
  final List<List<double>> holes = <List<double>>[
    for (int i = 0; i < 6; i++)
      () {
        final double y = h * (0.08 + i * 0.1);
        final double lean = h * 0.03;
        final double thickness = h * (0.05 - i * 0.004);
        return <double>[
          -b,
          y,
          w + b,
          y - lean,
          w + b,
          y - lean + thickness,
          -b,
          y + thickness,
        ];
      }(),
  ];
  _addCutField(c, c.palette.tone4, holes);
  c.add(
    drawPolygonFill(
      rectPolygon(w * 0.1, h * 0.72, w * 0.08, h * 0.2),
      c.palette.tone2,
      0.9,
      c.gradient,
    ),
    _o(delay: 0.2, span: 0.55, enterDY: h * 0.1),
  );
}

void _ringEye(TemperaComposer c) {
  final double w = c.width, h = c.height, unit = math.min(w, h);
  final double cx = w * 0.5,
      cy = h * 0.5,
      inner = unit * 0.31,
      outer = unit * 0.44;
  const int segments = 12;
  const double gap = 0.03;
  final List<List<double>> holes = <List<double>>[
    for (int i = 0; i < segments; i++)
      annularSectorPolygon(
        cx,
        cy,
        inner,
        outer,
        (i / segments) * math.pi * 2 + gap,
        ((i + 1) / segments) * math.pi * 2 - gap,
        8,
      ),
  ];
  _addCutField(c, c.palette.tone3, holes);
  c.add(
    drawRings(
      <TemperaDisc>[TemperaDisc(cx, cy, inner), TemperaDisc(cx, cy, outer)],
      c.palette.ink,
      2.4,
      0.85,
    ),
    _o(delay: 0.12, span: 0.5),
  );
}

void _notchStack(TemperaComposer c) {
  final double w = c.width, h = c.height, unit = math.min(w, h);
  final List<List<double>> holes = <List<double>>[
    for (int i = 0; i < 4; i++)
      rectPolygon(
        w * (0.6 + i * 0.06),
        h * (0.1 + i * 0.19),
        unit * (0.26 - i * 0.05),
        unit * (0.26 - i * 0.05),
      ),
  ];
  _addCutField(c, c.palette.tone4, holes);
  for (int i = 0; i < holes.length; i++) {
    _addHoleLip(c, holes[i], 2, 0.75, 0.1 + i * 0.04);
  }
}

void _wedgeGap(TemperaComposer c) {
  final double w = c.width, h = c.height, b = c.bleed;
  final double apexX = w * (0.4 + temperaHash01(c.seed, 3, 137) * 0.2);
  final List<double> wedge = <double>[
    w * 0.1,
    -b,
    w * 0.92,
    -b,
    apexX,
    h * 0.56,
  ];
  _addCutField(c, c.palette.tone3, <List<double>>[wedge]);
  _addHoleLip(c, wedge, 3, 0.9, 0.08);
  c.add(
    drawLines(
      <TemperaLine>[TemperaLine(apexX, h * 0.58, apexX, h + b)],
      c.palette.tone4,
      1.6,
      0.6,
    ),
    _o(delay: 0.18, span: 0.5, enterDY: h * 0.12),
  );
}

void _dotSieve(TemperaComposer c) {
  final double w = c.width, h = c.height, unit = math.min(w, h);
  final List<List<double>> holes = <List<double>>[];
  for (int row = 0; row < 6; row++) {
    for (int col = 0; col < 5; col++) {
      final double density = 1 - col / 4.5;
      if (temperaHash01(c.seed, row * 9 + col, 139) > density) continue;
      final double x = w * (0.06 + col * 0.105) + (row.isEven ? 0 : w * 0.05);
      holes.add(
        circlePolygon(
          x,
          h * (0.1 + row * 0.16),
          unit * 0.045 * density + unit * 0.012,
          18,
        ),
      );
    }
  }
  _addCutField(c, c.palette.tone2, holes, alpha: 0.92);
}

// ---------------------------------------------------------------------------
// 仪表族（signal）
// ---------------------------------------------------------------------------

void _cornerArms(
  TemperaComposer c,
  List<(double, double, double, double)> corners,
  double Function(double sx, double sy) armX,
  double Function(double sx, double sy) armY,
  double width,
  double baseDelay,
  double step,
  double enterScale,
) {
  for (int i = 0; i < corners.length; i++) {
    final (double x, double y, double sx, double sy) = corners[i];
    c.add(
      drawLines(
        <TemperaLine>[
          TemperaLine(x, y, x + armX(sx, sy), y),
          TemperaLine(x, y, x, y + armY(sx, sy)),
        ],
        c.palette.ink,
        width,
        enterScale == 0 ? 0.8 : 0.9,
      ),
      _o(
        delay: baseDelay + i * step,
        span: 0.5,
        enterDX: sx * c.width * enterScale,
      ),
    );
  }
}

void _sightMark(TemperaComposer c) {
  final double w = c.width, h = c.height, b = c.bleed;
  final double cx = w * 0.5, cy = h * 0.5;
  _addField(c, c.palette.tone1);
  c.add(
    drawLines(
      <TemperaLine>[
        TemperaLine(-b, cy, w + b, cy),
        TemperaLine(cx, -b, cx, h + b),
      ],
      c.palette.tone4,
      1.4,
      0.6,
    ),
    _o(delay: 0.04, span: 0.55, enterDX: w * 0.1),
  );
  c.add(
    drawPolygonFill(
      rectPolygon(w * 0.24, h * 0.36, w * 0.52, h * 0.28),
      c.palette.tone3,
      0.94,
      c.gradient,
    ),
    _o(delay: 0.1, span: 0.55, enterDY: h * 0.06),
  );
  c.add(
    drawPolygonOutline(
      rectPolygon(w * 0.2, h * 0.32, w * 0.6, h * 0.36),
      c.palette.ink,
      2.4,
      0.85,
    ),
    _o(delay: 0.16, span: 0.5),
  );
  if (!c.showDecor) return;
  _cornerArms(
    c,
    <(double, double, double, double)>[
      (w * 0.2, h * 0.32, 1, 1),
      (w * 0.8, h * 0.32, -1, 1),
      (w * 0.2, h * 0.68, 1, -1),
      (w * 0.8, h * 0.68, -1, -1),
    ],
    (double sx, double sy) => sx * w * 0.04,
    (double sx, double sy) => sy * h * 0.05,
    3,
    0.2,
    0.03,
    0,
  );
}

void _dialScale(TemperaComposer c) {
  final double w = c.width, h = c.height, unit = math.min(w, h);
  final double cx = w * 0.5, cy = h * 0.5;
  _addField(c, c.palette.tone2);
  c.add(
    drawPolygonFill(
      annularSectorPolygon(
        cx,
        cy,
        unit * 0.34,
        unit * 0.44,
        0,
        math.pi * 2 - 0.006,
        60,
      ),
      c.palette.tone4,
      0.92,
      c.gradient,
    ),
    _o(delay: 0.05, span: 0.6),
  );
  final List<TemperaLine> ticks = <TemperaLine>[
    for (int i = 0; i < 24; i++)
      () {
        final double angle = (i / 24) * math.pi * 2;
        final double inner = unit * (i % 6 == 0 ? 0.46 : 0.475);
        return TemperaLine(
          cx + math.cos(angle) * inner,
          cy + math.sin(angle) * inner,
          cx + math.cos(angle) * unit * 0.5,
          cy + math.sin(angle) * unit * 0.5,
        );
      }(),
  ];
  c.add(drawLines(ticks, c.palette.ink, 1.6, 0.7), _o(delay: 0.14, span: 0.55));
  final double pointer = 0.4 + temperaHash01(c.seed, 5, 149) * 0.5;
  c.add(
    drawPolygonFill(
      temperaAxisRect(
        cx + math.cos(pointer * math.pi * 2) * unit * 0.2,
        cy + math.sin(pointer * math.pi * 2) * unit * 0.2,
        unit * 0.4,
        unit * 0.035,
        pointer * math.pi * 2,
      ),
      c.palette.ink,
      0.9,
    ),
    _o(delay: 0.2, span: 0.5),
  );
}

void _chevronRun(TemperaComposer c) {
  final double w = c.width, h = c.height, b = c.bleed;
  const int focus = 2;
  _addField(c, c.palette.tone1);
  for (int i = 0; i < 5; i++) {
    final double y = h * (0.02 + i * 0.24);
    final double rise = h * 0.12, thickness = h * 0.07;
    final List<double> chevron = <double>[
      -b,
      y,
      w * 0.5,
      y - rise,
      w + b,
      y,
      w + b,
      y + thickness,
      w * 0.5,
      y - rise + thickness,
      -b,
      y + thickness,
    ];
    c.add(
      drawPolygonFill(
        chevron,
        i == focus ? c.palette.tone4 : c.palette.tone3,
        i == focus ? 0.95 : 0.7,
        c.gradient,
      ),
      _o(delay: i * 0.04, span: 0.55, enterDY: -h * 0.12),
    );
  }
}

void _tallyColumn(TemperaComposer c) {
  final double w = c.width, h = c.height;
  final double x = w * 0.82;
  _addField(c, c.palette.tone1);
  c.add(
    drawLines(
      <TemperaLine>[
        for (int i = 0; i < 11; i++)
          TemperaLine(
            x,
            h * (0.1 + i * 0.075),
            x + w * (i % 4 == 0 ? 0.12 : 0.06),
            h * (0.1 + i * 0.075),
          ),
      ],
      c.palette.tone4,
      2.4,
      0.75,
    ),
    _o(delay: 0.06, span: 0.6, enterDX: w * 0.1),
  );
  c.add(
    drawPolygonFill(
      rectPolygon(x - w * 0.02, h * 0.4, w * 0.16, h * 0.12),
      c.palette.tone4,
      0.95,
      c.gradient,
    ),
    _o(delay: 0.16, span: 0.55, enterDX: w * 0.14),
  );
  c.add(
    drawLines(
      <TemperaLine>[TemperaLine(x, h * 0.06, x, h * 0.92)],
      c.palette.ink,
      1.6,
      0.6,
    ),
    _o(delay: 0.2, span: 0.5),
  );
}

void _gridFocus(TemperaComposer c) {
  final double w = c.width, h = c.height;
  final double left = w * 0.08, top = h * 0.12;
  final double cw = (w * 0.84) / 4, ch = (h * 0.76) / 3;
  List<double> cell(int col, int row) =>
      rectPolygon(left + cw * col, top + ch * row, cw, ch);
  _addCutField(c, c.palette.tone2, <List<double>>[cell(0, 0), cell(3, 2)]);
  _addHoleLip(c, cell(0, 0), 2, 0.7, 0.1);
  _addHoleLip(c, cell(3, 2), 2, 0.7, 0.14);
  c.add(
    drawPolygonFill(cell(3, 0), c.palette.tone4, 0.95, c.gradient),
    _o(delay: 0.08, span: 0.55, enterDX: w * 0.08),
  );
  c.add(
    drawLines(
      <TemperaLine>[
        for (int col = 0; col <= 4; col++)
          TemperaLine(left + cw * col, top, left + cw * col, top + ch * 3),
        for (int row = 0; row <= 3; row++)
          TemperaLine(left, top + ch * row, left + cw * 4, top + ch * row),
      ],
      c.palette.tone4,
      1.2,
      0.6,
    ),
    _o(delay: 0.16, span: 0.55),
  );
}

void _axisCaps(TemperaComposer c) {
  final double w = c.width, h = c.height, unit = math.min(w, h);
  final double cx = w * 0.5, cy = h * 0.42;
  final List<double> bar = temperaAxisRect(
    cx,
    cy,
    _flowSpan(c),
    unit * 0.22,
    c.flowAngle,
  );
  final List<double> port = circlePolygon(cx, cy, unit * 0.08, 32);
  _addCutField(c, c.palette.tone1, <List<double>>[port], alpha: 0.92);
  c.add(
    drawPolygonFillWithHoles(
      bar,
      <List<double>>[port],
      c.palette.tone4,
      0.94,
      c.gradient,
    ),
    _o(delay: 0.05, span: 0.6),
  );
  c.add(
    drawRings(
      <TemperaDisc>[TemperaDisc(cx, cy, unit * 0.08)],
      c.palette.ink,
      2.4,
      0.85,
    ),
    _o(delay: 0.12, span: 0.5),
  );
  const List<double> sides = <double>[1, -1];
  for (int i = 0; i < 2; i++) {
    final double distance = unit * 0.46;
    final double capX = cx + math.cos(c.flowAngle) * distance * sides[i];
    final double capY = cy + math.sin(c.flowAngle) * distance * sides[i];
    c.add(
      drawPolygonFill(
        temperaAxisRect(capX, capY, unit * 0.1, unit * 0.34, c.flowAngle),
        c.palette.ink,
        0.85,
      ),
      _o(delay: 0.16 + i * 0.04, span: 0.5),
    );
  }
}

void _strobeSlats(TemperaComposer c) {
  final double w = c.width, h = c.height, b = c.bleed;
  _addField(c, c.palette.tone1);
  const List<double> widths = <double>[
    0.06,
    0.03,
    0.09,
    0.04,
    0.34,
    0.04,
    0.08,
    0.03,
    0.06,
  ];
  double cursor = w * 0.03;
  for (int i = 0; i < widths.length; i++) {
    final double fraction = widths[i];
    final bool wide = fraction > 0.2;
    c.add(
      drawPolygonFill(
        rectPolygon(cursor, -b, w * fraction, h + b * 2),
        wide ? c.palette.tone2 : c.palette.tone4,
        wide ? 0.9 : 0.85,
        c.gradient,
      ),
      _o(delay: i * 0.03, span: 0.55, enterDY: (i.isEven ? 1 : -1) * h * 0.14),
    );
    cursor += w * (fraction + 0.02);
  }
}

void _offsetPlate(TemperaComposer c) {
  final double w = c.width, h = c.height, unit = math.min(w, h);
  final double step = unit * 0.06, holeX = w * 0.72, holeY = h * 0.36;
  final List<double> hole = circlePolygon(holeX, holeY, unit * 0.05, 28);
  _addCutField(c, c.palette.tone1, <List<double>>[hole], alpha: 0.9);
  final List<Color> tones = <Color>[
    c.palette.tone2,
    c.palette.tone3,
    c.palette.tone4,
  ];
  for (int i = 0; i < tones.length; i++) {
    final List<double> plate = rectPolygon(
      w * 0.2 + step * i,
      h * 0.2 + step * i,
      w * 0.5,
      h * 0.5,
    );
    c.add(
      drawPolygonFillWithHoles(
        plate,
        <List<double>>[hole],
        tones[i],
        i == 2 ? 0.95 : 0.8,
        c.gradient,
      ),
      _o(delay: i * 0.06, span: 0.55, enterDX: -step * 2, enterDY: -step),
    );
  }
  c.add(
    drawRings(
      <TemperaDisc>[TemperaDisc(holeX, holeY, unit * 0.05)],
      c.palette.ink,
      2,
      0.8,
    ),
    _o(delay: 0.22, span: 0.5),
  );
}

void _radialComb(TemperaComposer c) {
  final double w = c.width, h = c.height;
  final double hubX = w * 1.06, hubY = h * 1.1;
  final double reach = math.sqrt(w * w + h * h) * 1.3;
  _addField(c, c.palette.tone2);
  c.add(
    drawLines(
      <TemperaLine>[
        for (int i = 0; i < 11; i++)
          TemperaLine(
            hubX,
            hubY,
            hubX + math.cos(math.pi + 0.16 + i * 0.062) * reach,
            hubY + math.sin(math.pi + 0.16 + i * 0.062) * reach,
          ),
      ],
      c.palette.tone4,
      2.6,
      0.8,
    ),
    _o(delay: 0.06, span: 0.6),
  );
  const double start = math.pi + 0.44, end = math.pi + 0.56;
  c.add(
    drawPolygonFill(
      <double>[
        hubX,
        hubY,
        hubX + math.cos(start) * reach,
        hubY + math.sin(start) * reach,
        hubX + math.cos(end) * reach,
        hubY + math.sin(end) * reach,
      ],
      c.palette.tone4,
      0.95,
      c.gradient,
    ),
    _o(delay: 0.14, span: 0.6),
  );
  if (!c.showDecor) return;
  c.add(
    drawHatchFill(
      rectPolygon(w * 0.06, h * 0.08, w * 0.2, h * 0.14),
      temperaHatchSpec(c.seed, 151),
      c.palette.tone4,
      0.4,
    ),
    _o(delay: 0.24, span: 0.6, grow: true),
  );
}

void _bracketTarget(TemperaComposer c) {
  final double w = c.width, h = c.height;
  final List<double> box = rectPolygon(w * 0.28, h * 0.54, w * 0.44, h * 0.34);
  _addCutField(c, c.palette.tone3, <List<double>>[box]);
  _addHoleLip(c, box, 2.4, 0.85, 0.08);
  final double arm = math.min(w, h) * 0.08;
  const List<(double, double, double, double)> corners =
      <(double, double, double, double)>[
        (0.28, 0.54, 1, 1),
        (0.72, 0.54, -1, 1),
        (0.28, 0.88, 1, -1),
        (0.72, 0.88, -1, -1),
      ];
  _cornerArms(
    c,
    <(double, double, double, double)>[
      for (final (double fx, double fy, double sx, double sy) in corners)
        (w * fx + sx * w * 0.03, h * fy + sy * h * 0.04, sx, sy),
    ],
    (double sx, double sy) => sx * arm,
    (double sx, double sy) => sy * arm,
    3.5,
    0.12,
    0.04,
    0.05,
  );
  c.add(
    drawLines(
      <TemperaLine>[TemperaLine(w * 0.1, h * 0.44, w * 0.9, h * 0.44)],
      c.palette.tone4,
      1.6,
      0.6,
    ),
    _o(delay: 0.24, span: 0.5, enterDX: -w * 0.1),
  );
}

// ---------------------------------------------------------------------------
// 通道族（corridor）：通道平行于分镜推移方向，交接时读作一条连续的走廊
// ---------------------------------------------------------------------------

List<double> _channel(TemperaComposer c, double offset, double width) {
  final Offset centre = _acrossPoint(c, offset);
  return temperaAxisRect(
    centre.dx,
    centre.dy,
    _flowSpan(c),
    width,
    temperaChannelAxis(c.flowAngle),
  );
}

void _addRails(
  TemperaComposer c,
  double offset,
  double width, [
  double alpha = 0.55,
]) {
  final double angle = temperaChannelAxis(c.flowAngle);
  final double half = _flowSpan(c) / 2;
  const List<double> sides = <double>[-1, 1];
  for (int i = 0; i < 2; i++) {
    final Offset start = _flowPoint(c, -half, offset + sides[i] * width);
    final Offset end = _flowPoint(c, half, offset + sides[i] * width);
    c.add(
      drawLines(<TemperaLine>[_seg(start, end)], c.palette.tone4, 1.4, alpha),
      _o(
        delay: 0.18 + i * 0.03,
        span: 0.5,
        enterDX: math.cos(angle) * c.width * 0.08,
        enterDY: math.sin(angle) * c.height * 0.08,
      ),
    );
  }
}

void _flowChannel(TemperaComposer c) {
  final double unit = math.min(c.width, c.height);
  final List<double> slot = _channel(c, c.width * 0.26, unit * 0.3);
  _addCutField(c, c.palette.tone3, <List<double>>[slot]);
  _addHoleLip(c, slot, 2.6, 0.85, 0.08);
  _addRails(c, c.width * 0.26, unit * 0.19);
}

void _twinChannel(TemperaComposer c) {
  final double unit = math.min(c.width, c.height);
  final List<List<double>> slots = <List<double>>[
    _channel(c, -c.width * 0.34, unit * 0.16),
    _channel(c, c.width * 0.34, unit * 0.16),
  ];
  _addCutField(c, c.palette.tone4, slots);
  for (int i = 0; i < slots.length; i++) {
    _addHoleLip(c, slots[i], 2.4, 0.8, 0.1 + i * 0.04);
  }
}

void _reedRun(TemperaComposer c) {
  final double unit = math.min(c.width, c.height);
  final List<List<double>> slots = <List<double>>[
    for (final double side in const <double>[-1, 1])
      for (int i = 0; i < 4; i++)
        _channel(c, side * c.width * (0.22 + i * 0.08), unit * 0.035),
  ];
  _addCutField(c, c.palette.tone2, slots, alpha: 0.9);
  _addRails(c, 0, c.width * 0.17, 0.4);
}

void _taperChannel(TemperaComposer c) {
  final double unit = math.min(c.width, c.height);
  final double half = _flowSpan(c) / 2;
  final double wide = unit * 0.24,
      narrow = unit * 0.06,
      offset = c.width * 0.24;
  final List<Offset> corners = <Offset>[
    _flowPoint(c, -half, offset - wide),
    _flowPoint(c, -half, offset + wide),
    _flowPoint(c, half, offset + narrow),
    _flowPoint(c, half, offset - narrow),
  ];
  final List<double> slot = <double>[
    for (final Offset p in corners) ...<double>[p.dx, p.dy],
  ];
  _addCutField(c, c.palette.tone3, <List<double>>[slot]);
  _addHoleLip(c, slot, 2.6, 0.85, 0.08);
}

void _chainPorts(TemperaComposer c) {
  final double unit = math.min(c.width, c.height);
  final double offset = c.width * 0.28, spacing = c.height * 0.26;
  final List<Offset> ports = <Offset>[
    for (final double step in const <double>[-1.5, -0.5, 0.5, 1.5])
      _flowPoint(c, step * spacing, offset),
  ];
  _addCutField(c, c.palette.tone4, <List<double>>[
    for (final Offset p in ports) circlePolygon(p.dx, p.dy, unit * 0.11, 40),
  ]);
  c.add(
    drawRings(
      <TemperaDisc>[
        for (final Offset p in ports) TemperaDisc(p.dx, p.dy, unit * 0.11),
      ],
      c.palette.ink,
      2.4,
      0.85,
    ),
    _o(delay: 0.1, span: 0.55),
  );
  c.add(
    drawLines(
      <TemperaLine>[
        _seg(
          _flowPoint(c, -spacing * 2.4, offset),
          _flowPoint(c, spacing * 2.4, offset),
        ),
      ],
      c.palette.tone2,
      1.6,
      0.6,
    ),
    _o(delay: 0.18, span: 0.5),
  );
}

void _dashChannel(TemperaComposer c) {
  final double unit = math.min(c.width, c.height);
  final double offset = c.width * 0.24, step = c.height * 0.32;
  final double angle = temperaChannelAxis(c.flowAngle);
  final List<List<double>> slots = <List<double>>[
    for (final double i in const <double>[-1.5, -0.5, 0.5, 1.5])
      () {
        final Offset centre = _flowPoint(c, i * step, offset);
        return temperaAxisRect(
          centre.dx,
          centre.dy,
          step * 0.72,
          unit * 0.22,
          angle,
        );
      }(),
  ];
  _addCutField(c, c.palette.tone3, slots);
  for (int i = 0; i < slots.length; i++) {
    _addHoleLip(c, slots[i], 2.2, 0.8, 0.08 + i * 0.03);
  }
}

void _windowRun(TemperaComposer c) {
  final double unit = math.min(c.width, c.height);
  final double offset = c.width * 0.27, step = c.height * 0.36;
  final double angle = temperaChannelAxis(c.flowAngle);
  final List<List<double>> slots = <List<double>>[
    for (final double i in const <double>[-1.5, -0.5, 0.5, 1.5])
      () {
        final Offset centre = _flowPoint(c, i * step, offset);
        final double size = unit * 0.2;
        return rotatePolygon(
          roundedRectPolygon(
            centre.dx - size,
            centre.dy - size * 0.62,
            size * 2,
            size * 1.24,
            size * 0.3,
          ),
          centre.dx,
          centre.dy,
          angle + math.pi / 2,
        );
      }(),
  ];
  _addCutField(c, c.palette.tone4, slots);
  for (int i = 0; i < slots.length; i++) {
    _addHoleLip(c, slots[i], 2.4, 0.85, 0.08 + i * 0.03);
  }
}

void _bridgeSpan(TemperaComposer c) {
  final double w = c.width, h = c.height, unit = math.min(w, h);
  final List<double> slot = _channel(c, 0, unit * 0.62);
  _addCutField(c, c.palette.tone4, <List<double>>[slot]);
  _addHoleLip(c, slot, 2.6, 0.8, 0.08);
  final List<double> band = temperaAxisRect(
    w / 2,
    h / 2,
    _flowSpan(c),
    h * 0.46,
    temperaChannelAxis(c.flowAngle) + math.pi / 2,
  );
  c.add(
    drawPolygonFill(band, c.palette.tone3, 0.95, c.gradient),
    _o(delay: 0.12, span: 0.6, enterDX: -w * 0.16),
  );
  c.add(
    drawPolygonOutline(band, c.palette.ink, 2, 0.7),
    _o(delay: 0.2, span: 0.5, enterDX: w * 0.1),
  );
}

void _braidChannel(TemperaComposer c) {
  final double w = c.width, h = c.height, unit = math.min(w, h);
  final double angle = temperaChannelAxis(c.flowAngle);
  final double pitch = h * 0.42;
  final List<List<double>> slots = <List<double>>[
    for (final double side in const <double>[-1, 1])
      for (int i = -1; i <= 1; i++)
        () {
          final Offset centre = _flowPoint(
            c,
            i * pitch + side * pitch * 0.5,
            side * w * 0.32,
          );
          return temperaAxisRect(
            centre.dx,
            centre.dy,
            pitch * 0.78,
            unit * 0.16,
            angle,
          );
        }(),
  ];
  _addCutField(c, c.palette.tone3, slots);
  for (int i = 0; i < slots.length; i++) {
    _addHoleLip(c, slots[i], 2.2, 0.8, 0.08 + i * 0.025);
  }
}

void _portLadder(TemperaComposer c) {
  final double w = c.width, h = c.height, unit = math.min(w, h);
  final double offset = w * 0.3;
  final List<double> slot = _channel(c, offset, unit * 0.14);
  _addCutField(c, c.palette.tone2, <List<double>>[slot]);
  _addHoleLip(c, slot, 2.2, 0.8, 0.08);
  c.add(
    drawLines(
      <TemperaLine>[
        for (int i = 0; i < 9; i++)
          _seg(
            _flowPoint(c, (i - 4) * h * 0.13, offset - unit * 0.09),
            _flowPoint(
              c,
              (i - 4) * h * 0.13,
              offset - unit * (i % 3 == 0 ? 0.22 : 0.15),
            ),
          ),
      ],
      c.palette.tone4,
      2,
      0.7,
    ),
    _o(delay: 0.14, span: 0.6),
  );
}

// ---------------------------------------------------------------------------
// 巨构族（monolith）
// ---------------------------------------------------------------------------

void _apexMass(TemperaComposer c) {
  final double w = c.width, h = c.height, b = c.bleed;
  final double apexX = w * (0.46 + temperaHash01(c.seed, 3, 227) * 0.12),
      apexY = h * 0.38;
  _addGround(c, c.palette.tone1);
  _addMass(
    c,
    <double>[-b, h + b, apexX, apexY, w + b, h + b],
    c.palette.tone3,
    enterDY: h * 0.1,
  );
  _addFaceRuling(c, <double>[
    apexX,
    apexY,
    w + b,
    h + b,
    apexX + w * 0.24,
    h + b,
  ], 229);
  _addSurveyLines(c, 3);
  if (!c.showDecor) return;
  _addCornerTicks(c);
  _addWireTrace(c, w * 0.12, h * 0.84, math.min(w, h) * 0.09);
}

void _ziggurat(TemperaComposer c) {
  final double w = c.width, h = c.height, b = c.bleed;
  _addGround(c, c.palette.tone1);
  final List<Color> tones = <Color>[
    c.palette.tone4,
    c.palette.tone3,
    c.palette.tone3,
    c.palette.tone2,
  ];
  for (int course = 0; course < 4; course++) {
    final double half = w * (0.44 - course * 0.09);
    final double top = h * (0.9 - course * 0.13) - h * 0.13;
    _addMass(
      c,
      rectPolygon(w / 2 - half, top, half * 2, h * 0.13 + b),
      tones[course],
      delay: 0.04 + course * 0.05,
      enterDY: h * 0.08,
      edgeWidth: 2,
    );
  }
  _addSurveyLines(c, 2);
  if (!c.showDecor) return;
  _addCornerTicks(c);
}

void _slabWall(TemperaComposer c) {
  final double w = c.width, h = c.height, b = c.bleed;
  final double edge = w * 0.36;
  _addGround(c, c.palette.tone1);
  _addMass(
    c,
    rectPolygon(edge, -b, w - edge + b, h + b * 2),
    c.palette.tone3,
    edge: false,
  );
  c.add(
    drawLines(
      <TemperaLine>[TemperaLine(edge, -b, edge, h + b)],
      c.palette.ink,
      3.5,
      0.9,
    ),
    _o(delay: 0.1, span: 0.55, enterDX: w * 0.06),
  );
  _addFaceRuling(c, rectPolygon(w * 0.62, h * 0.1, w * 0.3, h * 0.8), 233);
  _addSurveyLines(c, 3);
  if (!c.showDecor) return;
  _addWireTrace(c, w * 0.16, h * 0.24, math.min(w, h) * 0.08);
}

void _cantilever(TemperaComposer c) {
  final double w = c.width, h = c.height, b = c.bleed;
  _addGround(c, c.palette.tone1);
  _addMass(
    c,
    rectPolygon(0.16 * w, h * 0.5, w * 0.1, h * 0.5 + b),
    c.palette.tone4,
    delay: 0.02,
    enterDY: h * 0.1,
    edge: false,
  );
  _addMass(
    c,
    rectPolygon(-b, h * 0.34, w * 0.78 + b, h * 0.16),
    c.palette.tone3,
    delay: 0.08,
    enterDX: -w * 0.14,
  );
  _addFaceRuling(
    c,
    rectPolygon(w * 0.3, h * 0.36, w * 0.44, h * 0.12),
    239,
    c.palette.paper,
    0.35,
  );
  _addSurveyLines(c, 2);
  if (!c.showDecor) return;
  _addCornerTicks(c);
}

void _pylonPair(TemperaComposer c) {
  final double w = c.width, h = c.height, b = c.bleed;
  final List<double> bay = rectPolygon(
    w * 0.26,
    h * 0.3,
    w * 0.48,
    h * 0.7 + b,
  );
  _addCutField(c, c.palette.tone1, <List<double>>[bay]);
  _addHoleLip(c, bay, 2, 0.6, 0.12);
  const List<double> xs = <double>[0.1, 0.74];
  for (int i = 0; i < 2; i++) {
    _addMass(
      c,
      rectPolygon(w * xs[i], h * 0.28, w * 0.16, h * 0.72 + b),
      c.palette.tone4,
      delay: 0.04 + i * 0.05,
      enterDY: h * 0.08,
      edgeWidth: 2,
    );
  }
  _addMass(
    c,
    rectPolygon(w * 0.04, h * 0.14, w * 0.92, h * 0.16),
    c.palette.tone3,
    delay: 0.14,
    enterDY: -h * 0.1,
  );
  _addSurveyLines(c, 2);
}

void _bunkerSlit(TemperaComposer c) {
  final double w = c.width, h = c.height, b = c.bleed;
  final List<double> slit = rectPolygon(-b, h * 0.62, w + b * 2, h * 0.06);
  _addCutField(c, c.palette.tone1, <List<double>>[slit]);
  c.add(
    drawPolygonFill(
      rectPolygon(-b, h * 0.34, w + b * 2, h * 0.28),
      c.palette.tone4,
      0.95,
      c.gradient,
    ),
    _o(delay: 0.05, span: 0.6, enterDY: -h * 0.08),
  );
  c.add(
    drawPolygonFill(
      rectPolygon(-b, h * 0.68, w + b * 2, h * 0.32 + b),
      c.palette.tone4,
      0.95,
      c.gradient,
    ),
    _o(delay: 0.08, span: 0.6, enterDY: h * 0.1),
  );
  c.add(
    drawLines(
      <TemperaLine>[TemperaLine(-b, h * 0.34, w + b, h * 0.34)],
      c.palette.ink,
      3,
      0.85,
    ),
    _o(delay: 0.14, span: 0.5),
  );
  _addFaceRuling(
    c,
    rectPolygon(w * 0.08, h * 0.72, w * 0.36, h * 0.2),
    241,
    c.palette.paper,
    0.3,
  );
  _addSurveyLines(c, 2);
}

void _plinthStack(TemperaComposer c) {
  final double w = c.width, h = c.height, b = c.bleed;
  _addGround(c, c.palette.tone1);
  _addMass(
    c,
    rectPolygon(w * 0.06, h * 0.72, w * 0.88, h * 0.28 + b),
    c.palette.tone4,
    edgeWidth: 2,
  );
  _addMass(
    c,
    rectPolygon(w * 0.16, h * 0.52, w * 0.68, h * 0.2),
    c.palette.tone3,
    delay: 0.08,
    edgeWidth: 2,
  );
  _addMass(
    c,
    rectPolygon(w * 0.28, h * 0.34, w * 0.44, h * 0.18),
    c.palette.tone2,
    delay: 0.14,
    enterDY: h * 0.06,
  );
  _addFaceRuling(c, rectPolygon(w * 0.2, h * 0.76, w * 0.6, h * 0.16), 243);
  _addSurveyLines(c, 3);
  if (!c.showDecor) return;
  _addCornerTicks(c);
}

void _buttressRun(TemperaComposer c) {
  final double w = c.width, h = c.height, b = c.bleed;
  final List<double> band = rectPolygon(-b, h * 0.42, w + b * 2, h * 0.58 + b);
  _addCutField(c, c.palette.tone1, <List<double>>[band]);
  for (int i = 0; i < 5; i++) {
    final double left = w * (i * 0.2 + 0.01);
    _addMass(
      c,
      <double>[left, h + b, left + w * 0.09, h * 0.42, left + w * 0.17, h + b],
      i.isEven ? c.palette.tone4 : c.palette.tone3,
      delay: 0.04 + i * 0.04,
      enterDY: h * 0.12,
      edgeWidth: 2,
    );
  }
  c.add(
    drawLines(
      <TemperaLine>[TemperaLine(-b, h * 0.42, w + b, h * 0.42)],
      c.palette.ink,
      2.4,
      0.8,
    ),
    _o(delay: 0.2, span: 0.5, enterDX: -w * 0.1),
  );
  _addSurveyLines(c, 2);
}

void _voidCore(TemperaComposer c) {
  final double w = c.width, h = c.height;
  final List<double> core = rectPolygon(w * 0.22, h * 0.34, w * 0.56, h * 0.46);
  _addCutField(c, c.palette.tone3, <List<double>>[core], alpha: 0.95);
  _addHoleLip(c, core, 3.5, 0.9, 0.08);
  _addFaceRuling(
    c,
    rectPolygon(w * 0.04, h * 0.36, w * 0.14, h * 0.42),
    247,
    c.palette.tone4,
    0.45,
  );
  _addSurveyLines(c, 3);
  if (!c.showDecor) return;
  _addCornerTicks(c);
  _addWireTrace(c, w * 0.86, h * 0.86, math.min(w, h) * 0.08);
}

void _shearBlock(TemperaComposer c) {
  final double w = c.width, h = c.height;
  final double left = w * 0.14,
      right = w * 0.86,
      top = h * 0.2,
      bottom = h * 0.8;
  final double cutTop = w * 0.56, cutBottom = w * 0.44;
  _addGround(c, c.palette.tone1);
  _addMass(
    c,
    <double>[left, top, cutTop, top, cutBottom, bottom, left, bottom],
    c.palette.tone3,
    enterDX: -w * 0.08,
    enterDY: -h * 0.03,
    edgeWidth: 2,
  );
  _addMass(
    c,
    <double>[
      cutTop + w * 0.03,
      top + h * 0.04,
      right,
      top + h * 0.04,
      right,
      bottom + h * 0.04,
      cutBottom + w * 0.03,
      bottom + h * 0.04,
    ],
    c.palette.tone4,
    delay: 0.1,
    enterDX: w * 0.08,
    enterDY: h * 0.03,
    edgeWidth: 2,
  );
  _addSurveyLines(c, 2);
  if (!c.showDecor) return;
  c.add(
    drawPolygonOutline(
      rectPolygon(w * 0.1, h * 0.16, w * 0.8, h * 0.68),
      c.palette.paper,
      1.2,
      0.35,
    ),
    _o(delay: 0.28, span: 0.55),
  );
}

// ---------------------------------------------------------------------------
// 地形族（terrain）
// ---------------------------------------------------------------------------

void _ridgeLine(TemperaComposer c) {
  final double w = c.width, h = c.height, b = c.bleed;
  final double lift = temperaHash01(c.seed, 5, 251) * 0.06;
  _addGround(c, c.palette.tone1);
  _addMass(
    c,
    <double>[
      -b,
      h * (0.68 + lift),
      w * 0.34,
      h * (0.4 + lift),
      w * 0.62,
      h * (0.58 + lift),
      w + b,
      h * (0.34 + lift),
      w + b,
      h + b,
      -b,
      h + b,
    ],
    c.palette.tone3,
    enterDY: h * 0.08,
  );
  _addFaceRuling(
    c,
    <double>[
      w * 0.34,
      h * (0.42 + lift),
      w * 0.62,
      h * (0.6 + lift),
      w * 0.62,
      h + b,
      w * 0.34,
      h + b,
    ],
    253,
    c.palette.tone4,
    0.45,
  );
  _addSurveyLines(c, 3);
  if (!c.showDecor) return;
  _addCornerTicks(c);
  _addWireTrace(c, w * 0.1, h * 0.86, math.min(w, h) * 0.08);
}

void _chasm(TemperaComposer c) {
  final double w = c.width, h = c.height, b = c.bleed;
  final List<double> gap = rectPolygon(w * 0.46, -b, w * 0.1, h + b * 2);
  _addCutField(c, c.palette.tone1, <List<double>>[gap]);
  _addMass(
    c,
    rectPolygon(-b, h * 0.3, w * 0.46 + b, h * 0.7 + b),
    c.palette.tone3,
    enterDX: -w * 0.1,
    edgeWidth: 2,
  );
  _addMass(
    c,
    rectPolygon(w * 0.56, h * 0.2, w * 0.44 + b, h * 0.8 + b),
    c.palette.tone4,
    delay: 0.08,
    enterDX: w * 0.1,
    edgeWidth: 2,
  );
  _addSurveyLines(c, 2);
}

void _overhang(TemperaComposer c) {
  final double w = c.width, h = c.height, b = c.bleed;
  _addGround(c, c.palette.tone1);
  _addMass(
    c,
    rectPolygon(-b, -b, w + b * 2, h * 0.34 + b),
    c.palette.tone4,
    enterDY: -h * 0.1,
    edgeWidth: 3,
  );
  _addMass(
    c,
    rectPolygon(w * 0.72, h * 0.34, w * 0.28 + b, h * 0.66 + b),
    c.palette.tone3,
    delay: 0.08,
    enterDX: w * 0.1,
    edge: false,
  );
  c.add(
    drawPolygonFill(
      rectPolygon(-b, h * 0.34, w + b * 2, h * 0.14),
      c.palette.tone2,
      0.5,
      c.gradient,
    ),
    _o(delay: 0.16, span: 0.6),
  );
  _addSurveyLines(c, 3);
  if (!c.showDecor) return;
  _addCornerTicks(c);
}

void _stepWell(TemperaComposer c) {
  final double w = c.width, h = c.height, b = c.bleed;
  final List<double> shaft = rectPolygon(
    w * 0.36,
    h * 0.6,
    w * 0.28,
    h * 0.4 + b,
  );
  _addCutField(c, c.palette.tone2, <List<double>>[shaft]);
  final List<(double, double, double, Color)> steps =
      <(double, double, double, Color)>[
        (0.14, 0.3, 0.72, c.palette.tone3),
        (0.24, 0.44, 0.52, c.palette.tone4),
      ];
  for (int i = 0; i < steps.length; i++) {
    final (double x, double y, double sw, Color tone) = steps[i];
    c.add(
      drawPolygonFillWithHoles(
        rectPolygon(w * x, h * y, w * sw, h * (1 - y) + b),
        <List<double>>[shaft],
        tone,
        0.95,
        c.gradient,
      ),
      _o(delay: 0.06 + i * 0.06, span: 0.6, enterDY: h * 0.06),
    );
  }
  _addHoleLip(c, shaft, 3, 0.85, 0.18);
  _addSurveyLines(c, 2);
}

void _pierRow(TemperaComposer c) {
  final double w = c.width, h = c.height, b = c.bleed;
  final List<double> water = rectPolygon(-b, h * 0.46, w + b * 2, h * 0.54 + b);
  _addCutField(c, c.palette.tone1, <List<double>>[water]);
  const List<double> xs = <double>[0.04, 0.28, 0.52, 0.76];
  for (int i = 0; i < xs.length; i++) {
    _addMass(
      c,
      rectPolygon(w * xs[i], h * 0.46, w * 0.14, h * 0.54 + b),
      c.palette.tone4,
      delay: 0.06 + i * 0.04,
      enterDY: h * 0.1,
      edge: false,
    );
  }
  _addMass(
    c,
    rectPolygon(-b, h * 0.32, w + b * 2, h * 0.16),
    c.palette.tone3,
    delay: 0.02,
    enterDX: -w * 0.12,
    edgeWidth: 2,
  );
  _addSurveyLines(c, 2);
}

void _revetment(TemperaComposer c) {
  final double w = c.width, h = c.height, b = c.bleed;
  _addGround(c, c.palette.tone1);
  _addMass(
    c,
    <double>[
      -b,
      h * 0.72,
      w * 0.62,
      h * 0.3,
      w + b,
      h * 0.34,
      w + b,
      h + b,
      -b,
      h + b,
    ],
    c.palette.tone3,
    enterDY: h * 0.1,
  );
  c.add(
    drawLines(
      <TemperaLine>[
        for (int i = 0; i < 9; i++)
          () {
            final double x = w * (0.04 + i * 0.11);
            final double top = h * (0.72 - (x / (w * 0.62)) * 0.42);
            return TemperaLine(
              x,
              math.max(top, h * 0.3) + h * 0.03,
              x - w * 0.03,
              h + b,
            );
          }(),
      ],
      c.palette.tone4,
      2.4,
      0.5,
    ),
    _o(delay: 0.16, span: 0.65),
  );
  _addSurveyLines(c, 3);
  if (!c.showDecor) return;
  _addCornerTicks(c);
}

void _towerCrop(TemperaComposer c) {
  final double w = c.width, h = c.height, b = c.bleed;
  _addGround(c, c.palette.tone1);
  _addMass(
    c,
    rectPolygon(w * 0.58, h * 0.18, w * 0.42 + b, h * 0.82 + b),
    c.palette.tone4,
    enterDX: w * 0.08,
    enterDY: h * 0.06,
    edgeWidth: 3,
  );
  _addFaceRuling(
    c,
    rectPolygon(w * 0.62, h * 0.26, w * 0.12, h * 0.6),
    257,
    c.palette.paper,
    0.3,
  );
  _addSurveyLines(c, 2);
  if (!c.showDecor) return;
  _addWireTrace(c, w * 0.2, h * 0.7, math.min(w, h) * 0.1);
  _addCornerTicks(c);
}

void _lintel(TemperaComposer c) {
  final double w = c.width, h = c.height, b = c.bleed;
  _addGround(c, c.palette.tone1);
  _addMass(
    c,
    rectPolygon(-b, h * 0.4, w + b * 2, h * 0.2),
    c.palette.tone3,
    enterDX: -w * 0.16,
    edgeWidth: 3,
  );
  const List<double> xs = <double>[0.18, 0.66];
  for (int i = 0; i < 2; i++) {
    _addMass(
      c,
      rectPolygon(w * xs[i], h * 0.6, w * 0.16, h * 0.12),
      c.palette.tone4,
      delay: 0.12 + i * 0.04,
      enterDY: h * 0.06,
      edge: false,
    );
  }
  _addSurveyLines(c, 3);
  if (!c.showDecor) return;
  _addCornerTicks(c);
}

void _rubbleFan(TemperaComposer c) {
  final double w = c.width, h = c.height;
  final double hubX = -w * 0.12, hubY = h * 1.12;
  _addGround(c, c.palette.tone1);
  for (int i = 0; i < 5; i++) {
    final double angle =
        -1.24 + i * 0.19 + temperaHash01(c.seed, i, 259) * 0.05;
    final double reach = math.sqrt(w * w + h * h) * (0.5 + i * 0.09);
    final List<double> slab = rectPolygon(
      hubX + reach * 0.34,
      hubY - h * 0.06,
      reach * 0.5,
      h * 0.12 + i * 8,
    );
    _addMass(
      c,
      rotatePolygon(slab, hubX, hubY, angle),
      i.isEven ? c.palette.tone3 : c.palette.tone4,
      delay: 0.04 + i * 0.05,
      enterDX: -w * 0.06,
      enterDY: h * 0.06,
      edgeWidth: 2,
    );
  }
  _addSurveyLines(c, 2);
}

void _gnomon(TemperaComposer c) {
  final double w = c.width, h = c.height, b = c.bleed;
  _addGround(c, c.palette.tone1);
  c.add(
    drawPolygonFill(
      <double>[
        w * 0.42,
        h * 0.86,
        w + b,
        h * 0.6,
        w + b,
        h * 0.78,
        w * 0.46,
        h * 0.94,
      ],
      c.palette.tone2,
      0.6,
      c.gradient,
    ),
    _o(delay: 0.1, span: 0.65, enterDX: w * 0.1),
  );
  _addMass(
    c,
    <double>[
      w * 0.3,
      h + b,
      w * 0.36,
      h * 0.16,
      w * 0.42,
      h * 0.16,
      w * 0.46,
      h + b,
    ],
    c.palette.tone4,
    enterDY: h * 0.08,
    edgeWidth: 2,
  );
  _addSurveyLines(c, 3);
  if (!c.showDecor) return;
  _addCornerTicks(c);
  _addWireTrace(c, w * 0.8, h * 0.82, math.min(w, h) * 0.08);
}

/// 六族构图：注册进 `temperaCompositions`。
final Map<String, void Function(TemperaComposer)> temperaCutCompositions =
    <String, void Function(TemperaComposer)>{
      'bubble-drift': _bubbleDrift,
      'cloud-window': _cloudWindow,
      'heart-burst': _heartBurst,
      'sparkle-field': _sparkleField,
      'petal-arc': _petalArc,
      'scallop-band': _scallopBand,
      'ribbon-loop': _ribbonLoop,
      'round-plate': _roundPlate,
      'halo-burst': _haloBurst,
      'iris-hole': _irisHole,
      'slot-rail': _slotRail,
      'punch-row': _punchRow,
      'film-gate': _filmGate,
      'cross-vent': _crossVent,
      'louvre-slats': _louvre,
      'ring-eye': _ringEye,
      'notch-stack': _notchStack,
      'wedge-gap': _wedgeGap,
      'dot-sieve': _dotSieve,
      'sight-mark': _sightMark,
      'dial-scale': _dialScale,
      'chevron-run': _chevronRun,
      'tally-column': _tallyColumn,
      'grid-focus': _gridFocus,
      'axis-caps': _axisCaps,
      'strobe-slats': _strobeSlats,
      'offset-plate': _offsetPlate,
      'radial-comb': _radialComb,
      'bracket-target': _bracketTarget,
      'flow-channel': _flowChannel,
      'twin-channel': _twinChannel,
      'reed-run': _reedRun,
      'taper-channel': _taperChannel,
      'chain-ports': _chainPorts,
      'dash-channel': _dashChannel,
      'window-run': _windowRun,
      'bridge-span': _bridgeSpan,
      'braid-channel': _braidChannel,
      'port-ladder': _portLadder,
      'apex-mass': _apexMass,
      'ziggurat': _ziggurat,
      'slab-wall': _slabWall,
      'cantilever': _cantilever,
      'pylon-pair': _pylonPair,
      'bunker-slit': _bunkerSlit,
      'plinth-stack': _plinthStack,
      'buttress-run': _buttressRun,
      'void-core': _voidCore,
      'shear-block': _shearBlock,
      'ridge-line': _ridgeLine,
      'chasm': _chasm,
      'overhang': _overhang,
      'step-well': _stepWell,
      'pier-row': _pierRow,
      'revetment': _revetment,
      'tower-crop': _towerCrop,
      'lintel': _lintel,
      'rubble-fan': _rubbleFan,
      'gnomon': _gnomon,
    };
