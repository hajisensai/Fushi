// 快捷键类型的本地化展示层（从 shortcut_settings_page.dart 抽出）。
//
// 动机：动作/作用域的显示名过去是设置页里两个 100+ 行的文件私有 switch，
// 每加一个 [ShortcutAction] 都要跨文件手工同步一次标签分支。抽成与
// shortcuts 数据层同目录的公开扩展后，加动作时标签就近可见；穷举 switch
// 保留——漏写分支直接编译失败，不需要运行时兜底。
//
// 本文件只做「类型 → 本地化文案/图标」的纯映射，不读写注册表、不触碰
// 绑定序列化。

import 'package:flutter/material.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/shortcuts/input_binding.dart';
import 'package:hibiki/src/shortcuts/shortcut_action.dart';

/// Localised label for a [ShortcutAction].
extension ShortcutActionLabel on ShortcutAction {
  String get label {
    switch (this) {
      case ShortcutAction.readerPageForward:
        return t.shortcut_action_reader_page_forward;
      case ShortcutAction.readerPageBackward:
        return t.shortcut_action_reader_page_backward;
      case ShortcutAction.readerToggleChrome:
        return t.shortcut_action_reader_toggle_chrome;
      case ShortcutAction.readerOpenMenu:
        return t.shortcut_action_reader_open_menu;
      case ShortcutAction.readerOpenNavigation:
        return t.shortcut_action_reader_open_navigation;
      case ShortcutAction.readerDismissDict:
        return t.shortcut_action_reader_dismiss_dict;
      case ShortcutAction.readerExitBook:
        return t.shortcut_action_reader_exit_book;
      case ShortcutAction.readerToggleFurigana:
        return t.shortcut_action_reader_toggle_furigana;
      case ShortcutAction.readerLookupAtCursor:
        return t.shortcut_action_reader_lookup_at_cursor;
      case ShortcutAction.readerShiftLookup:
        return t.shortcut_action_reader_shift_lookup;
      case ShortcutAction.readerCreateCardFromPopup:
        return t.shortcut_action_reader_create_card_from_popup;
      case ShortcutAction.readerEnterCaret:
        return t.shortcut_action_reader_enter_caret;
      case ShortcutAction.homeTabBooks:
        return t.shortcut_action_home_tab_books;
      case ShortcutAction.homeTabDict:
        return t.shortcut_action_home_tab_dict;
      case ShortcutAction.homeTabSettings:
        return t.shortcut_action_home_tab_settings;
      case ShortcutAction.homeTabPrev:
        return t.shortcut_action_home_tab_prev;
      case ShortcutAction.homeTabNext:
        return t.shortcut_action_home_tab_next;
      case ShortcutAction.homeFocusSearch:
        return t.shortcut_action_home_focus_search;
      case ShortcutAction.globalBack:
        return t.shortcut_action_global_back;
      case ShortcutAction.globalScrollPageDown:
        return t.shortcut_action_global_scroll_page_down;
      case ShortcutAction.globalScrollPageUp:
        return t.shortcut_action_global_scroll_page_up;
      case ShortcutAction.globalToggleFullscreen:
        return t.shortcut_action_global_toggle_fullscreen;
      case ShortcutAction.audiobookPlayPause:
        return t.shortcut_action_audiobook_play_pause;
      case ShortcutAction.audiobookNextSentence:
        return t.shortcut_action_audiobook_next_sentence;
      case ShortcutAction.audiobookPrevSentence:
        return t.shortcut_action_audiobook_prev_sentence;
      case ShortcutAction.audiobookSeekToClickedSentence:
        return t.shortcut_action_audiobook_seek_clicked;
      case ShortcutAction.videoTogglePlayPause:
        return t.shortcut_action_video_toggle_play_pause;
      case ShortcutAction.videoPlay:
        return t.shortcut_action_video_play;
      case ShortcutAction.videoPause:
        return t.shortcut_action_video_pause;
      case ShortcutAction.videoPreviousSubtitle:
        return t.shortcut_action_video_previous_subtitle;
      case ShortcutAction.videoNextSubtitle:
        return t.shortcut_action_video_next_subtitle;
      case ShortcutAction.videoSeekBackward:
        return t.shortcut_action_video_seek_backward;
      case ShortcutAction.videoSeekForward:
        return t.shortcut_action_video_seek_forward;
      case ShortcutAction.videoToggleShaderCompare:
        return t.shortcut_action_video_toggle_shader_compare;
      case ShortcutAction.videoVolumeUp:
        return t.shortcut_action_video_volume_up;
      case ShortcutAction.videoVolumeDown:
        return t.shortcut_action_video_volume_down;
      case ShortcutAction.videoToggleMute:
        return t.shortcut_action_video_toggle_mute;
      case ShortcutAction.videoSpeedUp:
        return t.shortcut_action_video_speed_up;
      case ShortcutAction.videoSpeedDown:
        return t.shortcut_action_video_speed_down;
      case ShortcutAction.videoResetSpeed:
        return t.shortcut_action_video_reset_speed;
      case ShortcutAction.videoPreviousFrame:
        return t.shortcut_action_video_previous_frame;
      case ShortcutAction.videoNextFrame:
        return t.shortcut_action_video_next_frame;
      case ShortcutAction.videoScreenshot:
        return t.shortcut_action_video_screenshot;
      case ShortcutAction.videoToggleFullscreen:
        return t.shortcut_action_video_toggle_fullscreen;
      case ShortcutAction.videoToggleSubtitleList:
        return t.shortcut_action_video_toggle_subtitle_list;
      case ShortcutAction.videoToggleImmersiveLock:
        return t.shortcut_action_video_toggle_immersive_lock;
      case ShortcutAction.videoToggleSubtitleBlur:
        return t.shortcut_action_video_toggle_subtitle_blur;
      case ShortcutAction.videoCycleSubtitleObscure:
        return t.shortcut_action_video_cycle_subtitle_obscure;
      case ShortcutAction.videoToggleSubtitleHide:
        return t.shortcut_action_video_toggle_subtitle_hide;
      case ShortcutAction.videoCycleSecondarySubtitleObscure:
        return t.shortcut_action_video_cycle_secondary_subtitle_obscure;
      case ShortcutAction.videoToggleSecondarySubtitleHide:
        return t.shortcut_action_video_toggle_secondary_subtitle_hide;
      case ShortcutAction.videoToggleFavoriteSentence:
        return t.shortcut_action_video_toggle_favorite_sentence;
      case ShortcutAction.videoReplayCurrentSubtitle:
        return t.shortcut_action_video_replay_current_subtitle;
      case ShortcutAction.videoReplayPreviousSubtitle:
        return t.shortcut_action_video_replay_previous_subtitle;
      case ShortcutAction.videoPreviousChapter:
        return t.shortcut_action_video_previous_chapter;
      case ShortcutAction.videoNextChapter:
        return t.shortcut_action_video_next_chapter;
      case ShortcutAction.videoOpenSubtitleAlign:
        return t.shortcut_action_video_open_subtitle_align;
      case ShortcutAction.videoSubtitleDelayIncrease:
        return t.shortcut_action_video_subtitle_delay_increase;
      case ShortcutAction.videoSubtitleDelayDecrease:
        return t.shortcut_action_video_subtitle_delay_decrease;
      case ShortcutAction.videoAlignSubtitleToPrev:
        return t.shortcut_action_video_align_subtitle_to_prev;
      case ShortcutAction.videoAlignSubtitleToNext:
        return t.shortcut_action_video_align_subtitle_to_next;
      case ShortcutAction.videoEscape:
        return t.shortcut_action_video_escape;
      case ShortcutAction.dpadUp:
        return t.shortcut_action_dpad_up;
      case ShortcutAction.dpadDown:
        return t.shortcut_action_dpad_down;
      case ShortcutAction.dpadLeft:
        return t.shortcut_action_dpad_left;
      case ShortcutAction.dpadRight:
        return t.shortcut_action_dpad_right;
      case ShortcutAction.globalExternalLookup:
        return t.shortcut_action_global_external_lookup;
      case ShortcutAction.popupNextEntry:
        return t.shortcut_action_popup_next_entry;
      case ShortcutAction.popupPrevEntry:
        return t.shortcut_action_popup_prev_entry;
    }
  }
}

