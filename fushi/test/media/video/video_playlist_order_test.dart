import 'dart:math';

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_playlist_order.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi_core/fushi_core.dart';

void main() {
  group('VideoPlaylistOrder storage (拍板台 QHbRRctQdW)', () {
    test('round-trips storage values and falls back to sequential', () {
      for (final VideoPlaylistOrder order in VideoPlaylistOrder.values) {
        expect(VideoPlaylistOrder.fromStorage(order.storageValue), order);
      }
      expect(VideoPlaylistOrder.fromStorage(''), VideoPlaylistOrder.sequential);
      expect(
        VideoPlaylistOrder.fromStorage('garbage'),
        VideoPlaylistOrder.sequential,
      );
    });
  });

  group('sequentialNextEpisode', () {
    test('advances by one and stops at the last / single episode', () {
      expect(sequentialNextEpisode(count: 3, current: 0), 1);
      expect(sequentialNextEpisode(count: 3, current: 1), 2);
      expect(sequentialNextEpisode(count: 3, current: 2), isNull);
      expect(sequentialNextEpisode(count: 1, current: 0), isNull);
      expect(sequentialNextEpisode(count: 0, current: 0), isNull);
      expect(sequentialNextEpisode(count: 3, current: -1), isNull);
    });
  });

  group('pickShuffleEpisode', () {
    test('never picks the current episode and prefers unplayed ones', () {
      for (int seed = 0; seed < 50; seed++) {
        final int? pick = pickShuffleEpisode(
          count: 5,
          current: 2,
          played: <int>{0, 2, 4},
          random: Random(seed),
        );
        expect(<int>{1, 3}, contains(pick));
      }
    });

    test('when everything has played, picks any episode but the current', () {
      for (int seed = 0; seed < 50; seed++) {
        final int? pick = pickShuffleEpisode(
          count: 3,
          current: 1,
          played: <int>{0, 1, 2},
          random: Random(seed),
        );
        expect(<int>{0, 2}, contains(pick));
      }
    });

    test('a single episode or out-of-range current has no target', () {
      expect(
        pickShuffleEpisode(
          count: 1,
          current: 0,
          played: <int>{},
          random: Random(1),
        ),
        isNull,
      );
      expect(
        pickShuffleEpisode(
          count: 4,
          current: 4,
          played: <int>{},
          random: Random(1),
        ),
        isNull,
      );
    });
  });

  group('VideoShuffleRounds', () {
    test('one round visits every episode exactly once, then keeps going', () {
      for (int seed = 0; seed < 20; seed++) {
        final VideoShuffleRounds rounds = VideoShuffleRounds(
          random: Random(seed),
        );
        const int count = 6;
        final String key = VideoShuffleRounds.playlistKey(<String>[
          for (int i = 0; i < count; i++) 'ep$i',
        ]);
        int current = 0;
        final List<int> visited = <int>[current];
        for (int step = 0; step < count - 1; step++) {
          final int? next = rounds.next(
            playlistKey: key,
            count: count,
            current: current,
          );
          expect(next, isNotNull);
          current = next!;
          visited.add(current);
        }
        expect(
          visited.toSet().length,
          count,
          reason: '一轮之内每集正好播一次（seed $seed: $visited）',
        );
        // 整轮播完不停：开新一轮，且不会原地重播刚播完的这一集。
        final int? afterRound = rounds.next(
          playlistKey: key,
          count: count,
          current: current,
        );
        expect(afterRound, isNotNull);
        expect(afterRound, isNot(current));
      }
    });

    test('playlists are tracked in separate slots', () {
      final VideoShuffleRounds rounds = VideoShuffleRounds(random: Random(3));
      final String a = VideoShuffleRounds.playlistKey(<String>['a0', 'a1']);
      final String b = VideoShuffleRounds.playlistKey(<String>['b0', 'b1']);
      expect(rounds.next(playlistKey: a, count: 2, current: 0), 1);
      // b 的槽没被 a 的进度污染。
      expect(rounds.next(playlistKey: b, count: 2, current: 1), 0);
    });

    test('a single-episode playlist has no shuffle target', () {
      final VideoShuffleRounds rounds = VideoShuffleRounds(random: Random(1));
      expect(
        rounds.next(
          playlistKey: VideoShuffleRounds.playlistKey(<String>['only']),
          count: 1,
          current: 0,
        ),
        isNull,
      );
    });
  });

  group('PreferencesRepository videoPlaylistOrder', () {
    late FushiDatabase db;
    late PreferencesRepository repo;

    setUp(() async {
      db = FushiDatabase.forTesting(
        DatabaseConnection(NativeDatabase.memory()),
      );
      repo = PreferencesRepository(db);
      await repo.loadFromDb();
    });

    tearDown(() async {
      repo.dispose();
      await db.close();
    });

    test('defaults to sequential (historical behaviour)', () {
      expect(repo.videoPlaylistOrder, VideoPlaylistOrder.sequential);
    });

    test('persists shuffle across reload', () async {
      await repo.setVideoPlaylistOrder(VideoPlaylistOrder.shuffle);
      final PreferencesRepository reloaded = PreferencesRepository(db);
      await reloaded.loadFromDb();
      expect(reloaded.videoPlaylistOrder, VideoPlaylistOrder.shuffle);
      reloaded.dispose();
    });
  });
}
