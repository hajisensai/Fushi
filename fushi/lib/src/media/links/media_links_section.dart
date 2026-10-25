import 'dart:async';

import 'package:drift/drift.dart' show TableUpdate, TableUpdateQuery;

import 'package:fushi/src/shortcuts/context_menu_trigger.dart';
import 'package:fushi/src/media/links/adaptation_progress_section.dart';
import 'package:fushi/src/media/links/media_link_editor_dialog.dart';
import 'package:fushi/src/media/links/media_link_entries.dart';
import 'package:fushi/src/media/media_cover_source.dart';
import 'package:fushi/src/media/video/cover_ui/portrait_cover_image.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/fushi_animated_size.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/components/shelf_cover_material.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:material_ui/material_ui.dart';

/// 打开作品图谱另一端在本机的条目（各详情页注入；导航上下文在调用方）。
typedef MediaLinkOpenCallback = void Function(MediaLinkEntry entry);

/// 没有详情页的条目（EPUB / PDF 书卡菜单）用的弹窗形态：同一个 [MediaLinksSection]
/// 装进对话框。点卡片先关弹窗再打开目标（目标页要压在库页上，不压在弹窗上）。
Future<void> showMediaLinksDialog({
  required BuildContext context,
  required FushiDatabase database,
  required MediaLinkEndpoint self,
  required MediaLinkOpenCallback onOpen,
  Future<int> Function()? onInfer,
  ValueChanged<String>? Function(MediaLinkKind kind)? searchActionFor,
}) => showAppDialog<void>(
  context: context,
  builder: (BuildContext dialogContext) => FushiDialogFrame(
    maxWidth: 640,
    maxHeightFactor: 0.82,
    child: Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: MediaLinksSection(
        database: database,
        self: self,
        onInfer: onInfer,
        searchActionFor: searchActionFor,
        onOpen: (MediaLinkEntry e) {
          Navigator.of(dialogContext).pop();
          onOpen(e);
        },
      ),
    ),
  ),
);

/// 详情页「同一作品」横向区块（spec `docs/specs/2026-10-24-cross-media-links.md` §1）。
///
/// - 头部：标题 +「关联作品」入口（手动连接对话框）+ 可选的「查找相关作品」（L1 推断，
///   [onInfer] 为 null 时不显示）。
/// - 「同一作品」横滚行：只显示**已确认**的连接（手动连接 / 用户确认过的推断）。卡片
///   点了跳对应模块条目（[onOpen]）；本机不存在的端点是「未入库」灰卡，不可点。长按
///   / 右键出菜单「移除关联」（写墓碑，推断不会再提议这一对）。
/// - 「可能相关」行：未确认的推断建议，带来源与理由，「确认」/「不相关」两键。
///
/// 数据随 `media_links` 表变更自动重取（`tableUpdates` 手动订阅，而不是 drift
/// `.watch()`：长驻页面订阅 watch 流在 dispose 时会留下 Timer，见 BUG-834 范式）。
class MediaLinksSection extends StatefulWidget {
  const MediaLinksSection({
    required this.database,
    required this.self,
    required this.onOpen,
    this.onInfer,
    this.searchActionFor,
    super.key,
  });

  final FushiDatabase database;

  /// 本详情页条目的端点（本地键）。
  final MediaLinkEndpoint self;

  final MediaLinkOpenCallback onOpen;

  /// 「查找相关作品」：跑一轮推断，返回新增建议数。null = 不显示入口。
  final Future<int> Function()? onInfer;

  /// 「未入库」灰卡的去搜入口（按端点种类给出；返回 null = 该种类没有入口）。
  final ValueChanged<String>? Function(MediaLinkKind kind)? searchActionFor;

  @override
  State<MediaLinksSection> createState() => _MediaLinksSectionState();
}

