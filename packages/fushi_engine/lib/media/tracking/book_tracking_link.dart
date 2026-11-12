/// Linking a local book or manga to a tracking site (MangaBaka, AniList).
///
/// Order (user decision 2026-11-06):
/// 1. an id another site already gave (MangaBaka ↔ AniList), never a title;
/// 2. a title search, only on the default site for that kind (MangaBaka), then
///    [decideTitleMatch]: sure matches link, close ones become suggestions.
///
/// A title match only links by itself when the progress unit is safe too
/// ([planBookLink]); otherwise it waits for the user as a suggestion.
library;

import 'dart:convert';

import 'package:fushi_core/fushi_core.dart'
    show
        BookFormat,
        EpubBookRow,
        MediaTrackingMappingRow,
        MediaTrackingSuggestionRow;
import 'package:fushi_engine/epub/epub_series.dart';
import 'package:fushi_engine/media/collections/book_series_key.dart';
import 'package:fushi_engine/media/tracking/local_title_clean.dart';
import 'package:fushi_engine/media/tracking/media_tracking_repository.dart';
import 'package:fushi_engine/media/tracking/title_match.dart';
import 'package:fushi_engine/media/video/scraper/title_normalizer.dart';

/// `media_tracking_mappings.link_source` values (v145).
abstract final class TrackingLinkSource {
  /// Picked by the user.
  static const String manual = 'manual';

  /// From an id another source gave (MAL, MangaBaka → AniList).
  static const String id = 'id';

  /// Title match sure enough to link without asking.
  static const String auto = 'auto';

  /// Title match the user approved.
  static const String suggestion = 'suggestion';
}

/// A manga or book series on a tracking site.
final class TrackingBookSubject {
  const TrackingBookSubject({
    required this.subjectId,
    required this.name,
    required this.kind,
    this.titles = const <String>[],
    this.authors = const <String>[],
    this.totalChapters,
    this.finalVolume,
    this.isFinished = false,
    this.linkedIds = const <String, int>{},
  });

  final int subjectId;
  final String name;

  /// [TrackingKind.manga] or [TrackingKind.novel]; null for anything else
  /// (MangaBaka `other`), which never links.
  final TrackingKind? kind;

  /// Every title the site has, [name] included.
  final List<String> titles;
  final List<String> authors;
  final int? totalChapters;
  final int? finalVolume;
  final bool isFinished;

  /// The same series on other sites: provider id → subject id there.
  final Map<String, int> linkedIds;

  /// Facts the review UI shows (stored with a suggestion).
  Map<String, Object?> toDetailsJson() => <String, Object?>{
    'titles': titles,
    if (authors.isNotEmpty) 'authors': authors,
    if (totalChapters != null) 'totalChapters': totalChapters,
    if (finalVolume != null) 'finalVolume': finalVolume,
    'finished': isFinished,
  };
}

/// Optional extra for a [TrackingProvider] that tracks books and manga.
abstract interface class TrackingBookLinker {
  /// Title search limited to [kind]. Throws on network trouble.
  Future<List<TrackingBookSubject>> searchBooks(
    String query,
    TrackingKind kind,
  );

  /// This site's series [subjectId]; null when it does not exist.
  Future<TrackingBookSubject?> bookById(int subjectId);

  /// This site's series for [subjectId] on site [providerId]; null when this
  /// site cannot tell.
  Future<TrackingBookSubject?> bookForLinkedId(
    String providerId,
    int subjectId,
  );
}

/// What the app knows about a book beyond its database row. The app owns
/// these formats (display-title overrides, web novel and online manga
/// descriptors), so it supplies them.
///
/// [displayTitle] = the user's rename, null when none. [extraTitles] = other
/// names the item carries (web novel work title, source series title).
/// [chapterWork] = tracked by chapter (a web novel, an online manga series);
/// false = tracked by volume.
typedef BookLinkHints = ({
  String? displayTitle,
  List<String> extraTitles,
  List<String> authors,
  bool chapterWork,
});

typedef BookLinkHintsResolver =
    Future<BookLinkHints?> Function(EpubBookRow book);

/// The local side of a link: what is searched for and how progress counts.
final class BookLinkSource {
  const BookLinkSource({
    required this.mediaTitle,
    required this.format,
    required this.query,
    this.volume,
    this.chapterWork = false,
    TrackingKind? kind,
  }) : _kind = kind;

