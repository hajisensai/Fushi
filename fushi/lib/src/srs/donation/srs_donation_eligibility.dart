/// 复习历史捐赠的资格判据与偏好（设计 `docs/specs/2026-11-26-srs-review-donation.md`「客户端」）。
///
/// - 首次提示：当前 profile 评分复习 ≥ [kSrsDonationMinReviews] 次，且最早一次复习距今
///   ≥ [kSrsDonationMinDays] 天；
/// - 「以后再说」：[kSrsDonationSnooze]（30 天）内不再出现；「不再提示」：横幅永不出现
///   （复习页「⋯」里的捐赠入口照常可用）；
/// - 已捐过：复习数比上次捐赠多 ≥ max(1000, 上次的 50%) 且距上次 ≥ 30 天时，横幅改为「更新捐赠」。
///
/// 判据是纯函数 [srsDonationPromptOf]，偏好读写收在 [SrsDonationPrefs]；两者都不碰平台
/// （平台门是 `store_compliance.dart` 的 `srsDonationAvailable`，由调用方传进 `available`）。
library;

import 'dart:convert';
import 'dart:math' as math;

import 'package:fushi_engine/foundation/pref_store.dart';

/// 首次提示的最少评分复习次数（上游作者认可 1000 / 14 天，2026-11-26）。
const int kSrsDonationMinReviews = 1000;

/// 首次提示要求最早一次复习距今的最少天数。
const int kSrsDonationMinDays = 14;

/// 「以后再说」之后多久再出现。
const Duration kSrsDonationSnooze = Duration(days: 30);

/// 已捐过的用户再次提示「更新捐赠」的最短间隔。
const Duration kSrsDonationUpdateInterval = Duration(days: 30);

/// 已捐过的用户再次提示所需的最少新增复习数（与「上次的 50%」取大）。
const int kSrsDonationUpdateMinNewReviews = 1000;

/// 偏好键（登记在 `preference_keys.dart`；跟随 Profile，与捐赠身份同一粒度）。
///
/// bool：「不再提示」。
const String kSrsDonationNeverPrefKey = 'srs_donation_never';

/// int（毫秒时间戳，0 = 没有）：「以后再说」到期时刻。
const String kSrsDonationSnoozeUntilPrefKey = 'srs_donation_snooze_until';

/// int（毫秒时间戳，0 = 没捐过 / 已撤回）：上次成功上传的时刻。
const String kSrsDonationLastAtPrefKey = 'srs_donation_last_at';

/// int：上次成功上传时包里的复习条数。
const String kSrsDonationLastReviewsPrefKey = 'srs_donation_last_reviews';

/// String（JSON 字符串数组，笔记 id）：用户在预览里排除的单词。
const String kSrsDonationExcludedPrefKey = 'srs_donation_excluded';

/// bool（默认 true）：「包含我学的单词」（词头 + 读音）。
const String kSrsDonationIncludeWordsPrefKey = 'srs_donation_include_words';

/// 横幅形态。
enum SrsDonationPromptKind {
  /// 还没捐过：「了解并捐赠」。
  donate,

  /// 捐过、又攒了足够多的新复习：「更新捐赠」。
  update,
}

/// 捐赠相关偏好的快照。
class SrsDonationPrefsState {
  const SrsDonationPrefsState({
    this.never = false,
    this.snoozeUntil,
    this.lastAt,
    this.lastReviews = 0,
    this.excludedNoteIds = const <String>{},
    this.includeWords = true,
  });

  final bool never;
  final DateTime? snoozeUntil;

  /// 上次成功上传的时刻；null = 没捐过（或已撤回）。
  final DateTime? lastAt;
  final int lastReviews;
  final Set<String> excludedNoteIds;
  final bool includeWords;

  bool get donated => lastAt != null;
}

/// 已捐过时再次提示所需的新增复习数：max(1000, 上次的 50%)。
int srsDonationUpdateThreshold(int lastReviews) =>
    math.max(kSrsDonationUpdateMinNewReviews, (lastReviews / 2).ceil());

