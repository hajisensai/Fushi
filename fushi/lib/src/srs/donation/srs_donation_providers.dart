/// 复习历史捐赠的 provider：首页横幅判据、偏好刷新信号、HTTP 客户端。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_engine/srs/apkg/srs_donation_export.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';

import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/store_compliance.dart';
import 'package:fushi/src/profile/profile_view_model.dart';
import 'package:fushi/src/srs/donation/srs_donation_client.dart';
import 'package:fushi/src/srs/donation/srs_donation_eligibility.dart';
import 'package:fushi/src/srs/srs_home_stats.dart';

/// 捐赠偏好写完后递增：横幅判据重算。
final StateProvider<int> srsDonationPrefsRevisionProvider = StateProvider<int>(
  (Ref ref) => 0,
);

/// 捐赠接口客户端（测试里覆盖成 MockClient 版）。
final Provider<SrsDonationClient> srsDonationClientProvider =
    Provider<SrsDonationClient>((Ref ref) => SrsDonationClient());

/// 一份算好的捐赠预览，记着它是哪个 profile、哪一版库内容（[SrsDbStore.contentFingerprint]）算出来的。
typedef SrsDonationPreviewSnapshot = ({
  String profileUid,
  String fingerprint,
  SrsDonationPreview preview,
});

/// 上一次算好的捐赠预览：库内容没变时再进捐赠页直接用，不再后台重读全库（大库上是秒级）。
final StateProvider<SrsDonationPreviewSnapshot?>
srsDonationPreviewCacheProvider = StateProvider<SrsDonationPreviewSnapshot?>(
  (Ref ref) => null,
);

/// 当前时刻（测试覆盖）。
final Provider<DateTime Function()> srsDonationClockProvider =
    Provider<DateTime Function()>((Ref ref) => DateTime.now);

/// 当前 profile 的捐赠偏好快照。
final Provider<SrsDonationPrefsState> srsDonationPrefsProvider =
    Provider<SrsDonationPrefsState>((Ref ref) {
      ref.watch(srsDonationPrefsRevisionProvider);
      // 切 profile 时偏好整份换掉：跟随激活配置重读。
      ref.watch(
        profileViewModelProvider.select(
          (ProfileUiState s) => s.activeProfileId,
        ),
      );
      return SrsDonationPrefs(ref.read(appProvider).prefsRepo).read();
    });

/// 复习首页该不该出捐赠横幅、出哪一种（null = 不出）。
///
/// 复习数与最早复习日取首页统计（[srsHomeStatsProvider]，全部历史逐日复习数），首页本来就在
/// 装这份数，不为横幅另读一遍库；统计还没到时不出横幅。
final Provider<SrsDonationPromptKind?> srsDonationPromptProvider =
    Provider<SrsDonationPromptKind?>((Ref ref) {
      if (!srsDonationAvailable) return null;
      final SrsHomeStats? stats = ref.watch(srsHomeStatsProvider).valueOrNull;
      if (stats == null) return null;
      return srsDonationPromptOf(
        available: true,
        totalReviews: stats.totalReviews,
        daysSinceFirstReview: srsDonationDaysSinceFirst(stats),
        prefs: ref.watch(srsDonationPrefsProvider),
        now: ref.read(srsDonationClockProvider)(),
      );
    });

/// 最早一次复习距今的天数（按统计日序号算）；没有复习时为 null。
int? srsDonationDaysSinceFirst(SrsHomeStats stats) {
  int? first;
  for (final MapEntry<int, int> e in stats.countsByDay.entries) {
    if (e.value <= 0) continue;
    if (first == null || e.key < first) first = e.key;
  }
  return first == null ? null : stats.today - first;
}

/// 写捐赠偏好并让判据重算。
Future<void> updateSrsDonationPrefs(
  WidgetRef ref,
  Future<void> Function(SrsDonationPrefs prefs) write,
) async {
  await write(SrsDonationPrefs(ref.read(appProvider).prefsRepo));
  ref.read(srsDonationPrefsRevisionProvider.notifier).state++;
}
