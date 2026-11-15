/// The companion's Library tab (S5), answered in the MAIN process: the
/// `library.*` requests of `modules/library_companion_schema.dart`.
///
/// Why the panel does not read the Drift database itself (decision of S5):
/// - the main app's providers already derive titles, progress, completion and
///   the "continue" rules; reading the tables again in the panel would copy
///   that logic and drift from it;
/// - media servers (Jellyfin / Plex / Audiobookshelf) can only be reached
///   through the main app's clients anyway (tokens, shared ABS instance,
///   pinned image caches);
/// - the panel process's database connection (popup AppModel,
///   `FushiDatabase(isMainProcess: false)`) is a full read-write connection:
///   "read-only" would only be a convention, while adding a second reader of
///   every library table.
/// So the panel asks over the request / reply bridge and this service answers
/// from the main app's own data ([CompanionLibraryData]; the real adapter is
/// `companion_library_app_data.dart`). Writes ("mark finished") and "open"
/// use the library's own main-process paths.
library;

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/media_search_text.dart';
import 'package:fushi/src/second_screen/companion/companion_bridge.dart';
import 'package:fushi/src/second_screen/companion/companion_protocol.dart';
import 'package:fushi/src/second_screen/companion/modules/library_companion_schema.dart';

/// Rows of Browse's Home and the at-most size of each.
const int kCompanionLibraryHomeRowLimit = 12;

/// One library entry as the main app knows it (a book, a video, an album, a
/// server, ...). [kind] + [key] form the wire ref ([CompanionLibraryRef]).
class CompanionLibraryRecord {
  const CompanionLibraryRecord({
    required this.kind,
    required this.key,
    required this.title,
    this.subtitle,
    this.progress,
    this.progressLabel,
    this.finished = false,
    this.recentAt = 0,
    this.addedAt = 0,
    this.collectionId,
    this.sortIndex,
    this.count,
    this.searchTitles = const <String>[],
    this.coverPath,
    this.resolveCover,
    this.hasRemoteCover = false,
    this.mainTarget,
  });

  final CompanionLibraryItemKind kind;
  final String key;
  final String title;
  final String? subtitle;
  final double? progress;
  final String? progressLabel;
  final bool finished;

  /// Last activity (epoch ms), 0 = never.
  final int recentAt;

  /// When it entered the library (epoch ms), 0 = unknown.
  final int addedAt;

  /// The collection / series it is folded into on the library page (local
  /// sections only); null = shown on its own.
  final int? collectionId;

  /// Position inside [collectionId] (episode order).
  final int? sortIndex;
  final int? count;

  /// Other names the library search matches (original title, file name).
  final List<String> searchTitles;

  /// An already known local cover file.
  final String? coverPath;

  /// Looks the cover file up; only run for items on the requested page
  /// (cover probing is I/O, possibly on a network drive, BUG-3756).
  final Future<String?> Function()? resolveCover;
  final bool hasRemoteCover;
  final CompanionLibraryMainTarget? mainTarget;

  String get ref => CompanionLibraryRef.of(kind, key);

  /// Most recent of activity / adding (library order).
  int get recency => recentAt > addedAt ? recentAt : addedAt;

  CompanionLibraryItem toItem({String? coverPath}) => CompanionLibraryItem(
    ref: ref,
    kind: kind,
    title: title,
    subtitle: _text(subtitle),
    progress: progress,
    progressLabel: _text(progressLabel),
    coverPath: _text(coverPath ?? this.coverPath),
    hasRemoteCover: hasRemoteCover,
    finished: finished,
    count: count,
    mainTarget: mainTarget,
  );
}

/// A local collection / series of a section (video collections, book and
/// manga series).
class CompanionLibraryCollection {
  const CompanionLibraryCollection({
    required this.section,
    required this.id,
    required this.title,
    this.resolveCover,
  });

  final CompanionLibrarySection section;
  final int id;
  final String title;
  final Future<String?> Function()? resolveCover;

  String get key => '${section.wire}/$id';
}

/// The local music library ([CompanionLibraryData.music]).
class CompanionMusicLibrary {
  const CompanionMusicLibrary({
    this.albums = const <CompanionLibraryRecord>[],
    this.artists = const <CompanionLibraryRecord>[],
    this.playlists = const <CompanionLibraryRecord>[],
    this.tracks = const <CompanionLibraryRecord>[],
  });

  final List<CompanionLibraryRecord> albums;
  final List<CompanionLibraryRecord> artists;
  final List<CompanionLibraryRecord> playlists;
  final List<CompanionLibraryRecord> tracks;
}

/// Groups of the Music section's top level (`collection:music/<group>`).
enum CompanionMusicGroup {
  albums,
  artists,
  playlists,
  tracks;

  static CompanionMusicGroup? fromWire(String value) {
    for (final CompanionMusicGroup g in values) {
      if (g.name == value) return g;
    }
    return null;
  }
}

/// What a details page lists.
enum CompanionEntriesKind { chapters, episodes, tracks, items }

