/// 按块方向路由的识别器：竖排块整块喂块识别器，横排块切行后横行走 PP-OCRv6。
///
/// 命名说明：参数 / 字段名 `mangaOcr` 是历史名，指「整块识别器」——kha-white
/// manga-ocr 本地模型已于 2026-10 删除，现在传进来的是逐列 CTC 或 Baberu。下文
/// 的路由实测是当年在 manga-ocr 上做的，判据（块比它高还宽 → 横排路径）不变。
///
/// 为什么不是「一律切行」：2026-09-13 用用户真实页复测（「週に一度クラスメイトを
/// 買う話」mihon 下载 844×1200 + 「幼なじみが絶対に結ばれる百合アンソロジー」
/// 1444×2048，共 100+ 块）——
///
/// - 竖排正文块：整块喂 manga-ocr 几乎全对；PP det 切行反而会把一列切断
///   （「えっそれ私が食べていいの？」→「食べて、いつ、いいの？」）。
/// - 横排块（扉页简介、人物介绍、作者栏）：manga-ocr 把 800×190 的段落 squish 进
///   224×224 后整段幻觉；即使切好行再喂 manga-ocr 照样幻觉（方案 E）；PP det+rec
///   逐字全对。
///
/// 所以路由判据只有一条：**块比它高还宽 → 横排路径**，其余原样。竖排块的路径
/// 与本类出现前逐字节等价，存量表现零变化。
///
/// 横排路径：块内 PP det 切行 → 振假名过滤 → **按行投票定块方向** →
/// 横行占多数才逐行识别（竖行仍喂 manga-ocr、横行走 PP rec）→ 拼接。PP 什么都
/// 没检到 / 拼出来是空串 → 回落整块 manga-ocr（宁可幻觉也不丢块：块在
/// manga.json 里没了用户连点都点不到）。
///
/// 竖行占多数 = 宽 ≥ 高的**多列竖排**（两列台词的气泡常常比高还宽）：整块交
/// manga-ocr，与竖长块同一条已验证路径；逐列切反而会被 PP 切断、短列误判成
/// 横行（BUG-2783）。块方向由这里一次决定并经 [OrientedOcrRecognizer] 交回
/// pipeline，不再由 pipeline 按长宽比另猜。
///
/// 行几何（选词命中）：整块交 manga-ocr 的块，识别**文本不变**，识别完再用
/// PP det 检出的列把文本按列长切开（`ocr_line_layout.dart`），连同列框交回
/// pipeline 落成 `lines` + `lineBoxes`——阅读器覆盖层据此把字落到正确的列上。
/// 路由时已经检过行的宽块直接复用那次结果，只有竖长块多跑一次 PP det。横排
/// 路径本来就逐行识别，逐行文本与行框原样交回。
///
/// 主识别器本身逐行识别（[LineOcrRecognizer]，如 `ctc_column_ocr_recognizer.dart`
/// 的逐列 CTC）时，整块交它的块直接采用它逐行读出的文本与行框（路由时检过的行
/// 作为 `lineHints` 交给它复用），不再按列长估算切分。
library;

import 'dart:math' as math;

import 'package:image/image.dart' as img;

import 'package:fushi_engine/ocr/manga_ocr_pipeline.dart';
import 'package:fushi_engine/ocr/ocr_line_layout.dart';
import 'package:fushi_engine/ocr/ocr_types.dart';
import 'package:fushi_engine/ocr/ppocr_line_detector.dart';
import 'package:fushi_engine/ocr/ppocr_line_recognizer.dart';

/// 竖行喂 manga-ocr 前四周各留的像素边距（对拍脚本同值）。
const int kRoutingLinePadding = 4;

/// 横排路径判据：宽 ≥ 高。与 `isVerticalBlock`（1.25）刻意不同——那是 manga.json
/// 的展示口径；这里要的是「肯定不是一列竖排」的保守判定，1.0~1.25 之间的近方块
/// （「は？」「宮城！」这类短句）继续走 manga-ocr。
bool routesToHorizontalPath(OcrRect box) => box.width >= box.height;

/// `_routeBlock` 的结论：识别结果（`text` 为空 = 整块交 manga-ocr）+ 路由时已检出
/// 的原始行框（页面坐标），供整块识别后的排版复用；null = 路由没跑行检测。
class _RoutedBlock {
  const _RoutedBlock(this.recognition, {this.lineHints});

  final OcrRecognition recognition;
  final List<OcrRect>? lineHints;
}

