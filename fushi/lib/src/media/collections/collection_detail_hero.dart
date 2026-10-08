/// 合集详情页 hero（书架 / 漫画库 / 游戏库共用）：堆叠封面大图 + 合集名 + 项数 /
/// 读完数 + 整体进度（M3E 波浪条 + Display 级百分比；Apple 细线条）+ 「继续」主
/// 按钮（M3E 尺寸档 M 填充按钮；Apple 填充胶囊）+ 彩色标签 chip 与「编辑标签」。
///
/// 宽屏（[wide]）封面在左、信息在右；窄屏上下堆叠、封面居中。只吃纯值与回调，
/// 数据求值（续读是哪一本、进度怎么算）在页面与 `collection_member_view.dart`。
library;

import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/media/tags/tag_chips.dart';
import 'package:fushi/src/utils/components/fushi_expressive_progress.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
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
    this.continueLabel,
    this.continueStarted = false,
    this.onContinue,
    this.onEditTags,
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

  /// 「继续」目标的名字（按钮副文案）；null = 只显示「继续 / 开始」。
  final String? continueLabel;

  /// 目标已经读过（「继续」）还是没读过（「开始」）。
  final bool continueStarted;
  final VoidCallback? onContinue;
  final VoidCallback? onEditTags;
  final bool wide;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final bool apple = isGlassDesign(context);
    final bool eink = isEinkTheme(context);
    final double coverWidth = wide ? 184 : 132;

    final Widget cover = _StackedCovers(covers: covers, width: coverWidth);

    final TextStyle? titleStyle =
        (wide ? theme.textTheme.headlineMedium : theme.textTheme.headlineSmall)
            ?.copyWith(fontWeight: FontWeight.w800, height: 1.15);

    final List<String> meta = <String>[
      t.collection_detail_member_count(n: memberCount),
      if (finished != null)
        t.collection_detail_finished_count(done: finished!, total: memberCount),
    ];

    final Widget info = Column(
      crossAxisAlignment: wide
          ? CrossAxisAlignment.start
          : CrossAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          name,
          key: const ValueKey<String>('collection_detail_hero_name'),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          textAlign: wide ? TextAlign.start : TextAlign.center,
          style: titleStyle,
        ),
        SizedBox(height: tokens.spacing.gap),
        Text(
          meta.join('  ·  '),
          key: const ValueKey<String>('collection_detail_hero_meta'),
          style: tokens.type.listSubtitle,
        ),
        if (progress != null) ...<Widget>[
          SizedBox(height: tokens.spacing.gap * 1.5),
          _HeroProgress(value: progress!),
        ],
        if (tags.isNotEmpty || onEditTags != null) ...<Widget>[
          SizedBox(height: tokens.spacing.gap * 1.5),
          Wrap(
            alignment: wide ? WrapAlignment.start : WrapAlignment.center,
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
        if (onContinue != null) ...<Widget>[
          SizedBox(height: tokens.spacing.gap * 2),
          _ContinueButton(
            started: continueStarted,
            subtitle: continueLabel,
            onPressed: onContinue!,
          ),
        ],
      ],
    );

    final Widget body = wide
        ? Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              cover,
              SizedBox(width: tokens.spacing.card * 1.5),
              Expanded(child: info),
            ],
          )
        : Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              cover,
              SizedBox(height: tokens.spacing.card),
              info,
            ],
          );

    if (apple) {
      return Padding(padding: EdgeInsets.all(tokens.spacing.card), child: body);
    }
    // M3E：饱和的 primaryContainer 大色块分区（圆角 28），把 hero 和成员区分开。
    return Container(
      padding: EdgeInsets.all(tokens.spacing.card * (wide ? 1.5 : 1)),
      decoration: BoxDecoration(
        color: eink
            ? scheme.surface
            : Color.alphaBlend(
                scheme.primaryContainer.withValues(alpha: 0.62),
                scheme.surfaceContainerLow,
              ),
        borderRadius: FushiM3eShape.containerLargeRadius,
        border: eink ? Border.all(color: scheme.outline) : null,
      ),
      child: body,
    );
  }
}

/// 整体进度：「整体进度」小标题 + Display 级百分比 + 波浪进度条（Apple 细线条）。
class _HeroProgress extends StatelessWidget {
  const _HeroProgress({required this.value});

  final double value;

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

/// 「继续 / 开始」主按钮：M3E 尺寸档 M 的填充按钮（56 高、左右 24 留白，按压
/// 形变），Apple 强调色填充胶囊。副文案是目标条目名。
///
/// 不能用扩展 FAB：它把图标 + 文字按无界宽度排版后居中，可用宽度不够时内容
/// 从两侧溢出按钮（手机上长条目名把播放图标挤到按钮左缘外，BUG-3063）。填充
/// 按钮的文字是 Flexible，宽度不够就按省略号收缩，左右留白恒等于尺寸档 token。
class _ContinueButton extends StatelessWidget {
  const _ContinueButton({
    required this.started,
    required this.subtitle,
    required this.onPressed,
  });

  final bool started;
  final String? subtitle;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final String label = started
        ? t.collection_detail_continue
        : t.collection_detail_start;
    final String text = subtitle == null || subtitle!.isEmpty
        ? label
        : '$label · $subtitle';
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 420),
      child: FushiFilledButton.icon(
        key: const ValueKey<String>('collection_detail_continue'),
        size: FushiButtonSize.m,
        onPressed: onPressed,
        icon: const FushiIcon(FushiIcons.play),
        label: Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
    );
  }
}

/// hero 里的小动作 chip（「编辑标签」）：M3E secondaryContainer 圆角方，Apple 玻璃
/// 胶囊。
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
    final Color fill = eink ? scheme.surface : scheme.secondaryContainer;
    final Color fg = eink ? scheme.onSurface : scheme.onSecondaryContainer;
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
    return SizedBox(
      width: width,
      height: width * 1.5 + kShelfCoverStackLift,
      child: ShelfCoverFrame(
        // Apple 叠层用「下一本」的模糊封面；MD3 / 墨水屏只画色块层。
        stackedBehind: covers.length > 1 ? covers[1] : const SizedBox.shrink(),
        child: front,
      ),
    );
  }
}
