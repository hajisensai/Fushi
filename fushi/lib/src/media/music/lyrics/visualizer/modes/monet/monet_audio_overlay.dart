/// 莫奈底部的频谱条（移植 folia `monet/AudioOverlay.tsx`）：72 根柱 / 一条平滑曲线，
/// 中间高两头低（正弦包络）。Fushi 没有实时频谱，五段频带由「歌词节拍」包络合成。
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

/// 柱数。
const int kMonetAudioBarCount = 72;

/// 由节拍包络 [pulse]（0–1）与墙钟 [seconds] 合成五段频带（低 / 中低 / 中 / 人声 / 高），
/// 代替 folia 的 `audioBands`：各段比例不同、各自慢慢起伏，跟着唱词一起冲高回落。
List<double> monetSyntheticBands(double pulse, double seconds) {
  final double p = pulse.clamp(0.0, 1.0);
  return <double>[
    p * (0.86 + 0.1 * math.sin(seconds * 1.3)),
    p * (0.72 + 0.14 * math.sin(seconds * 2.1 + 1)),
    p * (0.66 + 0.16 * math.sin(seconds * 1.7 + 2)),
    p * (0.8 + 0.12 * math.sin(seconds * 2.9 + 3)),
    p * (0.52 + 0.16 * math.sin(seconds * 3.3 + 4)),
  ].map((double v) => v.clamp(0.0, 1.0)).toList();
}

/// folia `sampleSpectrumProfile`：五段频带插成 11 个锚点，按对数刻度取样，再叠一层轮廓。
double monetSpectrumProfile(List<double> bands, double normalizedIndex) {
  final double i = normalizedIndex.clamp(0.0, 1.0);
  final double bass = bands[0];
  final double lowMid = bands[1];
  final double mid = bands[2];
  final double vocal = bands[3];
  final double treble = bands[4];
  final List<double> anchors = <double>[
    bass * 1.08,
    bass * 0.96,
    bass * 0.74 + lowMid * 0.26,
    lowMid,
    lowMid * 0.58 + mid * 0.42,
    mid,
    mid * 0.42 + vocal * 0.58,
    vocal,
    vocal * 0.48 + treble * 0.52,
    treble,
    treble * 0.82,
  ].map((double v) => v.clamp(0.0, 1.0)).toList();
  final double logIndex = math.log(1 + i * 9) / math.ln10;
  final double scaled = logIndex * (anchors.length - 1);
  final int lo = scaled.floor();
  final int hi = math.min(lo + 1, anchors.length - 1);
  final double v = anchors[lo] + (anchors[hi] - anchors[lo]) * (scaled - lo);
  final double contour =
      0.92 +
      math.sin(i * math.pi * 3.4 - math.pi * 0.3) * 0.08 +
      math.sin(i * math.pi * 9.2 + math.pi * 0.2) * 0.035;
  return (v * contour).clamp(0.0, 1.0);
}

/// 一根柱 / 一个曲线点的高度比（0–1，乘以画布高）。[still] 时是 folia 的静态图案。
double monetAudioLevel({
  required int index,
  required bool line,
  required bool still,
  required List<double> bands,
  required double energy,
  required double ms,
}) {
  final double si = index / (kMonetAudioBarCount - 1);
  final double envelope = math.sin(si * math.pi);
  if (still) {
    final double val = 0.12 + (math.sin(index * 0.35) * 0.5 + 0.5) * 0.42;
    return line ? val * envelope : 0.02 + val * 0.8 * envelope;
  }
  final double band = monetSpectrumProfile(bands, si);
  if (line) {
    final double wave =
        math.sin(index * 0.24 + ms * 0.004) * 0.08 +
        math.sin(index * 0.68 + ms * 0.0028) * 0.05;
    return math.max(0, (energy * 0.04 + band * 0.8 + wave * 0.04) * envelope);
  }
  final double pulse = math.sin(index * 0.45 + ms * 0.006) * 0.5 + 0.5;
  return 0.02 + (energy * 0.04 + band * 0.82 + pulse * 0.02) * envelope;
}

/// 频谱画家。
class MonetAudioPainter extends CustomPainter {
  MonetAudioPainter({
    required this.color,
    required this.line,
    required this.still,
    required this.pulse,
    required this.seconds,
  });

  /// 主色（folia `theme.primaryColor`）。
  final Color color;
  final bool line;

  /// 静态图案（减弱动态效果）。
  final bool still;
  final double pulse;
  final double seconds;

  @override
  void paint(Canvas canvas, Size size) {
    final double w = size.width;
    final double h = size.height;
    if (w <= 0 || h <= 0) return;
    final List<double> bands = monetSyntheticBands(pulse, seconds);
    final double energy = math.max(0.08, pulse.clamp(0.0, 1.0));
    final double ms = seconds * 1000;
    final Shader ink = still
        ? ui.Gradient.linear(Offset.zero, Offset(w, 0), <Color>[
            color.withValues(alpha: 0.9),
            color.withValues(alpha: 0.9),
          ])
        : ui.Gradient.linear(
            Offset.zero,
            Offset(w, 0),
            <Color>[
              color.withValues(alpha: 0.72),
              color.withValues(alpha: 0.94),
              color.withValues(alpha: 0.72),
            ],
            <double>[0, 0.5, 1],
          );
    if (line) {
      final List<Offset> pts = <Offset>[
        for (int i = 0; i < kMonetAudioBarCount; i++)
          Offset(
            i / (kMonetAudioBarCount - 1) * w,
            h -
                h *
                    monetAudioLevel(
                      index: i,
                      line: true,
                      still: still,
                      bands: bands,
                      energy: energy,
                      ms: ms,
                    ),
          ),
      ];
      final Path curve = Path()..moveTo(pts.first.dx, pts.first.dy);
      for (int i = 0; i < pts.length - 1; i++) {
        final Offset m = Offset.lerp(pts[i], pts[i + 1], 0.5)!;
        curve.quadraticBezierTo(pts[i].dx, pts[i].dy, m.dx, m.dy);
      }
      curve.lineTo(pts.last.dx, pts.last.dy);
      final Path area = Path.from(curve)
        ..lineTo(w, h)
        ..lineTo(0, h)
        ..close();
      canvas.drawPath(
        area,
        Paint()
          ..shader = ui.Gradient.linear(Offset.zero, Offset(0, h), <Color>[
            color.withValues(alpha: 0.24),
            color.withValues(alpha: 0),
          ]),
      );
      canvas.drawPath(
        curve,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..strokeCap = StrokeCap.round
          ..shader = still ? null : ink
          ..color = color.withValues(alpha: 0.96),
      );
      return;
    }
    final double gap = w / kMonetAudioBarCount;
    final double barW = math.max(1.35, gap * 0.34);
    final Paint fill = Paint()..shader = ink;
    for (int i = 0; i < kMonetAudioBarCount; i++) {
      final double bh =
          h *
          monetAudioLevel(
            index: i,
            line: false,
            still: still,
            bands: bands,
            energy: energy,
            ms: ms,
          );
      canvas.drawRect(
        Rect.fromLTWH(i * gap + gap * 0.14, h - bh, barW, bh),
        fill,
      );
    }
  }

  @override
  bool shouldRepaint(covariant MonetAudioPainter old) =>
      old.color != color ||
      old.line != line ||
      old.still != still ||
      old.pulse != pulse ||
      old.seconds != seconds;
}
