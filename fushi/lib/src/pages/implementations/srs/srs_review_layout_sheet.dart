/// 复习页 ⋯「复习选项」：复习界面显示什么（对齐 Anki 偏好「复习」页里管显示的几项）——
/// 底部重播键放哪端、评分按钮显不显示下次间隔、页头显不显示剩余卡数、评分栏只留
/// 「重来 / 良好」，以及（当前卡不是 Fushi 卡片时）卡面跟不跟随设计系统。
/// 改了立即生效（按 profile 的偏好），面板开着就能看到复习页随之变化。
///
/// 这些以前有两项（只留重来 / 良好、卡面跟随设计系统）是顶栏上的独立开关按钮，和
/// 卡面样式入口共用同一个调色板图标，复习时满屏一排看不出谁是谁；收进这一个面板。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/srs/srs_review_gestures_page.dart';
import 'package:fushi/src/srs/srs_card_appearance.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/srs/srs_review_layout.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// 打开「复习选项」面板。[showDesignSkin]：当前卡不是 Fushi 卡片时为 true，面板里多一行
/// 「卡面跟随设计系统」（它只作用于非 Fushi 卡片；Fushi 卡片本身就按设计系统画）。
Future<void> showSrsReviewLayoutSheet(
  BuildContext context, {
  bool showDesignSkin = false,
}) => adaptiveModalSheet<void>(
  context: context,
  builder: (BuildContext context) =>
      SrsReviewLayoutSheet(showDesignSkin: showDesignSkin),
);

/// 「复习选项」面板正文。
class SrsReviewLayoutSheet extends ConsumerWidget {
  const SrsReviewLayoutSheet({super.key, this.showDesignSkin = false});

