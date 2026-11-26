/// 复习首页顶部的捐赠横幅（[srsDonationPromptProvider] 非 null 时由首页插进横幅列表）。
///
/// 三个按钮：「了解并捐赠」/「更新捐赠」进捐赠页，「以后再说」30 天后再出现，「不再提示」永不再出现。
/// [FushiCard] 与 Fushi 按钮在 M3E / Apple 两套设计系统下各自取外观。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/srs/donation/srs_donation_eligibility.dart';
import 'package:fushi/src/srs/donation/srs_donation_page.dart';
import 'package:fushi/src/srs/donation/srs_donation_providers.dart';
import 'package:fushi/src/srs/srs_home_stats.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_m3e_list_card.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

class SrsDonationBanner extends ConsumerWidget {
  const SrsDonationBanner({super.key, required this.kind});

  final SrsDonationPromptKind kind;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final SrsHomeStats? stats = ref.watch(srsHomeStatsProvider).valueOrNull;
    final int total = stats?.totalReviews ?? 0;
    final String body = kind == SrsDonationPromptKind.donate
        ? t.srs_donation_banner_body(n: total)
        : t.srs_donation_banner_update_body(
            n: total - ref.watch(srsDonationPrefsProvider).lastReviews,
          );
    return FushiCard(
      key: const ValueKey<String>('srs-donation-banner'),
      tone: FushiCardTone.primary,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: tokens.spacing.gap,
        children: <Widget>[
          Row(
            spacing: tokens.spacing.gap * 1.5,
            children: <Widget>[
              const FushiIcon(FushiIcons.favorite),
              Expanded(
                child: Text(
                  t.srs_donation_banner_title,
                  style: context.fushiType.titleMediumEmphasized,
                ),
              ),
            ],
          ),
          Text(body),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: tokens.spacing.gap,
            runSpacing: tokens.spacing.gap,
            children: <Widget>[
              FushiPressScale(
                child: FushiTextButton(
                  key: const ValueKey<String>('srs-donation-banner-never'),
                  onPressed: () => srsRunLogged(
                    'SrsDonationBanner.never',
                    () => updateSrsDonationPrefs(
                      ref,
                      (SrsDonationPrefs p) => p.never(),
                    ),
                  ),
                  child: Text(t.srs_donation_never),
                ),
              ),
              FushiPressScale(
                child: FushiTextButton(
                  key: const ValueKey<String>('srs-donation-banner-later'),
                  onPressed: () => srsRunLogged(
                    'SrsDonationBanner.later',
                    () => updateSrsDonationPrefs(
                      ref,
                      (SrsDonationPrefs p) =>
                          p.snooze(ref.read(srsDonationClockProvider)()),
                    ),
                  ),
                  child: Text(t.srs_donation_later),
                ),
              ),
              FushiPressScale(
                child: FushiFilledButton.icon(
                  key: const ValueKey<String>('srs-donation-banner-open'),
                  onPressed: () => srsRunLogged(
                    'SrsDonationBanner.open',
                    () => openSrsDonationPage(context),
                  ),
                  icon: const FushiIcon(FushiIcons.favorite),
                  label: Text(
                    kind == SrsDonationPromptKind.donate
                        ? t.srs_donation_learn_more
                        : t.srs_donation_update,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