class RoutingOcrRecognizer
    implements OrientedOcrRecognizer, LineLayoutOcrRecognizer {
  factory RoutingOcrRecognizer({
    required OcrRecognizer mangaOcr,
    required PpOcrLineDetector lineDetector,
    required PpOcrLineRecognizer lineRecognizer,
  }) {
    // 只向 pipeline 暴露真实可用的批处理能力。原版 ONNX / Baberu 不因此
    // 被合成一个假 batch，仍保留逐框调用和取消检查。
    if (mangaOcr is BatchOcrRecognizer) {
      return _BatchRoutingOcrRecognizer(
        mangaOcr: mangaOcr,
        lineDetector: lineDetector,
        lineRecognizer: lineRecognizer,
      );
    }
    return RoutingOcrRecognizer._(
      mangaOcr: mangaOcr,
      lineDetector: lineDetector,
      lineRecognizer: lineRecognizer,
    );
  }

  RoutingOcrRecognizer._({
    required OcrRecognizer mangaOcr,
    required PpOcrLineDetector lineDetector,
    required PpOcrLineRecognizer lineRecognizer,
  }) : _mangaOcr = mangaOcr,
       _lineDetector = lineDetector,
       _lineRecognizer = lineRecognizer;

  final OcrRecognizer _mangaOcr;
  final PpOcrLineDetector _lineDetector;
  final PpOcrLineRecognizer _lineRecognizer;

  @override
  Future<String> recognize(img.Image page, OcrRect box) async =>
      (await _recognizeOne(page, box)).text;

  @override
  Future<List<OcrRecognition>> recognizeOriented(
    img.Image page,
    List<OcrRect> boxes,
  ) async => <OcrRecognition>[
    for (final OcrRect box in boxes) await _recognizeOne(page, box),
  ];

  @override
  Future<OcrRecognition> layoutRecognized(
    img.Image page,
    OcrRect box,
    String text, {
    required bool vertical,
  }) => _withLineLayout(page, box, text, vertical: vertical);

  Future<OcrRecognition> _recognizeOne(img.Image page, OcrRect box) async {
    final _RoutedBlock routed = await _routeBlock(page, box);
    if (routed.recognition.text.isNotEmpty) return routed.recognition;
    final OcrRecognizer primary = _mangaOcr;
    if (primary is LineOcrRecognizer) {
      // 逐行识别的主识别器：逐行文本与行框直接采用，不再按列长估算切分。
      return primary.recognizeWithLines(
        page,
        box,
        vertical: routed.recognition.vertical,
        lineHints: routed.lineHints,
      );
    }
    final ScoredOcrText read = await _readScored(primary, page, box);
    return (await _withLineLayout(
      page,
      box,
      read.text,
      vertical: routed.recognition.vertical,
      lineHints: routed.lineHints,
    )).withConfidence(read.confidence);
  }

  /// 主识别器出分就取分，不出分的（Baberu 等）置信度为 null。
  static Future<ScoredOcrText> _readScored(
    OcrRecognizer recognizer,
    img.Image page,
    OcrRect box,
  ) async {
    if (recognizer is ScoredOcrRecognizer) {
      return recognizer.recognizeScored(page, box);
    }
    return (text: await recognizer.recognize(page, box), confidence: null);
  }

  /// 整块识别出的 [text] 按块内的列/行切开，带上行几何。
  ///
  /// [lineHints] 是路由时已检出的原始行框（页面坐标，未滤振假名）；null 时在这里
  /// 跑一次行检测。没检到行 / 没有可见字时原样返回单串与原方向（pipeline 落成
  /// 整块单行）。
  Future<OcrRecognition> _withLineLayout(
    img.Image page,
    OcrRect box,
    String text, {
    required bool vertical,
    List<OcrRect>? lineHints,
  }) async {
    if (text.isEmpty) return OcrRecognition(text: text, vertical: vertical);
    final List<OcrRect> rects =
        lineHints ?? await _lineDetector.detectInBlock(page, box);
    // 方向按检出行长度投票（宽扁的多列竖排常被外形或碎片带偏），没有明确的行时
    // 保持传入的方向；排版与块方向同一个结论。
    final bool layoutVertical = voteOcrLineOrientation(rects) ?? vertical;
    final OcrLineLayout? layout = layoutOcrTextOnLines(
      text,
      orderOcrLinesForReading(
        mergeOcrLineFragments(
          dropOcrRubyLines(rects, vertical: layoutVertical),
          vertical: layoutVertical,
        ),
        vertical: layoutVertical,
      ),
      vertical: layoutVertical,
    );
    if (layout == null) return OcrRecognition(text: text, vertical: vertical);
    return OcrRecognition(
      text: text,
      vertical: layoutVertical,
      lines: layout.lines,
      lineBoxes: layout.boxes,
    );
  }

  /// 定块方向，横排块顺带逐行识别（逐行文本 + 行框一并交回）。结论里 `text`
  /// 为空 = 整块交 manga-ocr，`vertical` 恒为该块的方向结论。
  Future<_RoutedBlock> _routeBlock(img.Image page, OcrRect box) async {
    if (!routesToHorizontalPath(box)) {
      return _RoutedBlock(
        OcrRecognition(text: '', vertical: isVerticalBlock(box)),
      );
    }
    final OcrBlockCrop? crop = cropOcrBlock(page, box);
    if (crop == null) {
      return const _RoutedBlock(OcrRecognition(text: '', vertical: false));
    }
    final int x = crop.x;
    final int y = crop.y;
    final int w = crop.image.width;
    final int h = crop.image.height;
    final List<PpTextLine> raw = await _lineDetector.detect(crop.image);
    final List<PpTextLine> detected = filterThinLines(raw);
    // 排版要看到全部检出行（方向投票、注音判定），交回未过滤的原始结果。
    final List<OcrRect> lineHints = <OcrRect>[
      for (final PpTextLine line in raw) crop.toPage(line.rect),
    ];
    if (linesAreVerticalMajority(detected)) {
      return _RoutedBlock(
        const OcrRecognition(text: '', vertical: true),
        lineHints: lineHints,
      );
    }
    final List<PpTextLine> lines = orderLinesForReading(detected);
    final List<String> texts = <String>[];
    final List<OcrRect> boxes = <OcrRect>[];
    double? confidence;
    for (final PpTextLine line in lines) {
      final OcrRect r = line.rect.clamp(w.toDouble(), h.toDouble());
      if (r.width < 1 || r.height < 1) {
        continue;
      }
      final ScoredOcrText lineRead;
      if (line.vertical) {
        // 竖行回到页面坐标、外扩边距，仍由 manga-ocr 识别。
        lineRead = await _readScored(
          _mangaOcr,
          page,
          OcrRect(
            left: x + r.left - kRoutingLinePadding,
            top: y + r.top - kRoutingLinePadding,
            right: x + r.right + kRoutingLinePadding,
            bottom: y + r.bottom + kRoutingLinePadding,
          ),
        );
      } else {
        final int lx = r.left.floor();
        final int ly = r.top.floor();
        final img.Image lineCrop = img.copyCrop(
          crop.image,
          x: lx,
          y: ly,
          width: math.min(math.max(1, r.width.ceil()), w - lx),
          height: math.min(math.max(1, r.height.ceil()), h - ly),
        );
        lineRead = await _lineRecognizer.recognizeLineScored(lineCrop);
      }
      if (lineRead.text.isEmpty) continue;
      texts.add(lineRead.text);
      boxes.add(crop.toPage(r));
      confidence = minOcrConfidence(confidence, lineRead.confidence);
    }
    final String text = texts.join();
    return _RoutedBlock(
      OcrRecognition(
        text: text,
        vertical: false,
        lines: text.isEmpty ? null : texts,
        lineBoxes: text.isEmpty ? null : boxes,
        confidence: text.isEmpty ? null : confidence,
      ),
      lineHints: lineHints,
    );
  }
}

