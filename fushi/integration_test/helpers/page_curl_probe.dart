import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart' show ValueKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/page_curl/page_curl.dart';

import 'observe_capture.dart';

/// 卷页拖到一半停住时，抓 Flutter 图层（卷页叠层在里面，WebView 原生纹理不在）
/// 并按控制器几何做定量检查（用户 2026-11-03 视频 / 截图里的两个问题）：
///
/// 1. **纸背透出镜像正文**（苹果图书的做法，用户 2026-11-04）：平铺背面（离卷起处
///    > 1.3r、离纸边 > 3px）每个像素都不透明，且亮度随快照里被翻起那一点（镜像位置）
///    的亮度线性变化：相关系数 `backCorrelation`、斜率 `backSlope`（≈ 1 − 纸色蒙版
///    比例 [kPageCurlBackVeil]）。源区域没有明暗变化（`sourceSpread` 小）时只看不透明。
/// 2. **黑边不是纸**：纸面矩形比视口小（漫画留黑边）时，纸面外不出现纸色像素——
///    旧实现把整个视口当纸，卷起的纸一直伸进黑边。和卷页开始前的 [baseline]
///    （[capturePageCurlBaseline]）逐点比：纸面外只许不变或变暗（阴影），不许变亮。
///
/// 截图存 `screenshots/<name>.png` 供人眼复核，返回值进证据 JSON。
Future<Map<String, Object?>> probePageCurlShading(
  WidgetTester tester,
  PageCurlController curl,
  String name, {
  Uint8List? baseline,
}) async {
  final Map<String, Object?> out = <String, Object?>{};
  final Finder overlay = find.byKey(
    const ValueKey<String>('fushi_page_curl_overlay'),
  );
  if (overlay.evaluate().isEmpty || !curl.visible) {
    out['error'] = 'overlay not painted';
    return out;
  }
  final Rect overlayRect = tester.getRect(overlay);
  final PageCurlGeometry g = curl.geometry;
  final Rect paper = g.paper;
  out['overlay'] = _rect(overlayRect);
  out['paper'] = _rect(paper);
  out['corner'] = <double>[g.corner.dx, g.corner.dy];
  out['point'] = <double>[g.point.dx, g.point.dy];
  out['mirror'] = g.mirror;

  final RenderView view = tester.binding.renderViews.first;
  final double dpr = tester.view.devicePixelRatio;
  final int iw = (view.paintBounds.width).round();
  final int ih = (view.paintBounds.height).round();
  final Uint8List? px = await capturePageCurlBaseline(tester);
  final ui.Image? sheet = curl.sheet;
  final ByteData? sheetBytes = await sheet?.toByteData(
    format: ui.ImageByteFormat.rawRgba,
  );
  if (px == null || sheet == null || sheetBytes == null) {
    out['error'] = 'no pixels';
    return out;
  }
  // 快照里纸面局部、未镜像坐标 q 处的亮度（与 shader 的 sheetUv 同一映射）。
  int sheetLuma(Offset q) {
    double cx = q.dx.clamp(0.0, paper.width);
    final double cy = q.dy.clamp(0.0, paper.height);
    if (g.mirror) cx = paper.width - cx;
    final double u = ((paper.left + cx) / overlayRect.width).clamp(0.0, 1.0);
    final double w = ((paper.top + cy) / overlayRect.height).clamp(0.0, 1.0);
    final int x = (u * (sheet.width - 1)).round();
    final int y = (w * (sheet.height - 1)).round();
    final int i = (y * sheet.width + x) * 4;
    return math.max(
      sheetBytes.getUint8(i),
      math.max(sheetBytes.getUint8(i + 1), sheetBytes.getUint8(i + 2)),
    );
  }

  // 覆盖层局部（逻辑像素）→ 图像像素。
  List<int>? at(Offset local) {
    final Offset global = overlayRect.topLeft + local;
    final int x = (global.dx * dpr).floor();
    final int y = (global.dy * dpr).floor();
    if (x < 0 || y < 0 || x >= iw || y >= ih) return null;
    final int i = (y * iw + x) * 4;
    return <int>[px[i], px[i + 1], px[i + 2], px[i + 3]];
  }

  int? lumaBefore(Offset local) {
    final Uint8List? b = baseline;
    if (b == null) return null;
    final Offset global = overlayRect.topLeft + local;
    final int i =
        ((global.dy * dpr).floor() * iw + (global.dx * dpr).floor()) * 4;
    if (i < 0 || i + 2 >= b.length) return null;
    return math.max(b[i], math.max(b[i + 1], b[i + 2]));
  }

  // 纸面局部、未镜像 → 覆盖层局部。
  Offset toOverlay(Offset q) => Offset(
    g.mirror ? paper.right - q.dx : paper.left + q.dx,
    paper.top + q.dy,
  );

  // 与 shaders/page_curl.frag 同一套几何。
  final Offset v = g.corner - g.point;
  final double len = v.distance;
  final Offset n = len > 1 ? v / len : const Offset(1, 0);
  final Offset m = Offset(-n.dy, n.dx);
  final double r = math.max(
    0.5,
    math.min(pageCurlRadiusFor(paper.size), len / math.pi),
  );
  final double a = (len - math.pi * r) * 0.5;
  final Offset axis = g.point + n * a;
  bool inPaper(Offset q, double margin) =>
      q.dx >= margin &&
      q.dy >= margin &&
      q.dx <= paper.width - margin &&
      q.dy <= paper.height - margin;
  // 覆盖层局部 → 纸面局部、未镜像。
  Offset toPaper(Offset local) {
    final double x = local.dx - paper.left;
    return Offset(g.mirror ? paper.width - x : x, local.dy - paper.top);
  }

  // 这一点上方有没有翻起的纸（背面平铺 / 圆柱）：翻起的那片绕卷轴镜像过来，
  // 斜卷时可以合理地越出原页边，这些点不算「纸面外」。
  bool liftedOver(Offset local) {
    if (len <= 1) return false;
    final Offset p = toPaper(local);
    final double d = (p - axis).dx * n.dx + (p - axis).dy * n.dy;
    if (d <= 0) return inPaper(p + n * (math.pi * r - 2 * d), -1.5);
    if (d > r) return false;
    final double theta = math.asin((d / r).clamp(0.0, 1.0));
    return inPaper(p + n * (r * (math.pi - theta) - d), -1.5) ||
        inPaper(p + n * (r * theta - d), -1.5);
  }

  // 1. 平铺背面。
  final List<List<int>> back = <List<int>>[];
  final List<int> source = <int>[];
  if (len > 1) {
    out['radius'] = r;
    for (double t = 1.3 * r; t < a; t += math.max(2, a / 24)) {
      for (double s = -paper.height; s <= paper.height; s += 6) {
        final Offset p = axis - n * t + m * s;
        final Offset qBack = p + n * (math.pi * r + 2 * t);
        if (!inPaper(qBack, 3)) continue;
        final Offset local = toOverlay(p);
        if (!(Offset.zero & overlayRect.size).deflate(2).contains(local)) {
          continue;
        }
        final List<int>? c = at(local);
        if (c == null) continue;
        back.add(c);
        source.add(sheetLuma(qBack));
      }
    }
  }
  out['backSamples'] = back.length;
  if (back.isNotEmpty) {
    int spread = 0;
    for (int ch = 0; ch < 4; ch++) {
      final Iterable<int> vals = back.map((List<int> c) => c[ch]);
      spread = math.max(spread, vals.reduce(math.max) - vals.reduce(math.min));
    }
    out['backSpread'] = spread;
    out['backColor'] = back.first;
    out['backOpaque'] = back.every((List<int> c) => c[3] == 255);
    final List<int> luma = back
        .map((List<int> c) => math.max(c[0], math.max(c[1], c[2])))
        .toList();
    out['sourceSpread'] = source.reduce(math.max) - source.reduce(math.min);
    final double mx = source.reduce((int a, int b) => a + b) / source.length;
    final double my = luma.reduce((int a, int b) => a + b) / luma.length;
    double sxy = 0, sxx = 0, syy = 0;
    for (int i = 0; i < source.length; i++) {
      final double dx = source[i] - mx;
      final double dy = luma[i] - my;
      sxy += dx * dy;
      sxx += dx * dx;
      syy += dy * dy;
    }
    if (sxx > 0 && syy > 0) {
      out['backCorrelation'] = sxy / math.sqrt(sxx * syy);
      out['backSlope'] = sxy / sxx;
    }
  }

  // 2. 纸面外。
  if (baseline != null && paper != Offset.zero & overlayRect.size) {
    int checked = 0;
    int light = 0;
    List<int>? worst;
    for (double y = 2; y < overlayRect.height - 2; y += 8) {
      for (double x = 2; x < overlayRect.width - 2; x += 8) {
        final Offset local = Offset(x, y);
        if (paper.inflate(3).contains(local) || liftedOver(local)) continue;
        final List<int>? c = at(local);
        final int? before = lumaBefore(local);
        if (c == null || before == null) continue;
        checked++;
        final int maxRgb = math.max(c[0], math.max(c[1], c[2]));
        if (maxRgb > before + 30) {
          light++;
          worst ??= c;
        }
      }
    }
    out['outsideSamples'] = checked;
    out['outsideLight'] = light;
    out['outsideWorst'] = worst;
  }

  final ObserveShot shot = await captureFlutterFrame(tester, name);
  out['shot'] = shot.path;
  return out;
}

