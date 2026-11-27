import 'dart:async';

import 'package:drift/drift.dart' show TableUpdate, TableUpdateQuery;

import 'package:fushi/src/shortcuts/context_menu_trigger.dart';
import 'package:fushi/src/media/links/adaptation_progress_section.dart';
import 'package:fushi/src/media/links/media_link_editor_dialog.dart';
import 'package:fushi/src/media/links/media_link_removal_notice.dart';
import 'package:fushi/src/media/links/media_link_entries.dart';
import 'package:fushi/src/media/links/work_graph_store.dart';
import 'package:fushi/src/media/links/work_plans.dart';
import 'package:fushi/src/media/media_cover_source.dart';
import 'package:fushi/src/media/video/cover_ui/portrait_cover_image.dart';
import 'package:fushi/src/pages/implementations/work_network_page.dart';
import 'package:fushi/src/sync/remote_cover_image.dart';
import 'package:fushi/src/sync/remote_video_client.dart';
import 'package:fushi/src/utils/cover_image.dart'
    show kLocalCoverDecodePixelWidth;
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/fushi_animated_size.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/components/shelf_cover_material.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_hover_lift.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart';
import 'package:fushi/src/utils/components/shelf_card_widgets.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';
import 'package:fushi/src/utils/misc/platform_utils.dart';
import 'package:fushi/src/utils/misc/show_app_dialog.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart'
    show RemoteVideoInfo;
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
  Future<List<RemoteVideoSource>> Function()? remoteVideoSources,
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
        remoteVideoSources: remoteVideoSources,
        onOpen: (MediaLinkEntry e) {
          // 从关系网页里打开时弹窗已不在栈顶：只移除弹窗这一条路由，不误关关系网页。
          final ModalRoute<Object?>? route = ModalRoute.of(dialogContext);
          final NavigatorState navigator = Navigator.of(dialogContext);
          if (route == null || route.isCurrent) {
            navigator.pop();
          } else if (route.isActive) {
            navigator.removeRoute(route);
          }
          onOpen(e);
        },
      ),
    ),
  ),
);

