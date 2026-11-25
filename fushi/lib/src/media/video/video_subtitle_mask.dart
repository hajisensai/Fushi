/// 视频「字幕遮布」：一块用户自己摆放的矩形，盖住烧进画面的硬字幕（典型是内嵌中文
/// 字幕——学日语时只想看日文 / Fushi 自己的字幕层）。
///
/// - 位置以**视频画面内容区**的比例保存（0..1 的 left/top/width/height），按当前
///   [BoxFit] 映射到视口：窗口缩放、全屏、黑边（letterbox）变化后仍盖在画面同一处。
/// - 层级：挂在 Fushi 文本字幕层之下、画面之上——遮布盖住硬字幕，Fushi 渲染的字幕仍
///   压在遮布上面可读可查词。平时 [IgnorePointer]，不抢点击 / 查词 / 控制条。
/// - 编辑：[VideoSubtitleMaskEditLayer] 挂在 chrome 层，拖动整体移动、拖四角缩放，
///   拖动中通过共享的 [ValueNotifier] 让下层遮布实时跟随，松手才落偏好。
///
/// 已知边界：mpv 截图（制卡截图 / 片段导出）拿的是解码帧，不含 Flutter 叠层，遮布不会
/// 出现在卡片截图里。
library;

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/video/graphic_subtitle_ocr.dart';
import 'package:fushi/src/media/video/smart_subtitle_mask_sampler.dart';
import 'package:fushi/src/media/video/video_player_controller.dart';
import 'package:fushi/src/media/video/video_subtitle_mask_config.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';

/// 视频画面内容区在视口里的矩形（按 [fit]，含黑边计算；cover 时可超出视口）。
/// 视频尺寸未知时退回整个视口。
Rect videoSubtitleMaskContentRect({
  required Size? frame,
  required Size view,
  required BoxFit fit,
}) {
  if (view.isEmpty) return Rect.zero;
  if (frame == null || frame.isEmpty) return Offset.zero & view;
  return graphicSubtitleImageRectToView(
    imageRect: Offset.zero & frame,
    imageSize: frame,
    displaySize: frame,
    viewSize: view,
    fit: fit,
  );
}

/// 比例矩形 → 视口像素矩形。
Rect videoSubtitleMaskFractionToView(Rect fraction, Rect content) =>
    Rect.fromLTWH(
      content.left + fraction.left * content.width,
      content.top + fraction.top * content.height,
      fraction.width * content.width,
      fraction.height * content.height,
    );

/// 模糊强度 → 模糊半径（按遮布像素高度取比例，再限一个绝对上下限）。
double videoSubtitleMaskBlurSigma(double strength, double heightPx) =>
    (heightPx * 0.25 * strength).clamp(2.0, 30.0);

/// 监听控制器的视频尺寸（只在宽高变化时重建，不跟播放位置的高频通知）。
class _VideoFrameSizeListener extends StatefulWidget {
  const _VideoFrameSizeListener({
    required this.controller,
    required this.builder,
  });

  final VideoPlayerController controller;
  final Widget Function(BuildContext context, Size? frame) builder;

  @override
  State<_VideoFrameSizeListener> createState() =>
      _VideoFrameSizeListenerState();
}

class _VideoFrameSizeListenerState extends State<_VideoFrameSizeListener> {
  Size? _frame;

  Size? _read() {
    final int? w = widget.controller.videoWidth;
    final int? h = widget.controller.videoHeight;
    if (w == null || h == null || w <= 0 || h <= 0) return null;
    return Size(w.toDouble(), h.toDouble());
  }

  @override
  void initState() {
    super.initState();
    _frame = _read();
    widget.controller.addListener(_onChanged);
  }

  @override
  void didUpdateWidget(_VideoFrameSizeListener oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onChanged);
      widget.controller.addListener(_onChanged);
      _frame = _read();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    final Size? next = _read();
    if (next != _frame) setState(() => _frame = next);
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _frame);
}

/// 遮布本体（画面之上、Fushi 字幕之下）。关闭时零开销。
///
/// 智能模式（[VideoSubtitleMaskMode.smart]）下本层持有 [SmartSubtitleMaskSampler]：
/// 开着才建、关掉或切回手动即拆，遮布矩形跟着采样结果走，没字时淡出。
class VideoSubtitleMaskLayer extends StatefulWidget {
  const VideoSubtitleMaskLayer({
    required this.controller,
    required this.fit,
    required this.config,
    required this.draftRect,
    this.createSmartDetector,
    this.smartDetectorIdentity,
    this.onSmartUnavailable,
    this.onSmartError,
    super.key,
  });

