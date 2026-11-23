/// 发现页共享**视觉**件：媒体块、封面占位、拼贴首块、骨架、「查看全部」网格
/// （sliver + 整页）。
///
/// 四个域（书 / 有声书 / galgame 资源站、视频、漫画）的发现页统一成同一套信息
/// 架构：页顶搜索 + 单行筛选 → 拼贴首块轮播 → 若干横滑 [DiscoveryShelf] →
/// 「查看全部」网格页 / 详情页。数据、请求、缓存、合规门都留在各页，这里只吃
/// 纯值（标题 / 文案 / ImageProvider / 封面 widget / 回调）。
///
/// 2026-11 拼贴改版（设计稿「发现」节，所有者已确认）：
/// - 条目是**等尺寸媒体块**（[DiscoveryCoverCard]）：一块圆角色块，底色取封面
///   色相（与库页拼贴色块同一套 [FushiCoverBlockColors]），上面是封面、下面是
///   装满标题盒的完整标题（[FushiFitText]，不截断）；没有封面时画按标题生成
///   的封面（[FushiGeneratedCover]），色块底色取同一色相。
/// - 首屏是**拼贴首块**（[DiscoveryHeroBanner]）：背景剧照（没有就用封面放大
///   模糊）向底色渐入，竖封面斜放，来源 chip + 标题完整显示在不透明的实底标题
///   区里；整块可点进详情，不放「开始阅读」类按钮。
///
/// 结构恒定：任何一处都不按设计系统增删父包装层，只换参数（见 `_elements.contains`
/// 断言的教训）。
library;

import 'package:fushi/src/media/video/cover_ui/cover_orientation_builder.dart';
import 'package:fushi/src/media/video/video_home_layout.dart'
    show VideoCardOrientation;
import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/media/video/cover_ui/portrait_cover_image.dart';
import 'package:fushi/src/utils/components/fushi_continue_card_row.dart'
    show coverColorSchemeCache;
import 'package:fushi/src/utils/components/fushi_cover_block.dart';
import 'package:fushi/src/utils/components/fushi_cover_block_layout.dart';
import 'package:fushi/src/utils/components/fushi_fit_text.dart';
import 'package:fushi/src/utils/components/fushi_generated_cover.dart';
import 'package:fushi/src/utils/components/fushi_m3e_feedback.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/shelf_cover_material.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_hover_lift.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_bars.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart';
import 'package:fushi/src/utils/components/shelf_card_widgets.dart';
import 'package:fushi/src/utils/adaptive/fushi_page_backdrop.dart';
import 'package:fushi/src/utils/components/fushi_sliver_width_builder.dart';

/// 书 / 漫画封面的宽高比：与书架书卡封面区同一口径（约 1:1.42，见
/// `kShelfBookCardAspectRatio` 的推导——那个常量是**整张卡槽**的比例，封面区
/// 本身是 1:1.42）。
const double kDiscoveryBookCoverAspectRatio = 1 / 1.42;

/// 封面槽向：竖版海报 2:3 / 书封 1:1.42 / 方形专辑 1:1 / 横版剧照 16:9。
enum DiscoveryCoverShape {
  portrait(2 / 3),
  book(kDiscoveryBookCoverAspectRatio),
  square(1),
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

/// 大横幅圆角：MD3 Expressive 超大圆角 28；Apple 24（桌面 16）。资源站发现页
/// 的引导横幅用；拼贴首块走色块外形（[fushiCoverBlockShape]）。
BorderRadius discoveryHeroRadius(BuildContext context) {
  if (isGlassDesign(context)) {
    return BorderRadius.circular(
      FushiAppleMetrics.of(context).desktop ? 16 : 24,
    );
  }
  return BorderRadius.circular(28);
}

/// 统一的封面占位：分组底色 + 居中单色图标（加载失败 / 骨架共用）。
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

/// 网络 / 磁盘封面：有图走 [PortraitCoverImage]（竖图 cover、横槽竖图模糊垫底）。
///
/// 无图 / 解码失败：给了 [title] 就画按标题生成的封面（[FushiGeneratedCover]，
/// 设计稿 M2：不放空图标方块），否则落 [DiscoveryCoverPlaceholder]。放进
/// [DiscoveryCoverCard] 时卡片会自动补上 [title]。
class DiscoveryImageCover extends StatelessWidget {
  const DiscoveryImageCover({
    required this.image,
    this.shape = DiscoveryCoverShape.portrait,
    this.placeholderIcon = Icons.image_outlined,
    this.title,
    super.key,
  });

