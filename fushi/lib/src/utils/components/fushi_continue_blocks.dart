import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/adaptive/shell_style.dart';
import 'package:fushi/src/utils/components/fushi_continue_hero.dart';
import 'package:fushi/src/utils/components/fushi_cover_block.dart';
import 'package:fushi/src/utils/components/fushi_cover_block_layout.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_hover_lift.dart';
import 'package:fushi/src/utils/components/fushi_m3e_feedback.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/components/shelf_card_widgets.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

// =============================================================================
// 「继续」区的封面色块版式（重设计外壳、库页布局为拼贴 / 规整色块时）。
//
// 各库页的「继续阅读 / 继续观看 / 继续游戏 / 继续收听」：条目排成**一行**半高
// 色块横向滑动（[FushiCoverBlockStrip] 的单行排法），整段只占一行高，与改版前的
// 横滑行同一结构（2026-11-12 用户：「继续阅读占空间太大了还是保持跟之前一样
// 侧滑」）。[leadingHero] 时第一条是大封面主块、其余在旁边（窄屏在下面）横滑
// ——视频首页「继续观看」用（同日用户：「视频首页还是要保留一个是大封面的
// 设计」），与首页仪表盘同一个 [FushiCoverBlockStrip] 排法。每块是 [FushiCoverBlock]——封面取色底、作品名出血大字、悬停动效，
// 与库墙 / 首页仪表盘同一套视觉。
//
// 数据仍是 [FushiContinueEntry]：[FushiContinueSpotlight] 与
// [FushiContinueCardRow] 在门控生效时整段换成本组件，调用点不必各写一份。封面
// 网格布局与墨水屏不走这里（[active] 为 false），保留原卡。
// =============================================================================

/// 「继续」区的封面色块横滑行。见文件头。
class FushiContinueBlocks extends StatelessWidget {
  const FushiContinueBlocks({
    required this.entries,
    this.label,
    this.showLabel = false,
    this.leadingHero = false,
    this.staggerEntrance = true,
    this.groupKey = const ValueKey<String>('fushi-continue-blocks'),
    super.key,
  });

  /// true：第一条是大封面主块（拼贴首块尺寸，带状态 chip 与「继续」按钮外观），
  /// 其余在旁边 / 下面横滑；false：全部条目一行半高块横滑。
  final bool leadingHero;

  /// 按最近活动排好的条目（第一项 = 最近一条，排在行首）。
  final List<FushiContinueEntry> entries;

  /// 区块名（「继续阅读」）：[showLabel] 时画成分区标题。
  final String? label;

  /// 在横滑行上方画 [label] 分区标题。
  final bool showLabel;

  /// 每块各自错峰进场；外层已整块包了进场动画的调用方传 false。
  final bool staggerEntrance;

  /// 横滑行的 key（测试按它找那一行）；[leadingHero] 时是整段（主块 + 横滑条）
  /// 的 key。
  final Key groupKey;

  /// 门控：重设计外壳（墨水屏除外）且库页布局不是封面网格。与首页仪表盘
  /// （`_posterPanels`）同一判据。只在 build 期间读。
  static bool active(BuildContext context) =>
      shellRedesignActive(context) &&
      shellContentLayoutOf(context) != ShellContentLayout.grid;

