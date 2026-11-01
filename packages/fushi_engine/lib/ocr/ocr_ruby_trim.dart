/// 「OCR 忽略振假名」（反馈 ZBJTgLuPIb）：逐列 CTC 识别前，把贴在正文列 / 行旁边
/// 的小号注音带从行框里裁掉。
///
/// 为什么还要这一步：[dropOcrRubyLines]（`ocr_line_layout.dart`）只能删掉被行检测器
/// **单独检出**的注音列。注音紧贴正文、行检测器把两者检成**同一条**行框时，裁出的
/// 列图里正文旁边就带着一条注音——CTC 把它当正文的一部分读，汉字被读成别的字或
/// 混进假名（用户在注音密集的《葬送のフリーレン》上用 Manga CTC 遇到的就是这个）。
///
/// 做法是在**行框内部**看墨迹：沿跨轴（竖排是 x、横排是 y）统计每一条像素线上的
/// 墨迹量，连续有墨迹的位置合成「带」。正文列是墨迹最多的那条带；位于它外侧、
/// 宽度不到正文带 [kOcrRubyBandRatio] 倍、墨迹量也明显更少的带就是注音，裁掉。
/// 只裁行框的跨轴两侧，沿阅读方向的长度不动；判不出（对比度不够 / 只有一条带 /
/// 行框太细）时原样返回，绝不比不开时更差。
///
/// 这只是不读来源自带的注音，不生成任何读音。
library;

import 'dart:math' as math;

import 'package:image/image.dart' as img;

import 'package:fushi_engine/ocr/ocr_types.dart';

/// 注音带宽度上限：正文带宽的这么多倍。注音字号一般是正文的 0.4~0.6。
const double kOcrRubyBandRatio = 0.65;

/// 注音带墨迹量上限：正文带墨迹量的这么多倍（注音只标在部分汉字旁，又小又稀）。
const double kOcrRubyMassRatio = 0.5;

/// 墨迹 / 底色的最小亮度差；低于它说明这块没有可分辨的文字，不动。
const int _kMinContrast = 48;

/// 裁掉 [line]（页面坐标）跨轴两侧的注音带，返回裁后的行框；没有可裁的返回
/// [line] 本身。[vertical] 为真时跨轴是 x（竖排注音在列右侧，也兼顾左侧——
/// 相邻列的注音会伸进本列框的左缘），否则跨轴是 y。
OcrRect trimOcrRubyBands(
  img.Image page,
  OcrRect line, {
  required bool vertical,
}) {
  final OcrRect clamped = line.clamp(
    page.width.toDouble(),
    page.height.toDouble(),
  );
  final int x0 = clamped.left.floor();
  final int y0 = clamped.top.floor();
  final int x1 = math.min(page.width, clamped.right.ceil());
  final int y1 = math.min(page.height, clamped.bottom.ceil());
  final int w = x1 - x0;
  final int h = y1 - y0;
  final int cross = vertical ? w : h;
  final int along = vertical ? h : w;
  if (cross < 6 || along < 4) return line;

  // 亮度表与对比度。
  final List<int> lum = List<int>.filled(w * h, 0);
  int lo = 255;
  int hi = 0;
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      final img.Pixel p = page.getPixel(x0 + x, y0 + y);
      final int l = (0.299 * p.r + 0.587 * p.g + 0.114 * p.b).round().clamp(
        0,
        255,
      );
      lum[y * w + x] = l;
      if (l < lo) lo = l;
      if (l > hi) hi = l;
    }
  }
  if (hi - lo < _kMinContrast) return line;
  final int threshold = (lo + hi) ~/ 2;
  int dark = 0;
  for (final int l in lum) {
    if (l < threshold) dark++;
  }
  // 墨迹是少数的那一类：黑字白底取暗、白字黑底（反白台词）取亮。
  final bool inkIsDark = dark * 2 <= lum.length;
  bool isInk(int l) => inkIsDark ? l < threshold : l >= threshold;

  // 跨轴墨迹投影。
  final List<int> profile = List<int>.filled(cross, 0);
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      if (isInk(lum[y * w + x])) profile[vertical ? x : y]++;
    }
  }
  final int minInk = math.max(1, (along * 0.01).round());
  final List<({int start, int end, int mass})> bands =
      <({int start, int end, int mass})>[];
  int? start;
  int mass = 0;
  for (int c = 0; c <= cross; c++) {
    final bool inked = c < cross && profile[c] >= minInk;
    if (inked) {
      start ??= c;
      mass += profile[c];
    } else if (start != null) {
      bands.add((start: start, end: c, mass: mass));
      start = null;
      mass = 0;
    }
  }
  if (bands.length < 2) return line;

  int mainIndex = 0;
  for (int i = 1; i < bands.length; i++) {
    if (bands[i].mass > bands[mainIndex].mass) mainIndex = i;
  }
  final ({int start, int end, int mass}) main = bands[mainIndex];
  final int mainWidth = main.end - main.start;
  bool isRuby(({int start, int end, int mass}) band) =>
      band.end - band.start < kOcrRubyBandRatio * mainWidth &&
      band.mass < kOcrRubyMassRatio * main.mass;

  // 从两侧往里剥注音带，碰到不像注音的带（另一列正文）就停。
  int first = 0;
  while (first < mainIndex && isRuby(bands[first])) {
    first++;
  }
  int last = bands.length - 1;
  while (last > mainIndex && isRuby(bands[last])) {
    last--;
  }
  if (first == 0 && last == bands.length - 1) return line;

  // 新边界落在被剥掉那条带与保留带之间空隙的中点：留出半个空隙的白边，
  // 不贴着笔画裁。
  final int keepStart = first == 0
      ? 0
      : (bands[first - 1].end + bands[first].start) ~/ 2;
  final int keepEnd = last == bands.length - 1
      ? cross
      : (bands[last].end + bands[last + 1].start + 1) ~/ 2;
  if (keepEnd - keepStart < 1) return line;
  return vertical
      ? OcrRect(
          left: (x0 + keepStart).toDouble(),
          top: line.top,
          right: (x0 + keepEnd).toDouble(),
          bottom: line.bottom,
        )
      : OcrRect(
          left: line.left,
          top: (y0 + keepStart).toDouble(),
          right: line.right,
          bottom: (y0 + keepEnd).toDouble(),
        );
}
