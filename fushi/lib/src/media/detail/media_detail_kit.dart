/// 作品详情页的 **M3E 共享骨架**（视频系列 / 媒体服务器作品 / 发现页与在线源作品
/// ——书、漫画、视频、小说——同一套视觉）。
///
/// 只吃纯值与回调，不知道数据来自 Drift 行、远端 DTO 还是扩展运行时：
/// - [MediaDetailBackdrop]：大背景（fanart / 封面模糊 + 色晕 scrim，渐隐到页面底色）；
/// - [MediaDetailHero]：背景 + 2:3 封面卡 + Display 级标题 + 原名 + 元信息 chip 行 +
///   主操作按钮组 + 页脚（简介 / 进度）；宽屏封面在左，窄屏上下堆叠居中；
/// - [MediaDetailActionBar] / [MediaDetailPrimaryButton] / [MediaDetailSecondaryButton] /
///   [MediaDetailMoreButton]：主操作按钮组（filled 大号 + tonal + 「⋯」菜单），进行中
///   时主按钮换波浪进度；
/// - [MediaDetailSynopsis]：可展开简介（spring 展开，超出行数才出「展开」）；
/// - [MediaDetailSectionHeader]：区块标题 + 计数胶囊 + 行尾动作；
/// - [MediaDetailItemRow]：章节 / 分集的分段列表行（序号胶囊、观看进度、已看对勾、
///   续看高亮、下载状态、多选）；
/// - [MediaDetailCastStrip]：人物横滑圆形头像卡；
/// - [MediaDetailLayout]：宽屏两栏（左 hero 信息独立滚动 = sticky，右正文），窄屏
///   单列；
/// - [MediaDetailSkeleton]：加载骨架。
///
/// Material 设计系统一律 M3 Expressive（饱和 container 色块、形状分级、spring 动效）；
/// Apple 设计系统走系统语义色与胶囊；墨水屏去掉背景图与色晕、改描边。动效时长全部
/// 取 `context.fushiMotion`（墨水屏 / 减弱动态效果自动归零）。
library;

import 'dart:async';
import 'dart:ui' as ui;
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart' show FushiFocusId;
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart'
    show FushiToolbarItem, FushiTopBarOverflowFit;
import 'package:fushi/src/utils/components/fushi_m3e_feedback.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/components/shelf_cover_material.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// 宽度 ≥ 它时 [MediaDetailLayout] 无条件切两栏。
const double kMediaDetailTwoPaneMinWidth = 1080;

/// 横屏（宽 > 高）且宽度 ≥ 它时也切两栏：手机横屏 / 平板横屏单列时整屏只剩 hero，
/// 章节 / 分集全在首屏之下。
const double kMediaDetailLandscapeTwoPaneMinWidth = 600;

/// 两栏布局左栏（hero 信息）宽度上限；实际按窗口宽的 40% 取，夹在
/// [kMediaDetailSidePaneMinWidth] 与它之间。
const double kMediaDetailSidePaneWidth = 420;

/// 两栏布局左栏宽度下限。
const double kMediaDetailSidePaneMinWidth = 320;

/// [MediaDetailHero] 宽度 ≥ 它时封面在左、信息在右。
const double kMediaDetailHeroWideMinWidth = 640;

// ---------------------------------------------------------------------------
// 背景
// ---------------------------------------------------------------------------

/// 详情页大背景：图模糊铺满 + 色晕 scrim，自上而下渐隐到页面底色（surface），
/// 让压在上面的文字直接用 onSurface 系颜色、明暗主题都可读。
///
/// [image] 变化（多张 fanart 轮换）时交叉淡入；[imageKey] 给轮换下标之类的
/// 稳定身份（缺省用 [image] 本身）。墨水屏不画图与色晕。
/// 详情页顶栏标题的淡入阈值（逻辑像素）：hero 大标题大致滚到顶栏胶囊下面的位置
/// （[FushiPageScaffold.revealTitleAfterScroll]）。窄屏紧凑 hero 的标题在小封面
/// 旁、hero 顶端；此前恒显示，顶栏与 hero 同屏出现两个相同标题。
const double kMediaDetailTitleRevealOffset = 120;

class MediaDetailBackdrop extends StatelessWidget {
  const MediaDetailBackdrop({
    this.image,
    this.imageKey,
    this.blurSigma = 28,
    this.artBand = false,
    super.key,
  });

  final ImageProvider? image;
  final Object? imageKey;

  /// 露画面（[blurSigma] 为 0）时只把画面画在顶部一条与宽度等高的带里、带内渐隐
  /// 到底色，而不是铺满整块。只给**窄式居中 hero**（手机单列：封面 + chip + 按钮
  /// + 简介叠成一长条）传 true：横版 fanart 铺满竖长容器会被 cover 放大四五倍、
  /// 再被起始侧底色冲成白雾（反馈「看不到背景插画」）。
  ///
  /// 判据由调用方按布局显式给出，不按容器宽高比猜：两栏整页背景在竖屏大屏 /
  /// 桌面窄高窗里同样高 > 宽，宽式 hero 展开长简介后也会高 > 宽——按比例判会
  /// 误切带，展开 / 收起简介时背景还会在两套画法之间跳变。
  final bool artBand;

  /// 模糊强度。竖版封面垫底要重模糊（只留色彩）；横版 fanart 传 0 = 不模糊、
  /// 画面原样露出（BUG-3190：fanart 被 16 的模糊 + 72% 底色压成一片色雾，用户看
  /// 来就是「海报没了 / 被压在毛玻璃后面」）。0 时 scrim 也换成「露画面」的一套：
  /// 上半基本透明，起始侧（两栏布局的信息栏 / 单列 hero 的文字）与底部才落到底色。
  final double blurSigma;

