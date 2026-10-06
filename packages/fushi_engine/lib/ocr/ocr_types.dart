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
    final double ix = math.max(
      0,
      math.min(right, other.right) - math.max(left, other.left),
    );
    final double iy = math.max(
      0,
      math.min(bottom, other.bottom) - math.max(top, other.top),
    );
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
  const PageDetections({
    required this.textRegions,
    required this.bubbles,
    this.weakTextRegions = const <DetectedTextRegion>[],
  });

  final List<DetectedTextRegion> textRegions;

  /// bubble（类别 0）框，仅用于内/外判定与后续 UI 需要。
  final List<OcrRect> bubbles;

  /// 没过正式阈值、但过了弱阈值的文字框（未做 NMS）：不直接识别，只给补检
  /// （`page_text_sweep.dart`）当候选——字距稀疏的装饰性标题常落在这一档。
  final List<DetectedTextRegion> weakTextRegions;
}

/// 识别 + 排序之后的最终文字块（供上层消费 / 缓存序列化）。
class OcrBlock {
  const OcrBlock({
    required this.box,
    required this.vertical,
    required this.lines,
    this.lineBoxes,
    this.score = 0,
    this.insideBubble = false,
    this.confidence,
  });

  final OcrRect box;

  /// 竖排判定（长宽比启发式，见 pipeline）。
  final bool vertical;

  /// 识别文本，阅读序。有行几何时一列（竖排）/一行（横排）一个元素，与
  /// [lineBoxes] 等长同序；没有时是整块一串（旧缓存、行检测什么也没检到）。
  /// 语义对齐 mokuro 的 `blocks[].lines`。
  final List<String> lines;

  /// 每行在页面上的框（页面像素坐标），对应 mokuro 的 `lines_coords`。阅读器
  /// 覆盖层靠它把字落到正确的列上；null = 没有行几何，覆盖层退回整块均铺。
  final List<OcrRect>? lineBoxes;

  final double score;
  final bool insideBubble;

  /// 识别置信度（0–1，越高越可信）；null = 识别器没给（旧缓存 / 不出分的
  /// 识别器）。与检测分 [score] 是两回事：那个说「这里有字」，这个说「字读对了」。
  /// 口径见 [OcrRecognition.confidence]。
  final double? confidence;

  /// 整块文本（各行按阅读序拼接）。
  String get text => lines.join();

  Map<String, dynamic> toJson() => <String, dynamic>{
        'box': box.toJson(),
        'vertical': vertical,
        'lines': lines,
        if (lineBoxes != null)
          'lineBoxes': <Map<String, dynamic>>[
            for (final OcrRect rect in lineBoxes!) rect.toJson(),
          ],
        'score': score,
        'insideBubble': insideBubble,
        if (confidence != null) 'confidence': confidence,
      };

  static OcrBlock fromJson(Map<String, dynamic> json) {
    final List<String> lines = (json['lines'] as List<dynamic>).cast<String>();
    final List<dynamic>? rawBoxes = json['lineBoxes'] as List<dynamic>?;
    // 行框必须与行一一对应；对不上（手改 / 截断的缓存）就当没有行几何。
    final List<OcrRect>? lineBoxes =
        rawBoxes != null && rawBoxes.length == lines.length
            ? <OcrRect>[
                for (final dynamic raw in rawBoxes)
                  OcrRect.fromJson(raw as Map<String, dynamic>),
              ]
            : null;
    return OcrBlock(
      box: OcrRect.fromJson(json['box'] as Map<String, dynamic>),
      vertical: json['vertical'] as bool,
      lines: lines,
      lineBoxes: lineBoxes,
      score: (json['score'] as num?)?.toDouble() ?? 0,
      insideBubble: json['insideBubble'] as bool? ?? false,
      confidence: (json['confidence'] as num?)?.toDouble(),
    );
  }
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

/// [ScoredOcrRecognizer.recognizeScored] 的结果。
typedef ScoredOcrText = ({String text, double? confidence});

/// 可选能力：识别时顺带给出置信度（见 [OcrRecognition.confidence]）。
///
/// 与 [OcrRecognizer.recognize] 必须读出同一段文字——它只是多交一个分数，
/// 调用方不会因为要分数而换一条解码路径。
abstract interface class ScoredOcrRecognizer implements OcrRecognizer {
  Future<ScoredOcrText> recognizeScored(img.Image page, OcrRect box);
}

/// 两个可空置信度取较小者（null 视作「不知道」，不拉低另一个）。
double? minOcrConfidence(double? a, double? b) {
  if (a == null) return b;
  if (b == null) return a;
  return a < b ? a : b;
}

/// 可选的同页批识别能力；没有实现此接口的识别器仍按单框调用。
///
/// 输出必须与 [boxes] 严格同长、同序；未认出文字也用空串占住原位置，
/// 不得在后端过滤或重排。空输入返回空列表。模型内部可再按显存限制分批。
abstract interface class BatchOcrRecognizer implements OcrRecognizer {
  Future<List<String>> recognizeBatch(img.Image page, List<OcrRect> boxes);
}

/// 一个框的识别结果 + 识别过程中确定的排版方向（可选带行几何）。
class OcrRecognition {
  const OcrRecognition({
    required this.text,
    required this.vertical,
    this.lines,
    this.lineBoxes,
    this.confidence,
  }) : assert((lines == null) == (lineBoxes == null));

  final String text;
  final bool vertical;

  /// 识别置信度（0–1）；null = 识别器不出分。
  ///
  /// 口径按识别器不同，只用来挑「可能读错的块」，不跨识别器比大小：逐列 CTC 取
  /// 各吐字帧 softmax 概率的**最小值**（一个字读糊就该被挑出来），manga-ocr 取
  /// beam 结果的逐 token 概率**几何平均**（beam 只留下了整句对数概率）。多行块取
  /// 各行最小值。
  final double? confidence;

  /// 换掉置信度的副本（路由层把子识别器的分数挂回排版结果）。
  OcrRecognition withConfidence(double? value) => OcrRecognition(
        text: text,
        vertical: vertical,
        lines: lines,
        lineBoxes: lineBoxes,
        confidence: value,
      );

  /// 按行切开的 [text]（阅读序，`lines.join() == text`），与 [lineBoxes]
  /// 等长；null = 识别器没给行几何，pipeline 落成整块单行。
  final List<String>? lines;

  /// 每行的页面坐标框，见 [OcrBlock.lineBoxes]。
  final List<OcrRect>? lineBoxes;
}

/// 可选能力：识别时顺带判定了块方向（例如块内切行后按行投票）的识别器。
///
/// 方向只该有一个拥有者：长宽比只是检测框的外形，两列竖排气泡常常宽 ≥ 高，
/// 按外形猜会把它标成横排（BUG-2783）。实现了本接口的识别器，pipeline 直接
/// 采用它给的方向。输出与 [boxes] 严格同长、同序。
abstract interface class OrientedOcrRecognizer implements OcrRecognizer {
  Future<List<OcrRecognition>> recognizeOriented(
    img.Image page,
    List<OcrRect> boxes,
  );
}