/// 详情页「同一作品」区块（spec `docs/specs/2026-10-24-cross-media-links.md` §1，
/// AI 库管家 spec `docs/specs/2026-11-18-ai-library-curator-design.md` §4.3）。
///
/// - 头部：标题 +「关系网」入口（作品成员 + 卫星 ≥ 2 个节点时）+「关联作品」入口
///   （手动连接对话框）+ 可选的「查找相关作品」（L1 推断，[onInfer] 为 null 时不显示）。
/// - 「同一作品」横滚行：列本条目所在的**整部作品**（作品图的连通分量，取自进程级
///   [WorkGraphStore]），按媒体种类分组；同一系列合集的各卷折成一张合集卡；本条目
///   自己与它所在的合集不重复列出；主题曲 / 原声 / 配音另起一组。卡片点了跳对应
///   模块条目（[onOpen]）；本机不存在的端点是「未入库」灰卡。与本条目**直接**相连
///   的卡长按 / 右键出菜单「移除关联」（写墓碑，推断不会再提议这一对）；AI 直接生效
///   的连接在卡上标「AI」并带一键移除。
/// - 「可能相关」行：本条目未确认的推断建议，带来源与理由，「确认」/「不相关」两键。
///
/// 直接连接随 `media_links` 表变更自动重取（`tableUpdates` 手动订阅，而不是 drift
/// `.watch()`：长驻页面订阅 watch 流在 dispose 时会留下 Timer，见 BUG-834 范式）；
/// 作品图由 [WorkGraphStore] 去抖重建后通知本区块。
class MediaLinksSection extends StatefulWidget {
  const MediaLinksSection({
    required this.database,
    required this.self,
    required this.onOpen,
    this.onInfer,
    this.searchActionFor,
    this.remoteVideoSources,
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

  /// 当前的远端视频来源（`resolveVisibleRemoteVideoSources`，按优先级排好、可多个
  /// 并存）。视频合集卡没有本地封面、成员又只在远端（[MediaLinkEntry.hasRemoteMembers]）
  /// 时，用它们按成员 id 问远端要剧海报，与视频库合集卡同一张图、同一份磁盘缓存。
  /// null = 不取远端海报（占位图）。每个区块实例至多调用一次；没有远端成员的卡不会
  /// 触发它。
  final Future<List<RemoteVideoSource>> Function()? remoteVideoSources;

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

/// 「未入库」灰卡的去饱和滤镜：RGB 按 Rec.709 亮度换成灰度，alpha 原样不动。
///
/// 不用 `ColorFilter.mode(Colors.grey, BlendMode.saturation)`：混合模式滤镜对完全
/// 透明的像素也生效（结果 = 滤镜色本身），封面材质烘焙纹理四周给投影留的透明外扩区
/// （`kShelfMaterialShadowExtent`）会被整块涂成灰板，压在组名与副行上（BUG-5457）。
/// 颜色矩阵的 alpha 行只取原 alpha、无平移项，透明像素仍是透明。
const ColorFilter mediaLinkMissingCoverFilter = ColorFilter.matrix(<double>[
  0.2126, 0.7152, 0.0722, 0, 0, //
  0.2126, 0.7152, 0.0722, 0, 0, //
  0.2126, 0.7152, 0.0722, 0, 0, //
  0, 0, 0, 1, 0, //
]);

/// 区块一次加载的结果。
class _SectionData {
  const _SectionData({
    required this.views,
    required this.plan,
    required this.entries,
  });

  static const _SectionData empty = _SectionData(
    views: <MediaLinkView>[],
    plan: null,
    entries: <String, MediaLinkEntry>{},
  );

  /// 本条目的全部直接连接（不含墓碑）。
  final List<MediaLinkView> views;
  final WorkSectionPlan? plan;

  /// 卡片键（[WorkCardSpec.key]）→ 解析好的展示信息。
  final Map<String, MediaLinkEntry> entries;
}

/// 横滚行里的一项：一张卡，带它所在分组（分组首卡上方画组名）。
typedef _RowItem = ({WorkCardSpec card, String? groupLabel});

class _MediaLinksSectionState extends State<MediaLinksSection> {
  static const double _cardWidth = 116;
  static const double _coverHeight = _cardWidth * 3 / 2;
  static const double _gap = 12;
  static const double _groupGap = 28;
  static const double _groupLabelHeight = 24;
  static const double _suggestionWidth = 300;
  static const double _suggestionHeight = 148;

  /// 持久化在 State 里（BUG-2010：build 里现取 = 每次重建都多查一次库）。
  late Future<_SectionData> _data;
  StreamSubscription<Set<TableUpdate>>? _tableSub;
  late WorkGraphStore _store;
  bool _inferring = false;

  /// 远端来源，首次需要远端海报时解析一次（[MediaLinksSection.remoteVideoSources]）。
  Future<List<RemoteVideoSource>>? _remoteSources;

  /// 合集卡的远端海报（只放查到了的）；区块重载（表变更 / 作品图重建）时沿用，
  /// 不重复问远端。
  final Map<MediaLinkEndpoint, ImageProvider> _remotePosters =
      <MediaLinkEndpoint, ImageProvider>{};

  /// 已发起过远端海报查询的卡（含没查到的），重载时不再查。
  final Set<MediaLinkEndpoint> _remotePosterRequested = <MediaLinkEndpoint>{};

  @override
  void initState() {
    super.initState();
    _store = WorkGraphStore.of(widget.database);
    _store.addListener(_reload);
    _data = _load();
    _subscribe();
  }

  void _subscribe() {
    _tableSub = widget.database
        .tableUpdates(TableUpdateQuery.onTable(widget.database.mediaLinks))
        .listen((_) => _reload());
  }

  void _reload() {
    if (!mounted) return;
    // 块体写法：箭头体会把赋值结果（Future）当返回值交给 setState，触发
    // 「setState() callback argument returned a Future」断言、整次重建作废。
    setState(() {
      _data = _load();
    });
  }

  @override
  void didUpdateWidget(covariant MediaLinksSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.database != widget.database) {
      _store.removeListener(_reload);
      _store = WorkGraphStore.of(widget.database);
      _store.addListener(_reload);
      unawaited(_tableSub?.cancel());
      _subscribe();
      _remoteSources = null;
      _remotePosters.clear();
      _remotePosterRequested.clear();
    }
    if (oldWidget.self != widget.self ||
        oldWidget.database != widget.database) {
      _data = _load();
    }
  }

  @override
  void dispose() {
    _store.removeListener(_reload);
    unawaited(_tableSub?.cancel());
    super.dispose();
  }

  Future<_SectionData> _load() async {
    final FushiDatabase db = widget.database;
    final List<MediaLinkView> views = await loadMediaLinkViews(db, widget.self);
    final WorkSectionPlan plan = planWorkSection(
      snapshot: _store.value,
      self: widget.self,
      confirmed: <MediaLinkView>[
        for (final MediaLinkView v in views)
          if (v.state == MediaLinkState.confirmed) v,
      ],
    );
    final Map<String, MediaLinkEntry> entries = <String, MediaLinkEntry>{};
    for (final WorkCardSpec card in <WorkCardSpec>[
      for (final ({WorkMediaGroup group, List<WorkCardSpec> cards}) g
          in plan.groups)
        ...g.cards,
      ...plan.satellites,
    ]) {
      entries[card.key] = await _resolveCard(db, card);
    }
    unawaited(
      _loadRemotePosters(<MediaLinkEntry>[
        ...entries.values,
        for (final MediaLinkView v in views) v.other,
      ]),
    );
    return _SectionData(views: views, plan: plan, entries: entries);
  }

  /// 没有本地封面、但有远端成员的视频合集卡：按成员 id 问远端要海报。
  ///
  /// 一次区块加载对每个来源只发一次查询（所有待查卡的成员 id 合进一发
  /// [RemoteVideoLookup.remoteVideosByIds]），来源整段生命周期只解析一次；没有
  /// 待查卡时既不解析来源也不发网络。取图选择与视频库合集卡一致：成员序里第一个
  /// 带剧海报的取剧海报（缓存键 = 不含令牌的 URL 路径，与库页共用磁盘缓存），都没有
  /// 才取第一个成员自己的封面（缓存键 = 视频 id，同库页单集卡）。来源不具备按 id
  /// 查询或取封面的能力（互联 / 云盘）、或查询失败时，卡片保持占位图。
  Future<void> _loadRemotePosters(List<MediaLinkEntry> entries) async {
    final Future<List<RemoteVideoSource>> Function()? loader =
        widget.remoteVideoSources;
    if (loader == null) return;
    final List<MediaLinkEntry> wanted = <MediaLinkEntry>[];
    for (final MediaLinkEntry e in entries) {
      if (!e.hasRemoteMembers || e.coverPath != null) continue;
      if (!_remotePosterRequested.add(e.endpoint)) continue;
      wanted.add(e);
    }
    if (wanted.isEmpty) return;
    final List<String> ids = <String>[
      for (final MediaLinkEntry e in wanted) ...e.remoteMemberKeys,
    ];
    // 多个来源并存（反馈 k5Ey2AglAf）：每个能按 id 查、能取封面的来源各问一次，
    // 同一 id 按来源优先级只认第一个查到的；每条成员配着查到它的那个来源的取图器。
    final Map<String, ({RemoteVideoInfo video, RemoteCoverFetcher fetcher})>
    byId = <String, ({RemoteVideoInfo video, RemoteCoverFetcher fetcher})>{};
    final List<RemoteVideoSource> sources;
    try {
      sources = await (_remoteSources ??= loader());
    } on Object catch (e) {
      debugPrint('[media_links] remote source resolve failed: $e');
      return;
    }
    for (final RemoteVideoSource source in sources) {
      if (source is! RemoteVideoLookup || source is! RemoteCoverFetcher) {
        continue;
      }
      final RemoteCoverFetcher fetcher = source as RemoteCoverFetcher;
      final List<RemoteVideoInfo> found;
      try {
        found = await (source as RemoteVideoLookup).remoteVideosByIds(ids);
      } on Object catch (e) {
        // 远端不可达 / 鉴权失效：海报只是装饰，卡片保持占位图，不打扰用户。
        debugPrint('[media_links] remote poster lookup failed: $e');
        continue;
      }
      for (final RemoteVideoInfo v in found) {
        byId.putIfAbsent(v.id, () => (video: v, fetcher: fetcher));
      }
    }
    bool changed = false;
    for (final MediaLinkEntry e in wanted) {
      final ImageProvider? poster = _remotePosterFor(
        <({RemoteVideoInfo video, RemoteCoverFetcher fetcher})>[
          for (final String key in e.remoteMemberKeys) ?byId[key],
        ],
      );
      if (poster == null) continue;
      _remotePosters[e.endpoint] = poster;
      changed = true;
    }
    if (changed && mounted) setState(() {});
  }

  /// 成员（按成员序）里第一个剧海报，没有则第一个成员封面；都没有返回 null。
  static ImageProvider? _remotePosterFor(
    List<({RemoteVideoInfo video, RemoteCoverFetcher fetcher})> members,
  ) {
    for (final (:RemoteVideoInfo video, :RemoteCoverFetcher fetcher)
        in members) {
      final String? url = video.seriesCoverUrl;
      if (url == null || url.isEmpty) continue;
      return _resizedRemoteCover(
        RemoteCoverImage(url, fetcher, cacheKey: Uri.parse(url).path),
      );
    }
    for (final (:RemoteVideoInfo video, :RemoteCoverFetcher fetcher)
        in members) {
      final String? url = video.coverUrl;
      if (url == null || url.isEmpty) continue;
      return _resizedRemoteCover(
        RemoteCoverImage(url, fetcher, cacheKey: video.id),
      );
    }
    return null;
  }

  /// 与视频库远端封面同一解码上限（BUG-959 口径：服务器原尺寸海报不整帧解码）。
  static ImageProvider _resizedRemoteCover(RemoteCoverImage image) =>
      ResizeImage(
        image,
        width: kLocalCoverDecodePixelWidth,
        allowUpscaling: false,
      );

  /// 卡片展示信息：直接相连的端点复用已解析的对端；折叠合集取合集名。
  Future<MediaLinkEntry> _resolveCard(
    FushiDatabase db,
    WorkCardSpec card,
  ) async {
    final WorkSeriesInfo? series = card.series;
    if (series == null) {
      for (final MediaLinkView v in card.direct) {
        if (v.other.endpoint == card.target) return v.other;
      }
    }
    final MediaLinkEntry entry = await resolveMediaLinkEntry(db, card.target);
    if (series == null || series.name.isEmpty) return entry;
    return MediaLinkEntry(
      endpoint: entry.endpoint,
      title: series.name,
      inLibrary: entry.inLibrary,
      coverPath: entry.coverPath,
      remoteMemberKeys: entry.remoteMemberKeys,
    );
  }

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

  void _openNetwork(MediaLinkEndpoint endpoint) {
    unawaited(
      Navigator.of(context).push<void>(
        adaptivePageRoute<void>(
          context: context,
          builder: (_) => WorkNetworkPage(
            database: widget.database,
            endpoint: endpoint,
            onOpen: widget.onOpen,
            onInfer: widget.onInfer,
          ),
        ),
      ),
    );
  }

  Future<void> _showCardMenu(
    List<MediaLinkView> direct,
    Offset globalPosition,
  ) async {
    if (direct.isEmpty) return;
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
    await removeMediaLinksWithUndo(context, widget.database, <MediaLinkId>[
      for (final MediaLinkView v in direct) v.id,
    ]);
  }

  /// 卡片角上的一键「移除 AI 关联」：一点就把这张卡上的 AI 连接全写成否决墓碑，
  /// 所以提示条必须带撤销（反馈 bkrkQrYhnX，[removeMediaLinksWithUndo]）。
  Future<void> _removeAiLinks(List<MediaLinkView> ai) =>
      removeMediaLinksWithUndo(context, widget.database, <MediaLinkId>[
        for (final MediaLinkView v in ai) v.id,
      ]);

  Widget _cover(BuildContext context, MediaLinkEntry entry, double width) {
    final MediaKind? kind = mediaKindOfLinkKind(entry.endpoint.kind);
    final ImageProvider? local = kind == null
        ? null
        : resolveMediaCoverImage(kind: kind, localPath: entry.coverPath);
    // 没有本地封面的远端合集：取 [_loadRemotePosters] 查到的服务器海报。
    final ImageProvider? image = local ?? _remotePosters[entry.endpoint];
    final Widget placeholder = ShelfCoverPlaceholder(
      icon: mediaLinkKindIcon(entry.endpoint.kind),
      iconSize: width / 4,
      backgroundColor: FushiDesignTokens.of(context).surfaces.overlay,
    );
    if (image == null) return placeholder;
    return PortraitCoverImage(
      image: image,
      errorBuilder: (BuildContext _) => placeholder,
    );
  }

  /// 卡片副行的关系 / 身份：直接相连的取关系名（「原作」「改编作」「主题曲」…），
  /// 折叠合集取卷数，作品原作标「原作」，其余取种类名。
  String _cardRelationLabel(WorkCardSpec card) {
    if (card.direct.isNotEmpty) return mediaLinkBadgeLabel(card.direct.first);
    final WorkSeriesInfo? series = card.series;
    if (series != null && series.endpoint == null) {
      return t.media_link_series_volumes(count: series.volumeCount);
    }
    if (card.original) return t.media_link_role_original;
    return mediaLinkKindLabel(card.target.kind);
  }

  /// AI 来源标识 + 一键移除（压在封面角上；只出现在 AI 直接生效的直接连接上）。
  Widget _aiOverlay(BuildContext context, List<MediaLinkView> ai) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Stack(
      children: <Widget>[
        Positioned(
          left: 6,
          top: 6,
          child: FushiTooltip(
            message: t.media_link_ai_linked,
            child: Semantics(
              label: t.media_link_ai_linked,
              child: DecoratedBox(
                key: const ValueKey<String>('media-link-ai-badge'),
                decoration: BoxDecoration(
                  color: scheme.tertiaryContainer,
                  borderRadius: FushiBorderRadius.card,
                ),
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: FushiIcon(
                    FushiIcons.ai,
                    size: 16,
                    color: scheme.onTertiaryContainer,
                  ),
                ),
              ),
            ),
          ),
        ),
        Positioned(
          right: 0,
          top: 0,
          child: FushiIconButtonControl.filledTonal(
            key: const ValueKey<String>('media-link-ai-remove'),
            tooltip: t.media_link_ai_remove,
            icon: const FushiIcon(FushiIcons.linkOff, size: 18),
            onPressed: () => unawaited(_removeAiLinks(ai)),
          ),
        ),
      ],
    );
  }

