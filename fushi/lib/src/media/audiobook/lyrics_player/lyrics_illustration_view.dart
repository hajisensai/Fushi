import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_illustrations.dart';
import 'package:fushi/src/reader/illustration_zoom_viewer.dart'
    show illustrationZoomRoute;
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

// 歌词模式插图的画法（两套设计系统共用；逻辑见 lyrics_illustrations.dart）。
//
//  * [LyricsIllustrationArtworkSlot]：宽屏左栏的封面位。平时显示设计系统自己的封面
//    卡；播放走过插图时以 M3E spatial 弹簧（缩放 + 淡入）换成插图卡并停住。插图卡
//    点左 / 右三分之一 = 上 / 下一张，点中间 = 看大图，右上角 ✕ = 回封面。
//  * [LyricsIllustrationCompactArtwork]：窄屏控制条里的小封面方块。有新插图时换成
//    插图缩略图并带一个提示点；点它进插图大图浏览，看完回到封面。
//  * [showLyricsIllustrationViewer]：插图大图浏览（左右翻页 + 双指 / 滚轮缩放）。

/// 插图卡上左右「翻页热区」各占的宽度比例；中间那段是「看大图」。
const double _kNavZoneFraction = 0.3;

/// 打开插图大图浏览：[controller] 已听到的插图（`0..reached`），从 [index] 看起。
/// 翻页会同步到 [controller]（宽屏左栏跟着换）。[returnToCover] = 关掉后插图位回
/// 封面（竖屏入口：看完就算确认过了）。
Future<void> showLyricsIllustrationViewer(
  BuildContext context, {
  required LyricsIllustrationController controller,
  required int index,
  bool returnToCover = false,
}) async {
  if (!controller.hasReached) return;
  final int start = index.clamp(0, controller.reached);
  controller.showAt(start);
  await Navigator.of(context).push(
    illustrationZoomRoute(
      context,
      (BuildContext routeContext) =>
          LyricsIllustrationViewer(controller: controller, initialIndex: start),
    ),
  );
  if (returnToCover) controller.dismiss();
}

// ---------------------------------------------------------------------------
// 宽屏：封面位
// ---------------------------------------------------------------------------

/// 宽屏左栏的封面位：封面卡 ↔ 插图卡。
class LyricsIllustrationArtworkSlot extends StatelessWidget {
  const LyricsIllustrationArtworkSlot({
    super.key,
    required this.controller,
    required this.side,
    required this.cover,
    required this.borderRadius,
    this.onOpen,
  });

  /// null = 这本书没有插图（或还没算完），只显示封面。
  final LyricsIllustrationController? controller;

  /// 封面位的边长（插图按原比例放进 [side]×[side]）。
  final double side;

  /// 设计系统自己的封面卡。
  final Widget cover;

  /// 插图卡圆角（与设计系统封面卡同一档）。
  final BorderRadius borderRadius;

  /// 点插图卡中间：看大图（参数是插图下标）。
  final ValueChanged<int>? onOpen;

  @override
  Widget build(BuildContext context) {
    final LyricsIllustrationController? c = controller;
    if (c == null) return cover;
    return ListenableBuilder(
      listenable: c,
      builder: (BuildContext context, Widget? _) {
        final int? shown = c.shown;
        final FushiMotionScheme motion = context.fushiMotion;
        final Widget child = shown == null
            ? KeyedSubtree(
                key: const ValueKey<String>('lyrics_artwork_cover'),
                child: _CoverWithIllustrationBadge(controller: c, cover: cover),
              )
            : KeyedSubtree(
                key: ValueKey<String>('lyrics_artwork_${c.items[shown].key}'),
                child: _IllustrationCard(
                  controller: c,
                  index: shown,
                  side: side,
                  borderRadius: borderRadius,
                  onOpen: onOpen,
                ),
              );
        return SizedBox.square(
          dimension: side,
          child: AnimatedSwitcher(
            duration: motion.spatialDefault.duration,
            reverseDuration: motion.effectsDefault.duration,
            switchInCurve: motion.spatialDefault.curve,
            switchOutCurve: motion.effectsDefault.curve,
            transitionBuilder: (Widget child, Animation<double> animation) =>
                FadeTransition(
                  opacity: fushiUnitClamped(animation),
                  child: ScaleTransition(
                    scale: Tween<double>(begin: 0.9, end: 1).animate(animation),
                    child: child,
                  ),
                ),
            child: child,
          ),
        );
      },
    );
  }
}

