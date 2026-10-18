/// 文字块的行级几何：把一整串识别文本切到块内检出的各列（竖排）/各行（横排）上。
///
/// 为什么需要：manga-ocr 对整块只吐一串文本，没有行坐标。阅读器覆盖层拿不到行几何
/// 时只能把整串字沿整块均匀铺开——多列竖排气泡里点第二列，命中的是第一列的字。
/// 2026-09-30 用用户真实卷《君が一等星に光るまで 01》80 页对照 Google Lens 逐字框
/// 模拟点击：整块均铺只有 14.2% 的点击落在正确位置；本文件的切分在同一批页上是
/// 87.7%，识别文本一个字都不变。另一套注音密集、气泡宽扁的漫画（21 页）上是
/// 69.2%（整块均铺 9.5%）。
///
/// 三步，每一步都是实测换来的：
/// 1. 块方向按检出行**长度加权**投票（[voteOcrLineOrientation]）：宽而扁的多列竖排
///    气泡常被当成横排，列又被 PP 切成若干碎片——按条数数会被碎片带偏。
/// 2. 去振假名（[dropOcrRubyLines]）：比块内行厚 p75 的 0.6 还细，或贴在更粗的行
///    注音侧（竖排右侧 / 横排上方）且不到它 0.82 倍厚的行。只按 0.6 过滤会漏掉
///    0.6~0.8 那一截注音，正文字就被分到注音列上。
/// 3. 按字格切分（[layoutOcrTextOnLines]）：每列按「长 ÷ 厚」估字格数；连续点号
///    （`...` / `・・・` / `…`）合占一格，`!?` `!!` 这类两个一组横排进一格。把它们
///    当一字一格数，会让整列之后的字都错一格。
/// 试过按墨迹投影切字格，实测反而更差，没有采用。
library;

import 'dart:math' as math;

import 'package:characters/characters.dart';

import 'package:fushi_engine/ocr/ocr_types.dart';

/// 块的行级排版结果：[lines] 与 [boxes] 等长、同为阅读序，
/// `lines.join()` 恒等于切分前的原文。[boxes] 是页面像素坐标。
class OcrLineLayout {
  OcrLineLayout({required this.lines, required this.boxes})
    : assert(lines.length == boxes.length);

  final List<String> lines;
  final List<OcrRect> boxes;
}

/// 行在跨轴方向的厚度：竖排是列宽，横排是行高。
double ocrLineThickness(OcrRect rect, {required bool vertical}) =>
    vertical ? rect.width : rect.height;

/// 行沿阅读方向的长度：竖排是列高，横排是行宽。
double ocrLineLength(OcrRect rect, {required bool vertical}) =>
    vertical ? rect.height : rect.width;

/// 检出行的长宽比达到这个倍数才算「明确」竖行 / 横行，参与方向投票。
const double kOcrLineOrientationRatio = 1.5;

/// 按检出行给块方向投票：明确的竖行按高、明确的横行按宽累计长度，长的一方胜。
///
/// 近方形的行（单字、合并在一起的几列）不投票；一条明确的行都没有时返回 null，
/// 调用方保持原来的方向。
bool? voteOcrLineOrientation(List<OcrRect> lines) {
  double vertical = 0;
  double horizontal = 0;
  for (final OcrRect line in lines) {
    if (line.height >= kOcrLineOrientationRatio * line.width) {
      vertical += line.height;
    } else if (line.width >= kOcrLineOrientationRatio * line.height) {
      horizontal += line.width;
    }
  }
  if (vertical == 0 && horizontal == 0) return null;
  return vertical >= horizontal;
}

