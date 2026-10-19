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

import 'package:fushi_compute/fushi_compute.dart';
import 'package:image/image.dart' as img;

import 'package:fushi_engine/media/image_kernels.dart';
import 'package:fushi_engine/ocr/ocr_inference.dart';
import 'package:fushi_engine/ocr/ocr_types.dart';

/// RT-DETR 类别 id。
const int kDetClassBubble = 0;
const int kDetClassTextBubble = 1;
const int kDetClassTextFree = 2;

/// 弱候选阈值（[TextDetector.weakScoreThreshold] 默认值）：用户真实页上字距稀疏的
/// 两行横排标题，检测器给第二行的分只有 0.02 出头。
const double kDetWeakScoreThreshold = 0.02;

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
  final int scaledW = (transform.srcWidth * transform.scaleX).round().clamp(
    1,
    dstW,
  );
  final int scaledH = (transform.srcHeight * transform.scaleY).round().clamp(
    1,
    dstH,
  );

  // 缩放 + letterbox 合成 + 归一化都在原生内核里（image_kernels.dart，与旧的
  // copyResize + compositeImage + 逐像素 getPixel 逐位相同）。
  return imageToChw(
    source,
    width: scaledW,
    height: scaledH,
    interpolation: img.Interpolation.linear,
    canvasWidth: dstW,
    canvasHeight: dstH,
    padX: transform.padX.round(),
    padY: transform.padY.round(),
    bgr: false,
  );
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

FfcLetterbox _letterbox(LetterboxTransform t) => (
  scaleX: t.scaleX,
  scaleY: t.scaleY,
  padX: t.padX,
  padY: t.padY,
  srcWidth: t.srcWidth,
  srcHeight: t.srcHeight,
  dstWidth: t.dstWidth,
  dstHeight: t.dstHeight,
);

OcrRect _rectOf(FfcDetection d) =>
    OcrRect(left: d.left, top: d.top, right: d.right, bottom: d.bottom);

/// 解码 RT-DETR 输出（原生 `ffc_ocr_rtdetr_decode`）。
///
/// [logits]：[numQueries, numClasses]（batch=1 已扁平），**未过 sigmoid**；
/// [boxes]：[numQueries, 4] cxcywh，相对模型输入归一化 0..1。
/// 语义对齐 `RTDetrImageProcessor.post_process_object_detection`
/// （use_focal_loss：sigmoid + 按 (query, class) 过阈值），再经 [transform]
/// 反变换回原图（夹进原图、去掉零面积）。
List<RawDetection> decodeRtdetrOutputs({
  required Float32List logits,
  required Float32List boxes,
  required LetterboxTransform transform,
  int numQueries = 300,
  int numClasses = 3,
  double scoreThreshold = 0.3,
}) => <RawDetection>[
  for (final FfcDetection d in FushiComputeOcr.instance.rtdetrDecode(
    logits: logits,
    boxes: boxes,
    queries: numQueries,
    classes: numClasses,
    transform: _letterbox(transform),
    scoreThreshold: scoreThreshold,
  ))
    RawDetection(rect: _rectOf(d), score: d.score, classId: d.tag),
];

/// `labels` 输出按会话实现可能是 float32（flutter_onnxruntime 插件把一切读成
/// float）也可能是 int64 / int32（服务端 FFI 会话按 ORT 报的元素类型原样返回）。
/// 三型都吃；只认 float 曾让无头服务端在第一页就空指针。
List<num> _labelValues(OcrTensor labels) {
  final List<num>? values =
      labels.floatData ?? labels.intData ?? labels.int32Data;
  if (values == null) {
    throw StateError('detector labels output has no readable data');
  }
  return values;
}

