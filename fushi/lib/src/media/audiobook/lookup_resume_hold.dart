/// 查词关弹窗后「恢复播放」：从哪里恢复，以及恢复在途期间的按住窗口何时结束。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:fushi_audio/fushi_audio.dart' show AudioCue;

/// 查词暂停后关弹窗：要从哪一句的句首重播。返回 null 表示照旧原地 `play()`。
///
/// - [restartEnabled]：用户开了「查词后从句首重播」；
/// - [alreadyPlaying]：关弹窗时播放器已经在播（用户在弹窗里按过播放 / 「从此句播放」），
///   不再二次跳句，免得把用户自己选的位置拽回去；
/// - [lookupCue]：被查词所在的句（点在哪句就重播哪句，哪怕那句早已播完）；
/// - [currentCue]：查不到被查词所在句时退回暂停那一刻正在播的句。
AudioCue? lookupRestartCue({
  required bool restartEnabled,
  required bool alreadyPlaying,
  required AudioCue? lookupCue,
  required AudioCue? currentCue,
}) {
  if (!restartEnabled || alreadyPlaying) return null;
  return lookupCue ?? currentCue;
}

/// 查词暂停后恢复播放：按住（`playbackHeldForLookup`）该在什么时候撤掉。
///
/// 关查词弹窗时阅读器调 `play()` 恢复有声书。激活是异步的（等载入、排队在激活串行尾
/// 之后、再等平台起播），这段间隙里播放器「还没在播」，覆盖层若此时把它当成用户暂停就会
/// 复位底栏并重排（awLXfD49Ep），所以要继续算按住。
///
/// 按住只覆盖**起播之前**这一段：返回的 Future 在下面两者之一先发生时完成——
/// - [playback] 通知、且 [isPlaying] 读到 true（播放器真的起播了）；
/// - [resume]（刚刚调用 `play()` 返回的 Future）完成或失败：激活被拒 / 已请求停止
///   等情形下根本不会起播，不能让按住悬着。
///
/// 不能只等 [resume]：just_audio 的 `play()` 在 Android / Darwin 后端要挂到下一次
/// pause / stop / 播完才完成（见 `playActivationSettled`），只等它会把恢复后的整段
/// 正常播放都误记成「被查词按住」。
///
/// [resume] 的错误在这里只用来结束按住，不吞也不转发：调用方仍应自行处理它。
Future<void> lookupResumeHoldReleased({
  required Listenable playback,
  required bool Function() isPlaying,
  required Future<void> resume,
}) {
  final Completer<void> released = Completer<void>();
  void release() {
    if (!released.isCompleted) released.complete();
  }

  void onPlayback() {
    if (isPlaying()) release();
  }

  playback.addListener(onPlayback);
  resume.then<void>(
    (_) => release(),
    onError: (Object _, StackTrace __) => release(),
  );
  // 调用时就已在播（别处抢先起播）：不必再按住。
  if (isPlaying()) release();
  return released.future.whenComplete(
    () => playback.removeListener(onPlayback),
  );
}
