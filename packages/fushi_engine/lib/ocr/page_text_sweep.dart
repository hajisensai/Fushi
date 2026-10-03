/// 补检：页面文字检测器不自信、没过阈值的文字，由行检测 + 逐行识别复核后补回来。
///
/// 为什么要它：页面检测器（comic-text-and-bubble-detector，RT-DETR）对气泡里的
/// 台词很稳，对**字距稀疏的装饰性标题**不自信。用户真实页的「モテる女子の /
/// オキテ」两行横排标题，检测器只给 0.125 / 0.02 分，低于 0.3 的阈值整块丢掉，
/// 阅读器上那里什么都点不到；同一区域交给 PP-OCR 行检测 + 逐行 CTC，两行一字
/// 不差。单纯降检测阈值救不全（第二行只有 0.02，而且常常只框住半行），还会放进
/// 成片的低分误检；整页再跑一遍行检测又太慢（实测每页 1.5 秒以上）。
///
/// 做法：检测器低于正式阈值的弱候选（[PageDetections.weakTextRegions]）里，去掉
/// 落在已有文字块里的 → 相邻的聚成一团 → 外扩一圈在原分辨率上检行（弱候选常常
/// 只框住半行）→ 去振假名、合并同列碎片、排阅读序 → 逐行识别（竖列先逆时针转
/// 90°，与逐列 CTC 同口径）→ 只收「读得有把握、而且是日文」的块。门槛刻意偏严：
/// 补回的块没有检测器背书，宁可漏一块装饰字，也不往阅读器里塞拟声词笔触、网点、
/// 水印读出来的乱码。
library;

import 'dart:math' as math;

import 'package:image/image.dart' as img;

import 'package:fushi_engine/ocr/manga_ocr_pipeline.dart';
import 'package:fushi_engine/ocr/ocr_line_layout.dart';
import 'package:fushi_engine/ocr/ocr_types.dart';
import 'package:fushi_engine/ocr/ppocr_line_detector.dart';
import 'package:fushi_engine/ocr/ppocr_line_recognizer.dart';

/// 框与已有文字块的交叠面积超过自身面积的这个比例，就算已被覆盖。
const double kOcrSweepCoveredRatio = 0.3;

/// 行厚度（横行的高 / 竖列的宽）至少是页面短边的这个比例：再细的是背景小字
/// （杂志封面、书脊、招牌上的花纹字），读出来也多半是乱码。
const double kOcrSweepMinThicknessRatio = 0.015;

/// 弱候选面积上限（相对整页）：横跨半页的低分框是检测器在画面上的乱猜，聚团时
/// 会把周围不相干的东西一起吞进来。
const double kOcrSweepMaxCandidateAreaRatio = 0.08;

/// 弱候选聚团时两框的间距上限（相对较小一框的短边）。
const double kOcrSweepClusterGapRatio = 1.0;

/// 一团里最高的候选分不到这个数就不复核：0.02～0.05 的散框绝大多数是画面纹理，
/// 每团复核都要一次块内行检测 + 识别。用户真实页的标题那团最高是 0.057（洗掉
/// 覆盖层的截图）/ 0.125（带覆盖层）。
const double kOcrSweepMinClusterScore = 0.05;

/// 每页复核区域的面积预算（相对整页）：块内行检测的耗时与面积成正比，弱候选
/// 团的最高分又几乎不区分「是字」和「是画」（真书 16 页实测：0.2～0.3 分的大团
/// 绝大多数读不出字）。按最高分从高到低花预算，花不下的大团跳过、换更小的团，
/// 补检的额外开销就有上界。
const double kOcrSweepAreaBudgetRatio = 0.1;

/// 行被检行区域截断时最多延长几轮、每轮延长几个行厚度。
const int kOcrSweepMaxRegionGrowth = 2;
const double kOcrSweepGrowthRatio = 2;

/// 聚好的团外扩多少再检行（相对团的短边）：弱候选常只框住半行。
const double kOcrSweepExpandRatio = 0.15;

/// 一块的平均 CTC 置信度下限。
const double kOcrSweepMinConfidence = 0.85;

/// 一块里日文字（假名 / 汉字 / 长音）至少几个、占可见字的比例至少多少。
const int kOcrSweepMinJapaneseChars = 2;
const double kOcrSweepMinJapaneseRatio = 0.6;

