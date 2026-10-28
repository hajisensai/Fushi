import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_hover_lift.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_resume_actions.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_expressive_controls.dart'
    show FushiButtonSize;
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/components/shelf_card_widgets.dart';

/// 书架 / 漫画书架 / 游戏 / 视频 / 首页共用的「继续」大卡（2026-10-28 统一）：
/// 满宽 tonal 卡，起始侧封面，「眉标 → 标题 → 元信息 → 进度 → 按钮」，背景
/// 海报。整卡点按 = 主按钮，悬停抬升（[FushiHoverLift]）、按压下沉与焦点环由
/// [FushiCard] 提供；进场随页面错峰淡入。
///
/// 背景海报只用于有构图的剧照（视频，给 [backdropAspectRatio]）：宽卡变成占满
/// 整行的横幅，剧照按原比例**完整**贴在行尾（不裁切），起始边淡出进卡面，封面
/// 与文字在起始侧。书 / 漫画 / 游戏是纯色卡（模糊封面底纹 2026-10-28 撤掉）。
///
/// 整卡是唯一的焦点站点：主按钮只是同一动作的视觉入口，不再单独抢焦点；次按钮
/// （「详情」）是另一个动作，保留可聚焦。
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
    this.secondary,
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

  /// 横幅卡高：随卡宽按 0.3 换算，夹在 [260, 420]。剧照按原比例贴在行尾时宽
  /// = 卡高 × 比例，宽屏下约占一半，起始侧留给封面与文字。
  static double bannerHeight(double cardWidth) =>
      (cardWidth * 0.3).clamp(260.0, 420.0);

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
  final FushiResumeSecondaryAction? secondary;
  final FushiFocusId? focusId;
  final Key? cardKey;
  final Key? progressKey;

  /// 长按 / 右键（视频首页的条目菜单）。
  final VoidCallback? onLongPress;

  /// 背景海报（视频剧照）。null 或墨水屏 = 纯色卡。
  final Widget? backdrop;

  /// [backdrop] 是有构图的图（视频剧照 16:9）时给它的宽高比：卡变横幅、剧照按
  /// 原比例完整显示。null = 模糊封面这类没有构图的底纹。
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

    // 卡上只剩次按钮（「详情」/「打开专辑」）；继续 = 点整张卡。
    final FushiResumeSecondaryAction? second = secondary;
    Widget actions({required bool fill}) => second == null
        ? const SizedBox.shrink()
        : FushiPressScale(
            scale: 0.96,
            child: FushiFilledButton.tonalIcon(
              key: second.key,
              size: FushiButtonSize.m,
              onPressed: second.onPressed,
              icon: FushiIcon(second.icon),
              label: Text(second.label, maxLines: 1),
            ),
          );
    final double actionsGap = second == null ? 0 : tokens.spacing.gap * 2;

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
      color: tokens.surfaces.group,
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
          final double gap = tokens.spacing.gap * (roomy ? 2.5 : 1.5);
          final double? stillAspect = poster == null
              ? null
              : backdropAspectRatio;
          final bool banner = roomy && stillAspect != null;
          final double cardHeight = banner ? bannerHeight(outer.maxWidth) : 0;
          // 横幅里剧照按原比例完整显示的宽（行尾）；起始侧剩下的给封面与文字。
          final double stillWidth = banner
              ? math.min(cardHeight * stillAspect, outer.maxWidth * 0.62)
              : 0;
          final double coverHeight = banner
              ? math.min(cardHeight - pad.vertical, 260.0)
              : (roomy ? 176 : 102);
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

          if (banner) {
            // 横幅：行尾 = 原比例清晰剧照，起始边淡出进卡面；起始侧叠封面 + 信息。
            return SizedBox(
              height: cardHeight,
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  PositionedDirectional(
                    top: 0,
                    bottom: 0,
                    end: 0,
                    width: stillWidth,
                    child: fade(
                      poster!,
                      <double>[0, 1, 1],
                      const <double>[0, 0.22, 1],
                    ),
                  ),
                  PositionedDirectional(
                    top: 0,
                    bottom: 0,
                    start: 0,
                    end: math.max(0, stillWidth - 96),
                    child: Padding(
                      padding: pad,
                      child: Row(
                        children: <Widget>[
                          coverBox,
                          SizedBox(width: gap),
                          Expanded(
                            child: Align(
                              alignment: AlignmentDirectional.centerStart,
                              child: ConstrainedBox(
                                constraints: const BoxConstraints(
                                  maxWidth: 520,
                                ),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: <Widget>[
                                    info(),
                                    SizedBox(height: actionsGap),
                                    actions(fill: false),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            );
          }

          final Widget body = roomy
              // 宽卡：封面 | 信息列（眉标 → 标题 → 元信息 → 进度 → 按钮）；信息列
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
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              info(),
                              SizedBox(height: actionsGap),
                              actions(fill: false),
                            ],
                          ),
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
                    if (second != null) ...<Widget>[
                      SizedBox(height: tokens.spacing.gap * 1.5),
                      actions(fill: true),
                    ],
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
                    // 窄卡上的剧照：按原比例贴在行尾（宽封顶 65%），起始边淡出。
                    : LayoutBuilder(
                        builder: (BuildContext _, BoxConstraints box) {
                          final double w = math.min(
                            box.maxHeight * stillAspect,
                            box.maxWidth * 0.65,
                          );
                          return Align(
                            alignment: AlignmentDirectional.centerEnd,
                            child: SizedBox(
                              width: w,
                              height: box.maxHeight,
                              child: fade(
                                poster,
                                <double>[0, 0.8, 1],
                                const <double>[0, 0.3, 0.5],
                              ),
                            ),
                          );
                        },
                      ),
              ),
              padded,
            ],
          );
        },
      ),
    );
    final Widget lifted = FushiHoverLift(
      scale: 1.01,
      builder: (BuildContext _, bool __) => card,
    );
    final int? index = entranceIndex;
    return index == null
        ? lifted
        : FushiStaggeredEntrance(index: index, child: lifted);
  }
}
