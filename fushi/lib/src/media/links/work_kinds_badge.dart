import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/links/work_graph_store.dart';
import 'package:fushi/src/media/links/work_plans.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/components/shelf_card_widgets.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/links/work_graph_loader.dart'
    show videoCollectionEndpoint;
import 'package:material_ui/material_ui.dart';

/// 库页卡片角标「另有：漫画 · 动画」（AI 库管家 spec §4.3）：卡片所在作品里还有
/// **别的媒体种类**的成员时，在卡片右上角叠一枚小图标；文字只进 tooltip 与
/// Semantics。点了打开该条目的「同一作品」弹窗 / 区块（[onPressed]）。
///
/// 数据只从进程级 [WorkGraphStore] 的当前快照取（哈希查表 + 每部作品一次的分组
/// 缓存），不逐卡查库；没有别的种类、快照还没建好时什么都不画。
///
/// 角标**不进焦点遍历**：书架网格的方向键 / 手柄导航只停在卡上，不在每张卡上多一
/// 站；键盘 / 手柄用户经卡片菜单里的「关联作品」进同一个弹窗。
class WorkKindsBadgeOverlay extends StatefulWidget {
  /// 单个条目（书 / 视频 / 游戏）的卡。
  const WorkKindsBadgeOverlay.entry({
    required this.database,
    required MediaLinkEndpoint this.endpoint,
    required this.onPressed,
    required this.child,
    this.enabled = true,
    super.key,
  }) : collectionId = null;

  /// 合集卡（系列合集按合集成员之外的种类算「另有」）。
  const WorkKindsBadgeOverlay.collection({
    required this.database,
    required int this.collectionId,
    required this.onPressed,
    required this.child,
    this.enabled = true,
    super.key,
  }) : endpoint = null;

  final FushiDatabase database;
  final MediaLinkEndpoint? endpoint;
  final int? collectionId;

  /// 点角标：打开以该端点为本条目的「同一作品」（合集卡给合集的代表端点）。
  final ValueChanged<MediaLinkEndpoint> onPressed;

  /// 被叠角标的卡片。
  final Widget child;

  /// false（多选态、拖排中）时不画角标，卡片原样返回。
  final bool enabled;

  @override
  State<WorkKindsBadgeOverlay> createState() => _WorkKindsBadgeOverlayState();
}

class _WorkKindsBadgeOverlayState extends State<WorkKindsBadgeOverlay> {
  late WorkGraphStore _store;

  @override
  void initState() {
    super.initState();
    _store = WorkGraphStore.of(widget.database);
    _store.addListener(_onGraph);
  }

  @override
  void didUpdateWidget(covariant WorkKindsBadgeOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.database != widget.database) {
      _store.removeListener(_onGraph);
      _store = WorkGraphStore.of(widget.database);
      _store.addListener(_onGraph);
    }
  }

  @override
  void dispose() {
    _store.removeListener(_onGraph);
    super.dispose();
  }

  void _onGraph() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final WorkGraphSnapshot? snapshot = widget.enabled ? _store.value : null;
    if (snapshot == null) return widget.child;
    // 合集卡：系列合集按「合集成员之外的种类」算；不是系列合集的视频合集（用户
    // 随手建的、直接连在作品图谱上的）按合集端点本身算；书 / 游戏的非系列合集
    // 没有端点，不出角标。
    final MediaLinkEndpoint? endpoint = widget.endpoint;
    final WorkSeriesInfo? series = endpoint == null
        ? snapshot.seriesById(widget.collectionId!)
        : null;
    final MediaLinkEndpoint self =
        endpoint ??
        series?.openTarget ??
        videoCollectionEndpoint(widget.collectionId!);
    final List<WorkMediaGroup> groups = series != null
        ? snapshot.otherGroupsForCollection(series.id)
        : snapshot.otherGroupsFor(self);
    if (groups.isEmpty) return widget.child;
    // 角标落在封面右上角：书架网格格子有内边距，色块布局为 0。
    final double inset = ShelfGridCellInset.of(context, 0) + 6;
    return Stack(
      children: <Widget>[
        widget.child,
        Positioned(
          top: inset,
          right: inset,
          child: WorkKindsBadge(
            groups: groups,
            onPressed: () => widget.onPressed(self),
          ),
        ),
      ],
    );
  }
}

/// 角标本体：纯图标，「另有：…」只进 tooltip 与 Semantics。
class WorkKindsBadge extends StatelessWidget {
  const WorkKindsBadge({
    required this.groups,
    required this.onPressed,
    super.key,
  });

  final List<WorkMediaGroup> groups;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final String label = t.media_link_badge_also(
      kinds: groups.map(workMediaGroupLabel).join(' · '),
    );
    return FushiTooltip(
      message: label,
      child: Semantics(
        button: true,
        label: label,
        excludeSemantics: true,
        child: Material(
          key: const ValueKey<String>('work-kinds-badge'),
          color: scheme.secondaryContainer,
          shape: const CircleBorder(),
          elevation: 1,
          child: InkWell(
            customBorder: const CircleBorder(),
            canRequestFocus: false,
            onTap: onPressed,
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: FushiIcon(
                FushiIcons.hub,
                size: 16,
                color: scheme.onSecondaryContainer,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