  /// [AnimatedSwitcher] 的铺满版布局：新旧子项都拿紧约束（见 BUG-3355）。
  static Widget _expandedSwitcherLayout(
    Widget? currentChild,
    List<Widget> previousChildren,
  ) => Stack(
    fit: StackFit.expand,
    children: <Widget>[...previousChildren, ?currentChild],
  );

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool eink = isEinkTheme(context);
    final bool apple = isGlassDesign(context);
    final FushiMotionScheme motion = context.fushiMotion;
    final ImageProvider? image = eink ? null : this.image;
    final Color base = cs.surface;
    final bool showArt = image != null && blurSigma <= 0;
    final Widget? art = image == null
        ? null
        : AnimatedSwitcher(
            duration: motion.effectsSlow.duration,
            // BUG-3355：默认 layoutBuilder 是 `Stack(alignment: center)`，子项拿到
            // 的是**松**约束——Image 于是按自己的宽高比缩成「整高、居中」的一条
            // 竖图（BoxFit.cover 在松约束下不生效），两栏详情页顶部就剩窗口中间
            // 一块模糊竖条，用户看来是「莫名的毛玻璃」。背景必须铺满，交叉淡入
            // 的新旧两层都撑满整块。
            layoutBuilder: _expandedSwitcherLayout,
            child: KeyedSubtree(
              key: ValueKey<Object>(imageKey ?? image),
              child: showArt
                  ? Image(
                      image: image,
                      fit: BoxFit.cover,
                      alignment: Alignment.topCenter,
                      gaplessPlayback: true,
                      errorBuilder: (_, _, _) => const SizedBox.shrink(),
                    )
                  // ClipRect：模糊会把封面边缘的颜色向外晕开，ImageFiltered 默认
                  // 不裁剪，晕出的部分落在 hero 底边之外、压在下方内容上，看起来
                  // 就是 hero 底部一条带阴影的硬边（渐隐 scrim 只盖得住框内）。
                  : ClipRect(
                      child: ImageFiltered(
                        imageFilter: ui.ImageFilter.blur(
                          sigmaX: blurSigma,
                          sigmaY: blurSigma,
                          tileMode: TileMode.decal,
                        ),
                        child: Image(
                          image: image,
                          fit: BoxFit.cover,
                          gaplessPlayback: true,
                          errorBuilder: (_, _, _) => const SizedBox.shrink(),
                        ),
                      ),
                    ),
            ),
          );
    return IgnorePointer(
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          // 窄式居中 hero（[artBand]）只把画面放进顶部一条与宽度等高的带里，带内
          // 渐隐到底色；hero 矮于宽度时带高取 hero 高，渐隐仍落到底边。
          final double width = constraints.maxWidth;
          final double height = constraints.maxHeight;
          if (artBand &&
              art != null &&
              showArt &&
              width.isFinite &&
              height.isFinite) {
            return _buildArtBand(
              art: art,
              base: base,
              bandHeight: math.min(width, height),
            );
          }
          return _buildFull(
            context,
            art: art,
            base: base,
            showArt: showArt,
            eink: eink,
            apple: apple,
          );
        },
      ),
    );
  }

  Widget _buildArtBand({
    required Widget art,
    required Color base,
    required double bandHeight,
  }) {
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        ColoredBox(color: base),
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: bandHeight,
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              art,
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    stops: const <double>[0, 0.5, 1],
                    colors: <Color>[
                      base.withValues(alpha: 0.08),
                      base.withValues(alpha: 0.4),
                      base,
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildFull(
    BuildContext context, {
    required Widget? art,
    required Color base,
    required bool showArt,
    required bool eink,
    required bool apple,
  }) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final ImageProvider? image = art == null ? null : this.image;
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        ColoredBox(color: base),
        ?art,
        if (showArt) ...<Widget>[
          // 露画面：起始侧一道底色把信息栏 / hero 文字托住，画面其余部分原样
          // 露出；再自上而下落到底色，与下方内容无缝。
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: AlignmentDirectional.centerStart,
                end: AlignmentDirectional.centerEnd,
                stops: const <double>[0, 0.28, 0.6],
                colors: <Color>[
                  base.withValues(alpha: 0.82),
                  base.withValues(alpha: 0.45),
                  base.withValues(alpha: 0),
                ],
              ),
            ),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                stops: const <double>[0, 0.45, 0.8, 1],
                colors: <Color>[
                  base.withValues(alpha: 0.05),
                  base.withValues(alpha: 0.35),
                  base.withValues(alpha: 0.9),
                  base,
                ],
              ),
            ),
          ),
        ] else if (!eink) ...<Widget>[
          // 色晕：起始侧上角一团 primaryContainer（Apple 用强调色淡染），
          // 让没有图 / 图很暗时 hero 也带主题色气质。
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: AlignmentDirectional.topStart,
                radius: 1.25,
                colors: <Color>[
                  (apple ? cs.primary : cs.primaryContainer).withValues(
                    alpha: apple ? 0.22 : 0.55,
                  ),
                  (apple ? cs.primary : cs.primaryContainer).withValues(
                    alpha: 0,
                  ),
                ],
              ),
            ),
          ),
          // 可读性 scrim：上半透出画面，底部完全落到页面底色，与下方内容无缝。
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                stops: const <double>[0, 0.55, 1],
                colors: <Color>[
                  base.withValues(alpha: image == null ? 0 : 0.30),
                  base.withValues(alpha: image == null ? 0.2 : 0.72),
                  base,
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 元信息 chip
// ---------------------------------------------------------------------------

/// hero 元信息 chip 的语气：neutral = 事实（年份 / 集数 / 时长），primary /
/// secondary / tertiary = 需要被看见的状态（评分、连载中、已在书架）。
enum MediaDetailChipTone { neutral, primary, secondary, tertiary, error }

/// 一枚元信息 chip（纯值）。
@immutable
class MediaDetailChip {
  const MediaDetailChip(
    this.label, {
    this.icon,
    this.tone = MediaDetailChipTone.neutral,
    this.key,
  });

  final String label;
  final IconData? icon;
  final MediaDetailChipTone tone;
  final Key? key;
}

/// 元信息 chip 行（年份 · 集数 · 时长 · 评分 / 作者 · 来源 · 状态）。
class MediaDetailChipRow extends StatelessWidget {
  const MediaDetailChipRow({
    required this.chips,
    this.alignment = WrapAlignment.start,
    super.key,
  });

  final List<MediaDetailChip> chips;
  final WrapAlignment alignment;

  @override
  Widget build(BuildContext context) {
    if (chips.isEmpty) return const SizedBox.shrink();
    return Wrap(
      alignment: alignment,
      spacing: 8,
      runSpacing: 8,
      children: <Widget>[
        for (final MediaDetailChip chip in chips)
          MediaDetailChipView(key: chip.key, chip: chip),
      ],
    );
  }
}

/// 单枚元信息 chip：M3E 小件圆角 8 的饱和色块（neutral = surfaceContainerHighest），
/// Apple 系统填充色胶囊，墨水屏描边。
class MediaDetailChipView extends StatelessWidget {
  const MediaDetailChipView({required this.chip, super.key});

  final MediaDetailChip chip;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool apple = isGlassDesign(context);
    final bool eink = isEinkTheme(context);
    final (Color fill, Color fg) = _colors(context, cs, apple, eink);
    final IconData? icon = chip.icon;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(apple ? 999 : 8),
        border: eink ? Border.all(color: cs.outline) : null,
      ),
      child: Padding(
        padding: EdgeInsetsDirectional.fromSTEB(
          icon == null ? 12 : 8,
          6,
          12,
          6,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (icon != null) ...<Widget>[
              FushiIcon(icon, size: 16, color: fg),
              const SizedBox(width: 6),
            ],
            Flexible(
              child: Text(
                chip.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.fushiType.labelLargeEmphasized.tabular.copyWith(
                  color: fg,
                  height: 1.2,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  (Color, Color) _colors(
    BuildContext context,
    ColorScheme cs,
    bool apple,
    bool eink,
  ) {
    if (eink) return (cs.surface, cs.onSurface);
    if (apple) {
      final FushiAppleColors palette = appleColorsOf(context);
      return switch (chip.tone) {
        MediaDetailChipTone.neutral => (palette.tertiaryFill, palette.label),
        MediaDetailChipTone.error => (
          cs.error.withValues(alpha: 0.16),
          cs.error,
        ),
        _ => (cs.primary.withValues(alpha: 0.16), cs.primary),
      };
    }
    return switch (chip.tone) {
      MediaDetailChipTone.neutral => (
        cs.surfaceContainerHighest,
        cs.onSurfaceVariant,
      ),
      MediaDetailChipTone.primary => (
        cs.primaryContainer,
        cs.onPrimaryContainer,
      ),
      MediaDetailChipTone.secondary => (
        cs.secondaryContainer,
        cs.onSecondaryContainer,
      ),
      MediaDetailChipTone.tertiary => (
        cs.tertiaryContainer,
        cs.onTertiaryContainer,
      ),
      MediaDetailChipTone.error => (cs.errorContainer, cs.onErrorContainer),
    };
  }
}

// ---------------------------------------------------------------------------
// hero
// ---------------------------------------------------------------------------

/// 详情页封面卡：与库页同一个 [ShelfCoverFrame]（2026-10-25 库页定版「条目
/// 材质」）。[material] 非 null 时内部包 [ShelfCoverMaterialScope]，书 / 漫画 =
/// 光面书皮、视频 = 光面海报、游戏 = 透明卡盒，与该条目在库页上的样子一致；
/// null 退回无材质的封面框（墨水屏下材质也整体退场，走描边框）。
///
/// 尺寸恒为 [width] × `width / aspectRatio`：材质只画在这个盒子里（接触阴影探出
/// 底边几像素、不参与布局），hero 的排版不随材质变。
class MediaDetailCoverFrame extends StatelessWidget {
  const MediaDetailCoverFrame({
    required this.child,
    required this.width,
    this.aspectRatio = 2 / 3,
    this.material,
    super.key,
  });

  final Widget child;
  final double width;

  /// 宽 / 高；视频横版缩略图可传 16 / 9，游戏卡盒传 [kShelfGameCaseAspectRatio]。
  final double aspectRatio;

  /// 封面的条目材质；null = 不套材质。
  final ShelfCoverMaterial? material;

  @override
  Widget build(BuildContext context) {
    final Widget frame = SizedBox(
      width: width,
      height: width / aspectRatio,
      child: ShelfCoverFrame(child: child),
    );
    final ShelfCoverMaterial? m = material;
    return m == null
        ? frame
        : ShelfCoverMaterialScope(material: m, child: frame);
  }
}

/// 封面缺失时的占位：secondaryContainer 色块 + 域图标。
class MediaDetailCoverPlaceholder extends StatelessWidget {
  const MediaDetailCoverPlaceholder({this.icon = FushiIcons.image, super.key});

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return ColoredBox(
      color: cs.secondaryContainer,
      child: Center(
        child: FushiIcon(icon, size: 40, color: cs.onSecondaryContainer),
      ),
    );
  }
}

/// 作品详情 hero（M3E）：[MediaDetailBackdrop] 大背景 + 封面卡 + 标题区 + 主操作 +
/// 页脚。高度随内容（不再钳死），长标题 / 长简介不会撑爆。
///
/// - 宽（≥ [kMediaDetailHeroWideMinWidth]）：封面在起始侧、信息靠底对齐；
/// - 窄：封面居中在上，信息居中；
/// - 在 [MediaDetailLayout] 的两栏左栏里：恒为窄式堆叠，且不画自己的背景（整页背景
///   由布局画在两栏后面）。
///
/// 进场：封面 / 标题区 / 操作区三段错峰（[FushiStaggeredEntrance]）。
class MediaDetailHero extends StatelessWidget {
  const MediaDetailHero({
    required this.title,
    super.key,
    this.cover,
    this.coverAspectRatio = 2 / 3,
    this.coverMaterial,
    this.backdrop,
    this.backdropKey,
    this.backdropBlur = 28,
    this.titleWidget,
    this.overline,
    this.originalTitle,
    this.chips = const <MediaDetailChip>[],
    this.actions,
    this.footer,
    this.titleKey,
  });

  final String title;

  /// 封面内容（各域自己的取图组件）；null = 不放封面卡。
  final Widget? cover;
  final double coverAspectRatio;

  /// 封面卡的条目材质（见 [MediaDetailCoverFrame.material]）；null = 不套材质。
  final ShelfCoverMaterial? coverMaterial;

  /// 背景图（fanart 优先，没有就传封面——模糊后垫底）。
  final ImageProvider? backdrop;
  final Object? backdropKey;
  final double backdropBlur;

  /// 替代文字标题的组件（如标题 logo）；null = Display 级文字标题。
  final Widget? titleWidget;

  /// 标题上方的小字（放送日期 / 来源名）。
  final String? overline;

  /// 原名；与 [title] 相同或为空时不占行。
  final String? originalTitle;

  final List<MediaDetailChip> chips;

  /// 主操作区（通常是 [MediaDetailActionBar]）。
  final Widget? actions;

  /// 操作区下方（简介 / 进度 / 标签）。
  final Widget? footer;

  final Key? titleKey;

  /// [context] 是否在紧凑 hero（窄屏单列 / 两栏左栏）的操作区或页脚里：页脚据此
  /// 调整简介 / 标签的排法。
  static bool isCompact(BuildContext context) =>
      _MediaDetailHeroAlignScope.compactOf(context);

  @override
  Widget build(BuildContext context) {
    final bool inSidePane = MediaDetailLayout.isSidePane(context);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool wide =
            !inSidePane &&
            constraints.maxWidth * FushiAppUiScale.of(context) >=
                kMediaDetailHeroWideMinWidth;
        final FushiDesignTokens tokens = FushiDesignTokens.of(context);
        final double page = tokens.spacing.page;
        final Widget content = Padding(
          padding: EdgeInsets.fromLTRB(
            page,
            MediaDetailLayout.heroTopInset(context) +
                (wide ? tokens.spacing.section * 1.5 : tokens.spacing.section),
            page,
            tokens.spacing.section,
          ),
          child: wide
              ? _buildWide(context)
              : _buildCompact(context, sidePane: inSidePane),
        );
        if (inSidePane) return content;
        return Stack(
          children: <Widget>[
            Positioned.fill(
              child: MediaDetailBackdrop(
                image: backdrop,
                imageKey: backdropKey,
                blurSigma: backdropBlur,
                artBand: !wide,
              ),
            ),
            content,
          ],
        );
      },
    );
  }

  Widget _buildWide(BuildContext context) {
    final Widget? cover = this.cover;
    final Widget info = _buildInfo(context, centered: false, wide: true);
    if (cover == null) return info;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: <Widget>[
        FushiStaggeredEntrance(
          index: 0,
          child: MediaDetailCoverFrame(
            key: const ValueKey<String>('media-detail-cover'),
            width: coverAspectRatio < 1 ? 208 : 320,
            aspectRatio: coverAspectRatio,
            material: coverMaterial,
            child: cover,
          ),
        ),
        const SizedBox(width: 28),
        Expanded(child: info),
      ],
    );
  }

  /// 窄屏单列与两栏左栏：见 [MediaDetailCompactHero]。
  Widget _buildCompact(BuildContext context, {required bool sidePane}) {
    return MediaDetailCompactHero(
      cover: cover,
      coverAspectRatio: coverAspectRatio,
      coverMaterial: coverMaterial,
      heading: _buildHeading(
        context,
        centered: false,
        titleStyle: MediaDetailCompactHero.titleStyleOf(context),
        chipGap: 10,
      ),
      actions: actions,
      footer: footer,
    );
  }

  /// 来源小字 + 标题 + 原名 + chip 行。
  Widget _buildHeading(
    BuildContext context, {
    required bool centered,
    required TextStyle titleStyle,
    double chipGap = 14,
  }) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final FushiTypography type = context.fushiType;
    final String? overline = this.overline?.trim();
    final String? originalTitle = this.originalTitle?.trim();
    final TextAlign align = centered ? TextAlign.center : TextAlign.start;
    final CrossAxisAlignment cross = centered
        ? CrossAxisAlignment.center
        : CrossAxisAlignment.start;
    return Column(
      crossAxisAlignment: cross,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (overline != null && overline.isNotEmpty) ...<Widget>[
          Text(
            overline,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: align,
            style: type.labelLargeEmphasized.copyWith(color: cs.primary),
          ),
          const SizedBox(height: 6),
        ],
        titleWidget ??
            Text(
              title,
              key: titleKey,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              textAlign: align,
              style: titleStyle.copyWith(color: cs.onSurface, height: 1.15),
            ),
        if (originalTitle != null &&
            originalTitle.isNotEmpty &&
            originalTitle != title) ...<Widget>[
          const SizedBox(height: 6),
          Text(
            originalTitle,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: align,
            style: type.titleMedium.copyWith(color: cs.onSurfaceVariant),
          ),
        ],
        if (chips.isNotEmpty) ...<Widget>[
          SizedBox(height: chipGap),
          MediaDetailChipRow(
            chips: chips,
            alignment: centered ? WrapAlignment.center : WrapAlignment.start,
          ),
        ],
      ],
    );
  }

  Widget _buildInfo(
    BuildContext context, {
    required bool centered,
    required bool wide,
  }) {
    final FushiTypography type = context.fushiType;
    final CrossAxisAlignment cross = centered
        ? CrossAxisAlignment.center
        : CrossAxisAlignment.start;
    return Column(
      crossAxisAlignment: cross,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        FushiStaggeredEntrance(
          index: 1,
          child: _buildHeading(
            context,
            centered: centered,
            titleStyle: wide
                ? type.displaySmallEmphasized
                : type.headlineMediumEmphasized,
          ),
        ),
        if (actions != null) ...<Widget>[
          const SizedBox(height: 20),
          FushiStaggeredEntrance(
            index: 2,
            child: _MediaDetailHeroAlignScope(
              centered: centered,
              child: actions!,
            ),
          ),
        ],
        if (footer != null) ...<Widget>[
          const SizedBox(height: 20),
          FushiStaggeredEntrance(
            index: 3,
            child: Align(
              alignment: centered
                  ? Alignment.topCenter
                  : AlignmentDirectional.topStart,
              child: footer,
            ),
          ),
        ],
      ],
    );
  }
}