/// 解码已经在 ONNX 图内完成 sigmoid/top-k/xyxy 转换的 RT-DETR 输出（几何在原生
/// `ffc_ocr_rtdetr_decode_processed`，类别按 `labels[i].round()`）。
List<RawDetection> decodeProcessedRtdetrOutputs({
  required Float32List scores,
  required List<num> labels,
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
  return <RawDetection>[
    for (final FfcDetection d in FushiComputeOcr.instance.rtdetrDecodeProcessed(
      scores: scores,
      boxes: boxes,
      transform: _letterbox(transform),
      scoreThreshold: scoreThreshold,
    ))
      RawDetection(
        rect: _rectOf(d),
        score: d.score,
        classId: labels[d.tag].round(),
      ),
  ];
}

/// NMS 分组：气泡（0 类）一组，文字（1/2 类）一组。
///
/// 解码按 (query, class) 对过阈值，同一个 query 在 text_bubble 与 text_free 上
/// 都过线时会产出两个 **rect 完全相同** 的检测；若按 classId 分组，两者互不抑制，
/// 同一块文字会被识别两次、写进 manga.json 两次（实测 mihon 下载的扉页人物名栏）。
/// 内/外只是同一块文字的属性，不是两种物体——所以文字两类共用一组，高分者带着
/// 自己的 classId 存活。气泡与其中的文字天然套叠，仍分组保留。（原生实现同此分组。）
int nmsGroupOf(int classId) => classId == kDetClassBubble ? 0 : 1;

/// 分组贪心 NMS（原生 `ffc_ocr_class_aware_nms`）：按分数降序，同组内 IoU >= [iouThreshold]
/// 的低分框剔除。低 IoU 的内框留到识别后判重：几何包含不能保证父块读全小字号正文，
/// 横排切行的振假名过滤也可能删掉正文，因此这里不按包含关系删除。
List<RawDetection> applyClassAwareNms(
  List<RawDetection> detections, {
  double iouThreshold = 0.7,
}) {
  final List<int> kept = FushiComputeOcr.instance.classAwareNms(<FfcDetection>[
    for (final RawDetection d in detections)
      (
        left: d.rect.left,
        top: d.rect.top,
        right: d.rect.right,
        bottom: d.rect.bottom,
        score: d.score,
        tag: d.classId,
      ),
  ], iouThreshold: iouThreshold);
  return <RawDetection>[for (final int i in kept) detections[i]];
}

({double left, double top, double right, double bottom}) _ltrb(OcrRect r) =>
    (left: r.left, top: r.top, right: r.right, bottom: r.bottom);

bool _isText(RawDetection d) =>
    d.classId == kDetClassTextBubble || d.classId == kDetClassTextFree;

/// 把原始检测拆成 文字块（1/2 类，带内/外判定）+ 气泡（0 类）。
/// [weakDetections] 是没过正式阈值的弱检测，只取其中的文字类给补检当候选。
/// 内/外判定（文字框中心是否落在某个气泡框内）在原生 `ffc_ocr_inside_bubbles`。
PageDetections buildPageDetections(
  List<RawDetection> detections, {
  List<RawDetection> weakDetections = const <RawDetection>[],
}) {
  final List<OcrRect> bubbles = <OcrRect>[
    for (final RawDetection d in detections)
      if (d.classId == kDetClassBubble) d.rect,
  ];
  final List<RawDetection> texts = detections.where(_isText).toList();
  final List<RawDetection> weakTexts = weakDetections.where(_isText).toList();
  final List<({double left, double top, double right, double bottom})>
  bubbleRects = bubbles.map(_ltrb).toList();
  final List<bool> inside = FushiComputeOcr.instance.insideBubbles(
    bubbleRects,
    texts.map((RawDetection d) => _ltrb(d.rect)).toList(),
  );
  final List<bool> weakInside = FushiComputeOcr.instance.insideBubbles(
    bubbleRects,
    weakTexts.map((RawDetection d) => _ltrb(d.rect)).toList(),
  );
  return PageDetections(
    textRegions: <DetectedTextRegion>[
      for (int i = 0; i < texts.length; i++)
        DetectedTextRegion(
          rect: texts[i].rect,
          score: texts[i].score,
          classId: texts[i].classId,
          insideBubble: inside[i],
        ),
    ],
    bubbles: bubbles,
    weakTextRegions: <DetectedTextRegion>[
      for (int i = 0; i < weakTexts.length; i++)
        DetectedTextRegion(
          rect: weakTexts[i].rect,
          score: weakTexts[i].score,
          classId: weakTexts[i].classId,
          insideBubble: weakInside[i],
        ),
    ],
  );
}

/// 检测器：会话注入，模型路径/EP 策略由上层决定。
class TextDetector implements OcrDetector {
  TextDetector(
    this._session, {
    this.scoreThreshold = 0.3,
    this.weakScoreThreshold = kDetWeakScoreThreshold,
    this.preserveAspect = false,
    this.inputName = 'pixel_values',
    this.logitsName = 'logits',
    this.boxesName = 'pred_boxes',
  });

  final OcrSession _session;

  /// 参考实现（comic-translate）默认置信度阈值 0.3。
  final double scoreThreshold;

  /// 弱阈值：分数落在 [weakScoreThreshold, [scoreThreshold]) 的文字框进
  /// [PageDetections.weakTextRegions]，正式结果不变。不低于 [scoreThreshold] 时
  /// 等于关掉弱档。
  final double weakScoreThreshold;

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
    final Map<String, OcrTensor> outputs = await _session.run(
      <String, OcrTensor>{
        inputName: OcrTensor.float32(input, <int>[
          1,
          3,
          transform.dstHeight,
          transform.dstWidth,
        ]),
        'orig_target_sizes': OcrTensor.int64(
          Int64List.fromList(<int>[transform.dstHeight, transform.dstWidth]),
          const <int>[1, 2],
        ),
      },
    );
    final OcrTensor? logits = outputs[logitsName];
    final OcrTensor? rawBoxes = outputs[boxesName];
    final OcrTensor? scores = outputs['scores'];
    final OcrTensor? labels = outputs['labels'];
    final OcrTensor? processedBoxes = outputs['boxes'];
    final double decodeThreshold = math.min(scoreThreshold, weakScoreThreshold);
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
        scoreThreshold: decodeThreshold,
      );
    } else if (scores != null && labels != null && processedBoxes != null) {
      raw = decodeProcessedRtdetrOutputs(
        scores: scores.floatData!,
        labels: _labelValues(labels),
        boxes: processedBoxes.floatData!,
        transform: transform,
        scoreThreshold: decodeThreshold,
      );
    } else {
      throw StateError(
        'detector outputs missing: got ${outputs.keys.toList()}, '
        'expected [$logitsName, $boxesName] or [scores, labels, boxes]',
      );
    }
    return buildPageDetections(
      applyClassAwareNms(<RawDetection>[
        for (final RawDetection d in raw)
          if (d.score >= scoreThreshold) d,
      ]),
      weakDetections: <RawDetection>[
        for (final RawDetection d in raw)
          if (d.score < scoreThreshold) d,
      ],
    );
  }

  Future<void> close() => _session.close();
}
