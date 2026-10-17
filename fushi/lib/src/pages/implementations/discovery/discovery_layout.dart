/// 发现页共享**视觉**件：封面卡、封面占位、Hero 推荐横幅、Hero 背景、骨架、
/// 「查看全部」网格（sliver + 整页）。
///
/// 四个域（书 / 有声书 / galgame 资源站、视频、漫画）的发现页统一成同一套信息
/// 架构：页顶搜索 + 单行筛选 → 首屏 Hero 推荐 → 若干横滑 [DiscoveryShelf] →
/// 「查看全部」网格页 / 详情页。数据、请求、缓存、合规门都留在各页，这里只吃
/// 纯值（标题 / 文案 / ImageProvider / 封面 widget / 回调）。
///
/// 两套设计系统各自像原生：
/// - MD3 Expressive：封面 16 圆角、Hero 28 圆角（Expressive 大圆角卡）、按压
///   状态层 + 轻微下沉（[FushiCard] 自带）；
/// - Apple 26：封面 12（桌面 10）、Hero 24（桌面 16）——Apple TV / App Store 的
///   内容卡是**实色**（不是玻璃），只有压在 Hero 上的主按钮是白底 prominent 玻璃
///   （`overImage`）。
///
/// 结构恒定：任何一处都不按设计系统增删父包装层，只换参数（见 `_elements.contains`
/// 断言的教训）。
library;

import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart' show SliverConstraints;
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/media/collections/collection_detail_layout.dart'
    show CollectionHeroBadgeChips;
import 'package:fushi/src/media/video/cover_ui/landscape_cover_image.dart';
import 'package:fushi/src/media/video/cover_ui/portrait_cover_image.dart';
import 'package:fushi/src/utils/components/fushi_carousel.dart';
import 'package:fushi/src/utils/components/fushi_m3e_feedback.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/utils.dart';

/// 封面槽向：竖版海报 2:3 / 横版剧照 16:9。
enum DiscoveryCoverShape {
  portrait(2 / 3),
  landscape(16 / 9);

  const DiscoveryCoverShape(this.aspectRatio);

  /// 宽 / 高。
  final double aspectRatio;
}

/// 封面圆角：MD3 16（与 galgame 海报卡 / Expressive 卡片同档）；Apple 12、
/// 桌面 10（Apple TV / Music 封面圆角）。
BorderRadius discoveryCoverRadius(BuildContext context) {
  if (isGlassDesign(context)) {
    return BorderRadius.circular(
      FushiAppleMetrics.of(context).desktop ? 10 : 12,
    );
  }
  return BorderRadius.circular(FushiRadii.posterValue);
}

/// Hero 横幅圆角：MD3 Expressive 超大圆角 28；Apple 24（桌面 16）。
BorderRadius discoveryHeroRadius(BuildContext context) {
  if (isGlassDesign(context)) {
    return BorderRadius.circular(
      FushiAppleMetrics.of(context).desktop ? 16 : 24,
    );
  }
  return BorderRadius.circular(28);
}

/// 封面卡标题样式：MD3 listTitle；Apple 同字号 w600（App Store 卡片标题）。
TextStyle _cardTitleStyle(BuildContext context) {
  final TextStyle base = FushiDesignTokens.of(context).type.listTitle;
  return isGlassDesign(context)
      ? base.copyWith(fontWeight: FontWeight.w600)
      : base;
}

/// 封面卡次行（年份 · 类型 · 来源）样式。
TextStyle _cardMetaStyle(BuildContext context) {
  final FushiDesignTokens tokens = FushiDesignTokens.of(context);
  return tokens.type.metadata.copyWith(
    color: isGlassDesign(context)
        ? appleColorsOf(context).secondaryLabel
        : tokens.surfaces.onVariant,
  );
}

/// 封面与文字之间的间距。
const double _kCardTextGap = 8;

/// 统一的封面占位：分组底色 + 居中单色图标（无封面 / 加载失败 / 骨架共用）。
class DiscoveryCoverPlaceholder extends StatelessWidget {
  const DiscoveryCoverPlaceholder({
    this.icon = Icons.image_outlined,
    this.showIcon = true,
    super.key,
  });

