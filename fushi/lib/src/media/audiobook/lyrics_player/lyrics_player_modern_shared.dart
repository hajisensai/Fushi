import 'dart:async';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_control_layout.dart';
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_control_layout_editor.dart'
    show lyricsControlItemIcon, lyricsControlItemLabel;
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_illustration_view.dart';
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_player_contract.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart'
    show FushiToolbarItem, FushiTopBarOverflowFit;
import 'package:fushi/src/utils/components/fushi_m3e_list_card.dart'
    show FushiM3eShape;
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

// 歌词模式「新版」播放控件（`LyricsControlsStyle.modern`）里与设计系统无关的部分：
// 宽屏几何（浮岛 / 进度线 / 时间行 / 歌词矩形）、字号档位、右岛测宽收进 ⋯、读数、
// 每秒轮询、窄屏可收起播放卡的几何与展开 / 收起交互、进场动效、底栏压暗。MD3
// （`Md3ModernLyricsPlayerDesign`）与 Apple（`AppleModernLyricsPlayerDesign`）两套
// 外观只各自画按钮 / 底色 / 字色，几何与交互出自这里同一份，歌词矩形不会两边各算
// 一套。宽屏底栏常驻（用户 2026-11-04「底部控制栏做成常驻不要收起」）。

/// 宽屏底栏的播放键边长（左右岛高度至少这么高）。
const double kLyricsModernWidePlaySize = 64;

/// 宽屏底栏的上一句 / 下一句 / ±10 秒圆钮边长。
const double kLyricsModernWideTransportSize = 52;

/// 宽屏中区钮间距。
const double kLyricsModernWideTransportGap = 12;

/// 宽屏右下动作钮（圆角方块）的尺寸与块间距。
const double kLyricsModernTileHeight = 48;
const double kLyricsModernTileWidth = 52;
const double kLyricsModernTileGap = 6;

/// 倍速键（文字按钮）所在方块的宽度（测宽时比一颗图标钮多占的部分先扣掉）。
const double kLyricsModernSpeedTileWidth = 76;

/// 宽屏浮岛：外边距、岛间距、进度线命中带高度。
const double kLyricsModernWideMargin = 24;
const double kLyricsModernIslandGap = 16;
const double kLyricsModernSeekBand = 24;

/// 右岛动作收进 ⋯ 的优先级（高 → 低）：放不下时从末尾起收。显示顺序仍按用户的
/// 按钮布局（[LyricsControlLayout]）。
const List<LyricsControlItem> kLyricsModernWidePriority = <LyricsControlItem>[
  LyricsControlItem.speed,
  LyricsControlItem.replayCue,
  LyricsControlItem.mask,
  LyricsControlItem.typography,
  LyricsControlItem.bookMode,
  LyricsControlItem.studyTimer,
  LyricsControlItem.statistics,
];

/// 宽屏中区宽：播放键 + 其余圆钮 + 钮间距 + 两侧 8。有 ±10 秒回调时 5 颗，否则 3 颗。
double lyricsModernWideCenterWidth(LyricsPlayerCallbacks callbacks) {
  final int buttons = callbacks.onSeekRelative == null ? 3 : 5;
  return kLyricsModernWidePlaySize +
      (buttons - 1) * kLyricsModernWideTransportSize +
      (buttons - 1) * kLyricsModernWideTransportGap +
      16;
}

// ---------------------------------------------------------------------------
// 宽屏几何
// ---------------------------------------------------------------------------

/// 宽屏左岛 / 两端时间的字号档位：按窗口宽度分三档（与左岛最大宽同一套断点），
/// 大屏上底栏文字跟着放大，不再是固定 14 / 11（大屏上看不清）。档位只取
/// [FushiTypography] 的角色（不写裸字号），跟随用户字体与字号缩放。颜色 / 字重
/// 由各设计系统自己叠。
@immutable
class LyricsModernWideText {
  const LyricsModernWideText._({
    required this.title,
    required this.detail,
    required this.thumbHeight,
    required this.maxInfoWidth,
  });

