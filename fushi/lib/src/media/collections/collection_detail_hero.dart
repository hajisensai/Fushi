/// 合集详情页 hero（书架 / 漫画库 / 游戏库共用）：堆叠封面大图 + 合集名 + 项数 /
/// 读完数 + 整体进度（M3E 波浪条 + Display 级百分比；Apple 细线条）+ 彩色标签
/// chip 与「编辑标签」。
///
/// 不放「继续」按钮（2026-10-28 用户拍板砍掉），但续播入口不能跟着丢（用户
/// 同日：「不要按钮，但是要用户知道点击可以继续观看」）：与库页外的「继续」
/// 大卡同一约定——整块点按 = 继续 [onContinue]，标题下「▶ 继续 · 成员名」
/// 一行示意点了会接着看哪一部（封面上的播放标记试过，用户嫌丑撤掉）。底色与「继续」大卡同一块色（[fushiHeroBlockColor]），封面平贴在
/// 色块里（[ShelfCoverFrame.flat]，不画材质投影），里外统一。
///
/// 宽窄同一排法：封面在起始侧、其余信息全在旁边一列；窄屏只缩封面与百分比
/// 字号（[wide]）。只吃纯值与回调，进度怎么算
/// 在页面与 `collection_member_view.dart`。
library;

import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/media/tags/tag_chips.dart';
import 'package:fushi/src/utils/components/fushi_expressive_progress.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_continue_hero.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/components/shelf_cover_material.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

class CollectionDetailHeroCard extends StatelessWidget {
  const CollectionDetailHeroCard({
    required this.name,
    required this.memberCount,
    super.key,
    this.finished,
    this.progress,
    this.covers = const <Widget>[],
    this.tags = const <BookTagRow>[],
    this.onEditTags,
    this.onContinue,
    this.continueLabel,
    this.wide = false,
  });

  final String name;
  final int memberCount;

  /// 读完数；null = 调用方没有读完信息（不显示「已读完」）。
  final int? finished;

  /// 整体进度 0..1；null = 不画进度。
  final double? progress;

  /// 前几本的纯封面（首个在最前），最多取 3 张堆叠。
  final List<Widget> covers;
  final List<BookTagRow> tags;
  final VoidCallback? onEditTags;

  /// 整块点按 = 继续（接着看 / 读 [continueLabel] 那一部）；null = 不可点。
  final VoidCallback? onContinue;

  /// 点了会接着的成员名（「▶ 继续 · 名字」那一行）；null / 空 = 不画该行。
  final String? continueLabel;
  final bool wide;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final bool apple = isGlassDesign(context);
    final bool eink = isEinkTheme(context);
    final double coverWidth = wide ? 184 : 96;

    final Widget cover = _StackedCovers(covers: covers, width: coverWidth);
    final Color accent = eink
        ? scheme.onSurface
        : (apple ? appleColorsOf(context).accent : scheme.primary);
    final String? nextName = continueLabel;

    final TextStyle? titleStyle =
        (wide ? theme.textTheme.headlineMedium : theme.textTheme.titleLarge)
            ?.copyWith(fontWeight: FontWeight.w800, height: 1.15);

    final List<String> meta = <String>[
      t.collection_detail_member_count(n: memberCount),
      if (finished != null)
        t.collection_detail_finished_count(done: finished!, total: memberCount),
    ];

