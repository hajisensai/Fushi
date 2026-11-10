/// 服务器（Jellyfin）歌单页的可重排曲目列（[MusicPlaylistTrackColumn]）；行尾把手
/// [MusicPlaylistDragHandle] 与本地歌单页的曲目列表共用。
library;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/pages/implementations/music/music_track_actions.dart';
import 'package:fushi/src/pages/implementations/music/music_track_list.dart'
    show MusicPlaylistDragHandle, formatMusicDuration;
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_reorderable_column.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart';

/// 可重排曲目列里的一行。
class MusicPlaylistTrackRowData {
  const MusicPlaylistTrackRowData({
    required this.key,
    required this.title,
    this.subtitle,
    this.durationMs,
  });

  /// 行身份（条目 id 派生；同一首放两次是两行）。
  final String key;
  final String title;
  final String? subtitle;
  final int? durationMs;
}

/// 歌单曲目列：点一行播放；[onReorder] 非空时行尾有拖拽把手（只从把手起拖，整行仍可点、
/// 可右键）；[menuOf] 给每行的「更多」菜单（行尾按钮 + 整行右键）。
class MusicPlaylistTrackColumn extends StatelessWidget {
  const MusicPlaylistTrackColumn({
    super.key,
    required this.rows,
    required this.onPlay,
    this.onReorder,
    this.menuOf,
  });

  final List<MusicPlaylistTrackRowData> rows;
  final void Function(int index) onPlay;
  final void Function(int from, int to)? onReorder;
  final MusicItemMenu? Function(BuildContext context, int index)? menuOf;

  Widget _row(BuildContext context, int i) {
    final MusicPlaylistTrackRowData r = rows[i];
    final MusicItemMenu? menu = menuOf?.call(context, i);
    return FushiStaggeredEntrance(
      index: i,
      child: musicWithContextMenu(
        menu,
        FushiPressScale(
          child: FushiGroupedListItem(
            key: ValueKey<String>('music-playlist-row-${r.key}'),
            index: i,
            count: rows.length,
            onTap: () => onPlay(i),
            child: FushiListItem(
              leading: SizedBox(
                width: 28,
                child: Text(
                  '${i + 1}',
                  textAlign: TextAlign.end,
                  style: context.fushiType.bodySmall,
                ),
              ),
              title: Text(
                r.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: r.subtitle == null || r.subtitle!.isEmpty
                  ? null
                  : Text(
                      r.subtitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    formatMusicDuration(r.durationMs),
                    style: context.fushiType.bodySmall,
                  ),
                  ?menu?.button(),
                  if (onReorder != null) const MusicPlaylistDragHandle(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final void Function(int from, int to)? reorder = onReorder;
    if (reorder == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (int i = 0; i < rows.length; i++) _row(context, i),
        ],
      );
    }
    return FushiReorderableColumn(
      itemCount: rows.length,
      useDragHandles: true,
      keyForIndex: (int i) =>
          ValueKey<String>('music-playlist-reorder-${rows[i].key}'),
      onReorder: reorder,
      itemBuilder: _row,
    );
  }
}
