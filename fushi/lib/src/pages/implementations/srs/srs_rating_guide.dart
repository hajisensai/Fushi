/// 复习页「评分按钮怎么选」的首次说明（反馈 qQA11YJLQF：第一次背卡时说明四个按钮分别在什么情况下点）。
///
/// 第一次翻到答案面时挂在评分按钮上方：每颗按钮一行（与按钮同色的色块 + 评价词 + 什么时候选它），
/// 只留「重来 / 良好」时只解释这两颗。点「知道了」后落偏好 [kSrsRatingGuideDismissedPrefKey]，
/// 以后不再出现（换设备 / 重装照旧会再见一次：这是本机提示，不是同步设置）。
///
/// 偏好层没装好（启动早期 / 没接数据库的测试宿主）时不显示：记不住「已看过」就不能保证只出现一次，
/// 宁可不出也不每次都弹。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/srs/srs_review_page.dart'
    show SrsRatingTone, srsRatingColors;
import 'package:fushi/src/srs/srs_providers.dart' show srsRunLogged;
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// 偏好：评分说明是否已被关掉（缺省 = 没关，第一次复习时显示）。
const String kSrsRatingGuideDismissedPrefKey = 'srs_rating_guide_dismissed';

/// 评分说明此刻该不该显示。偏好没装好时恒为 false（见文件头）。
final StateProvider<bool> srsRatingGuideVisibleProvider = StateProvider<bool>((
  Ref ref,
) {
  final AppModel app = ref.read(appProvider);
  if (!app.isPreferencesReady) return false;
  return app.prefsRepo.getPref(
        kSrsRatingGuideDismissedPrefKey,
        defaultValue: false,
      ) !=
      true;
});

/// 关掉评分说明：立即收起并落偏好。
Future<void> dismissSrsRatingGuide(WidgetRef ref) async {
  ref.read(srsRatingGuideVisibleProvider.notifier).state = false;
  final AppModel app = ref.read(appProvider);
  if (!app.isPreferencesReady) return;
  await app.prefsRepo.setPref(kSrsRatingGuideDismissedPrefKey, true);
}

/// 评分说明横幅。[twoButtons] = 只留「重来 / 良好」（与评分行同一个设置）。
class SrsRatingGuide extends ConsumerWidget {
  const SrsRatingGuide({super.key, required this.twoButtons});

  final bool twoButtons;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool apple = isGlassDesign(context);
    final List<(SrsRatingTone, String, String)> rows =
        <(SrsRatingTone, String, String)>[
          (SrsRatingTone.again, t.srs_rating_again, t.srs_rating_guide_again),
          if (!twoButtons)
            (SrsRatingTone.hard, t.srs_rating_hard, t.srs_rating_guide_hard),
          (SrsRatingTone.good, t.srs_rating_good, t.srs_rating_guide_good),
          if (!twoButtons)
            (SrsRatingTone.easy, t.srs_rating_easy, t.srs_rating_guide_easy),
        ];
    final TextStyle body = context.fushiType.bodyMedium;
    return FushiInlineNotice(
      key: const ValueKey<String>('srs-rating-guide'),
      icon: FushiIcons.info,
      title: t.srs_rating_guide_title,
      message: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: tokens.spacing.gap / 2,
        children: <Widget>[
          for (int i = 0; i < rows.length; i++)
            FushiStaggeredEntrance(
              index: i,
              child: Row(
                key: ValueKey<String>('srs-rating-guide-${rows[i].$1.name}'),
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: tokens.spacing.gap,
                children: <Widget>[
                  _ToneChip(
                    label: rows[i].$2,
                    colors: srsRatingColors(rows[i].$1, cs, apple: apple),
                  ),
                  Expanded(child: Text(rows[i].$3, style: body)),
                ],
              ),
            ),
        ],
      ),
      actions: <Widget>[
        FushiTextButton(
          key: const ValueKey<String>('srs-rating-guide-dismiss'),
          onPressed: () => srsRunLogged(
            'SrsRatingGuide.dismiss',
            () => dismissSrsRatingGuide(ref),
          ),
          child: Text(t.srs_rating_guide_dismiss),
        ),
      ],
    );
  }
}

/// 与评分按钮同色的小色块，写着评价词（让说明与底下的按钮一眼对上）。
class _ToneChip extends StatelessWidget {
  const _ToneChip({required this.label, required this.colors});

  final String label;
  final ({Color background, Color foreground}) colors;

  @override
  Widget build(BuildContext context) => Container(
    constraints: const BoxConstraints(minWidth: 56),
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    decoration: BoxDecoration(
      color: colors.background,
      borderRadius: BorderRadius.circular(8),
    ),
    child: Text(
      label,
      textAlign: TextAlign.center,
      style: context.fushiType.labelLarge.copyWith(color: colors.foreground),
    ),
  );
}
