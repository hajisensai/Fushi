import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/utils/adaptive/adaptive_navigation.dart'
    show AdaptiveNavItem;
import 'package:fushi/src/utils/adaptive/nav_overflow/nav_overflow_spec.dart';
import 'package:fushi/src/utils/components/fushi_hover_lift.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart'
    show FushiTooltip;
import 'package:fushi/src/utils/misc/platform_utils.dart'
    show HorizontalDragScrollable;
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_m3e_list_card.dart'
    show FushiM3eShape;

/// 底栏原型「书脊」（[AdaptiveNavBarStyle] 同名值，设计稿 divergent.html F2）。
///
/// 胶囊里先平铺放得下的固定目的地，其余的在胶囊末端画成一排竖立的小书脊
/// （几本书 = 还有几个模块，最后两本斜靠）。
/// - 轻点书脊区：升起一层书架，每个隐藏目的地是一本竖排书名的书，点书即去；
/// - 在书脊上按住横拖：每 [_kScrubStep] 换一本，手指下那本被「抽出来」并在
///   上方显示名字，松手跳转。
class NavShelfBar extends StatefulWidget {
  const NavShelfBar({super.key, required this.spec});

  final NavOverflowSpec spec;

  @override
  State<NavShelfBar> createState() => _NavShelfBarState();
}

/// 书脊区的最小宽度（设计稿约 70~80）。
const double _kSpineAreaMinWidth = 76;

/// 底栏小书脊：宽、间距。
const double _kSpineWidth = 7;
const double _kSpineWideWidth = 12;
const double _kSpineGap = 3;

/// 横拖超过它才算拖选（之前都当轻点）。
const double _kScrubSlop = 8;

/// 横拖每走这么远换一本。
const double _kScrubStep = 22;

/// 书架里的书：视觉宽、命中槽宽（≥48dp）、书区高度、搁板厚度。
const double _kBookWidth = 38;
const double _kBookSlotWidth = 48;
const double _kBooksAreaHeight = 192;
const double _kShelfBoardHeight = 6;

/// 书架面板升起 / 书弹入的基准时长与错峰（设计稿 .5s / .55s / 35ms）。
const Duration _kShelfRise = Duration(milliseconds: 500);
const Duration _kBookRise = Duration(milliseconds: 550);
const Duration _kBookStagger = Duration(milliseconds: 35);
const Duration _kShelfClose = Duration(milliseconds: 220);
const Duration _kSpineMorph = Duration(milliseconds: 300);

/// 设计稿里的三条回弹贝塞尔。
const Curve _kShelfCurve = Cubic(0.3, 1.2, 0.45, 1);
const Curve _kBookCurve = Cubic(0.3, 1.35, 0.5, 1);
const Curve _kSpineCurve = Cubic(0.3, 1.4, 0.5, 1);

/// 一本书的配色（底色 + 上面的字 / 图标色）。
class _BookTone {
  const _BookTone(this.background, this.foreground);

  final Color background;
  final Color foreground;
}

/// 由当前主题色调出的书脊色板（6~9 种，循环使用）。
List<_BookTone> _bookTones(ColorScheme scheme) {
  final List<Color> backgrounds = <Color>[
    scheme.tertiary,
    scheme.primary,
    scheme.secondary,
    Color.lerp(scheme.primary, scheme.tertiary, 0.5)!,
    Color.lerp(scheme.tertiary, scheme.onTertiaryContainer, 0.4)!,
    Color.lerp(scheme.secondary, scheme.tertiary, 0.5)!,
    Color.lerp(scheme.primary, scheme.onPrimaryContainer, 0.4)!,
    Color.lerp(scheme.secondary, scheme.onSecondaryContainer, 0.4)!,
    Color.lerp(scheme.tertiary, scheme.primary, 0.25)!,
  ];
  final Color lightInk = scheme.brightness == Brightness.light
      ? scheme.surface
      : scheme.onSurface;
  final Color darkInk = scheme.brightness == Brightness.light
      ? scheme.onSurface
      : scheme.surface;
  return <_BookTone>[
    for (final Color bg in backgrounds)
      _BookTone(
        bg,
        ThemeData.estimateBrightnessForColor(bg) == Brightness.dark
            ? lightInk
            : darkInk,
      ),
  ];
}