final RegExp _japaneseChar = RegExp(r'[ぁ-ゖゝ-ゟァ-ヺー-ヿ々一-鿿]');

/// 行检测器 + 行识别器做补检。识别器用的是装配层给横排行的那一个（逐列 CTC
/// 模式下就是漫画 CTC 权重）。
class PpOcrPageTextSweeper implements OcrPageTextSweeper {
  PpOcrPageTextSweeper({
    required PpOcrLineDetector lineDetector,
    required PpOcrLineRecognizer lineRecognizer,
  }) : _lineDetector = lineDetector,
       _lineRecognizer = lineRecognizer;

  final PpOcrLineDetector _lineDetector;
  final PpOcrLineRecognizer _lineRecognizer;

  @override
  Future<List<OcrBlock>> sweep(
    img.Image page, {
    required List<DetectedTextRegion> candidates,
    required List<OcrRect> covered,
  }) async {
    final double minThickness =
        kOcrSweepMinThicknessRatio * math.min(page.width, page.height);
    final double maxArea =
        kOcrSweepMaxCandidateAreaRatio * page.width * page.height;
    final List<DetectedTextRegion> open =
        <DetectedTextRegion>[
          for (final DetectedTextRegion candidate in candidates)
            if (candidate.rect.area <= maxArea &&
                math.min(candidate.rect.width, candidate.rect.height) >=
                    minThickness &&
                !isOcrRectCovered(candidate.rect, covered))
              candidate,
        ]..sort(
          (DetectedTextRegion a, DetectedTextRegion b) =>
              b.score.compareTo(a.score),
        );
    if (open.isEmpty) return const <OcrBlock>[];
    // 已补回的行也算覆盖：外扩后的检行区域会互相压到，同一行不读两次。
    final List<OcrRect> taken = <OcrRect>[...covered];
    final List<OcrBlock> blocks = <OcrBlock>[];
    final double budget = kOcrSweepAreaBudgetRatio * page.width * page.height;
    double spent = 0;
    for (final List<DetectedTextRegion> cluster in clusterOcrSweepCandidates(
      open,
      maxArea: maxArea,
    )) {
      // 团按最高分从高到低建，第一个就是团里最高分。
      if (cluster.first.score < kOcrSweepMinClusterScore) continue;
      final double area = _union(<OcrRect>[
        for (final DetectedTextRegion c in cluster) c.rect,
      ]).area;
      if (spent + area > budget) continue;
      spent += area;
      final OcrBlock? block = await _recognizeCluster(
        page,
        <OcrRect>[for (final DetectedTextRegion c in cluster) c.rect],
        taken: taken,
        minThickness: minThickness,
      );
      if (block == null) continue;
      blocks.add(block);
      taken.addAll(block.lineBoxes!);
    }
    return blocks;
  }

  Future<OcrBlock?> _recognizeCluster(
    img.Image page,
    List<OcrRect> cluster, {
    required List<OcrRect> taken,
    required double minThickness,
  }) async {
    final OcrRect union = _union(cluster);
    final double pad =
        kOcrSweepExpandRatio * math.min(union.width, union.height);
    OcrRect region = OcrRect(
      left: union.left - pad,
      top: union.top - pad,
      right: union.right + pad,
      bottom: union.bottom + pad,
    ).clamp(page.width.toDouble(), page.height.toDouble());
    ({bool vertical, List<OcrRect> lines})? found;
    for (int round = 0; round <= kOcrSweepMaxRegionGrowth; round++) {
      found = await _detectClusterLines(
        page,
        region,
        cluster,
        union: union,
        taken: taken,
        minThickness: minThickness,
      );
      if (found == null) return null;
      final OcrRect? grown = growOcrSweepRegion(
        region,
        found.lines,
        vertical: found.vertical,
        pageWidth: page.width,
        pageHeight: page.height,
      );
      if (grown == null) break;
      region = grown;
    }
    final bool vertical = found!.vertical;
    final List<OcrRect> lines = found.lines;
    final List<String> texts = <String>[];
    final List<OcrRect> boxes = <OcrRect>[];
    double confidenceSum = 0;
    int tokenCount = 0;
    for (final OcrRect line in lines) {
      final OcrBlockCrop? crop = cropOcrBlock(page, line);
      if (crop == null) continue;
      final PpOcrLineRecognition recognition = await _lineRecognizer
          .recognizeLineDetailed(
            vertical ? img.copyRotate(crop.image, angle: -90) : crop.image,
          );
      if (recognition.text.trim().isEmpty) continue;
      for (final PpOcrCtcToken token in recognition.tokens) {
        confidenceSum += token.confidence;
        tokenCount++;
      }
      texts.add(recognition.text);
      boxes.add(line);
    }
    if (tokenCount == 0) return null;
    final double confidence = confidenceSum / tokenCount;
    if (!acceptOcrSweepText(texts.join(), confidence)) return null;
    return OcrBlock(
      box: _union(boxes),
      vertical: vertical,
      lines: texts,
      lineBoxes: boxes,
      score: confidence,
    );
  }

