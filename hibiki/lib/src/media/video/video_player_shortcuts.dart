import 'package:flutter/widgets.dart';

import 'package:hibiki/src/shortcuts/shortcut_action.dart';
import 'package:hibiki/src/shortcuts/shortcut_registry.dart';

class VideoPlayerShortcutActions {
  const VideoPlayerShortcutActions({
    required this.togglePlayPause,
    required this.play,
    required this.pause,
    required this.previousSubtitle,
    required this.nextSubtitle,
    required this.seekBackward,
    required this.seekForward,
    required this.toggleShaderCompare,
    required this.volumeUp,
    required this.volumeDown,
    required this.toggleMute,
    required this.speedUp,
    required this.speedDown,
    required this.resetSpeed,
    required this.previousFrame,
    required this.nextFrame,
    required this.screenshot,
    required this.toggleFullscreen,
    required this.toggleSubtitleList,
    required this.toggleImmersiveLock,
    required this.toggleSubtitleBlur,
    required this.toggleFavoriteSentence,
    required this.replayCurrentSubtitle,
    required this.replayPreviousSubtitle,
    required this.showFavoriteSentences,
    required this.previousChapter,
    required this.nextChapter,
    required this.escape,
  });

  final VoidCallback togglePlayPause;
  final VoidCallback play;
  final VoidCallback pause;
  final VoidCallback previousSubtitle;
  final VoidCallback nextSubtitle;
  final VoidCallback seekBackward;
  final VoidCallback seekForward;
  final VoidCallback toggleShaderCompare;
  final VoidCallback volumeUp;
  final VoidCallback volumeDown;
  final VoidCallback toggleMute;
  final VoidCallback speedUp;
  final VoidCallback speedDown;
  final VoidCallback resetSpeed;
  final VoidCallback previousFrame;
  final VoidCallback nextFrame;
  final VoidCallback screenshot;
  final VoidCallback toggleFullscreen;

  /// 打开/关闭字幕跳转列表面板（TODO-069，默认裸 L 键；asbplayer 式 transcript 列表）。
  final VoidCallback toggleSubtitleList;

  /// 翻转锁定 / 沉浸模式（TODO-101，默认 Shift+L）。锁定后控制条按钮不再随鼠标/触摸弹出，
  /// 视频纯画面播放，但查词与快捷键仍可用；再按一次（或点常驻解锁按钮）退出。
  final VoidCallback toggleImmersiveLock;

  /// 翻转字幕模糊（默认 B 键，asbplayer 同款）。原本挂在 video 本体内层独立
  /// CallbackShortcuts，TODO-134 起并入可重映射注册表，与其它视频键统一。
  final VoidCallback toggleSubtitleBlur;

  final VoidCallback toggleFavoriteSentence;
  final VoidCallback replayCurrentSubtitle;

  /// 重播上一句（TODO-378，BUG-287）：纯句子跳转到上一条 cue 起点并播放，不退化回退。
  final VoidCallback replayPreviousSubtitle;
  final VoidCallback showFavoriteSentences;

  /// 内封章节上/下一章（TODO-424）：seek 到相邻章起点，无章节时 no-op。
  final VoidCallback previousChapter;
  final VoidCallback nextChapter;

  final VoidCallback escape;
}

/// Maps each video [ShortcutAction] to the callback that runs it. This is the
/// single fixed wiring between the (remappable) registry actions and the
/// concrete player operations; the keys themselves come from the registry so
/// users can rebind them (TODO-134).
Map<ShortcutAction, VoidCallback> videoActionCallbacks(
  VideoPlayerShortcutActions actions,
) {
  return <ShortcutAction, VoidCallback>{
    ShortcutAction.videoTogglePlayPause: actions.togglePlayPause,
    ShortcutAction.videoPlay: actions.play,
    ShortcutAction.videoPause: actions.pause,
    ShortcutAction.videoPreviousSubtitle: actions.previousSubtitle,
    ShortcutAction.videoNextSubtitle: actions.nextSubtitle,
    ShortcutAction.videoSeekBackward: actions.seekBackward,
    ShortcutAction.videoSeekForward: actions.seekForward,
    ShortcutAction.videoToggleShaderCompare: actions.toggleShaderCompare,
    ShortcutAction.videoVolumeUp: actions.volumeUp,
    ShortcutAction.videoVolumeDown: actions.volumeDown,
    ShortcutAction.videoToggleMute: actions.toggleMute,
    ShortcutAction.videoSpeedUp: actions.speedUp,
    ShortcutAction.videoSpeedDown: actions.speedDown,
    ShortcutAction.videoResetSpeed: actions.resetSpeed,
    ShortcutAction.videoPreviousFrame: actions.previousFrame,
    ShortcutAction.videoNextFrame: actions.nextFrame,
    ShortcutAction.videoScreenshot: actions.screenshot,
    ShortcutAction.videoToggleFullscreen: actions.toggleFullscreen,
    ShortcutAction.videoToggleSubtitleList: actions.toggleSubtitleList,
    ShortcutAction.videoToggleImmersiveLock: actions.toggleImmersiveLock,
    ShortcutAction.videoToggleSubtitleBlur: actions.toggleSubtitleBlur,
    ShortcutAction.videoToggleFavoriteSentence: actions.toggleFavoriteSentence,
    ShortcutAction.videoReplayCurrentSubtitle: actions.replayCurrentSubtitle,
    ShortcutAction.videoReplayPreviousSubtitle: actions.replayPreviousSubtitle,
    ShortcutAction.videoShowFavoriteSentences: actions.showFavoriteSentences,
    ShortcutAction.videoPreviousChapter: actions.previousChapter,
    ShortcutAction.videoNextChapter: actions.nextChapter,
    ShortcutAction.videoEscape: actions.escape,
  };
}

/// Builds the `Map<ShortcutActivator, VoidCallback>` for the video player from
/// the live registry's video-scope bindings (TODO-134). Every keyboard binding
/// the user has mapped to a video action becomes a [SingleActivator] pointing
/// at that action's callback, so rebinding in the shortcut settings page takes
/// effect immediately. The subtitle-blur toggle stays press-edge-only
/// (includeRepeats:false) to preserve its previous non-repeating behaviour.
Map<ShortcutActivator, VoidCallback> buildVideoPlayerShortcutsFromRegistry(
  HibikiShortcutRegistry registry,
  VideoPlayerShortcutActions actions,
) {
  final Map<ShortcutAction, VoidCallback> callbacks =
      videoActionCallbacks(actions);
  final Map<ShortcutActivator, VoidCallback> result =
      <ShortcutActivator, VoidCallback>{};
  for (final MapEntry<ShortcutAction, VoidCallback> entry
      in callbacks.entries) {
    final ShortcutAction action = entry.key;
    final bool includeRepeats =
        action != ShortcutAction.videoToggleSubtitleBlur;
    for (final binding in registry.bindingsFor(action).keyboardBindings) {
      // Last writer wins if two actions share a key; the settings UI's conflict
      // check prevents users from creating that within the video scope, and the
      // defaults are collision-free.
      result[binding.toActivator(includeRepeats: includeRepeats)] = entry.value;
    }
  }
  return result;
}