  Widget _buildCard(
    BuildContext context,
    WorkCardSpec spec,
    MediaLinkEntry other,
  ) {
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
    final List<MediaLinkView> ai = <MediaLinkView>[
      for (final MediaLinkView v in spec.direct)
        if (mediaLinkIsAiEffective(v.row)) v,
    ];
    final Widget cover = ShelfCoverMaterialScope(
      material: mediaLinkCoverMaterial(other.endpoint.kind),
      child: ShelfCoverFrame(child: _cover(context, other, _cardWidth)),
    );
    // 封面即卡片（与库页同一套材质，按对端种类逐卡选）；关系 / 未入库不再压在
    // 封面上，进封面下的副行。
    final Widget card = SizedBox(
      key: ValueKey<String>('media-link-card-${spec.key}'),
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
                      colorFilter: mediaLinkMissingCoverFilter,
                      child: cover,
                    ),
                  )
                : cover,
          ),
          Opacity(
            opacity: missing ? 0.6 : 1,
            child: ShelfCardMeta(
              title: other.title,
              subtitle: <String>[_cardRelationLabel(spec), ?status].join(' · '),
              // 与视频库合集卡同一提示：有只在 Jellyfin / 互联上的集。
              leadingIcon: other.hasRemoteMembers ? FushiIcons.cloud : null,
            ),
          ),
        ],
      ),
    );
    final Widget interactive = FushiHoverLift(
      enabled: !missing || search != null,
      builder: (BuildContext context, bool _) => Semantics(
        button: !missing || search != null,
        label: other.title,
        // 右键菜单由绑定表决定唤出键（默认右键），右键被别的动作占用时自动让位。
        child: ContextMenuTrigger(
          onInvoke: (Offset position) => _showCardMenu(spec.direct, position),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: missing
                ? (search == null ? null : () => search(other.title))
                : () => widget.onOpen(other),
            onLongPressStart: (LongPressStartDetails d) =>
                _showCardMenu(spec.direct, d.globalPosition),
            child: card,
          ),
        ),
      ),
    );
    if (ai.isEmpty) return interactive;
    return SizedBox(
      width: _cardWidth,
      child: Stack(
        children: <Widget>[
          interactive,
          Positioned(
            left: 0,
            top: 0,
            width: _cardWidth,
            height: _coverHeight,
            child: _aiOverlay(context, ai),
          ),
        ],
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
                          onPressed: () => removeMediaLinksWithUndo(
                            context,
                            widget.database,
                            <MediaLinkId>[view.id],
                          ),
                          child: Text(t.media_link_suggestion_reject),
                        ),
                        FushiTextButton(
                          key: const ValueKey<String>(
                            'media-link-suggestion-confirm',
                          ),
                          onPressed: () => confirmMediaLinks(
                            widget.database,
                            <MediaLinkId>[view.id],
                          ),
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
  Widget _row<T>({
    required double height,
    required List<T> items,
    required Widget Function(BuildContext, T) builder,
    required double Function(int index) gapBefore,
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
            separatorBuilder: (_, int index) =>
                SizedBox(width: gapBefore(index + 1)),
            itemBuilder: fushiStaggeredItemBuilder(
              (BuildContext context, int index) =>
                  builder(context, items[index]),
            ),
          ),
        ),
      ),
    );
  }

  /// 作品行的一项：分组首卡上方是组名，其余卡上方留同高空白（卡片顶端对齐）。
  Widget _buildRowItem(
    BuildContext context,
    _RowItem item,
    Map<String, MediaLinkEntry> entries,
  ) {
    final MediaLinkEntry? entry = entries[item.card.key];
    final String? label = item.groupLabel;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SizedBox(
          width: _cardWidth,
          height: _groupLabelHeight,
          child: label == null
              ? null
              : Text(
                  label,
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.visible,
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
        ),
        if (entry != null)
          _buildCard(context, item.card, entry)
        else
          const SizedBox(width: _cardWidth),
      ],
    );
  }

  List<_RowItem> _rowItems(WorkSectionPlan plan) => <_RowItem>[
    for (final ({WorkMediaGroup group, List<WorkCardSpec> cards}) g
        in plan.groups)
      for (int i = 0; i < g.cards.length; i++)
        (
          card: g.cards[i],
          groupLabel: i == 0 ? workMediaGroupLabel(g.group) : null,
        ),
    for (int i = 0; i < plan.satellites.length; i++)
      (
        card: plan.satellites[i],
        groupLabel: i == 0 ? t.media_link_group_satellites : null,
      ),
  ];

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ThemeData theme = Theme.of(context);
    return FutureBuilder<_SectionData>(
      future: _data,
      builder: (BuildContext context, AsyncSnapshot<_SectionData> snap) {
        final _SectionData data = snap.data ?? _SectionData.empty;
        final List<MediaLinkView> confirmed = <MediaLinkView>[
          for (final MediaLinkView v in data.views)
            if (v.state == MediaLinkState.confirmed) v,
        ];
        final List<MediaLinkView> suggested = <MediaLinkView>[
          for (final MediaLinkView v in data.views)
            if (v.state == MediaLinkState.suggested) v,
        ];
        final WorkSectionPlan? plan = data.plan;
        final List<_RowItem> items = plan == null
            ? const <_RowItem>[]
            : _rowItems(plan);
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
                      if (plan != null && plan.networkNodeCount >= 2)
                        FushiIconButtonControl(
                          key: const ValueKey<String>('media-link-network'),
                          tooltip: t.media_link_network_title,
                          icon: const FushiIcon(FushiIcons.hub),
                          onPressed: () => _openNetwork(plan.networkEndpoint),
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
                if (items.isNotEmpty) ...<Widget>[
                  SizedBox(height: tokens.spacing.rowVertical),
                  _row<_RowItem>(
                    height:
                        _groupLabelHeight +
                        _coverHeight +
                        ShelfCardMeta.heightFor(context),
                    items: items,
                    builder: (BuildContext context, _RowItem item) =>
                        _buildRowItem(context, item, data.entries),
                    gapBefore: (int index) =>
                        index < items.length && items[index].groupLabel != null
                        ? _groupGap
                        : _gap,
                    replayKey: items.length,
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
                  _row<MediaLinkView>(
                    height: _suggestionHeight,
                    items: suggested,
                    builder: _buildSuggestion,
                    gapBefore: (int _) => _gap,
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
