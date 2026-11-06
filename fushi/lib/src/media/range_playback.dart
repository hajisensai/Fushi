import 'dart:async';

/// 一次区间播放（「只播 [start, end) 这一段」）是怎么结束的。
enum RangePlaybackEnd {
  /// 播到了区间终点（或媒体在终点前自然播完）。
  reachedEnd,

  /// 没播完就被放弃：显式停止、用户 seek / 换片、被下一次区间播放顶掉、播放器销毁。
  interrupted,
}

/// 一次区间播放的结果句柄（FDN66-xurt）。
///
/// 播放器（`VideoPlayerController.playRangeMs` / `AudiobookPlayerController.playRange`）
/// 起播一段区间后交回它；[ended] 在这段**播完或被打断**时完成，且只完成一次。调用方据此
/// 复位自己的「正在试听」状态，而不是只在起播失败 / 显式停止时复位——否则一段播完后
/// 按钮还停在「停止」，下一次点击只会去停一段早已结束的播放。
///
/// 结束判定只由播放器在真实的终点 / 打断事件上调 [finish]，**不**按时长估算。
class RangePlayback {
  RangePlayback();

  /// 一个已经结束的句柄（空区间等「没有可播的」情形）。
  RangePlayback.ended(RangePlaybackEnd reason) {
    finish(reason);
  }

  final Completer<RangePlaybackEnd> _ended = Completer<RangePlaybackEnd>();

  /// 这段播完 / 被打断时完成。
  Future<RangePlaybackEnd> get ended => _ended.future;

  /// 是否已结束。
  bool get isEnded => _ended.isCompleted;

  /// 由播放器在终点 / 打断时调用；重复调用无效（首个原因为准）。
  void finish(RangePlaybackEnd reason) {
    if (!_ended.isCompleted) _ended.complete(reason);
  }
}