  /// Title shown for the link (the display title).
  final String mediaTitle;
  final BookFormat format;
  final TitleMatchQuery query;

  /// Local volume number (whole, ≥ 1); null when unknown.
  final int? volume;

  /// Tracked by chapter (web novel, online manga series).
  final bool chapterWork;

  final TrackingKind? _kind;

  /// The kind searched for and linked as: the one chosen for a PDF (see
  /// [trackingKindsForBookFormat]), else the format's.
  TrackingKind get kind => _kind ?? trackingKindForBookFormat(format);

  /// This source tracked as [kind] (a PDF as manga or novel).
  BookLinkSource withKind(TrackingKind kind) => BookLinkSource(
    mediaTitle: mediaTitle,
    format: format,
    query: query,
    volume: volume,
    chapterWork: chapterWork,
    kind: kind,
  );
}

/// The local side of [book]: titles to search (the user's rename first, then
/// the OPF series name, the app's extra titles, the stored title), authors,
/// and the volume number (OPF series index, else the one in the title).
BookLinkSource buildBookLinkSource(EpubBookRow book, BookLinkHints? hints) {
  final BookFormat format = BookFormat.parseOrEpub(book.format);
  final String raw = book.title.trim();
  final String? rename = hints?.displayTitle?.trim();
  final bool renamed = rename != null && rename.isNotEmpty && rename != raw;
  final EpubSeries? series = decodeEpubSeriesMetadata(book.sourceMetadata);
  final List<String> names = <String>[
    if (renamed) rename,
    if (series != null) series.name,
    ...?hints?.extraTitles,
    raw,
  ];
  final List<String> authors = <String>[
    ...?hints?.authors,
    ...splitBookAuthors(book.author),
    // `[水谷フーカ]` / `[作者：西尾維新]` in a file name is usually the author.
    for (final String name in names) ...bracketedNames(name),
  ];
  final TitleMatchQuery query = TitleMatchQuery.fromLocalTitle(
    names.first,
    extraTitles: <String>[
      ...names.skip(1),
      for (final String name in names) ...titleSpellingVariants(name),
    ],
    authors: authors,
  );
  final bool chapterWork = hints?.chapterWork ?? false;
  return BookLinkSource(
    mediaTitle: renamed ? rename : raw,
    format: format,
    query: query,
    volume: chapterWork
        ? null
        : _wholeVolume(series?.index) ??
              _wholeVolume(parseBookSeriesKey(raw)?.volume) ??
              _wholeVolume(query.volume),
    chapterWork: chapterWork,
  );
}

int? _wholeVolume(num? value) {
  if (value == null || value.isNaN || value.isInfinite) return null;
  if (value < 1 || value != value.roundToDouble()) return null;
  return value.toInt();
}

final RegExp _authorSeparator = RegExp(r'\s*[,、，;；&/]\s*');

/// `"西尾維新, VOFAN"` → both names. Empty for a missing author.
List<String> splitBookAuthors(String? author) => <String>[
  for (final String part in (author ?? '').split(_authorSeparator))
    if (part.trim().isNotEmpty) part.trim(),
];

final RegExp _bracketed = RegExp(r'\[([^\]]*)\]|【([^】]*)】|〔([^〕]*)〕');
final RegExp _authorLabel = RegExp(r'^(?:作者|著者|著|作|author)\s*[:：]\s*');

/// Names in `[]` / `【】` / `〔〕` that look like a person (no digits, short),
/// with an `作者：` label removed. Release tags like `[3574f94a]` are skipped.
List<String> bracketedNames(String title) => <String>[
  for (final RegExpMatch match in _bracketed.allMatches(title))
    if ((match.group(1) ?? match.group(2) ?? match.group(3) ?? '')
            .replaceFirst(_authorLabel, '')
            .trim()
        case final String name
        when name.isNotEmpty &&
            name.runes.length <= 24 &&
            !name.contains(RegExp(r'\d')))
      name,
];

