import 'dart:io';

import 'package:flutter/material.dart';

import 'package:hibiki/src/focus/hibiki_focus_controller.dart';
import 'package:hibiki/src/focus/hibiki_focus_target.dart';
import 'package:hibiki/src/media/collections/collection_continue.dart';
import 'package:hibiki/src/media/video/cover_ui/portrait_cover_image.dart';
import 'package:hibiki/src/media/collections/collection_one_key_sort.dart'
    show CollectionSortMeta, compareCollectionMembers;
import 'package:hibiki/src/pages/implementations/collection_detail_shared.dart';
import 'package:hibiki/src/pages/implementations/jimaku_batch_dialog.dart';
import 'package:hibiki/src/utils/cover_image.dart';
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

  /// 单集封面缩略图（16:9 槽）：有封面文件则渲染，否则 letterbox 占位图标。
  /// 每集是独立视频行，[VideoBookRow.coverPath] 由导入 / 后台补齐（home_video_page
  /// `_maybeBackfillCovers`）逐集抽帧填充；刮削可把它覆盖成 2:3 竖版海报——
  /// BUG-1262：走 [PortraitCoverImage] 的横槽自适应（横版截帧铺满、竖版海报
  /// 模糊垫底 + contain），不再 `BoxFit.cover` 把海报裁成中间一条。
  Widget _episodeThumb(VideoBookRow ep, ColorScheme cs) {
    const double w = 96;
    const double h = 54;
    final String? cover = ep.coverPath;
    if (cover != null && cover.isNotEmpty && File(cover).existsSync()) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: SizedBox(
          width: w,
          height: h,
          child: PortraitCoverImage(
            image: resizedFileImage(File(cover)),
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
          borderRadius: BorderRadius.circular(4),
        ),
        child: Icon(Icons.movie_outlined, color: cs.onSurfaceVariant, size: 20),
      );

  /// [availableWidth] 是这条 AppBar 实际拿到的约束宽（由 [LayoutBuilder] 下发）。
  AppBar _buildAppBar(double availableWidth) => AppBar(
        title: Text(_name, maxLines: 1, overflow: TextOverflow.ellipsis),
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

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    return Scaffold(
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
      body: SafeArea(
        child: _loading
            ? Center(child: adaptiveIndicator(context: context))
            : _members.isEmpty
                ? HibikiPlaceholderMessage(
                    icon: Icons.collections_bookmark_outlined,
                    message: t.collection_empty,
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      buildDetailTagChips(),
                      Padding(
                        padding: EdgeInsets.all(tokens.spacing.rowVertical),
                        child: Align(
                          alignment: AlignmentDirectional.centerStart,
                          child: FilledButton.icon(
                            icon: const Icon(Icons.play_arrow),
                            label: Text(t.collection_play),
                            onPressed: () =>
                                widget.onOpenEpisode(_members[_continueIndex]),
                          ),
                        ),
                      ),
                      const Divider(height: 1),
                      Expanded(
                        // 排序交互重设计层次 B1：拖拽精修。BUG-778：SDK 的
                        // ReorderableListView 拖拽代理用「全局坐标−overlay 原点」
                        // 纯平移，不认祖先 Transform.scale（HibikiAppUiScale 的
                        // 浏览器式整体缩放）——界面大小≠100% 时拖动位置按
                        // (1−s)×距离 漂移。换自实现的 HibikiReorderableColumn
                        // （浮层渲染在列表自身 Stack、指针经 globalToLocal 消
                        // 祖先缩放，词典排序/媒体源排序同款）。整行拖拽：鼠标
                        // 按下即拖、触摸长按；行尾拖柄图标保留为视觉提示。
                        // onReorder 落盘 sortIndex 后库页行/播放器换集立即同序。
                        child: SingleChildScrollView(
                          child: HibikiReorderableColumn(
                            itemCount: _members.length,
                            keyForIndex: (int i) =>
                                ValueKey<String>(_members[i].bookUid),
                            onReorder: _onReorder,
                            itemBuilder: (BuildContext _, int i) {
                              final VideoBookRow ep = _members[i];
                              final bool completed = ep.completedAt != null;
                              final bool started = ep.lastPositionMs > 0;
                              final bool isContinue = i == _continueIndex;
                              // 用 InkWell+Row（非 ListTile）保持 MD3 设计系统一致；
                              // VideoBooks 不存总时长无法算集内百分比 → 只标「已看完 /
                              // 看过一半 / 未看」三态图标，不画误导性进度条。
                              final Widget row = Material(
                                color: isContinue
                                    ? cs.primaryContainer
                                        .withValues(alpha: 0.35)
                                    : Colors.transparent,
                                child: InkWell(
                                  canRequestFocus: false,
                                  onTap: () => widget.onOpenEpisode(ep),
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
                                            style: TextStyle(
                                                color: cs.onSurfaceVariant),
                                          ),
                                        ),
                                        SizedBox(
                                            width: tokens.spacing.rowVertical),
                                        // Jellyfin 式：每集独立视频各自的封面缩略图（16:9
                                        // 抽帧；无封面时占位）。
                                        _episodeThumb(ep, cs),
                                        SizedBox(
                                            width: tokens.spacing.rowVertical),
                                        Expanded(
                                          child: Text(
                                            ep.title,
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                        if (completed)
                                          Icon(Icons.check_circle,
                                              color: cs.primary, size: 20)
                                        else if (started)
                                          Icon(Icons.play_circle_outline,
                                              color: cs.onSurfaceVariant,
                                              size: 20),
                                        SizedBox(width: tokens.spacing.gap / 2),
                                        // 逐集移出（整理页删除后的唯一入口）。
                                        HibikiIconButton(
                                          tooltip: t.collection_remove_member,
                                          icon: Icons.remove_circle_outline,
                                          size: 18,
                                          onTap: () => _removeEpisode(ep),
                                        ),
                                        SizedBox(width: tokens.spacing.gap / 2),
                                        // 拖柄图标：纯视觉提示（整行可拖，见类注释）。
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
                              // 巡检 PR-3：剧集行接入手柄/键盘方向焦点（裸 InkWell
                              // 不进 Hibiki 焦点系统，手柄用户到不了任何一集）。
                              // Enter / 手柄 A 与鼠标点击同路径开该集。
                              if (HibikiFocusRoot.maybeControllerOf(context) ==
                                  null) {
                                return row;
                              }
                              return Actions(
                                actions: <Type, Action<Intent>>{
                                  ActivateIntent:
                                      CallbackAction<ActivateIntent>(
                                    onInvoke: (_) {
                                      widget.onOpenEpisode(ep);
                                      return null;
                                    },
                                  ),
                                },
                                child: HibikiFocusTarget(
                                  id: HibikiFocusId(
                                      'collection-episode-${ep.bookUid}'),
                                  child: row,
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                    ],
                  ),
      ),
    );
  }
}