/// One chapter / episode / track before labelling.
class CompanionEntrySource {
  const CompanionEntrySource({
    required this.id,
    required this.title,
    this.number,
    this.positionMs = 0,
    this.durationMs,
    this.runtimeMinutes,
    this.finished = false,
    this.current = false,
  });

  final String id;
  final String title;

  /// Episode number (shown as `E<n>`), when known.
  final int? number;
  final int positionMs;
  final int? durationMs;
  final int? runtimeMinutes;
  final bool finished;
  final bool current;
}

/// Cached facts of an item; [CompanionLibraryService.details] labels them.
/// Missing = null / empty (the panel hides the row).
class CompanionDetailsSource {
  const CompanionDetailsSource({
    required this.record,
    this.author,
    this.description,
    this.genres = const <String>[],
    this.rating,
    this.ratingVotes,
    this.year,
    this.originalTitle,
    this.runtimeMinutes,
    this.narrator,
    this.series,
    this.released,
    this.cast = const <String>[],
    this.entriesKind,
    this.entries = const <CompanionEntrySource>[],
    this.canOpen = true,
    this.canMarkFinished = false,
  });

  final CompanionLibraryRecord record;
  final String? author;
  final String? description;
  final List<String> genres;
  final double? rating;
  final int? ratingVotes;
  final int? year;
  final String? originalTitle;
  final int? runtimeMinutes;
  final String? narrator;
  final String? series;
  final String? released;
  final List<String> cast;
  final CompanionEntriesKind? entriesKind;
  final List<CompanionEntrySource> entries;
  final bool canOpen;
  final bool canMarkFinished;
}

/// The main app's library as the companion sees it. The real implementation
/// (`AppCompanionLibraryData`) reads the main app's providers, repositories
/// and media-server clients and opens items through the library's own paths;
/// tests use a fake.
abstract interface class CompanionLibraryData {
  /// The section's module is enabled (and it exists on this platform).
  bool isSectionEnabled(CompanionLibrarySection section);

  /// "Open on main screen" entries appended to a section's top level (online
  /// sources that exist on this platform and are enabled).
  List<CompanionLibraryMainTarget> onlineTargets(
    CompanionLibrarySection section,
  );

  /// Local books, manga and audiobooks ([CompanionLibraryItemKind.book],
  /// `manga`, `audiobook`).
  Future<List<CompanionLibraryRecord>> books();

  /// Local videos.
  Future<List<CompanionLibraryRecord>> videos();

  /// The collections / series of a local section.
  Future<List<CompanionLibraryCollection>> collections(
    CompanionLibrarySection section,
  );

  Future<CompanionMusicLibrary> music();

  /// Tracks of an artist / a playlist ref; null = gone.
  Future<({String title, List<CompanionLibraryRecord> tracks})?> musicChildren(
    String ref,
  );

  /// In progress (books, manga, audiobooks, videos), any order.
  Future<List<CompanionLibraryRecord>> continueRecords();

  /// The home dashboard's media-server continue feed as already loaded
  /// (no request of its own).
  List<CompanionLibraryRecord> continueServer();

  /// Configured media servers (top level of the Servers section).
  Future<List<CompanionLibraryRecord>> servers();

  /// A page of a server / server library / server folder.
  Future<CompanionLibraryPage> serverChildren(
    String parentRef, {
    required String query,
    required int offset,
    required int limit,
  });

  /// Cached details; null = gone. Also asked for local collections (series
  /// details with their episodes / volumes).
  Future<CompanionDetailsSource?> details(String ref);

  /// A local cover file for [ref], fetching remote covers through the main
  /// app's clients / image caches; null = none.
  Future<String?> cover(String ref);

  /// The item open on top (book, manga, video, ...) as a ref `open` accepts.
  Future<CompanionLibraryRecord?> currentTop();

  /// Leaves whatever is open on top the normal way (its close path saves the
  /// place) and stops at the home route. False = something refused to close.
  Future<bool> returnToHome();

  /// Opens [ref] (at [entry] when given and supported) the way the library
  /// cards do; false = gone / cannot open. A local collection opens its
  /// Continue member (or [entry], a member ref key).
  Future<bool> open(String ref, {String? entry});

  /// The library's own "mark finished / watched" write; false = not
  /// supported for this item.
  Future<bool> setFinished(String ref, {required bool finished});

  Future<void> openOnMain(CompanionLibraryMainTarget target);
}

/// Answers the `library.*` requests from [CompanionLibraryData].
class CompanionLibraryService {
  CompanionLibraryService(this._data);

  final CompanionLibraryData _data;

  static const List<CompanionLibrarySection> _localSections =
      <CompanionLibrarySection>[
        CompanionLibrarySection.books,
        CompanionLibrarySection.manga,
        CompanionLibrarySection.video,
        CompanionLibrarySection.audiobooks,
      ];