/// 首页该不该出捐赠横幅、出哪一种；null = 不出。
///
/// [totalReviews] 是当前 profile 全部历史的评分复习次数，[daysSinceFirstReview] 是最早一次
/// 复习距今的天数（没有复习时为 null）。
SrsDonationPromptKind? srsDonationPromptOf({
  required bool available,
  required int totalReviews,
  required int? daysSinceFirstReview,
  required SrsDonationPrefsState prefs,
  required DateTime now,
}) {
  if (!available || prefs.never) return null;
  final DateTime? snooze = prefs.snoozeUntil;
  if (snooze != null && now.isBefore(snooze)) return null;
  final DateTime? lastAt = prefs.lastAt;
  if (lastAt == null) {
    final bool enough =
        totalReviews >= kSrsDonationMinReviews &&
        daysSinceFirstReview != null &&
        daysSinceFirstReview >= kSrsDonationMinDays;
    return enough ? SrsDonationPromptKind.donate : null;
  }
  final int fresh = totalReviews - prefs.lastReviews;
  final bool due =
      fresh >= srsDonationUpdateThreshold(prefs.lastReviews) &&
      now.difference(lastAt) >= kSrsDonationUpdateInterval;
  return due ? SrsDonationPromptKind.update : null;
}

/// 捐赠偏好的读写（[PrefStore] 之上的薄层）。
class SrsDonationPrefs {
  const SrsDonationPrefs(this._prefs);

  final PrefStore _prefs;

  static DateTime? _time(Object? raw) =>
      raw is int && raw > 0 ? DateTime.fromMillisecondsSinceEpoch(raw) : null;

  SrsDonationPrefsState read() {
    final Object? lastReviews = _prefs.getPref(
      kSrsDonationLastReviewsPrefKey,
      defaultValue: 0,
    );
    return SrsDonationPrefsState(
      never:
          _prefs.getPref(kSrsDonationNeverPrefKey, defaultValue: false) == true,
      snoozeUntil: _time(
        _prefs.getPref(kSrsDonationSnoozeUntilPrefKey, defaultValue: 0),
      ),
      lastAt: _time(_prefs.getPref(kSrsDonationLastAtPrefKey, defaultValue: 0)),
      lastReviews: lastReviews is int ? lastReviews : 0,
      excludedNoteIds: srsDonationDecodeExcluded(
        _prefs.getPref(kSrsDonationExcludedPrefKey, defaultValue: ''),
      ),
      includeWords:
          _prefs.getPref(kSrsDonationIncludeWordsPrefKey, defaultValue: true) !=
          false,
    );
  }

  /// 「以后再说」。
  Future<void> snooze(DateTime now) => _prefs.setPref(
    kSrsDonationSnoozeUntilPrefKey,
    now.add(kSrsDonationSnooze).millisecondsSinceEpoch,
  );

  /// 「不再提示」。
  Future<void> never() => _prefs.setPref(kSrsDonationNeverPrefKey, true);

  Future<void> setIncludeWords(bool value) =>
      _prefs.setPref(kSrsDonationIncludeWordsPrefKey, value);

  Future<void> setExcluded(Set<String> noteIds) => _prefs.setPref(
    kSrsDonationExcludedPrefKey,
    jsonEncode((noteIds.toList()..sort())),
  );

  /// 上传成功：记下时刻与条数（「更新捐赠」的基线），并清掉「以后再说」。
  Future<void> recordDonation({
    required DateTime at,
    required int reviews,
  }) async {
    await _prefs.setPref(kSrsDonationLastAtPrefKey, at.millisecondsSinceEpoch);
    await _prefs.setPref(kSrsDonationLastReviewsPrefKey, reviews);
    await _prefs.setPref(kSrsDonationSnoozeUntilPrefKey, 0);
  }

  /// 撤回成功：清掉捐赠记录与排除集合（「不再提示」保留，那是用户对横幅的选择）。
  Future<void> clearDonation() async {
    await _prefs.setPref(kSrsDonationLastAtPrefKey, 0);
    await _prefs.setPref(kSrsDonationLastReviewsPrefKey, 0);
    await _prefs.setPref(kSrsDonationExcludedPrefKey, '');
  }
}

/// 排除集合的解码：空串 / 坏值一律当空集合。
Set<String> srsDonationDecodeExcluded(Object? raw) {
  if (raw is! String || raw.isEmpty) return const <String>{};
  try {
    final Object? decoded = jsonDecode(raw);
    if (decoded is! List) return const <String>{};
    return <String>{
      for (final Object? e in decoded)
        if (e is String) e,
    };
  } on FormatException {
    return const <String>{};
  }
}
