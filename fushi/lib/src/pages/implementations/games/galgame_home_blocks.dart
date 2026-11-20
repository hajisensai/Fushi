import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/gestures.dart'
    show PointerDeviceKind, PointerEnterEvent;
import 'package:fushi_core/fushi_core.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/media/media_cover_source.dart';
import 'package:fushi/src/mining/galgame_library.dart';
import 'package:fushi/src/pages/implementations/games/galgame_detail_route.dart'
    show galgameCoverFlightShuttle, galgameCoverHeroTag;
import 'package:fushi/src/pages/implementations/games_library_page.dart'
    show galgamePlayStatusLabel, galgamePlayTimeFigure;
import 'package:fushi/src/shortcuts/gamepad_service.dart'
    show GamepadLongPressActions;
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_continue_card_row.dart'
    show coverColorSchemeCache;
import 'package:fushi/src/utils/components/fushi_cover_block.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_fit_title.dart';
import 'package:fushi/src/utils/components/fushi_generated_cover.dart';
import 'package:fushi/src/utils/components/fushi_hover_lift.dart';
import 'package:fushi/src/utils/components/fushi_m3e_feedback.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/components/shelf_card_widgets.dart';
import 'package:fushi/src/utils/cover_image.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

// =============================================================================
// 游戏首页拼贴块（设计稿「游戏 · 首页」`.gb` / `.sb`）。
//
// - 首块 [GalgameHomeHeroBlock]：斜放竖版封面 + 同封面模糊放大背景渐入 + 容器色
//   遮罩 + 时长巨号 + 品牌 / 状态 chip +「平均通关约 n 小时」文字 + 主按钮 / 详情 /
//   捕获工作台。
// - 普通块 [GalgameHomeGameBlock]（继续区、随机推荐）：左上斜放小封面、右上时长 +
//   状态 chip、底部眉标 + 装盒标题。
// - 统计块：[GalgameWeekStatBlock]（本周时长 + 7 日柱）、[GalgameStatusStatBlock]
//   （游玩状态分布）、[GalgameHomeMoreBlock]（「+N · 全部 ›」）、
//   [GalgameTimelineBlock]（时间线）。
// - [GalgameHomeGrid]：按列数把块排成行，行高取本行块需要的最大值（标题按
//   [FushiFitTitle] 二分字号，放不下最小字号时块增高，标题从不截断）。
//
// 块本身只管视觉与命中：点按 / 长按 / 右键 / 焦点由 [shelfCoverCard] 负责，块内
// 的独立按钮（详情、捕获工作台、换一个）是块的兄弟层，不嵌进卡片的焦点节点。
// =============================================================================

/// 被点块的原位信息（详情「从原位放大」的起点）。
///
/// [coverHeroTag] 非 null = 这块的封面挂着同 tag 的 [Hero]（只有首块），详情页
/// 带上它就能把封面当共享元素飞过去。
typedef GalgameBlockOrigin = ({
  BuildContext context,
  Color containerColor,
  double radius,
  String? coverHeroTag,
});

/// 块之间的间距。
const double kGalgameHomeGap = 14;

/// 首块的基准高（标题放得下时）。
const double kGalgameHomeHeroHeight = 300;

/// 普通块的基准高。
const double kGalgameHomeBlockHeight = 214;

/// 随机推荐块的基准高（多一行「换一个」）。
const double kGalgameHomeRandomHeight = 236;

/// 统计块的基准高。
const double kGalgameHomeStatHeight = 214;

// ── 游玩状态色 ──────────────────────────────────────────────────────────────

/// 6 档游玩状态的色点（设计稿第 6 节，深 / 浅两套；chip 底 = 色点 24% 叠在容器
/// 色上，文字用容器 onColor，两套都 ≥4.5:1）。
Color galgamePlayStatusDotColor(GalgamePlayStatus status, Brightness b) {
  final bool dark = b == Brightness.dark;
  return switch (status) {
    GalgamePlayStatus.unset =>
      dark ? const Color(0xFF8F8B96) : const Color(0xFF6B6E7B),
    GalgamePlayStatus.wantToPlay =>
      dark ? const Color(0xFFA9C8FF) : const Color(0xFF2F62C9),
    GalgamePlayStatus.playing =>
      dark ? const Color(0xFF9BE0AB) : const Color(0xFF1D8A45),
    GalgamePlayStatus.played =>
      dark ? const Color(0xFFE7CF6F) : const Color(0xFF8A6A00),
    GalgamePlayStatus.onHold =>
      dark ? const Color(0xFFC9C6CF) : const Color(0xFF5D5A66),
    GalgamePlayStatus.dropped =>
      dark ? const Color(0xFFFF9B9B) : const Color(0xFFB3261E),
  };
}

/// 「游玩状态」块里各档的展示顺序（设计稿：在玩 → 玩过 → 想玩 → 搁置 → 弃坑 →
/// 未设置）。
const List<GalgamePlayStatus> kGalgameHomeStatusOrder = <GalgamePlayStatus>[
  GalgamePlayStatus.playing,
  GalgamePlayStatus.played,
  GalgamePlayStatus.wantToPlay,
  GalgamePlayStatus.onHold,
  GalgamePlayStatus.dropped,
  GalgamePlayStatus.unset,
];

/// 按游玩状态计数（6 档都有键，没有的为 0）。纯函数。
Map<GalgamePlayStatus, int> countGalgamePlayStatuses(
  Iterable<GalgameEntry> games,
) {
  final Map<GalgamePlayStatus, int> counts = <GalgamePlayStatus, int>{
    for (final GalgamePlayStatus s in GalgamePlayStatus.values) s: 0,
  };
  for (final GalgameEntry g in games) {
    counts[g.playStatus] = (counts[g.playStatus] ?? 0) + 1;
  }
  return counts;
}

/// 「平均通关约 n 小时」的 n：10 小时内保留一位小数，往上取整；没有或非正为 null。
String? galgameAverageHoursLabel(double? hours) {
  if (hours == null || hours <= 0 || !hours.isFinite) return null;
  return hours < 10
      ? hours.toStringAsFixed(1).replaceFirst(RegExp(r'\.0$'), '')
      : '${hours.round()}';
}

// ── 封面与取色 ──────────────────────────────────────────────────────────────

/// 游戏封面图源（与游戏库同一条来源链）；没有封面为 null。
ImageProvider? galgameHomeCoverImage(
  GalgameEntry game, {
  int decodeWidth = kLocalCoverDecodePixelWidth,
}) => resolveMediaCoverImage(
  kind: MediaKind.game,
  localPath: game.coverPath,
  decodeWidth: decodeWidth,
);

/// 首页块里的游戏封面：有图画图，没有或解码失败画按标题生成的封面
/// （[FushiGeneratedCover]，首字 + 标题哈希取色）。
class GalgameHomeCover extends StatelessWidget {
  const GalgameHomeCover({
    required this.game,
    this.decodeWidth = kLocalCoverDecodePixelWidth,
    super.key,
  });

  final GalgameEntry game;
  final int decodeWidth;

  @override
  Widget build(BuildContext context) {
    final ImageProvider? provider = galgameHomeCoverImage(
      game,
      decodeWidth: decodeWidth,
    );
    final Widget generated = FushiGeneratedCover(title: game.displayName);
    if (provider == null) return generated;
    return Image(
      image: provider,
      fit: BoxFit.cover,
      excludeFromSemantics: true,
      errorBuilder: (BuildContext context, Object error, StackTrace? stack) =>
          generated,
    );
  }
}

/// 块配色：封面取色（[coverColorSchemeCache]，与库页色块同一份缓存）派生
/// [FushiCoverBlockColors]；没封面按标题哈希色相（与生成封面同色）；墨水屏中性色。
class GalgameBlockPalette extends StatefulWidget {
  const GalgameBlockPalette({
    required this.title,
    required this.image,
    required this.builder,
    super.key,
  });

