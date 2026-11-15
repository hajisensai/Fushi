import 'package:fushi_engine/media/tracking/title_match.dart';
import 'package:test/test.dart';

/// Titles taken from live MangaBaka results (2026-11-06).
TitleMatchCandidate<String> _candidate(
  int id,
  List<String> titles, {
  bool kindMatches = true,
  List<String> authors = const <String>[],
}) => TitleMatchCandidate<String>(
  subject: 'mb:$id',
  id: id,
  titles: titles,
  authors: authors,
  kindMatches: kindMatches,
);

final TitleMatchCandidate<String> _lotmNovel = _candidate(84351, <String>[
  'Lord of the Mysteries',
  '诡秘之主',
  'Guimi Zhi Zhu',
]);
final TitleMatchCandidate<String> _lotmManhua = _candidate(140001, <String>[
  'Lord of the Mysteries',
  '诡秘之主',
], kindMatches: false);
final TitleMatchCandidate<String> _bakeNovel = _candidate(84547, <String>[
  'Bakemonogatari',
  '化物語',
]);
final TitleMatchCandidate<String> _bakeManga = _candidate(7426, <String>[
  'Bakemonogatari',
  '化物語',
], kindMatches: false);

void main() {
  group('TitleMatchQuery.fromLocalTitle', () {
    test('drops volume numbers and labels, keeps the volume', () {
      final TitleMatchQuery query = TitleMatchQuery.fromLocalTitle('詭秘之主 第3卷');
      // The title as written stays last, a fallback when cleaning took too
      // much.
      expect(query.titles, <String>['詭秘之主', '詭秘之主 第3卷']);
      expect(query.volume, 3);
      expect(TitleMatchQuery.fromLocalTitle('化物語 (上)').titles, <String>[
        '化物語',
        '化物語 (上)',
      ]);
    });

    test('adds extra titles once', () {
      final TitleMatchQuery query = TitleMatchQuery.fromLocalTitle(
        'Lord of the Mysteries Vol.2',
        extraTitles: <String>['Lord of the Mysteries', '诡秘之主'],
      );
      expect(query.titles, <String>[
        'Lord of the Mysteries',
        '诡秘之主',
        'Lord of the Mysteries Vol.2',
      ]);
      expect(query.volume, 2);
    });
  });

  group('decideTitleMatch', () {
    test('exact title links the novel, never the manhua adaptation', () {
      final TitleMatchDecision<String> decision = decideTitleMatch(
        TitleMatchQuery.fromLocalTitle('Lord of the Mysteries'),
        <TitleMatchCandidate<String>>[_lotmManhua, _lotmNovel],
      );
      expect(decision.auto?.candidate.id, 84351);
      expect(decision.auto?.score, 1);
      expect(decision.suggestions, isEmpty);
    });

    // Folding covers only the characters in the shared title table
    // (native/fushi_compute/tool/gen_title_tables.dart); 詭 is not in it yet.
    test('Traditional/Japanese forms match the Simplified title', () {
      final TitleMatchDecision<String> decision = decideTitleMatch(
        TitleMatchQuery.fromLocalTitle('化物語 第3巻'),
        <TitleMatchCandidate<String>>[
          _candidate(84547, <String>['Bakemonogatari', '化物语']),
        ],
      );
      expect(decision.auto?.candidate.id, 84547);
    });

    test('Bakemonogatari novel links the novel entry', () {
      final TitleMatchDecision<String> decision = decideTitleMatch(
        TitleMatchQuery.fromLocalTitle('化物語 (上)'),
        <TitleMatchCandidate<String>>[_bakeManga, _bakeNovel],
      );
      expect(decision.auto?.candidate.id, 84547);
    });

    test('two equal candidates are suggestions, not an auto link', () {
      final TitleMatchDecision<String> decision = decideTitleMatch(
        TitleMatchQuery.fromLocalTitle('化物語'),
        <TitleMatchCandidate<String>>[
          _bakeNovel,
          _candidate(90000, <String>['化物語']),
        ],
      );
      expect(decision.auto, isNull);
      expect(
        decision.suggestions.map((ScoredTitleCandidate<String> s) {
          return s.candidate.id;
        }),
        unorderedEquals(<int>[84547, 90000]),
      );
    });

    test('katakana and hiragana spellings compare equal', () {
      final TitleMatchDecision<String> decision = decideTitleMatch(
        TitleMatchQuery.fromLocalTitle('ヨツバと!'),
        <TitleMatchCandidate<String>>[
          _candidate(1, <String>['Yotsuba&!', 'よつばと!']),
        ],
      );
      expect(decision.auto?.score, 1);
    });

    test('a close but inexact title is only a suggestion', () {
      final TitleMatchDecision<String> decision = decideTitleMatch(
        TitleMatchQuery.fromLocalTitle('Lord of Mysteries'),
        <TitleMatchCandidate<String>>[_lotmNovel],
      );
      expect(decision.auto, isNull);
      expect(decision.suggestions.single.candidate.id, 84351);
      final double score = decision.suggestions.single.score;
      expect(score, greaterThanOrEqualTo(kTitleMatchSuggest));
      expect(score, lessThan(kTitleMatchAutoLink));
    });

    test('a matching author lifts a close title over the auto threshold', () {
      final TitleMatchDecision<String> plain = decideTitleMatch(
        TitleMatchQuery.fromLocalTitle('Lord of Mysteries'),
        <TitleMatchCandidate<String>>[_lotmNovel],
      );
      final double base = plain.suggestions.single.score;
      final TitleMatchDecision<String> withAuthor = decideTitleMatch(
        TitleMatchQuery.fromLocalTitle(
          'Lord of Mysteries',
          authors: <String>['Cuttlefish That Loves Diving'],
        ),
        <TitleMatchCandidate<String>>[
          _candidate(
            84351,
            _lotmNovel.titles,
            authors: <String>['爱潜水的乌贼', 'Cuttlefish That Loves Diving'],
          ),
        ],
      );
      final ScoredTitleCandidate<String>? scored =
          withAuthor.auto ?? withAuthor.suggestions.firstOrNull;
      expect(scored?.score, closeTo(base + kTitleMatchAuthorBonus, 1e-9));
    });

    test('unrelated titles give nothing', () {
      final TitleMatchDecision<String> decision = decideTitleMatch(
        TitleMatchQuery.fromLocalTitle('葬送のフリーレン'),
        <TitleMatchCandidate<String>>[_lotmNovel, _bakeNovel],
      );
      expect(decision.isEmpty, isTrue);
    });

    test('only wrong-kind candidates give nothing', () {
      final TitleMatchDecision<String> decision = decideTitleMatch(
        TitleMatchQuery.fromLocalTitle('化物語'),
        <TitleMatchCandidate<String>>[_bakeManga],
      );
      expect(decision.isEmpty, isTrue);
    });

    test('the same subject listed twice counts once', () {
      final TitleMatchDecision<String> decision = decideTitleMatch(
        TitleMatchQuery.fromLocalTitle('Lord of the Mysteries'),
        <TitleMatchCandidate<String>>[_lotmNovel, _lotmNovel],
      );
      expect(decision.auto?.candidate.id, 84351);
    });
  });
}
