/// Library module of the companion (the Library tab, S5): the values that
/// cross between the main engine (`companion_library_service.dart`, built on
/// the main app's own providers, repositories and media-server clients) and
/// the panel's Browse / Main modes. Pure Dart.
///
/// All reads, writes and "open" run in the MAIN process: the panel never
/// touches the database or the network itself (see the S5 notes in the
/// progress log for why the companion does not read the Drift file).
///
/// Requests (`CompanionRequestMethods.library*`):
/// - `library.home` `{}` → [CompanionLibraryHome] (Continue rows, Recently
///   added).
/// - `library.list` `{section, parent?, query?, offset, limit}` →
///   [CompanionLibraryPage]. `parent` is the [CompanionLibraryItem.ref] of a
///   container (a collection, an album, a server, a server library); without
///   it the section's top level. `query` filters this list only.
/// - `library.search` `{query, offset, limit}` → [CompanionLibraryPage] over
///   every local section (Browse's "Search everything").
/// - `library.details` `{ref}` → [CompanionLibraryDetails].
/// - `library.open` `{ref, entry?}` → [CompanionLibraryOpenResult]: opens the
///   item (or one of its [CompanionLibraryEntry]s) on the main screen through
///   the same path the library cards use; the item open on top before is
///   closed the normal way (it saves its place) and comes back as
///   [CompanionLibraryOpenResult.previous].
/// - `library.markFinished` `{ref, finished}` → the re-read
///   [CompanionLibraryItem] (existing main-process write paths only).
/// - `library.cover` `{ref}` → a local image file path or null: covers that
///   are not local files yet (media servers) are fetched by the MAIN app's
///   existing clients / image caches.
/// - `library.openOnMain` `{target}` ([CompanionLibraryMainTarget]) → null.
///
/// Main mode: the library page on top claims `CompanionContextKind.library`
/// and publishes a [CompanionLibraryMainSnapshot]; the panel sends
/// [CompanionLibraryMainActions] commands that the page runs on its own
/// state (its search field, sort and filters).
///
/// The main engine pings `libraryChanged` (`session.libraryRevision`) when
/// library data changes: visible lists reload.
library;

import 'package:meta/meta.dart';

import 'package:fushi/src/second_screen/companion/companion_snapshot.dart';

/// Argument keys of the library requests.
abstract final class CompanionLibraryArgs {
  static const String section = 'section';
  static const String parent = 'parent';
  static const String query = 'query';
  static const String offset = 'offset';
  static const String limit = 'limit';
  static const String ref = 'ref';
  static const String entry = 'entry';
  static const String finished = 'finished';
  static const String target = 'target';

  /// Page size the panel asks for.
  static const int pageSize = 40;

  /// The main engine never returns more than this per page.
  static const int maxPageSize = 100;
}

/// Browse sections (the chip row).
enum CompanionLibrarySection {
  home,
  books,
  manga,
  video,
  audiobooks,
  music,

  /// Configured media servers (Jellyfin / Plex / Audiobookshelf / Kavita).
  servers;

  String get wire => name;

  static CompanionLibrarySection fromWire(Object? value) {
    for (final CompanionLibrarySection s in CompanionLibrarySection.values) {
      if (s.wire == value) return s;
    }
    return home;
  }
}

/// What a library item is. Decides the details layout and what "open" does.
enum CompanionLibraryItemKind {
  book,
  manga,
  video,
  audiobook,
  musicAlbum,
  musicTrack,
  musicArtist,
  musicPlaylist,

  /// A local collection / series (opens a list).
  collection,

  /// A configured media server (opens its libraries).
  server,

  /// One library of a media server (opens its items).
  serverLibrary,

  /// A media server item that opens a list (series, season, folder).
  serverFolder,

  /// A playable / readable media server item.
  serverItem,

  /// Not browsable here: shown with "Open on main screen"
  /// ([CompanionLibraryItem.mainTarget]).
  mainOnly;

  String get wire => name;