  /// The section a local item kind belongs to.
  static CompanionLibrarySection? sectionOf(CompanionLibraryItemKind kind) =>
      switch (kind) {
        CompanionLibraryItemKind.book => CompanionLibrarySection.books,
        CompanionLibraryItemKind.manga => CompanionLibrarySection.manga,
        CompanionLibraryItemKind.audiobook =>
          CompanionLibrarySection.audiobooks,
        CompanionLibraryItemKind.video => CompanionLibrarySection.video,
        CompanionLibraryItemKind.musicAlbum ||
        CompanionLibraryItemKind.musicTrack ||
        CompanionLibraryItemKind.musicArtist ||
        CompanionLibraryItemKind.musicPlaylist => CompanionLibrarySection.music,
        CompanionLibraryItemKind.server ||
        CompanionLibraryItemKind.serverLibrary ||
        CompanionLibraryItemKind.serverFolder ||
        CompanionLibraryItemKind.serverItem => CompanionLibrarySection.servers,
        CompanionLibraryItemKind.collection ||
        CompanionLibraryItemKind.mainOnly => null,
      };

  List<CompanionLibrarySection> _enabledSections() => <CompanionLibrarySection>[
    for (final CompanionLibrarySection s in CompanionLibrarySection.values)
      if (s != CompanionLibrarySection.home && _data.isSectionEnabled(s)) s,
  ];

  bool _kindEnabled(CompanionLibraryItemKind kind) {
    final CompanionLibrarySection? section = sectionOf(kind);
    return section != null && _data.isSectionEnabled(section);
  }

  /// Browse's Home.
  Future<CompanionLibraryHome> home() async {
    final List<CompanionLibraryRecord> inProgress = <CompanionLibraryRecord>[
      for (final CompanionLibraryRecord r in await _data.continueRecords())
        if (_kindEnabled(r.kind)) r,
    ]..sort(_byRecentAt);
    final List<CompanionLibraryRecord> server =
        _data.isSectionEnabled(CompanionLibrarySection.servers)
        ? _data.continueServer()
        : const <CompanionLibraryRecord>[];
    final List<CompanionLibraryRecord> added = <CompanionLibraryRecord>[
      for (final CompanionLibraryRecord r in await _localRecords())
        if (r.addedAt > 0) r,
    ]..sort(_byAddedAt);
    final List<CompanionLibraryHomeRow> rows = <CompanionLibraryHomeRow>[
      for (final (
            CompanionLibraryHomeRowKind kind,
            List<CompanionLibraryRecord> records,
          )
          in <(CompanionLibraryHomeRowKind, List<CompanionLibraryRecord>)>[
            (CompanionLibraryHomeRowKind.continueItems, inProgress),
            (CompanionLibraryHomeRowKind.continueServer, server),
            (CompanionLibraryHomeRowKind.recentlyAdded, added),
          ])
        if (records.isNotEmpty)
          CompanionLibraryHomeRow(
            kind: kind,
            items: await _withCovers(
              records.take(kCompanionLibraryHomeRowLimit).toList(),
            ),
          ),
    ];
    return CompanionLibraryHome(rows: rows, sections: _enabledSections());
  }

  /// `library.list`.
  Future<CompanionLibraryPage> list({
    required CompanionLibrarySection section,
    String? parent,
    String query = '',
    int offset = 0,
    int limit = CompanionLibraryArgs.pageSize,
  }) async {
    final ({int offset, int limit}) range = clampCompanionLibraryRange(
      offset,
      limit,
    );
    final String needle = query.trim();
    if (parent != null && parent.isNotEmpty) {
      return _listParent(parent, needle, range.offset, range.limit);
    }
    if (!_data.isSectionEnabled(section)) {
      return CompanionLibraryPage(
        items: const <CompanionLibraryItem>[],
        offset: range.offset,
        total: 0,
      );
    }
    switch (section) {
      case CompanionLibrarySection.home:
        return CompanionLibraryPage(
          items: const <CompanionLibraryItem>[],
          offset: range.offset,
          total: 0,
        );
      case CompanionLibrarySection.books ||
          CompanionLibrarySection.manga ||
          CompanionLibrarySection.video ||
          CompanionLibrarySection.audiobooks:
        return _page(
          await _sectionTop(section, needle),
          range.offset,
          range.limit,
        );
      case CompanionLibrarySection.music:
        return _page(
          _filter(await _musicTop(), needle),
          range.offset,
          range.limit,
        );
      case CompanionLibrarySection.servers:
        return _page(
          _filter(await _data.servers(), needle),
          range.offset,
          range.limit,
        );
    }
  }

  /// `library.search`: every enabled local section, unfolded.
  Future<CompanionLibraryPage> search({
    required String query,
    int offset = 0,
    int limit = CompanionLibraryArgs.pageSize,
  }) async {
    final ({int offset, int limit}) range = clampCompanionLibraryRange(
      offset,
      limit,
    );
    final String needle = query.trim();
    if (needle.isEmpty) {
      return CompanionLibraryPage(
        items: const <CompanionLibraryItem>[],
        offset: range.offset,
        total: 0,
      );
    }
    final CompanionMusicLibrary? music =
        _data.isSectionEnabled(CompanionLibrarySection.music)
        ? await _data.music()
        : null;
    final List<CompanionLibraryRecord> all = <CompanionLibraryRecord>[
      ...await _localRecords(),
      if (music != null) ...music.albums,
      if (music != null) ...music.tracks,
    ];
    return _page(_filter(all, needle), range.offset, range.limit);
  }

