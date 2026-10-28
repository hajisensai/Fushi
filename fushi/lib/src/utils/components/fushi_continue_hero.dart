import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_hover_lift.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_m3e_list_card.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/components/shelf_card_widgets.dart';

/// 书架 / 漫画书架 / 游戏 / 视频 / 首页共用的「继续」大卡（2026-10-28 统一）：
/// 满宽 tonal 卡，起始侧封面，「眉标 → 标题 → 元信息 → 进度」，背景海报。
/// 整卡点按 = 继续，悬停抬升（[FushiHoverLift]）、按压下沉与焦点环由
/// [FushiCard] 提供；进场随页面错峰淡入。
///
/// 背景海报只用于有构图的剧照（视频，给 [backdropAspectRatio]）：剧照铺满整卡
/// （按卡片比例裁切），起始侧淡成底纹托住封面与文字、行尾清晰（用户 2026-10-28
/// 「整块都是横屏图覆盖」）。卡高与书架同一档，不为剧照拉成高横幅（同日「继续
/// 观看还是太大了」）。
/// 书 / 漫画 / 游戏是纯色卡（模糊封面底纹 2026-10-28 撤掉）。
///
/// 卡宽封顶 [maxWidth]、贴起始侧（用户同日「横屏全宽有点丑」）：满宽铺开时
/// 封面与文字只占起始侧一小块，剩下一大片空。
///
/// 卡上不放任何按钮（2026-10-28 用户拍板）：整卡点按 = 继续，「详情 / 打开专辑」
/// 这类次动作走长按 / 右键（[onLongPress]）。整卡是唯一的焦点站点。
///
/// 底色与合集详情 hero 同一块色（[fushiHeroBlockColor]），库页外的「继续」卡与
/// 合集里的 hero 一眼看出是同一种东西。
class FushiContinueHero extends StatelessWidget {
  const FushiContinueHero({
    required this.cover,
    required this.eyebrow,
    required this.title,
    required this.onOpen,
    this.coverAspectRatio = 2 / 3,
    this.metaLines = const <String>[],
    this.progress,
    this.progressLabel,
    this.focusId,
    this.cardKey,
    this.progressKey,
    this.entranceIndex = 0,
    this.frameCover = true,
    this.onLongPress,
    this.metaIcon,
    this.backdrop,
    this.backdropAspectRatio,
    super.key,
  });

  /// 卡宽上限，见类注释。尺寸对齐旧版继续卡（用户 2026-10-28 给的旧版截图：
  /// 约 750 宽、封面 112 高、内边距 12）。
  static const double maxWidth = 750;

  /// 内容区（扣掉内边距）≥ 它时是宽卡：封面 [_roomyCoverHeight] 高。
  static const double _roomyMinWidth = 640;

  /// 宽卡封面高（窄卡 102）。
  static const double _roomyCoverHeight = 112;

  /// 首屏骨架用的卡高：与真卡同一套判据（同一个宽度上限与宽 / 窄分档），骨架
  /// 换真卡不跳。
  static double placeholderHeight(double cardWidth, {required double gap}) {
    final double pad = gap * 1.5;
    final bool roomy =
        math.min(cardWidth, maxWidth) - pad * 2 >= _roomyMinWidth;
    return (roomy ? _roomyCoverHeight : 102.0) + pad * 2;
  }

  /// 封面（调用方自带材质 / 占位）；[frameCover] 时外面套 [ShelfCoverFrame]。
  final Widget cover;

  /// false：[cover] 自带框（如游戏盒框），不再套 [ShelfCoverFrame]。
  final bool frameCover;

  /// 封面宽高比（书 / 漫画 2:3，游戏盒 [kShelfGameCaseAspectRatio]，视频海报
  /// 2:3 / 剧照 16:9）。封面按**高度**定尺寸。
  final double coverAspectRatio;
  final String eyebrow;
  final String title;
  final List<String> metaLines;

  /// 0..1；null = 不画进度行。
  final double? progress;

  /// 进度条行尾文字（「已读 27%」）。
  final String? progressLabel;

  /// 整卡点按 = 继续（卡上不再单放「继续」主按钮）。
  final VoidCallback? onOpen;
  final FushiFocusId? focusId;
  final Key? cardKey;
  final Key? progressKey;

  /// 长按 / 右键：条目菜单或详情（游戏详情、音乐专辑、视频条目菜单）。
  final VoidCallback? onLongPress;

  /// 背景海报（视频剧照）。null 或墨水屏 = 纯色卡。
  final Widget? backdrop;

  /// [backdrop] 是有构图的图（视频剧照 16:9）时给它的宽高比：剧照铺满整卡、
  /// 起始侧淡出。null = 模糊封面这类没有构图的底纹。
  final double? backdropAspectRatio;

  /// 第一行元信息前的小图标（视频远端条目的云图标）。
  final IconData? metaIcon;

