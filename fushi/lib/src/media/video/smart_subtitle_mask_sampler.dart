/// 智能遮布的抽帧循环：播放中按帧变化截出搜索区域的原始像素（截帧 isolate 上就地
/// 裁剪，整帧不出截帧 isolate）→ 本机 OCR 找行框 → 交给 [SmartSubtitleMaskTracker]
/// 算遮布矩形，经 [rect] 推给遮布层。
///
/// 只管「何时截、截完喂给谁」，几何与迟滞全在 tracker。串行：上一帧识别完才截下一帧，
/// 两次之间至少隔 [minInterval]；暂停且帧没变就停下，等控制器通知再继续。
///
/// 识别器不可用（本机 OCR 模型没下载 / 平台不支持）时进入「退化」：遮布按搜索区域整块
/// 常显（等同手动遮布），[onUnavailable] 只报一次。
library;

import 'dart:async';
import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart';

import 'package:fushi/src/media/video/raw_video_frame.dart';
import 'package:fushi/src/media/video/smart_subtitle_mask_tracker.dart';
import 'package:fushi/src/media/video/video_player_controller.dart';
import 'package:fushi/src/ocr/local_screen_ocr.dart';
import 'package:fushi/src/ocr/system_ocr_channel.dart';

/// 两次抽样之间的最短间隔。字幕一句通常停留 1.5 s 以上，这个间隔让换句后最多约
/// 一个采样周期就跟上。
const Duration kSmartSubtitleMaskMinInterval = Duration(milliseconds: 250);

/// 连续无字多久才隐藏遮布。
const Duration kSmartSubtitleMaskHoldEmpty = Duration(milliseconds: 1200);

/// 播放位置跳变超过它（或倒退）就当画面不连续，清空 tracker。
const int kSmartSubtitleMaskSeekJumpMs = 2000;

/// 识别器不可用（模型没下载 / 平台不支持）。
class SmartSubtitleMaskDetectorUnavailable implements Exception {
  const SmartSubtitleMaskDetectorUnavailable();
}

/// 在一块裁剪里找字幕行，返回整帧比例坐标的横排行框。不可用时抛
/// [SmartSubtitleMaskDetectorUnavailable]。
typedef SmartSubtitleMaskDetect =
    Future<List<Rect>> Function(RawVideoFrameCrop crop);

/// 识别器（遮布层持有，随智能模式开关建 / 拆）。
abstract interface class SmartSubtitleMaskDetector {
  /// 见 [SmartSubtitleMaskDetect]。
  Future<List<Rect>> detect(RawVideoFrameCrop crop);

  Future<void> dispose();
}

/// 生产识别器：本机 OCR（与截屏识字、硬字幕 OCR 同一套模型）。
class LocalOcrSmartSubtitleMaskDetector implements SmartSubtitleMaskDetector {
  LocalOcrSmartSubtitleMaskDetector(this._ocr);

  final LocalScreenOcr _ocr;

  @override
  Future<List<Rect>> detect(RawVideoFrameCrop crop) async {
    final SystemOcrPageResult page;
    try {
      page = await _ocr.recognizeRgba(
        crop.rgba,
        width: crop.width,
        height: crop.height,
      );
    } on SystemOcrUnavailableException {
      throw const SmartSubtitleMaskDetectorUnavailable();
    }
    return <Rect>[
      for (final SystemOcrTextLine line in page.lines)
        if (!line.isVertical && line.text.trim().isNotEmpty)
          crop.toFrameFraction(line.rect),
    ];
  }

  @override
  Future<void> dispose() => _ocr.dispose();
}

class SmartSubtitleMaskSampler {
  SmartSubtitleMaskSampler({
    required VideoPlayerController controller,
    required Rect region,
    required SmartSubtitleMaskDetect detect,
    Future<RawVideoFrameCrop?> Function(Rect region)? capture,
    this.onUnavailable,
    this.onError,
    this.minInterval = kSmartSubtitleMaskMinInterval,
    Duration holdEmpty = kSmartSubtitleMaskHoldEmpty,
    Duration Function()? clock,
  }) : _controller = controller,
       _region = region,
       _detect = detect,
       _capture = capture ?? controller.captureRawFrameCrop,
       _tracker = SmartSubtitleMaskTracker(holdEmpty: holdEmpty),
       _clock = clock ?? _stopwatchClock() {
    _controller.addListener(_onControllerChanged);
    _onControllerChanged();
  }