/// Localised label for a [ShortcutScope].
extension ShortcutScopeLabel on ShortcutScope {
  String get label {
    switch (this) {
      case ShortcutScope.reader:
        return t.shortcut_scope_reader;
      case ShortcutScope.home:
        return t.shortcut_scope_home;
      case ShortcutScope.global:
        return t.shortcut_scope_global;
      case ShortcutScope.audiobook:
        return t.shortcut_scope_audiobook;
      case ShortcutScope.video:
        return t.shortcut_scope_video;
      case ShortcutScope.gamepad:
        return t.shortcut_scope_gamepad;
      case ShortcutScope.globalExternal:
        return t.shortcut_scope_global_external;
      case ShortcutScope.dictionaryPopup:
        return t.shortcut_scope_dictionary_popup;
    }
  }
}

/// 滚轮绑定的本地化显示名与小图标（与 [MouseBindingLabel] 同形，供设置页的
/// chip 复用）。修饰键沿用 [ModifierKey.label] 的英文缩写（Alt/Ctrl/Shift/Meta，
/// 与键盘 chip 一致），只有方向翻译成人话。
extension WheelBindingLabel on WheelBinding {
  String get label {
    final String direction = switch (this.direction) {
      WheelDirection.up => t.shortcut_wheel_up,
      WheelDirection.down => t.shortcut_wheel_down,
    };
    if (modifiers.isEmpty) return direction;
    final List<ModifierKey> sorted = modifiers.toList()
      ..sort((ModifierKey a, ModifierKey b) => a.index.compareTo(b.index));
    return '${sorted.map((ModifierKey m) => m.label).join('+')}+$direction';
  }

  IconData get icon => Icons.mouse_outlined;
}

/// TODO-1050b: 鼠标绑定的本地化显示名与小图标。
extension MouseBindingLabel on MouseBinding {
  /// DOM MouseEvent.button：1=中键/滚轮、2=右键、3=后退侧键、4=前进侧键
  /// （与 [MouseBinding] 的已知按钮表对齐）；0=左键与其它未知值兜底。
  String get label {
    switch (button) {
      case 0:
        return t.shortcut_mouse_left;
      case 1:
        return t.shortcut_mouse_middle;
      case 2:
        return t.shortcut_mouse_right;
      case 3:
        return t.shortcut_mouse_back;
      case 4:
        return t.shortcut_mouse_forward;
      default:
        return t.shortcut_mouse_button;
    }
  }

  /// 中键落在滚轮上用滚轮图标，其余用通用鼠标图标
  /// （Material 无左右键专属图标）。
  IconData get icon {
    switch (button) {
      case 1:
        return Icons.mouse_outlined;
      default:
        return Icons.mouse;
    }
  }
}
