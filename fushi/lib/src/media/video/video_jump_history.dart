import 'package:fushi/src/utils/misc/jump_history.dart';

/// 视频播放位置要挪多远才算「跳转」（进回退历史）。逐句切换、几秒的修正不算；快进
/// 快退（±N 秒）是步进，调用方根本不报。有声书的阈值已改成可设置、默认 2 分钟（反馈
/// 0AwuVqrNFn，见 `audiobook_jump_threshold.dart`）；视频这边没有对应反馈，仍是 15 秒。
const int kVideoJumpThresholdMs = 15000;

/// 同一处的判据：落点相差不到 1 秒视为同一位置（连点同一句 / 同一章不重复压栈）。
const int kVideoJumpSamePlaceMs = 1000;

/// 从 [fromMs] 跳到 [toMs] 是否算一次「非连续跳转」。出发点未知（未 load）不算。
bool isVideoPositionJump({
  required int? fromMs,
  required int toMs,
  int thresholdMs = kVideoJumpThresholdMs,
}) {
  if (fromMs == null) return false;
  return (toMs - fromMs).abs() >= thresholdMs;
}

/// [JumpHistory.isSamePlace] 的视频版本（位置 = 播放器轴毫秒）。
bool isSameVideoJumpPlace(int a, int b) =>
    (a - b).abs() < kVideoJumpSamePlaceMs;

/// 视频页的跳转历史：位置就是播放器轴毫秒。
JumpHistory<int> createVideoJumpHistory() =>
    JumpHistory<int>(isSamePlace: isSameVideoJumpPlace);

/// media_kit 进度条拖动的出发点记账。
///
/// 进度条 seek 走 fork 内部 `player.seek`，绕过 controller，宿主只拿到
/// `onSeekStart`（按下进度条）与 `onSeekEnd(target)`（落点）两个信号；而落点信号
/// 同时也被横滑 / 双击快进快退复用（相对步进，不该进历史）。判据：
/// - 只有先经过 [begin]（进度条按下）的那次落点才可能是进度条落点；
/// - 横滑 / 双击开始时 fork 会取一次相对 seek 基准（controller 的
///   `relativeSeekBaseCaptureCount` 加一）：[begin] 记下当时的计数，[commit] 时计数
///   变了就说明中间插进了一次步进（进度条按下没收尾、指针被取消），不算跳转。
class VideoSeekBarJumpTracker {
  int? _originMs;
  int _captureCountAtBegin = 0;

  /// 当前记着的进度条出发点（测试可见）。
  int? get originMs => _originMs;

  /// 进度条按下：记下出发点（未 load 时为 null，等于不记）与当时的相对基准计数。
  void begin(int? fromMs, {required int relativeBaseCaptureCount}) {
    _originMs = fromMs;
    _captureCountAtBegin = relativeBaseCaptureCount;
  }

  /// 页面换集 / 执行返回前进：作废出发点。
  void cancel() => _originMs = null;

  /// 一次外部 seek 落点：返回该被压进历史的出发点；不是进度条落点（没按下过、中间
  /// 插进了相对步进）或跨度不够时返回 null。无论结果如何都消费掉出发点。
  int? commit(int targetMs, {required int relativeBaseCaptureCount}) {
    final int? origin = _originMs;
    _originMs = null;
    if (relativeBaseCaptureCount != _captureCountAtBegin) return null;
    if (!isVideoPositionJump(fromMs: origin, toMs: targetMs)) return null;
    return origin;
  }
}
