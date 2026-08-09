/// 漫画文字/气泡检测器：ogkalu/comic-text-and-bubble-detector（RT-DETR-v2）。
///
/// IO 规格（已核实：HF 模型卡 + 该 repo 的 preprocessor_config.json /
/// config.json + 作者 comic-translate 的 modules/detection/rtdetr_v2.py）：
///
/// - 预处理（RTDetrImageProcessor）：resize 到 640x640（`do_pad=false` ——
///   官方是**不保持长宽比的 squish resize**，非 YOLO 式 letterbox）、
///   `rescale 1/255`、`do_normalize=false`（**没有** mean/std 归一化）。
///   输入张量 `pixel_values` float32 [1,3,640,640]，RGB、CHW。
/// - 原始导出输出：`logits` [1,300,3]（300 = num_queries，3 类）、
///   `pred_boxes` [1,300,4]，cxcywh、相对输入图归一化到 0..1。
/// - 当前下载的 int8 导出把 HuggingFace 后处理包含在图内：输入为 `images` +
///   `orig_target_sizes`，输出 `scores` / `labels` / `boxes`（xyxy）。
///   两种导出都在这里兼容，算法层不依赖某一份模型文件的临时命名。
/// - 后处理（use_focal_loss=true）：对 logits 取 **sigmoid**（非 softmax），
///   按 (query, class) 对过阈值（参考实现默认 0.3），cxcywh -> xyxy 再乘回
///   原图尺寸；DETR 家族查询间本不需要 NMS，这里保留一个轻量 NMS 兜底
///   去重（同类 IoU 过高只留高分）。
/// - 类别：0=bubble（气泡整体）、1=text_bubble（气泡内文字）、
///   2=text_free（气泡外文字）。文字块 = {1,2}；0 仅用于内/外判定。
///
/// 预处理默认走与训练一致的 squish（[LetterboxTransform] 的 pad=0 退化态），
/// 也支持保持长宽比的 letterbox 模式；正反变换统一由 scale/pad 表达。
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'package:fushi/src/ocr/ocr_inference.dart';
import 'package:fushi/src/ocr/ocr_types.dart';

/// RT-DETR 类别 id。
const int kDetClassBubble = 0;
const int kDetClassTextBubble = 1;
const int kDetClassTextFree = 2;

/// 模型输入边长（模型卡：Training Image Size = 640）。
const int kDetInputSize = 640;

/// 原图 -> 模型输入的仿射变换：`dst = src * scale + pad`。
///
/// squish 模式（默认，匹配官方 `do_pad=false` 预处理）：scaleX/scaleY 独立、
/// pad=0；letterbox 模式：等比缩放 + 居中灰边，scaleX == scaleY。
class LetterboxTransform {
  const LetterboxTransform({
    required this.scaleX,
    required this.scaleY,
    required this.padX,
    required this.padY,
    required this.srcWidth,
    required this.srcHeight,
    required this.dstWidth,
    required this.dstHeight,
  });

  final double scaleX;
  final double scaleY;
  final double padX;
  final double padY;
  final int srcWidth;
  final int srcHeight;
  final int dstWidth;
  final int dstHeight;

  double forwardX(double x) => x * scaleX + padX;
  double forwardY(double y) => y * scaleY + padY;
  double inverseX(double x) => (x - padX) / scaleX;
  double inverseY(double y) => (y - padY) / scaleY;
}

/// 计算原图到 [dstWidth]x[dstHeight] 的变换。
LetterboxTransform computeLetterbox(
  int srcWidth,
  int srcHeight, {
  int dstWidth = kDetInputSize,
  int dstHeight = kDetInputSize,
  bool preserveAspect = false,
}) {
  if (srcWidth <= 0 || srcHeight <= 0) {
    throw ArgumentError('invalid source size: ${srcWidth}x$srcHeight');
  }
  if (!preserveAspect) {
    return LetterboxTransform(
      scaleX: dstWidth / srcWidth,
      scaleY: dstHeight / srcHeight,
      padX: 0,
      padY: 0,
      srcWidth: srcWidth,
      srcHeight: srcHeight,
      dstWidth: dstWidth,
      dstHeight: dstHeight,
    );
  }
  final double scale = math.min(dstWidth / srcWidth, dstHeight / srcHeight);
  return LetterboxTransform(
    scaleX: scale,
    scaleY: scale,
    padX: (dstWidth - srcWidth * scale) / 2,
    padY: (dstHeight - srcHeight * scale) / 2,
    srcWidth: srcWidth,
    srcHeight: srcHeight,
    dstWidth: dstWidth,
    dstHeight: dstHeight,
  );
}

