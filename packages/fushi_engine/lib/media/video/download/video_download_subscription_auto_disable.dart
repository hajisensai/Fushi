/// 追更订阅「太久没更新就自动关闭」（2026-10-20 用户：「超过半年一年没更新的
/// 弄掉」）。偏好是设备本地的 `preferences` 行，app 与无头服务端读同一份解码。
library;

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/foundation/pref_store.dart';

/// 追更订阅多久没有新命中就自动关闭，单位天；0 = 从不。
const String kVideoDownloadSubscriptionAutoDisablePref =
    'video_download_subscription_auto_disable_days';

/// 默认半年。
const int kVideoDownloadSubscriptionAutoDisableDefaultDays = 182;

/// 设置里给出的档位（天）：从不 / 半年 / 一年。
const List<int> kVideoDownloadSubscriptionAutoDisableChoices = <int>[
  0,
  182,
  365,
];

/// 当前档位（天）；读不出合法整数时退回默认。
int readVideoDownloadSubscriptionAutoDisableDays(PrefStore prefs) {
  final Object? raw = prefs.getPref(
    kVideoDownloadSubscriptionAutoDisablePref,
    defaultValue: kVideoDownloadSubscriptionAutoDisableDefaultDays,
  );
  final int? days = raw is int ? raw : int.tryParse('$raw');
  if (days == null || days < 0) {
    return kVideoDownloadSubscriptionAutoDisableDefaultDays;
  }
  return days;
}

Future<void> writeVideoDownloadSubscriptionAutoDisableDays(
  PrefStore prefs,
  int days,
) => prefs.setPref(kVideoDownloadSubscriptionAutoDisablePref, days);

/// 「多久没更新」的起点：最近一次发现新集（[latestDiscoveredAt]，items 的
/// `discoveredAt` 最大值）；一集都没发现过就用添加时刻。刻意不用
/// `lastMatchedAt`：它只要搜到符合规则的资源（含早已下过的旧集）就刷新，
/// 已完结的番会因此永远「刚命中过」、永远关不掉。
int videoDownloadSubscriptionLastActivityAt(
  VideoDownloadSubscriptionRow row, {
  int? latestDiscoveredAt,
}) => latestDiscoveredAt == null || latestDiscoveredAt < row.createdAt
    ? row.createdAt
    : latestDiscoveredAt;

/// 追更订阅在 [nowAt] 时是否已超过 [days] 天没有新集（[days] ≤ 0 = 从不）。
/// 单次订阅有自己的「下到即关闭」，不走这条。
bool isVideoDownloadSubscriptionStale(
  VideoDownloadSubscriptionRow row, {
  required int nowAt,
  required int days,
  int? latestDiscoveredAt,
}) {
  if (days <= 0 || row.mode == 'oneShot') return false;
  return nowAt -
          videoDownloadSubscriptionLastActivityAt(
            row,
            latestDiscoveredAt: latestDiscoveredAt,
          ) >
      Duration(days: days).inMilliseconds;
}
