/// 首页「本版新内容」卡片：升级后出现一次。「看看新内容」打开新内容页（打开即算
/// 看过）；「✕」把卡片收起，首页顶栏留一个入口，直到打开看过（见
/// [WhatsNewStage.entry]）。
library;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/updates/whats_new.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart'
    show isEinkTheme, isGlassDesign;
import 'package:fushi/src/utils/components/fushi_animated_size.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

class WhatsNewHomeCard extends StatelessWidget {
  const WhatsNewHomeCard({
    super.key,
    required this.controller,
    required this.onOpen,
  });

  final WhatsNewController controller;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return ListenableBuilder(
      listenable: controller,
      builder: (BuildContext context, Widget? _) {
        final WhatsNewStatus status = controller.status;
        final bool visible = status.stage == WhatsNewStage.card;
        // 出现 / 收起走尺寸 + 淡入淡出（减弱动态效果下零时长）；下间距挂在有内容
        // 的那一支上，没有新内容时首页顶部不留空。
        return FushiAnimatedSize(
          duration: fushiMotionDuration(context, FushiMotion.medium),
          curve: FushiMotion.standard,
          alignment: Alignment.topCenter,
          child: AnimatedSwitcher(
            duration: fushiMotionDuration(context, FushiMotion.short),
            child: visible
                ? Padding(
                    key: const ValueKey<String>('whats-new-card'),
                    padding: EdgeInsets.only(bottom: tokens.spacing.card),
                    child: _card(context, tokens, status),
                  )
                : const SizedBox(
                    key: ValueKey<String>('whats-new-card-hidden'),
                    width: double.infinity,
                  ),
          ),
        );
      },
    );
  }

  Widget _card(
    BuildContext context,
    FushiDesignTokens tokens,
    WhatsNewStatus status,
  ) {
    final ThemeData theme = Theme.of(context);
    final bool apple = isGlassDesign(context);
    final bool eink = isEinkTheme(context);
    final Color fill = apple
        ? appleColorsOf(context).secondaryGroupedBackground
        : theme.colorScheme.tertiaryContainer;
    final Color onFill = apple
        ? tokens.surfaces.onSurface
        : theme.colorScheme.onTertiaryContainer;
    return FushiPressScale(
      child: Material(
        color: eink ? Colors.transparent : fill,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(apple ? 12 : 28),
          side: eink
              ? BorderSide(color: tokens.surfaces.outline)
              : BorderSide.none,
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onOpen,
          child: Padding(
            padding: EdgeInsetsDirectional.only(
              start: tokens.spacing.card,
              end: tokens.spacing.gap / 2,
              top: tokens.spacing.gap / 2,
              bottom: tokens.spacing.card,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    FushiIcon(
                      FushiIcons.celebration,
                      size: 22,
                      color: apple ? theme.colorScheme.primary : onFill,
                    ),
                    SizedBox(width: tokens.spacing.gap),
                    Expanded(
                      child: Text(
                        t.whats_new_card_title(version: status.toVersion),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.fushiType.titleMedium.copyWith(
                          color: onFill,
                        ),
                      ),
                    ),
                    FushiIconButton(
                      key: const ValueKey<String>('whats-new-card-dismiss'),
                      icon: FushiIcons.close,
                      tooltip: t.home_updates_dismiss,
                      onTap: controller.dismissCard,
                    ),
                  ],
                ),
                Padding(
                  padding: EdgeInsetsDirectional.only(end: tokens.spacing.card),
                  child: Text(
                    t.whats_new_card_body,
                    style: tokens.type.metadata.copyWith(color: onFill),
                  ),
                ),
                SizedBox(height: tokens.spacing.gap),
                FushiFilledButton.icon(
                  key: const ValueKey<String>('whats-new-card-open'),
                  onPressed: onOpen,
                  icon: const FushiIcon(FushiIcons.forward),
                  label: Text(t.whats_new_card_open),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
