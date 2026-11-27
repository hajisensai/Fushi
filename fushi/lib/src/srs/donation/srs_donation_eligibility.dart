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
///
/// 「捐没捐过、捐了多少、什么时候」只认服务端（[SrsDonationRecord]，来自 GET / PUT 的同一形状响应），
/// 本机偏好不存镜像：捐赠身份按 profile 算、跨设备共享，镜像在别的设备上必然缺失（电脑上捐了、
/// 手机上照样弹「了解并捐赠」）。偏好只留本机的横幅选择与预览选项。
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

/// String（JSON 字符串数组，笔记 id）：用户在预览里排除的单词。
const String kSrsDonationExcludedPrefKey = 'srs_donation_excluded';

/// bool（默认 true）：「包含我学的单词」（词头 + 读音）。
const String kSrsDonationIncludeWordsPrefKey = 'srs_donation_include_words';

/// 服务端记着的一份捐赠（GET / PUT 成功响应）：包里的复习条数、卡片数与上传时刻。
typedef SrsDonationRecord = ({int reviews, int cards, DateTime updatedAt});

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
    this.excludedNoteIds = const <String>{},
    this.includeWords = true,
  });

  final bool never;
  final DateTime? snoozeUntil;
  final Set<String> excludedNoteIds;
  final bool includeWords;
}

/// 已捐过时再次提示所需的新增复习数：max(1000, 上次的 50%)。
int srsDonationUpdateThreshold(int lastReviews) =>
    math.max(kSrsDonationUpdateMinNewReviews, (lastReviews / 2).ceil());

/// 横幅的本机前置门：平台可用、没选「不再提示」、不在「以后再说」期内，且复习量过了首次门槛
/// （1000 次 / 14 天；捐过的人当时必然过过，所以两种横幅共用）。门不开就不必去问服务端。
bool srsDonationPromptGateOpen({
  required bool available,
  required int totalReviews,
  required int? daysSinceFirstReview,
  required SrsDonationPrefsState prefs,
  required DateTime now,
}) {
  if (!available || prefs.never) return false;
  final DateTime? snooze = prefs.snoozeUntil;
  if (snooze != null && now.isBefore(snooze)) return false;
  return totalReviews >= kSrsDonationMinReviews &&
      daysSinceFirstReview != null &&
      daysSinceFirstReview >= kSrsDonationMinDays;
}

/// 首页该不该出捐赠横幅、出哪一种；null = 不出。
///
/// [totalReviews] 是当前 profile 全部历史的评分复习次数，[daysSinceFirstReview] 是最早一次
/// 复习距今的天数（没有复习时为 null）。[donation] 是服务端记着的捐赠（null = 没捐过 / 已撤回）；
/// 服务端状态还不知道（没取到 / 失败）时调用方不该调本函数，直接不出横幅。
SrsDonationPromptKind? srsDonationPromptOf({
  required bool available,
  required int totalReviews,
  required int? daysSinceFirstReview,
  required SrsDonationPrefsState prefs,
  required SrsDonationRecord? donation,
  required DateTime now,
}) {
  final bool gate = srsDonationPromptGateOpen(
    available: available,
    totalReviews: totalReviews,
    daysSinceFirstReview: daysSinceFirstReview,
    prefs: prefs,
    now: now,
  );
  if (!gate) return null;
  if (donation == null) return SrsDonationPromptKind.donate;
  final int fresh = totalReviews - donation.reviews;
  final bool due =
      fresh >= srsDonationUpdateThreshold(donation.reviews) &&
      now.difference(donation.updatedAt) >= kSrsDonationUpdateInterval;
  return due ? SrsDonationPromptKind.update : null;
}

/// 捐赠偏好的读写（[PrefStore] 之上的薄层）。
class SrsDonationPrefs {
  const SrsDonationPrefs(this._prefs);

  final PrefStore _prefs;

  static DateTime? _time(Object? raw) =>
      raw is int && raw > 0 ? DateTime.fromMillisecondsSinceEpoch(raw) : null;

  SrsDonationPrefsState read() {
    return SrsDonationPrefsState(
      never:
          _prefs.getPref(kSrsDonationNeverPrefKey, defaultValue: false) == true,
      snoozeUntil: _time(
        _prefs.getPref(kSrsDonationSnoozeUntilPrefKey, defaultValue: 0),
      ),
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

  /// 上传成功：清掉「以后再说」（捐赠记录本身在服务端）。
  Future<void> clearSnooze() =>
      _prefs.setPref(kSrsDonationSnoozeUntilPrefKey, 0);

  /// 撤回成功：清掉排除集合（「不再提示」保留，那是用户对横幅的选择）。
  Future<void> clearExcluded() =>
      _prefs.setPref(kSrsDonationExcludedPrefKey, '');
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
