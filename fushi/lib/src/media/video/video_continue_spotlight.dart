import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_hover_lift.dart';
import 'package:fushi/src/utils/components/fushi_m3e_list_card.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/components/section_swipe_navigator.dart';
import 'package:fushi/src/utils/components/shelf_card_widgets.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/platform_utils.dart';

/// 视频首页「继续观看」首屏区（2026-10-28 用户在设计稿
/// `fushi/build/video_home_redesign/v2.html` 里选定方案 F「叠层主卡」）：
///
/// - 第一部是 16:9 剧照主卡，眉标 / 片名 / 副标题 / 进度压在底部渐变上；
/// - 其余在看的是 16:9 小卡（集数压在图左下、进度贴图底边、片名在图下）：
///   宽屏在主卡旁排成两行横滑网格（一屏的列数随剩余宽度增减，宽屏不留大片
///   空白），窄屏在主卡下排一条横滑行。
///
/// 这就是首页全部的「继续观看」，下面不再另起一行（用户 2026-10-28「最上面
/// 不就是继续观看，这不就重复了吗」）。卡上不放按钮：点按 = 续播，长按 / 右键
/// = 条目菜单。每张卡是独立焦点站点。
class VideoContinueSpotlight extends StatelessWidget {
  const VideoContinueSpotlight({required this.entries, super.key});

  /// 首个 = 主卡，其后依次是小卡。不能为空。
  final List<VideoContinueSpotlightEntry> entries;

  /// 宽 / 窄分档：内容宽 ≥ 它时主卡与小卡左右并排。
  static const double wideMinWidth = 720;

  /// 宽屏主卡高上限（16:9 → 最宽 640），不再像影院横幅那样占半屏。
  static const double _mainMaxHeight = 360;

  /// 窄屏主卡高上限（平板竖屏不让主卡吃掉半屏）。
  static const double _narrowMainMaxHeight = 300;

  /// 窄屏横滑小卡的宽。
  static const double _narrowSideWidth = 168;

  /// 小卡图下片名一行的高（含与图的间距）。
  static const double _sideTitleHeight = 24;

  /// 横滑区四周给小卡悬停放大留的余量：滚动区要裁切（懒加载 cacheExtent 里建好
  /// 的卡不能画到区外、压到主卡上），贴着视口边的卡放大时不能被裁平。
  static const double _liftRoom = 4;

  static double _gap(double unit) => unit * 1.5;

  /// 宽屏几何：主卡宽高、小卡列数与图高。
  static _WideGeometry _wideGeometry(double width, double gap) {
    final double mainWidth = math.min(width * 0.55, _mainMaxHeight * 16 / 9);
    final double mainHeight = mainWidth * 9 / 16;
    final double sideWidth = width - mainWidth - gap - _liftRoom * 2;
    final double rowHeight = (mainHeight - gap - _liftRoom * 2) / 2;
    final double natural = (rowHeight - _sideTitleHeight) * 16 / 9;
    final int columns = math.max(
      2,
      ((sideWidth + gap) / (natural + gap)).floor(),
    );
    final double cardWidth = (sideWidth - gap * (columns - 1)) / columns;
    return (
      mainWidth: mainWidth,
      mainHeight: mainHeight,
      columns: columns,
      sideWidth: cardWidth,
      sideImageHeight: math.min(
        rowHeight - _sideTitleHeight,
        cardWidth * 9 / 16,
      ),
    );
  }

  /// 首屏骨架的主卡位尺寸：与真主卡同一套几何（[width] 是本组件拿到的宽）。
  /// 骨架只画主卡位——小卡有几张要等数据，窄屏小卡行随数据出现。
  static Size placeholderMainSize(double width, double gapUnit) {
    if (width >= wideMinWidth) {
      final _WideGeometry g = _wideGeometry(width, _gap(gapUnit));
      return Size(g.mainWidth, g.mainHeight);
    }
    return Size(width, math.min(width * 9 / 16, _narrowMainMaxHeight));
  }