  final ImageProvider? image;
  final DiscoveryCoverShape shape;
  final IconData placeholderIcon;

  /// 生成封面用的标题；null = 无图时退回图标占位。
  final String? title;

  /// 补上 [title] 的副本（卡片给没带标题的封面兜底用）。
  DiscoveryImageCover withTitle(String value) => DiscoveryImageCover(
    key: key,
    image: image,
    shape: shape,
    placeholderIcon: placeholderIcon,
    title: value,
  );

  Widget _fallback(IconData icon) {
    final String? label = title?.trim();
    if (label != null && label.isNotEmpty) {
      return FushiGeneratedCover(title: label);
    }
    return DiscoveryCoverPlaceholder(icon: icon);
  }

  @override
  Widget build(BuildContext context) {
    final ImageProvider? provider = image;
    if (provider == null) return _fallback(placeholderIcon);
    return PortraitCoverImage(
      image: provider,
      landscapeSlot: shape == DiscoveryCoverShape.landscape,
      errorBuilder: (_) => _fallback(Icons.broken_image_outlined),
    );
  }
}

/// 色块配色：有封面图源时取封面色相（[coverColorSchemeCache]，与库页拼贴色块
/// 同一份缓存；取色完成前是中性色），没有图源时按 [title] 哈希给色相（与
/// [FushiGeneratedCover] 同色），墨水屏恒中性。两套设计系统都取色（与
/// [FushiCoverBlock] 同一口径，不经只在 MD3 下取色的 `FushiCoverTint`）。
class DiscoveryBlockTint extends StatefulWidget {
  const DiscoveryBlockTint({
    required this.title,
    required this.builder,
    this.image,
    super.key,
  });

  final String title;

  /// 取色图源；null = 按 [title] 哈希取色相。
  final ImageProvider? image;

  final Widget Function(BuildContext context, FushiCoverBlockColors colors)
  builder;

  @override
  State<DiscoveryBlockTint> createState() => _DiscoveryBlockTintState();
}

class _DiscoveryBlockTintState extends State<DiscoveryBlockTint> {
  ColorScheme? _scheme;
  ImageProvider? _tintFor;
  Brightness? _tintBrightness;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolve();
  }

  @override
  void didUpdateWidget(covariant DiscoveryBlockTint oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.image != widget.image) _resolve();
  }

  void _resolve() {
    final ImageProvider? image = isEinkTheme(context) ? null : widget.image;
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
    coverColorSchemeCache.resolve(image, brightness).then((ColorScheme? s) {
      if (!mounted || _tintFor != image || _tintBrightness != brightness) {
        return;
      }
      setState(() => _scheme = s);
    });
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final FushiCoverBlockColors colors;
    if (isEinkTheme(context)) {
      colors = FushiCoverBlockColors.resolve(theme, null);
    } else if (widget.image == null) {
      colors = FushiCoverBlockColors.fromHue(
        theme,
        fushiGeneratedCoverHue(widget.title),
      );
    } else {
      colors = FushiCoverBlockColors.resolve(theme, _scheme);
    }
    return widget.builder(context, colors);
  }
}

