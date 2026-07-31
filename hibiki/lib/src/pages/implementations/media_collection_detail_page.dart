import 'package:flutter/material.dart';

import 'package:hibiki/src/focus/hibiki_focus_controller.dart';
import 'package:hibiki/src/focus/hibiki_focus_target.dart';
import 'package:hibiki/src/media/collections/collection_continue.dart';
import 'package:hibiki/src/media/collections/collection_one_key_sort.dart'
    show CollectionSortMeta, compareCollectionMembers;
import 'package:hibiki/src/media/media_cover_source.dart';
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
    with CollectionDetailShared<MediaCollectionDetailPage> {
  late String _name;
  List<VideoBookRow> _members = const <VideoBookRow>[];
  bool _loading = true;
  bool _showAllEpisodes = false;

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

  Future<void> _reload() async {
    final List<VideoBookRow> members = await widget.loadMembers();
    if (!mounted) return;
    setState(() {
      _members = members;
      _loading = false;
    });
  }

  int get _continueIndex => continueMemberIndex(<CollectionMemberProgress>[
        for (final VideoBookRow r in _members)
          CollectionMemberProgress(
            positionMs: r.lastPositionMs,
            completed: r.completedAt != null,
          ),
      ]);

  int get _watchedCount =>
      _members.where((VideoBookRow row) => row.completedAt != null).length;

  List<VideoEpisodeEntry> get _episodeEntries => <VideoEpisodeEntry>[
        for (final VideoBookRow row in _members)
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

  ImageProvider? get _heroCover {
    final String? collectionCover = widget.collection.coverPath;
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
  Future<void> _onReorder(int oldIndex, int newIndex) async {
    if (oldIndex == newIndex) return;
    final List<VideoBookRow> next = List<VideoBookRow>.of(_members);
    final VideoBookRow moved = next.removeAt(oldIndex);
    next.insert(newIndex, moved);
    setState(() => _members = next);
    await _persistOrder();
  }

  /// 一键整理（覆盖 95% 场景）：按 [compare] 重排全表并落盘。乱序的手攒播放列表
  /// 一键回名称序 / 加入时序。
  Future<void> _applyOneKeySort(
    int Function(VideoBookRow a, VideoBookRow b) compare,
  ) async {
    final List<VideoBookRow> next = List<VideoBookRow>.of(_members)
      ..sort(compare);
    setState(() => _members = next);
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
    // 引用行并自删空合集，故随后的 deleteMediaCollection 多为幂等收尾（写合集级墓碑）。
    if (result.checked && widget.onDeleteMembersMedia != null) {
      await widget.onDeleteMembersMedia!(List<VideoBookRow>.of(_members));
    }
    await widget.database.deleteMediaCollection(widget.collection.id);
    if (!mounted) return;
    widget.onChanged();
    Navigator.of(context).maybePop();
  }

  /// 单集封面缩略图（16:9）：有封面文件则 [Image.file]，否则 letterbox 占位图标。
  /// 每集是独立视频行，[VideoBookRow.coverPath] 由导入 / 后台补齐（home_video_page
  /// `_maybeBackfillCovers`）逐集抽帧填充。
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
        child: Image(
          image: cover,
          width: w,
          height: h,
          fit: BoxFit.cover,
          // 抽帧文件损坏 / 读取失败时退回占位，绝不抛。
          errorBuilder: (BuildContext _, Object __, StackTrace? ___) =>
              _thumbPlaceholder(w, h, cs),
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
    return SizedBox(
      height: height,
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          ColoredBox(color: cs.surfaceContainerHighest),
          if (cover != null)
            Image(
              image: cover,
              fit: BoxFit.cover,
              alignment: Alignment.center,
              errorBuilder: (_, __, ___) =>
                  ColoredBox(color: cs.surfaceContainerHighest),
            ),
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
          SafeArea(
            bottom: false,
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                tokens.spacing.page,
                kToolbarHeight + tokens.spacing.gap,
                tokens.spacing.page,
                tokens.spacing.section,
              ),
              child: Align(
                alignment: AlignmentDirectional.bottomStart,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 680),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        _name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style:
                            Theme.of(context).textTheme.displaySmall?.copyWith(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w700,
                                  height: 1.08,
                                ),
                      ),
                      SizedBox(height: tokens.spacing.gap),
                      Text(
                        t.collection_watched_progress(
                          done: _watchedCount,
                          total: _members.length,
                        ),
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: Colors.white.withValues(alpha: 0.78),
                              fontWeight: FontWeight.w500,
                            ),
                      ),
                      SizedBox(height: tokens.spacing.card),
                      Text(
                        t.collection_continue_progress(n: _continueIndex + 1),
                        style: Theme.of(context).textTheme.labelLarge?.copyWith(
                              color: Colors.white.withValues(alpha: 0.82),
                              fontWeight: FontWeight.w700,
                            ),
                      ),
                      SizedBox(height: tokens.spacing.gap / 2),
                      Text(
                        episode.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                            ),
                      ),
                      SizedBox(height: tokens.spacing.card),
                      FilledButton.icon(
                        icon: const Icon(Icons.play_arrow_rounded),
                        label: Text(t.collection_play),
                        onPressed: () => widget.onOpenEpisode(episode),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
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
          SizedBox(height: tokens.spacing.rowVertical),
          VideoEpisodeRail(
            key: const ValueKey<String>('collection-episode-rail'),
            episodes: _episodeEntries,
            currentIndex: _continueIndex,
            onTapEpisode: (int index) => widget.onOpenEpisode(_members[index]),
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
                    key: const ValueKey<String>('episode-management-list'),
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

  Widget _buildEpisodeManagementList(
    ColorScheme cs,
    HibikiDesignTokens tokens,
  ) {
    return HibikiReorderableColumn(
      itemCount: _members.length,
      keyForIndex: (int i) => ValueKey<String>(_members[i].bookUid),
      onReorder: _onReorder,
      spacing: tokens.spacing.gap,
      itemBuilder: (BuildContext context, int i) {
        final VideoBookRow episode = _members[i];
        final bool completed = episode.completedAt != null;
        final bool started = episode.lastPositionMs > 0;
        final bool isContinue = i == _continueIndex;
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
