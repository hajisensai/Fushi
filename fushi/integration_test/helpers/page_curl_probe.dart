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
/// 1. **纸背不透字**：平铺背面（离卷起处 > 1.3r、离纸边 > 3px）每个像素颜色一致
///    ——纸背只有纸色与明暗，透出镜像正文时这里会有深浅不一的字形。
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
  if (px == null) {
    out['error'] = 'no pixels';
    return out;
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

  // 1. 平铺背面。
  final Offset v = g.corner - g.point;
  final double len = v.distance;
  final List<List<int>> back = <List<int>>[];
  if (len > 1) {
    final Offset n = v / len;
    final Offset m = Offset(-n.dy, n.dx);
    final double r = math.max(
      0.5,
      math.min(pageCurlRadiusFor(paper.size), len / math.pi),
    );
    final double a = (len - math.pi * r) * 0.5;
    final Offset axis = g.point + n * a;
    out['radius'] = r;
    bool inPaper(Offset q, double margin) =>
        q.dx >= margin &&
        q.dy >= margin &&
        q.dx <= paper.width - margin &&
        q.dy <= paper.height - margin;
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
        if (c != null) back.add(c);
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
  }

  // 2. 纸面外。
  if (baseline != null && paper != Offset.zero & overlayRect.size) {
    int checked = 0;
    int light = 0;
    List<int>? worst;
    for (double y = 2; y < overlayRect.height - 2; y += 8) {
      for (double x = 2; x < overlayRect.width - 2; x += 8) {
        final Offset local = Offset(x, y);
        if (paper.inflate(3).contains(local)) continue;
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
