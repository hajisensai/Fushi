/// 行级 OCR（Apple Vision / ML Kit 这类「整页进、文本行出」的识别器）的
/// **切片规划与跨片合并**，平台无关，所有行级识别器共用。
///
/// 为什么要切：这类识别器会把整页先缩到内部的固定分辨率再找字。漫画页上气泡
/// 字小而密，缩完就掉到检测下限以下——实测 21 页真实日漫、以 Google Lens 结果
/// 为基准，Apple `RecognizeDocumentsRequest` 整页一次只命中 82% 的文字块、52%
/// 的字；按行切成三片后到 87% / 69%，而单页耗时仍在 0.5 秒级（BUG-2767）。
/// Chimahon（Mihon 分支）对超高页做同一件事（重叠切条 + 边界去重）。
///
/// 切片带来的代价是**跨切线的行被截成两截**、重叠区里的行被读两遍。
/// [mergeTiledOcrLines] 负责收拾：丢掉被切边截断且另一片有完整版的行，把两片
/// 各读一截的行按文字重叠拼回去，最后全局去重。它对没切片的结果是恒等变换，
/// 所以平台忽略切片请求（旧系统、未实现的平台）时调用方不用分支。
///
/// 气泡归组**不在这里**：展示层（`manga_overlay_html.dart`）已有按几何邻接把
/// 行聚成整句、并识别注音的那一套，这里再写一套只会得到两种结果。
library;

import 'dart:math' as math;

import 'package:fushi_engine/ocr/ocr_types.dart';

/// 单片目标高度（像素，不含重叠）。实测 1370×2000 的漫画页切三行（每片约
/// 670 高）在召回和耗时之间最划算：切两行少 2.5 个百分点的字，切成 3×3 只多
/// 1.4 个点、耗时翻倍。
const double kOcrTileTargetHeight = 768;

/// 单片目标宽度。竖排列窄而横向排开，横向切只会把一排列切成两排，收益远小于
/// 纵向切；普通单页因此只按行切，跨页大图才会被竖着切一刀。
const double kOcrTileTargetWidth = 1536;

/// 相邻片之间的重叠比例（相对单片尺寸，每侧各延伸这么多）。
const double kOcrTileOverlapRatio = 0.1;

/// 重叠下限（像素）：至少容得下一个完整的漫画字，否则跨切线的字在两片里都
/// 只剩半个，哪边都认不出。
const double kOcrTileMinOverlap = 48;

/// 单页最多切几片。条漫长图按此封顶，片再大也比一页识别几十次强。
const int kOcrMaxTiles = 12;

/// 一条识别出的文本行。[tile] 是产出它的切片下标（对应 [planOcrPageTiles]
/// 的返回值）；整页识别出来的行为 `null`。
class OcrTextLine {
  const OcrTextLine({required this.text, required this.rect, this.tile});

  final String text;

  /// 原图像素坐标。
  final OcrRect rect;

  final int? tile;

  @override
  String toString() => 'OcrTextLine($text, $rect, tile: $tile)';
}

/// 给 [width]×[height] 的页面规划切片（原图像素坐标，已含重叠）。
///
/// 页面小到一片就装得下时返回空列表——表示「整页识别」，不是「没东西可认」。
List<OcrRect> planOcrPageTiles(
  int width,
  int height, {
  double targetTileWidth = kOcrTileTargetWidth,
  double targetTileHeight = kOcrTileTargetHeight,
  double overlapRatio = kOcrTileOverlapRatio,
  double minOverlap = kOcrTileMinOverlap,
  int maxTiles = kOcrMaxTiles,
}) {
  if (width <= 0 || height <= 0) {
    return const <OcrRect>[];
  }
  int columns = math.max(1, (width / targetTileWidth).ceil());
  int rows = math.max(1, (height / targetTileHeight).ceil());
  while (columns * rows > maxTiles) {
    // 先削切得更碎的那个方向，保持片的形状接近目标。
    if (rows / (height / targetTileHeight) >=
        columns / (width / targetTileWidth)) {
      if (rows > 1) {
        rows--;
      } else {
        columns--;
      }
    } else if (columns > 1) {
      columns--;
    } else {
      rows--;
    }
  }
  if (columns * rows <= 1) {
    return const <OcrRect>[];
  }
  final double tileWidth = width / columns;
  final double tileHeight = height / rows;
  final double overlapX = math.max(minOverlap, tileWidth * overlapRatio);
  final double overlapY = math.max(minOverlap, tileHeight * overlapRatio);
  return <OcrRect>[
    for (int row = 0; row < rows; row++)
      for (int column = 0; column < columns; column++)
        OcrRect(
          left:
              column == 0 ? 0 : (column * tileWidth - overlapX).floorToDouble(),
          top: row == 0 ? 0 : (row * tileHeight - overlapY).floorToDouble(),
          right: column == columns - 1
              ? width.toDouble()
              : ((column + 1) * tileWidth + overlapX)
                  .ceilToDouble()
                  .clamp(0, width.toDouble()),
          bottom: row == rows - 1
              ? height.toDouble()
              : ((row + 1) * tileHeight + overlapY)
                  .ceilToDouble()
                  .clamp(0, height.toDouble()),
        ),
  ];
}

