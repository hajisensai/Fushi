/// 时计弧上每一句的排版与逐字扫光（folia `PendoloActiveLyricSweep.tsx`、
/// `pendoloTextLayout.ts`、`pendoloSubtitleTracks.ts`）。TextPainter 按
/// 「句下标 + 焦点 + 宽度 + 字号」缓存，逐帧只算扫光位置。
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_runtime.dart';

/// 焦点句 / 其他句的字号（px，乘字号倍数前）。
const double kPendoloFocalFontPx = 28;
const double kPendoloIdleFontPx = 22;

/// 译文行字号（焦点 / 其他）、与歌词的间距（em）、行高比。
const double kPendoloFocalSubtitlePx = 16;
const double kPendoloIdleSubtitlePx = 12;
const double kPendoloSubtitleGapEm = 0.25;
const double kPendoloSubtitleLineHeight = 1.5;

/// 一行里横向排开的一个字形（扫光用）。
class PendoloSweepGlyph {
  const PendoloSweepGlyph({
    required this.left,
    required this.right,
    required this.startMs,
    required this.endMs,
  });

  final double left;
  final double right;
  final int startMs;
  final int endMs;
}

/// 换行后的一行。
class PendoloSweepRow {
  const PendoloSweepRow({
    required this.left,
    required this.right,
    required this.top,
    required this.bottom,
    required this.glyphs,
  });

  final double left;
  final double right;
  final double top;
  final double bottom;
  final List<PendoloSweepGlyph> glyphs;
}

/// 这一行此刻擦亮到的横坐标（folia `PendoloSweepLine` 的 fillWidth）：第一个字起唱前
/// 返回 null（整行不亮）；字内按进度线性推进；唱完是行尾。
double? pendoloSweepEdge(PendoloSweepRow row, int timeMs, int lineEndMs) {
  final List<PendoloSweepGlyph> g = row.glyphs;
  if (g.isEmpty) return timeMs >= lineEndMs ? row.right : null;
  if (timeMs < g.first.startMs) return null;
  for (final PendoloSweepGlyph glyph in g) {
    if (timeMs < glyph.startMs) return glyph.left;
    if (timeMs <= glyph.endMs) {
      final double span = math.max(1, glyph.endMs - glyph.startMs).toDouble();
      return glyph.left +
          (glyph.right - glyph.left) * ((timeMs - glyph.startMs) / span);
    }
  }
  return row.right;
}

/// 句子在块里的对齐：普通靠左（锚点在左端）、镜像靠右、轮心视角居中。
enum PendoloAlign { left, right, center }

TextAlign _textAlign(PendoloAlign a) => switch (a) {
  PendoloAlign.left => TextAlign.left,
  PendoloAlign.right => TextAlign.right,
  PendoloAlign.center => TextAlign.center,
};

double _alignX(PendoloAlign a, double blockWidth, double width) => switch (a) {
  PendoloAlign.left => 0,
  PendoloAlign.right => blockWidth - width,
  PendoloAlign.center => (blockWidth - width) / 2,
};

/// 一句排好的块：主歌词（焦点句带扫光层）+ 译文 / 罗马音行。
class PendoloLineBlock {
  PendoloLineBlock._({
    required this.main,
    required this.fill,
    required this.subtitles,
    required this.subtitleGaps,
    required this.rows,
    required this.align,
    required this.lineEndMs,
    required this.fontPx,
  }) {
    double w = main.width;
    for (final TextPainter s in subtitles) {
      w = math.max(w, s.width);
    }
    width = w;
    double h = main.height;
    for (int i = 0; i < subtitles.length; i++) {
      h += subtitleGaps[i] + subtitles[i].height;
    }
    height = h;
  }