/// 横排 PP 路径保留单块切行，竖框与横排空结果的整框后备合并成一批。
/// 索引表同时保留 PP 结果和空串位置，不让分流改变框与文字的对应关系。
class _BatchRoutingOcrRecognizer extends RoutingOcrRecognizer
    implements BatchOcrRecognizer {
  _BatchRoutingOcrRecognizer({
    required BatchOcrRecognizer mangaOcr,
    required super.lineDetector,
    required super.lineRecognizer,
  }) : _batchMangaOcr = mangaOcr,
       super._(mangaOcr: mangaOcr);

  final BatchOcrRecognizer _batchMangaOcr;

  @override
  Future<List<String>> recognizeBatch(
    img.Image page,
    List<OcrRect> boxes,
  ) async => <String>[
    for (final OcrRecognition r in await recognizeOriented(page, boxes)) r.text,
  ];

  @override
  Future<List<OcrRecognition>> recognizeOriented(
    img.Image page,
    List<OcrRect> boxes,
  ) async {
    final List<_RoutedBlock> routed = <_RoutedBlock>[
      for (final OcrRect box in boxes) await _routeBlock(page, box),
    ];
    final List<OcrRecognition> results = <OcrRecognition>[
      for (final _RoutedBlock block in routed) block.recognition,
    ];
    final List<int> mangaIndices = <int>[
      for (int index = 0; index < results.length; index++)
        if (results[index].text.isEmpty) index,
    ];
    if (mangaIndices.isEmpty) return results;
    final OcrRecognizer primary = _mangaOcr;
    if (primary is LineOcrRecognizer) {
      // 逐行识别的主识别器不走整框批次：逐行文本与行框直接采用（同 _recognizeOne）。
      for (final int slot in mangaIndices) {
        results[slot] = await primary.recognizeWithLines(
          page,
          boxes[slot],
          vertical: results[slot].vertical,
          lineHints: routed[slot].lineHints,
        );
      }
      return results;
    }
    final List<String> mangaResults = await _batchMangaOcr.recognizeBatch(
      page,
      <OcrRect>[for (final int index in mangaIndices) boxes[index]],
    );
    if (mangaResults.length != mangaIndices.length) {
      throw StateError(
        'Routed OCR batch returned ${mangaResults.length} results '
        'for ${mangaIndices.length} regions',
      );
    }
    for (int index = 0; index < mangaIndices.length; index++) {
      final int slot = mangaIndices[index];
      results[slot] = await _withLineLayout(
        page,
        boxes[slot],
        mangaResults[index],
        vertical: results[slot].vertical,
        lineHints: routed[slot].lineHints,
      );
    }
    return results;
  }
}