  /// `library.details`.
  Future<CompanionLibraryDetails> details(String ref) async {
    final CompanionLibraryItemKind kind = _requireKind(ref);
    if (kind == CompanionLibraryItemKind.mainOnly ||
        (kind.isContainer && !_isLocalCollection(ref))) {
      throw FormatException('no details for $ref');
    }
    final CompanionDetailsSource? source = await _data.details(ref);
    if (source == null) throw StateError('$ref is gone');
    final List<CompanionLibraryItem> item = await _withCovers(
      <CompanionLibraryRecord>[source.record],
    );
    return buildCompanionLibraryDetails(source, item.single);
  }

  /// `library.open`.
  Future<CompanionLibraryOpenResult> open(String ref, {String? entry}) async {
    final CompanionLibraryItemKind kind = _requireKind(ref);
    if (kind == CompanionLibraryItemKind.mainOnly) {
      final CompanionLibraryMainTarget? target =
          CompanionLibraryMainTarget.fromWire(CompanionLibraryRef.keyOf(ref));
      if (target == null) throw FormatException('unknown target in $ref');
      await _data.openOnMain(target);
      return const CompanionLibraryOpenResult(opened: true);
    }
    if (kind.isContainer && !_isLocalCollection(ref)) {
      throw FormatException('$ref is a list');
    }
    final CompanionLibraryRecord? top = await _data.currentTop();
    if (top != null && top.ref == ref && entry == null) {
      // Already what is open on top: nothing to close or reopen.
      return const CompanionLibraryOpenResult(opened: true);
    }
    if (!await _data.returnToHome()) {
      return const CompanionLibraryOpenResult(opened: false);
    }
    final bool opened = await _data.open(ref, entry: entry);
    final CompanionLibraryRecord? previous = top != null && top.ref != ref
        ? top
        : null;
    return CompanionLibraryOpenResult(
      opened: opened,
      previous: previous?.toItem(),
    );
  }

  /// `library.markFinished`: returns the re-read item.
  Future<CompanionLibraryItem> markFinished(
    String ref, {
    required bool finished,
  }) async {
    _requireKind(ref);
    if (!await _data.setFinished(ref, finished: finished)) {
      throw FormatException('$ref cannot be marked finished');
    }
    final CompanionLibraryRecord? record = await _findLocal(ref);
    if (record == null) throw StateError('$ref is gone');
    return (await _withCovers(<CompanionLibraryRecord>[record])).single;
  }

  /// A local item or collection by ref (as its list shows it).
  Future<CompanionLibraryRecord?> _findLocal(String ref) async {
    final List<CompanionLibraryRecord> candidates;
    if (_isLocalCollection(ref)) {
      final String key = CompanionLibraryRef.keyOf(ref);
      candidates = await _sectionTop(
        CompanionLibrarySection.fromWire(key.substring(0, key.indexOf('/'))),
        '',
      );
    } else {
      candidates = await _localRecords();
    }
    for (final CompanionLibraryRecord r in candidates) {
      if (r.ref == ref) return r;
    }
    return null;
  }

  /// `collection:<books|manga|video|audiobooks>/<id>` (not a music group).
  static bool _isLocalCollection(String ref) {
    if (CompanionLibraryRef.kindOf(ref) !=
        CompanionLibraryItemKind.collection) {
      return false;
    }
    final String key = CompanionLibraryRef.keyOf(ref);
    final int slash = key.indexOf('/');
    if (slash <= 0) return false;
    final String section = key.substring(0, slash);
    return _localSections.any((CompanionLibrarySection s) => s.wire == section);
  }

  /// `library.cover`.
  Future<String?> cover(String ref) async {
    _requireKind(ref);
    final String? path = await _data.cover(ref);
    return path == null || path.isEmpty ? null : path;
  }

  /// `library.openOnMain`.
  Future<void> openOnMain(CompanionLibraryMainTarget target) =>
      _data.openOnMain(target);

  // ---- lists ---------------------------------------------------------------

  Future<List<CompanionLibraryRecord>> _localRecords() async {
    final bool booksOn =
        _data.isSectionEnabled(CompanionLibrarySection.books) ||
        _data.isSectionEnabled(CompanionLibrarySection.manga) ||
        _data.isSectionEnabled(CompanionLibrarySection.audiobooks);
    return <CompanionLibraryRecord>[
      if (booksOn)
        for (final CompanionLibraryRecord r in await _data.books())
          if (_kindEnabled(r.kind)) r,
      if (_data.isSectionEnabled(CompanionLibrarySection.video))
        ...await _data.videos(),
    ];
  }

  Future<List<CompanionLibraryRecord>> _sectionRecords(
    CompanionLibrarySection section,
  ) async => <CompanionLibraryRecord>[
    for (final CompanionLibraryRecord r
        in section == CompanionLibrarySection.video
            ? await _data.videos()
            : await _data.books())
      if (sectionOf(r.kind) == section) r,
  ];