  factory LyricsModernWideText.of(BuildContext context, double width) {
    final FushiTypography type = context.fushiType;
    if (width >= 1900) {
      return LyricsModernWideText._(
        title: type.titleLargeEmphasized,
        detail: type.labelLarge,
        thumbHeight: 56,
        maxInfoWidth: 420,
      );
    }
    if (width >= 1200) {
      return LyricsModernWideText._(
        title: type.titleMediumEmphasized,
        detail: type.labelLarge,
        thumbHeight: 52,
        maxInfoWidth: 340,
      );
    }
    return LyricsModernWideText._(
      title: type.labelLargeEmphasized,
      detail: type.labelMedium,
      thumbHeight: 44,
      maxInfoWidth: 260,
    );
  }

  /// 书名。
  final TextStyle title;

  /// 章名 · 进度、进度线两端时间。
  final TextStyle detail;

  /// 左岛封面位高度。
  final double thumbHeight;

  /// 左岛最大宽。
  final double maxInfoWidth;
}

/// 新版宽屏几何：浮岛 / 进度线 / 时间行 / 歌词矩形出自同一份计算（两套设计系统
/// 共用）。
@immutable
class LyricsModernWideGeometry {
  const LyricsModernWideGeometry._({
    required this.islandHeight,
    required this.islandTop,
    required this.left,
    required this.right,
    required this.seekBand,
    required this.timeTop,
    required this.lyrics,
    required this.text,
  });

  factory LyricsModernWideGeometry.of(
    BuildContext context,
    Size size,
    EdgeInsets padding,
  ) {
    final TextScaler scaler = MediaQuery.textScalerOf(context);
    final LyricsModernWideText text = LyricsModernWideText.of(
      context,
      size.width,
    );
    // 左侧信息两行：书名 / 章名（读数在进度线上方居中，不占底栏高度）。
    final double textLines =
        scaler.scale(text.title.fontSize ?? 14) * 1.4 +
        scaler.scale(text.detail.fontSize ?? 12) * 1.4;
    final double islandHeight = math
        .max(kLyricsModernWidePlaySize, math.max(textLines, text.thumbHeight))
        .ceilToDouble();
    final double left = padding.left + kLyricsModernWideMargin;
    final double right = math.max(
      left + 1,
      size.width - padding.right - kLyricsModernWideMargin,
    );
    final double islandBottom = math.max(
      islandHeight,
      size.height - padding.bottom - 12,
    );
    final double islandTop = islandBottom - islandHeight;
    final Rect seekBand = Rect.fromLTRB(
      left,
      islandTop - 2 - kLyricsModernSeekBand,
      right,
      islandTop - 2,
    );
    final double timeHeight = scaler.scale(text.detail.fontSize ?? 12) * 1.4;
    final double timeTop = seekBand.top - timeHeight;
    final double lyricsTop = padding.top + 28;
    final Rect lyrics = Rect.fromLTRB(
      padding.left + 40,
      lyricsTop,
      math.max(padding.left + 41, size.width - padding.right - 40),
      math.max(lyricsTop + 1, timeTop - 12),
    );
    return LyricsModernWideGeometry._(
      islandHeight: islandHeight,
      islandTop: islandTop,
      left: left,
      right: right,
      seekBand: seekBand,
      timeTop: timeTop,
      lyrics: lyrics,
      text: text,
    );
  }

  final double islandHeight;

  /// 底栏文字档位（左岛 / 时间）。
  final LyricsModernWideText text;
  final double islandTop;
  final double left;
  final double right;

  /// 进度线的命中带（整宽，24 高；线画在带子中间）。
  final Rect seekBand;

  /// 进度线上方左右两端时间的顶边。
  final double timeTop;
  final Rect lyrics;

