import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// 网页漫画章末广告页的启发式判定（只用于网页漫画来源）。
///
/// 盗链 / 聚合站常在一章末尾塞几张「扫码下载 App / 加群」的彩色广告图，混进
/// 漫画页里翻到最后才看到。判据刻意做得窄，宁可漏判也不误删正文：
///
/// 1. 只看一章**最后 [kWebComicAdTailWindow] 张**；
/// 2. 前 [kWebComicAdProtectedLeadingPages] 张**永远不算广告**（短章 / 单页也不会
///    被整章删光）；
/// 3. 必须是**彩色图**（漫画正文几乎都是灰度，彩页也极少印二维码）；
/// 4. 且图里能找到**二维码的三个定位图形**（1:1:3:1:1 的「回」字，三个中心呈
///    等腰直角三角形）。
///
/// 只做「有没有二维码」的检测，不解码内容：判广告不需要知道码里写了什么，也就
/// 不必引入新的二维码依赖。
const int kWebComicAdTailWindow = 10;

/// 一章开头永不判广告的张数。
const int kWebComicAdProtectedLeadingPages = 3;

/// 一章 [pageCount] 张里需要做广告判定的页序（升序）。
List<int> webComicAdCandidateIndices(int pageCount) {
  if (pageCount <= kWebComicAdProtectedLeadingPages) return const <int>[];
  final int start = math.max(
    kWebComicAdProtectedLeadingPages,
    pageCount - kWebComicAdTailWindow,
  );
  return <int>[for (int i = start; i < pageCount; i++) i];
}

/// 判定用的缩放上限：二维码模块在 900px 长边下仍有几个像素宽，定位图形可检出；
/// 再大只是白算。
const int _kAnalysisMaxSide = 900;

/// [bytes] 是不是章末广告页（彩色 + 含二维码定位图形）。解码失败一律 false。
bool isWebComicAdImage(Uint8List bytes) {
  final img.Image? decoded;
  try {
    decoded = img.decodeImage(bytes);
  } on Object {
    return false;
  }
  if (decoded == null || decoded.width < 32 || decoded.height < 32) {
    return false;
  }
  final img.Image image =
      math.max(decoded.width, decoded.height) > _kAnalysisMaxSide
      ? img.copyResize(
          decoded,
          width: decoded.width >= decoded.height ? _kAnalysisMaxSide : null,
          height: decoded.height > decoded.width ? _kAnalysisMaxSide : null,
          interpolation: img.Interpolation.average,
        )
      : decoded;
  if (webComicColorfulFraction(image) < kWebComicColorfulThreshold) {
    return false;
  }
  return containsQrFinderPatterns(_luminance(image), image.width, image.height);
}

/// 彩色像素占比超过它才算彩色图。扫描的黑白页（纸张泛黄、JPEG 色噪）通常远低于
/// 5%；广告图大面积纯色，远高于它。
const double kWebComicColorfulThreshold = 0.12;

/// 「彩色像素」的通道差下限（max(r,g,b) - min(r,g,b)，0..255）。
const int _kColorfulChannelSpread = 48;

/// [image] 里彩色像素的占比（按步长抽样）。
double webComicColorfulFraction(img.Image image) {
  final int step = math.max(1, math.min(image.width, image.height) ~/ 160);
  int total = 0;
  int colorful = 0;
  for (int y = 0; y < image.height; y += step) {
    for (int x = 0; x < image.width; x += step) {
      final img.Pixel pixel = image.getPixel(x, y);
      final int r = (pixel.rNormalized * 255).round();
      final int g = (pixel.gNormalized * 255).round();
      final int b = (pixel.bNormalized * 255).round();
      final int spread =
          math.max(r, math.max(g, b)) - math.min(r, math.min(g, b));
      total++;
      if (spread >= _kColorfulChannelSpread) colorful++;
    }
  }
  return total == 0 ? 0 : colorful / total;
}

