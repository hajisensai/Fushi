// 快捷键类型的本地化展示层（从 shortcut_settings_page.dart 抽出）。
//
// 动机：动作/作用域的显示名过去是设置页里两个 100+ 行的文件私有 switch，
// 每加一个 [ShortcutAction] 都要跨文件手工同步一次标签分支。抽成与
// shortcuts 数据层同目录的公开扩展后，加动作时标签就近可见；穷举 switch
// 保留——漏写分支直接编译失败，不需要运行时兜底。
//
// 本文件只做「类型 → 本地化文案/图标」的纯映射，不读写注册表、不触碰
// 绑定序列化。

import 'package:material_ui/material_ui.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

/// Localised label for a [ShortcutAction].
extension ShortcutActionLabel on ShortcutAction {
  String get label {
    switch (this) {
      case ShortcutAction.mangaPageForward:
        return t.shortcut_action_manga_page_forward;
      case ShortcutAction.mangaPageBackward:
        return t.shortcut_action_manga_page_backward;
      case ShortcutAction.mangaDismissDict:
        return t.shortcut_action_manga_dismiss_dict;
      case ShortcutAction.mangaToggleChrome:
        return t.shortcut_action_manga_toggle_chrome;
      case ShortcutAction.mangaPanUp:
        return t.shortcut_action_manga_pan_up;
      case ShortcutAction.mangaPanDown:
        return t.shortcut_action_manga_pan_down;
      case ShortcutAction.mangaPanLeft:
        return t.shortcut_action_manga_pan_left;
      case ShortcutAction.mangaPanRight:
        return t.shortcut_action_manga_pan_right;
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
      case ShortcutAction.readerOpenGallery:
        return t.shortcut_action_reader_open_gallery;
      case ShortcutAction.readerOpenStatistics:
        return t.shortcut_action_reader_open_statistics;
      case ShortcutAction.readerOpenAudiobook:
        return t.shortcut_action_reader_open_audiobook;
      case ShortcutAction.readerToggleStudyClock:
        return t.shortcut_action_reader_toggle_study_clock;
      case ShortcutAction.readerDismissDict:
        return t.shortcut_action_reader_dismiss_dict;
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
      case ShortcutAction.globalScrollLineDown:
        return t.shortcut_action_global_scroll_line_down;
      case ShortcutAction.globalScrollLineUp:
        return t.shortcut_action_global_scroll_line_up;
      case ShortcutAction.globalScrollToTop:
        return t.shortcut_action_global_scroll_to_top;
      case ShortcutAction.globalScrollToBottom:
        return t.shortcut_action_global_scroll_to_bottom;
      case ShortcutAction.globalToggleFullscreen:
        return t.shortcut_action_global_toggle_fullscreen;
      case ShortcutAction.globalContextMenu:
        return t.shortcut_action_global_context_menu;
      case ShortcutAction.audiobookPlayPause:
        return t.shortcut_action_audiobook_play_pause;
      case ShortcutAction.audiobookNextSentence:
        return t.shortcut_action_audiobook_next_sentence;
      case ShortcutAction.audiobookPrevSentence:
        return t.shortcut_action_audiobook_prev_sentence;
      case ShortcutAction.audiobookSeekToClickedSentence:
        return t.shortcut_action_audiobook_seek_clicked;
      case ShortcutAction.videoDismissDict:
        return t.shortcut_action_video_dismiss_dict;
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
      case ShortcutAction.videoHoldSpeed:
        return t.shortcut_action_video_hold_speed;
      case ShortcutAction.videoPreviousFrame:
        return t.shortcut_action_video_previous_frame;
      case ShortcutAction.videoNextFrame:
        return t.shortcut_action_video_next_frame;
      case ShortcutAction.videoScreenshot:
        return t.shortcut_action_video_screenshot;
      case ShortcutAction.videoScreenshotSubtitled:
        return t.shortcut_action_video_screenshot_subtitled;
      case ShortcutAction.videoToggleFullscreen:
        return t.shortcut_action_video_toggle_fullscreen;
      case ShortcutAction.videoToggleMiniWindow:
        return t.shortcut_action_video_toggle_mini_window;
      case ShortcutAction.videoToggleMiniChrome:
        return t.shortcut_action_video_toggle_mini_chrome;
      case ShortcutAction.videoToggleSubtitleList:
        return t.shortcut_action_video_toggle_subtitle_list;
      case ShortcutAction.videoSearchSubtitleList:
        return t.shortcut_action_video_search_subtitle_list;
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
      case ShortcutAction.videoEnterCaret:
        return t.shortcut_action_video_enter_caret;
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
      case ShortcutAction.globalExternalOpenLookupPage:
        return t.shortcut_action_global_external_open_lookup_page;
      case ShortcutAction.popupNextEntry:
        return t.shortcut_action_popup_next_entry;
      case ShortcutAction.popupPrevEntry:
        return t.shortcut_action_popup_prev_entry;
      case ShortcutAction.popupMineEntry:
        return t.shortcut_action_popup_mine_entry;
      case ShortcutAction.popupPlayAudio:
        return t.shortcut_action_popup_play_audio;
    }
  }
}