/// 按 [transform] 把 [source] 画到目标画布并输出 CHW float32（RGB / 255）。
///
/// letterbox 模式的空白区域填 114 灰（YOLO 惯例）；squish 模式画布被铺满，
/// 填充色无效。
Float32List rtdetrPreprocess(img.Image source, LetterboxTransform transform) {
  final int dstW = transform.dstWidth;
  final int dstH = transform.dstHeight;
  final int scaledW =
      (transform.srcWidth * transform.scaleX).round().clamp(1, dstW);
  final int scaledH =
      (transform.srcHeight * transform.scaleY).round().clamp(1, dstH);

  img.Image canvas;
  final img.Image resized = img.copyResize(
    source,
    width: scaledW,
    height: scaledH,
    interpolation: img.Interpolation.linear,
  );
  if (scaledW == dstW && scaledH == dstH) {
    canvas = resized;
  } else {
    canvas = img.Image(width: dstW, height: dstH);
    img.fill(canvas, color: img.ColorRgb8(114, 114, 114));
    img.compositeImage(
      canvas,
      resized,
      dstX: transform.padX.round(),
      dstY: transform.padY.round(),
    );
  }

  final Float32List chw = Float32List(3 * dstH * dstW);
  final int planeSize = dstH * dstW;
  int index = 0;
  for (int y = 0; y < dstH; y++) {
    for (int x = 0; x < dstW; x++) {
      final img.Pixel pixel = canvas.getPixel(x, y);
      chw[index] = pixel.r / 255.0;
      chw[planeSize + index] = pixel.g / 255.0;
      chw[2 * planeSize + index] = pixel.b / 255.0;
      index++;
    }
  }
  return chw;
}

/// 解码后的原始检测（坐标已反变换回原图像素并 clamp）。
class RawDetection {
  const RawDetection({
    required this.rect,
    required this.score,
    required this.classId,
  });

  final OcrRect rect;
  final double score;
  final int classId;
}

double _sigmoid(double x) => 1 / (1 + math.exp(-x));

/// 解码 RT-DETR 输出。
///
/// [logits]：[numQueries, numClasses]（batch=1 已扁平），**未过 sigmoid**；
/// [boxes]：[numQueries, 4] cxcywh，相对模型输入归一化 0..1。
/// 语义对齐 `RTDetrImageProcessor.post_process_object_detection`
/// （use_focal_loss：sigmoid + 按 (query, class) 过阈值），再经 [transform]
/// 反变换回原图。
List<RawDetection> decodeRtdetrOutputs({
  required Float32List logits,
  required Float32List boxes,
  required LetterboxTransform transform,
  int numQueries = 300,
  int numClasses = 3,
  double scoreThreshold = 0.3,
}) {
  assert(logits.length == numQueries * numClasses);
  assert(boxes.length == numQueries * 4);
  final List<RawDetection> detections = <RawDetection>[];
  for (int q = 0; q < numQueries; q++) {
    for (int c = 0; c < numClasses; c++) {
      final double score = _sigmoid(logits[q * numClasses + c]);
      if (score < scoreThreshold) {
        continue;
      }
      final double cx = boxes[q * 4] * transform.dstWidth;
      final double cy = boxes[q * 4 + 1] * transform.dstHeight;
      final double w = boxes[q * 4 + 2] * transform.dstWidth;
      final double h = boxes[q * 4 + 3] * transform.dstHeight;
      final OcrRect rect = OcrRect(
        left: transform.inverseX(cx - w / 2),
        top: transform.inverseY(cy - h / 2),
        right: transform.inverseX(cx + w / 2),
        bottom: transform.inverseY(cy + h / 2),
      ).clamp(transform.srcWidth.toDouble(), transform.srcHeight.toDouble());
      if (rect.area <= 0) {
        continue;
      }
      detections.add(RawDetection(rect: rect, score: score, classId: c));
    }
  }
  return detections;
}

/// 解码已经在 ONNX 图内完成 sigmoid/top-k/xyxy 转换的 RT-DETR 输出。
List<RawDetection> decodeProcessedRtdetrOutputs({
  required Float32List scores,
  required Float32List labels,
  required Float32List boxes,
  required LetterboxTransform transform,
  double scoreThreshold = 0.3,
}) {
  if (scores.length != labels.length || boxes.length != scores.length * 4) {
    throw StateError(
      'processed detector output shapes disagree: '
      'scores=${scores.length}, labels=${labels.length}, boxes=${boxes.length}',
    );
  }
  final List<RawDetection> detections = <RawDetection>[];
  for (int i = 0; i < scores.length; i++) {
    final double score = scores[i];
    if (score < scoreThreshold) {
      continue;
    }
    final int boxOffset = i * 4;
    final OcrRect rect = OcrRect(
      left: transform.inverseX(boxes[boxOffset]),
      top: transform.inverseY(boxes[boxOffset + 1]),
      right: transform.inverseX(boxes[boxOffset + 2]),
      bottom: transform.inverseY(boxes[boxOffset + 3]),
    ).clamp(transform.srcWidth.toDouble(), transform.srcHeight.toDouble());
    if (rect.area <= 0) {
      continue;
    }
    detections.add(
      RawDetection(
        rect: rect,
        score: score,
        classId: labels[i].round(),
      ),
    );
  }
  return detections;
}