/// 紧凑 hero 的排法（窄屏单列 / 两栏左栏共用，各域 hero 都走这一份）：小封面在
/// 起始侧、[heading]（来源 / 标题 / chip）在旁边，[actions] 与 [footer] 占满整宽。
/// 首屏要留给正文（章节 / 分集）和简介，大封面居中堆叠会把它们整个挤出首屏
/// （2026-10 详情页重设计）。
///
/// 子树里 [MediaDetailActionBar] 自动改成「主按钮占满剩余宽度 + 次按钮收成图标」，
/// [MediaDetailSynopsis] 默认折叠成两行（左栏五行）；页脚可用
/// [MediaDetailHero.isCompact] 判断自己在不在紧凑 hero 里。
class MediaDetailCompactHero extends StatelessWidget {
  const MediaDetailCompactHero({
    required this.heading,
    super.key,
    this.cover,
    this.coverAspectRatio = 2 / 3,
    this.coverMaterial,
    this.coverKey = const ValueKey<String>('media-detail-cover'),
    this.actions,
    this.footer,
  });

  final Widget heading;

  /// 封面内容（不含外框，由这里套 [MediaDetailCoverFrame]）；null = 不放封面。
  final Widget? cover;
  final double coverAspectRatio;

  /// 封面卡的条目材质（见 [MediaDetailCoverFrame.material]）；null = 不套材质。
  final ShelfCoverMaterial? coverMaterial;
  final Key coverKey;
  final Widget? actions;
  final Widget? footer;

  /// 紧凑 hero 的标题字号：左栏 Headline S，窄屏 Title L（都取 Emphasized）。
  static TextStyle titleStyleOf(BuildContext context) =>
      MediaDetailLayout.isSidePane(context)
      ? context.fushiType.headlineSmallEmphasized
      : context.fushiType.titleLargeEmphasized;

