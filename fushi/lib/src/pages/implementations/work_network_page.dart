import 'dart:async';
import 'dart:io' show File;
import 'dart:math' as math;
import 'dart:ui' show PathMetric;

import 'package:drift/drift.dart' show TableUpdate, TableUpdateQuery;
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/links/media_link_editor_dialog.dart';
import 'package:fushi/src/media/links/media_link_entries.dart';
import 'package:fushi/src/media/links/theme_song/theme_song_plan.dart'
    show ThemeSongRole;
import 'package:fushi/src/media/links/work_graph_store.dart';
import 'package:fushi/src/media/links/work_network_layout.dart';
import 'package:fushi/src/media/links/work_plans.dart';
import 'package:fushi/src/media/video/cover_ui/portrait_cover_image.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/cover_image.dart'
    show kLocalCoverDecodePixelWidth, resizedFileImage;
import 'package:fushi/src/utils/components/fushi_hover_lift.dart';
import 'package:fushi/src/utils/components/fushi_m3e_list_card.dart'
    show FushiCardTone;
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_placeholder_message.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/components/shelf_card_widgets.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/platform_utils.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/links/work_graph.dart';
import 'package:material_ui/material_ui.dart';

/// 关系网页（AI 库管家 spec `docs/specs/2026-11-18-ai-library-curator-design.md`
/// §4.4）：一部作品的成员、卫星（主题曲 / 原声 / 配音）与它们之间的全部连接。
///
/// - 布局：[layoutWorkNetwork] 的确定性分栏（建议态 | 成员按媒体分组 | 卫星），连线
///   由 [CustomPainter] 画三次贝塞尔，按关系类型取主题色板着色并带文字标签，有方向
///   的关系（改编、主题曲…）带箭头；建议态节点与边画虚线。节点多时两向滚动，同一份
///   输入布局恒定。
/// - 节点 = 封面 + 标题 + 种类小标，同一系列合集的各卷折成一个节点。可聚焦，Enter /
///   点击经 [onOpen] 打开条目（详情页注入，与「同一作品」区块同一出口）。
/// - 建议态的边带「确认」/「不相关」两键，动作与区块建议卡同一套
///   （[confirmMediaLinks] / [rejectMediaLinks]）。
/// - 数据取进程级 [WorkGraphStore]，随连接 / 合集变更自动刷新。
/// - MD3 与 Apple 两套：页面壳 [FushiPageScaffold]、节点 [FushiCard]、按钮
///   [FushiIconButtonControl] 都是设计系统分派件；动效走错峰入场 + 悬停抬升 + 按压
///   缩放（[FushiCard] 自带），时长只取 [FushiMotion]。
class WorkNetworkPage extends StatefulWidget {
  const WorkNetworkPage({
    required this.database,
    required this.endpoint,
    required this.onOpen,
    this.onInfer,
    super.key,
  });

  final FushiDatabase database;

  /// 关系网从哪个端点展开（它所在的作品）。
  final MediaLinkEndpoint endpoint;

  /// 打开一个节点对应的条目。
  final void Function(MediaLinkEntry entry) onOpen;

  /// 空态的「查找相关作品」；null = 不显示。
  final Future<int> Function()? onInfer;

  @override
  State<WorkNetworkPage> createState() => _WorkNetworkPageState();
}

/// 一次加载的结果。
class _NetworkData {
  const _NetworkData({
    required this.plan,
    required this.layout,
    required this.entries,
    required this.edgeRows,
  });

  final WorkNetworkPlan plan;
  final WorkNetworkLayout layout;

  /// 节点 id → 展示信息。
  final Map<String, MediaLinkEntry> entries;

  /// 与 [WorkNetworkPlan.edges] 一一对应：折进这条边的落库行（取主题曲角色、AI 来源）。
  final List<List<MediaLinkRow>> edgeRows;
}

class _WorkNetworkPageState extends State<WorkNetworkPage> {
  late final WorkGraphStore _store = WorkGraphStore.of(widget.database);
  StreamSubscription<Set<TableUpdate>>? _tableSub;
  Future<_NetworkData?>? _data;
  final ScrollController _vertical = ScrollController();
  final ScrollController _horizontal = ScrollController();
  bool _inferring = false;

  @override
  void initState() {
    super.initState();
    _store.addListener(_reload);
    _data = _load();
    // 建议边确认 / 否决后，图要等 store 去抖重建；边上的 AI 标识等行级信息先跟上。
    _tableSub = widget.database
        .tableUpdates(TableUpdateQuery.onTable(widget.database.mediaLinks))
        .listen((_) => _reload());
  }