  final String title;
  final ImageProvider? image;
  final Widget Function(BuildContext context, FushiCoverBlockColors colors)
  builder;

  @override
  State<GalgameBlockPalette> createState() => _GalgameBlockPaletteState();
}

class _GalgameBlockPaletteState extends State<GalgameBlockPalette> {
  ColorScheme? _scheme;
  ImageProvider? _for;
  Brightness? _brightness;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolve();
  }

  @override
  void didUpdateWidget(GalgameBlockPalette oldWidget) {
    super.didUpdateWidget(oldWidget);
    _resolve();
  }

  void _resolve() {
    final ImageProvider? image = isEinkTheme(context) ? null : widget.image;
    final Brightness brightness = Theme.of(context).brightness;
    if (image == _for && brightness == _brightness) return;
    _for = image;
    _brightness = brightness;
    if (image == null) {
      _scheme = null;
      return;
    }
    _scheme = coverColorSchemeCache.peek(image, brightness);
    if (_scheme != null) return;
    coverColorSchemeCache.resolve(image, brightness).then((ColorScheme? s) {
      if (!mounted || _for != image || _brightness != brightness) return;
      setState(() => _scheme = s);
    });
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final FushiCoverBlockColors colors =
        _scheme == null && widget.image == null && !isEinkTheme(context)
        ? FushiCoverBlockColors.fromHue(
            theme,
            fushiGeneratedCoverHue(widget.title),
          )
        : FushiCoverBlockColors.resolve(theme, _scheme);
    return widget.builder(context, colors);
  }
}

// ── 装盒标题的高度 ──────────────────────────────────────────────────────────

/// 标题盒要多高：[preferred] 高下 [minSize] 放得下就是 [preferred]；放不下时取
/// 最小字号整段排完的高度（块随之增高，标题从不截断，设计稿 GA18）。
double galgameFitTitleHeight({
  required TextStyle base,
  required String text,
  required double width,
  required double preferred,
  required double minSize,
  required double maxSize,
  required TextDirection direction,
}) {
  if (width <= 0 || text.trim().isEmpty) return preferred;
  final TextStyle probe = fushiFitTitleStyle(
    base,
    fontSize: minSize,
    color: const Color(0xFF000000),
  );
  final double? size = fushiFitTitleFontSize(
    text: text,
    style: probe,
    box: Size(width, math.max(1, preferred)),
    minSize: minSize,
    maxSize: maxSize,
    direction: direction,
  );
  if (size != null) return preferred;
  final TextPainter painter = TextPainter(
    text: TextSpan(text: text, style: probe),
    textDirection: direction,
    textScaler: TextScaler.noScaling,
  )..layout(maxWidth: width);
  final double needed = painter.height.ceilToDouble() + 1;
  painter.dispose();
  return math.max(preferred, needed);
}

// ── 小件：chip ──────────────────────────────────────────────────────────────

/// 块内的普通 chip（品牌等）：onContainer 15% 底。
class GalgameBlockChip extends StatelessWidget {
  const GalgameBlockChip({
    required this.label,
    required this.colors,
    this.leading,
    this.filled = false,
    super.key,
  });

  final String label;
  final FushiCoverBlockColors colors;
  final Widget? leading;

  /// true = 强调色底（「游戏中」）。
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final Color bg = filled
        ? colors.accent
        : colors.onContainer.withValues(alpha: 0.15);
    final Color fg = filled ? colors.container : colors.onContainer;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: ShapeDecoration(color: bg, shape: const StadiumBorder()),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (leading != null) ...<Widget>[leading!, const SizedBox(width: 5)],
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.fushiType.labelSmallEmphasized.copyWith(color: fg),
            ),
          ),
        ],
      ),
    );
  }
}

/// 游玩状态 chip：方形色点 + 状态文案，底 = 色点 24% 叠在容器色上。
class GalgameStatusChip extends StatelessWidget {
  const GalgameStatusChip({
    required this.status,
    required this.colors,
    super.key,
  });

  final GalgamePlayStatus status;
  final FushiCoverBlockColors colors;

  @override
  Widget build(BuildContext context) {
    final Color dot = galgamePlayStatusDotColor(
      status,
      Theme.of(context).brightness,
    );
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: ShapeDecoration(
        color: Color.alphaBlend(dot.withValues(alpha: 0.24), colors.container),
        shape: const StadiumBorder(),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              color: dot,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              galgamePlayStatusLabel(status),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.fushiType.labelSmallEmphasized.copyWith(
                color: colors.onContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 「游戏中」chip 的呼吸圆点（减弱动效时静止）。
class _LiveDot extends StatefulWidget {
  const _LiveDot({required this.color});

  final Color color;

  @override
  State<_LiveDot> createState() => _LiveDotState();
}

class _LiveDotState extends State<_LiveDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: FushiMotion.ambientBreathBusy,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (fushiMotionEnabled(context)) {
      if (!_c.isAnimating) _c.repeat(reverse: true);
    } else {
      _c
        ..stop()
        ..value = 1;
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween<double>(begin: 0.35, end: 1).animate(_c),
      child: Container(
        width: 6,
        height: 6,
        decoration: BoxDecoration(color: widget.color, shape: BoxShape.circle),
      ),
    );
  }
}

/// 时长巨号（数值 + 小号单位，强调色）。读屏不单独读（块的语义标签里已有）。
class GalgameHoursFigure extends StatelessWidget {
  const GalgameHoursFigure({
    required this.figure,
    required this.color,
    this.fontSize = 44,
    super.key,
  });

  final FushiCoverBlockFigure figure;
  final Color color;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final TextStyle base = DefaultTextStyle.of(context).style;
    return ExcludeSemantics(
      child: Text.rich(
        TextSpan(
          children: <InlineSpan>[
            TextSpan(
              text: figure.value,
              style: base.copyWith(
                fontSize: fontSize,
                fontWeight: FontWeight.w900,
                letterSpacing: -0.05 * fontSize,
                height: 0.9,
                color: color,
              ),
            ),
            TextSpan(
              text: ' ${figure.unit}',
              style: base.copyWith(
                fontSize: context.fushiType.labelMedium.fontSize,
                fontWeight: FontWeight.w700,
                color: color.withValues(alpha: 0.9),
              ),
            ),
          ],
        ),
        maxLines: 1,
        textScaler: TextScaler.noScaling,
      ),
    );
  }
}

// ── 块的交互外壳 ────────────────────────────────────────────────────────────

/// 悬停 / 焦点姿态（0 静止、1 悬停或聚焦，弹簧可过冲）+ 抬升。手柄 / 键盘焦点与
/// 鼠标悬停同一姿态（设计稿第 7 节）；减弱动效下姿态不动（封面固定 -7°）。
class _BlockPose extends StatefulWidget {
  const _BlockPose({required this.builder});

  final Widget Function(
    BuildContext context,
    bool active,
    Animation<double> pose,
  )
  builder;

  @override
  State<_BlockPose> createState() => _BlockPoseState();
}

class _BlockPoseState extends State<_BlockPose>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pose = AnimationController.unbounded(
    vsync: this,
  );
  bool _hovered = false;
  bool _focused = false;

  bool get _active => _hovered || _focused;

  void _update({bool? hovered, bool? focused}) {
    final bool before = _active;
    _hovered = hovered ?? _hovered;
    _focused = focused ?? _focused;
    if (before == _active) return;
    if (fushiMotionEnabled(context)) {
      _pose.fushiSpringTo(
        _active ? 1 : 0,
        _active ? kFushiCoverBlockHoverSpring : kFushiCoverBlockRestSpring,
      );
    }
    setState(() {});
  }

  @override
  void dispose() {
    _pose.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: (bool f) => _update(focused: f),
      child: MouseRegion(
        opaque: false,
        onEnter: (PointerEnterEvent e) {
          if (e.kind == PointerDeviceKind.mouse) _update(hovered: true);
        },
        onExit: (_) => _update(hovered: false),
        child: FushiHoverLift(
          forceLifted: _focused,
          builder: (BuildContext context, bool _) =>
              widget.builder(context, _active, _pose),
        ),
      ),
    );
  }
}