/// 关联 / 跨媒体卡的条目材质：与对端在各自库页上的样子一致——视频 = 光面海报、
/// 书 / 有声书 = 光面书皮、游戏 = 透明卡盒、音乐 = 方形唱片。关联区与人物详情页
/// 的作品卡共用。
ShelfCoverMaterial mediaLinkCoverMaterial(MediaLinkKind kind) => switch (kind) {
  MediaLinkKind.videoCollection ||
  MediaLinkKind.videoEpisode => ShelfCoverMaterial.glossyPoster,
  MediaLinkKind.book ||
  MediaLinkKind.audiobook => ShelfCoverMaterial.glossyBook,
  MediaLinkKind.game => ShelfCoverMaterial.gameCase,
  MediaLinkKind.musicAlbum ||
  MediaLinkKind.musicTrack => ShelfCoverMaterial.glossyAlbum,
};

class _MediaLinksSectionState extends State<MediaLinksSection> {
  static const double _cardWidth = 116;
  static const double _coverHeight = _cardWidth * 3 / 2;
  static const double _gap = 12;
  static const double _suggestionWidth = 300;
  static const double _suggestionHeight = 148;

  /// 持久化在 State 里（BUG-2010：build 里现取 = 每次重建都多查一次库）。
  late Future<List<MediaLinkView>> _views;
  StreamSubscription<Set<TableUpdate>>? _tableSub;
  bool _inferring = false;

  @override
  void initState() {
    super.initState();
    _views = _load();
    _tableSub = widget.database
        .tableUpdates(TableUpdateQuery.onTable(widget.database.mediaLinks))
        .listen((_) {
          if (!mounted) return;
          // 块体写法：箭头体会把赋值结果（Future）当返回值交给 setState，触发
          // 「setState() callback argument returned a Future」断言、整次重建作废。
          setState(() {
            _views = _load();
          });
        });
  }

