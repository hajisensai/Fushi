/// 游戏 OCR 台词流的泵（spec `docs/specs/2026-11-22-game-ocr-line-stream-design.md`）。
///
/// 判定状态全在 Rust（`FfcOcrLineTracker`，native/fushi_compute `ocrline.rs`）：本类只按
/// 间隔截窗 → 把整窗 PNG 交给 Rust 判（后台 isolate）→ Rust 说要 OCR 才调识别器 → 把识别
/// 文本交给 Rust 去重 → Rust 判出的新句 / 续写经 [GalOcrLineSource.onLine] 送出。这里不存
/// 「上一句」「上一帧」之类的镜像状态。
///
/// 游戏画面内嵌查词（BUG-5299 ②）：识别器连文本交来逐字框，Rust 把它们对齐到这一句的显示文本、
/// 映回整张截图；本类再按这次截图的元数据（Magpie 时是呈现窗 → 源窗口客户区）换成游戏客户区
/// 物理像素，发布到 [GalOcrLineSource.measuredFeed]——查词扫描面只认这个中立数据面
/// （`gal_measured_text_feed.dart`），不碰 OCR 包。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:fushi/src/mining/gal_measured_text_feed.dart';
import 'package:fushi/src/mining/window_capture_channel.dart';
import 'package:fushi/src/ocr/system_ocr_channel.dart';
import 'package:fushi/src/platform/gal_hook_text_overlay_channel.dart'
    show galAttachedMeasuredSourceScreenOcr;
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

  /// 解析 [toJson] 的 JSON 文本（偏好里存的形态）；空 / 坏 JSON / 非法框返回 null。
  static GalOcrRegion? fromJsonString(String? json) {
    if (json == null || json.isEmpty) return null;
    try {
      return fromJson(jsonDecode(json));
    } on FormatException {
      return null;
    }
  }

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

/// 一次识别的结果：按阅读顺序、行间 `\n` 的全文，以及可选的逐字框。
@immutable
class GalOcrRecognition {
  const GalOcrRecognition(this.text, {this.charBoxes});

  final String text;

  /// `text.runes` 每个字一组 `[l, t, r, b]`（送检图像素，行间 `\n` 等填 0）；null = 识别器没给
  /// 几何（这一句不能在游戏画面里点）。
  final Float32List? charBoxes;
}

/// 识别一块 RGBA（`width * height * 4`）。识别器不可用（缺语言包 / 模型）抛
/// [SystemOcrUnavailableException]。
typedef GalOcrRecognize =
    Future<GalOcrRecognition> Function(Uint8List rgba, int width, int height);

/// 截图像素 → 游戏源窗口客户区物理像素的换算（[galOcrClientMapping]）。
typedef GalOcrClientMapping = ({
  double scaleX,
  double scaleY,
  double offsetX,
  double offsetY,
  int clientWidth,
  int clientHeight,
});

/// 这次截图的像素怎么落到游戏源窗口客户区（attached surface 实测排版的坐标契约）。
///
/// 普通截窗：截图就是完整客户区（[WindowCaptureMetadata.isCompleteClient]），恒等换算。
/// Magpie 超分时截的是呈现窗里的目标视口（[WindowCaptureMetadata.hasSourceClientMapping]）：
/// 截图对应源客户区里的源视口，按视口比例缩放再加上视口在源客户区里的偏移——与校准截图的投影
/// （`gal_lookup_calibration_projection.dart`）同一套换算。元数据缺失（老 runner）、截图尺寸
/// 与元数据不符、裁框不完整时返回 null：不猜坐标，这一句就不给游戏内命中框。
GalOcrClientMapping? galOcrClientMapping(
  WindowCaptureMetadata? metadata, {
  required int imageWidth,
  required int imageHeight,
}) {
  if (metadata == null || imageWidth <= 0 || imageHeight <= 0) return null;
  if (metadata.imageWidthPx != imageWidth ||
      metadata.imageHeightPx != imageHeight) {
    return null;
  }
  if (!metadata.usedPresentationCapture) {
    if (!metadata.isCompleteClient) return null;
    return (
      scaleX: 1,
      scaleY: 1,
      offsetX: 0,
      offsetY: 0,
      clientWidth: metadata.clientWidthPx,
      clientHeight: metadata.clientHeightPx,
    );
  }
  if (!metadata.hasSourceClientMapping) return null;
  return (
    scaleX: metadata.sourceViewportWidthPx / imageWidth,
    scaleY: metadata.sourceViewportHeightPx / imageHeight,
    offsetX: (metadata.sourceViewportLeftPx - metadata.sourceClientLeftPx)
        .toDouble(),
    offsetY: (metadata.sourceViewportTopPx - metadata.sourceClientTopPx)
        .toDouble(),
    clientWidth: metadata.sourceClientWidthPx,
    clientHeight: metadata.sourceClientHeightPx,
  );
}

/// OCR 行的一个字形（客户区物理像素；OCR 只在画面稳定后识别，所以都是已显示的字）。
@immutable
class GalOcrMeasuredGlyph implements GalMeasuredTextGlyph {
  const GalOcrMeasuredGlyph({
    required this.textStart,
    required this.textLength,
    required this.rect,
  });