/// 同类贪心 NMS：按分数降序，IoU >= [iouThreshold] 的低分框剔除。
List<RawDetection> applyClassAwareNms(
  List<RawDetection> detections, {
  double iouThreshold = 0.7,
}) {
  final List<RawDetection> sorted = List<RawDetection>.from(detections)
    ..sort((RawDetection a, RawDetection b) => b.score.compareTo(a.score));
  final List<RawDetection> kept = <RawDetection>[];
  for (final RawDetection candidate in sorted) {
    bool suppressed = false;
    for (final RawDetection keep in kept) {
      if (keep.classId == candidate.classId &&
          keep.rect.iou(candidate.rect) >= iouThreshold) {
        suppressed = true;
        break;
      }
    }
    if (!suppressed) {
      kept.add(candidate);
    }
  }
  return kept;
}

/// 把原始检测拆成 文字块（1/2 类，带内/外判定）+ 气泡（0 类）。
PageDetections buildPageDetections(List<RawDetection> detections) {
  final List<OcrRect> bubbles = <OcrRect>[
    for (final RawDetection d in detections)
      if (d.classId == kDetClassBubble) d.rect,
  ];
  final List<DetectedTextRegion> textRegions = <DetectedTextRegion>[];
  for (final RawDetection d in detections) {
    if (d.classId != kDetClassTextBubble && d.classId != kDetClassTextFree) {
      continue;
    }
    final bool inside = bubbles
        .any((OcrRect b) => b.containsPoint(d.rect.centerX, d.rect.centerY));
    textRegions.add(DetectedTextRegion(
      rect: d.rect,
      score: d.score,
      classId: d.classId,
      insideBubble: inside,
    ));
  }
  return PageDetections(textRegions: textRegions, bubbles: bubbles);
}

/// 检测器：会话注入，模型路径/EP 策略由上层决定。
class TextDetector implements OcrDetector {
  TextDetector(
    this._session, {
    this.scoreThreshold = 0.3,
    this.preserveAspect = false,
    this.inputName = 'pixel_values',
    this.logitsName = 'logits',
    this.boxesName = 'pred_boxes',
  });

  final OcrSession _session;

  /// 参考实现（comic-translate）默认置信度阈值 0.3。
  final double scoreThreshold;

  /// false = 官方 squish 预处理（与训练一致）；true = 等比 letterbox。
  final bool preserveAspect;

  final String inputName;
  final String logitsName;
  final String boxesName;

  @override
  Future<PageDetections> detect(img.Image page) async {
    final LetterboxTransform transform = computeLetterbox(
      page.width,
      page.height,
      preserveAspect: preserveAspect,
    );
    final Float32List input = rtdetrPreprocess(page, transform);
    final Map<String, OcrTensor> outputs =
        await _session.run(<String, OcrTensor>{
      inputName: OcrTensor.float32(
          input, <int>[1, 3, transform.dstHeight, transform.dstWidth]),
      'orig_target_sizes': OcrTensor.int64(
        Int64List.fromList(<int>[
          transform.dstHeight,
          transform.dstWidth,
        ]),
        const <int>[1, 2],
      ),
    });
    final OcrTensor? logits = outputs[logitsName];
    final OcrTensor? rawBoxes = outputs[boxesName];
    final OcrTensor? scores = outputs['scores'];
    final OcrTensor? labels = outputs['labels'];
    final OcrTensor? processedBoxes = outputs['boxes'];
    final List<RawDetection> raw;
    if (logits != null && rawBoxes != null) {
      final int numQueries = logits.shape[1];
      final int numClasses = logits.shape[2];
      raw = decodeRtdetrOutputs(
        logits: logits.floatData!,
        boxes: rawBoxes.floatData!,
        transform: transform,
        numQueries: numQueries,
        numClasses: numClasses,
        scoreThreshold: scoreThreshold,
      );
    } else if (scores != null && labels != null && processedBoxes != null) {
      raw = decodeProcessedRtdetrOutputs(
        scores: scores.floatData!,
        labels: labels.floatData!,
        boxes: processedBoxes.floatData!,
        transform: transform,
        scoreThreshold: scoreThreshold,
      );
    } else {
      throw StateError(
          'detector outputs missing: got ${outputs.keys.toList()}, '
          'expected [$logitsName, $boxesName] or [scores, labels, boxes]');
    }
    return buildPageDetections(applyClassAwareNms(raw));
  }

  Future<void> close() => _session.close();
}
