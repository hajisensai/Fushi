/// 游戏 OCR 台词流的泵（spec `docs/specs/2026-11-22-game-ocr-line-stream-design.md`）。
///
/// 判定状态全在 Rust（`FfcOcrLineTracker`，native/fushi_compute `ocrline.rs`）：本类只按
/// 间隔截窗 → 把整窗 PNG 交给 Rust 判（后台 isolate）→ Rust 说要 OCR 才调识别器 → 把识别
/// 文本交给 Rust 去重 → Rust 判出的新句 / 续写经 [GalOcrLineSource.onLine] 送出。这里不存
/// 「上一句」「上一帧」之类的镜像状态。
library;

import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:fushi/src/mining/window_capture_channel.dart';
import 'package:fushi/src/ocr/system_ocr_channel.dart';
import 'package:fushi_compute/fushi_compute.dart';

/// 台词框在游戏窗口**客户区**里的位置，归一化到 0～1（窗口缩放 / 换分辨率后仍对得上）。
@immutable
class GalOcrRegion {
  const GalOcrRegion({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });

  /// 没有记忆时的初始框：画面下方的常见台词框位置。
  static const GalOcrRegion defaultDialogue = GalOcrRegion(
    left: 0.05,
    top: 0.70,
    width: 0.90,
    height: 0.27,
  );

  /// 框的最小边长（归一化）：再小就框不住一个字。
  static const double minExtent = 0.02;

  final double left;
  final double top;
  final double width;
  final double height;

  double get right => left + width;
  double get bottom => top + height;

  /// 坐标有限、落在 0～1 内、宽高都不小于 [minExtent]。
  bool get isValid =>
      <double>[left, top, width, height].every((double v) => v.isFinite) &&
      left >= 0 &&
      top >= 0 &&
      right <= 1.0001 &&
      bottom <= 1.0001 &&
      width >= minExtent &&
      height >= minExtent;

  /// 由两个对角点（归一化，任意顺序）构造并夹到 0～1。
  factory GalOcrRegion.fromCorners(double x0, double y0, double x1, double y1) {
    double clamp(double v) => v.isFinite ? v.clamp(0.0, 1.0) : 0.0;
    final double l = clamp(math.min(x0, x1));
    final double t = clamp(math.min(y0, y1));
    final double r = clamp(math.max(x0, x1));
    final double b = clamp(math.max(y0, y1));
    return GalOcrRegion(left: l, top: t, width: r - l, height: b - t);
  }

  Map<String, double> toJson() => <String, double>{
    'left': left,
    'top': top,
    'width': width,
    'height': height,
  };

  /// 解析 [toJson] 的结果；缺字段 / 非法框返回 null（调用方用 [defaultDialogue]）。
  static GalOcrRegion? fromJson(Object? json) {
    if (json is! Map) return null;
    double? read(String key) {
      final Object? v = json[key];
      return v is num ? v.toDouble() : null;
    }

    final double? l = read('left');
    final double? t = read('top');
    final double? w = read('width');
    final double? h = read('height');
    if (l == null || t == null || w == null || h == null) return null;
    final GalOcrRegion region = GalOcrRegion(
      left: l,
      top: t,
      width: w,
      height: h,
    );
    return region.isValid ? region : null;
  }

  @override
  bool operator ==(Object other) =>
      other is GalOcrRegion &&
      other.left == left &&
      other.top == top &&
      other.width == width &&
      other.height == height;

  @override
  int get hashCode => Object.hash(left, top, width, height);

  @override
  String toString() => 'GalOcrRegion($left, $top, $width, $height)';
}

/// 识别一块 RGBA（`width * height * 4`），返回按阅读顺序、行间 `\n` 的全文。
/// 识别器不可用（缺语言包 / 模型）抛 [SystemOcrUnavailableException]。
typedef GalOcrRecognize =
    Future<String> Function(Uint8List rgba, int width, int height);

/// 截一帧窗口（默认 [WindowCaptureChannel.captureWindow]）。
typedef GalOcrWindowCapture = Future<WindowCaptureResult> Function(int hwnd);

/// 把整窗 PNG 交给 Rust tracker 判定（默认在后台 isolate 里跑 [FfcOcrLineTracker.feedPngAt]）。
typedef GalOcrFrameFeeder =
    Future<FfcOcrLineFrame> Function(
      int trackerAddress,
      Uint8List png,
      GalOcrRegion region,
    );

/// 泵的健康状况（只在变化时报一次，见 [GalOcrLineSource.onIssue]）。
enum GalOcrSourceIssue {
  /// 一切正常（从故障恢复时报这个）。
  none,

  /// 截不到窗口（最小化 / 窗口已关 / WGC 失败）。泵继续按间隔截，窗口回来就恢复。
  captureFailed,

  /// 识别器出错（单次）；泵继续。
  recognizeFailed,

  /// 识别器不可用（缺语言包 / 本机模型没下载）：不会自愈，泵已停。
  recognizerUnavailable,
}

/// 连续 OCR 台词流的泵。一个实例对应一次会话里的一个窗口；[stop] 之后不可再用。
class GalOcrLineSource {
  GalOcrLineSource({
    required this.hwnd,
    required GalOcrRegion region,
    required GalOcrRecognize recognize,
    required void Function(String text) onLine,
    void Function(GalOcrSourceIssue issue, Object? detail)? onIssue,
    GalOcrWindowCapture? capture,
    GalOcrFrameFeeder? feedFrame,
    FfcOcrLineTracker Function()? trackerFactory,
    this.interval = const Duration(milliseconds: 500),
  }) : _region = region,
       _recognize = recognize,
       _onLine = onLine,
       _onIssue = onIssue,
       _capture = capture ?? WindowCaptureChannel.captureWindow,
       _feedFrame = feedFrame ?? _feedInBackground,
       _trackerFactory = trackerFactory ?? FfcOcrLineTracker.new;