  final IconData icon;

  /// 骨架态不画图标（只占形状）。
  final bool showIcon;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final bool apple = isGlassDesign(context);
    final Color background = apple
        ? appleColorsOf(context).tertiaryFill
        : tokens.surfaces.group;
    final Color foreground = apple
        ? appleColorsOf(context).tertiaryLabel
        : tokens.surfaces.onVariant;
    return ColoredBox(
      color: background,
      child: showIcon
          ? Center(child: FushiIcon(icon, size: 28, color: foreground))
          : const SizedBox.expand(),
    );
  }
}

/// 网络 / 磁盘封面：有图走 [PortraitCoverImage]（竖图 cover、横槽竖图模糊垫底），
/// 无图 / 解码失败落 [DiscoveryCoverPlaceholder]。
class DiscoveryImageCover extends StatelessWidget {
  const DiscoveryImageCover({
    required this.image,
    this.shape = DiscoveryCoverShape.portrait,
    this.placeholderIcon = Icons.image_outlined,
    super.key,
  });

  final ImageProvider? image;
  final DiscoveryCoverShape shape;
  final IconData placeholderIcon;

  @override
  Widget build(BuildContext context) {
    final ImageProvider? provider = image;
    if (provider == null) {
      return DiscoveryCoverPlaceholder(icon: placeholderIcon);
    }
    return PortraitCoverImage(
      image: provider,
      landscapeSlot: shape == DiscoveryCoverShape.landscape,
      errorBuilder: (_) =>
          const DiscoveryCoverPlaceholder(icon: Icons.broken_image_outlined),
    );
  }
}

/// 发现页统一封面卡：圆角封面（角标压在右上）+ 封面下方标题 / 次行。
///
/// 卡片本身是透明底的 [FushiCard]：点击 / 长按 / 焦点（[focusId]，Enter 激活）/
/// 按压下沉 / 状态层都由它提供；视觉上是 Apple TV / Google TV 的「封面 + 下方
/// 文字」磁贴，而不是一块包着封面的色卡。宽度由父级给（横滑行 / 网格），高度
/// 用 [DiscoveryCoverCard.extentFor] 预先算好，横滑行与网格因此不会因大字体溢出。
class DiscoveryCoverCard extends StatelessWidget {
  const DiscoveryCoverCard({
    required this.title,
    required this.cover,
    this.subtitle,
    this.shape = DiscoveryCoverShape.portrait,
    this.badges = const <Widget>[],
    this.titleMaxLines = 2,
    this.onTap,
    this.onLongPress,
    this.focusId,
    super.key,
  });

  final String title;

  /// 次行（年份 · 类型 · 评分 / 来源名）；null 不占位。
  final String? subtitle;

  /// 封面内容（[DiscoveryImageCover]，或漫画来源自带的封面 widget）。
  final Widget cover;

  final DiscoveryCoverShape shape;

  /// 压在封面右上角的角标（一般是 [CoverBadge]：评分 / 语言 / 状态）。
  final List<Widget> badges;

  final int titleMaxLines;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final FushiFocusId? focusId;

  /// 给定卡宽时整张卡的高度：封面（按 [shape]）+ 间距 + 标题行 + 次行。
  ///
  /// 文字高度按当前排版与 textScaler 实测，不压进固定宽高比——大字体下标题
  /// 不会被裁、横滑行也不会溢出（BUG-1527 那一类）。
  static double extentFor(
    BuildContext context, {
    required double width,
    DiscoveryCoverShape shape = DiscoveryCoverShape.portrait,
    int titleMaxLines = 2,
    bool hasSubtitle = true,
  }) {
    double measure(String text, TextStyle style) {
      final TextPainter painter = TextPainter(
        text: TextSpan(text: text, style: style),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
        maxLines: titleMaxLines,
      )..layout();
      final double height = painter.height;
      painter.dispose();
      return height;
    }

    final String titleProbe = List<String>.filled(
      titleMaxLines < 1 ? 1 : titleMaxLines,
      '国M',
    ).join('\n');
    double text = measure(titleProbe, _cardTitleStyle(context));
    if (hasSubtitle) text += measure('2026 · ★ 8.4', _cardMetaStyle(context));
    return (width / shape.aspectRatio + _kCardTextGap + text + 4)
        .ceilToDouble();
  }

