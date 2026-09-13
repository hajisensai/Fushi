/// 按块方向路由的识别器：竖排块整块喂 manga-ocr，横排块切行后横行走 PP-OCRv6。
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
/// 横排路径：块内 PP det 切行 → 振假名过滤 → 阅读顺序 → 竖行仍喂 manga-ocr、
/// 横行走 PP rec → 拼接。PP 什么都没检到 / 拼出来是空串 → 回落整块 manga-ocr
/// （宁可幻觉也不丢块：块在 manga.json 里没了用户连点都点不到）。
library;

import 'dart:math' as math;

import 'package:image/image.dart' as img;

import 'package:fushi_engine/ocr/ocr_types.dart';
import 'package:fushi_engine/ocr/ppocr_line_detector.dart';
import 'package:fushi_engine/ocr/ppocr_line_recognizer.dart';

/// 竖行喂 manga-ocr 前四周各留的像素边距（对拍脚本同值）。
const int kRoutingLinePadding = 4;

/// 横排路径判据：宽 ≥ 高。与 `isVerticalBlock`（1.25）刻意不同——那是 manga.json
/// 的展示口径；这里要的是「肯定不是一列竖排」的保守判定，1.0~1.25 之间的近方块
/// （「は？」「宮城！」这类短句）继续走 manga-ocr。
bool routesToHorizontalPath(OcrRect box) => box.width >= box.height;

class RoutingOcrRecognizer implements OcrRecognizer {
  RoutingOcrRecognizer({
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
  Future<String> recognize(img.Image page, OcrRect box) async {
    if (!routesToHorizontalPath(box)) {
      return _mangaOcr.recognize(page, box);
    }
    final String routed = await _recognizeHorizontalBlock(page, box);
    if (routed.isNotEmpty) {
      return routed;
    }
    return _mangaOcr.recognize(page, box);
  }

  Future<String> _recognizeHorizontalBlock(img.Image page, OcrRect box) async {
    final OcrRect clamped = box.clamp(
      page.width.toDouble(),
      page.height.toDouble(),
    );
    final int x = clamped.left.floor();
    final int y = clamped.top.floor();
    final int w = math.min(math.max(1, clamped.width.ceil()), page.width - x);
    final int h = math.min(math.max(1, clamped.height.ceil()), page.height - y);
    if (w <= 0 || h <= 0) {
      return '';
    }
    final img.Image crop = img.copyCrop(page, x: x, y: y, width: w, height: h);
    final List<PpTextLine> lines = orderLinesForReading(
      filterThinLines(await _lineDetector.detect(crop)),
    );
    final StringBuffer out = StringBuffer();
    for (final PpTextLine line in lines) {
      final OcrRect r = line.rect.clamp(w.toDouble(), h.toDouble());
      if (r.width < 1 || r.height < 1) {
        continue;
      }
      if (line.vertical) {
        // 竖行回到页面坐标、外扩边距，仍由 manga-ocr 识别。
        out.write(
          await _mangaOcr.recognize(
            page,
            OcrRect(
              left: x + r.left - kRoutingLinePadding,
              top: y + r.top - kRoutingLinePadding,
              right: x + r.right + kRoutingLinePadding,
              bottom: y + r.bottom + kRoutingLinePadding,
            ),
          ),
        );
        continue;
      }
      final int lx = r.left.floor();
      final int ly = r.top.floor();
      final img.Image lineCrop = img.copyCrop(
        crop,
        x: lx,
        y: ly,
        width: math.min(math.max(1, r.width.ceil()), w - lx),
        height: math.min(math.max(1, r.height.ceil()), h - ly),
      );
      out.write(await _lineRecognizer.recognizeLine(lineCrop));
    }
    return out.toString();
  }
}