  /// Tapping it opens a list instead of a details page.
  bool get isContainer => switch (this) {
    musicArtist ||
    musicPlaylist ||
    collection ||
    server ||
    serverLibrary ||
    serverFolder => true,
    book ||
    manga ||
    video ||
    audiobook ||
    musicAlbum ||
    musicTrack ||
    serverItem ||
    mainOnly => false,
  };

  static CompanionLibraryItemKind fromWire(Object? value) {
    for (final CompanionLibraryItemKind k in CompanionLibraryItemKind.values) {
      if (k.wire == value) return k;
    }
    return mainOnly;
  }
}

/// Item references (`<kind>:<key>`), opaque to the panel. The key is the
/// identifier the main app's own data model uses, so the main engine can find
/// the item again without a lookup table:
/// - `book:` / `manga:` / `audiobook:` → `MediaItem.mediaIdentifier`
///   (`ReaderFushiSource` / `MangaFushiSource` items).
/// - `video:` → `VideoBooks.bookUid`; `collection:video/<collectionId>` for a
///   video collection (`collection:<section>/<id>` in general).
/// - `musicAlbum:` → `MusicAlbumRow.albumUid`, `musicTrack:` →
///   `MusicTrackRow.trackUid`, `musicArtist:` / `musicPlaylist:` → their row
///   ids.
/// - `server:<serverKey>`, `serverLibrary:<serverKey>/<libraryId>`,
///   `serverFolder:` / `serverItem:<serverKey>/<itemId>` (serverKey = the
///   main app's configured-server id, prefixed with its type, e.g.
///   `jellyfin.<id>`).
/// - `mainOnly:<CompanionLibraryMainTarget.wire>`.
abstract final class CompanionLibraryRef {
  static String of(CompanionLibraryItemKind kind, String key) =>
      '${kind.wire}:$key';

  static String book(String mediaIdentifier) =>
      of(CompanionLibraryItemKind.book, mediaIdentifier);
  static String manga(String mediaIdentifier) =>
      of(CompanionLibraryItemKind.manga, mediaIdentifier);
  static String audiobook(String mediaIdentifier) =>
      of(CompanionLibraryItemKind.audiobook, mediaIdentifier);
  static String video(String bookUid) =>
      of(CompanionLibraryItemKind.video, bookUid);
  static String collection(CompanionLibrarySection section, String id) =>
      of(CompanionLibraryItemKind.collection, '${section.wire}/$id');
  static String musicAlbum(String albumUid) =>
      of(CompanionLibraryItemKind.musicAlbum, albumUid);
  static String musicTrack(String trackUid) =>
      of(CompanionLibraryItemKind.musicTrack, trackUid);

  /// The kind part; null when [ref] is malformed.
  static CompanionLibraryItemKind? kindOf(String ref) {
    final int i = ref.indexOf(':');
    if (i <= 0) return null;
    final String wire = ref.substring(0, i);
    for (final CompanionLibraryItemKind k in CompanionLibraryItemKind.values) {
      if (k.wire == wire) return k;
    }
    return null;
  }

  /// The key part ('' when [ref] is malformed).
  static String keyOf(String ref) {
    final int i = ref.indexOf(':');
    return i <= 0 ? '' : ref.substring(i + 1);
  }
}

/// Pages the companion cannot show itself: "Open on main screen".
enum CompanionLibraryMainTarget {
  /// Online manga sources (Mihon-style extensions).
  onlineManga,

  /// Online video sources (Aniyomi-style extensions).
  onlineVideo,

  /// Online novel sources (LNReader-style plugins).
  onlineNovels,
  statistics,
  dictionaries,

  /// The library tab of the section on top (e.g. a library the companion
  /// does not browse, such as games).
  libraryTab;

  String get wire => name;

  static CompanionLibraryMainTarget? fromWire(Object? value) {
    for (final CompanionLibraryMainTarget t
        in CompanionLibraryMainTarget.values) {
      if (t.wire == value) return t;
    }
    return null;
  }
}

/// One tile / row of a library list.
@immutable
class CompanionLibraryItem {
  const CompanionLibraryItem({
    required this.ref,
    required this.kind,
    required this.title,
    this.subtitle,
    this.progress,
    this.progressLabel,
    this.coverPath,
    this.hasRemoteCover = false,
    this.finished = false,
    this.count,
    this.mainTarget,
  });