  @override
  Widget build(BuildContext context) {
    final BorderRadius radius = discoveryCoverRadius(context);
    final String? meta = subtitle?.trim();
    return FushiCard(
      padding: EdgeInsets.zero,
      color: Colors.transparent,
      borderRadius: radius,
      focusId: focusId,
      onTap: onTap,
      onLongPress: onLongPress,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          AspectRatio(
            aspectRatio: shape.aspectRatio,
            child: ClipRRect(
              borderRadius: radius,
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  cover,
                  PositionedDirectional(
                    top: 6,
                    end: 6,
                    child: Wrap(spacing: 4, runSpacing: 4, children: badges),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: _kCardTextGap),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: Text(
              title,
              maxLines: titleMaxLines,
              overflow: TextOverflow.ellipsis,
              style: _cardTitleStyle(context),
            ),
          ),
          if (meta != null && meta.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Text(
                meta,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: _cardMetaStyle(context),
              ),
            ),
        ],
      ),
    );
  }
}

/// 骨架卡：与 [DiscoveryCoverCard] 同几何的静态占位（封面块 + 两条文字条）。
///
/// M3E 闪光是**有界**的（[FushiSkeletonShimmer] 扫三轮就停）：常驻的重复动画会
/// 让 `pumpAndSettle` 永不收敛；墨水屏 / 减弱动态效果下不扫。
class DiscoverySkeletonCard extends StatelessWidget {
  const DiscoverySkeletonCard({
    this.shape = DiscoveryCoverShape.portrait,
    super.key,
  });

  final DiscoveryCoverShape shape;

  @override
  Widget build(BuildContext context) {
    final BorderRadius radius = discoveryCoverRadius(context);
    // M3E：文字条是 [FushiSkeleton] 胶囊，整卡外包一层有界闪光（扫三轮停）。
    Widget line(double widthFactor) =>
        FushiSkeleton.line(widthFactor: widthFactor, height: 10);
    return ExcludeSemantics(
      child: FushiSkeletonShimmer(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            AspectRatio(
              aspectRatio: shape.aspectRatio,
              child: ClipRRect(
                borderRadius: radius,
                child: const DiscoveryCoverPlaceholder(showIcon: false),
              ),
            ),
            const SizedBox(height: _kCardTextGap + 2),
            line(0.86),
            const SizedBox(height: 6),
            line(0.5),
          ],
        ),
      ),
    );
  }
}

/// Hero 背景：图（横图铺满 / 竖图模糊垫底 + 尾侧完整前景 / 自带封面 widget）+
/// 可读性渐变。[DiscoveryHeroBanner] 与发现详情页的 hero 共用这一份，渐变配方
/// 与合集详情 hero（`CollectionDetailHero`）同一套语言：上浅下深 + 起始侧压暗。
class DiscoveryHeroBackdrop extends StatelessWidget {
  const DiscoveryHeroBackdrop({
    this.backdrop,
    this.poster,
    this.coverWidget,
    this.showPoster = true,
    this.foregroundPadding = EdgeInsets.zero,
    super.key,
  });

  /// 横版剧照（优先）。
  final ImageProvider? backdrop;

  /// 竖版海报（无剧照时用）。
  final ImageProvider? poster;

  /// 来源自带的封面 widget（漫画来源没有 ImageProvider 可给）；无 [backdrop] /
  /// [poster] 时用。
  final Widget? coverWidget;

  /// 竖图时是否在尾侧画完整前景海报（窄屏的竖卡直接铺满，不再另放）。
  final bool showPoster;

  /// 竖图前景海报的内边距（避让顶栏 / 底部文字）。
  final EdgeInsetsGeometry foregroundPadding;

