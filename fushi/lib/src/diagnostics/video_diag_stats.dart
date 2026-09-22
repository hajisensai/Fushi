/// 视频诊断的两类**纯**聚合器：libmpv 属性周期快照（[VideoMpvStatsSnapshot]）与
/// Flutter 帧耗时聚合（[VideoFrameTimingAggregator]）。
///
/// 刻意不依赖 `media_kit` / `dart:ui`：读属性与拿 `FrameTiming` 的副作用留在调用
/// 方（`VideoPlayerController` / `VideoFrameTimingProbe`），这里只做「一串数字 →
/// 一行人能读的日志」。卡顿判据以后要调阈值，改的是这里的纯函数，单测直接喂序列。
library;

import 'dart:math' as math;

/// libmpv 属性的一次快照，字段选择对齐 mpv `stats.lua` 第 1 页 + 帧计时页里真正
/// 能解释卡顿的那些。累计计数器原样存（增量在 [describeSince] 里算），瞬时量直接存。
///
/// 全部 nullable：属性不可读（后端不是 libmpv、媒体还没打开、mpv 版本没这个属性）
/// 时按 null 处理并在输出里写 `-`，**绝不**拿 0 冒充——「读不到」和「真是 0」在排查
/// 丢帧时是完全相反的结论。
class VideoMpvStatsSnapshot {
  const VideoMpvStatsSnapshot({
    this.voDelayedFrames,
    this.voDroppedFrames,
    this.decoderDroppedFrames,
    this.avsync,
    this.demuxerCacheSeconds,
    this.cacheSpeedBytesPerSecond,
    this.videoBitrate,
    this.audioBitrate,
    this.estimatedVfFps,
    this.containerFps,
    this.estimatedDisplayFps,
    this.hwdec,
    this.currentVo,
    this.videoWidth,
    this.videoHeight,
    this.pixelFormat,
    this.pausedForCache,
  });

  /// 累计「迟到帧」（`vo-delayed-frame-count`）。
  final int? voDelayedFrames;

  /// 累计 VO 丢帧（`frame-drop-count`）——渲染跟不上。
  final int? voDroppedFrames;

  /// 累计解码器丢帧（`decoder-frame-drop-count`）——解码跟不上，与 VO 丢帧是两种
  /// 不同的卡顿，必须分开看。
  final int? decoderDroppedFrames;

  /// 音视频不同步秒数（`avsync`）。
  final double? avsync;

  /// demuxer 缓存时长（`demuxer-cache-duration`，秒）。网络源卡顿先看它。
  final double? demuxerCacheSeconds;

  /// 缓存填充速度（`cache-speed`，字节/秒）。
  final int? cacheSpeedBytesPerSecond;

  final int? videoBitrate;
  final int? audioBitrate;

  /// 实测视频滤镜链输出帧率（`estimated-vf-fps`）——低于 [containerFps] 即掉帧。
  final double? estimatedVfFps;

  /// 容器标称帧率（`container-fps`）。
  final double? containerFps;

  /// 实测显示刷新率（`estimated-display-fps`）。
  final double? estimatedDisplayFps;

  /// 当前硬解（`hwdec-current`），`no` 表示软解。
  final String? hwdec;

  /// 当前视频输出（`current-vo`）。
  final String? currentVo;

  final int? videoWidth;
  final int? videoHeight;
  final String? pixelFormat;

  /// 是否因缓存不足而暂停（`paused-for-cache`）——卡顿是「等数据」还是「算不过来」
  /// 的分水岭。
  final bool? pausedForCache;

