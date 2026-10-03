/// 漫画逐列 CTC 识别器：块内检出列/行 → 按行长投票定块方向 → 去振假名 → 合并同列
/// 碎片 → 阅读序 → 逐列交 CTC 行识别器（竖列先逆时针转 90°，当横行读）→ 逐行
/// 文本与行框直接交回，不再按字格估算切分（`ocr_line_layout.dart` 的
/// [layoutOcrTextOnLines] 只服务整块识别的模型）。
///
/// 为什么要它：2026-09-30 用用户真实卷《君が一等星に光るまで 01》80 页（485 块、
/// 5564 个参考字，参考为 Google Lens）实测，漫画微调的 PP-OCRv6 CTC 识别器
/// （Kellenok/PP-OCRv6_manga 的 rec v0.2，与随包的 `ppocrv6_small_rec.onnx` 同
/// 输入契约、同 18710 词表）逐列识别 CER 14.86%，manga-ocr 15.82%；每列约 11 ms，
/// 比 manga-ocr 快约 30 倍。逐列识别天然给出每列的文本与列框，选词几何不用估算。
/// 实测与选型见 `docs/reviews/2026-09-30-manga-ocr-select-speed.md`。
///
/// 两条生死线（同一次实测，注音密集、气泡宽扁的另一套 21 页上最明显）：
/// - **振假名**：CTC 会把没滤掉的注音列当正文读进去（「ここがねんいじょうまえ
///   二千年以上前…」），manga-ocr 训练时就学会了忽略注音——所以逐列识别前必须
///   先 [dropOcrRubyLines]。
/// - **方向**：块方向判错时整块乱码（竖列没转向就被当横行读，或反过来），manga-ocr
///   对方向不敏感——所以方向按检出行的长度投票（[voteOcrLineOrientation]），不按
///   块外形猜；投票结论同时决定去注音的口径、阅读序和要不要转向。
///
/// 行识别器就是现有的 [PpOcrLineRecognizer]（只认横行，竖列转向后交它），只是会话
/// 换成漫画权重——用哪套权重由装配层决定，本类不知道。
library;

import 'package:image/image.dart' as img;

import 'package:fushi_engine/ocr/manga_ocr_pipeline.dart';
import 'package:fushi_engine/ocr/ocr_line_layout.dart';
import 'package:fushi_engine/ocr/ocr_types.dart';
import 'package:fushi_engine/ocr/ppocr_line_detector.dart';
import 'package:fushi_engine/ocr/ppocr_line_recognizer.dart';

class CtcColumnOcrRecognizer implements LineOcrRecognizer {
  CtcColumnOcrRecognizer({
    required PpOcrLineDetector lineDetector,
    required PpOcrLineRecognizer lineRecognizer,
  }) : _lineDetector = lineDetector,
       _lineRecognizer = lineRecognizer;

  final PpOcrLineDetector _lineDetector;
  final PpOcrLineRecognizer _lineRecognizer;

  /// 单框识别（路由横排路径里的竖行也走这里）：块方向先按外形猜，再由检出的
  /// 行改判。
  @override
  Future<String> recognize(img.Image page, OcrRect box) async {
    final OcrRecognition recognition = await recognizeWithLines(
      page,
      box,
      vertical: isVerticalBlock(box),
    );
    return recognition.text;
  }

  @override
  Future<OcrRecognition> recognizeWithLines(
    img.Image page,
    OcrRect box, {
    required bool vertical,
    List<OcrRect>? lineHints,
  }) async {
    final List<OcrRect> detected =
        lineHints ?? await _lineDetector.detectInBlock(page, box);
    // 方向按检出行长度投票（宽扁的多列竖排常被外形或碎片带偏），没有明确的行时
    // 保持调用方的判断。
    final bool blockVertical = voteOcrLineOrientation(detected) ?? vertical;
    final List<OcrRect> lines = orderOcrLinesForReading(
      mergeOcrLineFragments(
        dropOcrRubyLines(detected, vertical: blockVertical),
        vertical: blockVertical,
      ),
      vertical: blockVertical,
    );
    if (lines.isEmpty) {
      // 一行都没检到：整块当一行读（竖排同样先转向），没有行几何可给。
      final ({String text, double? confidence}) whole = await _readRegion(
        page,
        box,
        vertical: blockVertical,
      );
      return OcrRecognition(
        text: whole.text,
        vertical: blockVertical,
        confidence: whole.confidence,
      );
    }
    final List<String> texts = <String>[];
    final List<OcrRect> boxes = <OcrRect>[];
    double? confidence;
    for (final OcrRect line in lines) {
      final OcrRect region = line.clamp(
        page.width.toDouble(),
        page.height.toDouble(),
      );
      if (region.width < 1 || region.height < 1) continue;
      final ({String text, double? confidence}) read = await _readRegion(
        page,
        region,
        vertical: blockVertical,
      );
      // 读不出字的行连同行框一起丢，`lines` 与 `lineBoxes` 仍一一对应。
      if (read.text.isEmpty) continue;
      texts.add(read.text);
      boxes.add(region);
      confidence = minOcrConfidence(confidence, read.confidence);
    }
    // 检到了行却一个字都没读出：不再整块重读——多列块当一行读只会得到串列的乱码。
    if (texts.isEmpty) {
      return OcrRecognition(text: '', vertical: blockVertical);
    }
    return OcrRecognition(
      text: texts.join(),
      vertical: blockVertical,
      lines: texts,
      lineBoxes: boxes,
      confidence: confidence,
    );
  }

  /// 裁出 [region]（页面坐标）交行识别器。竖排先逆时针转 90°：列顶转到左边，
  /// 从上往下读的列变成从左往右读的横行（PaddleOCR 对竖行同样是 `np.rot90`）。
  Future<({String text, double? confidence})> _readRegion(
    img.Image page,
    OcrRect region, {
    required bool vertical,
  }) async {
    final OcrBlockCrop? crop = cropOcrBlock(page, region);
    if (crop == null) return (text: '', confidence: null);
    // copyRotate 的正角是顺时针，-90 即逆时针 90°。
    return _lineRecognizer.recognizeLineScored(
      vertical ? img.copyRotate(crop.image, angle: -90) : crop.image,
    );
  }
}
