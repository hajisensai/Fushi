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
    required this.toggleImmersiveLock,
    required this.toggleCrossSubtitleRecording,
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

  /// 翻转锁定 / 沉浸模式（TODO-101，Shift+L）。锁定后控制条按钮不再随鼠标/触摸弹出，
  /// 视频纯画面播放，但查词与快捷键仍可用；再按一次（或点常驻解锁按钮）退出。
  final VoidCallback toggleImmersiveLock;

  /// 翻转跨字幕制卡区间录制（TODO-102，R 键；参考 asbplayer）。第一次按开始记录当前
  /// 字幕作起始句并继续播放，第二次按以当前句作结束句，把区间内所有字幕文本 + 区间音频
  /// 合并到一张 Anki 卡。
  final VoidCallback toggleCrossSubtitleRecording;
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
    // Shift+L = 切换锁定 / 沉浸模式（TODO-101）。与裸 L（字幕列表）区分；锁定态
    // 下所有快捷键仍生效，故此键也用来快速解锁（常驻解锁按钮是默认退出）。
    const SingleActivator(LogicalKeyboardKey.keyL, shift: true):
        actions.toggleImmersiveLock,
    // 'R' = 翻转跨字幕制卡区间录制（TODO-102；参考 asbplayer 的录制范式）。R(ecord) 此前
    // 未绑定，不撞既有键（裸 L 字幕列表 / Shift+L 锁定 / S 截图 / C 着色器对比都另有键）。
    const SingleActivator(LogicalKeyboardKey.keyR):
        actions.toggleCrossSubtitleRecording,
    const SingleActivator(LogicalKeyboardKey.keyF): actions.toggleFullscreen,
    const SingleActivator(LogicalKeyboardKey.escape): actions.escape,
  };
}