  final VideoPlayerController controller;
  final BoxFit fit;
  final VideoSubtitleMaskConfig config;

  /// 编辑中的实时矩形（比例坐标）；null = 用 [config.rect]。
  final ValueListenable<Rect?> draftRect;

  /// 智能模式的识别器工厂；null 时智能模式退化成手动（整块常显）。
  final SmartSubtitleMaskDetector Function()? createSmartDetector;

  /// 识别器的身份（宿主用模型 key、模型下载状态等拼成）：值一变就拆掉现有识别器与
  /// 采样器按新身份重建——换模型 / 模型刚下载好时，之前判成「不可用」的采样器不会
  /// 一直退化下去。null = 识别器不随外部状态变化。
  final ValueListenable<Object?>? smartDetectorIdentity;

  /// 识别器不可用（本机 OCR 模型没下载）：每个采样器只报一次。
  final VoidCallback? onSmartUnavailable;

  final void Function(Object error, StackTrace stack)? onSmartError;

  @override
  State<VideoSubtitleMaskLayer> createState() => _VideoSubtitleMaskLayerState();
}

class _VideoSubtitleMaskLayerState extends State<VideoSubtitleMaskLayer> {
  SmartSubtitleMaskSampler? _sampler;
  SmartSubtitleMaskDetector? _detector;

  bool get _wantsSampler =>
      widget.config.enabled &&
      widget.config.mode == VideoSubtitleMaskMode.smart &&
      widget.createSmartDetector != null;

  @override
  void initState() {
    super.initState();
    widget.smartDetectorIdentity?.addListener(_onDetectorIdentityChanged);
    _syncSampler();
  }

  @override
  void didUpdateWidget(VideoSubtitleMaskLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    final ValueListenable<Object?>? oldIdentity =
        oldWidget.smartDetectorIdentity;
    final ValueListenable<Object?>? identity = widget.smartDetectorIdentity;
    if (!identical(oldIdentity, identity)) {
      oldIdentity?.removeListener(_onDetectorIdentityChanged);
      identity?.addListener(_onDetectorIdentityChanged);
    }
    if (!identical(oldWidget.controller, widget.controller) ||
        oldIdentity?.value != identity?.value) {
      _disposeSampler();
    }
    _syncSampler();
  }

  @override
  void dispose() {
    widget.smartDetectorIdentity?.removeListener(_onDetectorIdentityChanged);
    _disposeSampler();
    super.dispose();
  }

  void _onDetectorIdentityChanged() {
    if (_sampler == null) return;
    setState(() {
      _disposeSampler();
      _syncSampler();
    });
  }

  void _syncSampler() {
    if (!_wantsSampler) {
      _disposeSampler();
      return;
    }
    final SmartSubtitleMaskSampler? sampler = _sampler;
    if (sampler != null) {
      sampler.region = widget.config.rect;
      return;
    }
    final SmartSubtitleMaskDetector detector = _detector =
        widget.createSmartDetector!();
    _sampler = SmartSubtitleMaskSampler(
      controller: widget.controller,
      region: widget.config.rect,
      detect: detector.detect,
      onUnavailable: () => widget.onSmartUnavailable?.call(),
      onError: (Object e, StackTrace s) => widget.onSmartError?.call(e, s),
    );
  }

  void _disposeSampler() {
    _sampler?.dispose();
    _sampler = null;
    final SmartSubtitleMaskDetector? detector = _detector;
    _detector = null;
    if (detector != null) unawaited(detector.dispose());
  }

  @override
  Widget build(BuildContext context) {
    final SmartSubtitleMaskSampler? sampler = _sampler;
    return ValueListenableBuilder<Rect?>(
      valueListenable: widget.draftRect,
      builder: (BuildContext context, Rect? draft, _) {
        if (draft != null) {
          return _build(context, draft, visible: true, animate: false);
        }
        if (sampler == null) {
          // 手动模式；智能模式但没有识别器时同样整块常显。
          return _build(
            context,
            widget.config.rect,
            visible: widget.config.enabled,
            animate: false,
          );
        }
        return ValueListenableBuilder<Rect?>(
          valueListenable: sampler.rect,
          builder: (BuildContext context, Rect? smart, _) =>
              _build(context, smart, visible: smart != null, animate: true),
        );
      },
    );
  }

  /// 最近一次可见的矩形：智能遮布淡出时停在原处淡，不跳回默认位置。
  Rect? _lastFraction;

