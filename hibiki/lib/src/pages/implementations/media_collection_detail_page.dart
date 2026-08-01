import 'package:flutter/material.dart';

import 'package:hibiki/src/focus/hibiki_focus_controller.dart';
import 'package:hibiki/src/focus/hibiki_focus_target.dart';
import 'package:hibiki/src/media/collections/collection_asset_reclaim.dart';
import 'package:hibiki/src/media/collections/collection_continue.dart';
import 'package:hibiki/src/media/collections/collection_one_key_sort.dart'
    show CollectionSortMeta, compareCollectionMembers;
import 'package:hibiki/src/media/collections/collection_season_groups.dart';
import 'package:hibiki/src/media/media_cover_source.dart';
import 'package:hibiki/src/media/video/cover_ui/landscape_cover_image.dart';
import 'package:hibiki/src/media/video/cover_ui/portrait_cover_image.dart';
import 'package:hibiki/src/media/video/scraper/collection_scrape_apply.dart';
import 'package:hibiki/src/media/video/scraper/scraper_types.dart';
import 'package:hibiki/src/media/video/video_episode_rail.dart';
import 'package:hibiki/src/pages/implementations/collection_detail_shared.dart';
import 'package:hibiki/src/pages/implementations/jimaku_batch_dialog.dart';
import 'package:hibiki/utils.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// 统一合集 Phase 4：合集详情页（Jellyfin 式）。playlist 合集 = 有序剧集列表：点某集从
/// 该集开始播放（带剧集面板 / 上下集 / 连播，调用方经 playlistCollectionId 打开播放器）；
/// 顶部「播放」按钮据各集进度推导「继续看」位置（[continueMemberIndex]）。可重命名 / 删除
/// 合集（删合集只解链、绝不删条目本身）。
class MediaCollectionDetailPage extends StatefulWidget {
  const MediaCollectionDetailPage({
    required this.database,
    required this.collection,
    required this.loadMembers,
    required this.onOpenEpisode,
    required this.onChanged,
    this.onDeleteMembersMedia,
    super.key,
  });

  final HibikiDatabase database;
  final MediaCollectionRow collection;

  /// 解析本合集**有序**成员的 VideoBooks 行（调用方持 repo + collectionId）。
  final Future<List<VideoBookRow>> Function() loadMembers;

  /// 打开某集（调用方用 playlistCollectionId 进播放器带面板）。
  final void Function(VideoBookRow episode) onOpenEpisode;

  /// 改名 / 删除后刷新库页。
  final VoidCallback onChanged;

  /// 「删除合集」时可选连同各集视频本体一起删（默认不删，保持只解链语义）。
  /// 调用方（持 [VideoBookRepository]）注入：按 [VideoBookRow] 删视频 DB 行 +
  /// app 拥有副本（封面/字幕），**保留用户原始视频文件**（导入时只存路径从不复制）。
  /// null = 详情页不提供该选项（确认框不显示复选框），退回纯解链删除。
  final Future<void> Function(List<VideoBookRow> members)? onDeleteMembersMedia;

  @override
  State<MediaCollectionDetailPage> createState() =>
      _MediaCollectionDetailPageState();
}