  /// A local section's top level: collections (folding their members) and the
  /// items outside any collection, most recent first; online sources last.
  /// With a query the matching items are listed unfolded, plus matching
  /// collections.
  Future<List<CompanionLibraryRecord>> _sectionTop(
    CompanionLibrarySection section,
    String query,
  ) async {
    final List<CompanionLibraryRecord> records = await _sectionRecords(section);
    final Map<int, CompanionLibraryCollection> collections =
        <int, CompanionLibraryCollection>{
          for (final CompanionLibraryCollection c in await _data.collections(
            section,
          ))
            c.id: c,
        };
    final Map<int, List<CompanionLibraryRecord>> members =
        <int, List<CompanionLibraryRecord>>{};
    final List<CompanionLibraryRecord> loose = <CompanionLibraryRecord>[];
    for (final CompanionLibraryRecord r in records) {
      final int? cid = r.collectionId;
      if (cid != null && collections.containsKey(cid)) {
        (members[cid] ??= <CompanionLibraryRecord>[]).add(r);
      } else {
        loose.add(r);
      }
    }
    final List<CompanionLibraryRecord> folded = <CompanionLibraryRecord>[
      for (final MapEntry<int, List<CompanionLibraryRecord>> e
          in members.entries)
        _collectionRecord(collections[e.key]!, e.value),
    ];
    if (query.isNotEmpty) {
      return <CompanionLibraryRecord>[
        ..._filter(folded, query),
        ..._filter(records, query),
      ];
    }
    return <CompanionLibraryRecord>[
      ...(<CompanionLibraryRecord>[...folded, ...loose]..sort(_byRecency)),
      for (final CompanionLibraryMainTarget target in _data.onlineTargets(
        section,
      ))
        CompanionLibraryRecord(
          kind: CompanionLibraryItemKind.mainOnly,
          key: target.wire,
          title: companionLibraryMainTargetTitle(target),
          mainTarget: target,
        ),
    ];
  }

  CompanionLibraryRecord _collectionRecord(
    CompanionLibraryCollection collection,
    List<CompanionLibraryRecord> members,
  ) {
    int recent = 0;
    int added = 0;
    for (final CompanionLibraryRecord m in members) {
      if (m.recentAt > recent) recent = m.recentAt;
      if (m.addedAt > added) added = m.addedAt;
    }
    final List<CompanionLibraryRecord> sorted = _bySortIndex(members);
    return CompanionLibraryRecord(
      kind: CompanionLibraryItemKind.collection,
      key: collection.key,
      title: collection.title,
      recentAt: recent,
      addedAt: added,
      count: members.length,
      finished: members.every((CompanionLibraryRecord m) => m.finished),
      resolveCover: () async {
        final String? own = await collection.resolveCover?.call();
        if (own != null && own.isNotEmpty) return own;
        for (final CompanionLibraryRecord m in sorted) {
          final String? path = m.coverPath ?? await m.resolveCover?.call();
          if (path != null && path.isNotEmpty) return path;
        }
        return null;
      },
    );
  }

  Future<List<CompanionLibraryRecord>> _musicTop() async {
    final CompanionMusicLibrary music = await _data.music();
    return <CompanionLibraryRecord>[
      for (final (CompanionMusicGroup group, List<CompanionLibraryRecord> rows)
          in <(CompanionMusicGroup, List<CompanionLibraryRecord>)>[
            (CompanionMusicGroup.albums, music.albums),
            (CompanionMusicGroup.artists, music.artists),
            (CompanionMusicGroup.playlists, music.playlists),
            (CompanionMusicGroup.tracks, music.tracks),
          ])
        if (rows.isNotEmpty)
          CompanionLibraryRecord(
            kind: CompanionLibraryItemKind.collection,
            key: '${CompanionLibrarySection.music.wire}/${group.name}',
            title: companionMusicGroupTitle(group),
            count: rows.length,
          ),
    ];
  }

