import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/media/detail/media_detail_kit.dart';
import 'package:fushi/src/media/video/cover_ui/portrait_cover_image.dart';
import 'package:fushi/src/media/video/video_library_overview.dart'
    show formatVideoPosition;
import 'package:fushi/src/sync/remote_download_progress_badge.dart';
import 'package:fushi/src/utils/components/fushi_floating_chrome.dart'
    show FushiFloatingToolbarSurface;
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// 作品详情页的**共享布局**（2026-10 M3E 重做）：hero（fanart / 封面模糊 + 色晕
/// scrim 大背景、2:3 封面卡、Display 级标题 / logo、原名、元信息 chip 行、主操作
/// 按钮组、续播行、可展开简介）、作品资料区、「选集」区块标题、浮动胶囊季分段、
/// hayase 式宽集卡（缩略图 + 集号胶囊 + 播出日 / 时长 + 观看进度 + 已看对勾）。
///
/// 本地系列（`MediaCollectionDetailPage`）与媒体服务器（Jellyfin / Emby，
/// `MediaServerDetailView`）两个详情页**同一套视觉**：这里只吃纯值（标题 / 文案 /
/// ImageProvider / 回调），不知道数据来自 Drift 行还是远端 DTO。两边任何一处想改
/// 样式都改这里，不再各画一份。视觉积木来自作品详情共享骨架
/// （`media_detail_kit.dart`：背景、封面卡、chip、按钮组、简介、区块标题）。
///
/// 数据求值（续播是哪一集、徽标有哪些、缩略图 provider 怎么来）留在各自页面：
/// 那部分绑的是各自的数据源，抽进来只会让本文件长出两套 if。

/// hero 里的人物 chip：`kind` 是 `director` / `actor` / `voice_actor`（决定图标）。
class CollectionHeroCredit {
  const CollectionHeroCredit({required this.kind, required this.name});

  final String kind;
  final String name;
}

/// 横版 fanart 当大背景时的模糊强度：轻一点，保留画面气质。
const double kCollectionHeroBackdropBlur = 16;

/// 没有 fanart、拿 2:3 封面垫底时的模糊强度：重一点，只留色彩。
const double kCollectionHeroCoverBlur = 32;

/// hero 大背景该用哪张图：横版 fanart 优先，没有就拿封面模糊垫底。
/// 两栏布局（[MediaDetailLayout]）把背景画在整页后面时与 hero 同一判据。
ImageProvider? collectionHeroBackdropImage({
  ImageProvider? backdrop,
  ImageProvider? cover,
}) => backdrop ?? cover;

/// 与 [collectionHeroBackdropImage] 配套的模糊强度。
double collectionHeroBackdropBlur({ImageProvider? backdrop}) => backdrop != null
    ? kCollectionHeroBackdropBlur
    : kCollectionHeroCoverBlur;

/// hero 上的数字 / 标签胶囊描边（发现页详情仍在用的白字胶囊）：Apple 的 hero
/// 元信息是无描边的半透明胶囊（描边是 MD3 outlined chip 的语言），玻璃下去掉描边。
Border? _heroChipBorder(BuildContext context, double alpha) =>
    isGlassDesign(context)
    ? null
    : Border.all(color: Colors.white.withValues(alpha: alpha));

/// 作品详情 hero（M3E）：
///
/// - 大背景：有横版 [backdrop]（fanart）→ 轻模糊铺满（key
///   `collection-hero-backdrop`，多张轮换由调用方推进 [backdropIndex]、交叉淡入）；
///   没有 → 拿 [cover] 重模糊垫底（key `collection-hero-cover`）。两者之上是色晕 +
///   可读性 scrim，底部落到页面底色（[MediaDetailBackdrop]）。
/// - 2:3 封面卡（key `collection-hero-poster`）：[PortraitCoverImage] 按朝向分流，
///   横版截帧不会被裁成中间一条（BUG-1298 / BUG-1299 的同一条纪律）。
/// - 宽（≥ [kMediaDetailHeroWideMinWidth]）：封面在起始侧、信息靠底；窄：上下堆叠
///   居中；在 [MediaDetailLayout] 的两栏左栏里恒为窄式、不画自己的背景（整页背景
///   由布局画在两栏后面）。
/// - 高度随内容（不再钳死 60% 视口），长标题 / 长简介不会撑爆。
class CollectionDetailHero extends StatelessWidget {
  const CollectionDetailHero({
    required this.title,
    required this.onPlay,
    this.backdrop,
    this.backdropIndex = 0,
    this.cover,
    this.logo,
    this.semanticsName,
    this.originalTitle,
    this.airDate,
    this.badgeParts = const <String>[],
    this.chips,
    this.tagNames = const <String>[],
    this.credits = const <CollectionHeroCredit>[],
    this.summary,
    this.selectableSummary = true,
    this.continueLabel,
    this.playLabel,
    this.playIcon,
    this.playButtonKey,
    this.secondaryAction,
    this.secondaryActions = const <Widget>[],
    this.moreItems = const <MediaDetailMenuItem>[],
    this.footer,
    super.key,
  });

