import 'dart:io';

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

  group('didCompleteDictionaryAutoUpdateBatch', () {
    test('所有可更新词典都完成检查或更新 → true', () {
      expect(
        didCompleteDictionaryAutoUpdateBatch(
          totalCount: 3,
          completedCount: 3,
        ),
        isTrue,
      );
    });

    test('任一本检查或重导失败 → false，保留下次启动重试', () {
      expect(
        didCompleteDictionaryAutoUpdateBatch(
          totalCount: 3,
          completedCount: 2,
        ),
        isFalse,
      );
    });

    test('没有可更新词典不构成一轮检查', () {
      expect(
        didCompleteDictionaryAutoUpdateBatch(
          totalCount: 0,
          completedCount: 0,
        ),
        isFalse,
      );
    });
  });

  test('BUG-1226 自动更新按完整检查结果写时间，而非只认实际重导数量', () {
    final String source =
        File('lib/src/models/app_model.dart').readAsStringSync();
    expect(
      source,
      contains('DictionaryUpdateService.fetchRemoteIndexResult'),
    );
    expect(
      source,
      contains('didCompleteDictionaryAutoUpdateBatch('),
    );
    expect(
      source,
      matches(
        RegExp(
          r'if \(!DictionaryUpdateService\.needsUpdate\('
          r'[\s\S]*?\)\) \{\s*completedCount\+\+;\s*continue;',
        ),
      ),
      reason: '已是最新版也必须计为一次成功完成的检查',
    );
    expect(source, isNot(contains('if (successCount > 0)')));
  });
}