  Future<CompanionLibraryPage> _listParent(
    String parent,
    String query,
    int offset,
    int limit,
  ) async {
    final CompanionLibraryItemKind kind = _requireKind(parent);
    switch (kind) {
      case CompanionLibraryItemKind.collection:
        final String key = CompanionLibraryRef.keyOf(parent);
        final int slash = key.indexOf('/');
        if (slash <= 0) throw FormatException('malformed collection $parent');
        final CompanionLibrarySection section =
            CompanionLibrarySection.fromWire(key.substring(0, slash));
        final String id = key.substring(slash + 1);
        if (section == CompanionLibrarySection.music) {
          final CompanionMusicGroup? group = CompanionMusicGroup.fromWire(id);
          if (group == null) throw FormatException('unknown group $parent');
          final CompanionMusicLibrary music = await _data.music();
          final List<CompanionLibraryRecord> rows = switch (group) {
            CompanionMusicGroup.albums => music.albums,
            CompanionMusicGroup.artists => music.artists,
            CompanionMusicGroup.playlists => music.playlists,
            CompanionMusicGroup.tracks => music.tracks,
          };
          return _page(
            _filter(rows, query),
            offset,
            limit,
            title: companionMusicGroupTitle(group),
          );
        }
        final int? cid = int.tryParse(id);
        if (cid == null || !_localSections.contains(section)) {
          throw FormatException('malformed collection $parent');
        }
        CompanionLibraryCollection? collection;
        for (final CompanionLibraryCollection c in await _data.collections(
          section,
        )) {
          if (c.id == cid) collection = c;
        }
        final List<CompanionLibraryRecord> members =
            _bySortIndex(<CompanionLibraryRecord>[
              for (final CompanionLibraryRecord r in await _sectionRecords(
                section,
              ))
                if (r.collectionId == cid) r,
            ]);
        return _page(
          _filter(members, query),
          offset,
          limit,
          title: collection?.title,
        );
      case CompanionLibraryItemKind.musicArtist ||
          CompanionLibraryItemKind.musicPlaylist:
        final ({String title, List<CompanionLibraryRecord> tracks})? children =
            await _data.musicChildren(parent);
        if (children == null) throw StateError('$parent is gone');
        return _page(
          _filter(children.tracks, query),
          offset,
          limit,
          title: children.title,
        );
      case CompanionLibraryItemKind.server ||
          CompanionLibraryItemKind.serverLibrary ||
          CompanionLibraryItemKind.serverFolder:
        return _data.serverChildren(
          parent,
          query: query,
          offset: offset,
          limit: limit,
        );
      case CompanionLibraryItemKind.book ||
          CompanionLibraryItemKind.manga ||
          CompanionLibraryItemKind.video ||
          CompanionLibraryItemKind.audiobook ||
          CompanionLibraryItemKind.musicAlbum ||
          CompanionLibraryItemKind.musicTrack ||
          CompanionLibraryItemKind.serverItem ||
          CompanionLibraryItemKind.mainOnly:
        throw FormatException('$parent is not a list');
    }
  }

  Future<CompanionLibraryPage> _page(
    List<CompanionLibraryRecord> records,
    int offset,
    int limit, {
    String? title,
  }) async {
    final int start = offset > records.length ? records.length : offset;
    final int end = start + limit > records.length
        ? records.length
        : start + limit;
    return CompanionLibraryPage(
      items: await _withCovers(records.sublist(start, end)),
      offset: start,
      total: records.length,
      hasMore: end < records.length,
      title: title,
    );
  }

  /// Items with their cover files resolved (only these records are probed).
  Future<List<CompanionLibraryItem>> _withCovers(
    List<CompanionLibraryRecord> records,
  ) => Future.wait<CompanionLibraryItem>(<Future<CompanionLibraryItem>>[
    for (final CompanionLibraryRecord r in records)
      if (r.coverPath != null || r.resolveCover == null)
        Future<CompanionLibraryItem>.value(r.toItem())
      else
        r.resolveCover!().then((String? path) => r.toItem(coverPath: path)),
  ]);

  static List<CompanionLibraryRecord> _filter(
    List<CompanionLibraryRecord> records,
    String query,
  ) {
    if (query.isEmpty) return records;
    return <CompanionLibraryRecord>[
      for (final CompanionLibraryRecord r in records)
        if (matchesMediaSearch(
          query: query,
          titles: <String>[r.title, ?r.subtitle, ...r.searchTitles],
        ))
          r,
    ];
  }

  static List<CompanionLibraryRecord> _bySortIndex(
    List<CompanionLibraryRecord> records,
  ) =>
      List<CompanionLibraryRecord>.of(records)
        ..sort((CompanionLibraryRecord a, CompanionLibraryRecord b) {
          final int byIndex = (a.sortIndex ?? 1 << 30).compareTo(
            b.sortIndex ?? 1 << 30,
          );
          return byIndex != 0 ? byIndex : a.title.compareTo(b.title);
        });

  static int _byRecency(CompanionLibraryRecord a, CompanionLibraryRecord b) {
    final int c = b.recency.compareTo(a.recency);
    return c != 0 ? c : a.title.compareTo(b.title);
  }

  static int _byRecentAt(CompanionLibraryRecord a, CompanionLibraryRecord b) =>
      b.recentAt.compareTo(a.recentAt);

  static int _byAddedAt(CompanionLibraryRecord a, CompanionLibraryRecord b) =>
      b.addedAt.compareTo(a.addedAt);

  static CompanionLibraryItemKind _requireKind(String ref) {
    final CompanionLibraryItemKind? kind = CompanionLibraryRef.kindOf(ref);
    if (kind == null || CompanionLibraryRef.keyOf(ref).isEmpty) {
      throw FormatException('malformed library ref "$ref"');
    }
    return kind;
  }
}

/// `offset` / `limit` as the service uses them: offset >= 0, limit in
/// 1..[CompanionLibraryArgs.maxPageSize] (0 / negative = the panel's page
/// size).
({int offset, int limit}) clampCompanionLibraryRange(int offset, int limit) => (
  offset: offset < 0 ? 0 : offset,
  limit: limit <= 0
      ? CompanionLibraryArgs.pageSize
      : (limit > CompanionLibraryArgs.maxPageSize
            ? CompanionLibraryArgs.maxPageSize
            : limit),
);

