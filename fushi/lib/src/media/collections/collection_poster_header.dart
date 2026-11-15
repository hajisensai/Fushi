/// 合集详情页的合集信息块（重设计外壳，放在 [MediaPosterDetailLayout] 里）。
///
/// 书 / 漫画只有竖版封面、没有横版背景图，所以不拿竖封面糊成模糊横幅、不压
/// 出血大字，也不装进整宽的大卡片（2026-11-12 用户三轮「重新设计」）。两种排法：
///
/// - [side]（宽屏左栏）：直接铺在页面底色上，从上到下是一张大封面（「正在读」
///   那本，按真实竖封面比例、宽占满左栏，M3E 圆角 + 投影，不倾斜）、合集名
///   大字（最多 3 行）、「共 N 项 · 已读完 x/y」一行小字、标签行（已挂标签 chip
///   + 小号 tonal「编辑标签」）。
/// - 顶部一行（窄屏）：封面（宽约 120）在起始侧，标题 / 统计 / 标签在旁边。
///
/// 背后一团很淡的封面取色径向光晕从左上角散开、不画边界：页面有颜色但不像盒子。
/// 游戏合集的封面用卡盒比例与卡盒材质（[caseMaterial]），与成员卡一致。
///
/// [block]（库页布局为拼贴 / 规整色块时）换成色块语言，与库页色块墙一脉相承：
/// 整块是一张封面取色的高色块（[MediaPosterDetailTheme] 同一取色来源 / HSL
/// 规则，即库墙色块的 `FushiCoverBlockColors`），上半是成员书封扇形（库墙同款
/// 条目材质 [ShelfCoverFrame.stackedCovers]），下面是合集名大字、统计与标签行。
/// 只吃纯值与回调。
library;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/detail/media_detail_kit.dart'
    show MediaDetailCoverFrame, MediaDetailCoverPlaceholder;
import 'package:fushi/src/media/detail/media_poster_detail.dart'
    show MediaPosterDetailLayout, MediaPosterDetailTheme;
import 'package:fushi/src/media/tags/tag_chips.dart';
import 'package:fushi/src/media/video/cover_ui/cover_aspect_probe.dart'
    show CoverAspectProbe;
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/adaptive/shell_style.dart'
    show ShellClip, shellShape;
import 'package:fushi/src/utils/components/fushi_cover_block.dart'
    show FushiCoverBlockSize, fushiCoverBlockShadows;
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_hover_lift.dart';
import 'package:fushi/src/utils/components/fushi_m3e_list_card.dart'
    show FushiM3eShape;
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/components/glass/fushi_expressive_controls.dart'
    show FushiButtonSize;
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart'
    show FushiFilledButton;
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/components/shelf_card_widgets.dart'
    show ShelfCoverFrame, kShelfCoverStackLift;
import 'package:fushi/src/utils/components/shelf_cover_material.dart'
    show ShelfCoverMaterial, ShelfCoverMaterialScope, kShelfGameCaseAspectRatio;
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi_core/fushi_core.dart' show BookTagRow;

/// 窄屏顶部一行的封面宽。
const double _kNarrowCoverWidth = 120;

/// 封面固有比例的夹取范围（条漫长图 / 横跨页不至于把左栏撑变形）。
const double _kCoverAspectMin = 0.55;
const double _kCoverAspectMax = 0.85;
const double _kCoverAspectDefault = 2 / 3;

/// 径向光晕的直径（以起始侧上角为心往外散）。
const double _kGlowExtent = 820;

/// 色块风格扇形里最多画几本（与书架合集卡一致）。
const int _kMaxFanCovers = 4;

/// 色块风格窄屏的扇形宽。
const double _kNarrowFanWidth = 104;

/// 合集信息块（见文件头）。
class CollectionPosterHeader extends StatelessWidget {
  const CollectionPosterHeader({
    required this.title,
    required this.side,
    required this.block,
    required this.stats,
    required this.horizontalPadding,
    required this.tags,
    this.cover,
    this.coverImage,
    this.caseMaterial,
    this.covers = const <Widget>[],
    this.coverMaterial,
    this.onEditTags,
    super.key,
  });

  final String title;

