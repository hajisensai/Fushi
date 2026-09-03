import 'package:flutter/material.dart';

import 'package:fushi/src/media/video/video_player_shortcuts.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/shortcuts/shortcut_labels.dart';
import 'package:fushi/utils.dart';

/// 「快捷键 N」动作选择的结果。
///
/// 存在的唯一理由：把**取消**和**显式选了「不绑定」**分开。两者携带的
/// [ShortcutAction] 都是 null，若直接 `pop<ShortcutAction?>(null)`，点弹窗外部关闭就
///会被当成「清空绑定」——用户只是想关掉弹窗，配好的按钮却没了。
/// 包一层之后：取消 = `null`，不绑定 = `VideoCustomActionPick(null)`。
class VideoCustomActionPick {
  const VideoCustomActionPick(this.action);

  /// 用户选中的动作；null = 显式选择「不绑定」（清空该槽位）。
  final ShortcutAction? action;
}

/// 弹出「快捷键 [slotNumber]」的动作选择器（1-based 序号，仅用于标题文案）。
///
/// 两个宿主共用同一个入口，保证两处看到的列表、顺序、选中态完全一致：
///   · 控件布局编辑器里点 chip（摆位置时顺手配）；
///   · **播放器控制条上直接点未绑定的按钮**（手机上不用先进设置面板——这正是本功能
///     「便于手机使用」的初衷，也是「未绑定按钮也显示」得以成立的前提：它不是死按钮，
///     而是就地的配置入口）。
///
/// 列表内容是 [kVideoAssignableActions]（= 视频页真正接过线的动作），外加置顶的一条
/// 「不绑定」。返回 null 表示用户取消。
Future<VideoCustomActionPick?> showVideoCustomActionPicker({
  required BuildContext context,
  required int slotNumber,
  required ShortcutAction? current,
}) {
  return showDialog<VideoCustomActionPick>(
    context: context,
    builder: (BuildContext dialogContext) => SimpleDialog(
      title: Text(t.video_control_custom_action(index: slotNumber)),
      children: <Widget>[
        // 「不绑定」置顶：解绑是唯一「把按钮变回空槽」的路径，排在几十条动作末尾会找不到。
        FushiListItem(
          title: Text(t.video_control_custom_action_none),
          leading: const Icon(Icons.block),
          selected: current == null,
          onTap: () => Navigator.of(dialogContext).pop(
            const VideoCustomActionPick(null),
          ),
        ),
        for (final ShortcutAction action in kVideoAssignableActions)
          FushiListItem(
            title: Text(action.label),
            leading: Icon(action.buttonIcon ?? Icons.bolt_outlined),
            selected: current == action,
            onTap: () => Navigator.of(dialogContext).pop(
              VideoCustomActionPick(action),
            ),
          ),
      ],
    ),
  );
}