  /// 在 [region] 里检行，取本团的行：方向只按碰到本团候选的行定（隔壁的字不投票）；
  /// 先合并碎片、再去振假名、最后认领——字距大的装饰字被行检测逐字切开，先去注音
  /// 会把单个小假名（「オキテ」的「テ」）按厚度当成注音删掉；候选常只框住半行，
  /// 合并后的整行碰到候选就整行收下。一行都没有返回 null。
  Future<({bool vertical, List<OcrRect> lines})?> _detectClusterLines(
    img.Image page,
    OcrRect region,
    List<OcrRect> cluster, {
    required OcrRect union,
    required List<OcrRect> taken,
    required double minThickness,
  }) async {
    final List<OcrRect> detected = <OcrRect>[
      for (final OcrRect line in await _lineDetector.detectInBlock(
        page,
        region,
      ))
        if (!isOcrRectCovered(line, taken) &&
            math.min(line.width, line.height) >= minThickness)
          line,
    ];
    final List<OcrRect> own = <OcrRect>[
      for (final OcrRect line in detected)
        if (_touchesAny(line, cluster)) line,
    ];
    if (own.isEmpty) return null;
    final bool vertical = pickOcrSweepOrientation(own, union);
    final List<OcrRect> lines = orderOcrLinesForReading(<OcrRect>[
      for (final OcrRect line in dropOcrRubyLines(
        mergeOcrLineFragments(detected, vertical: vertical),
        vertical: vertical,
      ))
        if (_touchesAny(line, cluster)) line,
    ], vertical: vertical);
    if (lines.isEmpty) return null;
    return (vertical: vertical, lines: lines);
  }
}

OcrRect _union(List<OcrRect> rects) => OcrRect(
  left: rects.map((OcrRect r) => r.left).reduce(math.min),
  top: rects.map((OcrRect r) => r.top).reduce(math.min),
  right: rects.map((OcrRect r) => r.right).reduce(math.max),
  bottom: rects.map((OcrRect r) => r.bottom).reduce(math.max),
);

/// 被检行区域截断的行：沿阅读方向把 [region] 往截断的那头延长一个行厚度的
/// [kOcrSweepGrowthRatio] 倍再检一次（弱候选只框住「モテる女子」，外扩后右边界
/// 正好切在「の」前）。没有行碰到可延长的边界时返回 null。
OcrRect? growOcrSweepRegion(
  OcrRect region,
  List<OcrRect> lines, {
  required bool vertical,
  required int pageWidth,
  required int pageHeight,
}) {
  const double edge = 2;
  double left = region.left;
  double top = region.top;
  double right = region.right;
  double bottom = region.bottom;
  for (final OcrRect line in lines) {
    final double step =
        kOcrSweepGrowthRatio * ocrLineThickness(line, vertical: vertical);
    if (vertical) {
      if (line.top <= region.top + edge && region.top > 0) {
        top = math.min(top, region.top - step);
      }
      if (line.bottom >= region.bottom - edge && region.bottom < pageHeight) {
        bottom = math.max(bottom, region.bottom + step);
      }
    } else {
      if (line.left <= region.left + edge && region.left > 0) {
        left = math.min(left, region.left - step);
      }
      if (line.right >= region.right - edge && region.right < pageWidth) {
        right = math.max(right, region.right + step);
      }
    }
  }
  if (left == region.left &&
      top == region.top &&
      right == region.right &&
      bottom == region.bottom) {
    return null;
  }
  return OcrRect(
    left: left,
    top: top,
    right: right,
    bottom: bottom,
  ).clamp(pageWidth.toDouble(), pageHeight.toDouble());
}

