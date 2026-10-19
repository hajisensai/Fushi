/// 复习页 ⋯「复习布局」：底部重播键放哪端、评分按钮显不显示下次间隔。
/// 改了立即生效（按 profile 的偏好），面板开着就能看到复习页随之变化。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/srs/srs_review_layout.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// 打开「复习布局」面板。
Future<void> showSrsReviewLayoutSheet(BuildContext context) =>
    adaptiveModalSheet<void>(
      context: context,
      builder: (BuildContext context) => const SrsReviewLayoutSheet(),
    );

/// 「复习布局」面板正文。
class SrsReviewLayoutSheet extends ConsumerWidget {
  const SrsReviewLayoutSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppModel app = ref.read(appProvider);
    final SrsReviewReplayButton replay = ref.watch(
      srsReviewReplayButtonProvider,
    );
    final bool intervals = ref.watch(srsReviewShowIntervalsProvider);
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
          AdaptiveSettingsSwitchRow(
            key: const ValueKey<String>('srs-review-layout-intervals'),
            title: t.srs_review_layout_show_intervals,
            subtitle: t.srs_review_layout_show_intervals_hint,
            value: intervals,
            onChanged: (bool v) => app.setSrsReviewShowIntervals(v),
          ),
        ],
      ),
    );
  }
}
