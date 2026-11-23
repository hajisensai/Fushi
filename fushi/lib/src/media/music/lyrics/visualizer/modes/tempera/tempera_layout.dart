/// 凝彩的歌词排版（folia `temperaLayout.ts` + `temperaMeasure.ts`）：按分镜构图的版式区域
/// 把词段排成几行，选一个「主角词」放大，逐字给出落位、入场向量与时序。
///
/// 量宽通过 [TemperaMeasure] 注入：运行时用 TextPainter（带全局缓存），测试可换成假量尺。
library;

import 'dart:math' as math;

import 'package:fushi/src/media/music/lyrics/visualizer/modes/tempera/tempera_motion.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/tempera/tempera_profiles.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/tempera/tempera_program.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/tempera/tempera_random.dart';

/// 量一段文字在某字号下的整体宽度（像素）。
typedef TemperaMeasure = double Function(String text, double fontSize);

/// 一个字的最终落位。
class TemperaGlyphPlacement {
  TemperaGlyphPlacement({
    required this.char,
    required this.lineIndex,
    required this.segmentIndex,
    required this.x,
    required this.y,
    required this.rotation,
    required this.startTime,
    required this.endTime,
    required this.fontSize,
    required this.enterX,
    required this.enterY,
    required this.enterRotation,
    required this.enterScale,
    required this.enterStyle,
  }) : settleTime = endTime;

  final String char;
  final int lineIndex;
  final int segmentIndex;
  final double x;
  final double y;
  final double rotation;
  final double startTime;
  final double endTime;
  final double fontSize;
  final double enterX;
  final double enterY;
  final double enterRotation;
  final double enterScale;
  final TemperaEnterStyle enterStyle;
  double settleTime;
  double releaseTime = 0;
  double trackingX = 0;
  double trackingY = 0;

  TemperaGlyphMotionInput get motion => TemperaGlyphMotionInput(
    startTime: startTime,
    settleTime: settleTime,
    endTime: endTime,
    enterX: enterX,
    enterY: enterY,
    enterRotation: enterRotation,
    enterScale: enterScale,
    rotation: rotation,
    enterStyle: enterStyle,
    releaseTime: releaseTime,
    trackingX: trackingX,
    trackingY: trackingY,
  );
}

class _WordGlyph {
  const _WordGlyph(
    this.char,
    this.startTime,
    this.endTime,
    this.offset,
    this.width,
  );

  final String char;
  final double startTime;
  final double endTime;
  final double offset;
  final double width;
}

class _WordUnit {
  _WordUnit({
    required this.lineIndex,
    required this.segmentIndex,
    required this.scale,
    required this.width,
    required this.glyphs,
  });

  final int lineIndex;
  final int segmentIndex;
  final double scale;
  final double width;
  final List<_WordGlyph> glyphs;
  double leadingGap = 0;
}

class _Row {
  _Row(this.words, this.width);

  final List<_WordUnit> words;
  final double width;
  double height = 0;
}

/// 参与排版的词段（纯空白不排）。
bool temperaIsLayoutSegment(TemperaSegment s) => s.text.trim().isNotEmpty;

double _measureGrapheme(TemperaMeasure measure, String char, double fontSize) =>
    char.trim().isEmpty
    ? fontSize * 0.3
    : math.max(fontSize * 0.08, measure(char, fontSize));

