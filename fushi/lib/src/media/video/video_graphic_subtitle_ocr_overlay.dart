/// 暂停 OCR 查词覆盖层：暂停时截下当前帧（含 libmpv 自绘的字幕位图）做 OCR，
/// 在识别出的每个字上方铺一个透明可点区域，点字即查词。
///
/// 起初只为图形字幕（PGS / VobSub / DVB，没有 Dart 文字）而设；现在按
/// [VideoPauseOcrScope] 扩到所有视频（硬字幕、画面文字），Fushi 自绘的文字字幕在屏
/// 时让位给它（见 [VideoPauseOcrScope.shouldRecognize]）。
///
/// 识别与 AI 重读见 `graphic_subtitle_ocr.dart`；本层只负责「何时识别」与「摆在哪」。
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/video/graphic_subtitle_ocr.dart';
import 'package:fushi/src/media/video/video_pause_ocr_scope.dart';
import 'package:fushi/src/media/video/video_graphic_subtitle_ocr_progress.dart';
import 'package:fushi/src/media/video/video_player_controller.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';

/// 识别触发的防抖：逐帧步进 / 连续 seek 时只识别停下来的那一帧。
const Duration kGraphicSubtitleOcrSettleDelay = Duration(milliseconds: 250);

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

/// 图形字幕 OCR 查词覆盖层。尺寸须与视频控件一致（挂在 controls 层里）。
class VideoGraphicSubtitleOcrOverlay extends StatefulWidget {
  const VideoGraphicSubtitleOcrOverlay({
    required this.controller,
    required this.fit,
    required this.prepare,
    required this.onCharTap,
    this.scope = VideoPauseOcrScope.graphicSubtitles,
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

  /// 用户点了「开启」提示（BUG-3342）。识别关着、暂停在图片字幕帧上时才出现提示；
  /// null 时不提示。页面负责把范围写成开启并以新 [scope] 重建本层。
  final VoidCallback? onEnableRequested;

  /// 点中一个字：整句、句内字素下标、字在**全局**坐标系下的矩形。
  final void Function(String sentence, int graphemeIndex, Rect globalRect)
  onCharTap;

  /// 引擎不可用（每个会话只报一次；只在图形字幕帧上报——普通视频的暂停识别是
  /// 顺带的，没配 OCR 的用户不该每看一部片都被提示一次）。
  final void Function(GraphicSubtitleOcrUnavailableReason reason)?
  onUnavailable;

  /// 截帧 / 识别 / AI 重读出错。
  final void Function(Object error, StackTrace stack)? onError;

  /// 截帧；默认走 [VideoPlayerController.captureFrameWithSubtitles]（测试注入用）。
  final Future<Uint8List?> Function()? captureFrame;

  /// 识别一帧；默认走 [GraphicSubtitleOcrSession.recognize]（测试注入用，不触发
  /// AI 重读回调）。
  @visibleForTesting
  final Future<GraphicSubtitleOcrFrame?> Function(Uint8List frameBytes)?
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
      _onControllerChanged();
    } else if (oldWidget.scope != widget.scope) {
      _onControllerChanged();
    } else {
      _syncEnableHint();
    }
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

  _FrameKey? _currentKey() {
    final VideoPlayerController c = widget.controller;
    if (c.isPlaying || !c.hasFirstFrame) return null;
    if (!widget.scope.shouldRecognize(
      graphicSubtitleActive: c.isPlayerRenderedSubtitleActive,
      textCueOnScreen:
          c.activeCues.isNotEmpty || c.secondaryActiveCues.isNotEmpty,
      // 副字幕没有独立的加载态（由页面一次性 setSecondaryCues），只有内封主字幕的
      // 后台抽取有加载窗口。
      textCuesLoading: c.isSubtitleCuesLoading,
    )) {
      return null;
    }
    final int? position = c.positionMs;
    if (position == null) return null;
    return (positionMs: position, trackId: c.activeSubtitleTrackId);
  }

  bool _enableHintWanted() {
    final VideoPlayerController c = widget.controller;
    if (widget.onEnableRequested == null || _enableHintDismissed) return false;
    if (c.isPlaying || !c.hasFirstFrame) return false;
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
    _syncEnableHint();
    final _FrameKey? key = _currentKey();
    if (key == _key) return;
    _reset();
    _key = key;
    if (key == null) return;
    _settle = Timer(kGraphicSubtitleOcrSettleDelay, _recognize);
  }

  /// 丢弃当前结果与在途识别（播放 / seek / 换轨）。
  void _reset() {
    _settle?.cancel();
    _settle = null;
    _generation++;
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

  Future<void> _recognize() async {
    final int generation = _generation;
    bool stale() => !mounted || generation != _generation;
    final bool graphic = widget.controller.isPlayerRenderedSubtitleActive;
    try {
      final Uint8List? bytes =
          await (widget.captureFrame ??
              widget.controller.captureFrameWithSubtitles)();
      if (bytes == null || stale()) return;
      _statusGraphic = graphic;
      _setStatus(GraphicSubtitlePauseOcrStatus.recognizing);
      final GraphicSubtitleOcrFrame? frame = await _recognizeBytes(
        bytes,
        stale,
      );
      if (frame == null || stale()) return;
      setState(() => _frame = frame);
      // 「这一帧没有字」只对图形字幕有意义（那里本该有字幕）；普通画面没字是常态。
      _setStatus(switch ((frame.isEmpty, graphic)) {
        (false, _) => GraphicSubtitlePauseOcrStatus.ready,
        (true, true) => GraphicSubtitlePauseOcrStatus.empty,
        (true, false) => GraphicSubtitlePauseOcrStatus.idle,
      });
    } on GraphicSubtitleOcrUnavailable catch (e) {
      if (!stale()) _setStatus(GraphicSubtitlePauseOcrStatus.idle);
      if (_unavailableReported || !mounted || !graphic) return;
      _unavailableReported = true;
      widget.onUnavailable?.call(e.reason);
    } catch (error, stack) {
      if (!stale()) _setStatus(GraphicSubtitlePauseOcrStatus.idle);
      if (mounted) widget.onError?.call(error, stack);
    }
  }

  Future<GraphicSubtitleOcrFrame?> _recognizeBytes(
    Uint8List bytes,
    bool Function() stale,
  ) {
    final Future<GraphicSubtitleOcrFrame?> Function(Uint8List)? injected =
        widget.recognizeFrame;
    if (injected != null) return injected(bytes);
    final GraphicSubtitleOcrSession session = _session ??=
        GraphicSubtitleOcrSession(prepare: widget.prepare);
    return session.recognize(
      bytes,
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
        return Stack(
          children: <Widget>[
            for (final GraphicSubtitleOcrChar char in frame.chars)
              Positioned.fromRect(
                rect: graphicSubtitleImageRectToView(
                  imageRect: char.rect,
                  imageSize: frame.imageSize,
                  displaySize: displaySize,
                  viewSize: viewSize,
                  fit: widget.fit,
                ),
                child: _CharHitBox(char: char, onTap: widget.onCharTap),
              ),
            pill,
          ],
        );
      },
    );
  }
}

class _CharHitBox extends StatelessWidget {
  const _CharHitBox({required this.char, required this.onTap});

  final GraphicSubtitleOcrChar char;
  final void Function(String sentence, int graphemeIndex, Rect globalRect)
  onTap;

  void _handleTap(BuildContext context) {
    final RenderBox? box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final Offset topLeft = box.localToGlobal(Offset.zero);
    final Offset bottomRight = box.localToGlobal(
      box.size.bottomRight(Offset.zero),
    );
    onTap(
      char.sentence,
      char.graphemeIndex,
      Rect.fromPoints(topLeft, bottomRight),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: Builder(
        builder: (BuildContext context) => GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _handleTap(context),
        ),
      ),
    );
  }
}
