/// 底部「正在播放」条：音乐迷你条（`MusicNowPlayingBar`）与首页「正在听书」条
/// （`NowListeningMiniBar`）共用的展示组件，只吃数据与回调，不碰任何播放业务对象。
///
/// 视觉与本仓「色块 + 大字」外壳同一套（`FushiCoverBlock` / 曲目行
/// `MusicTrackRowSurface`）：
/// - 整条是一块平滑圆角（[shellShape]）色块，底色取封面色（[coverColorSchemeCache]
///   + [FushiCoverBlockColors]，与封面色块同一份缓存、同一套 HSL），没封面 / 墨水屏
///   退回中性色；色块里的字、图标、按钮一律换成色块前景 / 强调色（[_blockTheme]）；
/// - 色块背后压一行 900 字重的出血标题大字（水印），从封面右侧起往末端排、被色块
///   裁掉；悬停时色块抬起（[FushiHoverLift]，阴影加深）、大字按指针位置横移
///   （与封面色块同一条弹簧 [kFushiCoverBlockWatermarkSpring]）、封面圆环轻轻偏转；
/// - 左端是九角饼干形封面外绕一圈 M3E 波浪进度（[FushiWavyCircularProgress]，读
///   [FushiPlaybackClock]），右侧是 M3E 按钮组：上一个 / 形变播放键
///   （[FushiExpressivePlayButton]）/ 下一个，再接调用方给的额外动作。
///
/// 两形态（同一块色块、同一枚圆环封面、同一组按钮，只差排布）：
/// - 宽屏 [_DockedBar]（≥ [kFushiNowPlayingDockedMinWidth]）：底部居中、按内容
///   收宽的浮动色块；宿主往下滚（[FushiNowPlayingCollapse]）时缩成「圆环 + 标题 +
///   播放键」，悬停 / 触屏点一下弹性展开；
/// - 窄屏 [_CompactBar]：底栏上方、封顶 [kFushiNowPlayingCompactMaxWidth] 的卡片；
///   宿主往下滚时缩成贴末端的「圆环 + 播放键」，点一下先展开。放不下额外动作
///   （< [kFushiNowPlayingRoomyWidth]）且调用方给了 [FushiNowPlayingBar.onMore] 时，
///   额外动作收进长按 / 右键菜单。
///
/// Apple 设计系统同一块取色色块，外框换 Apple 实色浮层的发丝描边 + 投影
/// （[fushiAppleSolidFloatingDecoration]），按钮 / 播放键由各自的设计系统分派件
/// 画；墨水屏不压大字、不取色、不投影，改描一圈 outline。
library;

import 'dart:async';

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/shortcuts/context_menu_trigger.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/adaptive/shell_style.dart';
import 'package:fushi/src/utils/components/fushi_animated_size.dart';
import 'package:fushi/src/utils/components/fushi_continue_card_row.dart'
    show coverColorSchemeCache;
import 'package:fushi/src/utils/components/fushi_cover_block.dart'
    show FushiCoverBlockColors, kFushiCoverBlockWatermarkSpring;
import 'package:fushi/src/utils/components/fushi_expressive_progress.dart';
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart'
    show kFushiFloatingToolbarEdgeMargin;
import 'package:fushi/src/utils/components/fushi_hover_lift.dart';
import 'package:fushi/src/utils/components/fushi_m3e_player.dart'
    show FushiExpressivePlayButton, FushiPlaybackClock;
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/components/glass/fushi_expressive.dart'
    show FushiButtonGroup;
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart'
    show fushiAppleSolidFloatingDecoration;
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';

/// 可用宽到这个值就用宽屏浮动色块（M3 expanded 档下限之上）。
const double kFushiNowPlayingDockedMinWidth = 900;

/// 窄屏卡片在这个宽度以上才平铺额外动作（放不下时收进 [FushiNowPlayingBar.onMore]）。
const double kFushiNowPlayingRoomyWidth = 520;

/// 窄屏卡片封顶宽度（宽一些的手机横屏 / 平板竖屏不铺满）。
const double kFushiNowPlayingCompactMaxWidth = 560;

