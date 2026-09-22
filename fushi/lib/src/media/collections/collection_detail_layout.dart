import 'package:flutter/material.dart';
import 'package:fushi/src/media/video/cover_ui/landscape_cover_image.dart';
import 'package:fushi/src/media/video/cover_ui/portrait_cover_image.dart';
import 'package:fushi/src/media/video/video_library_overview.dart'
    show formatVideoPosition;
import 'package:fushi/utils.dart';

/// 作品详情页的**共享布局**：hero（背景轮换 / 海报卡 / logo / 徽标 / 标签 / 人物 /
/// 简介 / 续播 / 播放）、作品详情区、「选集」标题、季 tab 条、hayase 式宽集卡。
///
/// 本地系列（`MediaCollectionDetailPage`）与媒体服务器（Jellyfin / Emby，
/// `MediaServerDetailView`）两个详情页**同一套视觉**：这里只吃纯值（标题 / 文案 /
/// ImageProvider / 回调），不知道数据来自 Drift 行还是远端 DTO。视觉代码是从
/// 本地详情页逐行搬来的，本地页面改为消费本文件后必须逐像素不变；两边任何一处
/// 想改样式都改这里，不再各画一份。
///
/// 数据求值（续播是哪一集、徽标有哪些、缩略图 provider 怎么来）留在各自页面：
/// 那部分绑的是各自的数据源，抽进来只会让本文件长出两套 if。

/// hero 里的人物 chip：`kind` 是 `director` / `actor` / `voice_actor`（决定图标）。
class CollectionHeroCredit {
  const CollectionHeroCredit({required this.kind, required this.name});

  final String kind;
  final String name;
}