  @override
  final int textStart;

  @override
  final int textLength;

  @override
  final math.Rectangle<double> rect;

  @override
  bool get shown => true;

  @override
  bool operator ==(Object other) =>
      other is GalOcrMeasuredGlyph &&
      other.textStart == textStart &&
      other.textLength == textLength &&
      other.rect == rect;

  @override
  int get hashCode => Object.hash(textStart, textLength, rect);
}

/// OCR 游戏模式发布给查词几何的一帧。空文本 = 撤掉命中框（画面在变 / 台词框清空 / 换区域）。
@immutable
class GalOcrMeasuredFrame implements GalMeasuredTextFrame {
  const GalOcrMeasuredFrame({
    required this.text,
    required this.glyphs,
    required this.clientWidth,
    required this.clientHeight,
  });

  /// 撤掉命中框。
  const GalOcrMeasuredFrame.clear()
    : text = '',
      glyphs = const <GalOcrMeasuredGlyph>[],
      clientWidth = 0,
      clientHeight = 0;

  @override
  final String text;

  @override
  final List<GalOcrMeasuredGlyph> glyphs;

  @override
  final int clientWidth;

  @override
  final int clientHeight;

  /// OCR 只在画面稳定后才识别：发布出来的都是显示完的句子。
  @override
  bool get complete => true;

  /// 坐标直接是物理像素（不是 CSS 像素换算出来的），测量尺寸与真实客户区逐像素相等。
  @override
  double get devicePixelRatio => 1;

  bool get isClear => text.isEmpty;
}

/// OCR 游戏模式的实测排版数据源：一个 [GalOcrLineSource] 一个，[GalOcrLineSource.stop] 时关闭。
class GalOcrMeasuredFeed implements GalMeasuredTextFeed {
  GalOcrMeasuredFeed({required this.hwnd});

  /// 被识别的游戏窗口（只用于诊断）。
  final int hwnd;

  final StreamController<GalOcrMeasuredFrame> _frames =
      StreamController<GalOcrMeasuredFrame>.broadcast();
  GalOcrMeasuredFrame? _latest;

  @override
  String get measuredSource => galAttachedMeasuredSourceScreenOcr;

  @override
  String get diagnosticLabel => 'screen_ocr hwnd=$hwnd';

  @override
  Stream<GalOcrMeasuredFrame> get frames => _frames.stream;

  @override
  GalOcrMeasuredFrame? get latest => _latest;

  @override
  bool get isClosed => _frames.isClosed;

  /// 发布一帧；与上一帧相同（含连续两次清空）时不重发。
  void add(GalOcrMeasuredFrame frame) {
    if (_frames.isClosed) return;
    final GalOcrMeasuredFrame? previous = _latest;
    if (previous != null &&
        previous.text == frame.text &&
        previous.clientWidth == frame.clientWidth &&
        previous.clientHeight == frame.clientHeight &&
        listEquals(previous.glyphs, frame.glyphs)) {
      return;
    }
    _latest = frame;
    _frames.add(frame);
  }

  /// 撤掉命中框（还没发布过任何几何时不发）。
  void clear() {
    if (_latest == null) return;
    add(const GalOcrMeasuredFrame.clear());
  }

  Future<void> close() => _frames.close();
}

