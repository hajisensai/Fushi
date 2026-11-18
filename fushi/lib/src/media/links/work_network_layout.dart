/// 关系网页的确定性布局（AI 库管家 spec §4.4）：分栏 + 贝塞尔连线。
///
/// - 栏从左到右：建议态节点 → 作品成员按媒体分组（小说 / 漫画 / 动画 / 游戏 /
///   有声书 / 音乐）→ 卫星（主题曲 / 原声 / 配音）。成员在中间，卫星与建议态分居
///   两侧。
/// - 栏内自上而下：本条目 → 原作 → 其余按节点 id；各栏纵向居中对齐。
/// - 边从左节点右沿中点连到右节点左沿中点（同栏两节点之间向右鼓出一道弧），标签
///   放在曲线中点，与先放的标签重叠就往下错开。
///
/// 纯函数：同一份 [WorkNetworkPlan] 永远得到同一组坐标（不依赖屏幕宽度——窄屏靠
/// 两向滚动看全，不改排法，避免旋转 / 调窗口时节点跳位）。
library;

import 'dart:math' as math;
import 'dart:ui' show Offset, Rect, Size;

import 'package:fushi/src/media/links/work_graph_store.dart';
import 'package:fushi/src/media/links/work_plans.dart';
import 'package:fushi_engine/media/links/work_graph.dart';

/// 一栏是什么（页面按它取栏名）。
sealed class WorkNetworkLaneKind {
  const WorkNetworkLaneKind();
}

/// 建议态节点栏。
final class WorkNetworkSuggestedLane extends WorkNetworkLaneKind {
  const WorkNetworkSuggestedLane();
}

/// 作品成员的一个媒体分组栏。
final class WorkNetworkGroupLane extends WorkNetworkLaneKind {
  const WorkNetworkGroupLane(this.group);
  final WorkMediaGroup group;
}

/// 卫星栏。
final class WorkNetworkSatelliteLane extends WorkNetworkLaneKind {
  const WorkNetworkSatelliteLane();
}

/// 一栏的位置。
typedef WorkNetworkLane = ({WorkNetworkLaneKind kind, Rect header});

/// 一条边的几何：三次贝塞尔 [start] → [control1] → [control2] → [end]，标签框
/// [label]（中心在曲线中点附近）。
typedef WorkNetworkEdgeGeometry = ({
  Offset start,
  Offset control1,
  Offset control2,
  Offset end,
  Rect label,
});

/// 布局结果。
final class WorkNetworkLayout {
  const WorkNetworkLayout({
    required this.size,
    required this.lanes,
    required this.nodes,
    required this.nodeOrder,
    required this.edges,
  });

  /// 画布大小（含四周留白）。
  final Size size;
  final List<WorkNetworkLane> lanes;

  /// 节点 id → 节点框。
  final Map<String, Rect> nodes;

  /// 节点的阅读顺序（逐栏自上而下）：错峰入场与焦点遍历都按它。
  final List<String> nodeOrder;

  /// 与 [WorkNetworkPlan.edges] 一一对应。
  final List<WorkNetworkEdgeGeometry> edges;
}

/// 布局常量。
abstract final class WorkNetworkMetrics {
  static const double nodeWidth = 136;
  static const double nodeHeight = 204;
  static const double laneGap = 136;
  static const double rowGap = 28;
  static const double padding = 32;
  static const double headerHeight = 36;

  /// 同栏两节点之间的弧向右鼓出的距离。
  static const double sameLaneBulge = 64;

  /// 已生效边的标签框。
  static const Size labelSize = Size(120, 28);

  /// 建议态边的标签框（文字 + 确认 / 否决两个 48dp 按钮）。
  static const Size suggestedLabelSize = Size(200, 48);
}

int _laneRank(WorkNetworkNodeSpec n) => switch (n.role) {
  WorkNetworkRole.suggested => -1,
  WorkNetworkRole.member => n.group.index,
  WorkNetworkRole.satellite => WorkMediaGroup.values.length,
};

WorkNetworkLaneKind _laneKind(WorkNetworkNodeSpec n) => switch (n.role) {
  WorkNetworkRole.suggested => const WorkNetworkSuggestedLane(),
  WorkNetworkRole.member => WorkNetworkGroupLane(n.group),
  WorkNetworkRole.satellite => const WorkNetworkSatelliteLane(),
};

