/// 漫画 OCR 子系统共享类型：几何、检测/识别结果与窄接口。
///
/// 本层没有任何 UI，也不直接依赖 ONNX runtime —— 推理经由
/// `ocr_inference.dart` 的 [OcrSession] 抽象注入，方便单元测试用 fake。
library;

import 'dart:math' as math;

import 'package:image/image.dart' as img;

/// 轴对齐矩形（原图像素坐标，left/top 含、right/bottom 不含语义不强求，
/// 只要求 right >= left、bottom >= top）。
class OcrRect {
  const OcrRect({
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
  });

  final double left;
  final double top;
  final double right;
  final double bottom;

  double get width => math.max(0, right - left);
  double get height => math.max(0, bottom - top);
  double get area => width * height;
  double get centerX => (left + right) / 2;
  double get centerY => (top + bottom) / 2;

  bool containsPoint(double x, double y) =>
      x >= left && x <= right && y >= top && y <= bottom;

  /// 与 [other] 的交并比。
  double iou(OcrRect other) {
    final double ix =
        math.max(0, math.min(right, other.right) - math.max(left, other.left));
    final double iy =
        math.max(0, math.min(bottom, other.bottom) - math.max(top, other.top));
    final double inter = ix * iy;
    if (inter <= 0) {
      return 0;
    }
    final double union = area + other.area - inter;
    return union <= 0 ? 0 : inter / union;
  }

  /// 纵向区间是否与 [other] 重叠（用于行/列聚类）。
  bool verticalOverlaps(OcrRect other) =>
      math.min(bottom, other.bottom) > math.max(top, other.top);

  /// 横向区间是否与 [other] 重叠。
  bool horizontalOverlaps(OcrRect other) =>
      math.min(right, other.right) > math.max(left, other.left);

  OcrRect clamp(double maxWidth, double maxHeight) => OcrRect(
        left: left.clamp(0, maxWidth),
        top: top.clamp(0, maxHeight),
        right: right.clamp(0, maxWidth),
        bottom: bottom.clamp(0, maxHeight),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'left': left,
        'top': top,
        'right': right,
        'bottom': bottom,
      };

  static OcrRect fromJson(Map<String, dynamic> json) => OcrRect(
        left: (json['left'] as num).toDouble(),
        top: (json['top'] as num).toDouble(),
        right: (json['right'] as num).toDouble(),
        bottom: (json['bottom'] as num).toDouble(),
      );

  @override
  String toString() =>
      'OcrRect(${left.toStringAsFixed(1)}, ${top.toStringAsFixed(1)}, '
      '${right.toStringAsFixed(1)}, ${bottom.toStringAsFixed(1)})';
}

/// 检测器输出的单个文字区域（坐标已反变换回原图像素）。
class DetectedTextRegion {
  const DetectedTextRegion({
    required this.rect,
    required this.score,
    required this.classId,
    required this.insideBubble,
  });

  final OcrRect rect;
  final double score;

  /// RT-DETR 类别：1 = text_bubble（气泡内文字）、2 = text_free（气泡外文字）。
  /// 0 = bubble 不会作为文字区域出现，仅用于 [insideBubble] 判定。
  final int classId;

  /// 文字块中心是否落在某个 bubble 框内。
  final bool insideBubble;
}

/// 单页检测结果。
class PageDetections {
  const PageDetections({required this.textRegions, required this.bubbles});

  final List<DetectedTextRegion> textRegions;

  /// bubble（类别 0）框，仅用于内/外判定与后续 UI 需要。
  final List<OcrRect> bubbles;
}

/// 识别 + 排序之后的最终文字块（供上层消费 / 缓存序列化）。
class OcrBlock {
  const OcrBlock({
    required this.box,
    required this.vertical,
    required this.lines,
    this.score = 0,
    this.insideBubble = false,
  });

  final OcrRect box;

  /// 竖排判定（长宽比启发式，见 pipeline）。
  final bool vertical;

  /// 识别文本；manga-ocr 对整块输出单串，故通常只有一个元素。
  /// 语义对齐 mokuro 的 `blocks[].lines`。
  final List<String> lines;

  final double score;
  final bool insideBubble;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'box': box.toJson(),
        'vertical': vertical,
        'lines': lines,
        'score': score,
        'insideBubble': insideBubble,
      };

  static OcrBlock fromJson(Map<String, dynamic> json) => OcrBlock(
        box: OcrRect.fromJson(json['box'] as Map<String, dynamic>),
        vertical: json['vertical'] as bool,
        lines: (json['lines'] as List<dynamic>).cast<String>(),
        score: (json['score'] as num?)?.toDouble() ?? 0,
        insideBubble: json['insideBubble'] as bool? ?? false,
      );
}

/// 单页 OCR 结果（阅读顺序已排好）。
class OcrPageResult {
  const OcrPageResult({
    required this.pageIndex,
    required this.imageWidth,
    required this.imageHeight,
    required this.blocks,
  });

  final int pageIndex;
  final int imageWidth;
  final int imageHeight;
  final List<OcrBlock> blocks;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'pageIndex': pageIndex,
        'imageWidth': imageWidth,
        'imageHeight': imageHeight,
        'blocks': blocks.map((OcrBlock b) => b.toJson()).toList(),
      };

  static OcrPageResult fromJson(Map<String, dynamic> json) => OcrPageResult(
        pageIndex: json['pageIndex'] as int,
        imageWidth: json['imageWidth'] as int,
        imageHeight: json['imageHeight'] as int,
        blocks: (json['blocks'] as List<dynamic>)
            .map((dynamic b) => OcrBlock.fromJson(b as Map<String, dynamic>))
            .toList(),
      );
}

/// 检测器窄接口（pipeline 依赖它而非具体实现，测试可 fake）。
abstract interface class OcrDetector {
  Future<PageDetections> detect(img.Image page);
}

/// 识别器窄接口：对页面上的一个框做识别，返回文本。
abstract interface class OcrRecognizer {
  Future<String> recognize(img.Image page, OcrRect box);
}
