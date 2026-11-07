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

import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/video/graphic_subtitle_ocr.dart';
import 'package:fushi/src/media/video/video_player_controller.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';

/// 遮布外观。
enum VideoSubtitleMaskStyle {
  /// 背景模糊（默认）：糊开字形，画面色调仍在，观感最轻。
  blur,

  /// 纯色块：彻底挡住，强度 = 不透明度。
  solid,
}

/// 遮布最小边长（画面比例），防止缩成看不见、抓不住的一条线。
const double kVideoSubtitleMaskMinFraction = 0.03;

/// 遮布配置（偏好 `video_subtitle_mask` 的 JSON 形态）。
@immutable
class VideoSubtitleMaskConfig {
  const VideoSubtitleMaskConfig({
    this.enabled = false,
    this.rect = kDefaultRect,
    this.style = VideoSubtitleMaskStyle.blur,
    this.strength = 0.85,
  });

  /// 默认摆在画面底部居中、约一行硬字幕高——中文内嵌字幕最常见的位置。
  static const Rect kDefaultRect = Rect.fromLTWH(0.15, 0.82, 0.7, 0.12);

  final bool enabled;

  /// 画面内容区比例坐标（0..1）。
  final Rect rect;
  final VideoSubtitleMaskStyle style;

  /// 0..1：模糊时映射成模糊半径，纯色时就是不透明度。
  final double strength;

  VideoSubtitleMaskConfig copyWith({
    bool? enabled,
    Rect? rect,
    VideoSubtitleMaskStyle? style,
    double? strength,
  }) => VideoSubtitleMaskConfig(
    enabled: enabled ?? this.enabled,
    rect: rect == null ? this.rect : clampVideoSubtitleMaskRect(rect),
    style: style ?? this.style,
    strength: (strength ?? this.strength).clamp(0.0, 1.0),
  );

  String toJson() => jsonEncode(<String, Object>{
    'enabled': enabled,
    'l': rect.left,
    't': rect.top,
    'w': rect.width,
    'h': rect.height,
    'style': style.name,
    'strength': strength,
  });

  /// 解析偏好；缺字段 / 坏值逐项回落默认，整串坏掉回落整份默认。
  static VideoSubtitleMaskConfig fromJson(String? raw) {
    if (raw == null || raw.isEmpty) return const VideoSubtitleMaskConfig();
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is! Map<String, Object?>) {
        return const VideoSubtitleMaskConfig();
      }
      double readNum(String key, double fallback) {
        final Object? v = decoded[key];
        return v is num && v.isFinite ? v.toDouble() : fallback;
      }

      const Rect d = kDefaultRect;
      final Object? styleName = decoded['style'];
      return VideoSubtitleMaskConfig(
        enabled: decoded['enabled'] == true,
        rect: clampVideoSubtitleMaskRect(
          Rect.fromLTWH(
            readNum('l', d.left),
            readNum('t', d.top),
            readNum('w', d.width),
            readNum('h', d.height),
          ),
        ),
        style: VideoSubtitleMaskStyle.values.firstWhere(
          (VideoSubtitleMaskStyle s) => s.name == styleName,
          orElse: () => VideoSubtitleMaskStyle.blur,
        ),
        strength: readNum('strength', 0.85).clamp(0.0, 1.0),
      );
    } on FormatException {
      return const VideoSubtitleMaskConfig();
    }
  }

  @override
  bool operator ==(Object other) =>
      other is VideoSubtitleMaskConfig &&
      other.enabled == enabled &&
      other.rect == rect &&
      other.style == style &&
      other.strength == strength;

  @override
  int get hashCode => Object.hash(enabled, rect, style, strength);
}

/// 把比例矩形钳进画面：尺寸不小于 [kVideoSubtitleMaskMinFraction]、不大于整幅，
/// 位置平移回 0..1 内（保尺寸、只挪位置）。
Rect clampVideoSubtitleMaskRect(Rect r) {
  const double min = kVideoSubtitleMaskMinFraction;
  final double w = r.width.isFinite ? r.width.clamp(min, 1.0) : min;
  final double h = r.height.isFinite ? r.height.clamp(min, 1.0) : min;
  final double l = r.left.isFinite ? r.left.clamp(0.0, 1.0 - w) : 0.0;
  final double t = r.top.isFinite ? r.top.clamp(0.0, 1.0 - h) : 0.0;
  return Rect.fromLTWH(l, t, w, h);
}

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
class VideoSubtitleMaskLayer extends StatelessWidget {
  const VideoSubtitleMaskLayer({
    required this.controller,
    required this.fit,
    required this.config,
    required this.draftRect,
    super.key,
  });

  final VideoPlayerController controller;
  final BoxFit fit;
  final VideoSubtitleMaskConfig config;

  /// 编辑中的实时矩形（比例坐标）；null = 用 [config.rect]。
  final ValueListenable<Rect?> draftRect;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Rect?>(
      valueListenable: draftRect,
      builder: (BuildContext context, Rect? draft, _) {
        // 编辑中即使开关是关的也显示，让用户看到正在摆的位置。
        final bool visible = config.enabled || draft != null;
        return IgnorePointer(
          child: AnimatedOpacity(
            opacity: visible ? 1 : 0,
            duration: fushiMotionDuration(context, FushiMotion.short),
            curve: FushiMotion.standard,
            child: !visible
                ? const SizedBox.expand()
                : _VideoFrameSizeListener(
                    controller: controller,
                    builder: (BuildContext context, Size? frame) =>
                        LayoutBuilder(
                          builder:
                              (
                                BuildContext context,
                                BoxConstraints constraints,
                              ) {
                                final Rect content =
                                    videoSubtitleMaskContentRect(
                                      frame: frame,
                                      view: constraints.biggest,
                                      fit: fit,
                                    );
                                final Rect px = videoSubtitleMaskFractionToView(
                                  draft ?? config.rect,
                                  content,
                                ).intersect(Offset.zero & constraints.biggest);
                                if (px.isEmpty) return const SizedBox.expand();
                                return Stack(
                                  children: <Widget>[
                                    Positioned.fromRect(
                                      rect: px,
                                      child: _MaskSurface(
                                        style: config.style,
                                        strength: config.strength,
                                        heightPx: px.height,
                                      ),
                                    ),
                                  ],
                                );
                              },
                        ),
                  ),
          ),
        );
      },
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
