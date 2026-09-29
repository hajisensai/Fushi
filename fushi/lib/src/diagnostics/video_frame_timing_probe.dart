import 'dart:async';
import 'package:flutter/scheduler.dart';
import 'package:fushi/src/diagnostics/video_diag_log.dart';
import 'package:fushi/src/diagnostics/video_diag_stats.dart';

/// Flutter 侧帧耗时探针：视频页挂载期间订阅 [SchedulerBinding.addTimingsCallback]，
/// 每 [flushInterval] 汇总一行进 [VideoDiagLog]。
///
/// 这是「视频为什么卡顿」的**另一半**证据。libmpv 的丢帧计数只说明解码/渲染管线
/// 的状况；用户感知的卡顿还可能整个发生在 Flutter 这侧——字幕层每次 controller
/// 通知都 `_charEntries.clear()` 后逐字符重建（双语长句几十条），`\fad`/`\move`
/// 动画期还挂 ticker 逐帧空 setState，控制条又是 7 个 notifier 的 merge。这些在
/// mpv 日志里一个字都看不到，只有 `FrameTiming` 的 build 耗时看得见。
///
/// 两条线打进同一个时间轴、同一把 uptime 尺，才回答得了「这一秒是 GPU 掉帧还是 UI
/// 线程被占住」。
///
/// 只在诊断开启时接线（[start] 自己判），关掉即零开销。
class VideoFrameTimingProbe {
  VideoFrameTimingProbe({
    this.flushInterval = const Duration(seconds: 1),
    this.label = 'video',
  });

  /// 汇总节奏。与 libmpv 属性采样同为 1 秒，两行才对得上。
  final Duration flushInterval;

  /// 日志里的来源标签（视频页 / 查词期等，便于区分同一进程里的多个探针）。
  final String label;

  final VideoFrameTimingAggregator _aggregator = VideoFrameTimingAggregator();

  TimingsCallback? _callback;
  Timer? _timer;
  DateTime? _windowStartedAt;

  bool get isRunning => _callback != null;

  /// 开始采样。诊断关着、或已在跑，都直接返回（幂等）。
  void start() {
    if (_callback != null) return;
    if (!VideoDiagLog.instance.isLoggable(
      VideoDiagCategory.frame,
      VideoDiagLevel.v,
    )) {
      return;
    }
    final TimingsCallback callback = _onTimings;
    _callback = callback;
    SchedulerBinding.instance.addTimingsCallback(callback);
    _windowStartedAt = DateTime.now();
    _timer = Timer.periodic(flushInterval, (_) => _flush());
    videoDiag(
      VideoDiagCategory.frame,
      VideoDiagLevel.info,
      'probe start label=$label interval=${flushInterval.inMilliseconds}ms',
    );
  }

  /// 停止采样并把残留窗口打掉（退出视频页时别丢掉最后一秒——卡死前的最后一窗往往
  /// 正是要看的那一窗）。幂等。
  void stop() {
    final TimingsCallback? callback = _callback;
    if (callback == null) return;
    SchedulerBinding.instance.removeTimingsCallback(callback);
    _callback = null;
    _timer?.cancel();
    _timer = null;
    _flush();
    videoDiag(
      VideoDiagCategory.frame,
      VideoDiagLevel.info,
      'probe stop label=$label',
    );
    _windowStartedAt = null;
  }

  void _onTimings(List<FrameTiming> timings) {
    for (final FrameTiming t in timings) {
      _aggregator.add(
        VideoFrameSample(
          buildMicros: t.buildDuration.inMicroseconds,
          rasterMicros: t.rasterDuration.inMicroseconds,
          vsyncOverheadMicros: t.vsyncOverhead.inMicroseconds,
        ),
      );
    }
  }

  void _flush() {
    if (_aggregator.frameCount == 0) {
      _windowStartedAt = DateTime.now();
      return;
    }
    final DateTime? started = _windowStartedAt;
    final int windowMs = started == null
        ? flushInterval.inMilliseconds
        : DateTime.now().difference(started).inMilliseconds;
    _windowStartedAt = DateTime.now();
    // 先问卡不卡再汇总——[summariseAndReset] 会清空窗口。
    final bool janky = _aggregator.isJankyWindow();
    final String? line = _aggregator.summariseAndReset(windowMs);
    if (line == null) return;
    videoDiag(
      VideoDiagCategory.frame,
      janky ? VideoDiagLevel.warn : VideoDiagLevel.v,
      '$label $line',
    );
  }
}