_WordUnit? _buildWordUnit(
  TemperaMeasure measure,
  TemperaSegment segment,
  int lineIndex,
  int segmentIndex,
  double fontSize,
  double scale,
) {
  final List<TemperaGrapheme> glyphs = segment.graphemes
      .where((TemperaGrapheme g) => g.char.isNotEmpty)
      .toList();
  if (glyphs.isEmpty) return null;
  final double size = fontSize * scale;
  final List<double> raw = <double>[
    for (final TemperaGrapheme g in glyphs)
      _measureGrapheme(measure, g.char, size),
  ];
  final double rawTotal = raw.fold(0, (double a, double b) => a + b);
  final String trimmed = segment.text.trimRight();
  final double shaped = trimmed.isEmpty
      ? rawTotal
      : math.max(size * 0.08, measure(trimmed, size));
  final double correction = rawTotal > 0 ? shaped / rawTotal : 1;
  double offset = 0;
  final List<_WordGlyph> placed = <_WordGlyph>[];
  for (int i = 0; i < glyphs.length; i++) {
    final double width = raw[i] * correction;
    placed.add(
      _WordGlyph(
        glyphs[i].char,
        glyphs[i].startTime,
        glyphs[i].endTime,
        offset,
        width,
      ),
    );
    offset += width;
  }
  return _WordUnit(
    lineIndex: lineIndex,
    segmentIndex: segmentIndex,
    scale: scale,
    width: offset,
    glyphs: placed,
  );
}

/// 一行里最长的词（之一）当主角放大，其余缩小（folia `resolveWordScales`）。
List<double> temperaWordScales(
  List<TemperaSegment> segments,
  int seed,
  int lineIndex,
) {
  final List<int> lengths = <int>[
    for (final TemperaSegment s in segments)
      s.isWordLike ? s.graphemes.length : 0,
  ];
  final int maxLength = lengths.fold(0, math.max);
  final List<int> heroCandidates = <int>[
    for (int i = 0; i < lengths.length; i++)
      if (lengths[i] > 0 && lengths[i] >= maxLength - 1) i,
  ];
  final int heroIndex = heroCandidates.isEmpty
      ? -1
      : heroCandidates[(temperaHash01(seed, lineIndex, 101) *
                    heroCandidates.length)
                .floor() %
            heroCandidates.length];
  return <double>[
    for (int i = 0; i < segments.length; i++)
      i == heroIndex
          ? 1.34 + temperaHash01(seed, lineIndex * 31 + i, 103) * 0.26
          : 0.7 + temperaHash01(seed, lineIndex * 31 + i, 107) * 0.16,
  ];
}

List<_WordUnit> _buildWordUnits(
  TemperaMeasure measure,
  List<List<TemperaSegment>> lines,
  double fontSize,
  int seed,
) {
  final List<_WordUnit> out = <_WordUnit>[];
  for (int lineIndex = 0; lineIndex < lines.length; lineIndex++) {
    final List<TemperaSegment> segments = lines[lineIndex];
    final List<double> scales = temperaWordScales(segments, seed, lineIndex);
    int? previousEnd;
    for (int i = 0; i < segments.length; i++) {
      final _WordUnit? unit = _buildWordUnit(
        measure,
        segments[i],
        lineIndex,
        i,
        fontSize,
        scales[i],
      );
      if (unit == null) continue;
      final bool spaced =
          previousEnd != null && segments[i].startOffset > previousEnd;
      unit.leadingGap = previousEnd == null
          ? 0
          : fontSize * (spaced ? 0.26 : 0.035);
      previousEnd = segments[i].endOffset;
      out.add(unit);
    }
  }
  return out;
}

List<_Row> _packRows(List<_WordUnit> words, double maxWidth, int seed) {
  final List<_Row> rows = <_Row>[];
  List<_WordUnit> current = <_WordUnit>[];
  double currentWidth = 0;
  double budgetFor(int row) =>
      maxWidth * (0.72 + temperaHash01(seed, row, 109) * 0.28);
  void flush() {
    if (current.isEmpty) return;
    rows.add(_Row(current, currentWidth));
    current = <_WordUnit>[];
    currentWidth = 0;
  }

  for (final _WordUnit word in words) {
    final bool newLine =
        current.isNotEmpty && word.lineIndex != current.first.lineIndex;
    final double advance = current.isEmpty
        ? word.width
        : word.width + word.leadingGap;
    if (newLine ||
        (current.isNotEmpty &&
            currentWidth + advance > budgetFor(rows.length))) {
      flush();
    }
    currentWidth += current.isEmpty ? word.width : advance;
    current.add(word);
  }
  flush();
  return rows;
}

