/// Picking a tracker title for a local book or manga from its title, with a
/// confidence score. Used only where no id exists (books, manga); anime links
/// from ids.
///
/// Rules (user decision 2026-11-06):
/// - score ≥ [kTitleMatchAutoLink] and at least [kTitleMatchMargin] ahead of
///   the next candidate → link automatically;
/// - otherwise candidates scoring ≥ [kTitleMatchSuggest] are suggestions for
///   the user to approve;
/// - below that, nothing (manual link only).
///
/// A candidate of the wrong kind (a manga adaptation for a novel, or the
/// reverse) never scores: the caller says so with
/// [TitleMatchCandidate.kindMatches]. That is a hard gate, never a fallback.
library;

import 'package:fushi_core/fushi_core.dart' show katakanaToHiragana;
import 'package:fushi_engine/media/collections/book_series_key.dart';
import 'package:fushi_engine/media/tracking/local_title_clean.dart';
import 'package:fushi_engine/media/video/scraper/title_normalizer.dart';

/// At or above: link without asking (also needs [kTitleMatchMargin]).
const double kTitleMatchAutoLink = 0.90;

/// At or above (and not auto-linked): offer as a suggestion.
const double kTitleMatchSuggest = 0.60;

/// The best candidate must beat the next by this much to link automatically.
const double kTitleMatchMargin = 0.08;

/// Added when an author matches too (never pushes past 1.0). Author names
/// often differ in script between sources, so a mismatch is not penalised.
const double kTitleMatchAuthorBonus = 0.05;

/// At most this many suggestions are kept.
const int kTitleMatchMaxSuggestions = 5;

/// What we know about the local item.
final class TitleMatchQuery {
  const TitleMatchQuery({
    required this.titles,
    this.authors = const <String>[],
    this.volume,
  });

  /// Builds the query from a local title: the clean names of
  /// [localTitleSearchCandidates] (no volume numbers, publisher labels,
  /// release / scan / group tags or repeated series name: `化物語 (上)`,
  /// `Vol.3`, `第2巻`, `[3574f94a]`, `Ajin (HD Scan) Ajin 01`). [extraTitles]
  /// are other names the item carries (OPF series name, web novel work title,
  /// source series title). Every clean name comes first, in that order; the
  /// names as written come last (a fallback when cleaning took too much).
  factory TitleMatchQuery.fromLocalTitle(
    String title, {
    List<String> extraTitles = const <String>[],
    List<String> authors = const <String>[],
  }) {
    final BookSeriesKey? key = parseBookSeriesKey(title);
    final List<String> titles = <String>[];
    final List<String> asWritten = <String>[];
    void add(String value) {
      final String trimmed = value.trim();
      if (trimmed.isNotEmpty && !titles.contains(trimmed)) titles.add(trimmed);
    }

    for (final String name in <String>[title, ...extraTitles]) {
      final List<String> candidates = localTitleSearchCandidates(name);
      if (candidates.length == 1) {
        // Nothing to clean: the name is already a clean one.
        add(candidates.single);
        continue;
      }
      candidates.take(candidates.length - 1).forEach(add);
      asWritten.add(candidates.last);
    }
    asWritten.forEach(add);
    if (titles.isEmpty) add(title);
    return TitleMatchQuery(
      titles: titles,
      authors: authors,
      volume: key?.volume,
    );
  }

  /// Names to compare, best first. Never empty for a usable query.
  final List<String> titles;
  final List<String> authors;

  /// Local volume number when the title carries one.
  final num? volume;

  /// Strings worth sending to a search API, best first.
  List<String> get searchTerms => titles;
}

/// One tracker result.
final class TitleMatchCandidate<T> {
  const TitleMatchCandidate({
    required this.subject,
    required this.id,
    required this.titles,
    this.authors = const <String>[],
    this.kindMatches = true,
  });

  final T subject;

  /// Provider id of the subject (two results with the same id are one).
  final int id;

  /// Every title the provider has (all languages, synonyms).
  final List<String> titles;
  final List<String> authors;

  /// False when the result is of the other kind (novel vs manga). Such a
  /// candidate is dropped before scoring.
  final bool kindMatches;
}

final class ScoredTitleCandidate<T> {
  const ScoredTitleCandidate({required this.candidate, required this.score});

  final TitleMatchCandidate<T> candidate;

  /// 0..1.
  final double score;
}

final class TitleMatchDecision<T> {
  const TitleMatchDecision({required this.auto, required this.suggestions});

  /// Link this one without asking; null when nothing is sure enough.
  final ScoredTitleCandidate<T>? auto;

