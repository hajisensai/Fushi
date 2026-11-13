// 原始 OCR 字框：只验证字符覆盖或按行几何分格，不修改识别文本。
import 'dart:math' as math;

import 'package:characters/characters.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';

/// 一行原始或由调用方明确变换后的文本及其 UTF-16 起点。
typedef OcrTextLine = ({int start, String text});

/// 返回以 `block.lines.join()` 为偏移基准的字框，不断词、不补空格。
List<MangaOcrTextRegion> ocrTextRegions(MokuroBlock block) {
  final List<MangaOcrTextRegion>? supplied = block.regions;
  if (supplied != null &&
      supplied.isNotEmpty &&
      ocrTextRegionsMatchSentence(supplied, block.lines.join())) {
    return supplied;
  }
  int start = 0;
  final List<OcrTextLine> lines = <OcrTextLine>[];
  for (final String text in block.lines) {
    lines.add((start: start, text: text));
    start += text.length;
  }
  return ocrGeometryTextRegions(block, lines);
}

/// Whether [regions] can stand for [sentence] character by character.
///
/// Each region must be a non-empty UTF-16 range on grapheme boundaries inside
/// the sentence, and together they must cover every non-whitespace grapheme.
/// A single miss makes the whole set unusable: the caller then re-derives
/// regions from line geometry instead of keeping a partial set.
bool ocrTextRegionsMatchSentence(
  List<MangaOcrTextRegion> regions,
  String sentence,
) {
  final Set<int> boundaries = <int>{0};
  final List<({int start, int end})> visible = <({int start, int end})>[];
  int offset = 0;
  for (final String grapheme in sentence.characters) {
    final int end = offset + grapheme.length;
    if (grapheme.trim().isNotEmpty) visible.add((start: offset, end: end));
    boundaries.add(end);
    offset = end;
  }
  final List<bool> covered = List<bool>.filled(sentence.length, false);
  for (final MangaOcrTextRegion region in regions) {
    final int start = region.utf16Start;
    final int end = region.utf16End;
    if (start < 0 || end <= start || end > sentence.length) return false;
    if (!boundaries.contains(start) || !boundaries.contains(end)) return false;
    covered.fillRange(start, end, true);
  }
  return visible.every((({int start, int end}) g) => covered[g.start]);
}

/// Character regions derived from `lines_coords` (or the block rectangle).
List<MangaOcrTextRegion> ocrGeometryTextRegions(
  MokuroBlock block,
  List<OcrTextLine> lines,
) {
  if (block.lines.isEmpty || block.rectangle.isEmpty) {
    return const <MangaOcrTextRegion>[];
  }
  final List<MokuroOrientedRect> lineRects = _ocrLineRects(block);
  final List<MangaOcrTextRegion> result = <MangaOcrTextRegion>[];
  for (int lineIndex = 0; lineIndex < lines.length; lineIndex++) {
    final OcrTextLine effectiveLine = lines[lineIndex];
    final List<({String text, int start, int end})> characters =
        <({String text, int start, int end})>[];
    int offset = effectiveLine.start;
    for (final String character in effectiveLine.text.characters) {
      final int end = offset + character.length;
      if (character.trim().isNotEmpty) {
        characters.add((text: character, start: offset, end: end));
      }
      offset = end;
    }
    if (characters.isNotEmpty) {
      final MokuroOrientedRect line = lineRects[lineIndex];
      final MokuroRect lineRect = line.unrotated;
      for (int index = 0; index < characters.length; index++) {
        // 先在摆正的行里均分字格，再把字格中心转回行的倾角：斜行上的字格
        // 沿着斜线排，而不是在外接框里横平竖直地铺。
        final MokuroRect upright = block.isVertical
            ? MokuroRect.fromLTWH(
                lineRect.left,
                lineRect.top + index * lineRect.height / characters.length,
                lineRect.width,
                lineRect.height / characters.length,
              )
            : MokuroRect.fromLTWH(
                lineRect.left + index * lineRect.width / characters.length,
                lineRect.top,
                lineRect.width / characters.length,
                lineRect.height,
              );
        final MokuroRect characterRect;
        if (line.rotation == 0) {
          characterRect = upright;
        } else {
          final MokuroPoint center = line.toPage(
            upright.center.dx - line.center.dx,
            upright.center.dy - line.center.dy,
          );
          characterRect = MokuroRect.fromLTWH(
            center.dx - upright.width / 2,
            center.dy - upright.height / 2,
            upright.width,
            upright.height,
          );
        }
        result.add(
          MangaOcrTextRegion(
            rectangle: characterRect,
            utf16Start: characters[index].start,
            utf16End: characters[index].end,
            rotation: line.rotation,
          ),
        );
      }
    }
  }
  return result;
}

/// 每行的几何：`lines_coords` 齐全时逐行取，四点矩形保留旋转
/// （[mokuroOrientedRectFromQuad]），其它多边形取外接框；否则按块均分。
List<MokuroOrientedRect> _ocrLineRects(MokuroBlock block) {
  final List<List<List<double>>>? coordinates = block.linesCoords;
  if (coordinates != null && coordinates.length == block.lines.length) {
    final List<MokuroOrientedRect> parsed = <MokuroOrientedRect>[];
    for (final List<List<double>> polygon in coordinates) {
      if (polygon.isEmpty ||
          polygon.any((List<double> point) => point.length < 2)) {
        parsed.clear();
        break;
      }
      double left = double.infinity;
      double top = double.infinity;
      double right = double.negativeInfinity;
      double bottom = double.negativeInfinity;
      for (final List<double> point in polygon) {
        left = math.min(left, point[0]);
        top = math.min(top, point[1]);
        right = math.max(right, point[0]);
        bottom = math.max(bottom, point[1]);
      }
      if (right <= left || bottom <= top) {
        parsed.clear();
        break;
      }
      final MokuroOrientedRect? oriented = mokuroOrientedRectFromQuad(polygon);
      parsed.add(
        oriented != null && oriented.rotation != 0
            ? oriented
            : _uprightLine(MokuroRect.fromLTRB(left, top, right, bottom)),
      );
    }
    if (parsed.length == block.lines.length) {
      return parsed;
    }
  }

  final MokuroRect rect = block.rectangle;
  final int count = block.lines.length;
  if (block.isVertical) {
    final double width = rect.width / count;
    return <MokuroOrientedRect>[
      for (int index = 0; index < count; index++)
        _uprightLine(
          MokuroRect.fromLTWH(
            rect.right - (index + 1) * width,
            rect.top,
            width,
            rect.height,
          ),
        ),
    ];
  }
  final double height = rect.height / count;
  return <MokuroOrientedRect>[
    for (int index = 0; index < count; index++)
      _uprightLine(
        MokuroRect.fromLTWH(
          rect.left,
          rect.top + index * height,
          rect.width,
          height,
        ),
      ),
  ];
}

MokuroOrientedRect _uprightLine(MokuroRect rect) => MokuroOrientedRect(
  center: rect.center,
  width: rect.width,
  height: rect.height,
);