  /// [animate]：智能遮布换句时矩形平滑过渡；手动 / 编辑拖动时跟手、不过渡。
  Widget _build(
    BuildContext context,
    Rect? fraction, {
    required bool visible,
    required bool animate,
  }) {
    if (fraction != null) _lastFraction = fraction;
    final Rect? target = fraction ?? _lastFraction;
    final Duration duration = fushiMotionDuration(context, FushiMotion.short);
    final Duration rectDuration = animate ? duration : Duration.zero;
    return IgnorePointer(
      child: AnimatedOpacity(
        opacity: visible ? 1 : 0,
        duration: duration,
        curve: FushiMotion.standard,
        // 手动遮布关着时零开销（不建模糊层）；智能遮布淡出时留在原处淡掉（透明度 0
        // 时不绘制）。
        child: !visible && (!animate || target == null)
            ? const SizedBox.expand()
            : _VideoFrameSizeListener(
                controller: widget.controller,
                builder: (BuildContext context, Size? frame) => LayoutBuilder(
                  builder: (BuildContext context, BoxConstraints constraints) {
                    final Rect content = videoSubtitleMaskContentRect(
                      frame: frame,
                      view: constraints.biggest,
                      fit: widget.fit,
                    );
                    return TweenAnimationBuilder<Rect?>(
                      tween: RectTween(end: target),
                      duration: rectDuration,
                      curve: FushiMotion.standard,
                      builder: (BuildContext context, Rect? animated, _) {
                        if (animated == null) return const SizedBox.expand();
                        final Rect px = videoSubtitleMaskFractionToView(
                          animated,
                          content,
                        ).intersect(Offset.zero & constraints.biggest);
                        if (px.isEmpty) return const SizedBox.expand();
                        return Stack(
                          children: <Widget>[
                            Positioned.fromRect(
                              rect: px,
                              child: _MaskSurface(
                                style: widget.config.style,
                                strength: widget.config.strength,
                                heightPx: px.height,
                              ),
                            ),
                          ],
                        );
                      },
                    );
                  },
                ),
              ),
      ),
    );
  }
}

class _MaskSurface extends StatelessWidget {
  const _MaskSurface({
    required this.style,
    required this.strength,
    required this.heightPx,
  });

  final VideoSubtitleMaskStyle style;
  final double strength;
  final double heightPx;

  @override
  Widget build(BuildContext context) {
    final BorderRadius radius = BorderRadius.circular(
      (heightPx * 0.12).clamp(2.0, 12.0),
    );
    switch (style) {
      case VideoSubtitleMaskStyle.solid:
        return DecoratedBox(
          key: const ValueKey<String>('video-subtitle-mask-solid'),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: strength.clamp(0.05, 1.0)),
            borderRadius: radius,
          ),
        );
      case VideoSubtitleMaskStyle.blur:
        final double sigma = videoSubtitleMaskBlurSigma(strength, heightPx);
        return ClipRRect(
          borderRadius: radius,
          child: BackdropFilter(
            key: const ValueKey<String>('video-subtitle-mask-blur'),
            filter: ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
            // 轻微压暗：纯模糊在高对比描边字上仍能看出轮廓。
            child: ColoredBox(
              color: Colors.black.withValues(alpha: 0.18 * strength),
            ),
          ),
        );
    }
  }
}

/// 遮布编辑层（挂在 chrome 层，最上面）：遮布框可拖动、四角可缩放（「重置 / 完成」
/// 横幅由页面挂）。拖动只改 [draftRect]，松手经 [onCommit] 落偏好。
class VideoSubtitleMaskEditLayer extends StatefulWidget {
  const VideoSubtitleMaskEditLayer({
    required this.controller,
    required this.fit,
    required this.config,
    required this.draftRect,
    required this.onCommit,
    super.key,
  });

  final VideoPlayerController controller;
  final BoxFit fit;
  final VideoSubtitleMaskConfig config;
  final ValueNotifier<Rect?> draftRect;
  final ValueChanged<Rect> onCommit;

  @override
  State<VideoSubtitleMaskEditLayer> createState() =>
      _VideoSubtitleMaskEditLayerState();
}

enum _MaskHandle { move, topLeft, topRight, bottomLeft, bottomRight }