/// 封面 + 底边「插图」小胶囊（已听到至少一张时出现）：点封面或胶囊都把封面位
/// 换成最近听到的那张插图。没有可看的插图时原样返回封面。
class _CoverWithIllustrationBadge extends StatelessWidget {
  const _CoverWithIllustrationBadge({
    required this.controller,
    required this.cover,
  });

  final LyricsIllustrationController controller;
  final Widget cover;

  @override
  Widget build(BuildContext context) {
    if (!controller.hasReached) return cover;
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool glass = isGlassDesign(context);
    void reveal() {
      final int? start = controller.browseStart;
      if (start != null) controller.showAt(start);
    }

    return Stack(
      children: <Widget>[
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: reveal,
            child: cover,
          ),
        ),
        // 底边居中：设计系统的封面卡按封面原比例居中放在方形槽位里，书封（竖版）
        // 的底边正是槽位底边，角落位置会落到封面外面。
        Positioned(
          left: 0,
          right: 0,
          bottom: 10,
          child: Center(
            child: FushiTooltip(
              message: t.lyrics_illustration_open,
              child: FushiPressScale(
                child: Material(
                  color: glass
                      ? Colors.black.withValues(alpha: 0.42)
                      : cs.secondaryContainer.withValues(alpha: 0.92),
                  shape: const StadiumBorder(),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    key: const ValueKey<String>('lyrics_artwork_badge'),
                    onTap: reveal,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          FushiIcon(
                            FushiIcons.image,
                            size: 16,
                            color: glass
                                ? Colors.white
                                : cs.onSecondaryContainer,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            '${controller.reached + 1}',
                            style: Theme.of(context).textTheme.labelMedium
                                ?.copyWith(
                                  color: glass
                                      ? Colors.white
                                      : cs.onSecondaryContainer,
                                ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 插图卡：按插图原比例放进 [side]×[side]，叠一层操作（✕ / 左右箭头 / 计数）。
class _IllustrationCard extends StatefulWidget {
  const _IllustrationCard({
    required this.controller,
    required this.index,
    required this.side,
    required this.borderRadius,
    required this.onOpen,
  });

  final LyricsIllustrationController controller;
  final int index;
  final double side;
  final BorderRadius borderRadius;
  final ValueChanged<int>? onOpen;

  @override
  State<_IllustrationCard> createState() => _IllustrationCardState();
}

class _IllustrationCardState extends State<_IllustrationCard> {
  /// 插图宽高比；解码前按常见竖版插图 0.7。
  double _aspect = 0.7;
  ImageStream? _stream;
  ImageStreamListener? _listener;

  ImageProvider get _image {
    final int cache = (widget.side * MediaQuery.devicePixelRatioOf(context))
        .round();
    return ResizeImage.resizeIfNeeded(
      null,
      cache,
      widget.controller.items[widget.index].image,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolveAspect();
  }

  @override
  void didUpdateWidget(covariant _IllustrationCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.index != widget.index ||
        oldWidget.side != widget.side ||
        !identical(oldWidget.controller, widget.controller)) {
      _resolveAspect();
    }
  }

  void _resolveAspect() {
    final ImageStream next = _image.resolve(
      createLocalImageConfiguration(context),
    );
    if (next.key == _stream?.key) return;
    _detach();
    final ImageStreamListener listener = ImageStreamListener(
      (ImageInfo info, bool _) {
        final double w = info.image.width.toDouble();
        final double h = info.image.height.toDouble();
        info.dispose();
        if (!mounted || w <= 0 || h <= 0) return;
        final double aspect = w / h;
        if ((aspect - _aspect).abs() > 0.001) setState(() => _aspect = aspect);
      },
      onError: (Object error, StackTrace? stackTrace) {
        // 坏图：保持占位比例，图片自己的 errorBuilder 画占位图标。
      },
    );
    _stream = next..addListener(listener);
    _listener = listener;
  }

  void _detach() {
    final ImageStreamListener? listener = _listener;
    if (listener != null) _stream?.removeListener(listener);
    _stream = null;
    _listener = null;
  }

  @override
  void dispose() {
    _detach();
    super.dispose();
  }

  void _onTapUp(TapUpDetails details, double width) {
    final LyricsIllustrationController c = widget.controller;
    final double x = details.localPosition.dx;
    if (x < width * _kNavZoneFraction && c.canShowPrevious) {
      c.showPrevious();
    } else if (x > width * (1 - _kNavZoneFraction) && c.canShowNext) {
      c.showNext();
    } else {
      widget.onOpen?.call(widget.index);
    }
  }

  @override
  Widget build(BuildContext context) {
    final LyricsIllustrationController c = widget.controller;
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool glass = isGlassDesign(context);
    final double side = widget.side;
    final double w = _aspect >= 1 ? side : side * _aspect;
    final double h = _aspect >= 1 ? side / _aspect : side;
    final Color controlBg = glass
        ? Colors.black.withValues(alpha: 0.42)
        : cs.secondaryContainer.withValues(alpha: 0.92);
    final Color controlFg = glass ? Colors.white : cs.onSecondaryContainer;
    Widget control({
      required Key key,
      required IconData icon,
      required String tooltip,
      required VoidCallback onTap,
    }) {
      return FushiIconButton(
        key: key,
        icon: icon,
        tooltip: tooltip,
        size: 20,
        backgroundColor: controlBg,
        enabledColor: controlFg,
        onTap: onTap,
      );
    }

    return Center(
      child: SizedBox(
        width: w,
        height: h,
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: widget.borderRadius,
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: (glass ? Colors.black : cs.shadow).withValues(
                  alpha: 0.28,
                ),
                blurRadius: 24,
                offset: const Offset(0, 12),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: widget.borderRadius,
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                Semantics(
                  button: true,
                  label: t.lyrics_illustration_open,
                  child: GestureDetector(
                    key: const ValueKey<String>('lyrics_illustration_card'),
                    behavior: HitTestBehavior.opaque,
                    onTapUp: (TapUpDetails d) => _onTapUp(d, w),
                    child: MouseRegion(
                      cursor: SystemMouseCursors.zoomIn,
                      child: Image(
                        image: _image,
                        fit: BoxFit.cover,
                        filterQuality: FilterQuality.medium,
                        gaplessPlayback: true,
                        errorBuilder: (_, Object e, StackTrace? s) =>
                            ColoredBox(
                              color: cs.surfaceContainerHigh,
                              child: Center(
                                child: FushiIcon(
                                  FushiIcons.brokenImage,
                                  size: math.min(w, h) * 0.2,
                                  color: cs.onSurfaceVariant,
                                ),
                              ),
                            ),
                      ),
                    ),
                  ),
                ),
                PositionedDirectional(
                  top: 8,
                  end: 8,
                  child: control(
                    key: const ValueKey<String>('lyrics_illustration_close'),
                    icon: FushiIcons.close,
                    tooltip: t.lyrics_illustration_back_to_cover,
                    onTap: c.dismiss,
                  ),
                ),
                if (c.canShowPrevious)
                  Positioned(
                    left: 6,
                    top: 0,
                    bottom: 0,
                    child: Center(
                      child: control(
                        key: const ValueKey<String>('lyrics_illustration_prev'),
                        icon: FushiIcons.chevronLeft,
                        tooltip: t.lyrics_illustration_previous,
                        onTap: c.showPrevious,
                      ),
                    ),
                  ),
                if (c.canShowNext)
                  Positioned(
                    right: 6,
                    top: 0,
                    bottom: 0,
                    child: Center(
                      child: control(
                        key: const ValueKey<String>('lyrics_illustration_next'),
                        icon: FushiIcons.chevronRight,
                        tooltip: t.lyrics_illustration_next,
                        onTap: c.showNext,
                      ),
                    ),
                  ),
                if (c.reached > 0)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 10,
                    child: Center(
                      child: IgnorePointer(
                        child: DecoratedBox(
                          decoration: ShapeDecoration(
                            color: controlBg,
                            shape: const StadiumBorder(),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 4,
                            ),
                            child: Text(
                              '${widget.index + 1} / ${c.reached + 1}',
                              style: Theme.of(context).textTheme.labelMedium
                                  ?.copyWith(color: controlFg),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 窄屏：小封面方块
// ---------------------------------------------------------------------------

/// 窄屏控制条里的小封面：[builder] 画设计系统自己的小方块（参数为 null = 画封面，
/// 否则画这张插图）。有可看的插图时整块可点，点了进插图大图浏览。
class LyricsIllustrationCompactArtwork extends StatelessWidget {
  const LyricsIllustrationCompactArtwork({
    super.key,
    required this.controller,
    required this.builder,
    this.onOpen,
  });

  final LyricsIllustrationController? controller;
  final Widget Function(BuildContext context, ImageProvider? illustration)
  builder;

  /// 点小方块：从第几张看起（参数是插图下标）。
  final ValueChanged<int>? onOpen;

  @override
  Widget build(BuildContext context) {
    final LyricsIllustrationController? c = controller;
    if (c == null) return builder(context, null);
    return ListenableBuilder(
      listenable: c,
      builder: (BuildContext context, Widget? _) {
        final LyricsIllustration? shown = c.shownIllustration;
        final FushiMotionScheme motion = context.fushiMotion;
        final Widget face = AnimatedSwitcher(
          duration: motion.spatialDefault.duration,
          switchInCurve: motion.spatialDefault.curve,
          switchOutCurve: motion.effectsDefault.curve,
          transitionBuilder: (Widget child, Animation<double> animation) =>
              FadeTransition(
                opacity: fushiUnitClamped(animation),
                child: ScaleTransition(
                  scale: Tween<double>(begin: 0.8, end: 1).animate(animation),
                  child: child,
                ),
              ),
          child: KeyedSubtree(
            key: ValueKey<String>(
              'lyrics_compact_artwork_${shown?.key ?? 'cover'}',
            ),
            child: builder(context, shown?.image),
          ),
        );
        final int? start = c.browseStart;
        if (start == null || onOpen == null) return face;
        final ColorScheme cs = Theme.of(context).colorScheme;
        return Semantics(
          button: true,
          label: t.lyrics_illustration_open,
          child: FushiTooltip(
            message: t.lyrics_illustration_open,
            child: FushiPressScale(
              child: GestureDetector(
                key: const ValueKey<String>('lyrics_compact_artwork'),
                behavior: HitTestBehavior.opaque,
                onTap: () => onOpen!(start),
                child: Stack(
                  clipBehavior: Clip.none,
                  children: <Widget>[
                    face,
                    // 新插图提示点：插图位换上了还没看过的插图。
                    if (shown != null)
                      PositionedDirectional(
                        top: -2,
                        end: -2,
                        child: Container(
                          key: const ValueKey<String>(
                            'lyrics_compact_artwork_dot',
                          ),
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(
                            color: cs.primary,
                            shape: BoxShape.circle,
                            border: Border.all(color: cs.surface, width: 1.5),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// 大图浏览
// ---------------------------------------------------------------------------

/// 插图大图浏览：已听到的插图左右翻页，每页可双指 / 滚轮 / 双击缩放（看清印在
/// 插图上的文字）。放大时停用翻页手势，免得拖动看细节时翻走。← / → 翻页，Esc 关闭。
class LyricsIllustrationViewer extends StatefulWidget {
  const LyricsIllustrationViewer({
    super.key,
    required this.controller,
    required this.initialIndex,
  });

  final LyricsIllustrationController controller;
  final int initialIndex;

  @override
  State<LyricsIllustrationViewer> createState() =>
      _LyricsIllustrationViewerState();
}

class _LyricsIllustrationViewerState extends State<LyricsIllustrationViewer> {
  late final PageController _pages = PageController(
    initialPage: widget.initialIndex,
  );
  late int _index = widget.initialIndex;
  final Map<int, TransformationController> _zoom =
      <int, TransformationController>{};
  bool _zoomed = false;

  int get _count => widget.controller.reached + 1;

  TransformationController _zoomFor(int index) =>
      _zoom.putIfAbsent(index, TransformationController.new);

  @override
  void dispose() {
    _pages.dispose();
    for (final TransformationController z in _zoom.values) {
      z.dispose();
    }
    super.dispose();
  }

  void _goTo(int index) {
    if (index < 0 || index >= _count) return;
    final Duration d = fushiMotionDuration(context, FushiMotion.medium);
    if (d == Duration.zero) {
      _pages.jumpToPage(index);
    } else {
      _pages.animateToPage(index, duration: d, curve: FushiMotion.standard);
    }
  }

  void _onPageChanged(int index) {
    _zoom[_index]?.value = Matrix4.identity();
    setState(() {
      _index = index;
      _zoomed = false;
    });
    widget.controller.showAt(index);
  }

  void _onInteractionEnd(int index) {
    final double scale = _zoomFor(index).value.getMaxScaleOnAxis();
    final bool zoomed = scale > 1.01;
    if (zoomed != _zoomed) setState(() => _zoomed = zoomed);
  }

  void _toggleZoom(int index, Offset focal) {
    final TransformationController z = _zoomFor(index);
    if (z.value.getMaxScaleOnAxis() > 1.01) {
      z.value = Matrix4.identity();
      setState(() => _zoomed = false);
      return;
    }
    const double scale = 2.5;
    z.value = Matrix4.identity()
      ..translateByDouble(
        -focal.dx * (scale - 1),
        -focal.dy * (scale - 1),
        0,
        1,
      )
      ..scaleByDouble(scale, scale, 1, 1);
    setState(() => _zoomed = true);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final LogicalKeyboardKey key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowLeft) {
      _goTo(_index - 1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      _goTo(_index + 1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      Navigator.of(context).maybePop();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool glass = isGlassDesign(context);
    final Color controlBg = glass
        ? Colors.black.withValues(alpha: 0.42)
        : cs.secondaryContainer.withValues(alpha: 0.92);
    final Color controlFg = glass ? Colors.white : cs.onSecondaryContainer;
    final List<LyricsIllustration> items = widget.controller.items;
    // 路由是透明叠层，没有 Material 祖先：按钮的墨水反馈要一层透明 Material 托着。
    return Material(
      type: MaterialType.transparency,
      child: Focus(
        autofocus: true,
        onKeyEvent: _onKey,
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            PageView.builder(
              key: const ValueKey<String>('lyrics_illustration_viewer_pages'),
              controller: _pages,
              itemCount: _count,
              physics: _zoomed
                  ? const NeverScrollableScrollPhysics()
                  : const PageScrollPhysics(),
              onPageChanged: _onPageChanged,
              itemBuilder: (BuildContext context, int index) {
                final LyricsIllustration item = items[index];
                Offset focal = Offset.zero;
                return GestureDetector(
                  onDoubleTapDown: (TapDownDetails d) =>
                      focal = d.localPosition,
                  onDoubleTap: () => _toggleZoom(index, focal),
                  child: InteractiveViewer(
                    transformationController: _zoomFor(index),
                    minScale: 1,
                    maxScale: 10,
                    onInteractionEnd: (_) => _onInteractionEnd(index),
                    child: Center(
                      child: Image(
                        image: item.image,
                        fit: BoxFit.contain,
                        filterQuality: FilterQuality.medium,
                        errorBuilder: (_, Object error, StackTrace? stack) {
                          ErrorLogService.instance.logDiagnostic(
                            'LyricsIllustrationViewer.decode',
                            '${item.key}: $error',
                          );
                          return FushiIcon(
                            FushiIcons.brokenImage,
                            size: 64,
                            color: cs.onSurfaceVariant,
                          );
                        },
                      ),
                    ),
                  ),
                );
              },
            ),
            PositionedDirectional(
              top: 0,
              end: 0,
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: FushiIconButton(
                    key: const ValueKey<String>(
                      'lyrics_illustration_viewer_close',
                    ),
                    icon: FushiIcons.close,
                    tooltip: MaterialLocalizations.of(
                      context,
                    ).closeButtonTooltip,
                    backgroundColor: controlBg,
                    enabledColor: controlFg,
                    onTap: () => Navigator.of(context).maybePop(),
                  ),
                ),
              ),
            ),
            if (_index > 0)
              Positioned(
                left: 12,
                top: 0,
                bottom: 0,
                child: Center(
                  child: FushiIconButton(
                    key: const ValueKey<String>(
                      'lyrics_illustration_viewer_prev',
                    ),
                    icon: FushiIcons.chevronLeft,
                    tooltip: t.lyrics_illustration_previous,
                    backgroundColor: controlBg,
                    enabledColor: controlFg,
                    onTap: () => _goTo(_index - 1),
                  ),
                ),
              ),
            if (_index < _count - 1)
              Positioned(
                right: 12,
                top: 0,
                bottom: 0,
                child: Center(
                  child: FushiIconButton(
                    key: const ValueKey<String>(
                      'lyrics_illustration_viewer_next',
                    ),
                    icon: FushiIcons.chevronRight,
                    tooltip: t.lyrics_illustration_next,
                    backgroundColor: controlBg,
                    enabledColor: controlFg,
                    onTap: () => _goTo(_index + 1),
                  ),
                ),
              ),
            if (_count > 1)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: Center(
                      child: DecoratedBox(
                        decoration: ShapeDecoration(
                          color: controlBg,
                          shape: const StadiumBorder(),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 6,
                          ),
                          child: Text(
                            '${_index + 1} / $_count',
                            style: Theme.of(
                              context,
                            ).textTheme.labelLarge?.copyWith(color: controlFg),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