    final Widget heading = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          name,
          key: const ValueKey<String>('collection_detail_hero_name'),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: titleStyle,
        ),
        SizedBox(height: tokens.spacing.gap),
        Text(
          meta.join('  ·  '),
          key: const ValueKey<String>('collection_detail_hero_meta'),
          style: tokens.type.listSubtitle,
        ),
        if (onContinue != null && nextName != null && nextName.isNotEmpty)
          Padding(
            padding: EdgeInsets.only(top: tokens.spacing.gap),
            child: Row(
              key: const ValueKey<String>('collection_detail_hero_continue'),
              children: <Widget>[
                FushiIcon(FushiIcons.play, size: 18, color: accent),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    '${t.home_continue} · $nextName',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: tokens.type.sectionLabel.copyWith(color: accent),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
    final List<Widget> details = <Widget>[
      if (progress != null) ...<Widget>[
        SizedBox(height: tokens.spacing.gap * 1.5),
        _HeroProgress(value: progress!, compact: !wide),
      ],
      if (tags.isNotEmpty || onEditTags != null) ...<Widget>[
        SizedBox(height: tokens.spacing.gap * 1.5),
        Wrap(
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
              _HeroActionChip(
                key: const ValueKey<String>('collection_detail_edit_tags'),
                icon: FushiIcons.tag,
                label: t.collection_detail_edit_tags,
                onTap: onEditTags!,
              ),
          ],
        ),
      ],
    ];

    // 宽窄同一排法：封面在起始侧，标题 / 项数 / 继续 / 进度 / 标签全进旁边一列
    // （用户 2026-10-28：窄屏此前把进度与标签放在封面下方，封面右侧空出一大
    // 块）。窄屏只缩封面、间距与百分比字号。
    final Widget body = Row(
      crossAxisAlignment: wide
          ? CrossAxisAlignment.center
          : CrossAxisAlignment.start,
      children: <Widget>[
        cover,
        SizedBox(width: wide ? tokens.spacing.card * 1.5 : 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[heading, ...details],
          ),
        ),
      ],
    );

    if (apple && onContinue == null) {
      return Padding(padding: EdgeInsets.all(tokens.spacing.card), child: body);
    }
    if (onContinue == null) {
      // M3E：primaryContainer 色块分区（圆角 28），把 hero 和成员区分开。
      return Container(
        padding: EdgeInsets.all(tokens.spacing.card * (wide ? 1.5 : 1)),
        decoration: BoxDecoration(
          color: eink ? scheme.surface : collectionHeroBackground(scheme),
          borderRadius: FushiM3eShape.containerLargeRadius,
          border: eink ? Border.all(color: scheme.outline) : null,
        ),
        child: body,
      );
    }
    // 可续播：与「继续」大卡同一套整卡交互（点按 / 焦点环 / 按压下沉 / 悬停抬升），
    // 色块与圆角同上；Apple 与「继续」卡一样落在分组底色上。
    return FushiHoverLift(
      scale: 1.01,
      builder: (BuildContext _, bool __) => FushiCard(
        key: const ValueKey<String>('collection_detail_hero_card'),
        color: eink
            ? scheme.surface
            : (apple
                  ? tokens.surfaces.group
                  : collectionHeroBackground(scheme)),
        borderColor: eink ? scheme.outline : null,
        borderRadius: apple ? null : FushiM3eShape.containerLargeRadius,
        padding: EdgeInsets.all(tokens.spacing.card * (wide ? 1.5 : 1)),
        onTap: onContinue,
        child: body,
      ),
    );
  }
}

/// hero 色块底色：与「继续」大卡同一块色，见 [fushiHeroBlockColor]。
Color collectionHeroBackground(ColorScheme scheme) =>
    fushiHeroBlockColor(scheme);

/// 整体进度：「整体进度」小标题 + Display 级百分比 + 波浪进度条（Apple 细线条）。
class _HeroProgress extends StatelessWidget {
  const _HeroProgress({required this.value, this.compact = false});

  final double value;

  /// 窄屏：进度挤在封面旁边一列里，百分比从 Display 降到 headline。
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final bool apple = isGlassDesign(context);
    final double v = value.clamp(0.0, 1.0);
    final int percent = (v * 100).round();
    final Widget bar = apple || isEinkTheme(context)
        ? ClipRRect(
            borderRadius: FushiBorderRadius.chip,
            child: FushiLinearProgressIndicator(
              value: v,
              minHeight: 4,
              color: scheme.primary,
              backgroundColor: apple
                  ? appleColorsOf(context).tertiaryFill
                  : scheme.surfaceContainerHighest,
            ),
          )
        : SizedBox(
            height: 12,
            child: FushiWavyLinearProgress(
              value: v,
              color: scheme.primary,
              trackColor: scheme.primary.withValues(alpha: 0.22),
            ),
          );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          t.collection_detail_progress_label,
          style: tokens.type.sectionLabel,
        ),
        SizedBox(height: tokens.spacing.gap / 2),
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            Text(
              '$percent%',
              key: const ValueKey<String>('collection_detail_hero_percent'),
              style:
                  (apple
                          ? theme.textTheme.titleLarge
                          : compact
                          ? theme.textTheme.headlineMedium
                          : theme.textTheme.displaySmall)
                      ?.copyWith(
                        fontWeight: FontWeight.w800,
                        color: apple ? null : scheme.primary,
                        height: 1,
                      ),
            ),
            SizedBox(width: tokens.spacing.gap * 1.5),
            Expanded(child: bar),
          ],
        ),
      ],
    );
  }
}