  @override
  Widget build(BuildContext context) {
    final bool sidePane = MediaDetailLayout.isSidePane(context);
    final Widget? cover = this.cover;
    final double coverWidth = coverAspectRatio < 1
        ? (sidePane ? 112 : 96)
        : (sidePane ? 176 : 148);
    final Widget heading = FushiStaggeredEntrance(
      index: 1,
      child: this.heading,
    );
    return _MediaDetailHeroAlignScope(
      centered: false,
      compact: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (cover == null)
            heading
          else
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                FushiStaggeredEntrance(
                  index: 0,
                  child: MediaDetailCoverFrame(
                    key: coverKey,
                    width: coverWidth,
                    aspectRatio: coverAspectRatio,
                    material: coverMaterial,
                    child: cover,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(child: heading),
              ],
            ),
          if (actions != null) ...<Widget>[
            const SizedBox(height: 16),
            FushiStaggeredEntrance(index: 2, child: actions!),
          ],
          if (footer != null) ...<Widget>[
            const SizedBox(height: 16),
            FushiStaggeredEntrance(index: 3, child: footer!),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 主操作按钮组
// ---------------------------------------------------------------------------

/// 主操作按钮组：主按钮（filled 大号）+ 次按钮（tonal）+ 「⋯」。窄屏换行；
/// [alignment] 让窄式 hero 居中。
class MediaDetailActionBar extends StatelessWidget {
  const MediaDetailActionBar({
    required this.primary,
    this.secondary = const <Widget>[],
    this.more,
    this.alignment,
    super.key,
  });

  final Widget primary;
  final List<Widget> secondary;
  final Widget? more;

  /// null = 跟随所在 hero（窄式居中、宽式起始侧；不在 hero 里时起始侧）。
  final WrapAlignment? alignment;

  @override
  Widget build(BuildContext context) {
    // 单列详情页的悬浮按钮按主按钮的实际位置决定显隐（[_MediaDetailFabHost]）。
    final GlobalKey? anchor = _MediaDetailFabAnchorScope.of(context);
    final Widget primary = anchor == null
        ? this.primary
        : KeyedSubtree(key: anchor, child: this.primary);
    if (alignment == null && _MediaDetailHeroAlignScope.compactOf(context)) {
      return _buildCompact(primary);
    }
    final WrapAlignment resolved =
        alignment ??
        (_MediaDetailHeroAlignScope.centeredOf(context)
            ? WrapAlignment.center
            : WrapAlignment.start);
    return Wrap(
      key: const ValueKey<String>('media-detail-actions'),
      alignment: resolved,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 8,
      runSpacing: 8,
      children: <Widget>[primary, ...secondary, ?more],
    );
  }

  /// 紧凑 hero：主按钮吃掉次按钮（紧凑下一律是图标按钮）之外的整行宽度，「⋯」
  /// 拿剩下的空间自己按宽度决定平铺几个；放不下最小主按钮时主按钮独占一行。
  Widget _buildCompact(Widget primary) {
    const double gap = 8;
    const double iconExtent = 56;
    const double minPrimaryWidth = 200;
    final Widget? more = this.more;
    return LayoutBuilder(
      key: const ValueKey<String>('media-detail-actions'),
      builder: (BuildContext context, BoxConstraints constraints) {
        final double reserved =
            secondary.length * (iconExtent + gap) +
            (more == null ? 0 : iconExtent + gap);
        final List<Widget> trailing = <Widget>[
          for (final Widget button in secondary) ...<Widget>[
            const SizedBox(width: gap),
            button,
          ],
          if (more != null) ...<Widget>[
            const SizedBox(width: gap),
            Flexible(
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: more,
              ),
            ),
          ],
        ];
        final double primaryWidth = constraints.maxWidth - reserved;
        if (primaryWidth >= minPrimaryWidth) {
          return Row(
            children: <Widget>[
              SizedBox(width: primaryWidth, child: primary),
              ...trailing,
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            primary,
            if (trailing.isNotEmpty) ...<Widget>[
              const SizedBox(height: gap),
              Row(children: trailing.skip(1).toList(growable: false)),
            ],
          ],
        );
      },
    );
  }
}

/// hero 信息区的对齐（窄式居中 / 宽式起始侧），让操作区跟着对齐。
class _MediaDetailHeroAlignScope extends InheritedWidget {
  const _MediaDetailHeroAlignScope({
    required this.centered,
    required super.child,
    this.compact = false,
  });

  final bool centered;

  /// 紧凑 hero（窄屏单列 / 两栏左栏）：主按钮占满一行剩余宽度，次按钮收成图标。
  final bool compact;

  static bool centeredOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<_MediaDetailHeroAlignScope>()
          ?.centered ??
      false;

  static bool compactOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<_MediaDetailHeroAlignScope>()
          ?.compact ??
      false;

  @override
  bool updateShouldNotify(_MediaDetailHeroAlignScope oldWidget) =>
      centered != oldWidget.centered || compact != oldWidget.compact;
}

/// 主按钮（「继续观看」「开始阅读」「在线阅读」）：M3E filled M 档（56 高）+
/// 按压回弹；[busy] 时图标位换成转圈、按钮禁用；[progress] 非 null 时按钮下方挂
/// 一条波浪进度（下载 / 准备中）。
class MediaDetailPrimaryButton extends StatelessWidget {
  const MediaDetailPrimaryButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    super.key,
    this.buttonKey,
    this.busy = false,
    this.progress,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  /// 落在内部按钮本体上的 key（测试按 key 取 FilledButton / 点按）。
  final Key? buttonKey;
  final bool busy;

  /// 0..1 确定进度；-1 = 不确定进度；null = 不挂进度条。
  final double? progress;

  @override
  Widget build(BuildContext context) {
    final Widget button = FushiPressScale(
      scale: 0.96,
      child: FushiFilledButton.icon(
        key: buttonKey,
        onPressed: busy ? null : onPressed,
        size: FushiButtonSize.m,
        icon: busy
            ? const SizedBox.square(
                dimension: 20,
                child: FushiCircularProgressIndicator(strokeWidth: 2.5),
              )
            : FushiIcon(icon),
        label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
    );
    final double? progress = this.progress;
    if (progress == null) return button;
    return IntrinsicWidth(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          button,
          const SizedBox(height: 8),
          FushiLinearProgressIndicator(value: progress < 0 ? null : progress),
        ],
      ),
    );
  }
}

/// 次按钮（加入书架 / 下载 / 收藏 / 标记已看）：M3E tonal M 档；[selected] 时
/// 图标换实心（「已在书架」）。[iconOnly] = 方形图标按钮 + tooltip。
class MediaDetailSecondaryButton extends StatelessWidget {
  const MediaDetailSecondaryButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    super.key,
    this.buttonKey,
    this.selected = false,
    this.iconOnly = false,
    this.busy = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final Key? buttonKey;
  final bool selected;
  final bool iconOnly;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final Widget glyph = busy
        ? const SizedBox.square(
            dimension: 18,
            child: FushiCircularProgressIndicator(strokeWidth: 2.5),
          )
        : FushiIcon(FushiIcons.resolve(icon, filled: selected));
    if (iconOnly || _MediaDetailHeroAlignScope.compactOf(context)) {
      return FushiIconButtonControl.filledTonal(
        key: buttonKey,
        tooltip: label,
        size: ButtonSizeVariant.medium,
        isSelected: selected,
        onPressed: busy ? null : onPressed,
        icon: glyph,
      );
    }
    return FushiPressScale(
      scale: 0.96,
      child: FushiFilledButton.tonalIcon(
        key: buttonKey,
        onPressed: busy ? null : onPressed,
        size: FushiButtonSize.m,
        icon: glyph,
        label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
    );
  }
}

/// 「⋯」菜单里的一项。
@immutable
class MediaDetailMenuItem {
  const MediaDetailMenuItem({
    required this.icon,
    required this.label,
    required this.onSelected,
    this.enabled = true,
    this.key,
  });

  final IconData icon;
  final String label;
  final VoidCallback onSelected;
  final bool enabled;
  final Key? key;
}

/// 「⋯」更多操作：tonal 图标按钮，点开锚定菜单（在网站打开 / 刷新 / 换源…）。
///
/// 默认按工具栏规则（用户 2026-10-06「默认展开，空间不足才收起」）：
/// [items] 按给出顺序（= 优先级）先全部平铺成图标钮（文字进 tooltip），只有宽度
/// 放不下时才从最低优先级起收进「⋯」。测宽与展开回差复用顶栏同一套
/// [FushiTopBarOverflowFit]，不另写测宽逻辑。
class MediaDetailMoreButton extends StatefulWidget {
  const MediaDetailMoreButton({
    required this.items,
    super.key,
    this.buttonKey,
    this.tooltip,
    this.adaptiveOverflow = true,
  });

  final List<MediaDetailMenuItem> items;

  /// 落在「⋯」按钮上（全部平铺时落在平铺那一组上）。
  final Key? buttonKey;
  final String? tooltip;

  /// 默认 true（工具栏规则）。false 只留给确实要恒收进「⋯」的特殊场合（例如测试旧形态）。
  final bool adaptiveOverflow;

  @override
  State<MediaDetailMoreButton> createState() => _MediaDetailMoreButtonState();
}

/// 详情页图标钮的实际尺寸（[ButtonSizeVariant.medium]）：测宽与实际渲染取同一个值，
/// 不再按顶栏的 48 估（实测 6 个动作 340px 预算全展开需要 376px，会溢出）。
/// 官方 M3E 规格：medium × standard 宽 56。
const double _kInlineButtonExtent = 56;

/// 平铺钮之间的间距（[MediaDetailMoreButton.build] 里的 SizedBox 宽度）。
const double _kInlineButtonGap = 8;

class _MediaDetailMoreButtonState extends State<MediaDetailMoreButton> {
  /// 平铺颗数决策（带展开回差），与 [FushiFloatingTopBar] 同一份实现。
  final FushiTopBarOverflowFit _fit = FushiTopBarOverflowFit();

  /// 在 [maxWidth] 里平铺前几颗。操作区是 Wrap：这组按钮放不进当前行会整组换到
  /// 下一行，所以预算是整行宽，只有一整行都放不下才收进「⋯」。
  int _visibleFor(double maxWidth) {
    final List<MediaDetailMenuItem> items = widget.items;
    if (!widget.adaptiveOverflow) return 0;
    return _fit.visibleFor(
      groups: <List<FushiToolbarItem>>[
        <FushiToolbarItem>[
          for (final MediaDetailMenuItem item in items)
            FushiToolbarItem(
              icon: item.icon,
              label: item.label,
              onPressed: item.onSelected,
            ),
        ],
      ],
      budget: maxWidth,
      // n 颗 = n * 钮宽 + (n - 1) * 间距：槽宽含一个间距，首尾共少一个，
      // 用负的两端内边距抵掉。
      slotWidth: _kInlineButtonExtent + _kInlineButtonGap,
      padding: -_kInlineButtonGap,
    );
  }

  Widget _inlineButton(MediaDetailMenuItem item) => Semantics(
    label: item.label,
    child: FushiIconButtonControl.filledTonal(
      key: item.key,
      tooltip: item.label,
      size: ButtonSizeVariant.medium,
      onPressed: item.enabled ? item.onSelected : null,
      icon: FushiIcon(item.icon),
    ),
  );

  Widget _moreButton(List<MediaDetailMenuItem> hidden) => Builder(
    builder: (BuildContext context) => FushiIconButtonControl.filledTonal(
      key: widget.buttonKey,
      tooltip: widget.tooltip ?? t.common_more_actions,
      size: ButtonSizeVariant.medium,
      onPressed: () => unawaited(_open(context, hidden)),
      icon: const FushiIcon(FushiIcons.moreHoriz),
    ),
  );

  Future<void> _open(
    BuildContext context,
    List<MediaDetailMenuItem> items,
  ) async {
    final RenderObject? box = context.findRenderObject();
    final RenderObject? overlay = Overlay.of(
      context,
    ).context.findRenderObject();
    if (box is! RenderBox || overlay is! RenderBox) return;
    final Rect anchor = Rect.fromPoints(
      box.localToGlobal(Offset(0, box.size.height), ancestor: overlay),
      box.localToGlobal(box.size.bottomRight(Offset.zero), ancestor: overlay),
    );
    final int? index = await showFushiMenu<int>(
      context: context,
      position: RelativeRect.fromRect(anchor, Offset.zero & overlay.size),
      items: <PopupMenuEntry<int>>[
        for (int i = 0; i < items.length; i++)
          PopupMenuItem<int>(
            key: items[i].key,
            value: i,
            enabled: items[i].enabled,
            child: Row(
              children: <Widget>[
                FushiIcon(items[i].icon, size: 20),
                const SizedBox(width: 12),
                Flexible(child: Text(items[i].label)),
              ],
            ),
          ),
      ],
    );
    if (index == null || index < 0 || index >= items.length) return;
    items[index].onSelected();
  }

  @override
  Widget build(BuildContext context) {
    final List<MediaDetailMenuItem> items = widget.items;
    if (items.isEmpty) return const SizedBox.shrink();
    if (!widget.adaptiveOverflow) return _moreButton(items);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final int visible = _visibleFor(constraints.maxWidth);
        final List<MediaDetailMenuItem> shown = items.sublist(0, visible);
        final List<MediaDetailMenuItem> hidden = items.sublist(visible);
        return Row(
          key: hidden.isEmpty ? widget.buttonKey : null,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (int i = 0; i < shown.length; i++) ...<Widget>[
              if (i > 0) const SizedBox(width: _kInlineButtonGap),
              _inlineButton(shown[i]),
            ],
            if (hidden.isNotEmpty) ...<Widget>[
              if (shown.isNotEmpty) const SizedBox(width: _kInlineButtonGap),
              _moreButton(hidden),
            ],
          ],
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// 简介
// ---------------------------------------------------------------------------

/// 可展开简介：收起时 [collapsedLines] 行，超出至少两行才出「展开 / 收起」；展开用
/// spring（[AnimatedSize]）。点正文本身也能切换（[selectable] 时只能点按钮，
/// 正文要留给选词）。
class MediaDetailSynopsis extends StatefulWidget {
  const MediaDetailSynopsis({
    required this.text,
    super.key,
    this.collapsedLines,
    this.selectable = false,
    this.textAlign = TextAlign.start,
    this.initiallyExpanded = false,
  });

  final String text;

  /// 收起时的行数；null = 跟随所在 hero：窄屏紧凑 hero 2 行（首屏留给正文）、
  /// 两栏左栏 5 行、其余 4 行。
  final int? collapsedLines;

  static int defaultCollapsedLines(BuildContext context) {
    if (MediaDetailLayout.isSidePane(context)) return 5;
    if (_MediaDetailHeroAlignScope.compactOf(context)) return 2;
    return 4;
  }

  final bool selectable;
  final TextAlign textAlign;
  final bool initiallyExpanded;

  @override
  State<MediaDetailSynopsis> createState() => _MediaDetailSynopsisState();
}

class _MediaDetailSynopsisState extends State<MediaDetailSynopsis> {
  late bool _expanded = widget.initiallyExpanded;

  void _toggle() => setState(() => _expanded = !_expanded);

  @override
  Widget build(BuildContext context) {
    final String text = widget.text.trim();
    if (text.isEmpty) return const SizedBox.shrink();
    final ColorScheme cs = Theme.of(context).colorScheme;
    final FushiMotionScheme motion = context.fushiMotion;
    final int collapsedLines =
        widget.collapsedLines ??
        MediaDetailSynopsis.defaultCollapsedLines(context);
    final TextStyle style = context.fushiType.bodyLarge.copyWith(
      color: cs.onSurfaceVariant,
      height: 1.55,
    );
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // 只多出一行时不折叠：收起后只少一行，按钮按了像没反应，还白占一行。
        final TextPainter painter = TextPainter(
          text: TextSpan(text: text, style: style),
          maxLines: collapsedLines + 1,
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
        )..layout(maxWidth: constraints.maxWidth);
        final bool overflows = painter.didExceedMaxLines;
        painter.dispose();
        final int? maxLines = overflows && !_expanded ? collapsedLines : null;
        final Widget body = widget.selectable
            ? SelectableText(
                text,
                key: const ValueKey<String>('media-detail-synopsis-text'),
                maxLines: maxLines,
                textAlign: widget.textAlign,
                style: style,
              )
            : Text(
                text,
                key: const ValueKey<String>('media-detail-synopsis-text'),
                maxLines: maxLines,
                overflow: maxLines == null ? null : TextOverflow.ellipsis,
                textAlign: widget.textAlign,
                style: style,
              );
        return Column(
          crossAxisAlignment: widget.textAlign == TextAlign.center
              ? CrossAxisAlignment.center
              : CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            AnimatedSize(
              duration: motion.spatialDefault.duration,
              curve: motion.spatialDefault.curve,
              alignment: Alignment.topCenter,
              child: overflows && !widget.selectable
                  ? GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: _toggle,
                      child: body,
                    )
                  : body,
            ),
            if (overflows)
              FushiTextButton.icon(
                key: const ValueKey<String>('media-detail-synopsis-toggle'),
                onPressed: _toggle,
                icon: AnimatedRotation(
                  turns: _expanded ? 0.5 : 0,
                  duration: motion.spatialFast.duration,
                  curve: motion.spatialFast.curve,
                  child: const FushiIcon(FushiIcons.expandMore),
                ),
                label: Text(
                  _expanded ? t.collection_collapse : t.collection_expand,
                ),
              ),
          ],
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// 区块标题
// ---------------------------------------------------------------------------

/// 区块标题（「选集」「章节」「演职人员」）：titleLarge Emphasized + 计数胶囊 +
/// 行尾动作（排序 / 多选 / 全部下载）。
class MediaDetailSectionHeader extends StatelessWidget {
  const MediaDetailSectionHeader(
    this.title, {
    super.key,
    this.count,
    this.trailing,
    this.padding = const EdgeInsets.fromLTRB(0, 24, 0, 8),
  });

  final String title;
  final int? count;
  final Widget? trailing;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool apple = isGlassDesign(context);
    final int? count = this.count;
    return Padding(
      padding: padding,
      // 标题 + 计数胶囊收进一个 Expanded，[trailing] 才真正贴右缘。旧写法是
      // `Flexible(标题) … Spacer() … trailing`：两个 flex 子项平分剩余宽度，松约束
      // 的标题用不完自己那一半也不让出来，Spacer 只拿到另一半——trailing 落在行中
      // 偏右的半空里（用户反馈「剧集」区多选的 ✕ 位置是歪的）。
      child: Row(
        children: <Widget>[
          Expanded(
            child: Row(
              children: <Widget>[
                Flexible(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.fushiType.titleLargeEmphasized,
                  ),
                ),
                if (count != null) ...<Widget>[
                  const SizedBox(width: 10),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: apple
                          ? appleColorsOf(context).tertiaryFill
                          : cs.secondaryContainer,
                      borderRadius: const BorderRadius.all(
                        Radius.circular(999),
                      ),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 2,
                      ),
                      child: Text(
                        '$count',
                        style: context.fushiType.labelLargeEmphasized.tabular
                            .copyWith(
                              color: apple ? null : cs.onSecondaryContainer,
                            ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 章节 / 分集行
// ---------------------------------------------------------------------------

/// 条目（章节 / 分集）的下载状态。
enum MediaDetailDownloadState { none, queued, downloading, downloaded, failed }

/// 章节 / 分集的分段列表行（M3E segmented list，组首尾大圆角、行间 2px 缝）：
///
/// - 行首：[leading]（缩略图）或 [number] 序号胶囊（续看那条用 primary 实色）；
/// - 标题 + 副标题 + 元信息（播出日 · 时长）；已看完的标题降为 onSurfaceVariant；
/// - 观看进度（[progress]）：底部 primary 细条（M3E 波浪）；
/// - 状态：已看 = tertiary 实心对勾；下载 = 排队 / 转圈 / 已下载 / 失败图标；
/// - [current]：续看的那条整行 primaryContainer 高亮；
/// - [selected] 非 null = 多选模式（行首对勾圆，点行切换选择）。
class MediaDetailItemRow extends StatelessWidget {
  const MediaDetailItemRow({
    required this.title,
    required this.index,
    required this.count,
    super.key,
    this.leading,
    this.number,
    this.subtitle,
    this.meta = const <String>[],
    this.progress,
    this.completed = false,
    this.current = false,
    this.downloadState = MediaDetailDownloadState.none,
    this.downloadProgress,
    this.trailing,
    this.selected,
    this.onTap,
    this.onLongPress,
    this.onSecondaryTap,
    this.focusId,
    this.margin = EdgeInsets.zero,
    this.titleMaxLines = 2,
  });

  final String title;

  /// 组内位置与总数（决定分段圆角）。
  final int index;
  final int count;
  final Widget? leading;
  final String? number;
  final String? subtitle;
  final List<String> meta;
  final double? progress;
  final bool completed;
  final bool current;
  final MediaDetailDownloadState downloadState;
  final double? downloadProgress;
  final Widget? trailing;
  final bool? selected;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final VoidCallback? onSecondaryTap;
  final FushiFocusId? focusId;
  final EdgeInsetsGeometry margin;
  final int titleMaxLines;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool apple = isGlassDesign(context);
    final bool eink = isEinkTheme(context);
    final FushiTypography type = context.fushiType;
    final bool highlight = current && !eink;
    final Color fg = highlight && !apple ? cs.onPrimaryContainer : cs.onSurface;
    final Color fgVariant = highlight && !apple
        ? cs.onPrimaryContainer.withValues(alpha: 0.78)
        : cs.onSurfaceVariant;
    final String? subtitle = this.subtitle?.trim();
    final List<String> meta = <String>[
      for (final String part in this.meta)
        if (part.trim().isNotEmpty) part.trim(),
    ];
    final double? progress = this.progress;
    final bool? selected = this.selected;
    final Widget? leadingSlot = selected != null
        ? _SelectionMark(selected: selected)
        : leading ??
              (number == null
                  ? null
                  : _NumberPill(number: number!, current: current));
    final Widget? status = _buildStatus(context, cs, trailing != null);
    return FushiGroupedListItem(
      index: index,
      count: count,
      margin: margin,
      color: highlight
          ? (apple ? cs.primary.withValues(alpha: 0.14) : cs.primaryContainer)
          : null,
      selected: selected ?? false,
      onTap: onTap,
      onLongPress: onLongPress,
      onSecondaryTap: onSecondaryTap,
      focusId: focusId,
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(16, 12, 12, 12),
        child: Row(
          children: <Widget>[
            if (leadingSlot != null) ...<Widget>[
              leadingSlot,
              const SizedBox(width: 14),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    title,
                    maxLines: titleMaxLines,
                    overflow: TextOverflow.ellipsis,
                    style:
                        (current
                                ? type.titleMediumEmphasized
                                : type.titleMedium)
                            .copyWith(
                              color: completed && !current ? fgVariant : fg,
                            ),
                  ),
                  if (subtitle != null && subtitle.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: type.bodyMedium.copyWith(color: fgVariant),
                    ),
                  ],
                  if (meta.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 2),
                    Text(
                      meta.join('  ·  '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: type.labelMedium.tabular.copyWith(
                        color: fgVariant,
                      ),
                    ),
                  ],
                  if (progress != null && progress > 0 && !completed)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: FushiLinearProgressIndicator(
                        value: progress.clamp(0.0, 1.0),
                        minHeight: 4,
                        color: cs.primary,
                      ),
                    ),
                ],
              ),
            ),
            if (status != null) ...<Widget>[const SizedBox(width: 8), status],
            if (trailing != null) ...<Widget>[
              const SizedBox(width: 4),
              trailing!,
            ],
          ],
        ),
      ),
    );
  }

  Widget? _buildStatus(BuildContext context, ColorScheme cs, bool hasTrailing) {
    final List<Widget> icons = <Widget>[
      if (completed)
        FushiIcon(
          FushiIcons.filled(FushiIcons.success),
          key: const ValueKey<String>('media-detail-item-completed'),
          size: 20,
          color: isGlassDesign(context) ? cs.primary : cs.tertiary,
        ),
      ...switch (downloadState) {
        MediaDetailDownloadState.none => const <Widget>[],
        MediaDetailDownloadState.queued => <Widget>[
          FushiIcon(FushiIcons.pending, size: 20, color: cs.onSurfaceVariant),
        ],
        MediaDetailDownloadState.downloading => <Widget>[
          // 下载中行尾的下载钮会被撤掉：进度圈要落在它原来的 48dp 命中区
          // 中心（否则右偏 14dp 且只有 20dp 显得迷你）。有 trailing 时圈
          // 仍排在状态位，只放大到 24dp。
          SizedBox.square(
            key: const ValueKey<String>('media-detail-item-downloading'),
            dimension: hasTrailing ? 24 : 48,
            child: Center(
              child: SizedBox.square(
                dimension: 24,
                child: FushiCircularProgressIndicator(
                  value: downloadProgress,
                  strokeWidth: 3,
                ),
              ),
            ),
          ),
        ],
        MediaDetailDownloadState.downloaded => <Widget>[
          FushiIcon(
            FushiIcons.filled(FushiIcons.downloadDone),
            size: 20,
            color: cs.primary,
          ),
        ],
        MediaDetailDownloadState.failed => <Widget>[
          FushiIcon(FushiIcons.error, size: 20, color: cs.error),
        ],
      },
    ];
    if (icons.isEmpty) return null;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (int i = 0; i < icons.length; i++) ...<Widget>[
          if (i > 0) const SizedBox(width: 6),
          icons[i],
        ],
      ],
    );
  }
}

/// 序号胶囊：常态 secondaryContainer，续看那条 primary 实色。
class _NumberPill extends StatelessWidget {
  const _NumberPill({required this.number, required this.current});

  final String number;
  final bool current;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool apple = isGlassDesign(context);
    final Color fill = current
        ? cs.primary
        : (apple ? appleColorsOf(context).tertiaryFill : cs.secondaryContainer);
    final Color fg = current
        ? cs.onPrimary
        : (apple ? cs.onSurface : cs.onSecondaryContainer);
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 40, minHeight: 32),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: fill,
          borderRadius: const BorderRadius.all(Radius.circular(999)),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Text(
            number,
            textAlign: TextAlign.center,
            style: context.fushiType.labelLargeEmphasized.tabular.copyWith(
              color: fg,
            ),
          ),
        ),
      ),
    );
  }
}