/// 媒体块的几何（设计稿 `.db.tile`）：桌面内边距 9、圆角 24、标题 15→12；手机
/// 内边距 7、圆角 18、标题 13→12。[DiscoveryCoverCard] 的布局、
/// [DiscoveryCoverCard.extentFor] 与骨架都只读这一份，三处永远同高。
@immutable
class _DiscoveryTileMetrics {
  const _DiscoveryTileMetrics({
    required this.padding,
    required this.radius,
    required this.gap,
    required this.titleMax,
  });

  factory _DiscoveryTileMetrics.of(BuildContext context) =>
      MediaQuery.sizeOf(context).width < 600
      ? const _DiscoveryTileMetrics(
          padding: 7,
          radius: 18,
          gap: 6,
          titleMax: 13,
        )
      : const _DiscoveryTileMetrics(
          padding: 9,
          radius: 24,
          gap: 7,
          titleMax: 15,
        );

  final double padding;
  final double radius;

  /// 封面与标题之间。
  final double gap;
  final double titleMax;

  /// 标题字号下限（两档同为 12：小字 ≥ 12px）。
  static const double titleMin = 12;

  /// 标题行高（设计稿 `.tile .fit` line-height 1.2）。
  static const double titleLineHeight = 1.2;

  /// 标题盒高：按**最小字号**预留 [titleMaxLines] + 1 行（默认两行标题 → 三行
  /// 12px），随系统字号放大；长标题到下限仍完整显示。
  double titleBoxHeight(BuildContext context, int titleMaxLines) =>
      MediaQuery.textScalerOf(context).scale(titleMin) *
      titleLineHeight *
      (titleMaxLines + 1);
}

/// 发现页**等尺寸媒体块**（设计稿 `.db.tile`）：一块圆角色块，底色取封面色相
/// （[DiscoveryBlockTint]），上面是封面（[ShelfCoverFrame] 平贴材质），下面是装满
/// 标题盒的完整标题（[FushiFitText]，桌面 15→12、手机 13→12，不截断），
/// 再下是可选副行（评分 · 年份 / 放送时间，可带 [leadingIcon]）。副行恒占一行
/// （同一网格行高一致）；没有副行时这一行让给标题。
///
/// 没有封面（[DiscoveryImageCover] 不带图）时画按标题生成的封面，色块取同一
/// 色相。点击 / 长按 / 焦点（[focusId]，Enter 激活）/ 按压下沉由卡壳（[FushiCard]）
/// 提供；悬停上浮来自 [FushiHoverLift]。宽度由父级给（横滑行 / 网格），高度用
/// [DiscoveryCoverCard.extentFor] 预先算好（随系统字号走，大字体不溢出，BUG-1527）。
class DiscoveryCoverCard extends StatelessWidget {
  const DiscoveryCoverCard({
    required this.title,
    required this.cover,
    this.subtitle,
    this.leadingIcon,
    this.shape = DiscoveryCoverShape.portrait,
    this.titleMaxLines = kShelfCardMetaTitleLines,
    this.tintImage,
    this.backdrop,
    this.logo,
    this.logoFuture,
    this.onTap,
    this.onLongPress,
    this.focusId,
    super.key,
  });

  final String title;

  /// 懒取的标题 logo（[discoveryLogoFor]）；[logo] 为 null 时等它，取到就代替
  /// 标题文字（与视频库系列块一样都有艺术字）。
  final Future<ImageProvider?>? logoFuture;

  /// 横版剧照（只在竖海报摆法下生效）：有就与视频库系列块同摆法——剧照按原比例
  /// 铺在尾侧、竖海报完整斜放在起始侧。
  final ImageProvider? backdrop;

  /// 标题 logo（透明底艺术字）：有就代替标题文字。
  final ImageProvider? logo;

  /// 副行（评分 · 年份 · 类型 / 来源名）；null 时这一行让给标题。
  final String? subtitle;

  /// 副行前导图标（如评分的星）。
  final IconData? leadingIcon;