  factory CompanionLibraryItem.fromJson(Map<String, Object?> json) =>
      CompanionLibraryItem(
        ref: json.str('ref'),
        kind: CompanionLibraryItemKind.fromWire(json['kind']),
        title: json.str('title'),
        subtitle: json.strOrNull('subtitle'),
        progress: json.doubleOrNull('progress'),
        progressLabel: json.strOrNull('progressLabel'),
        coverPath: json.strOrNull('coverPath'),
        hasRemoteCover: json.flag('hasRemoteCover'),
        finished: json.flag('finished'),
        count: json.intOrNull('count'),
        mainTarget: CompanionLibraryMainTarget.fromWire(json['mainTarget']),
      );

  final String ref;
  final CompanionLibraryItemKind kind;
  final String title;

  /// Author / artist / series line.
  final String? subtitle;

  /// 0..1 when the item has a saved position.
  final double? progress;

  /// Localized by the main engine ("p. 37", "E7", "62%").
  final String? progressLabel;

  /// A local image file both processes can read.
  final String? coverPath;

  /// No local file yet, but `library.cover` can produce one.
  final bool hasRemoteCover;
  final bool finished;

  /// Children of a container (episodes, tracks, items) when known.
  final int? count;

  /// Only for [CompanionLibraryItemKind.mainOnly].
  final CompanionLibraryMainTarget? mainTarget;

  Map<String, Object?> toJson() => <String, Object?>{
    'ref': ref,
    'kind': kind.wire,
    'title': title,
    if (subtitle != null) 'subtitle': subtitle,
    if (progress != null) 'progress': progress,
    if (progressLabel != null) 'progressLabel': progressLabel,
    if (coverPath != null) 'coverPath': coverPath,
    if (hasRemoteCover) 'hasRemoteCover': true,
    if (finished) 'finished': true,
    if (count != null) 'count': count,
    if (mainTarget != null) 'mainTarget': mainTarget!.wire,
  };

  @override
  bool operator ==(Object other) =>
      other is CompanionLibraryItem &&
      other.ref == ref &&
      other.kind == kind &&
      other.title == title &&
      other.subtitle == subtitle &&
      other.progress == progress &&
      other.progressLabel == progressLabel &&
      other.coverPath == coverPath &&
      other.hasRemoteCover == hasRemoteCover &&
      other.finished == finished &&
      other.count == count &&
      other.mainTarget == mainTarget;

  @override
  int get hashCode => Object.hash(
    ref,
    kind,
    title,
    subtitle,
    progress,
    progressLabel,
    coverPath,
    hasRemoteCover,
    finished,
    count,
    mainTarget,
  );
}

List<CompanionLibraryItem> _items(Map<String, Object?> json, String key) =>
    <CompanionLibraryItem>[
      for (final Map<String, Object?> m in json.maps(key))
        CompanionLibraryItem.fromJson(m),
    ];

/// One page of a list.
@immutable
class CompanionLibraryPage {
  const CompanionLibraryPage({
    required this.items,
    this.offset = 0,
    this.total,
    this.hasMore = false,
    this.title,
    this.nextOffset,
  });

  factory CompanionLibraryPage.fromJson(Map<String, Object?> json) =>
      CompanionLibraryPage(
        items: _items(json, 'items'),
        offset: json.integer('offset'),
        total: json.intOrNull('total'),
        hasMore: json.flag('hasMore'),
        title: json.strOrNull('title'),
        nextOffset: json.intOrNull('nextOffset'),
      );

  final List<CompanionLibraryItem> items;
  final int offset;

  /// Null when the source does not know (servers paging by cursor).
  final int? total;
  final bool hasMore;

  /// The container's title (for a `parent` list).
  final String? title;

  /// The `offset` to ask for next when it is not `offset + items.length`:
  /// media servers page by server rows (rows the app filters out still count)
  /// and Audiobookshelf by whole pages. Null = `offset + items.length`.
  final int? nextOffset;

