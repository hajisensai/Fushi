/// 隐喻的配色（纯函数，移植 folia `metaphor/metaphorPalette.ts`）：配色 → 纸、墨、强调色、网点。
/// 纸是背景色，墨是字色（「画面反相」开着时两个对调）；网点用次色，和纸太接近时往墨那边拉；
/// 强调色和纸分不开时同样处理，和墨分不开时换成一档灰。
library;

import 'dart:math' as math;
import 'dart:ui' show Color;

import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';

class MetaphorPalette {
  const MetaphorPalette({
    required this.paper,
    required this.ink,
    required this.accent,
    required this.tone,
  });

  final Color paper;
  final Color ink;
  final Color accent;
  final Color tone;
}

double _luma(Color c) => 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b;

Color _mix(Color a, Color b, double t) => Color.from(
  alpha: 1,
  red: a.r + (b.r - a.r) * t,
  green: a.g + (b.g - a.g) * t,
  blue: a.b + (b.b - a.b) * t,
);

double _distance(Color a, Color b) {
  final double dr = a.r - b.r;
  final double dg = a.g - b.g;
  final double db = a.b - b.b;
  return math.sqrt(dr * dr + dg * dg + db * db);
}

Color _opaque(Color c) => Color.from(alpha: 1, red: c.r, green: c.g, blue: c.b);

/// 往墨那边拉，直到和纸拉开 min 这么远（最多拉到七成）。
Color _awayFromPaper(Color color, Color paper, Color ink, double min) {
  Color out = color;
  for (
    double amount = 0.2;
    _distance(out, paper) < min && amount <= 0.7 + 1e-9;
    amount += 0.1
  ) {
    out = _mix(color, ink, amount);
  }
  return out;
}

/// 主题配色 → 隐喻的四个颜色。
MetaphorPalette resolveMetaphorPalette(
  LyricVisualizerPalette palette, {
  bool flip = false,
}) {
  Color paper = _opaque(palette.background);
  Color ink = _opaque(palette.text);
  // 字色和背景分不开（坏主题）：墨换成纸的反面
  if ((_luma(ink) - _luma(paper)).abs() < 0.18) {
    ink = _luma(paper) > 0.5
        ? const Color.from(alpha: 1, red: 0.08, green: 0.08, blue: 0.09)
        : const Color.from(alpha: 1, red: 0.95, green: 0.94, blue: 0.9);
  }
  if (flip) {
    final Color t = paper;
    paper = ink;
    ink = t;
  }
  final Color tone = _awayFromPaper(
    _opaque(palette.secondary),
    paper,
    ink,
    0.22,
  );
  Color accent = _awayFromPaper(_opaque(palette.accent), paper, ink, 0.25);
  // 强调色和墨是同一个颜色：压在字上的融球会和字糊成一片，换成纸墨之间的一档灰
  if (_distance(accent, ink) < 0.25) accent = _mix(paper, ink, 0.42);
  return MetaphorPalette(paper: paper, ink: ink, accent: accent, tone: tone);
}