  /// 封面内容（[DiscoveryImageCover]，或来源自带的封面 widget）。由
  /// [ShelfCoverFrame] 裁圆角、铺满，封面 widget 自己不要再裁。
  final Widget cover;

  final DiscoveryCoverShape shape;

  /// 标题常规行数：标题盒按最小字号预留这么多行再多一行（长标题降到下限时
  /// 仍完整显示）。
  final int titleMaxLines;

  /// 色块取色图源；null = 从 [cover] 推（[DiscoveryImageCover] 的图 / `Image`
  /// 的图源），推不出来按标题哈希取色相。
  final ImageProvider? tintImage;

  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final FushiFocusId? focusId;

  /// 给定卡宽时整块的高度：内边距 + 封面（按 [shape]）+ 标题盒 + 副行。
  static double extentFor(
    BuildContext context, {
    required double width,
    DiscoveryCoverShape shape = DiscoveryCoverShape.portrait,
    int titleMaxLines = kShelfCardMetaTitleLines,
  }) => discoveryTileHeight(context);
  ImageProvider? get _resolvedTint {
    final ImageProvider? explicit = tintImage;
    if (explicit != null) return explicit;
    final Widget source = cover;
    if (source is DiscoveryImageCover) return source.image;
    return fushiCoverImageOf(source);
  }

  /// 封面槽向 → 色块的封面摆法（竖海报斜放 / 书封 / 方形 / 横版剧照）。
  FushiCoverBlockArt get _art => switch (shape) {
    DiscoveryCoverShape.portrait => FushiCoverBlockArt.portrait,
    DiscoveryCoverShape.book => FushiCoverBlockArt.book,
    DiscoveryCoverShape.square => FushiCoverBlockArt.square,
    DiscoveryCoverShape.landscape => FushiCoverBlockArt.landscape,
  };

  /// 色块的前景封面：[DiscoveryImageCover] 拆成图源直接给色块（没图时给空表，
  /// 色块自己按标题画生成封面、取同一色相）；来源自带的封面 widget 原样给。
  List<Widget> get _blockCovers {
    final Widget source = cover;
    if (source is! DiscoveryImageCover) return <Widget>[source];
    final ImageProvider? image = source.image;
    if (image == null) return const <Widget>[];
    return <Widget>[
      PortraitCoverImage(
        image: image,
        landscapeSlot: shape == DiscoveryCoverShape.landscape,
        errorBuilder: (BuildContext _) =>
            FushiGeneratedCover(title: title.trim().isEmpty ? '?' : title),
      ),
    ];
  }

  /// 竖海报槽里的封面图（只有 [DiscoveryImageCover] 带图时有）。
  ImageProvider? get _portraitImage {
    final Widget source = cover;
    if (shape != DiscoveryCoverShape.portrait) return null;
    return source is DiscoveryImageCover ? source.image : null;
  }

  Widget _buildBlock({
    required FushiCoverBlockArt art,
    required List<Widget> covers,
    required ImageProvider? backdropImage,
    required ImageProvider? logoImage,
  }) {
    final String? meta = subtitle?.trim();
    return FushiCoverBlock(
      title: title,
      art: art,
      covers: covers,
      tintImage: _resolvedTint,
      subtitle: meta == null || meta.isEmpty ? null : meta,
      leadingIcon: leadingIcon,
      hoverEnabled: onTap != null || onLongPress != null,
      backdrop: backdropImage == null
          ? null
          : Image(
              image: backdropImage,
              fit: BoxFit.cover,
              excludeFromSemantics: true,
              errorBuilder: (BuildContext _, Object _, StackTrace? _) =>
                  const SizedBox.shrink(),
            ),
      logo: logoImage,
    );
  }