  /// The offset of the next page ([nextOffset] or `offset + items.length`).
  int get followingOffset => nextOffset ?? offset + items.length;

  Map<String, Object?> toJson() => <String, Object?>{
    'items': <Map<String, Object?>>[
      for (final CompanionLibraryItem i in items) i.toJson(),
    ],
    'offset': offset,
    if (total != null) 'total': total,
    if (hasMore) 'hasMore': true,
    if (title != null) 'title': title,
    if (nextOffset != null) 'nextOffset': nextOffset,
  };
}

/// Rows of Browse's Home.
enum CompanionLibraryHomeRowKind {
  /// Everything in progress, newest first (books, manga, video, audiobooks).
  continueItems,

  /// In progress on a media server (the home dashboard's server continue).
  continueServer,
  recentlyAdded;

  String get wire => name;

  static CompanionLibraryHomeRowKind fromWire(Object? value) {
    for (final CompanionLibraryHomeRowKind k
        in CompanionLibraryHomeRowKind.values) {
      if (k.wire == value) return k;
    }
    return recentlyAdded;
  }
}

@immutable
class CompanionLibraryHomeRow {
  const CompanionLibraryHomeRow({required this.kind, required this.items});

  factory CompanionLibraryHomeRow.fromJson(Map<String, Object?> json) =>
      CompanionLibraryHomeRow(
        kind: CompanionLibraryHomeRowKind.fromWire(json['kind']),
        items: _items(json, 'items'),
      );

  final CompanionLibraryHomeRowKind kind;
  final List<CompanionLibraryItem> items;

  Map<String, Object?> toJson() => <String, Object?>{
    'kind': kind.wire,
    'items': <Map<String, Object?>>[
      for (final CompanionLibraryItem i in items) i.toJson(),
    ],
  };
}

/// Browse's Home: only non-empty rows, in display order. [sections] are the
/// sections whose module is enabled (the chip row hides the others).
@immutable
class CompanionLibraryHome {
  const CompanionLibraryHome({required this.rows, required this.sections});

  factory CompanionLibraryHome.fromJson(Map<String, Object?> json) =>
      CompanionLibraryHome(
        rows: <CompanionLibraryHomeRow>[
          for (final Map<String, Object?> m in json.maps('rows'))
            CompanionLibraryHomeRow.fromJson(m),
        ],
        sections: <CompanionLibrarySection>[
          for (final String s in json.strings('sections'))
            CompanionLibrarySection.fromWire(s),
        ],
      );

  final List<CompanionLibraryHomeRow> rows;
  final List<CompanionLibrarySection> sections;

  Map<String, Object?> toJson() => <String, Object?>{
    'rows': <Map<String, Object?>>[
      for (final CompanionLibraryHomeRow r in rows) r.toJson(),
    ],
    'sections': <String>[
      for (final CompanionLibrarySection s in sections) s.wire,
    ],
  };
}

/// A chapter / episode / track of a details page.
@immutable
class CompanionLibraryEntry {
  const CompanionLibraryEntry({
    required this.id,
    required this.title,
    this.subtitle,
    this.progress,
    this.finished = false,
    this.current = false,
  });

  factory CompanionLibraryEntry.fromJson(Map<String, Object?> json) =>
      CompanionLibraryEntry(
        id: json.str('id'),
        title: json.str('title'),
        subtitle: json.strOrNull('subtitle'),
        progress: json.doubleOrNull('progress'),
        finished: json.flag('finished'),
        current: json.flag('current'),
      );

  /// Passed back as `library.open {ref, entry}`.
  final String id;
  final String title;

  /// Localized status / length ("Watched", "6:20 in", "24 min").
  final String? subtitle;
  final double? progress;
  final bool finished;

  /// Where Continue resumes.
  final bool current;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'title': title,
    if (subtitle != null) 'subtitle': subtitle,
    if (progress != null) 'progress': progress,
    if (finished) 'finished': true,
    if (current) 'current': true,
  };
}

/// A labelled fact of a details page ("Studio", "Year", "Narrator").
@immutable
class CompanionLibraryFact {
  const CompanionLibraryFact({required this.label, required this.value});