  /// Ask the user; best first. Empty when [auto] is set.
  final List<ScoredTitleCandidate<T>> suggestions;

  bool get isEmpty => auto == null && suggestions.isEmpty;
}

/// Folds what [TitleNormalizer] does not: katakana → hiragana, so `ヨツバと!`
/// and `よつばと!` compare equal. Width and Traditional → Simplified are done by
/// [TitleNormalizer.normalize].
String foldTitleForMatch(String title) => TitleNormalizer.normalize(
  String.fromCharCodes(<int>[
    for (final int code in title.runes) katakanaToHiragana(code),
  ]),
);

/// Scores [candidates] against [query] and decides auto-link / suggestions.
TitleMatchDecision<T> decideTitleMatch<T>(
  TitleMatchQuery query,
  List<TitleMatchCandidate<T>> candidates,
) {
  final List<String> queryTitles = <String>[
    for (final String title in query.titles)
      if (foldTitleForMatch(title) case final String folded
          when folded.isNotEmpty)
        folded,
  ];
  if (queryTitles.isEmpty) {
    return TitleMatchDecision<T>(
      auto: null,
      suggestions: <ScoredTitleCandidate<T>>[],
    );
  }
  final List<String> queryAuthors = <String>[
    for (final String author in query.authors)
      if (foldTitleForMatch(author) case final String folded
          when folded.isNotEmpty)
        folded,
  ];

  // Best score per subject id (a provider can list one subject twice).
  final Map<int, ScoredTitleCandidate<T>> best =
      <int, ScoredTitleCandidate<T>>{};
  for (final TitleMatchCandidate<T> candidate in candidates) {
    if (!candidate.kindMatches) continue;
    final double score = _score(queryTitles, queryAuthors, candidate);
    final ScoredTitleCandidate<T>? known = best[candidate.id];
    if (known == null || score > known.score) {
      best[candidate.id] = ScoredTitleCandidate<T>(
        candidate: candidate,
        score: score,
      );
    }
  }
  final List<ScoredTitleCandidate<T>> ranked = best.values.toList()
    ..sort(
      (ScoredTitleCandidate<T> a, ScoredTitleCandidate<T> b) =>
          b.score.compareTo(a.score),
    );
  if (ranked.isEmpty) {
    return TitleMatchDecision<T>(
      auto: null,
      suggestions: <ScoredTitleCandidate<T>>[],
    );
  }
  final ScoredTitleCandidate<T> top = ranked.first;
  final double next = ranked.length > 1 ? ranked[1].score : 0;
  if (top.score >= kTitleMatchAutoLink &&
      top.score - next >= kTitleMatchMargin) {
    return TitleMatchDecision<T>(
      auto: top,
      suggestions: <ScoredTitleCandidate<T>>[],
    );
  }
  return TitleMatchDecision<T>(
    auto: null,
    suggestions: <ScoredTitleCandidate<T>>[
      for (final ScoredTitleCandidate<T> scored in ranked.take(
        kTitleMatchMaxSuggestions,
      ))
        if (scored.score >= kTitleMatchSuggest) scored,
    ],
  );
}

double _score<T>(
  List<String> queryTitles,
  List<String> queryAuthors,
  TitleMatchCandidate<T> candidate,
) {
  final List<String> titles = <String>[
    for (final String title in candidate.titles)
      if (foldTitleForMatch(title) case final String folded
          when folded.isNotEmpty)
        folded,
  ];
  if (titles.isEmpty) return 0;
  double score = 0;
  for (final String q in queryTitles) {
    for (final String t in titles) {
      if (q == t) return _withAuthor(1, queryAuthors, candidate);
    }
  }
  final List<double> matrix = TitleNormalizer.similarityNormalizedMatrix(
    queryTitles,
    titles,
  );
  for (final double value in matrix) {
    if (value > score) score = value;
  }
  return _withAuthor(score, queryAuthors, candidate);
}

double _withAuthor<T>(
  double score,
  List<String> queryAuthors,
  TitleMatchCandidate<T> candidate,
) {
  if (queryAuthors.isEmpty || candidate.authors.isEmpty || score >= 1) {
    return score;
  }
  for (final String author in candidate.authors) {
    final String folded = foldTitleForMatch(author);
    if (folded.isEmpty) continue;
    for (final String q in queryAuthors) {
      if (q == folded) {
        final double boosted = score + kTitleMatchAuthorBonus;
        return boosted > 1 ? 1 : boosted;
      }
    }
  }
  return score;
}
