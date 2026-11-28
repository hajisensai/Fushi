/// 关系网页的确定性布局（AI 库管家 spec §4.4）：分栏 + 贝塞尔连线。
///
/// - 栏从左到右：建议态节点 → 作品成员按媒体分组（小说 / 漫画 / 动画 / 游戏 /
///   有声书 / 音乐）→ 系列（续作 / 前传 / 外传 / 剧场版…，含未入库的相关作品）→
///   卫星（主题曲 / 原声 / 配音）。成员在中间，系列紧挨成员，卫星与建议态分居两侧。
/// - 系列栏内：「另有 N 部」恒在最后。
/// - 栏内自上而下：本条目 → 原作 → 其余按节点 id；各栏纵向居中对齐。
/// - 边从左节点右沿中点连到右节点左沿中点（同栏两节点之间向右鼓出一道弧）。标签
///   恒压在自己那条曲线上：从中点起沿曲线前后找、再在曲线点上下小幅错开，取第一个
///   不压节点、不压先放标签的位置；栏间距按最宽的标签留，跨栏的边自然落进栏缝。
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

/// 系列栏（续作 / 前传 / 外传 / 剧场版…）。
final class WorkNetworkSeriesLane extends WorkNetworkLaneKind {
  const WorkNetworkSeriesLane();
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
  static const double nodeWidth = 160;

  /// 封面 + 三行标题 + 种类小标（前編 / 後編这类区别常在标题末尾，两行会被截掉）。
  static const double nodeHeight = 268;

  /// 栏缝：放得下建议态标签（[suggestedLabelSize]）两侧再各留 [labelMargin]。
  static const double laneGap = 220;
  static const double rowGap = 28;
  static const double padding = 32;
  static const double headerHeight = 36;

  /// 同栏两节点之间的弧向右鼓出的距离：弧顶（0.75 × 鼓出）恰好让已生效标签整个
  /// 落在栏缝里、不压节点。
  static const double sameLaneBulge = 120;

  /// 已生效边的标签框（「同一作品 · AI 关联」放得下）。
  static const Size labelSize = Size(156, 28);

  /// 建议态边的标签框（文字 + 确认 / 否决两个 48dp 按钮）。
  static const Size suggestedLabelSize = Size(196, 48);

  /// 标签与节点 / 别的标签之间至少留的空。
  static const double labelMargin = 4;
}

int _laneRank(WorkNetworkNodeSpec n) => switch (n.role) {
  WorkNetworkRole.suggested => -1,
  WorkNetworkRole.member => n.group.index,
  WorkNetworkRole.series => WorkMediaGroup.values.length,
  WorkNetworkRole.satellite => WorkMediaGroup.values.length + 1,
};

WorkNetworkLaneKind _laneKind(WorkNetworkNodeSpec n) => switch (n.role) {
  WorkNetworkRole.suggested => const WorkNetworkSuggestedLane(),
  WorkNetworkRole.member => WorkNetworkGroupLane(n.group),
  WorkNetworkRole.satellite => const WorkNetworkSatelliteLane(),
  WorkNetworkRole.series => const WorkNetworkSeriesLane(),
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
      final bool aMore = a.moreCount > 0;
      if (aMore != (b.moreCount > 0)) return aMore ? 1 : -1;
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
    final Size labelSize = e.suggested
        ? WorkNetworkMetrics.suggestedLabelSize
        : WorkNetworkMetrics.labelSize;
    final Rect label = _placeLabel(
      start: start,
      c1: c1,
      c2: c2,
      end: end,
      size: labelSize,
      blocked: (Rect r) {
        final Rect padded = r.inflate(WorkNetworkMetrics.labelMargin);
        return placedLabels.any((Rect p) => p.overlaps(padded)) ||
            nodes.values.any((Rect n) => n.overlaps(padded)) ||
            r.top < 0 ||
            r.left < 0;
      },
    );
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

/// 沿曲线找标签位置的参数次序：中点优先，再以 0.02 步长向两端交替。步长要细：
/// 跨两栏的边只有落进栏缝的一小段（栏缝 − 标签宽，约 16 px）放得下标签。
final List<double> _labelTs = <double>[
  0.5,
  for (int k = 1; k <= 24; k++) ...<double>[0.5 - k * 0.02, 0.5 + k * 0.02],
];

/// 标签中心相对曲线点的竖直错开（先不错开，再上下交替，最多半个标签高 + 一行）。
const List<double> _labelDys = <double>[0, -10, 10, -20, 20, -30, 30, -40, 40];

/// 把 [size] 的标签放到曲线上：标签框必含一个曲线点（不离开自己的边）。全都被挡
/// 时退回中点——宁可压住别的东西，也不让标签离开它标的那条边。
Rect _placeLabel({
  required Offset start,
  required Offset c1,
  required Offset c2,
  required Offset end,
  required Size size,
  required bool Function(Rect r) blocked,
}) {
  for (final double t in _labelTs) {
    final Offset p = _cubicPoint(start, c1, c2, end, t);
    for (final double dy in _labelDys) {
      if (dy.abs() * 2 >= size.height) continue; // 曲线点须仍在框内
      final Rect r = Rect.fromCenter(
        center: p.translate(0, dy),
        width: size.width,
        height: size.height,
      );
      if (!blocked(r)) return r;
    }
  }
  return Rect.fromCenter(
    center: _cubicPoint(start, c1, c2, end, 0.5),
    width: size.width,
    height: size.height,
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
