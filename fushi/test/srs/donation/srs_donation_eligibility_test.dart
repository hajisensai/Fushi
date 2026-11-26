import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/srs/donation/srs_donation_eligibility.dart';
import 'package:fushi/src/srs/donation/srs_donation_providers.dart';
import 'package:fushi/src/srs/srs_home_stats.dart';
import 'package:fushi_engine/foundation/pref_store.dart';

class _MapPrefs implements PrefStore {
  final Map<String, Object?> values = <String, Object?>{};

  @override
  dynamic getPref(String key, {dynamic defaultValue}) =>
      values.containsKey(key) ? values[key] : defaultValue;

  @override
  Future<void> setPref(String key, dynamic value) async => values[key] = value;
}

void main() {
  final DateTime now = DateTime(2026, 11, 26, 12);

  SrsDonationPromptKind? prompt({
    bool available = true,
    int total = 1000,
    int? days = 14,
    SrsDonationPrefsState prefs = const SrsDonationPrefsState(),
  }) => srsDonationPromptOf(
    available: available,
    totalReviews: total,
    daysSinceFirstReview: days,
    prefs: prefs,
    now: now,
  );

  group('首次提示门槛：1000 次 / 14 天', () {
    test('正好到门槛就提示', () {
      expect(prompt(), SrsDonationPromptKind.donate);
    });
    test('复习数差一次不提示', () {
      expect(prompt(total: 999), isNull);
    });
    test('跨度差一天不提示', () {
      expect(prompt(days: 13), isNull);
    });
    test('没有复习（最早日未知）不提示', () {
      expect(prompt(days: null), isNull);
    });
    test('平台不可用（iOS）不提示', () {
      expect(prompt(available: false, total: 50000, days: 400), isNull);
    });
  });

  group('以后再说 / 不再提示', () {
    test('以后再说 30 天内不提示，到期后恢复', () async {
      final _MapPrefs store = _MapPrefs();
      final SrsDonationPrefs prefs = SrsDonationPrefs(store);
      await prefs.snooze(now);
      final SrsDonationPrefsState s = prefs.read();
      expect(s.snoozeUntil, now.add(const Duration(days: 30)));
      expect(prompt(prefs: s), isNull);
      expect(
        srsDonationPromptOf(
          available: true,
          totalReviews: 1000,
          daysSinceFirstReview: 14,
          prefs: s,
          now: now.add(const Duration(days: 29, hours: 23)),
        ),
        isNull,
      );
      expect(
        srsDonationPromptOf(
          available: true,
          totalReviews: 1000,
          daysSinceFirstReview: 14,
          prefs: s,
          now: now.add(const Duration(days: 30)),
        ),
        SrsDonationPromptKind.donate,
      );
    });

    test('不再提示：门槛再高也不出，更新提示也不出', () async {
      final _MapPrefs store = _MapPrefs();
      final SrsDonationPrefs prefs = SrsDonationPrefs(store);
      await prefs.never();
      expect(prompt(prefs: prefs.read(), total: 100000, days: 999), isNull);
      await prefs.recordDonation(
        at: now.subtract(const Duration(days: 400)),
        reviews: 1000,
      );
      expect(prompt(prefs: prefs.read(), total: 100000, days: 999), isNull);
    });
  });

  group('已捐过：新增 ≥ max(1000, 50%) 且距上次 ≥ 30 天才提示更新', () {
    SrsDonationPrefsState donated({required int reviews, required int ago}) =>
        SrsDonationPrefsState(
          lastAt: now.subtract(Duration(days: ago)),
          lastReviews: reviews,
        );

    test('阈值取 max(1000, 上次的 50%)', () {
      expect(srsDonationUpdateThreshold(0), 1000);
      expect(srsDonationUpdateThreshold(1500), 1000);
      expect(srsDonationUpdateThreshold(2000), 1000);
      expect(srsDonationUpdateThreshold(2002), 1001);
      expect(srsDonationUpdateThreshold(10000), 5000);
      expect(srsDonationUpdateThreshold(10001), 5001);
    });

    test('小库：新增 1000 即可', () {
      final SrsDonationPrefsState s = donated(reviews: 1200, ago: 30);
      expect(prompt(prefs: s, total: 2199), isNull);
      expect(prompt(prefs: s, total: 2200), SrsDonationPromptKind.update);
    });

    test('大库：新增须达上次的 50%', () {
      final SrsDonationPrefsState s = donated(reviews: 10000, ago: 60);
      expect(prompt(prefs: s, total: 14999), isNull);
      expect(prompt(prefs: s, total: 15000), SrsDonationPromptKind.update);
    });

    test('不满 30 天不提示', () {
      final SrsDonationPrefsState s = donated(reviews: 1000, ago: 29);
      expect(prompt(prefs: s, total: 50000), isNull);
    });

    test('捐过之后不再按首次门槛提示', () {
      final SrsDonationPrefsState s = donated(reviews: 5000, ago: 1);
      expect(prompt(prefs: s, total: 5000, days: 400), isNull);
    });
  });

  group('偏好读写', () {
    test('记捐赠清掉以后再说；撤回清掉捐赠记录与排除集合，保留不再提示', () async {
      final _MapPrefs store = _MapPrefs();
      final SrsDonationPrefs prefs = SrsDonationPrefs(store);
      await prefs.snooze(now);
      await prefs.setExcluded(<String>{'n2', 'n1'});
      await prefs.setIncludeWords(false);
      await prefs.recordDonation(at: now, reviews: 1234);
      SrsDonationPrefsState s = prefs.read();
      expect(s.snoozeUntil, isNull);
      expect(s.lastAt, now);
      expect(s.lastReviews, 1234);
      expect(s.donated, isTrue);
      expect(s.excludedNoteIds, <String>{'n1', 'n2'});
      expect(s.includeWords, isFalse);
      await prefs.never();
      await prefs.clearDonation();
      s = prefs.read();
      expect(s.donated, isFalse);
      expect(s.lastReviews, 0);
      expect(s.excludedNoteIds, isEmpty);
      expect(s.never, isTrue);
    });

    test('默认值与坏值', () {
      final _MapPrefs store = _MapPrefs()
        ..values[kSrsDonationExcludedPrefKey] = 'not json';
      final SrsDonationPrefsState s = SrsDonationPrefs(store).read();
      expect(s.never, isFalse);
      expect(s.includeWords, isTrue);
      expect(s.donated, isFalse);
      expect(s.excludedNoteIds, isEmpty);
      expect(srsDonationDecodeExcluded('{"a":1}'), isEmpty);
      expect(srsDonationDecodeExcluded('["a",1,"b"]'), <String>{'a', 'b'});
    });
  });

  test('首页统计 → 复习总数与最早复习距今天数', () {
    final SrsHomeStats stats = SrsHomeStats(
      doneToday: 0,
      averageMsPerCard: 0,
      streak: 0,
      today: 100,
      countsByDay: const <int, int>{80: 0, 85: 600, 99: 400},
    );
    expect(stats.totalReviews, 1000);
    expect(srsDonationDaysSinceFirst(stats), 15);
    expect(
      srsDonationDaysSinceFirst(
        SrsHomeStats(doneToday: 0, averageMsPerCard: 0, streak: 0, today: 3),
      ),
      isNull,
    );
  });
}