/// 算 [plan] 的布局。
WorkNetworkLayout layoutWorkNetwork(WorkNetworkPlan plan) {
  const double w = WorkNetworkMetrics.nodeWidth;
  const double h = WorkNetworkMetrics.nodeHeight;
  const double pad = WorkNetworkMetrics.padding;

  final Map<int, List<WorkNetworkNodeSpec>> byLane =
      <int, List<WorkNetworkNodeSpec>>{};
  for (final WorkNetworkNodeSpec n in plan.nodes) {
    (byLane[_laneRank(n)] ??= <WorkNetworkNodeSpec>[]).add(n);
  }
  final List<int> laneRanks = byLane.keys.toList()..sort();
  for (final List<WorkNetworkNodeSpec> lane in byLane.values) {
    lane.sort((WorkNetworkNodeSpec a, WorkNetworkNodeSpec b) {
      if (a.isSelf != b.isSelf) return a.isSelf ? -1 : 1;
      if (a.original != b.original) return a.original ? -1 : 1;
      return a.id.compareTo(b.id);
    });
  }
  int tallest = 0;
  for (final List<WorkNetworkNodeSpec> lane in byLane.values) {
    tallest = math.max(tallest, lane.length);
  }
  double laneHeight(int count) =>
      count * h + math.max(0, count - 1) * WorkNetworkMetrics.rowGap;
  final double bodyHeight = laneHeight(tallest);
  const double top = pad + WorkNetworkMetrics.headerHeight;

  final Map<String, Rect> nodes = <String, Rect>{};
  final Map<String, int> laneOf = <String, int>{};
  final List<String> order = <String>[];
  final List<WorkNetworkLane> lanes = <WorkNetworkLane>[];
  for (int li = 0; li < laneRanks.length; li++) {
    final List<WorkNetworkNodeSpec> lane = byLane[laneRanks[li]]!;
    final double x = pad + li * (w + WorkNetworkMetrics.laneGap);
    lanes.add((
      kind: _laneKind(lane.first),
      header: Rect.fromLTWH(x, pad, w, WorkNetworkMetrics.headerHeight),
    ));
    double y = top + (bodyHeight - laneHeight(lane.length)) / 2;
    for (final WorkNetworkNodeSpec n in lane) {
      nodes[n.id] = Rect.fromLTWH(x, y, w, h);
      laneOf[n.id] = li;
      order.add(n.id);
      y += h + WorkNetworkMetrics.rowGap;
    }
  }

  double right = pad + math.max(0, laneRanks.length) * w;
  if (laneRanks.length > 1) {
    right += (laneRanks.length - 1) * WorkNetworkMetrics.laneGap;
  }
  double bottom = top + bodyHeight;

  final List<Rect> placedLabels = <Rect>[];
  final List<WorkNetworkEdgeGeometry> edges = <WorkNetworkEdgeGeometry>[];
  for (final WorkNetworkEdgeSpec e in plan.edges) {
    final Rect a = nodes[e.from]!;
    final Rect b = nodes[e.to]!;
    final int la = laneOf[e.from]!;
    final int lb = laneOf[e.to]!;
    final Offset start;
    final Offset end;
    final Offset c1;
    final Offset c2;
    if (la == lb) {
      start = a.centerRight;
      end = b.centerRight;
      const Offset bulge = Offset(WorkNetworkMetrics.sameLaneBulge, 0);
      c1 = start + bulge;
      c2 = end + bulge;
    } else {
      start = la < lb ? a.centerRight : a.centerLeft;
      end = la < lb ? b.centerLeft : b.centerRight;
      final double half = (end.dx - start.dx) / 2;
      c1 = Offset(start.dx + half, start.dy);
      c2 = Offset(end.dx - half, end.dy);
    }
    final Offset mid = _cubicPoint(start, c1, c2, end, 0.5);
    final Size labelSize = e.suggested
        ? WorkNetworkMetrics.suggestedLabelSize
        : WorkNetworkMetrics.labelSize;
    Rect label = Rect.fromCenter(
      center: mid,
      width: labelSize.width,
      height: labelSize.height,
    );
    // 与已放的标签（及节点）重叠就往下错开，直到不重叠。
    bool overlaps(Rect r) =>
        placedLabels.any((Rect p) => p.overlaps(r)) ||
        nodes.values.any((Rect n) => n.overlaps(r));
    int guard = 0;
    while (overlaps(label) && guard < 128) {
      label = label.shift(const Offset(0, 8));
      guard++;
    }
    placedLabels.add(label);
    right = math.max(right, math.max(label.right, c1.dx));
    bottom = math.max(bottom, label.bottom);
    edges.add((
      start: start,
      control1: c1,
      control2: c2,
      end: end,
      label: label,
    ));
  }

  return WorkNetworkLayout(
    size: Size(right + pad, bottom + pad),
    lanes: lanes,
    nodes: nodes,
    nodeOrder: order,
    edges: edges,
  );
}

/// 三次贝塞尔上参数 [t] 处的点。
Offset _cubicPoint(Offset p0, Offset p1, Offset p2, Offset p3, double t) {
  final double u = 1 - t;
  return p0 * (u * u * u) +
      p1 * (3 * u * u * t) +
      p2 * (3 * u * t * t) +
      p3 * (t * t * t);
}
