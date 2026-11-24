/// 音乐 Cupertino 版的浏览类公共件（设计稿
/// fushi/build/music_online_cupertino_design/index.html 方案 A ③，用户 2026-11-24
/// 「都要改 apple 风格啊，彩色渐变」）：分类块的稳定彩色渐变、Apple 曲目行与
/// 「热门歌曲」式分页列、实体行（专辑 / 艺人 / 歌单一行）、平封面网格与自适应
/// 宽度的平封面卡。
///
/// 只在 `isGlassDesign` 为真时用；M3E 一侧不经过这里。尺寸取
/// [FushiAppleMetrics]（macOS 档乘 `fushiAppleMacScale`），颜色只取
/// [appleColorsOf] 与 [CupertinoColors] 的系统色（深浅色各取各的值）。
library;

import 'dart:math' as math;

import 'package:cupertino_ui/cupertino_ui.dart'
    show CupertinoColors, CupertinoDynamicColor;
import 'package:flutter/rendering.dart' show SliverConstraints;
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/pages/implementations/music/apple/apple_music_recommend_widgets.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/fushi_focusable.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart'
    show FushiAppleMetrics;
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/components/apple/apple_radii.dart';

// =========================================================================
// 分类块的彩色渐变
// =========================================================================

/// 分类块渐变的系统色对（起点 → 终点），照 Apple Music「按类别浏览」的饱和中间调；
/// 不放黄色起点（白字对比不够）。
const List<(CupertinoDynamicColor, CupertinoDynamicColor)> _kCategoryPairs =
    <(CupertinoDynamicColor, CupertinoDynamicColor)>[
      (CupertinoColors.systemPink, CupertinoColors.systemOrange),
      (CupertinoColors.systemIndigo, CupertinoColors.systemBlue),
      (CupertinoColors.systemTeal, CupertinoColors.systemGreen),
      (CupertinoColors.systemPurple, CupertinoColors.systemPink),
      (CupertinoColors.systemRed, CupertinoColors.systemOrange),
      (CupertinoColors.systemBlue, CupertinoColors.systemCyan),
      (CupertinoColors.systemGreen, CupertinoColors.systemMint),
      (CupertinoColors.systemOrange, CupertinoColors.systemPink),
      (CupertinoColors.systemIndigo, CupertinoColors.systemPurple),
      (CupertinoColors.systemCyan, CupertinoColors.systemIndigo),
      (CupertinoColors.systemMint, CupertinoColors.systemTeal),
      (CupertinoColors.systemPink, CupertinoColors.systemPurple),
    ];

/// 稳定的字符串散列（FNV-1a 32 位）：同一个分类名 / id 每次启动、每台设备都落在
/// 同一组颜色上（`String.hashCode` 不保证跨运行稳定）。
int appleMusicStableHash(String seed) {
  int h = 0x811c9dc5;
  for (final int unit in seed.codeUnits) {
    h ^= unit;
    h = (h * 0x01000193) & 0xffffffff;
  }
  return h;
}

/// [seed]（分类 id / 名）对应的系统色对下标。
int appleMusicCategoryPairIndex(String seed) =>
    appleMusicStableHash(seed) % _kCategoryPairs.length;

/// [seed] 的分类块渐变：按主题明暗取系统色的浅色 / 深色值，左上 → 右下。
LinearGradient appleMusicCategoryGradient(BuildContext context, String seed) {
  final bool dark = Theme.of(context).brightness == Brightness.dark;
  final (CupertinoDynamicColor a, CupertinoDynamicColor b) =
      _kCategoryPairs[appleMusicCategoryPairIndex(seed)];
  Color pick(CupertinoDynamicColor c) => dark ? c.darkColor : c.color;
  return LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: <Color>[pick(a), pick(b)],
  );
}

// =========================================================================
// 曲目行
// =========================================================================

/// 正在播放的三根柱（静态字形，强调色）。
class AppleMusicEqualizerGlyph extends StatelessWidget {
  const AppleMusicEqualizerGlyph({super.key, required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.end,
    spacing: 2,
    children: <Widget>[
      for (final double h in const <double>[6, 12, 8])
        Container(
          width: 2.5,
          height: h,
          decoration: BoxDecoration(
            color: color,
            borderRadius: FushiAppleRadii.of(context).markRadius,
          ),
        ),
    ],
  );
}

/// Apple 列表行的按下高亮：按下整行铺 fill 底（不缩放），可聚焦、Enter 激活。
class AppleMusicRowHighlight extends StatefulWidget {
  const AppleMusicRowHighlight({
    super.key,
    required this.onTap,
    required this.child,
  });

