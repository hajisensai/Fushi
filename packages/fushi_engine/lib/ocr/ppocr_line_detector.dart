/// PP-OCRv6 文本行检测器（DB，PaddlePaddle/PP-OCRv6_small_det_onnx，Apache-2.0）。
///
/// 只在一个文字块的裁图（[cropOcrBlock]）内部把段落切成行（横排）/列（竖排）：
/// 横排块的行交行识别器（`routing_ocr_recognizer.dart`）；竖排块的列给整块识别
/// 结果切出行几何，或逐列交 CTC 识别（`ctc_column_ocr_recognizer.dart`）。
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
///   精确相等；倾斜行按真实像素数算面积，外扩量与原版同量级）。框本身不旋转，
///   但每个连通域的主轴角另记在 [PpTextLine.axisAngle]（像素二阶矩），整块的
///   倾角由 [ppBlockTilt] 汇总，供覆盖层把逐字命中格沿斜行摆正。
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'package:fushi_engine/media/manga/mokuro_geometry.dart';
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
  const PpTextLine({
    required this.rect,
    required this.score,
    this.axisAngle = 0,
    this.elongation = 1,
    this.pixelCount = 0,
  });

  final OcrRect rect;

  /// 连通域内概率均值。
  final double score;

  /// 连通域主轴与 +x 轴的夹角（弧度，(-π/2, π/2]，图像坐标 y 向下，正值即
  /// 屏幕上顺时针）。由像素二阶矩求得；[elongation] 太小时没有意义。
  final double axisAngle;

  /// 连通域主轴 / 次轴标准差之比（≥1）：越大越像一条细长的行，主轴角越可信。
  final double elongation;

  /// 连通域像素数（[ppBlockTilt] 的加权用）。
  final int pixelCount;

  /// 行相对正立方向的倾角（弧度，(-π/2, π/2]，正值顺时针）：横行是主轴偏离
  /// 水平的角度，竖列是主轴偏离竖直的角度。
  double get tilt =>
      _wrapHalfTurn(vertical ? axisAngle - math.pi / 2 : axisAngle);

  /// 把行从概率图像素系换到另一像素系：框按 [sx]/[sy] 缩放，主轴方向向量同样
  /// 按轴缩放后重求角度（两轴缩放比不同会改变斜线的角度）。
  PpTextLine scaled(double sx, double sy) => PpTextLine(
    rect: OcrRect(
      left: rect.left * sx,
      top: rect.top * sy,
      right: rect.right * sx,
      bottom: rect.bottom * sy,
    ),
    score: score,
    axisAngle: _wrapHalfTurn(
      math.atan2(math.sin(axisAngle) * sy, math.cos(axisAngle) * sx),
    ),
    elongation: elongation,
    pixelCount: pixelCount,
  );

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
    // 像素坐标的一、二阶矩（求主轴角）；以种子点为原点，避免大坐标平方的精度损失。
    final int ox = start % width;
    final int oy = start ~/ width;
    double mx = 0, my = 0, mxx = 0, myy = 0, mxy = 0;
    while (sp > 0) {
      final int p = stack[--sp];
      final int px = p % width;
      final int py = p ~/ width;
      sum += prob[p];
      count++;
      final double rx = (px - ox).toDouble();
      final double ry = (py - oy).toDouble();
      mx += rx;
      my += ry;
      mxx += rx * rx;
      myy += ry * ry;
      mxy += rx * ry;
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
    final ({double angle, double elongation}) axis = _principalAxis(
      count,
      mx,
      my,
      mxx,
      myy,
      mxy,
    );
    lines.add(
      PpTextLine(
        rect: OcrRect(
          left: minX - d,
          top: minY - d,
          right: maxX + 1 + d,
          bottom: maxY + 1 + d,
        ).clamp(width.toDouble(), height.toDouble()),
        score: score,
        axisAngle: axis.angle,
        elongation: axis.elongation,
        pixelCount: count,
      ),
    );
  }
  return lines;
}

/// 角度折进 (-π/2, π/2]（主轴是无向直线，差半圈是同一条）。
double _wrapHalfTurn(double angle) {
  double t = angle;
  while (t <= -math.pi / 2) {
    t += math.pi;
  }
  while (t > math.pi / 2) {
    t -= math.pi;
  }
  return t;
}

/// 由 [count] 个像素的一阶矩（[mx]/[my]）与二阶矩求主轴角与长短轴比。
({double angle, double elongation}) _principalAxis(
  int count,
  double mx,
  double my,
  double mxx,
  double myy,
  double mxy,
) {
  final double n = count.toDouble();
  final double cx = mx / n;
  final double cy = my / n;
  final double cxx = mxx / n - cx * cx;
  final double cyy = myy / n - cy * cy;
  final double cxy = mxy / n - cx * cy;
  final double half = (cxx - cyy) / 2;
  final double root = math.sqrt(half * half + cxy * cxy);
  final double major = (cxx + cyy) / 2 + root;
  // 单像素宽的离散方差下限是 1/12，避免细线的次轴方差为 0 除零。
  final double minor = math.max(1 / 12, (cxx + cyy) / 2 - root);
  return (
    angle: _wrapHalfTurn(0.5 * math.atan2(2 * cxy, cxx - cyy)),
    elongation: math.sqrt(math.max(1.0, major / minor)),
  );
}