  /// true = 宽屏左栏（宽度由所在栏给定，不自己留页边 / 页头让位）；false =
  /// 窄屏顶部一行（自己留 [horizontalPadding] 与页头让位）。
  final bool side;

  /// true = 色块语言（库页布局为拼贴 / 规整色块），见文件头。
  final bool block;

  /// 色块风格扇形用的成员封面（最前那本在首位）。
  final List<Widget> covers;

  /// 色块风格扇形的条目材质（书 / 漫画光面书皮、游戏卡盒），null = 光面书皮。
  final ShelfCoverMaterial? coverMaterial;

  /// 「共 N 项 · 已读完 x/y」。
  final String stats;

  /// 页面左右页边：窄屏的块边距，光晕也按它往页面角上推。
  final double horizontalPadding;

  /// 封面内容（不含外框）；null = 合集图标占位。
  final Widget? cover;

  /// [cover] 那张图的图片源：书 / 漫画按它的固有比例定封面框（整张显示全）。
  final ImageProvider? coverImage;

  /// 非 null = 卡盒类封面（游戏）：固定卡盒比例 + 该材质，与成员卡一致。
  final ShelfCoverMaterial? caseMaterial;

  final List<BookTagRow> tags;
  final VoidCallback? onEditTags;

  @override
  Widget build(BuildContext context) {
    final ({bool wide, double topInset}) metrics =
        MediaPosterDetailLayout.metricsOf(context);
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final double top = metrics.topInset + tokens.spacing.gap;
    if (block) {
      final Widget tile = _buildBlockTile(context);
      return side
          ? tile
          : Padding(
              padding: EdgeInsetsDirectional.fromSTEB(
                horizontalPadding,
                top,
                horizontalPadding,
                0,
              ),
              child: tile,
            );
    }
    final Widget body = side
        ? _buildSide(context)
        : Padding(
            padding: EdgeInsetsDirectional.fromSTEB(
              horizontalPadding,
              top,
              horizontalPadding,
              0,
            ),
            child: _buildRow(context),
          );
    if (isEinkTheme(context)) return body;
    // 光晕心落在页面起始侧上角：左栏 / 顶部块的上沿在页头让位之下、起始边
    // 在页边之内，往回推这两段。
    final double backTop = side ? top : 0;
    final double backStart = horizontalPadding;
    return Stack(
      clipBehavior: Clip.none,
      children: <Widget>[
        PositionedDirectional(
          start: -backStart - _kGlowExtent / 2,
          top: -backTop - _kGlowExtent / 2,
          width: _kGlowExtent,
          height: _kGlowExtent,
          child: const IgnorePointer(child: _CoverGlow()),
        ),
        body,
      ],
    );
  }

  // ── 色块风格：封面取色的整块高色块 ──
  Widget _buildBlockTile(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final bool eink = isEinkTheme(context);
    return MediaPosterDetailTheme(
      image: coverImage,
      fallbackKey: title,
      child: Builder(
        builder: (BuildContext context) {
          final ColorScheme cs = Theme.of(context).colorScheme;
          return DecoratedBox(
            key: const ValueKey<String>('collection_detail_header_block'),
            decoration: ShapeDecoration(
              color: cs.surface,
              shape: shellShape(
                context,
                FushiM3eShape.containerLargeRadius,
                side: eink ? BorderSide(color: cs.outline) : BorderSide.none,
              ),
              shadows: eink
                  ? null
                  : fushiCoverBlockShadows(FushiCoverBlockSize.regular),
            ),
            child: Padding(
              padding: EdgeInsets.all(
                side ? tokens.spacing.section * 0.875 : tokens.spacing.card,
              ),
              child: side
                  ? _buildBlockColumn(context)
                  : _buildBlockRow(context),
            ),
          );
        },
      ),
    );
  }