  /// 与视频库系列块同一套朝向分流（[CoverOrientationBuilder]）：竖海报槽里的
  /// 封面其实是横图时（AniList 部分作品只有横版主视觉），不硬塞进 2:3 斜放
  /// 封面，改走横版摆法——有横版剧照用剧照、否则用这张横图铺在尾侧（用户
  /// 2026-11-16「只有横屏的要显示横屏的……跟媒体库的系列组件要一样」）。
  Widget _buildOriented(ImageProvider? logoImage) {
    final ImageProvider? image = _portraitImage;
    final ImageProvider? backdropImage = shape == DiscoveryCoverShape.portrait
        ? backdrop
        : null;
    if (image == null) {
      return _buildBlock(
        art: _art,
        covers: _blockCovers,
        backdropImage: backdropImage,
        logoImage: logoImage,
      );
    }
    return CoverOrientationBuilder(
      image: image,
      builder: (BuildContext context, VideoCardOrientation resolved) {
        if (resolved == VideoCardOrientation.portrait) {
          return _buildBlock(
            art: FushiCoverBlockArt.portrait,
            covers: _blockCovers,
            backdropImage: backdropImage,
            logoImage: logoImage,
          );
        }
        return _buildBlock(
          art: FushiCoverBlockArt.landscape,
          covers: <Widget>[
            PortraitCoverImage(
              image: backdropImage ?? image,
              landscapeSlot: true,
              errorBuilder: (BuildContext _) => FushiGeneratedCover(
                title: title.trim().isEmpty ? '?' : title,
              ),
            ),
          ],
          backdropImage: null,
          logoImage: logoImage,
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool interactive = onTap != null || onLongPress != null;
    final Future<ImageProvider?>? pending = logo == null ? logoFuture : null;
    final Widget block = pending == null
        ? _buildOriented(logo)
        : FutureBuilder<ImageProvider?>(
            future: pending,
            builder:
                (BuildContext context, AsyncSnapshot<ImageProvider?> snap) =>
                    _buildOriented(snap.data),
          );
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) => FushiHoverLift(
        enabled: interactive,
        builder: (BuildContext _, bool _) => shelfCoverCard(
          focusId: focusId,
          onTap: onTap,
          onLongPress: onLongPress,
          onSecondaryTap: onLongPress,
          borderRadius: BorderRadius.circular(
            fushiCoverBlockRadius(FushiCoverBlockSize.regular, c.maxHeight),
          ),
          child: block,
        ),
      ),
    );
  }
}

/// 骨架块：与 [DiscoveryCoverCard] 同几何的静态占位（色块 + 封面块 + 两条文字
/// 条），数据到达时版面不跳。
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
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final _DiscoveryTileMetrics m = _DiscoveryTileMetrics.of(context);
    final Color block = isGlassDesign(context)
        ? appleColorsOf(context).tertiaryFill
        : tokens.surfaces.group;
    Widget line(double widthFactor) =>
        FushiSkeleton.line(widthFactor: widthFactor, height: 10);
    return ExcludeSemantics(
      child: FushiSkeletonShimmer(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: block,
            borderRadius: BorderRadius.circular(m.radius),
          ),
          child: Padding(
            padding: EdgeInsets.all(m.padding),
            // 高度受限（拼贴块格子 / 横滑行定高）时按色块摆法占位：起始侧
            // 竖封面 + 尾侧标题行，与真卡（[FushiCoverBlock]）同形，不再把
            // 竖版卡塞进矮格子溢出；不受限（自由高度的网格）仍是竖卡。
            child: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints c) {
                final Widget lines = Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    line(0.86),
                    const SizedBox(height: 6),
                    line(0.5),
                  ],
                );
                if (c.hasBoundedHeight) {
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      AspectRatio(
                        aspectRatio: DiscoveryCoverShape.portrait.aspectRatio,
                        child: FushiSkeleton(
                          borderRadius: shelfCoverRadius(context),
                        ),
                      ),
                      SizedBox(width: m.gap + 6),
                      Expanded(
                        child: Align(
                          alignment: AlignmentDirectional.bottomStart,
                          child: lines,
                        ),
                      ),
                    ],
                  );
                }
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    AspectRatio(
                      aspectRatio: shape.aspectRatio,
                      child: FushiSkeleton(
                        borderRadius: shelfCoverRadius(context),
                      ),
                    ),
                    SizedBox(height: m.gap + 2),
                    lines,
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

