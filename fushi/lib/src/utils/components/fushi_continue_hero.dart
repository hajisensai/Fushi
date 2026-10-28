import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_hover_lift.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_resume_actions.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/components/shelf_card_widgets.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

/// 书架 / 漫画书架 / 游戏 / 视频 / 首页共用的「继续」大卡（2026-10-28 统一）：
/// tonal 卡，起始侧封面，「眉标 → 标题 → 元信息 → 进度 → 按钮」，背景海报
/// （剧照 / 模糊封面）。整卡点按 = 主按钮，悬停抬升（[FushiHoverLift]）、按压
/// 下沉与焦点环由 [FushiCard] 提供；进场随页面错峰淡入。
///
/// 给了 [aside]（右侧模块：「已更新未看」/「也在读」/「最近玩过」）且宽度
/// ≥ [asideMinWidth] 时左右并排（主卡 : 模块 = [asideFlex] : 1，同高），主卡
/// 变横幅：剧照铺满卡面、起始侧淡出；宽度不够时模块不画，主卡占满整行。
///
/// 整卡是唯一的焦点站点：主按钮只是同一动作的视觉入口，不再单独抢焦点；次按钮
/// （「详情」）是另一个动作，保留可聚焦。
class FushiContinueHero extends StatelessWidget {
  const FushiContinueHero({
    required this.cover,
    required this.eyebrow,
    required this.title,
    required this.actionLabel,
    required this.onOpen,
    this.coverAspectRatio = 2 / 3,
    this.metaLines = const <String>[],
    this.progress,
    this.progressLabel,
    this.actionIcon = FushiIcons.play,
    this.secondary,
    this.focusId,
    this.cardKey,
    this.actionKey,
    this.progressKey,
    this.entranceIndex = 0,
    this.frameCover = true,
    this.onLongPress,
    this.metaIcon,
    this.backdrop,
    this.backdropAspectRatio,
    this.aside,
    this.asideMinWidth = 860,
    this.asideFlex = 1.55,
    super.key,
  });

  /// 封面模糊成背景海报（书 / 漫画 / 游戏没有横版剧照时用自己的封面）。
  static Widget blurredBackdrop(Widget image) => ImageFiltered(
    imageFilter: ui.ImageFilter.blur(sigmaX: 28, sigmaY: 28),
    child: image,
  );

  /// 封面（调用方自带材质 / 占位）；[frameCover] 时外面套 [ShelfCoverFrame]。
  final Widget cover;

  /// false：[cover] 自带框（如游戏盒框），不再套 [ShelfCoverFrame]。
  final bool frameCover;

  /// 封面宽高比（书 / 漫画 2:3，游戏盒 [kShelfGameCaseAspectRatio]，视频剧照
  /// 16:9）。封面按**高度**定尺寸，各域卡高一致、横图自然变宽。
  final double coverAspectRatio;
  final String eyebrow;
  final String title;
  final List<String> metaLines;

  /// 0..1；null = 不画进度行。
  final double? progress;

  /// 进度条行尾文字（「已读 27%」）。
  final String? progressLabel;
  final String actionLabel;
  final IconData actionIcon;
  final VoidCallback? onOpen;
  final FushiResumeSecondaryAction? secondary;
  final FushiFocusId? focusId;
  final Key? cardKey;
  final Key? actionKey;
  final Key? progressKey;

  /// 长按 / 右键（视频首页的条目菜单）。
  final VoidCallback? onLongPress;

  /// 背景海报（视频剧照 / [blurredBackdrop] 模糊封面）：铺满整卡，起始侧用卡面色
  /// 渐变压住保证文字可读，行尾露出画面。null 或墨水屏 = 纯色卡。
  final Widget? backdrop;

  /// 背景海报是一张有构图的图（视频剧照 16:9）时给它的宽高比：按原比例**完整**
  /// 贴在卡片行尾（宽封顶卡宽 65%），起始边渐隐进卡面色，不再铺满裁成一条。
  /// null = 铺满整卡（模糊封面这类没有构图的底纹）。
  final double? backdropAspectRatio;

  /// 右侧并排模块（通常是 [FushiContinueAside]）；null = 主卡占满整行。
  final Widget? aside;

  /// 并排的最小总宽；窄于它时 [aside] 不画。
  final double asideMinWidth;

  /// 并排时主卡与模块的宽度比（主卡 : 模块 = asideFlex : 1）。
  final double asideFlex;

  /// 第一行元信息前的小图标（视频远端条目的云图标）。
  final IconData? metaIcon;