  /// 横版背景（多张轮换时传当前那张）。
  final ImageProvider? backdrop;

  /// 轮换下标：变化时背景交叉淡入到新图。
  final int backdropIndex;

  /// 2:3 海报（封面卡；没有 [backdrop] 时也拿它模糊垫底）。
  final ImageProvider? cover;

  /// 标题 logo：有则替代文字大标题（Jellyfin `.detailLogo` 同款），解码失败回落文字。
  final ImageProvider? logo;

  /// 文字大标题。
  final String title;

  /// logo 的读屏名（缺省 = [title]）。
  final String? semanticsName;

  /// 原名；与 [title] 相同时不重复占行。
  final String? originalTitle;

  /// 放送日期（小字压在大标题上方；空则不占位）。
  final String? airDate;

  /// 徽标行（数字事实：`全 12 话` / `★ 8.1` / `已看 3/12`），逐项存在才出。
  /// [chips] 非 null 时以它为准（可带图标 / 语气）。
  final List<String> badgeParts;

  /// 带图标 / 语气的元信息 chip；null = 由 [badgeParts] 生成中性 chip。
  final List<MediaDetailChip>? chips;

  /// 作品标签（题材，调用方已裁到前 6 个）。
  final List<String> tagNames;

  /// 人物 chips（一条横向轨道，key `collection-hero-credits`）。
  final List<CollectionHeroCredit> credits;

  /// 简介（可展开，spring）；null / 空不占位。
  final String? summary;

  /// 简介可选中（留给划词查词）；可选中时只能点「展开」按钮切换。
  final bool selectableSummary;

  /// 续播行文案（`继续看 第 3 集  ·  集名`）；null 不占位。
  final String? continueLabel;

  /// 主按钮文案（缺省 `t.collection_play`）。
  final String? playLabel;

  /// 主按钮图标（缺省播放）。
  final IconData? playIcon;

  /// 主按钮的 key（落在按钮本体上，测试定位用）。
  final Key? playButtonKey;

  final VoidCallback? onPlay;

  /// 主按钮旁的次按钮（兼容旧调用：单个 widget）；null 不占位。
  final Widget? secondaryAction;

  /// 更多次按钮（tonal，[MediaDetailSecondaryButton]）。
  final List<Widget> secondaryActions;

  /// 「⋯」菜单项；空 = 不出「⋯」。
  final List<MediaDetailMenuItem> moreItems;