/// Other ways [title] may be written on a tracking site, best first. Sites
/// like MangaBaka match the exact script only, so these are searched too:
/// 1. the parts of a mixed title (`14 Sai no Koi [水谷フーカ] 14歳の恋` →
///    `14 Sai no Koi`, `14歳の恋`), and the title without bracketed names;
/// 2. katakana ↔ hiragana (`ヨツバと!` ↔ `よつばと!`), for titles with kana;
/// 3. Simplified Chinese (`詭秘之主` → `诡秘之主`), for Han titles without kana
///    (Japanese kanji are not Chinese). Uses the title matcher's character
///    table, so only characters it knows change.
///
/// Never contains [title] itself.
List<String> titleSpellingVariants(String title) {
  final String trimmed = title.trim();
  final List<String> out = <String>[];
  void add(String value) {
    final String clean = value.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (clean.isNotEmpty && clean != trimmed && !out.contains(clean)) {
      out.add(clean);
    }
  }

  final String unbracketed = trimmed.replaceAll(_bracketed, ' ');
  final List<String> parts = titleScriptRuns(unbracketed);
  if (parts.length > 1) parts.forEach(add);
  add(unbracketed);

  final List<int> runes = trimmed.runes.toList();
  if (runes.any(isTitleKana)) {
    add(
      String.fromCharCodes(<int>[
        for (final int c in runes) c >= 0x30A1 && c <= 0x30F6 ? c - 0x60 : c,
      ]),
    );
    add(
      String.fromCharCodes(<int>[
        for (final int c in runes) c >= 0x3041 && c <= 0x3096 ? c + 0x60 : c,
      ]),
    );
  } else if (runes.any(isTitleHan)) {
    final List<int> han = runes.where(isTitleHan).toSet().toList();
    final List<String> folded = TitleNormalizer.normalizeAll(<String>[
      for (final int c in han) String.fromCharCode(c),
    ]);
    final Map<int, int> simplified = <int, int>{
      for (int i = 0; i < han.length; i++)
        if (folded[i].runes.length == 1 &&
            isTitleHan(folded[i].runes.first) &&
            folded[i].runes.first != han[i])
          han[i]: folded[i].runes.first,
    };
    if (simplified.isNotEmpty) {
      add(
        String.fromCharCodes(<int>[
          for (final int c in runes) simplified[c] ?? c,
        ]),
      );
    }
  }
  return out;
}

/// How a new link counts progress.
typedef BookLinkPlan = ({TrackingProgressMode mode, int offset});

/// The progress unit for linking [source] to [subject], or null when that is
/// not safe to decide without the user:
/// - chapter works (web novels, online manga) count chapters, unless the local
///   count is past the total of a finished series (numbering differs);
/// - a volume with a known number counts volumes, unless the number is past
///   the last volume of a finished series;
/// - a volume without a number (and every PDF, which counts as one volume)
///   links only to a finished one-volume work; anything else could claim
///   volume 1 of a longer series.
BookLinkPlan? planBookLink({
  required BookLinkSource source,
  required TrackingBookSubject subject,
  int? localChapters,
}) {
  if (source.chapterWork && source.format != BookFormat.pdf) {
    final int? total = subject.totalChapters;
    if (subject.isFinished &&
        total != null &&
        localChapters != null &&
        localChapters > total) {
      return null;
    }
    return (mode: TrackingProgressMode.chapter, offset: 0);
  }
  final int? volume = source.format == BookFormat.pdf ? null : source.volume;
  final int? finalVolume = subject.finalVolume;
  if (volume != null) {
    if (subject.isFinished && finalVolume != null && volume > finalVolume) {
      return null;
    }
    return (mode: TrackingProgressMode.volume, offset: volume);
  }
  if (subject.isFinished && finalVolume == 1) {
    return (mode: TrackingProgressMode.volume, offset: 1);
  }
  return null;
}

/// [subject] as a [decideTitleMatch] candidate for a [kind] item.
TitleMatchCandidate<TrackingBookSubject> titleCandidateOf(
  TrackingBookSubject subject,
  TrackingKind kind,
) => TitleMatchCandidate<TrackingBookSubject>(
  subject: subject,
  id: subject.subjectId,
  titles: <String>[subject.name, ...subject.titles],
  authors: subject.authors,
  kindMatches: subject.kind == kind,
);

/// At most this many title searches per item and attempt (MangaBaka allows
/// 30 searches a minute for everything). The item's own title, then its
/// spellings ([titleSpellingVariants]); stops at the first sure match.
const int kBookLinkMaxSearches = 3;

/// One site's state for one book or manga (the Track sheet).
final class BookTrackingSite {
  const BookTrackingSite({
    required this.providerId,
    required this.connected,
    required this.kindEnabled,
    required this.isDefaultSite,
    this.link,
    this.suggestions = const <MediaTrackingSuggestionRow>[],
  });

