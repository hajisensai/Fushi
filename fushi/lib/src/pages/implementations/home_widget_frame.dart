/// 首页小组件的外框与共用排版件（spec 2026-11-15「首页小组件网格」）。
///
/// 网格给每块一个固定尺寸的格子；[HomeWidgetFrame] 把格子画成两套外观之一：
/// - 海报色块（重设计外壳且库页布局不是封面网格，原 `_posterPanels` 那套）：按组件
///   折叠色相的色块 + 大字水印；
/// - 分区卡（封面网格布局 / 墨水屏 / 旧外壳，原 `_sectionCard` 那套）：group 底色
///   圆角卡，墨水屏补 1px 描边，Apple 用 inset grouped 实色。
///
/// 框里是「小标题行 + 内容」，内容拿到剩余的全部空间（紧约束），按格子大小自己
/// 排版。内容里的文字配色经 [HomeWidgetStyle] 取，两套外观共用同一份内容代码。
library;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_cover_block.dart'
    show FushiCoverBlockColors, FushiCoverBlockSize, fushiCoverBlockShape;
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/components/fushi_hover_lift.dart';
import 'package:fushi/src/utils/components/fushi_poster_block.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart'
    show FushiAppleMetrics;
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/components/shelf_card_widgets.dart'
    show shelfCoverCard;

/// 小组件内容的配色与密度（由 [HomeWidgetFrame] 提供）。
class HomeWidgetStyle extends InheritedWidget {
  const HomeWidgetStyle({
    super.key,
    required this.poster,
    required this.foreground,
    required this.muted,
    required this.accent,
    required this.dense,
    this.colors,
    required super.child,
  });

  /// true = 海报色块外观。
  final bool poster;

  /// 海报色块的配色（[poster] 时非空）。
  final FushiCoverBlockColors? colors;

  /// 正文 / 大字颜色。
  final Color foreground;

  /// 次要文字颜色。
  final Color muted;

  /// 强调色（进度、主数字、图标）。
  final Color accent;

  /// 格子很矮（窄网格一行高）：内容只放最核心的一个数 / 图形。
  final bool dense;

  static HomeWidgetStyle of(BuildContext context) {
    final HomeWidgetStyle? style = context
        .dependOnInheritedWidgetOfExactType<HomeWidgetStyle>();
    assert(style != null, 'HomeWidgetStyle.of() outside a HomeWidgetFrame');
    return style!;
  }

  /// 框外（测试直接 pump 内容）时按分区卡外观兜底。
  static HomeWidgetStyle? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<HomeWidgetStyle>();

  @override
  bool updateShouldNotify(HomeWidgetStyle oldWidget) =>
      poster != oldWidget.poster ||
      colors != oldWidget.colors ||
      foreground != oldWidget.foreground ||
      muted != oldWidget.muted ||
      accent != oldWidget.accent ||
      dense != oldWidget.dense;
}

/// 格子高度低于它算「矮格」（窄网格一行高 76…96）：内容只放最核心的一个数 /
/// 图形，外框内边距收紧。宽网格最矮一行夹到 104，不算矮格。
const double kHomeWidgetDenseHeight = 100;

/// 格子宽度达到它算「宽格」（约 2 列起）：横向能并排挂计数 / 按钮 / 目标环。
const double kHomeWidgetWideWidth = 240;

/// [height] 高的格子是不是矮格（见 [kHomeWidgetDenseHeight]）。
bool homeWidgetIsDense(double height) => height < kHomeWidgetDenseHeight;

/// [width] 宽的格子是不是宽格（见 [kHomeWidgetWideWidth]）。
bool homeWidgetIsWide(double width) => width >= kHomeWidgetWideWidth;

/// [height] 高的区域里，行高 [lineHeight] 的文字最多放几行（至少 1 行，最多
/// [max] 行）：格子越高、文字放得越多，又不会溢出。
int homeWidgetLinesFor(double height, double lineHeight, {int max = 8}) {
  if (!height.isFinite) return max;
  return (height / lineHeight).floor().clamp(1, max);
}

/// [style] 的一行在当前文字缩放下占多高（字号 × 行高倍数），给
/// [homeWidgetLinesFor] 用：行数和渲染取自同一个排版角色，不另写一份字号。
double homeWidgetLineHeight(BuildContext context, TextStyle style) {
  final TextStyle resolved = DefaultTextStyle.of(context).style.merge(style);
  return MediaQuery.textScalerOf(
        context,
      ).scale(resolved.fontSize ?? kDefaultFontSize) *
      (resolved.height ?? 1.0);
}

/// 小组件格子的内边距：窄网格一行高的格子收紧，其余统一 14。
double homeWidgetFramePadding({required bool dense}) => dense ? 12 : 14;

/// 小标题行（图标 + 标题）高度。
const double kHomeWidgetHeaderHeight = 18;

/// 小标题行与内容之间的间距。
const double kHomeWidgetHeaderGap = 6;

/// 一块小组件的外框：小标题行 + 撑满剩余空间的内容。
///
/// [onTap] 非空时整块是一个点按目标（也是一个焦点停靠点）；内容里另有按钮时它们
/// 各自是停靠点。[tapKey] 落在点按目标上（沿用旧分区的测试 key）。
class HomeWidgetFrame extends StatelessWidget {
  const HomeWidgetFrame({
    super.key,
    required this.title,
    required this.icon,
    required this.hueKey,
    required this.poster,
    required this.dense,
    required this.child,
    this.onTap,
    this.tapKey,
    this.showHeader = true,
    this.attention = false,
    this.semanticLabel,
  });

  final String title;
  final IconData icon;