  /// 简介下方的附加内容（用户标签等）。
  final Widget? footer;

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
                (wide ? tokens.spacing.section * 2 : tokens.spacing.section),
            page,
            tokens.spacing.section,
          ),
          child: wide ? _buildWide(context) : _buildNarrow(context),
        );
        return SizedBox(
          key: const ValueKey<String>('video-work-hero-card'),
          width: double.infinity,
          child: inSidePane
              ? content
              : Stack(
                  children: <Widget>[
                    Positioned.fill(child: _buildBackdrop()),
                    content,
                  ],
                ),
        );
      },
    );
  }

  /// 大背景：fanart 轻模糊 / 封面重模糊垫底（key 区分两条路，测试据此断言）。
  Widget _buildBackdrop() {
    final ImageProvider? backdrop = this.backdrop;
    if (backdrop != null) {
      return KeyedSubtree(
        key: const ValueKey<String>('collection-hero-backdrop'),
        child: MediaDetailBackdrop(
          image: backdrop,
          imageKey: backdropIndex,
          blurSigma: kCollectionHeroBackdropBlur,
        ),
      );
    }
    final ImageProvider? cover = this.cover;
    if (cover == null) return const MediaDetailBackdrop();
    return KeyedSubtree(
      key: const ValueKey<String>('collection-hero-cover'),
      child: MediaDetailBackdrop(
        image: cover,
        blurSigma: kCollectionHeroCoverBlur,
      ),
    );
  }

  /// 2:3 封面卡（无封面 → null，不占位）。
  Widget? _buildCoverCard(double width) {
    final ImageProvider? cover = this.cover;
    if (cover == null) return null;
    return MediaDetailCoverFrame(
      width: width,
      child: SizedBox.expand(
        key: const ValueKey<String>('collection-hero-poster'),
        child: PortraitCoverImage(
          image: cover,
          errorBuilder: (BuildContext _) =>
              const MediaDetailCoverPlaceholder(icon: FushiIcons.video),
        ),
      ),
    );
  }

  Widget _buildWide(BuildContext context) {
    final Widget? cover = _buildCoverCard(220);
    final Widget info = ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 760),
      child: _buildInfo(context, centered: false, wide: true),
    );
    if (cover == null) {
      return Align(alignment: AlignmentDirectional.bottomStart, child: info);
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: <Widget>[
        FushiStaggeredEntrance(index: 0, child: cover),
        const SizedBox(width: 32),
        Expanded(
          child: Align(alignment: AlignmentDirectional.bottomStart, child: info),
        ),
      ],
    );
  }

  Widget _buildNarrow(BuildContext context) {
    final Widget? cover = _buildCoverCard(168);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (cover != null) ...<Widget>[
          Center(child: FushiStaggeredEntrance(index: 0, child: cover)),
          const SizedBox(height: 20),
        ],
        _buildInfo(context, centered: true, wide: false),
      ],
    );
  }

  /// hero 文字区：日期 / logo 或标题 / 原名 / chip 行 / 标签 / 人物 / 续播 / 按钮组 /
  /// 简介 / 页脚。缺的逐项跳过（不占位、不显示「未知」）。
  Widget _buildInfo(
    BuildContext context, {
    required bool centered,
    required bool wide,
  }) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final FushiTypography type = context.fushiType;
    final String? airDate = this.airDate?.trim();
    final String? originalTitle = this.originalTitle?.trim();
    final String? summary = this.summary?.trim();
    final ImageProvider? logo = this.logo;
    final TextAlign align = centered ? TextAlign.center : TextAlign.start;
    final CrossAxisAlignment cross = centered
        ? CrossAxisAlignment.center
        : CrossAxisAlignment.start;
    final WrapAlignment wrap = centered
        ? WrapAlignment.center
        : WrapAlignment.start;
    final Widget titleText = _buildTitleText(context, align: align, wide: wide);
    final List<MediaDetailChip> chips =
        this.chips ??
        <MediaDetailChip>[
          for (final String part in badgeParts) MediaDetailChip(part),
        ];
    final String? continueLabel = this.continueLabel;
    return Column(
      crossAxisAlignment: cross,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        FushiStaggeredEntrance(
          index: 1,
          child: Column(
            crossAxisAlignment: cross,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              // 放送日期行（hayase 式：小字压在大标题上方）。
              if (airDate != null && airDate.isNotEmpty) ...<Widget>[
                Text(
                  airDate,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: align,
                  style: type.labelLargeEmphasized.tabular.copyWith(
                    color: cs.primary,
                  ),
                ),
                const SizedBox(height: 6),
              ],
              // v68：有标题 logo 时替代纯文字大标题。Semantics 保留名字——logo 是
              // 图，读屏与测试都还能按名字找到它；logo 解码失败回落文字标题。
              if (logo != null)
                Semantics(
                  label: semanticsName ?? title,
                  image: true,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: wide ? 120 : 88,
                      maxWidth: 460,
                    ),
                    child: Image(
                      key: const ValueKey<String>('collection-hero-logo'),
                      image: logo,
                      fit: BoxFit.contain,
                      alignment: centered
                          ? Alignment.bottomCenter
                          : AlignmentDirectional.bottomStart,
                      errorBuilder: (_, _, _) => titleText,
                    ),
                  ),
                )
              else
                titleText,
              // 原名与标题相同就不重复占一行。
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
                const SizedBox(height: 14),
                MediaDetailChipRow(chips: chips, alignment: wrap),
              ],
              if (tagNames.isNotEmpty) ...<Widget>[
                const SizedBox(height: 8),
                MediaDetailChipRow(
                  alignment: wrap,
                  chips: <MediaDetailChip>[
                    for (final String name in tagNames)
                      MediaDetailChip(
                        name,
                        tone: MediaDetailChipTone.secondary,
                      ),
                  ],
                ),
              ],
              if (credits.isNotEmpty) ...<Widget>[
                const SizedBox(height: 8),
                CollectionHeroCreditChips(credits: credits),
              ],
            ],
          ),
        ),
        if (continueLabel != null) ...<Widget>[
          const SizedBox(height: 16),
          FushiStaggeredEntrance(
            index: 2,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                FushiIcon(FushiIcons.history, size: 18, color: cs.primary),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    continueLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: type.labelLargeEmphasized.copyWith(
                      color: cs.onSurface,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 16),
        FushiStaggeredEntrance(
          index: 2,
          child: MediaDetailActionBar(
            alignment: wrap,
            primary: MediaDetailPrimaryButton(
              icon: playIcon ?? FushiIcons.play,
              label: playLabel ?? t.collection_play,
              onPressed: onPlay,
              buttonKey: playButtonKey,
            ),
            secondary: <Widget>[?secondaryAction, ...secondaryActions],
            more: moreItems.isEmpty
                ? null
                : MediaDetailMoreButton(
                    key: const ValueKey<String>('collection-hero-more'),
                    items: moreItems,
                  ),
          ),
        ),
        if ((summary != null && summary.isNotEmpty) || footer != null)
          FushiStaggeredEntrance(
            index: 3,
            child: Column(
              crossAxisAlignment: cross,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (summary != null && summary.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 20),
                  MediaDetailSynopsis(
                    key: const ValueKey<String>('collection-hero-summary'),
                    text: summary,
                    selectable: selectableSummary,
                    textAlign: align,
                  ),
                ],
                if (footer != null) ...<Widget>[
                  const SizedBox(height: 12),
                  footer!,
                ],
              ],
            ),
          ),
      ],
    );
  }

  /// hero 纯文字大标题（无 logo 的常态路径 / logo 解码失败回落共用）：宽屏
  /// Display、窄屏 Headline（Emphasized）。
  Widget _buildTitleText(
    BuildContext context, {
    required TextAlign align,
    required bool wide,
  }) {
    final FushiTypography type = context.fushiType;
    return Text(
      title,
      maxLines: 3,
      overflow: TextOverflow.ellipsis,
      textAlign: align,
      style: (wide ? type.displaySmallEmphasized : type.headlineMediumEmphasized)
          .copyWith(
            color: Theme.of(context).colorScheme.onSurface,
            height: 1.1,
          ),
    );
  }
}

