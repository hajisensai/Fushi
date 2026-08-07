import 'package:flutter/material.dart';

import 'package:fushi/src/media/media_cover_source.dart';
import 'package:fushi/src/media/video/cover_ui/portrait_cover_image.dart';
import 'package:fushi/src/media/video/scraper/collection_relations_scrape.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';

/// 合集详情页「相关作品」横滚区（TODO-2484 UI）。
///
/// 数据来自 `collection_relations`（PR#663 数据层，刮削时顺带落库）；无任何关系
/// 边时整块不渲染（未刮削/无关联的合集与本功能引入前逐像素一致）。
///
/// 卡片 = 2:3 封面（coverPath 本地优先 → coverUrl 网络回落 → 占位图标）+
/// 关系类型徽标 + 两行标题。点击分两路：
/// - targetCollectionId 非空（已绑定本地合集）→ [onOpenCollection] 跳详情；
/// - 空（纯刮削边）→ 小菜单「去下载」（[onDownload]，预填标题开下载对话框）/
///   「绑定到已有合集」（列本地合集选择后写 bindCollectionRelationTarget）。
class CollectionRelationsSection extends StatefulWidget {
  const CollectionRelationsSection({
    required this.database,
    required this.collectionId,
    required this.onOpenCollection,
    required this.onDownload,
    super.key,
  });

  final FushiDatabase database;
  final int collectionId;

  /// 打开已绑定的本地合集详情（调用方持导航上下文）。
  final void Function(int targetCollectionId) onOpenCollection;

  /// 「去下载」：以关系边标题预填打开下载对话框。
  final void Function(CollectionRelationRow relation) onDownload;

  @override
  State<CollectionRelationsSection> createState() =>
      _CollectionRelationsSectionState();
}

