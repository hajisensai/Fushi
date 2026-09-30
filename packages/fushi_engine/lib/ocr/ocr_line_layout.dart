/// 文字块的行级几何：把一整串识别文本切到块内检出的各列（竖排）/各行（横排）上。
///
/// 为什么需要：manga-ocr 对整块只吐一串文本，没有行坐标。阅读器覆盖层拿不到行几何
/// 时只能把整串字沿整块均匀铺开——多列竖排气泡里点第二列，命中的是第一列的字。
/// 2026-09-30 用用户真实卷《君が一等星に光るまで 01》80 页、5267 次模拟点击对照
/// Google Lens 逐字框：整块均铺只有 14.2% 的点击落在正确位置；按 PP-OCRv6 检出的
/// 列把同一串文本按列长切开后是 81.5%（以 Lens 真实列与真实字数切分的上限 85.8%），
/// 识别文本一个字都不变。
///
/// 切分口径：每列按「长 ÷ 厚」估它能放几个字（日文一字一个近似正方形的字格），
/// 总字数按最大余数法摊到各列；切点只落在字素簇边界，拼回去逐字节等于原文。
/// 列内字形不等宽（`!?` 横排进一格、`…`）会让个别列差一格，这是估算口径的已知
/// 误差；试过按墨迹投影切字格，实测反而更差（76%），没有采用。
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

/// 把同一列（竖排）/同一行（横排）被检测器切碎的片段合并成一条。
///
/// PP-OCR 会在一列中间的空隙（「っ」、句读、字距大的地方）把列切断；两段在跨轴
/// 方向重叠达到较薄者厚度的 [overlapRatio] 就算同一列。振假名要在调用前滤掉
/// （`filterThinLines`），否则它和正文列部分重叠会被并进来。
List<OcrRect> mergeOcrLineFragments(
  List<OcrRect> rects, {
  required bool vertical,
  double overlapRatio = 0.5,
}) {
  if (rects.isEmpty) return const <OcrRect>[];
  double crossStart(OcrRect r) => vertical ? r.left : r.top;
  double crossEnd(OcrRect r) => vertical ? r.right : r.bottom;
  final List<OcrRect> sorted = List<OcrRect>.of(rects)
    ..sort(
      (OcrRect a, OcrRect b) =>
          (crossStart(a) + crossEnd(a)).compareTo(crossStart(b) + crossEnd(b)),
    );
  final List<OcrRect> merged = <OcrRect>[sorted.first];
  for (final OcrRect rect in sorted.skip(1)) {
    final OcrRect last = merged.last;
    final double overlap =
        math.min(crossEnd(last), crossEnd(rect)) -
        math.max(crossStart(last), crossStart(rect));
    final double thinner = math.min(
      ocrLineThickness(last, vertical: vertical),
      ocrLineThickness(rect, vertical: vertical),
    );
    if (thinner > 0 && overlap >= overlapRatio * thinner) {
      merged[merged.length - 1] = OcrRect(
        left: math.min(last.left, rect.left),
        top: math.min(last.top, rect.top),
        right: math.max(last.right, rect.right),
        bottom: math.max(last.bottom, rect.bottom),
      );
    } else {
      merged.add(rect);
    }
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

/// 把 [text] 按 [lines]（已是阅读序）的字格容量切开。
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
  final int visible = clusters.where((String c) => c.trim().isNotEmpty).length;
  if (visible == 0) return null;
  final List<int> counts = _apportion(visible, <double>[
    for (final OcrRect line in usable)
      math.max(
        0.5,
        ocrLineLength(line, vertical: vertical) /
            math.max(1e-6, ocrLineThickness(line, vertical: vertical)),
      ),
  ]);
  final List<StringBuffer> buffers = <StringBuffer>[
    for (int i = 0; i < usable.length; i++) StringBuffer(),
  ];
  int line = 0;
  int taken = 0;
  for (final String cluster in clusters) {
    final bool isVisible = cluster.trim().isNotEmpty;
    if (isVisible) {
      // 当前行配额已满就换到下一个还有配额的行；空白跟着前一个可见字走。
      while (line < usable.length - 1 && taken >= counts[line]) {
        line++;
        taken = 0;
      }
      taken++;
    }
    buffers[line].write(cluster);
  }
  final List<String> outLines = <String>[];
  final List<OcrRect> outBoxes = <OcrRect>[];
  for (int i = 0; i < usable.length; i++) {
    if (counts[i] == 0) {
      // 没分到可见字的行：若它恰好吸收了前导/尾随空白，把空白并回相邻行，
      // 保证拼回去仍是原文。
      final String orphan = buffers[i].toString();
      if (orphan.isEmpty) continue;
      if (outLines.isNotEmpty) {
        outLines[outLines.length - 1] = outLines.last + orphan;
      } else {
        final int next = counts.indexWhere((int c) => c > 0, i + 1);
        if (next < 0) continue;
        final String rest = buffers[next].toString();
        buffers[next]
          ..clear()
          ..write(orphan)
          ..write(rest);
      }
      continue;
    }
    outLines.add(buffers[i].toString());
    outBoxes.add(usable[i]);
  }
  if (outLines.isEmpty) return null;
  return OcrLineLayout(lines: outLines, boxes: outBoxes);
}

/// 最大余数法：把 [total] 个字按 [weights] 摊成整数份，和恒为 [total]。
List<int> _apportion(int total, List<double> weights) {
  final double sum = weights.fold(0.0, (double a, double b) => a + b);
  final List<double> exact = <double>[
    for (final double w in weights) total * w / sum,
  ];
  final List<int> counts = <int>[for (final double e in exact) e.floor()];
  int remaining = total - counts.fold(0, (int a, int b) => a + b);
  final List<int> byRemainder = List<int>.generate(weights.length, (int i) => i)
    ..sort(
      (int a, int b) => (exact[b] - counts[b]).compareTo(exact[a] - counts[a]),
    );
  for (final int index in byRemainder) {
    if (remaining <= 0) break;
    counts[index]++;
    remaining--;
  }
  return counts;
}