class _MediaCollectionDetailPageState extends State<MediaCollectionDetailPage>
    with
        CollectionDetailShared<MediaCollectionDetailPage>,
        TickerProviderStateMixin {
  late String _name;
  List<VideoBookRow> _members = const <VideoBookRow>[];
  bool _loading = true;
  bool _showAllEpisodes = false;

  /// 分季：video 成员 bookUid → 分组键，**由 videoPath 文件名现场派生**（不落库，
  /// 数据模型见 collection_season_groups.dart）。路径不随重排变化，故只在
  /// [_reload] 重算。
  Map<String, String> _groupKeyByUid = const <String, String>{};

  /// 由 [_members] + [_groupKeyByUid] 派生的分节（季号升序、PV/特典殿后）。
  /// ≥2 节 → 顶部出季 tab；否则整页与单季合集完全一致（不平白加一层 UI）。
  List<CollectionSeasonSection<VideoBookRow>> _sections =
      const <CollectionSeasonSection<VideoBookRow>>[];

  /// 季 tab 控制器：只在 ≥2 节时存在，节数变化（移出成员导致某季清空）时重建。
  TabController? _seasonTabs;
  int _selectedSeason = 0;

  /// 初始选季只做一次（落在续播那一季，见 [_rebuildSections]）。之后一律尊重
  /// 用户手选的 tab —— 重排 / 移出成员不得把他弹回别的季。
  bool _seasonSelectionInitialized = false;

  /// 合集行的**当前**快照（DB 才是真相源）。
  ///
  /// `widget.collection` 是进页那一刻的副本：刮削会改写它的 `name` 与 `coverPath`，
  /// 只认进页副本会让详情页停在旧文件夹名 + 旧封面。首帧为 null（还没读到），此时
  /// 回落 `widget.collection` —— 与本改动前逐帧相同。
  MediaCollectionRow? _collectionRow;

  /// 合集级刮削资料（简介/评分/放送/标签，schema v64）；未刮过为 null —— 此时 hero
  /// 回落到「只有标题 + 进度」的旧形态，与本功能引入前一致（BUG-1310）。
  ScrapeMetadata? _scrapeMeta;

  /// 横版背景本地路径；仅 TMDB 源有，Bangumi / 离线库恒为 null。
  String? _backdropPath;

  @override
  HibikiDatabase get detailDatabase => widget.database;
  @override
  MediaCollectionRow get detailCollection => widget.collection;
  @override
  String get detailName => _name;
  @override
  set detailName(String value) => _name = value;
  @override
  VoidCallback get detailOnChanged => widget.onChanged;

  @override
  void initState() {
    super.initState();
    _name = widget.collection.name;
    _reload();
  }

  @override
  void dispose() {
    _seasonTabs?.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final List<VideoBookRow> members = await widget.loadMembers();
    // 刮削资料与合集行一起重取：刮削**经用户确认后可能回写合集名**
    //（`applyCollectionScrape` 的 confirmedTitle），而 widget.collection 是进页时的
    // 快照，只认它会让详情页标题停在旧文件夹名。
    final CollectionScrapeMetaRow? metaRow =
        await widget.database.getCollectionScrapeMeta(widget.collection.id);
    final ({ScrapeMetadata metadata, String? backdropPath})? decoded =
        decodeCollectionScrapeMeta(metaRow);
    final MediaCollectionRow? fresh =
        await widget.database.getMediaCollectionById(widget.collection.id);
    if (!mounted) return;
    setState(() {
      _members = members;
      _groupKeyByUid = <String, String>{
        for (final VideoBookRow r in members)
          r.bookUid: collectionGroupKeyForFilename(r.videoPath),
      };
      _rebuildSections();
      _scrapeMeta = decoded?.metadata;
      _backdropPath = decoded?.backdropPath;
      if (fresh != null) {
        _collectionRow = fresh;
        _name = fresh.name;
      }
      _loading = false;
    });
  }

  /// 重建分节并让季 tab 控制器跟上节数。**必须在 setState 内调用**（会改
  /// [_sections] / [_seasonTabs] / [_selectedSeason]）。
  void _rebuildSections() {
    _sections = sortCollectionSeasonSections<VideoBookRow>(
      buildCollectionSeasonSections<VideoBookRow>(
        members: _members,
        keyOf: (VideoBookRow r) => _groupKeyByUid[r.bookUid],
      ),
    );
    final int count = _sections.length;
    // 单季（含纯电影 / 全 PV）退化：销毁控制器、不渲染 tab 条，整页回到原样。
    if (count < 2) {
      _seasonTabs?.removeListener(_onSeasonTabChanged);
      _seasonTabs?.dispose();
      _seasonTabs = null;
      _selectedSeason = 0;
      return;
    }
    // 首次进页面停在**续播那一季**：顶部大图讲的是全局续播集，tab 若固定停在第
    // 1 季，看第二季的用户一进来就是「大图第二季 / 列表第一季」两套内容。
    if (!_seasonSelectionInitialized) {
      _seasonSelectionInitialized = true;
      final String? uid = _continueUid;
      final int index = uid == null
          ? -1
          : _sections.indexWhere((CollectionSeasonSection<VideoBookRow> s) =>
              s.items.any((VideoBookRow r) => r.bookUid == uid));
      if (index >= 0) _selectedSeason = index;
    }
    _selectedSeason = _selectedSeason.clamp(0, count - 1);
    if (_seasonTabs?.length == count) {
      if (_seasonTabs!.index != _selectedSeason) {
        _seasonTabs!.index = _selectedSeason;
      }
      return;
    }
    _seasonTabs?.removeListener(_onSeasonTabChanged);
    _seasonTabs?.dispose();
    _seasonTabs = TabController(
      length: count,
      initialIndex: _selectedSeason,
      vsync: this,
    )..addListener(_onSeasonTabChanged);
  }

  void _onSeasonTabChanged() {
    final TabController? tabs = _seasonTabs;
    // indexIsChanging 期间是动画中间态；只认落定值，避免滑动过程中反复重建列表。
    if (tabs == null || tabs.indexIsChanging || tabs.index == _selectedSeason) {
      return;
    }
    setState(() => _selectedSeason = tabs.index);
  }

  bool get _hasSeasonTabs => _sections.length >= 2;

  /// 当前选中的季（无 tab 时为 null）。
  CollectionSeasonSection<VideoBookRow>? get _selectedSection => _hasSeasonTabs
      ? _sections[_selectedSeason.clamp(0, _sections.length - 1)]
      : null;

  /// 当前 tab 下应展示的剧集（无 tab 时就是全表）。
  List<VideoBookRow> get _visibleMembers => _selectedSection?.items ?? _members;

  /// 续播集在**当前可见列表**里的下标；不在本季则 -1（轨道不高亮也不自动滚）。
  int get _visibleContinueIndex {
    final String? uid = _continueUid;
    if (uid == null) return -1;
    return _visibleMembers.indexWhere((VideoBookRow r) => r.bookUid == uid);
  }

  int get _continueIndex => continueMemberIndex(<CollectionMemberProgress>[
        for (final VideoBookRow r in _members)
          CollectionMemberProgress(
            positionMs: r.lastPositionMs,
            completed: r.completedAt != null,
          ),
      ]);

  /// 续播成员的 uid：分季视图里行下标是**节内**下标，与全局 [_continueIndex]
  /// 对不上，高亮统一按 uid 判定（平铺视图两者等价）。
  String? get _continueUid =>
      _members.isEmpty ? null : _members[_continueIndex].bookUid;

  /// 分组键 → tab / 分节标题（`s<N>` → 「第 N 季」；其余 → PV·特典）。
  String _groupLabel(String groupKey) {
    final int? season = seasonNumberOfGroupKey(groupKey);
    return season == null
        ? t.collection_group_extras
        : t.collection_group_season(n: season);
  }

  int get _watchedCount =>
      _members.where((VideoBookRow row) => row.completedAt != null).length;

  List<VideoEpisodeEntry> get _episodeEntries => <VideoEpisodeEntry>[
        for (final VideoBookRow row in _visibleMembers)
          VideoEpisodeEntry(
            title: row.title,
            cover: resolveMediaCoverImage(
              kind: MediaKind.video,
              localPath: row.coverPath,
            ),
            completed: row.completedAt != null,
            started: row.lastPositionMs > 0 && row.completedAt == null,
          ),
      ];

  /// hero 背景的**横版**图源（BUG-1298 的数据层根治）。
  ///
  /// hero 是约 2.7:1 的宽幅槽，理应喂横图。刮削若拿到了 TMDB 的 `backdrop_path`
  /// 就落在这里，槽向天然吻合、直接 cover 铺满即可。
  ///
  /// 返回 null = 该源没有横版图（Bangumi / 离线库只有竖版海报，恒为 null），此时
  /// 背景回落到海报 + [LandscapeCoverImage] 的模糊垫底。那不是权宜之计，是这些源
  /// 的常态路径。
  ImageProvider? get _heroBackdrop {
    final String? path = _backdropPath;
    if (path == null || path.isEmpty) return null;
    return resolveMediaCoverImage(
      kind: MediaKind.video,
      localPath: path,
      // 背景横跨整屏，4K 桌面下物理宽可达 3840；比海报的 1600 给得更宽。
      decodeWidth: 2560,
    );
  }

  ImageProvider? get _heroCover {
    // 读 DB 快照而非进页副本：刮削刚写进去的新封面必须立刻生效（见 [_collectionRow]）。
    final String? collectionCover =
        (_collectionRow ?? widget.collection).coverPath;
    if (collectionCover != null && collectionCover.isNotEmpty) {
      return resolveMediaCoverImage(
        kind: MediaKind.video,
        localPath: collectionCover,
        decodeWidth: 1600,
      );
    }
    if (_members.isEmpty) return null;
    final String? continueCover = _members[_continueIndex].coverPath;
    String? fallbackCover =
        continueCover?.isNotEmpty == true ? continueCover : null;
    if (fallbackCover == null) {
      for (final VideoBookRow row in _members) {
        final String? candidate = row.coverPath;
        if (candidate != null && candidate.isNotEmpty) {
          fallbackCover = candidate;
          break;
        }
      }
    }
    return resolveMediaCoverImage(
      kind: MediaKind.video,
      localPath: fallbackCover,
      decodeWidth: 1600,
    );
  }

  /// 把当前 [_members] 顺序一次落盘（sortIndex 全表回写）。库页合集行与播放器
  /// 换集读同一 `getCollectionItems`，落盘即三处同序（层次 C 单一真相源）。
  ///
  /// 本页只渲染 video 成员（调用方 `loadMembers` 按 mediaType 过滤），而一个合集**可以**
  /// 同时含非 video 成员，所以这里传的是**子集**——这是 `reorderCollectionItems` 的合法
  /// 用法：不可见成员留在原槽位、全表写成致密序，由 DAO 保证（BUG-1194 的不变量归属在
  /// DAO，不是各调用方自觉；页面不再自己做保序合并）。
  Future<void> _persistOrder() async {
    await widget.database.reorderCollectionItems(
      widget.collection.id,
      <CollectionMemberKey>[
        for (final VideoBookRow r in _members)
          (mediaType: MediaKind.video.dbValue, entryKey: r.bookUid),
      ],
    );
    widget.onChanged();
  }

  /// 拖拽精修：HibikiReorderableColumn 语义（newIndex 即最终下标，无 SDK
  /// ReorderableListView 的「移除前下标」修正）→ 内存 move → 落盘。
  ///
  /// 分季 tab 下拖的是**本季**列表：下标是节内的，先在节内 move，再把各节按
  /// **落盘序**（[_members] 里各组首次出现的顺序，不是 tab 的展示序）拼回全序，
  /// 避免拖一集顺带把整表按 tab 序重写。
  Future<void> _onReorder(int oldIndex, int newIndex) async {
    if (oldIndex == newIndex) return;
    final List<VideoBookRow> section = List<VideoBookRow>.of(_visibleMembers);
    final VideoBookRow moved = section.removeAt(oldIndex);
    section.insert(newIndex, moved);
    if (!_hasSeasonTabs) {
      setState(() {
        _members = section;
        _rebuildSections();
      });
      await _persistOrder();
      return;
    }
    final String movedKey =
        _groupKeyByUid[moved.bookUid] ?? kCollectionExtrasGroupKey;
    final List<CollectionSeasonSection<VideoBookRow>> persisted =
        buildCollectionSeasonSections<VideoBookRow>(
      members: _members,
      keyOf: (VideoBookRow r) => _groupKeyByUid[r.bookUid],
    );
    setState(() {
      _members = <VideoBookRow>[
        for (final CollectionSeasonSection<VideoBookRow> s in persisted)
          ...(s.groupKey == movedKey ? section : s.items),
      ];
      _rebuildSections();
    });
    await _persistOrder();
  }

  /// 一键整理（覆盖 95% 场景）：按 [compare] 重排全表并落盘。乱序的手攒播放列表
  /// 一键回名称序 / 加入时序。
  Future<void> _applyOneKeySort(
    int Function(VideoBookRow a, VideoBookRow b) compare,
  ) async {
    final List<VideoBookRow> next = List<VideoBookRow>.of(_members)
      ..sort(compare);
    setState(() {
      _members = next;
      _rebuildSections();
    });
    await _persistOrder();
  }

  /// 「按季排序」：按文件名重排全表（季→集→标题，PV/特典殿后）并落盘。季 tab
  /// **展示**本身是派生的、进页面即生效，本动作只负责把落盘全序也整理成分季连续
  /// （单季合集执行后无可见变化，幂等）。
  Future<void> _sortBySeason() async {
    if (_members.isEmpty) return;
    final CollectionSeasonRegroup<VideoBookRow> regroup =
        regroupMembersBySeason<VideoBookRow>(
      members: _members,
      filenameOf: (VideoBookRow r) => r.videoPath,
      titleOf: (VideoBookRow r) => r.title,
    );
    setState(() {
      _members = regroup.ordered;
      _rebuildSections();
    });
    await _persistOrder();
  }

  /// AppBar「排序」菜单：按名称（natural，卷1<卷2<卷10）/ 按导入时间（旧→新 =
  /// 原始加入时序）一键重排。菜单外壳共享 [buildDetailSortMenu]。
  ///
  /// 比较规则走共享的 [compareCollectionMembers]（与库页合集右键菜单、书架网格
  /// 详情页同一份）。本页成员已是内存里的 [VideoBookRow]，标题 / 导入时刻直接取，
  /// 不必像另两处那样现查四表——收口的是**规则**，不是取数路径。
  ///
  /// 顺带修掉本页原先「按名称」缺平局兜底的问题：`List.sort` 不是稳定排序，同名
  /// 条目（同一集的两个来源 / 都还没刮到标题）此前每次整理都可能换个顺序，而顺序
  /// 是要落盘的，看起来就像列表自己在动。
  Widget _buildSortMenu() {
    CollectionSortMeta metaOf(VideoBookRow r) => (
          title: r.title,
          importedAt: r.importedAt ?? 0,
          key: r.bookUid,
        );
    return buildDetailSortMenu(
      onSortByTitle: () => _applyOneKeySort(
        (VideoBookRow a, VideoBookRow b) =>
            compareCollectionMembers(metaOf(a), metaOf(b), byTitle: true),
      ),
      onSortByImported: () => _applyOneKeySort(
        (VideoBookRow a, VideoBookRow b) =>
            compareCollectionMembers(metaOf(a), metaOf(b), byTitle: false),
      ),
    );
  }

  /// 「为整个合集获取字幕」：把合集绑定到 AniList 系列后逐集经 Jimaku 批量下载字幕并
  /// 持久化（本地集落 DB、远端集落 prefs，见 [JimakuBatchDialog]）。
  Future<void> _fetchCollectionSubtitles() async {
    if (_members.isEmpty) return;
    // 用当前 collection 行（可能已在别处更新 anilistId）作对话框初值。
    final MediaCollectionRow collection =
        await widget.database.getMediaCollectionById(widget.collection.id) ??
            widget.collection;
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (_) => JimakuBatchDialog(
        database: widget.database,
        collection: collection,
        members: _members,
      ),
    );
  }

  /// 逐集「移出合集」（整理排序页删除后本页是视频侧唯一移出入口）：确认 →
  /// [HibikiDatabase.removeFromCollection]（空合集自动删）→ 重载；合集被清空则
  /// 退回上层。条目本身绝不删除。
  Future<void> _removeEpisode(VideoBookRow ep) async {
    if (!await confirmDetailRemoveMember()) return;
    if (!mounted) return;
    await widget.database.removeFromCollection(
        widget.collection.id, MediaKind.video, ep.bookUid);
    if (!mounted) return;
    widget.onChanged();
    HibikiToast.show(msg: t.collection_member_removed);
    final bool emptied =
        await widget.database.getMediaCollectionById(widget.collection.id) ==
            null;
    if (!mounted) return;
    if (emptied) {
      Navigator.of(context).maybePop();
      return;
    }
    await _reload();
  }

  Future<void> _delete() async {
    // 仅当调用方注入了删本体回调、且合集当前有成员时，才给用户「连同视频一起删」
    // 勾选行；否则退回纯解链删除（老行为，零变化）。确认框统一走 PR-0 的
    // [HibikiDestructiveConfirmDialog]（经 [confirmDetailCollectionDelete]）。
    final bool canDeleteMembers =
        widget.onDeleteMembersMedia != null && _members.isNotEmpty;
    final HibikiDestructiveConfirmResult? result =
        await confirmDetailCollectionDelete(
      checkboxLabel: canDeleteMembers ? t.delete_collection_also_videos : null,
    );
    if (result == null || !mounted) return;
    // 先删各集视频本体（DB 行 + 封面/字幕副本），再解散容器。删视频会连带清各合集
    // 引用行并自删空合集，故随后的解散多为幂等收尾（写合集级墓碑）。解散必须走
    // [deleteMediaCollectionWithAssets]：裸 deleteMediaCollection 只删 DB 行，合集
    // 自有封面会永久留在磁盘上（BUG-1319）。
    if (result.checked && widget.onDeleteMembersMedia != null) {
      await widget.onDeleteMembersMedia!(List<VideoBookRow>.of(_members));
    }
    await deleteMediaCollectionWithAssets(
        widget.database, widget.collection.id);
    if (!mounted) return;
    widget.onChanged();
    Navigator.of(context).maybePop();
  }

  /// 单集封面缩略图（16:9 槽）：有封面文件则渲染，否则 letterbox 占位图标。
  /// 每集是独立视频行，[VideoBookRow.coverPath] 由导入 / 后台补齐（home_video_page
  /// `_maybeBackfillCovers`）逐集抽帧填充；刮削可把它覆盖成 2:3 竖版海报——
  /// BUG-1299：走 [PortraitCoverImage] 的横槽自适应（横版截帧铺满、竖版海报
  /// 模糊垫底 + contain），不再 `BoxFit.cover` 把海报裁成中间一条。
  Widget _episodeThumb(VideoBookRow ep, ColorScheme cs) {
    const double w = 96;
    const double h = 54;
    final ImageProvider? cover = resolveMediaCoverImage(
      kind: MediaKind.video,
      localPath: ep.coverPath,
    );
    if (cover != null) {
      return ClipRRect(
        borderRadius: HibikiBorderRadius.card,
        child: SizedBox(
          width: w,
          height: h,
          child: PortraitCoverImage(
            image: cover,
            landscapeSlot: true,
            // 抽帧文件损坏 / 读取失败时退回占位，绝不抛。
            errorBuilder: (BuildContext _) => _thumbPlaceholder(w, h, cs),
          ),
        ),
      );
    }
    return _thumbPlaceholder(w, h, cs);
  }

  Widget _thumbPlaceholder(double w, double h, ColorScheme cs) => Container(
        width: w,
        height: h,
        decoration: BoxDecoration(
          color: cs.surfaceContainerHighest,
          borderRadius: HibikiBorderRadius.card,
        ),
        child: Icon(Icons.movie_outlined, color: cs.onSurfaceVariant, size: 20),
      );

  Widget _buildHero(
    BuildContext context,
    ColorScheme cs,
    HibikiDesignTokens tokens,
  ) {
    final Size screen = MediaQuery.sizeOf(context);
    final double height = (screen.height * 0.62).clamp(400.0, 600.0);
    final ImageProvider? cover = _heroCover;
    final VideoBookRow episode = _members[_continueIndex];
    final bool rtl = Directionality.of(context) == TextDirection.rtl;
    // 可读性渐变：压在封面之上、竖版海报前景之下（层序由 [LandscapeCoverImage]
    // 保证，见该组件文档）。无封面时直接铺在底色上，与引入组件前一致。
    final List<Widget> overlays = <Widget>[
      const DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            stops: <double>[0, 0.48, 1],
            colors: <Color>[
              Color(0x52000000),
              Color(0x22000000),
              Color(0xE8000000),
            ],
          ),
        ),
      ),
      DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: rtl ? Alignment.centerRight : Alignment.centerLeft,
            end: rtl ? Alignment.centerLeft : Alignment.centerRight,
            stops: const <double>[0, 0.66, 1],
            colors: const <Color>[
              Color(0xC9000000),
              Color(0x26000000),
              Color(0x7A000000),
            ],
          ),
        ),
      ),
    ];
    final ImageProvider? backdrop = _heroBackdrop;
    return SizedBox(
      height: height,
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          ColoredBox(color: cs.surfaceContainerHighest),
          // 背景分两条路，取决于**这次刮削的源有没有横版图**：
          // ① 有 backdrop（TMDB）→ 槽向天然吻合，直接 cover 铺满，海报另以独立
          //    2:3 卡片出现在左侧（Jellyfin 式，各就各位）；
          // ② 无 backdrop（Bangumi / 离线库 / 未刮削）→ 只有 2:3 海报或 16:9 抽帧
          //    可用，朝向判定交给 [LandscapeCoverImage]：横图 cover 铺满，竖版海报
          //    模糊垫底 + 靠右完整显示（BUG-1298）。此时不再另放海报卡，否则同一张
          //    图在同一屏出现两次。
          if (backdrop != null) ...<Widget>[
            Image(
              key: const ValueKey<String>('collection-hero-backdrop'),
              image: backdrop,
              fit: BoxFit.cover,
              alignment: Alignment.center,
              errorBuilder: (_, __, ___) =>
                  ColoredBox(color: cs.surfaceContainerHighest),
            ),
            ...overlays,
          ] else if (cover != null)
            LandscapeCoverImage(
              key: const ValueKey<String>('collection-hero-cover'),
              image: cover,
              overlays: overlays,
              // 竖版海报避让顶部 AppBar 与底部内容区，靠右不压左下标题/播放按钮。
              foregroundPadding: EdgeInsetsDirectional.only(
                top: kToolbarHeight,
                bottom: tokens.spacing.section,
                end: tokens.spacing.page,
              ),
              errorBuilder: (BuildContext _) =>
                  ColoredBox(color: cs.surfaceContainerHighest),
            )
          else
            ...overlays,
          SafeArea(
            bottom: false,
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                tokens.spacing.page,
                kToolbarHeight + tokens.spacing.gap,
                tokens.spacing.page,
                tokens.spacing.section,
              ),
              child: LayoutBuilder(
                builder: (BuildContext context, BoxConstraints constraints) {
                  final Widget info = ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 680),
                    child: _buildHeroInfo(context, tokens, episode),
                  );
                  // 海报卡只在「有横版背景 + 宽度够」时出现：窄屏放不下 2:3 卡还要
                  // 留 680 给文字，挤压的结果是标题被压成一列竖排字。
                  final bool showPoster = backdrop != null &&
                      cover != null &&
                      constraints.maxWidth >= 720;
                  if (!showPoster) {
                    return Align(
                      alignment: AlignmentDirectional.bottomStart,
                      child: info,
                    );
                  }
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: <Widget>[
                      _buildHeroPosterCard(cover, height),
                      SizedBox(width: tokens.spacing.section),
                      Expanded(
                        child: Align(
                          alignment: AlignmentDirectional.bottomStart,
                          child: info,
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// hero 左侧的竖版海报卡（仅在有横版背景时出现，见 [_buildHero]）。
  ///
  /// 2:3 是海报的**正确槽向**——这才是 BUG-1298 的正解：不是把海报硬塞进宽幅槽再想
  /// 办法补救，而是让宽幅槽拿横图、让海报回到它自己的比例里。
  Widget _buildHeroPosterCard(ImageProvider cover, double heroHeight) {
    final double posterHeight = (heroHeight * 0.62).clamp(180.0, 340.0);
    return ClipRRect(
      borderRadius: HibikiBorderRadius.card,
      child: SizedBox(
        key: const ValueKey<String>('collection-hero-poster'),
        height: posterHeight,
        width: posterHeight * 2 / 3,
        child: PortraitCoverImage(image: cover),
      ),
    );
  }

  /// hero 文字区：标题 / 原名 / 元数据行 / 标签 / 简介 / 继续看 / 播放。
  ///
  /// 刮削资料缺失时逐项跳过（不占位、不显示「未知」）：未刮过的合集看到的就是引入
  /// 本功能前的老形态——标题 + 进度 + 播放，逐像素不变（Never break userspace）。
  Widget _buildHeroInfo(
    BuildContext context,
    HibikiDesignTokens tokens,
    VideoBookRow episode,
  ) {
    final TextTheme text = Theme.of(context).textTheme;
    final ScrapeMetadata? meta = _scrapeMeta;
    final String? originalTitle = meta?.originalTitle;
    final String? summary = meta?.summary?.trim();
    final String metaLine = _heroMetaLine(meta);
    final List<ScrapeTag> scrapeTags = _heroScrapeTags(meta);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          _name,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: text.displaySmall?.copyWith(
            color: Colors.white,
            fontWeight: FontWeight.w700,
            height: 1.08,
          ),
        ),
        // 原名与合集名相同就不重复占一行（刮削回写后二者常常一致）。
        if (originalTitle != null &&
            originalTitle.isNotEmpty &&
            originalTitle != _name) ...<Widget>[
          SizedBox(height: tokens.spacing.gap / 2),
          Text(
            originalTitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: text.bodyMedium?.copyWith(
              color: Colors.white.withValues(alpha: 0.72),
            ),
          ),
        ],
        SizedBox(height: tokens.spacing.gap),
        Text(
          metaLine,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: text.bodyMedium?.copyWith(
            color: Colors.white.withValues(alpha: 0.82),
            fontWeight: FontWeight.w500,
          ),
        ),
        if (scrapeTags.isNotEmpty) ...<Widget>[
          SizedBox(height: tokens.spacing.gap),
          _buildHeroTagChips(scrapeTags),
        ],
        if (summary != null && summary.isNotEmpty) ...<Widget>[
          SizedBox(height: tokens.spacing.card),
          // Flexible + ellipsis：简介长度不可控，hero 高度是钳死的，必须让它先收缩
          // 再截断，否则长简介直接把 Column 撑出 RenderFlex overflow。
          Flexible(
            child: Text(
              summary,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: text.bodyMedium?.copyWith(
                color: Colors.white.withValues(alpha: 0.78),
                height: 1.35,
              ),
            ),
          ),
        ],
        SizedBox(height: tokens.spacing.card),
        Text(
          '${t.collection_continue_progress(n: _continueIndex + 1)}  ·  '
          '${episode.title}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: text.labelLarge?.copyWith(
            color: Colors.white.withValues(alpha: 0.82),
            fontWeight: FontWeight.w700,
          ),
        ),
        SizedBox(height: tokens.spacing.card),
        FilledButton.icon(
          icon: const Icon(Icons.play_arrow_rounded),
          label: Text(t.collection_play),
          onPressed: () => widget.onOpenEpisode(episode),
        ),
      ],
    );
  }

  /// 元数据行：`2023 · 全 12 话 · ★ 8.1 · 1234 人评分 · 已看完 0/12`。
  ///
  /// 逐项存在才拼（缺的不留空档、不写「未知」）。观看进度恒在——它不依赖刮削，是
  /// 本页固有信息，未刮过的合集这一行就只剩它，与旧形态一致。
  String _heroMetaLine(ScrapeMetadata? meta) {
    final List<String> parts = <String>[];
    final String? year = _heroYear(meta?.airDate);
    if (year != null) parts.add(year);
    final int? episodeCount = meta?.episodeCount;
    if (episodeCount != null && episodeCount > 0) {
      parts.add(t.collection_hero_total_episodes(count: episodeCount));
    }
    final double? rating = meta?.rating;
    if (rating != null && rating > 0) {
      parts.add('★ ${rating.toStringAsFixed(1)}');
      final int? votes = meta?.ratingCount;
      if (votes != null && votes > 0) {
        parts.add(t.video_scrape_rating_votes(count: votes));
      }
    }
    parts.add(
      t.collection_watched_progress(
        done: _watchedCount,
        total: _members.length,
      ),
    );
    return parts.join('  ·  ');
  }

  /// hero 展示的**作品标签**（题材/类型，来自刮削源，按热度降序取前 6）。
  ///
  /// 与合集自己的**用户标签**（`buildDetailTagChips`，hero 下方那排）是两条正交轴：
  /// 这里是「这部作品是什么题材」（源给的，只读），那里是「我把它归到哪些自建分类」
  /// （用户建的，可增删）。两者都该有，不互相取代。
  List<ScrapeTag> _heroScrapeTags(ScrapeMetadata? meta) {
    final List<ScrapeTag> tags = meta?.tags ?? const <ScrapeTag>[];
    return tags.take(6).toList();
  }

  /// 作品标签 chips。
  ///
  /// 用 [Wrap] 而不是单行 Row：标签长短不一，钳成一行会让第二个起就被 ellipsis 吃掉。
  /// 取前 6 个已使最坏情况稳定在两行内，配合调用方的 [Flexible] 不会撑爆 hero。
  Widget _buildHeroTagChips(List<ScrapeTag> tags) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: <Widget>[
        for (final ScrapeTag tag in tags)
          DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: Colors.white.withValues(alpha: 0.22)),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
              child: Text(
                tag.name,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.2,
                  color: Colors.white.withValues(alpha: 0.88),
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ),
      ],
    );
  }

  /// 从 `YYYY-MM-DD` / `YYYY` 取年份；取不到返回 null（源常见残缺日期，不补造）。
  static String? _heroYear(String? airDate) {
    if (airDate == null || airDate.length < 4) return null;
    final String head = airDate.substring(0, 4);
    return int.tryParse(head) == null ? null : head;
  }

  Widget _buildEpisodeSection(
    BuildContext context,
    ColorScheme cs,
    HibikiDesignTokens tokens,
  ) {
    return Padding(
      padding: EdgeInsets.only(
        top: tokens.spacing.section,
        bottom: tokens.spacing.section,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: EdgeInsets.symmetric(horizontal: tokens.spacing.page),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    t.video_episode_list,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                ),
                TextButton.icon(
                  onPressed: () =>
                      setState(() => _showAllEpisodes = !_showAllEpisodes),
                  icon: Icon(
                    _showAllEpisodes
                        ? Icons.keyboard_arrow_up
                        : Icons.view_list_outlined,
                  ),
                  label: Text(
                    _showAllEpisodes
                        ? t.collection_collapse
                        : t.collection_view_all,
                  ),
                ),
              ],
            ),
          ),
          // 多季合集：季 tab 紧贴标题行、在**默认展开**的剧集轨之上——用户一进
          // 详情页就看得见分季，不需要先展开下面那条折叠的管理列表。
          if (_hasSeasonTabs) _buildSeasonTabs(context, cs, tokens),
          SizedBox(height: tokens.spacing.rowVertical),
          VideoEpisodeRail(
            // 换季时轨道要连滚动位置一起重来（沿用旧 State 会停在上一季的
            // 偏移上），故 key 带上当前季。
            key: ValueKey<String>(
              'collection-episode-rail'
              '${_selectedSection == null ? '' : '-${_selectedSection!.groupKey}'}',
            ),
            episodes: _episodeEntries,
            currentIndex: _visibleContinueIndex,
            onTapEpisode: (int index) =>
                widget.onOpenEpisode(_visibleMembers[index]),
            colorScheme: cs,
            fontSize: 14,
            cardWidth:
                (MediaQuery.sizeOf(context).width * 0.24).clamp(168.0, 232.0),
            padding: EdgeInsets.symmetric(horizontal: tokens.spacing.page),
          ),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeOut,
            child: _showAllEpisodes
                ? Padding(
                    // key 带当前季：换季时整段管理列表重建，不复用上一季的
                    // 拖拽 State。
                    key: ValueKey<String>(
                      'episode-management-list'
                      '${_selectedSection == null ? '' : '-${_selectedSection!.groupKey}'}',
                    ),
                    padding: EdgeInsets.fromLTRB(
                      tokens.spacing.page,
                      tokens.spacing.section,
                      tokens.spacing.page,
                      0,
                    ),
                    child: _buildEpisodeManagementList(cs, tokens),
                  )
                : const SizedBox.shrink(
                    key: ValueKey<String>('episode-management-collapsed'),
                  ),
          ),
        ],
      ),
    );
  }

  /// 季 tab 条（MD3 可滚动 [TabBar]）：多季合集**首屏**就能看见并切季，切换后
  /// 下面的剧集轨与管理列表一起换成该季（分季若只做在默认折叠的管理
  /// 列表里，用户进页面根本看不见）。单季合集不渲染本条（[_hasSeasonTabs] 门）。
  Widget _buildSeasonTabs(
    BuildContext context,
    ColorScheme cs,
    HibikiDesignTokens tokens,
  ) {
    return Padding(
      key: const ValueKey<String>('collection-season-tabs'),
      padding: EdgeInsets.only(top: tokens.spacing.gap),
      child: TabBar(
        controller: _seasonTabs,
        isScrollable: true,
        tabAlignment: TabAlignment.start,
        padding: EdgeInsets.symmetric(horizontal: tokens.spacing.page),
        labelColor: cs.primary,
        unselectedLabelColor: cs.onSurfaceVariant,
        indicatorColor: cs.primary,
        dividerColor: Colors.transparent,
        tabs: <Widget>[
          for (final CollectionSeasonSection<VideoBookRow> section in _sections)
            Tab(
              key:
                  ValueKey<String>('collection-season-tab-${section.groupKey}'),
              text: _groupLabel(section.groupKey),
            ),
        ],
      ),
    );
  }

  Widget _buildEpisodeManagementList(
    ColorScheme cs,
    HibikiDesignTokens tokens,
  ) {
    // 分季时管理列表也只列本季（与上方轨道同一份 [_visibleMembers]），拖拽是
    // 节内重排，由 [_onReorder] 拼回全序落盘。
    final List<VideoBookRow> visible = _visibleMembers;
    return HibikiReorderableColumn(
      itemCount: visible.length,
      keyForIndex: (int i) => ValueKey<String>(visible[i].bookUid),
      onReorder: _onReorder,
      spacing: tokens.spacing.gap,
      itemBuilder: (BuildContext context, int i) {
        final VideoBookRow episode = visible[i];
        final bool completed = episode.completedAt != null;
        final bool started = episode.lastPositionMs > 0;
        final bool isContinue = episode.bookUid == _continueUid;
        final Widget row = Material(
          key: ValueKey<String>('collection-episode-row-${episode.bookUid}'),
          color: isContinue
              ? cs.primaryContainer.withValues(alpha: 0.35)
              : cs.surfaceContainerLow,
          borderRadius: HibikiBorderRadius.card,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            canRequestFocus: false,
            onTap: () => widget.onOpenEpisode(episode),
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: tokens.spacing.rowHorizontal,
                vertical: tokens.spacing.rowVertical,
              ),
              child: Row(
                children: <Widget>[
                  SizedBox(
                    width: tokens.spacing.gap * 4,
                    child: Text(
                      '${i + 1}',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: cs.onSurfaceVariant),
                    ),
                  ),
                  SizedBox(width: tokens.spacing.rowVertical),
                  _episodeThumb(episode, cs),
                  SizedBox(width: tokens.spacing.rowVertical),
                  Expanded(
                    child: Text(
                      episode.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (completed)
                    Icon(Icons.check_circle, color: cs.primary, size: 20)
                  else if (started)
                    Icon(
                      Icons.play_circle_outline,
                      color: cs.onSurfaceVariant,
                      size: 20,
                    ),
                  SizedBox(width: tokens.spacing.gap / 2),
                  HibikiIconButton(
                    tooltip: t.collection_remove_member,
                    icon: Icons.remove_circle_outline,
                    size: 18,
                    onTap: () => _removeEpisode(episode),
                  ),
                  SizedBox(width: tokens.spacing.gap / 2),
                  Icon(
                    Icons.drag_handle,
                    color: cs.onSurfaceVariant,
                    size: 20,
                  ),
                ],
              ),
            ),
          ),
        );
        if (HibikiFocusRoot.maybeControllerOf(context) == null) return row;
        return Actions(
          actions: <Type, Action<Intent>>{
            ActivateIntent: CallbackAction<ActivateIntent>(
              onInvoke: (_) {
                widget.onOpenEpisode(episode);
                return null;
              },
            ),
          },
          child: HibikiFocusTarget(
            id: HibikiFocusId('collection-episode-${episode.bookUid}'),
            child: row,
          ),
        );
      },
    );
  }

  /// [availableWidth] 是这条 AppBar 实际拿到的约束宽（由 [LayoutBuilder] 下发）。
  AppBar _buildAppBar(double availableWidth) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool cinematic = !_loading && _members.isNotEmpty;
    return AppBar(
      title: cinematic
          ? null
          : Text(_name, maxLines: 1, overflow: TextOverflow.ellipsis),
      backgroundColor: cinematic ? const Color(0x42000000) : cs.surface,
      foregroundColor: cinematic ? Colors.white : cs.onSurface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      // BUG-1184：5 个动作 + 返回键在 320dp 上吃掉约 296px，合集名只剩二十几像素、
      // 等于完全看不见。窄屏把后 4 个收进溢出菜单，排序保持一眼可点。
      actions: narrowAwareAppBarActions(
        availableWidth: availableWidth,
        alwaysVisible: <Widget>[_buildSortMenu()],
        collapsible: <HibikiAppBarAction>[
          // 季 tab 的排序补充：tab 展示是派生的、进页面即生效，本动作只把
          // **落盘全序**整理成季→集连续（单季合集执行后无可见变化，幂等）。
          HibikiAppBarAction(
            icon: Icons.segment,
            label: t.collection_sort_by_season,
            onPressed: _members.isEmpty ? null : _sortBySeason,
          ),
          HibikiAppBarAction(
            icon: Icons.subtitles_outlined,
            label: t.video_jimaku_batch_title,
            onPressed: _members.isEmpty ? null : _fetchCollectionSubtitles,
          ),
          HibikiAppBarAction(
            icon: Icons.drive_file_rename_outline,
            label: t.rename_collection,
            onPressed: renameDetailCollection,
          ),
          HibikiAppBarAction(
            icon: Icons.sell_outlined,
            label: t.tag_label,
            onPressed: editDetailCollectionTags,
          ),
          HibikiAppBarAction(
            icon: Icons.delete_outline,
            label: t.delete_collection,
            onPressed: _delete,
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final bool cinematic = !_loading && _members.isNotEmpty;
    return Scaffold(
      extendBodyBehindAppBar: cinematic,
      // BUG-1186：动作要不要折叠，得看这条 AppBar 自己拿到多宽，而不是整窗多宽。
      // 包一层 [LayoutBuilder] 把局部约束喂给 [narrowAwareAppBarActions]；高度就是
      // [AppBar] 无 bottom 时的默认 preferredSize（kToolbarHeight），Scaffold 仍会
      // 自己叠上状态栏 padding，行为与直接挂 AppBar 完全一致。
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(kToolbarHeight),
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) =>
              _buildAppBar(constraints.maxWidth),
        ),
      ),
      body: _loading
          ? SafeArea(
              child: Center(child: adaptiveIndicator(context: context)),
            )
          : _members.isEmpty
              ? SafeArea(
                  child: HibikiPlaceholderMessage(
                    icon: Icons.collections_bookmark_outlined,
                    message: t.collection_empty,
                  ),
                )
              : CustomScrollView(
                  slivers: <Widget>[
                    SliverToBoxAdapter(
                      child: _buildHero(context, cs, tokens),
                    ),
                    SliverToBoxAdapter(child: buildDetailTagChips()),
                    SliverToBoxAdapter(
                      child: _buildEpisodeSection(context, cs, tokens),
                    ),
                    SliverSafeArea(
                      top: false,
                      sliver: SliverToBoxAdapter(
                        child: SizedBox(height: tokens.spacing.page),
                      ),
                    ),
                  ],
                ),
    );
  }
}