/// 抓一帧 Flutter 图层（含 WebView 纹理的平台）的 RGBA，卷页开始前调用当基线。
Future<Uint8List?> capturePageCurlBaseline(WidgetTester tester) async {
  final RenderView view = tester.binding.renderViews.first;
  final OffsetLayer layer = view.debugLayer! as OffsetLayer;
  final ui.Image image = await layer.toImage(view.paintBounds);
  try {
    final ByteData? rgba = await image.toByteData(
      format: ui.ImageByteFormat.rawRgba,
    );
    return rgba?.buffer.asUint8List();
  } finally {
    image.dispose();
  }
}

List<double> _rect(Rect r) => <double>[r.left, r.top, r.width, r.height];

/// 纸背检查（两条 itest 共用）：不透明；源区域有明暗时亮度跟着镜像正文走。
bool pageCurlBackShowsMirroredText(Map<String, Object?> shading) {
  if (((shading['backSamples'] as int?) ?? 0) < 30) return false;
  if (shading['backOpaque'] != true) return false;
  if (((shading['sourceSpread'] as int?) ?? 0) < 40) return true;
  final double corr = (shading['backCorrelation'] as double?) ?? 0;
  final double slope = (shading['backSlope'] as double?) ?? 0;
  const double expected = 1 - kPageCurlBackVeil;
  return corr >= 0.8 && (slope - expected).abs() <= 0.15;
}
