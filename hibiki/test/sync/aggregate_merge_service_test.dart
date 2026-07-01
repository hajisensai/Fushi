import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/aggregate_merge_service.dart';
import 'package:hibiki_audio/hibiki_audio.dart'
    show FavoriteSentence, kFavoriteSentenceSourceBook;

FavoriteSentence _fs(
  String text, {
  String? bookKey,
  int? sectionIndex,
  int? normCharOffset,
  required int createdAtMs,
  String? id,
  String source = kFavoriteSentenceSourceBook,
}) =>
    FavoriteSentence(
      id: id,
      text: text,
      bookTitle: 'title',
      bookKey: bookKey,
      sectionIndex: sectionIndex,
      normCharOffset: normCharOffset,
      createdAt: DateTime.fromMillisecondsSinceEpoch(createdAtMs),
      source: source,
    );

void main() {
  group('mergeMaxCounters', () {
    test('per-key MAX, never SUM; disjoint keys unioned', () {
      final Map<String, int> local = <String, int>{'a': 5, 'b': 2};
      final Map<String, int> remote = <String, int>{'a': 3, 'c': 9};
      final Map<String, int> out =
          AggregateMergeService.mergeMaxCounters(local, remote);
      expect(out, <String, int>{'a': 5, 'b': 2, 'c': 9}); // a=max(5,3)
    });

    test('idempotent: merge(a, a) == a and re-merge is stable', () {
      final Map<String, int> a = <String, int>{'x': 7, 'y': 1};
      final Map<String, int> once =
          AggregateMergeService.mergeMaxCounters(a, a);
      expect(once, a);
      final Map<String, int> b = <String, int>{'x': 4, 'z': 3};
      final Map<String, int> m1 = AggregateMergeService.mergeMaxCounters(a, b);
      final Map<String, int> m2 = AggregateMergeService.mergeMaxCounters(m1, b);
      expect(m2, m1); // re-applying the same remote changes nothing
    });

    test('commutative on the result set/values', () {
      final Map<String, int> a = <String, int>{'x': 7, 'y': 1};
      final Map<String, int> b = <String, int>{'x': 4, 'z': 3};
      expect(
        AggregateMergeService.mergeMaxCounters(a, b),
        AggregateMergeService.mergeMaxCounters(b, a),
      );
    });

    test('does not mutate the input maps', () {
      final Map<String, int> a = <String, int>{'x': 1};
      final Map<String, int> b = <String, int>{'y': 2};
      AggregateMergeService.mergeMaxCounters(a, b);
      expect(a, <String, int>{'x': 1});
      expect(b, <String, int>{'y': 2});
    });

    test('a value never shrinks (under-counting peer cannot pull down)', () {
      final Map<String, int> local = <String, int>{'a': 100};
      final Map<String, int> remote = <String, int>{'a': 1};
      expect(AggregateMergeService.mergeMaxCounters(local, remote),
          <String, int>{'a': 100});
    });
  });

  group('mergeStatBuckets', () {
    test('field-wise MAX on shared bucket; disjoint buckets unioned', () {
      final Map<String, StatBucket> local = <String, StatBucket>{
        'A|2026-01-01':
            const StatBucket(<String, int>{'chars': 100, 'ms': 6000}),
      };
      final Map<String, StatBucket> remote = <String, StatBucket>{
        'A|2026-01-01':
            const StatBucket(<String, int>{'chars': 80, 'ms': 9000}),
        'B|2026-01-01': const StatBucket(<String, int>{'chars': 999, 'ms': 1}),
      };
      final Map<String, StatBucket> out =
          AggregateMergeService.mergeStatBuckets(local, remote);
      expect(out.length, 2);
      // Distinct titles under one dateKey NOT folded.
      expect(out['A|2026-01-01'],
          const StatBucket(<String, int>{'chars': 100, 'ms': 9000}));
      expect(out['B|2026-01-01'],
          const StatBucket(<String, int>{'chars': 999, 'ms': 1}));
    });

    test('idempotent and commutative on values', () {
      final Map<String, StatBucket> a = <String, StatBucket>{
        'k': const StatBucket(<String, int>{'v': 5}),
      };
      final Map<String, StatBucket> b = <String, StatBucket>{
        'k': const StatBucket(<String, int>{'v': 9}),
      };
      expect(AggregateMergeService.mergeStatBuckets(a, a), a);
      expect(
        AggregateMergeService.mergeStatBuckets(a, b),
        AggregateMergeService.mergeStatBuckets(b, a),
      );
    });

    test('mismatched field sets throw (programming error, not silent)', () {
      const StatBucket wide = StatBucket(<String, int>{'x': 1, 'y': 2});
      const StatBucket narrow = StatBucket(<String, int>{'x': 1});
      expect(() => wide.maxWith(narrow), throwsArgumentError);
    });
  });

  group('mergeUniqueByKey (favorite words)', () {
    String keyOf(List<String> row) => row.join('|');
    test('dedupe on key; local wins on collision; remote-only appended', () {
      final List<List<String>> local = <List<String>>[
        <String>['a', 'r', 'book', 'LOCAL'],
      ];
      final List<List<String>> remote = <List<String>>[
        <String>['a', 'r', 'book', 'REMOTE'], // same {a,r,book} key -> dropped
        <String>['new', '', 'book', 'X'],
      ];
      String uk(List<String> row) => keyOf(row.sublist(0, 3));
      final List<List<String>> out =
          AggregateMergeService.mergeUniqueByKey(local, remote, uk);
      expect(out.length, 2);
      expect(out.first[3], 'LOCAL'); // local row kept on collision
      expect(out.last.first, 'new');
    });

    test('idempotent: re-merging same remote adds nothing', () {
      String uk(String r) => r;
      final List<String> local = <String>['a', 'b'];
      final List<String> remote = <String>['b', 'c'];
      final List<String> m1 =
          AggregateMergeService.mergeUniqueByKey(local, remote, uk);
      final List<String> m2 =
          AggregateMergeService.mergeUniqueByKey(m1, remote, uk);
      expect(m1, <String>['a', 'b', 'c']);
      expect(m2, m1);
    });
  });

  group('mergeFavoriteSentences', () {
    test('content dedupe-union; identical content across ids dropped once', () {
      final List<FavoriteSentence> local = <FavoriteSentence>[
        _fs('text',
            bookKey: 'bk',
            sectionIndex: 1,
            normCharOffset: 10,
            createdAtMs: 500,
            id: 'hl_local'),
      ];
      final List<FavoriteSentence> remote = <FavoriteSentence>[
        // Same content tuple, DIFFERENT id + LATER createdAt -> deduped.
        _fs('text',
            bookKey: 'bk',
            sectionIndex: 1,
            normCharOffset: 10,
            createdAtMs: 900,
            id: 'hl_remote'),
        // A genuinely new sentence -> added.
        _fs('other',
            bookKey: 'bk',
            sectionIndex: 2,
            normCharOffset: 20,
            createdAtMs: 700,
            id: 'hl_new'),
      ];
      final List<FavoriteSentence> out =
          AggregateMergeService.mergeFavoriteSentences(local, remote);
      expect(out.length, 2);
      final FavoriteSentence dup =
          out.firstWhere((FavoriteSentence s) => s.text == 'text');
      // Earlier createdAt kept (the local id/timestamp), later dropped.
      expect(dup.id, 'hl_local');
      expect(dup.createdAt.millisecondsSinceEpoch, 500);
    });

    test('output sorted newest-first by createdAt', () {
      final List<FavoriteSentence> out =
          AggregateMergeService.mergeFavoriteSentences(
        <FavoriteSentence>[_fs('old', createdAtMs: 100, normCharOffset: 1)],
        <FavoriteSentence>[_fs('new', createdAtMs: 900, normCharOffset: 2)],
      );
      expect(out.map((FavoriteSentence s) => s.text).toList(),
          <String>['new', 'old']);
    });

    test('idempotent: merge(a, a) == a (by content) and re-merge stable', () {
      final List<FavoriteSentence> a = <FavoriteSentence>[
        _fs('s1', normCharOffset: 1, createdAtMs: 100),
        _fs('s2', normCharOffset: 2, createdAtMs: 200),
      ];
      final List<FavoriteSentence> once =
          AggregateMergeService.mergeFavoriteSentences(a, a);
      expect(once.length, 2);
      final List<FavoriteSentence> b = <FavoriteSentence>[
        _fs('s2', normCharOffset: 2, createdAtMs: 250), // dup content
        _fs('s3', normCharOffset: 3, createdAtMs: 300),
      ];
      final List<FavoriteSentence> m1 =
          AggregateMergeService.mergeFavoriteSentences(a, b);
      final List<FavoriteSentence> m2 =
          AggregateMergeService.mergeFavoriteSentences(m1, b);
      expect(m1.length, 3); // s1, s2, s3
      expect(m2.length, m1.length);
    });

    test('collision result independent of side order (earliest wins)', () {
      final FavoriteSentence early =
          _fs('t', normCharOffset: 5, createdAtMs: 100, id: 'early');
      final FavoriteSentence late =
          _fs('t', normCharOffset: 5, createdAtMs: 900, id: 'late');
      final List<FavoriteSentence> ab =
          AggregateMergeService.mergeFavoriteSentences(
              <FavoriteSentence>[early], <FavoriteSentence>[late]);
      final List<FavoriteSentence> ba =
          AggregateMergeService.mergeFavoriteSentences(
              <FavoriteSentence>[late], <FavoriteSentence>[early]);
      expect(ab.single.id, 'early');
      expect(ba.single.id, 'early'); // same winner regardless of order
    });

    test('null fields do not collide with empty-string / zero counterparts',
        () {
      // Same text but distinct nullable tuples must all survive.
      final List<FavoriteSentence> out =
          AggregateMergeService.mergeFavoriteSentences(
        <FavoriteSentence>[
          _fs('t',
              bookKey: null,
              sectionIndex: null,
              normCharOffset: null,
              createdAtMs: 1),
        ],
        <FavoriteSentence>[
          _fs('t',
              bookKey: '', sectionIndex: 0, normCharOffset: 0, createdAtMs: 2),
        ],
      );
      expect(out.length, 2); // null tuple != (empty,0,0) tuple
    });

    test('empty remote is a no-op (deletion does not propagate)', () {
      final List<FavoriteSentence> local = <FavoriteSentence>[
        _fs('keep', normCharOffset: 1, createdAtMs: 100),
      ];
      final List<FavoriteSentence> out =
          AggregateMergeService.mergeFavoriteSentences(
              local, const <FavoriteSentence>[]);
      expect(out.length, 1);
      expect(out.single.text, 'keep');
    });
  });
}
