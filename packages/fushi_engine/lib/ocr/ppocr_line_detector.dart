/// PP-OCRv6 文本行检测器（DB，PaddlePaddle/PP-OCRv6_small_det_onnx，Apache-2.0）。
///
/// 只在一个**横排文字块**内部把段落切成行，交给行识别器；竖排块不经过这里
/// （整块喂 manga-ocr 实测最好，见 `routing_ocr_recognizer.dart`）。
///
/// IO 规格（已核实：该 repo 的 `inference.yml` + PaddleOCR 3.x `DetResizeForTest`
/// / `DBPostProcess`，与 2026-09-11 对拍脚本 `ppocr.py` 逐步对齐）：
///
/// - 输入 `x` float32 [1,3,H,W]，**BGR**、`x/255` 后按 ImageNet 均值方差归一化
///   （mean 0.485/0.456/0.406、std 0.229/0.224/0.225，按通道序作用在 BGR 上——
///   PaddleOCR 的 NormalizeImage 就是这么写的，对拍也是这么跑的，别「纠正」成
///   RGB）。H/W = 原图边按 `limit_type=min, limit_side_len=64` 缩放后取整到 32
///   倍数（短边不足 64 才放大，否则原尺寸）。
/// - 输出 [1,1,H,W] 概率图。
/// - 后处理：`thresh=0.2` 二值化 → 连通域 → 域内概率均值 `box_thresh=0.45` →
///   `unclip_ratio=1.4` 外扩。原版对每个轮廓取最小外接旋转矩形再用 Clipper
///   偏移多边形；本实现只产**轴对齐**框：连通域的外接矩形 + 按
///   `d = 像素数 * ratio / 外接矩形周长` 四边外扩（轴对齐矩形上与 Clipper 偏移
///   精确相等；倾斜行按真实像素数算面积，外扩量与原版同量级）。横排段落的行
///   天然轴对齐，丢掉旋转信息对本用途没有损失。
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'package:fushi_engine/ocr/ocr_inference.dart';
import 'package:fushi_engine/ocr/ocr_types.dart';

/// DB 二值化阈值（`inference.yml` PostProcess.thresh）。
const double kPpDetThresh = 0.2;

/// 框内概率均值阈值（PostProcess.box_thresh）。
const double kPpDetBoxThresh = 0.45;

/// 外扩比例（PostProcess.unclip_ratio）。
const double kPpDetUnclipRatio = 1.4;

/// `DetResizeForTest` 的 `limit_side_len`（PaddleOCR 3.x 默认 `limit_type=min`）。
const int kPpDetLimitSideLen = 64;

/// 行框判竖排的长宽比（PaddleOCR `get_rotate_crop_image` 同口径）。
const double kPpLineVerticalRatio = 1.5;

/// ImageNet 归一化常量（作用于 BGR 通道序，见库注释）。
const List<double> kPpDetMean = <double>[0.485, 0.456, 0.406];
const List<double> kPpDetStd = <double>[0.229, 0.224, 0.225];

/// 检测器输入尺寸：`DetResizeForTest`——短边不足 [limitSideLen] 放大到它，
/// 再把两边各自取整到 32 的倍数（最小 32）。返回 (width, height)。
({int width, int height}) ppDetInputSize(
  int srcWidth,
  int srcHeight, {
  int limitSideLen = kPpDetLimitSideLen,
}) {
  if (srcWidth <= 0 || srcHeight <= 0) {
    throw ArgumentError('invalid source size: ${srcWidth}x$srcHeight');
  }
  final int minSide = math.min(srcWidth, srcHeight);
  final double ratio = minSide < limitSideLen ? limitSideLen / minSide : 1.0;
  int round32(int side) =>
      math.max(32, ((side * ratio).toInt() / 32).round() * 32);
  return (width: round32(srcWidth), height: round32(srcHeight));
}

/// resize 到 [width]x[height] 并输出 BGR CHW float32（ImageNet 归一化）。
Float32List ppDetPreprocess(img.Image source, int width, int height) {
  final img.Image resized = (source.width == width && source.height == height)
      ? source
      : img.copyResize(
          source,
          width: width,
          height: height,
          interpolation: img.Interpolation.linear,
        );
  final int planeSize = width * height;
  final Float32List chw = Float32List(3 * planeSize);
  int index = 0;
  for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
      final img.Pixel pixel = resized.getPixel(x, y);
      // 通道序 BGR：channel0 = B 配 mean[0]。
      chw[index] = (pixel.b / 255.0 - kPpDetMean[0]) / kPpDetStd[0];
      chw[planeSize + index] = (pixel.g / 255.0 - kPpDetMean[1]) / kPpDetStd[1];
      chw[2 * planeSize + index] =
          (pixel.r / 255.0 - kPpDetMean[2]) / kPpDetStd[2];
      index++;
    }
  }
  return chw;
}

/// 一条检测到的文本行（坐标在**输入给检测器的那张图**的像素系）。
class PpTextLine {
  const PpTextLine({required this.rect, required this.score});

  final OcrRect rect;

  /// 连通域内概率均值。
  final double score;

  /// 竖排：高 ≥ 1.5 × 宽。
  bool get vertical => rect.height >= rect.width * kPpLineVerticalRatio;

  /// 行「厚度」：横排是高、竖排是宽（振假名过滤用）。
  double get thickness => vertical ? rect.width : rect.height;
}

