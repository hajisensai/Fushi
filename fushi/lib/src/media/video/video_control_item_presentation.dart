import 'package:flutter/material.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/video/video_control_customization.dart';
import 'package:fushi/src/media/video/video_custom_action_bindings.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/shortcuts/shortcut_labels.dart';

/// Single source of truth for the icon + label presentation of every
/// [VideoControlItem] / [VideoControlButton].
///
/// This static mapping previously lived, byte-for-byte, as four private methods
/// (`_controlItemIcon` / `_controlItemLabel` / `_controlButtonIcon` /
/// `_controlButtonLabel`) in **both** the layout-editor overlay and the
/// quick-settings drag editor, plus a third near-copy on the player page. The
/// overlay and the sheet now delegate here verbatim.
///
/// The player page keeps its own thin `_videoControlItemIcon` /
/// `_videoControlItemTooltip` that override only the cases where its display
/// value genuinely differs — the immersive-lock toggle state, the clip-export
/// progress glyph, the filled transport glyphs for the previous/next episode
/// buttons, and the `speed` legacy glyph — and falls back to these functions for
/// everything else. Those per-surface differences are intentional and must NOT
/// be folded in here; keep them at the call site.
///
/// Labels read the ambient global `t` (matching the original code, which used
/// the global translations rather than `context.t`); [context] is only needed
/// for the `back` case's [MaterialLocalizations] tooltip.

/// Icon for [button] as rendered by the customization editor and the
/// quick-settings sheet. (The player page has its own filled-glyph variant for
/// [VideoControlButton.speed] and must keep it.)
IconData videoControlButtonIcon(VideoControlButton button) {
  switch (button) {
    case VideoControlButton.speed:
      return Icons.speed_outlined;
    case VideoControlButton.subtitleList:
      return Icons.format_list_bulleted;
    case VideoControlButton.favoriteSentence:
      return Icons.star_border_rounded;
    case VideoControlButton.settings:
      return Icons.tune;
  }
}

/// Localised label for [button].
String videoControlButtonLabel(VideoControlButton button) {
  switch (button) {
    case VideoControlButton.speed:
      return t.video_control_speed;
    case VideoControlButton.subtitleList:
      return t.video_control_subtitle_list;
    case VideoControlButton.favoriteSentence:
      return t.video_control_favorite_sentence;
    case VideoControlButton.settings:
      return t.video_control_settings;
  }
}

/// Icon for [item]. Legacy button items defer to [videoControlButtonIcon].
///
/// [bindings] 只对自定义「快捷键 1..4」按钮有意义：它们没有固定图标，长相取决于用户
/// 绑了哪个动作（用户拍板：按钮显示该动作的图标，一眼认得出，不用记住 1 是什么）。
/// 不传 / 未绑定时退回通用的「快捷键」闪电图标——编辑器调色板里那个还没配动作的空槽位
/// 正是这个样子。
IconData videoControlItemIcon(
  VideoControlItem item, {
  VideoCustomActionBindings? bindings,
}) {
  final int? slotIndex = item.customActionSlotIndex;
  if (slotIndex != null) {
    return bindings?.actionAt(slotIndex)?.buttonIcon ?? Icons.bolt_outlined;
  }
  final VideoControlButton? legacy = item.legacyButton;
  if (legacy != null) return videoControlButtonIcon(legacy);
  switch (item) {
    case VideoControlItem.playPause:
      return Icons.play_arrow_rounded;
    case VideoControlItem.back:
      return Icons.arrow_back;
    case VideoControlItem.immersiveLock:
      return Icons.lock_outline;
    case VideoControlItem.seekBackward:
      return Icons.fast_rewind;
    case VideoControlItem.seekForward:
      return Icons.fast_forward;
    case VideoControlItem.frameBackward:
      return Icons.arrow_left;
    case VideoControlItem.frameForward:
      return Icons.arrow_right;
    case VideoControlItem.previousCue:
      return Icons.skip_previous;
    case VideoControlItem.nextCue:
      return Icons.skip_next;
    case VideoControlItem.fullscreen:
      return Icons.fullscreen;
    case VideoControlItem.screenshot:
      return Icons.photo_camera_outlined;
    case VideoControlItem.clipExport:
      return Icons.movie_creation_outlined;
    case VideoControlItem.subtitleTrack:
      return Icons.subtitles;
    case VideoControlItem.audioTrack:
      return Icons.audiotrack;
    case VideoControlItem.previousEpisode:
      return Icons.skip_previous_outlined;
    case VideoControlItem.nextEpisode:
      return Icons.skip_next_outlined;
    case VideoControlItem.episodeList:
      return Icons.playlist_play;
    case VideoControlItem.previousChapter:
      return Icons.first_page;
    case VideoControlItem.nextChapter:
      return Icons.last_page;
    case VideoControlItem.chapterList:
      return Icons.format_list_numbered;
    case VideoControlItem.volume:
      return Icons.volume_up_outlined;
    case VideoControlItem.title:
      return Icons.title;
    case VideoControlItem.positionIndicator:
    case VideoControlItem.speed:
    case VideoControlItem.subtitleList:
    case VideoControlItem.favoriteSentence:
    case VideoControlItem.settings:
      return Icons.tune;
    case VideoControlItem.customAction1:
    case VideoControlItem.customAction2:
    case VideoControlItem.customAction3:
    case VideoControlItem.customAction4:
      // 不可达：函数开头已按 [customActionSlotIndex] 解析并返回。保留分支只为让穷举
      // 检查继续生效——将来新增枚举项时仍然是「漏写即编译失败」。
      return Icons.bolt_outlined;
  }
}