/// Title of an "Open on main screen" entry.
String companionLibraryMainTargetTitle(CompanionLibraryMainTarget target) =>
    switch (target) {
      CompanionLibraryMainTarget.onlineManga =>
        t.second_screen_library_data_online_manga,
      CompanionLibraryMainTarget.onlineVideo =>
        t.second_screen_library_data_online_video,
      CompanionLibraryMainTarget.onlineNovels =>
        t.second_screen_library_data_online_novels,
      CompanionLibraryMainTarget.statistics => t.media_stats_title,
      CompanionLibraryMainTarget.dictionaries => t.dictionaries,
      CompanionLibraryMainTarget.libraryTab =>
        t.second_screen_library_data_server_on_main,
    };

String companionMusicGroupTitle(CompanionMusicGroup group) => switch (group) {
  CompanionMusicGroup.albums => t.music_section_albums,
  CompanionMusicGroup.artists => t.music_section_artists,
  CompanionMusicGroup.playlists => t.music_section_playlists,
  CompanionMusicGroup.tracks => t.second_screen_library_data_entries_tracks,
};

/// `m:ss` / `h:mm:ss`.
String formatCompanionClock(int ms) {
  final int total = ms ~/ 1000;
  final int h = total ~/ 3600;
  final int m = (total % 3600) ~/ 60;
  final String s = (total % 60).toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$s' : '$m:$s';
}

/// Labels [source] into the wire details ([item] = its list item with the
/// cover resolved). Blank / non-positive values are left out.
CompanionLibraryDetails buildCompanionLibraryDetails(
  CompanionDetailsSource source,
  CompanionLibraryItem item,
) {
  final CompanionEntriesKind? entriesKind = source.entriesKind;
  final List<CompanionLibraryEntry> entries = <CompanionLibraryEntry>[
    for (final CompanionEntrySource e in _entryWindow(source.entries))
      _entry(e, entriesKind),
  ];
  CompanionEntrySource? current;
  for (final CompanionEntrySource e in source.entries) {
    if (e.current) current = e;
  }
  final int? currentNumber = current?.number;
  final String? originalTitle = _text(source.originalTitle);
  final int? runtime = _positive(source.runtimeMinutes);
  final List<String> cast = <String>[
    for (final String c in source.cast)
      if (_text(c) case final String name) name,
  ];
  final List<CompanionLibraryFact> facts = <CompanionLibraryFact>[
    if (originalTitle != null && originalTitle != source.record.title)
      CompanionLibraryFact(
        label: t.second_screen_library_data_fact_original_title,
        value: originalTitle,
      ),
    if (runtime != null)
      CompanionLibraryFact(
        label: t.second_screen_library_data_fact_runtime,
        value: t.second_screen_library_data_entry_minutes(n: runtime),
      ),
    if (_text(source.series) case final String series)
      CompanionLibraryFact(
        label: t.second_screen_library_data_fact_series,
        value: series,
      ),
    if (_text(source.narrator) case final String narrator)
      CompanionLibraryFact(
        label: t.second_screen_library_data_fact_narrator,
        value: narrator,
      ),
    if (_text(source.released) case final String released)
      CompanionLibraryFact(
        label: t.second_screen_library_data_fact_released,
        value: released,
      ),
    if (cast.isNotEmpty)
      CompanionLibraryFact(
        label: t.second_screen_library_data_fact_cast,
        value: cast.take(6).join(', '),
      ),
  ];
  final double? rating = source.rating;
  return CompanionLibraryDetails(
    item: item,
    author: _text(source.author),
    description: _text(source.description),
    genres: <String>[
      for (final String g in source.genres)
        if (_text(g) case final String genre) genre,
    ],
    rating: rating != null && rating > 0 ? rating : null,
    ratingVotes: _positive(source.ratingVotes),
    year: _positive(source.year),
    facts: facts,
    entries: entries,
    entriesLabel: entries.isEmpty || entriesKind == null
        ? null
        : switch (entriesKind) {
            CompanionEntriesKind.chapters =>
              t.second_screen_library_data_entries_chapters,
            CompanionEntriesKind.episodes =>
              t.second_screen_library_data_entries_episodes,
            CompanionEntriesKind.tracks =>
              t.second_screen_library_data_entries_tracks,
            CompanionEntriesKind.items =>
              t.second_screen_library_data_entries_items,
          },
    continueLabel:
        entriesKind == CompanionEntriesKind.episodes &&
            currentNumber != null &&
            currentNumber > 0
        ? t.second_screen_library_data_continue_episode(n: currentNumber)
        : null,
    canOpen: source.canOpen,
    canMarkFinished: source.canMarkFinished,
  );
}

