import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/aggregate_snapshot.dart';
import 'package:hibiki/src/sync/aggregate_sync_service.dart';
import 'package:hibiki_audio/hibiki_audio.dart' show FavoriteSentence;

AggregateSnapshot _sample() => AggregateSnapshot(
      readingStats: const <ReadingStatRecord>[
        ReadingStatRecord(
          title: 'Book A',
          dateKey: '2026-06-01',
          charactersRead: 100,
          readingTimeMs: 60000,
          lastStatisticModified: 10,
        ),
      ],
      videoStats: const <VideoStatRecord>[
        VideoStatRecord(
          title: 'Video A',
          dateKey: '2026-06-01',
          subtitleChars: 50,
          watchTimeMs: 30000,
          lastModified: 5,
        ),
      ],
      readingHourly: const <HourlyRecord>[
        HourlyRecord(dateKey: '2026-06-01', hour: 9, durationMs: 60000),
      ],
      videoHourly: const <HourlyRecord>[
        HourlyRecord(dateKey: '2026-06-01', hour: 20, durationMs: 30000),
      ],
      miningStats: const <MiningRecord>[
        MiningRecord(sourceType: 'book', dateKey: '2026-06-01', count: 3),
      ],
      favoriteWords: const <FavoriteWordRecord>[
        FavoriteWordRecord(
          expression: 'neko',
          reading: 'ne',
          glossary: 'cat',
          sourceType: 'book',
          dateKey: '2026-06-01',
          createdAt: 1000,
        ),
      ],
      favoriteSentences: <FavoriteSentence>[
        FavoriteSentence(
          id: 'hl_1',
          text: 'sentence one',
          bookTitle: 'Book A',
          createdAt: DateTime.fromMillisecondsSinceEpoch(2000),
          bookKey: 'bookA',
          sectionIndex: 0,
          normCharOffset: 10,
        ),
      ],
    );

