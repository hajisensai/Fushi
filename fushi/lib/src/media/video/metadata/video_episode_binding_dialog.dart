/// 「手动指定季集」（集级 UserVerified）——Shoko `CrossRef_AniDB_TMDB_Episode`
/// 里用户逐集手动改链接并保留的用户面。
///
/// 挂在合集详情页集卡的上下文菜单上：从规范作品已有的季 / 集里选一个，写
/// `video_episode_binding_overrides`（刮削时最高优先级，AniDB 集级链接与文件名
/// 解析都不再动它）并**立刻**把分集行改绑过去
/// （[FushiDatabase.rebindVideoEpisodeToBook]），不等下一次刮削。
library;

import 'package:flutter/material.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';

/// 打开季集选择框并在确认后写库 + 立刻改绑。返回是否改了。
///
/// [workId] 是合集的规范作品行；还没刮出季集时给提示、不弹框。
Future<bool> pinVideoEpisodeBinding({
  required BuildContext context,
  required FushiDatabase database,
  required int workId,
  required String bookUid,
}) async {
  final List<VideoMetadataSeasonRow> seasons = await database
      .getVideoMetadataSeasons(workId);
  final Map<int, List<VideoMetadataEpisodeRow>> episodesBySeason =
      <int, List<VideoMetadataEpisodeRow>>{
        for (final VideoMetadataSeasonRow season in seasons)
          season.seasonNumber: await database.getVideoMetadataEpisodes(
            season.id,
          ),
      };
  episodesBySeason.removeWhere(
    (int _, List<VideoMetadataEpisodeRow> rows) => rows.isEmpty,
  );
  if (!context.mounted) return false;
  if (episodesBySeason.isEmpty) {
    FushiToast.show(
      msg: t.collection_episode_link_unavailable,
      severity: ToastSeverity.info,
    );
    return false;
  }
  final VideoEpisodeBindingOverrideRow? existing = await database
      .getVideoEpisodeBindingOverride(bookUid);
  final List<VideoMetadataEpisodeRow> bound = await database
      .getVideoMetadataEpisodesByBook(bookUid);
  if (!context.mounted) return false;
  (int, int)? initial;
  if (existing != null) {
    initial = (existing.seasonNumber, existing.episodeNumber);
  } else if (bound.firstOrNull case final VideoMetadataEpisodeRow row) {
    final VideoMetadataSeasonRow? season = seasons
        .where((VideoMetadataSeasonRow s) => s.id == row.seasonId)
        .firstOrNull;
    if (season != null) initial = (season.seasonNumber, row.episodeNumber);
  }
  final _BindingChoice? picked = await showAppDialog<_BindingChoice>(
    context: context,
    builder: (BuildContext context) => _VideoEpisodeBindingDialog(
      episodesBySeason: episodesBySeason,
      initial: initial,
      canClear: existing != null,
    ),
  );
  if (picked == null || !context.mounted) return false;
  if (picked.clear) {
    await database.clearVideoEpisodeBindingOverride(bookUid);
    if (!context.mounted) return true;
    FushiToast.show(
      msg: t.collection_episode_link_cleared,
      severity: ToastSeverity.info,
    );
    return true;
  }
  final (int, int) key = picked.key!;
  await database.setVideoEpisodeBindingOverride(
    bookUid,
    seasonNumber: key.$1,
    episodeNumber: key.$2,
  );
  await database.rebindVideoEpisodeToBook(
    workId: workId,
    bookUid: bookUid,
    seasonNumber: key.$1,
    episodeNumber: key.$2,
  );
  if (!context.mounted) return true;
  FushiToast.show(
    msg: t.collection_episode_link_saved,
    severity: ToastSeverity.success,
  );
  return true;
}

/// 对话框返回值：`clear` = 清除手动指定；否则 [key] 为选中的 (季, 集)。
class _BindingChoice {
  const _BindingChoice.pick(this.key) : clear = false;
  const _BindingChoice.clear() : key = null, clear = true;
  final (int, int)? key;
  final bool clear;
}

class _VideoEpisodeBindingDialog extends StatefulWidget {
  const _VideoEpisodeBindingDialog({
    required this.episodesBySeason,
    required this.initial,
    required this.canClear,
  });

  final Map<int, List<VideoMetadataEpisodeRow>> episodesBySeason;
  final (int, int)? initial;
  final bool canClear;

  @override
  State<_VideoEpisodeBindingDialog> createState() =>
      _VideoEpisodeBindingDialogState();
}

class _VideoEpisodeBindingDialogState
    extends State<_VideoEpisodeBindingDialog> {
  late int _season = widget.initial?.$1 ?? widget.episodesBySeason.keys.first;
  late int _episode =
      widget.initial?.$2 ??
      widget.episodesBySeason[_season]!.first.episodeNumber;

  List<VideoMetadataEpisodeRow> get _episodes =>
      widget.episodesBySeason[_season] ?? const <VideoMetadataEpisodeRow>[];

  @override
  Widget build(BuildContext context) {
    final List<int> seasons = widget.episodesBySeason.keys.toList()..sort();
    if (!widget.episodesBySeason.containsKey(_season)) _season = seasons.first;
    if (!_episodes.any(
      (VideoMetadataEpisodeRow e) => e.episodeNumber == _episode,
    )) {
      _episode = _episodes.first.episodeNumber;
    }
    return AlertDialog(
      title: Text(t.collection_episode_link_manual),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(t.collection_episode_link_hint),
            const SizedBox(height: 12),
            DropdownButtonFormField<int>(
              key: const ValueKey<String>('video-episode-link-season'),
              value: _season,
              items: <DropdownMenuItem<int>>[
                for (final int season in seasons)
                  DropdownMenuItem<int>(
                    value: season,
                    child: Text(
                      t.collection_episode_link_season(number: season),
                    ),
                  ),
              ],
              onChanged: (int? value) {
                if (value == null) return;
                setState(() {
                  _season = value;
                  _episode = _episodes.first.episodeNumber;
                });
              },
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<int>(
              key: const ValueKey<String>('video-episode-link-episode'),
              value: _episode,
              isExpanded: true,
              items: <DropdownMenuItem<int>>[
                for (final VideoMetadataEpisodeRow row in _episodes)
                  DropdownMenuItem<int>(
                    value: row.episodeNumber,
                    child: Text(
                      <String>[
                        t.collection_episode_link_episode(
                          number: row.episodeNumber,
                        ),
                        if (row.title?.trim().isNotEmpty ?? false)
                          row.title!.trim(),
                      ].join(' · '),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: (int? value) {
                if (value == null) return;
                setState(() => _episode = value);
              },
            ),
          ],
        ),
      ),
      actions: <Widget>[
        if (widget.canClear)
          adaptiveDialogAction(
            context: context,
            onPressed: () =>
                Navigator.pop(context, const _BindingChoice.clear()),
            child: Text(t.collection_episode_link_clear),
          ),
        adaptiveDialogAction(
          context: context,
          onPressed: () => Navigator.pop(context),
          child: Text(t.dialog_cancel),
        ),
        adaptiveDialogAction(
          context: context,
          isDefaultAction: true,
          onPressed: () =>
              Navigator.pop(context, _BindingChoice.pick((_season, _episode))),
          child: Text(t.dialog_save),
        ),
      ],
    );
  }
}