  final VoidCallback? onTap;
  final Widget child;

  @override
  State<AppleMusicRowHighlight> createState() => _AppleMusicRowHighlightState();
}

class _AppleMusicRowHighlightState extends State<AppleMusicRowHighlight> {
  bool _pressed = false;

  void _set(bool v) {
    if (_pressed != v && mounted) setState(() => _pressed = v);
  }

  @override
  Widget build(BuildContext context) {
    final FushiAppleColors c = appleColorsOf(context);
    return Listener(
      onPointerDown: widget.onTap == null ? null : (_) => _set(true),
      onPointerUp: (_) => _set(false),
      onPointerCancel: (_) => _set(false),
      child: FushiFocusable(
        onTap: widget.onTap,
        borderRadius: FushiAppleRadii.of(context).highlightRadius,
        child: AnimatedContainer(
          duration: fushiMotionDuration(context, FushiMotion.micro),
          decoration: BoxDecoration(
            color: _pressed ? c.fill : c.fill.withValues(alpha: 0),
            borderRadius: FushiAppleRadii.of(context).highlightRadius,
          ),
          child: widget.child,
        ),
      ),
    );
  }
}

/// 曲目行尾的「MV」描边小标（可点 = 播放 MV）。
class AppleMusicMvBadge extends StatelessWidget {
  const AppleMusicMvBadge({
    super.key,
    required this.onTap,
    required this.semanticLabel,
  });

  final VoidCallback onTap;
  final String semanticLabel;