/// 算胶囊里平铺几个固定项：书脊区要放下全部隐藏项的书脊。
int _resolvePinnedCount(NavOverflowSpec spec) {
  double trigger = _kSpineAreaMinWidth;
  int pinned = spec.pinnedCount(triggerWidth: trigger);
  for (int round = 0; round < 4; round++) {
    final int hidden = spec.indices.length - pinned;
    final double need = _spineRowWidth(hidden) + 24;
    if (need <= trigger) break;
    trigger = need;
    pinned = spec.pinnedCount(triggerWidth: trigger);
  }
  return pinned;
}

/// [count] 本书脊横排（含当前 / 抽出那本加宽）需要的宽度。
double _spineRowWidth(int count) {
  if (count <= 0) return 0;
  return count * _kSpineWidth +
      (count - 1) * _kSpineGap +
      (_kSpineWideWidth - _kSpineWidth) * 2;
}

/// 底栏小书脊第 [k] 本的高度（24~36 错落）。
double _spineHeight(int k) => 24 + ((k * 7) % 13).toDouble();

/// 书架里第 [k] 本书的高度（132~171 错落）。
double _bookHeight(int k) => 132 + ((k * 13) % 40).toDouble();

enum _OverlayMode { none, shelf, scrub }

class _NavShelfBarState extends State<NavShelfBar>
    with SingleTickerProviderStateMixin {
  final OverlayPortalController _portal = OverlayPortalController();
  final GlobalKey _barKey = GlobalKey(debugLabel: 'nav-shelf-bar');
  final GlobalKey _spineKey = GlobalKey(debugLabel: 'nav-shelf-spines');
  late final AnimationController _shelf = AnimationController(vsync: this);
  final FocusNode _shelfFocus = FocusNode(debugLabel: 'nav-shelf-panel');

  _OverlayMode _mode = _OverlayMode.none;

  /// 横拖状态：按下点、起始书序、是否已越过 [_kScrubSlop]、当前抽出的书序。
  double? _scrubOriginX;
  int _scrubStart = 0;
  bool _scrubMoved = false;
  int? _scrubHot;

  /// 本次按下已经走了拖选，紧随其后的 InkWell 轻点要吞掉。
  bool _suppressTap = false;

  NavOverflowSpec get spec => widget.spec;

  @override
  void dispose() {
    _shelf.dispose();
    _shelfFocus.dispose();
    super.dispose();
  }

  List<int> _hiddenIndices(int pinned) => spec.indices.sublist(pinned);

  // ---------------------------------------------------------------- 书架开合

  Duration _shelfOpenDuration(int bookCount) {
    final Duration books =
        _kBookRise + _kBookStagger * math.max(0, bookCount - 1);
    return books > _kShelfRise ? books : _kShelfRise;
  }

  void _openShelf(int bookCount) {
    if (_mode == _OverlayMode.shelf) return;
    _shelf
      ..duration = fushiMotionDuration(context, _shelfOpenDuration(bookCount))
      ..reverseDuration = fushiMotionDuration(context, _kShelfClose);
    setState(() => _mode = _OverlayMode.shelf);
    _portal.show();
    _shelf.forward(from: 0);
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (mounted && _mode == _OverlayMode.shelf) _shelfFocus.requestFocus();
    });
  }

  Future<void> _closeShelf() async {
    if (_mode != _OverlayMode.shelf) return;
    await _shelf.reverse();
    if (!mounted || _mode != _OverlayMode.shelf) return;
    setState(() => _mode = _OverlayMode.none);
    _portal.hide();
  }

  void _pickFromShelf(int index) {
    spec.onSelect(index);
    _closeShelf();
  }

  // ---------------------------------------------------------------- 横拖抽书

  void _onSpinePointerDown(PointerDownEvent event, List<int> hidden) {
    if (_mode == _OverlayMode.shelf) return;
    _suppressTap = false;
    _scrubOriginX = event.position.dx;
    _scrubMoved = false;
    _scrubStart = math.max(0, hidden.indexOf(spec.currentIndex));
  }

  void _onSpinePointerMove(PointerMoveEvent event, List<int> hidden) {
    final double? origin = _scrubOriginX;
    if (origin == null) return;
    final double dx = event.position.dx - origin;
    if (!_scrubMoved && dx.abs() < _kScrubSlop) return;
    final int hot = (_scrubStart + (dx / _kScrubStep).round())
        .clamp(0, hidden.length - 1)
        .toInt();
    if (_scrubMoved && hot == _scrubHot) return;
    final bool first = !_scrubMoved;
    setState(() {
      _scrubMoved = true;
      _scrubHot = hot;
      _mode = _OverlayMode.scrub;
    });
    if (first) _portal.show();
  }

  void _onSpinePointerUp(List<int> hidden) {
    if (_scrubOriginX == null) return;
    final bool moved = _scrubMoved;
    final int? hot = _scrubHot;
    _endScrub();
    if (moved && hot != null) {
      _suppressTap = true;
      spec.onSelect(hidden[hot]);
    }
  }

  void _endScrub() {
    _scrubOriginX = null;
    if (_mode == _OverlayMode.scrub) {
      _portal.hide();
    }
    if (_scrubMoved || _mode == _OverlayMode.scrub) {
      setState(() {
        _scrubMoved = false;
        _scrubHot = null;
        if (_mode == _OverlayMode.scrub) _mode = _OverlayMode.none;
      });
    }
  }

  void _onSpineTap(int bookCount) {
    if (_suppressTap) {
      _suppressTap = false;
      return;
    }
    _openShelf(bookCount);
  }

  // ---------------------------------------------------------------- 构建

  @override
  Widget build(BuildContext context) {
    final int pinned = _resolvePinnedCount(spec);
    if (pinned >= spec.indices.length) return navOverflowPlainRow(spec);
    final List<int> hidden = _hiddenIndices(pinned);
    final double spineArea = math.max(
      _kSpineAreaMinWidth,
      _spineRowWidth(hidden.length) + 24,
    );
    final double cellWidth = math.max(0, spec.width - spineArea) / pinned;
    return OverlayPortal(
      controller: _portal,
      overlayChildBuilder: (BuildContext overlayContext) =>
          _buildOverlay(overlayContext, hidden),
      child: Row(
        key: _barKey,
        children: <Widget>[
          for (final int i in spec.indices.take(pinned))
            SizedBox(width: cellWidth, child: spec.cellBuilder(i, cellWidth)),
          Expanded(child: _buildSpineArea(context, hidden)),
        ],
      ),
    );
  }

  Widget _buildSpineArea(BuildContext context, List<int> hidden) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final List<_BookTone> tones = _bookTones(scheme);
    final Duration morph = fushiMotionDuration(context, _kSpineMorph);
    final String names = <String>[
      for (final int i in hidden) spec.item(i).label,
    ].join(' · ');
    final bool currentHidden = hidden.contains(spec.currentIndex);
    return Semantics(
      button: true,
      selected: currentHidden,
      label: names,
      excludeSemantics: true,
      child: FushiTooltip(
        message: names,
        child: Listener(
          onPointerDown: (PointerDownEvent e) => _onSpinePointerDown(e, hidden),
          onPointerMove: (PointerMoveEvent e) => _onSpinePointerMove(e, hidden),
          onPointerUp: (PointerUpEvent _) => _onSpinePointerUp(hidden),
          onPointerCancel: (PointerCancelEvent _) => _endScrub(),
          child: InkWell(
            customBorder: const StadiumBorder(),
            onTap: () => _onSpineTap(hidden.length),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48, minWidth: 48),
              child: SizedBox(
                key: _spineKey,
                height: spec.height,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: <Widget>[
                      for (int k = 0; k < hidden.length; k++) ...<Widget>[
                        if (k > 0) const SizedBox(width: _kSpineGap),
                        _buildSpine(
                          k: k,
                          count: hidden.length,
                          tone: tones[k % tones.length],
                          outline: scheme.onTertiaryContainer,
                          current: hidden[k] == spec.currentIndex,
                          hot: _scrubHot == k,
                          duration: morph,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSpine({
    required int k,
    required int count,
    required _BookTone tone,
    required Color outline,
    required bool current,
    required bool hot,
    required Duration duration,
  }) {
    final bool scrubbing = _scrubHot != null;
    // 拖选时只有手指下那本抽出；当前那本退回普通姿态，免得两本同时抬起。
    final bool showCurrent = current && !scrubbing;
    final double width = hot || showCurrent ? _kSpineWideWidth : _kSpineWidth;
    final double height = _spineHeight(k) + (showCurrent ? 4 : 0);
    final Matrix4 transform;
    if (hot) {
      transform = Matrix4.translationValues(0, -14, 0);
    } else if (showCurrent) {
      transform = Matrix4.translationValues(0, -6, 0);
    } else if (k == count - 1 && count > 2) {
      transform = Matrix4.translationValues(2, 0, 0)
        ..multiply(Matrix4.rotationZ(18 * math.pi / 180));
    } else if (k == count - 2 && count > 2) {
      transform = Matrix4.rotationZ(10 * math.pi / 180);
    } else {
      transform = Matrix4.identity();
    }
    return AnimatedContainer(
      duration: duration,
      curve: _kSpineCurve,
      width: width,
      height: height,
      transform: transform,
      transformAlignment: Alignment.bottomCenter,
      decoration: BoxDecoration(
        color: tone.background,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(2),
          bottom: Radius.circular(1),
        ),
        boxShadow: showCurrent
            ? <BoxShadow>[BoxShadow(color: outline, spreadRadius: 2)]
            : const <BoxShadow>[],
      ),
    );
  }

  // ---------------------------------------------------------------- 上层

  /// [key] 对应控件在 Overlay 坐标系里的矩形；还没布局时为 null。
  Rect? _rectInOverlay(GlobalKey key) {
    final RenderObject? target = key.currentContext?.findRenderObject();
    final RenderObject? overlay = Overlay.maybeOf(
      context,
    )?.context.findRenderObject();
    if (target is! RenderBox || overlay is! RenderBox || !target.hasSize) {
      return null;
    }
    final Offset origin = target.localToGlobal(Offset.zero, ancestor: overlay);
    return origin & target.size;
  }

  Widget _buildOverlay(BuildContext overlayContext, List<int> hidden) {
    return switch (_mode) {
      _OverlayMode.shelf => _buildShelfOverlay(overlayContext, hidden),
      _OverlayMode.scrub => _buildScrubBubble(overlayContext, hidden),
      _OverlayMode.none => const SizedBox.shrink(),
    };
  }

  Widget _buildScrubBubble(BuildContext overlayContext, List<int> hidden) {
    final int? hot = _scrubHot;
    final Rect? area = _rectInOverlay(_spineKey);
    if (hot == null || area == null) return const SizedBox.shrink();
    final ColorScheme scheme = Theme.of(overlayContext).colorScheme;
    final AdaptiveNavItem item = spec.item(hidden[hot]);
    // 气泡大致对着手指下那本书脊。
    final double spineX =
        area.center.dx -
        _spineRowWidth(hidden.length) / 2 +
        hot * (_kSpineWidth + _kSpineGap) +
        _kSpineWideWidth / 2;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints box) {
        const double bubbleWidth = 160;
        final double left = (spineX - bubbleWidth / 2)
            .clamp(8.0, math.max(8.0, box.maxWidth - bubbleWidth - 8))
            .toDouble();
        return Stack(
          children: <Widget>[
            Positioned(
              left: left,
              width: bubbleWidth,
              bottom: box.maxHeight - area.top + 12,
              child: IgnorePointer(
                child: Center(
                  child: Material(
                    color: scheme.inverseSurface,
                    shape: const StadiumBorder(),
                    elevation: 3,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 8,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          FushiIcon(
                            item.icon,
                            size: 18,
                            color: scheme.onInverseSurface,
                          ),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              item.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(overlayContext)
                                  .textTheme
                                  .labelLarge
                                  ?.copyWith(
                                    color: scheme.onInverseSurface,
                                    fontWeight: FontWeight.w600,
                                  ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildShelfOverlay(BuildContext overlayContext, List<int> hidden) {
    final ColorScheme scheme = Theme.of(overlayContext).colorScheme;
    final List<_BookTone> tones = _bookTones(scheme);
    final Rect? bar = _rectInOverlay(_barKey);
    final Duration total = _shelf.duration ?? _kShelfRise;
    final double totalMs = math.max(1, total.inMilliseconds).toDouble();
    final double motionScale = fushiMotionEnabled(overlayContext) ? 1 : 0;
    final Animation<double> panel = CurvedAnimation(
      parent: _shelf,
      curve: Interval(
        0,
        math.min(1, _kShelfRise.inMilliseconds / totalMs),
        curve: _kShelfCurve,
      ),
      reverseCurve: FushiMotion.exit,
    );
    final Animation<double> fade = CurvedAnimation(
      parent: _shelf,
      curve: Interval(0, math.min(1, 200 / totalMs)),
      reverseCurve: FushiMotion.exit,
    );
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): _closeShelf,
      },
      child: Focus(
        focusNode: _shelfFocus,
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints box) {
            final double width = math.min(box.maxWidth - 24, 480);
            final double left = bar == null
                ? (box.maxWidth - width) / 2
                : (bar.center.dx - width / 2)
                      .clamp(12.0, math.max(12.0, box.maxWidth - width - 12))
                      .toDouble();
            final double bottom = bar == null
                ? 16
                : math.max(8, box.maxHeight - bar.bottom - 4);
            return Stack(
              children: <Widget>[
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _closeShelf,
                    child: FadeTransition(
                      opacity: fade,
                      child: ColoredBox(
                        color: scheme.scrim.withValues(alpha: 0.32),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  left: left,
                  width: width,
                  bottom: bottom,
                  child: AnimatedBuilder(
                    animation: panel,
                    builder: (BuildContext context, Widget? child) {
                      final double t = panel.value;
                      final double rise = 40 * (1 - t) * motionScale;
                      final double scaleY = 0.3 + 0.7 * t;
                      return Opacity(
                        opacity: fade.value.clamp(0.0, 1.0).toDouble(),
                        child: Transform(
                          alignment: Alignment.bottomCenter,
                          transform: Matrix4.translationValues(0, rise, 0)
                            ..multiply(
                              Matrix4.diagonal3Values(
                                1,
                                math.max(0.01, scaleY),
                                1,
                              ),
                            ),
                          child: child,
                        ),
                      );
                    },
                    child: _buildShelfPanel(
                      context,
                      scheme: scheme,
                      tones: tones,
                      hidden: hidden,
                      totalMs: totalMs,
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildShelfPanel(
    BuildContext context, {
    required ColorScheme scheme,
    required List<_BookTone> tones,
    required List<int> hidden,
    required double totalMs,
  }) {
    return Material(
      color: FushiDesignTokens.of(context).surfaces.search,
      elevation: 6,
      shadowColor: scheme.shadow,
      borderRadius: FushiM3eShape.containerLargeRadius,
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            SizedBox(
              height: _kBooksAreaHeight,
              child: LayoutBuilder(
                builder: (BuildContext context, BoxConstraints box) {
                  return HorizontalDragScrollable(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          minWidth: box.maxWidth,
                          minHeight: box.maxHeight,
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: <Widget>[
                            for (int k = 0; k < hidden.length; k++)
                              _ShelfBook(
                                item: spec.item(hidden[k]),
                                tone: tones[k % tones.length],
                                height: _bookHeight(k),
                                current: hidden[k] == spec.currentIndex,
                                outline: scheme.onSurface,
                                shade: scheme.shadow,
                                rise: CurvedAnimation(
                                  parent: _shelf,
                                  curve: Interval(
                                    math.min(
                                      1,
                                      (_kBookStagger.inMilliseconds * k) /
                                          totalMs,
                                    ),
                                    math.min(
                                      1,
                                      (_kBookStagger.inMilliseconds * k +
                                              _kBookRise.inMilliseconds) /
                                          totalMs,
                                    ),
                                    curve: _kBookCurve,
                                  ),
                                  reverseCurve: FushiMotion.exit,
                                ),
                                onTap: () => _pickFromShelf(hidden[k]),
                              ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            // 搁板。
            Container(
              height: _kShelfBoardHeight,
              decoration: BoxDecoration(
                color: scheme.tertiary,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 书架上的一本书：上面图标、下面竖排书名（字头朝上逐字往下排）。
class _ShelfBook extends StatelessWidget {
  const _ShelfBook({
    required this.item,
    required this.tone,
    required this.height,
    required this.current,
    required this.outline,
    required this.shade,
    required this.rise,
    required this.onTap,
  });

  final AdaptiveNavItem item;
  final _BookTone tone;
  final double height;
  final bool current;
  final Color outline;
  final Color shade;
  final Animation<double> rise;
  final VoidCallback onTap;

  /// 竖排书名：放不下就截断并补竖排省略号。
  List<String> _verticalGlyphs(double lineHeight) {
    final List<String> glyphs = item.label.characters
        .where((String c) => c.trim().isNotEmpty)
        .toList();
    final int room = math.max(1, ((height - 44) / lineHeight).floor());
    if (glyphs.length <= room) return glyphs;
    return <String>[...glyphs.take(math.max(0, room - 1)), '︙'];
  }

  @override
  Widget build(BuildContext context) {
    final TextScaler scaler = MediaQuery.textScalerOf(context);
    const double fontSize = 13;
    final double lineHeight = scaler.scale(fontSize) * 1.18;
    final TextStyle glyphStyle = TextStyle(
      color: tone.foreground,
      fontSize: fontSize,
      fontWeight: FontWeight.w700,
      height: 1.18,
    );
    final Duration lift = fushiMotionDuration(context, _kSpineMorph);
    final Widget book = Container(
      width: _kBookWidth,
      height: height,
      decoration: BoxDecoration(
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(5),
          bottom: Radius.circular(2),
        ),
        gradient: LinearGradient(
          colors: <Color>[
            Color.lerp(tone.background, tone.foreground, 0.12)!,
            tone.background,
            tone.background,
            Color.lerp(tone.background, shade, 0.18)!,
          ],
          stops: const <double>[0, 0.1, 0.88, 1],
        ),
      ),
      padding: const EdgeInsets.only(top: 8),
      child: ClipRect(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            FushiIcon(item.icon, size: 16, color: tone.foreground),
            const SizedBox(height: 6),
            for (final String glyph in _verticalGlyphs(lineHeight))
              Text(
                glyph,
                style: glyphStyle,
                textAlign: TextAlign.center,
                maxLines: 1,
                softWrap: false,
              ),
          ],
        ),
      ),
    );
    final Widget outlined = current
        ? Stack(
            clipBehavior: Clip.none,
            children: <Widget>[
              book,
              Positioned(
                left: -5,
                right: -5,
                top: -5,
                bottom: -5,
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      border: Border.all(color: outline, width: 3),
                      borderRadius: BorderRadius.circular(9),
                    ),
                  ),
                ),
              ),
            ],
          )
        : book;
    return Semantics(
      button: true,
      selected: current,
      label: item.label,
      excludeSemantics: true,
      child: AnimatedBuilder(
        animation: rise,
        builder: (BuildContext context, Widget? child) {
          return Transform.translate(
            offset: Offset(0, _kBooksAreaHeight * (1 - rise.value)),
            child: child,
          );
        },
        child: FushiHoverLift(
          scale: 1,
          builder: (BuildContext context, bool hovering) {
            return FushiPressScale(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onTap,
                child: SizedBox(
                  width: _kBookSlotWidth,
                  height: height + 14,
                  child: Align(
                    alignment: Alignment.bottomCenter,
                    child: AnimatedContainer(
                      duration: lift,
                      curve: _kSpineCurve,
                      transform: Matrix4.translationValues(
                        0,
                        hovering ? -10 : 0,
                        0,
                      ),
                      child: outlined,
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