Uint8List _luminance(img.Image image) {
  final Uint8List out = Uint8List(image.width * image.height);
  int i = 0;
  for (int y = 0; y < image.height; y++) {
    for (int x = 0; x < image.width; x++) {
      final img.Pixel pixel = image.getPixel(x, y);
      final double l =
          0.299 * pixel.rNormalized +
          0.587 * pixel.gNormalized +
          0.114 * pixel.bNormalized;
      out[i++] = (l * 255).round().clamp(0, 255);
    }
  }
  return out;
}

/// 灰度图 [gray]（宽 [width]、高 [height]）里有没有一组二维码定位图形。
bool containsQrFinderPatterns(Uint8List gray, int width, int height) {
  if (gray.length != width * height || width < 21 || height < 21) return false;
  final int threshold = _otsuThreshold(gray);
  final Uint8List dark = Uint8List(gray.length);
  for (int i = 0; i < gray.length; i++) {
    dark[i] = gray[i] < threshold ? 1 : 0;
  }
  final List<_FinderCluster> clusters = <_FinderCluster>[];
  final List<int> runLengths = <int>[];
  final List<int> runStarts = <int>[];
  final List<int> runColors = <int>[];
  for (int y = 0; y < height; y++) {
    runLengths.clear();
    runStarts.clear();
    runColors.clear();
    final int row = y * width;
    int start = 0;
    for (int x = 1; x <= width; x++) {
      if (x == width || dark[row + x] != dark[row + start]) {
        runLengths.add(x - start);
        runStarts.add(start);
        runColors.add(dark[row + start]);
        start = x;
      }
    }
    for (int r = 0; r + 4 < runLengths.length; r++) {
      if (runColors[r] != 1) continue;
      final List<int> counts = runLengths.sublist(r, r + 5);
      if (!_finderRatio(counts)) continue;
      final int hTotal = counts.fold(0, (int a, int b) => a + b);
      final double cx = runStarts[r + 2] + runLengths[r + 2] / 2;
      final ({double center, int total})? vertical = _crossCheckVertical(
        dark,
        width,
        height,
        cx.floor(),
        y,
        hTotal,
      );
      if (vertical == null) continue;
      _addCandidate(
        clusters,
        cx,
        vertical.center,
        (hTotal + vertical.total) / 14,
      );
    }
  }
  final List<_FinderCluster> confirmed =
      clusters.where((_FinderCluster c) => c.hits >= 2).toList()..sort(
        (_FinderCluster a, _FinderCluster b) => b.hits.compareTo(a.hits),
      );
  final List<_FinderCluster> top = confirmed.length > 12
      ? confirmed.sublist(0, 12)
      : confirmed;
  for (int a = 0; a < top.length; a++) {
    for (int b = a + 1; b < top.length; b++) {
      for (int c = b + 1; c < top.length; c++) {
        if (_formsQrTriangle(top[a], top[b], top[c])) return true;
      }
    }
  }
  return false;
}

/// 1:1:3:1:1（允许每格半个模块的误差，中间那格 1.5 个模块）。
bool _finderRatio(List<int> counts) {
  int total = 0;
  for (final int count in counts) {
    if (count == 0) return false;
    total += count;
  }
  if (total < 7) return false;
  final double module = total / 7;
  final double variance = module / 2;
  return (counts[0] - module).abs() < variance &&
      (counts[1] - module).abs() < variance &&
      (counts[2] - 3 * module).abs() < 3 * variance &&
      (counts[3] - module).abs() < variance &&
      (counts[4] - module).abs() < variance;
}