  /// 排一句。[focal] 决定字号与是否带扫光；[maxWidth] 是块的最大宽度。
  factory PendoloLineBlock.build({
    required LyricVisualizerLine line,
    required bool focal,
    required double fontScale,
    required double maxWidth,
    required PendoloAlign align,
    required Color primary,
    required Color fillColor,
    required Color secondary,
  }) {
    final double fontPx =
        (focal ? kPendoloFocalFontPx : kPendoloIdleFontPx) * fontScale;
    final TextAlign ta = _textAlign(align);
    // 字形时间线按未裁剪的音节拼接；排版用去掉首尾空白的文本，两者按偏移对齐。
    final String raw = line.glyphs
        .map((LyricVisualizerGlyph g) => g.text)
        .join();
    final String body = raw.isEmpty ? line.text : raw;
    final int lead = body.length - body.trimLeft().length;
    final String text = body.trim().isEmpty ? line.text : body.trim();
    final TextStyle style = TextStyle(
      fontSize: fontPx,
      height: 1.2,
      letterSpacing: fontPx * 0.01,
    );
    TextPainter painter(Color color) => TextPainter(
      text: TextSpan(
        text: text,
        style: style.copyWith(color: color),
      ),
      textAlign: ta,
      textDirection: TextDirection.ltr,
      textWidthBasis: TextWidthBasis.longestLine,
    )..layout(maxWidth: math.max(1, maxWidth));

    final TextPainter main = painter(
      focal
          ? primary.withValues(alpha: 0.52 * primary.a)
          : primary.withValues(alpha: 0.75 * primary.a),
    );
    TextPainter? fill;
    List<PendoloSweepRow> rows = const <PendoloSweepRow>[];
    if (focal) {
      fill = painter(fillColor);
      rows = _buildRows(fill, line, lead, text.length);
    }

    final List<TextPainter> subs = <TextPainter>[];
    final List<double> gaps = <double>[];
    final String? sub = _subtitleOf(line);
    if (sub != null) {
      final double px =
          ((focal ? kPendoloFocalSubtitlePx : kPendoloIdleSubtitlePx) *
                  fontScale)
              .roundToDouble();
      subs.add(
        TextPainter(
          text: TextSpan(
            text: sub,
            style: TextStyle(
              fontSize: px,
              height: kPendoloSubtitleLineHeight,
              fontWeight: FontWeight.w500,
              letterSpacing: px * 0.01,
              color: focal
                  ? secondary
                  : secondary.withValues(alpha: secondary.a * 0.6),
            ),
          ),
          textAlign: ta,
          textDirection: TextDirection.ltr,
          textWidthBasis: TextWidthBasis.longestLine,
        )..layout(maxWidth: math.max(1, maxWidth)),
      );
      gaps.add(px * kPendoloSubtitleGapEm);
    }
    return PendoloLineBlock._(
      main: main,
      fill: fill,
      subtitles: subs,
      subtitleGaps: gaps,
      rows: rows,
      align: align,
      lineEndMs: line.endMs,
      fontPx: fontPx,
    );
  }

  final TextPainter main;
  final TextPainter? fill;
  final List<TextPainter> subtitles;
  final List<double> subtitleGaps;
  final List<PendoloSweepRow> rows;
  final PendoloAlign align;
  final int lineEndMs;
  final double fontPx;
  late final double width;
  late final double height;

  /// 画在 [origin]（块左上角）；[opacity] 乘在整块上。
  void paint(Canvas canvas, Offset origin, double opacity, int timeMs) {
    if (opacity <= 0.003) return;
    final Rect bounds = (origin & Size(width, height)).inflate(fontPx);
    final bool layered = opacity < 0.999;
    if (layered) {
      canvas.saveLayer(
        bounds,
        Paint()..color = Color.fromRGBO(0, 0, 0, opacity.clamp(0.0, 1.0)),
      );
    }
    final Offset mainAt = origin.translate(
      _alignX(align, width, main.width),
      0,
    );
    main.paint(canvas, mainAt);
    final TextPainter? f = fill;
    if (f != null) _paintSweep(canvas, f, mainAt, timeMs);
    double y = origin.dy + main.height;
    for (int i = 0; i < subtitles.length; i++) {
      y += subtitleGaps[i];
      final TextPainter s = subtitles[i];
      s.paint(canvas, Offset(origin.dx + _alignX(align, width, s.width), y));
      y += s.height;
    }
    if (layered) canvas.restore();
  }

  void _paintSweep(Canvas canvas, TextPainter f, Offset at, int timeMs) {
    final List<double?> edges = <double?>[
      for (final PendoloSweepRow row in rows)
        pendoloSweepEdge(row, timeMs, lineEndMs),
    ];
    if (edges.every((double? e) => e == null)) return;
    final double soft = (fontPx * 0.42).clamp(8.0, 16.0);
    final Rect area = (at & Size(f.width, f.height)).inflate(fontPx);
    canvas.saveLayer(area, Paint());
    f.paint(canvas, at);
    final Paint mask = Paint()..blendMode = BlendMode.dstIn;
    for (int i = 0; i < rows.length; i++) {
      final PendoloSweepRow row = rows[i];
      final double top = i == 0 ? area.top : at.dy + row.top;
      final double bottom = i == rows.length - 1
          ? area.bottom
          : at.dy + row.bottom;
      final Rect band = Rect.fromLTRB(area.left, top, area.right, bottom);
      final double? e = edges[i];
      if (e == null) {
        mask.shader = null;
        mask.color = const Color(0x00000000);
        canvas.drawRect(band, mask);
        continue;
      }
      final double edge = at.dx + e;
      final double start = math.max(edge - soft, area.left);
      final double end = edge + soft;
      final double span = math.max(1, end - area.left).toDouble();
      mask
        ..color = const Color(0xFF000000)
        ..shader = ui.Gradient.linear(
          Offset(area.left, 0),
          Offset(end, 0),
          const <Color>[
            Color(0xFF000000),
            Color(0xFF000000),
            Color(0xD6000000),
            Color(0x00000000),
          ],
          <double>[
            0,
            ((start - area.left) / span).clamp(0.0, 1.0),
            ((edge - area.left) / span).clamp(0.0, 1.0),
            1,
          ],
        );
      canvas.drawRect(band, mask);
    }
    canvas.restore();
  }