class _CollectionRelationsSectionState
    extends State<CollectionRelationsSection> {
  static const double _cardWidth = 132;
  static const double _coverHeight = _cardWidth * 3 / 2;
  static const double _textHeight = 48;
  static const double _gap = 12;

  final ScrollController _controller = ScrollController();

  /// 绑定后自增，强制 FutureBuilder 重取（与 detailTagsRefresh 同范式）。
  int _refresh = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String _relationLabel(String wire) {
    switch (CollectionRelationType.fromWire(wire)) {
      case CollectionRelationType.prequel:
        return t.collection_relation_prequel;
      case CollectionRelationType.sequel:
        return t.collection_relation_sequel;
      case CollectionRelationType.sideStory:
        return t.collection_relation_side_story;
      case CollectionRelationType.movie:
        return t.collection_relation_movie;
      case CollectionRelationType.spinOff:
        return t.collection_relation_spin_off;
      case CollectionRelationType.other:
        return t.collection_relation_other;
    }
  }

  /// 未绑定边的点击菜单：去下载 / 绑定到已有合集。坐标经 Overlay
  /// globalToLocal 消掉 FushiAppUiScale 缩放（BUG-781 同族纪律）。
  Future<void> _showUnboundMenu(
    CollectionRelationRow relation,
    Offset globalPosition,
  ) async {
    final RenderObject? overlay =
        Overlay.of(context).context.findRenderObject();
    if (overlay is! RenderBox) return;
    final Offset anchor = overlay.globalToLocal(globalPosition);
    final _RelationMenuAction? action = await showMenu<_RelationMenuAction>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromPoints(anchor, anchor),
        Offset.zero & overlay.size,
      ),
      items: <PopupMenuEntry<_RelationMenuAction>>[
        PopupMenuItem<_RelationMenuAction>(
          value: _RelationMenuAction.download,
          child: Row(
            children: <Widget>[
              const Icon(Icons.download_outlined, size: 20),
              const SizedBox(width: 12),
              Text(t.collection_relation_download),
            ],
          ),
        ),
        PopupMenuItem<_RelationMenuAction>(
          value: _RelationMenuAction.bind,
          child: Row(
            children: <Widget>[
              const Icon(Icons.link, size: 20),
              const SizedBox(width: 12),
              Text(t.collection_relation_bind),
            ],
          ),
        ),
      ],
    );
    if (!mounted) return;
    switch (action) {
      case _RelationMenuAction.download:
        widget.onDownload(relation);
      case _RelationMenuAction.bind:
        await _bindToExisting(relation);
      case null:
        break;
    }
  }

  /// 「绑定到已有合集」：列全部本地合集（排除本合集自身）→ 选中即写
  /// bindCollectionRelationTarget 并刷新区块。
  Future<void> _bindToExisting(CollectionRelationRow relation) async {
    final List<MediaCollectionRow> all =
        await widget.database.getAllMediaCollections();
    final List<MediaCollectionRow> candidates = <MediaCollectionRow>[
      for (final MediaCollectionRow c in all)
        if (c.id != widget.collectionId) c,
    ];
    if (!mounted) return;
    final MediaCollectionRow? chosen = await showAppDialog<MediaCollectionRow>(
      context: context,
      builder: (BuildContext context) => SimpleDialog(
        title: Text(t.collection_relation_bind),
        children: <Widget>[
          for (final MediaCollectionRow c in candidates)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop(c),
              child: Text(c.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
        ],
      ),
    );
    if (chosen == null || !mounted) return;
    await widget.database.bindCollectionRelationTarget(relation.id, chosen.id);
    if (!mounted) return;
    FushiToast.show(
      msg: t.collection_relation_bound(name: chosen.name),
      severity: ToastSeverity.success,
    );
    setState(() => _refresh++);
  }

  Widget _buildCard(
    BuildContext context,
    CollectionRelationRow relation,
  ) {
    // 封面三级回落：coverPath 本地文件 → coverUrl 网络（Image.network 是刮削
    // 候选封面的既有口径，见 scrape_cover_preview.dart）→ 占位图标。
    final ImageProvider? localCover = resolveMediaCoverImage(
      kind: MediaKind.video,
      localPath: relation.coverPath,
    );
    final String? coverUrl = relation.coverUrl;
    final Widget coverWidget;
    if (localCover != null) {
      coverWidget = PortraitCoverImage(
        image: localCover,
        errorBuilder: (BuildContext _) => _coverPlaceholder(context),
      );
    } else if (coverUrl != null && coverUrl.isNotEmpty) {
      coverWidget = Image.network(
        coverUrl,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _coverPlaceholder(context),
      );
    } else {
      coverWidget = _coverPlaceholder(context);
    }
    final bool bound = relation.targetCollectionId != null;
    return SizedBox(
      width: _cardWidth,
      child: GestureDetector(
        // 未绑定边需要触发点坐标定位菜单，InkWell onTap 拿不到，统一走 onTapUp。
        onTapUp: (TapUpDetails details) {
          final int? target = relation.targetCollectionId;
          if (target != null) {
            widget.onOpenCollection(target);
            return;
          }
          _showUnboundMenu(relation, details.globalPosition);
        },
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            ClipRRect(
              borderRadius: FushiBorderRadius.card,
              child: SizedBox(
                width: _cardWidth,
                height: _coverHeight,
                child: Stack(
                  fit: StackFit.expand,
                  children: <Widget>[
                    coverWidget,
                    PositionedDirectional(
                      top: 6,
                      start: 6,
                      // 关系类型徽标压在封面图上，走共享封面角标胶囊
                      // （CoverBadge 的纯文字形态）——此前这里是第四份手抄的
                      // 「深色 scrim + 圆角胶囊 + 白色小字」，正是 CoverBadge
                      // 要收口的那一类。
                      child: CoverBadge(
                        label: _relationLabel(relation.relationType),
                      ),
                    ),
                    if (bound)
                      PositionedDirectional(
                        bottom: 6,
                        end: 6,
                        child: Icon(
                          Icons.link,
                          size: 16,
                          color: Colors.white.withValues(alpha: 0.9),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 6),
            SizedBox(
              height: _textHeight - 6,
              child: Text(
                relation.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 无封面占位走三库页共用的 [ShelfCoverPlaceholder]（底色/描边/图标色全部
  /// 取自设计令牌，`tokens.surfaces.overlay` 即原先直读的最高阶容器面色）。
  Widget _coverPlaceholder(BuildContext context) => ShelfCoverPlaceholder(
        icon: Icons.movie_outlined,
        iconSize: 28,
        backgroundColor: FushiDesignTokens.of(context).surfaces.overlay,
      );

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return FutureBuilder<List<CollectionRelationRow>>(
      key: ValueKey<int>(_refresh),
      future: widget.database.getCollectionRelations(widget.collectionId),
      builder: (
        BuildContext context,
        AsyncSnapshot<List<CollectionRelationRow>> snap,
      ) {
        final List<CollectionRelationRow> relations =
            snap.data ?? const <CollectionRelationRow>[];
        // 无关系边（未刮削/源无关联）整块不渲染，不占位。
        if (relations.isEmpty) return const SizedBox.shrink();
        return Padding(
          key: const ValueKey<String>('collection-relations-section'),
          padding: EdgeInsets.only(top: tokens.spacing.section),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Padding(
                padding: EdgeInsets.symmetric(horizontal: tokens.spacing.page),
                child: Text(
                  t.collection_related_title,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
              ),
              SizedBox(height: tokens.spacing.rowVertical),
              SizedBox(
                height: _coverHeight + _textHeight,
                // 滚轮桥 + 鼠标拖动横滚两件套（home_video 合集行同款，BUG-1214）。
                child: WheelToHorizontalScroll(
                  controller: _controller,
                  child: HorizontalDragScrollable(
                    child: ListView.separated(
                      controller: _controller,
                      scrollDirection: Axis.horizontal,
                      physics: desktopAwareScrollPhysics(),
                      padding: EdgeInsets.symmetric(
                        horizontal: tokens.spacing.page,
                      ),
                      itemCount: relations.length,
                      separatorBuilder: (_, __) => const SizedBox(width: _gap),
                      itemBuilder: (BuildContext context, int index) =>
                          _buildCard(context, relations[index]),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

enum _RelationMenuAction { download, bind }
