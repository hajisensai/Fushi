import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/aggregate_snapshot.dart';
import 'package:hibiki/src/sync/aggregate_sync_service.dart';
import 'package:hibiki_audio/hibiki_audio.dart' show FavoriteSentence;
import 'package:hibiki_core/hibiki_core.dart' show BookFormat;

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
      readingHourlyByFormat: const <HourlyFormatRecord>[
        HourlyFormatRecord(
            dateKey: '2026-06-01', hour: 9, format: 'epub', durationMs: 40000),
        HourlyFormatRecord(
            dateKey: '2026-06-01', hour: 9, format: 'manga', durationMs: 20000),
      ],
      videoHourly: const <HourlyRecord>[
        HourlyRecord(dateKey: '2026-06-01', hour: 20, durationMs: 30000),
      ],
      miningStats: const <MiningRecord>[
        MiningRecord(sourceType: 'book', dateKey: '2026-06-01', count: 3),
      ],
      lookupMiningCounters: const <LookupMiningRecord>[
        LookupMiningRecord(
          bookKey: 'bookA',
          title: 'Book A',
          sourceType: 'book',
          dateKey: '2026-06-01',
          lookupCount: 12,
          mineCount: 4,
        ),
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
      expect(back.readingHourlyByFormat, hasLength(2));
      expect(
        back.readingHourlyByFormat
            .singleWhere(
                (HourlyFormatRecord r) => r.format == BookFormat.epub.dbValue)
            .durationMs,
        40000,
      );
      expect(
        back.readingHourlyByFormat
            .singleWhere(
                (HourlyFormatRecord r) => r.format == BookFormat.manga.dbValue)
            .durationMs,
        20000,
      );
      expect(back.videoHourly.single.durationMs, 30000);
      expect(back.miningStats.single.count, 3);
      expect(back.miningStats.single.sourceType, 'book');
      expect(back.lookupMiningCounters.single.lookupCount, 12);
      expect(back.lookupMiningCounters.single.mineCount, 4);
      expect(back.lookupMiningCounters.single.bookKey, 'bookA');
      expect(back.lookupMiningCounters.single.title, 'Book A');
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

    test('hourly-by-format MAX per {dateKey, hour, format}; totals untouched',
        () {
      // 同一 {dateKey, hour} 下不同 format 是不同桶：各自 MAX，不互相折叠；
      // 逐时总量字段 readingHourly 保持旧 wire 语义（{dateKey, hour} MAX）。
      const AggregateSnapshot a = AggregateSnapshot(
        readingHourly: <HourlyRecord>[
          HourlyRecord(dateKey: 'd', hour: 9, durationMs: 30000),
        ],
        readingHourlyByFormat: <HourlyFormatRecord>[
          HourlyFormatRecord(
              dateKey: 'd', hour: 9, format: 'epub', durationMs: 20000),
          HourlyFormatRecord(
              dateKey: 'd', hour: 9, format: 'manga', durationMs: 10000),
        ],
      );
      const AggregateSnapshot b = AggregateSnapshot(
        readingHourly: <HourlyRecord>[
          HourlyRecord(dateKey: 'd', hour: 9, durationMs: 25000),
        ],
        readingHourlyByFormat: <HourlyFormatRecord>[
          HourlyFormatRecord(
              dateKey: 'd', hour: 9, format: 'epub', durationMs: 25000),
        ],
      );
      final AggregateSnapshot ab = AggregateSyncService.mergeSnapshots(a, b);
      final AggregateSnapshot ba = AggregateSyncService.mergeSnapshots(b, a);
      expect(ab.readingHourly.single.durationMs, 30000);
      expect(ab.readingHourlyByFormat, hasLength(2));
      expect(
        ab.readingHourlyByFormat
            .singleWhere(
                (HourlyFormatRecord r) => r.format == BookFormat.epub.dbValue)
            .durationMs,
        25000, // MAX(20000, 25000)
      );
      expect(
        ab.readingHourlyByFormat
            .singleWhere(
                (HourlyFormatRecord r) => r.format == BookFormat.manga.dbValue)
            .durationMs,
        10000, // 只有 a 携带，原样并入
      );
      // 可交换性。
      expect(
        ba.readingHourlyByFormat
            .singleWhere(
                (HourlyFormatRecord r) => r.format == BookFormat.epub.dbValue)
            .durationMs,
        25000,
      );
    });

    test('an OLD payload missing readingHourlyByFormat defaults it to empty',
        () {
      // 旧端上传只有逐时总量：byFormat 缺失 → 空列表，其余 family 照常折叠。
      final AggregateSnapshot snap =
          AggregateSnapshot.fromJson(<String, Object?>{
        'version': AggregateSnapshot.currentVersion,
        'readingHourly': <Object?>[
          <String, Object?>{'dateKey': 'd', 'hour': 9, 'durationMs': 1000},
        ],
      });
      expect(snap.readingHourly.single.durationMs, 1000);
      expect(snap.readingHourlyByFormat, isEmpty);
    });

    test('lookup/mine counters MAX both columns; bookKey prefers non-null', () {
      const AggregateSnapshot a = AggregateSnapshot(
        lookupMiningCounters: <LookupMiningRecord>[
          LookupMiningRecord(
            bookKey: null, // A had no book identity on this bucket
            title: 'Book A',
            sourceType: 'book',
            dateKey: 'd',
            lookupCount: 10,
            mineCount: 2,
          ),
        ],
      );
      const AggregateSnapshot b = AggregateSnapshot(
        lookupMiningCounters: <LookupMiningRecord>[
          LookupMiningRecord(
            bookKey: 'keyA', // B carries the book identity
            title: 'Book A',
            sourceType: 'book',
            dateKey: 'd',
            lookupCount: 4,
            mineCount: 9,
          ),
          LookupMiningRecord(
            bookKey: 'keyB',
            title: 'Book B',
            sourceType: 'book',
            dateKey: 'd',
            lookupCount: 1,
            mineCount: 1,
          ),
        ],
      );
      final AggregateSnapshot ab = AggregateSyncService.mergeSnapshots(a, b);
      final AggregateSnapshot ba = AggregateSyncService.mergeSnapshots(b, a);
      // Two buckets: the shared {Book A} and the peer-only {Book B}.
      expect(ab.lookupMiningCounters.length, 2);
      final LookupMiningRecord sharedAb = ab.lookupMiningCounters
          .firstWhere((LookupMiningRecord r) => r.title == 'Book A');
      // lookupCount MAX(10,4)=10, mineCount MAX(2,9)=9 (each column independent).
      expect(sharedAb.lookupCount, 10);
      expect(sharedAb.mineCount, 9);
      // The null bookKey is filled from the peer's non-null one.
      expect(sharedAb.bookKey, 'keyA');
      // bookKey resolution is order-independent (non-null wins either way).
      final LookupMiningRecord sharedBa = ba.lookupMiningCounters
          .firstWhere((LookupMiningRecord r) => r.title == 'Book A');
      expect(sharedBa.bookKey, 'keyA');
      expect(sharedBa.lookupCount, 10);
      expect(sharedBa.mineCount, 9);
    });
  });

  group('version compatibility', () {
    test('an OLD payload missing lookupMiningCounters defaults it to empty',
        () {
      // An older peer never wrote the counters key at all.
      final AggregateSnapshot snap =
          AggregateSnapshot.fromJson(<String, Object?>{
        'version': AggregateSnapshot.currentVersion,
        'miningStats': <Object?>[
          <String, Object?>{
            'sourceType': 'book',
            'dateKey': 'd',
            'count': 5,
          },
        ],
      });
      // Every other family still folds; the missing list is simply empty.
      expect(snap.miningStats.single.count, 5);
      expect(snap.lookupMiningCounters, isEmpty);
    });

    test('an additive UNKNOWN key at the same version is ignored, not dropped',
        () {
      // A FUTURE build adds an optional family WITHOUT bumping the version (the
      // discipline this snapshot mandates). An old build must still fold every
      // family it knows and simply ignore the key it does not — the whole
      // snapshot must NOT degrade to empty.
      final AggregateSnapshot snap =
          AggregateSnapshot.fromJson(<String, Object?>{
        'version': AggregateSnapshot.currentVersion,
        'miningStats': <Object?>[
          <String, Object?>{'sourceType': 'book', 'dateKey': 'd', 'count': 7},
        ],
        'lookupMiningCounters': <Object?>[
          <String, Object?>{
            'title': 'Book A',
            'sourceType': 'book',
            'dateKey': 'd',
            'lookupCount': 3,
            'mineCount': 1,
          },
        ],
        // An unknown future family key the current build has no decoder for.
        'someFutureFamily': <Object?>[
          <String, Object?>{'anything': 1},
        ],
      });
      expect(snap.isEmpty, isFalse); // NOT wholesale-rejected
      expect(snap.miningStats.single.count, 7);
      expect(snap.lookupMiningCounters.single.lookupCount, 3);
    });

    test('a payload with NO version field still decodes best-effort', () {
      // A version-less blob (e.g. a lenient encoder) is read, not rejected: the
      // higher-version guard only fires on an int strictly above currentVersion.
      final AggregateSnapshot snap =
          AggregateSnapshot.fromJson(<String, Object?>{
        'lookupMiningCounters': <Object?>[
          <String, Object?>{
            'title': 'Book A',
            'sourceType': 'book',
            'dateKey': 'd',
            'lookupCount': 9,
            'mineCount': 2,
          },
        ],
      });
      expect(snap.lookupMiningCounters.single.lookupCount, 9);
      expect(snap.lookupMiningCounters.single.mineCount, 2);
    });

    test(
        'only a strictly-HIGHER version (a breaking reshape) degrades to empty',
        () {
      // The version is reserved for genuinely breaking changes; a higher one is
      // rejected wholesale so this build never mis-parses a shape it cannot read.
      final AggregateSnapshot snap =
          AggregateSnapshot.fromJson(<String, Object?>{
        'version': AggregateSnapshot.currentVersion + 1,
        'lookupMiningCounters': <Object?>[
          <String, Object?>{
            'title': 'Book A',
            'sourceType': 'book',
            'dateKey': 'd',
            'lookupCount': 5,
            'mineCount': 5,
          },
        ],
      });
      expect(snap.isEmpty, isTrue);
    });
  });
}
