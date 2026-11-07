/// 在线来源共用的「更多」动作：曲目 / 专辑 / 歌单 / 艺人菜单、加入歌单（含新建）。
///
/// Apple Music（[MusicServerBrowser] 来源）与在线插件（网易云等）各自只回答「这一项能做哪些事、
/// 每件事怎么做」（一组 [MusicMenuAction]、一个 [MusicPlaylistEditor]），菜单外观、
/// 选歌单 / 新建歌单的流程、错误提示只在这里写一次。
library;

import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/music_player_engine.dart';

import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_m3e_overlays.dart';
import 'package:fushi/src/utils/components/glass/fushi_expressive_controls.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart';
import 'package:fushi/src/shortcuts/context_menu_trigger.dart'
    show ContextMenuTrigger, activeContextMenuAnchor;

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

/// 曲目菜单最上面的两项「下一首播放」「加入播放队列」（各来源的曲目菜单共用），操作后
/// 提示结果。[item] 在点下时才取（插件 / 服务器曲目的播放项要读当时的设置）。当前在放
/// 后端自管的队列（Apple Music 电台，[MusicPlayerEngine.canEditQueue] 为假）时不给这两项；
/// 没有队列时两项都直接开播。
List<MusicMenuAction> musicQueueMenuActions(
  MusicPlayerEngine engine,
  MusicPlayItem Function() item,
) {
  if (engine.queue.isNotEmpty && !engine.canEditQueue) {
    return const <MusicMenuAction>[];
  }
  return <MusicMenuAction>[
    MusicMenuAction(
      id: 'playNext',
      label: t.music_queue_play_next,
      icon: FushiIcons.playlist,
      run: (_) async {
        final MusicPlayItem it = item();
        await engine.playNext(<MusicPlayItem>[it]);
        FushiToast.show(
          msg: t.music_queue_queued_next(title: it.title),
          severity: ToastSeverity.success,
        );
      },
    ),
    MusicMenuAction(
      id: 'addToQueue',
      label: t.music_queue_add,
      icon: FushiIcons.add,
      run: (_) async {
        final MusicPlayItem it = item();
        await engine.addToQueue(<MusicPlayItem>[it]);
        FushiToast.show(
          msg: t.music_queue_added(title: it.title),
          severity: ToastSeverity.success,
        );
      },
    ),
  ];
}

/// 菜单锚点（global 坐标系的矩形）：「更多」按钮给按钮自己的矩形，右键给按下处的点。
typedef MusicMenuAnchor = Rect;

/// [context] 所在控件的 global 矩形；拿不到（还没布局）时回 null。
MusicMenuAnchor? musicMenuAnchorOf(BuildContext context) {
  final RenderObject? box = context.findRenderObject();
  if (box is! RenderBox || !box.hasSize) return null;
  return box.localToGlobal(Offset.zero) & box.size;
}

/// 右键派发期间的按下点（[activeContextMenuAnchor]）当锚点；不在右键派发里回 null。
MusicMenuAnchor? musicContextMenuAnchor() => switch (activeContextMenuAnchor) {
  final Offset p => Rect.fromPoints(p, p),
  null => null,
};

/// 在 [anchor] 处弹下拉菜单（右键 = 指针处，「更多」= 按钮下方），执行选中的一项。
/// [anchor] 为 null 时依次取右键按下点、[context] 自身的矩形。[errorText] 把异常转成
/// 给用户看的一句话（各来源的错误文案不同：Apple Music 请求失败 / 插件报的原话）。
///
/// 先 await 再弹的调用方要在第一个 await 之前取好 [anchor]（右键坐标只在同步派发期间可读）。
Future<void> showMusicActionMenu(
  BuildContext context, {
  required List<MusicMenuAction> actions,
  required String Function(Object error) errorText,
  MusicMenuAnchor? anchor,
}) async {
  if (actions.isEmpty) return;
  final MusicMenuAnchor? at =
      anchor ?? musicContextMenuAnchor() ?? musicMenuAnchorOf(context);
  final RenderObject? overlay = Overlay.of(context).context.findRenderObject();
  if (at == null || overlay is! RenderBox) return;
  // 全局 UI 缩放下 Overlay 与屏幕坐标不同尺度：经 globalToLocal 换算（BUG-781 同族）。
  final Rect local = Rect.fromPoints(
    overlay.globalToLocal(at.topLeft),
    overlay.globalToLocal(at.bottomRight),
  );
  final TextStyle? sub = Theme.of(context).textTheme.bodySmall?.copyWith(
    color: Theme.of(context).colorScheme.onSurfaceVariant,
  );
  final MusicMenuAction? picked = await showFushiMenu<MusicMenuAction>(
    context: context,
    position: RelativeRect.fromRect(local, Offset.zero & overlay.size),
    items: <PopupMenuEntry<MusicMenuAction>>[
      for (final MusicMenuAction a in actions)
        PopupMenuItem<MusicMenuAction>(
          key: ValueKey<String>('music-menu-action-${a.id}'),
          value: a,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              FushiIcon(a.icon, size: 20),
              const SizedBox(width: 12),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(a.label),
                    if (a.subtitle case final String s)
                      Text(
                        s,
                        style: sub,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
            ],
          ),
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

/// 行尾 / 按钮行里的「更多」按钮：[onTap] 收到按钮自己的矩形，菜单从按钮处展开。
Widget musicMoreButton({
  required Key key,
  required ValueChanged<MusicMenuAnchor?> onTap,
}) => Builder(
  builder: (BuildContext buttonContext) => FushiIconButton(
    key: key,
    icon: FushiIcons.moreHoriz,
    tooltip: t.music_action_more,
    padTouchTarget: true,
    onTap: () => onTap(musicMenuAnchorOf(buttonContext)),
  ),
);

/// 一项条目（曲目 / 专辑 / 歌单 / 艺人）的动作菜单：行尾「更多」按钮与整行右键弹的是同一份。
class MusicItemMenu {
  const MusicItemMenu({required this.buttonKey, required this.open});

  /// 「更多」按钮的 key（测试按它点）。
  final Key buttonKey;

  /// 在锚点处弹菜单；null 锚点 = 取右键按下点 / 调用方自身矩形。
  final ValueChanged<MusicMenuAnchor?> open;

  /// 行尾「更多」按钮：菜单从按钮处展开。
  Widget button() => musicMoreButton(key: buttonKey, onTap: open);

  /// 把 [child] 包成右键（绑定表里的「上下文菜单」键）也弹这份菜单。
  Widget contextMenu({required Widget child}) => ContextMenuTrigger(
    onInvoke: (Offset p) => open(Rect.fromPoints(p, p)),
    child: child,
  );
}

/// 有菜单就包右键，没有原样返回。
Widget musicWithContextMenu(MusicItemMenu? menu, Widget child) =>
    menu == null ? child : menu.contextMenu(child: child);

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
    // 段头里的次要动作：与同行的刷新图标、推荐页「私人电台」同为 S 号。
    size: FushiButtonSize.s,
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
