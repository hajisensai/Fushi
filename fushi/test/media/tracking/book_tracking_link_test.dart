import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/tracking/book_link_hints.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/epub_series.dart';
import 'package:fushi_engine/media/tracking/book_tracking_link.dart';
import 'package:fushi_engine/media/tracking/media_tracking_repository.dart';
import 'package:fushi_engine/media/tracking/media_tracking_service.dart';
import 'package:fushi_engine/media/tracking/title_match.dart';
import 'package:fushi_engine/media/tracking/tracking_provider.dart';

// Core book-linking tests with fake sites only: the sites besides Bangumi
// are tracking plugins.

const String _defaultId = 'fake_default';
const String _otherId = 'fake_other';

final class _FakeSession implements TrackingProviderSession {
  @override
  void close() {}
}

/// An in-memory book site. Search matches the exact script only (a
/// substring of a title), filtered by kind, like MangaBaka's search.
final class _FakeBookSite implements TrackingProvider, TrackingBookLinker {
  _FakeBookSite(this.id, {required this.siteHost, required bool isDefault})
    : capabilities = TrackingProviderCapabilities(
        kinds: const <TrackingKind>{TrackingKind.novel, TrackingKind.manga},
        progressModes: const <TrackingProgressMode>{
          TrackingProgressMode.chapter,
          TrackingProgressMode.volume,
        },
        onByDefault: isDefault
            ? const <TrackingKind>{TrackingKind.novel, TrackingKind.manga}
            : const <TrackingKind>{},
      );

  @override
  final String id;

  @override
  String get displayName => id;

  @override
  final String siteHost;

  @override
  final TrackingProviderCapabilities capabilities;

  final List<TrackingBookSubject> catalogue = <TrackingBookSubject>[];
  final List<String> searches = <String>[];
  final List<PendingTrackingUpdate> pushed = <PendingTrackingUpdate>[];

  @override
  bool get isConfigured => true;

  @override
  Future<TrackingProviderSession> openSession() async => _FakeSession();

  @override
  Future<void> push(
    TrackingProviderSession session,
    PendingTrackingUpdate update,
  ) async {
    pushed.add(update);
  }

  @override
  TrackingFailureKind classify(Object error) => TrackingFailureKind.transient;

  @override
  Future<List<TrackingBookSubject>> searchBooks(
    String query,
    TrackingKind kind,
  ) async {
    searches.add(query);
    return <TrackingBookSubject>[
      for (final TrackingBookSubject subject in catalogue)
        if (subject.kind == kind &&
            <String>[
              subject.name,
              ...subject.titles,
            ].any((String title) => title.contains(query)))
          subject,
    ];
  }

  @override
  Future<TrackingBookSubject?> bookById(int subjectId) async {
    for (final TrackingBookSubject subject in catalogue) {
      if (subject.subjectId == subjectId) return subject;
    }
    return null;
  }

  @override
  Future<TrackingBookSubject?> bookForLinkedId(
    String providerId,
    int subjectId,
  ) async {
    for (final TrackingBookSubject subject in catalogue) {
      if (subject.linkedIds[providerId] == subjectId) return subject;
    }
    return null;
  }
}

final class _NoTimer implements Timer {
  @override
  void cancel() {}

  @override
  bool get isActive => false;

  @override
  int get tick => 0;
}

/// A finished two-volume novel, known on the other site as 44893.
const TrackingBookSubject _bakeNovel = TrackingBookSubject(
  subjectId: 84547,
  name: 'Bakemonogatari',
  kind: TrackingKind.novel,
  titles: <String>['化物語', 'Bakemonogatari'],
  authors: <String>['西尾維新'],
  finalVolume: 2,
  isFinished: true,
  linkedIds: <String, int>{_otherId: 44893},
);

/// The manga adaptation: same titles, other kind.
const TrackingBookSubject _bakeManga = TrackingBookSubject(
  subjectId: 7426,
  name: 'Bakemonogatari',
  kind: TrackingKind.manga,
  titles: <String>['化物語', 'Bakemonogatari'],
  isFinished: true,
);

/// A finished 18-volume novel with 1432 chapters.
const TrackingBookSubject _lotm = TrackingBookSubject(
  subjectId: 84351,
  name: 'Lord of Mysteries',
  kind: TrackingKind.novel,
  titles: <String>['诡秘之主', 'Lord of Mysteries'],
  totalChapters: 1432,
  finalVolume: 18,
  isFinished: true,
);

TrackingBookSubject _subject({
  int? finalVolume,
  int? totalChapters,
  bool finished = true,
}) => TrackingBookSubject(
  subjectId: 1,
  name: 'S',
  kind: TrackingKind.novel,
  finalVolume: finalVolume,
  totalChapters: totalChapters,
  isFinished: finished,
);