/// 斜放封面：静止 -7°、悬停 / 聚焦 -2° 并上抬、放大 3%（RTL 镜像角度）。
class _TiltedArt extends StatelessWidget {
  const _TiltedArt({
    required this.pose,
    required this.radius,
    required this.child,
  });

  final Animation<double> pose;
  final double radius;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final double dir = Directionality.of(context) == TextDirection.rtl ? -1 : 1;
    final Widget art = ExcludeSemantics(
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          boxShadow: const <BoxShadow>[
            BoxShadow(
              color: Color(0x80000000),
              offset: Offset(0, 12),
              blurRadius: 26,
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(radius),
          child: child,
        ),
      ),
    );
    return AnimatedBuilder(
      animation: pose,
      child: art,
      builder: (BuildContext context, Widget? child) {
        final double p = pose.value;
        final double degrees = -7 + 5 * p;
        return Transform.translate(
          offset: Offset(dir * 4 * (1 - p), 2 - 6 * p),
          child: Transform.rotate(
            angle: dir * degrees * math.pi / 180,
            child: Transform.scale(scale: 1 + 0.03 * p, child: child),
          ),
        );
      },
    );
  }
}

/// 同封面的模糊放大背景。[always] = 首块常驻一层（进场时渐入：透明度 0 → 0.4、
/// 缩放 1.15 → 1）；否则只在 [active]（悬停 / 聚焦）时渐入 0.28。减弱动效：首块
/// 静态显示，普通块不渐入。同一时刻最多首块 + 一块悬停块两层 blur。
class _BlurBackdrop extends StatelessWidget {
  const _BlurBackdrop({
    required this.image,
    required this.always,
    required this.active,
  });