  @override
  void dispose() {
    _store.removeListener(_reload);
    unawaited(_tableSub?.cancel());
    _vertical.dispose();
    _horizontal.dispose();
    super.dispose();
  }

  void _reload() {
    if (!mounted) return;
    setState(() {
      _data = _load();
    });
  }

  Future<_NetworkData?> _load() async {
    final WorkGraphSnapshot? snapshot = _store.value;
    if (snapshot == null) return null;
    final FushiDatabase db = widget.database;
    final WorkNetworkPlan plan = planWorkNetwork(snapshot, widget.endpoint);
    final Map<String, MediaLinkEntry> entries = <String, MediaLinkEntry>{};
    for (final WorkNetworkNodeSpec n in plan.nodes) {
      final MediaLinkEntry entry = await resolveMediaLinkEntry(db, n.target);
      final WorkSeriesInfo? series = n.series;
      entries[n.id] = series == null || series.name.isEmpty
          ? entry
          : MediaLinkEntry(
              endpoint: entry.endpoint,
              title: series.name,
              inLibrary: entry.inLibrary,
              coverPath: entry.coverPath,
            );
    }
    final List<List<MediaLinkRow>> edgeRows = <List<MediaLinkRow>>[];
    for (final WorkNetworkEdgeSpec e in plan.edges) {
      edgeRows.add(<MediaLinkRow>[
        for (final MediaLinkId id in e.ids) ?await db.mediaLinkById(id),
      ]);
    }
    return _NetworkData(
      plan: plan,
      layout: layoutWorkNetwork(plan),
      entries: entries,
      edgeRows: edgeRows,
    );
  }