/// 振假名：比块内行厚 p75 的 [thinRatio] 还细的行，或贴在一条至少厚 1.25 倍的行的
/// 注音侧（竖排右侧 / 横排上方或下方，跨轴间隙不超过那条行厚的 0.35 倍、沿轴有
/// 重叠）且不到 p75 的 [sideRatio] 倍厚的行。
///
/// p75 按**行长加权**（[_lengthWeightedP75]）：注音天生切成很多短段，按段数取
/// 分位数时，一行正文配四段注音的块 p75 就落在注音自己的厚度上，两条判据一起失效。
///
/// 横排认下方：双行字幕第二行的注音标在字**下方**（上方被第一行占了）；字幕注音
/// 约为正文行高的 0.6~0.65，只按 [thinRatio] 会整排漏掉（BUG-3314）。下方注音
/// 只在「正文行上方已被另一行正文占住」时才认（[_hasTextLineAbove]）——这正是
/// 注音被挤到下方的原因；否则英文双行字幕第二行全是 x 高度小写字母（「can we
/// see」）时，行高不到第一行 0.82 倍又紧贴其下，会被误当注音删掉。
List<OcrRect> dropOcrRubyLines(
  List<OcrRect> lines, {
  required bool vertical,
  double thinRatio = 0.6,
  double sideRatio = 0.82,
}) {
  if (lines.length < 2) return lines;
  final double p75 = _lengthWeightedP75(lines, vertical: vertical);
  bool besideThickerLine(OcrRect line) {
    final double own = ocrLineThickness(line, vertical: vertical);
    for (final OcrRect other in lines) {
      if (identical(other, line)) continue;
      final double base = ocrLineThickness(other, vertical: vertical);
      if (base < own * 1.25) continue;
      bool hugs(double gap) => gap >= -0.35 * base && gap <= 0.35 * base;
      final bool onRubySide = vertical
          ? hugs(line.left - other.right)
          : hugs(other.top - line.bottom) ||
                (hugs(line.top - other.bottom) &&
                    _hasTextLineAbove(other, lines, ruby: line, own: own));
      final double along = vertical
          ? math.min(line.bottom, other.bottom) - math.max(line.top, other.top)
          : math.min(line.right, other.right) - math.max(line.left, other.left);
      if (onRubySide && along > 0) return true;
    }
    return false;
  }

  return <OcrRect>[
    for (final OcrRect line in lines)
      if (!(ocrLineThickness(line, vertical: vertical) < thinRatio * p75 ||
          (ocrLineThickness(line, vertical: vertical) < sideRatio * p75 &&
              besideThickerLine(line))))
        line,
  ];
}

/// 横排行 [base] 的正上方是否紧贴着另一行正文（厚度至少是候选注音 [ruby] 厚
/// [own] 的 1.25 倍、跨轴间隙不超过 [base] 行厚的 0.35 倍、沿轴有重叠）。
bool _hasTextLineAbove(
  OcrRect base,
  List<OcrRect> lines, {
  required OcrRect ruby,
  required double own,
}) {
  final double baseThickness = base.height;
  for (final OcrRect above in lines) {
    if (identical(above, base) || identical(above, ruby)) continue;
    if (above.height < own * 1.25) continue;
    final double gap = base.top - above.bottom;
    if (gap < -0.35 * baseThickness || gap > 0.35 * baseThickness) continue;
    final double along =
        math.min(above.right, base.right) - math.max(above.left, base.left);
    if (along > 0) return true;
  }
  return false;
}

/// 行厚的 75 分位，每行按它沿阅读方向的长度计权（文字量越多的行越代表正文字号）。
double _lengthWeightedP75(List<OcrRect> lines, {required bool vertical}) {
  final List<({double thickness, double length})> rows =
      <({double thickness, double length})>[
        for (final OcrRect line in lines)
          (
            thickness: ocrLineThickness(line, vertical: vertical),
            length: math.max(1, vertical ? line.height : line.width),
          ),
      ]..sort(
        (
          ({double thickness, double length}) a,
          ({double thickness, double length}) b,
        ) => a.thickness.compareTo(b.thickness),
      );
  final double total = rows.fold<double>(0, (double s, r) => s + r.length);
  double seen = 0;
  for (final ({double thickness, double length}) row in rows) {
    seen += row.length;
    if (seen >= 0.75 * total) return row.thickness;
  }
  return rows.last.thickness;
}

