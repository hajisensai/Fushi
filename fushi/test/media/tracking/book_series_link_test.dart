// Series-level book links: one link on a series card counts every volume
// of the card, also ones added later (design notes section E).
import 'dart:async';

import 'package:drift/drift.dart'
    show ApplyInterceptor, QueryExecutor, QueryInterceptor, Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/tracking/book_series_link.dart';
import 'package:fushi_engine/media/tracking/book_tracking_link.dart';
import 'package:fushi_engine/media/tracking/media_tracking_recent_sends.dart'
    show MediaTrackingRecentSend;
import 'package:fushi_engine/media/tracking/media_tracking_repository.dart';
import 'package:fushi_engine/media/tracking/media_tracking_service.dart';
import 'package:fushi_engine/media/tracking/tracking_provider.dart';

const String _defaultId = 'fake_default';
const String _otherId = 'fake_other';

final class _FakeSession implements TrackingProviderSession {
  @override
  void close() {}
}

final class _FakeBookSite implements TrackingProvider, TrackingBookLinker {
  _FakeBookSite(this.id, {required bool isDefault})
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
  String get siteHost => '$id.test';

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

/// Counts the SELECTs the database runs (BUG-5372: the tracking page's
/// series planning must not grow with the number of links).
final class _SelectCounter extends QueryInterceptor {
  int selects = 0;

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    selects++;
    return executor.runSelect(statement, args);
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

/// A finished 17-volume manga, known on the other site as 9001.
const TrackingBookSubject _ajin = TrackingBookSubject(
  subjectId: 700,
  name: 'Ajin',
  titles: <String>['亜人', 'Ajin: Demi-Human'],
  kind: TrackingKind.manga,
  finalVolume: 17,
  isFinished: true,
  linkedIds: <String, int>{_otherId: 9001},
);

TrackingSeriesMemberFacts _fact(
  String key, {
  int? volume,
  String? series = 'ajin',
  bool started = false,
  bool finished = false,
  bool excluded = false,
  bool private = false,
  bool otherKind = false,
  bool ownLink = false,
}) => TrackingSeriesMemberFacts(
  bookKey: key,
  title: key,
  volume: volume,
  seriesKey: series,
  started: started || finished,
  finished: finished,
  evidenceAt: volume ?? 0,
  excluded: excluded,
  private: private,
  otherKind: otherKind,
  ownLink: ownLink,
);

void main() {
  group('planSeriesCoverage', () {
    test('the highest finished volume; the one being read counts the one '
        'before it', () {
      final TrackingSeriesCoverage coverage =
          planSeriesCoverage(<TrackingSeriesMemberFacts>[
            _fact('v1', volume: 1, finished: true),
            _fact('v2', volume: 2, finished: true),
            _fact('v4', volume: 4, started: true),
            _fact('v5', volume: 5),
          ]);
      expect(coverage.progress?.progress, 3);
      expect(coverage.progress?.completed, isFalse);
      expect(
        coverage.members.every((TrackingSeriesMember m) => m.counted),
        isTrue,
      );
    });

    test('finishing the highest volume completes it', () {
      final TrackingSeriesCoverage coverage = planSeriesCoverage(
        <TrackingSeriesMemberFacts>[
          _fact('v1', volume: 1, finished: true),
          _fact('v2', volume: 2, finished: true),
        ],
      );
      expect(coverage.progress, (progress: 2, completed: true, evidenceAt: 2));
    });

    test('nothing started sends nothing', () {
      expect(
        planSeriesCoverage(<TrackingSeriesMemberFacts>[
          _fact('v1', volume: 1),
        ]).progress,
        isNull,
      );
    });

    test('excluded, own-link, private and other-kind volumes are not '
        'counted', () {
      final TrackingSeriesCoverage coverage =
          planSeriesCoverage(<TrackingSeriesMemberFacts>[
            _fact('v1', volume: 1, finished: true),
            _fact('v2', volume: 2, finished: true, excluded: true),
            _fact('v3', volume: 3, finished: true, ownLink: true),
            _fact('v4', volume: 4, finished: true, private: true),
            _fact('v5', volume: 5, finished: true, otherKind: true),
          ]);
      expect(coverage.progress?.progress, 1);
      expect(
        coverage.members.map((TrackingSeriesMember m) => m.state),
        <TrackingSeriesMemberState>[
          TrackingSeriesMemberState.counted,
          TrackingSeriesMemberState.excluded,
          TrackingSeriesMemberState.ownLink,
          TrackingSeriesMemberState.private,
          TrackingSeriesMemberState.otherKind,
        ],
      );
    });

    test('no volume numbered at all: the card position counts', () {
      final TrackingSeriesCoverage coverage = planSeriesCoverage(
        <TrackingSeriesMemberFacts>[
          _fact('a', finished: true),
          _fact('b', finished: true),
          _fact('c'),
        ],
      );
      expect(coverage.numberedByPosition, isTrue);
      expect(coverage.members.map((TrackingSeriesMember m) => m.volume), <int>[
        1,
        2,
        3,
      ]);
      expect(coverage.progress?.progress, 2);
    });

    test('in a numbered series a volume without a number is not counted', () {
      final TrackingSeriesCoverage coverage = planSeriesCoverage(
        <TrackingSeriesMemberFacts>[
          _fact('v1', volume: 1, finished: true),
          _fact('extra', finished: true),
        ],
      );
      expect(coverage.numberedByPosition, isFalse);
      expect(
        coverage.memberOf('extra')?.state,
        TrackingSeriesMemberState.noNumber,
      );
      expect(coverage.progress?.progress, 1);
    });

    test('a spin-off grouped in by mistake is not counted', () {
      final TrackingSeriesCoverage coverage =
          planSeriesCoverage(<TrackingSeriesMemberFacts>[
            _fact('v1', volume: 1, finished: true),
            _fact('v2', volume: 2, finished: true),
            _fact(
              'side 12',
              volume: 12,
              series: 'ajin side story',
              finished: true,
            ),
          ]);
      expect(
        coverage.memberOf('side 12')?.state,
        TrackingSeriesMemberState.otherSeries,
      );
      expect(coverage.progress?.progress, 2, reason: 'no over-claim');
    });
  });

  group('series links with fake sites', () {
    late FushiDatabase db;
    late PreferencesRepository preferences;
    late MediaTrackingRepository repository;
    late _FakeBookSite primary;
    late _FakeBookSite other;
    late MediaTrackingService service;
    late _SelectCounter queries;

    setUp(() async {
      queries = _SelectCounter();
      db = FushiDatabase.forTesting(
        NativeDatabase.memory().interceptWith(queries),
      );
      preferences = PreferencesRepository(db);
      await preferences.loadFromDb();
      repository = MediaTrackingRepository(db);
      primary = _FakeBookSite(_defaultId, isDefault: true);
      other = _FakeBookSite(_otherId, isDefault: false);
      service = MediaTrackingService(
        repository: repository,
        preferences: preferences,
        userAgent: 'test',
        retryTimerFactory: (Duration delay, void Function() callback) =>
            _NoTimer(),
        extraProviders: <TrackingProvider>[other, primary],
        bookLinkHints: (EpubBookRow book) async => null,
      );
    });

    tearDown(() async {
      service.dispose();
      preferences.dispose();
      await db.close();
    });

    Future<void> insertBook(String title) => db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: title,
        title: title,
        epubPath: '/tmp/$title',
        extractDir: '/tmp/$title',
        chapterCount: 10,
        chaptersJson: '[]',
        importedAt: 1,
        format: const Value<String>('manga'),
        uid: Value<String>('uid:$title'),
      ),
    );

    /// The organiser's series card holding [titles] (books added first).
    Future<int> seriesCard(String name, List<String> titles) async {
      final int id = await db.createMediaCollection(
        name,
        collectionType: 'playlist',
        origin: CollectionOrigin.rule,
      );
      for (final String title in titles) {
        await db.addToCollection(
          id,
          MediaKind.epub,
          'uid:$title',
          userIntent: false,
        );
      }
      return id;
    }

    Future<void> markFinished(String bookKey) =>
        (db.update(
          db.epubBooks,
        )..where((t) => t.bookKey.equals(bookKey))).write(
          EpubBooksCompanion(completedAt: Value<DateTime>(DateTime.now())),
        );

    Future<void> finish(String bookKey) async {
      await markFinished(bookKey);
      await service.recordBookProgress(
        bookKey: bookKey,
        completedChapterCount: 10,
        completed: true,
      );
      await service.whenBookLinksSettled();
      await service.syncNow();
    }

    Future<MediaTrackingMappingRow?> seriesLink(String provider, int card) =>
        repository.findMapping(
          mediaType: TrackingMediaType.bookCollection,
          mediaKey: '$card',
          provider: provider,
        );

    Future<MediaTrackingMappingRow?> bookLink(String provider, String key) =>
        repository.findMapping(
          mediaType: TrackingMediaType.book,
          mediaKey: key,
          provider: provider,
        );

    test('a sure match for a volume of a series card links the whole card; '
        'a volume added later is covered without a search', () async {
      primary.catalogue.add(_ajin);
      await insertBook('Ajin 01');
      await insertBook('Ajin 02');
      final int card = await seriesCard('Ajin', <String>['Ajin 01', 'Ajin 02']);

      await finish('Ajin 01');

      final MediaTrackingMappingRow? link = await seriesLink(_defaultId, card);
      expect(link, isNotNull);
      expect(link!.subjectId, 700);
      expect(link.progressMode, TrackingProgressMode.volume.value);
      expect(link.progressOffset, 0);
      expect(link.mediaTitle, 'Ajin');
      expect(link.linkSource, TrackingLinkSource.auto);
      expect(
        await bookLink(_defaultId, 'Ajin 01'),
        isNull,
        reason: 'no per-volume link',
      );
      expect(primary.pushed.last.mapping.id, link.id);
      expect(primary.pushed.last.outbox.progress, 1);

      // Volume 3 arrives next month.
      final int searches = primary.searches.length;
      await insertBook('Ajin 03');
      await db.addToCollection(
        card,
        MediaKind.epub,
        'uid:Ajin 03',
        userIntent: false,
      );
      await finish('Ajin 03');

      expect(primary.searches.length, searches, reason: 'already covered');
      expect(await bookLink(_defaultId, 'Ajin 03'), isNull);
      expect(primary.pushed.last.mapping.id, link.id);
      expect(primary.pushed.last.outbox.progress, 3);
      final List<MediaTrackingUnlinkedItem> unlinked = await repository
          .listUnlinkedHistory(provider: _defaultId);
      expect(
        unlinked.where(
          (MediaTrackingUnlinkedItem item) =>
              item.mediaType == TrackingMediaType.book,
        ),
        isEmpty,
        reason: 'covered volumes are not unlinked',
      );
    });

    test('the home snapshot names the book of the volume a series link '
        'sent, by its number and not its place on the card', () async {
      primary.catalogue.add(_ajin);
      for (final String t in <String>['Ajin 01', 'Ajin 02', 'Ajin 03']) {
        await insertBook(t);
      }
      // Volume 3 sits first on the card: a position-based pick would be
      // wrong.
      final int card = await seriesCard('Ajin', <String>[
        'Ajin 03',
        'Ajin 01',
        'Ajin 02',
      ]);
      await service.linkSeriesToSubject(
        collectionId: card,
        providerId: _defaultId,
        subject: _ajin,
      );
      await finish('Ajin 01');
      await finish('Ajin 02');
      expect(primary.pushed.last.outbox.progress, 2);

      final MediaTrackingHomeSnapshot snapshot = await service
          .loadHomeSnapshot();
      final MediaTrackingRecentSend send = snapshot.recentSends().first;
      expect(send.mediaType, TrackingMediaType.bookCollection.value);
      expect(send.progress, 2);
      expect(snapshot.seriesVolumeBookOf(send), 'Ajin 02');
      // A locked volume is not offered for its cover.
      expect(
        snapshot
            .withoutMedia(
              (String type, String key) =>
                  type == TrackingMediaType.book.value && key == 'Ajin 02',
            )
            .seriesVolumeBookOf(send),
        isNull,
      );
    });

    test('a volume with its own link counts on its own; an excluded volume '
        'is not counted', () async {
      primary.catalogue.add(_ajin);
      for (final String t in <String>['Ajin 01', 'Ajin 02', 'Ajin 03']) {
        await insertBook(t);
      }
      final int card = await seriesCard('Ajin', <String>[
        'Ajin 01',
        'Ajin 02',
        'Ajin 03',
      ]);
      await service.linkSeriesToSubject(
        collectionId: card,
        providerId: _defaultId,
        subject: _ajin,
      );
      await service.ignoreItem(
        mediaType: TrackingMediaType.book,
        mediaKey: 'Ajin 03',
        mediaTitle: 'Ajin 03',
      );
      await markFinished('Ajin 03');
      await finish('Ajin 01');

      final MediaTrackingMappingRow link = (await seriesLink(
        _defaultId,
        card,
      ))!;
      TrackingSeriesCoverage coverage = await service.seriesCoverage(link);
      expect(coverage.progress?.progress, 1, reason: 'volume 3 excluded');
      expect(
        coverage.memberOf('Ajin 03')?.state,
        TrackingSeriesMemberState.excluded,
      );

      // "Change volume number" on volume 2: its own link, as volume 5.
      await service.setSeriesVolumeNumber(
        bookKey: 'Ajin 02',
        providerId: _defaultId,
        volume: 5,
      );
      final MediaTrackingMappingRow? own = await bookLink(
        _defaultId,
        'Ajin 02',
      );
      expect(own?.subjectId, 700);
      expect(own?.progressOffset, 5);
      coverage = await service.seriesCoverage(link);
      expect(
        coverage.memberOf('Ajin 02')?.state,
        TrackingSeriesMemberState.ownLink,
      );

      // "Count again": volume 3 is counted and its finish goes out.
      await service.trackAgain(
        mediaType: TrackingMediaType.book.value,
        mediaKey: 'Ajin 03',
      );
      await service.syncNow();
      coverage = await service.seriesCoverage(link);
      expect(coverage.progress?.progress, 3);
      expect(primary.pushed.last.mapping.id, link.id);
      expect(primary.pushed.last.outbox.progress, 3);
    });

    test('the other site links the series from the id the default site '
        'gave', () async {
      primary.catalogue.add(_ajin);
      other.catalogue.add(
        const TrackingBookSubject(
          subjectId: 9001,
          name: 'Ajin',
          kind: TrackingKind.manga,
        ),
      );
      await service.setKindEnabled(_otherId, TrackingKind.manga, true);
      await insertBook('Ajin 01');
      await insertBook('Ajin 02');
      final int card = await seriesCard('Ajin', <String>['Ajin 01', 'Ajin 02']);

      await finish('Ajin 01');

      final MediaTrackingMappingRow? there = await seriesLink(_otherId, card);
      expect(there?.subjectId, 9001);
      expect(there?.linkSource, TrackingLinkSource.id);
      expect(other.searches, isEmpty);
      expect(other.pushed.last.outbox.progress, 1);
    });

    test(
      'a match that cannot hold every volume links only the volume',
      () async {
        primary.catalogue.add(
          const TrackingBookSubject(
            subjectId: 701,
            name: 'Ajin',
            kind: TrackingKind.manga,
            finalVolume: 2,
            isFinished: true,
          ),
        );
        for (final String t in <String>['Ajin 01', 'Ajin 02', 'Ajin 09']) {
          await insertBook(t);
        }
        final int card = await seriesCard('Ajin', <String>[
          'Ajin 01',
          'Ajin 02',
          'Ajin 09',
        ]);

        await finish('Ajin 01');

        expect(await seriesLink(_defaultId, card), isNull);
        expect((await bookLink(_defaultId, 'Ajin 01'))?.progressOffset, 1);
      },
    );

    test('a removed series link leaves the series to the user', () async {
      primary.catalogue.add(_ajin);
      await insertBook('Ajin 01');
      await insertBook('Ajin 02');
      final int card = await seriesCard('Ajin', <String>['Ajin 01', 'Ajin 02']);
      await finish('Ajin 01');
      await service.removeLink((await seriesLink(_defaultId, card))!);

      await finish('Ajin 02');

      expect(await seriesLink(_defaultId, card), isNull);
      expect(await bookLink(_defaultId, 'Ajin 02'), isNull);
    });

    test('the page\'s series planning takes the same number of queries '
        'however many links (BUG-5372)', () async {
      int next = 0;

      /// One card whose two volume links one series link could replace, and
      /// one series-linked card with a volume that has no number.
      Future<void> addCards() async {
        final int n = next++;
        final List<String> merge = <String>['M$n 01', 'M$n 02'];
        final List<String> linked = <String>['L$n 01', 'L$n 02', 'L$n'];
        for (final String t in <String>[...merge, ...linked]) {
          await insertBook(t);
        }
        await seriesCard('M$n', merge);
        for (int v = 1; v <= merge.length; v++) {
          await repository.saveMapping(
            mediaType: TrackingMediaType.book,
            mediaKey: merge[v - 1],
            mediaTitle: merge[v - 1],
            kind: TrackingKind.manga,
            subjectId: 800 + n,
            subjectName: 'M$n',
            progressMode: TrackingProgressMode.volume,
            progressOffset: v,
            provider: _defaultId,
            linkSource: TrackingLinkSource.auto,
          );
        }
        final int card = await seriesCard('L$n', linked);
        await repository.saveMapping(
          mediaType: TrackingMediaType.bookCollection,
          mediaKey: '$card',
          mediaTitle: 'L$n',
          kind: TrackingKind.manga,
          subjectId: 900 + n,
          subjectName: 'L$n',
          progressMode: TrackingProgressMode.volume,
          progressOffset: 0,
          provider: _defaultId,
        );
      }

      Future<(int, int)> planAndCount() async {
        queries.selects = 0;
        final int candidates = (await service.seriesMergeCandidates()).length;
        final int waiting =
            (await service.seriesVolumesNeedingAttention()).length;
        // What the tracking page itself loads for the Linked tab (and its
        // attention rows): every series link's coverage, progress included.
        final Map<int, TrackingSeriesCoverage> coverage = await service
            .seriesCoverages(await repository.listMappings());
        expect(candidates, next);
        expect(waiting, next);
        expect(
          coverage.values
              .where(
                (TrackingSeriesCoverage c) =>
                    c.countOf(TrackingSeriesMemberState.noNumber) == 1,
              )
              .length,
          next,
        );
        return (queries.selects, candidates);
      }

      for (int i = 0; i < 2; i++) {
        await addCards();
      }
      final (int few, _) = await planAndCount();
      for (int i = 0; i < 8; i++) {
        await addCards();
      }
      final (int many, _) = await planAndCount();

      expect(many, few, reason: '10 cards cost what 2 cards cost');
    });

    group('merging per-volume links into a series link', () {
      late int card;

      Future<void> volumeLink(String key, int subject, int volume) =>
          repository.saveMapping(
            mediaType: TrackingMediaType.book,
            mediaKey: key,
            mediaTitle: key,
            kind: TrackingKind.manga,
            subjectId: subject,
            subjectName: 'Ajin',
            progressMode: TrackingProgressMode.volume,
            progressOffset: volume,
            provider: _defaultId,
            linkSource: TrackingLinkSource.auto,
          );

      setUp(() async {
        for (final String t in <String>['Ajin 01', 'Ajin 02', 'Ajin 03']) {
          await insertBook(t);
        }
        card = await seriesCard('Ajin', <String>[
          'Ajin 01',
          'Ajin 02',
          'Ajin 03',
        ]);
        await volumeLink('Ajin 01', 700, 1);
        await volumeLink('Ajin 02', 700, 2);
        // Another number: an override, kept.
        await volumeLink('Ajin 03', 700, 7);
        for (final String key in <String>['Ajin 01', 'Ajin 02']) {
          final MediaTrackingMappingRow row = (await bookLink(
            _defaultId,
            key,
          ))!;
          await repository.adoptSentProgress(
            row.id,
            progress: row.progressOffset,
            completed: true,
          );
          await markFinished(key);
        }
        // A site that has synced before (its first catch-up resends all).
        await preferences.setPref(
          TrackingProviderPrefKeys.forProvider(_defaultId).bookWatermark,
          1,
        );
      });

      test('sync never merges them on its own; they are offered', () async {
        await service.syncNow();

        expect(await seriesLink(_defaultId, card), isNull);
        expect(await bookLink(_defaultId, 'Ajin 01'), isNotNull);
        final List<TrackingSeriesMergeCandidate> offered = await service
            .seriesMergeCandidates();
        expect(offered, hasLength(1));
        expect(offered.single.collectionId, card);
        expect(offered.single.subjectId, 700);
        expect(offered.single.seriesLink, isNull);
        expect(<String>[
          for (final MediaTrackingMappingRow row in offered.single.volumeLinks)
            row.mediaKey,
        ], unorderedEquals(<String>['Ajin 01', 'Ajin 02']));
      });

      test('confirming merges them into one series link, sending '
          'nothing', () async {
        final TrackingSeriesMergeCandidate candidate =
            (await service.seriesMergeCandidates()).single;

        expect(await service.mergeSeriesLinks(candidate), isTrue);
        await service.syncNow();

        final MediaTrackingMappingRow? series = await seriesLink(
          _defaultId,
          card,
        );
        expect(series?.subjectId, 700);
        expect(series?.sentProgress, 2);
        expect(await bookLink(_defaultId, 'Ajin 01'), isNull);
        expect(await bookLink(_defaultId, 'Ajin 02'), isNull);
        expect((await bookLink(_defaultId, 'Ajin 03'))?.progressOffset, 7);
        expect(primary.pushed, isEmpty, reason: 'the merge sends nothing');
        expect(await service.seriesMergeCandidates(), isEmpty);
      });

      test("a volume finished while its link's row still waited is sent "
          'through the series link after the merge', () async {
        // Ajin 02 was finished offline: its link has not sent it yet and its
        // row waits in the outbox. The merge removes that row with the link.
        await db.customStatement(
          'UPDATE media_tracking_mappings SET sent_progress = NULL, '
          "sent_completed = 0 WHERE media_key = 'Ajin 02'",
        );
        expect(
          await repository.enqueueProgress(
            mediaType: TrackingMediaType.book,
            mediaKey: 'Ajin 02',
            localProgress: 0,
            completed: true,
            provider: _defaultId,
          ),
          isTrue,
        );
        final TrackingSeriesMergeCandidate candidate =
            (await service.seriesMergeCandidates()).single;

        expect(await service.mergeSeriesLinks(candidate), isTrue);
        await service.syncNow();

        final MediaTrackingMappingRow series = (await seriesLink(
          _defaultId,
          card,
        ))!;
        expect(primary.pushed, isNotEmpty);
        expect(primary.pushed.last.mapping.id, series.id);
        expect(primary.pushed.last.outbox.progress, 2);
        expect(primary.pushed.last.outbox.completed, isTrue);
        expect(
          primary.pushed.where(
            (PendingTrackingUpdate u) => u.outbox.progress < 2,
          ),
          isEmpty,
          reason: 'volume 1 was sent already',
        );
      });

      test('the merge is one transaction: a failure part way leaves every '
          'link as it was', () async {
        final TrackingSeriesMergeCandidate candidate =
            (await service.seriesMergeCandidates()).single;
        // Fail the second delete, after the series link was written and the
        // first volume link removed.
        await db.customStatement(
          'CREATE TEMP TRIGGER fail_merge BEFORE DELETE ON '
          "media_tracking_mappings WHEN old.media_key = 'Ajin 02' "
          "BEGIN SELECT RAISE(ABORT, 'boom'); END",
        );

        await expectLater(
          service.mergeSeriesLinks(candidate),
          throwsA(anything),
        );

        expect(await seriesLink(_defaultId, card), isNull);
        expect(await bookLink(_defaultId, 'Ajin 01'), isNotNull);
        expect(await bookLink(_defaultId, 'Ajin 02'), isNotNull);
      });

      test("\"Don't merge\" is remembered for that card", () async {
        final TrackingSeriesMergeCandidate candidate =
            (await service.seriesMergeCandidates()).single;

        await service.declineSeriesMerge(candidate);

        expect(await service.seriesMergeCandidates(), isEmpty);
        expect(await service.mergeSeriesLinks(candidate), isFalse);
        expect(await seriesLink(_defaultId, card), isNull);
        expect(await bookLink(_defaultId, 'Ajin 01'), isNotNull);
      });

      test('volume links next to a series link to the same entry are '
          'offered for folding into it', () async {
        primary.catalogue.add(_ajin);
        await repository.saveMapping(
          mediaType: TrackingMediaType.bookCollection,
          mediaKey: '$card',
          mediaTitle: 'Ajin',
          kind: TrackingKind.manga,
          subjectId: 700,
          subjectName: 'Ajin',
          progressMode: TrackingProgressMode.volume,
          progressOffset: 0,
          provider: _defaultId,
        );

        final TrackingSeriesMergeCandidate candidate =
            (await service.seriesMergeCandidates()).single;
        expect(candidate.seriesLink, isNotNull);
        expect(await service.mergeSeriesLinks(candidate), isTrue);

        expect(await bookLink(_defaultId, 'Ajin 01'), isNull);
        expect(await bookLink(_defaultId, 'Ajin 02'), isNull);
        expect((await seriesLink(_defaultId, card))?.sentProgress, 2);
      });
    });

    test(
      'a deleted series card leaves an orphan link that sends nothing',
      () async {
        primary.catalogue.add(_ajin);
        await insertBook('Ajin 01');
        await insertBook('Ajin 02');
        final int card = await seriesCard('Ajin', <String>[
          'Ajin 01',
          'Ajin 02',
        ]);
        await service.linkSeriesToSubject(
          collectionId: card,
          providerId: _defaultId,
          subject: _ajin,
        );
        final MediaTrackingMappingRow link = (await seriesLink(
          _defaultId,
          card,
        ))!;
        await db.deleteMediaCollection(card);

        expect(await service.orphanSeriesLinkIds(), <int>{link.id});
        expect((await service.seriesCoverage(link)).progress, isNull);
      },
    );

    test(
      'the Track sheet shows how the series link counts the volume',
      () async {
        primary.catalogue.add(_ajin);
        await insertBook('Ajin 01');
        await insertBook('Ajin 02');
        final int card = await seriesCard('Ajin', <String>[
          'Ajin 01',
          'Ajin 02',
        ]);
        await service.linkSeriesToSubject(
          collectionId: card,
          providerId: _defaultId,
          subject: _ajin,
        );

        final BookTrackingOverview overview = (await service.loadBookTracking(
          'Ajin 02',
        ))!;
        expect(overview.seriesCard, (id: card, name: 'Ajin'));
        final BookTrackingSite site = overview.sites.firstWhere(
          (BookTrackingSite s) => s.providerId == _defaultId,
        );
        expect(site.link, isNull);
        expect(site.seriesLink?.subjectId, 700);
        expect(site.seriesMember?.volume, 2);
        expect(site.seriesMember?.counted, isTrue);
      },
    );
  });
}