  /// 插图弹出卡的最大框：320×460（1920 宽及以上 400×560），高度不超过可用空间。
  Size popupSize(Size page, EdgeInsets padding) {
    final bool big = page.width >= 1900;
    final double maxH = timeTop - 12 - (padding.top + 16);
    return Size(
      math.min(big ? 400.0 : 320.0, (right - left) * 0.5),
      math.max(0, math.min(big ? 560.0 : 460.0, maxH)),
    );
  }
}

/// 无底板底栏下面的一层渐隐压暗（保证按钮 / 文字在背景上可读）。不吃指针。
class LyricsModernBottomScrim extends StatelessWidget {
  const LyricsModernBottomScrim({
    this.color = const Color(0x38000000),
    super.key,
  });

  /// 底端压暗色（顶端渐隐到全透明）。
  final Color color;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[color.withValues(alpha: 0), color],
        ),
      ),
    ),
  );
}

// ---------------------------------------------------------------------------
// 右岛测宽
// ---------------------------------------------------------------------------

/// 右岛的平铺 / 收起结果：[shown] 平铺，[collapsed] 收进 ⋯（按显示顺序）。
typedef LyricsModernActionSplit = ({
  Set<LyricsControlItem> shown,
  List<LyricsControlItem> collapsed,
});

/// 右岛动作默认平铺；放不下时按 [kLyricsModernWidePriority] 从低优先级起收进 ⋯
/// （收进去的按钮经 [LyricsMenuAnchor.collapsedItems] 交给页面排在菜单最前）。
/// 测宽复用 [FushiTopBarOverflowFit]（顶栏同一套，含展开回差；[fit] 由调用方的
/// State 持有）。[items] 是按显示顺序、当前形态下会渲染的按钮；关闭键与跳转记录
/// 恒在，先从 [budget] 里扣掉。
LyricsModernActionSplit lyricsModernActionSplit({
  required FushiTopBarOverflowFit fit,
  required List<LyricsControlItem> items,
  required double budget,
  required int jumpActionCount,
}) {
  const double slot = kLyricsModernTileWidth + kLyricsModernTileGap;
  // 按优先级排成一组交给测宽；倍速键比图标钮宽，关闭键恒在，先从预算里扣掉。
  final List<LyricsControlItem> byPriority = <LyricsControlItem>[
    for (final LyricsControlItem p in kLyricsModernWidePriority)
      if (items.contains(p)) p,
    for (final LyricsControlItem i in items)
      if (!kLyricsModernWidePriority.contains(i)) i,
  ];
  final bool hasSpeed = items.contains(LyricsControlItem.speed);
  // 跳转记录的返回 / 前进恒在岛的最前，与关闭键一样先从预算里扣掉。
  final double remaining =
      budget -
      slot -
      jumpActionCount * slot -
      (hasSpeed ? kLyricsModernSpeedTileWidth - slot : 0);
  final List<FushiToolbarItem> probe = <FushiToolbarItem>[
    for (final LyricsControlItem item in byPriority)
      FushiToolbarItem(
        icon: lyricsControlItemIcon(item),
        label: lyricsControlItemLabel(item),
        onPressed: null,
      ),
  ];
  final int visible = fit.visibleFor(
    groups: <List<FushiToolbarItem>>[probe],
    budget: remaining,
    pinnedMenu: true,
    slotWidth: slot,
    padding: 16,
  );
  final Set<LyricsControlItem> shown = byPriority.take(visible).toSet();
  return (
    shown: shown,
    collapsed: <LyricsControlItem>[
      for (final LyricsControlItem item in items)
        if (!shown.contains(item)) item,
    ],
  );
}

