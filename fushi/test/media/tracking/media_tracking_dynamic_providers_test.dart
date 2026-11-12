import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/tracking/bangumi_api_client.dart';
import 'package:fushi_engine/media/tracking/book_tracking_link.dart';
import 'package:fushi_engine/media/tracking/media_tracking_repository.dart';
import 'package:fushi_engine/media/tracking/media_tracking_service.dart';
import 'package:fushi_engine/media/tracking/tracking_provider.dart';

/// Bangumi that accepts everything and links nothing.
class _QuietBangumiApi implements BangumiTrackingApi {
  final List<Map<String, dynamic>> creates = <Map<String, dynamic>>[];

  @override
  Future<BangumiUser> getMe() async =>
      const BangumiUser(username: 'alice', nickname: 'Alice');

  @override
  Future<List<BangumiWatchedItem>> getWatchedAnime(String username) async =>
      const <BangumiWatchedItem>[];

  @override
  Future<List<BangumiSubject>> searchSubjects({
    required String keyword,
    required int subjectType,
  }) async => const <BangumiSubject>[];

  @override
  Future<BangumiSubject> getSubject(int subjectId) async =>
      const BangumiSubject(
        id: 7,
        type: 1,
        name: 'Remote book',
        nameCn: '',
        platform: '书籍',
        episodeCount: 0,
        volumeCount: 0,
      );

  @override
  Future<BangumiUserCollection?> getCollection(
    String username,
    int subjectId,
  ) async => null;

  @override
  Future<void> createCollection(
    int subjectId, {
    required Map<String, dynamic> payload,
  }) async => creates.add(payload);

  @override
  Future<void> patchCollection(
    int subjectId, {
    required Map<String, dynamic> payload,
  }) async {}

  @override
  Future<List<BangumiEpisode>> getMainEpisodes(int subjectId) async =>
      const <BangumiEpisode>[];

  @override
  Future<void> markEpisodesDone(int subjectId, List<int> episodeIds) async {}

  @override
  void close() {}
}

final class _Session implements TrackingProviderSession {
  bool closed = false;

  @override
  void close() => closed = true;
}

/// A plugin-like book site: records pushes; [gate] holds a push in flight.
final class _Site implements TrackingProvider, TrackingBookLinker {
  _Site(this.id);

  @override
  final String id;

  @override
  String get displayName => 'Site $id';

  @override
  String get siteHost => '$id.example';

  @override
  TrackingProviderCapabilities get capabilities =>
      const TrackingProviderCapabilities(
        kinds: <TrackingKind>{TrackingKind.novel, TrackingKind.manga},
        progressModes: <TrackingProgressMode>{
          TrackingProgressMode.chapter,
          TrackingProgressMode.volume,
        },
      );

  @override
  bool get isConfigured => true;

  Completer<void>? gate;
  Exception? pushError;
  int pushAttempts = 0;
  int searches = 0;

  /// When set, every title search waits for it (to hold a linking run).
  Completer<void>? searchGate;
  final List<PendingTrackingUpdate> pushed = <PendingTrackingUpdate>[];
  final List<_Session> sessions = <_Session>[];

  @override
  Future<TrackingProviderSession> openSession() async {
    final _Session session = _Session();
    sessions.add(session);
    return session;
  }

  @override
  Future<void> push(
    TrackingProviderSession session,
    PendingTrackingUpdate update,
  ) async {
    pushAttempts++;
    final Completer<void>? wait = gate;
    if (wait != null) await wait.future;
    final Exception? error = pushError;
    if (error != null) throw error;
    pushed.add(update);
  }

  @override
  TrackingFailureKind classify(Object error) => TrackingFailureKind.transient;

  @override
  Future<List<TrackingBookSubject>> searchBooks(
    String query,
    TrackingKind kind,
  ) async {
    searches++;
    final Completer<void>? wait = searchGate;
    if (wait != null) await wait.future;
    return const <TrackingBookSubject>[];
  }

  @override
  Future<TrackingBookSubject?> bookById(int subjectId) async => null;

  @override
  Future<TrackingBookSubject?> bookForLinkedId(
    String providerId,
    int subjectId,
  ) async => null;
}