/// At most [CompanionLibraryArgs.maxPageSize] entries around the current one.
List<CompanionEntrySource> _entryWindow(List<CompanionEntrySource> all) {
  const int max = CompanionLibraryArgs.maxPageSize;
  if (all.length <= max) return all;
  int current = all.indexWhere((CompanionEntrySource e) => e.current);
  if (current < 0) current = 0;
  int start = current - max ~/ 2;
  if (start < 0) start = 0;
  if (start + max > all.length) start = all.length - max;
  return all.sublist(start, start + max);
}

CompanionLibraryEntry _entry(
  CompanionEntrySource e,
  CompanionEntriesKind? kind,
) {
  final int? number = _positive(e.number);
  final String title = e.title.trim();
  final String label = kind == CompanionEntriesKind.episodes && number != null
      ? (title.isEmpty ? 'E$number' : 'E$number · $title')
      : title;
  final int? duration = _positive(e.durationMs);
  final int? runtime =
      _positive(e.runtimeMinutes) ??
      (duration == null ? null : (duration / 60000).round());
  final String? subtitle = e.finished
      ? (kind == CompanionEntriesKind.episodes
            ? t.second_screen_library_data_entry_watched
            : null)
      : e.positionMs > 0
      ? t.second_screen_library_data_entry_resume(
          time: formatCompanionClock(e.positionMs),
        )
      : (runtime != null && runtime > 0
            ? t.second_screen_library_data_entry_minutes(n: runtime)
            : null);
  return CompanionLibraryEntry(
    id: e.id,
    title: label,
    subtitle: subtitle,
    progress: !e.finished && duration != null && e.positionMs > 0
        ? (e.positionMs / duration).clamp(0.0, 1.0)
        : null,
    finished: e.finished,
    current: e.current,
  );
}

String? _text(String? value) {
  final String v = value?.trim() ?? '';
  return v.isEmpty ? null : v;
}

int? _positive(int? value) => value != null && value > 0 ? value : null;

/// Registers the `library.*` request methods on [bridge].
void registerCompanionLibraryHandlers(
  CompanionBridge bridge,
  CompanionLibraryService service,
) {
  String requireRef(Map<String, Object?> args) {
    final Object? ref = args[CompanionLibraryArgs.ref];
    if (ref is String && ref.isNotEmpty) return ref;
    throw const FormatException('ref missing');
  }

  String? optionalString(Map<String, Object?> args, String key) {
    final Object? v = args[key];
    return v is String && v.isNotEmpty ? v : null;
  }

  int intArg(Map<String, Object?> args, String key, int fallback) {
    final Object? v = args[key];
    return v is num ? v.toInt() : fallback;
  }

  bridge
    ..registerRequestHandler(
      CompanionRequestMethods.libraryHome,
      (Map<String, Object?> args) async => (await service.home()).toJson(),
    )
    ..registerRequestHandler(
      CompanionRequestMethods.libraryList,
      (Map<String, Object?> args) async => (await service.list(
        section: CompanionLibrarySection.fromWire(
          args[CompanionLibraryArgs.section],
        ),
        parent: optionalString(args, CompanionLibraryArgs.parent),
        query: optionalString(args, CompanionLibraryArgs.query) ?? '',
        offset: intArg(args, CompanionLibraryArgs.offset, 0),
        limit: intArg(
          args,
          CompanionLibraryArgs.limit,
          CompanionLibraryArgs.pageSize,
        ),
      )).toJson(),
    )
    ..registerRequestHandler(
      CompanionRequestMethods.librarySearch,
      (Map<String, Object?> args) async => (await service.search(
        query: optionalString(args, CompanionLibraryArgs.query) ?? '',
        offset: intArg(args, CompanionLibraryArgs.offset, 0),
        limit: intArg(
          args,
          CompanionLibraryArgs.limit,
          CompanionLibraryArgs.pageSize,
        ),
      )).toJson(),
    )
    ..registerRequestHandler(
      CompanionRequestMethods.libraryDetails,
      (Map<String, Object?> args) async =>
          (await service.details(requireRef(args))).toJson(),
    )
    ..registerRequestHandler(
      CompanionRequestMethods.libraryOpen,
      (Map<String, Object?> args) async => (await service.open(
        requireRef(args),
        entry: optionalString(args, CompanionLibraryArgs.entry),
      )).toJson(),
    )
    ..registerRequestHandler(CompanionRequestMethods.libraryMarkFinished, (
      Map<String, Object?> args,
    ) async {
      final CompanionLibraryItem item = await service.markFinished(
        requireRef(args),
        finished: args[CompanionLibraryArgs.finished] != false,
      );
      bridge.notifyLibraryChanged();
      return item.toJson();
    })
    ..registerRequestHandler(
      CompanionRequestMethods.libraryCover,
      (Map<String, Object?> args) => service.cover(requireRef(args)),
    )
    ..registerRequestHandler(CompanionRequestMethods.libraryOpenOnMain, (
      Map<String, Object?> args,
    ) async {
      final CompanionLibraryMainTarget? target =
          CompanionLibraryMainTarget.fromWire(
            args[CompanionLibraryArgs.target],
          );
      if (target == null) throw const FormatException('unknown target');
      await service.openOnMain(target);
      return null;
    });
}