  /// 从一张 `属性名 → 原始值` 表解析（调用方逐个 `getProperty` 后塞进来，读失败的
  /// 键直接不放进表即可）。任何解析不了的值落 null，不抛。
  factory VideoMpvStatsSnapshot.fromProperties(Map<String, Object?> raw) {
    return VideoMpvStatsSnapshot(
      voDelayedFrames: parseInt(raw['vo-delayed-frame-count']),
      voDroppedFrames: parseInt(raw['frame-drop-count']),
      decoderDroppedFrames: parseInt(raw['decoder-frame-drop-count']),
      avsync: parseDouble(raw['avsync']),
      demuxerCacheSeconds: parseDouble(raw['demuxer-cache-duration']),
      cacheSpeedBytesPerSecond: parseInt(raw['cache-speed']),
      videoBitrate: parseInt(raw['video-bitrate']),
      audioBitrate: parseInt(raw['audio-bitrate']),
      estimatedVfFps: parseDouble(raw['estimated-vf-fps']),
      containerFps: parseDouble(raw['container-fps']),
      estimatedDisplayFps: parseDouble(raw['estimated-display-fps']),
      hwdec: parseString(raw['hwdec-current']),
      currentVo: parseString(raw['current-vo']),
      videoWidth: parseInt(raw['width']),
      videoHeight: parseInt(raw['height']),
      pixelFormat: parseString(raw['video-params/pixelformat']),
      pausedForCache: parseBool(raw['paused-for-cache']),
    );
  }

  /// libmpv 需要读的属性名清单（调用方照这个列表逐个 `getProperty`，避免两处各写
  /// 一份字符串导致漂移）。
  static const List<String> properties = <String>[
    'vo-delayed-frame-count',
    'frame-drop-count',
    'decoder-frame-drop-count',
    'avsync',
    'demuxer-cache-duration',
    'cache-speed',
    'video-bitrate',
    'audio-bitrate',
    'estimated-vf-fps',
    'container-fps',
    'estimated-display-fps',
    'hwdec-current',
    'current-vo',
    'width',
    'height',
    'video-params/pixelformat',
    'paused-for-cache',
  ];

  static int? parseInt(Object? raw) {
    if (raw == null) return null;
    if (raw is int) return raw;
    if (raw is double) return raw.isFinite ? raw.round() : null;
    final String s = raw.toString().trim();
    if (s.isEmpty) return null;
    final int? direct = int.tryParse(s);
    if (direct != null) return direct;
    final double? asDouble = double.tryParse(s);
    return (asDouble != null && asDouble.isFinite) ? asDouble.round() : null;
  }

  static double? parseDouble(Object? raw) {
    if (raw == null) return null;
    if (raw is num) return raw.isFinite ? raw.toDouble() : null;
    final String s = raw.toString().trim();
    if (s.isEmpty) return null;
    final double? v = double.tryParse(s);
    return (v != null && v.isFinite) ? v : null;
  }

  static String? parseString(Object? raw) {
    if (raw == null) return null;
    final String s = raw.toString().trim();
    if (s.isEmpty || s == 'null') return null;
    return s;
  }

  static bool? parseBool(Object? raw) {
    if (raw == null) return null;
    if (raw is bool) return raw;
    final String s = raw.toString().trim().toLowerCase();
    if (s == 'yes' || s == 'true' || s == '1') return true;
    if (s == 'no' || s == 'false' || s == '0') return false;
    return null;
  }

  /// 「静态」部分：换片 / 首次采样时打一行即可，不必每秒重复（vo / hwdec / 分辨率
  /// / 像素格式 / 容器帧率）。这些一旦变了就是重新协商过解码链，本身就是事件。
  String describeStatic() {
    return 'vo=${_s(currentVo)} hwdec=${_s(hwdec)} '
        'size=${_s(videoWidth)}x${_s(videoHeight)} pixfmt=${_s(pixelFormat)} '
        'container-fps=${_f(containerFps, 3)} '
        'display-fps=${_f(estimatedDisplayFps, 2)}';
  }

  /// 判断静态部分是否与 [other] 不同（变了才重打一行）。
  bool staticDiffersFrom(VideoMpvStatsSnapshot? other) {
    if (other == null) return true;
    return currentVo != other.currentVo ||
        hwdec != other.hwdec ||
        videoWidth != other.videoWidth ||
        videoHeight != other.videoHeight ||
        pixelFormat != other.pixelFormat ||
        containerFps != other.containerFps;
  }