class _VideoSubtitleMaskEditLayerState
    extends State<VideoSubtitleMaskEditLayer> {
  Rect get _current => widget.draftRect.value ?? widget.config.rect;

  @override
  void initState() {
    super.initState();
    widget.draftRect.addListener(_onDraft);
  }

  @override
  void didUpdateWidget(VideoSubtitleMaskEditLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.draftRect != widget.draftRect) {
      oldWidget.draftRect.removeListener(_onDraft);
      widget.draftRect.addListener(_onDraft);
    }
  }

  @override
  void dispose() {
    widget.draftRect.removeListener(_onDraft);
    super.dispose();
  }

  void _onDraft() => setState(() {});

  void _drag(_MaskHandle handle, Offset deltaPx, Rect content) {
    if (content.isEmpty) return;
    final double dx = deltaPx.dx / content.width;
    final double dy = deltaPx.dy / content.height;
    final Rect r = _current;
    const double min = kVideoSubtitleMaskMinFraction;
    Rect next;
    switch (handle) {
      case _MaskHandle.move:
        next = r.shift(Offset(dx, dy));
      case _MaskHandle.topLeft:
        next = Rect.fromLTRB(
          (r.left + dx).clamp(0.0, r.right - min),
          (r.top + dy).clamp(0.0, r.bottom - min),
          r.right,
          r.bottom,
        );
      case _MaskHandle.topRight:
        next = Rect.fromLTRB(
          r.left,
          (r.top + dy).clamp(0.0, r.bottom - min),
          (r.right + dx).clamp(r.left + min, 1.0),
          r.bottom,
        );
      case _MaskHandle.bottomLeft:
        next = Rect.fromLTRB(
          (r.left + dx).clamp(0.0, r.right - min),
          r.top,
          r.right,
          (r.bottom + dy).clamp(r.top + min, 1.0),
        );
      case _MaskHandle.bottomRight:
        next = Rect.fromLTRB(
          r.left,
          r.top,
          (r.right + dx).clamp(r.left + min, 1.0),
          (r.bottom + dy).clamp(r.top + min, 1.0),
        );
    }
    widget.draftRect.value = clampVideoSubtitleMaskRect(next);
  }

  void _commit() {
    final Rect? draft = widget.draftRect.value;
    if (draft != null) widget.onCommit(draft);
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return _VideoFrameSizeListener(
      controller: widget.controller,
      builder: (BuildContext context, Size? frame) => LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final Rect content = videoSubtitleMaskContentRect(
            frame: frame,
            view: constraints.biggest,
            fit: widget.fit,
          );
          final Rect px = videoSubtitleMaskFractionToView(_current, content);
          const double handle = 24;
          Widget corner(_MaskHandle h, Alignment align, MouseCursor cursor) =>
              Align(
                alignment: align,
                child: MouseRegion(
                  cursor: cursor,
                  child: GestureDetector(
                    key: ValueKey<String>('video-subtitle-mask-${h.name}'),
                    behavior: HitTestBehavior.opaque,
                    onPanUpdate: (DragUpdateDetails d) =>
                        _drag(h, d.delta, content),
                    onPanEnd: (_) => _commit(),
                    child: SizedBox.square(
                      dimension: handle,
                      child: Center(
                        child: Container(
                          width: 12,
                          height: 12,
                          decoration: BoxDecoration(
                            color: cs.primary,
                            shape: BoxShape.circle,
                            border: Border.all(color: cs.onPrimary, width: 2),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              );
          return Stack(
            children: <Widget>[
              Positioned.fromRect(
                rect: px.inflate(handle / 2),
                child: Stack(
                  children: <Widget>[
                    Positioned.fill(
                      left: handle / 2,
                      top: handle / 2,
                      right: handle / 2,
                      bottom: handle / 2,
                      child: MouseRegion(
                        cursor: SystemMouseCursors.move,
                        child: GestureDetector(
                          key: const ValueKey<String>(
                            'video-subtitle-mask-move',
                          ),
                          behavior: HitTestBehavior.opaque,
                          onPanUpdate: (DragUpdateDetails d) =>
                              _drag(_MaskHandle.move, d.delta, content),
                          onPanEnd: (_) => _commit(),
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              border: Border.all(color: cs.primary, width: 2),
                              color: cs.primary.withValues(alpha: 0.08),
                            ),
                          ),
                        ),
                      ),
                    ),
                    corner(
                      _MaskHandle.topLeft,
                      Alignment.topLeft,
                      SystemMouseCursors.resizeUpLeft,
                    ),
                    corner(
                      _MaskHandle.topRight,
                      Alignment.topRight,
                      SystemMouseCursors.resizeUpRight,
                    ),
                    corner(
                      _MaskHandle.bottomLeft,
                      Alignment.bottomLeft,
                      SystemMouseCursors.resizeDownLeft,
                    ),
                    corner(
                      _MaskHandle.bottomRight,
                      Alignment.bottomRight,
                      SystemMouseCursors.resizeDownRight,
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
