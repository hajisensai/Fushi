/// 逐行 CTC 识别的 token 位置 → 逐字命中格（页面坐标）。
///
/// 为什么需要：覆盖层没有字级几何时按行长把字均分。行里有空格、长破折号、字距
/// 不匀（「第13話 — ロックスマス」这类标题）时，均分的字格整体偏到相邻的字上，
/// 点哪个字查到的是隔壁。逐行 CTC 识别器本来就知道每个字落在行图的哪几帧
/// （[OcrLineToken]），把它换回页面坐标就是逐字命中格，不用再估。
///
/// 位置是模型帧感受野的近似区间，不是字形 bbox：argmax 帧常只占字宽的一小段。
/// 所以字格不直接用 token 区间，而是取字中心：相邻两字中心的中点作分界（每个
/// 点击落到离它最近的字上），每格再以字中心为准、沿阅读方向最多伸出
/// [kOcrGlyphHalfExtentRatio] 倍行厚——空格、字距大的地方不让一个字的格子铺满
/// 整段空白，字格中心才落在字上。
library;

import 'dart:math' as math;

import 'package:characters/characters.dart';

import 'package:fushi_engine/ocr/ocr_types.dart';

/// 字格沿阅读方向从字中心最多伸出行厚的这么多倍。日文字大致是边长等于行厚的
/// 方块，半个行厚正好是一个字；多给 0.1 容下 CTC 峰值相对字形中心的几像素偏移。
const double kOcrGlyphHalfExtentRatio = 0.6;

/// 行识别器吐出的一个 CTC token：在行文本里的 UTF-16 区间 + 行图沿阅读方向的
/// 近似像素区间（横行是 x；竖列先逆时针转 90° 再识别，所以这里就是原列图的 y）。
/// token 落在右侧填充里时没有位置（[left] / [right] 为 null）。
class OcrLineToken {
  const OcrLineToken({
    required this.start,
    required this.end,
    this.left,
    this.right,
  });

  final int start;
  final int end;
  final double? left;
  final double? right;

  double? get center {
    final double? l = left;
    final double? r = right;
    if (l == null || r == null) return null;
    return (l + r) / 2;
  }
}

/// 一行的逐字命中格（页面坐标，区间按块文本计）。
///
/// [text] 是这一行的识别文本，[tokens] 与它逐 UTF-16 对齐。[line] 是行在页面上
/// 的框，字格在跨轴方向占满它。[alongOrigin] 是行图坐标 0 在页面上沿阅读方向的
/// 位置（横行 = 行裁图左边的 x，竖列 = 行裁图上边的 y）。[utf16Offset] 是本行在
/// 块文本里的起点。
///
/// 每个可见字素簇的中心取覆盖它的 token 中心的平均（基字 + 组合浊点这类一字多
/// token 也算一个字）。有一个可见字拿不到位置、或字中心不严格递增时返回 null，
/// 调用方整块退回按行均分——半套字格比没有更糟。
List<OcrGlyphBox>? ocrLineGlyphBoxes({
  required String text,
  required List<OcrLineToken> tokens,
  required OcrRect line,
  required bool vertical,
  required double alongOrigin,
  required int utf16Offset,
}) {
  final List<({int start, int end, double center})> glyphs =
      <({int start, int end, double center})>[];
  int offset = 0;
  for (final String grapheme in text.characters) {
    final int start = offset;
    final int end = offset + grapheme.length;
    offset = end;
    if (grapheme.trim().isEmpty) continue;
    double sum = 0;
    int count = 0;
    for (final OcrLineToken token in tokens) {
      if (token.end <= start || token.start >= end) continue;
      final double? center = token.center;
      if (center == null) return null;
      sum += center;
      count++;
    }
    if (count == 0) return null;
    final double center = alongOrigin + sum / count;
    if (glyphs.isNotEmpty && center <= glyphs.last.center) return null;
    glyphs.add((start: start, end: end, center: center));
  }
  // 只有空白的行没有字要点，不算缺位置。
  if (glyphs.isEmpty) return const <OcrGlyphBox>[];
  final double lineStart = vertical ? line.top : line.left;
  final double lineEnd = vertical ? line.bottom : line.right;
  final double halfExtent =
      kOcrGlyphHalfExtentRatio * (vertical ? line.width : line.height);
  final List<OcrGlyphBox> boxes = <OcrGlyphBox>[];
  for (int i = 0; i < glyphs.length; i++) {
    final double from = i == 0
        ? lineStart
        : (glyphs[i - 1].center + glyphs[i].center) / 2;
    final double to = i == glyphs.length - 1
        ? lineEnd
        : (glyphs[i].center + glyphs[i + 1].center) / 2;
    final double center = glyphs[i].center;
    final double a = math
        .max(from, center - halfExtent)
        .clamp(lineStart, lineEnd);
    final double b = math
        .min(to, center + halfExtent)
        .clamp(lineStart, lineEnd);
    if (b <= a) return null;
    boxes.add(
      OcrGlyphBox(
        start: utf16Offset + glyphs[i].start,
        end: utf16Offset + glyphs[i].end,
        rect: vertical
            ? OcrRect(left: line.left, top: a, right: line.right, bottom: b)
            : OcrRect(left: a, top: line.top, right: b, bottom: line.bottom),
      ),
    );
  }
  return boxes;
}

/// 把逐行字格拼成整块的：任一行是 null（拿不到位置）整块就是 null。
List<OcrGlyphBox>? joinOcrLineGlyphBoxes(List<List<OcrGlyphBox>?> lines) {
  final List<OcrGlyphBox> all = <OcrGlyphBox>[];
  for (final List<OcrGlyphBox>? line in lines) {
    if (line == null) return null;
    all.addAll(line);
  }
  return all.isEmpty ? null : all;
}
