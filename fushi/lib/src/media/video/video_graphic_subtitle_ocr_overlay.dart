/// 暂停 OCR 查词覆盖层：暂停时截下当前帧（含 libmpv 自绘的字幕位图）做 OCR，
/// 在识别出的每个字上方铺一个透明可点区域，点字即查词。
///
/// 起初只为图形字幕（PGS / VobSub / DVB，没有 Dart 文字）而设；现在按
/// [VideoPauseOcrScope] 扩到所有视频（硬字幕、画面文字），见
/// [VideoPauseOcrScope.shouldRecognize]。
///
/// 识别与 AI 重读见 `graphic_subtitle_ocr.dart`；本层只负责「何时识别」与「摆在哪」。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/video/graphic_subtitle_ocr.dart';
import 'package:fushi/src/media/video/video_pause_ocr_scope.dart';
import 'package:fushi/src/media/video/video_graphic_subtitle_ocr_progress.dart';
import 'package:fushi/src/media/video/video_player_controller.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi_engine/ocr/ocr_types.dart' show OcrRgbaImage;

/// 识别触发的防抖：逐帧步进 / 连续 seek 时只识别停下来的那一帧。
const Duration kGraphicSubtitleOcrSettleDelay = Duration(milliseconds: 250);

/// 同一帧截帧失败（mpv `screenshot-raw` 无结果）后的重截退避。
///
/// 暂停态 seek / 跳句 / 逐帧步进后，mpv 先清掉当前帧，新帧解码显示前截帧必然失败；
/// 网络流缓冲、4K / HEVC 长 GOP 时新帧会晚于 [kGraphicSubtitleOcrSettleDelay] 才出来。
/// 帧键（位置 + 字幕轨）此时已经不变，不重截这一帧就再也不会识别（BUG-3561）。
///
/// 这是对外部时序的兼容层：media_kit 1.2.6 不暴露 mpv 的 `playback-restart` 事件，
/// 而 `seeking` 属性观测会合并 yes→no 翻转（见 `VideoPlayerController` 的
/// `_kSeekSettledAdvanceMs` 注释），拿不到可靠的「新帧已显示」信号。影响范围只有暂停
/// OCR 截帧；帧一变（播放 / seek / 换轨）在途重截即作废。清理条件：播放器能给出
/// 「新帧已显示」事件后，改成挂在那个事件上重截。
const List<Duration> kGraphicSubtitleOcrCaptureRetryDelays = <Duration>[
  Duration(milliseconds: 250),
  Duration(milliseconds: 500),
  Duration(seconds: 1),
  Duration(seconds: 2),
];

/// 识别完成后的状态标记（「已识别 · 点字查词」/「这一帧没有字」）停留多久后淡出。
///
/// 反馈 YtbinN_pBG / -6dAnq8S6f：「已识别」以前在暂停期间常驻、一直压在画面上；
/// 它只是告诉用户「现在可以点字了」，看到一眼就够。淡出的只是标记，识别出的可点
/// 区域照旧留到继续播放 / seek / 换轨为止。
const Duration kGraphicSubtitleOcrStatusHintDuration = Duration(
  milliseconds: 2500,
);

/// 暂停 OCR 的识别结果标记是否到时自动淡出（识别中要一直显示到出结果为止）。
bool graphicSubtitlePauseOcrStatusAutoHides(
  GraphicSubtitlePauseOcrStatus status,
) => switch (status) {
  GraphicSubtitlePauseOcrStatus.ready ||
  GraphicSubtitlePauseOcrStatus.empty => true,
  GraphicSubtitlePauseOcrStatus.idle ||
  GraphicSubtitlePauseOcrStatus.recognizing => false,
};