void main() {
  group('AggregateSnapshot JSON round-trip', () {
    test('toJson then fromJson reproduces every family through real JSON', () {
      final AggregateSnapshot original = _sample();
      final Object? wire = jsonDecode(jsonEncode(original.toJson()));
      final AggregateSnapshot back = AggregateSnapshot.fromJson(wire);

      expect(back.readingStats.single.charactersRead, 100);
      expect(back.readingStats.single.readingTimeMs, 60000);
      expect(back.readingStats.single.title, 'Book A');
      expect(back.videoStats.single.subtitleChars, 50);
      expect(back.videoStats.single.watchTimeMs, 30000);
      expect(back.readingHourly.single.durationMs, 60000);
      expect(back.readingHourly.single.hour, 9);
      expect(back.videoHourly.single.durationMs, 30000);
      expect(back.miningStats.single.count, 3);
      expect(back.miningStats.single.sourceType, 'book');
      expect(back.favoriteWords.single.expression, 'neko');
      expect(back.favoriteSentences.single.text, 'sentence one');
      expect(back.favoriteSentences.single.normCharOffset, 10);
    });

    test('null or non-map or higher-version degrades to empty', () {
      expect(AggregateSnapshot.fromJson(null).isEmpty, isTrue);
      expect(AggregateSnapshot.fromJson('nope').isEmpty, isTrue);
      expect(
        AggregateSnapshot.fromJson(<String, Object?>{
          'version': AggregateSnapshot.currentVersion + 1,
          'miningStats': <Object?>[
            <String, Object?>{
              'sourceType': 'book',
              'dateKey': '2026-06-01',
              'count': 9,
            },
          ],
        }).isEmpty,
        isTrue,
      );
    });

    test('malformed rows are skipped not fatal', () {
      final AggregateSnapshot snap =
          AggregateSnapshot.fromJson(<String, Object?>{
        'version': 1,
        'readingStats': <Object?>[
          'garbage',
          <String, Object?>{'title': 'ok', 'dateKey': 'd', 'charactersRead': 5},
          <String, Object?>{'dateKey': 'missing-title'},
        ],
      });
      expect(snap.readingStats.length, 1);
      expect(snap.readingStats.single.title, 'ok');
      expect(snap.readingStats.single.charactersRead, 5);
    });
  });

  group('mergeSnapshots invariants', () {
    test('statistics take per-bucket MAX not SUM, favorites union', () {
      const AggregateSnapshot a = AggregateSnapshot(
        readingStats: <ReadingStatRecord>[
          ReadingStatRecord(
            title: 'B',
            dateKey: 'd',
            charactersRead: 100,
            readingTimeMs: 5,
            lastStatisticModified: 1,
          ),
        ],
        miningStats: <MiningRecord>[
          MiningRecord(sourceType: 'book', dateKey: 'd', count: 4),
        ],
        favoriteWords: <FavoriteWordRecord>[
          FavoriteWordRecord(
            expression: 'a',
            reading: 'r',
            glossary: 'g',
            sourceType: 'book',
            dateKey: 'd',
            createdAt: 1,
          ),
        ],
      );
      const AggregateSnapshot b = AggregateSnapshot(
        readingStats: <ReadingStatRecord>[
          ReadingStatRecord(
            title: 'B',
            dateKey: 'd',
            charactersRead: 70,
            readingTimeMs: 9,
            lastStatisticModified: 3,
          ),
        ],
        miningStats: <MiningRecord>[
          MiningRecord(sourceType: 'book', dateKey: 'd', count: 6),
        ],
        favoriteWords: <FavoriteWordRecord>[
          FavoriteWordRecord(
            expression: 'z',
            reading: 'r2',
            glossary: 'g2',
            sourceType: 'video',
            dateKey: 'd',
            createdAt: 2,
          ),
        ],
      );

      final AggregateSnapshot merged =
          AggregateSyncService.mergeSnapshots(a, b);
      expect(merged.readingStats.single.charactersRead, 100);
      expect(merged.readingStats.single.readingTimeMs, 9);
      expect(merged.miningStats.single.count, 6);
      expect(merged.favoriteWords.length, 2);
    });

    test('merge is idempotent: merge(merge(a,b),b) equals merge(a,b)', () {
      final AggregateSnapshot a = _sample();
      final AggregateSnapshot b = AggregateSnapshot(
        readingStats: const <ReadingStatRecord>[
          ReadingStatRecord(
            title: 'Book A',
            dateKey: '2026-06-01',
            charactersRead: 250,
            readingTimeMs: 12000,
            lastStatisticModified: 20,
          ),
        ],
        miningStats: const <MiningRecord>[
          MiningRecord(sourceType: 'book', dateKey: '2026-06-01', count: 7),
        ],
        favoriteWords: const <FavoriteWordRecord>[
          FavoriteWordRecord(
            expression: 'inu',
            reading: 'in',
            glossary: 'dog',
            sourceType: 'book',
            dateKey: '2026-06-02',
            createdAt: 3000,
          ),
        ],
        favoriteSentences: <FavoriteSentence>[
          FavoriteSentence(
            id: 'hl_2',
            text: 'sentence two',
            bookTitle: 'Book A',
            createdAt: DateTime.fromMillisecondsSinceEpoch(4000),
          ),
        ],
      );

      final AggregateSnapshot once = AggregateSyncService.mergeSnapshots(a, b);
      final AggregateSnapshot twice =
          AggregateSyncService.mergeSnapshots(once, b);

      expect(twice.readingStats.single.charactersRead,
          once.readingStats.single.charactersRead);
      expect(twice.miningStats.single.count, once.miningStats.single.count);
      expect(twice.favoriteWords.length, once.favoriteWords.length);
      expect(twice.favoriteSentences.length, once.favoriteSentences.length);
      expect(once.readingStats.single.charactersRead, 250);
      expect(once.miningStats.single.count, 7);
      expect(once.favoriteWords.length, 2);
      expect(once.favoriteSentences.length, 2);
    });

    test('commutative on union set: merge(a,b) buckets equal merge(b,a)', () {
      final AggregateSnapshot a = _sample();
      const AggregateSnapshot b = AggregateSnapshot(
        readingStats: <ReadingStatRecord>[
          ReadingStatRecord(
            title: 'Book A',
            dateKey: '2026-06-01',
            charactersRead: 250,
            readingTimeMs: 3,
            lastStatisticModified: 99,
          ),
        ],
      );
      final AggregateSnapshot ab = AggregateSyncService.mergeSnapshots(a, b);
      final AggregateSnapshot ba = AggregateSyncService.mergeSnapshots(b, a);
      expect(ab.readingStats.single.charactersRead,
          ba.readingStats.single.charactersRead);
      expect(ab.readingStats.single.readingTimeMs,
          ba.readingStats.single.readingTimeMs);
      expect(ab.readingStats.single.charactersRead, 250);
      expect(ab.readingStats.single.readingTimeMs, 60000);
    });
  });
}