  /// 首屏骨架：与真内容同一套几何（[label] 给了就同样先画分区标题，下面是一行
  /// 与真块同宽同高、圆角同半高色块的骨架块，排到行尾裁掉），骨架换真内容不跳。
  /// [leadingHero] 时是整行一块主块高的骨架（条目数未知，按只有主块那一档排：
  /// 与真主块同位同高）。
  static Widget placeholder(
    BuildContext context, {
    String? label,
    bool leadingHero = false,
  }) {
    if (leadingHero) {
      return LayoutBuilder(
        builder: (BuildContext context, BoxConstraints c) {
          final double height = FushiCoverBlockStrip.heroHeightFor(c.maxWidth);
          return FushiSkeleton(
            width: c.maxWidth,
            height: height,
            borderRadius: BorderRadius.circular(
              fushiCoverBlockRadius(FushiCoverBlockSize.hero, height),
            ),
          );
        },
      );
    }
    final double height = FushiCoverBlockStrip.rowHeight();
    final BorderRadius radius = BorderRadius.circular(
      fushiCoverBlockRadius(FushiCoverBlockSize.half, height),
    );
    final Widget bar = SizedBox(
      height: height,
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints c) {
          const double spacing = kFushiCoverBlockSpacing;
          final double tile = FushiCoverBlockStrip.rowTileWidth(c.maxWidth);
          final int count = ((c.maxWidth + spacing) / (tile + spacing))
              .ceil()
              .clamp(1, 12);
          return ClipRect(
            child: OverflowBox(
              alignment: AlignmentDirectional.centerStart,
              maxWidth: double.infinity,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  for (int i = 0; i < count; i++) ...<Widget>[
                    if (i > 0) const SizedBox(width: spacing),
                    FushiSkeleton(
                      width: tile,
                      height: height,
                      borderRadius: radius,
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
    if (label == null) return bar;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        FushiBlockSectionTitle(label),
        SizedBox(height: FushiDesignTokens.of(context).spacing.card),
        bar,
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final Widget row = FushiCoverBlockStrip(
      key: leadingHero ? groupKey : null,
      leadingHero: leadingHero,
      stripKey: leadingHero ? null : groupKey,
      itemCount: entries.length,
      staggerEntrance: staggerEntrance,
      itemBuilder: (BuildContext context, int i, FushiCoverBlockSize size) {
        final FushiContinueEntry entry = entries[i];
        // State（取色、悬停姿态、朝向探测）跟着条目走，不跟格子下标。
        return KeyedSubtree(
          key: ValueKey<Key>(entry.key),
          child: FushiContinueOrientedEntry(
            entry: entry,
            builder: (FushiContinueEntry e) =>
                FushiContinueBlockCard(entry: e, size: size, label: label),
          ),
        );
      },
    );
    final String? title = label;
    if (!showLabel || title == null) return row;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        FushiBlockSectionTitle(title),
        SizedBox(height: FushiDesignTokens.of(context).spacing.card),
        row,
      ],
    );
  }
}

/// 封面色块版式的分区标题：与首页仪表盘色块分区（「最近添加」）同一款——24 号
/// 900 字重、收紧字距，读屏标为标题。
class FushiBlockSectionTitle extends StatelessWidget {
  const FushiBlockSectionTitle(this.title, {super.key});

  final String title;

  @override
  Widget build(BuildContext context) {
    final TextStyle base =
        Theme.of(context).textTheme.bodyMedium ?? const TextStyle();
    return Semantics(
      header: true,
      child: Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: base.copyWith(
          fontSize: context.fushiType.headlineSmall.fontSize,
          fontWeight: FontWeight.w900,
          letterSpacing: -0.5,
          color: FushiDesignTokens.of(context).surfaces.onSurface,
        ),
      ),
    );
  }
}

/// 「继续」区的一块色块：信息与原卡同一份（标题、署名、进度文案、进度条），拼贴
/// 首块再加状态 chip（[FushiContinueEntry.blockEyebrow]，没给就是区块名）与主按钮
/// 外观。点按 = 继续，长按 / 右键 = 条目菜单 / 详情；卡壳是 [shelfCoverCard]
/// （焦点站点、按压反馈），外面 [FushiHoverLift] 悬停抬升——与首页仪表盘「继续」
/// 色块同一套。封面上不压角标。
class FushiContinueBlockCard extends StatelessWidget {
  const FushiContinueBlockCard({
    required this.entry,
    required this.size,
    this.action,
    this.label,
    super.key,
  });

  final FushiContinueEntry entry;
  final FushiCoverBlockSize size;

  /// 拼贴首块（[FushiCoverBlockSize.hero]）的主按钮外观（纯视觉，点卡就是这个
  /// 动作）；null = 「▶ 继续」。其余尺寸不画按钮。
  final FushiCoverBlockAction? action;

  /// 区块名：拼贴首块状态 chip 的默认文字。
  final String? label;

  @override
  Widget build(BuildContext context) {
    final bool hero = size == FushiCoverBlockSize.hero;
    final bool interactive = entry.onOpen != null;
    final Widget cover = entry.blockCover ?? entry.cover;
    final String? subtitle = _joinDistinct(<String?>[
      entry.subtitle,
      entry.progressLabel,
    ]);
    final String? byline =
        entry.byline ?? _joinDistinct(<String?>[...entry.metaLines]);
    final String? eyebrow = hero ? (entry.blockEyebrow ?? label) : null;
    final Widget block = FushiCoverBlock(
      size: size,
      art: entry.blockArtResolved,
      title: entry.title,
      covers: <Widget>[cover],
      tintImage: entry.colorSource ?? fushiCoverImageOf(cover),
      eyebrow: eyebrow == null || eyebrow.isEmpty ? null : eyebrow,
      byline: byline,
      subtitle: subtitle,
      leadingIcon: entry.subtitleIcon ?? entry.metaIcon,
      progress: entry.progress?.clamp(0.0, 1.0),
      // 状态角标（游戏的游玩状态）进文字区底部，不压在封面上。
      trailing: entry.badge,
      action: hero && interactive
          ? (action ??
                FushiCoverBlockAction(
                  icon: FushiIcons.play,
                  label: t.home_continue,
                ))
          : null,
      hoverEnabled: interactive,
    );
    final String? semanticLabel = entry.semanticLabel;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        final BorderRadius radius = BorderRadius.circular(
          fushiCoverBlockRadius(size, c.maxHeight),
        );
        Widget card = FushiHoverLift(
          enabled: interactive,
          builder: (BuildContext _, bool _) => shelfCoverCard(
            key: entry.key,
            focusId: entry.focusId,
            borderRadius: radius,
            onTap: entry.onOpen,
            onLongPress: entry.onLongPress,
            onSecondaryTap: entry.onLongPress,
            child: block,
          ),
        );
        if (semanticLabel != null) {
          card = Semantics(container: true, label: semanticLabel, child: card);
        }
        return card;
      },
    );
  }
}

/// 非空、去重后用「 · 」连起来；全空为 null。
String? _joinDistinct(List<String?> parts) {
  final List<String> kept = <String>[];
  for (final String? p in parts) {
    final String? s = p?.trim();
    if (s == null || s.isEmpty || kept.contains(s)) continue;
    kept.add(s);
  }
  return kept.isEmpty ? null : kept.join(' · ');
}
