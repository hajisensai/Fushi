/// 查词关弹窗后「恢复播放」在途期间的按住窗口何时结束。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

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