/// 徽标 chips（hayase 式白字胶囊，压在深色封面图上）：这排是**数字事实**——
/// 话数/评分/进度。发现页详情仍用它；作品详情 hero 已换 [MediaDetailChipRow]。
class CollectionHeroBadgeChips extends StatelessWidget {
  const CollectionHeroBadgeChips({required this.parts, super.key});

  final List<String> parts;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: <Widget>[
        for (final String part in parts)
          DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.32),
              borderRadius: BorderRadius.circular(999),
              border: _heroChipBorder(context, 0.28),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
              child: Text(
                part,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  height: 1.2,
                  color: Colors.white.withValues(alpha: 0.92),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// 作品标签 chips（题材，白字胶囊，发现页详情用）。[Wrap] 而不是单行：标签长短不一。
class CollectionHeroTagChips extends StatelessWidget {
  const CollectionHeroTagChips({required this.names, super.key});

  final List<String> names;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: <Widget>[
        for (final String name in names)
          DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(999),
              border: _heroChipBorder(context, 0.22),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
              child: Text(
                name,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  height: 1.2,
                  color: Colors.white.withValues(alpha: 0.88),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// 人物 chips：hero 内只占一条横向轨道（M3E 元信息 chip 同款）。
class CollectionHeroCreditChips extends StatelessWidget {
  const CollectionHeroCreditChips({required this.credits, super.key});

  final List<CollectionHeroCredit> credits;

  static IconData iconFor(String creditKind) => switch (creditKind) {
    'director' => FushiIcons.video,
    'voice_actor' => FushiIcons.voice,
    _ => FushiIcons.person,
  };

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      key: const ValueKey<String>('collection-hero-credits'),
      height: 34,
      child: HorizontalDragScrollable(
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: <Widget>[
              for (int index = 0; index < credits.length; index++) ...<Widget>[
                if (index > 0) const SizedBox(width: 8),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 240),
                  child: MediaDetailChipView(
                    key: ValueKey<String>(
                      'collection-hero-credit-${credits[index].kind}-$index',
                    ),
                    chip: MediaDetailChip(
                      credits[index].name,
                      icon: iconFor(credits[index].kind),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 作品详情区：`作品资料` 区块标题 + 可展开可选中的简介 + 「标签 : 值」事实卡。
///
/// 两者都空时：[pendingText] 非空 → 画一张「资料待补」卡；否则整块不渲染。
/// [showOverview] = false：简介已在 hero 里展示，这里只用它判空（有简介就不是
/// 「资料待补」），不再重复渲染。
class CollectionWorkDetailsSection extends StatelessWidget {
  const CollectionWorkDetailsSection({
    this.overview,
    this.facts = const <(String, String)>[],
    this.pendingText,
    this.showOverview = true,
    super.key,
  });

  final String? overview;
  final List<(String, String)> facts;
  final String? pendingText;
  final bool showOverview;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme cs = Theme.of(context).colorScheme;
    final FushiTypography type = context.fushiType;
    final String? overview = this.overview?.trim();
    final bool hasOverview = overview != null && overview.isNotEmpty;
    if (!hasOverview && facts.isEmpty) {
      final String? pending = pendingText;
      if (pending == null) return const SizedBox.shrink();
      return Padding(
        key: const ValueKey<String>('video-work-details-pending'),
        padding: EdgeInsets.fromLTRB(
          tokens.spacing.page,
          tokens.spacing.section,
          tokens.spacing.page,
          0,
        ),
        child: FushiCard(
          padding: EdgeInsets.all(tokens.spacing.section),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              FushiIcon(FushiIcons.info, color: cs.onSurfaceVariant),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(t.video_work_details, style: type.titleMediumEmphasized),
                    const SizedBox(height: 4),
                    Text(
                      pending,
                      style: type.bodyMedium.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    }
    final bool renderOverview = showOverview && hasOverview;
    if (!renderOverview && facts.isEmpty) return const SizedBox.shrink();
    return Padding(
      key: const ValueKey<String>('video-work-details'),
      padding: EdgeInsets.symmetric(horizontal: tokens.spacing.page),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          MediaDetailSectionHeader(t.video_work_details),
          if (renderOverview)
            MediaDetailSynopsis(
              text: overview,
              selectable: true,
              collapsedLines: 6,
            ),
          if (facts.isNotEmpty) ...<Widget>[
            if (renderOverview) SizedBox(height: tokens.spacing.card),
            FushiCard(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  for (final (String label, String value) in facts)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          SizedBox(
                            width: 116,
                            child: Text(
                              label,
                              style: type.labelLargeEmphasized.copyWith(
                                color: cs.onSurfaceVariant,
                              ),
                            ),
                          ),
                          Expanded(
                            child: SelectableText(
                              value,
                              style: type.bodyMedium,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 「选集」一类区块标题：M3E 区块标题（titleLarge Emphasized + 计数胶囊 + 行尾
/// 动作），只带页边距、上下间距由调用方决定。
class CollectionSectionTitle extends StatelessWidget {
  const CollectionSectionTitle(this.text, {this.count, this.trailing, super.key});

  final String text;
  final int? count;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return MediaDetailSectionHeader(
      text,
      count: count,
      trailing: trailing,
      padding: EdgeInsets.symmetric(horizontal: tokens.spacing.page),
    );
  }
}

/// 季分段（M3E 浮动胶囊）：贴合内容宽的 floating toolbar 胶囊里一排可滚动页签，
/// 选中段是 secondaryContainer 全胶囊、切换时弹性滑过去；季多到放不下时胶囊吃满
/// 可用宽、页签在里面横滑。Apple 走玻璃分段页签。紧贴「选集」标题、在集列表
/// 之上。单季不该渲染本条（由调用方门控）。
class CollectionSeasonTabBar extends StatelessWidget {
  const CollectionSeasonTabBar({
    required this.controller,
    required this.labels,
    required this.tabKeys,
    this.onTap,
    super.key,
  });

  final TabController controller;
  final List<String> labels;

  /// 与 [labels] 等长；测试按 `collection-season-tab-<groupKey>` 定位。
  final List<Key> tabKeys;

  /// 页签被点（Enter / 手柄 A 同样走这里）；控制器的 index 已由 TabBar 推进。
  final ValueChanged<int>? onTap;

  /// 胶囊内边距（四周）。
  static const double _framePadding = 4;

  /// 单个页签文字两侧的内边距（框架 TabBar 的默认 labelPadding）。
  static const double _labelPadding = 16;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    assert(labels.length == tabKeys.length);
    final List<Widget> tabs = <Widget>[
      for (int i = 0; i < labels.length; i++)
        Tab(key: tabKeys[i], text: labels[i]),
    ];
    final Widget bar;
    if (isGlassDesign(context)) {
      bar = FushiTabBar(
        controller: controller,
        trackInset: 0,
        isScrollable: true,
        tabAlignment: TabAlignment.start,
        dividerHeight: 0,
        onTap: onTap,
        tabs: tabs,
      );
    } else {
      final TextStyle labelStyle = context.fushiType.titleSmallEmphasized;
      bar = LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final double natural = _naturalWidth(context, labelStyle);
          // +2：量尺取整的余量，免得刚好摆得下时多出一丝滚动范围。
          final double wanted = natural + _framePadding * 2 + 2;
          final double width = constraints.maxWidth.isFinite
              ? math.min(wanted, constraints.maxWidth)
              : wanted;
          return Align(
            alignment: AlignmentDirectional.centerStart,
            child: SizedBox(
              width: width,
              child: FushiFloatingToolbarSurface(
                height: 48,
                padding: const EdgeInsets.all(_framePadding),
                child: FushiTabBar(
                  controller: controller,
                  track: false,
                  padding: EdgeInsets.zero,
                  isScrollable: true,
                  tabAlignment: TabAlignment.start,
                  dividerHeight: 0,
                  labelStyle: labelStyle,
                  unselectedLabelStyle: context.fushiType.titleSmall,
                  onTap: onTap,
                  indicator: ShapeDecoration(
                    shape: const StadiumBorder(),
                    color: cs.secondaryContainer,
                  ),
                  indicatorSize: TabBarIndicatorSize.tab,
                  indicatorAnimation: TabIndicatorAnimation.elastic,
                  labelColor: cs.onSecondaryContainer,
                  unselectedLabelColor: cs.onSurfaceVariant,
                  splashBorderRadius: const BorderRadius.all(
                    Radius.circular(999),
                  ),
                  tabs: tabs,
                ),
              ),
            ),
          );
        },
      );
    }
    return Padding(
      key: const ValueKey<String>('collection-season-tabs'),
      // 胶囊左缘与「选集」标题、集列表同一条页边。
      padding: EdgeInsets.fromLTRB(
        tokens.spacing.page,
        tokens.spacing.gap,
        tokens.spacing.page,
        0,
      ),
      child: bar,
    );
  }

  /// 整排页签的自然宽（不含胶囊内边距）：逐个量文字 + 两侧 label 内边距。
  double _naturalWidth(BuildContext context, TextStyle style) {
    final TextScaler scaler = MediaQuery.textScalerOf(context);
    final TextDirection direction = Directionality.of(context);
    double width = 0;
    for (final String label in labels) {
      final TextPainter painter = TextPainter(
        text: TextSpan(text: label, style: style),
        maxLines: 1,
        textDirection: direction,
        textScaler: scaler,
      )..layout();
      width += painter.width + _labelPadding * 2;
      painter.dispose();
    }
    return width;
  }
}

/// hayase 式宽集卡的固定高度。
const double kCollectionEpisodeCardHeight = 128;

/// 集卡网格：宽度 ≥ 此值两列，否则一列。
const double kCollectionEpisodeTwoColumnMinWidth = 900;

/// 集卡内边距（缩略图高 = 卡高 − 2×它）。
const double kCollectionEpisodeCardPadding = 10;

/// 集卡缩略图尺寸（16:9）。
const double kCollectionEpisodeThumbHeight =
    kCollectionEpisodeCardHeight - kCollectionEpisodeCardPadding * 2;
const double kCollectionEpisodeThumbWidth =
    kCollectionEpisodeThumbHeight * 16 / 9;

/// 集卡网格列数（与本地详情页同一条规则）。
int collectionEpisodeColumns(double maxWidth) =>
    maxWidth >= kCollectionEpisodeTwoColumnMinWidth ? 2 : 1;

/// 集卡缩略图：有图走 [PortraitCoverImage] 横槽（解码失败退占位），无图占位。
Widget collectionEpisodeThumb(
  BuildContext context,
  ImageProvider? image, {
  double w = kCollectionEpisodeThumbWidth,
  double h = kCollectionEpisodeThumbHeight,
}) {
  final ColorScheme cs = Theme.of(context).colorScheme;
  if (image != null) {
    return ClipRRect(
      borderRadius: FushiBorderRadius.card,
      child: SizedBox(
        width: w,
        height: h,
        child: PortraitCoverImage(
          image: image,
          landscapeSlot: true,
          errorBuilder: (BuildContext _) =>
              collectionEpisodeThumbPlaceholder(w, h, cs),
        ),
      ),
    );
  }
  return collectionEpisodeThumbPlaceholder(w, h, cs);
}

Widget collectionEpisodeThumbPlaceholder(double w, double h, ColorScheme cs) =>
    Container(
      width: w,
      height: h,
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: FushiBorderRadius.card,
      ),
      child: FushiIcon(FushiIcons.video, color: cs.onSurfaceVariant, size: 22),
    );

/// 集号胶囊（压在集缩略图左上角）：常态 secondaryContainer，续播那一集 primary
/// 实色。Apple 用半透明系统底 / 强调色。
class CollectionEpisodeNumberPill extends StatelessWidget {
  const CollectionEpisodeNumberPill({
    required this.number,
    this.current = false,
    super.key,
  });

  final String number;
  final bool current;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool apple = isGlassDesign(context);
    final bool eink = isEinkTheme(context);
    final Color fill = current
        ? cs.primary
        : (apple
              ? cs.surface.withValues(alpha: 0.86)
              : cs.secondaryContainer);
    final Color fg = current
        ? cs.onPrimary
        : (apple ? cs.onSurface : cs.onSecondaryContainer);
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 30),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: eink ? cs.surface : fill,
          borderRadius: const BorderRadius.all(Radius.circular(999)),
          border: eink ? Border.all(color: cs.outline) : null,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
          child: Text(
            number,
            textAlign: TextAlign.center,
            maxLines: 1,
            style: context.fushiType.labelLargeEmphasized.tabular.copyWith(
              color: eink ? cs.onSurface : fg,
              height: 1.2,
            ),
          ),
        ),
      ),
    );
  }
}

/// 单张集卡（M3E）：左 16:9 缩略图（集号胶囊 + 云 / 下载角标）+ 右集名 / AniDB
/// 编号 / 播出日 · 时长 / 集简介 / 观看状态，底部观看进度条。
///
/// - 续播那一集整卡 primaryContainer 高亮（Apple 抬一阶 raised 底）；
/// - 已看完：tertiary 实心对勾、集名降为 onSurfaceVariant；
/// - 看了一半：知道总时长（[progress]）→ 底部 primary 进度条；算不出百分比时
///   不造假条，改在状态行给「看到 mm:ss」。
///
/// 纯视觉（手势归外层网格 / 焦点目标），整卡 [IgnorePointer]，调用方自己包
/// [FushiFocusTarget] / [Actions]。
class CollectionEpisodeCard extends StatelessWidget {
  const CollectionEpisodeCard({
    required this.thumb,
    required this.number,
    required this.title,
    this.summary,
    this.completed = false,
    this.positionMs = 0,
    this.progress,
    this.meta = const <String>[],
    this.isContinue = false,
    this.isRemote = false,
    this.downloadBadge,
    this.trailingStatus,
    this.identityLabel,
    super.key,
  });

  /// 已按 [kCollectionEpisodeThumbWidth] × [kCollectionEpisodeThumbHeight]
  /// 定尺的缩略图（用 [collectionEpisodeThumb] 造）。
  final Widget thumb;

  /// 显示序号（`3` / `S01E03`），画在缩略图左上角的集号胶囊里。
  final String number;
  final String title;
  final String? summary;
  final bool completed;

  /// 文件身份给出的**另一套**编号（`AniDB 第 04 集`）：Shoko 同时暴露 AniDB
  /// 原生编号与 TMDB 季集，这里作为集名下的小字并存，不改 [number]。
  final String? identityLabel;

  /// 看到的位置（ms）；>0 且未看完时显示进度条或「看到 mm:ss」。
  final int positionMs;

  /// 观看进度 0..1（总时长已知时）；null = 算不出，不画进度条。
  final double? progress;

  /// 元信息（播出日 / 时长），逐项存在才出。
  final List<String> meta;

  /// 续播那一集（整卡高亮）。
  final bool isContinue;

  /// 只在对端 / 远端（缩略图右下角云角标）。
  final bool isRemote;

  /// 这一集正在 / 刚刚从对端下载到本机时盖在云角标位上的下载态角标（进度环 /
  /// 失败角标，由调用方按下载管理器的任务快照造）。非 null 时替换云角标：
  /// 「在下载」本身就蕴含「在对端」，同一个角不叠两枚。
  final Widget? downloadBadge;

  /// 状态行右端（本地页放规格摘要 `1080p · HEVC`）。
  final Widget? trailingStatus;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final FushiTypography type = context.fushiType;
    final bool apple = isGlassDesign(context);
    final bool eink = isEinkTheme(context);
    final bool started = positionMs > 0 && !completed;
    final bool highlight = isContinue && !eink;
    // Apple：primaryContainer 在单色强调色下就是灰填充，续播集认不出来；改用
    // 高一阶的实色 raised 底（iOS 选中行同款）。M3E：续播集 = primaryContainer
    // 饱和色块。卡圆角走 M3E 卡档 20（内边距 10 + 缩略图 12 近似同心）。
    final Color container = highlight
        ? (apple ? cs.surfaceContainerHigh : cs.primaryContainer)
        : cs.surfaceContainerLow;
    final Color fg = highlight && !apple ? cs.onPrimaryContainer : cs.onSurface;
    final Color fgVariant = highlight && !apple
        ? cs.onPrimaryContainer.withValues(alpha: 0.78)
        : cs.onSurfaceVariant;
    final double? progress = this.progress;
    final double? fraction = started && progress != null && progress > 0
        ? progress.clamp(0.0, 1.0)
        : null;
    final List<String> meta = <String>[
      for (final String part in this.meta)
        if (part.trim().isNotEmpty) part.trim(),
    ];
    final String? summary = this.summary?.trim();
    final Widget statusRow = Row(
      children: <Widget>[
        if (completed)
          FushiIcon(
            FushiIcons.filled(FushiIcons.success),
            key: const ValueKey<String>('collection-episode-completed'),
            color: apple ? cs.primary : cs.tertiary,
            size: 18,
          )
        else if (started && fraction == null) ...<Widget>[
          FushiIcon(FushiIcons.playCircle, color: fgVariant, size: 16),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              t.collection_episode_watched_at(
                position: formatVideoPosition(positionMs),
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: type.labelMedium.tabular.copyWith(color: fgVariant),
            ),
          ),
        ],
        if (trailingStatus != null)
          Expanded(
            child: Align(
              alignment: AlignmentDirectional.centerEnd,
              child: trailingStatus,
            ),
          ),
      ],
    );
    return IgnorePointer(
      child: Material(
        color: container,
        borderRadius: FushiM3eShape.cardRadius,
        clipBehavior: Clip.antiAlias,
        child: Stack(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.all(kCollectionEpisodeCardPadding),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Stack(
                    children: <Widget>[
                      thumb,
                      PositionedDirectional(
                        start: 6,
                        top: 6,
                        child: CollectionEpisodeNumberPill(
                          number: number,
                          current: isContinue,
                        ),
                      ),
                      // 进行中 → 铺满缩略图的压暗 + 进度环；失败 → 右下角标。
                      if (downloadBadge case final Widget badge)
                        positionRemoteDownloadBadge(
                          badge,
                          corner: (Widget b) =>
                              Positioned(right: 4, bottom: 4, child: b),
                        )
                      else if (isRemote)
                        const Positioned(
                          right: 4,
                          bottom: 4,
                          child: CoverBadge(icon: FushiIcons.cloud),
                        ),
                    ],
                  ),
                  SizedBox(width: tokens.spacing.rowVertical),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style:
                              (isContinue
                                      ? type.titleMediumEmphasized
                                      : type.titleMedium)
                                  .copyWith(
                                    color: completed && !isContinue
                                        ? fgVariant
                                        : fg,
                                    height: 1.3,
                                  ),
                        ),
                        if (identityLabel case final String label
                            when label.isNotEmpty)
                          Text(
                            label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: type.labelSmall.copyWith(
                              height: 1.3,
                              color: fgVariant,
                            ),
                          ),
                        if (meta.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              meta.join('  ·  '),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: type.labelMedium.tabular.copyWith(
                                color: fgVariant,
                              ),
                            ),
                          ),
                        // 简介吃剩余高度（放不下就省略），卡高恒定不溢出。
                        if (summary != null && summary.isNotEmpty)
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Align(
                                alignment: AlignmentDirectional.topStart,
                                child: Text(
                                  summary,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: type.bodySmall.copyWith(
                                    color: fgVariant,
                                    height: 1.3,
                                  ),
                                ),
                              ),
                            ),
                          )
                        else
                          const Spacer(),
                        statusRow,
                      ],
                    ),
                  ),
                ],
              ),
            ),
            if (fraction != null)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: FushiLinearProgressIndicator(
                  key: const ValueKey<String>('collection-episode-progress'),
                  value: fraction,
                  minHeight: 4,
                  backgroundColor: Colors.transparent,
                  color: cs.primary,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