  factory CompanionLibraryFact.fromJson(Map<String, Object?> json) =>
      CompanionLibraryFact(label: json.str('label'), value: json.str('value'));

  /// Localized by the main engine.
  final String label;
  final String value;

  Map<String, Object?> toJson() => <String, Object?>{
    'label': label,
    'value': value,
  };
}

/// An item's details: cached data only, missing values are null / empty and
/// the panel hides their rows.
@immutable
class CompanionLibraryDetails {
  const CompanionLibraryDetails({
    required this.item,
    this.author,
    this.description,
    this.genres = const <String>[],
    this.rating,
    this.ratingVotes,
    this.year,
    this.facts = const <CompanionLibraryFact>[],
    this.entries = const <CompanionLibraryEntry>[],
    this.entriesLabel,
    this.continueLabel,
    this.canOpen = true,
    this.canMarkFinished = false,
  });

  factory CompanionLibraryDetails.fromJson(Map<String, Object?> json) =>
      CompanionLibraryDetails(
        item: CompanionLibraryItem.fromJson(
          json.mapOrNull('item') ?? const <String, Object?>{},
        ),
        author: json.strOrNull('author'),
        description: json.strOrNull('description'),
        genres: json.strings('genres'),
        rating: json.doubleOrNull('rating'),
        ratingVotes: json.intOrNull('ratingVotes'),
        year: json.intOrNull('year'),
        facts: <CompanionLibraryFact>[
          for (final Map<String, Object?> m in json.maps('facts'))
            CompanionLibraryFact.fromJson(m),
        ],
        entries: <CompanionLibraryEntry>[
          for (final Map<String, Object?> m in json.maps('entries'))
            CompanionLibraryEntry.fromJson(m),
        ],
        entriesLabel: json.strOrNull('entriesLabel'),
        continueLabel: json.strOrNull('continueLabel'),
        canOpen: json['canOpen'] != false,
        canMarkFinished: json.flag('canMarkFinished'),
      );

  final CompanionLibraryItem item;
  final String? author;
  final String? description;
  final List<String> genres;

  /// 0..10 as the source gives it (cached metadata / Bangumi scrape).
  final double? rating;
  final int? ratingVotes;
  final int? year;
  final List<CompanionLibraryFact> facts;

  /// At most [CompanionLibraryArgs.maxPageSize] around the current one.
  final List<CompanionLibraryEntry> entries;

  /// Localized heading of [entries] ("Chapters", "Episodes", "Tracks").
  final String? entriesLabel;

  /// Localized Continue button ("Continue E4 on top"); null = "Open on top".
  final String? continueLabel;
  final bool canOpen;
  final bool canMarkFinished;

  Map<String, Object?> toJson() => <String, Object?>{
    'item': item.toJson(),
    if (author != null) 'author': author,
    if (description != null) 'description': description,
    if (genres.isNotEmpty) 'genres': genres,
    if (rating != null) 'rating': rating,
    if (ratingVotes != null) 'ratingVotes': ratingVotes,
    if (year != null) 'year': year,
    if (facts.isNotEmpty)
      'facts': <Map<String, Object?>>[
        for (final CompanionLibraryFact f in facts) f.toJson(),
      ],
    if (entries.isNotEmpty)
      'entries': <Map<String, Object?>>[
        for (final CompanionLibraryEntry e in entries) e.toJson(),
      ],
    if (entriesLabel != null) 'entriesLabel': entriesLabel,
    if (continueLabel != null) 'continueLabel': continueLabel,
    if (!canOpen) 'canOpen': false,
    if (canMarkFinished) 'canMarkFinished': true,
  };
}

/// The reply of `library.open`.
@immutable
class CompanionLibraryOpenResult {
  const CompanionLibraryOpenResult({required this.opened, this.previous});

  factory CompanionLibraryOpenResult.fromJson(Map<String, Object?> json) {
    final Map<String, Object?>? prev = json.mapOrNull('previous');
    return CompanionLibraryOpenResult(
      opened: json.flag('opened'),
      previous: prev == null ? null : CompanionLibraryItem.fromJson(prev),
    );
  }