/// 详情页 hero：60% 视口高（460–680）。
///
/// 背景分两条路（BUG-1298）：有横版 [backdrop] → cover 铺满 + 左侧独立 2:3 海报卡
/// （宽度 ≥ 900 才放）；没有 → 只有 [cover]，交给 [LandscapeCoverImage] 判朝向
/// （横图铺满，竖版海报模糊垫底 + 靠右完整显示），此时不再另放海报卡。
///
/// 多张背景轮换由调用方推进 [backdropIndex]（内层 key 随它变化驱动交叉淡入）。
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
    this.tagNames = const <String>[],
    this.credits = const <CollectionHeroCredit>[],
    this.summary,
    this.continueLabel,
    this.playLabel,
    this.playButtonKey,
    super.key,
  });

  /// 横版背景（多张轮换时传当前那张）。
  final ImageProvider? backdrop;

  /// 轮换下标：变化时 [AnimatedSwitcher] 交叉淡入到新图。
  final int backdropIndex;

  /// 2:3 海报（有 [backdrop] 时作左侧海报卡；否则作整块背景）。
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
  final List<String> badgeParts;

  /// 作品标签（题材，调用方已裁到前 6 个）。
  final List<String> tagNames;

  /// 人物 chips（一条横向轨道）。
  final List<CollectionHeroCredit> credits;

  /// 简介（hero 内两行省略；有全宽详情区时调用方传 null）。
  final String? summary;

  /// 续播行文案（`继续看 第 3 集  ·  集名`）；null 不占位。
  final String? continueLabel;

  /// 播放按钮文案（缺省 `t.collection_play`）。
  final String? playLabel;

  /// 播放按钮的 key（测试定位用）。
  final Key? playButtonKey;

  final VoidCallback? onPlay;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final Size screen = MediaQuery.sizeOf(context);
    final double height = (screen.height * 0.60).clamp(460.0, 680.0);
    final bool rtl = Directionality.of(context) == TextDirection.rtl;
    // 可读性渐变：压在封面之上、竖版海报前景之下（层序由 [LandscapeCoverImage]
    // 保证，见该组件文档）。无封面时直接铺在底色上。
    final List<Widget> overlays = <Widget>[
      const DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            stops: <double>[0, 0.48, 1],
            colors: <Color>[
              Color(0x52000000),
              Color(0x22000000),
              Color(0xE8000000),
            ],
          ),
        ),
      ),
      DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: rtl ? Alignment.centerRight : Alignment.centerLeft,
            end: rtl ? Alignment.centerLeft : Alignment.centerRight,
            stops: const <double>[0, 0.66, 1],
            colors: const <Color>[
              Color(0xC9000000),
              Color(0x26000000),
              Color(0x7A000000),
            ],
          ),
        ),
      ),
    ];
    final ImageProvider? backdrop = this.backdrop;
    final ImageProvider? cover = this.cover;
    return SizedBox(
      key: const ValueKey<String>('video-work-hero-card'),
      width: double.infinity,
      height: height,
      child: ClipRect(
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            ColoredBox(color: cs.surfaceContainerHighest),
            if (backdrop != null) ...<Widget>[
              // v68：多张背景 10 秒轮换（Jellyfin 详情页同款）。外层 key 恒定供
              // 测试定位；内层 key 随轮换下标变化驱动 AnimatedSwitcher 交叉淡入。
              // gaplessPlayback：新图解码完成前保留旧帧，避免轮换瞬间闪底色。
              KeyedSubtree(
                key: const ValueKey<String>('collection-hero-backdrop'),
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 700),
                  // AnimatedSwitcher 缺省 layoutBuilder 是宽松 Stack，Image 会按
                  // 原图尺寸居中而不铺满；SizedBox.expand 给它 hero 的紧约束，
                  // 小于 hero 的 backdrop（服务器缩略图、高 dpr 大屏）也按 cover 铺满。
                  child: SizedBox.expand(
                    key: ValueKey<int>(backdropIndex),
                    child: Image(
                      image: backdrop,
                      fit: BoxFit.cover,
                      alignment: Alignment.center,
                      gaplessPlayback: true,
                      errorBuilder: (_, __, ___) =>
                          ColoredBox(color: cs.surfaceContainerHighest),
                    ),
                  ),
                ),
              ),
              ...overlays,
            ] else if (cover != null)
              LandscapeCoverImage(
                key: const ValueKey<String>('collection-hero-cover'),
                image: cover,
                overlays: overlays,
                // 竖版海报避让顶部 AppBar 与底部内容区，靠右不压左下标题/播放按钮。
                foregroundPadding: EdgeInsetsDirectional.only(
                  top: tokens.spacing.gap,
                  bottom: tokens.spacing.section,
                  end: tokens.spacing.page,
                ),
                errorBuilder: (BuildContext _) =>
                    ColoredBox(color: cs.surfaceContainerHighest),
              )
            else
              ...overlays,
            Padding(
              padding: EdgeInsets.fromLTRB(
                tokens.spacing.page,
                tokens.spacing.section,
                tokens.spacing.page,
                tokens.spacing.section,
              ),
              child: LayoutBuilder(
                builder: (BuildContext context, BoxConstraints constraints) {
                  final Widget info = ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 680),
                    child: _buildInfo(context, tokens),
                  );
                  // 海报卡只在「有横版背景 + 宽度够」时出现：窄屏放不下 2:3 卡还要
                  // 留 680 给文字，挤压的结果是标题被压成一列竖排字。
                  final bool showPoster =
                      backdrop != null &&
                      cover != null &&
                      constraints.maxWidth >= 900;
                  if (!showPoster) {
                    return Align(
                      alignment: AlignmentDirectional.bottomStart,
                      child: info,
                    );
                  }
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: <Widget>[
                      _buildPosterCard(cover, height),
                      SizedBox(width: tokens.spacing.section),
                      Expanded(
                        child: Align(
                          alignment: AlignmentDirectional.bottomStart,
                          child: info,
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// hero 左侧的竖版海报卡（仅在有横版背景时出现）。2:3 是海报的正确槽向。
  Widget _buildPosterCard(ImageProvider cover, double heroHeight) {
    final double posterHeight = (heroHeight * 0.78).clamp(280.0, 500.0);
    return ClipRRect(
      borderRadius: FushiBorderRadius.card,
      child: SizedBox(
        key: const ValueKey<String>('collection-hero-poster'),
        height: posterHeight,
        width: posterHeight * 2 / 3,
        child: PortraitCoverImage(image: cover),
      ),
    );
  }

  /// hero 文字区：日期 / logo 或标题 / 原名 / 徽标 / 标签 / 人物 / 简介 / 续播 / 播放。
  /// 缺的逐项跳过（不占位、不显示「未知」）。
  Widget _buildInfo(BuildContext context, FushiDesignTokens tokens) {
    final TextTheme text = Theme.of(context).textTheme;
    final String? airDate = this.airDate?.trim();
    final String? originalTitle = this.originalTitle;
    final String? summary = this.summary?.trim();
    final ImageProvider? logo = this.logo;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        // 放送日期行（hayase 式：小字压在大标题上方）。
        if (airDate != null && airDate.isNotEmpty) ...<Widget>[
          Text(
            airDate,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: text.labelMedium?.copyWith(
              color: Colors.white.withValues(alpha: 0.7),
              fontWeight: FontWeight.w600,
              letterSpacing: 0.4,
            ),
          ),
          SizedBox(height: tokens.spacing.gap / 2),
        ],
        // v68：有标题 logo 时替代纯文字大标题。Semantics 保留名字——logo 是图，
        // 读屏与测试都还能按名字找到它；logo 解码失败回落文字标题。
        if (logo != null)
          Semantics(
            label: semanticsName ?? title,
            image: true,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 110, maxWidth: 460),
              child: Image(
                key: const ValueKey<String>('collection-hero-logo'),
                image: logo,
                fit: BoxFit.contain,
                alignment: AlignmentDirectional.bottomStart,
                errorBuilder: (_, __, ___) => _buildTitleText(text),
              ),
            ),
          )
        else
          _buildTitleText(text),
        // 原名与标题相同就不重复占一行。
        if (originalTitle != null &&
            originalTitle.isNotEmpty &&
            originalTitle != title) ...<Widget>[
          SizedBox(height: tokens.spacing.gap / 2),
          Text(
            originalTitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: text.bodyMedium?.copyWith(
              color: Colors.white.withValues(alpha: 0.72),
            ),
          ),
        ],
        SizedBox(height: tokens.spacing.gap),
        CollectionHeroBadgeChips(parts: badgeParts),
        if (tagNames.isNotEmpty) ...<Widget>[
          SizedBox(height: tokens.spacing.gap),
          CollectionHeroTagChips(names: tagNames),
        ],
        if (credits.isNotEmpty) ...<Widget>[
          SizedBox(height: tokens.spacing.gap),
          CollectionHeroCreditChips(credits: credits),
        ],
        if (summary != null && summary.isNotEmpty) ...<Widget>[
          SizedBox(height: tokens.spacing.card),
          // Flexible + ellipsis：简介长度不可控，hero 高度是钳死的，必须让它先收缩
          // 再截断，否则长简介直接把 Column 撑出 RenderFlex overflow。
          Flexible(
            child: Text(
              summary,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: text.bodyMedium?.copyWith(
                color: Colors.white.withValues(alpha: 0.78),
                height: 1.35,
              ),
            ),
          ),
        ],
        if (continueLabel != null) ...<Widget>[
          SizedBox(height: tokens.spacing.card),
          Text(
            continueLabel!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: text.labelLarge?.copyWith(
              color: Colors.white.withValues(alpha: 0.82),
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
        SizedBox(height: tokens.spacing.card),
        FilledButton.icon(
          key: playButtonKey,
          icon: const Icon(Icons.play_arrow_rounded),
          label: Text(playLabel ?? t.collection_play),
          onPressed: onPlay,
        ),
      ],
    );
  }

  /// hero 纯文字大标题（无 logo 的常态路径 / logo 解码失败回落共用）。
  Widget _buildTitleText(TextTheme text) {
    return Text(
      title,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: text.displaySmall?.copyWith(
        color: Colors.white,
        fontWeight: FontWeight.w700,
        height: 1.08,
      ),
    );
  }
}

/// 徽标 chips（hayase 式胶囊）：这排是**数字事实**——话数/评分/进度。
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
              border: Border.all(color: Colors.white.withValues(alpha: 0.28)),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
              child: Text(
                part,
                style: TextStyle(
                  fontSize: 12.5,
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

/// 作品标签 chips（题材）。[Wrap] 而不是单行：标签长短不一。
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
              border: Border.all(color: Colors.white.withValues(alpha: 0.22)),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
              child: Text(
                name,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.2,
                  color: Colors.white.withValues(alpha: 0.88),
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// 人物 chips：固定高 hero 内只占一条横向轨道。
class CollectionHeroCreditChips extends StatelessWidget {
  const CollectionHeroCreditChips({required this.credits, super.key});

  final List<CollectionHeroCredit> credits;

  static IconData iconFor(String creditKind) => switch (creditKind) {
    'director' => Icons.movie_creation_outlined,
    'voice_actor' => Icons.record_voice_over_outlined,
    _ => Icons.person_outline,
  };

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      key: const ValueKey<String>('collection-hero-credits'),
      height: 28,
      child: HorizontalDragScrollable(
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: <Widget>[
              for (int index = 0; index < credits.length; index++) ...<Widget>[
                if (index > 0) const SizedBox(width: 6),
                DecoratedBox(
                  key: ValueKey<String>(
                    'collection-hero-credit-${credits[index].kind}-$index',
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.32),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.24),
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 9,
                      vertical: 3,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Icon(
                          iconFor(credits[index].kind),
                          size: 13,
                          color: Colors.white.withValues(alpha: 0.76),
                        ),
                        const SizedBox(width: 5),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 220),
                          child: Text(
                            credits[index].name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              height: 1.2,
                              color: Colors.white.withValues(alpha: 0.9),
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ],
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

/// 作品详情区：`作品资料` 标题 + 可选择的全文简介 + 「标签 : 值」事实行。
///
/// 两者都空时：[pendingText] 非空 → 画一张「资料待补」卡；否则整块不渲染。
class CollectionWorkDetailsSection extends StatelessWidget {
  const CollectionWorkDetailsSection({
    this.overview,
    this.facts = const <(String, String)>[],
    this.pendingText,
    super.key,
  });

  final String? overview;
  final List<(String, String)> facts;
  final String? pendingText;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final String? overview = this.overview?.trim();
    if ((overview == null || overview.isEmpty) && facts.isEmpty) {
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
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                t.video_work_details,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              SizedBox(height: tokens.spacing.card),
              Text(
                pending,
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      );
    }
    return Padding(
      key: const ValueKey<String>('video-work-details'),
      padding: EdgeInsets.fromLTRB(
        tokens.spacing.page,
        tokens.spacing.section,
        tokens.spacing.page,
        0,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            t.video_work_details,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          if (overview != null && overview.isNotEmpty) ...<Widget>[
            SizedBox(height: tokens.spacing.card),
            SelectableText(
              overview,
              style: Theme.of(
                context,
              ).textTheme.bodyLarge?.copyWith(height: 1.55),
            ),
          ],
          for (final (String label, String value) in facts)
            Padding(
              padding: EdgeInsets.only(top: tokens.spacing.card),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  SizedBox(
                    width: 116,
                    child: Text(
                      label,
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                  ),
                  Expanded(child: SelectableText(value)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// 「选集」一类区块标题（titleLarge 加粗，带页边距）。
class CollectionSectionTitle extends StatelessWidget {
  const CollectionSectionTitle(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: tokens.spacing.page),
      child: Text(
        text,
        style: Theme.of(
          context,
        ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
      ),
    );
  }
}

/// 季 tab 条（MD3 可滚动 [TabBar]）：紧贴「选集」标题、在集列表之上。
/// 单季不该渲染本条（由调用方门控）。
class CollectionSeasonTabBar extends StatelessWidget {
  const CollectionSeasonTabBar({
    required this.controller,
    required this.labels,
    required this.tabKeys,
    super.key,
  });

  final TabController controller;
  final List<String> labels;

  /// 与 [labels] 等长；测试按 `collection-season-tab-<groupKey>` 定位。
  final List<Key> tabKeys;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    assert(labels.length == tabKeys.length);
    return Padding(
      key: const ValueKey<String>('collection-season-tabs'),
      padding: EdgeInsets.only(top: tokens.spacing.gap),
      child: TabBar(
        controller: controller,
        isScrollable: true,
        tabAlignment: TabAlignment.start,
        padding: EdgeInsets.symmetric(horizontal: tokens.spacing.page),
        labelColor: cs.primary,
        unselectedLabelColor: cs.onSurfaceVariant,
        indicatorColor: cs.primary,
        dividerColor: Colors.transparent,
        tabs: <Widget>[
          for (int i = 0; i < labels.length; i++)
            Tab(key: tabKeys[i], text: labels[i]),
        ],
      ),
    );
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
      child: Icon(Icons.movie_outlined, color: cs.onSurfaceVariant, size: 20),
    );

/// 单张集卡：左 16:9 缩略图 + 右「N. 集名」/集简介两行/观看状态，底部进度条。
///
/// 进度条只画**真实事实**：看完 → 满格；看了一半算不出百分比时不造假条，改在
/// 状态行给「看到 mm:ss」。纯视觉（手势归外层网格 / 焦点目标），整卡
/// [IgnorePointer]，调用方自己包 [FushiFocusTarget] / [Actions]。
class CollectionEpisodeCard extends StatelessWidget {
  const CollectionEpisodeCard({
    required this.thumb,
    required this.number,
    required this.title,
    this.summary,
    this.completed = false,
    this.positionMs = 0,
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

  /// 显示序号（`3` / `S01E03`），前面会拼 `. `。
  final String number;
  final String title;
  final String? summary;
  final bool completed;

  /// 文件身份给出的**另一套**编号（`AniDB 第 04 集`）：Shoko 同时暴露 AniDB
  /// 原生编号与 TMDB 季集，这里作为序号行下的小字并存，不改 [number]。
  final String? identityLabel;

  /// 看到的位置（ms）；>0 且未看完时显示「看到 mm:ss」。
  final int positionMs;

  /// 续播那一集（底色高亮）。
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
    final bool started = positionMs > 0 && !completed;
    final String? summary = this.summary;
    return IgnorePointer(
      child: Material(
        color: isContinue
            ? cs.primaryContainer.withValues(alpha: 0.35)
            : cs.surfaceContainerLow,
        borderRadius: FushiBorderRadius.card,
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
                      if (downloadBadge case final Widget badge)
                        Positioned(right: 4, bottom: 4, child: badge)
                      else if (isRemote)
                        const Positioned(
                          right: 4,
                          bottom: 4,
                          child: CoverBadge(icon: Icons.cloud_outlined),
                        ),
                    ],
                  ),
                  SizedBox(width: tokens.spacing.rowVertical),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          '$number. $title',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        if (identityLabel case final String label
                            when label.isNotEmpty)
                          Text(
                            label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11,
                              height: 1.3,
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                        if (summary != null && summary.isNotEmpty) ...<Widget>[
                          SizedBox(height: tokens.spacing.gap / 2),
                          Text(
                            summary,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              height: 1.3,
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                        ],
                        const Spacer(),
                        Row(
                          children: <Widget>[
                            if (completed)
                              Icon(
                                Icons.check_circle,
                                color: cs.primary,
                                size: 16,
                              )
                            else if (started) ...<Widget>[
                              Icon(
                                Icons.play_circle_outline,
                                color: cs.onSurfaceVariant,
                                size: 16,
                              ),
                              SizedBox(width: tokens.spacing.gap / 2),
                              Text(
                                t.collection_episode_watched_at(
                                  position: formatVideoPosition(positionMs),
                                ),
                                style: TextStyle(
                                  fontSize: 12,
                                  color: cs.onSurfaceVariant,
                                ),
                              ),
                            ],
                            if (trailingStatus != null)
                              Flexible(
                                child: Align(
                                  alignment: Alignment.centerRight,
                                  child: trailingStatus,
                                ),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            if (completed)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: LinearProgressIndicator(
                  value: 1,
                  minHeight: 3,
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
