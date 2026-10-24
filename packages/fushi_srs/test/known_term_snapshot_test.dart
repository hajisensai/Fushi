import 'dart:math';

import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

typedef _Card = ({String reading, SrsQueue queue, bool suspended});

/// 逐词查询（`SrsDbStore.lookupTermStatus`）的口径：匹配读音的卡片按
/// [srsTermUrgencyCompare] 排序，最急一张在复习队列才算已知。
bool _referenceKnown(List<_Card> cards, String? queryReading) {
  final String rk = srsReadingKey(queryReading);
  final List<SrsTermStatus> matched = <SrsTermStatus>[
    for (final _Card c in cards)
      if (rk.isEmpty || c.reading.isEmpty || c.reading == rk)
        SrsTermStatus(
          cardId: 'c',
          noteId: 'n',
          queue: c.queue,
          suspended: c.suspended,
          deckId: 'd',
          cardCount: 1,
        ),
  ];
  if (matched.isEmpty) return false;
  matched.sort(srsTermUrgencyCompare);
  return matched.first.queue == SrsQueue.review;
}

SrsKnownTermSnapshot _snapshot(String term, List<_Card> cards) =>
    SrsKnownTermSnapshot.fromRows(
      <({String termKey, String readingKey, SrsQueue queue, bool suspended})>[
        for (final _Card c in cards)
          (
            termKey: srsTermKey(term),
            readingKey: c.reading,
            queue: c.queue,
            suspended: c.suspended,
          ),
      ],
    );

void main() {
  test('only a word whose most urgent card is in review is known', () {
    const String term = '猫';
    expect(
      _snapshot(term, <_Card>[
        (reading: 'ねこ', queue: SrsQueue.review, suspended: false),
      ]).isKnown(const SrsTermQuery(term, 'ねこ')),
      isTrue,
    );
    // 新卡 / 学习中 / 重学都不算已知。
    for (final SrsQueue q in <SrsQueue>[
      SrsQueue.newCard,
      SrsQueue.learning,
      SrsQueue.relearning,
    ]) {
      expect(
        _snapshot(term, <_Card>[
          (reading: 'ねこ', queue: q, suspended: false),
        ]).isKnown(const SrsTermQuery(term)),
        isFalse,
        reason: q.wire,
      );
    }
    // 同词另一张卡在学习中：最急一张不是复习卡。
    expect(
      _snapshot(term, <_Card>[
        (reading: 'ねこ', queue: SrsQueue.review, suspended: false),
        (reading: 'ねこ', queue: SrsQueue.learning, suspended: false),
      ]).isKnown(const SrsTermQuery(term)),
      isFalse,
    );
    // 暂停的学习卡排在未暂停的复习卡后面。
    expect(
      _snapshot(term, <_Card>[
        (reading: 'ねこ', queue: SrsQueue.review, suspended: false),
        (reading: 'ねこ', queue: SrsQueue.learning, suspended: true),
      ]).isKnown(const SrsTermQuery(term)),
      isTrue,
    );
    // 同形异读：查询带读音时不被别的读音的卡带成已知。
    expect(
      _snapshot('上手', <_Card>[
        (reading: 'うわて', queue: SrsQueue.review, suspended: false),
      ]).isKnown(const SrsTermQuery('上手', 'じょうず')),
      isFalse,
    );
    expect(
      SrsKnownTermSnapshot.empty().isKnown(const SrsTermQuery(term)),
      isFalse,
    );
  });

  test('matches the per-term urgency rule on random card sets', () {
    final Random rng = Random(20261024);
    const List<String> readings = <String>['', 'a', 'b'];
    for (int round = 0; round < 3000; round++) {
      final List<_Card> cards = <_Card>[
        for (int i = rng.nextInt(5); i > 0; i--)
          (
            reading: readings[rng.nextInt(readings.length)],
            queue: SrsQueue.values[rng.nextInt(SrsQueue.values.length)],
            suspended: rng.nextInt(3) == 0,
          ),
      ];
      final SrsKnownTermSnapshot snap = _snapshot('w', cards);
      for (final String? q in <String?>[null, 'a', 'b']) {
        expect(
          snap.isKnown(SrsTermQuery('w', q)),
          _referenceKnown(cards, q),
          reason: 'round $round cards=$cards query=$q',
        );
      }
    }
  });

  test('stamp changes only when the known-relevant distribution changes', () {
    final SrsKnownTermSnapshot a = _snapshot('w', <_Card>[
      (reading: 'a', queue: SrsQueue.review, suspended: false),
      (reading: 'a', queue: SrsQueue.review, suspended: false),
    ]);
    final SrsKnownTermSnapshot same = _snapshot('w', <_Card>[
      (reading: 'a', queue: SrsQueue.review, suspended: false),
    ]);
    final SrsKnownTermSnapshot moved = _snapshot('w', <_Card>[
      (reading: 'a', queue: SrsQueue.relearning, suspended: false),
    ]);
    expect(a.stamp, same.stamp);
    expect(a.stamp, isNot(moved.stamp));
  });
}