  final VideoPlayerController _controller;
  final SmartSubtitleMaskDetect _detect;

  /// 截出整帧比例矩形内的一块 RGBA。
  final Future<RawVideoFrameCrop?> Function(Rect region) _capture;
  final SmartSubtitleMaskTracker _tracker;
  final Duration Function() _clock;
  final VoidCallback? onUnavailable;
  final void Function(Object error, StackTrace stack)? onError;
  final Duration minInterval;

  Rect _region;
  final ValueNotifier<Rect?> _rect = ValueNotifier<Rect?>(null);
  Timer? _timer;
  bool _inFlight = false;
  bool _disposed = false;
  bool _unavailable = false;

  /// 这一串连续失败已经报过：持续失败（每个采样周期一次）只记第一条。
  bool _errorReported = false;
  int? _lastSampledPositionMs;
  int? _lastSeenPositionMs;
  Duration? _lastSampleAt;

  /// 遮布该盖的矩形（画面比例坐标）；null = 现在不显示。
  ValueListenable<Rect?> get rect => _rect;

  /// 识别器不可用、已退化成整块常显。
  bool get unavailable => _unavailable;

  /// 换搜索区域（用户拖了框）：清空 tracker，按新区域重新识别。
  set region(Rect value) {
    if (value == _region) return;
    _region = value;
    _tracker.reset();
    if (_unavailable) {
      _rect.value = value;
      return;
    }
    _rect.value = null;
    _lastSampledPositionMs = null;
    _onControllerChanged();
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    _controller.removeListener(_onControllerChanged);
    _rect.dispose();
  }

  static Duration Function() _stopwatchClock() {
    final Stopwatch watch = Stopwatch()..start();
    return () => watch.elapsed;
  }

  /// 现在的帧值得抽样吗：有首帧、能截帧、且（在播放，或暂停着但帧变了）。
  bool _wantsSample() {
    final VideoPlayerController c = _controller;
    if (_disposed || _unavailable) return false;
    if (!c.hasFirstFrame || !c.canCaptureFrame) return false;
    final int? position = c.positionMs;
    if (position == null) return false;
    return c.isPlaying || position != _lastSampledPositionMs;
  }

  void _onControllerChanged() {
    if (_disposed) return;
    final int? position = _controller.positionMs;
    final int? seen = _lastSeenPositionMs;
    if (position != null && seen != null) {
      final int delta = position - seen;
      if (delta < 0 || delta > kSmartSubtitleMaskSeekJumpMs) {
        _tracker.reset();
        if (!_unavailable) _rect.value = null;
      }
    }
    if (position != null) _lastSeenPositionMs = position;
    if (_inFlight || _timer != null || !_wantsSample()) return;
    _schedule();
  }

  void _schedule() {
    final Duration? last = _lastSampleAt;
    final Duration wait = last == null
        ? Duration.zero
        : minInterval - (_clock() - last);
    _timer = Timer(wait.isNegative ? Duration.zero : wait, () {
      _timer = null;
      unawaited(_sample());
    });
  }

  Future<void> _sample() async {
    if (!_wantsSample()) return;
    _inFlight = true;
    _lastSampleAt = _clock();
    _lastSampledPositionMs = _controller.positionMs;
    final Rect region = _region;
    try {
      final RawVideoFrameCrop? crop = await _capture(region);
      if (_disposed || crop == null) return;
      final List<Rect> lines = await _detect(crop);
      // 识别期间换了搜索区域：这一帧作废。
      if (_disposed || region != _region) return;
      final Rect? next = _tracker.addSample(
        lines: lines,
        region: region,
        at: _clock(),
      );
      _errorReported = false;
      final Rect? current = _rect.value;
      if (next == null ||
          current == null ||
          !smartSubtitleMaskRectsClose(current, next)) {
        _rect.value = next;
      }
    } on SmartSubtitleMaskDetectorUnavailable {
      if (_disposed) return;
      _unavailable = true;
      _rect.value = _region;
      onUnavailable?.call();
    } catch (error, stack) {
      if (_disposed || _errorReported) return;
      _errorReported = true;
      onError?.call(error, stack);
    } finally {
      _inFlight = false;
      if (!_disposed && _timer == null && _wantsSample()) _schedule();
    }
  }
}
