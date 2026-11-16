/// 首页拼贴版式（重设计外壳、库页布局为拼贴时）的分区组件，设计稿
/// `collage_review_design` H1–H8：
///
/// - [HomeSectionHeader]：分区标题 + 可选「全部 ›」；
/// - [HomeContinueCarousel]（H1，手机）：「继续」单行等尺寸横滑，封面在上、标题 +
///   进度在下，整段约 230 高，第一本不加大；
/// - [HomeContinueGrid]（H4，桌面）：首块 + 两行半高块，列数按可用宽度算，排不下
///   的条目进「全部 ›」（[HomeContinueAllPage]），不让卡切在窗口边；
/// - [HomeStatTile]（H2 / H5）：一个主数字 + 一行副信息 + 可选环 / 柱条 / 右下动作
///   的小统计块，不画水印。
///
/// 只管排版与视觉；数据、点按去向由首页（`home_dashboard_page.dart`）给。
library;

import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/components/fushi_continue_hero.dart'
    show FushiContinueEntry, FushiContinueSideMeta, FushiContinueSideTile;
import 'package:fushi/src/utils/components/fushi_cover_block.dart'
    show FushiCoverBlockColors, FushiCoverBlockSize, fushiCoverBlockShape;
import 'package:fushi/src/utils/components/fushi_cover_block_layout.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart'
    show FushiPageScaffold;
import 'package:fushi/src/utils/components/fushi_poster_block.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/components/shelf_card_widgets.dart'
    show shelfCoverCard;
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/platform_utils.dart'
    show HorizontalDragScrollable, desktopAwareScrollPhysics;

// ── 分区标题 ────────────────────────────────────────────────────────────────

/// 分区标题行：标题（读屏是标题节点）+ 末端可选的「全部 ›」文字按钮。
class HomeSectionHeader extends StatelessWidget {
  const HomeSectionHeader({
    super.key,
    required this.title,
    this.compact = false,
    this.onSeeAll,
    this.seeAllKey,
  });

  final String title;

  /// 手机：标题收小一档（设计稿手机 `.sec`）。
  final bool compact;

  /// 「全部 ›」；null = 不画。
  final VoidCallback? onSeeAll;
  final Key? seeAllKey;

  @override
  Widget build(BuildContext context) {
    final TextStyle base =
        Theme.of(context).textTheme.bodyMedium ?? const TextStyle();
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final VoidCallback? seeAll = onSeeAll;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        Expanded(
          child: Semantics(
            header: true,
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: (compact ? FushiPosterText.name : FushiPosterText.section)
                  .on(base)
                  .copyWith(color: tokens.surfaces.onSurface),
            ),
          ),
        ),
        if (seeAll != null)
          FushiTextButton.icon(
            key: seeAllKey,
            onPressed: seeAll,
            icon: const FushiIcon(FushiIcons.chevronRight),
            iconAlignment: IconAlignment.end,
            label: Text(t.home_continue_see_all),
          ),
      ],
    );
  }
}

// ── H1：手机「继续」单行横滑 ──────────────────────────────────────────────────

/// 手机「继续」横滑条的总高（封面 + 标题 / 进度文字块），设计稿 H1「约 230」。
const double kHomeContinueCarouselHeight = 230;

/// 手机「继续」横滑条（H1）：所有条目等尺寸排成一行横向滑动——封面在上，
/// 库页同款文字块（标题 + 副行 + 进度条）在下。第一本不加大；上次活动时间由
/// 调用方写进副行（[FushiContinueEntry.subtitle]）。
///
/// 横滑视口向两侧外扩 [bleed]（页边距），条目滑到屏幕边才被裁，内容起点仍与
/// 页面对齐；卡片悬停抬升 / 按压由 [FushiContinueSideTile] 自带，进场错峰。
class HomeContinueCarousel extends StatelessWidget {
  const HomeContinueCarousel({
    super.key,
    required this.entries,
    required this.bleed,
    this.height = kHomeContinueCarouselHeight,
    this.spacing = 12,
    this.listKey,
  });

  final List<FushiContinueEntry> entries;

  /// 视口向左右外扩的量（= 页面左右边距）。
  final double bleed;
  final double height;
  final double spacing;
  final Key? listKey;