/// 宽屏右岛的候选按钮：布局的「工具条」区 + 「顶部」区（左右互换在新版里没有
/// 意义，不画），再由 [renders] 去掉当前形态下不渲染的（没有回调等）。
List<LyricsControlItem> lyricsModernWideItems(
  LyricsPlayerData data,
  bool Function(LyricsControlItem item) renders,
) {
  final LyricsControlLayout layout = data.wideControls;
  return <LyricsControlItem>[
    for (final LyricsControlItem item in <LyricsControlItem>[
      ...layout.itemsIn(LyricsControlSlot.toolbar),
      ...layout.itemsIn(LyricsControlSlot.top),
    ])
      if (item != LyricsControlItem.swapSides && renders(item)) item,
  ];
}

// ---------------------------------------------------------------------------
// 读数与每秒轮询
// ---------------------------------------------------------------------------

/// 千分位（读数用；与统计侧栏同口径的 1,234 写法）。
String lyricsGroupedNumber(int n) {
  final String digits = n.abs().toString();
  final StringBuffer out = StringBuffer(n < 0 ? '-' : '');
  for (int i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) out.write(',');
    out.write(digits[i]);
  }
  return out.toString();
}

/// 本次会话阅读时长文案。
String lyricsSessionText(LyricsPlayerStats stats) =>
    formatLyricsPlayerTime(Duration(milliseconds: stats.sessionDurationMs));

/// 阅读速度文案（字 / 小时，千分位）。
String lyricsSpeedText(LyricsPlayerStats stats) =>
    t.reader_stats_chars_per_hour(n: lyricsGroupedNumber(stats.charsPerHour));

/// 剩余时间文案 `-m:ss`。
String lyricsRemainingText(Duration position, Duration total) =>
    '-${formatLyricsPlayerTime(total > position ? total - position : Duration.zero)}';

/// 每秒读一次 [LyricsPlayerClock] 的位置 / 时长，变了才重建这一小块（自带重绘
/// 边界）。播放 / 暂停一样每秒一次：没有逐帧刷新。
class LyricsClockSecondsBuilder extends StatefulWidget {
  const LyricsClockSecondsBuilder({
    required this.clock,
    required this.builder,
    super.key,
  });

  final LyricsPlayerClock clock;
  final Widget Function(BuildContext context, Duration position, Duration total)
  builder;

  @override
  State<LyricsClockSecondsBuilder> createState() =>
      _LyricsClockSecondsBuilderState();
}

class _LyricsClockSecondsBuilderState extends State<LyricsClockSecondsBuilder> {
  late int _second = widget.clock.position.inSeconds;
  late int _total = widget.clock.duration.inSeconds;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _poll());
  }

  @override
  void didUpdateWidget(covariant LyricsClockSecondsBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.clock, widget.clock)) _poll();
  }

  void _poll() {
    if (!mounted) return;
    final int second = widget.clock.position.inSeconds;
    final int total = widget.clock.duration.inSeconds;
    if (second != _second || total != _total) {
      setState(() {
        _second = second;
        _total = total;
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: widget.builder(
      context,
      Duration(seconds: _second),
      Duration(seconds: _total),
    ),
  );
}

/// 每秒读一次 [LyricsPlayerClock.stats]（只读），变了才重建这一小块。
class LyricsStatsBuilder extends StatefulWidget {
  const LyricsStatsBuilder({
    required this.clock,
    required this.builder,
    super.key,
  });

  final LyricsPlayerClock clock;
  final Widget Function(BuildContext context, LyricsPlayerStats stats) builder;

  @override
  State<LyricsStatsBuilder> createState() => _LyricsStatsBuilderState();
}

class _LyricsStatsBuilderState extends State<LyricsStatsBuilder> {
  late LyricsPlayerStats _stats = widget.clock.stats;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _poll());
  }

  @override
  void didUpdateWidget(covariant LyricsStatsBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.clock, widget.clock)) _stats = widget.clock.stats;
  }

  void _poll() {
    if (!mounted) return;
    final LyricsPlayerStats next = widget.clock.stats;
    if (next != _stats) setState(() => _stats = next);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  // 自带重绘边界：读数每秒一变只重录这一小块，不连带播放卡投影与封面。
  @override
  Widget build(BuildContext context) =>
      RepaintBoundary(child: widget.builder(context, _stats));
}