(double, double) _rotateAbout(
  double x,
  double y,
  double cx,
  double cy,
  double angle,
) {
  if (angle == 0) return (x, y);
  final double c = math.cos(angle), s = math.sin(angle);
  final double dx = x - cx, dy = y - cy;
  return (cx + dx * c - dy * s, cy + dx * s + dy * c);
}

const double _minSettleSeconds = 0.34;

void _applyGlyphTiming(
  List<TemperaGlyphPlacement> placements,
  double settleStretch,
) {
  if (placements.isEmpty) return;
  final double stretch = settleStretch.isFinite
      ? settleStretch.clamp(0.0, 1.0)
      : 0.5;
  final Map<int, double> lineEnds = <int, double>{};
  final Map<int, double> lineStarts = <int, double>{};
  double shotLyricEnd = 0;
  for (final TemperaGlyphPlacement p in placements) {
    lineEnds[p.lineIndex] = math.max(lineEnds[p.lineIndex] ?? 0, p.endTime);
    lineStarts[p.lineIndex] = math.min(
      lineStarts[p.lineIndex] ?? double.infinity,
      p.startTime,
    );
    shotLyricEnd = math.max(shotLyricEnd, p.endTime);
  }
  double sumX = 0, sumY = 0;
  for (final TemperaGlyphPlacement p in placements) {
    final double reach = math.max(
      0,
      shotLyricEnd - p.startTime - _minSettleSeconds,
    );
    p.settleTime = p.startTime + _minSettleSeconds + reach * stretch;
    sumX += p.x;
    sumY += p.y;
  }
  final double cx = sumX / placements.length, cy = sumY / placements.length;
  for (final TemperaGlyphPlacement p in placements) {
    final double span = math.max(
      0.5,
      (lineEnds[p.lineIndex] ?? p.endTime) -
          (lineStarts[p.lineIndex] ?? p.startTime),
    );
    p.releaseTime = math.max(p.endTime, p.settleTime) + span;
    p.trackingX = p.x - cx;
    p.trackingY = p.y - cy;
  }
}

