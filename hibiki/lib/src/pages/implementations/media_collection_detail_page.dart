import 'dart:io';

import 'package:flutter/material.dart';

import 'package:hibiki/src/media/collections/collection_continue.dart';
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
                        child: ListView.builder(
                          itemCount: _members.length,
                          itemBuilder: (BuildContext _, int i) {
                            final VideoBookRow ep = _members[i];
                            final bool completed = ep.completedAt != null;
                            final bool started = ep.lastPositionMs > 0;
                            final bool isContinue = i == _continueIndex;
                            // 用 InkWell+Row（非 ListTile）保持 MD3 设计系统一致；
                            // VideoBooks 不存总时长无法算集内百分比 → 只标「已看完 / 看过
                            // 一半 / 未看」三态图标，不画误导性进度条。
                            return Material(
                              color: isContinue
                                  ? cs.primaryContainer.withValues(alpha: 0.35)
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
                                    ],
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
      ),
    );
  }
}