/// 外扩区域里检出的行只认和本团弱候选有交叠的：外扩是为了接上候选只框住一半的
/// 行，不是去捡隔壁的字（洗掉覆盖层的用户真实页上，「夏は恋しなきゃ」那团外扩后
/// 会压到标题的「モ」）。
bool _touchesAny(OcrRect line, List<OcrRect> cluster) => cluster.any(
  (OcrRect c) =>
      math.min(line.right, c.right) > math.max(line.left, c.left) &&
      math.min(line.bottom, c.bottom) > math.max(line.top, c.top),
);

/// [rect] 与 [covered] 里任一框的交叠超过自身面积的 [kOcrSweepCoveredRatio]。
bool isOcrRectCovered(OcrRect rect, List<OcrRect> covered) {
  if (rect.area <= 0) return true;
  for (final OcrRect block in covered) {
    final double ix =
        math.min(rect.right, block.right) - math.max(rect.left, block.left);
    final double iy =
        math.min(rect.bottom, block.bottom) - math.max(rect.top, block.top);
    if (ix > 0 && iy > 0 && ix * iy >= kOcrSweepCoveredRatio * rect.area) {
      return true;
    }
  }
  return false;
}

/// 补检块的文字门槛：平均置信度够高、日文字够多且占多数。
bool acceptOcrSweepText(String text, double confidence) {
  if (confidence < kOcrSweepMinConfidence) return false;
  final String visible = text.replaceAll(RegExp(r'\s'), '');
  if (visible.isEmpty) return false;
  final int japanese = _japaneseChar.allMatches(visible).length;
  return japanese >= kOcrSweepMinJapaneseChars &&
      japanese >= kOcrSweepMinJapaneseRatio * visible.length;
}

/// 弱候选聚团：[regions] 按分数从高到低给出，与某团外接框的间距（横纵两个方向的
/// 空隙取大者，交叠时为负）不超过两者较小短边的 [kOcrSweepClusterGapRatio] 倍、且
/// 并进去之后团的面积不超过 [maxArea] 的团里，并进间距最小（交叠最深）的那一团，
/// 一个都没有就另起一团。按「第一个够得着的」并会让标题的「モ」被隔壁先建的
/// 「夏は恋しなきゃ」那团抢走。标题「モテる女子の」被检测器拆成的几个
/// 半行框、和下一行「オキテ」就这样聚到一起；面积上限挡住低分框互相压成一串、
/// 把整页连成一团。
List<List<DetectedTextRegion>> clusterOcrSweepCandidates(
  List<DetectedTextRegion> regions, {
  required double maxArea,
}) {
  final List<List<DetectedTextRegion>> clusters = <List<DetectedTextRegion>>[];
  final List<OcrRect> unions = <OcrRect>[];
  for (final DetectedTextRegion region in regions) {
    final OcrRect rect = region.rect;
    int target = -1;
    double bestGap = double.infinity;
    for (int i = 0; i < clusters.length; i++) {
      final OcrRect u = unions[i];
      final double gap = math.max(
        math.max(u.left, rect.left) - math.min(u.right, rect.right),
        math.max(u.top, rect.top) - math.min(u.bottom, rect.bottom),
      );
      final double limit =
          kOcrSweepClusterGapRatio *
          math.min(
            math.min(u.width, u.height),
            math.min(rect.width, rect.height),
          );
      if (gap <= limit &&
          gap < bestGap &&
          _union(<OcrRect>[u, rect]).area <= maxArea) {
        target = i;
        bestGap = gap;
      }
    }
    if (target < 0) {
      clusters.add(<DetectedTextRegion>[region]);
      unions.add(rect);
    } else {
      clusters[target].add(region);
      unions[target] = _union(<OcrRect>[unions[target], rect]);
    }
  }
  return clusters;
}

/// 块方向：检出的行先按长度投票（[voteOcrLineOrientation]）；全是近方形的单字
/// （字距大，行检测逐字断开）投不出票时，看按哪个方向合并碎片能并成更少的行——
/// 两列竖排按竖排合并是 2 条、按横排合并是一字一行；平局才按外形猜。
bool pickOcrSweepOrientation(List<OcrRect> lines, OcrRect union) {
  final bool? voted = voteOcrLineOrientation(lines);
  if (voted != null) return voted;
  final int asVertical = mergeOcrLineFragments(lines, vertical: true).length;
  final int asHorizontal = mergeOcrLineFragments(lines, vertical: false).length;
  if (asVertical != asHorizontal) return asVertical < asHorizontal;
  return isVerticalBlock(union);
}