  /// 相对上一次快照的一行增量描述（`previous` 为 null 时只打瞬时量，不打速率）。
  ///
  /// 三个丢帧计数器分别给「本窗增量」与「每秒速率」：`late` / `vo-drop` /
  /// `dec-drop`。libmpv 换片会把累计值清零，负增量按 0 处理（与
  /// `VideoBlackFlickerDetector` 同口径）。
  String describeSince(VideoMpvStatsSnapshot? previous, int windowMs) {
    final StringBuffer sb = StringBuffer();
    final double windowSec = windowMs > 0 ? windowMs / 1000.0 : 0;
    void rate(String label, int? cur, int? prev) {
      if (cur == null) {
        sb.write('$label=- ');
        return;
      }
      final int delta = (prev == null) ? 0 : math.max(0, cur - prev);
      if (previous == null || windowSec <= 0) {
        sb.write('$label=$cur ');
        return;
      }
      final String perSec = (delta / windowSec).toStringAsFixed(1);
      sb.write('$label=+$delta($perSec/s,tot=$cur) ');
    }

    rate('late', voDelayedFrames, previous?.voDelayedFrames);
    rate('vo-drop', voDroppedFrames, previous?.voDroppedFrames);
    rate('dec-drop', decoderDroppedFrames, previous?.decoderDroppedFrames);
    sb.write('vf-fps=${_f(estimatedVfFps, 2)} ');
    sb.write('avsync=${_f(avsync, 3)} ');
    sb.write('cache=${_f(demuxerCacheSeconds, 1)}s ');
    sb.write('cache-speed=${_s(cacheSpeedBytesPerSecond)} ');
    sb.write('vbitrate=${_s(videoBitrate)} ');
    sb.write('abitrate=${_s(audioBitrate)} ');
    sb.write('paused-for-cache=${_s(pausedForCache)}');
    return sb.toString().trimRight();
  }

  /// 本窗是否「显著掉帧」——供调用方把这一行提级到 warn，让 grep 一眼看到。
  /// 判据与 `VideoBlackFlickerDetector` 的默认阈值对齐（>= 8 帧/秒）。
  bool isDegradedSince(
    VideoMpvStatsSnapshot? previous,
    int windowMs, {
    double lateFramesPerSecondThreshold = 8,
  }) {
    if (previous == null || windowMs <= 0) return false;
    int delta(int? cur, int? prev) {
      if (cur == null || prev == null) return 0;
      return math.max(0, cur - prev);
    }

    final int total =
        delta(voDelayedFrames, previous.voDelayedFrames) +
        delta(voDroppedFrames, previous.voDroppedFrames) +
        delta(decoderDroppedFrames, previous.decoderDroppedFrames);
    return total * 1000.0 / windowMs >= lateFramesPerSecondThreshold;
  }

  static String _s(Object? v) => v?.toString() ?? '-';

  static String _f(double? v, int digits) =>
      v == null ? '-' : v.toStringAsFixed(digits);
}

/// 一帧的耗时三元组（微秒）。从 `FrameTiming` 抄出来，避免本文件依赖 `dart:ui`。
class VideoFrameSample {
  const VideoFrameSample({
    required this.buildMicros,
    required this.rasterMicros,
    this.vsyncOverheadMicros = 0,
  });

  final int buildMicros;
  final int rasterMicros;
  final int vsyncOverheadMicros;

  /// UI + GPU 相加的总耗时。**不是**掉帧判据：Flutter 的 build（UI 线程）与
  /// raster（raster 线程）是流水线并行的，各自 ≤ 预算这一帧就赶得上；求和会把
  /// 「build 9ms + raster 9ms」这种完全流畅的窗口记成 jank——视频页带纹理合成与
  /// 字幕阴影时 raster 常在 8~12ms，误报会是常态，把归因引向 Dart 侧。只用于展示。
  int get totalMicros => buildMicros + rasterMicros;

  /// 掉帧判据用的关键路径：两条流水线里较慢的那条（Flutter DevTools 同口径）。
  int get criticalMicros =>
      buildMicros > rasterMicros ? buildMicros : rasterMicros;
}

/// 帧耗时聚合：攒一个窗口（默认 1 秒）的帧，输出一行 mpv stats 风格的汇总。
///
/// 为什么要它：视频「卡顿」有两个完全不同的源头——libmpv 解码/渲染跟不上（看
/// [VideoMpvStatsSnapshot] 的丢帧计数），和 Flutter 这一侧的 UI 线程被占住（字幕层
/// 每次 controller 通知都清空重建逐字符登记表、`\fad` 动画期还逐帧空 setState）。
/// 后者 libmpv 一无所知，只有 `FrameTiming` 看得见。两条线同刻对齐才分得清。
class VideoFrameTimingAggregator {
  VideoFrameTimingAggregator({
    this.jankBudgetMicros = 16667,
    this.severeMultiplier = 3,
  });

