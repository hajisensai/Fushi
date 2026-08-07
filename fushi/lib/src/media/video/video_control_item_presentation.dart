import 'package:flutter/material.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/video/video_control_customization.dart';

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
IconData videoControlItemIcon(VideoControlItem item) {
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
  }
}

/// Localised label for [item]. Legacy button items defer to
/// [videoControlButtonLabel]; the `back` case uses [MaterialLocalizations].
String videoControlItemLabel(VideoControlItem item, BuildContext context) {
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
  }
}