  static List<Widget> _overlays(BuildContext context) {
    final bool rtl = Directionality.of(context) == TextDirection.rtl;
    return <Widget>[
      const DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            stops: <double>[0, 0.45, 1],
            colors: <Color>[
              Color(0x33000000),
              Color(0x14000000),
              Color(0xE6000000),
            ],
          ),
        ),
      ),
      DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: rtl ? Alignment.centerRight : Alignment.centerLeft,
            end: rtl ? Alignment.centerLeft : Alignment.centerRight,
            stops: const <double>[0, 0.62, 1],
            colors: const <Color>[
              Color(0xB8000000),
              Color(0x1A000000),
              Color(0x00000000),
            ],
          ),
        ),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final List<Widget> overlays = _overlays(context);
    final ImageProvider? backdrop = this.backdrop;
    final ImageProvider? poster = this.poster;
    final Widget? coverWidget = this.coverWidget;
    // 无图 / 解码失败的回落底：恒深色（白字要压在上面），MD3 混一点主色的
    // 色相，Apple 单色强调色下就是近黑的 systemGray6 深色。
    final Widget fallback = ColoredBox(
      color: Color.alphaBlend(
        cs.primary.withValues(alpha: 0.22),
        const Color(0xFF1C1C1E),
      ),
    );
    final Widget image;
    if (backdrop != null) {
      image = Stack(
        fit: StackFit.expand,
        children: <Widget>[
          // M3E carousel 视差：在 DiscoveryHeroCarousel 里随翻页反向慢移；
          // 单独使用（详情页 hero）时原样。
          FushiParallax(
            child: Image(
              image: backdrop,
              fit: BoxFit.cover,
              gaplessPlayback: true,
              errorBuilder: (_, __, ___) => fallback,
            ),
          ),
          ...overlays,
        ],
      );
    } else if (poster != null) {
      image = showPoster
          ? LandscapeCoverImage(
              image: poster,
              overlays: overlays,
              foregroundPadding: foregroundPadding,
              errorBuilder: (_) => fallback,
            )
          : Stack(
              fit: StackFit.expand,
              children: <Widget>[
                Image(
                  image: poster,
                  fit: BoxFit.cover,
                  alignment: Alignment.topCenter,
                  gaplessPlayback: true,
                  errorBuilder: (_, __, ___) => fallback,
                ),
                ...overlays,
              ],
            );
    } else if (coverWidget != null && !showPoster) {
      // 窄屏竖卡：封面直接铺满（与竖版海报 ImageProvider 的走法一致），底部
      // 渐变压字；不模糊——竖卡本身就是封面的槽向。
      image = Stack(
        fit: StackFit.expand,
        children: <Widget>[coverWidget, ...overlays],
      );
    } else if (coverWidget != null) {
      image = Stack(
        fit: StackFit.expand,
        children: <Widget>[
          // 模糊垫底：widget 没有 ImageProvider 可给 LandscapeCoverImage，
          // 直接把封面 widget 放大 + 模糊铺满。
          ClipRect(
            child: ImageFiltered(
              imageFilter: ui.ImageFilter.blur(
                sigmaX: LandscapeCoverImage.backdropBlurSigma,
                sigmaY: LandscapeCoverImage.backdropBlurSigma,
                tileMode: TileMode.mirror,
              ),
              child: Transform.scale(scale: 1.3, child: coverWidget),
            ),
          ),
          const ColoredBox(color: Color(0x1F000000)),
          ...overlays,
          Padding(
            padding: foregroundPadding,
            child: Align(
              alignment: AlignmentDirectional.centerEnd,
              child: AspectRatio(
                aspectRatio: DiscoveryCoverShape.portrait.aspectRatio,
                child: ClipRRect(
                  borderRadius: discoveryCoverRadius(context),
                  child: coverWidget,
                ),
              ),
            ),
          ),
        ],
      );
    } else {
      image = Stack(
        fit: StackFit.expand,
        children: <Widget>[fallback, ...overlays],
      );
    }
    return image;
  }
}

/// Hero 上压在深色渐变里的文字样式（与合集详情 hero 同一套：白字 + 透明度分层）。
abstract final class DiscoveryHeroText {
  /// 眉题（「热门」「某来源热门」）。
  static TextStyle eyebrow(BuildContext context) =>
      (Theme.of(context).textTheme.labelLarge ?? const TextStyle()).copyWith(
        color: Colors.white.withValues(alpha: 0.78),
        fontWeight: FontWeight.w600,
        letterSpacing: 0.3,
      );

