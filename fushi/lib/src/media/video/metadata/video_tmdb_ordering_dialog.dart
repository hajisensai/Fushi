/// 「TMDB 集编排」（备选排序）选择入口——Shoko `TMDB_AlternateOrdering` +
/// `PreferredAlternateOrderingID` 的用户面。
///
/// 挂在合集详情页的管理菜单上：列出这部剧在 TMDB 上的全部 episode groups，用户
/// 选一个（或选回默认排序）→ 写作品行 `episode_group_id` 并上 `episodeGroup`
/// 字段锁（[FushiDatabase.setVideoMetadataWorkEpisodeGroup]）→ 以作品既有身份
/// 重刮（[VideoSourceScrapeTaskController.rescrapeWorkWithLookup]），季集结构与
/// AniDB 集级链接随之按该排序重算。**不新开写库路径**：排序只是 lookup 上的一个
/// 字段，落库仍是那一条 `_store.apply`。
library;

import 'package:flutter/material.dart';
import 'package:fushi_engine/media/source_library/source_library_row.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_provider.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_work_loader.dart';
import 'package:fushi_engine/media/video/metadata/video_source_scrape_task.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';

/// 打开备选排序对话框并在用户确认后写库 + 重刮。返回是否真的改了排序。
///
/// [workId] 是合集的规范作品行；作品没有 TMDB 身份（纯 MAL / AniDB 资料、或还没
/// 刮过）时给提示、不弹框——备选排序是 TMDB 的概念。
Future<bool> chooseVideoTmdbOrdering({
  required BuildContext context,
  required FushiDatabase database,
  required VideoSourceScrapeTaskController controller,
  required SourceLibraryRow source,
  required String workTitle,
  required String workStableKey,
  required int workId,
}) async {
  final VideoMetadataWorkRow? row = await database.getVideoMetadataWorkById(
    workId,
  );
  if (row == null || !context.mounted) return false;
  final VideoMetadataProviderIdentityRow? tmdbIdentity =
      (await database.getVideoMetadataProviderIdentities(workId: workId))
          .where(
            (VideoMetadataProviderIdentityRow identity) =>
                identity.provider == VideoMetadataProviderKind.tmdb.name,
          )
          .firstOrNull;
  if (!context.mounted) return false;
  if (tmdbIdentity == null || row.mediaType != VideoMetadataMediaKind.tv.name) {
    FushiToast.show(
      msg: t.collection_tmdb_ordering_unavailable,
      severity: ToastSeverity.info,
    );
    return false;
  }
  final List<VideoMetadataEpisodeGroupSummary> groups = await controller
      .listEpisodeGroups(
        VideoMetadataLookup(
          provider: VideoMetadataProviderKind.tmdb,
          externalId: tmdbIdentity.externalId,
          mediaKind: VideoMetadataMediaKind.tv,
        ),
      );
  if (!context.mounted) return false;
  if (groups.isEmpty && row.episodeGroupId == null) {
    FushiToast.show(
      msg: t.collection_tmdb_ordering_none,
      severity: ToastSeverity.info,
    );
    return false;
  }
  final VideoTmdbOrderingChoice? picked = await showVideoTmdbOrderingPicker(
    context: context,
    groups: groups,
    initial: row.episodeGroupId,
  );
  if (picked == null || !context.mounted) return false;
  await database.setVideoMetadataWorkEpisodeGroup(workId, picked.groupId);
  final VideoMetadataLookup? lookup = await lookupOfWork(database, workId);
  if (lookup == null || !context.mounted) return true;
  FushiToast.show(
    msg: t.collection_tmdb_ordering_saved,
    severity: ToastSeverity.info,
  );
  try {
    await controller.rescrapeWorkWithLookup(
      source: source,
      workTitle: workTitle,
      workStableKey: workStableKey,
      lookup: lookup,
    );
  } on VideoSourceScrapeCancelled {
    // 用户在任务面板撤回了尚未执行的重刮；排序本身已写入。
  }
  return true;
}

/// 对话框返回值：`groupId == null` = TMDB 默认排序（与「取消」区分开）。
class VideoTmdbOrderingChoice {
  const VideoTmdbOrderingChoice(this.groupId);
  final String? groupId;
}

/// 只弹选择框（不写库）：本机与互联远端两条路径共用同一张列表，数据源由调用方给。
/// 取消 → null。
Future<VideoTmdbOrderingChoice?> showVideoTmdbOrderingPicker({
  required BuildContext context,
  required List<VideoMetadataEpisodeGroupSummary> groups,
  required String? initial,
}) =>
    showAppDialog<VideoTmdbOrderingChoice>(
      context: context,
      builder: (BuildContext context) =>
          _VideoTmdbOrderingDialog(groups: groups, initial: initial),
    );

class _VideoTmdbOrderingDialog extends StatefulWidget {
  const _VideoTmdbOrderingDialog({required this.groups, required this.initial});

  final List<VideoMetadataEpisodeGroupSummary> groups;
  final String? initial;

  @override
  State<_VideoTmdbOrderingDialog> createState() =>
      _VideoTmdbOrderingDialogState();
}

class _VideoTmdbOrderingDialogState extends State<_VideoTmdbOrderingDialog> {
  late String? _selected = widget.initial;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(t.collection_tmdb_ordering),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(t.collection_tmdb_ordering_hint),
              RadioListTile<String?>(
                key: const ValueKey<String>('video-tmdb-ordering-default'),
                value: null,
                groupValue: _selected,
                title: Text(t.collection_tmdb_ordering_default),
                onChanged: (String? value) => setState(() => _selected = value),
              ),
              for (final VideoMetadataEpisodeGroupSummary group
                  in widget.groups)
                RadioListTile<String?>(
                  key: ValueKey<String>('video-tmdb-ordering-${group.id}'),
                  value: group.id,
                  groupValue: _selected,
                  title: Text(group.name),
                  subtitle: Text(
                    <String>[
                      if (group.groupCount != null ||
                          group.episodeCount != null)
                        t.collection_tmdb_ordering_counts(
                          groups: group.groupCount ?? 0,
                          episodes: group.episodeCount ?? 0,
                        ),
                      if (group.description?.trim().isNotEmpty ?? false)
                        group.description!.trim(),
                    ].join('\n'),
                  ),
                  isThreeLine:
                      (group.description?.trim().isNotEmpty ?? false) &&
                      (group.groupCount != null || group.episodeCount != null),
                  onChanged: (String? value) =>
                      setState(() => _selected = value),
                ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        adaptiveDialogAction(
          context: context,
          onPressed: () => Navigator.pop(context),
          child: Text(t.dialog_cancel),
        ),
        adaptiveDialogAction(
          context: context,
          isDefaultAction: true,
          onPressed: () =>
              Navigator.pop(context, VideoTmdbOrderingChoice(_selected)),
          child: Text(t.dialog_save),
        ),
      ],
    );
  }
}
