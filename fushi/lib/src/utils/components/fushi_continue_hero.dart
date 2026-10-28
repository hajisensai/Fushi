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
import 'package:fushi/src/utils/components/shelf_card_widgets.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

/// 书架 / 漫画书架 / 游戏首页共用的「继续」大卡（2026-10-28 统一）：满宽 tonal
/// 卡，起始侧封面，中间「眉标 → 标题 → 元信息 → 进度」，行尾 [FushiResumeActions]
/// （窄卡换到信息列下方占满整行）。整卡点按 = 主按钮，悬停抬升（[FushiHoverLift]）、
/// 按压下沉与焦点环由 [FushiCard] 提供；进场随页面错峰淡入。
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
    super.key,
  });

  /// 封面（调用方自带材质 / 占位）；[frameCover] 时外面套 [ShelfCoverFrame]。
  final Widget cover;

  /// false：[cover] 自带框（如游戏盒框），不再套 [ShelfCoverFrame]。
  final bool frameCover;

  /// 封面宽高比（书 / 漫画 2:3，游戏盒 [kShelfGameCaseAspectRatio]）。
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
          for (final String line in metaLines)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                line,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: tokens.type.metadata,
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
                    // 卡上不要常驻波浪动画，走平直形态（同封面进度条）。
                    year2023: apple ? null : true,
                    color: accent,
                    backgroundColor: apple
                        ? appleColorsOf(context).tertiaryFill
                        : cs.surfaceContainerHighest,
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

    final Widget card = FushiCard(
      key: cardKey,
      focusId: focusId,
      padding: EdgeInsets.all(tokens.spacing.gap * 2),
      onTap: onOpen,
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints c) {
          final bool roomy = c.maxWidth >= 640;
          final double coverWidth = roomy ? 96 : 68;
          final Widget coverBox = SizedBox(
            width: coverWidth,
            child: AspectRatio(
              aspectRatio: coverAspectRatio,
              child: frameCover ? ShelfCoverFrame(child: cover) : cover,
            ),
          );
          final double gap = tokens.spacing.gap * (roomy ? 2.5 : 1.5);
          if (roomy) {
            return Row(
              children: <Widget>[
                coverBox,
                SizedBox(width: gap),
                // 宽卡信息列封顶 520：进度条不被拉成整行长线，按钮贴行尾。
                Expanded(
                  child: Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 520),
                      child: info(),
                    ),
                  ),
                ),
                SizedBox(width: gap),
                actions(fill: false),
              ],
            );
          }
          return Column(
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