/// 横滑行的悬停留白：卡片悬停放大（[FushiHoverLift]）后上下各多出的高度再加
/// 4px 投影余量。自己摆横滑列表的行（「今日放送」）按它上下留白，抬升的块不被
/// 行的裁切边吃掉（与媒体服务器横滚行同一算法）。
double discoveryShelfLiftHeadroom(double cardHeight) =>
    shelfHoverLiftHeadroom(cardHeight);

/// 首屏**拼贴首块**（设计稿「发现」`.hero2`，DI1）：一块色块，底色取封面色相
/// （[DiscoveryBlockTint]），背景是横版剧照（[backdrop]；没有就用封面放大模糊）
/// 从尾侧向底色渐入；起始侧斜放竖封面（悬停 −4° → −8° 并略放大，减弱动态效果下
/// 不动），旁边是**不透明实底**标题区：来源 chip（[eyebrow] · 排名 [rank]）+ 装满
/// 盒子的完整标题（[FushiFitText]，桌面 34→18、手机 22→14，不截断）+ 可选
/// 元信息行（[metaParts]：年份 / 评分 / 题材，只放来源已给的）。
///
/// 默认只有「标题 + 来源 + 排名」（DI9：不为首块另取作者 / 状态 / 题材）。整块
/// 可点 = 打开详情（[onOpen]），不放「开始阅读」类按钮；键盘 / 手柄焦点就落在
/// 整块上（[actionKey] 是这块的 key，[actionLabel] 进读屏提示）。
class DiscoveryHeroBanner extends StatelessWidget {
  const DiscoveryHeroBanner({
    required this.title,
    required this.onOpen,
    this.eyebrow,
    this.rank,
    this.metaParts = const <String>[],
    this.backdrop,
    this.logo,
    this.poster,
    this.coverWidget,
    this.actionLabel,
    this.actionKey,
    this.focusId,
    super.key,
  });

  final String title;

  /// 来源 chip 文字（「MangaDex 热门」「热门」）；null 且无 [rank] 时不画 chip。
  final String? eyebrow;

  /// 在来源列表里的排名（1 起）；chip 里接在 [eyebrow] 后。
  final int? rank;

  /// 元信息（年份 / ★ 评分 / 题材），逐项存在才出，合成一行。
  final List<String> metaParts;

  /// 横版剧照（背景优先用它）。
  final ImageProvider? backdrop;

  /// 标题 logo 艺术字（透明底 PNG）：有就代替标题文字；解码失败回落文字。
  final ImageProvider? logo;

  /// 竖版海报：前景竖封面；没有 [backdrop] 时也放大模糊作背景。
  final ImageProvider? poster;

  /// 来源自带的封面 widget（漫画来源没有 ImageProvider 可给）；没有 [poster]
  /// 时用作前景竖封面与模糊背景。
  final Widget? coverWidget;

  /// 读屏提示（「查看详情」）。
  final String? actionLabel;

  /// 整块（焦点停靠点）的 key。
  final Key? actionKey;
  final FushiFocusId? focusId;

  final VoidCallback onOpen;

  /// 首块所在槽位（含顶部 gap）的高度：轮播与骨架按它占位。
  static double heightFor(double width) => width >= 720 ? 292 : 256;

