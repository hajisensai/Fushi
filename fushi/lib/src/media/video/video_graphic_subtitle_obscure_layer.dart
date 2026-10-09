/// 图形字幕（PGS / VobSub）的「模糊 / 隐藏」遮蔽：与文本字幕同一个三态开关
/// （`VideoSubtitleObscureMode`）、同一条显形门（暂停 / 查词浮层开着 / 悬停字幕区都让位，
/// 总闸关掉则恒定遮蔽），练听力时图形字幕也能遮住。
///
/// 图形字幕由 libmpv 直接画进画面，Flutter 拿不到字幕的文字层，所以两种视觉的做法不同：
/// - **隐藏**：切 libmpv `sub-visibility`（[VideoPlayerController.setGraphicSubtitleVisible]），
///   画面本身不受影响；
/// - **模糊**：只糊字幕位图本身占的矩形（略外扩），画面其余部分保持清晰。位图坐标
///   来自抽轨解析出的 PGS 时间表（[GraphicSubtitleRegionLoader]），按当前播放位置取
///   正在显示的句子，没有字幕的时刻画面完全不糊。时间表还没抽好、或这条轨抽不出坐标
///   （VobSub / DVB / 远端流）时，退回整条字幕带（帧底 [kGraphicSubtitleBandFraction]）。
///   字幕显形后整层撤掉。
library;

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/scheduler.dart' show Ticker;
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/video/graphic_subtitle_ocr.dart';
import 'package:fushi/src/media/video/video_graphic_subtitle_regions.dart';
import 'package:fushi/src/media/video/video_player_controller.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';