/// 参与估块倾角的行至少要有的长短轴比：单字、标点这类近方块的连通域主轴角
/// 没有意义。
const double kPpTiltMinElongation = 2.5;

/// 倾角绝对值超过它就不信（接近 45° 时横竖判断本身就不可靠，按外接框反推
/// 旋转矩形也会病态）。
const double kPpTiltMaxRadians = 40 * math.pi / 180;

/// 一个文字块的整体倾角（弧度，正值顺时针；0 = 正立）。
///
/// 同一个气泡里的行/列共享同一个倾斜（斜放的标题、手写旁白），所以按块估一个
/// 角度：取细长连通域倾角的像素数加权中位数（抗振假名、碎片干扰）。没有可信
/// 的行、角度大到不可信、或倾斜对块里最长那行都无关紧要
/// （[mokuroTiltIsNegligible]：按偏移量判，不按固定角度）时返回 0。
double ppBlockTilt(List<PpTextLine> lines) {
  final List<PpTextLine> usable = <PpTextLine>[
    for (final PpTextLine line in lines)
      if (line.elongation >= kPpTiltMinElongation &&
          line.pixelCount > 0 &&
          line.tilt.abs() <= kPpTiltMaxRadians)
        line,
  ]..sort((PpTextLine a, PpTextLine b) => a.tilt.compareTo(b.tilt));
  if (usable.isEmpty) return 0;
  final int total = usable.fold<int>(
    0,
    (int acc, PpTextLine line) => acc + line.pixelCount,
  );
  int running = 0;
  double median = usable.last.tilt;
  for (final PpTextLine line in usable) {
    running += line.pixelCount;
    if (running * 2 >= total) {
      median = line.tilt;
      break;
    }
  }
  // 行的真实长 / 厚从像素数与长短轴比还原（矩形：L·T = 面积、L/T = 长短轴比），
  // 与旋转无关；外接框在倾斜时会把厚度撑大。
  double longest = 0;
  double thickness = 0;
  for (final PpTextLine line in usable) {
    final double length = math.sqrt(line.pixelCount * line.elongation);
    if (length > longest) {
      longest = length;
      thickness = math.sqrt(line.pixelCount / line.elongation);
    }
  }
  return mokuroTiltIsNegligible(longest, thickness, median) ? 0 : median;
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

/// 整块判竖排：切出的行里竖行**严格过半**（BUG-2783 路由用）。
///
/// 与 [orderLinesForReading] 的「不少于一半」刻意不同：一横一竖的混排块
/// 仍走逐行路径（2026-09-13 实测过的行为），只有明确的多列竖排才整块交回。
bool linesAreVerticalMajority(List<PpTextLine> lines) {
  final int verticalCount = lines.where((PpTextLine l) => l.vertical).length;
  return verticalCount * 2 > lines.length;
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

/// 文字块在页面上的裁图 + 裁图坐标 → 页面坐标的换算。
class OcrBlockCrop {
  const OcrBlockCrop(this.image, this.x, this.y);

  final img.Image image;

  /// 裁图左上角在页面上的像素坐标。
  final int x;
  final int y;

  OcrRect toPage(OcrRect rect) => OcrRect(
    left: x + rect.left,
    top: y + rect.top,
    right: x + rect.right,
    bottom: y + rect.bottom,
  );
}

/// 把 [box] 夹进页面后按整像素裁出来：左上取 floor，宽高取 ceil 且至少 1 像素；
/// 夹完没有面积返回 null。
OcrBlockCrop? cropOcrBlock(img.Image page, OcrRect box) {
  final OcrRect clamped = box.clamp(
    page.width.toDouble(),
    page.height.toDouble(),
  );
  final int x = clamped.left.floor();
  final int y = clamped.top.floor();
  final int w = math.min(math.max(1, clamped.width.ceil()), page.width - x);
  final int h = math.min(math.max(1, clamped.height.ceil()), page.height - y);
  if (w <= 0 || h <= 0) return null;
  return OcrBlockCrop(
    img.copyCrop(page, x: x, y: y, width: w, height: h),
    x,
    y,
  );
}

/// 行检测器：会话注入。
class PpOcrLineDetector {
  PpOcrLineDetector(this._session, {this.inputName = 'x'});

  final OcrSession _session;
  final String inputName;

  /// 在页面 [page] 的文字块 [box] 内检测文本行，行框换回页面坐标（未滤振假名）；
  /// 块夹进页面后没有面积时返回空列表。
  Future<List<OcrRect>> detectInBlock(img.Image page, OcrRect box) async =>
      (await detectLayoutInBlock(page, box)).lines;

  /// 同 [detectInBlock]，另带整块倾角（[ppBlockTilt]）。
  Future<({List<OcrRect> lines, double tilt})> detectLayoutInBlock(
    img.Image page,
    OcrRect box,
  ) async {
    final OcrBlockCrop? crop = cropOcrBlock(page, box);
    if (crop == null) return (lines: const <OcrRect>[], tilt: 0.0);
    final List<PpTextLine> detected = await detect(crop.image);
    return (
      lines: <OcrRect>[
        for (final PpTextLine line in detected) crop.toPage(line.rect),
      ],
      tilt: ppBlockTilt(detected),
    );
  }

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
    return <PpTextLine>[for (final PpTextLine l in raw) l.scaled(sx, sy)];
  }

  Future<void> close() => _session.close();
}
