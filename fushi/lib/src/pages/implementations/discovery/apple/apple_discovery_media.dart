/// 发现页媒体条目的 Apple（Cupertino，iOS 27 / macOS 27）画法：海报卡、横滑
/// 海报货架、首块大图横幅与骨架（「浏览」页方案 A / B：Apple TV / Books 式的
/// 「封面 + 标题 + 副行」，不画 M3E 的取色色块与斜放海报拼贴）。
///
/// 只被共享发现件（[DiscoveryCoverCard] / [DiscoveryShelf] / [DiscoveryCoverGrid]
/// / [DiscoveryHeroBanner] / 「今日放送」）在 `isGlassDesign` 下分派调用；M3E
/// 路径不经过这里。
library;

import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/pages/implementations/discovery/apple/apple_discovery_shelf.dart';
import 'package:fushi/src/pages/implementations/discovery/apple/apple_discovery_widgets.dart';
import 'package:fushi/src/pages/implementations/discovery/discovery_layout.dart';
import 'package:fushi/src/utils/components/fushi_hover_lift.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/components/shelf_card_widgets.dart';

/// 海报卡的封面宽（Apple TV / Books 货架档）：iOS 档竖版 120、横版 240；macOS 档
/// 竖版 150、横版 280（Windows / Linux 乘 [fushiAppleMacScale]）。
double appleDiscoveryArtworkWidth(
  BuildContext context, [
  DiscoveryCoverShape shape = DiscoveryCoverShape.portrait,
]) {
  final bool mac = fushiAppleUsesMacMetrics(context);
  final double k = mac ? fushiAppleMacScale(context) : 1;
  final bool wide = shape == DiscoveryCoverShape.landscape;
  return (mac ? (wide ? 280.0 : 150.0) : (wide ? 240.0 : 120.0)) * k;
}

/// 卡内封面与文字的间距、标题 / 副行字号。
double _gap(BuildContext context) => 8;

TextStyle appleDiscoveryCardTitleStyle(BuildContext context) {
  final bool mac = fushiAppleUsesMacMetrics(context);
  return shelfCardTitleStyle(context).copyWith(
    fontSize: mac ? 13 * fushiAppleMacScale(context) : 15,
    height: 1.25,
  );
}

TextStyle appleDiscoveryCardSubtitleStyle(BuildContext context) {
  final bool mac = fushiAppleUsesMacMetrics(context);
  return TextStyle(
    fontSize: mac ? 12 * fushiAppleMacScale(context) : 13,
    height: 1.25,
    color: appleColorsOf(context).secondaryLabel,
  );
}

/// 给定卡宽时整张海报卡的高：封面（按 [shape] 比例）+ 间距 + 标题行 + 副行。
double appleDiscoveryTileHeight(
  BuildContext context, {
  required double width,
  DiscoveryCoverShape shape = DiscoveryCoverShape.portrait,
  int titleMaxLines = 2,
}) {
  final TextScaler scaler = MediaQuery.textScalerOf(context);
  final TextStyle title = appleDiscoveryCardTitleStyle(context);
  final TextStyle sub = appleDiscoveryCardSubtitleStyle(context);
  final double titleLine = scaler.scale(title.fontSize!) * title.height!;
  final double subLine = scaler.scale(sub.fontSize!) * sub.height!;
  return (width / shape.aspectRatio) +
      _gap(context) +
      titleLine * titleMaxLines +
      2 +
      subLine +
      2;
}

/// 海报卡：圆角封面（[ShelfCoverFrame] 的 Apple 内描边 + 柔和投影）+ 标题 +
/// 副行（星标评分等前导图标在副行最前）。焦点 / Enter / 长按 / 右键走
/// [shelfCoverCard]，悬停抬升走 [FushiHoverLift]。
class AppleDiscoveryPosterCard extends StatelessWidget {
  const AppleDiscoveryPosterCard({
    required this.title,
    required this.cover,
    this.subtitle,
    this.leadingIcon,
    this.shape = DiscoveryCoverShape.portrait,
    this.titleMaxLines = 2,
    this.onTap,
    this.onLongPress,
    this.focusId,
    super.key,
  });

  final String title;
  final Widget cover;
  final String? subtitle;
  final IconData? leadingIcon;
  final DiscoveryCoverShape shape;
  final int titleMaxLines;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final FushiFocusId? focusId;

