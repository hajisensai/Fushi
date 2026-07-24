/// 漫画文字块阅读顺序（纯函数）。
///
/// 三步启发式（块投影 + 间距）：
/// 1. **面板聚类** [clusterPanels]：间距小（相对块尺寸）的块并进同一面板
///    （union-find）—— 同一格里的气泡彼此靠近，跨格间距大；
/// 2. **面板整页流向** ：面板包围盒做行带聚类（纵向重叠归同带），带间
///    从上到下，带内 RTL 从右到左（日漫 tier 行主序）；webtoon 纵向长条
///    自然退化为逐格下行；
/// 3. **面板内排序** [orderWithinPanel]：横向重叠的块聚成列，列序 RTL 从右
///    到左、列内从上到下 —— 即竖排文本的「右上 → 左下」列主序。
library;

import 'dart:math' as math;

import 'package:hibiki/src/ocr/ocr_types.dart';

/// 按谓词做 union-find 聚类，返回每簇的原始下标列表。
List<List<int>> _clusterBy(
  int count,
  bool Function(int a, int b) related,
) {
  final List<int> parent = List<int>.generate(count, (int i) => i);
  int find(int x) {
    while (parent[x] != x) {
      parent[x] = parent[parent[x]];
      x = parent[x];
    }
    return x;
  }

  for (int i = 0; i < count; i++) {
    for (int j = i + 1; j < count; j++) {
      if (related(i, j)) {
        final int ri = find(i);
        final int rj = find(j);
        if (ri != rj) {
          parent[ri] = rj;
        }
      }
    }
  }
  final Map<int, List<int>> clusters = <int, List<int>>{};
  for (int i = 0; i < count; i++) {
    clusters.putIfAbsent(find(i), () => <int>[]).add(i);
  }
  return clusters.values.toList();
}

/// 两矩形的轴向间距（相交为 0）。
double _gapX(OcrRect a, OcrRect b) =>
    math.max(0, math.max(a.left, b.left) - math.min(a.right, b.right));

double _gapY(OcrRect a, OcrRect b) =>
    math.max(0, math.max(a.top, b.top) - math.min(a.bottom, b.bottom));

/// 面板聚类：两块的横/纵间距都小于
/// `gapRatio * min(两块各自的短边)` 时视为同一面板。
///
/// 直觉：同格气泡的间距通常小于一个气泡的尺度，跨格间距（含格线/留白）
/// 更大。返回每个面板的块下标列表（无序）。
List<List<int>> clusterPanels(
  List<OcrRect> boxes, {
  double gapRatio = 0.75,
}) {
  double minDim(OcrRect r) => math.min(r.width, r.height);
  return _clusterBy(boxes.length, (int i, int j) {
    final OcrRect a = boxes[i];
    final OcrRect b = boxes[j];
    final double threshold = gapRatio * math.min(minDim(a), minDim(b));
    return _gapX(a, b) <= threshold && _gapY(a, b) <= threshold;
  });
}

/// 面板包围盒。
OcrRect panelBounds(List<OcrRect> boxes, List<int> panel) {
  double left = double.infinity;
  double top = double.infinity;
  double right = double.negativeInfinity;
  double bottom = double.negativeInfinity;
  for (final int i in panel) {
    left = math.min(left, boxes[i].left);
    top = math.min(top, boxes[i].top);
    right = math.max(right, boxes[i].right);
    bottom = math.max(bottom, boxes[i].bottom);
  }
  return OcrRect(left: left, top: top, right: right, bottom: bottom);
}

/// 面板内列主序：横向重叠的块聚成列，列序按阅读方向（RTL 默认右列先），
/// 列内从上到下。返回面板内块的下标（原始下标）排列。
List<int> orderWithinPanel(
  List<OcrRect> boxes,
  List<int> panel, {
  bool rightToLeft = true,
}) {
  final List<List<int>> localColumns = _clusterBy(
    panel.length,
    (int a, int b) => boxes[panel[a]].horizontalOverlaps(boxes[panel[b]]),
  );
  final List<List<int>> columns = <List<int>>[
    for (final List<int> col in localColumns)
      <int>[for (final int local in col) panel[local]],
  ];
  double colCenter(List<int> col) {
    double sum = 0;
    for (final int i in col) {
      sum += boxes[i].centerX;
    }
    return sum / col.length;
  }

  columns.sort((List<int> a, List<int> b) => rightToLeft
      ? colCenter(b).compareTo(colCenter(a))
      : colCenter(a).compareTo(colCenter(b)));
  final List<int> order = <int>[];
  for (final List<int> col in columns) {
    col.sort((int a, int b) => boxes[a].top.compareTo(boxes[b].top));
    order.addAll(col);
  }
  return order;
}

/// 计算整页阅读顺序：返回 [boxes] 的下标排列。
///
/// [rightToLeft] 默认 true（日漫）。webtoon 纵排（块间距大、逐块下行）
/// 自动退化为纯上下序。
List<int> computeReadingOrder(
  List<OcrRect> boxes, {
  bool rightToLeft = true,
  double panelGapRatio = 0.75,
}) {
  if (boxes.isEmpty) {
    return const <int>[];
  }
  final List<List<int>> panels = clusterPanels(boxes, gapRatio: panelGapRatio);
  final List<OcrRect> bounds = <OcrRect>[
    for (final List<int> panel in panels) panelBounds(boxes, panel),
  ];

  // 面板整页流向：行带（纵向重叠）从上到下，带内按阅读方向排。
  final List<List<int>> bands = _clusterBy(
    panels.length,
    (int a, int b) => bounds[a].verticalOverlaps(bounds[b]),
  );
  double bandTop(List<int> band) => band
      .map((int p) => bounds[p].top)
      .reduce((double a, double b) => math.min(a, b));
  bands.sort((List<int> a, List<int> b) => bandTop(a).compareTo(bandTop(b)));

  final List<int> order = <int>[];
  for (final List<int> band in bands) {
    band.sort((int a, int b) => rightToLeft
        ? bounds[b].centerX.compareTo(bounds[a].centerX)
        : bounds[a].centerX.compareTo(bounds[b].centerX));
    for (final int panelIndex in band) {
      order.addAll(orderWithinPanel(boxes, panels[panelIndex],
          rightToLeft: rightToLeft));
    }
  }
  return order;
}