/// 把各片识别出的行合成一页。
///
/// [tiles] 必须是产出这些行时用的那份切片规划（[OcrTextLine.tile] 是它的下标）。
/// 三步，顺序有意义：
///
/// 1. **截断行让位**：一行碰到了所在片的「内侧切边」（不是页面边界）就可能只读了
///    半截。若另一片里有盖住它大半的未截断行，丢掉这条截断的。
/// 2. **跨切线拼接**：两片各读一截的同一行（上片的碰下切边、下片的碰上切边，且
///    在重叠区里相交）拼回一行。文字优先按「前一截的尾 = 后一截的头」精确对齐，
///    对不上（切边上的半个字常被读错）就按重叠区中线各取一半。
/// 3. **全局去重**：重叠区里完整读了两遍的行只留一条（文字互相包含且框大半重合）。
List<OcrTextLine> mergeTiledOcrLines(
  List<OcrTextLine> lines,
  List<OcrRect> tiles,
) {
  if (tiles.isEmpty || lines.every((OcrTextLine line) => line.tile == null)) {
    return lines;
  }
  final double pageRight = tiles.map((OcrRect t) => t.right).reduce(math.max);
  final double pageBottom = tiles.map((OcrRect t) => t.bottom).reduce(math.max);

  final List<_TiledLine> pending = <_TiledLine>[
    for (final OcrTextLine line in lines)
      _TiledLine.of(line, tiles, pageRight: pageRight, pageBottom: pageBottom),
  ];

  // 1. 截断行让位给别片的完整版。
  pending.removeWhere((_TiledLine candidate) {
    if (!candidate.clipped) {
      return false;
    }
    return pending.any((_TiledLine other) =>
        !identical(other, candidate) &&
        !other.clipped &&
        other.line.tile != candidate.line.tile &&
        _intersection(other.line.rect, candidate.line.rect) >=
            0.5 * candidate.line.rect.area);
  });

  // 2. 跨切线拼接。拼出来的行可能还要和第三片再拼（极长的列），所以迭代到不动。
  bool merged = true;
  while (merged) {
    merged = false;
    outer:
    for (int i = 0; i < pending.length; i++) {
      for (int j = 0; j < pending.length; j++) {
        if (i == j) {
          continue;
        }
        final _TiledLine? stitched = _stitch(pending[i], pending[j]);
        if (stitched != null) {
          final _TiledLine first = pending[i];
          final _TiledLine second = pending[j];
          pending
            ..remove(first)
            ..remove(second)
            ..add(stitched);
          merged = true;
          break outer;
        }
      }
    }
  }

  return _dedupeOcrLines(<OcrTextLine>[
    for (final _TiledLine line in pending) line.line,
  ]);
}

/// 一条带「碰到了哪几条内侧切边」标记的行。拼接后的行继承两段的外侧标记。
class _TiledLine {
  _TiledLine(
    this.line, {
    required this.clipTop,
    required this.clipBottom,
    required this.clipLeft,
    required this.clipRight,
  });