  Widget _buildBlockColumn(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Center(
            child: FushiStaggeredEntrance(
              index: 0,
              child: _buildFan(
                (constraints.maxWidth * 0.66).clamp(120.0, 240.0),
              ),
            ),
          ),
          SizedBox(height: tokens.spacing.section),
          FushiStaggeredEntrance(index: 1, child: _buildTitle(context, true)),
          SizedBox(height: tokens.spacing.gap),
          FushiStaggeredEntrance(index: 2, child: _buildStats(context)),
          if (_hasTagRow) ...<Widget>[
            SizedBox(height: tokens.spacing.card),
            FushiStaggeredEntrance(index: 3, child: _buildTagRow(context)),
          ],
        ],
      ),
    );
  }

  Widget _buildBlockRow(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        FushiStaggeredEntrance(index: 0, child: _buildFan(_kNarrowFanWidth)),
        SizedBox(width: tokens.spacing.card),
        Expanded(
          child: FushiStaggeredEntrance(
            index: 1,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                _buildTitle(context, false),
                SizedBox(height: tokens.spacing.gap / 2),
                _buildStats(context),
                if (_hasTagRow) ...<Widget>[
                  SizedBox(height: tokens.spacing.rowVertical),
                  _buildTagRow(context),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// 成员书封扇形：与书架合集卡同一个 [ShelfCoverFrame]（条目材质下按真实后续
  /// 成员封面转开，只有一本时就是单张）。悬停时扇形再转开一点（[FushiHoverLift]，
  /// [ShelfCoverFrame] 读 `liftedOf`）。
  Widget _buildFan(double width) {
    final List<Widget> shown = covers.take(_kMaxFanCovers).toList();
    final ShelfCoverMaterial material =
        coverMaterial ?? ShelfCoverMaterial.glossyBook;
    final double aspect = material == ShelfCoverMaterial.gameCase
        ? kShelfGameCaseAspectRatio
        : _kCoverAspectDefault;
    final Widget frame = SizedBox(
      key: const ValueKey<String>('collection_detail_header_covers'),
      width: width,
      height: width / aspect + (shown.length > 1 ? kShelfCoverStackLift : 0),
      child: ShelfCoverMaterialScope(
        material: material,
        child: ShelfCoverFrame(
          stackedBehind: shown.length > 1 ? shown[1] : null,
          stackedCovers: shown.skip(1).toList(growable: false),
          child: shown.isEmpty
              ? const MediaDetailCoverPlaceholder(icon: FushiIcons.collection)
              : shown.first,
        ),
      ),
    );
    return FushiHoverLift(
      builder: (BuildContext context, bool hovering) => frame,
    );
  }

  // ── 宽屏左栏：大封面 / 名称 / 统计 / 标签，竖排 ──
  Widget _buildSide(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          FushiStaggeredEntrance(
            index: 0,
            child: _buildCover(constraints.maxWidth, large: true),
          ),
          SizedBox(height: tokens.spacing.section * 0.75),
          FushiStaggeredEntrance(index: 1, child: _buildTitle(context, true)),
          SizedBox(height: tokens.spacing.gap),
          FushiStaggeredEntrance(index: 2, child: _buildStats(context)),
          if (_hasTagRow) ...<Widget>[
            SizedBox(height: tokens.spacing.card),
            FushiStaggeredEntrance(index: 3, child: _buildTagRow(context)),
          ],
        ],
      ),
    );
  }

  // ── 窄屏顶部一行：封面 | 标题 / 统计 / 标签 ──
  Widget _buildRow(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        FushiStaggeredEntrance(
          index: 0,
          child: _buildCover(_kNarrowCoverWidth, large: false),
        ),
        SizedBox(width: tokens.spacing.rowHorizontal),
        Expanded(
          child: FushiStaggeredEntrance(
            index: 1,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                _buildTitle(context, false),
                SizedBox(height: tokens.spacing.gap / 2),
                _buildStats(context),
                if (_hasTagRow) ...<Widget>[
                  SizedBox(height: tokens.spacing.rowVertical),
                  _buildTagRow(context),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildCover(double width, {required bool large}) {
    final ShelfCoverMaterial? material = caseMaterial;
    final Widget content =
        cover ?? const MediaDetailCoverPlaceholder(icon: FushiIcons.collection);
    final ImageProvider? image = coverImage;
    final Widget frame = material != null
        ? MediaDetailCoverFrame(
            width: width,
            aspectRatio: kShelfGameCaseAspectRatio,
            material: material,
            child: content,
          )
        : image == null
        ? _CoverCard(
            width: width,
            aspect: _kCoverAspectDefault,
            large: large,
            child: content,
          )
        : _CoverAspect(
            image: image,
            builder: (double? probed) => _CoverCard(
              width: width,
              aspect: probed == null || probed <= 0
                  ? _kCoverAspectDefault
                  : probed.clamp(_kCoverAspectMin, _kCoverAspectMax),
              large: large,
              child: content,
            ),
          );
    return FushiHoverLift(
      key: const ValueKey<String>('collection_detail_header_cover'),
      builder: (BuildContext context, bool hovering) => frame,
    );
  }

  Widget _buildTitle(BuildContext context, bool large) {
    final FushiTypography type = context.fushiType;
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Semantics(
      header: true,
      child: Text(
        title,
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
        style: (large ? type.displaySmallEmphasized : type.titleLargeEmphasized)
            .copyWith(color: cs.onSurface, height: 1.12),
      ),
    );
  }

  Widget _buildStats(BuildContext context) => Text(
    stats,
    key: const ValueKey<String>('collection_detail_hero_meta'),
    maxLines: 2,
    overflow: TextOverflow.ellipsis,
    style: context.fushiType.bodyMedium.copyWith(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    ),
  );

  bool get _hasTagRow => onEditTags != null || tags.isNotEmpty;

  /// 标签行：已挂标签 chip（点按 = 编辑）+ 小号 tonal「编辑标签」。
  Widget _buildTagRow(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final VoidCallback? onEditTags = this.onEditTags;
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: tokens.spacing.gap,
      runSpacing: tokens.spacing.gap,
      children: <Widget>[
        for (final BookTagRow tag in tags)
          FushiTagToggleChip(
            label: tag.name,
            color: Color(tag.colorValue),
            state: TagCheckState.all,
            onTap: onEditTags,
          ),
        if (onEditTags != null)
          FushiFilledButton.tonalIcon(
            key: const ValueKey<String>('collection_detail_edit_tags'),
            onPressed: onEditTags,
            size: FushiButtonSize.xs,
            icon: const FushiIcon(FushiIcons.tag),
            label: Text(t.collection_detail_edit_tags),
          ),
      ],
    );
  }
}

/// 书 / 漫画封面：按 [aspect] 定高、M3E 圆角裁切 + 投影，不倾斜。
class _CoverCard extends StatelessWidget {
  const _CoverCard({
    required this.width,
    required this.aspect,
    required this.large,
    required this.child,
  });

  final double width;
  final double aspect;
  final bool large;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final BorderRadius radius = large
        ? FushiM3eShape.cardRadius
        : FushiM3eShape.smallRadius;
    return DecoratedBox(
      decoration: ShapeDecoration(
        shape: shellShape(context, radius),
        shadows: isEinkTheme(context)
            ? null
            : <BoxShadow>[
                BoxShadow(
                  color: Colors.black.withValues(alpha: large ? 0.38 : 0.3),
                  offset: Offset(0, large ? 16 : 8),
                  blurRadius: large ? 40 : 20,
                ),
              ],
      ),
      child: ShellClip(
        radius: radius,
        child: SizedBox(width: width, height: width / aspect, child: child),
      ),
    );
  }
}

/// 探封面固有宽高比（解码前 / 失败时给 null）。
class _CoverAspect extends StatefulWidget {
  const _CoverAspect({required this.image, required this.builder});

  final ImageProvider image;
  final Widget Function(double? aspect) builder;

  @override
  State<_CoverAspect> createState() => _CoverAspectState();
}

class _CoverAspectState extends State<_CoverAspect>
    with CoverAspectProbe<_CoverAspect> {
  @override
  ImageProvider probedImageOf(_CoverAspect widget) => widget.image;

  @override
  bool needsBackdropSeed(double aspect) => false;

  @override
  Widget build(BuildContext context) =>
      widget.builder(coverFailed ? null : coverAspect);
}

/// 封面取色的径向光晕：面板主题（[MediaPosterDetailTheme] 按封面取色）的强调色
/// 从中心往外淡到全透明，不画边界。
class _CoverGlow extends StatelessWidget {
  const _CoverGlow();

  @override
  Widget build(BuildContext context) {
    final Color accent = Theme.of(context).colorScheme.primary;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: RadialGradient(
          colors: <Color>[
            accent.withValues(alpha: 0.2),
            accent.withValues(alpha: 0.08),
            accent.withValues(alpha: 0),
          ],
          stops: const <double>[0, 0.45, 1],
        ),
      ),
    );
  }
}