  @override
  Widget build(BuildContext context) {
    final FushiAppleColors colors = appleColorsOf(context);
    final Widget source = cover;
    final Widget art = source is DiscoveryImageCover && source.title == null
        ? source.withTitle(title)
        : source;
    final String? meta = subtitle?.trim();
    final TextStyle subStyle = appleDiscoveryCardSubtitleStyle(context);
    final IconData? icon = leadingIcon;
    final bool interactive = onTap != null || onLongPress != null;
    final BorderRadius radius = discoveryCoverRadius(context);
    return FushiHoverLift(
      enabled: interactive,
      builder: (BuildContext context, bool _) => shelfCoverCard(
        focusId: focusId,
        onTap: onTap,
        onLongPress: onLongPress,
        onSecondaryTap: onLongPress,
        borderRadius: radius,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            AspectRatio(
              aspectRatio: shape.aspectRatio,
              child: ShelfCoverFrame(
                backgroundColor: colors.tertiaryFill,
                child: art,
              ),
            ),
            SizedBox(height: _gap(context)),
            Text(
              title,
              maxLines: titleMaxLines,
              overflow: TextOverflow.ellipsis,
              style: appleDiscoveryCardTitleStyle(context),
            ),
            if (meta != null && meta.isNotEmpty) ...<Widget>[
              const SizedBox(height: 2),
              Row(
                children: <Widget>[
                  if (icon != null) ...<Widget>[
                    FushiIcon(
                      icon,
                      size: (subStyle.fontSize ?? 13) - 1,
                      color: colors.secondaryLabel,
                    ),
                    const SizedBox(width: 2),
                  ],
                  Expanded(
                    child: Text(
                      meta,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: subStyle,
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 骨架海报卡：与 [AppleDiscoveryPosterCard] 同几何的静态占位（无动画）。
class AppleDiscoveryPosterSkeleton extends StatelessWidget {
  const AppleDiscoveryPosterSkeleton({
    this.shape = DiscoveryCoverShape.portrait,
    super.key,
  });

  final DiscoveryCoverShape shape;

  @override
  Widget build(BuildContext context) {
    final Color fill = appleColorsOf(context).tertiaryFill;
    Widget bar(double widthFactor) => FractionallySizedBox(
      widthFactor: widthFactor,
      child: Container(
        height: 10,
        decoration: BoxDecoration(
          color: fill,
          borderRadius: BorderRadius.circular(5),
        ),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        AspectRatio(
          aspectRatio: shape.aspectRatio,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: fill,
              borderRadius: discoveryCoverRadius(context),
            ),
          ),
        ),
        SizedBox(height: _gap(context) + 2),
        bar(0.85),
        const SizedBox(height: 6),
        bar(0.5),
      ],
    );
  }
}

/// 横滑海报货架：货架头（标题 + 行尾「查看全部 ›」）+ 横滑海报条（桌面悬停两端
/// 出翻页箭头）。[loading] 时画不可滚、不可聚焦的骨架条。
class AppleDiscoveryPosterShelf extends StatelessWidget {
  const AppleDiscoveryPosterShelf({
    required this.title,
    required this.itemCount,
    required this.itemBuilder,
    this.shape = DiscoveryCoverShape.portrait,
    this.titleMaxLines = 2,
    this.loading = false,
    this.trailing,
    this.storageKey,
    this.headerWrapper,
    super.key,
  });

  final String title;
  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;
  final DiscoveryCoverShape shape;
  final int titleMaxLines;
  final bool loading;

  /// 行尾件（「查看全部」）。
  final Widget? trailing;

  /// 横向列表的 [PageStorageKey] 值。
  final String? storageKey;

  /// 包住货架头的外层（「今日放送」整行可点进日历用）。
  final Widget Function(Widget header)? headerWrapper;

  @override
  Widget build(BuildContext context) {
    final double page = appleDiscoveryPageInset(context);
    final bool mac = fushiAppleUsesMacMetrics(context);
    final double gap = mac ? 16 : 12;
    final double width = appleDiscoveryArtworkWidth(context, shape);
    final double height = appleDiscoveryTileHeight(
      context,
      width: width,
      shape: shape,
      titleMaxLines: titleMaxLines,
    );
    final Widget header = Padding(
      padding: EdgeInsets.fromLTRB(page, 24, page, 4),
      child: AppleDiscoveryShelfHeader(
        title: title,
        loading: loading,
        trailing: trailing,
      ),
    );
    final String? storage = storageKey;
    final Widget strip = SizedBox(
      // 上下各留 8 给悬停抬升与投影。
      height: height + 16,
      child: ListView.separated(
        key: storage == null ? null : PageStorageKey<String>(storage),
        scrollDirection: Axis.horizontal,
        clipBehavior: Clip.none,
        physics: loading ? const NeverScrollableScrollPhysics() : null,
        padding: EdgeInsets.symmetric(horizontal: page, vertical: 8),
        itemCount: loading ? 8 : itemCount,
        separatorBuilder: (BuildContext context, int index) =>
            SizedBox(width: gap),
        itemBuilder: (BuildContext context, int index) => SizedBox(
          width: width,
          child: loading
              ? ExcludeFocus(child: AppleDiscoveryPosterSkeleton(shape: shape))
              : itemBuilder(context, index),
        ),
      ),
    );
    final Widget Function(Widget header)? wrap = headerWrapper;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        wrap == null ? header : wrap(header),
        if (loading) strip else AppleShelfHoverArrows(child: strip),
      ],
    );
  }
}

/// 首块大图横幅（Apple TV「精选」式）：剧照（没有就用海报）铺满圆角卡，底部
/// 渐暗，左下是眉标 · 排名、标题（有 logo 用 logo）与元信息。整块是一个焦点
/// 停靠点（Enter 打开）。
class AppleDiscoveryHeroBanner extends StatelessWidget {
  const AppleDiscoveryHeroBanner({
    required this.title,
    required this.onOpen,
    required this.height,
    this.eyebrow,
    this.metaParts = const <String>[],
    this.backdrop,
    this.poster,
    this.coverWidget,
    this.logo,
    this.actionLabel,
    this.actionKey,
    this.focusId,
    super.key,
  });

  final String title;
  final VoidCallback onOpen;

  /// 卡高（含不含页边距由调用方算好）。
  final double height;
  final String? eyebrow;
  final List<String> metaParts;
  final ImageProvider? backdrop;
  final ImageProvider? poster;
  final Widget? coverWidget;
  final ImageProvider? logo;
  final String? actionLabel;
  final Key? actionKey;
  final FushiFocusId? focusId;

  @override
  Widget build(BuildContext context) {
    final bool mac = fushiAppleUsesMacMetrics(context);
    final double k = mac ? fushiAppleMacScale(context) : 1;
    final BorderRadius radius = discoveryHeroRadius(context);
    final ImageProvider? image = backdrop ?? poster;
    final Widget background = image != null
        ? Image(
            image: image,
            fit: BoxFit.cover,
            alignment: backdrop != null
                ? Alignment.center
                : const Alignment(0, -0.4),
            excludeFromSemantics: true,
            errorBuilder: (BuildContext _, Object _, StackTrace? _) =>
                const DiscoveryCoverPlaceholder(showIcon: false),
          )
        : coverWidget ?? const DiscoveryCoverPlaceholder(showIcon: false);
    final String? eyebrowText = eyebrow?.trim();
    final ImageProvider? logoImage = logo;
    final TextStyle titleStyle = TextStyle(
      fontSize: (mac ? 26 : 28) * k,
      fontWeight: FontWeight.w700,
      height: 1.15,
      color: Colors.white,
    );
    final Widget titleWidget = logoImage == null
        ? Text(
            title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: titleStyle,
          )
        : ConstrainedBox(
            constraints: BoxConstraints(maxHeight: 64 * k, maxWidth: 320 * k),
            child: Image(
              image: logoImage,
              fit: BoxFit.contain,
              alignment: AlignmentDirectional.centerStart,
              semanticLabel: title,
              errorBuilder: (BuildContext _, Object _, StackTrace? _) =>
                  Text(title, maxLines: 2, style: titleStyle),
            ),
          );
    Widget card = FushiHoverLift(
      scale: 1.01,
      builder: (BuildContext _, bool _) => shelfCoverCard(
        key: actionKey,
        focusId: focusId,
        borderRadius: radius,
        onTap: onOpen,
        child: SizedBox(
          height: height,
          child: ClipRRect(
            borderRadius: radius,
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                background,
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      stops: <double>[0.35, 1],
                      colors: <Color>[Color(0x00000000), Color(0xB3000000)],
                    ),
                  ),
                ),
                Padding(
                  padding: EdgeInsets.all((mac ? 20 : 16) * k),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.end,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      if (eyebrowText != null && eyebrowText.isNotEmpty)
                        Text(
                          eyebrowText,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize:
                                (context.fushiType.bodySmall.fontSize ?? 13) *
                                k,
                            fontWeight: FontWeight.w600,
                            color: Colors.white.withValues(alpha: 0.8),
                          ),
                        ),
                      const SizedBox(height: 4),
                      titleWidget,
                      if (metaParts.isNotEmpty) ...<Widget>[
                        const SizedBox(height: 4),
                        Text(
                          metaParts.join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize:
                                (context.fushiType.bodySmall.fontSize ?? 13) *
                                k,
                            color: Colors.white.withValues(alpha: 0.8),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    final String? hint = actionLabel;
    if (hint != null && hint.isNotEmpty) {
      card = Semantics(container: true, hint: hint, child: card);
    }
    return card;
  }
}