  /// 截取的游戏窗口。
  final int hwnd;

  /// 两次取帧之间的目标间隔（从一次取帧开始算；一轮比它慢就紧接着下一轮）。
  final Duration interval;

  final GalOcrRecognize _recognize;
  final void Function(String text) _onLine;
  final void Function(GalOcrSourceIssue issue, Object? detail)? _onIssue;
  final GalOcrWindowCapture _capture;
  final GalOcrFrameFeeder _feedFrame;
  final FfcOcrLineTracker Function() _trackerFactory;

  GalOcrRegion _region;
  FfcOcrLineTracker? _tracker;
  bool _running = false;
  bool _stopped = false;

  /// 换了区域：下一轮开始前让 Rust tracker 忘掉旧区域的帧与上一句；在途的那一轮作废。
  int _regionGeneration = 0;
  int _trackerGeneration = 0;

  Future<void>? _loop;
  Timer? _sleepTimer;
  Completer<void>? _sleep;
  GalOcrSourceIssue _lastIssue = GalOcrSourceIssue.none;

  GalOcrRegion get region => _region;
  bool get isRunning => _running;

  /// 开始泵（幂等）。
  void start() {
    if (_running || _stopped) return;
    _running = true;
    _tracker = _trackerFactory();
    _trackerGeneration = _regionGeneration;
    _loop = _run();
  }

  /// 换识别区域（会话中「调整识别区域」）。
  void setRegion(GalOcrRegion region) {
    if (region == _region) return;
    _region = region;
    _regionGeneration++;
    _wake();
  }

  /// 停泵：等在途的一轮收尾（后台 isolate 还在用 tracker 时不能释放它），再释放 tracker。
  Future<void> stop() async {
    _stopped = true;
    final Future<void>? loop = _loop;
    if (loop == null) return;
    _loop = null;
    _running = false;
    _wake();
    await loop;
    _tracker?.close();
    _tracker = null;
  }

  void _wake() {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    final Completer<void>? sleep = _sleep;
    _sleep = null;
    if (sleep != null && !sleep.isCompleted) sleep.complete();
  }

  Future<void> _run() async {
    while (_running) {
      final Stopwatch clock = Stopwatch()..start();
      await _tick();
      if (!_running) break;
      final Duration rest = interval - clock.elapsed;
      if (rest > Duration.zero) {
        final Completer<void> sleep = Completer<void>();
        _sleep = sleep;
        _sleepTimer = Timer(rest, _wake);
        await sleep.future;
      }
    }
  }

  /// 一轮：截窗 → Rust 判帧 →（需要时）OCR → Rust 判文本 → 送出。
  Future<void> _tick() async {
    final FfcOcrLineTracker tracker = _tracker!;
    if (_trackerGeneration != _regionGeneration) {
      tracker.reset();
      _trackerGeneration = _regionGeneration;
    }
    final int generation = _regionGeneration;
    final GalOcrRegion region = _region;
    bool stale() => !_running || generation != _regionGeneration;

    final WindowCaptureResult shot;
    try {
      shot = await _capture(hwnd);
    } on Object catch (error) {
      _report(GalOcrSourceIssue.captureFailed, error);
      return;
    }
    final Uint8List? png = shot.pngBytes;
    if (png == null || png.isEmpty) {
      _report(GalOcrSourceIssue.captureFailed, shot.error);
      return;
    }
    if (stale()) return;
    final FfcOcrLineFrame frame;
    try {
      frame = await _feedFrame(tracker.address, png, region);
    } on Object catch (error) {
      // 坏 PNG / 框落在图外（窗口被缩到极小）：和截不到一样，下一轮再看。
      _report(GalOcrSourceIssue.captureFailed, error);
      return;
    }
    if (stale()) return;
    final Uint8List? rgba = frame.rgba;
    if (frame.action != FfcOcrLineFrameAction.ocr || rgba == null) {
      _report(GalOcrSourceIssue.none, null);
      return;
    }
    final String text;
    try {
      text = await _recognize(rgba, frame.width, frame.height);
    } on SystemOcrUnavailableException catch (error) {
      _report(GalOcrSourceIssue.recognizerUnavailable, error.reason);
      _running = false;
      return;
    } on Object catch (error) {
      _report(GalOcrSourceIssue.recognizeFailed, error);
      return;
    }
    if (stale()) return;
    _report(GalOcrSourceIssue.none, null);
    final FfcOcrLineText result = tracker.feedText(text);
    if (result.kind == FfcOcrLineTextKind.newLine ||
        result.kind == FfcOcrLineTextKind.extend) {
      _onLine(result.text);
    }
  }

  void _report(GalOcrSourceIssue issue, Object? detail) {
    if (issue == _lastIssue) return;
    _lastIssue = issue;
    _onIssue?.call(issue, detail);
  }

  static Future<FfcOcrLineFrame> _feedInBackground(
    int address,
    Uint8List png,
    GalOcrRegion region,
  ) => Isolate.run(
    () => FfcOcrLineTracker.feedPngAt(
      address,
      png,
      left: region.left,
      top: region.top,
      width: region.width,
      height: region.height,
    ),
    debugName: 'gal-ocr-frame',
  );
}