  final String providerId;

  /// Signed in.
  final bool connected;

  /// The user's switch for this kind on this site.
  final bool kindEnabled;

  /// The site searched by title for this kind (MangaBaka for books and manga).
  final bool isDefaultSite;
  final MediaTrackingMappingRow? link;

  /// Waiting for the user, best first (not dismissed).
  final List<MediaTrackingSuggestionRow> suggestions;
}

/// Everything the Track sheet shows for one item.
final class BookTrackingOverview {
  const BookTrackingOverview({
    required this.bookKey,
    required this.title,
    required this.searchQuery,
    required this.kind,
    required this.isPrivate,
    required this.sites,
    this.kinds = const <TrackingKind>[],
    this.ignored = false,
    this.series,
    this.seriesIgnored = false,
  });

  final String bookKey;
  final String title;

  /// What the search box starts with: the best clean search term
  /// ([localTitleSearchCandidates]), the same one linking searches first.
  final String searchQuery;

  /// The kind shown and linked as.
  final TrackingKind kind;

  /// Kinds the user may pick from (a PDF: novel or manga); one = no choice.
  final List<TrackingKind> kinds;

  /// Private items are never searched for or sent.
  final bool isPrivate;
  final List<BookTrackingSite> sites;

  /// The book itself is on the do-not-track list.
  final bool ignored;

  /// The series collection the book belongs to (what "Don't track the
  /// series" ignores); null when it is in none.
  final ({int id, String name})? series;

  /// [series] is on the do-not-track list (covers this book).
  final bool seriesIgnored;
}

/// [suggestion] as a subject (from its stored details).
TrackingBookSubject subjectOfSuggestion(MediaTrackingSuggestionRow suggestion) {
  Map<String, dynamic> details = const <String, dynamic>{};
  try {
    final Object? decoded = jsonDecode(suggestion.detailsJson);
    if (decoded is Map<String, dynamic>) details = decoded;
  } on FormatException {
    // Keep the defaults: the id and name are enough to link.
  }
  List<String> strings(String key) => <String>[
    if (details[key] case final List<dynamic> values)
      for (final Object? value in values)
        if (value is String) value,
  ];
  int? number(String key) => (details[key] as num?)?.toInt();
  return TrackingBookSubject(
    subjectId: suggestion.subjectId,
    name: suggestion.subjectName,
    kind: TrackingKind.values
        .where((TrackingKind k) => k.value == suggestion.subjectKind)
        .firstOrNull,
    titles: strings('titles'),
    authors: strings('authors'),
    totalChapters: number('totalChapters'),
    finalVolume: number('finalVolume'),
    isFinished: details['finished'] == true,
  );
}

/// A subject id typed or pasted by the user: a plain number, or a link to
/// the site, whose pages are on [siteHost] or a subdomain of it
/// (`https://example.org/manga/44893/...`). Null when it is neither (a
/// title). With an empty [siteHost] only plain numbers are understood.
int? parseTrackingSubjectInput(String siteHost, String input) {
  final String text = input.trim();
  final int? plain = int.tryParse(text);
  if (plain != null) return plain > 0 ? plain : null;
  if (siteHost.isEmpty) return null;
  final Uri? uri = Uri.tryParse(text);
  if (uri == null ||
      !uri.hasScheme ||
      !(uri.host == siteHost || uri.host.endsWith('.$siteHost'))) {
    return null;
  }
  for (final String segment in uri.pathSegments) {
    final int? id = int.tryParse(segment);
    if (id != null && id > 0) return id;
  }
  return null;
}

/// The progress unit when the user picks [subject] themselves: the safe plan
/// when there is one, else chapters for chapter works and the known volume,
/// else volume 1 (one book = one volume). The user can change the volume.
BookLinkPlan planBookLinkForUser({
  required BookLinkSource source,
  required TrackingBookSubject subject,
  int? localChapters,
}) =>
    planBookLink(
      source: source,
      subject: subject,
      localChapters: localChapters,
    ) ??
    (source.chapterWork && source.format != BookFormat.pdf
        ? (mode: TrackingProgressMode.chapter, offset: 0)
        : (
            mode: TrackingProgressMode.volume,
            offset: source.format == BookFormat.pdf ? 1 : source.volume ?? 1,
          ));