/// DB 后处理：概率图 → 轴对齐行框（概率图像素系，未反变换）。
///
/// [prob] 长度 = [width] * [height]，行主序。
List<PpTextLine> ppDetPostprocess(
  Float32List prob,
  int width,
  int height, {
  double thresh = kPpDetThresh,
  double boxThresh = kPpDetBoxThresh,
  double unclipRatio = kPpDetUnclipRatio,
}) {
  assert(prob.length == width * height);
  final Int32List label = Int32List(width * height); // 0 = 未访问/背景
  final List<PpTextLine> lines = <PpTextLine>[];
  final Int32List stack = Int32List(width * height);
  int nextLabel = 0;
  // 4 连通洪泛：未访问且过阈值的邻居压栈并打标；返回新栈顶。
  int push(int q, int sp) {
    if (label[q] == 0 && prob[q] > thresh) {
      label[q] = nextLabel;
      stack[sp] = q;
      return sp + 1;
    }
    return sp;
  }

  for (int start = 0; start < prob.length; start++) {
    if (label[start] != 0 || prob[start] <= thresh) {
      continue;
    }
    nextLabel++;
    int sp = push(start, 0);
    int minX = width, minY = height, maxX = -1, maxY = -1;
    double sum = 0;
    int count = 0;
    while (sp > 0) {
      final int p = stack[--sp];
      final int px = p % width;
      final int py = p ~/ width;
      sum += prob[p];
      count++;
      if (px < minX) minX = px;
      if (px > maxX) maxX = px;
      if (py < minY) minY = py;
      if (py > maxY) maxY = py;
      if (px > 0) sp = push(p - 1, sp);
      if (px < width - 1) sp = push(p + 1, sp);
      if (py > 0) sp = push(p - width, sp);
      if (py < height - 1) sp = push(p + width, sp);
    }
    final double score = sum / count;
    if (score < boxThresh) {
      continue;
    }
    // 外接矩形（右/下含端点，+1 成为半开区间宽高）。
    final double w = (maxX - minX + 1).toDouble();
    final double h = (maxY - minY + 1).toDouble();
    if (w < 2 || h < 2) {
      continue;
    }
    // Clipper 偏移距离 area * ratio / perimeter，对轴对齐矩形四边等距外扩即精确解。
    // 面积用连通域真实像素数而不是 w*h：轴对齐时两者恒等，倾斜行的外接矩形面积
    // 虚大（12° 倾斜实测 d 从 58 涨到 101），会把邻行吞进来让识别串行。
    final double d = count * unclipRatio / (2 * (w + h));
    lines.add(
      PpTextLine(
        rect: OcrRect(
          left: minX - d,
          top: minY - d,
          right: maxX + 1 + d,
          bottom: maxY + 1 + d,
        ).clamp(width.toDouble(), height.toDouble()),
        score: score,
      ),
    );
  }
  return lines;
}

/// 振假名过滤：比块内行厚度 p75 的 [ratio] 还细的行丢掉（对拍脚本同规则，
/// 是 PP-OCR 在日漫上的生死线：过滤前 CER 41%~92%）。
List<PpTextLine> filterThinLines(List<PpTextLine> lines, {double ratio = 0.6}) {
  if (lines.isEmpty) {
    return lines;
  }
  final List<double> thick = <double>[
    for (final PpTextLine l in lines) l.thickness,
  ]..sort();
  final double p75 = thick[math.min(thick.length - 1, (3 * thick.length) ~/ 4)];
  return <PpTextLine>[
    for (final PpTextLine l in lines)
      if (l.thickness >= ratio * p75) l,
  ];
}

/// 阅读顺序：竖排占多数 → 按列从右到左；否则从上到下、从左到右。
List<PpTextLine> orderLinesForReading(List<PpTextLine> lines) {
  final List<PpTextLine> sorted = List<PpTextLine>.from(lines);
  final int verticalCount = lines.where((PpTextLine l) => l.vertical).length;
  if (lines.isNotEmpty && verticalCount * 2 >= lines.length) {
    sorted.sort(
      (PpTextLine a, PpTextLine b) =>
          (b.rect.left + b.rect.right).compareTo(a.rect.left + a.rect.right),
    );
  } else {
    sorted.sort((PpTextLine a, PpTextLine b) {
      final int byTop = a.rect.top.compareTo(b.rect.top);
      return byTop != 0 ? byTop : a.rect.left.compareTo(b.rect.left);
    });
  }
  return sorted;
}

/// 行检测器：会话注入。
class PpOcrLineDetector {
  PpOcrLineDetector(this._session, {this.inputName = 'x'});

  final OcrSession _session;
  final String inputName;

  /// 在 [crop]（一个文字块的裁图）内检测文本行，坐标为 [crop] 像素系。
  Future<List<PpTextLine>> detect(img.Image crop) async {
    final ({int width, int height}) size = ppDetInputSize(
      crop.width,
      crop.height,
    );
    final Float32List input = ppDetPreprocess(crop, size.width, size.height);
    final Map<String, OcrTensor> outputs = await _session.run(
      <String, OcrTensor>{
        inputName: OcrTensor.float32(input, <int>[
          1,
          3,
          size.height,
          size.width,
        ]),
      },
    );
    if (outputs.length != 1) {
      throw StateError(
        'PP-OCR det expected 1 output, got ${outputs.keys.toList()}',
      );
    }
    final OcrTensor prob = outputs.values.single;
    final int outH = prob.shape[prob.shape.length - 2];
    final int outW = prob.shape[prob.shape.length - 1];
    final List<PpTextLine> raw = ppDetPostprocess(prob.floatData!, outW, outH);
    // 概率图与输入同尺寸；反变换回裁图像素系。
    final double sx = crop.width / outW;
    final double sy = crop.height / outH;
    return <PpTextLine>[
      for (final PpTextLine l in raw)
        PpTextLine(
          rect: OcrRect(
            left: l.rect.left * sx,
            top: l.rect.top * sy,
            right: l.rect.right * sx,
            bottom: l.rect.bottom * sy,
          ),
          score: l.score,
        ),
    ];
  }

  Future<void> close() => _session.close();
}
