/// Windows「高显卡占用黑屏闪烁」运行时判据（TODO-1119 / BUG-545）。
///
/// 背景：Windows 视频渲染链（media_kit_video / ANGLE legacy shared texture，无
/// KeyedMutex）在高 GPU 负载下可能瞬时黑屏闪烁；真正的 hwdec 修复属 device-gated
/// 后续项（盲改默认值会拖慢多数 Windows 用户，违反 never-break-userspace）。本轮做
/// 运行时检测：持续采样 libmpv 的「迟到/丢弃帧」累计计数器（`vo-delayed-frame-count`
/// + `frame-drop-count`），当播放中每秒迟帧率持续超阈值达数秒时，判定为「疑似黑闪」，
/// 由播放器给出可关闭提示（每会话最多一次）。
///
/// 信号来源说明：这两个计数器经 `NativePlayer.getProperty`（`mpv_get_property`）读取，
/// **独立于 libmpv 的 msg-level 日志级别**——即使诊断探针的 log stream 卡在 error 级
/// （TODO-1232 分析所述），属性读取依然可用，故动态判据可落地。
///
/// 判据本身是**纯逻辑**（本类不依赖 Flutter / media_kit），把「疑似黑闪」从「正常播放」
/// 里独立出来靠一条规则：连续 [sustainedBadWindows] 个「坏采样窗」（该窗内迟帧率
/// >= [lateFramesPerSecondThreshold]）即触发，且整个生命周期只触发一次。阈值取保守值
/// （宁缺勿滥），暂停会重置连击并重定基线，避免暂停/换片造成的计数跳变误报。
library;

/// 一次采样的输入：libmpv 迟帧/丢帧累计计数器之和、距上次采样的毫秒数、采样时是否在
/// 播放。累计计数器（非增量）由调用方直接透传，增量与频率在 [VideoBlackFlickerDetector]
/// 内计算，便于单测喂固定序列断言。
class VideoFlickerSample {
  const VideoFlickerSample({
    required this.cumulativeLateFrames,
    required this.windowMs,
    required this.playing,
  });

  /// `vo-delayed-frame-count + frame-drop-count` 的累计值（单调不减，除非 libmpv 内部
  /// 换片重置——检测器把负增量视为 0）。
  final int cumulativeLateFrames;

  /// 距上一次采样经过的毫秒数（近似 1000ms）。<=0 时该样本只用于重定基线、不判定。
  final int windowMs;

  /// 采样时刻是否处于播放态（暂停/缓冲不计入坏窗，避免误报）。
  final bool playing;
}

/// Windows 黑闪运行时判据（纯逻辑、可单测）。喂入 [VideoFlickerSample] 序列，
/// [addSample] 在**刚刚**跨过触发条件的那一次返回 `true`（此后即使继续坏也只返回
/// `false`，保证每生命周期一次）。
class VideoBlackFlickerDetector {
  VideoBlackFlickerDetector({
    this.lateFramesPerSecondThreshold = 8,
    this.sustainedBadWindows = 3,
  })  : assert(lateFramesPerSecondThreshold > 0),
        assert(sustainedBadWindows > 0);

  /// 单个采样窗内「每秒迟帧数」触发阈值。保守默认 8/s：偶发 1~2 帧迟到属正常，持续
  /// >=8/s 才算显著卡顿/闪烁。
  final int lateFramesPerSecondThreshold;

  /// 连续多少个坏窗才触发。默认 3（约 3 秒持续），滤掉一次性 GPU 尖峰的瞬态。
  final int sustainedBadWindows;

  /// 上一次采样的累计计数器（首样本 / 暂停后为 null，只重定基线不判定）。
  int? _lastCumulative;

  /// 当前连续坏窗计数。
  int _consecutiveBadWindows = 0;

  /// 本生命周期是否已触发过（触发后永不再触发）。
  bool _fired = false;

  /// 是否已经触发过（供调用方短路，触发后可停止采样）。
  bool get hasFired => _fired;

  /// 当前连续坏窗数（测试/诊断可读）。
  int get consecutiveBadWindows => _consecutiveBadWindows;

  /// 喂入一次采样，返回本次是否**刚刚**判定为疑似黑闪（仅首次为 true）。
  bool addSample(VideoFlickerSample sample) {
    if (_fired) return false;

    // 非播放态：清零连击并重定基线（暂停期间的计数不算坏窗，恢复播放后的第一个增量
    // 也不会把「暂停跨度」误算成一瞬间的巨量迟帧）。
    if (!sample.playing) {
      _consecutiveBadWindows = 0;
      _lastCumulative = sample.cumulativeLateFrames;
      return false;
    }

    // 首样本 / 窗口非法：只记基线，不判定。
    final int? last = _lastCumulative;
    _lastCumulative = sample.cumulativeLateFrames;
    if (last == null || sample.windowMs <= 0) {
      return false;
    }

    // 增量（libmpv 换片重置导致的负值按 0 处理）。
    final int delta = sample.cumulativeLateFrames - last;
    final int lateFrames = delta > 0 ? delta : 0;
    final double ratePerSecond = lateFrames * 1000.0 / sample.windowMs;

    if (ratePerSecond >= lateFramesPerSecondThreshold) {
      _consecutiveBadWindows++;
    } else {
      _consecutiveBadWindows = 0;
    }

    if (_consecutiveBadWindows >= sustainedBadWindows) {
      _fired = true;
      return true;
    }
    return false;
  }

  /// 换片/重载时复位（清基线与连击，但**不**清 [_fired]——每会话一次由调用方的会话级
  /// 标志与本标志共同保证；若希望换片后可再次触发，调用方另建实例即可）。
  void resetWindows() {
    _lastCumulative = null;
    _consecutiveBadWindows = 0;
  }
}