/// Localised label for [item]. Legacy button items defer to
/// [videoControlButtonLabel]; the `back` case uses [MaterialLocalizations].
///
/// [bindings] 同 [videoControlItemIcon]：自定义「快捷键 1..4」按钮显示其**绑定动作**的
/// 名字（tooltip / 无障碍标签都读这里），未绑定时退回「快捷键 N」这个槽位名——用户在
/// 编辑器里正是靠这个名字认出「这是第几个槽位」。
String videoControlItemLabel(
  VideoControlItem item,
  BuildContext context, {
  VideoCustomActionBindings? bindings,
}) {
  final int? slotIndex = item.customActionSlotIndex;
  if (slotIndex != null) {
    final ShortcutAction? action = bindings?.actionAt(slotIndex);
    if (action != null) return action.label;
    return t.video_control_custom_action(index: slotIndex + 1);
  }
  final VideoControlButton? legacy = item.legacyButton;
  if (legacy != null) return videoControlButtonLabel(legacy);
  switch (item) {
    case VideoControlItem.playPause:
      return t.video_control_play_pause;
    case VideoControlItem.back:
      return MaterialLocalizations.of(context).backButtonTooltip;
    case VideoControlItem.immersiveLock:
      return t.video_menu_lock;
    case VideoControlItem.seekBackward:
      return t.video_control_seek_backward;
    case VideoControlItem.seekForward:
      return t.video_control_seek_forward;
    case VideoControlItem.frameBackward:
      return t.shortcut_action_video_previous_frame;
    case VideoControlItem.frameForward:
      return t.shortcut_action_video_next_frame;
    case VideoControlItem.previousCue:
      return t.video_control_previous_cue;
    case VideoControlItem.nextCue:
      return t.video_control_next_cue;
    case VideoControlItem.fullscreen:
      return t.video_control_fullscreen;
    case VideoControlItem.screenshot:
      return t.video_control_screenshot;
    case VideoControlItem.clipExport:
      return t.video_clip_export;
    case VideoControlItem.subtitleTrack:
      return t.video_control_subtitle_track;
    case VideoControlItem.audioTrack:
      return t.video_control_audio_track;
    case VideoControlItem.previousEpisode:
      return t.video_prev_episode;
    case VideoControlItem.nextEpisode:
      return t.video_next_episode;
    case VideoControlItem.episodeList:
      return t.video_control_episode_list;
    case VideoControlItem.previousChapter:
      return t.shortcut_action_video_previous_chapter;
    case VideoControlItem.nextChapter:
      return t.shortcut_action_video_next_chapter;
    case VideoControlItem.chapterList:
      return t.video_chapters;
    case VideoControlItem.volume:
      return t.video_control_volume;
    case VideoControlItem.title:
      return t.video_control_title;
    case VideoControlItem.positionIndicator:
    case VideoControlItem.speed:
    case VideoControlItem.subtitleList:
    case VideoControlItem.favoriteSentence:
    case VideoControlItem.settings:
      return item.storageValue;
    case VideoControlItem.customAction1:
    case VideoControlItem.customAction2:
    case VideoControlItem.customAction3:
    case VideoControlItem.customAction4:
      // 不可达：函数开头已按 [customActionSlotIndex] 解析并返回（见 icon 同款注释）。
      return item.storageValue;
  }
}
