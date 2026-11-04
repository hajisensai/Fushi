/// 在线来源共用的「更多」动作：曲目 / 专辑 / 歌单 / 艺人菜单、加入歌单（含新建）。
///
/// Apple Music（[MusicServerBrowser] 来源）与在线插件（网易云等）各自只回答「这一项能做哪些事、
/// 每件事怎么做」（一组 [MusicMenuAction]、一个 [MusicPlaylistEditor]），菜单外观、
/// 选歌单 / 新建歌单的流程、错误提示只在这里写一次。
library;

import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// 菜单里的一项。[run] 在菜单关掉后执行；抛错由 [showMusicActionMenu] 统一提示。
class MusicMenuAction {
  const MusicMenuAction({
    required this.id,
    required this.label,
    required this.icon,
    required this.run,
    this.subtitle,
  });

  /// 稳定标识（测试按它找项；同一菜单内唯一）。
  final String id;
  final String label;
  final String? subtitle;
  final IconData icon;
  final Future<void> Function(BuildContext context) run;
}

/// 弹出动作菜单，执行选中的一项。[errorText] 把异常转成给用户看的一句话（各来源的错误
/// 文案不同：Apple Music 请求失败 / 插件报的原话）。
Future<void> showMusicActionMenu(
  BuildContext context, {
  required String title,
  required List<MusicMenuAction> actions,
  required String Function(Object error) errorText,
  IconData icon = FushiIcons.music,
}) async {
  if (actions.isEmpty) return;
  final MusicMenuAction? picked = await showFushiChoiceDialog<MusicMenuAction>(
    context: context,
    title: title,
    icon: icon,
    options: <FushiChoiceOption<MusicMenuAction>>[
      for (final MusicMenuAction a in actions)
        FushiChoiceOption<MusicMenuAction>(
          value: a,
          label: a.label,
          subtitle: a.subtitle,
          icon: a.icon,
        ),
    ],
  );
  if (picked == null || !context.mounted) return;
  try {
    await picked.run(context);
  } on Object catch (e) {
    FushiToast.show(msg: errorText(e), severity: ToastSeverity.error);
  }
}

/// 行尾 / 按钮行里的「更多」按钮。
Widget musicMoreButton({required Key key, required VoidCallback onTap}) =>
    FushiIconButton(
      key: key,
      icon: FushiIcons.moreHoriz,
      tooltip: t.music_action_more,
      padTouchTarget: true,
      onTap: onTap,
    );

/// 加歌时可选的一个歌单。
class MusicPlaylistTarget {
  const MusicPlaylistTarget({
    required this.id,
    required this.title,
    this.trackCount,
  });

  final String id;
  final String title;
  final int? trackCount;
}

/// 一个能往账号歌单里加歌、能新建歌单的来源。
abstract interface class MusicPlaylistEditor {
  /// 当前账号能往里加歌的歌单。
  Future<List<MusicPlaylistTarget>> editablePlaylists();

  /// 新建歌单（可带初始曲目），回新歌单。
  Future<MusicPlaylistTarget> createPlaylist(
    String name, {
    List<String> trackIds = const <String>[],
  });

  /// 把 [trackIds] 加进 [playlistId]。
  Future<void> addToPlaylist(String playlistId, List<String> trackIds);
}

/// 选一个可编辑歌单（或新建）并把 [trackIds] 加进去；成功时提示。用户取消回 false。
Future<bool> musicAddToPlaylist(
  BuildContext context,
  MusicPlaylistEditor editor,
  List<String> trackIds,
) async {
  final List<MusicPlaylistTarget> editable = await editor.editablePlaylists();
  if (!context.mounted) return false;
  const String newId = '\u0000new';
  final String? picked = await showFushiChoiceDialog<String>(
    context: context,
    title: t.music_action_add_to_playlist,
    icon: FushiIcons.playlist,
    options: <FushiChoiceOption<String>>[
      FushiChoiceOption<String>(
        value: newId,
        label: t.music_action_new_playlist,
        icon: FushiIcons.add,
      ),
      for (final MusicPlaylistTarget p in editable)
        FushiChoiceOption<String>(
          value: p.id,
          label: p.title,
          subtitle: p.trackCount == null
              ? null
              : t.music_tracks_count(count: p.trackCount!),
          icon: FushiIcons.playlist,
        ),
    ],
  );
  if (picked == null || !context.mounted) return false;
  if (picked == newId) {
    final MusicPlaylistTarget? created = await musicCreatePlaylist(
      context,
      editor,
      trackIds: trackIds,
    );
    if (created == null) return false;
    FushiToast.show(
      msg: t.music_action_added_to_playlist(name: created.title),
      severity: ToastSeverity.success,
    );
    return true;
  }
  await editor.addToPlaylist(picked, trackIds);
  final String name = editable
      .firstWhere((MusicPlaylistTarget p) => p.id == picked)
      .title;
  FushiToast.show(
    msg: t.music_action_added_to_playlist(name: name),
    severity: ToastSeverity.success,
  );
  return true;
}

/// 问名字并新建歌单（可带初始曲目）。取消回 null。
Future<MusicPlaylistTarget?> musicCreatePlaylist(
  BuildContext context,
  MusicPlaylistEditor editor, {
  List<String> trackIds = const <String>[],
}) async {
  final String? name = await showFushiTextInputDialog(
    context: context,
    title: t.music_action_new_playlist,
    labelText: t.music_action_playlist_name,
    icon: FushiIcons.playlist,
  );
  if (name == null || name.isEmpty) return null;
  return editor.createPlaylist(name, trackIds: trackIds);
}

/// 歌单列表顶部的「新建歌单」按钮：建好后提示并回调 [onCreated]（调用方刷新列表）。
Widget musicCreatePlaylistButton(
  BuildContext context,
  MusicPlaylistEditor editor, {
  required Key key,
  required VoidCallback onCreated,
  required String Function(Object error) errorText,
}) => FushiPressScale(
  child: FushiFilledButton.tonalIcon(
    key: key,
    size: FushiButtonSize.m,
    onPressed: () async {
      try {
        final MusicPlaylistTarget? p = await musicCreatePlaylist(
          context,
          editor,
        );
        if (p == null) return;
        FushiToast.show(
          msg: t.music_action_playlist_created(name: p.title),
          severity: ToastSeverity.success,
        );
        onCreated();
      } on Object catch (e) {
        FushiToast.show(msg: errorText(e), severity: ToastSeverity.error);
      }
    },
    icon: const FushiIcon(FushiIcons.add),
    label: Text(t.music_action_new_playlist),
  ),
);