  /// 错峰进场序号；null = 调用方自己包进场动画。
  final int? entranceIndex;

  /// 并排时两边的高度：随主卡宽按 0.45 换算，夹在 [260, 380]（与视频首页横排版
  /// 同一口径）。
  static double splitHeight(double heroWidth) =>
      (heroWidth * 0.45).clamp(260.0, 380.0);

  @override
  Widget build(BuildContext context) {
    final Widget? side = aside;
    final int? index = entranceIndex;
    Widget enter(Widget child, int offset) => index == null && offset == 0
        ? child
        : FushiStaggeredEntrance(index: (index ?? 0) + offset, child: child);
    if (side == null) return enter(_buildCard(context, banner: false), 0);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints outer) {
        if (outer.maxWidth < asideMinWidth) {
          return enter(_buildCard(context, banner: false), 0);
        }
        final double gap = FushiDesignTokens.of(context).spacing.gap * 1.5;
        final double heroWidth =
            (outer.maxWidth - gap) * asideFlex / (asideFlex + 1);
        return SizedBox(
          height: splitHeight(heroWidth),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              SizedBox(
                width: heroWidth,
                child: enter(_buildCard(context, banner: true), 0),
              ),
              SizedBox(width: gap),
              Expanded(child: enter(side, 1)),
            ],
          ),
        );
      },
    );
  }

  Widget _buildCard(BuildContext context, {required bool banner}) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool eink = isEinkTheme(context);
    final bool apple = isGlassDesign(context) && !eink;
    final Color accent = eink
        ? cs.onSurface
        : (apple ? appleColorsOf(context).accent : tokens.surfaces.primary);
    final TextStyle titleStyle = tokens.type.listTitle.copyWith(
      fontSize: (tokens.type.listTitle.fontSize ?? 16) + 4,
      fontWeight: FontWeight.w700,
      height: 1.2,
    );

    Widget info() {
      final double? v = progress?.clamp(0.0, 1.0);
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            eyebrow,
            style: tokens.type.sectionLabel.copyWith(color: accent),
          ),
          SizedBox(height: tokens.spacing.gap / 2),
          ShelfTitleOverflowTooltip(
            title: title,
            style: titleStyle,
            maxLines: 2,
            child: Text(
              title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: titleStyle,
            ),
          ),
          for (int i = 0; i < metaLines.length; i++)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                children: <Widget>[
                  if (i == 0 && metaIcon != null) ...<Widget>[
                    FushiIcon(
                      metaIcon!,
                      size: (tokens.type.metadata.fontSize ?? 12) + 2,
                      color: tokens.type.metadata.color,
                    ),
                    const SizedBox(width: 6),
                  ],
                  Flexible(
                    child: Text(
                      metaLines[i],
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: tokens.type.metadata,
                    ),
                  ),
                ],
              ),
            ),
          if (v != null) ...<Widget>[
            SizedBox(height: tokens.spacing.gap * 1.25),
            Row(
              children: <Widget>[
                Expanded(
                  child: FushiLinearProgressIndicator(
                    key: progressKey,
                    value: v,
                    minHeight: 4,
                    borderRadius: const BorderRadius.all(Radius.circular(2)),
                    // MD3 = M3 Expressive 波浪线性进度（轨道间隙 + 末端停止点，
                    // 轨道色取主题的 M3E 轨道色）；Apple 原生细条；墨水屏平直。
                    color: accent,
                    backgroundColor: apple
                        ? appleColorsOf(context).tertiaryFill
                        : null,
                  ),
                ),
                if (progressLabel != null) ...<Widget>[
                  SizedBox(width: tokens.spacing.gap),
                  Text(progressLabel!, style: tokens.type.metadata),
                ],
              ],
            ),
          ],
        ],
      );
    }

    Widget actions({required bool fill}) => FushiResumeActions(
      primaryKey: actionKey,
      label: actionLabel,
      icon: actionIcon,
      onPressed: onOpen,
      fill: fill,
      primaryFocusable: false,
      secondary: secondary,
    );

    final Color cardColor = tokens.surfaces.group;
    final Widget? poster = eink ? null : backdrop;
    final Widget card = FushiCard(
      key: cardKey,
      focusId: focusId,
      color: cardColor,
      // 背景海报要贴边铺满到圆角，内边距挪到 Stack 里的内容层。
      padding: EdgeInsets.zero,
      onTap: onOpen,
      onLongPress: onLongPress,
      onSecondaryTap: onLongPress,
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints outer) {
          final EdgeInsets pad = EdgeInsets.all(tokens.spacing.gap * 2);
          final BoxConstraints c = outer.deflate(pad);
          final bool roomy = c.maxWidth >= 640;
          final double? stillAspect = poster == null
              ? null
              : backdropAspectRatio;
          // 宽卡按钮在信息列底下，封面与信息列同高。
          final double gap = tokens.spacing.gap * (roomy ? 2.5 : 1.5);
          // 有行尾剧照的宽卡：剧照**永不裁切**（按原比例完整显示），反过来由卡宽
          // 解出卡高，让原比例剧照的宽度正好填满信息列右边的空间：
          //   (h + 上下内边距) × 剧照比 = 卡宽 − 左内边距 − h × 封面比 − 间距 − 信息列
          final double coverHeight;
          if (banner) {
            // 横幅：卡高已由并排布局定好，封面在其中居中。
            coverHeight = math.min(
              roomy ? 176.0 : 102.0,
              outer.maxHeight - pad.vertical,
            );
          } else if (!roomy) {
            coverHeight = 102;
          } else if (stillAspect == null) {
            coverHeight = 176;
          } else {
            final double solved =
                (outer.maxWidth -
                    pad.left -
                    gap -
                    520 -
                    pad.vertical * stillAspect) /
                (stillAspect + coverAspectRatio);
            coverHeight = solved.clamp(176.0, 300.0);
          }
          // 横图（视频剧照）在窄卡上别吃掉信息列：宽度封顶卡宽 40%。
          final double coverWidth = (coverHeight * coverAspectRatio).clamp(
            0.0,
            c.maxWidth * 0.4,
          );
          final Widget coverBox = SizedBox(
            width: coverWidth,
            height: coverWidth / coverAspectRatio,
            child: frameCover ? ShelfCoverFrame(child: cover) : cover,
          );

          // 海报用**透明度遮罩**淡出（不是盖一层卡面色渐变）：卡片的悬停 / 按压
          // 高亮画在内容下面，盖固定色会在海报起始边露出一道接缝。
          Widget fade(Widget image, List<double> opacity, List<double> stops) =>
              ShaderMask(
                blendMode: BlendMode.dstIn,
                shaderCallback: (Rect r) => LinearGradient(
                  begin: AlignmentDirectional.centerStart,
                  end: AlignmentDirectional.centerEnd,
                  colors: <Color>[
                    for (final double o in opacity)
                      Colors.black.withValues(alpha: o),
                  ],
                  stops: stops,
                ).createShader(r, textDirection: Directionality.of(context)),
                child: image,
              );

          Widget layered(Widget body) {
            final Widget padded = banner
                ? Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: Padding(padding: pad, child: body),
                  )
                : Padding(padding: pad, child: body);
            if (poster == null) return padded;
            final Widget layer = banner && stillAspect != null
                // 横幅：剧照铺满卡面（卡已是横幅比例，裁切很少），起始侧淡出。
                ? Positioned.fill(
                    child: fade(
                      poster,
                      <double>[0.1, 0.55, 1],
                      const <double>[0, 0.35, 0.62],
                    ),
                  )
                : stillAspect == null
                // 模糊封面：整卡淡淡一层底纹，行尾稍浓。
                ? Positioned.fill(
                    child: fade(
                      poster,
                      <double>[0, 0.18, roomy ? 0.5 : 0.35],
                      const <double>[0, 0.45, 1],
                    ),
                  )
                // 有构图的剧照：按原比例完整贴在行尾，起始边淡出。
                : Positioned.fill(
                    child: LayoutBuilder(
                      builder: (BuildContext _, BoxConstraints box) {
                        // 剧照恒按原比例完整显示（宽 = 卡高 × 比例），不拉伸不裁切；
                        // 卡高已按卡宽解好，宽卡上它正好接到信息列右边。
                        final double w = math.min(
                          box.maxHeight * stillAspect,
                          box.maxWidth * (roomy ? 0.7 : 0.65),
                        );
                        return Align(
                          alignment: AlignmentDirectional.centerEnd,
                          child: SizedBox(
                            width: w,
                            height: box.maxHeight,
                            child: fade(
                              poster,
                              <double>[0, 0.8, 1],
                              const <double>[0, 0.18, 0.32],
                            ),
                          ),
                        );
                      },
                    ),
                  );
            return Stack(
              fit: banner ? StackFit.expand : StackFit.loose,
              children: <Widget>[layer, padded],
            );
          }

          if (roomy) {
            // 宽卡：封面 | 信息列（眉标 → 标题 → 元信息 → 进度 → 按钮），右侧整块
            // 留给海报；信息列封顶 520，进度条不被拉成整行长线。
            return layered(
              Row(
                children: <Widget>[
                  coverBox,
                  SizedBox(width: gap),
                  Expanded(
                    child: Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 520),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            info(),
                            SizedBox(height: tokens.spacing.gap * 2),
                            actions(fill: false),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          }
          return layered(
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    coverBox,
                    SizedBox(width: gap),
                    Expanded(child: info()),
                  ],
                ),
                SizedBox(height: tokens.spacing.gap * 1.5),
                actions(fill: true),
              ],
            ),
          );
        },
      ),
    );
    return FushiHoverLift(
      scale: 1.01,
      builder: (BuildContext _, bool __) => card,
    );
  }
}