BookLinkSource _source({
  BookFormat format = BookFormat.epub,
  int? volume,
  bool chapterWork = false,
}) => BookLinkSource(
  mediaTitle: 'T',
  format: format,
  query: const TitleMatchQuery(titles: <String>['T']),
  volume: volume,
  chapterWork: chapterWork,
);

void main() {
  group('planBookLink', () {
    test('a numbered volume counts volumes from its number', () {
      expect(planBookLink(source: _source(volume: 3), subject: _subject()), (
        mode: TrackingProgressMode.volume,
        offset: 3,
      ));
    });

    test('a volume past the last one of a finished series is not linked', () {
      expect(
        planBookLink(
          source: _source(volume: 3),
          subject: _subject(finalVolume: 2),
        ),
        isNull,
      );
      expect(
        planBookLink(
          source: _source(volume: 3),
          subject: _subject(finalVolume: 2, finished: false),
        ),
        isNotNull,
        reason: 'a releasing series can still get that volume',
      );
    });

    test('no volume number links only a finished one-volume work', () {
      expect(
        planBookLink(source: _source(), subject: _subject(finalVolume: 1)),
        (mode: TrackingProgressMode.volume, offset: 1),
      );
      expect(
        planBookLink(source: _source(), subject: _subject(finalVolume: 18)),
        isNull,
      );
      expect(
        planBookLink(source: _source(), subject: _subject(finished: false)),
        isNull,
      );
    });

    test('a PDF is one volume, even with a number in its name', () {
      expect(
        planBookLink(
          source: _source(format: BookFormat.pdf, volume: 3),
          subject: _subject(finalVolume: 1),
        ),
        (mode: TrackingProgressMode.volume, offset: 1),
      );
      expect(
        planBookLink(
          source: _source(format: BookFormat.pdf, volume: 3),
          subject: _subject(finalVolume: 5),
        ),
        isNull,
      );
    });

    test('chapter works count chapters unless numbering differs', () {
      expect(
        planBookLink(
          source: _source(chapterWork: true),
          subject: _subject(totalChapters: 1432),
          localChapters: 40,
        ),
        (mode: TrackingProgressMode.chapter, offset: 0),
      );
      expect(
        planBookLink(
          source: _source(chapterWork: true),
          subject: _subject(totalChapters: 100),
          localChapters: 140,
        ),
        isNull,
      );
    });
  });

  group('planBookLinkForUser', () {
    test('the safe plan when there is one', () {
      expect(
        planBookLinkForUser(
          source: _source(volume: 2),
          subject: _subject(finalVolume: 5),
        ),
        (mode: TrackingProgressMode.volume, offset: 2),
      );
    });

    test('otherwise the known volume, volume 1, or chapters', () {
      expect(
        planBookLinkForUser(
          source: _source(volume: 3),
          subject: _subject(finalVolume: 2),
        ),
        (mode: TrackingProgressMode.volume, offset: 3),
      );
      expect(planBookLinkForUser(source: _source(), subject: _subject()), (
        mode: TrackingProgressMode.volume,
        offset: 1,
      ));
      expect(
        planBookLinkForUser(
          source: _source(format: BookFormat.pdf, volume: 3),
          subject: _subject(finalVolume: 5),
        ),
        (mode: TrackingProgressMode.volume, offset: 1),
      );
      expect(
        planBookLinkForUser(
          source: _source(chapterWork: true),
          subject: _subject(totalChapters: 100),
          localChapters: 140,
        ),
        (mode: TrackingProgressMode.chapter, offset: 0),
      );
    });
  });

  group('buildBookLinkSource', () {
    EpubBookRow row({
      String title = '化物語 第2巻',
      String format = 'epub',
      String? author,
      String? sourceMetadata,
    }) => EpubBookRow(
      bookKey: title,
      uid: 'u',
      title: title,
      author: author,
      epubPath: '/x',
      extractDir: '/x',
      chapterCount: 1,
      chaptersJson: '[]',
      importedAt: 1,
      format: format,
      sourceMetadata: sourceMetadata,
    );

    test('the series name without the volume, and the volume number', () {
      final BookLinkSource source = buildBookLinkSource(
        row(author: '西尾維新, VOFAN'),
        null,
      );
      expect(source.query.titles.first, '化物語');
      expect(source.volume, 2);
      expect(source.query.authors, <String>['西尾維新', 'VOFAN']);
      expect(source.kind, TrackingKind.novel);
    });

    test('the rename goes first; the OPF series index wins', () {
      final BookLinkSource source = buildBookLinkSource(
        row(
          title: 'bakemono_vol1_final',
          sourceMetadata: encodeEpubSeriesMetadata(
            const EpubSeries(name: '化物語', index: 1),
          ),
        ),
        (
          displayTitle: 'Bakemonogatari',
          extraTitles: const <String>[],
          authors: const <String>[],
          chapterWork: false,
        ),
      );
      expect(source.mediaTitle, 'Bakemonogatari');
      expect(source.query.titles.take(2), <String>['Bakemonogatari', '化物語']);
      expect(source.volume, 1);
    });

    test('chapter works have no volume', () {
      final BookLinkSource source =
          buildBookLinkSource(row(title: '诡秘之主 第3巻'), (
            displayTitle: null,
            extraTitles: const <String>['诡秘之主'],
            authors: const <String>[],
            chapterWork: true,
          ));
      expect(source.chapterWork, isTrue);
      expect(source.volume, isNull);
    });

    test('app hints: web novels and LNReader novels count chapters', () {
      final BookLinkHints web = bookLinkHintsOf(
        row(
          sourceMetadata:
              '{"type":"fushi_web_novel","workKey":"ncode.syosetu.com/n1",'
              '"workTitle":"无职转生","chapters":[],"queue":[]}',
        ),
      );
      expect(web.chapterWork, isTrue);
      expect(web.extraTitles, <String>['无职转生']);
      expect(
        bookLinkHintsOf(
          row(sourceMetadata: '{"type":"fushi-lnreader-online"}'),
        ).chapterWork,
        isTrue,
      );
      expect(bookLinkHintsOf(row()).chapterWork, isFalse);
    });
  });

  group('titleSpellingVariants', () {
    test('a mixed title is split into its scripts, brackets dropped', () {
      expect(
        titleSpellingVariants('14 Sai no Koi [水谷フーカ] 14歳の恋'),
        containsAllInOrder(<String>[
          '14 Sai no Koi',
          '14歳の恋',
          '14 Sai no Koi 14歳の恋',
        ]),
      );
    });

    test('katakana and hiragana both ways', () {
      expect(titleSpellingVariants('ヨツバと!'), contains('よつばと!'));
      expect(titleSpellingVariants('よつばと!'), contains('ヨツバト!'));
    });

    test('Simplified Chinese for Han titles without kana', () {
      expect(titleSpellingVariants('化物語'), contains('化物语'));
      expect(
        titleSpellingVariants('化物語'),
        isNot(contains('化物語')),
        reason: 'never the title itself',
      );
      expect(titleSpellingVariants('よつばと'), everyElement(isNot(contains('语'))));
    });

    test('bracketed names are authors, release tags are not', () {
      expect(bracketedNames('[作者：西尾維新]化物語'), <String>['西尾維新']);
      expect(bracketedNames('化物語 [3574f94a]'), isEmpty);
      expect(bracketedNames('14 Sai no Koi [水谷フーカ] 14歳の恋'), <String>['水谷フーカ']);
    });
  });

  group('parseTrackingSubjectInput', () {
    test('a number, or a link to that site', () {
      expect(parseTrackingSubjectInput('example.org', '84547'), 84547);
      expect(
        parseTrackingSubjectInput(
          'example.org',
          'https://example.org/manga/44893/x',
        ),
        44893,
      );
      expect(
        parseTrackingSubjectInput('example.org', 'https://example.org/84547'),
        84547,
      );
      expect(
        parseTrackingSubjectInput('example.org', 'https://other.test/manga/1'),
        isNull,
        reason: 'a link to another site',
      );
      expect(parseTrackingSubjectInput('example.org', '化物語'), isNull);
      expect(parseTrackingSubjectInput('example.org', '0'), isNull);
    });

    test('the host must be the site or a subdomain of it', () {
      expect(
        parseTrackingSubjectInput(
          'example.org',
          'https://www.example.org/x/12',
        ),
        12,
      );
      expect(
        parseTrackingSubjectInput('example.org', 'https://notexample.org/1'),
        isNull,
      );
      expect(
        parseTrackingSubjectInput(
          'example.org',
          'https://example.org.evil.test/1',
        ),
        isNull,
      );
    });

    test('an empty site host understands plain numbers only', () {
      expect(parseTrackingSubjectInput('', '42'), 42);
      expect(parseTrackingSubjectInput('', 'https://example.org/42'), isNull);
    });
  });

  group('linking with fake sites', () {
    late FushiDatabase db;
    late PreferencesRepository preferences;
    late MediaTrackingRepository repository;
    late _FakeBookSite primary;
    late _FakeBookSite other;
    late MediaTrackingService service;
    BookLinkHints? hints;

    setUp(() async {
      db = FushiDatabase.forTesting(NativeDatabase.memory());
      preferences = PreferencesRepository(db);
      await preferences.loadFromDb();
      repository = MediaTrackingRepository(db);
      primary = _FakeBookSite(
        _defaultId,
        siteHost: 'example.org',
        isDefault: true,
      );
      other = _FakeBookSite(_otherId, siteHost: 'other.test', isDefault: false);
      hints = null;
      service = MediaTrackingService(
        repository: repository,
        preferences: preferences,
        userAgent: 'test',
        retryTimerFactory: (Duration delay, void Function() callback) =>
            _NoTimer(),
        extraProviders: <TrackingProvider>[other, primary],
        bookLinkHints: (EpubBookRow book) async => hints,
      );
    });

    tearDown(() async {
      service.dispose();
      preferences.dispose();
      await db.close();
    });

    Future<void> insertBook(String title, {String format = 'epub'}) =>
        db.insertEpubBook(
          EpubBooksCompanion.insert(
            bookKey: title,
            title: title,
            epubPath: '/tmp/$title',
            extractDir: '/tmp/$title',
            chapterCount: 10,
            chaptersJson: '[]',
            importedAt: 1,
            format: Value<String>(format),
          ),
        );

    Future<void> finish(String bookKey) async {
      await service.recordBookProgress(
        bookKey: bookKey,
        completedChapterCount: 10,
        completed: true,
      );
      await service.whenBookLinksSettled();
      await service.syncNow();
    }

    Future<MediaTrackingMappingRow?> mapping(String provider, String key) =>
        repository.findMapping(
          mediaType: TrackingMediaType.book,
          mediaKey: key,
          provider: provider,
        );

    Future<List<MediaTrackingSuggestionRow>> suggestionsOf(String key) =>
        repository.loadSuggestions(
          mediaType: TrackingMediaType.book,
          mediaKey: key,
        );

    Future<void> enableOther(TrackingKind kind) =>
        service.setKindEnabled(_otherId, kind, true);

    test('kind switches follow onByDefault', () {
      expect(service.isKindEnabled(_defaultId, TrackingKind.novel), isTrue);
      expect(service.isKindEnabled(_defaultId, TrackingKind.manga), isTrue);
      expect(service.isKindEnabled(_otherId, TrackingKind.novel), isFalse);
      expect(service.isKindEnabled(_otherId, TrackingKind.manga), isFalse);
    });

    test('a file-name manga title links by its clean series name', () async {
      primary.catalogue.add(
        const TrackingBookSubject(
          subjectId: 700,
          name: 'Ajin',
          titles: <String>['亜人', 'Ajin: Demi-Human'],
          kind: TrackingKind.manga,
          finalVolume: 17,
          isFinished: true,
        ),
      );
      await insertBook('Ajin (HD Scan) Ajin 01', format: 'manga');

      await finish('Ajin (HD Scan) Ajin 01');

      expect(primary.searches.first, 'Ajin');
      final MediaTrackingMappingRow? link = await mapping(
        _defaultId,
        'Ajin (HD Scan) Ajin 01',
      );
      expect(link?.subjectId, 700);
      expect(link?.progressOffset, 1);
      final BookTrackingOverview? overview = await service.loadBookTracking(
        'Ajin (HD Scan) Ajin 01',
      );
      expect(overview!.searchQuery, 'Ajin', reason: 'Track sheet search box');
      expect(overview.title, 'Ajin (HD Scan) Ajin 01');
    });

    test('a sure match on the default site links and sends', () async {
      primary.catalogue.addAll(<TrackingBookSubject>[_bakeNovel, _bakeManga]);
      await enableOther(TrackingKind.novel);
      // Only a title search could find this; no id points to it.
      other.catalogue.add(
        const TrackingBookSubject(
          subjectId: 500,
          name: '化物語',
          kind: TrackingKind.novel,
          finalVolume: 2,
          isFinished: true,
        ),
      );
      await insertBook('化物語 第1巻');

      await finish('化物語 第1巻');

      final MediaTrackingMappingRow? link = await mapping(
        _defaultId,
        '化物語 第1巻',
      );
      expect(link, isNotNull);
      expect(link!.subjectId, 84547, reason: 'the novel, not the manga');
      expect(link.kind, TrackingKind.novel.value);
      expect(link.progressMode, TrackingProgressMode.volume.value);
      expect(link.progressOffset, 1);
      expect(link.linkSource, TrackingLinkSource.auto);
      expect(link.confidence, greaterThanOrEqualTo(kTitleMatchAutoLink));
      expect(primary.searches, isNotEmpty);
      expect(primary.searches.length, lessThanOrEqualTo(kBookLinkMaxSearches));
      final PendingTrackingUpdate sent = primary.pushed.single;
      expect(sent.mapping.subjectId, 84547);
      expect(sent.outbox.progress, 1);
      expect(sent.outbox.completed, isTrue);
      expect(other.searches, isEmpty, reason: 'not the default site');
      expect(await mapping(_otherId, '化物語 第1巻'), isNull);
      expect(other.pushed, isEmpty);
    });

    test('the non-default site is off by default and not linked', () async {
      primary.catalogue.add(_bakeNovel);
      other.catalogue.add(
        const TrackingBookSubject(
          subjectId: 44893,
          name: 'Bakemonogatari',
          kind: TrackingKind.novel,
          finalVolume: 2,
          isFinished: true,
        ),
      );
      await insertBook('化物語 第1巻');

      await finish('化物語 第1巻');

      expect(await mapping(_defaultId, '化物語 第1巻'), isNotNull);
      expect(await mapping(_otherId, '化物語 第1巻'), isNull);
      expect(other.searches, isEmpty);
      expect(other.pushed, isEmpty);
    });

    test('the other site links from the id the default site gave', () async {
      await enableOther(TrackingKind.novel);
      primary.catalogue.add(_bakeNovel);
      other.catalogue.add(
        const TrackingBookSubject(
          subjectId: 44893,
          name: 'Bakemonogatari (other)',
          kind: TrackingKind.novel,
          finalVolume: 2,
          isFinished: true,
        ),
      );
      await insertBook('化物語 第2巻');

      await finish('化物語 第2巻');

      final MediaTrackingMappingRow? base = await mapping(
        _defaultId,
        '化物語 第2巻',
      );
      final MediaTrackingMappingRow? link = await mapping(_otherId, '化物語 第2巻');
      expect(base?.progressOffset, 2);
      expect(link, isNotNull);
      expect(link!.subjectId, 44893);
      expect(link.subjectName, 'Bakemonogatari (other)');
      expect(link.linkSource, TrackingLinkSource.id);
      expect(link.progressMode, base!.progressMode);
      expect(link.progressOffset, 2, reason: 'same unit as the default link');
      expect(other.searches, isEmpty, reason: 'never searched by title');
      expect(primary.searches, hasLength(1));
      final PendingTrackingUpdate sent = other.pushed.single;
      expect(sent.mapping.subjectId, 44893);
      expect(sent.outbox.progress, 2);
      expect(sent.outbox.completed, isTrue);
    });

    test('the other site links from its own lookup of the id', () async {
      await enableOther(TrackingKind.novel);
      primary.catalogue.add(
        const TrackingBookSubject(
          subjectId: 84547,
          name: 'Bakemonogatari',
          kind: TrackingKind.novel,
          titles: <String>['化物語'],
          finalVolume: 2,
          isFinished: true,
        ),
      );
      other.catalogue.add(
        const TrackingBookSubject(
          subjectId: 9001,
          name: 'Bakemonogatari',
          kind: TrackingKind.novel,
          linkedIds: <String, int>{_defaultId: 84547},
        ),
      );
      await insertBook('化物語 第1巻');

      await finish('化物語 第1巻');

      final MediaTrackingMappingRow? link = await mapping(_otherId, '化物語 第1巻');
      expect(link?.subjectId, 9001);
      expect(link?.linkSource, TrackingLinkSource.id);
      expect(link?.progressOffset, 1);
      expect(other.searches, isEmpty);
    });

    test('an id link to an entry of the other kind is refused', () async {
      await enableOther(TrackingKind.novel);
      primary.catalogue.add(_bakeNovel);
      other.catalogue.add(
        const TrackingBookSubject(
          subjectId: 44893,
          name: 'Bakemonogatari',
          kind: TrackingKind.manga,
        ),
      );
      await insertBook('化物語 第1巻');

      await finish('化物語 第1巻');

      expect(await mapping(_defaultId, '化物語 第1巻'), isNotNull);
      expect(await mapping(_otherId, '化物語 第1巻'), isNull);
      expect(other.pushed, isEmpty);
    });

    test('an unsure match is a suggestion, searched once', () async {
      // Two novels with the same title: no margin between them.
      primary.catalogue.addAll(const <TrackingBookSubject>[
        TrackingBookSubject(
          subjectId: 10,
          name: '化物語',
          kind: TrackingKind.novel,
          finalVolume: 2,
          isFinished: true,
        ),
        TrackingBookSubject(
          subjectId: 11,
          name: '化物語',
          kind: TrackingKind.novel,
          finalVolume: 3,
          isFinished: true,
        ),
      ]);
      await insertBook('化物語 第1巻');

      await finish('化物語 第1巻');

      expect(await mapping(_defaultId, '化物語 第1巻'), isNull);
      final List<MediaTrackingSuggestionRow> suggestions = await suggestionsOf(
        '化物語 第1巻',
      );
      expect(
        suggestions.map((MediaTrackingSuggestionRow s) => s.subjectId).toSet(),
        <int>{10, 11},
      );
      expect(
        suggestions.every(
          (MediaTrackingSuggestionRow s) => s.provider == _defaultId,
        ),
        isTrue,
      );
      expect(primary.pushed, isEmpty);

      final int searched = primary.searches.length;
      await finish('化物語 第1巻');
      await service.refreshBookLinks('化物語 第1巻');
      expect(primary.searches, hasLength(searched), reason: 'no search again');
    });

    test('a sure series without a safe volume is a suggestion', () async {
      primary.catalogue.add(_lotm);
      await insertBook('诡秘之主');

      await finish('诡秘之主');

      expect(await mapping(_defaultId, '诡秘之主'), isNull);
      final MediaTrackingSuggestionRow suggestion = (await suggestionsOf(
        '诡秘之主',
      )).single;
      expect(suggestion.subjectId, 84351);
      expect(suggestion.subjectKind, TrackingKind.novel.value);
      expect(suggestion.score, greaterThanOrEqualTo(kTitleMatchAutoLink));
      expect(primary.pushed, isEmpty);

      final int searched = primary.searches.length;
      await finish('诡秘之主');
      expect(primary.searches, hasLength(searched), reason: 'no search again');
    });

    test('a volume past the last one is a suggestion', () async {
      primary.catalogue.add(_bakeNovel);
      await insertBook('化物語 第3巻');

      await finish('化物語 第3巻');

      expect(await mapping(_defaultId, '化物語 第3巻'), isNull);
      expect((await suggestionsOf('化物語 第3巻')).single.subjectId, 84547);
      expect(primary.pushed, isEmpty);
    });

    test('a web novel links by chapter', () async {
      primary.catalogue.add(_lotm);
      hints = (
        displayTitle: null,
        extraTitles: const <String>['诡秘之主'],
        authors: const <String>[],
        chapterWork: true,
      );
      await insertBook('诡秘之主 web');

      await finish('诡秘之主 web');

      final MediaTrackingMappingRow? link = await mapping(
        _defaultId,
        '诡秘之主 web',
      );
      expect(link?.subjectId, 84351);
      expect(link?.progressMode, TrackingProgressMode.chapter.value);
      expect(link?.progressOffset, 0);
      expect(link?.linkSource, TrackingLinkSource.auto);
    });

    test('a book with only results of the other kind links nothing', () async {
      primary.catalogue.add(_bakeManga);
      await insertBook('化物語 第1巻');

      await finish('化物語 第1巻');

      expect(await mapping(_defaultId, '化物語 第1巻'), isNull);
      expect(await suggestionsOf('化物語 第1巻'), isEmpty);
      expect(primary.pushed, isEmpty);
    });

    test('a private book is never searched for', () async {
      await enableOther(TrackingKind.novel);
      primary.catalogue.add(_bakeNovel);
      await insertBook('化物語 第1巻');
      await db.setMediaPrivate(TagHostKind.epub, '化物語 第1巻', true);

      await finish('化物語 第1巻');
      await service.refreshBookLinks('化物語 第1巻');

      expect(primary.searches, isEmpty);
      expect(other.searches, isEmpty);
      expect(await mapping(_defaultId, '化物語 第1巻'), isNull);
      expect(primary.pushed, isEmpty);
      expect((await service.loadBookTracking('化物語 第1巻'))!.isPrivate, isTrue);
    });

    test('a manual link is never replaced', () async {
      primary.catalogue.add(_bakeNovel);
      await insertBook('化物語 第1巻');
      await repository.saveMapping(
        mediaType: TrackingMediaType.book,
        mediaKey: '化物語 第1巻',
        mediaTitle: '化物語 第1巻',
        kind: TrackingKind.novel,
        subjectId: 999,
        subjectName: 'Mine',
        progressMode: TrackingProgressMode.volume,
        progressOffset: 1,
        provider: _defaultId,
      );

      await finish('化物語 第1巻');

      final MediaTrackingMappingRow? link = await mapping(
        _defaultId,
        '化物語 第1巻',
      );
      expect(link!.subjectId, 999);
      expect(link.linkSource, TrackingLinkSource.manual);
      expect(primary.searches, isEmpty);
      expect(primary.pushed.single.mapping.subjectId, 999);
    });

    test('a mixed-script file name links through its parts', () async {
      primary.catalogue.add(
        const TrackingBookSubject(
          subjectId: 5501,
          name: '14-sai no Koi',
          kind: TrackingKind.manga,
          titles: <String>['14歳の恋', '14-sai no Koi'],
          authors: <String>['水谷フーカ'],
          finalVolume: 9,
          isFinished: true,
        ),
      );
      const String key = '14 Sai no Koi [水谷フーカ] 14歳の恋 第01巻';
      await insertBook(key, format: 'manga');

      await finish(key);

      final MediaTrackingMappingRow? link = await mapping(_defaultId, key);
      expect(link?.subjectId, 5501);
      expect(link?.kind, TrackingKind.manga.value);
      expect(link?.progressMode, TrackingProgressMode.volume.value);
      expect(link?.progressOffset, 1);
      expect(primary.searches.length, lessThanOrEqualTo(kBookLinkMaxSearches));
    });

    test('a katakana title finds the hiragana entry', () async {
      primary.catalogue.add(
        const TrackingBookSubject(
          subjectId: 6766,
          name: 'Yotsuba&!',
          kind: TrackingKind.manga,
          titles: <String>['よつばと!'],
        ),
      );
      await insertBook('ヨツバと! 第3巻', format: 'manga');

      await finish('ヨツバと! 第3巻');

      final MediaTrackingMappingRow? link = await mapping(
        _defaultId,
        'ヨツバと! 第3巻',
      );
      expect(link?.subjectId, 6766);
      expect(link?.progressOffset, 3);
      expect(primary.searches, contains('よつばと!'));
      expect(primary.searches.length, lessThanOrEqualTo(kBookLinkMaxSearches));
    });

    test('approving a suggestion links it and sends progress', () async {
      primary.catalogue.add(_lotm);
      await insertBook('诡秘之主');
      await finish('诡秘之主');
      // The reader stores the finish; approving sends from what is stored.
      await db.setEpubBookCompleted('诡秘之主', DateTime(2026, 11, 6));
      final MediaTrackingSuggestionRow suggestion = (await suggestionsOf(
        '诡秘之主',
      )).single;

      await service.approveSuggestion(suggestion);
      await service.syncNow();

      final MediaTrackingMappingRow? link = await mapping(_defaultId, '诡秘之主');
      expect(link?.subjectId, 84351);
      expect(link?.linkSource, TrackingLinkSource.suggestion);
      expect(link?.confidence, suggestion.score);
      expect(link?.progressMode, TrackingProgressMode.volume.value);
      expect(link?.progressOffset, 1, reason: 'no volume number: volume 1');
      final PendingTrackingUpdate sent = primary.pushed.single;
      expect(sent.mapping.subjectId, 84351);
      expect(sent.outbox.progress, 1);
      expect(sent.outbox.completed, isTrue);

      await service.setBookLinkVolume(
        bookKey: '诡秘之主',
        providerId: _defaultId,
        volume: 4,
      );
      await service.syncNow();
      expect((await mapping(_defaultId, '诡秘之主'))?.progressOffset, 4);
      expect(primary.pushed.last.outbox.progress, 4);
    });

    test('a dismissed suggestion is hidden and not searched again', () async {
      primary.catalogue.add(_lotm);
      await insertBook('诡秘之主');
      await finish('诡秘之主');
      final MediaTrackingSuggestionRow suggestion = (await suggestionsOf(
        '诡秘之主',
      )).single;

      await service.dismissSuggestion(suggestion.id);
      final int searched = primary.searches.length;
      await service.refreshBookLinks('诡秘之主');

      final BookTrackingOverview? overview = await service.loadBookTracking(
        '诡秘之主',
      );
      final BookTrackingSite site = overview!.sites.first;
      expect(site.providerId, _defaultId, reason: 'default site first');
      expect(site.isDefaultSite, isTrue);
      expect(site.suggestions, isEmpty);
      expect(site.link, isNull);
      expect(overview.sites.map((BookTrackingSite s) => s.providerId), <String>[
        _defaultId,
        _otherId,
      ]);
      expect(primary.searches, hasLength(searched));
      expect(await mapping(_defaultId, '诡秘之主'), isNull);
    });

    test('an unlinked item is not linked again by itself', () async {
      primary.catalogue.add(_bakeNovel);
      await insertBook('化物語 第1巻');
      await finish('化物語 第1巻');
      expect(await mapping(_defaultId, '化物語 第1巻'), isNotNull);
      final int searched = primary.searches.length;

      await service.unlinkBook(bookKey: '化物語 第1巻', providerId: _defaultId);
      await finish('化物語 第1巻');
      await service.refreshBookLinks('化物語 第1巻');

      expect(await mapping(_defaultId, '化物語 第1巻'), isNull);
      expect(primary.searches, hasLength(searched));
      final BookTrackingSite site = (await service.loadBookTracking(
        '化物語 第1巻',
      ))!.sites.first;
      expect(site.link, isNull);
      expect(site.suggestions, isEmpty, reason: 'kept as dismissed');
    });

    test('manual search by id and by link, only of the book kind', () async {
      primary.catalogue.addAll(<TrackingBookSubject>[_bakeNovel, _bakeManga]);
      await insertBook('化物語 第1巻');

      Future<List<TrackingBookSubject>> search(String query) =>
          service.searchBookSubjects(
            providerId: _defaultId,
            bookKey: '化物語 第1巻',
            query: query,
          );

      expect(
        (await search('84547')).map((TrackingBookSubject s) => s.subjectId),
        <int>[84547],
      );
      final List<TrackingBookSubject> byLink = await search(
        'https://www.example.org/series/84547',
      );
      expect(byLink.single.subjectId, 84547);
      expect(
        primary.searches,
        isEmpty,
        reason: 'ids are looked up, not searched',
      );
      expect(
        await search('7426'),
        isEmpty,
        reason: 'the manga is the wrong kind for a book',
      );
      expect(
        await search('https://other.test/84547'),
        isEmpty,
        reason: 'a link to another site is no id here',
      );
      expect(
        (await search('化物語')).map((TrackingBookSubject s) => s.subjectId),
        <int>[84547],
        reason: 'a title search keeps the book kind',
      );

      await service.linkBookToSubject(
        bookKey: '化物語 第1巻',
        providerId: _defaultId,
        subject: byLink.single,
      );
      final MediaTrackingMappingRow? link = await mapping(
        _defaultId,
        '化物語 第1巻',
      );
      expect(link?.subjectId, 84547);
      expect(link?.linkSource, TrackingLinkSource.manual);
      expect(link?.progressMode, TrackingProgressMode.volume.value);
      expect(link?.progressOffset, 1);
    });

    test('a manual link of the wrong kind is refused', () async {
      await insertBook('化物語 第1巻');

      await expectLater(
        service.linkBookToSubject(
          bookKey: '化物語 第1巻',
          providerId: _defaultId,
          subject: _bakeManga,
        ),
        throwsArgumentError,
      );
      expect(await mapping(_defaultId, '化物語 第1巻'), isNull);
    });

    // Audit gap 4: a PDF was always a novel, even linked by hand.
    group('a PDF linked as manga', () {
      test('the Track sheet offers novel or manga, novel by default', () async {
        await insertBook('化物語 01.pdf', format: 'pdf');
        final BookTrackingOverview overview = (await service.loadBookTracking(
          '化物語 01.pdf',
        ))!;
        expect(overview.kinds, <TrackingKind>[
          TrackingKind.novel,
          TrackingKind.manga,
        ]);
        expect(overview.kind, TrackingKind.novel);
        await insertBook('化物語 第1巻');
        expect(
          (await service.loadBookTracking('化物語 第1巻'))!.kinds,
          <TrackingKind>[TrackingKind.novel],
          reason: 'an EPUB has no choice',
        );
      });

      test('linked by hand as manga: kind kept, progress sent, the sheet '
          'and the other sites follow', () async {
        primary.catalogue.addAll(<TrackingBookSubject>[_bakeNovel, _bakeManga]);
        await insertBook('化物語 01.pdf', format: 'pdf');
        final List<TrackingBookSubject> found = await service
            .searchBookSubjects(
              providerId: _defaultId,
              bookKey: '化物語 01.pdf',
              query: '化物語',
              asKind: TrackingKind.manga,
            );
        expect(found.single.subjectId, _bakeManga.subjectId);

        await service.linkBookToSubject(
          bookKey: '化物語 01.pdf',
          providerId: _defaultId,
          subject: _bakeManga,
          asKind: TrackingKind.manga,
        );
        final MediaTrackingMappingRow link = (await mapping(
          _defaultId,
          '化物語 01.pdf',
        ))!;
        expect(link.kind, TrackingKind.manga.value);
        expect(link.progressMode, TrackingProgressMode.volume.value);
        expect(
          (await service.loadBookTracking('化物語 01.pdf'))!.kind,
          TrackingKind.manga,
          reason: 'the link says manga',
        );

        primary.pushed.clear();
        await db.setEpubBookCompleted('化物語 01.pdf', DateTime(2026));
        await finish('化物語 01.pdf');
        expect(
          primary.pushed.map((PendingTrackingUpdate u) => u.mapping.kind),
          contains(TrackingKind.manga.value),
          reason: 'the wrong-kind guard lets a manga PDF through',
        );
      });

      test('an EPUB with a manga link is still refused (BUG-1318)', () async {
        await insertBook('化物語 第1巻');
        await repository.saveMapping(
          mediaType: TrackingMediaType.book,
          mediaKey: '化物語 第1巻',
          mediaTitle: '化物語 第1巻',
          kind: TrackingKind.manga,
          subjectId: _bakeManga.subjectId,
          subjectName: 'Bakemonogatari',
          progressMode: TrackingProgressMode.volume,
          progressOffset: 1,
          provider: _defaultId,
        );
        await finish('化物語 第1巻');
        expect(
          primary.pushed.where(
            (PendingTrackingUpdate u) => u.mapping.kind == 'manga',
          ),
          isEmpty,
        );
        expect(
          () => service.linkBookToSubject(
            bookKey: '化物語 第1巻',
            providerId: _defaultId,
            subject: _bakeManga,
            asKind: TrackingKind.manga,
          ),
          throwsArgumentError,
        );
      });
    });
  });
}