  @override
  void didUpdateWidget(covariant MediaLinksSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.self != widget.self ||
        oldWidget.database != widget.database) {
      _views = _load();
    }
  }

  @override
  void dispose() {
    unawaited(_tableSub?.cancel());
    super.dispose();
  }

  Future<List<MediaLinkView>> _load() =>
      loadMediaLinkViews(widget.database, widget.self);

  Future<void> _openEditor() async {
    await showMediaLinkEditorDialog(
      context: context,
      database: widget.database,
      self: widget.self,
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

  Future<void> _showCardMenu(MediaLinkView view, Offset globalPosition) async {
    final RenderObject? overlay = Overlay.of(
      context,
    ).context.findRenderObject();
    if (overlay is! RenderBox) return;
    // 坐标经 Overlay globalToLocal 消掉 FushiAppUiScale 缩放（BUG-781 同族纪律）。
    final Offset anchor = overlay.globalToLocal(globalPosition);
    final bool? remove = await showFushiMenu<bool>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromPoints(anchor, anchor),
        Offset.zero & overlay.size,
      ),
      items: <PopupMenuEntry<bool>>[
        PopupMenuItem<bool>(
          value: true,
          child: Row(
            children: <Widget>[
              const FushiIcon(FushiIcons.linkOff, size: 20),
              const SizedBox(width: 12),
              Text(t.media_link_remove),
            ],
          ),
        ),
      ],
    );
    if (remove != true || !mounted) return;
    await widget.database.removeMediaLink(view.id);
    FushiToast.show(msg: t.media_link_removed, severity: ToastSeverity.info);
  }

  Widget _cover(BuildContext context, MediaLinkEntry entry, double width) {
    final MediaKind? kind = mediaKindOfLinkKind(entry.endpoint.kind);
    final ImageProvider? local = kind == null
        ? null
        : resolveMediaCoverImage(kind: kind, localPath: entry.coverPath);
    final Widget placeholder = ShelfCoverPlaceholder(
      icon: mediaLinkKindIcon(entry.endpoint.kind),
      iconSize: width / 4,
      backgroundColor: FushiDesignTokens.of(context).surfaces.overlay,
    );
    if (local == null) return placeholder;
    return PortraitCoverImage(
      image: local,
      errorBuilder: (BuildContext _) => placeholder,
    );
  }

  Widget _buildCard(BuildContext context, MediaLinkView view) {
    final MediaLinkEntry other = view.other;
    final bool missing = !other.inLibrary;
    // 合集端点的键是本机 id，丢了就没有可搜的标题。
    final ValueChanged<String>? search =
        missing && other.endpoint.kind != MediaLinkKind.videoCollection
        ? widget.searchActionFor?.call(other.endpoint.kind)
        : null;
    final String? status = missing
        ? (search == null
              ? t.media_link_not_in_library
              : t.media_link_search_missing)
        : null;
    final Widget cover = ShelfCoverMaterialScope(
      material: mediaLinkCoverMaterial(other.endpoint.kind),
      child: ShelfCoverFrame(child: _cover(context, other, _cardWidth)),
    );
    // 封面即卡片（与库页同一套材质，按对端种类逐卡选）；关系 / 未入库不再压在
    // 封面上，进封面下的副行。
    final Widget card = SizedBox(
      key: ValueKey<String>(
        'media-link-card-${other.endpoint.kind.dbValue}-${other.endpoint.key}',
      ),
      width: _cardWidth,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SizedBox(
            width: _cardWidth,
            height: _coverHeight,
            // 「未入库」灰卡：去饱和 + 半透明（材质一起变灰），与可点卡片一眼区分。
            child: missing
                ? Opacity(
                    opacity: 0.45,
                    child: ColorFiltered(
                      colorFilter: const ColorFilter.mode(
                        Colors.grey,
                        BlendMode.saturation,
                      ),
                      child: cover,
                    ),
                  )
                : cover,
          ),
          Opacity(
            opacity: missing ? 0.6 : 1,
            child: ShelfCardMeta(
              title: other.title,
              subtitle: <String>[
                mediaLinkBadgeLabel(view),
                ?status,
              ].join(' · '),
            ),
          ),
        ],
      ),
    );
    return FushiHoverLift(
      enabled: !missing || search != null,
      builder: (BuildContext context, bool _) => Semantics(
        button: !missing || search != null,
        label: other.title,
        // 右键菜单由绑定表决定唤出键（默认右键），右键被别的动作占用时自动让位。
        child: ContextMenuTrigger(
          onInvoke: (Offset position) => _showCardMenu(view, position),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: missing
                ? (search == null ? null : () => search(other.title))
                : () => widget.onOpen(other),
            onLongPressStart: (LongPressStartDetails d) =>
                _showCardMenu(view, d.globalPosition),
            child: card,
          ),
        ),
      ),
    );
  }

  Widget _buildSuggestion(BuildContext context, MediaLinkView view) {
    final ThemeData theme = Theme.of(context);
    final MediaLinkEntry other = view.other;
    final String? reason = view.row.reason;
    return SizedBox(
      key: ValueKey<String>(
        'media-link-suggestion-${other.endpoint.kind.dbValue}-'
        '${other.endpoint.key}',
      ),
      width: _suggestionWidth,
      child: FushiCard(
        // 卡片自带内边距会再吃掉一圈高度，这里由本卡自己给定一圈 10。
        padding: const EdgeInsets.all(10),
        child: SizedBox.expand(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              ClipRRect(
                borderRadius: FushiBorderRadius.card,
                child: SizedBox(
                  width: 64,
                  height: 96,
                  child: _cover(context, other, 64),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      other.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      '${mediaLinkBadgeLabel(view)} · '
                      '${t.media_link_suggestion_source(source: view.row.source)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall,
                    ),
                    if (reason != null)
                      Expanded(
                        child: Text(
                          reason,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall,
                        ),
                      )
                    else
                      const Spacer(),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: <Widget>[
                        FushiTextButton(
                          key: const ValueKey<String>(
                            'media-link-suggestion-reject',
                          ),
                          onPressed: () =>
                              widget.database.removeMediaLink(view.id),
                          child: Text(t.media_link_suggestion_reject),
                        ),
                        FushiTextButton(
                          key: const ValueKey<String>(
                            'media-link-suggestion-confirm',
                          ),
                          onPressed: () =>
                              widget.database.confirmMediaLink(view.id),
                          child: Text(t.media_link_suggestion_confirm),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 横滚行：鼠标拖动横滚；裸滚轮刻意不横滚（嵌在详情页纵向滚动里，BUG-1536）。
  Widget _row({
    required double height,
    required List<MediaLinkView> items,
    required Widget Function(BuildContext, MediaLinkView) builder,
    required Object replayKey,
  }) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return SizedBox(
      height: height,
      child: FushiEntranceScope(
        replayKey: replayKey,
        child: HorizontalDragScrollable(
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            physics: desktopAwareScrollPhysics(),
            padding: EdgeInsets.symmetric(horizontal: tokens.spacing.page),
            itemCount: items.length,
            separatorBuilder: (_, __) => const SizedBox(width: _gap),
            itemBuilder: fushiStaggeredItemBuilder(
              (BuildContext context, int index) =>
                  builder(context, items[index]),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ThemeData theme = Theme.of(context);
    return FutureBuilder<List<MediaLinkView>>(
      future: _views,
      builder: (BuildContext context, AsyncSnapshot<List<MediaLinkView>> snap) {
        final List<MediaLinkView> views = snap.data ?? const <MediaLinkView>[];
        final List<MediaLinkView> confirmed = <MediaLinkView>[
          for (final MediaLinkView v in views)
            if (v.state == MediaLinkState.confirmed) v,
        ];
        final List<MediaLinkView> suggested = <MediaLinkView>[
          for (final MediaLinkView v in views)
            if (v.state == MediaLinkState.suggested) v,
        ];
        return Padding(
          key: const ValueKey<String>('media-links-section'),
          padding: EdgeInsets.only(top: tokens.spacing.section),
          child: FushiAnimatedSize(
            duration: fushiMotionDuration(context, FushiMotion.medium),
            curve: FushiMotion.standard,
            alignment: Alignment.topCenter,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: tokens.spacing.page,
                  ),
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          t.media_link_section_title,
                          style: theme.textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      if (widget.onInfer != null)
                        FushiTextButton(
                          key: const ValueKey<String>('media-link-infer'),
                          onPressed: _inferring ? null : _infer,
                          child: Text(t.media_link_infer_action),
                        ),
                      FushiTextButton(
                        key: const ValueKey<String>('media-link-add'),
                        onPressed: _openEditor,
                        child: Text(t.media_link_add),
                      ),
                    ],
                  ),
                ),
                if (confirmed.isNotEmpty) ...<Widget>[
                  SizedBox(height: tokens.spacing.rowVertical),
                  _row(
                    height: _coverHeight + ShelfCardMeta.heightFor(context),
                    items: confirmed,
                    builder: _buildCard,
                    replayKey: confirmed.length,
                  ),
                ],
                if (suggested.isNotEmpty) ...<Widget>[
                  Padding(
                    padding: EdgeInsets.fromLTRB(
                      tokens.spacing.page,
                      tokens.spacing.rowVertical,
                      tokens.spacing.page,
                      tokens.spacing.rowVertical,
                    ),
                    child: Text(
                      t.media_link_suggestions_title,
                      style: theme.textTheme.titleSmall,
                    ),
                  ),
                  _row(
                    height: _suggestionHeight,
                    items: suggested,
                    builder: _buildSuggestion,
                    replayKey: suggested.length,
                  ),
                ],
                // 作品图谱 L5：已确认的「原作（书）→ 改编（视频）」连接的进度对应。
                AdaptationProgressSection(
                  database: widget.database,
                  links: adaptationProgressLinksOf(confirmed),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
