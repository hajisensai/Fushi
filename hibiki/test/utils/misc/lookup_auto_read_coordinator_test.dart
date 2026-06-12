import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/misc/lookup_auto_read_coordinator.dart';

void main() {
  group('LookupAutoReadCoordinator', () {
    late DateTime now;

    LookupAutoReadCoordinator newCoordinator({
      Duration window = const Duration(milliseconds: 500),
    }) {
      return LookupAutoReadCoordinator(
        dedupeWindow: window,
        now: () => now,
      );
    }

    setUp(() {
      now = DateTime(2026, 6, 12, 12);
    });

    test('suppresses duplicate automatic playback inside the window', () async {
      final LookupAutoReadCoordinator coordinator = newCoordinator();
      int playCount = 0;

      final bool first = await coordinator.runAutomatic(
        expression: '日本語',
        reading: 'にほんご',
        play: () async {
          playCount++;
        },
      );
      final bool second = await coordinator.runAutomatic(
        expression: '日本語',
        reading: 'にほんご',
        play: () async {
          playCount++;
        },
      );

      expect(first, isTrue);
      expect(second, isFalse);
      expect(playCount, 1);
    });

    test('allows the same automatic playback after the window expires',
        () async {
      final LookupAutoReadCoordinator coordinator = newCoordinator();
      int playCount = 0;

      await coordinator.runAutomatic(
        expression: '日本語',
        reading: 'にほんご',
        play: () async {
          playCount++;
        },
      );
      now = now.add(const Duration(milliseconds: 501));
      final bool replayed = await coordinator.runAutomatic(
        expression: '日本語',
        reading: 'にほんご',
        play: () async {
          playCount++;
        },
      );

      expect(replayed, isTrue);
      expect(playCount, 2);
    });

    test('keeps reading and source in the automatic playback key', () async {
      final LookupAutoReadCoordinator coordinator = newCoordinator();
      final List<String> played = <String>[];

      await coordinator.runAutomatic(
        expression: '今日',
        reading: 'きょう',
        source: 'lookup',
        play: () async {
          played.add('きょう/lookup');
        },
      );
      await coordinator.runAutomatic(
        expression: '今日',
        reading: 'こんにち',
        source: 'lookup',
        play: () async {
          played.add('こんにち/lookup');
        },
      );
      await coordinator.runAutomatic(
        expression: '今日',
        reading: 'きょう',
        source: 'preview',
        play: () async {
          played.add('きょう/preview');
        },
      );

      expect(
        played,
        <String>['きょう/lookup', 'こんにち/lookup', 'きょう/preview'],
      );
    });

    test('propagates failures and does not keep failed playback deduped',
        () async {
      final LookupAutoReadCoordinator coordinator = newCoordinator();
      int attempts = 0;

      Future<void> failingPlay() async {
        attempts++;
        throw StateError('boom');
      }

      await expectLater(
        coordinator.runAutomatic(
          expression: '音',
          reading: 'おと',
          play: failingPlay,
        ),
        throwsA(isA<StateError>()),
      );
      await expectLater(
        coordinator.runAutomatic(
          expression: '音',
          reading: 'おと',
          play: failingPlay,
        ),
        throwsA(isA<StateError>()),
      );

      expect(attempts, 2);
    });
  });
}