/// 多选模式的行首选择标记（spring 缩放切换实心对勾）。
class _SelectionMark extends StatelessWidget {
  const _SelectionMark({required this.selected});

  final bool selected;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final FushiMotionScheme motion = context.fushiMotion;
    return AnimatedSwitcher(
      duration: motion.spatialFast.duration,
      switchInCurve: motion.spatialFast.curve,
      transitionBuilder: (Widget child, Animation<double> animation) =>
          ScaleTransition(scale: animation, child: child),
      child: FushiIcon(
        selected ? FushiIcons.filled(FushiIcons.success) : FushiIcons.addCircle,
        key: ValueKey<bool>(selected),
        size: 24,
        color: selected ? cs.primary : cs.onSurfaceVariant,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 人物表
// ---------------------------------------------------------------------------

/// 人物表里的一个人（纯值）。
@immutable
class MediaDetailPerson {
  const MediaDetailPerson({
    required this.name,
    this.role,
    this.image,
    this.key,
    this.onImageError,
    this.onTap,
  });

  final String name;

  /// 角色名 / 职位。
  final String? role;
  final ImageProvider? image;
  final Key? key;

  /// 头像解码失败（诊断日志用）。
  final void Function(Object error)? onImageError;

  /// 点头像（作品图谱 L5：进人物聚合页）；null = 不可点。
  final VoidCallback? onTap;
}

/// 人物表横滑：圆形头像卡（照片 + 姓名 + 角色），错峰进场。
class MediaDetailCastStrip extends StatelessWidget {
  const MediaDetailCastStrip({
    required this.people,
    super.key,
    this.title,
    this.padding = EdgeInsets.zero,
    this.avatarSize = 76,
  });

  final List<MediaDetailPerson> people;
  final String? title;

  /// 标题与横滑轨道的左右页边距。
  final EdgeInsets padding;
  final double avatarSize;

  @override
  Widget build(BuildContext context) {
    if (people.isEmpty) return const SizedBox.shrink();
    final String? title = this.title;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (title != null)
          MediaDetailSectionHeader(
            title,
            count: people.length,
            padding: EdgeInsets.fromLTRB(padding.left, 24, padding.right, 12),
          ),
        SizedBox(
          height: avatarSize + 62,
          child: HorizontalDragScrollable(
            child: ListView.separated(
              padding: EdgeInsets.only(
                left: padding.left,
                right: padding.right,
              ),
              scrollDirection: Axis.horizontal,
              itemCount: people.length,
              separatorBuilder: (_, _) => const SizedBox(width: 12),
              itemBuilder: (BuildContext context, int index) =>
                  FushiStaggeredEntrance(
                    index: index,
                    child: _CastAvatar(
                      key: people[index].key,
                      person: people[index],
                      size: avatarSize,
                    ),
                  ),
            ),
          ),
        ),
      ],
    );
  }
}

class _CastAvatar extends StatelessWidget {
  const _CastAvatar({required this.person, required this.size, super.key});