/// 把 Rust 交回的整图字形换成客户区实测帧；换算不可用或一个字都落不进客户区时返回 null。
GalOcrMeasuredFrame? galOcrMeasuredFrameOf(
  FfcOcrLineText result,
  WindowCaptureMetadata? metadata,
) {
  final List<FfcOcrLineGlyph>? glyphs = result.glyphs;
  if (glyphs == null || glyphs.isEmpty || result.text.isEmpty) return null;
  final GalOcrClientMapping? mapping = galOcrClientMapping(
    metadata,
    imageWidth: result.imageWidth,
    imageHeight: result.imageHeight,
  );
  if (mapping == null) return null;
  final double width = mapping.clientWidth.toDouble();
  final double height = mapping.clientHeight.toDouble();
  final List<GalOcrMeasuredGlyph> out = <GalOcrMeasuredGlyph>[];
  for (final FfcOcrLineGlyph glyph in glyphs) {
    final double left = (mapping.offsetX + glyph.left * mapping.scaleX).clamp(
      0.0,
      width,
    );
    final double top = (mapping.offsetY + glyph.top * mapping.scaleY).clamp(
      0.0,
      height,
    );
    final double right = (mapping.offsetX + glyph.right * mapping.scaleX).clamp(
      0.0,
      width,
    );
    final double bottom = (mapping.offsetY + glyph.bottom * mapping.scaleY)
        .clamp(0.0, height);
    if (right <= left || bottom <= top) continue;
    out.add(
      GalOcrMeasuredGlyph(
        textStart: glyph.start,
        textLength: glyph.length,
        rect: math.Rectangle<double>(left, top, right - left, bottom - top),
      ),
    );
  }
  if (out.isEmpty) return null;
  return GalOcrMeasuredFrame(
    text: result.text,
    glyphs: List<GalOcrMeasuredGlyph>.unmodifiable(out),
    clientWidth: mapping.clientWidth,
    clientHeight: mapping.clientHeight,
  );
}

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
    bool binarize = false,
    this.interval = const Duration(milliseconds: 500),
  }) : _region = region,
       _binarize = binarize,
       _recognize = recognize,
       _onLine = onLine,
       _onIssue = onIssue,
       _capture = capture ?? WindowCaptureChannel.captureWindow,
       _feedFrame = feedFrame ?? _feedInBackground,
       _trackerFactory = trackerFactory ?? FfcOcrLineTracker.new,
       measuredFeed = GalOcrMeasuredFeed(hwnd: hwnd);

  /// 截取的游戏窗口。
  final int hwnd;

  /// 当前画面上这一句的逐字客户区几何（游戏画面内嵌查词消费）；[stop] 时关闭。
  final GalOcrMeasuredFeed measuredFeed;

  /// 两次取帧之间的目标间隔（从一次取帧开始算；一轮比它慢就紧接着下一轮）。
  final Duration interval;

  final GalOcrRecognize _recognize;
  final void Function(String text) _onLine;
  final void Function(GalOcrSourceIssue issue, Object? detail)? _onIssue;
  final GalOcrWindowCapture _capture;
  final GalOcrFrameFeeder _feedFrame;
  final FfcOcrLineTracker Function() _trackerFactory;

  GalOcrRegion _region;

  /// 送 OCR 前是否二值化（Rust tracker 的预处理选项）。每轮开始前若与已下发的不同就下发，
  /// 与换区域一样只在轮与轮之间改 tracker，不和在途的后台判帧抢。
  bool _binarize;
  bool? _appliedBinarize;
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
  bool get binarize => _binarize;
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
    // 旧区域那一句的命中框不再对应新区域的画面。
    measuredFeed.clear();
    _wake();
  }

  /// 开关「二值化」预处理（会话中在框选对话框里改）。同一画面会按新选项再识别一次。
  void setBinarize(bool binarize) {
    if (binarize == _binarize) return;
    _binarize = binarize;
    _wake();
  }

  /// 停泵：等在途的一轮收尾（后台 isolate 还在用 tracker 时不能释放它），再释放 tracker。
  Future<void> stop() async {
    _stopped = true;
    final Future<void>? loop = _loop;
    if (loop == null) {
      await measuredFeed.close();
      return;
    }
    _loop = null;
    _running = false;
    _wake();
    await loop;
    _tracker?.close();
    _tracker = null;
    await measuredFeed.close();
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
    if (_appliedBinarize != _binarize) {
      tracker.configure(binarize: _binarize);
      _appliedBinarize = _binarize;
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
      // 画面在变（换句 / 打字机）或台词框清空：旧句的命中框不能留着——点击的本意是推进
      // 游戏或跳过打字，而且点到的已不是画面上的字。
      if (frame.action == FfcOcrLineFrameAction.settling ||
          frame.action == FfcOcrLineFrameAction.cleared) {
        measuredFeed.clear();
      }
      return;
    }
    final GalOcrRecognition recognition;
    try {
      recognition = await _recognize(rgba, frame.width, frame.height);
    } on SystemOcrUnavailableException catch (error) {
      _report(GalOcrSourceIssue.recognizerUnavailable, error.reason);
      _running = false;
      return;
    } on Object catch (error) {
      _report(GalOcrSourceIssue.recognizeFailed, error);
      // Rust 交出这帧时已记下「OCR 过了」；没识别成就让它忘掉，同一画面下一轮再交出。
      if (!stale()) tracker.forgetFrame();
      return;
    }
    if (stale()) return;
    _report(GalOcrSourceIssue.none, null);
    final FfcOcrLineText result = tracker.feedText(
      recognition.text,
      charBoxes: _validCharBoxes(recognition),
    );
    final bool emitted =
        result.kind == FfcOcrLineTextKind.newLine ||
        result.kind == FfcOcrLineTextKind.extend;
    if (emitted) _onLine(result.text);
    final GalOcrMeasuredFrame? measured = galOcrMeasuredFrameOf(
      result,
      shot.metadata,
    );
    if (measured != null) {
      measuredFeed.add(measured);
    } else if (result.kind != FfcOcrLineTextKind.duplicate) {
      // 新句 / 续写 / 空：画面上的字变了，没有能用的几何就撤掉旧框。重复句对不齐时旧框
      // 仍对应同一句，保留。
      measuredFeed.clear();
    }
  }

  /// 识别器给的逐字框与文本字数对不上（识别器实现有误）时当作没给，不让 Rust 拒收整次识别。
  static Float32List? _validCharBoxes(GalOcrRecognition recognition) {
    final Float32List? boxes = recognition.charBoxes;
    if (boxes == null) return null;
    return boxes.length == recognition.text.runes.length * 4 ? boxes : null;
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