/// 宽屏读数：阅读速度 · 阅读进度 · 阅读时间（只读；每秒刷新）。图标走
/// [FushiIcon]，Apple 设计系统下自动换成同义的 SF 风格字形。
class LyricsModernStatsLine extends StatelessWidget {
  const LyricsModernStatsLine({
    required this.clock,
    required this.style,
    super.key,
  });

  final LyricsPlayerClock clock;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final double iconSize = (style.fontSize ?? 12) + 2;
    Widget stat(IconData icon, String value) => Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        FushiIcon(icon, size: iconSize, color: style.color),
        const SizedBox(width: 4),
        Text(value, maxLines: 1, style: style),
      ],
    );
    return LyricsStatsBuilder(
      clock: clock,
      builder: (BuildContext context, LyricsPlayerStats stats) {
        final double? percent = stats.percent;
        return FittedBox(
          key: const ValueKey<String>('lyrics_modern_stats_line'),
          fit: BoxFit.scaleDown,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              stat(FushiIcons.speed, lyricsSpeedText(stats)),
              if (percent != null) ...<Widget>[
                const SizedBox(width: 16),
                stat(FushiIcons.books, '${percent.toStringAsFixed(1)}%'),
              ],
              const SizedBox(width: 16),
              stat(
                stats.tracking ? FushiIcons.timer : FushiIcons.timerOff,
                lyricsSessionText(stats),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// 进场动效
// ---------------------------------------------------------------------------

/// 进场：spatial 弹簧从下方上移 + effects 淡入（墨水屏 / 减弱动态效果时长归零，
/// 直接落位）。[delay] 是占总时长的比例，做错峰。
class LyricsSpringEntrance extends StatelessWidget {
  const LyricsSpringEntrance({required this.child, this.delay = 0, super.key});

  final Widget child;
  final double delay;

  @override
  Widget build(BuildContext context) {
    final FushiMotionScheme motion = context.fushiMotion;
    final double d = delay.clamp(0.0, 0.6);
    Duration total(Duration base) =>
        base == Duration.zero ? Duration.zero : base * (1 / (1 - d));
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: total(motion.effectsSlow.duration),
      curve: Interval(d, 1, curve: motion.effectsSlow.curve),
      builder: (BuildContext context, double fade, Widget? child) =>
          Opacity(opacity: fade.clamp(0.0, 1.0), child: child),
      child: TweenAnimationBuilder<double>(
        tween: Tween<double>(begin: 0, end: 1),
        duration: total(motion.spatialSlow.duration),
        curve: Interval(d, 1, curve: motion.spatialSlow.curve),
        builder: (BuildContext context, double v, Widget? child) =>
            Transform.translate(offset: Offset(0, 28 * (1 - v)), child: child),
        child: child,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 封面缩略图
// ---------------------------------------------------------------------------

/// 封面 / 插图缩略图：固定高 [height]，宽按图片原比例（夹在 0.5–1.6 倍高之间，
/// 超出的部分按原比例留边、不裁切）。比例变化（封面 ↔ 插图）时宽度按
/// `FushiMotion.short` 过渡。外观参数为 null 时取 MD3 默认（primaryContainer 占位 +
/// 书本图标、small 圆角、overlay 底）。
class LyricsAspectThumb extends StatefulWidget {
  const LyricsAspectThumb({
    required this.image,
    required this.height,
    this.uncropped = false,
    this.borderRadius,
    this.backdrop,
    this.placeholder,
    super.key,
  });

  final ImageProvider? image;
  final double height;

  /// 宽屏左区：按封面原比例完整显示（不夹宽高比、不切圆角）。
  final bool uncropped;

  /// 裁切圆角（[uncropped] 有图时不裁）。null = MD3 small 圆角。
  final BorderRadius? borderRadius;

  /// 图片留边处的底色。null = MD3 overlay 表面色。
  final Color? backdrop;

  /// 无图占位。null = MD3 primaryContainer + 书本图标。
  final WidgetBuilder? placeholder;

  @override
  State<LyricsAspectThumb> createState() => _LyricsAspectThumbState();
}

class _LyricsAspectThumbState extends State<LyricsAspectThumb> {
  double _aspect = 0.72;
  ImageStream? _stream;
  ImageStreamListener? _listener;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolve();
  }

  @override
  void didUpdateWidget(covariant LyricsAspectThumb oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.image != widget.image) _resolve();
  }

  ImageProvider? get _sized {
    final ImageProvider? image = widget.image;
    if (image == null) return null;
    final int cache =
        (widget.height * 1.6 * MediaQuery.devicePixelRatioOf(context)).round();
    return ResizeImage.resizeIfNeeded(cache, null, image);
  }

  void _resolve() {
    final ImageStream? next = _sized?.resolve(
      createLocalImageConfiguration(context),
    );
    if (next != null && next.key == _stream?.key) return;
    _detach();
    if (next == null) return;
    final ImageStreamListener listener = ImageStreamListener((
      ImageInfo info,
      bool _,
    ) {
      final double w = info.image.width.toDouble();
      final double h = info.image.height.toDouble();
      info.dispose();
      if (!mounted || w <= 0 || h <= 0) return;
      final double aspect = w / h;
      if ((aspect - _aspect).abs() > 0.001) setState(() => _aspect = aspect);
    }, onError: (Object error, StackTrace? stack) {});
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

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final double h = widget.height;
    final ImageProvider? image = _sized;
    final double target = image == null
        ? h
        : widget.uncropped
        ? h * _aspect
        : (h * _aspect).clamp(h * 0.5, h * 1.6);
    final WidgetBuilder? placeholder = widget.placeholder;
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(end: target),
      duration: fushiMotionDuration(context, FushiMotion.short),
      curve: FushiMotion.standard,
      builder: (BuildContext context, double width, Widget? child) =>
          SizedBox(width: width, height: h, child: child),
      child: ClipRRect(
        borderRadius: widget.uncropped && image != null
            ? BorderRadius.zero
            : widget.borderRadius ?? FushiM3eShape.smallRadius,
        child: image == null
            ? placeholder != null
                  ? placeholder(context)
                  : ColoredBox(
                      color: cs.primaryContainer,
                      child: Center(
                        child: FushiIcon(
                          FushiIcons.books,
                          size: h * 0.5,
                          color: cs.onPrimaryContainer,
                        ),
                      ),
                    )
            : ColoredBox(
                color:
                    widget.backdrop ??
                    FushiDesignTokens.of(context).surfaces.overlay,
                child: Image(
                  image: image,
                  fit: BoxFit.contain,
                  filterQuality: FilterQuality.medium,
                  gaplessPlayback: true,
                ),
              ),
      ),
    );
  }
}

/// 封面位（兼插图入口）：有新插图时换成插图缩略图 + 红点，点它看大图。外观参数
/// 透传给 [LyricsAspectThumb]。
Widget lyricsModernArtwork(
  LyricsPlayerData data,
  LyricsPlayerCallbacks callbacks, {
  required double height,
  bool uncropped = false,
  BorderRadius? borderRadius,
  Color? backdrop,
  WidgetBuilder? placeholder,
}) => LyricsIllustrationCompactArtwork(
  controller: data.illustrations,
  onOpen: callbacks.onOpenIllustration == null
      ? null
      : (int index) =>
            callbacks.onOpenIllustration!(index, returnToCover: true),
  builder: (BuildContext context, ImageProvider? illustration) =>
      LyricsAspectThumb(
        image: illustration ?? data.cover,
        height: height,
        uncropped: uncropped,
        borderRadius: borderRadius,
        backdrop: backdrop,
        placeholder: placeholder,
      ),
);

// ---------------------------------------------------------------------------
// 窄屏：可收起的播放卡
// ---------------------------------------------------------------------------

/// 窄屏播放卡的几何：收起（迷你条）/ 展开两档高度、卡片横向位置与底边、插图
/// 弹出卡能往上长到哪（[popupTopLimit] = 顶栏底边）。
@immutable
class LyricsModernCardGeometry {
  const LyricsModernCardGeometry({
    required this.miniHeight,
    required this.fullHeight,
    required this.cardLeft,
    required this.cardRight,
    required this.cardBottom,
    required this.popupTopLimit,
  });

  final double miniHeight;
  final double fullHeight;
  final double cardLeft;
  final double cardRight;
  final double cardBottom;

  /// 插图弹出卡顶边不能高过这里（顶栏底边）。
  final double popupTopLimit;

  double get cardWidth => cardRight - cardLeft;

  /// 展开进度 [t]（0 = 收起，1 = 展开；动画途中取中间值）下的卡片高度。
  double heightAt(double t) => miniHeight + (fullHeight - miniHeight) * t;

  /// 卡片顶边（展开进度 [t]）。
  double cardTopAt(double t) => math.max(0, cardBottom - heightAt(t));

  /// 插图弹出卡的最大框：宽取卡宽的 60%，高不超过 320、也不顶到顶栏（顶栏底到
  /// 卡片顶之间再各留 12）。
  Size popupSizeAt(double t) => Size(
    cardWidth * 0.6,
    math.max(0, math.min(320, cardTopAt(t) - popupTopLimit - 24)),
  );
}

/// 窄屏播放卡 + 插图弹出卡：两者随展开进度一起动（卡高 `FushiMotion.medium`，
/// spatial 弹簧；弹出卡底边跟着卡片顶边走）。[card] 一般是
/// [LyricsModernCollapsibleCard]（外面包进场动效）。
class LyricsModernCardHost extends StatelessWidget {
  const LyricsModernCardHost({
    required this.data,
    required this.callbacks,
    required this.size,
    required this.geometry,
    required this.popupBorderRadius,
    required this.card,
    super.key,
  });

  final LyricsPlayerData data;
  final LyricsPlayerCallbacks callbacks;
  final Size size;
  final LyricsModernCardGeometry geometry;

  /// 插图弹出卡圆角（各设计系统自己的卡片圆角）。
  final BorderRadius popupBorderRadius;
  final Widget card;

  @override
  Widget build(BuildContext context) {
    final bool expanded = data.compactControlsExpanded;
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(end: expanded ? 1 : 0),
      duration: fushiMotionDuration(context, FushiMotion.medium),
      curve: FushiSpringCurve.spatial,
      builder: (BuildContext context, double t, Widget? card) {
        final double top = geometry.cardTopAt(t);
        final Size popup = geometry.popupSizeAt(t);
        return Stack(
          clipBehavior: Clip.none,
          children: <Widget>[
            Positioned(
              left: geometry.cardLeft,
              bottom: size.height - top + 12,
              width: popup.width,
              height: popup.height,
              child: LyricsIllustrationPopupCard(
                controller: data.illustrations,
                width: popup.width,
                height: popup.height,
                borderRadius: popupBorderRadius,
                onOpen: callbacks.onOpenIllustration == null
                    ? null
                    : (int index) => callbacks.onOpenIllustration!(
                        index,
                        returnToCover: false,
                      ),
              ),
            ),
            Positioned(
              left: geometry.cardLeft,
              width: geometry.cardWidth,
              top: top,
              height: geometry.heightAt(t),
              child: card!,
            ),
          ],
        );
      },
      child: card,
    );
  }
}

/// 可收起的播放卡（交互与设计系统无关）：点 / 拖顶部把手、在卡片上上滑 → 展开；
/// 点把手或下滑 → 收起。两套内容按 `FushiMotion.short` 交叉淡化，各按自己的自然
/// 高度排（卡高动画途中被裁，不被压扁）。外观由 [surface]（底板 + 裁切）与
/// [handleBuilder]（顶部把手）给出。
class LyricsModernCollapsibleCard extends StatefulWidget {
  const LyricsModernCollapsibleCard({
    required this.expanded,
    required this.onExpandedChanged,
    required this.miniHeight,
    required this.fullHeight,
    required this.handleHeight,
    required this.miniBuilder,
    required this.fullBuilder,
    required this.surface,
    required this.handleBuilder,
    super.key = const ValueKey<String>('lyrics_modern_card'),
  });

  final bool expanded;

  /// 展开 / 收起（写偏好）。null = 卡片固定在当前状态。
  final ValueChanged<bool>? onExpandedChanged;
  final double miniHeight;
  final double fullHeight;

  /// 顶部把手命中区高度（只占内边距那一截）。
  final double handleHeight;

  /// 收起态内容；参数是「展开」动作（章名 / 时间区点按用）。
  final Widget Function(BuildContext context, VoidCallback onExpand)
  miniBuilder;
  final WidgetBuilder fullBuilder;

  /// 卡片底板：把已裁切前的内容栈包进去（负责底色与裁切）。
  final Widget Function(BuildContext context, Widget content) surface;

  /// 顶部把手。
  final Widget Function(
    BuildContext context,
    bool expanded,
    VoidCallback onToggle,
  )
  handleBuilder;

  @override
  State<LyricsModernCollapsibleCard> createState() =>
      _LyricsModernCollapsibleCardState();
}

class _LyricsModernCollapsibleCardState
    extends State<LyricsModernCollapsibleCard> {
  /// 本次竖向拖动累计位移（向上为负）。
  double _dragDy = 0;

  void _set(bool expanded) {
    if (expanded == widget.expanded) return;
    widget.onExpandedChanged?.call(expanded);
  }

  void _onDragEnd(DragEndDetails details) {
    final double v = details.primaryVelocity ?? 0;
    final double dy = _dragDy;
    _dragDy = 0;
    if (v < -200 || dy < -24) {
      _set(true);
    } else if (v > 200 || dy > 24) {
      _set(false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool expanded = widget.expanded;
    final Duration fade = fushiMotionDuration(context, FushiMotion.short);
    final double contentHeight = expanded
        ? widget.fullHeight
        : widget.miniHeight;
    final Widget content = AnimatedSwitcher(
      duration: fade,
      switchInCurve: FushiMotion.enter,
      switchOutCurve: FushiMotion.exit,
      layoutBuilder: (Widget? current, List<Widget> previous) => Stack(
        alignment: Alignment.topCenter,
        clipBehavior: Clip.hardEdge,
        children: <Widget>[...previous, if (current != null) current],
      ),
      child: KeyedSubtree(
        key: ValueKey<bool>(expanded),
        // 内容按自己的自然高度排（卡高动画途中被裁，不被压扁）。
        child: OverflowBox(
          alignment: Alignment.topCenter,
          minHeight: contentHeight,
          maxHeight: contentHeight,
          child: expanded
              ? widget.fullBuilder(context)
              : widget.miniBuilder(context, () => _set(true)),
        ),
      ),
    );
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onVerticalDragStart: (_) => _dragDy = 0,
      onVerticalDragUpdate: (DragUpdateDetails d) => _dragDy += d.delta.dy,
      onVerticalDragEnd: _onDragEnd,
      child: widget.surface(
        context,
        Stack(
          fit: StackFit.expand,
          children: <Widget>[
            content,
            Positioned(
              top: 0,
              height: widget.handleHeight,
              left: 0,
              right: 0,
              child: Center(
                child: widget.handleBuilder(
                  context,
                  expanded,
                  () => _set(!expanded),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