  /// 错峰进场序号；null = 调用方自己包进场动画。
  final int? entranceIndex;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool eink = isEinkTheme(context);
    final bool apple = isGlassDesign(context) && !eink;
    final Color accent = eink
        ? cs.onSurface
        : (apple ? appleColorsOf(context).accent : tokens.surfaces.primary);
    final TextStyle titleStyle = tokens.type.listTitle.copyWith(
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

    // 海报用**透明度遮罩**淡出（不是盖一层卡面色渐变）：卡片的悬停 / 按压高亮
    // 画在内容下面，盖固定色会在海报起始边露出一道接缝。
    Widget fade(Widget image, List<double> opacity, List<double> stops) =>
        ShaderMask(
          blendMode: BlendMode.dstIn,
          shaderCallback: (Rect r) => LinearGradient(
            begin: AlignmentDirectional.centerStart,
            end: AlignmentDirectional.centerEnd,
            colors: <Color>[
              for (final double o in opacity) Colors.black.withValues(alpha: o),
            ],
            stops: stops,
          ).createShader(r, textDirection: Directionality.of(context)),
          child: image,
        );

    final Widget? poster = eink ? null : backdrop;
    final Widget card = FushiCard(
      key: cardKey,
      focusId: focusId,
      color: eink || apple ? tokens.surfaces.group : fushiHeroBlockColor(cs),
      borderRadius: eink || apple ? null : FushiM3eShape.containerLargeRadius,
      // 背景海报要贴边铺满到圆角，内边距挪到 Stack 里的内容层。
      padding: EdgeInsets.zero,
      onTap: onOpen,
      onLongPress: onLongPress,
      onSecondaryTap: onLongPress,
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints outer) {
          final EdgeInsets pad = EdgeInsets.all(tokens.spacing.gap * 1.5);
          final BoxConstraints c = outer.deflate(pad);
          final bool roomy = c.maxWidth >= _roomyMinWidth;
          final double gap = tokens.spacing.gap * (roomy ? 2 : 1.5);
          final double? stillAspect = backdropAspectRatio;
          final double coverHeight = roomy ? _roomyCoverHeight : 102;
          // 横图封面在窄卡上别吃掉信息列：宽度封顶卡宽 40%。
          final double coverWidth = (coverHeight * coverAspectRatio).clamp(
            0.0,
            c.maxWidth * 0.4,
          );
          final Widget coverBox = SizedBox(
            width: coverWidth,
            height: coverWidth / coverAspectRatio,
            child: frameCover ? ShelfCoverFrame(child: cover) : cover,
          );

          final Widget body = roomy
              // 宽卡：封面 | 信息列（眉标 → 标题 → 元信息 → 进度）；信息列
              // 封顶 520，进度条不被拉成整行长线。
              ? Row(
                  children: <Widget>[
                    coverBox,
                    SizedBox(width: gap),
                    Expanded(
                      child: Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 520),
                          child: info(),
                        ),
                      ),
                    ),
                  ],
                )
              : Column(
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
                  ],
                );
          final Widget padded = Padding(padding: pad, child: body);
          if (poster == null) return padded;
          return Stack(
            children: <Widget>[
              Positioned.fill(
                child: stillAspect == null
                    // 模糊封面：整卡淡淡一层底纹，行尾稍浓。
                    ? fade(
                        poster,
                        <double>[0, 0.18, roomy ? 0.5 : 0.35],
                        const <double>[0, 0.45, 1],
                      )
                    // 剧照铺满整卡（用户 2026-10-28「整块都是横屏图覆盖」）：
                    // cover 裁成卡片比例，起始侧淡成底纹托住文字，行尾清晰。
                    : fade(
                        poster,
                        roomy
                            ? <double>[0.28, 0.45, 1]
                            : <double>[0.18, 0.3, 0.7],
                        const <double>[0, 0.4, 0.85],
                      ),
              ),
              padded,
            ],
          );
        },
      ),
    );
    final Widget lifted = Align(
      alignment: AlignmentDirectional.centerStart,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: maxWidth),
        child: FushiHoverLift(
          scale: 1.01,
          builder: (BuildContext _, bool __) => card,
        ),
      ),
    );
    final int? index = entranceIndex;
    return index == null
        ? lifted
        : FushiStaggeredEntrance(index: index, child: lifted);
  }
}

/// 「继续」卡与合集详情 hero 共用的 M3E 色块：primaryContainer 叠在
/// surfaceContainerLow 上。
///
/// 深色下 vibrant 方案的 primaryContainer 是 tone 30 的满彩度色（紫色主题下一大块
/// 纯紫，iOS 深色反馈截图），叠 62% 后整块像一面纯色墙、压过封面与正文；深色改叠
/// 32%，色相仍在、彩度降到与其它深色卡面同一档。浅色维持原配比。
Color fushiHeroBlockColor(ColorScheme scheme) => Color.alphaBlend(
  scheme.primaryContainer.withValues(
    alpha: scheme.brightness == Brightness.dark ? 0.32 : 0.62,
  ),
  scheme.surfaceContainerLow,
);