/// 一击落在哪个可点字上：返回 [charRects] 里的下标，没有字框盖住 [point] 时返回
/// null（这一击不归本层，穿透给下面的视频控件）。
///
/// 多个字框都盖住落点时（BUG-5177，反馈 WgeFHwdQ65）取落点在框里「最深」的那个：
/// 落点离框中心的偏移按半宽 / 半高归一后取较大的一维，越小越深；一样深再取面积小的，
/// 还一样取排在后面的（与以前的叠放顺序一致）。以前每个字一个 [Positioned] 手势框，
/// 框之间有重叠时全凭 [Stack] 的叠放顺序裁决——同一块里后一行的字永远压住前一行，
/// 斜行的轴对齐字框、注音 / 下划线这类扁框盖到别的字上时，点中哪个字跟点在哪无关。
/// 判据与截屏识字的 `screenOcrHitTest`（BUG-4069）同一个意思：人点的是字身，离
/// 被点那个字的中心近、离别的字框的中心远。
int? graphicSubtitleOcrHitTest({
  required List<Rect> charRects,
  required Offset point,
}) {
  int? best;
  double bestDepth = double.infinity;
  double bestArea = double.infinity;
  for (int i = 0; i < charRects.length; i++) {
    final Rect rect = charRects[i];
    if (rect.isEmpty || !rect.contains(point)) continue;
    final double depth = math.max(
      (point.dx - rect.center.dx).abs() / (rect.width / 2),
      (point.dy - rect.center.dy).abs() / (rect.height / 2),
    );
    final double area = rect.width * rect.height;
    if (best == null ||
        depth < bestDepth ||
        (depth == bestDepth && area <= bestArea)) {
      best = i;
      bestDepth = depth;
      bestArea = area;
    }
  }
  return best;
}

/// 暂停 OCR 点字的诊断（`video.pause_ocr_tap`，进错误日志随反馈上传）：落点、控件 /
/// 显示 / 帧图三套尺寸与摆放方式、盖住落点的框数、命中的字及其帧图 / 控件字框、离
/// 落点最近的几个字框、整句前 32 个字。反馈 WgeFHwdQ65 点「中」命中上一行的「u」，
/// 当时这条路径什么都不记，分不清是字框摆错（识别几何 / 坐标映射）还是命中裁决错
/// ——有了这一行，下一份同类反馈可以直接回放。
String graphicSubtitleOcrTapDiagnostic({
  required GraphicSubtitleOcrFrame frame,
  required List<Rect> viewRects,
  required Offset point,
  required int hit,
  required Size viewSize,
  required Size displaySize,
  required BoxFit fit,
}) {
  String rectOf(Rect r) =>
      '${r.left.round()},${r.top.round()},${r.right.round()},${r.bottom.round()}';
  String sizeOf(Size s) => '${s.width.round()}x${s.height.round()}';
  String glyphOf(GraphicSubtitleOcrChar c) =>
      c.sentence.characters.elementAtOrNull(c.graphemeIndex) ?? '?';
  final int covering = viewRects
      .where((Rect r) => !r.isEmpty && r.contains(point))
      .length;
  final List<int> nearest = List<int>.generate(viewRects.length, (int i) => i)
    ..sort(
      (int a, int b) => (viewRects[a].center - point).distance.compareTo(
        (viewRects[b].center - point).distance,
      ),
    );
  final GraphicSubtitleOcrChar picked = frame.chars[hit];
  final String near = <String>[
    for (final int i in nearest.take(4))
      '#$i"${glyphOf(frame.chars[i])}"@${rectOf(frame.chars[i].rect)}',
  ].join(' ');
  return 'point=(${point.dx.round()},${point.dy.round()}) '
      'view=${sizeOf(viewSize)} display=${sizeOf(displaySize)} '
      'image=${sizeOf(frame.imageSize)} fit=${fit.name} '
      'chars=${frame.chars.length} covering=$covering '
      'hit=#$hit"${glyphOf(picked)}" grapheme=${picked.graphemeIndex} '
      'charImage=${rectOf(picked.rect)} charView=${rectOf(viewRects[hit])} '
      'near=[$near] '
      'text="${picked.sentence.characters.take(32)}"';
}

/// 图形字幕 OCR 查词覆盖层。尺寸须与视频控件一致（挂在 controls 层里）。
class VideoGraphicSubtitleOcrOverlay extends StatefulWidget {
  const VideoGraphicSubtitleOcrOverlay({
    required this.controller,
    required this.fit,
    required this.prepare,
    required this.onCharTap,
    this.scope = VideoPauseOcrScope.graphicSubtitles,
    this.manualRequestSerial = 0,
    this.onEnableRequested,
    this.onUnavailable,
    this.onError,
    this.captureFrame,
    this.recognizeFrame,
    this.statusTopInset = 12,
    super.key,
  });

  final VideoPlayerController controller;

  /// 画面在控件里的摆放方式（与 Video 的 fit 同源）。
  final BoxFit fit;

  final GraphicSubtitleOcrPrepare prepare;

  /// 哪些视频暂停时识别（用户设置）。
  final VideoPauseOcrScope scope;