/// hero 里的小动作 chip（「编辑标签」）：M3E 下是叠在 hero 色块上的 tonal 圆角方
/// （onPrimaryContainer 12% 填充 + onPrimaryContainer 前景，与色块同一色相族），
/// Apple 玻璃胶囊。此前用 secondaryContainer：深色下是一块灰紫，压在 hero 的
/// 饱和紫上显得突兀（iOS 深色反馈截图）。
class _HeroActionChip extends StatelessWidget {
  const _HeroActionChip({
    required this.icon,
    required this.label,
    required this.onTap,
    super.key,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    if (isGlassDesign(context)) return FushiTagChip(label: label, onTap: onTap);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool eink = isEinkTheme(context);
    final Color fill = eink
        ? scheme.surface
        : scheme.onPrimaryContainer.withValues(alpha: 0.12);
    final Color fg = eink ? scheme.onSurface : scheme.onPrimaryContainer;
    final OutlinedBorder shape = RoundedRectangleBorder(
      borderRadius: const BorderRadius.all(Radius.circular(12)),
      side: eink ? BorderSide(color: scheme.outline) : BorderSide.none,
    );
    return FushiPressScale(
      scale: 0.94,
      child: Material(
        color: fill,
        shape: shape,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          customBorder: shape,
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 36),
            child: Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(10, 6, 14, 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  FushiIcon(icon, size: 18, color: fg),
                  const SizedBox(width: 6),
                  Text(
                    label,
                    style:
                        (Theme.of(context).textTheme.labelLarge ??
                                const TextStyle())
                            .copyWith(color: fg, fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 堆叠封面：与书架合集卡（`SeriesShelfCard`）同一个 [ShelfCoverFrame] 叠层——
/// 首本封面在前，顶上露出两层「后面还有」（同一套 [kShelfCoverStackLift] 偏移、
/// 左右内缩与阴影）。此前这里自绘「后两本左右错开 + 旋转」，后排封面的书名字与
/// 角标从左上 / 右侧露出半截，看着像重影。没有封面时是 tonal 色块 + 合集图标。
///
/// 调用方给了 [ShelfCoverMaterialScope] 时走库页同款材质的多本排列（书 / 卡盒 =
/// 扇形、海报 = 叠层，[ShelfCoverPile]），后几层用真实的后续成员封面；卡盒材质
/// 下高度按 1:1.6 卡盒比例。
class _StackedCovers extends StatelessWidget {
  const _StackedCovers({required this.covers, required this.width});

  final List<Widget> covers;
  final double width;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Widget front = covers.isEmpty
        ? ColoredBox(
            color: scheme.secondaryContainer,
            child: Center(
              child: FushiIcon(
                FushiIcons.collection,
                size: width * 0.32,
                color: scheme.onSecondaryContainer,
              ),
            ),
          )
        : covers.first;
    final ShelfCoverMaterial? material = shelfCoverMaterialOf(context);
    final double coverHeight = material == ShelfCoverMaterial.gameCase
        ? width / kShelfGameCaseAspectRatio
        : width * 1.5;
    return SizedBox(
      width: width,
      height: coverHeight + kShelfCoverStackLift,
      child: ShelfCoverFrame(
        // 平贴在 hero 色块里：材质投影压在色块上会糊出一块发灰的底。
        flat: true,
        // Apple 叠层用「下一本」的模糊封面；MD3 / 墨水屏只画色块层。
        stackedBehind: covers.length > 1 ? covers[1] : const SizedBox.shrink(),
        // 材质下：后续成员的真实封面（只有一本时就是单张，不叠空层）。
        stackedCovers: covers.skip(1).toList(growable: false),
        child: front,
      ),
    );
  }
}