  final ImageProvider image;
  final bool always;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final bool motion = fushiMotionEnabled(context);
    if (!always && !motion) return const SizedBox.shrink();
    final double target = always ? 0.4 : (active ? 0.28 : 0);
    final Duration duration = fushiMotionDuration(context, FushiMotion.long);
    return IgnorePointer(
      child: ExcludeSemantics(
        child: TweenAnimationBuilder<double>(
          tween: Tween<double>(
            begin: always && motion ? 0 : target,
            end: target,
          ),
          duration: duration,
          curve: FushiMotion.standard,
          builder: (BuildContext context, double v, Widget? child) {
            if (v <= 0.001) return const SizedBox.shrink();
            final double progress = target <= 0 ? 0 : (v / target);
            return Opacity(
              opacity: v.clamp(0.0, 1.0),
              child: Transform.scale(
                scale: 1.15 - 0.15 * progress.clamp(0.0, 1.0),
                child: child,
              ),
            );
          },
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints c) {
              final double dx = c.maxWidth * 0.2;
              final double dy = c.maxHeight * 0.2;
              return OverflowBox(
                maxWidth: c.maxWidth + dx * 2,
                maxHeight: c.maxHeight + dy * 2,
                child: ImageFiltered(
                  imageFilter: ImageFilter.blur(sigmaX: 26, sigmaY: 26),
                  child: Image(
                    image: image,
                    fit: BoxFit.cover,
                    width: c.maxWidth + dx * 2,
                    height: c.maxHeight + dy * 2,
                    excludeFromSemantics: true,
                    errorBuilder:
                        (BuildContext _, Object __, StackTrace? ___) =>
                            const SizedBox.shrink(),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// 块内的独立药丸按钮（首块的主按钮 / 详情 / 捕获工作台，随机推荐的「换一个」）：
/// 视觉 [height] 高，命中区外扩到 ≥48dp；自带焦点站点与按压回弹（[FushiCard]）。
class GalgameBlockButton extends StatelessWidget {
  const GalgameBlockButton({
    required this.label,
    required this.onPressed,
    required this.colors,
    required this.focusId,
    this.icon,
    this.trailingIcon,
    this.primary = false,
    this.height = 40,
    super.key,
  });

  final String label;
  final VoidCallback onPressed;
  final FushiCoverBlockColors colors;
  final FushiFocusId focusId;
  final IconData? icon;
  final IconData? trailingIcon;

  /// true = 强调色实底（主按钮）；false = onContainer 16% 淡底。
  final bool primary;
  final double height;

  @override
  Widget build(BuildContext context) {
    final Color bg = primary
        ? colors.accent
        : colors.onContainer.withValues(alpha: 0.16);
    final Color fg = primary ? colors.container : colors.onContainer;
    final TextStyle style = context.fushiType.labelLargeEmphasized.copyWith(
      color: fg,
    );
    final double outset = math.max(0, (kMinInteractiveDimension - height) / 2);
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: outset),
        child: FushiCard(
          focusId: focusId,
          onTap: onPressed,
          color: bg,
          borderColor: Colors.transparent,
          shape: const StadiumBorder(),
          padding: EdgeInsets.symmetric(horizontal: primary ? 18 : 14),
          child: SizedBox(
            height: height,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (icon != null) ...<Widget>[
                  FushiIcon(icon!, size: 18, color: fg),
                  const SizedBox(width: 6),
                ],
                Text(label, maxLines: 1, style: style),
                if (trailingIcon != null) ...<Widget>[
                  const SizedBox(width: 4),
                  FushiIcon(trailingIcon!, size: 16, color: fg),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 块的卡片外壳：色块底 + 投影 + 裁剪，命中 / 焦点 / 长按 / 右键交给
/// [shelfCoverCard]；手柄长按 A 也出菜单（[GamepadLongPressActions]）。
Widget _blockCard({
  required BuildContext context,
  required FushiCoverBlockSize size,
  required double height,
  required FushiCoverBlockColors colors,
  required FushiFocusId focusId,
  required VoidCallback onTap,
  required VoidCallback? onLongPress,
  required VoidCallback? onSecondaryTap,
  required String semanticLabel,
  required Widget child,
}) {
  final OutlinedBorder shape = fushiCoverBlockShape(context, size);
  final double radius = fushiCoverBlockRadius(size, height);
  final Widget visual = DecoratedBox(
    decoration: ShapeDecoration(
      color: colors.container,
      shape: shape,
      shadows: fushiCoverBlockShadows(size),
    ),
    child: ClipPath(
      clipper: ShapeBorderClipper(shape: shape),
      child: child,
    ),
  );
  return GamepadLongPressActions(
    onLongPress: onLongPress,
    child: MergeSemantics(
      child: Semantics(
        button: true,
        label: semanticLabel,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: shelfCoverCard(
            focusId: focusId,
            shape: shape,
            borderRadius: BorderRadius.circular(radius),
            onTap: onTap,
            onLongPress: onLongPress,
            onSecondaryTap: onSecondaryTap,
            child: visual,
          ),
        ),
      ),
    ),
  );
}

// ── 首块 ────────────────────────────────────────────────────────────────────

/// 首块的几何（布局与行高计算共用一份，二者永不分叉）。
@immutable
class GalgameHeroMetrics {
  const GalgameHeroMetrics({
    required this.artStart,
    required this.artWidth,
    required this.artHeight,
    required this.textStart,
    required this.titleWidth,
    required this.titleHeight,
    required this.height,
  });

  /// 按块宽 [width] 与内容算几何。
  factory GalgameHeroMetrics.compute({
    required TextStyle base,
    required TextDirection direction,
    required double width,
    required String title,
    required bool hasHours,
    required bool hasAverage,
  }) {
    const double artStart = 22;
    final double artWidth = math.min(150, math.max(72, width * 0.3));
    final double artHeight = artWidth * 1.5;
    final double textStart = artStart + artWidth + 24;
    final double titleWidth = math.max(40, width - textStart - 18);
    final double fixed =
        _kHeroPadTop +
        24 + // chips
        _kHeroGap +
        _kHeroGap +
        18 + // meta
        (hasHours ? _kHeroGap + 52 : 0) +
        (hasAverage ? _kHeroGap + 18 : 0) +
        _kHeroGap +
        kMinInteractiveDimension + // 按钮行（命中区）
        _kHeroPadBottom;
    final double minHeight = math.max(
      kGalgameHomeHeroHeight,
      artHeight + 2 * _kHeroArtTop,
    );
    final double preferredTitle = math.max(40, minHeight - fixed);
    final double titleHeight = galgameFitTitleHeight(
      base: base,
      text: title,
      width: titleWidth,
      preferred: preferredTitle,
      minSize: 18,
      maxSize: 34,
      direction: direction,
    );
    return GalgameHeroMetrics(
      artStart: artStart,
      artWidth: artWidth,
      artHeight: artHeight,
      textStart: textStart,
      titleWidth: titleWidth,
      titleHeight: titleHeight,
      height: math.max(minHeight, fixed + titleHeight),
    );
  }

  final double artStart;
  final double artWidth;
  final double artHeight;
  final double textStart;
  final double titleWidth;
  final double titleHeight;
  final double height;

  /// 按钮行在块高 [blockHeight] 下的起始边距：斜放封面（含 -7° 旋转外扩的
  /// [_kHeroArtTiltBleed]）底边在按钮行之上时，按钮行从封面起始边排起（窄屏
  /// 下文字列太窄，三个按钮挤在文字列里会被缩到命中区不足 48dp）；否则与文字列
  /// 对齐（桌面宽块，按设计稿版位）。
  double buttonStartFor(double blockHeight) {
    final double artBottom = _kHeroArtTop + artHeight + _kHeroArtTiltBleed;
    final double buttonsTop =
        blockHeight - _kHeroPadBottom - kMinInteractiveDimension;
    return artBottom <= buttonsTop ? artStart : textStart;
  }
}

/// 首块斜放封面距块顶。
const double _kHeroArtTop = 30;

/// 封面 -7° 旋转 + 静止位移后底边外扩的余量。
const double _kHeroArtTiltBleed = 16;

const double _kHeroPadTop = 16;
const double _kHeroPadBottom = 10;
const double _kHeroGap = 6;

/// 首块：有运行中的条目取它，否则取最后游玩（选择在页面里做）。
///
/// 点按块 = [onLaunch]（运行中只换主按钮文案为「继续游戏」）；长按 / 右键 =
/// [onMenu]（与游戏库同一份菜单）；「详情」按钮 = [onDetail]（从原位放大）；
/// [onWorkbench] 非 null（本机有 Hook 会话）时多一个「捕获工作台 ›」。
class GalgameHomeHeroBlock extends StatelessWidget {
  const GalgameHomeHeroBlock({
    required this.game,
    required this.running,
    required this.lastPlayedLabel,
    required this.onLaunch,
    required this.onDetail,
    required this.onMenu,
    this.onWorkbench,
    super.key,
  });

  final GalgameEntry game;

  /// 本机正在跑这个游戏（Hook 会话的 exe 是它）。
  final bool running;

  /// 「最后游玩 …」整行（null = 从未游玩，不画）。
  final String? lastPlayedLabel;
  final VoidCallback onLaunch;
  final ValueChanged<GalgameBlockOrigin> onDetail;
  final ValueChanged<GalgameBlockOrigin> onMenu;
  final VoidCallback? onWorkbench;

  /// 块在宽 [width] 下需要的高度。
  static double heightFor(
    BuildContext context,
    GalgameEntry game,
    double width,
  ) => GalgameHeroMetrics.compute(
    base: DefaultTextStyle.of(context).style,
    direction: Directionality.of(context),
    width: width,
    title: game.displayName,
    hasHours: galgamePlayTimeFigure(game.totalPlaySeconds) != null,
    hasAverage: galgameAverageHoursLabel(game.metadata.averageHours) != null,
  ).height;

  String _semanticLabel(FushiCoverBlockFigure? figure) => <String>[
    game.displayName,
    if (figure != null) '${figure.value} ${figure.unit}',
    galgamePlayStatusLabel(game.playStatus),
  ].join(', ');

  @override
  Widget build(BuildContext context) {
    final ImageProvider? image = galgameHomeCoverImage(game);
    final FushiCoverBlockFigure? figure = galgamePlayTimeFigure(
      game.totalPlaySeconds,
    );
    final String? average = galgameAverageHoursLabel(
      game.metadata.averageHours,
    );
    final String? developer = game.developer?.trim().isEmpty ?? true
        ? null
        : game.developer!.trim();
    return GalgameBlockPalette(
      title: game.displayName,
      image: image,
      builder: (BuildContext context, FushiCoverBlockColors colors) {
        return LayoutBuilder(
          builder: (BuildContext context, BoxConstraints c) {
            final GalgameHeroMetrics m = GalgameHeroMetrics.compute(
              base: DefaultTextStyle.of(context).style,
              direction: Directionality.of(context),
              width: c.maxWidth,
              title: game.displayName,
              hasHours: figure != null,
              hasAverage: average != null,
            );
            final double height = c.maxHeight.isFinite ? c.maxHeight : m.height;
            final double radius = fushiCoverBlockRadius(
              FushiCoverBlockSize.hero,
              height,
            );
            return Builder(
              builder: (BuildContext originContext) {
                GalgameBlockOrigin origin() => (
                  context: originContext,
                  containerColor: colors.container,
                  radius: radius,
                  coverHeroTag: galgameCoverHeroTag(game.id),
                );
                return _BlockPose(
                  builder:
                      (
                        BuildContext context,
                        bool active,
                        Animation<double> pose,
                      ) {
                        final Widget card = _blockCard(
                          context: context,
                          size: FushiCoverBlockSize.hero,
                          height: height,
                          colors: colors,
                          focusId: FushiFocusId(
                            'game-dashboard-hero-${game.id}',
                          ),
                          onTap: onLaunch,
                          onLongPress: () => onMenu(origin()),
                          onSecondaryTap: () => onMenu(origin()),
                          semanticLabel: _semanticLabel(figure),
                          child: _heroBody(
                            context,
                            colors,
                            m,
                            pose,
                            image,
                            figure,
                            average,
                            developer,
                          ),
                        );
                        return Stack(
                          children: <Widget>[
                            Positioned.fill(child: card),
                            PositionedDirectional(
                              start: m.buttonStartFor(height),
                              end: 18,
                              bottom: _kHeroPadBottom,
                              height: kMinInteractiveDimension,
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                alignment: AlignmentDirectional.centerStart,
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: <Widget>[
                                    GalgameBlockButton(
                                      primary: true,
                                      icon: FushiIcons.play,
                                      label: running
                                          ? t.game_focus_continue
                                          : t.game_launch,
                                      colors: colors,
                                      focusId: FushiFocusId(
                                        'game-dashboard-hero-launch-${game.id}',
                                      ),
                                      onPressed: onLaunch,
                                    ),
                                    const SizedBox(width: 8),
                                    GalgameBlockButton(
                                      label: t.game_view_detail,
                                      colors: colors,
                                      focusId: FushiFocusId(
                                        'game-dashboard-hero-detail-${game.id}',
                                      ),
                                      onPressed: () => onDetail(origin()),
                                    ),
                                    if (onWorkbench != null) ...<Widget>[
                                      const SizedBox(width: 8),
                                      GalgameBlockButton(
                                        label: t.game_capture_workbench,
                                        trailingIcon: FushiIcons.chevronRight,
                                        colors: colors,
                                        focusId: const FushiFocusId(
                                          'game-dashboard-hero-workbench',
                                        ),
                                        onPressed: onWorkbench!,
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            ),
                          ],
                        );
                      },
                );
              },
            );
          },
        );
      },
    );
  }

  Widget _heroBody(
    BuildContext context,
    FushiCoverBlockColors colors,
    GalgameHeroMetrics m,
    Animation<double> pose,
    ImageProvider? image,
    FushiCoverBlockFigure? figure,
    String? average,
    String? developer,
  ) {
    final TextDirection dir = Directionality.of(context);
    final FushiTypography type = context.fushiType;
    final TextStyle meta = type.bodySmall.copyWith(
      color: colors.onContainer.withValues(alpha: 0.82),
    );
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        // nsfw 封面不画放大模糊背景（GA14 / GA20）。
        if (image != null && !game.isNsfw && !isEinkTheme(context))
          _BlurBackdrop(image: image, always: true, active: true),
        // 容器色遮罩：起始侧 25% → 52% 处 94%。
        IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: AlignmentDirectional.centerStart.resolve(dir),
                end: AlignmentDirectional.centerEnd.resolve(dir),
                stops: const <double>[0, 0.52],
                colors: <Color>[
                  colors.container.withValues(alpha: 0.25),
                  colors.container.withValues(alpha: 0.94),
                ],
              ),
            ),
          ),
        ),
        PositionedDirectional(
          start: m.artStart,
          top: _kHeroArtTop,
          width: m.artWidth,
          height: m.artHeight,
          // 封面是首块 → 详情的共享元素（GA24）：Hero 包在斜放姿态外层，飞行
          // 起点是封面未旋转的布局框，角度由替身从 -7° 插值到 0°。
          child: Hero(
            tag: galgameCoverHeroTag(game.id),
            flightShuttleBuilder: galgameCoverFlightShuttle,
            child: _TiltedArt(
              pose: pose,
              radius: 14,
              child: GalgameHomeCover(game: game),
            ),
          ),
        ),
        PositionedDirectional(
          start: m.textStart,
          end: 18,
          top: _kHeroPadTop,
          bottom: _kHeroPadBottom + kMinInteractiveDimension + _kHeroGap,
          child: ExcludeSemantics(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                SizedBox(
                  height: 24,
                  child: Row(
                    children: <Widget>[
                      // 三个 chip 都可收缩（文案省略号），窄屏不溢出。
                      if (running) ...<Widget>[
                        Flexible(
                          child: GalgameBlockChip(
                            label: t.game_home_live_chip,
                            colors: colors,
                            filled: true,
                            leading: _LiveDot(color: colors.container),
                          ),
                        ),
                        const SizedBox(width: 5),
                      ],
                      if (developer != null) ...<Widget>[
                        Flexible(
                          child: GalgameBlockChip(
                            label: developer,
                            colors: colors,
                          ),
                        ),
                        const SizedBox(width: 5),
                      ],
                      Flexible(
                        child: GalgameStatusChip(
                          status: game.playStatus,
                          colors: colors,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: _kHeroGap),
                Expanded(
                  child: SizedBox(
                    width: double.infinity,
                    child: FushiFitTitle(
                      text: game.displayName,
                      color: colors.onContainer,
                      maxSize: 34,
                      minSize: 18,
                      align: FushiFitTitleAlign.top,
                    ),
                  ),
                ),
                const SizedBox(height: _kHeroGap),
                SizedBox(
                  height: 18,
                  child: Text(
                    lastPlayedLabel ?? t.game_never_played,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: meta,
                  ),
                ),
                if (figure != null) ...<Widget>[
                  const SizedBox(height: _kHeroGap),
                  SizedBox(
                    height: 52,
                    child: Align(
                      alignment: AlignmentDirectional.bottomStart,
                      child: GalgameHoursFigure(
                        figure: figure,
                        color: colors.accent,
                        fontSize: context.fushiType.displayLarge.fontSize ?? 57,
                      ),
                    ),
                  ),
                ],
                if (average != null) ...<Widget>[
                  const SizedBox(height: _kHeroGap),
                  SizedBox(
                    height: 18,
                    child: Text(
                      t.game_home_average_hours(hours: average),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: meta,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// ── 普通块（继续区 / 随机推荐）──────────────────────────────────────────────

const double _kStackArtTop = 14;
const double _kStackArtWidth = 58;
const double _kStackArtHeight = 87;
const double _kStackPad = 14;
const double _kStackEyebrow = 16;

/// 普通块：左上斜放小封面，右上时长巨号 + 状态 chip，底部眉标 + 装盒标题
/// （22 → 13 二分，不截断）。[topEndAction] 是右上 chip 下方的独立按钮（随机
/// 推荐的「换一个」），是块的兄弟层。
class GalgameHomeGameBlock extends StatelessWidget {
  const GalgameHomeGameBlock({
    required this.game,
    required this.focusId,
    required this.eyebrow,
    required this.onTap,
    required this.onLongPress,
    required this.onSecondaryTap,
    this.showHours = true,
    this.topEndAction,
    this.semanticPrefix,
    super.key,
  });

  final GalgameEntry game;
  final FushiFocusId focusId;
  final String? eyebrow;
  final VoidCallback onTap;
  final ValueChanged<GalgameBlockOrigin> onLongPress;
  final ValueChanged<GalgameBlockOrigin> onSecondaryTap;
  final bool showHours;
  final Widget Function(FushiCoverBlockColors colors)? topEndAction;

  /// 语义标签的前缀（随机推荐的「今天玩这个？」）。
  final String? semanticPrefix;

  /// 标题区顶端（有 [topEndAction] 时让出一行）。
  double get _titleTop => topEndAction == null ? 110 : 112;

  /// 块在宽 [width] 下需要的高度（[preferred] 是基准高）。
  static double heightFor(
    BuildContext context,
    GalgameEntry game,
    double width, {
    double preferred = kGalgameHomeBlockHeight,
    bool withAction = false,
  }) {
    final double top = withAction ? 112 : 110;
    final double fixed = top + _kStackEyebrow + 4 + 12;
    final double title = galgameFitTitleHeight(
      base: DefaultTextStyle.of(context).style,
      text: game.displayName,
      width: math.max(40, width - _kStackPad * 2),
      preferred: math.max(36, preferred - fixed),
      minSize: 13,
      maxSize: 22,
      direction: Directionality.of(context),
    );
    return math.max(preferred, fixed + title);
  }

  @override
  Widget build(BuildContext context) {
    final ImageProvider? image = galgameHomeCoverImage(
      game,
      decodeWidth: kActivityCoverDecodePixelWidth * 2,
    );
    final FushiCoverBlockFigure? figure = showHours
        ? galgamePlayTimeFigure(game.totalPlaySeconds)
        : null;
    final String semanticLabel = <String>[
      if (semanticPrefix != null) semanticPrefix!,
      game.displayName,
      if (figure != null) '${figure.value} ${figure.unit}',
      galgamePlayStatusLabel(game.playStatus),
    ].join(', ');
    return GalgameBlockPalette(
      title: game.displayName,
      image: image,
      builder: (BuildContext context, FushiCoverBlockColors colors) {
        return LayoutBuilder(
          builder: (BuildContext context, BoxConstraints c) {
            final double height = c.maxHeight.isFinite
                ? c.maxHeight
                : kGalgameHomeBlockHeight;
            final double radius = fushiCoverBlockRadius(
              FushiCoverBlockSize.regular,
              height,
            );
            return Builder(
              builder: (BuildContext originContext) {
                GalgameBlockOrigin origin() => (
                  context: originContext,
                  containerColor: colors.container,
                  radius: radius,
                  coverHeroTag: null,
                );
                return _BlockPose(
                  builder:
                      (
                        BuildContext context,
                        bool active,
                        Animation<double> pose,
                      ) {
                        final Widget card = _blockCard(
                          context: context,
                          size: FushiCoverBlockSize.regular,
                          height: height,
                          colors: colors,
                          focusId: focusId,
                          onTap: onTap,
                          onLongPress: () => onLongPress(origin()),
                          onSecondaryTap: () => onSecondaryTap(origin()),
                          semanticLabel: semanticLabel,
                          child: _body(
                            context,
                            colors,
                            image,
                            figure,
                            active,
                            pose,
                          ),
                        );
                        final Widget? action = topEndAction?.call(colors);
                        if (action == null) return card;
                        return Stack(
                          children: <Widget>[
                            Positioned.fill(child: card),
                            PositionedDirectional(
                              end: _kStackPad - 4,
                              top: figure == null ? 36 : 86,
                              child: action,
                            ),
                          ],
                        );
                      },
                );
              },
            );
          },
        );
      },
    );
  }

  Widget _body(
    BuildContext context,
    FushiCoverBlockColors colors,
    ImageProvider? image,
    FushiCoverBlockFigure? figure,
    bool active,
    Animation<double> pose,
  ) {
    final FushiTypography type = context.fushiType;
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        if (image != null && !game.isNsfw && !isEinkTheme(context))
          _BlurBackdrop(image: image, always: false, active: active),
        PositionedDirectional(
          start: _kStackPad,
          top: _kStackArtTop,
          width: _kStackArtWidth,
          height: _kStackArtHeight,
          child: _TiltedArt(
            pose: pose,
            radius: 10,
            child: GalgameHomeCover(
              game: game,
              decodeWidth: kActivityCoverDecodePixelWidth,
            ),
          ),
        ),
        PositionedDirectional(
          end: _kStackPad,
          top: 12,
          start: _kStackPad + _kStackArtWidth + 16,
          child: ExcludeSemantics(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: <Widget>[
                if (figure != null)
                  GalgameHoursFigure(figure: figure, color: colors.accent),
                if (figure != null) const SizedBox(height: 6),
                GalgameStatusChip(status: game.playStatus, colors: colors),
              ],
            ),
          ),
        ),
        PositionedDirectional(
          start: _kStackPad,
          end: _kStackPad,
          top: _titleTop,
          bottom: 12,
          child: ExcludeSemantics(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                SizedBox(
                  height: _kStackEyebrow,
                  child: eyebrow == null
                      ? null
                      : Text(
                          eyebrow!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: type.labelSmallEmphasized.copyWith(
                            color: colors.onContainer.withValues(alpha: 0.82),
                          ),
                        ),
                ),
                const SizedBox(height: 4),
                Expanded(
                  child: SizedBox(
                    width: double.infinity,
                    child: FushiFitTitle(
                      text: game.displayName,
                      color: colors.onContainer,
                      maxSize: 22,
                      minSize: 13,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// ── 统计块 ──────────────────────────────────────────────────────────────────

/// 统计块的底色与文字色（深色 ≈ 稿 #24231f / 浅色 ≈ #eceef6）。
({Color container, Color onContainer, Color muted}) _statColors(
  BuildContext context,
) {
  final ColorScheme cs = Theme.of(context).colorScheme;
  return (
    container: cs.surfaceContainerHigh,
    onContainer: cs.onSurface,
    muted: cs.onSurfaceVariant,
  );
}

/// 统计块外壳（不可点的块用；可点的块走 [FushiCard]）。
class _StatShell extends StatelessWidget {
  const _StatShell({required this.child, this.onTap, this.focusId});

  final Widget child;
  final VoidCallback? onTap;
  final FushiFocusId? focusId;

  @override
  Widget build(BuildContext context) {
    final OutlinedBorder shape = fushiCoverBlockShape(
      context,
      FushiCoverBlockSize.regular,
    );
    final Color bg = _statColors(context).container;
    const EdgeInsets padding = EdgeInsets.fromLTRB(16, 14, 16, 14);
    if (onTap == null) {
      return DecoratedBox(
        decoration: ShapeDecoration(color: bg, shape: shape),
        child: ClipPath(
          clipper: ShapeBorderClipper(shape: shape),
          child: Padding(padding: padding, child: child),
        ),
      );
    }
    return FushiHoverLift(
      builder: (BuildContext context, bool _) => FushiCard(
        focusId: focusId,
        onTap: onTap,
        color: bg,
        borderColor: Colors.transparent,
        shape: shape,
        padding: padding,
        child: child,
      ),
    );
  }
}

/// 统计块的大数值（「9.8 小时」「42 部」）。
class _StatValue extends StatelessWidget {
  const _StatValue({required this.value, required this.unit, this.size = 38});

  final String value;
  final String unit;
  final double size;

  @override
  Widget build(BuildContext context) {
    final ({Color container, Color onContainer, Color muted}) c = _statColors(
      context,
    );
    final TextStyle base = DefaultTextStyle.of(context).style;
    return Text.rich(
      TextSpan(
        children: <InlineSpan>[
          TextSpan(
            text: value,
            style: base.copyWith(
              fontSize: size,
              fontWeight: FontWeight.w900,
              letterSpacing: -0.04 * size,
              height: 1,
              color: c.onContainer,
            ),
          ),
          TextSpan(
            text: ' $unit',
            style: base.copyWith(
              fontSize: context.fushiType.bodyMedium.fontSize,
              fontWeight: FontWeight.w700,
              color: c.muted,
            ),
          ),
        ],
      ),
      maxLines: 1,
      textScaler: TextScaler.noScaling,
    );
  }
}

TextStyle _statKeyStyle(BuildContext context) => context
    .fushiType
    .labelMediumEmphasized
    .copyWith(color: _statColors(context).muted);

TextStyle _statSubStyle(BuildContext context) =>
    context.fushiType.bodySmall.copyWith(color: _statColors(context).muted);

/// 「本周时长」统计块（原 4 张 KPI 的今日 / 本周合进这里；总数 / 累计在页头副行）。
/// [days] 是近 7 天每天的游玩秒数（最旧 → 今天），今天那根用强调色，其余用
/// outline 与 onSurfaceVariant 的中点（在块底上约 4:1，对应稿 #8a8478）。柱高进场时从 0 长起（减弱动效瞬间）。
class GalgameWeekStatBlock extends StatelessWidget {
  const GalgameWeekStatBlock({required this.days, super.key});

  final List<int> days;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final int week = days.fold<int>(0, (int a, int b) => a + b);
    final int today = days.isEmpty ? 0 : days.last;
    final FushiCoverBlockFigure figure =
        galgamePlayTimeFigure(week) ??
        FushiCoverBlockFigure(value: '0', unit: t.shelf_block_play_hours_unit);
    final FushiCoverBlockFigure todayFigure =
        galgamePlayTimeFigure(today) ??
        FushiCoverBlockFigure(value: '0', unit: t.shelf_block_play_hours_unit);
    final int peak = days.fold<int>(0, math.max);
    // 非今天的柱：outline 与 onSurfaceVariant 的中点。单用 outline 在浅色
    // surfaceContainerHigh 上不到 3:1；设计稿 GA25 要的是 #8a8478 级别（≈4:1），
    // 同时比今天那根 primary 弱一档。
    final Color rest = Color.lerp(cs.outline, cs.onSurfaceVariant, 0.5)!;
    final MaterialLocalizations l10n = MaterialLocalizations.of(context);
    final DateTime now = DateTime.now();
    return Semantics(
      container: true,
      label:
          '${t.game_home_week_title}: ${figure.value} ${figure.unit}, '
          '${t.game_home_today_time(time: '${todayFigure.value} ${todayFigure.unit}')}',
      child: ExcludeSemantics(
        child: _StatShell(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(t.game_home_week_title, style: _statKeyStyle(context)),
              const SizedBox(height: 6),
              _StatValue(value: figure.value, unit: figure.unit),
              const SizedBox(height: 4),
              Text(
                t.game_home_today_time(
                  time: '${todayFigure.value} ${todayFigure.unit}',
                ),
                style: _statSubStyle(context),
              ),
              const Spacer(),
              TweenAnimationBuilder<double>(
                tween: Tween<double>(begin: 0, end: 1),
                duration: fushiMotionDuration(context, FushiMotion.long),
                curve: FushiMotion.enter,
                builder: (BuildContext context, double p, Widget? _) =>
                    SizedBox(
                      height: 46,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: <Widget>[
                          for (int i = 0; i < days.length; i++) ...<Widget>[
                            if (i > 0) const SizedBox(width: 5),
                            Expanded(
                              child: Container(
                                height: math.max(
                                  3,
                                  46 * p * (peak == 0 ? 0 : days[i] / peak),
                                ),
                                decoration: BoxDecoration(
                                  color: i == days.length - 1
                                      ? cs.primary
                                      : rest,
                                  borderRadius: const BorderRadius.vertical(
                                    top: Radius.circular(4),
                                    bottom: Radius.circular(2),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
              ),
              const SizedBox(height: 6),
              Row(
                children: <Widget>[
                  for (int i = 0; i < days.length; i++)
                    Expanded(
                      child: Text(
                        l10n.narrowWeekdays[now
                                .subtract(Duration(days: days.length - 1 - i))
                                .weekday %
                            7],
                        textAlign: TextAlign.center,
                        style: _statSubStyle(context),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 「游玩状态」分布块：总数 + 分段条 + 两列图例；点某档 = [onStatus]（进库页并
/// 筛到该状态）。图例行命中区 48dp。
class GalgameStatusStatBlock extends StatelessWidget {
  const GalgameStatusStatBlock({
    required this.counts,
    required this.onStatus,
    super.key,
  });

  final Map<GalgamePlayStatus, int> counts;
  final ValueChanged<GalgamePlayStatus> onStatus;

  /// 块需要的高度（3 行图例 × 48dp）。
  static const double height = 14 + 18 + 6 + 38 + 12 + 14 + 8 + 3 * 48 + 14;

  @override
  Widget build(BuildContext context) {
    final Brightness b = Theme.of(context).brightness;
    final int total = counts.values.fold<int>(0, (int a, int c) => a + c);
    const List<GalgamePlayStatus> order = kGalgameHomeStatusOrder;
    return _StatShell(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          ExcludeSemantics(
            child: Text(t.game_play_status, style: _statKeyStyle(context)),
          ),
          const SizedBox(height: 6),
          Semantics(
            label: '${t.game_play_status}: $total ${t.game_home_count_unit}',
            excludeSemantics: true,
            child: _StatValue(value: '$total', unit: t.game_home_count_unit),
          ),
          const SizedBox(height: 12),
          ExcludeSemantics(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(7),
              child: SizedBox(
                height: 14,
                child: Row(
                  children: <Widget>[
                    for (final GalgamePlayStatus s in order)
                      if ((counts[s] ?? 0) > 0)
                        Expanded(
                          flex: counts[s]!,
                          child: Padding(
                            padding: const EdgeInsetsDirectional.only(end: 2),
                            child: ColoredBox(
                              color: galgamePlayStatusDotColor(s, b),
                            ),
                          ),
                        ),
                    if (total == 0)
                      Expanded(
                        child: ColoredBox(
                          color: Theme.of(context).colorScheme.outlineVariant,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          for (int row = 0; row < 3; row++)
            Row(
              children: <Widget>[
                for (int col = 0; col < 2; col++)
                  Expanded(
                    child: _StatusLegendItem(
                      status: order[row * 2 + col],
                      count: counts[order[row * 2 + col]] ?? 0,
                      onTap: () => onStatus(order[row * 2 + col]),
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

class _StatusLegendItem extends StatelessWidget {
  const _StatusLegendItem({
    required this.status,
    required this.count,
    required this.onTap,
  });

  final GalgamePlayStatus status;
  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final Color dot = galgamePlayStatusDotColor(
      status,
      Theme.of(context).brightness,
    );
    final String label = '${galgamePlayStatusLabel(status)} $count';
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: FushiCard(
        focusId: FushiFocusId('game-dashboard-status-${status.name}'),
        onTap: onTap,
        color: Colors.transparent,
        borderColor: Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: SizedBox(
          height: kMinInteractiveDimension,
          child: Row(
            children: <Widget>[
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: dot,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.fushiType.bodySmall.copyWith(
                    color: _statColors(context).onContainer,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 「继续 · 最近」列表块：首块与 3 个普通块之外还有 [remaining] 个玩过的游戏，
/// 整块点按 = [onOpen]（进按最近游玩排序的库）。
class GalgameHomeMoreBlock extends StatelessWidget {
  const GalgameHomeMoreBlock({
    required this.remaining,
    required this.onOpen,
    super.key,
  });

  final int remaining;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final ({Color container, Color onContainer, Color muted}) c = _statColors(
      context,
    );
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label:
          '${t.game_home_more_title}, +$remaining ${t.game_home_count_unit}, '
          '${t.home_filter_all}',
      excludeSemantics: true,
      child: _StatShell(
        focusId: const FushiFocusId('game-dashboard-more'),
        onTap: onOpen,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(t.game_home_more_title, style: _statKeyStyle(context)),
            const SizedBox(height: 6),
            _StatValue(
              value: '+$remaining',
              unit: t.game_home_count_unit,
              size: 30,
            ),
            const Spacer(),
            Container(
              padding: const EdgeInsets.fromLTRB(12, 5, 8, 5),
              decoration: ShapeDecoration(
                color: Color.alphaBlend(
                  cs.onSurface.withValues(alpha: 0.08),
                  c.container,
                ),
                shape: const StadiumBorder(),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    t.home_filter_all,
                    style: context.fushiType.labelMediumEmphasized.copyWith(
                      color: c.onContainer,
                    ),
                  ),
                  const SizedBox(width: 2),
                  FushiIcon(
                    FushiIcons.chevronRight,
                    size: 16,
                    color: c.onContainer,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── 时间线 ──────────────────────────────────────────────────────────────────

/// 时间线一行的数据。
@immutable
class GalgameTimelineRowData {
  const GalgameTimelineRowData({
    required this.key,
    required this.title,
    required this.trailing,
    required this.dotHue,
    required this.added,
    this.onTap,
  });

  final String key;
  final String title;
  final String trailing;

  /// 行首色点的色相（标题哈希，与生成封面同色）。
  final double dotHue;

  /// 「新增」事件（标题前加「新增 · 」）。
  final bool added;

  /// null = 库里已没有这条，不可点。
  final VoidCallback? onTap;
}

/// 时间线一行：色点 + 标题（可换行，不截断）+ 行尾「会话数 · 时长」/「加入
/// 游戏库」。点按进详情。命中区 48dp。
class GalgameTimelineRow extends StatelessWidget {
  const GalgameTimelineRow({required this.data, super.key});

  final GalgameTimelineRowData data;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    final Color dot = FushiCoverBlockColors.fromHue(theme, data.dotHue).accent;
    final String title = data.added
        ? '${t.home_filter_added} · ${data.title}'
        : data.title;
    return Semantics(
      button: data.onTap != null,
      label: '$title, ${data.trailing}',
      excludeSemantics: true,
      child: FushiCard(
        focusId: FushiFocusId('game-dashboard-activity-${data.key}'),
        onTap: data.onTap,
        color: Colors.transparent,
        borderColor: Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            minHeight: kMinInteractiveDimension,
          ),
          child: Row(
            children: <Widget>[
              Container(
                width: 8,
                height: 24,
                decoration: BoxDecoration(
                  color: dot,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Text(
                    title,
                    style: context.fushiType.bodyMedium.copyWith(
                      color: cs.onSurface,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Text(
                data.trailing,
                maxLines: 1,
                style: context.fushiType.bodySmall.copyWith(
                  color: cs.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 一组：日期标签 + 当天的行。
@immutable
class GalgameTimelineGroupData {
  const GalgameTimelineGroupData({required this.label, required this.rows});

  final String label;
  final List<GalgameTimelineRowData> rows;
}

/// 时间线块：标题 +「全部 / 游戏 / 新增」筛选 chip（[filters]）+ 最近几行；块下
/// 由页面接完整历史（按日分组、日期头钉住）。
class GalgameTimelineBlock extends StatelessWidget {
  const GalgameTimelineBlock({
    required this.filters,
    required this.groups,
    required this.emptyLabel,
    super.key,
  });

  final List<Widget> filters;
  final List<GalgameTimelineGroupData> groups;
  final String emptyLabel;

  @override
  Widget build(BuildContext context) {
    return _StatShell(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            children: <Widget>[
              Text(t.home_activity, style: _statKeyStyle(context)),
              const SizedBox(width: 12),
              Expanded(
                child: Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: Wrap(spacing: 6, runSpacing: 6, children: filters),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          if (groups.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Text(emptyLabel, style: _statSubStyle(context)),
            )
          else
            for (final GalgameTimelineGroupData g in groups) ...<Widget>[
              Padding(
                padding: const EdgeInsetsDirectional.only(top: 6, start: 8),
                child: Text(
                  g.label,
                  style: context.fushiType.labelSmallEmphasized.copyWith(
                    color: _statColors(context).muted,
                  ),
                ),
              ),
              for (final GalgameTimelineRowData r in g.rows)
                GalgameTimelineRow(data: r),
            ],
        ],
      ),
    );
  }
}

// ── 网格 ────────────────────────────────────────────────────────────────────

/// 网格里的一块。[height] 给定块在宽度下需要的高度；null = 自然高度（时间线）。
@immutable
class GalgameHomeTile {
  const GalgameHomeTile({
    required this.span,
    required this.builder,
    this.height,
    this.compactSpan,
  });

  /// 四列时的跨列数。
  final int span;

  /// 两列时的跨列数；null = 同 [span]（超过列数按列数算）。
  final int? compactSpan;

  /// [columns] 列下的跨列数。
  int spanFor(int columns) =>
      (columns >= 4 ? span : (compactSpan ?? span)).clamp(1, columns);

  final double Function(double width)? height;
  final WidgetBuilder builder;
}

/// 按列数把块的跨列数 [spans] 顺序排进行（放不下就换行；超过列数按列数算），
/// 返回每行的块下标。纯函数。
List<List<int>> packGalgameHomeRows(List<int> spans, int columns) {
  final List<List<int>> rows = <List<int>>[];
  List<int> current = <int>[];
  int used = 0;
  for (int i = 0; i < spans.length; i++) {
    final int span = spans[i].clamp(1, columns);
    if (used + span > columns && current.isNotEmpty) {
      rows.add(current);
      current = <int>[];
      used = 0;
    }
    current.add(i);
    used += span;
  }
  if (current.isNotEmpty) rows.add(current);
  return rows;
}

/// 首页列数：宽 ≥ 960 四列，否则两列。
int galgameHomeColumnsFor(double width) => width >= 960 ? 4 : 2;

/// 拼贴网格：每行固定高度的块取本行最大需要高度；有自然高度块的行顶端对齐。
/// 块按出现顺序错峰进场（首块先到）。
class GalgameHomeGrid extends StatelessWidget {
  const GalgameHomeGrid({
    required this.tiles,
    this.gap = kGalgameHomeGap,
    super.key,
  });

  final List<GalgameHomeTile> tiles;
  final double gap;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        final double width = c.maxWidth;
        final int columns = galgameHomeColumnsFor(width);
        final double cell = (width - gap * (columns - 1)) / columns;
        double spanWidth(int span) {
          final int s = span.clamp(1, columns);
          return cell * s + gap * (s - 1);
        }

        final List<int> spans = <int>[
          for (final GalgameHomeTile tile in tiles) tile.spanFor(columns),
        ];
        final List<List<int>> rows = packGalgameHomeRows(spans, columns);
        final List<Widget> children = <Widget>[];
        for (int r = 0; r < rows.length; r++) {
          final List<int> row = rows[r];
          double fixed = 0;
          for (final int i in row) {
            final double Function(double)? h = tiles[i].height;
            if (h != null) {
              fixed = math.max(fixed, h(spanWidth(spans[i])));
            }
          }
          if (r > 0) children.add(SizedBox(height: gap));
          children.add(
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                for (int k = 0; k < row.length; k++) ...<Widget>[
                  if (k > 0) SizedBox(width: gap),
                  SizedBox(
                    width: spanWidth(spans[row[k]]),
                    height: tiles[row[k]].height == null ? null : fixed,
                    child: FushiStaggeredEntrance(
                      index: row[k],
                      child: tiles[row[k]].builder(context),
                    ),
                  ),
                ],
              ],
            ),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: children,
        );
      },
    );
  }
}

// ── 骨架与空状态 ────────────────────────────────────────────────────────────

/// 首载骨架：与真首页同轮廓（副行 → 首块 + 两个统计块 → 一行普通块 → 随机块 +
/// 时间线块），一层共享闪光扫过整组（减弱动效停止闪烁）。
class GalgameHomeSkeleton extends StatelessWidget {
  const GalgameHomeSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    BorderRadius radius(FushiCoverBlockSize size, double h) =>
        BorderRadius.circular(fushiCoverBlockRadius(size, h));
    Widget block(
      double h, {
      FushiCoverBlockSize size = FushiCoverBlockSize.regular,
    }) => FushiSkeleton(height: h, borderRadius: radius(size, h));
    return FushiSkeletonShimmer(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          FushiSkeleton.line(widthFactor: 0.28, height: 16),
          const SizedBox(height: kGalgameHomeGap),
          GalgameHomeGrid(
            tiles: <GalgameHomeTile>[
              GalgameHomeTile(
                span: 2,
                height: (_) => kGalgameHomeHeroHeight,
                builder: (_) => block(
                  kGalgameHomeHeroHeight,
                  size: FushiCoverBlockSize.hero,
                ),
              ),
              for (int i = 0; i < 2; i++)
                GalgameHomeTile(
                  span: 1,
                  height: (_) => kGalgameHomeStatHeight,
                  builder: (_) => block(kGalgameHomeStatHeight),
                ),
              for (int i = 0; i < 4; i++)
                GalgameHomeTile(
                  span: 1,
                  height: (_) => kGalgameHomeBlockHeight,
                  builder: (_) => block(kGalgameHomeBlockHeight),
                ),
              GalgameHomeTile(
                span: 1,
                height: (_) => kGalgameHomeRandomHeight,
                builder: (_) => block(kGalgameHomeRandomHeight),
              ),
              GalgameHomeTile(
                span: 3,
                height: (_) => kGalgameHomeRandomHeight,
                builder: (_) => block(kGalgameHomeRandomHeight),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 空状态引导块（不用大字）：生成封面小方块 + 「还没有游戏」+ 拖放提示 +
/// 「导入」/「去发现」。[onDiscover] 为 null（`externalDiscovery` 门控不可用）时
/// 不画「去发现」。
class GalgameHomeEmpty extends StatelessWidget {
  const GalgameHomeEmpty({
    required this.onImport,
    required this.onDiscover,
    super.key,
  });

  final VoidCallback onImport;
  final VoidCallback? onDiscover;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ({Color container, Color onContainer, Color muted}) c = _statColors(
      context,
    );
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: FushiStaggeredEntrance(
          index: 0,
          child: _StatShell(
            child: Padding(
              padding: EdgeInsets.all(tokens.spacing.gap),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  SizedBox(
                    width: 64,
                    height: 64,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(14),
                      child: FushiGeneratedCover(title: t.game_library),
                    ),
                  ),
                  SizedBox(width: tokens.spacing.card),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          t.game_empty,
                          style: context.fushiType.titleMediumEmphasized
                              .copyWith(color: c.onContainer),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          t.game_import_drop_hint,
                          style: _statSubStyle(context),
                        ),
                        SizedBox(height: tokens.spacing.card),
                        Wrap(
                          spacing: tokens.spacing.gap,
                          runSpacing: tokens.spacing.gap,
                          children: <Widget>[
                            FushiFilledButton.icon(
                              onPressed: onImport,
                              icon: const FushiIcon(FushiIcons.libraryAdd),
                              label: Text(t.library_view_import),
                            ),
                            if (onDiscover != null)
                              FushiFilledButton.tonalIcon(
                                onPressed: onDiscover,
                                icon: const FushiIcon(FushiIcons.travelExplore),
                                label: Text(t.game_home_go_discover),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
