/// 首页小组件的外框与共用排版件（spec 2026-11-15「首页小组件网格」）。
///
/// 网格给每块一个固定尺寸的格子；[HomeWidgetFrame] 把格子画成两套外观之一：
/// - 海报色块（重设计外壳且库页布局不是封面网格，原 `_posterPanels` 那套）：按组件
///   折叠色相的拼贴色块。统计 / 面板块默认不画标题大字水印（拼贴设计稿 G2 / H2 /
///   H5：水印只给带封面的媒体块）；需要「幽灵大字」的组件（AI 助手的「AI」）经
///   [HomeWidgetFrame.watermark] 自己给，装进末端半块；
/// - 分区卡（封面网格布局 / 墨水屏 / 旧外壳，原 `_sectionCard` 那套）：group 底色
///   圆角卡，墨水屏补 1px 描边，Apple 用 inset grouped 实色。
///
/// 框里是「小标题行 + 内容」，内容拿到剩余的全部空间（紧约束），按格子大小自己
/// 排版。内容里的文字配色经 [HomeWidgetStyle] 取，两套外观共用同一份内容代码。
library;

import 'dart:math' as math;

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

/// 小组件格子的内边距：窄网格一行高的格子收紧到 12，其余 16（与拼贴统计块
/// `HomeStatTile` 同口径）。
double homeWidgetFramePadding({required bool dense}) => dense ? 12 : 16;

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
    this.hue,
    required this.poster,
    required this.dense,
    required this.child,
    this.onTap,
    this.tapKey,
    this.showHeader = true,
    this.attention = false,
    this.semanticLabel,
    this.watermark,
    this.watermarkStartFactor = 0.5,
    this.bare = false,
  });

  final String title;
  final IconData icon;

  /// 海报色块取色用的稳定键（同一种组件每次同色）。
  final String hueKey;

  /// 指定色相（0–360）时海报色块用它、不按 [hueKey] 折叠（「语言目标」格用语言色，
  /// 与设置里目标行的颜色一致）。
  final double? hue;
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

  /// 海报色块的幽灵大字（如 AI 助手的「AI」）；null = 不画（G2：统计 / 面板块
  /// 不画标题水印）。分区卡外观忽略。
  final String? watermark;

  /// [watermark] 从块宽的这个比例处起排（装进末端那半块，不压内容）。
  final double watermarkStartFactor;

  /// true = 不画外框（色块 / 分区卡底都不要），只留小标题行 + 内容直接摆在页面
  /// 底上、四周不留内边距。内容本身就是一排封面色块时用（「最近添加」）：色块
  /// 套在另一块色块里，两层底色互相打架（用户 2026-11-17）。
  final bool bare;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final double pad = homeWidgetFramePadding(dense: dense);
    final FushiCoverBlockColors? colors = poster && !bare
        ? fushiPosterColors(
            context,
            hue ?? fushiPosterHue('home-widget/$hueKey'),
          )
        : null;
    final Color foreground = colors?.onContainer ?? tokens.surfaces.onSurface;
    final Color muted =
        colors?.onContainer.withValues(alpha: 0.8) ??
        tokens.type.metadata.color ??
        tokens.surfaces.onVariant;
    final Color accent = colors?.accent ?? tokens.surfaces.primary;
    final Color headerColor = attention
        ? scheme.error
        : colors != null
        ? muted
        : (tokens.type.sectionLabel.color ?? muted);
    // 海报色块的小标题与拼贴统计块（`HomeStatTile`）同一套：w700、次要色；分区卡
    // 外观走排版角色（不写裸字号）。
    final TextStyle headerStyle = colors != null
        ? FushiPosterText.meta
              .on(Theme.of(context).textTheme.bodyMedium ?? const TextStyle())
              .copyWith(color: headerColor, height: 1.2)
        : context.fushiType.labelMedium.copyWith(
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
                  // 无外框时标题行与下面色块里的文字对齐，往里收一点。
                  if (bare) const SizedBox(width: 12),
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

    if (bare) return body;

    final VoidCallback? tap = onTap;
    if (colors != null) {
      final String mark = watermark ?? '';
      final Widget block = mark.isEmpty
          ? FushiPosterBlock(
              watermark: '',
              colors: colors,
              padding: EdgeInsets.all(pad),
              hoverEnabled: tap != null,
              child: body,
            )
          : LayoutBuilder(
              builder: (BuildContext context, BoxConstraints box) =>
                  FushiPosterBlock(
                    watermark: mark,
                    watermarkEdge: FushiPosterWatermarkEdge.bottom,
                    watermarkStart: box.maxWidth.isFinite
                        ? box.maxWidth * watermarkStartFactor
                        : 0,
                    watermarkFontSize: dense ? 64 : 90,
                    colors: colors,
                    padding: EdgeInsets.all(pad),
                    hoverEnabled: tap != null,
                    child: body,
                  ),
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
    // 海报色块里主数字用强调色、900 字重、收紧字距（拼贴统计块 `HomeStatTile`
    // 同款）；分区卡外观照旧正文色。
    final bool poster = style?.poster ?? false;
    final Color fg = poster
        ? style!.accent
        : (style?.foreground ?? tokens.surfaces.onSurface);
    final Color muted = style?.muted ?? tokens.surfaces.onVariant;
    final String? u = unit;
    final FushiTypography type = context.fushiType;
    final TextStyle role = large ? type.displaySmall : type.headlineMedium;
    final double size = role.fontSize ?? kDefaultFontSize;
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: AlignmentDirectional.centerStart,
      child: Text.rich(
        TextSpan(
          children: <InlineSpan>[
            TextSpan(
              text: value,
              style: role.copyWith(
                fontWeight: poster ? FontWeight.w900 : FontWeight.w800,
                height: poster ? 1 : 1.05,
                letterSpacing: poster ? -0.03 * size : null,
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

/// 大字（[HomeWidgetFigure]）下面挂一行副行（今日时长 / 目标进度）时的排法：按自己
/// **实际拿到的高度**排，不靠裁剪（TinO49VcdQ：此前按整格高度判断矮不矮、放不下就
/// 竖向居中裁掉，窄窗口里副行被切掉下半截）。
///
/// - 副行按自然高度完整画出，大字收进剩下的高度（[HomeWidgetFigure] 自带等比缩小）；
/// - 剩下的高度连 [minFigureHeight] 都不够时只画大字（大字是格子的核心，副行让位）；
/// - 整组在高度方向居中、起始侧对齐。
class HomeWidgetFigureWithLine extends StatelessWidget {
  const HomeWidgetFigureWithLine({
    super.key,
    required this.figure,
    required this.line,
    required this.lineStyle,
    this.gap = 4,
    this.minFigureHeight = 24,
  });

  final Widget figure;

  /// 副行；null = 只有大字。
  final Widget? line;

  /// 副行文字的样式，用来估副行占多高（见 [homeWidgetLineExtent]）。
  final TextStyle lineStyle;

  /// 大字与副行之间的间距。
  final double gap;

  /// 挂副行时大字至少留这么高，不够就不挂副行。
  final double minFigureHeight;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints box) {
        final Widget? l = line;
        final bool showLine =
            l != null &&
            (!box.maxHeight.isFinite ||
                box.maxHeight >=
                    minFigureHeight +
                        gap +
                        homeWidgetLineExtent(context, lineStyle));
        final Widget column = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (box.maxHeight.isFinite) Flexible(child: figure) else figure,
            if (showLine) ...<Widget>[SizedBox(height: gap), l],
          ],
        );
        if (!box.maxHeight.isFinite) return column;
        return Align(
          alignment: AlignmentDirectional.centerStart,
          child: column,
        );
      },
    );
  }
}

/// 一行 [style] 文字在当前文字缩放下最多占多高：给了行高倍数按它算，没给时按 1.5 倍
/// 字号保守估（CJK 回退字体的自然行高约 1.3～1.45 倍），宁可多留也不让副行放不下。
double homeWidgetLineExtent(BuildContext context, TextStyle style) {
  final TextStyle resolved = DefaultTextStyle.of(context).style.merge(style);
  return MediaQuery.textScalerOf(
        context,
      ).scale(resolved.fontSize ?? kDefaultFontSize) *
      math.max(resolved.height ?? 1.5, 1.0);
}