/// 按钮 / 菜单文案后缀快捷键提示（`插图画廊 · G`）。只在 [keyboardHints] 为 true
/// （桌面：键盘是常规输入）时追加；触屏平台（Android / iOS）不挂——手机、平板上
/// 菜单里写「有声书 · B」是噪声（BUG-2960）。键名走 [InputBinding.displayLabel]，
/// 不用持久化 token（`Ctrl+KeyF`）。
String labelWithShortcutHint(
  String label,
  List<InputBinding> keyboardBindings, {
  required bool keyboardHints,
}) {
  if (!keyboardHints || keyboardBindings.isEmpty) return label;
  return '$label · ${keyboardBindings.first.displayLabel}';
}

/// 工具栏按钮的 tooltip 文案：功能名后括注快捷键（`导航 (Ctrl+F)`）。可见标签只放
/// 功能名，快捷键挪进 tooltip——窄窗下 `导航 · Ctrl+F` 这种拼接会把底栏标签挤成
/// 截断的乱码。触屏平台同 [labelWithShortcutHint] 不挂。
String tooltipWithShortcutHint(
  String label,
  List<InputBinding> keyboardBindings, {
  required bool keyboardHints,
}) {
  if (!keyboardHints || keyboardBindings.isEmpty) return label;
  return '$label (${keyboardBindings.first.displayLabel})';
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
      case ShortcutScope.universal:
        return t.shortcut_scope_universal;
      case ShortcutScope.audiobook:
        return t.shortcut_scope_audiobook;
      case ShortcutScope.video:
        return t.shortcut_scope_video;
      case ShortcutScope.manga:
        return t.shortcut_scope_manga;
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

  IconData get icon => FushiIcons.mouse;
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
        return FushiIcons.mouse;
      default:
        return FushiIcons.mouse;
    }
  }
}