  factory _TiledLine.of(
    OcrTextLine line,
    List<OcrRect> tiles, {
    required double pageRight,
    required double pageBottom,
  }) {
    final int? index = line.tile;
    if (index == null || index < 0 || index >= tiles.length) {
      return _TiledLine(
        line,
        clipTop: false,
        clipBottom: false,
        clipLeft: false,
        clipRight: false,
      );
    }
    final OcrRect tile = tiles[index];
    final OcrRect rect = line.rect;
    // 容差取一个字宽：切边上的半个字 Vision 往往干脆不报，读到的截断行会停在
    // 切边前一个字的位置，只按像素贴边判会漏掉这种截断。
    final double margin =
        math.max(6.0, math.min(rect.width, rect.height) * 1.0);
    return _TiledLine(
      line,
      clipTop: tile.top > 0 && rect.top - tile.top <= margin,
      clipBottom:
          tile.bottom < pageBottom && tile.bottom - rect.bottom <= margin,
      clipLeft: tile.left > 0 && rect.left - tile.left <= margin,
      clipRight: tile.right < pageRight && tile.right - rect.right <= margin,
    );
  }

  final OcrTextLine line;
  final bool clipTop;
  final bool clipBottom;
  final bool clipLeft;
  final bool clipRight;

  bool get clipped => clipTop || clipBottom || clipLeft || clipRight;
}

/// 若 [first] 与 [second] 是同一行被切线截成的两截（[first] 在前），返回拼好的行。
_TiledLine? _stitch(_TiledLine first, _TiledLine second) {
  if (first.line.tile == second.line.tile) {
    return null;
  }
  final OcrRect a = first.line.rect;
  final OcrRect b = second.line.rect;
  final bool alongY = first.clipBottom && second.clipTop;
  final bool alongX = first.clipRight && second.clipLeft;
  if (!alongY && !alongX) {
    return null;
  }
  // 同一行：垂直于切线方向的范围大半重合，且沿切线方向在重叠区里相交。
  final double crossOverlap = alongY
      ? math.min(a.right, b.right) - math.max(a.left, b.left)
      : math.min(a.bottom, b.bottom) - math.max(a.top, b.top);
  final double crossMin =
      alongY ? math.min(a.width, b.width) : math.min(a.height, b.height);
  if (crossMin <= 0 || crossOverlap < 0.5 * crossMin) {
    return null;
  }
  final double aStart = alongY ? a.top : a.left;
  final double aEnd = alongY ? a.bottom : a.right;
  final double bStart = alongY ? b.top : b.left;
  final double bEnd = alongY ? b.bottom : b.right;
  if (!(aStart < bStart && bStart < aEnd && aEnd < bEnd)) {
    return null;
  }
  final String text = stitchOcrLineText(
    first.line.text,
    second.line.text,
    firstStart: aStart,
    firstEnd: aEnd,
    secondStart: bStart,
    secondEnd: bEnd,
  );
  return _TiledLine(
    OcrTextLine(
      text: text,
      rect: OcrRect(
        left: math.min(a.left, b.left),
        top: math.min(a.top, b.top),
        right: math.max(a.right, b.right),
        bottom: math.max(a.bottom, b.bottom),
      ),
      tile: first.line.tile,
    ),
    clipTop: first.clipTop,
    clipBottom: second.clipBottom,
    clipLeft: first.clipLeft,
    clipRight: second.clipRight,
  );
}

/// 拼接时允许丢弃的「切边受损字」个数（每截各算）。
const int _kStitchEdgeTrim = 2;