  /// 显示「卡面跟随设计系统」一行（当前卡不是 Fushi 卡片时）。
  final bool showDesignSkin;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppModel app = ref.read(appProvider);
    final SrsReviewReplayButton replay = ref.watch(
      srsReviewReplayButtonProvider,
    );
    final bool intervals = ref.watch(srsReviewShowIntervalsProvider);
    final bool counts = ref.watch(srsReviewShowCountsProvider);
    final bool floating = ref.watch(srsReviewChromeFloatingProvider);
    final bool hideHardEasy = ref.watch(srsReviewHideHardEasyProvider);
    final double volume = ref.watch(srsReviewVolumeProvider);
    final SrsReviewImageSize imageSize = ref.watch(srsReviewImageSizeProvider);
    // 「左 / 右」按视觉方向标：RTL 下行首在右边。
    final bool rtl = Directionality.of(context) == TextDirection.rtl;
    return FushiModalSheetFrame(
      title: t.srs_review_layout_title,
      leadingIcon: FushiIcons.dashboardCustomize,
      scrollable: true,
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          AdaptiveSettingsSegmentedRow<SrsReviewReplayButton>(
            key: const ValueKey<String>('srs-review-layout-replay'),
            title: t.srs_review_layout_replay_button,
            subtitle: t.srs_review_layout_replay_button_hint,
            selected: replay,
            segments: <ButtonSegment<SrsReviewReplayButton>>[
              ButtonSegment<SrsReviewReplayButton>(
                value: SrsReviewReplayButton.off,
                label: Text(t.srs_review_layout_replay_off),
              ),
              ButtonSegment<SrsReviewReplayButton>(
                value: SrsReviewReplayButton.start,
                label: Text(
                  rtl
                      ? t.srs_review_layout_replay_end
                      : t.srs_review_layout_replay_start,
                ),
              ),
              ButtonSegment<SrsReviewReplayButton>(
                value: SrsReviewReplayButton.end,
                label: Text(
                  rtl
                      ? t.srs_review_layout_replay_start
                      : t.srs_review_layout_replay_end,
                ),
              ),
            ],
            onChanged: (SrsReviewReplayButton v) =>
                app.setSrsReviewReplayButton(v),
          ),
          AdaptiveSettingsSliderRow(
            key: const ValueKey<String>('srs-review-layout-volume'),
            title: t.srs_review_layout_volume,
            subtitle: t.srs_review_layout_volume_hint,
            icon: FushiIcons.volumeUp,
            showIcon: true,
            value: volume,
            divisions: 20,
            readout: '${(volume * 100).round()}%',
            onChanged: (double v) => app.setSrsReviewVolume(v),
          ),
          AdaptiveSettingsSwitchRow(
            key: const ValueKey<String>('srs-review-layout-intervals'),
            title: t.srs_review_layout_show_intervals,
            subtitle: t.srs_review_layout_show_intervals_hint,
            value: intervals,
            onChanged: (bool v) => app.setSrsReviewShowIntervals(v),
          ),
          AdaptiveSettingsSwitchRow(
            key: const ValueKey<String>('srs-review-layout-counts'),
            title: t.srs_review_layout_show_counts,
            subtitle: t.srs_review_layout_show_counts_hint,
            value: counts,
            onChanged: (bool v) => app.setSrsReviewShowCounts(v),
          ),
          AdaptiveSettingsSwitchRow(
            key: const ValueKey<String>('srs-review-layout-hide-hard-easy'),
            title: t.srs_review_hide_hard_easy,
            subtitle: t.srs_review_hide_hard_easy_hint,
            value: hideHardEasy,
            onChanged: (bool v) => app.setSrsReviewHideHardEasy(v),
          ),
          AdaptiveSettingsSwitchRow(
            key: const ValueKey<String>('srs-review-layout-floating-top-bar'),
            title: t.srs_review_layout_floating_top_bar,
            subtitle: t.srs_review_layout_floating_top_bar_hint,
            value: floating,
            onChanged: (bool v) => app.setSrsReviewChromeFloating(v),
          ),
          AdaptiveSettingsNavigationRow(
            key: const ValueKey<String>('srs-review-layout-gestures'),
            title: t.srs_review_gestures_title,
            subtitle: t.srs_review_gestures_hint,
            onTap: () => openSrsReviewGesturesPage(context),
          ),
          AdaptiveSettingsSegmentedRow<SrsReviewImageSize>(
            key: const ValueKey<String>('srs-review-layout-image-size'),
            title: t.srs_review_layout_image_size,
            subtitle: t.srs_review_layout_image_size_hint,
            selected: imageSize,
            segments: <ButtonSegment<SrsReviewImageSize>>[
              ButtonSegment<SrsReviewImageSize>(
                value: SrsReviewImageSize.original,
                label: Text(t.srs_review_layout_image_original),
              ),
              ButtonSegment<SrsReviewImageSize>(
                value: SrsReviewImageSize.fitWidth,
                label: Text(t.srs_review_layout_image_fit_width),
              ),
              ButtonSegment<SrsReviewImageSize>(
                value: SrsReviewImageSize.large,
                label: Text(t.srs_review_layout_image_large),
              ),
            ],
            onChanged: (SrsReviewImageSize v) => app.setSrsReviewImageSize(v),
          ),
          if (showDesignSkin) _designSkinRow(ref, app),
        ],
      ),
    );
  }

  /// 「卡面跟随设计系统」：写进卡面外观偏好，当前卡面经外观监听原地换主题、立即生效
  /// （与卡面外观页里同一项是同一个偏好）。
  Widget _designSkinRow(WidgetRef ref, AppModel app) {
    final SrsCardAppearance a = ref.watch(srsCardAppearanceProvider);
    return AdaptiveSettingsSwitchRow(
      key: const ValueKey<String>('srs-review-layout-design-skin'),
      title: t.srs_card_appearance_design_skin,
      subtitle: t.srs_card_appearance_design_skin_hint,
      value: a.designSkin,
      onChanged: (bool v) =>
          app.setSrsCardAppearance(a.copyWith(designSkin: v)),
    );
  }
}