  /// 「识别一次当前画面」请求序号（反馈 X3ozgOAx8v：按钮 / 快捷键手动识别）。
  ///
  /// 页面每次触发 +1；本层看到序号变化，就把**下一个暂停帧**（已暂停则是当前帧）标成
  /// 手动豁免——即使 [scope] 不识别这类帧也识别它一次。豁免只认那一帧：继续播放 /
  /// seek / 换轨（帧键变化）即解除，之后照 [scope] 办。[scope] 本来就会识别该帧时不重复
  /// 识别。
  final int manualRequestSerial;

  /// 用户点了「开启」提示（BUG-3342）。识别关着、暂停在图片字幕帧上时才出现提示；
  /// null 时不提示。页面负责把范围写成开启并以新 [scope] 重建本层。
  final VoidCallback? onEnableRequested;

  /// 点中一个字：整句、句内字素下标、字在**全局**坐标系下的矩形。
  final void Function(String sentence, int graphemeIndex, Rect globalRect)
  onCharTap;

  /// 引擎不可用（自动识别每个会话只报一次，且只在图形字幕帧上报——普通视频的暂停
  /// 识别是顺带的，没配 OCR 的用户不该每看一部片都被提示一次）。手动识别
  /// （[manualRequestSerial]）是用户主动要求，每次都报。
  final void Function(GraphicSubtitleOcrUnavailableReason reason)?
  onUnavailable;

  /// 截帧 / 识别 / AI 重读出错。
  final void Function(Object error, StackTrace stack)? onError;

  /// 截帧；默认走 [VideoPlayerController.captureFrameWithSubtitles]（测试注入用）。
  final Future<OcrRgbaImage?> Function()? captureFrame;

  /// 识别一帧；默认走 [GraphicSubtitleOcrSession.recognize]（测试注入用，不触发
  /// AI 重读回调）。
  @visibleForTesting
  final Future<GraphicSubtitleOcrFrame?> Function(OcrRgbaImage frame)?
  recognizeFrame;

  /// 状态标记（识别中 / 已识别）距顶部的距离——页面传顶栏高度，标记落在顶栏下方、
  /// 不压字幕（图形字幕绝大多数在画面下方）。
  final double statusTopInset;

  @override
  State<VideoGraphicSubtitleOcrOverlay> createState() =>
      _VideoGraphicSubtitleOcrOverlayState();
}

/// 识别时刻的身份：位置与字幕轨都没变，画面上的字幕就没变。
typedef _FrameKey = ({int positionMs, String? trackId});

