import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';

/// TODO-861③（移植 Hoshi `94d0c41`）：check-due 纯函数 + interval 枚举的表驱动守卫。
void main() {
  group('DictionaryUpdateInterval', () {
    test('fromName 解析 daily/weekly/monthly', () {
      expect(DictionaryUpdateInterval.fromName('daily'),
          DictionaryUpdateInterval.daily);
      expect(DictionaryUpdateInterval.fromName('weekly'),
          DictionaryUpdateInterval.weekly);
      expect(DictionaryUpdateInterval.fromName('monthly'),
          DictionaryUpdateInterval.monthly);
    });

    test('未知/空值回退 weekly', () {
      expect(DictionaryUpdateInterval.fromName(null),
          DictionaryUpdateInterval.weekly);
      expect(DictionaryUpdateInterval.fromName('garbage'),
          DictionaryUpdateInterval.weekly);
    });

    test('每档 Duration 正确', () {
      expect(DictionaryUpdateInterval.daily.duration, const Duration(days: 1));
      expect(DictionaryUpdateInterval.weekly.duration, const Duration(days: 7));
      expect(
          DictionaryUpdateInterval.monthly.duration, const Duration(days: 30));
    });
  });

  group('shouldAutoUpdateDictionaries', () {
    final DateTime now = DateTime(2026, 6, 28, 12);

    bool run({
      DateTime? lastUpdate,
      DictionaryUpdateInterval interval = DictionaryUpdateInterval.weekly,
      bool hasUpdatable = true,
      bool isBusy = false,
    }) =>
        shouldAutoUpdateDictionaries(
          now: now,
          lastUpdate: lastUpdate,
          interval: interval,
          hasUpdatable: hasUpdatable,
          isBusy: isBusy,
        );

    test('从未更新（lastUpdate=null）且有可更新 → true', () {
      expect(run(lastUpdate: null), isTrue);
    });

    test('正忙 → false', () {
      expect(run(lastUpdate: null, isBusy: true), isFalse);
    });

    test('无可更新词典 → false', () {
      expect(run(lastUpdate: null, hasUpdatable: false), isFalse);
    });

    test('未到期（weekly，3 天前）→ false', () {
      expect(run(lastUpdate: now.subtract(const Duration(days: 3))), isFalse);
    });

    test('已到期（weekly，8 天前）→ true', () {
      expect(run(lastUpdate: now.subtract(const Duration(days: 8))), isTrue);
    });

    test('恰好到期（weekly，整 7 天前）→ true', () {
      expect(run(lastUpdate: now.subtract(const Duration(days: 7))), isTrue);
    });

    test('daily 间隔，2 天前 → true', () {
      expect(
        run(
          lastUpdate: now.subtract(const Duration(days: 2)),
          interval: DictionaryUpdateInterval.daily,
        ),
        isTrue,
      );
    });

    test('monthly 间隔，10 天前 → false', () {
      expect(
        run(
          lastUpdate: now.subtract(const Duration(days: 10)),
          interval: DictionaryUpdateInterval.monthly,
        ),
        isFalse,
      );
    });
  });
}
