/// 音乐模块的键盘 / 鼠标派发（[ShortcutScope.music]）：曲库页与歌词页共用一份执行体，
/// 两处按键行为一致（用户 2026-11-02「不要做成不同模块交互方式都不一样」）。
library;

import 'dart:async';

import 'package:flutter/services.dart' hide ModifierKey;
import 'package:flutter/widgets.dart' show KeyEventResult;

import 'package:fushi/src/media/audiobook/pointer_seek.dart'
    show isSeekToClickedSentenceButton;
import 'package:fushi/src/media/music/music_player_engine.dart';
import 'package:fushi/src/shortcuts/gamepad_service.dart'
    show focusedEditableText;
import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/shortcuts/shortcut_registry.dart';

/// 把按键按 [ShortcutScope.music] 解析成的动作交给引擎。返回是否消费。纯逻辑（不依赖
/// 页面状态），单测直接喂动作。
bool dispatchMusicShortcut(ShortcutAction? action, MusicPlayerEngine engine) {
  switch (action) {
    case ShortcutAction.musicTogglePlayPause:
      if (!engine.isActive) return false;
      unawaited(engine.togglePlayPause());
      return true;
    case ShortcutAction.musicNextTrack:
      if (!engine.isActive) return false;
      unawaited(engine.skipNext());
      return true;
    case ShortcutAction.musicPreviousTrack:
      if (!engine.isActive) return false;
      unawaited(engine.skipPrevious());
      return true;
    case ShortcutAction.musicSeekForward:
      if (!engine.isActive) return false;
      unawaited(engine.seekRelative(const Duration(seconds: 5)));
      return true;
    case ShortcutAction.musicSeekBackward:
      if (!engine.isActive) return false;
      unawaited(engine.seekRelative(const Duration(seconds: -5)));
      return true;
    default:
      return false;
  }
}

/// 音乐页键事件节点的 `onKeyEvent` 本体：按 [ShortcutScope.music] 解析后派发。
///
/// 文本框持焦时一律让路：空格 / 字母键是在打字，不是播放控制（[editableFocused] 缺省
/// 读当前主焦点，测试可注入）。
KeyEventResult handleMusicShortcutKey(
  KeyEvent event, {
  required FushiShortcutRegistry registry,
  required MusicPlayerEngine engine,
  bool Function()? editableFocused,
}) {
  if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
    return KeyEventResult.ignored;
  }
  if ((editableFocused ?? () => focusedEditableText() != null)()) {
    return KeyEventResult.ignored;
  }
  final Set<ModifierKey> modifiers = <ModifierKey>{
    if (HardwareKeyboard.instance.isControlPressed) ModifierKey.ctrl,
    if (HardwareKeyboard.instance.isShiftPressed) ModifierKey.shift,
    if (HardwareKeyboard.instance.isAltPressed) ModifierKey.alt,
    if (HardwareKeyboard.instance.isMetaPressed) ModifierKey.meta,
  };
  final ShortcutAction? action = registry.resolveKeyboard(
    event.logicalKey,
    modifiers: modifiers,
    scope: ShortcutScope.music,
  );
  return dispatchMusicShortcut(action, engine)
      ? KeyEventResult.handled
      : KeyEventResult.ignored;
}

/// 歌词行上的鼠标键是不是「跳到点中的这一句」：与有声书歌词模式 / 阅读器**同一个**
/// 绑定项（设置里只有一处可改，默认中键）。[buttons] 是 Flutter 指针的按钮位掩码。
bool isMusicLyricsSeekPointer(FushiShortcutRegistry registry, int buttons) {
  final int? button = domMouseButtonFromPointerButtons(buttons);
  return button != null && isSeekToClickedSentenceButton(registry, button);
}