  @override
  Widget build(BuildContext context) {
    final FushiAppleColors c = appleColorsOf(context);
    final double k = FushiAppleMetrics.of(context).scale;
    return FushiFocusable(
      onTap: onTap,
      child: Semantics(
        button: true,
        label: semanticLabel,
        excludeSemantics: true,
        child: SizedBox(
          width: 44,
          height: 44,
          child: Center(
            child: Container(
              padding: EdgeInsets.symmetric(horizontal: 3 * k),
              decoration: BoxDecoration(
                border: Border.all(color: c.tertiaryLabel),
                borderRadius: FushiAppleRadii.of(context).badgeRadius,
              ),
              child: Text(
                'MV',
                style: appleMusicText(
                  context,
                  size: 9.5 * k,
                  weight: FontWeight.w700,
                  color: c.secondaryLabel,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 一行歌曲（Apple 列表行，高 60）：封面 48（或 [ordinal] 序号）+ 标题（正在播放 =
/// 强调色 + 均衡器）+ 副行 + [badges] + 时长 + [trailing]（MV / ⋯）；按下整行
/// fill 底、不缩放。[separator] 画行底细线（与文字左缘对齐）。
class AppleMusicSongRow extends StatelessWidget {
  const AppleMusicSongRow({
    super.key,
    required this.title,
    required this.subtitle,
    required this.cover,
    required this.onTap,
    this.playing = false,
    this.separator = true,
    this.ordinal,
    this.badges = const <Widget>[],
    this.durationText,
    this.trailing = const <Widget>[],
  });

  final String title;
  final String subtitle;
  final String? cover;
  final VoidCallback? onTap;
  final bool playing;
  final bool separator;

  /// 非 null 时行首画序号（专辑曲目号 / 榜单名次）代替封面。
  final String? ordinal;
  final List<Widget> badges;
  final String? durationText;
  final List<Widget> trailing;

  /// 行高：封面 48 与两行文字（按 textScaler）取大者，上下各留 6。
  static double heightOf(BuildContext context) {
    final double k = FushiAppleMetrics.of(context).scale;
    return math.max(
          48 * k,
          appleMusicLineExtent(context, 14.5 * k) +
              appleMusicLineExtent(context, 12.5 * k),
        ) +
        12 * k;
  }

  @override
  Widget build(BuildContext context) {
    final FushiAppleColors c = appleColorsOf(context);
    final double k = FushiAppleMetrics.of(context).scale;
    final String? no = ordinal;
    return SizedBox(
      height: heightOf(context),
      child: AppleMusicRowHighlight(
        onTap: onTap,
        child: Row(
          children: <Widget>[
            if (no != null)
              SizedBox(
                width: 32 * k,
                child: Text(
                  no,
                  textAlign: TextAlign.center,
                  style: appleMusicText(
                    context,
                    size: 14 * k,
                    color: c.secondaryLabel,
                  ),
                ),
              )
            else
              appleMusicCover(cover: cover, size: 48 * k, radius: 6 * k),
            SizedBox(width: 11 * k),
            Expanded(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: separator
                      ? Border(
                          bottom: BorderSide(color: c.separator, width: 0.5),
                        )
                      : null,
                ),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Row(
                            children: <Widget>[
                              if (playing) ...<Widget>[
                                AppleMusicEqualizerGlyph(color: c.accent),
                                SizedBox(width: 5 * k),
                              ],
                              Flexible(
                                child: Text(
                                  title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: appleMusicText(
                                    context,
                                    size: 14.5 * k,
                                    color: playing ? c.accent : c.label,
                                  ),
                                ),
                              ),
                              for (final Widget b in badges) ...<Widget>[
                                SizedBox(width: 5 * k),
                                b,
                              ],
                            ],
                          ),
                          if (subtitle.isNotEmpty)
                            Text(
                              subtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: appleMusicText(
                                context,
                                size: 12.5 * k,
                                color: c.secondaryLabel,
                              ),
                            ),
                        ],
                      ),
                    ),
                    if (durationText case final String d
                        when d.isNotEmpty) ...<Widget>[
                      SizedBox(width: 8 * k),
                      Text(
                        d,
                        style: appleMusicText(
                          context,
                          size: 12.5 * k,
                          color: c.tertiaryLabel,
                        ),
                      ),
                    ],
                    ...trailing,
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Apple Music「热门歌曲」式分页列：每列 [perColumn] 行、横滑、露出下一列边；
/// macOS 宽窗一屏 3 列。[rowBuilder] 的 `separator` = 不是本列最后一行。
class AppleMusicSongColumns extends StatelessWidget {
  const AppleMusicSongColumns({
    super.key,
    required this.itemCount,
    required this.rowBuilder,
    this.perColumn = 4,
    this.columnKeyPrefix = 'music-song-column',
  });

  final int itemCount;
  final Widget Function(BuildContext context, int index, bool separator)
  rowBuilder;
  final int perColumn;
  final String columnKeyPrefix;

  @override
  Widget build(BuildContext context) {
    final FushiAppleMetrics m = FushiAppleMetrics.of(context);
    final double k = m.scale;
    final double pad = appleMusicPagePadding(context);
    final double gap = 18 * k;
    final double rowHeight = AppleMusicSongRow.heightOf(context);
    final int columns = (itemCount / perColumn).ceil();
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        final double avail = c.maxWidth - pad * 2;
        final double colWidth = m.desktop
            ? math.max(240 * k, (avail - gap * 2) / 3)
            : math.min(360.0, avail - 28);
        return AppleMusicCarousel(
          itemCount: columns,
          itemExtent: colWidth,
          spacing: gap,
          height: rowHeight * math.min(perColumn, itemCount),
          itemBuilder: (BuildContext context, int col) {
            final int start = col * perColumn;
            final int end = math.min(start + perColumn, itemCount);
            return Column(
              key: ValueKey<String>('$columnKeyPrefix-$col'),
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                for (int i = start; i < end; i++)
                  rowBuilder(context, i, i < end - 1),
              ],
            );
          },
        );
      },
    );
  }
}

// =========================================================================
// 实体行与平封面
// =========================================================================

/// 专辑 / 艺人 / 歌单 / 流派一行（Apple 列表行）：封面 48（艺人圆形）+ 标题 + 副行
/// （+ [extra] 一行可点标签）+ [badges] + ›。
class AppleMusicEntityRow extends StatelessWidget {
  const AppleMusicEntityRow({
    super.key,
    required this.title,
    required this.onTap,
    this.subtitle = '',
    this.cover,
    this.circular = false,
    this.extra,
    this.badges = const <Widget>[],
    this.separator = true,
  });

  final String title;
  final String subtitle;
  final String? cover;
  final bool circular;
  final VoidCallback? onTap;
  final Widget? extra;
  final List<Widget> badges;
  final bool separator;

  @override
  Widget build(BuildContext context) {
    final FushiAppleColors c = appleColorsOf(context);
    final double k = FushiAppleMetrics.of(context).scale;
    return AppleMusicListRowFrame(
      onTap: onTap,
      separator: separator,
      leading: appleMusicCover(
        cover: cover,
        size: appleMusicRowCoverExtent(context),
        radius: appleMusicRowCoverRadius(context),
        title: title,
        circular: circular,
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: AppleMusicRowTexts(
              title: title,
              subtitle: subtitle,
              badges: badges,
              extra: extra,
            ),
          ),
          FushiIcon(
            FushiIcons.chevronRight,
            size: 16 * k,
            color: c.tertiaryLabel,
          ),
          SizedBox(width: 6 * k),
        ],
      ),
    );
  }
}

/// Apple 列表行的文字列：标题（15 × 缩放，label，单行省略）+ 紧跟标题的
/// [badges] + 副行（12.5，secondaryLabel）+ 可选 [extra]。实体行与来源 / 插件行
/// 共用这一份字样。
class AppleMusicRowTexts extends StatelessWidget {
  const AppleMusicRowTexts({
    super.key,
    required this.title,
    this.subtitle = '',
    this.badges = const <Widget>[],
    this.extra,
    this.subtitleMaxLines = 1,
  });

  final String title;
  final String subtitle;
  final List<Widget> badges;
  final Widget? extra;

  /// 副行最多几行（来源 / 插件行的说明可折两行）。
  final int subtitleMaxLines;

  @override
  Widget build(BuildContext context) {
    final FushiAppleColors c = appleColorsOf(context);
    final double k = FushiAppleMetrics.of(context).scale;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 2 * k,
      children: <Widget>[
        Row(
          children: <Widget>[
            Flexible(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: appleMusicText(context, size: 15 * k),
              ),
            ),
            for (final Widget b in badges) ...<Widget>[
              SizedBox(width: 5 * k),
              b,
            ],
          ],
        ),
        if (subtitle.isNotEmpty)
          Text(
            subtitle,
            maxLines: subtitleMaxLines,
            overflow: TextOverflow.ellipsis,
            style: appleMusicText(
              context,
              size: 12.5 * k,
              color: c.secondaryLabel,
            ),
          ),
        ?extra,
      ],
    );
  }
}

/// Apple 实体行（[AppleMusicEntityRow]）行首封面的边长：iOS 48，macOS 档 ×scale。
double appleMusicRowCoverExtent(BuildContext context) =>
    48 * FushiAppleMetrics.of(context).scale;

/// Apple 列表行行首（封面 / 方块）与文字之间的间距：11 × 缩放。分隔线与子行都从
/// 「行首 + 这段」的文字左缘起。
double appleMusicRowLeadingGap(BuildContext context) =>
    11 * FushiAppleMetrics.of(context).scale;

/// Apple 实体行行首封面的连续曲率圆角（与 [appleMusicRowCoverExtent] 同比缩放）。
double appleMusicRowCoverRadius(BuildContext context) =>
    6 * FushiAppleMetrics.of(context).scale;

/// Apple 列表行的骨架（实体行 / 歌单页「新建歌单…」等动作行共用）：最小行高 64、
/// 行首 [leading]（封面 / 方块）+ 11 间距 + [child]；按下整行铺 fill 底、可聚焦、
/// Enter 激活（[AppleMusicRowHighlight]）。[separator] 在**行底**画 0.5 细线，左端
/// 与文字左缘对齐（UITableView 的 separatorInset），不随内容高度漂。
class AppleMusicListRowFrame extends StatelessWidget {
  const AppleMusicListRowFrame({
    super.key,
    required this.leading,
    required this.child,
    required this.onTap,
    this.separator = true,
    this.trailing,
  });

  final Widget leading;
  final Widget child;
  final VoidCallback? onTap;
  final bool separator;

  /// 行尾控件（开关 / 重排把手）：排在文字的竖直内边距**之外**、竖直居中，自带命中区
  /// 的控件不会把行撑高。
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final FushiAppleColors c = appleColorsOf(context);
    final double k = FushiAppleMetrics.of(context).scale;
    final double gap = appleMusicRowLeadingGap(context);
    return ConstrainedBox(
      constraints: BoxConstraints(minHeight: 64 * k),
      child: AppleMusicRowHighlight(
        onTap: onTap,
        child: Stack(
          alignment: AlignmentDirectional.centerStart,
          children: <Widget>[
            Row(
              children: <Widget>[
                leading,
                SizedBox(width: gap),
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.symmetric(vertical: 8 * k),
                    child: child,
                  ),
                ),
                ?trailing,
              ],
            ),
            if (separator)
              PositionedDirectional(
                start: appleMusicRowCoverExtent(context) + gap,
                end: 0,
                bottom: 0,
                child: SizedBox(
                  height: 0.5,
                  child: ColoredBox(color: c.separator),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 宽度跟着父级走的平封面卡（[AppleMusicCoverTile]）：网格格子 / 货架条目给多宽
/// 封面就多宽；父级宽度无界时取货架标准宽（150）。
class AppleMusicAutoCoverTile extends StatelessWidget {
  const AppleMusicAutoCoverTile({
    super.key,
    required this.title,
    required this.cover,
    required this.onTap,
    this.subtitle,
    this.circular = false,
    this.subtitleTrailing,
  });

  final String title;
  final String? subtitle;
  final String? cover;
  final VoidCallback? onTap;
  final bool circular;
  final Widget? subtitleTrailing;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (BuildContext context, BoxConstraints c) {
      double width = c.hasBoundedWidth
          ? c.maxWidth
          : appleMusicShelfTileWidth(context);
      // 父级定了高（别的页面按自己的度量排的货架 / 网格）：封面让出文字放不下的
      // 那部分，整卡恰好装进格子，不溢出。
      if (c.hasBoundedHeight) {
        final double excess =
            AppleMusicCoverTile.heightFor(context, width) - c.maxHeight;
        if (excess > 0) width = math.max(0, width - excess);
      }
      return Align(
        alignment: AlignmentDirectional.topStart,
        child: AppleMusicCoverTile(
          title: title,
          subtitle: subtitle,
          cover: cover,
          width: width,
          onTap: onTap,
          circular: circular,
          subtitleTrailing: subtitleTrailing,
        ),
      );
    },
  );
}

/// 货架上一张平封面卡的标准宽（iOS 150，macOS 档 ×scale）。
double appleMusicShelfTileWidth(BuildContext context) =>
    150 * FushiAppleMetrics.of(context).scale;

/// 一排平封面货架（段标题 + 横滑）：[children] 每条按货架标准宽排，卡片自己按
/// 父级宽画（[AppleMusicAutoCoverTile]）。没有条目不占位。
class AppleMusicCoverShelfSection extends StatelessWidget {
  const AppleMusicCoverShelfSection({
    super.key,
    required this.title,
    required this.children,
    this.onOpen,
    this.openKey,
    this.circular = false,
  });

  final String title;
  final List<Widget> children;
  final VoidCallback? onOpen;
  final Key? openKey;

  /// 艺人头像货架（条目更窄、间距更大）。
  final bool circular;

  @override
  Widget build(BuildContext context) {
    if (children.isEmpty) return const SizedBox.shrink();
    final double k = FushiAppleMetrics.of(context).scale;
    final double w = circular ? 112 * k : appleMusicShelfTileWidth(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        AppleMusicSectionHeader(title: title, onOpen: onOpen, openKey: openKey),
        AppleMusicCarousel(
          itemCount: children.length,
          itemExtent: w,
          spacing: (circular ? 16 : 12) * k,
          height: AppleMusicCoverTile.heightFor(context, w),
          arrowCenter: w / 2,
          itemBuilder: (BuildContext context, int i) => children[i],
        ),
      ],
    );
  }
}

/// 平封面网格的格子几何：[width] 是网格可用宽（已去页边）。
({int columns, double tileWidth, SliverGridDelegate delegate})
appleMusicCoverGridGeometry(BuildContext context, double width) {
  final FushiAppleMetrics m = FushiAppleMetrics.of(context);
  final double k = m.scale;
  final double gap = (m.desktop ? 16 : 12) * k;
  final double target = m.desktop ? 160 * k : 160;
  final int columns = math.max(2, ((width + gap) / (target + gap)).floor());
  final double tile = (width - gap * (columns - 1)) / columns;
  return (
    columns: columns,
    tileWidth: tile,
    delegate: SliverGridDelegateWithFixedCrossAxisCount(
      crossAxisCount: columns,
      crossAxisSpacing: gap,
      mainAxisSpacing: 18 * k,
      mainAxisExtent: AppleMusicCoverTile.heightFor(context, tile),
    ),
  );
}

/// 一页平封面网格 / Apple 列表（Apple 版的「查看全部」/ 分区内容）：[tileBuilder]
/// 非 null 排平封面网格（格宽自适应，iOS 至少两列），否则按 [rowBuilder] 排 Apple
/// 列表行。[header] 随列表滚（新建歌单 / 筛选条），[footer] 是分页加载的尾巴。
class AppleMusicCollectionView extends StatelessWidget {
  const AppleMusicCollectionView({
    super.key,
    required this.itemCount,
    required this.rowBuilder,
    this.tileBuilder,
    this.header,
    this.footer,
    this.scrollKey,
    this.controller,
    this.topInset = true,
  });

  final int itemCount;
  final IndexedWidgetBuilder rowBuilder;
  final IndexedWidgetBuilder? tileBuilder;
  final Widget? header;
  final Widget? footer;
  final Key? scrollKey;
  final ScrollController? controller;

  /// 顶部让出 `MediaQuery.padding.top`（页头玻璃下面）。
  final bool topInset;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final double pad = appleMusicPagePadding(context);
    final MediaQueryData mq = MediaQuery.of(context);
    final IndexedWidgetBuilder? tile = tileBuilder;
    final Widget? header = this.header;
    final Widget? footer = this.footer;
    final Widget body = tile == null
        ? SliverList(
            delegate: SliverChildBuilderDelegate(
              fushiStaggeredItemBuilder(rowBuilder),
              childCount: itemCount,
            ),
          )
        : SliverLayoutBuilder(
            builder: (BuildContext context, SliverConstraints c) => SliverGrid(
              gridDelegate: appleMusicCoverGridGeometry(
                context,
                c.crossAxisExtent,
              ).delegate,
              delegate: SliverChildBuilderDelegate(
                fushiStaggeredItemBuilder(tile),
                childCount: itemCount,
              ),
            ),
          );
    return FushiEntranceScope(
      child: CustomScrollView(
        key: scrollKey,
        controller: controller,
        slivers: <Widget>[
          SliverPadding(
            padding: EdgeInsets.fromLTRB(
              pad,
              (topInset ? mq.padding.top : 0) + tokens.spacing.gap,
              pad,
              mq.padding.bottom + tokens.spacing.section,
            ),
            sliver: SliverMainAxisGroup(
              slivers: <Widget>[
                if (header != null) ...<Widget>[
                  SliverToBoxAdapter(
                    child: FushiStaggeredEntrance(index: 0, child: header),
                  ),
                  SliverToBoxAdapter(
                    child: SizedBox(height: tokens.spacing.gap),
                  ),
                ],
                body,
                if (footer != null) SliverToBoxAdapter(child: footer),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 一页彩色分类块网格（流派 / 分面目录）：两列起，宽窗按 160 宽加列；[footer] 是
/// 分页续载的尾巴。
class AppleMusicCategoryGrid extends StatelessWidget {
  const AppleMusicCategoryGrid({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    this.footer,
    this.topInset = true,
  });

  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;
  final Widget? footer;

  /// 顶部让出 `MediaQuery.padding.top`（页头玻璃下面）。
  final bool topInset;

  @override
  Widget build(BuildContext context) {
    final double k = FushiAppleMetrics.of(context).scale;
    final double gap = 12 * k;
    final double pad = appleMusicPagePadding(context);
    final MediaQueryData mq = MediaQuery.of(context);
    final Widget? footer = this.footer;
    return FushiEntranceScope(
      child: CustomScrollView(
        slivers: <Widget>[
          SliverPadding(
            padding: EdgeInsets.fromLTRB(
              pad,
              (topInset ? mq.padding.top : 0) + 12 * k,
              pad,
              mq.padding.bottom + 24 * k,
            ),
            sliver: SliverMainAxisGroup(
              slivers: <Widget>[
                SliverLayoutBuilder(
                  builder: (BuildContext context, SliverConstraints c) =>
                      SliverGrid(
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: math.max(
                            2,
                            ((c.crossAxisExtent + gap) / (160 * k + gap))
                                .floor(),
                          ),
                          crossAxisSpacing: gap,
                          mainAxisSpacing: gap,
                          mainAxisExtent: 96 * k,
                        ),
                        delegate: SliverChildBuilderDelegate(
                          fushiStaggeredItemBuilder(itemBuilder),
                          childCount: itemCount,
                        ),
                      ),
                ),
                if (footer != null) SliverToBoxAdapter(child: footer),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