/// 排一个分镜的字（folia `resolveTemperaLayout`）。[lines] 是各切片的可排词段。
List<TemperaGlyphPlacement> resolveTemperaLayout({
  required List<List<TemperaSegment>> lines,
  required String shotKind,
  required double width,
  required double height,
  required double baseFontSize,
  required int seed,
  required TemperaMeasure measure,
  double settleStretch = 0.5,
}) {
  final TemperaShotProfile profile = temperaShotProfile(shotKind);
  final TemperaShotRegion r = profile.region;
  final double regionX = r.cx * width, regionY = r.cy * height;
  final double regionW = r.w * width, regionH = r.h * height;
  double fontSize = math.max(14, baseFontSize * r.fontScale);
  List<_Row> rows = <_Row>[];
  double blockHeight = 0;
  for (int attempt = 0; attempt < 4; attempt++) {
    rows = _packRows(
      _buildWordUnits(measure, lines, fontSize, seed),
      regionW,
      seed,
    );
    for (int i = 0; i < rows.length; i++) {
      final double tallest = rows[i].words.fold(
        0,
        (double m, _WordUnit w) => math.max(m, w.scale),
      );
      rows[i].height =
          fontSize * tallest * (1.02 + temperaHash01(seed, i, 113) * 0.1);
    }
    blockHeight = rows.fold(0, (double s, _Row row) => s + row.height);
    final double maxRowWidth = rows.fold(
      1,
      (double m, _Row row) => math.max(m, row.width),
    );
    final double fit = math.min(
      1,
      math.min(
        blockHeight > regionH ? regionH / blockHeight : 1,
        maxRowWidth > regionW ? regionW / maxRowWidth : 1,
      ),
    );
    if (fit >= 0.999) break;
    fontSize *= fit;
  }
  final double baseX = profile.enterX * fontSize,
      baseY = profile.enterY * fontSize;
  final double baseAngle = math.atan2(baseY, baseX);
  final double baseMagnitude = math.sqrt(baseX * baseX + baseY * baseY);
  final List<TemperaGlyphPlacement> placements = <TemperaGlyphPlacement>[];
  const List<TemperaEnterStyle> styles = TemperaEnterStyle.values;
  double cursorY = regionY - blockHeight / 2;
  for (int rowIndex = 0; rowIndex < rows.length; rowIndex++) {
    final _Row row = rows[rowIndex];
    final double rowCenterY = cursorY + row.height / 2;
    cursorY += row.height;
    final double drift =
        (temperaHash01(seed, rowIndex, 127) - 0.5) * regionW * 0.06;
    final double rowRotation =
        (temperaHash01(seed, rowIndex, 131) - 0.5) * 0.06;
    final double rowLeft = switch (r.align) {
      TemperaAlign.center => regionX - row.width / 2 + drift,
      TemperaAlign.left => regionX - regionW / 2 + drift.abs() * 0.6,
      TemperaAlign.right =>
        regionX + regionW / 2 - row.width - drift.abs() * 0.6,
    };
    final double rowCenterX = rowLeft + row.width / 2;
    double cursorX = rowLeft;
    for (int wordIndex = 0; wordIndex < row.words.length; wordIndex++) {
      final _WordUnit word = row.words[wordIndex];
      final int salt = rowIndex * 37 + wordIndex;
      final TemperaEnterStyle style =
          styles[(temperaHash01(seed, salt, 193) * styles.length).floor() %
              styles.length];
      final double wordRotation = (temperaHash01(seed, salt, 137) - 0.5) * 0.07;
      final double wordShiftY =
          (temperaHash01(seed, salt, 139) - 0.5) * fontSize * 0.09;
      final double wordLeft = cursorX + (wordIndex == 0 ? 0 : word.leadingGap);
      cursorX = wordLeft + word.width;
      final double wordCenterX = wordLeft + word.width / 2;
      final double wordCenterY = rowCenterY + wordShiftY;
      final double glyphSize = fontSize * word.scale;
      for (int gi = 0; gi < word.glyphs.length; gi++) {
        final _WordGlyph glyph = word.glyphs[gi];
        if (glyph.char.trim().isEmpty) continue;
        final double localX = wordLeft + glyph.offset + glyph.width / 2;
        final (double wx, double wy) = _rotateAbout(
          localX,
          wordCenterY,
          wordCenterX,
          wordCenterY,
          wordRotation,
        );
        final (double rx, double ry) = _rotateAbout(
          wx,
          wy,
          rowCenterX,
          rowCenterY,
          rowRotation,
        );
        final (double fx, double fy) = _rotateAbout(
          rx,
          ry,
          regionX,
          regionY,
          r.rotation,
        );
        final int glyphSalt = salt * 53 + gi;
        final double spread = (temperaHash01(seed, glyphSalt, 149) - 0.5) * 1.7;
        final double magnitude =
            baseMagnitude * (0.55 + temperaHash01(seed, glyphSalt, 151) * 1.05);
        final double angle = baseAngle + spread;
        placements.add(
          TemperaGlyphPlacement(
            char: glyph.char,
            lineIndex: word.lineIndex,
            segmentIndex: word.segmentIndex,
            x: fx,
            y: fy,
            rotation: r.rotation + rowRotation + wordRotation,
            startTime: glyph.startTime,
            endTime: glyph.endTime,
            fontSize: glyphSize,
            enterX: math.cos(angle) * magnitude,
            enterY: math.sin(angle) * magnitude,
            enterRotation: (temperaHash01(seed, glyphSalt, 157) - 0.5) * 0.7,
            enterScale: 0.6 + temperaHash01(seed, glyphSalt, 163) * 0.3,
            enterStyle: style,
          ),
        );
      }
    }
  }
  _applyGlyphTiming(placements, settleStretch);
  return placements;
}