/// [FushiContinueAside] 的一行。
@immutable
class FushiContinueQueueItem {
  const FushiContinueQueueItem({
    required this.cover,
    required this.title,
    required this.onTap,
    this.subtitle,
    this.progress,
    this.trailing,
    this.onLongPress,
    this.focusId,
    this.key,
  });

  final Widget cover;
  final String title;
  final String? subtitle;

  /// 0..1；null = 不画进度。
  final double? progress;

  /// 行尾附件（视频「N 集新」徽标 + 播放钮）。
  final Widget? trailing;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final FushiFocusId? focusId;
  final Key? key;
}

/// 继续卡并排的右侧模块：圆角 tonal 面板，小标题 + 按面板高度放得下的几行
/// （1–4 行；每行小竖封面、标题、副标题 / M3E 平直进度、行尾附件）。
class FushiContinueAside extends StatelessWidget {
  const FushiContinueAside({
    required this.title,
    required this.items,
    this.coverAspectRatio = 2 / 3,
    super.key,
  });

  final String title;
  final List<FushiContinueQueueItem> items;
  final double coverAspectRatio;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool eink = isEinkTheme(context);
    final bool apple = isGlassDesign(context) && !eink;
    final Color accent = eink
        ? cs.onSurface
        : (apple ? appleColorsOf(context).accent : tokens.surfaces.primary);
    // 每行 60 高封面 + 上下各 8 内边距；标题行约 28。
    const double tileExtent = 76;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: tokens.surfaces.group,
        borderRadius: const BorderRadius.all(Radius.circular(28)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 10),
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints c) {
            final int capacity = c.hasBoundedHeight
                ? ((c.maxHeight - 28) / tileExtent).floor().clamp(1, 4)
                : 4;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsetsDirectional.only(
                    start: 8,
                    bottom: 6,
                  ),
                  child: Text(title, style: tokens.type.sectionLabel),
                ),
                for (final FushiContinueQueueItem item in items.take(capacity))
                  _AsideTile(
                    item: item,
                    coverAspectRatio: coverAspectRatio,
                    accent: accent,
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _AsideTile extends StatelessWidget {
  const _AsideTile({
    required this.item,
    required this.coverAspectRatio,
    required this.accent,
  });

  final FushiContinueQueueItem item;
  final double coverAspectRatio;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final TextTheme textTheme = Theme.of(context).textTheme;
    const double coverHeight = 60;
    return FushiCard(
      key: item.key,
      focusId: item.focusId,
      color: Colors.transparent,
      borderColor: Colors.transparent,
      borderRadius: const BorderRadius.all(Radius.circular(16)),
      padding: const EdgeInsets.all(8),
      onTap: item.onTap,
      onLongPress: item.onLongPress,
      onSecondaryTap: item.onLongPress,
      child: Row(
        children: <Widget>[
          SizedBox(
            height: coverHeight,
            width: coverHeight * coverAspectRatio,
            child: ShelfCoverFrame(child: item.cover),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  item.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (item.subtitle != null) ...<Widget>[
                  const SizedBox(height: 2),
                  Text(
                    item.subtitle!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: tokens.type.metadata,
                  ),
                ],
                if (item.progress != null) ...<Widget>[
                  const SizedBox(height: 6),
                  FushiLinearProgressIndicator(
                    value: item.progress!.clamp(0.0, 1.0),
                    minHeight: 3,
                    wavy: false,
                    color: accent,
                  ),
                ],
              ],
            ),
          ),
          if (item.trailing != null) ...<Widget>[
            const SizedBox(width: 8),
            item.trailing!,
          ],
        ],
      ),
    );
  }
}