  /// 海报色块取色用的稳定键（同一种组件每次同色）。
  final String hueKey;
  final bool poster;
  final bool dense;
  final Widget child;
  final VoidCallback? onTap;
  final Key? tapKey;

  /// false = 不画小标题行（内容自己就标明了是什么，例如 1×1「今日」环）。
  final bool showHeader;

  /// 小标题行画成错误色（追踪有要处理的事）。
  final bool attention;

  /// 整块点按目标的读屏标签；null = 由内容文字合成。
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final double pad = homeWidgetFramePadding(dense: dense);
    final FushiCoverBlockColors? colors = poster
        ? fushiPosterColors(context, fushiPosterHue('home-widget/$hueKey'))
        : null;
    final Color foreground = colors?.onContainer ?? tokens.surfaces.onSurface;
    final Color muted =
        colors?.onContainer.withValues(alpha: 0.8) ??
        tokens.type.metadata.color ??
        tokens.surfaces.onVariant;
    final Color accent = colors?.accent ?? tokens.surfaces.primary;
    final Color headerColor = attention
        ? scheme.error
        : (colors?.onContainer ?? tokens.type.sectionLabel.color ?? muted);
    final TextStyle headerStyle = context.fushiType.labelMedium.copyWith(
      color: headerColor,
      height: 1.2,
      fontWeight: FontWeight.w600,
    );
    final Widget body = HomeWidgetStyle(
      poster: poster,
      colors: colors,
      foreground: foreground,
      muted: muted,
      accent: accent,
      dense: dense,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (showHeader) ...<Widget>[
            SizedBox(
              height: kHomeWidgetHeaderHeight,
              child: Row(
                children: <Widget>[
                  FushiIcon(icon, size: 14, color: headerColor),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: headerStyle,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: kHomeWidgetHeaderGap),
          ],
          Expanded(child: child),
        ],
      ),
    );

    final VoidCallback? tap = onTap;
    if (colors != null) {
      final Widget block = FushiPosterBlock(
        watermark: title,
        colors: colors,
        watermarkFontSize: dense ? 64 : 96,
        watermarkEdge: FushiPosterWatermarkEdge.bottom,
        padding: EdgeInsets.all(pad),
        hoverEnabled: tap != null,
        child: body,
      );
      if (tap == null) return block;
      return Semantics(
        label: semanticLabel,
        child: shelfCoverCard(
          key: tapKey,
          shape: fushiCoverBlockShape(context, FushiCoverBlockSize.regular),
          onTap: tap,
          child: block,
        ),
      );
    }

    // 分区卡：与原 `_sectionCard` 同口径（Apple 实色 inset grouped、墨水屏描边）。
    final bool eink = isEinkTheme(context);
    final bool apple = isGlassDesign(context);
    final Widget card = Material(
      color: apple
          ? appleColorsOf(context).secondaryGroupedBackground
          : tokens.surfaces.group,
      shape: RoundedRectangleBorder(
        borderRadius: apple
            ? FushiAppleMetrics.of(context).groupBorderRadius
            : FushiBorderRadius.card,
        side: eink
            ? BorderSide(color: tokens.surfaces.outline)
            : BorderSide.none,
      ),
      clipBehavior: Clip.antiAlias,
      child: tap == null
          ? Padding(padding: EdgeInsets.all(pad), child: body)
          : Semantics(
              label: semanticLabel,
              button: true,
              child: InkWell(
                key: tapKey,
                onTap: tap,
                child: Padding(padding: EdgeInsets.all(pad), child: body),
              ),
            ),
    );
    if (tap == null) return card;
    return FushiHoverLift(
      scale: 1.01,
      builder: (BuildContext context, bool hovering) =>
          FushiPressScale(child: card),
    );
  }
}

/// 格子里放不下自然高度的内容时（字号放大、长标题换行）：按自然高度排版、超出的
/// 部分裁掉，不抛溢出错误。只给按自然高度排版的复合内容（「继续」主角卡、封面行）
/// 用；自己按格子算好尺寸的内容不需要它。
class HomeWidgetOverflowClip extends StatelessWidget {
  const HomeWidgetOverflowClip({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => ClipRect(
    child: OverflowBox(
      alignment: AlignmentDirectional.topStart,
      minHeight: 0,
      maxHeight: double.infinity,
      child: child,
    ),
  );
}

/// 小组件里的「大数字 + 单位」（复习剩余张数、今日字数）：放不下时整体等比缩小，
/// 不折行、不省略号截断数字。
class HomeWidgetFigure extends StatelessWidget {
  const HomeWidgetFigure({
    super.key,
    required this.value,
    this.unit,
    this.large = false,
  });

  final String value;
  final String? unit;

  /// true = 大号（2 行以上的格子）。
  final bool large;

  @override
  Widget build(BuildContext context) {
    final HomeWidgetStyle? style = HomeWidgetStyle.maybeOf(context);
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final Color fg = style?.foreground ?? tokens.surfaces.onSurface;
    final Color muted = style?.muted ?? tokens.surfaces.onVariant;
    final String? u = unit;
    final FushiTypography type = context.fushiType;
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: AlignmentDirectional.centerStart,
      child: Text.rich(
        TextSpan(
          children: <InlineSpan>[
            TextSpan(
              text: value,
              style: (large ? type.displaySmall : type.headlineMedium).copyWith(
                fontWeight: FontWeight.w800,
                height: 1.05,
                color: fg,
              ),
            ),
            if (u != null)
              TextSpan(
                text: ' $u',
                style: type.labelLarge.copyWith(
                  fontWeight: FontWeight.w600,
                  color: muted,
                ),
              ),
          ],
        ),
        maxLines: 1,
        softWrap: false,
      ),
    );
  }
}