class _VideoGraphicSubtitleOcrOverlayState
    extends State<VideoGraphicSubtitleOcrOverlay> {
  GraphicSubtitleOcrSession? _session;
  GraphicSubtitleOcrFrame? _frame;
  _FrameKey? _key;
  Timer? _settle;
  Timer? _statusFade;
  int _generation = 0;
  bool _unavailableReported = false;

  /// 暂停自动 OCR 的状态：给用户一个轻量反馈，知道这一帧识别过了（以前完全无提示，
  /// 用户不知道暂停后已经可以点字）。
  GraphicSubtitlePauseOcrStatus _status = GraphicSubtitlePauseOcrStatus.idle;

  /// 当前状态标记对应的帧是不是图片字幕帧（决定标记说「字幕」还是「画面文字」）。
  bool _statusGraphic = true;

  /// 暂停在图片字幕帧上、识别又关着：显示「可开启 OCR」提示（BUG-3342）。
  bool _offerEnable = false;

  /// 用户关掉了本次播放的开启提示。
  bool _enableHintDismissed = false;

  /// 手动识别已请求、但还没落到一个暂停帧上（请求时正在播放，页面先发了暂停）。
  bool _manualPending = false;

  /// 手动豁免的那一帧；帧键一变就清空。
  _FrameKey? _manualKey;

  /// 当前帧有一次识别在途（截帧 / 识别 / 退避重截）。
  bool _inFlight = false;

  /// 当前帧的识别是不是手动豁免出来的（决定「没有字」与不可用提示照报）。
  bool get _manualFrame => _manualKey != null && _manualKey == _key;

  /// 可点字层（[Stack]）：点字时把全局落点换算进本层坐标。
  final GlobalKey _charLayerKey = GlobalKey();

  /// 最近一次布局的可点字层：哪一帧、各字在本层的框、控件 / 显示尺寸。点字时在这
  /// 份几何上裁决命中（[graphicSubtitleOcrHitTest]）。
  _CharLayout? _charLayout;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChanged);
    // 首帧 build 之前：直接赋值，不走 setState。
    _offerEnable = _enableHintWanted();
    _onControllerChanged();
  }

  @override
  void didUpdateWidget(VideoGraphicSubtitleOcrOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller.removeListener(_onControllerChanged);
      widget.controller.addListener(_onControllerChanged);
      _reset();
      _key = null;
      _manualKey = null;
      _manualPending = false;
      _onControllerChanged();
    } else if (oldWidget.manualRequestSerial != widget.manualRequestSerial) {
      _requestManualRecognition();
    } else if (oldWidget.scope != widget.scope) {
      _onControllerChanged();
    } else {
      _syncEnableHint();
    }
  }

  /// 手动识别一次：已经暂停就落到当前帧；正在播放（页面刚发了暂停、状态还没回来）就
  /// 挂起，等第一次停下来的那一帧。没有可识别的帧（未出首帧 / 网页后端）直接作废。
  void _requestManualRecognition() {
    final VideoPlayerController c = widget.controller;
    if (c.isPlaying) {
      _manualPending = true;
      return;
    }
    final _FrameKey? raw = _pausedFrameKey();
    if (raw == null) return;
    _manualKey = raw;
    if (raw != _key) {
      _onControllerChanged();
      return;
    }
    // 当前帧已经在识别 / 识别过：不重复识别，只把结果再亮一次给用户看。
    if (_inFlight || _settle != null) return;
    final GraphicSubtitleOcrFrame? frame = _frame;
    if (frame != null) {
      _setStatus(
        frame.isEmpty
            ? GraphicSubtitlePauseOcrStatus.empty
            : GraphicSubtitlePauseOcrStatus.ready,
      );
      return;
    }
    // 上一次在这一帧上没拿到结果（引擎不可用 / 出错）：用户主动要求，再跑一次。
    unawaited(_recognize());
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    _settle?.cancel();
    _statusFade?.cancel();
    _generation++;
    unawaited(_session?.close());
    _session = null;
    super.dispose();
  }

  /// 暂停着、能截帧时的帧键（不看 [VideoGraphicSubtitleOcrOverlay.scope]）。
  _FrameKey? _pausedFrameKey() {
    final VideoPlayerController c = widget.controller;
    if (c.isPlaying || !c.hasFirstFrame) return null;
    // 截不了帧（网页档的 DRM 站点）：识别不了，不截、不重截。非 DRM 站点照常识别。
    if (!c.canCaptureFrame) return null;
    final int? position = c.positionMs;
    if (position == null) return null;
    return (positionMs: position, trackId: c.activeSubtitleTrackId);
  }

  /// 该识别的帧键：暂停帧且（范围允许，或是手动豁免的那一帧）。
  _FrameKey? _currentKey() {
    final _FrameKey? raw = _pausedFrameKey();
    if (raw == null) return null;
    if (raw == _manualKey) return raw;
    if (!widget.scope.shouldRecognize(
      graphicSubtitleActive: widget.controller.isPlayerRenderedSubtitleActive,
    )) {
      return null;
    }
    return raw;
  }

  /// 手动豁免的生命周期：挂起的请求落到第一次停下的帧上；豁免帧之外的任何帧
  /// （继续播放 / seek / 换轨）一出现就解除。
  void _syncManualRequest() {
    if (_manualPending && !widget.controller.isPlaying) {
      _manualPending = false;
      _manualKey = _pausedFrameKey();
      return;
    }
    if (_manualKey != null && _pausedFrameKey() != _manualKey) {
      _manualKey = null;
    }
  }

  bool _enableHintWanted() {
    final VideoPlayerController c = widget.controller;
    if (widget.onEnableRequested == null || _enableHintDismissed) return false;
    if (c.isPlaying || !c.hasFirstFrame) return false;
    // 这一帧已经按用户要求手动识别了，不再劝「开启」。
    if (_manualKey != null && _manualKey == _pausedFrameKey()) return false;
    return widget.scope.offersEnableHint(
      graphicSubtitleActive: c.isPlayerRenderedSubtitleActive,
    );
  }

  void _syncEnableHint() {
    final bool wanted = _enableHintWanted();
    if (wanted == _offerEnable) return;
    if (mounted) {
      setState(() => _offerEnable = wanted);
    } else {
      _offerEnable = wanted;
    }
  }

  void _dismissEnableHint() {
    _enableHintDismissed = true;
    _syncEnableHint();
  }

  void _onControllerChanged() {
    _syncManualRequest();
    _syncEnableHint();
    final _FrameKey? key = _currentKey();
    if (key == _key) return;
    _reset();
    _key = key;
    if (key == null) return;
    _settle = Timer(kGraphicSubtitleOcrSettleDelay, () => _recognize());
  }

  /// 丢弃当前结果与在途识别（播放 / seek / 换轨）。
  void _reset() {
    _settle?.cancel();
    _settle = null;
    _generation++;
    _inFlight = false;
    _setStatus(GraphicSubtitlePauseOcrStatus.idle);
    if (_frame != null && mounted) setState(() => _frame = null);
    _frame = null;
  }

  void _setStatus(GraphicSubtitlePauseOcrStatus status) {
    _statusFade?.cancel();
    _statusFade = null;
    if (graphicSubtitlePauseOcrStatusAutoHides(status)) {
      final int generation = _generation;
      _statusFade = Timer(kGraphicSubtitleOcrStatusHintDuration, () {
        if (mounted && generation == _generation) {
          _setStatus(GraphicSubtitlePauseOcrStatus.idle);
        }
      });
    }
    if (status == _status) return;
    if (mounted) {
      setState(() => _status = status);
    } else {
      _status = status;
    }
  }

  /// [attempt]：这一帧第几次重截（0 = 首次），见 [kGraphicSubtitleOcrCaptureRetryDelays]。
  Future<void> _recognize({int attempt = 0}) async {
    final int generation = _generation;
    bool stale() => !mounted || generation != _generation;
    final bool graphic = widget.controller.isPlayerRenderedSubtitleActive;
    final bool manual = _manualFrame;
    _settle = null;
    _inFlight = true;
    bool retrying = false;
    try {
      final OcrRgbaImage? captured =
          await (widget.captureFrame ??
              widget.controller.captureFrameWithSubtitles)();
      if (stale()) return;
      if (captured == null) {
        retrying = _retryCapture(attempt);
        return;
      }
      _statusGraphic = graphic;
      _setStatus(GraphicSubtitlePauseOcrStatus.recognizing);
      final GraphicSubtitleOcrFrame? frame = await _recognizeFrame(
        captured,
        stale,
      );
      if (frame == null || stale()) return;
      setState(() => _frame = frame);
      // 「这一帧没有字」只对图形字幕有意义（那里本该有字幕）；普通画面没字是常态。
      // 手动识别是用户点名要看这一帧，没字也要告诉他。
      _setStatus(switch ((frame.isEmpty, graphic || manual)) {
        (false, _) => GraphicSubtitlePauseOcrStatus.ready,
        (true, true) => GraphicSubtitlePauseOcrStatus.empty,
        (true, false) => GraphicSubtitlePauseOcrStatus.idle,
      });
    } on GraphicSubtitleOcrUnavailable catch (e) {
      if (!stale()) _setStatus(GraphicSubtitlePauseOcrStatus.idle);
      if (!mounted) return;
      if (!manual && (_unavailableReported || !graphic)) return;
      _unavailableReported = true;
      widget.onUnavailable?.call(e.reason);
    } catch (error, stack) {
      if (!stale()) _setStatus(GraphicSubtitlePauseOcrStatus.idle);
      if (mounted) widget.onError?.call(error, stack);
    } finally {
      if (!stale() && !retrying) _inFlight = false;
    }
  }

  /// 这一帧截帧没拿到图：按退避重截；重截机会用完就记一条错误（截帧失败本身不抛异常，
  /// 不记就没有任何证据）。重截挂在 [_settle] 上，帧一变由 [_reset] 一起取消。
  /// 返回是否排了重截。
  bool _retryCapture(int attempt) {
    if (attempt < kGraphicSubtitleOcrCaptureRetryDelays.length) {
      _settle = Timer(
        kGraphicSubtitleOcrCaptureRetryDelays[attempt],
        () => _recognize(attempt: attempt + 1),
      );
      return true;
    }
    widget.onError?.call(
      StateError(
        'pause OCR frame capture returned no image after '
        '${attempt + 1} attempts',
      ),
      StackTrace.current,
    );
    return false;
  }

  Future<GraphicSubtitleOcrFrame?> _recognizeFrame(
    OcrRgbaImage captured,
    bool Function() stale,
  ) {
    final Future<GraphicSubtitleOcrFrame?> Function(OcrRgbaImage)? injected =
        widget.recognizeFrame;
    if (injected != null) return injected(captured);
    final GraphicSubtitleOcrSession session = _session ??=
        GraphicSubtitleOcrSession(prepare: widget.prepare);
    return session.recognize(
      captured,
      onRefined: (GraphicSubtitleOcrFrame refined) {
        if (!stale()) setState(() => _frame = refined);
      },
      onRefineError: (Object error, StackTrace stack) {
        if (!stale()) widget.onError?.call(error, stack);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final Widget pill = Positioned(
      top: widget.statusTopInset,
      left: 16,
      right: 16,
      child: Center(
        child: AnimatedSwitcher(
          duration: fushiMotionDuration(context, FushiMotion.medium),
          switchInCurve: FushiMotion.enter,
          switchOutCurve: FushiMotion.exit,
          transitionBuilder: (Widget child, Animation<double> animation) =>
              FadeTransition(opacity: animation, child: child),
          child: _offerEnable
              ? VideoPauseOcrEnableHint(
                  onEnable: () => widget.onEnableRequested?.call(),
                  onDismiss: _dismissEnableHint,
                )
              : VideoGraphicSubtitleOcrStatusPill(
                  status: _status,
                  graphicSubtitle: _statusGraphic,
                ),
        ),
      ),
    );
    final GraphicSubtitleOcrFrame? frame = _frame;
    if (frame == null || frame.isEmpty) {
      return Stack(children: <Widget>[pill]);
    }
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final Size viewSize = constraints.biggest;
        final int? dw = widget.controller.videoWidth;
        final int? dh = widget.controller.videoHeight;
        final Size displaySize = dw != null && dh != null && dw > 0 && dh > 0
            ? Size(dw.toDouble(), dh.toDouble())
            : frame.imageSize;
        final List<Rect> rects = <Rect>[
          for (final GraphicSubtitleOcrChar char in frame.chars)
            graphicSubtitleImageRectToView(
              imageRect: char.rect,
              imageSize: frame.imageSize,
              displaySize: displaySize,
              viewSize: viewSize,
              fit: widget.fit,
            ),
        ];
        _charLayout = (
          frame: frame,
          rects: rects,
          viewSize: viewSize,
          displaySize: displaySize,
        );
        // 每个字框只管「这一击归不归本层」与鼠标手形；点中哪个字由整层几何裁决
        // （[_handleCharTap]），不看框的叠放顺序。
        return Stack(
          key: _charLayerKey,
          children: <Widget>[
            for (final Rect rect in rects)
              Positioned.fromRect(
                rect: rect,
                child: _CharHitBox(onTapUp: _handleCharTap),
              ),
            pill,
          ],
        );
      },
    );
  }

  void _handleCharTap(Offset globalPosition) {
    final _CharLayout? layout = _charLayout;
    final RenderBox? layer =
        _charLayerKey.currentContext?.findRenderObject() as RenderBox?;
    if (layout == null || layer == null || !layer.hasSize) return;
    final Offset point = layer.globalToLocal(globalPosition);
    final int? hit = graphicSubtitleOcrHitTest(
      charRects: layout.rects,
      point: point,
    );
    if (hit == null) return;
    ErrorLogService.instance.logDiagnostic(
      'video.pause_ocr_tap',
      graphicSubtitleOcrTapDiagnostic(
        frame: layout.frame,
        viewRects: layout.rects,
        point: point,
        hit: hit,
        viewSize: layout.viewSize,
        displaySize: layout.displaySize,
        fit: widget.fit,
      ),
    );
    final GraphicSubtitleOcrChar char = layout.frame.chars[hit];
    final Rect local = layout.rects[hit];
    widget.onCharTap(
      char.sentence,
      char.graphemeIndex,
      Rect.fromPoints(
        layer.localToGlobal(local.topLeft),
        layer.localToGlobal(local.bottomRight),
      ),
    );
  }
}

/// 可点字层的几何快照（见 `_charLayout`）。
typedef _CharLayout = ({
  GraphicSubtitleOcrFrame frame,
  List<Rect> rects,
  Size viewSize,
  Size displaySize,
});

class _CharHitBox extends StatelessWidget {
  const _CharHitBox({required this.onTapUp});

  /// 点在这个字框里（全局坐标）；命中哪个字由覆盖层整层裁决。
  final void Function(Offset globalPosition) onTapUp;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: (TapUpDetails details) => onTapUp(details.globalPosition),
      ),
    );
  }
}