  final MediaDetailPerson person;
  final double size;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool eink = isEinkTheme(context);
    final FushiTypography type = context.fushiType;
    final ImageProvider? image = person.image;
    final Widget placeholder = ColoredBox(
      color: cs.secondaryContainer,
      child: Center(
        child: FushiIcon(
          FushiIcons.person,
          size: size * 0.42,
          color: cs.onSecondaryContainer,
        ),
      ),
    );
    final String? role = person.role?.trim();
    final Widget card = SizedBox(
      width: size + 28,
      child: Column(
        children: <Widget>[
          DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: eink ? cs.outline : cs.surfaceContainerHighest,
                width: 3,
              ),
            ),
            child: ClipOval(
              child: SizedBox.square(
                dimension: size,
                child: image == null
                    ? placeholder
                    : Image(
                        image: image,
                        fit: BoxFit.cover,
                        errorBuilder: (_, Object error, _) {
                          person.onImageError?.call(error);
                          return placeholder;
                        },
                      ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            person.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: type.labelLargeEmphasized,
          ),
          if (role != null && role.isNotEmpty)
            Text(
              role,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: type.bodySmall.copyWith(color: cs.onSurfaceVariant),
            ),
        ],
      ),
    );
    final VoidCallback? onTap = person.onTap;
    if (onTap == null) return card;
    // 可点头像：按压回弹 + 悬停抬升（两套设计系统同样生效），InkWell 承接焦点与
    // Enter / 手柄 A 激活。
    return FushiHoverLift(
      builder: (BuildContext context, bool _) => FushiPressScale(
        child: Semantics(
          button: true,
          label: role == null || role.isEmpty
              ? person.name
              : '${person.name} · $role',
          excludeSemantics: true,
          child: InkWell(
            borderRadius: FushiM3eShape.cardRadius,
            onTap: onTap,
            child: card,
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 布局
// ---------------------------------------------------------------------------

/// 详情页整体布局：宽屏（≥ [twoPaneMinWidth]）两栏——左栏 [header]（hero 信息，
/// 独立滚动，相当于 sticky）、右栏 [slivers]（分集 / 章节 / 人物…）；整页背景
/// 画在两栏之后。窄屏单列：[header] 在顶、[slivers] 跟随。
///
/// [header] 里的 [MediaDetailHero] 在左栏时自动改成窄式堆叠、不重复画背景。
class MediaDetailLayout extends StatelessWidget {
  const MediaDetailLayout({
    required this.header,
    this.slivers = const <Widget>[],
    this.body,
    super.key,
    this.backdrop,
    this.backdropKey,
    this.backdropBlur = 28,
    this.twoPaneMinWidth = kMediaDetailTwoPaneMinWidth,
    this.sidePaneWidth,
    this.controller,
    this.bottomPadding = 24,
    this.fab,
  });

  final Widget header;
  final List<Widget> slivers;

  /// 非 sliver 的正文（自带滚动的页签区等），给了就不用 [slivers]：单列时
  /// [header] 在顶、[body] 吃掉剩余高度；两栏时 [body] 占右栏。
  final Widget? body;

  /// 两栏时整页背景（与 hero 的背景同一张）。
  final ImageProvider? backdrop;
  final Object? backdropKey;
  final double backdropBlur;

  /// 无条件切两栏的宽度；[double.infinity] = 永远单列（连横屏判据一起关掉）。
  final double twoPaneMinWidth;

  /// null = 按窗口宽自适应（见 [sidePaneWidthFor]）。
  final double? sidePaneWidth;

  /// 正文（单列时整页 / 两栏时右栏）的滚动控制器。
  final ScrollController? controller;
  final double bottomPadding;

  /// 右下角悬浮按钮（通常是 [MediaDetailResumeFab]），只在单列时出现；正文末尾
  /// 多留出它的高度，最后一行不被挡住。
  final Widget? fab;

  /// [context] 是否在两栏布局的左栏里。
  static bool isSidePane(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_MediaDetailSidePaneScope>() !=
      null;

  /// 当前是否两栏（供页面决定右栏的列数等）。[maxHeight] 缺省取窗口高。
  static bool isTwoPane(
    BuildContext context,
    double maxWidth, {
    double? maxHeight,
  }) => shouldUseTwoPane(
    maxWidth * FushiAppUiScale.of(context),
    (maxHeight ?? MediaQuery.sizeOf(context).height) *
        FushiAppUiScale.of(context),
  );

  /// 两栏判据（已乘 UI 缩放的逻辑宽高）：够宽，或横屏且不太窄。
  static bool shouldUseTwoPane(
    double width,
    double height, {
    double twoPaneMinWidth = kMediaDetailTwoPaneMinWidth,
  }) {
    if (width >= twoPaneMinWidth) return true;
    if (twoPaneMinWidth == double.infinity) return false;
    return width >= kMediaDetailLandscapeTwoPaneMinWidth &&
        height.isFinite &&
        width > height;
  }

  /// 左栏宽度：窗口宽的 40%，夹在 [kMediaDetailSidePaneMinWidth] 与
  /// [kMediaDetailSidePaneWidth] 之间。
  static double sidePaneWidthFor(double width) => (width * 0.4).clamp(
    kMediaDetailSidePaneMinWidth,
    kMediaDetailSidePaneWidth,
  );

  /// 顶栏（浮动胶囊，[Scaffold.extendBodyBehindAppBar]）+ 状态栏占掉的高度：
  /// 背景铺满到窗口顶端，hero 内容从这条线下开始排。由布局按
  /// `MediaQuery.paddingOf(context).top` 下发，不在两栏左栏 / 单列 hero 之外生效。
  static double heroTopInset(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<_MediaDetailTopInsetScope>()
          ?.top ??
      0;

  @override
  Widget build(BuildContext context) {
    // 页面以 extendBodyBehindAppBar 挂在浮动顶栏之下时，Scaffold 把顶栏高度折进
    // MediaQuery 顶部 padding。背景必须从窗口顶端画起（顶栏只是几颗悬浮胶囊，
    // 不画任何整宽底带），内容自己让开这段——所以这里读出来、往下自己用，并从
    // 子树里摘掉，免得滚动视图 / hero 再让一次。
    final double topInset = MediaQuery.paddingOf(context).top;
    return MediaQuery.removePadding(
      context: context,
      removeTop: true,
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final double scale = FushiAppUiScale.of(context);
          final bool twoPane = shouldUseTwoPane(
            constraints.maxWidth * scale,
            constraints.maxHeight * scale,
            twoPaneMinWidth: twoPaneMinWidth,
          );
          final double paneWidth =
              sidePaneWidth ?? sidePaneWidthFor(constraints.maxWidth);
          // 悬浮按钮只在单列出现：两栏时左栏 hero 的主按钮一直在视野里，再挂一个
          // 重复（用户 2026-10-20）。
          final Widget? fab = twoPane ? null : this.fab;
          final Widget bottom = SliverSafeArea(
            top: false,
            sliver: SliverToBoxAdapter(
              child: SizedBox(
                height:
                    bottomPadding +
                    (fab == null ? 0 : kMediaDetailFabClearance),
              ),
            ),
          );
          Widget withFab(Widget child) => fab == null
              ? child
              : _MediaDetailFabHost(fab: fab, topInset: topInset, child: child);
          // 顶部可读性遮罩**不在这里画**：内容滚到浮动顶栏下面时的渐隐归顶栏
          // 自己（[FushiAppBar] / [FushiPageScaffold] 页头，共享的
          // [FushiTopFadeScrim]）。布局曾经再叠一层 55% 底色渐变，与顶栏那层
          // 叠加后在栏下沿形成一道浅色带 + 硬边。
          final Widget? body = this.body;
          if (!twoPane && body != null) {
            // hero 最多占六成高度（展开长简介时在自己里面滚），页签区至少留四成。
            return withFab(
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: constraints.maxHeight * 0.6,
                    ),
                    child: SingleChildScrollView(
                      primary: false,
                      child: _MediaDetailTopInsetScope(
                        top: topInset,
                        child: header,
                      ),
                    ),
                  ),
                  Expanded(child: body),
                ],
              ),
            );
          }
          if (!twoPane) {
            return withFab(
              CustomScrollView(
                controller: controller,
                slivers: <Widget>[
                  SliverToBoxAdapter(
                    child: _MediaDetailTopInsetScope(
                      top: topInset,
                      child: header,
                    ),
                  ),
                  ...slivers,
                  bottom,
                ],
              ),
            );
          }
          return Stack(
            children: <Widget>[
              Positioned.fill(
                child: MediaDetailBackdrop(
                  image: backdrop,
                  imageKey: backdropKey,
                  blurSigma: backdropBlur,
                ),
              ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  SizedBox(
                    width: paneWidth,
                    child: _MediaDetailSidePaneScope(
                      child: SingleChildScrollView(
                        key: const ValueKey<String>('media-detail-side-pane'),
                        // 左栏不接 PrimaryScrollController：右栏是主滚动视图，两个
                        // 都挂上会撞「controller attached to multiple scroll views」。
                        primary: false,
                        padding: EdgeInsets.only(
                          top: topInset,
                          bottom:
                              bottomPadding +
                              MediaQuery.paddingOf(context).bottom,
                        ),
                        child: header,
                      ),
                    ),
                  ),
                  Expanded(
                    child: body != null
                        ? Padding(
                            key: const ValueKey<String>(
                              'media-detail-main-pane',
                            ),
                            padding: EdgeInsets.only(top: topInset + 8),
                            child: body,
                          )
                        : CustomScrollView(
                            key: const ValueKey<String>(
                              'media-detail-main-pane',
                            ),
                            controller: controller,
                            slivers: <Widget>[
                              SliverToBoxAdapter(
                                child: SizedBox(height: topInset + 8),
                              ),
                              ...slivers,
                              bottom,
                            ],
                          ),
                  ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}

/// 布局下发给 hero 按钮组的锚点：主按钮挂上它，[_MediaDetailFabHost] 据它的
/// 实际位置判断「主按钮还看得见吗」。
class _MediaDetailFabAnchorScope extends InheritedWidget {
  const _MediaDetailFabAnchorScope({
    required this.anchor,
    required super.child,
  });

  final GlobalKey anchor;

  static GlobalKey? of(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<_MediaDetailFabAnchorScope>()
      ?.anchor;

  @override
  bool updateShouldNotify(_MediaDetailFabAnchorScope oldWidget) =>
      anchor != oldWidget.anchor;
}

/// 单列详情页的悬浮按钮宿主：与 hero 主按钮**互斥显示**（用户 2026-10-20）——
/// 主按钮还在视口里时隐藏；主按钮下边缘滚进浮动顶栏底下（[topInset] 线以上）
/// 后淡入 + 轻微上滑出现，滚回来再隐藏。判据是主按钮的实际位置，不是固定的
/// 像素阈值：窗口高度、hero 高度（简介展开 / 收起）变了照样准。
class _MediaDetailFabHost extends StatefulWidget {
  const _MediaDetailFabHost({
    required this.fab,
    required this.topInset,
    required this.child,
  });

  final Widget fab;

  /// 浮动顶栏 + 状态栏占掉的高度（主按钮滚到这条线以上就算被遮住）。
  final double topInset;
  final Widget child;

  @override
  State<_MediaDetailFabHost> createState() => _MediaDetailFabHostState();
}

class _MediaDetailFabHostState extends State<_MediaDetailFabHost> {
  final GlobalKey _anchor = GlobalKey(debugLabel: 'media-detail-primary');
  bool _visible = false;

  @override
  void initState() {
    super.initState();
    _scheduleEvaluate();
  }

  @override
  void didUpdateWidget(_MediaDetailFabHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    _scheduleEvaluate();
  }

  void _scheduleEvaluate() {
    WidgetsBinding.instance.addPostFrameCallback((_) => _evaluate());
  }

  /// 主按钮下边缘是否已在顶栏线以上。找不到主按钮（页面没给主操作）时恒显示。
  void _evaluate() {
    if (!mounted) return;
    final RenderObject? host = context.findRenderObject();
    final RenderObject? anchor = _anchor.currentContext?.findRenderObject();
    bool visible = true;
    if (host is RenderBox &&
        anchor is RenderBox &&
        anchor.attached &&
        anchor.hasSize) {
      final double bottom = anchor
          .localToGlobal(Offset(0, anchor.size.height), ancestor: host)
          .dy;
      visible = bottom <= widget.topInset;
    }
    if (visible != _visible) setState(() => _visible = visible);
  }

  bool _onScroll(ScrollNotification notification) {
    if (notification.metrics.axis == Axis.vertical) _evaluate();
    return false;
  }

  bool _onMetrics(ScrollMetricsNotification notification) {
    if (notification.metrics.axis == Axis.vertical) _evaluate();
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final Duration duration = fushiMotionDuration(context, FushiMotion.short);
    return Stack(
      children: <Widget>[
        Positioned.fill(
          child: NotificationListener<ScrollMetricsNotification>(
            onNotification: _onMetrics,
            child: NotificationListener<ScrollNotification>(
              onNotification: _onScroll,
              child: _MediaDetailFabAnchorScope(
                anchor: _anchor,
                child: widget.child,
              ),
            ),
          ),
        ),
        PositionedDirectional(
          end: 16,
          bottom: 16 + MediaQuery.paddingOf(context).bottom,
          child: ExcludeFocus(
            excluding: !_visible,
            child: IgnorePointer(
              ignoring: !_visible,
              child: AnimatedSlide(
                offset: _visible ? Offset.zero : const Offset(0, 0.25),
                duration: duration,
                curve: context.fushiMotion.spatialDefault.curve,
                child: AnimatedOpacity(
                  opacity: _visible ? 1 : 0,
                  duration: duration,
                  curve: context.fushiMotion.effectsDefault.curve,
                  child: widget.fab,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// [MediaDetailLayout.fab] 占掉的正文底部留白（56 高的悬浮按钮 + 上下间距）。
const double kMediaDetailFabClearance = 80;

/// 详情页右下角的「继续 / 开始」悬浮按钮（M3E primaryContainer 圆角方 FAB，
/// Apple 强调色胶囊）：图标 + 文案的扩展 FAB。由
/// [MediaDetailLayout.fab] 挂载，两栏时不出现。
///
/// 文案：有进度时「继续阅读 · 第 12 话」「继续观看 · 第 3 集」，一次都没打开过时
/// 「开始阅读」「开始观看」（[itemLabel] 照样跟在后面，告诉用户从哪一话开始）。
class MediaDetailResumeFab extends StatelessWidget {
  const MediaDetailResumeFab({
    required this.watching,
    required this.started,
    required this.onPressed,
    super.key,
    this.itemLabel,
    this.buttonKey,
    this.labelOverride,
    this.icon,
  });

  /// 非 null 时直接用作按钮文案（原盘作品的「播放原盘」），不再按 [watching] /
  /// [started] 推导。
  final String? labelOverride;

  /// 非 null 时替换默认的播放图标。
  final IconData? icon;

  /// true = 视频（观看），false = 书 / 漫画 / 小说（阅读）。
  final bool watching;

  /// 已经有阅读 / 观看进度（「继续」）还是从没打开过（「开始」）。
  final bool started;

  /// 目标那一话 / 一集的名字；null / 空 = 只显示动作。
  final String? itemLabel;
  final VoidCallback? onPressed;
  final Key? buttonKey;

  /// 按钮文案（tooltip 与扩展态共用）。
  static String labelFor({
    required bool watching,
    required bool started,
    String? itemLabel,
  }) {
    final String verb = switch ((watching, started)) {
      (true, true) => t.video_continue_watching,
      (true, false) => t.media_detail_start_watching,
      (false, true) => t.book_continue_reading,
      (false, false) => t.media_detail_start_reading,
    };
    final String? item = itemLabel?.trim();
    return item == null || item.isEmpty ? verb : '$verb · $item';
  }

  @override
  Widget build(BuildContext context) {
    final String label =
        labelOverride ??
        labelFor(watching: watching, started: started, itemLabel: itemLabel);
    // 扩展 FAB（图标 + 文案）：一眼看出会从哪一话 / 集继续；过长的章名省略。
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 280),
      child: FushiFab(
        key: buttonKey,
        heroTag: null,
        icon: FushiIcon(icon ?? FushiIcons.play),
        tooltip: label,
        onPressed: onPressed,
        label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
    );
  }
}

/// 布局下发给单列 hero 的顶部让位高度（见 [MediaDetailLayout.heroTopInset]）。
class _MediaDetailTopInsetScope extends InheritedWidget {
  const _MediaDetailTopInsetScope({required this.top, required super.child});

  final double top;

  @override
  bool updateShouldNotify(_MediaDetailTopInsetScope oldWidget) =>
      top != oldWidget.top;
}

class _MediaDetailSidePaneScope extends InheritedWidget {
  const _MediaDetailSidePaneScope({required super.child});

  @override
  bool updateShouldNotify(_MediaDetailSidePaneScope oldWidget) => false;
}

// ---------------------------------------------------------------------------
// 加载骨架
// ---------------------------------------------------------------------------

/// 详情页加载骨架：与加载完成后的 [MediaDetailLayout] **同一套版式**。
///
/// - 两栏宽度（≥ [kMediaDetailTwoPaneMinWidth]）：左栏是窄式 hero（2:3 封面居中 +
///   居中标题 / chip / 按钮条 + 简介条），右栏是区块标题 + [rows] 张宽集卡；
/// - 单列：hero 按 [kMediaDetailHeroWideMinWidth] 分宽（封面在起始侧）/ 窄（居中），
///   下面跟 [rows] 行条目。
///
/// BUG-3190：曾经不分宽窄恒画「封面在左 + 整宽条目」的旧单列样式，两栏详情页一加载
/// 就先闪一下旧版式再跳成新版式（用户：「未加载完时显示的还是之前的样子」）。
class MediaDetailSkeleton extends StatelessWidget {
  const MediaDetailSkeleton({super.key, this.rows = 6});

  final int rows;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final double page = tokens.spacing.page;
    // 页面以 extendBodyBehindAppBar 挂在浮动顶栏下时，让开顶栏。
    final double top = MediaQuery.paddingOf(context).top;
    return FushiSkeletonShimmer(
      child: LayoutBuilder(
        key: const ValueKey<String>('media-detail-skeleton'),
        builder: (BuildContext context, BoxConstraints constraints) {
          final double width = constraints.maxWidth;
          if (MediaDetailLayout.isTwoPane(context, width)) {
            // 两栏各自是不可滚的 SingleChildScrollView（与单列骨架的
            // NeverScrollable ListView 同理）：横屏矮窗口（如 800×600）放不下
            // 六张集卡时裁掉多出的部分，而不是 RenderFlex 溢出。
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                SizedBox(
                  width: MediaDetailLayout.sidePaneWidthFor(width),
                  child: SingleChildScrollView(
                    primary: false,
                    physics: const NeverScrollableScrollPhysics(),
                    padding: EdgeInsets.fromLTRB(
                      page,
                      top + tokens.spacing.section,
                      page,
                      page,
                    ),
                    child: _compactHero(sidePane: true),
                  ),
                ),
                Expanded(
                  child: SingleChildScrollView(
                    primary: false,
                    physics: const NeverScrollableScrollPhysics(),
                    padding: EdgeInsets.fromLTRB(
                      page,
                      top + 8 + 12,
                      page,
                      page,
                    ),
                    child: _cards(context),
                  ),
                ),
              ],
            );
          }
          final bool wideHero =
              width * FushiAppUiScale.of(context) >=
              kMediaDetailHeroWideMinWidth;
          return ListView(
            physics: const NeverScrollableScrollPhysics(),
            padding: EdgeInsets.fromLTRB(
              page,
              tokens.spacing.section + top,
              page,
              page,
            ),
            children: <Widget>[
              if (wideHero) _wideHero() else _compactHero(sidePane: false),
              const SizedBox(height: 24),
              for (int i = 0; i < rows; i++) ...<Widget>[
                FushiSkeleton(
                  height: 64,
                  borderRadius: fushiGroupedItemRadius(context, i, rows),
                ),
                const SizedBox(height: 2),
              ],
            ],
          );
        },
      ),
    );
  }

  /// 紧凑 hero：与 [MediaDetailHero] 的窄屏单列 / 两栏左栏同形（小封面在起始
  /// 侧、信息在旁，操作区与简介占满整宽）。
  Widget _compactHero({required bool sidePane}) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: <Widget>[
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          FushiSkeleton(
            width: sidePane ? 112 : 96,
            height: sidePane ? 168 : 144,
            borderRadius: FushiM3eShape.cardRadius,
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const FushiSkeleton(width: 96, height: 14),
                const SizedBox(height: 10),
                FushiSkeleton.line(widthFactor: 0.85, height: 24),
                const SizedBox(height: 8),
                FushiSkeleton.line(widthFactor: 0.55, height: 16),
                const SizedBox(height: 12),
                FushiSkeleton.line(widthFactor: 0.7, height: 26),
              ],
            ),
          ),
        ],
      ),
      const SizedBox(height: 16),
      const FushiSkeleton(
        height: 56,
        borderRadius: BorderRadius.all(Radius.circular(28)),
      ),
      const SizedBox(height: 16),
      FushiSkeleton.line(height: 14),
      const SizedBox(height: 8),
      FushiSkeleton.line(widthFactor: 0.8, height: 14),
    ],
  );

  /// 宽式 hero：封面在起始侧、信息靠底。
  Widget _wideHero() => Row(
    crossAxisAlignment: CrossAxisAlignment.end,
    children: <Widget>[
      FushiSkeleton(
        width: 132,
        height: 198,
        borderRadius: FushiM3eShape.cardRadius,
      ),
      const SizedBox(width: 20),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            FushiSkeleton.line(widthFactor: 0.8, height: 28),
            const SizedBox(height: 12),
            FushiSkeleton.line(widthFactor: 0.5, height: 16),
            const SizedBox(height: 16),
            FushiSkeleton.line(widthFactor: 0.65, height: 28),
            const SizedBox(height: 20),
            FushiSkeleton.line(widthFactor: 0.4, height: 48),
          ],
        ),
      ),
    ],
  );

  /// 右栏：区块标题 + 宽集卡（缩略图 + 两条文字），与选集区同轮廓。
  Widget _cards(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      const FushiSkeleton(width: 96, height: 24),
      const SizedBox(height: 16),
      for (int i = 0; i < rows; i++) ...<Widget>[
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Row(
            children: <Widget>[
              FushiSkeleton(
                width: 168,
                height: 96,
                borderRadius: FushiM3eShape.cardRadius,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    FushiSkeleton.line(widthFactor: 0.7, height: 16),
                    const SizedBox(height: 10),
                    FushiSkeleton.line(widthFactor: 0.4, height: 12),
                    const SizedBox(height: 10),
                    FushiSkeleton.line(height: 12),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
      ],
    ],
  );
}