  String? get _chipLabel {
    final List<String> parts = <String>[
      if (eyebrow?.trim().isNotEmpty == true) eyebrow!.trim(),
      if (rank != null) t.discovery_hero_rank(rank: rank!),
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ImageProvider? posterImage = poster;
    final ImageProvider? coverImage = posterImage ?? _coverWidgetImage;
    final ImageProvider? backdropImage = backdrop;
    final Widget? front = posterImage != null
        ? PortraitCoverImage(
            image: posterImage,
            errorBuilder: (BuildContext _) => FushiGeneratedCover(title: title),
          )
        : coverWidget;
    // 与视频库系列首块同一个组件（用户 2026-11-16：「用视频里的系列那种，有封面
    // 艺术字」）：横版剧照按原比例铺在尾侧、起始侧渐隐进色块，竖海报斜放在
    // 起始侧，有标题 logo 时 logo 代替标题文字。不再用封面放大模糊垫底。
    final Widget block = FushiCoverBlock(
      size: FushiCoverBlockSize.hero,
      art: FushiCoverBlockArt.portrait,
      title: title,
      covers: <Widget>[?front],
      backdrop: backdropImage == null
          ? null
          : Image(
              image: backdropImage,
              fit: BoxFit.cover,
              excludeFromSemantics: true,
              errorBuilder: (BuildContext _, Object _, StackTrace? _) =>
                  const SizedBox.shrink(),
            ),
      logo: logo,
      eyebrow: _chipLabel,
      overview: metaParts.isEmpty ? null : metaParts.join(' · '),
      tintImage: coverImage ?? backdropImage,
    );
    return Padding(
      padding: EdgeInsets.fromLTRB(
        tokens.spacing.page,
        tokens.spacing.gap,
        tokens.spacing.page,
        0,
      ),
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          // 槽高按含页边距的整宽判档（轮播与骨架给 [heightFor] 的就是它）。
          final double slotWidth =
              constraints.maxWidth + tokens.spacing.page * 2;
          final double height = heightFor(slotWidth) - tokens.spacing.gap;
          Widget card = FushiHoverLift(
            builder: (BuildContext _, bool _) => shelfCoverCard(
              key: actionKey,
              focusId: focusId,
              shape: fushiCoverBlockShape(context, FushiCoverBlockSize.hero),
              onTap: onOpen,
              child: SizedBox(height: height, child: block),
            ),
          );
          final String? hint = actionLabel;
          if (hint != null && hint.isNotEmpty) {
            card = Semantics(container: true, hint: hint, child: card);
          }
          return card;
        },
      ),
    );
  }

  ImageProvider? get _coverWidgetImage {
    final Widget? widget = coverWidget;
    return widget == null ? null : fushiCoverImageOf(widget);
  }
}

