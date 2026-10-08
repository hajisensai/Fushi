import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/video/video_control_customization.dart';
import 'package:fushi/src/media/video/video_custom_action_bindings.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/shortcuts/shortcut_labels.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

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
      return FushiIcons.speed;
    case VideoControlButton.subtitleList:
      return FushiIcons.listView;
    case VideoControlButton.favoriteSentence:
      return FushiIcons.star;
    case VideoControlButton.settings:
      return FushiIcons.settings;
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
/// 不传 / 未绑定时退回**加号**——空槽位的唯一语义就是「点这里加一个动作」，播放器上
/// 露出来的那个（[VideoCustomActionBindings.firstUnboundSlotIndex]）和编辑器调色板里
/// 还没配动作的槽位都是这个样子。
IconData videoControlItemIcon(
  VideoControlItem item, {
  VideoCustomActionBindings? bindings,
}) {
  final int? slotIndex = item.customActionSlotIndex;
  if (slotIndex != null) {
    return bindings?.actionAt(slotIndex)?.buttonIcon ?? FushiIcons.add;
  }
  final VideoControlButton? legacy = item.legacyButton;
  if (legacy != null) return videoControlButtonIcon(legacy);
  switch (item) {
    case VideoControlItem.playPause:
      return FushiIcons.play;
    case VideoControlItem.back:
      return FushiIcons.back;
    case VideoControlItem.immersiveLock:
      return FushiIcons.lock;
    case VideoControlItem.seekBackward:
      return FushiIcons.fastRewind;
    case VideoControlItem.seekForward:
      return FushiIcons.fastForward;
    case VideoControlItem.frameBackward:
      return FushiIcons.stepBackward;
    case VideoControlItem.frameForward:
      return FushiIcons.stepForward;
    case VideoControlItem.previousCue:
      return FushiIcons.skipPrevious;
    case VideoControlItem.nextCue:
      return FushiIcons.skipNext;
    case VideoControlItem.replayCue:
      return FushiIcons.replay;
    case VideoControlItem.fullscreen:
      return FushiIcons.fullscreen;
    case VideoControlItem.screenshot:
      return FushiIcons.camera;
    case VideoControlItem.clipExport:
      return FushiIcons.video;
    case VideoControlItem.subtitleTrack:
      return FushiIcons.subtitles;
    case VideoControlItem.audioTrack:
      return FushiIcons.audio;
    case VideoControlItem.previousEpisode:
      // 上/下一集用实心字形，与上/下一句字幕（线框 skipPrevious）区分。
      return FushiIcons.filled(FushiIcons.skipPrevious);
    case VideoControlItem.nextEpisode:
      return FushiIcons.filled(FushiIcons.skipNext);
    case VideoControlItem.episodeList:
      return FushiIcons.playlist;
    case VideoControlItem.previousChapter:
      return FushiIcons.firstPage;
    case VideoControlItem.nextChapter:
      return FushiIcons.lastPage;
    case VideoControlItem.chapterList:
      return FushiIcons.numberedList;
    case VideoControlItem.danmaku:
      return FushiIcons.danmaku;
    case VideoControlItem.volume:
      return FushiIcons.volumeUp;
    case VideoControlItem.title:
      return FushiIcons.title;
    case VideoControlItem.positionIndicator:
    case VideoControlItem.speed:
    case VideoControlItem.subtitleList:
    case VideoControlItem.favoriteSentence:
    case VideoControlItem.settings:
      return FushiIcons.settings;
    case VideoControlItem.customAction1:
    case VideoControlItem.customAction2:
    case VideoControlItem.customAction3:
    case VideoControlItem.customAction4:
      // 不可达：函数开头已按 [customActionSlotIndex] 解析并返回。保留分支只为让穷举
      // 检查继续生效——将来新增枚举项时仍然是「漏写即编译失败」。
      return FushiIcons.add;
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
    case VideoControlItem.replayCue:
      return t.shortcut_action_video_replay_current_subtitle;
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
    case VideoControlItem.danmaku:
      return t.video_control_danmaku;
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