/// 同一行 / 列的两段碎片沿阅读方向的空隙上限：较厚那段行厚的这么多倍。
///
/// 取 3：同一行里被切开的地方是字距、空格、「っ」、句读、破折号，实测最宽的是
/// 字距大的装饰标题——「モテる女子の」逐字断开处空隙 111 px，两侧行厚 69 / 80 px，
/// 约为较厚者的 1.4 倍（较薄者的 1.6 倍），日文全角空格也只有 1 倍行厚。左右分栏
/// （人物资料页两栏、同一高度的两段旁白）之间的空白一般是行厚的 4~5 倍以上。3 给
/// 标题字距留了一倍多的余量，又低于分栏间距。按较厚者算：被切下来的小段（句读、
/// 小假名）自己很薄，按它算上限会把同一行的正常字距也当成分栏。
const double kOcrFragmentMaxGapRatio = 3;

/// 把同一列（竖排）/同一行（横排）被检测器切碎的片段合并成一条。
///
/// PP-OCR 会在一列中间的空隙（「っ」、句读、字距大的地方）把列切断；两段在跨轴
/// 方向重叠达到较薄者厚度的 [overlapRatio] 就算同一列。振假名要在调用前滤掉
/// （[dropOcrRubyLines]），否则它和正文列部分重叠会被并进来。
///
/// 同一列的碎片沿阅读方向首尾相接；沿阅读方向重叠超过较短者 [sideBySideRatio]
/// 的两段是**并排**的两列 / 两行——斜体字的轴对齐列框在跨轴上能互相压进一半以上
/// （用户真实页「パステルカラーで / 女子力アップ♡」重叠 54%），按碎片合并会把两列
/// 并成一条宽列，逐列 CTC 只读出一列、另一列整列丢失。并排的两段只有跨轴也重叠
/// 到 [duplicateRatio]（同一列被检出两次）时才合并。
///
/// 沿阅读方向的空隙超过较厚者行厚的 [maxGapRatio] 倍不合并
/// （[kOcrFragmentMaxGapRatio]）：只看跨轴重叠时，左右两栏同一高度的两行（竖排是
/// 上下两段同一 x 的列）会被并成一条横跨两栏的长行，逐行识别读出串栏的句子，覆盖
/// 层的字格也铺到两栏中间的空白上。
///
/// 合并做到不动点（传递闭包）：一趟按跨轴中心排序的贪心合并里，同一行的 A、B、C
/// 可能按 A、C、B 的顺序到达——C 与 A 隔着整个 B 的长度超过空隙上限而单独成条，B
/// 并进 C 之后再没有机会与 A 比较，一行被拆成两条。所以每趟合并后只要条数还在减少
/// 就再来一趟，直到没有任何两条可合并；结果与输入顺序无关。条数每趟严格减少，
/// 至多 `rects.length` 趟。返回顺序不是阅读序，调用方按 [orderOcrLinesForReading]
/// 等重排。
List<OcrRect> mergeOcrLineFragments(
  List<OcrRect> rects, {
  required bool vertical,
  double overlapRatio = 0.5,
  double sideBySideRatio = 0.5,
  double duplicateRatio = 0.8,
  double maxGapRatio = kOcrFragmentMaxGapRatio,
}) {
  if (rects.isEmpty) return const <OcrRect>[];
  List<OcrRect> current = rects;
  while (true) {
    final List<OcrRect> next = _mergeOcrLineFragmentsOnce(
      current,
      vertical: vertical,
      overlapRatio: overlapRatio,
      sideBySideRatio: sideBySideRatio,
      duplicateRatio: duplicateRatio,
      maxGapRatio: maxGapRatio,
    );
    // 条数没变 = 这一趟一次合并都没发生，已到不动点。
    if (next.length == current.length) return next;
    current = next;
  }
}