/// 首块骨架：与 [DiscoveryHeroBanner] 同几何的静态占位（首屏数据未到时占住
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
        child: ClipPath(
          clipper: ShapeBorderClipper(
            shape: fushiCoverBlockShape(context, FushiCoverBlockSize.hero),
            textDirection: Directionality.of(context),
          ),
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
double discoveryGridMaxExtent(double width, DiscoveryCoverShape shape) =>
    shape == DiscoveryCoverShape.landscape
    ? kFushiCoverBlockTargetWidthWide
    : kFushiCoverBlockTargetWidthMedia;

/// 发现页媒体块（[DiscoveryCoverCard]）的块高：与库页拼贴规整块同档——只排得下
/// 一列的窄窗 [kFushiCoverBlockHeightCompact]，否则 [kFushiCoverBlockHeight]。
double discoveryTileHeight(BuildContext context) =>
    FushiCoverBlockStrip.isCompact(MediaQuery.sizeOf(context).width)
    ? kFushiCoverBlockHeightCompact
    : kFushiCoverBlockHeight;

/// 发现页横滑行的块宽（与库页横滑条 [FushiCoverBlockStrip.rowTileWidth] 同一
/// 规则：桌面 300，窄窗约七成行宽）。
double discoveryTileWidth(BuildContext context) =>
    FushiCoverBlockStrip.rowTileWidth(MediaQuery.sizeOf(context).width);

/// 「查看全部」/ 搜索结果的媒体块网格（sliver）：等尺寸块，按宽度自适应列数
/// （手机至少 2 列），行高由 [DiscoveryCoverCard.extentFor] 实测，大字体不溢出。
class DiscoveryCoverGrid extends StatelessWidget {
  const DiscoveryCoverGrid({
    required this.itemCount,
    required this.itemBuilder,
    this.shape = DiscoveryCoverShape.portrait,
    this.titleMaxLines = kShelfCardMetaTitleLines,
    this.padding,
    super.key,
  });

  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;
  final DiscoveryCoverShape shape;
  final int titleMaxLines;

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
      sliver: FushiSliverWidthBuilder(
        builder: (BuildContext context, double crossAxisExtent) {
          final double available = crossAxisExtent;
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
              // 媒体块自带色块底：行列同距。
              mainAxisSpacing: gap,
              crossAxisSpacing: gap,
              mainAxisExtent: DiscoveryCoverCard.extentFor(
                context,
                width: width,
                shape: shape,
                titleMaxLines: titleMaxLines,
              ),
            ),
            // 2026-10 动效重做：逐项错峰淡入（与 [fushiStaggeredItemBuilder] 同一
            // 包法；调用方已自行包 [FushiStaggeredEntrance] 的原样放行，不叠两层）。
            // 进场窗口 [FushiEntranceScope] 由调用方在结果到达处给，这里不内置——
            // 骨架网格与结果网格同位复用时，内置窗口会在骨架期就关掉。
            delegate: SliverChildBuilderDelegate((
              BuildContext context,
              int index,
            ) {
              final Widget child = itemBuilder(context, index);
              return child is FushiStaggeredEntrance
                  ? child
                  : FushiStaggeredEntrance(index: index, child: child);
            }, childCount: itemCount),
          );
        },
      ),
    );
  }
}

/// 「查看全部」整页：顶栏标题 + [DiscoveryCoverGrid]。横滑行只展示一屏的条目，
/// 点行头「查看全部」推这一页看整组。
///
/// 这是一条新路由，读不到发现页外层的 [ShelfCoverMaterialScope]，所以条目材质
/// 由调用方显式传 [material]（与来源发现页同一种）。
class DiscoveryGridPage extends StatelessWidget {
  const DiscoveryGridPage({
    required this.title,
    required this.itemCount,
    required this.itemBuilder,
    required this.material,
    this.shape = DiscoveryCoverShape.portrait,
    this.titleMaxLines = kShelfCardMetaTitleLines,
    super.key,
  });

  final String title;
  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;
  final ShelfCoverMaterial material;
  final DiscoveryCoverShape shape;
  final int titleMaxLines;

  /// 推一页「查看全部」。
  static Future<void> open(
    BuildContext context, {
    required String title,
    required int itemCount,
    required IndexedWidgetBuilder itemBuilder,
    required ShelfCoverMaterial material,
    DiscoveryCoverShape shape = DiscoveryCoverShape.portrait,
    int titleMaxLines = kShelfCardMetaTitleLines,
  }) {
    return Navigator.push<void>(
      context,
      adaptivePageRoute<void>(
        context: context,
        builder: (_) => DiscoveryGridPage(
          title: title,
          itemCount: itemCount,
          itemBuilder: itemBuilder,
          material: material,
          shape: shape,
          titleMaxLines: titleMaxLines,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return Scaffold(
      backgroundColor: fushiPageBackgroundColor(context),
      appBar: FushiAppBar(title: Text(title)),
      body: ShelfCoverMaterialScope(
        material: material,
        child: CustomScrollView(
          slivers: <Widget>[
            FushiEntranceScope(
              child: DiscoveryCoverGrid(
                itemCount: itemCount,
                itemBuilder: itemBuilder,
                shape: shape,
                titleMaxLines: titleMaxLines,
              ),
            ),
            SliverToBoxAdapter(child: SizedBox(height: tokens.spacing.section)),
          ],
        ),
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