  Future<void> _infer() async {
    final Future<int> Function()? infer = widget.onInfer;
    if (infer == null || _inferring) return;
    setState(() => _inferring = true);
    try {
      final int added = await infer();
      FushiToast.show(
        msg: added > 0
            ? t.media_link_infer_found(count: added)
            : t.media_link_infer_none,
        severity: ToastSeverity.info,
      );
    } finally {
      if (mounted) setState(() => _inferring = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FushiPageScaffold(
      masthead: true,
      title: t.media_link_network_title,
      body: Builder(
        builder: (BuildContext context) {
          // 页头浮在正文上：顶部让位从 body 子树里的 context 读。
          final double topInset = MediaQuery.paddingOf(context).top;
          return FutureBuilder<_NetworkData?>(
            future: _data,
            builder: (BuildContext context, AsyncSnapshot<_NetworkData?> snap) {
              final _NetworkData? data = snap.data;
              if (data == null) {
                return Padding(
                  padding: EdgeInsets.only(top: topInset),
                  child: const Center(child: FushiCircularProgressIndicator()),
                );
              }
              if (data.plan.nodes.length <= 1) {
                return Padding(
                  padding: EdgeInsets.only(top: topInset),
                  child: _buildEmpty(context),
                );
              }
              return _buildNetwork(context, data, topInset);
            },
          );
        },
      ),
    );
  }

  Widget _buildEmpty(BuildContext context) {
    return Center(
      key: const ValueKey<String>('work-network-empty'),
      child: FushiPlaceholderMessage(
        icon: FushiIcons.hub,
        message: t.media_link_network_empty,
        action: Wrap(
          spacing: 8,
          runSpacing: 8,
          alignment: WrapAlignment.center,
          children: <Widget>[
            if (widget.onInfer != null)
              FushiTextButton(
                key: const ValueKey<String>('work-network-infer'),
                onPressed: _inferring ? null : _infer,
                child: Text(t.media_link_infer_action),
              ),
            FushiTextButton(
              key: const ValueKey<String>('work-network-add'),
              onPressed: () => unawaited(
                showMediaLinkEditorDialog(
                  context: context,
                  database: widget.database,
                  self: widget.endpoint,
                ),
              ),
              child: Text(t.media_link_add),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNetwork(
    BuildContext context,
    _NetworkData data,
    double topInset,
  ) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final WorkNetworkLayout layout = data.layout;
    final Map<String, WorkNetworkNodeSpec> nodeById =
        <String, WorkNetworkNodeSpec>{
          for (final WorkNetworkNodeSpec n in data.plan.nodes) n.id: n,
        };
    final List<Widget> children = <Widget>[
      Positioned.fill(
        child: TweenAnimationBuilder<double>(
          tween: Tween<double>(begin: 0, end: 1),
          duration: fushiMotionDuration(context, FushiMotion.long),
          curve: FushiMotion.enter,
          builder: (BuildContext context, double opacity, Widget? _) =>
              CustomPaint(
                key: const ValueKey<String>('work-network-edges'),
                painter: WorkNetworkEdgePainter(
                  edges: <WorkNetworkPaintedEdge>[
                    for (int i = 0; i < data.plan.edges.length; i++)
                      (
                        geometry: layout.edges[i],
                        color: workNetworkRelationColor(
                          scheme,
                          data.plan.edges[i].relation,
                        ),
                        dashed: data.plan.edges[i].suggested,
                        directed: data.plan.edges[i].directed,
                      ),
                  ],
                  opacity: opacity,
                ),
              ),
        ),
      ),
      for (final WorkNetworkLane lane in layout.lanes)
        Positioned.fromRect(
          rect: lane.header,
          child: Align(
            alignment: Alignment.bottomLeft,
            child: Text(
              _laneLabel(lane.kind),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                context,
              ).textTheme.labelLarge?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
        ),
      for (int i = 0; i < layout.nodeOrder.length; i++)
        Positioned.fromRect(
          rect: layout.nodes[layout.nodeOrder[i]]!,
          child: FushiStaggeredEntrance(
            index: i,
            child: _NetworkNode(
              spec: nodeById[layout.nodeOrder[i]]!,
              entry: data.entries[layout.nodeOrder[i]]!,
              onOpen: widget.onOpen,
            ),
          ),
        ),
      for (int i = 0; i < data.plan.edges.length; i++)
        Positioned.fromRect(
          rect: layout.edges[i].label,
          child: _EdgeLabel(
            edge: data.plan.edges[i],
            rows: data.edgeRows[i],
            onConfirm: () =>
                confirmMediaLinks(widget.database, data.plan.edges[i].ids),
            onReject: () =>
                rejectMediaLinks(widget.database, data.plan.edges[i].ids),
          ),
        ),
    ];
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // 画布比视口小就居中；比视口大两向滚动。
        final double width = math.max(layout.size.width, constraints.maxWidth);
        return FushiEntranceScope(
          replayKey: widget.endpoint,
          child: Scrollbar(
            controller: _vertical,
            child: SingleChildScrollView(
              key: const ValueKey<String>('work-network-vertical'),
              controller: _vertical,
              physics: desktopAwareScrollPhysics(),
              padding: EdgeInsets.only(top: topInset),
              child: Scrollbar(
                controller: _horizontal,
                notificationPredicate: (ScrollNotification n) =>
                    n.metrics.axis == Axis.horizontal,
                child: HorizontalDragScrollable(
                  child: SingleChildScrollView(
                    key: const ValueKey<String>('work-network-horizontal'),
                    controller: _horizontal,
                    scrollDirection: Axis.horizontal,
                    physics: desktopAwareScrollPhysics(),
                    child: SizedBox(
                      width: width,
                      height: layout.size.height,
                      child: Align(
                        alignment: Alignment.topCenter,
                        child: SizedBox.fromSize(
                          key: const ValueKey<String>('work-network-canvas'),
                          size: layout.size,
                          child: FocusTraversalGroup(
                            child: Stack(children: children),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  String _laneLabel(WorkNetworkLaneKind kind) => switch (kind) {
    WorkNetworkSuggestedLane() => t.media_link_suggestions_title,
    WorkNetworkGroupLane(:final WorkMediaGroup group) => workMediaGroupLabel(
      group,
    ),
    WorkNetworkSatelliteLane() => t.media_link_group_satellites,
  };
}

/// 关系类型 → 连线颜色。只取主题色板，深浅两套主题下都与 surface 有对比。
Color workNetworkRelationColor(
  ColorScheme scheme,
  MediaLinkRelation relation,
) => switch (relation) {
  MediaLinkRelation.adaptation => scheme.primary,
  MediaLinkRelation.sameWork => scheme.secondary,
  MediaLinkRelation.themeSong => scheme.tertiary,
  MediaLinkRelation.soundtrack => scheme.onTertiaryContainer,
  MediaLinkRelation.cast => scheme.outline,
};

/// 边的标签文字：主题曲按角色细分（OP / ED / 插入曲 / 主题曲），其余取关系名。
String workNetworkEdgeLabel(
  MediaLinkRelation relation,
  List<MediaLinkRow> rows,
) {
  if (relation == MediaLinkRelation.themeSong) {
    final List<ThemeSongRole> roles = <ThemeSongRole>[
      for (final ThemeSongRole r in ThemeSongRole.values)
        if (rows.any(
          (MediaLinkRow row) => ThemeSongRole.tryParse(row.role) == r,
        ))
          r,
    ];
    if (roles.isNotEmpty) {
      return roles.map(mediaLinkThemeSongRoleLabel).join(' / ');
    }
  }
  return mediaLinkRelationLabel(relation);
}

/// 画布上的一条边（几何 + 样式）。
typedef WorkNetworkPaintedEdge = ({
  WorkNetworkEdgeGeometry geometry,
  Color color,
  bool dashed,
  bool directed,
});

/// 连线画家：三次贝塞尔，建议态虚线，有方向的关系在终点画箭头。
class WorkNetworkEdgePainter extends CustomPainter {
  WorkNetworkEdgePainter({required this.edges, required this.opacity});

  final List<WorkNetworkPaintedEdge> edges;
  final double opacity;

  @override
  void paint(Canvas canvas, Size size) {
    for (final WorkNetworkPaintedEdge e in edges) {
      final WorkNetworkEdgeGeometry g = e.geometry;
      final Color color = e.color.withValues(
        alpha: e.color.a * opacity * (e.dashed ? 0.8 : 1),
      );
      final Paint stroke = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = e.dashed ? 1.5 : 2
        ..strokeCap = StrokeCap.round;
      final Path path = Path()
        ..moveTo(g.start.dx, g.start.dy)
        ..cubicTo(
          g.control1.dx,
          g.control1.dy,
          g.control2.dx,
          g.control2.dy,
          g.end.dx,
          g.end.dy,
        );
      canvas.drawPath(e.dashed ? _dashed(path) : path, stroke);
      if (e.directed) _arrow(canvas, g, color);
    }
  }

  static Path _dashed(Path source) {
    const double dash = 7;
    const double gap = 5;
    final Path out = Path();
    for (final PathMetric metric in source.computeMetrics()) {
      double d = 0;
      while (d < metric.length) {
        out.addPath(
          metric.extractPath(d, math.min(d + dash, metric.length)),
          Offset.zero,
        );
        d += dash + gap;
      }
    }
    return out;
  }

  static void _arrow(Canvas canvas, WorkNetworkEdgeGeometry g, Color color) {
    Offset dir = g.end - g.control2;
    if (dir.distance < 0.001) dir = g.end - g.start;
    if (dir.distance < 0.001) return;
    final Offset u = dir / dir.distance;
    final Offset n = Offset(-u.dy, u.dx);
    const double length = 10;
    const double half = 5;
    final Offset tip = g.end;
    final Offset base = tip - u * length;
    canvas.drawPath(
      Path()
        ..moveTo(tip.dx, tip.dy)
        ..lineTo((base + n * half).dx, (base + n * half).dy)
        ..lineTo((base - n * half).dx, (base - n * half).dy)
        ..close(),
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(WorkNetworkEdgePainter oldDelegate) =>
      oldDelegate.opacity != opacity || oldDelegate.edges != edges;
}

/// 一个节点：封面 + 标题 + 种类小标。建议态描虚线边，本条目用强调色底。
class _NetworkNode extends StatelessWidget {
  const _NetworkNode({
    required this.spec,
    required this.entry,
    required this.onOpen,
  });

  final WorkNetworkNodeSpec spec;
  final MediaLinkEntry entry;
  final void Function(MediaLinkEntry entry) onOpen;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final bool missing = !entry.inLibrary;
    final String kindLabel =
        spec.series != null && spec.series!.endpoint == null
        ? '${workMediaGroupLabel(spec.group)} · '
              '${t.media_link_series_volumes(count: spec.series!.volumeCount)}'
        : workMediaGroupLabel(spec.group);
    final List<String> tags = <String>[
      kindLabel,
      if (spec.original) t.media_link_role_original,
      if (spec.isSelf) t.media_link_network_self,
      if (missing) t.media_link_not_in_library,
    ];
    final Widget card = FushiCard(
      key: ValueKey<String>('work-network-node-${spec.id}'),
      padding: const EdgeInsets.all(8),
      tone: spec.isSelf ? FushiCardTone.primary : FushiCardTone.neutral,
      onTap: missing ? null : () => onOpen(entry),
      child: Opacity(
        opacity: missing ? 0.55 : 1,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Expanded(
              child: Center(
                child: AspectRatio(
                  aspectRatio: 2 / 3,
                  child: ClipRRect(
                    borderRadius: FushiBorderRadius.card,
                    child: _cover(context),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              entry.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 2),
            Row(
              children: <Widget>[
                FushiIcon(
                  mediaLinkKindIcon(spec.target.kind),
                  size: 14,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    tags.join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
    final Widget bordered = spec.role == WorkNetworkRole.suggested
        ? CustomPaint(
            foregroundPainter: _DashedBorderPainter(
              color: scheme.outline,
              radius: FushiBorderRadius.card,
            ),
            child: card,
          )
        : card;
    return Semantics(
      container: true,
      label: '${entry.title}, ${tags.join(', ')}',
      child: FushiTooltip(
        message: entry.title,
        child: FushiHoverLift(
          enabled: !missing,
          builder: (BuildContext context, bool _) => bordered,
        ),
      ),
    );
  }

  Widget _cover(BuildContext context) {
    // 与区块同一口径（本机封面文件按库页解码上限缩放）；不经 `media_cover_source`
    // ——那里为书架远端封面依赖 AppModel，会把本页拖进 import 大环。
    final String? path = entry.coverPath;
    final ImageProvider? local =
        mediaKindOfLinkKind(entry.endpoint.kind) == null ||
            path == null ||
            path.isEmpty
        ? null
        : resizedFileImage(File(path), width: kLocalCoverDecodePixelWidth);
    final Widget placeholder = ShelfCoverPlaceholder(
      icon: mediaLinkKindIcon(entry.endpoint.kind),
      iconSize: 28,
      backgroundColor: FushiDesignTokens.of(context).surfaces.overlay,
    );
    if (local == null) return placeholder;
    return PortraitCoverImage(
      image: local,
      errorBuilder: (BuildContext _) => placeholder,
    );
  }
}

/// 边的标签：关系名（+ AI 来源）；建议态再带「确认」/「不相关」两键。
class _EdgeLabel extends StatelessWidget {
  const _EdgeLabel({
    required this.edge,
    required this.rows,
    required this.onConfirm,
    required this.onReject,
  });

  final WorkNetworkEdgeSpec edge;
  final List<MediaLinkRow> rows;
  final Future<void> Function() onConfirm;
  final Future<void> Function() onReject;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final Color color = workNetworkRelationColor(scheme, edge.relation);
    final bool ai = rows.any(mediaLinkIsAiEffective);
    final String label = <String>[
      workNetworkEdgeLabel(edge.relation, rows),
      if (ai) t.media_link_ai_linked,
    ].join(' · ');
    final Widget text = Text(
      label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurface),
    );
    final Widget chip = DecoratedBox(
      decoration: BoxDecoration(
        color: FushiDesignTokens.of(context).surfaces.search,
        borderRadius: FushiBorderRadius.card,
        border: Border.all(color: color, width: edge.suggested ? 1 : 1.5),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          children: <Widget>[
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 6),
            Expanded(child: text),
            if (edge.suggested) ...<Widget>[
              FushiIconButtonControl(
                key: ValueKey<String>(
                  'work-network-confirm-${edge.from}-${edge.to}',
                ),
                tooltip: t.media_link_suggestion_confirm,
                icon: const FushiIcon(FushiIcons.check, size: 20),
                onPressed: () => unawaited(onConfirm()),
              ),
              FushiIconButtonControl(
                key: ValueKey<String>(
                  'work-network-reject-${edge.from}-${edge.to}',
                ),
                tooltip: t.media_link_suggestion_reject,
                icon: const FushiIcon(FushiIcons.close, size: 20),
                onPressed: () => unawaited(onReject()),
              ),
            ],
          ],
        ),
      ),
    );
    return Semantics(
      key: ValueKey<String>(
        'work-network-edge-${edge.from}-${edge.relation.dbValue}-${edge.to}',
      ),
      container: true,
      label: label,
      child: chip,
    );
  }
}

/// 建议态节点的虚线圆角边框。
class _DashedBorderPainter extends CustomPainter {
  _DashedBorderPainter({required this.color, required this.radius});

  final Color color;
  final BorderRadius radius;

  @override
  void paint(Canvas canvas, Size size) {
    final Path border = Path()
      ..addRRect(radius.toRRect(Offset.zero & size).deflate(0.75));
    canvas.drawPath(
      WorkNetworkEdgePainter._dashed(border),
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
  }

  @override
  bool shouldRepaint(_DashedBorderPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.radius != radius;
}