/// [mergeOcrLineFragments] 的一趟贪心合并。
List<OcrRect> _mergeOcrLineFragmentsOnce(
  List<OcrRect> rects, {
  required bool vertical,
  required double overlapRatio,
  required double sideBySideRatio,
  required double duplicateRatio,
  required double maxGapRatio,
}) {
  double crossStart(OcrRect r) => vertical ? r.left : r.top;
  double crossEnd(OcrRect r) => vertical ? r.right : r.bottom;
  double alongStart(OcrRect r) => vertical ? r.top : r.left;
  double alongEnd(OcrRect r) => vertical ? r.bottom : r.right;
  final List<OcrRect> sorted = List<OcrRect>.of(rects)
    ..sort(
      (OcrRect a, OcrRect b) =>
          (crossStart(a) + crossEnd(a)).compareTo(crossStart(b) + crossEnd(b)),
    );
  bool mergeable(OcrRect last, OcrRect rect) {
    final double overlap =
        math.min(crossEnd(last), crossEnd(rect)) -
        math.max(crossStart(last), crossStart(rect));
    final double thinner = math.min(
      ocrLineThickness(last, vertical: vertical),
      ocrLineThickness(rect, vertical: vertical),
    );
    final double thicker = math.max(
      ocrLineThickness(last, vertical: vertical),
      ocrLineThickness(rect, vertical: vertical),
    );
    final double alongOverlap =
        math.min(alongEnd(last), alongEnd(rect)) -
        math.max(alongStart(last), alongStart(rect));
    // 负的重叠就是两段之间的空隙。
    if (-alongOverlap > maxGapRatio * thicker) return false;
    final double shorter = math.min(
      alongEnd(last) - alongStart(last),
      alongEnd(rect) - alongStart(rect),
    );
    final bool sideBySide =
        shorter > 0 && alongOverlap > sideBySideRatio * shorter;
    final double required = sideBySide ? duplicateRatio : overlapRatio;
    return thinner > 0 && overlap >= required * thinner;
  }

  final List<OcrRect> merged = <OcrRect>[];
  for (final OcrRect rect in sorted) {
    // 从最近合并的往回找：跨轴位置相近的碎片按中心排序后挨在一起，但同一高度
    // 的另一栏会夹在同一行的两段之间，只看最后一条会把这行拆成两条。
    int target = -1;
    for (int i = merged.length - 1; i >= 0; i--) {
      if (mergeable(merged[i], rect)) {
        target = i;
        break;
      }
    }
    if (target < 0) {
      merged.add(rect);
      continue;
    }
    final OcrRect last = merged[target];
    merged[target] = OcrRect(
      left: math.min(last.left, rect.left),
      top: math.min(last.top, rect.top),
      right: math.max(last.right, rect.right),
      bottom: math.max(last.bottom, rect.bottom),
    );
  }
  return merged;
}

/// 阅读序：竖排按列从右到左，横排按行从上到下。
List<OcrRect> orderOcrLinesForReading(
  List<OcrRect> rects, {
  required bool vertical,
}) {
  final List<OcrRect> sorted = List<OcrRect>.of(rects);
  if (vertical) {
    sorted.sort(
      (OcrRect a, OcrRect b) => (b.left + b.right).compareTo(a.left + a.right),
    );
  } else {
    sorted.sort(
      (OcrRect a, OcrRect b) => (a.top + a.bottom).compareTo(b.top + b.bottom),
    );
  }
  return sorted;
}

/// 连续点号（省略号的各种写法）：两个以上合占一格。
final RegExp _dotRun = RegExp(r'^[.．・…‥]$');

/// 感叹 / 问号：两个以上时两个一组横排进一格。
final RegExp _markRun = RegExp(r'^[!！?？]$');