/// 退回整条字幕带时，字幕带占视频帧高度的比例（自帧底向上）。
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
    this.regionRequest,
    this.regionLoader,
    super.key,
  });

  final VideoPlayerController controller;
  final BoxFit fit;
  final GraphicSubtitleObscure obscure;

  /// 遮蔽「悬停 / 暂停 / 查词时显形」总闸（与文本字幕同一偏好）。
  final bool revealOnInteraction;

  /// 查词浮层还开着也算「用户在看」（与文本字幕 BUG-2235 同一判据）。
  final bool lookupPopupVisible;

  /// 抽轨请求的覆盖值（测试用）。缺省按控制器当前的视频路径与图形轨推导
  /// （[graphicSubtitleRegionRequestFor]）；推导不出 = 只能糊整条字幕带。
  final GraphicSubtitleRegionRequest? regionRequest;

  /// 位图时间表来源；缺省为播放页共用的 [FfmpegGraphicSubtitleRegionLoader.shared]。
  final GraphicSubtitleRegionLoader? regionLoader;

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
    extends State<VideoGraphicSubtitleObscureLayer>
    with SingleTickerProviderStateMixin {
  bool _hovering = false;

  /// 已抽好的位图时间表（对应 [_regionsFor]）；null = 还没有 / 拿不到。
  GraphicSubtitleRegionTrack? _regions;
  GraphicSubtitleRegionRequest? _regionsFor;
  Completer<void>? _regionCancel;

  /// 此刻正在显示的句子的模糊框（画布坐标）。逐帧按播放位置重算，变了才重建。
  List<Rect> _activeRects = const <Rect>[];
  late final Ticker _ticker = createTicker((_) => _tickRegions());

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChanged);
    _syncVisibility();
    _syncRegions();
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
    _syncRegions();
  }

  @override
  void dispose() {
    _cancelRegionLoad();
    _ticker.dispose();
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
      c.videoPath,
      c.activeGraphicSubtitleTrack,
    );
    if (key == _lastControllerKey) return;
    _lastControllerKey = key;
    _syncVisibility();
    _syncRegions();
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

  /// 只有「模糊」且图形轨在播时才需要位图时间表；请求变了（换轨 / 换片）就丢掉旧的
  /// 重新取。抽轨期间先按字幕带糊。
  void _syncRegions() {
    final VideoPlayerController c = widget.controller;
    final GraphicSubtitleRegionRequest? want =
        widget.obscure == GraphicSubtitleObscure.blur &&
            c.isPlayerRenderedSubtitleActive
        ? widget.regionRequest ??
              graphicSubtitleRegionRequestFor(
                videoPath: c.videoPath,
                track: c.activeGraphicSubtitleTrack,
              )
        : null;
    if (want != _regionsFor) {
      _cancelRegionLoad();
      _regionsFor = want;
      _regions = null;
      _activeRects = const <Rect>[];
      if (want != null) unawaited(_loadRegions(want));
    }
    _syncTicker();
  }

  Future<void> _loadRegions(GraphicSubtitleRegionRequest request) async {
    final Completer<void> cancel = Completer<void>();
    _regionCancel = cancel;
    final VideoPlayerController c = widget.controller;
    GraphicSubtitleRegionTrack? track;
    try {
      track =
          await (widget.regionLoader ??
                  FfmpegGraphicSubtitleRegionLoader.shared)
              .load(
                request,
                fallbackCanvas: Size(
                  (c.videoWidth ?? 0).toDouble(),
                  (c.videoHeight ?? 0).toDouble(),
                ),
                cancel: cancel.future,
              );
    } catch (e, stack) {
      debugPrint('[graphic-subtitle] region load failed: $e\n$stack');
      track = null;
    }
    if (!mounted || cancel.isCompleted || _regionsFor != request) return;
    _regionCancel = null;
    if (track == null || track.regions.isEmpty || track.canvas.isEmpty) return;
    setState(() {
      _regions = track;
      _activeRects = _rectsNow();
    });
    _syncTicker();
  }

  void _cancelRegionLoad() {
    final Completer<void>? cancel = _regionCancel;
    _regionCancel = null;
    if (cancel != null && !cancel.isCompleted) cancel.complete();
  }

  List<Rect> _rectsNow() {
    final GraphicSubtitleRegionTrack? regions = _regions;
    final int? pos = widget.controller.effectivePositionMs;
    if (regions == null || pos == null) return const <Rect>[];
    return regions.blurRectsAt(pos);
  }

  /// 有位图时间表时逐帧跟播放位置；没有时不跑。
  void _syncTicker() {
    final bool want = _regions != null;
    if (want && !_ticker.isActive) {
      _ticker.start();
    } else if (!want && _ticker.isActive) {
      _ticker.stop();
    }
  }

  void _tickRegions() {
    final List<Rect> next = _rectsNow();
    if (_sameRects(next, _activeRects)) return;
    setState(() {
      _activeRects = next;
      // 句子消失时 MouseRegion 随之卸载、收不到 onExit：悬停显形不能带到下一句。
      if (next.isEmpty) _hovering = false;
    });
    _syncVisibility();
  }

  static bool _sameRects(List<Rect> a, List<Rect> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
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
        final GraphicSubtitleRegionTrack? regions = _regions;
        if (regions != null) {
          // 按位图糊：只盖正在显示的句子，没字幕的时刻什么都不画。
          final List<Rect> rects = <Rect>[
            for (final Rect r in _activeRects)
              graphicSubtitleImageRectToView(
                imageRect: r,
                imageSize: regions.canvas,
                displaySize: frame,
                viewSize: view,
                fit: widget.fit,
              ).intersect(Offset.zero & view),
          ].where((Rect r) => !r.isEmpty).toList(growable: false);
          return Stack(
            children: <Widget>[
              for (int i = 0; i < rects.length; i++)
                _blurBox(
                  key: ValueKey<String>('graphic_subtitle_obscure_region_$i'),
                  rect: rects[i],
                  blurred: blurred,
                  // 框只比字高一圈，按框高取更大的比例才糊得开字形。
                  sigma: (rects[i].height * 0.15).clamp(8.0, 18.0),
                ),
            ],
          );
        }
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
            _blurBox(
              key: const ValueKey<String>('graphic_subtitle_obscure_band'),
              rect: band,
              blurred: blurred,
              sigma: (band.height * 0.06).clamp(6.0, 18.0),
            ),
          ],
        );
      },
    );
  }

  /// 一块模糊区：悬停显形（与文本字幕一致）+ 背景模糊。
  Widget _blurBox({
    required Key key,
    required Rect rect,
    required bool blurred,
    required double sigma,
  }) {
    return Positioned.fromRect(
      rect: rect,
      child: MouseRegion(
        key: key,
        opaque: false,
        hitTestBehavior: HitTestBehavior.translucent,
        onEnter: (_) => _setHovering(true),
        onExit: (_) => _setHovering(false),
        child: IgnorePointer(
          child: _BandBlur(blurred: blurred, sigma: sigma),
        ),
      ),
    );
  }
}

/// 一块区域的背景模糊，模糊强度随显形 / 遮蔽平滑过渡。
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