/// 把同一行的前后两截文字拼起来。两截沿行方向的像素区间分别是
/// `[firstStart, firstEnd]` 与 `[secondStart, secondEnd]`，在
/// `[secondStart, firstEnd]` 这段重叠区里两边各读过一遍。
///
/// 先找「前一截的尾 = 后一截的头」的精确重叠，取与按字距估出来的重叠字数最
/// 接近的那个（单字巧合相等很常见，不能只取最长）；估计偏差过大或根本对不上
/// 时，按重叠区中线切：前一截留中线之前的字，后一截留中线之后的字。
String stitchOcrLineText(
  String first,
  String second, {
  required double firstStart,
  required double firstEnd,
  required double secondStart,
  required double secondEnd,
}) {
  final List<int> a = first.runes.toList();
  final List<int> b = second.runes.toList();
  if (a.isEmpty) {
    return second;
  }
  if (b.isEmpty) {
    return first;
  }
  final double pitchA = (firstEnd - firstStart) / a.length;
  final double pitchB = (secondEnd - secondStart) / b.length;
  final double pitch = (pitchA + pitchB) / 2;
  final double overlapPixels = firstEnd - secondStart;
  final double expected = pitch > 0 ? overlapPixels / pitch : 0;

  // 切边上的半个字常被读成别的字（实测「★ユニバー」在切边处读成「★ユニバー：」），
  // 所以允许两截各自丢掉贴着切边的至多 [_kStitchEdgeTrim] 个字再对齐。丢了字的
  // 对齐要求至少两个字相等，免得单字巧合把两截错位拼上。
  ({int trimA, int trimB, int k})? best;
  double bestScore = double.infinity;
  for (int trimA = 0; trimA <= _kStitchEdgeTrim; trimA++) {
    for (int trimB = 0; trimB <= _kStitchEdgeTrim; trimB++) {
      final int lengthA = a.length - trimA;
      final int lengthB = b.length - trimB;
      final int minimum = trimA + trimB == 0 ? 1 : 2;
      for (int k = math.min(lengthA, lengthB); k >= minimum; k--) {
        bool matches = true;
        for (int index = 0; index < k; index++) {
          if (a[lengthA - k + index] != b[trimB + index]) {
            matches = false;
            break;
          }
        }
        if (!matches) {
          continue;
        }
        // 重叠区里 A 占 k + trimA 个字、B 占 trimB + k 个字。先比丢了几个字，再
        // 比与估计重叠字数的偏差。
        final double deviation = (k + math.max(trimA, trimB) - expected).abs();
        if (deviation > math.max(1.5, expected / 2)) {
          continue;
        }
        final double score = (trimA + trimB) * 10 + deviation;
        if (score < bestScore) {
          bestScore = score;
          best = (trimA: trimA, trimB: trimB, k: k);
        }
      }
    }
  }
  if (best != null) {
    return String.fromCharCodes(<int>[
      ...a.sublist(0, a.length - best.trimA),
      ...b.sublist(best.trimB + best.k),
    ]);
  }

  final double middle = (secondStart + firstEnd) / 2;
  final int keepA = pitchA > 0
      ? ((middle - firstStart) / pitchA).round().clamp(0, a.length)
      : a.length;
  final int dropB = pitchB > 0
      ? ((middle - secondStart) / pitchB).round().clamp(0, b.length)
      : 0;
  return String.fromCharCodes(<int>[
    ...a.sublist(0, keepA),
    ...b.sublist(dropB),
  ]);
}

/// 重叠区里完整读了两遍的行只留一条：长的先占位，短的若文字被包含（或框几乎
/// 重合）且框大半落在已留行里就丢。输出保持输入顺序。
List<OcrTextLine> _dedupeOcrLines(List<OcrTextLine> lines) {
  final List<int> byLength = List<int>.generate(lines.length, (int i) => i)
    ..sort((int x, int y) {
      final int length =
          lines[y].text.runes.length.compareTo(lines[x].text.runes.length);
      return length != 0 ? length : x.compareTo(y);
    });
  final List<int> kept = <int>[];
  for (final int index in byLength) {
    final OcrTextLine line = lines[index];
    final bool duplicate = kept.any((int keptIndex) {
      final OcrTextLine other = lines[keptIndex];
      final double shared = _intersection(line.rect, other.rect);
      if (shared < 0.5 * math.min(line.rect.area, other.rect.area)) {
        return false;
      }
      return other.text.contains(line.text) ||
          shared >= 0.8 * math.max(line.rect.area, other.rect.area);
    });
    if (!duplicate) {
      kept.add(index);
    }
  }
  kept.sort();
  return <OcrTextLine>[for (final int index in kept) lines[index]];
}

double _intersection(OcrRect a, OcrRect b) {
  final double width =
      math.max(0, math.min(a.right, b.right) - math.max(a.left, b.left));
  final double height =
      math.max(0, math.min(a.bottom, b.bottom) - math.max(a.top, b.top));
  return width * height;
}
