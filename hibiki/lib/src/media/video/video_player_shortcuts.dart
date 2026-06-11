import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

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

  /// 打开/关闭字幕跳转列表面板（TODO-069，裸 L 键；asbplayer 式 transcript 列表）。
  final VoidCallback toggleSubtitleList;
  final VoidCallback escape;
}

Map<ShortcutActivator, VoidCallback> buildVideoPlayerShortcuts(
  VideoPlayerShortcutActions actions,
) {
  return <ShortcutActivator, VoidCallback>{
    const SingleActivator(LogicalKeyboardKey.space): actions.togglePlayPause,
    const SingleActivator(LogicalKeyboardKey.keyP): actions.togglePlayPause,
    const SingleActivator(LogicalKeyboardKey.mediaPlay): actions.play,
    const SingleActivator(LogicalKeyboardKey.mediaPause): actions.pause,
    const SingleActivator(LogicalKeyboardKey.mediaPlayPause):
        actions.togglePlayPause,
    // TODO-090：普通 ←/→ = 时间 seek（±seekSeconds 秒）；Ctrl+←/→ = 上/下一句字幕。
    // 与 asbplayer 习惯一致：裸方向键管「快进快退」，Ctrl 管「按字幕跳句」。
    const SingleActivator(LogicalKeyboardKey.arrowLeft): actions.seekBackward,
    const SingleActivator(LogicalKeyboardKey.arrowRight): actions.seekForward,
    const SingleActivator(LogicalKeyboardKey.arrowLeft, control: true):
        actions.previousSubtitle,
    const SingleActivator(LogicalKeyboardKey.arrowRight, control: true):
        actions.nextSubtitle,
    const SingleActivator(LogicalKeyboardKey.keyA): actions.seekBackward,
    const SingleActivator(LogicalKeyboardKey.keyD): actions.seekForward,
    const SingleActivator(
      LogicalKeyboardKey.keyF,
      shift: true,
    ): actions.seekForward,
    const SingleActivator(LogicalKeyboardKey.keyC): actions.toggleShaderCompare,
    const SingleActivator(LogicalKeyboardKey.keyJ): actions.seekBackward,
    const SingleActivator(LogicalKeyboardKey.keyI): actions.seekForward,
    const SingleActivator(LogicalKeyboardKey.arrowUp): actions.volumeUp,
    const SingleActivator(LogicalKeyboardKey.digit0): actions.volumeUp,
    const SingleActivator(LogicalKeyboardKey.arrowDown): actions.volumeDown,
    const SingleActivator(LogicalKeyboardKey.digit9): actions.volumeDown,
    const SingleActivator(LogicalKeyboardKey.keyM): actions.toggleMute,
    const SingleActivator(LogicalKeyboardKey.bracketLeft): actions.speedDown,
    const SingleActivator(LogicalKeyboardKey.minus): actions.speedDown,
    const SingleActivator(LogicalKeyboardKey.bracketRight): actions.speedUp,
    const SingleActivator(LogicalKeyboardKey.equal): actions.speedUp,
    const SingleActivator(LogicalKeyboardKey.backspace): actions.resetSpeed,
    const SingleActivator(LogicalKeyboardKey.comma): actions.previousFrame,
    const SingleActivator(LogicalKeyboardKey.period): actions.nextFrame,
    const SingleActivator(LogicalKeyboardKey.keyS): actions.screenshot,
    // 'L' = 打开/关闭字幕跳转列表（TODO-069；asbplayer 式 transcript 面板，按一下右侧
    // 出现字幕句子列表，点句跳到对应画面）。未与既有键冲突（裸 L 此前未绑定）。
    const SingleActivator(LogicalKeyboardKey.keyL): actions.toggleSubtitleList,
    const SingleActivator(LogicalKeyboardKey.keyF): actions.toggleFullscreen,
    const SingleActivator(LogicalKeyboardKey.escape): actions.escape,
  };
}