/// 在第 [x] 列从 [y] 起上下各走一遍，确认竖直方向也是 1:1:3:1:1；返回竖直中心与总长。
({double center, int total})? _crossCheckVertical(
  Uint8List dark,
  int width,
  int height,
  int x,
  int y,
  int hTotal,
) {
  bool isDark(int yy) => dark[yy * width + x] == 1;
  if (!isDark(y)) return null;
  final List<int> counts = List<int>.filled(5, 0);
  int yy = y;
  // 向上：中心黑块 → 白环 → 黑环。
  while (yy >= 0 && isDark(yy)) {
    counts[2]++;
    yy--;
  }
  while (yy >= 0 && !isDark(yy)) {
    counts[1]++;
    yy--;
  }
  while (yy >= 0 && isDark(yy)) {
    counts[0]++;
    yy--;
  }
  if (counts[1] == 0 || counts[0] == 0) return null;
  yy = y + 1;
  int centerBottom = y;
  while (yy < height && isDark(yy)) {
    counts[2]++;
    centerBottom = yy;
    yy++;
  }
  while (yy < height && !isDark(yy)) {
    counts[3]++;
    yy++;
  }
  while (yy < height && isDark(yy)) {
    counts[4]++;
    yy++;
  }
  if (counts[3] == 0 || counts[4] == 0) return null;
  if (!_finderRatio(counts)) return null;
  final int vTotal = counts.fold(0, (int a, int b) => a + b);
  if (5 * (vTotal - hTotal).abs() >= 2 * hTotal) return null;
  final int centerTop = centerBottom - counts[2] + 1;
  return (center: (centerTop + centerBottom) / 2, total: vTotal);
}

class _FinderCluster {
  _FinderCluster(this.x, this.y, this.module);

  double x;
  double y;
  double module;
  int hits = 1;
}

void _addCandidate(
  List<_FinderCluster> clusters,
  double x,
  double y,
  double module,
) {
  for (final _FinderCluster cluster in clusters) {
    final double tolerance = math.max(cluster.module, module) * 2;
    if ((cluster.x - x).abs() <= tolerance &&
        (cluster.y - y).abs() <= tolerance &&
        (cluster.module - module).abs() <= math.max(cluster.module, module)) {
      final int n = cluster.hits;
      cluster
        ..x = (cluster.x * n + x) / (n + 1)
        ..y = (cluster.y * n + y) / (n + 1)
        ..module = (cluster.module * n + module) / (n + 1)
        ..hits = n + 1;
      return;
    }
  }
  clusters.add(_FinderCluster(x, y, module));
}

/// 三个定位图形：模块尺寸相近，中心呈等腰直角三角形，腰长 ≥ 14 个模块（版本 1）。
bool _formsQrTriangle(_FinderCluster a, _FinderCluster b, _FinderCluster c) {
  final double minModule = math.min(a.module, math.min(b.module, c.module));
  final double maxModule = math.max(a.module, math.max(b.module, c.module));
  if (minModule <= 0 || maxModule / minModule > 1.5) return false;
  double dist(_FinderCluster p, _FinderCluster q) =>
      math.sqrt(math.pow(p.x - q.x, 2) + math.pow(p.y - q.y, 2));
  final List<double> sides = <double>[dist(a, b), dist(b, c), dist(a, c)]
    ..sort();
  final double leg1 = sides[0];
  final double leg2 = sides[1];
  final double hypotenuse = sides[2];
  if (leg1 <= 0 || leg1 / leg2 < 0.8) return false;
  final double expected = math.sqrt(leg1 * leg1 + leg2 * leg2);
  if ((hypotenuse - expected).abs() / hypotenuse > 0.12) return false;
  final double module = (a.module + b.module + c.module) / 3;
  final double legModules = leg1 / module;
  return legModules >= 12 && legModules <= 200;
}

int _otsuThreshold(Uint8List gray) {
  final List<int> histogram = List<int>.filled(256, 0);
  for (final int value in gray) {
    histogram[value]++;
  }
  final int total = gray.length;
  double sum = 0;
  for (int i = 0; i < 256; i++) {
    sum += i * histogram[i];
  }
  double sumBackground = 0;
  int weightBackground = 0;
  double bestVariance = -1;
  int best = 128;
  for (int t = 0; t < 256; t++) {
    weightBackground += histogram[t];
    if (weightBackground == 0) continue;
    final int weightForeground = total - weightBackground;
    if (weightForeground == 0) break;
    sumBackground += t * histogram[t];
    final double meanBackground = sumBackground / weightBackground;
    final double meanForeground = (sum - sumBackground) / weightForeground;
    final double between =
        weightBackground *
        weightForeground *
        math.pow(meanBackground - meanForeground, 2).toDouble();
    if (between > bestVariance) {
      bestVariance = between;
      best = t + 1;
    }
  }
  return best;
}