/// 动作的按钮图标（视频页「快捷键 1..4」自定义按钮用）。
///
/// 为什么返回可空、而不是像同文件其它 switch 那样穷举全部动作：能被绑到屏幕按钮上的
/// 只有视频页真正能执行的那批动作（`videoActionCallbacks` 的 keys），给阅读器 / 漫画 /
/// 首页那些永远绑不上的动作硬凑图标是纯噪声。null = 没有专属图标，由调用方兜底。
///
/// ⚠️ 这里有 default 分支，漏配图标**不会**编译失败，所以由守卫测试
/// `video_custom_action_bindings_test` 反向兜住：`videoActionCallbacks` 的每一个 key
/// 都必须在这里拿到非 null 图标，新增视频动作时忘了配图标即测试红。否则用户会看到一个
/// 没有语义的通用按钮，而「按钮长成它绑的那个动作」正是这个功能的设计承诺。
extension ShortcutActionIcon on ShortcutAction {
  IconData? get buttonIcon {
    switch (this) {
      // 播放控制
      case ShortcutAction.videoTogglePlayPause:
        return FushiIcons.play;
      case ShortcutAction.videoPlay:
        return FushiIcons.playCircle;
      case ShortcutAction.videoPause:
        return FushiIcons.pauseCircle;
      case ShortcutAction.videoSeekBackward:
        return FushiIcons.fastRewind;
      case ShortcutAction.videoSeekForward:
        return FushiIcons.fastForward;
      case ShortcutAction.videoPreviousFrame:
        return FushiIcons.stepBackward;
      case ShortcutAction.videoNextFrame:
        return FushiIcons.stepForward;

      // 倍速
      case ShortcutAction.videoSpeedUp:
        return FushiIcons.speed;
      case ShortcutAction.videoSpeedDown:
        return FushiIcons.slowMotion;
      case ShortcutAction.videoResetSpeed:
        return FushiIcons.restart;
      case ShortcutAction.videoHoldSpeed:
        return FushiIcons.fastForward;

      // 字幕跳转 / 重播
      case ShortcutAction.videoPreviousSubtitle:
        return FushiIcons.skipPrevious;
      case ShortcutAction.videoNextSubtitle:
        return FushiIcons.skipNext;
      case ShortcutAction.videoReplayCurrentSubtitle:
        return FushiIcons.replay;
      case ShortcutAction.videoReplayPreviousSubtitle:
        return FushiIcons.replay5;

      // 章节
      case ShortcutAction.videoPreviousChapter:
        return FushiIcons.firstPage;
      case ShortcutAction.videoNextChapter:
        return FushiIcons.lastPage;

      // 字幕显示 / 遮蔽
      case ShortcutAction.videoToggleSubtitleList:
        return FushiIcons.listView;
      case ShortcutAction.videoSearchSubtitleList:
        return FushiIcons.search;
      case ShortcutAction.videoToggleSubtitleBlur:
        return FushiIcons.blur;
      case ShortcutAction.videoCycleSubtitleObscure:
        return FushiIcons.visibilityOff;
      case ShortcutAction.videoToggleSubtitleHide:
        return FushiIcons.subtitlesOff;
      case ShortcutAction.videoCycleSecondarySubtitleObscure:
        return FushiIcons.blurLinear;
      case ShortcutAction.videoToggleSecondarySubtitleHide:
        return FushiIcons.captionsOff;

      // 字幕对轴
      case ShortcutAction.videoOpenSubtitleAlign:
        return FushiIcons.audio;
      case ShortcutAction.videoSubtitleDelayIncrease:
        return FushiIcons.moreTime;
      case ShortcutAction.videoSubtitleDelayDecrease:
        return FushiIcons.history;
      case ShortcutAction.videoAlignSubtitleToPrev:
        return FushiIcons.alignLeft;
      case ShortcutAction.videoAlignSubtitleToNext:
        return FushiIcons.alignRight;

      // 音量
      case ShortcutAction.videoVolumeUp:
        return FushiIcons.volumeUp;
      case ShortcutAction.videoVolumeDown:
        return FushiIcons.volumeDown;
      case ShortcutAction.videoToggleMute:
        return FushiIcons.volumeOff;

      // 画面 / 杂项
      case ShortcutAction.videoToggleFullscreen:
        return FushiIcons.fullscreen;
      case ShortcutAction.videoToggleMiniWindow:
        return FushiIcons.pictureInPicture;
      case ShortcutAction.videoToggleMiniChrome:
        return FushiIcons.settings;
      case ShortcutAction.videoScreenshot:
        return FushiIcons.camera;
      case ShortcutAction.videoScreenshotSubtitled:
        return FushiIcons.subtitles;
      case ShortcutAction.videoToggleShaderCompare:
        return FushiIcons.compare;
      case ShortcutAction.videoToggleImmersiveLock:
        return FushiIcons.lock;

      // 学习
      case ShortcutAction.videoToggleFavoriteSentence:
        return FushiIcons.star;
      case ShortcutAction.videoEnterCaret:
        return FushiIcons.textFields;

      // 全 app 共用「返回上一级」：视频页把它解释成逐级退出阶梯。
      case ShortcutAction.globalBack:
        return FushiIcons.back;

      // 全 app 共用全屏键（F11）：视频页把它接成与 F / 双击同一个视频全屏（BUG-2462）。
      case ShortcutAction.globalToggleFullscreen:
        return FushiIcons.fullscreen;

      // 右键菜单（按钮归属声明，执行体在各卡片 / 各媒体表面自己的 showMenu）。
      case ShortcutAction.globalContextMenu:
        return FushiIcons.menu;

      // ignore: no_default_cases
      default:
        return null;
    }
  }
}
