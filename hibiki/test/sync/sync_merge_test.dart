import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/ttu_models.dart';

/// Replicate the high-water merge logic from SyncManager for unit testing.
List<TtuStatistics> mergeStatistics(
  List<TtuStatistics> localStats,
  List<TtuStatistics> externalStats,
  StatisticsSyncMode mode,
) {
  if (mode == StatisticsSyncMode.replace) return externalStats;

  final grouped = <String, TtuStatistics>{};
  for (final stat in localStats) {
    grouped[stat.dateKey] = stat;
  }
  for (final stat in externalStats) {
    final existing = grouped[stat.dateKey];
    if (existing == null) {
      grouped[stat.dateKey] = stat;
    } else {
      grouped[stat.dateKey] = TtuStatistics(
        title: stat.title,
        dateKey: stat.dateKey,
        charactersRead: max(existing.charactersRead, stat.charactersRead),
        readingTimeSec: max(existing.readingTimeSec, stat.readingTimeSec),
        minReadingSpeed:
            existing.minReadingSpeed > 0 && stat.minReadingSpeed > 0
                ? min(existing.minReadingSpeed, stat.minReadingSpeed)
                : max(existing.minReadingSpeed, stat.minReadingSpeed),
        altMinReadingSpeed:
            existing.altMinReadingSpeed > 0 && stat.altMinReadingSpeed > 0
                ? min(existing.altMinReadingSpeed, stat.altMinReadingSpeed)
                : max(existing.altMinReadingSpeed, stat.altMinReadingSpeed),
        lastReadingSpeed: max(existing.lastReadingSpeed, stat.lastReadingSpeed),
        maxReadingSpeed: max(existing.maxReadingSpeed, stat.maxReadingSpeed),
        lastStatisticModified:
            max(existing.lastStatisticModified, stat.lastStatisticModified),
      );
    }
  }
  return grouped.values.toList();
}

TtuStatistics _stat({
  String dateKey = '2026-01-15',
  int charactersRead = 1000,
  double readingTimeSec = 3600,
  int minReadingSpeed = 300,
  int altMinReadingSpeed = 280,
  int lastReadingSpeed = 350,
  int maxReadingSpeed = 400,
  int lastStatisticModified = 1000,
}) =>
    TtuStatistics(
      title: 'Book',
      dateKey: dateKey,
      charactersRead: charactersRead,
      readingTimeSec: readingTimeSec,
      minReadingSpeed: minReadingSpeed,
      altMinReadingSpeed: altMinReadingSpeed,
      lastReadingSpeed: lastReadingSpeed,
      maxReadingSpeed: maxReadingSpeed,
      lastStatisticModified: lastStatisticModified,
    );

void main() {
  group('high-water merge', () {
    test('disjoint dates are unioned', () {
      final local = [_stat(dateKey: '2026-01-01')];
      final remote = [_stat(dateKey: '2026-01-02')];
      final merged = mergeStatistics(local, remote, StatisticsSyncMode.merge);
      expect(merged.length, 2);
    });

    test('same date takes max of charactersRead and readingTime', () {
      final local = [
        _stat(charactersRead: 1000, readingTimeSec: 3600),
      ];
      final remote = [
        _stat(charactersRead: 1500, readingTimeSec: 2000),
      ];
      final merged = mergeStatistics(local, remote, StatisticsSyncMode.merge);
      expect(merged.length, 1);
      expect(merged.first.charactersRead, 1500);
      expect(merged.first.readingTimeSec, 3600);
    });

    test('same date takes min of minReadingSpeed (both nonzero)', () {
      final local = [_stat(minReadingSpeed: 300)];
      final remote = [_stat(minReadingSpeed: 200)];
      final merged = mergeStatistics(local, remote, StatisticsSyncMode.merge);
      expect(merged.first.minReadingSpeed, 200);
    });

    test('minReadingSpeed: zero side ignored', () {
      final local = [_stat(minReadingSpeed: 0)];
      final remote = [_stat(minReadingSpeed: 200)];
      final merged = mergeStatistics(local, remote, StatisticsSyncMode.merge);
      expect(merged.first.minReadingSpeed, 200);
    });

    test('same date takes max of maxReadingSpeed', () {
      final local = [_stat(maxReadingSpeed: 400)];
      final remote = [_stat(maxReadingSpeed: 500)];
      final merged = mergeStatistics(local, remote, StatisticsSyncMode.merge);
      expect(merged.first.maxReadingSpeed, 500);
    });

    test('same date takes max of lastStatisticModified', () {
      final local = [_stat(lastStatisticModified: 1000)];
      final remote = [_stat(lastStatisticModified: 2000)];
      final merged = mergeStatistics(local, remote, StatisticsSyncMode.merge);
      expect(merged.first.lastStatisticModified, 2000);
    });

    test('replace mode returns external stats entirely', () {
      final local = [_stat(dateKey: '2026-01-01', charactersRead: 9999)];
      final remote = [_stat(dateKey: '2026-01-02', charactersRead: 100)];
      final merged = mergeStatistics(local, remote, StatisticsSyncMode.replace);
      expect(merged.length, 1);
      expect(merged.first.dateKey, '2026-01-02');
    });

    test('two-device scenario: both read same day, no data lost', () {
      final deviceA = [
        _stat(charactersRead: 2000, readingTimeSec: 1800, maxReadingSpeed: 400),
      ];
      final deviceB = [
        _stat(charactersRead: 3000, readingTimeSec: 2400, maxReadingSpeed: 500),
      ];
      final merged =
          mergeStatistics(deviceA, deviceB, StatisticsSyncMode.merge);
      expect(merged.first.charactersRead, 3000);
      expect(merged.first.readingTimeSec, 2400);
      expect(merged.first.maxReadingSpeed, 500);
    });
  });
}