  void dispose() {
    main.dispose();
    fill?.dispose();
    for (final TextPainter s in subtitles) {
      s.dispose();
    }
  }
}

/// 首选译文，没有就用罗马音；只剩符号（"//"、"●●●"）的不显示。
String? _subtitleOf(LyricVisualizerLine line) {
  final RegExp readable = RegExp(r'[\p{L}\p{N}]', unicode: true);
  for (final String? s in <String?>[line.translation, line.romanization]) {
    if (s != null && s.trim().isNotEmpty && readable.hasMatch(s)) {
      return s.trim();
    }
  }
  return null;
}

/// 按字形取排版后的位置，分到各行。
List<PendoloSweepRow> _buildRows(
  TextPainter p,
  LyricVisualizerLine line,
  int lead,
  int textLength,
) {
  final List<ui.LineMetrics> metrics = p.computeLineMetrics();
  if (metrics.isEmpty) return const <PendoloSweepRow>[];
  final List<List<PendoloSweepGlyph>> perRow = <List<PendoloSweepGlyph>>[
    for (int i = 0; i < metrics.length; i++) <PendoloSweepGlyph>[],
  ];
  int offset = -lead;
  for (final LyricVisualizerGlyph g in line.glyphs) {
    final int s = offset;
    final int e = offset + g.text.length;
    offset = e;
    if (s < 0 || e > textLength || g.isSpace) continue;
    final List<TextBox> boxes = p.getBoxesForSelection(
      TextSelection(baseOffset: s, extentOffset: e),
    );
    if (boxes.isEmpty) continue;
    final TextBox b = boxes.first;
    final double cy = (b.top + b.bottom) / 2;
    int row = metrics.length - 1;
    for (int i = 0; i < metrics.length; i++) {
      final ui.LineMetrics m = metrics[i];
      if (cy <= m.baseline + m.descent) {
        row = i;
        break;
      }
    }
    perRow[row].add(
      PendoloSweepGlyph(
        left: b.left,
        right: b.right,
        startMs: g.startMs,
        endMs: g.endMs,
      ),
    );
  }
  return <PendoloSweepRow>[
    for (int i = 0; i < metrics.length; i++)
      PendoloSweepRow(
        left: metrics[i].left,
        right: metrics[i].left + metrics[i].width,
        top: metrics[i].baseline - metrics[i].ascent,
        bottom: metrics[i].baseline + metrics[i].descent,
        glyphs: perRow[i],
      ),
  ];
}

/// 一句在焦点状态下占的高度（folia `lineBlockHeights`：主歌词 + 焦点字号的译文，
/// 再乘焦点放大），弧上间距按它留够，放大后不和邻句叠在一起。
double pendoloFocalBlockHeight(
  LyricVisualizerLine line, {
  required double fontScale,
  required double measureWidth,
  required double activeScale,
}) {
  final double fontPx = kPendoloFocalFontPx * fontScale;
  final TextPainter p = TextPainter(
    text: TextSpan(
      text: line.text,
      style: TextStyle(fontSize: fontPx, height: 1.2),
    ),
    textDirection: TextDirection.ltr,
  )..layout(maxWidth: math.max(1, measureWidth));
  double h = p.height;
  p.dispose();
  final String? sub = _subtitleOf(line);
  if (sub != null) {
    final double px = (kPendoloFocalSubtitlePx * fontScale).roundToDouble();
    final TextPainter s = TextPainter(
      text: TextSpan(
        text: sub,
        style: TextStyle(
          fontSize: px,
          height: kPendoloSubtitleLineHeight,
          fontWeight: FontWeight.w500,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: math.max(1, measureWidth));
    h += s.height + px * kPendoloSubtitleGapEm;
    s.dispose();
  }
  return h * activeScale;
}
