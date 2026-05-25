import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/sync_manager.dart';
import 'package:hibiki/src/sync/ttu_models.dart';

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
