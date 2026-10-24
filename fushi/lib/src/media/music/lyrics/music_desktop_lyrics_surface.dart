/// 音乐桌面歌词的真实窗口：复用有声书的原生悬浮字幕窗（Android 系统 overlay
/// `FloatingLyricService` / Windows 置顶分层窗 `floating_lyric_window.cpp`：置顶、可穿透、
/// 不抢前台），同一条 `FloatingLyricChannel` 契约。音乐与有声书同一时刻只有一方持有它
/// （[MusicLyricsLive] 按媒体会话归属让出 / 拿回）。
library;

import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/audiobook/floating_lyric_channel.dart';
import 'package:fushi/src/media/audiobook/audiobook_session.dart'
    show FloatingLyricStyle;
import 'package:fushi/src/media/music/lyrics/music_lyrics_live.dart';

class FloatingLyricMusicSurface implements MusicDesktopLyricsSurface {
  FloatingLyricMusicSurface({
    required this.style,
    required this.clickLookup,
    required this.windowRect,
    required this.onLookup,
    required this.onPlayPause,
    required this.onPrevious,
    required this.onNext,
    required this.onClose,
    this.onBoundsChanged,
  });

  final FloatingLyricStyle Function() style;
  final bool Function() clickLookup;
  final FloatingLyricWindowRect? Function() windowRect;
  final void Function(String text, int index, Rect? wordRect) onLookup;
  final VoidCallback onPlayPause;
  final VoidCallback onPrevious;
  final VoidCallback onNext;

  /// 用户点了窗口上的关闭：调用方把「桌面歌词」设置关掉。
  final VoidCallback onClose;
  final void Function(FloatingLyricWindowRect rect)? onBoundsChanged;

  @override
  bool get isSupported => FloatingLyricChannel.supported;

  @override
  Future<bool> show() async {
    if (!await FloatingLyricChannel.canDrawOverlays()) return false;
    final FloatingLyricStyle s = style();
    final bool shown = await FloatingLyricChannel.show(
      fontSize: s.fontSize,
      textColor: s.textColor,
      bgColor: s.bgColor,
      buttonTextColor: s.buttonTextColor,
      buttonBgColor: s.buttonBgColor,
      highlightColor: s.highlightColor,
      activeColor: s.activeColor,
      cornerRadius: s.cornerRadius,
      windowWidth: s.windowWidth,
      clickLookupEnabled: clickLookup(),
      // 槽位顺序与原生 kAudiobookSlotActions 同（上一句 / 播放暂停 / 下一句 / 锁定 /
      // 置顶 / 关闭）；音乐里「上一句 / 下一句」是上一首 / 下一首。
      slotTooltips: <String>[
        t.shortcut_action_music_previous_track,
        t.shortcut_action_music_toggle_play_pause,
        t.shortcut_action_music_next_track,
        t.floating_lyric_lock,
        t.floating_lyric_topmost,
        t.floating_lyric_close,
      ],
      rect: windowRect(),
      styleExtras: s.nativeStyleArgs,
    );
    if (!shown) return false;
    await FloatingLyricChannel.updateLabels(
      previous: t.shortcut_action_music_previous_track,
      playPause: t.shortcut_action_music_toggle_play_pause,
      next: t.shortcut_action_music_next_track,
      lock: t.floating_lyric_lock,
      unlock: t.floating_lyric_unlock,
      close: t.floating_lyric_close,
    );
    FloatingLyricChannel.setEventHandlers(
      onLookupText: onLookup,
      onPlayPause: onPlayPause,
      onPreviousCue: onPrevious,
      onNextCue: onNext,
      onClose: onClose,
      onBoundsChanged: (int left, int top, int width, int height) {
        final FloatingLyricWindowRect rect = FloatingLyricWindowRect(
          left: left,
          top: top,
          width: width,
          height: height,
        );
        if (rect.isValid) onBoundsChanged?.call(rect);
      },
    );
    return true;
  }

  @override
  Future<void> hide() async {
    FloatingLyricChannel.clearEventHandlers();
    await FloatingLyricChannel.hide();
  }

  @override
  Future<void> showBlock(String text, int currentStart, int currentLength) =>
      FloatingLyricChannel.updateText(
        text,
        currentLineStart: currentStart,
        currentLineLength: currentLength,
      );

  @override
  Future<void> highlight(int start, int length) =>
      FloatingLyricChannel.highlight(start: start, length: length);

  @override
  Future<void> setPlaying(bool playing) =>
      FloatingLyricChannel.setPlaybackState(playing: playing);
}