  /// [height] 高的横滑条里封面的高：总高减去文字块（随文字缩放）。
  static double coverHeightFor(BuildContext context, double height) {
    final double meta = FushiContinueSideMeta.full.heightFor(context);
    return math.max(96.0, height - meta);
  }

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) return const SizedBox.shrink();
    final double metaHeight = FushiContinueSideMeta.full.heightFor(context);
    final double coverHeight = coverHeightFor(context, height);
    return SizedBox(
      key: listKey,
      height: coverHeight + metaHeight,
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          Positioned(
            left: -bleed,
            right: -bleed,
            top: 0,
            bottom: 0,
            child: HorizontalDragScrollable(
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                physics: desktopAwareScrollPhysics(),
                padding: EdgeInsets.symmetric(horizontal: bleed),
                itemCount: entries.length,
                separatorBuilder: (BuildContext _, int _) =>
                    SizedBox(width: spacing),
                itemBuilder: (BuildContext context, int i) =>
                    FushiStaggeredEntrance(
                      index: i,
                      child: FushiContinueSideTile(
                        entry: entries[i],
                        coverHeight: coverHeight,
                        metaHeight: metaHeight,
                      ),
                    ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── H4：桌面「继续」首块 + 两行半高块 ──────────────────────────────────────────

/// 半高块的最小宽：再窄就放不下小封面 + 两行标题，列数少一列。
const double kHomeContinueGridMinTileWidth = 180;

/// 半高块最多排几列（窗口再宽也不无限加列）。
const int kHomeContinueGridMaxColumns = 4;

/// 首块宽：约三成行宽，夹在 280…440（设计稿 `grid-template-columns: 280px …`）。
double homeContinueGridHeroWidth(double width) =>
    (width * 0.3).clamp(280.0, 440.0);

/// [width] 宽下首块旁能排几列半高块（每列上下两块）。纯函数，测试与版面共用。
int homeContinueGridColumns({
  required double width,
  double spacing = kFushiCoverBlockSpacing,
}) {
  final double rest = width - homeContinueGridHeroWidth(width) - spacing;
  final int fit = ((rest + spacing) / (kHomeContinueGridMinTileWidth + spacing))
      .floor();
  return fit.clamp(1, kHomeContinueGridMaxColumns);
}

/// [width] 宽、共 [itemCount] 条时网格里真正画出来的条数（首块 + 两行半高块）；
/// 其余进「全部 ›」。
int homeContinueGridVisibleCount({
  required double width,
  required int itemCount,
  double spacing = kFushiCoverBlockSpacing,
}) => math.min(
  itemCount,
  1 + 2 * homeContinueGridColumns(width: width, spacing: spacing),
);

/// 桌面「继续」（H4）：起始侧一个首块（[FushiCoverBlockSize.hero]），旁边两行
/// 半高块（[FushiCoverBlockSize.half]）。列数按可用宽度算
/// （[homeContinueGridColumns]），每块都完整落在内容区里——不横滑、不切边；
/// 排不下的条目不画，由调用方在分区标题给「全部 ›」。条目少于一整格时按实际
/// 条数收列，半高块吃满余宽。每格错峰进场。
class HomeContinueGrid extends StatelessWidget {
  const HomeContinueGrid({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    this.spacing = kFushiCoverBlockSpacing,
  });

  final int itemCount;
  final FushiCoverBlockItemBuilder itemBuilder;
  final double spacing;

  Widget _cell(BuildContext context, int index, FushiCoverBlockSize size) =>
      FushiStaggeredEntrance(
        index: index,
        child: itemBuilder(context, index, size),
      );

  @override
  Widget build(BuildContext context) {
    if (itemCount <= 0) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double width = constraints.maxWidth;
        const double heroHeight = kFushiCoverBlockHeroHeight;
        final double halfHeight = (heroHeight - spacing) / 2;
        final int columns = homeContinueGridColumns(
          width: width,
          spacing: spacing,
        );
        final int rest = math.min(itemCount - 1, columns * 2);
        if (rest <= 0) {
          return Align(
            alignment: AlignmentDirectional.centerStart,
            child: SizedBox(
              width: math.min(width, homeContinueGridHeroWidth(width) * 1.6),
              height: heroHeight,
              child: _cell(context, 0, FushiCoverBlockSize.hero),
            ),
          );
        }
        final int used = (rest + 1) ~/ 2;
        Widget row(int r) => SizedBox(
          height: halfHeight,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: spacing,
            children: <Widget>[
              for (int c = 0; c < used; c++)
                Expanded(
                  child: switch (1 + r * used + c) {
                    final int i when i <= rest => _cell(
                      context,
                      i,
                      FushiCoverBlockSize.half,
                    ),
                    _ => const SizedBox.shrink(),
                  },
                ),
            ],
          ),
        );
        return SizedBox(
          height: heroHeight,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: spacing,
            children: <Widget>[
              SizedBox(
                width: homeContinueGridHeroWidth(width),
                child: _cell(context, 0, FushiCoverBlockSize.hero),
              ),
              Expanded(
                child: Column(
                  spacing: spacing,
                  children: <Widget>[row(0), row(1)],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 「继续」的「全部 ›」页：全部条目排成等尺寸色块网格（与首页同一个 item
/// builder，点按去向不变），错峰进场。
class HomeContinueAllPage extends StatelessWidget {
  const HomeContinueAllPage({
    super.key,
    required this.title,
    required this.itemCount,
    required this.itemBuilder,
  });

  final String title;
  final int itemCount;
  final FushiCoverBlockItemBuilder itemBuilder;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final double page = tokens.spacing.page;
    return FushiPageScaffold(
      title: title,
      // Builder：让位高度由页头外壳经 MediaQuery 下发给正文，本页 build 的
      // context 在外壳之上读不到（读到的是 0，首行压在页名大字上）。
      body: FushiEntranceScope(
        child: Builder(
          builder: (BuildContext context) => CustomScrollView(
            key: const ValueKey<String>('home-continue-all-list'),
            slivers: <Widget>[
              SliverPadding(
                // 顶边吃掉页头让位（[FushiPageScaffold] 正文铺到页头底下，页头高度经
                // `MediaQuery.padding.top` 下发）：只写固定间距时首行色块压在返回键
                // 和页名大字上（用户 2026-11-16「继续页盖住了」）。
                padding: EdgeInsets.fromLTRB(
                  page,
                  tokens.spacing.card + MediaQuery.paddingOf(context).top,
                  page,
                  tokens.spacing.card + MediaQuery.paddingOf(context).bottom,
                ),
                sliver: SliverFushiCoverBlocks(
                  itemCount: itemCount,
                  itemBuilder: itemBuilder,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── H2 / H5：小统计块 ─────────────────────────────────────────────────────────

/// 手机并排两格统计块的高（设计稿 H2「104px」）。
const double kHomeStatTileHeightCompact = 104;

/// 桌面统计块的高（主数字 + 副行 + 7 天柱条 / 右下动作）。
const double kHomeStatTileHeight = 132;

/// 小统计块（H2 / H5）：左上「图标 + 标签」，主数字（强调色）+ 小单位，一行副
/// 信息；可选末端环（[ring] 非 null）、底部附件（[footer]，如 7 天柱条）与副行
/// 末端（块内右下）的动作（[action]，如「开始复习」）。不画大字水印（G2：水印只给带封面的媒体块）。
///
/// 高度固定为 [height]（同一行的两格等高）。[onTap] 非 null 时整块是一张可点卡
/// （悬停抬升、按压下沉、焦点由卡壳负责）。
class HomeStatTile extends StatelessWidget {
  const HomeStatTile({
    super.key,
    required this.colors,
    required this.icon,
    required this.label,
    required this.value,
    required this.height,
    this.unit,
    this.detail,
    this.ring,
    this.ringCenter,
    this.footer,
    this.action,
    this.onTap,
    this.cardKey,
    this.valueKey,
    this.semanticValue,
  });

  final FushiCoverBlockColors colors;
  final IconData icon;
  final String label;

  /// 主数字（已格式化）。
  final String value;
  final String? unit;

  /// 主数字下的一行副信息；null = 不画。
  final String? detail;

  /// 末端环的值：null = 不画环；`double.nan` = 画空环（只有底圈，中间
  /// [ringCenter]，如「没设目标」的旗子）。
  final double? ring;
  final Widget? ringCenter;

  final Widget? footer;
  final Widget? action;
  final VoidCallback? onTap;
  final Key? cardKey;
  final Key? valueKey;

  /// 主数字的读屏文案（如「1,429 待复习」）；null = [value] + [unit]。
  final String? semanticValue;

  final double height;

  bool get _compact => height <= kHomeStatTileHeightCompact;

  @override
  Widget build(BuildContext context) {
    final TextStyle base =
        Theme.of(context).textTheme.bodyMedium ?? const TextStyle();
    final bool compact = _compact;
    final Color muted = colors.onContainer.withValues(alpha: 0.8);
    final TextStyle labelStyle = FushiPosterText.meta
        .on(base)
        .copyWith(color: muted);
    final TextStyle detailStyle = FushiPosterText.meta
        .on(base)
        .copyWith(color: muted, fontWeight: FontWeight.w600);
    final double figureSize = compact ? 26 : 34;
    final TextStyle figureStyle = base.copyWith(
      fontSize: figureSize,
      fontWeight: FontWeight.w900,
      height: 1,
      letterSpacing: -0.03 * figureSize,
      color: colors.accent,
    );
    final TextStyle unitStyle = FushiPosterText.meta
        .on(base)
        .copyWith(color: muted);
    final double? ringValue = ring;
    final String? unitText = unit;
    final String? detailText = detail;

    final Widget figure = Semantics(
      key: valueKey,
      label: semanticValue ?? <String>[value, ?unitText].join(' '),
      excludeSemantics: true,
      child: Text.rich(
        TextSpan(
          children: <InlineSpan>[
            TextSpan(text: value, style: figureStyle),
            if (unitText != null && unitText.isNotEmpty)
              TextSpan(text: ' $unitText', style: unitStyle),
          ],
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );

    final Widget body = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: <Widget>[
        Row(
          spacing: 6,
          children: <Widget>[
            FushiIcon(icon, size: 14, color: muted),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: labelStyle,
              ),
            ),
          ],
        ),
        figure,
        if (detailText != null || action != null)
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            spacing: 8,
            children: <Widget>[
              Expanded(
                child: detailText == null
                    ? const SizedBox.shrink()
                    : Text(
                        detailText,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: detailStyle,
                      ),
              ),
              ?action,
            ],
          ),
        ?footer,
      ],
    );

    final Widget content = Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      spacing: 10,
      children: <Widget>[
        Expanded(child: body),
        if (ringValue != null)
          ExcludeSemantics(
            child: FushiPosterRing(
              value: ringValue.isNaN ? null : ringValue.clamp(0.0, 1.0),
              colors: colors,
              size: compact ? 44 : 56,
              center: ringCenter,
            ),
          ),
      ],
    );

    final Widget poster = FushiPosterBlock(
      watermark: '',
      colors: colors,
      hoverEnabled: onTap != null,
      padding: EdgeInsets.all(compact ? 12 : 16),
      child: SizedBox(height: height - (compact ? 24 : 32), child: content),
    );

    final VoidCallback? tap = onTap;
    return SizedBox(
      key: tap == null ? cardKey : null,
      height: height,
      child: tap == null
          ? poster
          : shelfCoverCard(
              key: cardKey,
              shape: fushiCoverBlockShape(context, FushiCoverBlockSize.regular),
              onTap: tap,
              child: poster,
            ),
    );
  }
}

/// 两块等高并排（H2 手机统计 / H6 + H7 桌面追踪与 AI）：只有一块时占满整行。
class HomeTileRow extends StatelessWidget {
  const HomeTileRow({
    super.key,
    required this.children,
    this.gap = kFushiCoverBlockSpacing,
  });

  final List<Widget> children;
  final double gap;

  @override
  Widget build(BuildContext context) {
    if (children.isEmpty) return const SizedBox.shrink();
    if (children.length == 1) return children.single;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: gap,
      children: <Widget>[
        for (final Widget child in children) Expanded(child: child),
      ],
    );
  }
}

/// 追踪 + AI 助手两块拼贴色块的高（设计稿 H6 / H7「118」，留一点字号余量）。
const double kHomeCollagePairHeight = 124;

/// 手机「继续」横滑超过这么多条时分区标题给「全部 ›」（一屏约露三张）。
const int kHomeContinueCompactSeeAllMin = 3;

/// 手机内容底部渐隐（H3）：从底栏上沿（底部 [inset] = 悬浮底栏 + 安全区）起
/// 渐到透明，到底栏中线全透明——内容滑到底栏下面时淡出，不被拦腰硬切。渐隐
/// 只落在底栏占的那一段里；列表末尾本来就留了 [inset] + 间距的空白，静止在
/// 底部时最后一块完全不受影响。
LinearGradient homeBottomFadeGradient({
  required double height,
  required double inset,
}) {
  if (height <= 0) {
    return const LinearGradient(colors: <Color>[Colors.white, Colors.white]);
  }
  final double end = ((height - inset * 0.5) / height).clamp(0.0, 1.0);
  final double start = ((height - inset) / height).clamp(0.0, end);
  return LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: const <Color>[Colors.white, Colors.white, Color(0x00FFFFFF)],
    stops: <double>[0, start, end],
  );
}
