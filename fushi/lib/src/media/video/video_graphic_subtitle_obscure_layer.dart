/// 图形字幕（PGS / VobSub）的「模糊 / 隐藏」遮蔽：与文本字幕同一个三态开关
/// （`VideoSubtitleObscureMode`）、同一条显形门（暂停 / 查词浮层开着 / 悬停字幕区都让位，
/// 总闸关掉则恒定遮蔽），练听力时图形字幕也能遮住。
///
/// 图形字幕由 libmpv 直接画进画面，Flutter 拿不到字幕的文字层，所以两种视觉的做法不同：
/// - **隐藏**：切 libmpv `sub-visibility`（[VideoPlayerController.setGraphicSubtitleVisible]），
///   画面本身不受影响；
/// - **模糊**：在画面的字幕带（帧底部 [kGraphicSubtitleBandFraction]，图形对白字幕几乎都
///   摆在这里）上叠一层背景高斯模糊。字幕带里的画面会一起糊掉——这是没有字幕位图坐标时
///   能做到的最贴近的效果；字幕显形后整层撤掉。
library;

import 'dart:async';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/video/graphic_subtitle_ocr.dart';
import 'package:fushi/src/media/video/video_player_controller.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';

/// 模糊字幕带占视频帧高度的比例（自帧底向上）。
const double kGraphicSubtitleBandFraction = 0.3;

/// 图形字幕遮蔽的视觉。
enum GraphicSubtitleObscure { none, blur, hide }

/// 图形字幕遮蔽层。尺寸与视频控件一致；非图形字幕时零开销（不画任何东西）。
class VideoGraphicSubtitleObscureLayer extends StatefulWidget {
  const VideoGraphicSubtitleObscureLayer({
    required this.controller,
    required this.fit,
    required this.obscure,
    required this.revealOnInteraction,
    required this.lookupPopupVisible,
    super.key,
  });

  final VideoPlayerController controller;
  final BoxFit fit;
  final GraphicSubtitleObscure obscure;

  /// 遮蔽「悬停 / 暂停 / 查词时显形」总闸（与文本字幕同一偏好）。
  final bool revealOnInteraction;

  /// 查词浮层还开着也算「用户在看」（与文本字幕 BUG-2235 同一判据）。
  final bool lookupPopupVisible;

  @override
  State<VideoGraphicSubtitleObscureLayer> createState() =>
      _VideoGraphicSubtitleObscureLayerState();
}

/// 图形字幕此刻是否该遮蔽：与文本字幕 overlay 同一条门（`video_subtitle_overlay.dart`
/// 的 `obscureActive`）——开了遮蔽、没被悬停显形、用户也没在看（暂停 / 查词浮层开着）。
bool graphicSubtitleObscureActive({
  required GraphicSubtitleObscure obscure,
  required bool graphicActive,
  required bool hoverRevealed,
  required bool revealOnInteraction,
  required bool isPlaying,
  required bool lookupPopupVisible,
}) {
  if (obscure == GraphicSubtitleObscure.none || !graphicActive) return false;
  final bool userIsReading =
      revealOnInteraction && (!isPlaying || lookupPopupVisible);
  final bool revealed = revealOnInteraction && hoverRevealed;
  return !revealed && !userIsReading;
}

class _VideoGraphicSubtitleObscureLayerState
    extends State<VideoGraphicSubtitleObscureLayer> {
  bool _hovering = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChanged);
    _syncVisibility();
  }

  @override
  void didUpdateWidget(VideoGraphicSubtitleObscureLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller.removeListener(_onControllerChanged);
      unawaited(oldWidget.controller.setGraphicSubtitleVisible(true));
      widget.controller.addListener(_onControllerChanged);
    }
    _syncVisibility();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    // 离开（换页 / 关遮蔽层）时把图形字幕还原成可见，不把「隐藏」留在播放器上。
    unawaited(widget.controller.setGraphicSubtitleVisible(true));
    super.dispose();
  }

  bool get _obscureActive => graphicSubtitleObscureActive(
    obscure: widget.obscure,
    graphicActive: widget.controller.isPlayerRenderedSubtitleActive,
    hoverRevealed: _hovering,
    revealOnInteraction: widget.revealOnInteraction,
    isPlaying: widget.controller.isPlaying,
    lookupPopupVisible: widget.lookupPopupVisible,
  );

  /// 控制器通知很频繁（播放位置每拍都通知）；只有影响本层的几个量变了才重建。
  Object? _lastControllerKey;

  void _onControllerChanged() {
    final VideoPlayerController c = widget.controller;
    final Object key = (
      c.isPlayerRenderedSubtitleActive,
      c.isPlaying,
      c.videoWidth,
      c.videoHeight,
    );
    if (key == _lastControllerKey) return;
    _lastControllerKey = key;
    _syncVisibility();
    if (mounted) setState(() {});
  }

  /// 隐藏态下发 libmpv 可见性；其它视觉一律保持可见。
  void _syncVisibility() {
    final bool hide =
        widget.obscure == GraphicSubtitleObscure.hide && _obscureActive;
    unawaited(widget.controller.setGraphicSubtitleVisible(!hide));
  }

  void _setHovering(bool hovering) {
    if (_hovering == hovering) return;
    setState(() => _hovering = hovering);
    _syncVisibility();
  }

  @override
  Widget build(BuildContext context) {
    final VideoPlayerController c = widget.controller;
    if (widget.obscure == GraphicSubtitleObscure.none ||
        !c.isPlayerRenderedSubtitleActive) {
      return const SizedBox.shrink();
    }
    final bool blurred =
        widget.obscure == GraphicSubtitleObscure.blur && _obscureActive;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final Size view = constraints.biggest;
        final int? w = c.videoWidth;
        final int? h = c.videoHeight;
        if (w == null || h == null || w <= 0 || h <= 0) {
          return const SizedBox.shrink();
        }
        final Size frame = Size(w.toDouble(), h.toDouble());
        final Rect band = graphicSubtitleImageRectToView(
          imageRect: Rect.fromLTRB(
            0,
            frame.height * (1 - kGraphicSubtitleBandFraction),
            frame.width,
            frame.height,
          ),
          imageSize: frame,
          displaySize: frame,
          viewSize: view,
          fit: widget.fit,
        ).intersect(Offset.zero & view);
        if (band.isEmpty) return const SizedBox.shrink();
        return Stack(
          children: <Widget>[
            Positioned.fromRect(
              rect: band,
              child: MouseRegion(
                key: const ValueKey<String>('graphic_subtitle_obscure_band'),
                opaque: false,
                hitTestBehavior: HitTestBehavior.translucent,
                onEnter: (_) => _setHovering(true),
                onExit: (_) => _setHovering(false),
                child: IgnorePointer(
                  child: _BandBlur(
                    blurred: blurred,
                    sigma: (band.height * 0.06).clamp(6.0, 18.0),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// 字幕带的背景模糊，模糊强度随显形 / 遮蔽平滑过渡。
class _BandBlur extends StatelessWidget {
  const _BandBlur({required this.blurred, required this.sigma});

  final bool blurred;
  final double sigma;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(end: blurred ? sigma : 0),
      duration: fushiMotionDuration(context, FushiMotion.short),
      curve: FushiMotion.standard,
      builder: (BuildContext context, double value, Widget? child) {
        if (value <= 0.01) return const SizedBox.expand();
        return ClipRect(
          child: BackdropFilter(
            key: const ValueKey<String>('graphic_subtitle_obscure_blur'),
            filter: ui.ImageFilter.blur(sigmaX: value, sigmaY: value),
            child: const SizedBox.expand(),
          ),
        );
      },
    );
  }
}