void main() {
  late FushiDatabase db;
  late PreferencesRepository preferences;
  late MediaTrackingRepository repository;
  late _QuietBangumiApi api;
  late MediaTrackingService service;

  MediaTrackingService buildService(List<TrackingProvider> extra) =>
      MediaTrackingService(
        repository: repository,
        preferences: preferences,
        userAgent: 'test-agent',
        apiFactory: (_) => api,
        retryTimerFactory: (Duration delay, void Function() callback) =>
            Timer(const Duration(days: 1), () {}),
        extraProviders: extra,
      );

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    preferences = PreferencesRepository(db);
    await preferences.loadFromDb();
    await preferences.setPref(kBangumiAccessTokenPref, 'token');
    repository = MediaTrackingRepository(db);
    api = _QuietBangumiApi();
    service = buildService(const <TrackingProvider>[]);
  });

  tearDown(() async {
    service.dispose();
    preferences.dispose();
    await db.close();
  });

  Future<void> insertNovel(String bookKey) => db.insertEpubBook(
    EpubBooksCompanion.insert(
      bookKey: bookKey,
      title: 'Novel',
      epubPath: '/tmp/$bookKey.epub',
      extractDir: '/tmp/$bookKey',
      chapterCount: 12,
      chaptersJson: '[]',
      importedAt: 1,
    ),
  );

  Future<void> mapBook(String provider, {String bookKey = 'book'}) => repository
      .saveMapping(
        mediaType: TrackingMediaType.book,
        mediaKey: bookKey,
        mediaTitle: 'Novel',
        kind: TrackingKind.novel,
        subjectId: 7,
        subjectName: 'Remote novel',
        progressMode: TrackingProgressMode.chapter,
        progressOffset: 0,
        provider: provider,
      )
      .then((_) {});

  Future<void> enqueueBook(
    String provider, {
    String bookKey = 'book',
    int progress = 3,
  }) => repository
      .enqueueProgress(
        mediaType: TrackingMediaType.book,
        mediaKey: bookKey,
        localProgress: progress,
        completed: false,
        provider: provider,
      )
      .then((_) {});

  Future<List<PendingTrackingUpdate>> pendingOf(String provider) =>
      repository.allPending(provider: provider);

  Future<MediaTrackingMappingRow?> linkOf(
    String provider, {
    String bookKey = 'book',
  }) => repository.findMapping(
    mediaType: TrackingMediaType.book,
    mediaKey: bookKey,
    provider: provider,
  );

  /// The row is exactly as queued: never attempted, never failed.
  void expectUntouched(PendingTrackingUpdate row) {
    expect(row.outbox.attemptCount, 0);
    expect(row.outbox.lastError, isNull);
  }

  test('a site added at runtime is registered and synced', () async {
    await mapBook('late');
    await enqueueBook('late');
    await service.syncNow();
    expect((await pendingOf('late')).single.outbox.attemptCount, 0);

    final _Site late = _Site('late');
    final int revision = service.statusRevision.value;
    expect(service.setExtraProviders(<TrackingProvider>[late]), isEmpty);
    expect(service.statusRevision.value, greaterThan(revision));
    expect(service.providers.all.map((TrackingProvider p) => p.id), <String>[
      kTrackingProviderBangumi,
      'late',
    ]);

    // The new site's arrival already started a sync; this joins it.
    await service.syncNow();

    expect(late.pushed.single.outbox.progress, 3);
    expect(await pendingOf('late'), isEmpty);
  });

  test('a removed site sends nothing and keeps its link and queued update; '
      're-adding it sends the update', () async {
    final _Site site = _Site('site');
    service.setExtraProviders(<TrackingProvider>[site]);
    await service.syncNow();
    await insertNovel('book');
    await mapBook('site');
    await enqueueBook('site');

    service.setExtraProviders(const <TrackingProvider>[]);
    expect(service.providers.byId('site'), isNull);
    final MediaTrackingSyncResult result = await service.syncNow();
    // New reading while the site is gone is not queued for it.
    await service.recordBookProgress(
      bookKey: 'book',
      completedChapterCount: 9,
      completed: false,
    );
    await service.whenBookLinksSettled();
    await service.syncNow();

    expect(site.pushAttempts, 0);
    expect(site.searches, 0);
    expect(result.byProvider.keys, isNot(contains('site')));
    expect(await linkOf('site'), isNotNull);
    final PendingTrackingUpdate kept = (await pendingOf('site')).single;
    expectUntouched(kept);
    expect(kept.outbox.progress, 3);

    // Back (a fresh instance, as a re-enabled plugin would be).
    final _Site again = _Site('site');
    service.setExtraProviders(<TrackingProvider>[again]);
    await service.syncNow();

    expect(again.pushed, isNotEmpty);
    expect(again.pushed.first.outbox.progress, greaterThanOrEqualTo(3));
    expect(await pendingOf('site'), isEmpty);
    expect(site.pushAttempts, 0, reason: 'the old instance is never used');
  });

  test('duplicate ids: the first wins, the rest are returned', () async {
    final _Site first = _Site('dup');
    final _Site second = _Site('dup');
    final _Site fakeBangumi = _Site(kTrackingProviderBangumi);
    final _Site other = _Site('other');

    final List<TrackingProvider> ignored = service.setExtraProviders(
      <TrackingProvider>[first, second, fakeBangumi, other],
    );

    expect(ignored, <TrackingProvider>[second, fakeBangumi]);
    expect(service.providers.ignored, ignored);
    expect(service.providers.all.map((TrackingProvider p) => p.id), <String>[
      kTrackingProviderBangumi,
      'dup',
      'other',
    ]);
    expect(service.providers.byId('dup'), same(first));
    expect(
      service.providers.byId(kTrackingProviderBangumi),
      isNot(same(fakeBangumi)),
    );

    await service.syncNow(); // the round the new sites started
    await mapBook('dup');
    await enqueueBook('dup');
    await service.syncNow();
    expect(first.pushed, hasLength(1));
    expect(second.pushAttempts, 0);
    expect(fakeBangumi.pushAttempts, 0);
  });

  test('replacing the list during a sync: the running push finishes, the rest '
      'of the removed site waits untouched', () async {
    final _Site site = _Site('site');
    service.setExtraProviders(<TrackingProvider>[site]);
    await service.syncNow();
    await mapBook('site', bookKey: 'a');
    await mapBook('site', bookKey: 'b');
    await enqueueBook('site', bookKey: 'a');
    await enqueueBook('site', bookKey: 'b');
    final Completer<void> gate = Completer<void>();
    site.gate = gate;

    final Future<MediaTrackingSyncResult> running = service.syncNow();
    while (site.pushAttempts == 0) {
      await Future<void>.delayed(Duration.zero);
    }
    service.setExtraProviders(const <TrackingProvider>[]);
    gate.complete();
    final MediaTrackingSyncResult result = await running;

    expect(site.pushAttempts, 1, reason: 'no push after the removal');
    expect(site.pushed, hasLength(1));
    expect(site.sessions.single.closed, isTrue);
    expect(result.byProvider['site']?.succeeded, 1);
    final PendingTrackingUpdate left = (await pendingOf('site')).single;
    expectUntouched(left);

    site.gate = null;
    service.setExtraProviders(<TrackingProvider>[site]);
    await service.syncNow();
    expect(site.pushed, hasLength(2));
    expect(await pendingOf('site'), isEmpty);
  });

  test(
    'a push that fails because its site was removed is not marked failed',
    () async {
      final _Site site = _Site('site');
      service.setExtraProviders(<TrackingProvider>[site]);
      await service.syncNow();
      await mapBook('site');
      await enqueueBook('site');
      final Completer<void> gate = Completer<void>();
      site
        ..gate = gate
        ..pushError = Exception('plugin unloaded');

      final Future<MediaTrackingSyncResult> running = service.syncNow();
      while (site.pushAttempts == 0) {
        await Future<void>.delayed(Duration.zero);
      }
      service.setExtraProviders(const <TrackingProvider>[]);
      gate.complete();
      final MediaTrackingSyncResult result = await running;

      expect(result.failed, 0);
      expect(result.byProvider.keys, isNot(contains('site')));
      expectUntouched((await pendingOf('site')).single);
    },
  );

  test('every replacement bumps the status revision', () async {
    final int start = service.statusRevision.value;
    service.setExtraProviders(<TrackingProvider>[_Site('one')]);
    // Synchronously, before the sync it started reports anything.
    expect(service.statusRevision.value, start + 1);
    service.setExtraProviders(const <TrackingProvider>[]);
    expect(service.statusRevision.value, start + 2);
    // Even a list with nothing new tells open pages to refresh.
    service.setExtraProviders(const <TrackingProvider>[]);
    expect(service.statusRevision.value, start + 3);
    await service.syncNow();
  });

  test('a linking run started before a site was added links it too', () async {
    await insertNovel('book');
    final _Site first = _Site('first');
    service.setExtraProviders(<TrackingProvider>[first]);
    await service.syncNow();
    final Completer<void> gate = Completer<void>();
    first.searchGate = gate;

    final Future<void> early = service.refreshBookLinks('book');
    while (first.searches == 0) {
      await Future<void>.delayed(Duration.zero);
    }
    final _Site added = _Site('added');
    service.setExtraProviders(<TrackingProvider>[first, added]);
    final Future<void> later = service.refreshBookLinks('book');
    gate.complete();
    await Future.wait(<Future<void>>[early, later]);
    await service.syncNow();

    expect(added.searches, greaterThan(0));
  });

  test(
    'a link to an unregistered site breaks no status, overview or sync',
    () async {
      await insertNovel('book');
      final _Site site = _Site('site');
      service.setExtraProviders(<TrackingProvider>[site]);
      await service.syncNow();
      await mapBook('site');
      await mapBook('gone');
      await enqueueBook('gone');

      final BookTrackingOverview withSite = (await service.loadBookTracking(
        'book',
      ))!;
      expect(withSite.sites.map((BookTrackingSite s) => s.providerId), <String>[
        'site',
      ]);
      expect(withSite.sites.single.link, isNotNull);

      service.setExtraProviders(const <TrackingProvider>[]);

      final BookTrackingOverview overview = (await service.loadBookTracking(
        'book',
      ))!;
      expect(overview.sites, isEmpty);
      final List<MediaTrackingProviderStatus> statuses = await service
          .loadProviderStatuses();
      expect(
        statuses.map((MediaTrackingProviderStatus s) => s.providerId),
        <String>[kTrackingProviderBangumi],
      );
      final MediaTrackingStatus status = await service.loadStatus();
      expect(status.pending, 0, reason: 'the Bangumi view counts Bangumi');
      final MediaTrackingSyncResult result = await service.syncNow();
      expect(result.byProvider.keys, <String>[kTrackingProviderBangumi]);
      expect(result.pending, 1, reason: 'the gone site\'s row is kept');
      expect(service.siteNameOf('gone'), 'gone');
      expect(await linkOf('site'), isNotNull);
      expect(await linkOf('gone'), isNotNull);
      expectUntouched((await pendingOf('gone')).single);
    },
  );
}