/// 每个字素簇占几格（只算可见字；空白为 0）。
List<double> _cellWeights(List<String> clusters) {
  final List<double> weights = <double>[
    for (final String c in clusters) c.trim().isEmpty ? 0 : 1,
  ];
  int i = 0;
  while (i < clusters.length) {
    final bool dot = _dotRun.hasMatch(clusters[i]);
    final bool mark = _markRun.hasMatch(clusters[i]);
    if (!dot && !mark) {
      i++;
      continue;
    }
    final RegExp same = dot ? _dotRun : _markRun;
    int end = i + 1;
    while (end < clusters.length && same.hasMatch(clusters[end])) {
      end++;
    }
    final int run = end - i;
    if (run >= 2) {
      final double cells = dot ? 1 : (run / 2).ceilToDouble();
      for (int k = i; k < end; k++) {
        weights[k] = cells / run;
      }
    }
    i = end;
  }
  return weights;
}

/// 把 [text] 按 [lines]（已是阅读序）的字格容量切开。
///
/// 每列容量 =「长 ÷ 厚」；每个字按它在全文里所占字格的中点，落进按容量比例划分的
/// 那一列（点号串、`!?` 组按 [_cellWeights] 少占格）。
///
/// 返回 null 表示没法给出行几何（没有行、没有可见字）——调用方保持单行旧口径。
/// 分不到字的行连同它的框一起丢掉，所以结果行数可能少于 [lines]。
OcrLineLayout? layoutOcrTextOnLines(
  String text,
  List<OcrRect> lines, {
  required bool vertical,
}) {
  final List<OcrRect> usable = <OcrRect>[
    for (final OcrRect line in lines)
      if (line.width > 0 && line.height > 0) line,
  ];
  if (usable.isEmpty) return null;
  final List<String> clusters = text.characters.toList();
  final List<double> weights = _cellWeights(clusters);
  final double totalWeight = weights.fold(0.0, (double a, double b) => a + b);
  if (totalWeight <= 0) return null;
  final List<double> capacities = <double>[
    for (final OcrRect line in usable)
      math.max(
        0.5,
        ocrLineLength(line, vertical: vertical) /
            math.max(1e-6, ocrLineThickness(line, vertical: vertical)),
      ),
  ];
  final double totalCapacity = capacities.fold(
    0.0,
    (double a, double b) => a + b,
  );
  // 各列在「全文字格」坐标上的右端。
  final List<double> ends = <double>[];
  double acc = 0;
  for (final double capacity in capacities) {
    acc += capacity / totalCapacity * totalWeight;
    ends.add(acc);
  }
  final List<StringBuffer> buffers = <StringBuffer>[
    for (int i = 0; i < usable.length; i++) StringBuffer(),
  ];
  final List<bool> hasVisible = List<bool>.filled(usable.length, false);
  int line = 0;
  double position = 0;
  for (int i = 0; i < clusters.length; i++) {
    final double weight = weights[i];
    if (weight > 0) {
      final double middle = position + weight / 2;
      position += weight;
      // 只往后走：空白跟着前一个可见字，阅读序不回退。
      while (line < usable.length - 1 && middle > ends[line]) {
        line++;
      }
      hasVisible[line] = true;
    }
    buffers[line].write(clusters[i]);
  }
  final List<String> outLines = <String>[];
  final List<OcrRect> outBoxes = <OcrRect>[];
  String pending = '';
  for (int i = 0; i < usable.length; i++) {
    final String content = buffers[i].toString();
    if (!hasVisible[i]) {
      // 只有空白（或什么都没有）的行不出框；空白并进相邻行，拼回仍是原文。
      if (outLines.isEmpty) {
        pending += content;
      } else {
        outLines[outLines.length - 1] = outLines.last + content;
      }
      continue;
    }
    outLines.add(pending + content);
    pending = '';
    outBoxes.add(usable[i]);
  }
  if (outLines.isEmpty) return null;
  return OcrLineLayout(lines: outLines, boxes: outBoxes);
}
