import 'dart:io';

import 'package:flutter/material.dart';

import 'package:hibiki/src/media/collections/collection_continue.dart';
import 'package:hibiki/src/media/collections/shelf_sort.dart'
    show naturalCompare;
import 'package:hibiki/src/pages/implementations/collection_name_dialog.dart'
    show showCollectionNameDialog;
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

  @override
  State<MediaCollectionDetailPage> createState() =>
      _MediaCollectionDetailPageState();
}

class _MediaCollectionDetailPageState extends State<MediaCollectionDetailPage> {
  late String _name;
  List<VideoBookRow> _members = const <VideoBookRow>[];
  bool _loading = true;

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
  Future<void> _persistOrder() async {
    await widget.database.reorderCollectionItems(
      widget.collection.id,
      <({String mediaType, String entryKey})>[
        for (final VideoBookRow r in _members)
          (mediaType: 'video', entryKey: r.bookUid),
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
  /// 原始加入时序）一键重排。
  Widget _buildSortMenu() {
    int importedMsOf(VideoBookRow r) =>
        r.importedAt?.millisecondsSinceEpoch ?? 0;
    return MenuAnchor(
      menuChildren: <Widget>[
        MenuItemButton(
          leadingIcon: const Icon(Icons.sort_by_alpha, size: 20),
          onPressed: () => _applyOneKeySort(
            (VideoBookRow a, VideoBookRow b) =>
                naturalCompare(a.title, b.title),
          ),
          child: Text(t.collection_sort_by_title),
        ),
        MenuItemButton(
          leadingIcon: const Icon(Icons.history, size: 20),
          onPressed: () => _applyOneKeySort(
            (VideoBookRow a, VideoBookRow b) {
              final int c = importedMsOf(a).compareTo(importedMsOf(b));
              return c != 0 ? c : naturalCompare(a.title, b.title);
            },
          ),
          child: Text(t.collection_sort_by_imported),
        ),
      ],
      builder: (BuildContext context, MenuController controller, Widget? _) =>
          IconButton(
        tooltip: t.sort_by,
        icon: const Icon(Icons.sort),
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
      ),
    );
  }

  Future<void> _rename() async {
    final String? newName = await showCollectionNameDialog(
      context: context,
      title: t.rename_collection,
      initialName: _name,
    );
    if (newName == null || newName == _name) return;
    await widget.database.renameMediaCollection(widget.collection.id, newName);
    if (!mounted) return;
    setState(() => _name = newName);
    widget.onChanged();
  }

  /// 逐集「移出合集」（整理排序页删除后本页是视频侧唯一移出入口）：确认 →
  /// [HibikiDatabase.removeFromCollection]（空合集自动删）→ 重载；合集被清空则
  /// 退回上层。条目本身绝不删除。
  Future<void> _removeEpisode(VideoBookRow ep) async {
    final bool? ok = await showAppDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(t.collection_remove_member),
        content: Text(t.collection_remove_member_confirm),
        actions: <Widget>[
          adaptiveDialogAction(
            context: ctx,
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(t.dialog_cancel),
          ),
          adaptiveDialogAction(
            context: ctx,
            isDestructiveAction: true,
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(t.collection_remove_member),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await widget.database
        .removeFromCollection(widget.collection.id, 'video', ep.bookUid);
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
    final bool? ok = await showAppDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(t.delete_collection),
        content: Text(t.delete_collection_confirm),
        actions: <Widget>[
          adaptiveDialogAction(
            context: ctx,
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(t.dialog_cancel),
          ),
          adaptiveDialogAction(
            context: ctx,
            isDestructiveAction: true,
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(t.delete_collection),
          ),
        ],
      ),
    );
    if (ok != true) return;
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
    final String? cover = ep.coverPath;
    if (cover != null && cover.isNotEmpty && File(cover).existsSync()) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: Image.file(
          File(cover),
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
          borderRadius: BorderRadius.circular(4),
        ),
        child: Icon(Icons.movie_outlined, color: cs.onSurfaceVariant, size: 20),
      );

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(_name),
        actions: <Widget>[
          _buildSortMenu(),
          IconButton(
            tooltip: t.rename_collection,
            icon: const Icon(Icons.drive_file_rename_outline),
            onPressed: _rename,
          ),
          IconButton(
            tooltip: t.delete_collection,
            icon: const Icon(Icons.delete_outline),
            onPressed: _delete,
          ),
        ],
      ),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _members.isEmpty
                ? Center(child: Text(t.collection_empty))
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      Padding(
                        padding: const EdgeInsets.all(12),
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
                        // 排序交互重设计层次 B1：拖拽精修。BUG-757：SDK 的
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
                              return Material(
                                color: isContinue
                                    ? cs.primaryContainer
                                        .withValues(alpha: 0.35)
                                    : Colors.transparent,
                                child: InkWell(
                                  onTap: () => widget.onOpenEpisode(ep),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 16, vertical: 12),
                                    child: Row(
                                      children: <Widget>[
                                        SizedBox(
                                          width: 32,
                                          child: Text(
                                            '${i + 1}',
                                            textAlign: TextAlign.center,
                                            style: TextStyle(
                                                color: cs.onSurfaceVariant),
                                          ),
                                        ),
                                        const SizedBox(width: 12),
                                        // Jellyfin 式：每集独立视频各自的封面缩略图（16:9
                                        // 抽帧；无封面时占位）。
                                        _episodeThumb(ep, cs),
                                        const SizedBox(width: 12),
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
                                        const SizedBox(width: 4),
                                        // 逐集移出（整理页删除后的唯一入口）。
                                        HibikiIconButton(
                                          tooltip: t.collection_remove_member,
                                          icon: Icons.remove_circle_outline,
                                          size: 18,
                                          onTap: () => _removeEpisode(ep),
                                        ),
                                        const SizedBox(width: 4),
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