  /// 大标题：宽屏 displaySmall、窄屏 headlineMedium，粗体白字。
  static TextStyle title(BuildContext context, {required bool wide}) {
    final TextTheme text = Theme.of(context).textTheme;
    final bool apple = isGlassDesign(context);
    return ((wide ? text.displaySmall : text.headlineMedium) ??
            const TextStyle())
        .copyWith(
          color: Colors.white,
          fontWeight: FontWeight.w700,
          height: 1.1,
          letterSpacing: apple ? -0.4 : null,
        );
  }

  /// 次行（原名 / 年份 · 类型）。
  static TextStyle meta(BuildContext context) =>
      (Theme.of(context).textTheme.bodyMedium ?? const TextStyle()).copyWith(
        color: Colors.white.withValues(alpha: 0.78),
      );

  /// 简介。
  static TextStyle summary(BuildContext context) =>
      (Theme.of(context).textTheme.bodyMedium ?? const TextStyle()).copyWith(
        color: Colors.white.withValues(alpha: 0.82),
        height: 1.35,
      );
}

/// 首屏 Hero 推荐横幅：大圆角大封面卡，左下大标题 + 元信息胶囊 + 简介 + 主按钮。
///
/// - 宽屏（≥ 720）：横幅高 = 宽 × 0.36（300–440）；有剧照铺满，只有竖版海报时
///   模糊垫底 + 尾侧完整海报（[LandscapeCoverImage]）。
/// - 窄屏：竖卡（宽 × 1.1，340–500），封面直接铺满、底部渐变压字。
///
/// 整卡可点（指针）；键盘 / 手柄的焦点落在主按钮上（只一个焦点停靠点，不让
/// 「卡片 + 按钮」重复占两次方向键）。
class DiscoveryHeroBanner extends StatelessWidget {
  const DiscoveryHeroBanner({
    required this.title,
    required this.actionLabel,
    required this.onOpen,
    this.eyebrow,
    this.subtitle,
    this.metaParts = const <String>[],
    this.summary,
    this.backdrop,
    this.poster,
    this.coverWidget,
    this.actionIcon = Icons.info_outline_rounded,
    this.actionKey,
    this.secondaryActions = const <Widget>[],
    super.key,
  });

  final String title;
  final String? eyebrow;

  /// 标题下一行（原名等）。
  final String? subtitle;

  /// 元信息胶囊（年份 / 类型 / ★ 评分），逐项存在才出。
  final List<String> metaParts;

  final String? summary;
  final ImageProvider? backdrop;
  final ImageProvider? poster;
  final Widget? coverWidget;

  final String actionLabel;
  final IconData actionIcon;
  final Key? actionKey;
  final VoidCallback onOpen;

  /// 主按钮之后的附加按钮（如订阅）。
  final List<Widget> secondaryActions;

