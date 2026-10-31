/// 复习页「复习选项 → 手势」：问题面 / 答案面各一组「手势 → 动作」（映射与判定见
/// srs_review_gestures.dart）。改了立即生效（按 profile 的偏好）。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/srs/srs_review_gestures.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// 手势的界面名。
String srsReviewGestureLabel(SrsReviewGesture g) => switch (g) {
  SrsReviewGesture.tapLeft => t.srs_review_gestures_tap_left,
  SrsReviewGesture.tapCenter => t.srs_review_gestures_tap_center,
  SrsReviewGesture.tapRight => t.srs_review_gestures_tap_right,
  SrsReviewGesture.doubleTap => t.srs_review_gestures_double_tap,
  SrsReviewGesture.longPress => t.srs_review_gestures_long_press,
  SrsReviewGesture.swipeLeft => t.srs_review_gestures_swipe_left,
  SrsReviewGesture.swipeRight => t.srs_review_gestures_swipe_right,
  SrsReviewGesture.swipeUp => t.srs_review_gestures_swipe_up,
  SrsReviewGesture.swipeDown => t.srs_review_gestures_swipe_down,
};

/// 动作的界面名：与复习页上对应按钮同一个词。
String srsReviewGestureActionLabel(SrsReviewGestureAction a) => switch (a) {
  SrsReviewGestureAction.none => t.srs_review_gestures_action_none,
  SrsReviewGestureAction.showAnswer => t.srs_review_show_answer,
  SrsReviewGestureAction.rateAgain => t.srs_rating_again,
  SrsReviewGestureAction.rateHard => t.srs_rating_hard,
  SrsReviewGestureAction.rateGood => t.srs_rating_good,
  SrsReviewGestureAction.rateEasy => t.srs_rating_easy,
  SrsReviewGestureAction.undo => t.undo,
  SrsReviewGestureAction.replayAudio => t.srs_review_replay_audio,
  SrsReviewGestureAction.toggleToolbar =>
    t.srs_review_gestures_action_toggle_toolbar,
  SrsReviewGestureAction.editNote => t.srs_note_edit,
  SrsReviewGestureAction.bury => t.srs_card_bury,
  SrsReviewGestureAction.suspend => t.srs_card_suspend,
  SrsReviewGestureAction.flag => t.srs_card_flag,
};

/// 动作的图标（与复习页上对应按钮同一个）；评分没有图标，按评分色调显示。
IconData? srsReviewGestureActionIcon(SrsReviewGestureAction a) => switch (a) {
  SrsReviewGestureAction.none => null,
  SrsReviewGestureAction.showAnswer => FushiIcons.visibility,
  SrsReviewGestureAction.rateAgain ||
  SrsReviewGestureAction.rateHard ||
  SrsReviewGestureAction.rateGood ||
  SrsReviewGestureAction.rateEasy => null,
  SrsReviewGestureAction.undo => FushiIcons.undo,
  SrsReviewGestureAction.replayAudio => FushiIcons.replay,
  SrsReviewGestureAction.toggleToolbar => FushiIcons.dashboardCustomize,
  SrsReviewGestureAction.editNote => FushiIcons.edit,
  SrsReviewGestureAction.bury => FushiIcons.schedule,
  SrsReviewGestureAction.suspend => FushiIcons.pause,
  SrsReviewGestureAction.flag => FushiIcons.flag,
};

/// 打开「手势」设置页。
Future<void> openSrsReviewGesturesPage(BuildContext context) =>
    Navigator.of(context).push<void>(
      adaptivePageRoute<void>(
        context: context,
        builder: (_) => const SrsReviewGesturesPage(),
      ),
    );

/// 「手势」设置页：两面各一组，每个手势一行选动作。
class SrsReviewGesturesPage extends ConsumerWidget {
  const SrsReviewGesturesPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppModel app = ref.read(appProvider);
    final SrsReviewGestureMap map = ref.watch(srsReviewGesturesProvider);
    final bool hideHardEasy = ref.watch(srsReviewHideHardEasyProvider);

    // 每面的可选动作都多于行内下拉的上限（kSettingsPickerInlineLimit），一律走整页选择
    // （与 AdaptiveSettingsPickerRow 的长列表分支同一个 pickOption）；行副标题是当前
    // 动作，被「只留重来 / 良好」屏蔽时随附说明（长列表分支的副标题只能放当前值）。
    Widget row(SrsReviewSide side, SrsReviewGesture g) {
      final SrsReviewGestureAction selected = map.actionFor(side, g);
      final String label = srsReviewGestureActionLabel(selected);
      final String title = srsReviewGestureLabel(g);
      return FushiPressScale(
        child: AdaptiveSettingsNavigationRow(
          key: ValueKey<String>('srs-gesture-${side.name}-${g.wire}'),
          title: title,
          subtitle: selected.hiddenBy(hideHardEasy: hideHardEasy)
              ? '$label · ${t.srs_review_gestures_rating_hidden}'
              : label,
          icon: srsReviewGestureActionIcon(selected),
          showIcon: srsReviewGestureActionIcon(selected) != null,
          onTap: () async {
            final SrsReviewGestureAction? picked =
                await pickOption<SrsReviewGestureAction>(
                  context,
                  title: title,
                  selected: selected,
                  options: <FushiOptionSelectionOption<SrsReviewGestureAction>>[
                    for (final SrsReviewGestureAction a
                        in SrsReviewGestureAction.choicesFor(side))
                      FushiOptionSelectionOption<SrsReviewGestureAction>(
                        value: a,
                        label: srsReviewGestureActionLabel(a),
                      ),
                  ],
                );
            if (picked == null || picked == selected) return;
            // 选择页开着期间映射可能已变（重置等）：按最新的写。
            await app.setSrsReviewGestures(
              ref.read(srsReviewGesturesProvider).withBinding(side, g, picked),
            );
          },
        ),
      );
    }

    Widget section(SrsReviewSide side) => AdaptiveSettingsSection(
      key: ValueKey<String>('srs-gestures-section-${side.name}'),
      title: side == SrsReviewSide.front
          ? t.srs_review_gestures_front
          : t.srs_review_gestures_back,
      children: <Widget>[
        for (final SrsReviewGesture g in SrsReviewGesture.values) row(side, g),
      ],
    );

    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return AdaptiveSettingsScaffold(
      title: Text(t.srs_review_gestures_title),
      actions: <Widget>[
        FushiIconButton(
          key: const ValueKey<String>('srs-gestures-reset'),
          icon: FushiIcons.restart,
          tooltip: t.srs_review_gestures_reset,
          enabled: !map.isDefault,
          onTap: () => app.setSrsReviewGestures(SrsReviewGestureMap.defaults),
        ),
      ],
      children: <Widget>[
        // 新页面动效：说明与两组错峰进场、行按压缩放，时长走 FushiMotion（墨水屏 /
        // 减弱动态效果下组件自己归零）。
        FushiEntranceScope(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              FushiStaggeredEntrance(
                index: 0,
                child: Padding(
                  padding: EdgeInsets.only(bottom: tokens.spacing.gap),
                  child: Text(
                    t.srs_review_gestures_note,
                    key: const ValueKey<String>('srs-gestures-note'),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
              FushiStaggeredEntrance(
                index: 1,
                child: section(SrsReviewSide.front),
              ),
              FushiStaggeredEntrance(
                index: 2,
                child: section(SrsReviewSide.back),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