  /// False when the item no longer exists / cannot open (the panel says so).
  final bool opened;

  /// What was open on top before (it saved its place); the panel offers
  /// "Back to <title>" (`library.open {ref: previous.ref}`) for a while.
  final CompanionLibraryItem? previous;

  Map<String, Object?> toJson() => <String, Object?>{
    'opened': opened,
    if (previous != null) 'previous': previous!.toJson(),
  };
}

// ---------------------------------------------------------------------------
// Main mode (the library page on top)
// ---------------------------------------------------------------------------

/// Commands the panel sends to the library page on top
/// (`session.command(action, args)`, kind `library`).
abstract final class CompanionLibraryMainActions {
  /// `{query}`: the page's own search ('' clears it).
  static const String search = 'search';

  /// `{id}`: one of [CompanionLibraryMainSnapshot.sorts].
  static const String sort = 'sort';

  /// `{id, selected}`: one of [CompanionLibraryMainSnapshot.filters].
  static const String filter = 'filter';

  /// `{}`: open / continue the highlighted item on top (the same action as
  /// activating the card).
  static const String openHighlighted = 'openHighlighted';

  static const String argQuery = 'query';
  static const String argId = 'id';
  static const String argSelected = 'selected';
}

/// A sort or filter choice of the page on top (labels localized by the main
/// engine, ids are the page's own option names).
@immutable
class CompanionLibraryOption {
  const CompanionLibraryOption({
    required this.id,
    required this.label,
    this.selected = false,
  });

  factory CompanionLibraryOption.fromJson(Map<String, Object?> json) =>
      CompanionLibraryOption(
        id: json.str('id'),
        label: json.str('label'),
        selected: json.flag('selected'),
      );

  final String id;
  final String label;
  final bool selected;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'label': label,
    if (selected) 'selected': true,
  };

  @override
  bool operator ==(Object other) =>
      other is CompanionLibraryOption &&
      other.id == id &&
      other.label == label &&
      other.selected == selected;

  @override
  int get hashCode => Object.hash(id, label, selected);
}

/// The snapshot a library page on top publishes.
@immutable
class CompanionLibraryMainSnapshot {
  const CompanionLibraryMainSnapshot({
    this.highlighted,
    this.query = '',
    this.searchable = true,
    this.sorts = const <CompanionLibraryOption>[],
    this.filters = const <CompanionLibraryOption>[],
    this.itemCount,
  });

  factory CompanionLibraryMainSnapshot.fromJson(Map<String, Object?> json) {
    final Map<String, Object?>? h = json.mapOrNull('highlighted');
    return CompanionLibraryMainSnapshot(
      highlighted: h == null ? null : CompanionLibraryItem.fromJson(h),
      query: json.str('query'),
      searchable: json['searchable'] != false,
      sorts: <CompanionLibraryOption>[
        for (final Map<String, Object?> m in json.maps('sorts'))
          CompanionLibraryOption.fromJson(m),
      ],
      filters: <CompanionLibraryOption>[
        for (final Map<String, Object?> m in json.maps('filters'))
          CompanionLibraryOption.fromJson(m),
      ],
      itemCount: json.intOrNull('itemCount'),
    );
  }

  /// The item focused / long-pressed / selected on top; null = none.
  final CompanionLibraryItem? highlighted;

  /// The page's current search text.
  final String query;

  /// The page has a search the panel can drive.
  final bool searchable;

  /// Exactly one selected when not empty.
  final List<CompanionLibraryOption> sorts;
  final List<CompanionLibraryOption> filters;

  /// Items the page shows after search / filter, when known.
  final int? itemCount;

  Map<String, Object?> toJson() => <String, Object?>{
    if (highlighted != null) 'highlighted': highlighted!.toJson(),
    'query': query,
    if (!searchable) 'searchable': false,
    'sorts': <Map<String, Object?>>[
      for (final CompanionLibraryOption o in sorts) o.toJson(),
    ],
    'filters': <Map<String, Object?>>[
      for (final CompanionLibraryOption o in filters) o.toJson(),
    ],
    if (itemCount != null) 'itemCount': itemCount,
  };
}
