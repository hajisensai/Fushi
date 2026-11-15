/// Searching a tracking site for a work, in one shape for every site: the
/// manual link dialog of the Tracking page searches through this interface
/// and never asks which site it talks to.
library;

import 'package:fushi_engine/media/tracking/book_tracking_link.dart';
import 'package:fushi_engine/media/tracking/media_tracking_repository.dart';
import 'package:fushi_engine/media/tracking/tracking_provider.dart';

/// One work on a tracking site, as a search result or an id lookup.
final class TrackingSearchHit {
  const TrackingSearchHit({
    required this.subjectId,
    required this.name,
    required this.kind,
    this.altName = '',
    this.year,
    this.episodeCount,
    this.totalChapters,
    this.finalVolume,
    this.isFinished,
    this.book,
  });

  /// A book or manga series ([TrackingBookLinker] result).
  factory TrackingSearchHit.ofBook(TrackingBookSubject book) =>
      TrackingSearchHit(
        subjectId: book.subjectId,
        name: book.name,
        kind: book.kind,
        altName: book.titles.firstWhere(
          (String title) => title.trim().isNotEmpty && title != book.name,
          orElse: () => '',
        ),
        totalChapters: book.totalChapters,
        finalVolume: book.finalVolume,
        isFinished: book.isFinished,
        book: book,
      );

  /// An anime ([TrackingAnimeLinker] result).
  factory TrackingSearchHit.ofAnime(TrackingLinkedSubject anime) =>
      TrackingSearchHit(
        subjectId: anime.subjectId,
        name: anime.name,
        kind: TrackingKind.anime,
        episodeCount: anime.episodeCount,
      );

  final int subjectId;
  final String name;

  /// The site's kind for the work; null when the site does not say.
  final TrackingKind? kind;

  /// Another title of the work (original or romanized); empty when none.
  final String altName;
  final int? year;
  final int? episodeCount;
  final int? totalChapters;
  final int? finalVolume;

  /// Null when the site does not say.
  final bool? isFinished;

  /// The full book subject when the site gave one: a book link then plans its
  /// progress unit from it (`planBookLinkForUser`).
  final TrackingBookSubject? book;
}

/// Optional extra for a [TrackingProvider]: title search and id lookup for
/// any kind it tracks, plus the address of a work's page on the site.
abstract interface class TrackingSubjectSearch {
  /// Works of [kind] matching [query], best first. Throws on network trouble.
  Future<List<TrackingSearchHit>> searchSubjects(
    String query,
    TrackingKind kind,
  );

  /// The site's work [subjectId] when it exists and is of [kind].
  Future<TrackingSearchHit?> subjectById(int subjectId, TrackingKind kind);

  /// The work's page on the site; null when the site's addresses are not
  /// known.
  Uri? subjectPageUrl(int subjectId, TrackingKind kind);
}