  /// 横滑区与首页其它横滚行同一套：鼠标 / 触控板可拖（调用点各自包
  /// [HorizontalDragScrollable]，守卫按文件逐处计数），滑到边缘继续拖交给分区
  /// 级联（[SectionSwipeCascade]）。不接裸滚轮横滚：首页外层是纵向滚动，滚轮要
  /// 留给它。
  static Widget _horizontalScroller(HorizontalDragScrollable scrollable) =>
      SectionSwipeCascade(child: scrollable);

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final double gap = _gap(tokens.spacing.gap);
    final VideoContinueSpotlightEntry main = entries.first;
    final List<VideoContinueSpotlightEntry> rest = entries.skip(1).toList();
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        final double width = c.maxWidth;
        if (width >= wideMinWidth) {
          final _WideGeometry g = _wideGeometry(width, gap);
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              SizedBox(
                width: g.mainWidth,
                height: g.mainHeight,
                child: FushiStaggeredEntrance(
                  index: 0,
                  child: _MainCard(entry: main),
                ),
              ),
              if (rest.isNotEmpty) ...<Widget>[
                SizedBox(width: gap),
                Expanded(
                  child: SizedBox(
                    height: g.mainHeight,
                    child: _horizontalScroller(
                      HorizontalDragScrollable(
                        child: GridView.builder(
                          scrollDirection: Axis.horizontal,
                          padding: const EdgeInsets.all(_liftRoom),
                          physics: desktopAwareScrollPhysics(),
                          itemCount: rest.length,
                          gridDelegate:
                              SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: 2,
                                mainAxisSpacing: gap,
                                crossAxisSpacing: gap,
                                mainAxisExtent: g.sideWidth,
                              ),
                          itemBuilder: (BuildContext _, int i) =>
                              FushiStaggeredEntrance(
                                index: i + 1,
                                child: _SideCard(
                                  entry: rest[i],
                                  imageHeight: g.sideImageHeight,
                                ),
                              ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ],
          );
        }
        final double mainHeight = math.min(
          width * 9 / 16,
          _narrowMainMaxHeight,
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            SizedBox(
              height: mainHeight,
              child: FushiStaggeredEntrance(
                index: 0,
                child: _MainCard(entry: main),
              ),
            ),
            if (rest.isNotEmpty) ...<Widget>[
              SizedBox(height: gap),
              SizedBox(
                height:
                    _narrowSideWidth * 9 / 16 +
                    _sideTitleHeight +
                    _liftRoom * 2,
                child: _horizontalScroller(
                  HorizontalDragScrollable(
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.all(_liftRoom),
                      physics: desktopAwareScrollPhysics(),
                      itemCount: rest.length,
                      separatorBuilder: (BuildContext _, int __) =>
                          SizedBox(width: gap),
                      itemBuilder: (BuildContext _, int i) => SizedBox(
                        width: _narrowSideWidth,
                        child: FushiStaggeredEntrance(
                          index: i + 1,
                          child: _SideCard(
                            entry: rest[i],
                            imageHeight: _narrowSideWidth * 9 / 16,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

/// 宽屏几何（[VideoContinueSpotlight._wideGeometry]）：主卡宽高、小卡列数、
/// 小卡宽与图高。
typedef _WideGeometry = ({
  double mainWidth,
  double mainHeight,
  int columns,
  double sideWidth,
  double sideImageHeight,
});

/// 一部在看的作品（主卡 / 小卡共用）。
class VideoContinueSpotlightEntry {
  const VideoContinueSpotlightEntry({
    required this.cardKey,
    required this.focusId,
    required this.title,
    required this.subtitle,
    required this.image,
    required this.onOpen,
    this.shortSubtitle,
    this.progress,
    this.onLongPress,
    this.cloud = false,
  });

  final Key cardKey;
  final FushiFocusId focusId;
  final String title;

  /// 主卡的完整副标题（「看到第 N 集 · 剩余 M 分钟 · 已看 N 集」）。
  final String subtitle;

  /// 小卡压在图上的那行（不含「已看 N 集」这类追加段）；null = 用 [subtitle]。
  /// 由调用方给，不在这里按分隔符切：「下一集 · 第 N 集」切开就只剩「下一集」。
  final String? shortSubtitle;

  /// 横版剧照（调用方负责无图 / 失败占位）。
  final Widget image;

  /// 0..1；null = 不画进度。
  final double? progress;
  final VoidCallback? onOpen;
  final VoidCallback? onLongPress;

  /// 目标集只在 host 上（副标题前缀云图标）。
  final bool cloud;
}

class _MainCard extends StatelessWidget {
  const _MainCard({required this.entry});

  final VideoContinueSpotlightEntry entry;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme cs = Theme.of(context).colorScheme;
    final TextTheme text = Theme.of(context).textTheme;
    // 文字压在底部暗渐变上，深浅主题一律用浅色字；眉标取固定色调的浅主色
    // （Apple 取系统强调色，墨水屏纯白），与 [FushiContinueHero] 同一套分派。
    final bool eink = isEinkTheme(context);
    final bool apple = isGlassDesign(context) && !eink;
    final Color accent = eink
        ? Colors.white
        : (apple ? appleColorsOf(context).accent : cs.primaryFixedDim);
    final double? v = entry.progress?.clamp(0.0, 1.0);
    return FushiHoverLift(
      enabled: entry.onOpen != null,
      scale: 1.01,
      builder: (BuildContext _, bool __) => FushiCard(
        key: entry.cardKey,
        focusId: entry.focusId,
        padding: EdgeInsets.zero,
        borderRadius: eink || apple ? null : FushiM3eShape.containerLargeRadius,
        onTap: entry.onOpen,
        onLongPress: entry.onLongPress,
        onSecondaryTap: entry.onLongPress,
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            entry.image,
            const IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: <Color>[
                      Color(0xE6120E18),
                      Color(0x80120E18),
                      Color(0x00120E18),
                    ],
                    stops: <double>[0, 0.42, 0.75],
                  ),
                ),
              ),
            ),
            Positioned(
              left: tokens.spacing.gap * 2.5,
              right: tokens.spacing.gap * 2.5,
              bottom: tokens.spacing.gap * 2,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      if (entry.cloud) ...<Widget>[
                        FushiIcon(FushiIcons.cloud, size: 14, color: accent),
                        const SizedBox(width: 4),
                      ],
                      Flexible(
                        child: Text(
                          entry.subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: tokens.type.sectionLabel.copyWith(
                            color: accent,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    entry.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: (text.titleLarge ?? const TextStyle()).copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      height: 1.2,
                    ),
                  ),
                  if (v != null) ...<Widget>[
                    SizedBox(height: tokens.spacing.gap),
                    FushiLinearProgressIndicator(
                      value: v,
                      minHeight: 4,
                      borderRadius: const BorderRadius.all(Radius.circular(2)),
                      color: accent,
                      backgroundColor: Colors.white.withValues(alpha: 0.24),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SideCard extends StatelessWidget {
  const _SideCard({required this.entry, required this.imageHeight});

  final VideoContinueSpotlightEntry entry;
  final double imageHeight;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final String episode = entry.shortSubtitle ?? entry.subtitle;
    return FushiHoverLift(
      enabled: entry.onOpen != null,
      builder: (BuildContext _, bool __) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          SizedBox(
            height: imageHeight,
            child: FushiCard(
              key: entry.cardKey,
              focusId: entry.focusId,
              padding: EdgeInsets.zero,
              borderRadius: const BorderRadius.all(Radius.circular(16)),
              onTap: entry.onOpen,
              onLongPress: entry.onLongPress,
              onSecondaryTap: entry.onLongPress,
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  entry.image,
                  if (episode.isNotEmpty)
                    Positioned(
                      left: 10,
                      right: 10,
                      bottom: 10,
                      child: Text(
                        episode,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: tokens.type.metadata.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          shadows: const <Shadow>[
                            Shadow(color: Color(0xCC000000), blurRadius: 4),
                          ],
                        ),
                      ),
                    ),
                  if (entry.progress != null)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: CoverProgressStrip(value: entry.progress!),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            entry.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: tokens.type.metadata.copyWith(
              color: Theme.of(context).colorScheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }
}