  /// 一帧的预算（默认 60Hz 的 16.667ms）。调用方可按实测刷新率改。
  final int jankBudgetMicros;

  /// 「严重卡顿」倍数：总耗时超过 [jankBudgetMicros] 的这么多倍单独计数。
  final int severeMultiplier;

  final List<VideoFrameSample> _window = <VideoFrameSample>[];

  int get frameCount => _window.length;

  void add(VideoFrameSample sample) => _window.add(sample);

  void addAll(Iterable<VideoFrameSample> samples) => _window.addAll(samples);

  void reset() => _window.clear();

  /// 汇总当前窗口并清空。窗口为空时返回 null（调用方据此跳过这一行——没帧可画
  /// 不是信息，暂停时每秒打一行 `frames=0` 只会淹没日志）。
  String? summariseAndReset(int windowMs) {
    if (_window.isEmpty) return null;
    final String line = summarise(
      _window,
      windowMs,
      jankBudgetMicros: jankBudgetMicros,
      severeMultiplier: severeMultiplier,
    );
    _window.clear();
    return line;
  }

  /// 本窗是否卡（供调用方提级到 warn）：有严重卡顿帧，或超预算帧占比过半。
  bool isJankyWindow({double jankRatioThreshold = 0.5}) {
    if (_window.isEmpty) return false;
    final int severeCut = jankBudgetMicros * severeMultiplier;
    int janky = 0;
    for (final VideoFrameSample s in _window) {
      if (s.criticalMicros >= severeCut) return true;
      if (s.criticalMicros > jankBudgetMicros) janky++;
    }
    return janky / _window.length >= jankRatioThreshold;
  }

  /// 纯函数：一窗帧 → 一行。给 build / raster 各自的 p50 / p95 / max，再加超预算
  /// 帧数与严重卡顿帧数。分开给 build 与 raster 是因为两者指向不同的责任方：build
  /// 高 = Dart 侧 widget 树重建太贵（字幕层重建、控制条 merge listenable）；
  /// raster 高 = GPU 侧画不动（着色器、大量半透明层、视频纹理合成）。
  static String summarise(
    List<VideoFrameSample> frames,
    int windowMs, {
    int jankBudgetMicros = 16667,
    int severeMultiplier = 3,
  }) {
    if (frames.isEmpty) return 'frames=0';
    final List<int> build = frames.map((f) => f.buildMicros).toList()..sort();
    final List<int> raster = frames.map((f) => f.rasterMicros).toList()..sort();
    final int severeCut = jankBudgetMicros * severeMultiplier;
    int janky = 0;
    int severe = 0;
    // jank / severe 按关键路径（max(build, raster)）计，见 [VideoFrameSample
    // .criticalMicros]；分位仍按 build / raster 各自给。
    for (final VideoFrameSample f in frames) {
      if (f.criticalMicros > jankBudgetMicros) janky++;
      if (f.criticalMicros >= severeCut) severe++;
    }
    final String fps = windowMs > 0
        ? (frames.length * 1000.0 / windowMs).toStringAsFixed(1)
        : '-';
    return 'frames=${frames.length} fps=$fps '
        'jank=$janky severe=$severe '
        'build(p50/p95/max)=${_ms(percentile(build, 0.5))}/'
        '${_ms(percentile(build, 0.95))}/${_ms(build.last)} '
        'raster(p50/p95/max)=${_ms(percentile(raster, 0.5))}/'
        '${_ms(percentile(raster, 0.95))}/${_ms(raster.last)} '
        'budget=${_ms(jankBudgetMicros)}';
  }

  /// 纯函数：已排序列表的分位数（最近秩，空列表返回 0）。
  static int percentile(List<int> sorted, double q) {
    if (sorted.isEmpty) return 0;
    if (sorted.length == 1) return sorted.first;
    final double pos = q * (sorted.length - 1);
    final int idx = pos.round().clamp(0, sorted.length - 1);
    return sorted[idx];
  }

  static String _ms(int micros) => (micros / 1000.0).toStringAsFixed(1);
}