  /// 横幅外边距内的高度（供调用方给骨架占位同高）。
  static double heightFor(double width) => width >= 720
      ? (width * 0.36).clamp(300.0, 440.0)
      : (width * 1.1).clamp(340.0, 500.0);

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double width = constraints.maxWidth;
        final bool wide = width >= 720;
        final double height = heightFor(width);
        final String? summary = this.summary?.trim();
        final String? subtitle = this.subtitle?.trim();
        final Widget info = ConstrainedBox(
          constraints: BoxConstraints(maxWidth: wide ? 560 : double.infinity),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              if (eyebrow != null) ...<Widget>[
                Text(
                  eyebrow!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: DiscoveryHeroText.eyebrow(context),
                ),
                const SizedBox(height: 4),
              ],
              Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: DiscoveryHeroText.title(context, wide: wide),
              ),
              if (subtitle != null &&
                  subtitle.isNotEmpty &&
                  subtitle != title) ...<Widget>[
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: DiscoveryHeroText.meta(context),
                ),
              ],
              if (metaParts.isNotEmpty) ...<Widget>[
                SizedBox(height: tokens.spacing.gap),
                CollectionHeroBadgeChips(parts: metaParts),
              ],
              if (summary != null && summary.isNotEmpty) ...<Widget>[
                SizedBox(height: tokens.spacing.gap),
                Flexible(
                  child: Text(
                    summary,
                    maxLines: wide ? 3 : 2,
                    overflow: TextOverflow.ellipsis,
                    style: DiscoveryHeroText.summary(context),
                  ),
                ),
              ],
              SizedBox(height: tokens.spacing.card),
              Wrap(
                spacing: tokens.spacing.gap,
                runSpacing: tokens.spacing.gap,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: <Widget>[
                  FushiFilledButton.icon(
                    key: actionKey,
                    onPressed: onOpen,
                    icon: FushiIcon(actionIcon),
                    label: Text(actionLabel),
                    // Apple：压在 hero 深色渐变上，白底黑字 prominent 玻璃
                    // （Apple TV「播放」）；MD3 不受影响。
                    overImage: true,
                  ),
                  ...secondaryActions,
                ],
              ),
            ],
          ),
        );
        return Padding(
          padding: EdgeInsets.fromLTRB(
            tokens.spacing.page,
            tokens.spacing.gap,
            tokens.spacing.page,
            0,
          ),
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onOpen,
              child: ClipRRect(
                borderRadius: discoveryHeroRadius(context),
                child: SizedBox(
                  height: height - tokens.spacing.gap,
                  child: Stack(
                    fit: StackFit.expand,
                    children: <Widget>[
                      DiscoveryHeroBackdrop(
                        backdrop: backdrop,
                        poster: poster,
                        coverWidget: coverWidget,
                        showPoster: wide,
                        foregroundPadding: const EdgeInsetsDirectional.fromSTEB(
                          0,
                          24,
                          32,
                          24,
                        ),
                      ),
                      Padding(
                        padding: EdgeInsets.all(wide ? 32 : 20),
                        child: Align(
                          alignment: AlignmentDirectional.bottomStart,
                          child: info,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Hero 骨架：与 [DiscoveryHeroBanner] 同几何的静态占位（首屏数据未到时占住
/// 位置，到达那一刻不把下方横滑行整体顶下去）。
class DiscoveryHeroSkeleton extends StatelessWidget {
  const DiscoveryHeroSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) => Padding(
        padding: EdgeInsets.fromLTRB(
          tokens.spacing.page,
          tokens.spacing.gap,
          tokens.spacing.page,
          0,
        ),
        child: ClipRRect(
          borderRadius: discoveryHeroRadius(context),
          child: SizedBox(
            height:
                DiscoveryHeroBanner.heightFor(constraints.maxWidth) -
                tokens.spacing.gap,
            child: const DiscoveryCoverPlaceholder(showIcon: false),
          ),
        ),
      ),
    );
  }
}

/// 网格单卡的目标最大宽度：竖版沿用书架同源档位（手机 150 → 桌面 210），横版
/// 放宽到 1.6 倍。
double discoveryGridMaxExtent(double width, DiscoveryCoverShape shape) {
  final double portrait = readerShelfGridExtentForWidth(width);
  return shape == DiscoveryCoverShape.landscape ? portrait * 1.6 : portrait;
}

/// 「查看全部」/ 搜索结果的封面网格（sliver）：按宽度自适应列数（手机至少
/// 2 列），行高由 [DiscoveryCoverCard.extentFor] 实测，大字体不溢出。
class DiscoveryCoverGrid extends StatelessWidget {
  const DiscoveryCoverGrid({
    required this.itemCount,
    required this.itemBuilder,
    this.shape = DiscoveryCoverShape.portrait,
    this.titleMaxLines = 2,
    this.hasSubtitle = true,
    this.padding,
    super.key,
  });

  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;
  final DiscoveryCoverShape shape;
  final int titleMaxLines;
  final bool hasSubtitle;

  /// null = 左右页边距、上 gap、下 card。
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final double gap = tokens.spacing.card;
    return SliverPadding(
      padding:
          padding ??
          EdgeInsets.fromLTRB(
            tokens.spacing.page,
            tokens.spacing.gap,
            tokens.spacing.page,
            tokens.spacing.card,
          ),
      sliver: SliverLayoutBuilder(
        builder: (BuildContext context, SliverConstraints constraints) {
          final double available = constraints.crossAxisExtent;
          final double maxExtent = discoveryGridMaxExtent(
            MediaQuery.sizeOf(context).width,
            shape,
          );
          final int desired = ((available + gap) / (maxExtent + gap)).ceil();
          final int columns = desired < 2
              ? (shape == DiscoveryCoverShape.landscape ? 1 : 2)
              : desired;
          final double width = (available - gap * (columns - 1)) / columns;
          return SliverGrid(
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
              mainAxisSpacing: gap,
              crossAxisSpacing: gap,
              mainAxisExtent: DiscoveryCoverCard.extentFor(
                context,
                width: width,
                shape: shape,
                titleMaxLines: titleMaxLines,
                hasSubtitle: hasSubtitle,
              ),
            ),
            // 2026-10 动效重做：逐项错峰淡入（与 [fushiStaggeredItemBuilder] 同一
            // 包法；调用方已自行包 [FushiStaggeredEntrance] 的原样放行，不叠两层）。
            // 进场窗口 [FushiEntranceScope] 由调用方在结果到达处给，这里不内置——
            // 骨架网格与结果网格同位复用时，内置窗口会在骨架期就关掉。
            delegate: SliverChildBuilderDelegate(
              (BuildContext context, int index) {
                final Widget child = itemBuilder(context, index);
                return child is FushiStaggeredEntrance
                    ? child
                    : FushiStaggeredEntrance(index: index, child: child);
              },
              childCount: itemCount,
            ),
          );
        },
      ),
    );
  }
}

/// 「查看全部」整页：顶栏标题 + [DiscoveryCoverGrid]。横滑行只展示一屏的条目，
/// 点行头「查看全部」推这一页看整组。
class DiscoveryGridPage extends StatelessWidget {
  const DiscoveryGridPage({
    required this.title,
    required this.itemCount,
    required this.itemBuilder,
    this.shape = DiscoveryCoverShape.portrait,
    this.titleMaxLines = 2,
    this.hasSubtitle = true,
    super.key,
  });

  final String title;
  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;
  final DiscoveryCoverShape shape;
  final int titleMaxLines;
  final bool hasSubtitle;

  /// 推一页「查看全部」。
  static Future<void> open(
    BuildContext context, {
    required String title,
    required int itemCount,
    required IndexedWidgetBuilder itemBuilder,
    DiscoveryCoverShape shape = DiscoveryCoverShape.portrait,
    int titleMaxLines = 2,
    bool hasSubtitle = true,
  }) {
    return Navigator.push<void>(
      context,
      adaptivePageRoute<void>(
        context: context,
        builder: (_) => DiscoveryGridPage(
          title: title,
          itemCount: itemCount,
          itemBuilder: itemBuilder,
          shape: shape,
          titleMaxLines: titleMaxLines,
          hasSubtitle: hasSubtitle,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return Scaffold(
      backgroundColor: tokens.surfaces.page,
      appBar: FushiAppBar(title: Text(title)),
      body: CustomScrollView(
        slivers: <Widget>[
          FushiEntranceScope(
            child: DiscoveryCoverGrid(
              itemCount: itemCount,
              itemBuilder: itemBuilder,
              shape: shape,
              titleMaxLines: titleMaxLines,
              hasSubtitle: hasSubtitle,
            ),
          ),
          SliverToBoxAdapter(child: SizedBox(height: tokens.spacing.section)),
        ],
      ),
    );
  }
}

/// 行头「查看全部」：文字按钮 + 尾侧小 chevron（Apple「See All ›」/ MD3
/// Expressive 的文字按钮）。文案沿用 `manga_discovery_view_all`（各语言已有）。
class DiscoveryViewAllButton extends StatelessWidget {
  const DiscoveryViewAllButton({required this.onPressed, super.key});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return FushiTextButton.icon(
      onPressed: onPressed,
      iconAlignment: IconAlignment.end,
      icon: const FushiIcon(Icons.chevron_right_rounded, size: 18),
      label: Text(t.manga_discovery_view_all),
    );
  }
}