/// 色块圆角（平滑圆角下由 [shellShape] 再放大）。
const double kFushiNowPlayingRadius = 28;

/// 悬停抬起的放大倍数：整条很宽，比卡片的默认倍数轻得多。
const double kFushiNowPlayingLiftScale = 1.015;

/// 播放中刷新进度圆环的周期（读 [FushiPlaybackClock]，不是动效时长）。
const Duration kFushiNowPlayingProgressTick = Duration(milliseconds: 500);

/// 展开态封面圆环边长（两形态同一个尺寸）。
const double _kRing = 60;

/// 宽屏收起态的封面圆环边长。
const double _kRingCollapsed = 48;

/// 上一个 / 下一个键的数据（null 回调 = 显示但禁用）。
class FushiNowPlayingSkip {
  const FushiNowPlayingSkip({
    required this.icon,
    required this.tooltip,
    this.onPressed,
    this.key,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final Key? key;
}

/// 宿主页的「滚动收起」状态（往下滚 = 收起，往上滚 = 展开）。没有这一层时恒为
/// 展开。
class FushiNowPlayingCollapse extends InheritedWidget {
  const FushiNowPlayingCollapse({
    super.key,
    required this.collapsed,
    required super.child,
  });

  final bool collapsed;

  static bool of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<FushiNowPlayingCollapse>()
          ?.collapsed ??
      false;

  @override
  bool updateShouldNotify(FushiNowPlayingCollapse oldWidget) =>
      oldWidget.collapsed != collapsed;
}

/// 底部「正在播放」条。见文件头。
class FushiNowPlayingBar extends StatefulWidget {
  const FushiNowPlayingBar({
    required this.title,
    required this.coverBuilder,
    required this.isPlaying,
    required this.onPlayPause,
    required this.onTap,
    this.subtitle,
    this.titleTrailing,
    this.tintImage,
    this.clock,
    this.previous,
    this.next,
    this.actions = const <Widget>[],
    this.onMore,
    this.barKey,
    this.playButtonKey,
    super.key,
  });

  /// 主标题（也是背后压的出血大字）。
  final String title;

  /// 副标题（歌手 · 专辑 / 当前句）；null / 空串不画。
  final String? subtitle;

  /// 紧跟主标题的小件（试听标记等）。
  final Widget? titleTrailing;

  /// 封面（给定边长的方图；组件负责裁成九角饼干形）。在色块配色的主题下调用，
  /// 占位图可直接读 `Theme.of(context).colorScheme.primary / onPrimary`。
  final Widget Function(BuildContext context, double size) coverBuilder;

  /// 取色用的封面图源（与 [coverBuilder] 同一张）；null = 中性色块。
  final ImageProvider? tintImage;

  /// 进度读口（封面外圈的波浪进度）；null = 只画底圈。
  final FushiPlaybackClock? clock;

  final bool isPlaying;
  final VoidCallback onPlayPause;

  /// 上一个 / 下一个；null = 不放这颗键。
  final FushiNowPlayingSkip? previous;
  final FushiNowPlayingSkip? next;

  /// 按钮组之后的额外动作（纯图标按钮，tooltip / Semantics 由各按钮自带）。
  /// 需要在弹出浮层期间保持宽屏展开的（音量滑杆等）用
  /// [FushiNowPlayingBar.holdExpandedOf] 报告浮层开合。
  final List<Widget> actions;

  /// 窄屏放不下额外动作时的「更多」菜单（长按 / 右键条身）；null = 额外动作恒平铺。
  final VoidCallback? onMore;

  /// 点条身（按钮各自吃掉自己的点击）。
  final VoidCallback onTap;

  /// 条身点按区的 key（测试 / 自动化定位用）。
  final Key? barKey;

  /// 播放键的 key。
  final Key? playButtonKey;

  /// 额外动作里弹浮层的件拿它报告浮层开合：开着时宽屏色块不收起（浮层浮在
  /// 色块外，指针移过去会离开色块）。不在本组件下面时为 null。
  static ValueChanged<bool>? holdExpandedOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<_HoldScope>()?.onHold;

  @override
  State<FushiNowPlayingBar> createState() => _FushiNowPlayingBarState();
}

class _FushiNowPlayingBarState extends State<FushiNowPlayingBar> {
  /// 封面取色（与封面色块同一份缓存）；两套设计系统都取色，墨水屏不取。
  ColorScheme? _scheme;
  ImageProvider? _tintFor;
  Brightness? _tintBrightness;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolveTint();
  }

  @override
  void didUpdateWidget(FushiNowPlayingBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    _resolveTint();
  }

  void _resolveTint() {
    final ImageProvider? image = isEinkTheme(context) ? null : widget.tintImage;
    final Brightness brightness = Theme.of(context).brightness;
    if (image == _tintFor && brightness == _tintBrightness) return;
    _tintFor = image;
    _tintBrightness = brightness;
    if (image == null) {
      _scheme = null;
      return;
    }
    // 换了封面：先取缓存里的（没有就 null = 中性色），不留上一张的配色。
    _scheme = coverColorSchemeCache.peek(image, brightness);
    if (_scheme != null) return;
    unawaited(
      coverColorSchemeCache.resolve(image, brightness).then((ColorScheme? s) {
        if (!mounted || _tintFor != image || _tintBrightness != brightness) {
          return;
        }
        setState(() => _scheme = s);
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final FushiCoverBlockColors colors = FushiCoverBlockColors.resolve(
      theme,
      _scheme,
    );
    final FushiMotionScheme motion = context.fushiMotion;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        final Widget bar = c.maxWidth >= kFushiNowPlayingDockedMinWidth
            ? _DockedBar(bar: widget, colors: colors)
            : _CompactBar(
                bar: widget,
                colors: colors,
                roomy: c.maxWidth >= kFushiNowPlayingRoomyWidth,
              );
        // 首次出现弹簧上浮落位（减弱动态 / 墨水屏下时长为零）。
        return TweenAnimationBuilder<double>(
          tween: Tween<double>(begin: 0, end: 1),
          duration: motion.spatialDefault.duration,
          curve: motion.spatialDefault.curve,
          builder: (BuildContext context, double v, Widget? child) =>
              Transform.translate(
                offset: Offset(0, (1 - v) * 24),
                child: Opacity(opacity: v.clamp(0.0, 1.0), child: child),
              ),
          child: bar,
        );
      },
    );
  }
}

/// 色块里的局部主题：按钮 / 图标 / 播放键读到的是色块前景与强调色，而不是应用
/// 主题色（浅色下强调色与前景同为深色，播放键是深底浅字；深色下是浅底深字）。
ThemeData _blockTheme(ThemeData base, FushiCoverBlockColors c) {
  final Color tonal = Color.alphaBlend(
    c.onContainer.withValues(alpha: 0.12),
    c.container,
  );
  return base.copyWith(
    colorScheme: base.colorScheme.copyWith(
      primary: c.accent,
      onPrimary: c.container,
      secondaryContainer: tonal,
      onSecondaryContainer: c.onContainer,
      onSurface: c.onContainer,
      onSurfaceVariant: c.onContainer.withValues(alpha: 0.78),
    ),
    iconTheme: base.iconTheme.copyWith(color: c.onContainer),
  );
}

/// 上一个 / 形变播放键 / 下一个（M3E 标准按钮组）。播放条之外的播放页也可直接用。
class FushiNowPlayingTransport extends StatelessWidget {
  const FushiNowPlayingTransport({
    required this.isPlaying,
    required this.onPlayPause,
    required this.playSize,
    this.previous,
    this.next,
    this.playButtonKey,
    super.key,
  });

  final bool isPlaying;
  final VoidCallback onPlayPause;
  final double playSize;
  final FushiNowPlayingSkip? previous;
  final FushiNowPlayingSkip? next;
  final Key? playButtonKey;

  Widget _skip(FushiNowPlayingSkip skip) => FushiIconButtonControl.filledTonal(
    key: skip.key,
    size: ButtonSizeVariant.small,
    tooltip: skip.tooltip,
    onPressed: skip.onPressed,
    icon: FushiIcon(skip.icon),
  );

  @override
  Widget build(BuildContext context) {
    final FushiNowPlayingSkip? prev = previous;
    final FushiNowPlayingSkip? nxt = next;
    return FushiButtonGroup(
      spacing: 4,
      children: <Widget>[
        if (prev != null) _skip(prev),
        FushiExpressivePlayButton(
          key: playButtonKey,
          isPlaying: isPlaying,
          size: playSize,
          onPressed: onPlayPause,
        ),
        if (nxt != null) _skip(nxt),
      ],
    );
  }
}

/// 额外动作的「保持展开」通道（见 [FushiNowPlayingBar.holdExpandedOf]）。
class _HoldScope extends InheritedWidget {
  const _HoldScope({required this.onHold, required super.child});

  final ValueChanged<bool> onHold;

  @override
  bool updateShouldNotify(_HoldScope oldWidget) => false;
}

/// 色块外壳：取色底、平滑圆角、投影 / 描边、出血大字、悬停抬起、点条身。两形态
/// 共用；[builder] 拿到「指针是否在色块上」（封面圆环据此偏转）。
class _BarShell extends StatefulWidget {
  const _BarShell({
    required this.bar,
    required this.colors,
    required this.padding,
    required this.watermarkStart,
    required this.onTap,
    required this.builder,
    this.onLongPress,
  });

  final FushiNowPlayingBar bar;
  final FushiCoverBlockColors colors;
  final EdgeInsetsGeometry padding;

  /// 大字从色块起始侧往里多少开始排（封面右侧）。
  final double watermarkStart;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final Widget Function(BuildContext context, bool hovered) builder;

  @override
  State<_BarShell> createState() => _BarShellState();
}

class _BarShellState extends State<_BarShell>
    with SingleTickerProviderStateMixin {
  /// 大字 X 偏移（逻辑像素，弹簧可过冲）。
  late final AnimationController _shift = AnimationController.unbounded(
    vsync: this,
  );
  bool _hovered = false;

  @override
  void dispose() {
    _shift.dispose();
    super.dispose();
  }

  void _setHover(bool hovered, {double fraction = 0.5}) {
    if (hovered != _hovered) setState(() => _hovered = hovered);
    final FushiSpringSpec spec = fushiMotionEnabled(context)
        ? kFushiCoverBlockWatermarkSpring
        : kFushiCoverBlockWatermarkSpring.reduced;
    // 与封面色块同一手感：指针越靠末端，大字往起始侧让得越多。
    unawaited(_shift.fushiSpringTo(hovered ? -24 - fraction * 48 : 0, spec));
  }

  void _onHover(PointerEvent event) {
    if (event.kind != PointerDeviceKind.mouse) return;
    // 色块按内容收宽（宽屏），按实际宽度归一指针位置。
    final double width = context.size?.width ?? 0;
    final double f = width <= 0
        ? 0.5
        : (event.localPosition.dx / width).clamp(0.0, 1.0);
    _setHover(true, fraction: f);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool eink = isEinkTheme(context);
    final bool glass = isGlassDesign(context);
    final FushiCoverBlockColors colors = widget.colors;
    const BorderRadius radius = BorderRadius.all(
      Radius.circular(kFushiNowPlayingRadius),
    );
    final Duration duration = fushiMotionDuration(context, FushiMotion.short);
    final ShapeDecoration decoration;
    if (eink) {
      // 墨水屏：中性色底塌成页面底色，描一圈 outline 把条切出来（阴影 / 半透明在
      // 灰阶下都会糊成脏边）。
      decoration = ShapeDecoration(
        color: colors.container,
        shape: shellShape(
          context,
          radius,
          side: BorderSide(color: theme.colorScheme.outline),
        ),
      );
    } else if (glass) {
      decoration = fushiAppleSolidFloatingDecoration(
        context,
        shape: shellShape(context, radius),
        tint: colors.container,
      );
    } else {
      final Color shadow = theme.colorScheme.shadow;
      decoration = ShapeDecoration(
        color: colors.container,
        shape: shellShape(context, radius),
        shadows: <BoxShadow>[
          BoxShadow(
            color: shadow.withValues(alpha: _hovered ? 0.34 : 0.26),
            blurRadius: _hovered ? 28 : 18,
            offset: Offset(0, _hovered ? 10 : 6),
          ),
        ],
      );
    }
    final TextDirection direction = Directionality.of(context);
    final Widget surface = AnimatedContainer(
      duration: duration,
      curve: FushiMotion.standard,
      decoration: decoration,
      child: ShellClip(
        radius: radius,
        child: Stack(
          children: <Widget>[
            if (!eink)
              Positioned.fill(
                child: IgnorePointer(
                  child: ExcludeSemantics(
                    child: CustomPaint(
                      painter: _WatermarkPainter(
                        title: widget.bar.title,
                        style: context.fushiType.displayLarge.copyWith(
                          fontWeight: FontWeight.w900,
                          height: 0.82,
                          color: colors.accent.withValues(
                            alpha: colors.watermarkOpacity,
                          ),
                        ),
                        start: widget.watermarkStart,
                        shift: _shift,
                        direction: direction,
                      ),
                    ),
                  ),
                ),
              ),
            Material(
              type: MaterialType.transparency,
              child: InkWell(
                key: widget.bar.barKey,
                onTap: widget.onTap,
                onLongPress: widget.onLongPress,
                customBorder: shellShape(context, radius),
                hoverColor: Colors.transparent,
                splashFactory: glass ? NoSplash.splashFactory : null,
                child: Padding(
                  padding: widget.padding,
                  child: widget.builder(context, _hovered),
                ),
              ),
            ),
          ],
        ),
      ),
    );
    return MouseRegion(
      opaque: false,
      onEnter: _onHover,
      onHover: _onHover,
      onExit: (_) => _setHover(false),
      child: FushiHoverLift(
        scale: kFushiNowPlayingLiftScale,
        builder: (BuildContext context, bool _) => FushiPressScale(
          child: Theme(
            data: eink ? theme : _blockTheme(theme, colors),
            child: surface,
          ),
        ),
      ),
    );
  }
}

/// 出血标题大字：字号按色块高度定（高 × 0.62，与封面色块水印同一比例 / 字距 /
/// 行高 / 透明度），从 [start] 起往末端排、被色块裁掉；[shift] 驱动悬停横移。
/// 纯装饰：画在 CustomPaint 里，不进语义、不参与命中、不进文字查找。
class _WatermarkPainter extends CustomPainter {
  _WatermarkPainter({
    required this.title,
    required this.style,
    required this.start,
    required this.shift,
    required this.direction,
  }) : super(repaint: shift);

  final String title;
  final TextStyle style;
  final double start;
  final Animation<double> shift;
  final TextDirection direction;

  @override
  void paint(Canvas canvas, Size size) {
    final double base = style.fontSize ?? 57;
    final double target = size.height * 0.62;
    final double k = target / base;
    final TextPainter painter = TextPainter(
      text: TextSpan(
        text: title,
        style: style.copyWith(letterSpacing: -0.05 * base),
      ),
      textDirection: direction,
      maxLines: 1,
      textScaler: TextScaler.noScaling,
    )..layout();
    final double width = painter.width * k;
    final double dx = direction == TextDirection.rtl
        ? size.width - start - width - shift.value
        : start + shift.value;
    canvas
      ..save()
      ..translate(dx, size.height * 0.02)
      ..scale(k);
    painter.paint(canvas, Offset.zero);
    canvas.restore();
    painter.dispose();
  }

  @override
  bool shouldRepaint(covariant _WatermarkPainter old) =>
      old.title != title ||
      old.style != style ||
      old.start != start ||
      old.direction != direction;
}

/// 九角饼干形封面外绕一圈波浪进度；播放中按 [kFushiNowPlayingProgressTick] 读
/// [FushiPlaybackClock] 刷新，暂停 / 被盖住（[TickerMode] 关）时不常驻计时器。
/// 悬停时轻轻偏转（[FushiHoverLift]）。
class _CoverRing extends StatefulWidget {
  const _CoverRing({
    required this.bar,
    required this.colors,
    required this.size,
    required this.hovered,
  });

  final FushiNowPlayingBar bar;
  final FushiCoverBlockColors colors;
  final double size;
  final bool hovered;

  @override
  State<_CoverRing> createState() => _CoverRingState();
}

class _CoverRingState extends State<_CoverRing> {
  Timer? _ticker;
  bool _tickerModeEnabled = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _tickerModeEnabled = TickerMode.valuesOf(context).enabled;
    _sync();
  }

  @override
  void didUpdateWidget(_CoverRing oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  void _sync() {
    final bool run =
        widget.bar.isPlaying && widget.bar.clock != null && _tickerModeEnabled;
    if (run && _ticker == null) {
      _ticker = Timer.periodic(kFushiNowPlayingProgressTick, (_) {
        if (mounted) setState(() {});
      });
    } else if (!run) {
      _ticker?.cancel();
      _ticker = null;
    }
  }

  double _progress() {
    final FushiPlaybackClock? clock = widget.bar.clock;
    if (clock == null) return 0;
    final int total = clock.duration.inMilliseconds;
    if (total <= 0) return 0;
    return (clock.position.inMilliseconds / total).clamp(0.0, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    final double size = widget.size;
    final FushiCoverBlockColors colors = widget.colors;
    final Duration duration = fushiMotionDuration(context, FushiMotion.medium);
    return SizedBox.square(
      dimension: size,
      child: Stack(
        alignment: Alignment.center,
        children: <Widget>[
          FushiWavyCircularProgress(
            value: _progress(),
            color: colors.accent,
            trackColor: colors.onContainer.withValues(alpha: 0.14),
            strokeWidth: 3,
            size: size,
            padding: EdgeInsets.zero,
          ),
          FushiHoverLift(
            forceLifted: widget.hovered,
            builder: (BuildContext context, bool lifted) => AnimatedRotation(
              duration: duration,
              curve: FushiSpringCurve.spatial,
              // 抬起时饼干形转小半瓣，与色块里压着的封面同一种姿态。
              turns: lifted ? -0.03 : 0,
              child: ClipPath(
                clipper: ShapeBorderClipper(
                  shape: MaterialShapeBorder(
                    shape: MaterialShapes.cookie9Sided,
                  ),
                ),
                child: SizedBox.square(
                  dimension: size - 16,
                  child: widget.bar.coverBuilder(context, size - 16),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 主标题（+ 小件）与副标题两行，色块前景色。
class _TitleBlock extends StatelessWidget {
  const _TitleBlock({required this.bar, required this.colors});

  final FushiNowPlayingBar bar;
  final FushiCoverBlockColors colors;

  @override
  Widget build(BuildContext context) {
    final FushiTypography type = context.fushiType;
    final String? subtitle = bar.subtitle;
    final Widget? trailing = bar.titleTrailing;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Flexible(
              child: Text(
                bar.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: type.titleSmallEmphasized.copyWith(
                  color: colors.onContainer,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            ?trailing,
          ],
        ),
        if (subtitle != null && subtitle.isNotEmpty)
          Text(
            subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: type.bodySmall.copyWith(
              color: colors.onContainer.withValues(alpha: 0.72),
            ),
          ),
      ],
    );
  }
}

/// 窄屏：底栏上方的卡片（见文件头）。
class _CompactBar extends StatelessWidget {
  const _CompactBar({
    required this.bar,
    required this.colors,
    required this.roomy,
  });

  final FushiNowPlayingBar bar;
  final FushiCoverBlockColors colors;

  /// 宽度够时平铺额外动作；不够且有 [FushiNowPlayingBar.onMore] 时收进菜单。
  final bool roomy;

  @override
  Widget build(BuildContext context) => _CollapsePeek(
    builder: (BuildContext context, bool collapsed, VoidCallback peek) {
      final Duration motion = fushiMotionDuration(context, FushiMotion.medium);
      final VoidCallback? more = roomy ? null : bar.onMore;
      final bool showActions = !collapsed && more == null;
      final Widget card = _BarShell(
        bar: bar,
        colors: colors,
        padding: EdgeInsets.fromLTRB(8, 8, collapsed ? 8 : 10, 8),
        watermarkStart: 8 + _kRing + 4,
        // 收起时点一下先展开，展开后再点才是条身动作。
        onTap: collapsed ? peek : bar.onTap,
        onLongPress: collapsed ? null : more,
        builder: (BuildContext context, bool hovered) => FushiAnimatedSize(
          duration: motion,
          curve: FushiSpringCurve.spatial,
          alignment: AlignmentDirectional.centerEnd,
          child: Row(
            mainAxisSize: collapsed ? MainAxisSize.min : MainAxisSize.max,
            children: <Widget>[
              _CoverRing(
                bar: bar,
                colors: colors,
                size: _kRing,
                hovered: hovered,
              ),
              if (collapsed) ...<Widget>[
                const SizedBox(width: 10),
                FushiExpressivePlayButton(
                  key: bar.playButtonKey,
                  isPlaying: bar.isPlaying,
                  size: 48,
                  onPressed: bar.onPlayPause,
                ),
              ] else ...<Widget>[
                const SizedBox(width: 12),
                Expanded(
                  child: _TitleBlock(bar: bar, colors: colors),
                ),
                const SizedBox(width: 8),
                FushiNowPlayingTransport(
                  isPlaying: bar.isPlaying,
                  onPlayPause: bar.onPlayPause,
                  playSize: 48,
                  previous: bar.previous,
                  next: bar.next,
                  playButtonKey: bar.playButtonKey,
                ),
                if (showActions) ...bar.actions,
              ],
            ],
          ),
        ),
      );
      return Padding(
        padding: const EdgeInsets.fromLTRB(
          kFushiFloatingToolbarEdgeMargin,
          4,
          kFushiFloatingToolbarEdgeMargin,
          8,
        ),
        child: AnimatedAlign(
          duration: motion,
          curve: FushiSpringCurve.effects,
          heightFactor: 1,
          alignment: collapsed
              ? AlignmentDirectional.centerEnd.resolve(
                  Directionality.of(context),
                )
              : Alignment.center,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: kFushiNowPlayingCompactMaxWidth,
            ),
            child: more == null
                ? card
                : ContextMenuTrigger(
                    onInvoke: contextMenuInvoker(more),
                    child: card,
                  ),
          ),
        ),
      );
    },
  );
}

/// 宽屏：底部居中、按内容收宽的浮动色块；宿主滚动收起时缩成「圆环 + 标题 +
/// 播放键」，鼠标移上去（触屏先点一下）弹性展开出副标题、上 / 下一个与额外动作。
class _DockedBar extends StatefulWidget {
  const _DockedBar({required this.bar, required this.colors});

  final FushiNowPlayingBar bar;
  final FushiCoverBlockColors colors;

  @override
  State<_DockedBar> createState() => _DockedBarState();
}

class _DockedBarState extends State<_DockedBar> {
  bool _hovered = false;

  /// 触屏点开的展开态（没有悬停可依赖）；点到条外或鼠标离开时收起。
  bool _pinned = false;

  /// 额外动作的浮层开着（[FushiNowPlayingBar.holdExpandedOf]）：浮层在条外，
  /// 鼠标移过去会离开条，这期间不许收起。
  bool _held = false;

  void _hold(bool held) {
    if (held != _held && mounted) setState(() => _held = held);
  }

  @override
  Widget build(BuildContext context) {
    final FushiNowPlayingBar bar = widget.bar;
    final FushiCoverBlockColors colors = widget.colors;
    final bool expanded =
        _hovered || _pinned || _held || !FushiNowPlayingCollapse.of(context);
    final double ring = expanded ? _kRing : _kRingCollapsed;
    final Duration motion = fushiMotionDuration(context, FushiMotion.medium);
    Widget cover(bool hovered) =>
        _CoverRing(bar: bar, colors: colors, size: ring, hovered: hovered);
    Widget collapsedRow(bool hovered) => Row(
      key: const ValueKey<String>('now-playing-docked-collapsed'),
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        cover(hovered),
        const SizedBox(width: 12),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 200),
          child: Text(
            bar.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: context.fushiType.titleSmallEmphasized.copyWith(
              color: colors.onContainer,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        const SizedBox(width: 12),
        FushiExpressivePlayButton(
          key: bar.playButtonKey,
          isPlaying: bar.isPlaying,
          size: 44,
          onPressed: bar.onPlayPause,
        ),
      ],
    );
    Widget openRow(bool hovered) => Row(
      key: const ValueKey<String>('now-playing-docked-expanded'),
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        cover(hovered),
        const SizedBox(width: 14),
        SizedBox(
          width: 220,
          child: _TitleBlock(bar: bar, colors: colors),
        ),
        const SizedBox(width: 12),
        FushiNowPlayingTransport(
          isPlaying: bar.isPlaying,
          onPlayPause: bar.onPlayPause,
          playSize: 52,
          previous: bar.previous,
          next: bar.next,
          playButtonKey: bar.playButtonKey,
        ),
        if (bar.actions.isNotEmpty) const SizedBox(width: 8),
        ...bar.actions,
      ],
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
      child: AnimatedAlign(
        duration: motion,
        curve: FushiSpringCurve.effects,
        heightFactor: 1,
        alignment: Alignment.center,
        child: MouseRegion(
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() {
            _hovered = false;
            _pinned = false;
          }),
          child: TapRegion(
            onTapOutside: (_) {
              if (_pinned) setState(() => _pinned = false);
            },
            child: _HoldScope(
              onHold: _hold,
              child: _BarShell(
                bar: bar,
                colors: colors,
                padding: EdgeInsets.fromLTRB(8, 6, expanded ? 12 : 8, 6),
                watermarkStart: 8 + ring + 4,
                // 收起时第一下只展开（触屏没有悬停）；展开后点条身才是条身动作。
                onTap: expanded
                    ? bar.onTap
                    : () => setState(() => _pinned = true),
                builder: (BuildContext context, bool hovered) =>
                    FushiAnimatedSize(
                      duration: motion,
                      curve: FushiSpringCurve.spatial,
                      child: AnimatedSwitcher(
                        duration: fushiMotionDuration(
                          context,
                          FushiMotion.short,
                        ),
                        layoutBuilder:
                            (Widget? current, List<Widget> previous) => Stack(
                              alignment: Alignment.center,
                              clipBehavior: Clip.none,
                              children: <Widget>[
                                for (final Widget w in previous)
                                  Positioned(child: w),
                                ?current,
                              ],
                            ),
                        child: expanded
                            ? openRow(hovered)
                            : collapsedRow(hovered),
                      ),
                    ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 滚动收起的「先展开」：收起时点一下只展开（[peek]），展开后再点才是条身动作；
/// 宿主的收起状态一翻转（再往下 / 往上滚）就把这次展开作废。
class _CollapsePeek extends StatefulWidget {
  const _CollapsePeek({required this.builder});

  final Widget Function(BuildContext context, bool collapsed, VoidCallback peek)
  builder;

  @override
  State<_CollapsePeek> createState() => _CollapsePeekState();
}

class _CollapsePeekState extends State<_CollapsePeek> {
  bool? _hostCollapsed;
  bool _peeking = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final bool host = FushiNowPlayingCollapse.of(context);
    if (host != _hostCollapsed) {
      _hostCollapsed = host;
      _peeking = false;
    }
  }

  @override
  Widget build(BuildContext context) => widget.builder(
    context,
    (_hostCollapsed ?? false) && !_peeking,
    () => setState(() => _peeking = true),
  );
}
