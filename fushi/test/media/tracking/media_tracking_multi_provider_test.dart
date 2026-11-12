import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/tracking/bangumi_api_client.dart';
import 'package:fushi_engine/media/tracking/media_tracking_repository.dart';
import 'package:fushi_engine/media/tracking/media_tracking_service.dart';
import 'package:fushi_engine/media/tracking/tracking_provider.dart';

/// Minimal Bangumi API: records writes, can be told to fail.
class _FakeBangumiApi implements BangumiTrackingApi {
  Exception? error;
  final List<Map<String, dynamic>> creates = <Map<String, dynamic>>[];
  final List<Map<String, dynamic>> patches = <Map<String, dynamic>>[];
  final List<String> searches = <String>[];

  void _throwIfNeeded() {
    final Exception? value = error;
    if (value != null) throw value;
  }

  @override
  Future<BangumiUser> getMe() async {
    _throwIfNeeded();
    return const BangumiUser(username: 'alice', nickname: 'Alice');
  }

  @override
  Future<List<BangumiWatchedItem>> getWatchedAnime(String username) async =>
      const <BangumiWatchedItem>[];

  @override
  Future<List<BangumiSubject>> searchSubjects({
    required String keyword,
    required int subjectType,
  }) async {
    searches.add(keyword);
    return const <BangumiSubject>[];
  }

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
  ) async {
    _throwIfNeeded();
    return null;
  }

  @override
  Future<void> createCollection(
    int subjectId, {
    required Map<String, dynamic> payload,
  }) async {
    _throwIfNeeded();
    creates.add(payload);
  }

  @override
  Future<void> patchCollection(
    int subjectId, {
    required Map<String, dynamic> payload,
  }) async {
    _throwIfNeeded();
    patches.add(payload);
  }

  @override
  Future<List<BangumiEpisode>> getMainEpisodes(int subjectId) async =>
      const <BangumiEpisode>[];

  @override
  Future<void> markEpisodesDone(int subjectId, List<int> episodeIds) async {}

  @override
  void close() {}
}

final class _AuthError implements Exception {
  const _AuthError();
}

final class _RateLimitError implements Exception {
  const _RateLimitError();
}

final class _FakeSession implements TrackingProviderSession {
  bool closed = false;

  @override
  void close() => closed = true;
}

/// A second tracking site.
final class _FakeProvider implements TrackingProvider {
  _FakeProvider(
    this.id, {
    this.capabilities = const TrackingProviderCapabilities(
      kinds: <TrackingKind>{TrackingKind.novel, TrackingKind.manga},
      progressModes: <TrackingProgressMode>{
        TrackingProgressMode.chapter,
        TrackingProgressMode.volume,
      },
    ),
  });

  @override
  final String id;

  @override
  String get displayName => id;

  @override
  String get siteHost => '';

  @override
  final TrackingProviderCapabilities capabilities;

  bool configured = true;
  Exception? openError;
  Exception? pushError;
  int sessionsOpened = 0;
  int pushAttempts = 0;

  /// When set, every push waits for it (to hold a sync in flight).
  Completer<void>? gate;
  final List<_FakeSession> sessions = <_FakeSession>[];
  final List<PendingTrackingUpdate> pushed = <PendingTrackingUpdate>[];

  @override
  bool get isConfigured => configured;

  @override
  Future<TrackingProviderSession> openSession() async {
    sessionsOpened++;
    final Exception? error = openError;
    if (error != null) throw error;
    final _FakeSession session = _FakeSession();
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
  TrackingFailureKind classify(Object error) => switch (error) {
    _AuthError() => TrackingFailureKind.unauthorized,
    _RateLimitError() => TrackingFailureKind.rateLimited,
    _ => TrackingFailureKind.transient,
  };
}

class _FakeRetryTimer implements Timer {
  _FakeRetryTimer(this.delay);

  final Duration delay;
  bool cancelled = false;

  @override
  void cancel() => cancelled = true;

  @override
  bool get isActive => !cancelled;

  @override
  int get tick => 0;
}

const String _fakeId = 'fake';

void main() {
  late FushiDatabase db;
  late PreferencesRepository preferences;
  late MediaTrackingRepository repository;
  late _FakeBangumiApi api;
  late _FakeProvider fake;
  late List<_FakeRetryTimer> timers;
  late MediaTrackingService service;

  MangaReadProgress? mangaProgress;

  /// The host's Media tracking module switch.
  bool trackingOn = true;

  MediaTrackingService buildService(List<TrackingProvider> extra) =>
      MediaTrackingService(
        mangaReadProgress: (EpubBookRow book) async =>
            book.bookKey == 'series' ? mangaProgress : null,
        repository: repository,
        preferences: preferences,
        userAgent: 'test-agent',
        apiFactory: (_) => api,
        retryTimerFactory: (Duration delay, void Function() callback) {
          final _FakeRetryTimer timer = _FakeRetryTimer(delay);
          timers.add(timer);
          return timer;
        },
        extraProviders: extra,
        trackingOn: () => trackingOn,
      );

  setUp(() async {
    trackingOn = true;
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    preferences = PreferencesRepository(db);
    await preferences.loadFromDb();
    await preferences.setPref(kBangumiAccessTokenPref, 'token');
    repository = MediaTrackingRepository(db);
    api = _FakeBangumiApi();
    fake = _FakeProvider(_fakeId);
    timers = <_FakeRetryTimer>[];
    mangaProgress = null;
    service = buildService(<TrackingProvider>[fake]);
  });

  tearDown(() async {
    service.dispose();
    preferences.dispose();
    await db.close();
  });

  Future<void> insertNovel(String bookKey, {String title = 'Novel'}) =>
      db.insertEpubBook(
        EpubBooksCompanion.insert(
          bookKey: bookKey,
          title: title,
          epubPath: '/tmp/$bookKey.epub',
          extractDir: '/tmp/$bookKey',
          chapterCount: 12,
          chaptersJson: '[]',
          importedAt: 1,
        ),
      );

  Future<void> mapBook(
    String provider, {
    String bookKey = 'book',
    TrackingKind kind = TrackingKind.novel,
    TrackingProgressMode mode = TrackingProgressMode.chapter,
  }) => repository
      .saveMapping(
        mediaType: TrackingMediaType.book,
        mediaKey: bookKey,
        mediaTitle: 'Novel',
        kind: kind,
        subjectId: 7,
        subjectName: 'Remote novel',
        progressMode: mode,
        progressOffset: 0,
        provider: provider,
      )
      .then((_) {});

  Future<void> enqueueBook(String provider, {int progress = 3}) => repository
      .enqueueProgress(
        mediaType: TrackingMediaType.book,
        mediaKey: 'book',
        localProgress: progress,
        completed: false,
        provider: provider,
      )
      .then((_) {});

  Future<List<PendingTrackingUpdate>> pendingOf(String provider) =>
      repository.allPending(provider: provider);

  Future<void> recordBook({int chapters = 3}) async {
    await service.recordBookProgress(
      bookKey: 'book',
      completedChapterCount: chapters,
      completed: false,
    );
    await service.syncNow();
  }

  test(
    'one reading event reaches every linked provider, each its own row',
    () async {
      await insertNovel('book');
      await mapBook(kTrackingProviderBangumi);
      await mapBook(_fakeId);

      await service.recordBookProgress(
        bookKey: 'book',
        completedChapterCount: 3,
        completed: false,
      );
      final List<PendingTrackingUpdate> queued = await repository.allPending();
      expect(
        queued.map((PendingTrackingUpdate u) => u.mapping.provider).toSet(),
        <String>{kTrackingProviderBangumi, _fakeId},
      );
      expect(queued, hasLength(2));

      final MediaTrackingSyncResult result = await service.syncNow();

      expect(api.creates, hasLength(1));
      expect(fake.pushed.single.outbox.progress, 3);
      expect(fake.pushed.single.mapping.provider, _fakeId);
      // The event already started a background sync, so [result] is the
      // follow-up round; it still reports both active providers.
      expect(result.byProvider.keys, <String>[
        kTrackingProviderBangumi,
        _fakeId,
      ]);
      expect(await repository.pendingCount(), 0);
    },
  );

  test('a failing provider does not block another provider', () async {
    await mapBook(kTrackingProviderBangumi);
    await mapBook(_fakeId);
    await enqueueBook(kTrackingProviderBangumi);
    await enqueueBook(_fakeId);
    fake.pushError = Exception('boom');

    final MediaTrackingSyncResult result = await service.syncNow();

    expect(api.creates, hasLength(1));
    expect(result.byProvider[kTrackingProviderBangumi]!.succeeded, 1);
    expect(result.byProvider[_fakeId]!.failed, 1);
    expect(await pendingOf(kTrackingProviderBangumi), isEmpty);
    final PendingTrackingUpdate left = (await pendingOf(_fakeId)).single;
    expect(left.outbox.attemptCount, 1);
    expect(left.outbox.lastError, contains('boom'));
    expect(fake.sessions.single.closed, isTrue);
  });

  test(
    'Bangumi rejecting its token leaves the other provider syncing',
    () async {
      await mapBook(kTrackingProviderBangumi);
      await mapBook(_fakeId);
      await enqueueBook(kTrackingProviderBangumi);
      await enqueueBook(_fakeId);
      api.error = const BangumiApiException(statusCode: 401, message: 'nope');

      final MediaTrackingSyncResult result = await service.syncNow();

      expect(result.unauthorized, isTrue);
      expect(result.byProvider[kTrackingProviderBangumi]!.unauthorized, isTrue);
      expect(result.byProvider[_fakeId]!.unauthorized, isFalse);
      expect(fake.pushed, hasLength(1));
      expect(
        preferences.getPref(kMediaTrackingLastSyncUnauthorizedPref),
        isTrue,
      );
      expect(
        preferences.getPref('media_tracking_fake_last_sync_unauthorized_v1'),
        isFalse,
      );
    },
  );

  test('an unauthorized provider stops only its own batch', () async {
    await mapBook(kTrackingProviderBangumi);
    await mapBook(_fakeId);
    await enqueueBook(kTrackingProviderBangumi);
    await enqueueBook(_fakeId);
    fake.openError = const _AuthError();

    final MediaTrackingSyncResult result = await service.syncNow();

    expect(api.creates, hasLength(1));
    expect(result.byProvider[_fakeId]!.unauthorized, isTrue);
    expect(result.byProvider[kTrackingProviderBangumi]!.unauthorized, isFalse);
    expect((await pendingOf(_fakeId)).single.outbox.attemptCount, 1);
    final List<MediaTrackingProviderStatus> statuses = await service
        .loadProviderStatuses();
    expect(statuses.last.unauthorized, isTrue);
    expect(statuses.first.unauthorized, isFalse);
  });

  test('providers only receive kinds and modes they support', () async {
    final _FakeProvider mangaOnly = _FakeProvider(
      'manga_only',
      capabilities: const TrackingProviderCapabilities(
        kinds: <TrackingKind>{TrackingKind.manga},
        progressModes: <TrackingProgressMode>{TrackingProgressMode.volume},
      ),
    );
    service.dispose();
    service = buildService(<TrackingProvider>[mangaOnly]);
    await insertNovel('book');
    await mapBook(kTrackingProviderBangumi);
    // A mapping the provider cannot honour (e.g. written by an older build).
    await mapBook('manga_only');

    await recordBook();

    expect(mangaOnly.pushed, isEmpty);
    expect(await pendingOf('manga_only'), isEmpty);
    expect(api.creates, hasLength(1));

    await expectLater(
      service.saveManualMappingAndSync(
        mediaType: TrackingMediaType.book,
        mediaKey: 'book',
        mediaTitle: 'Novel',
        kind: TrackingKind.novel,
        subjectId: 1,
        subjectName: 'x',
        progressMode: TrackingProgressMode.chapter,
        progressOffset: 0,
        provider: 'manga_only',
      ),
      throwsArgumentError,
    );
    await expectLater(
      service.saveManualMappingAndSync(
        mediaType: TrackingMediaType.book,
        mediaKey: 'book',
        mediaTitle: 'Novel',
        kind: TrackingKind.novel,
        subjectId: 1,
        subjectName: 'x',
        progressMode: TrackingProgressMode.chapter,
        progressOffset: 0,
        provider: 'not_registered',
      ),
      throwsArgumentError,
    );
  });

  test(
    'a manual mapping for another provider queues and sends only to it',
    () async {
      await insertNovel('book');

      await service.saveManualMappingAndSync(
        mediaType: TrackingMediaType.book,
        mediaKey: 'book',
        mediaTitle: 'Novel',
        kind: TrackingKind.novel,
        subjectId: 99,
        subjectName: 'Remote novel',
        progressMode: TrackingProgressMode.chapter,
        progressOffset: 0,
        provider: _fakeId,
      );

      expect(
        await repository.findMapping(
          mediaType: TrackingMediaType.book,
          mediaKey: 'book',
        ),
        isNull,
        reason: 'Bangumi must not get a mapping it was never given',
      );
      expect(
        (await repository.findMapping(
          mediaType: TrackingMediaType.book,
          mediaKey: 'book',
          provider: _fakeId,
        ))!.subjectId,
        99,
      );
      expect(api.creates, isEmpty);
    },
  );

  test('the in-memory de-dup is per provider', () async {
    await insertNovel('book');
    await mapBook(kTrackingProviderBangumi);
    await recordBook();
    expect(api.creates, hasLength(1));

    // The second provider is linked later; the same local progress must still
    // reach it even though Bangumi already got exactly this value.
    await mapBook(_fakeId);
    await recordBook();

    expect(fake.pushed.single.outbox.progress, 3);
    expect(api.creates, hasLength(1));
  });

  test('sending twice does not write twice', () async {
    await mapBook(_fakeId);
    await enqueueBook(_fakeId);

    await service.syncNow();
    await service.syncNow();
    await service.syncNow(force: true);

    expect(fake.pushed, hasLength(1));
  });

  test(
    'Bangumi keeps its frozen preference keys; others are namespaced',
    () async {
      final TrackingProviderPrefKeys bangumi =
          TrackingProviderPrefKeys.forProvider(kTrackingProviderBangumi);
      expect(bangumi.enabled, 'media_tracking_bangumi_enabled');
      expect(bangumi.accountName, kBangumiAccountNamePref);
      expect(bangumi.lastSyncAt, 'media_tracking_last_sync_at_v1');
      expect(
        bangumi.lastSyncSucceeded,
        'media_tracking_last_sync_succeeded_v1',
      );
      expect(bangumi.lastSyncFailed, 'media_tracking_last_sync_failed_v1');
      expect(
        bangumi.lastSyncUnauthorized,
        'media_tracking_last_sync_unauthorized_v1',
      );
      expect(bangumi.videoWatermark, kVideoTrackingReconcileWatermarkPref);
      expect(bangumi.bookWatermark, kBookTrackingReconcileWatermarkPref);
      expect(bangumi.gameWatermark, kGameTrackingReconcileWatermarkPref);

      final TrackingProviderPrefKeys other =
          TrackingProviderPrefKeys.forProvider(_fakeId);
      expect(other.lastSyncAt, 'media_tracking_fake_last_sync_at_v1');
      expect(
        other.bookWatermark,
        'media_tracking_fake_book_reconcile_watermark_v1',
      );
      expect(
        other.kindEnabled(TrackingKind.manga),
        'media_tracking_fake_manga_enabled',
      );

      await mapBook(_fakeId);
      await enqueueBook(_fakeId);
      await service.syncNow();
      expect(
        preferences.getPref('media_tracking_fake_last_sync_succeeded_v1'),
        1,
      );
      expect(preferences.getPref(kMediaTrackingLastSyncSucceededPref), 0);

      // The legacy Bangumi-only snapshot ignores the other provider's rows.
      await enqueueBook(_fakeId, progress: 5);
      fake.pushError = Exception('later');
      await service.syncNow();
      final MediaTrackingStatus legacy = await service.loadStatus();
      expect(legacy.pending, 0);
      expect(legacy.failures, isEmpty);
    },
  );

  test('provider statuses list every registered provider in order', () async {
    fake.configured = false;
    await mapBook(_fakeId);
    await enqueueBook(_fakeId);

    final List<MediaTrackingProviderStatus> statuses = await service
        .loadProviderStatuses();

    expect(
      statuses.map((MediaTrackingProviderStatus s) => s.providerId),
      <String>[kTrackingProviderBangumi, _fakeId],
    );
    expect(statuses.first.configured, isTrue);
    expect(statuses.first.pending, 0);
    expect(statuses.last.configured, isFalse);
    expect(statuses.last.enabled, isTrue);
    expect(statuses.last.pending, 1);
  });

  test(
    'rows of an unconfigured provider are left alone and never arm the retry timer',
    () async {
      fake.configured = false;
      await mapBook(_fakeId);
      await enqueueBook(_fakeId);

      final MediaTrackingSyncResult result = await service.syncNow();

      expect(fake.sessionsOpened, 0);
      expect(result.byProvider.containsKey(_fakeId), isFalse);
      expect((await pendingOf(_fakeId)).single.outbox.attemptCount, 0);
      expect(timers, isEmpty, reason: 'would loop every 5 s otherwise');
      expect(
        preferences.getPref('media_tracking_fake_last_sync_at_v1'),
        isNull,
      );
    },
  );

  test(
    'a failure in one provider schedules a retry from its own rows only',
    () async {
      await mapBook(_fakeId);
      await enqueueBook(_fakeId);
      fake.pushError = Exception('boom');

      await service.syncNow();

      expect(timers, hasLength(1));
      expect(timers.single.delay.inSeconds, greaterThan(20));
    },
  );

  test('other providers never auto-map by title', () async {
    await insertNovel('book', title: 'Some Title');
    await service.setProviderEnabled(kTrackingProviderBangumi, false);

    await recordBook();

    expect(api.searches, isEmpty);
    expect(await repository.listMappings(), isEmpty);
    expect(fake.pushed, isEmpty);
  });

  test('rows of a provider that is not registered are never touched', () async {
    await mapBook('ghost');
    await enqueueBook('ghost');

    await service.syncNow();
    await service.syncNow(force: true);

    final PendingTrackingUpdate ghost = (await pendingOf('ghost')).single;
    expect(ghost.outbox.attemptCount, 0);
    expect(ghost.outbox.lastError, isNull);
    expect(timers, isEmpty);
  });

  test(
    'turning a provider off keeps its rows; turning it on sends them',
    () async {
      await mapBook(_fakeId);
      await enqueueBook(_fakeId);
      await service.setProviderEnabled(_fakeId, false);

      await service.syncNow();
      expect(fake.pushed, isEmpty);
      expect(await pendingOf(_fakeId), hasLength(1));
      expect((await service.loadProviderStatuses()).last.enabled, isFalse);

      await insertNovel('book');
      await recordBook(chapters: 6);
      expect(
        (await pendingOf(_fakeId)).single.outbox.progress,
        3,
        reason: 'a disabled provider queues nothing new',
      );

      await service.setProviderEnabled(_fakeId, true);
      await service.syncNow();
      expect(fake.pushed, hasLength(1));
      expect(await pendingOf(_fakeId), isEmpty);
    },
  );

  test(
    'turning one kind off blocks only that kind, queued rows included',
    () async {
      await insertNovel('book');
      await mapBook(kTrackingProviderBangumi);
      await mapBook(_fakeId);
      await mapBook(
        _fakeId,
        bookKey: 'manga',
        kind: TrackingKind.manga,
        mode: TrackingProgressMode.volume,
      );
      // Queued before the switch goes off: must wait, not go out.
      await enqueueBook(_fakeId);
      await service.setKindEnabled(_fakeId, TrackingKind.novel, false);
      expect(service.isKindEnabled(_fakeId, TrackingKind.novel), isFalse);
      expect(service.isKindEnabled(_fakeId, TrackingKind.manga), isTrue);
      await repository.enqueueProgress(
        mediaType: TrackingMediaType.book,
        mediaKey: 'manga',
        localProgress: 0,
        completed: true,
        provider: _fakeId,
      );

      await recordBook(chapters: 4);

      expect(
        fake.pushed.map((PendingTrackingUpdate u) => u.mapping.mediaKey),
        <String>['manga'],
        reason: 'manga still flows; the novel row waits',
      );
      expect(api.creates, hasLength(1));
      final PendingTrackingUpdate waiting = (await pendingOf(_fakeId)).single;
      expect(waiting.mapping.mediaKey, 'book');
      expect(waiting.outbox.attemptCount, 0);
      expect(waiting.outbox.progress, 3, reason: 'nothing new was queued');
      expect(
        timers,
        isEmpty,
        reason: 'a switched-off kind must not arm retries',
      );

      await service.setKindEnabled(_fakeId, TrackingKind.novel, true);
      await service.syncNow();
      expect(fake.pushed.last.mapping.mediaKey, 'book');
      expect(await pendingOf(_fakeId), isEmpty);
    },
  );

  test(
    're-enabling a kind replays only what happened while it was off',
    () async {
      const String bookWatermark =
          'media_tracking_fake_book_reconcile_watermark_v1';
      const String gameWatermark =
          'media_tracking_fake_game_reconcile_watermark_v1';
      // Not connected: the syncs these switches start never reconcile it, so
      // nothing but the switch itself moves its watermarks here.
      fake.configured = false;
      final int before = DateTime.now().millisecondsSinceEpoch;
      await service.setKindEnabled(_fakeId, TrackingKind.novel, false);
      // Turning it off twice must not move the "off since" time forward.
      await service.setKindEnabled(_fakeId, TrackingKind.novel, false);
      final int disabledAt =
          preferences.getPref('media_tracking_fake_novel_disabled_at_v1')
              as int;
      expect(disabledAt, greaterThanOrEqualTo(before));
      // Reconcile moved on while the kind was off.
      await preferences.setPref(bookWatermark, disabledAt + 999999);
      await preferences.setPref(gameWatermark, disabledAt + 999999);

      await service.setKindEnabled(_fakeId, TrackingKind.novel, true);

      expect(preferences.getPref(bookWatermark), disabledAt);
      expect(
        preferences.getPref(gameWatermark),
        disabledAt + 999999,
        reason: 'only the watermark of that kind moves',
      );

      await service.setKindEnabled(_fakeId, TrackingKind.game, false);
      await service.setKindEnabled(_fakeId, TrackingKind.game, true);
      // Each "on" started a sync; let it finish before the database closes.
      await service.syncNow();
      expect(
        preferences.getPref(gameWatermark),
        0,
        reason: 'play status has no change time: games replay in full',
      );
    },
  );

  test(
    'a switch flipped during a running sync is honoured in that sync',
    () async {
      final _FakeProvider other = _FakeProvider('other');
      service.dispose();
      service = buildService(<TrackingProvider>[fake, other]);
      await mapBook(_fakeId);
      await enqueueBook(_fakeId);
      await mapBook('other');
      await enqueueBook('other');
      await service.setProviderEnabled('other', false);
      fake.gate = Completer<void>();

      final Future<MediaTrackingSyncResult> running = service.syncNow();
      await pumpEventQueue();
      expect(fake.pushAttempts, 1, reason: 'sync is held inside the push');

      await service.setProviderEnabled('other', true);
      fake.gate!.complete();
      await running;
      await service.syncNow();

      expect(other.pushed, hasLength(1));
      expect(await repository.pendingCount(), 0);
    },
  );

  test('a rate limit stops that provider without sending the rest', () async {
    for (final String key in <String>['a', 'b', 'c']) {
      await mapBook(_fakeId, bookKey: key);
      await repository.enqueueProgress(
        mediaType: TrackingMediaType.book,
        mediaKey: key,
        localProgress: 1,
        completed: false,
        provider: _fakeId,
      );
    }
    await mapBook(kTrackingProviderBangumi);
    await enqueueBook(kTrackingProviderBangumi);
    fake.pushError = const _RateLimitError();

    final MediaTrackingSyncResult result = await service.syncNow();

    expect(fake.pushAttempts, 1);
    expect(result.byProvider[_fakeId]!.failed, 3);
    expect(
      (await pendingOf(
        _fakeId,
      )).every((PendingTrackingUpdate u) => u.outbox.attemptCount == 1),
      isTrue,
    );
    expect(api.creates, hasLength(1), reason: 'Bangumi is unaffected');
  });

  test(
    'a kind a provider leaves off by default stays off until enabled',
    () async {
      final _FakeProvider animeFirst = _FakeProvider(
        'anime_first',
        capabilities: const TrackingProviderCapabilities(
          kinds: <TrackingKind>{TrackingKind.anime, TrackingKind.novel},
          progressModes: <TrackingProgressMode>{
            TrackingProgressMode.episode,
            TrackingProgressMode.chapter,
          },
          onByDefault: <TrackingKind>{TrackingKind.anime},
        ),
      );
      service.dispose();
      service = buildService(<TrackingProvider>[animeFirst]);
      await insertNovel('book');
      await mapBook('anime_first');

      expect(service.isKindEnabled('anime_first', TrackingKind.anime), isTrue);
      expect(service.isKindEnabled('anime_first', TrackingKind.novel), isFalse);
      await recordBook();
      expect(await pendingOf('anime_first'), isEmpty);

      await service.setKindEnabled('anime_first', TrackingKind.novel, true);
      expect(service.isKindEnabled('anime_first', TrackingKind.novel), isTrue);
      await recordBook(chapters: 4);
      expect(animeFirst.pushed.single.outbox.progress, 4);
    },
  );

  test('a link of the other kind gets nothing after a format change', () async {
    // BUG-1318: linked as manga, the book is now an EPUB (Books section).
    await insertNovel('book');
    await mapBook(
      _fakeId,
      kind: TrackingKind.manga,
      mode: TrackingProgressMode.volume,
    );

    await recordBook();

    expect(fake.pushed, isEmpty);
    expect(await pendingOf(_fakeId), isEmpty);
    expect(
      await repository.loadPersistedBookTrackingProgress(
        afterMs: 0,
        provider: _fakeId,
      ),
      isEmpty,
    );
  });

  group('manga and PDF progress', () {
    Future<void> insertPaged(
      String bookKey, {
      String format = 'manga',
      DateTime? completedAt,
    }) => db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: bookKey,
        title: bookKey,
        epubPath: '/tmp/$bookKey',
        extractDir: '/tmp/$bookKey',
        chapterCount: 40,
        chaptersJson: '[]',
        importedAt: 1,
        format: Value<String>(format),
        completedAt: Value<DateTime?>(completedAt),
      ),
    );

    Future<void> link(
      String bookKey,
      TrackingProgressMode mode, {
      int offset = 0,
      TrackingKind kind = TrackingKind.manga,
    }) => repository
        .saveMapping(
          mediaType: TrackingMediaType.book,
          mediaKey: bookKey,
          mediaTitle: bookKey,
          kind: kind,
          subjectId: 7,
          subjectName: 'Remote',
          progressMode: mode,
          progressOffset: offset,
          provider: _fakeId,
        )
        .then((_) {});

    Future<void> report(String bookKey) async {
      await service.recordPagedBookProgress(bookKey);
      await service.syncNow();
    }

    test('an online series sends its highest read chapter', () async {
      await insertPaged('series');
      await link('series', TrackingProgressMode.chapter);
      mangaProgress = (highestChapter: 12, allRead: false, lastReadAt: 5);

      await report('series');

      expect(fake.pushed.single.outbox.progress, 12);
      expect(fake.pushed.single.outbox.completed, isFalse);
    });

    test(
      'an online series is finished only when every chapter is read',
      () async {
        await insertPaged('series', completedAt: DateTime(2026));
        await link('series', TrackingProgressMode.chapter);
        mangaProgress = (highestChapter: 30, allRead: false, lastReadAt: 5);
        await report('series');
        expect(
          fake.pushed.last.outbox.completed,
          isFalse,
          reason: 'completedAt on a series row only means a chapter ended',
        );

        mangaProgress = (highestChapter: 40, allRead: true, lastReadAt: 6);
        await report('series');
        expect(fake.pushed.last.outbox.progress, 40);
        expect(fake.pushed.last.outbox.completed, isTrue);
      },
    );

    test('a series with no numbered chapter read sends nothing', () async {
      await insertPaged('series');
      await link('series', TrackingProgressMode.chapter);
      mangaProgress = (highestChapter: null, allRead: false, lastReadAt: 5);

      await report('series');

      expect(fake.pushed, isEmpty);
      expect(await pendingOf(_fakeId), isEmpty);
    });

    test('a local volume 3 sends 2 while reading and 3 when done', () async {
      await insertPaged('vol3');
      await link('vol3', TrackingProgressMode.volume, offset: 3);

      await report('vol3');
      expect(fake.pushed.single.outbox.progress, 2);

      await db.markEpubBookCompletedIfUnset('vol3', DateTime(2026));
      await report('vol3');
      expect(fake.pushed.last.outbox.progress, 3);
      expect(fake.pushed.last.outbox.completed, isTrue);
    });

    test('a finished PDF counts as one volume', () async {
      await insertPaged('doc', format: 'pdf', completedAt: DateTime(2026));
      await link(
        'doc',
        TrackingProgressMode.volume,
        offset: 1,
        kind: TrackingKind.novel,
      );

      await report('doc');

      expect(fake.pushed.single.outbox.progress, 1);
    });

    test('a PDF never sends pages as chapters', () async {
      await insertPaged('doc', format: 'pdf', completedAt: DateTime(2026));
      await link('doc', TrackingProgressMode.chapter, kind: TrackingKind.novel);

      await report('doc');

      expect(fake.pushed, isEmpty);
    });

    test('never starts a Bangumi title search for manga', () async {
      await insertPaged('vol3');

      await report('vol3');

      expect(api.searches, isEmpty);
      expect(
        await repository.findMapping(
          mediaType: TrackingMediaType.book,
          mediaKey: 'vol3',
        ),
        isNull,
      );
    });

    test('reconcile sees chapters marked on the series page', () async {
      // No reader position: the chapters were marked without opening them.
      await insertPaged('series');
      await link('series', TrackingProgressMode.chapter);
      mangaProgress = (highestChapter: 8, allRead: false, lastReadAt: 99);

      final List<PersistedBookTrackingProgress> found = await repository
          .loadPersistedBookTrackingProgress(
            afterMs: 0,
            provider: _fakeId,
            mangaProgress: (EpubBookRow book) async => mangaProgress,
          );

      expect(found.single.localProgress, 8);
      expect(found.single.evidenceAt, greaterThanOrEqualTo(99));
    });
  });

  group('Media tracking module switch (host fact)', () {
    test('off: nothing is recorded, linked, queued or sent; links and '
        'queued rows stay', () async {
      await insertNovel('book', title: 'Some Title');
      await mapBook(_fakeId);
      await enqueueBook(_fakeId);
      trackingOn = false;

      await service.recordBookProgress(
        bookKey: 'book',
        completedChapterCount: 6,
        completed: false,
      );
      await service.recordGameStatus(gameId: 'g', status: 2);
      final MediaTrackingSyncResult result = await service.syncNow(
        force: true,
      );

      expect(service.isOn, isFalse);
      expect(result.succeeded + result.failed, 0);
      expect(fake.pushed, isEmpty);
      expect(fake.sessionsOpened, 0);
      expect(api.searches, isEmpty, reason: 'no Bangumi auto-link while off');
      expect(timers, isEmpty);
      expect((await pendingOf(_fakeId)).single.outbox.progress, 3);
      expect(await repository.listMappings(provider: _fakeId), hasLength(1));
    });

    test('progress made while off is caught up once it is on again', () async {
      await insertNovel('book');
      await mapBook(_fakeId);
      await service.syncNow();
      expect(fake.pushed, isEmpty, reason: 'nothing read yet');

      trackingOn = false;
      await db.markEpubBookCompletedIfUnset(
        'book',
        DateTime.now().add(const Duration(seconds: 5)),
      );
      await service.recordBookProgress(
        bookKey: 'book',
        completedChapterCount: 12,
        completed: true,
      );
      await service.syncNow();
      expect(fake.pushed, isEmpty);
      expect(await pendingOf(_fakeId), isEmpty);

      trackingOn = true;
      await service.syncNow();
      expect(fake.pushed, hasLength(1));
      expect(fake.pushed.single.outbox.completed, isTrue);
      expect(await pendingOf(_fakeId), isEmpty);
    });
  });

  group('needs a link = some connected site tracks the kind', () {
    Future<void> insertPlayedGame() => db.upsertGalgame(
      GalgamesCompanion.insert(
        id: 'game',
        name: 'Some game',
        exePath: '/games/game.exe',
        workdir: '/games',
        addedAt: 1000,
        playStatus: const Value<int>(2),
      ),
    );

    Future<Set<String>> homeUnlinked() async => <String>{
      for (final MediaTrackingUnlinkedItem item
          in (await service.loadHomeSnapshot()).unlinked)
        item.mediaKey,
    };

    test('a game is listed only while a site that tracks games (Bangumi) '
        'is connected', () async {
      await insertPlayedGame();
      await preferences.setPref(kBangumiAccessTokenPref, '');
      expect(
        (await repository.listUnlinkedHistory()).map(
          (MediaTrackingUnlinkedItem i) => i.mediaKey,
        ),
        contains('game'),
        reason: 'the raw list still has it',
      );
      expect(await homeUnlinked(), isNot(contains('game')));
      expect(
        (await service.loadStatus()).unlinked.map(
          (MediaTrackingUnlinkedItem i) => i.mediaKey,
        ),
        isNot(contains('game')),
      );

      await preferences.setPref(kBangumiAccessTokenPref, 'token');
      expect(await homeUnlinked(), contains('game'));
      expect(
        (await service.loadStatus()).unlinked.map(
          (MediaTrackingUnlinkedItem i) => i.mediaKey,
        ),
        contains('game'),
      );

      // Bangumi connected but its game kind switched off: not listed.
      await service.setKindEnabled(
        kTrackingProviderBangumi,
        TrackingKind.game,
        false,
      );
      expect(await homeUnlinked(), isNot(contains('game')));
    });

    test('a novel is not listed while only an anime-only site is '
        'connected', () async {
      await insertNovel('book');
      await db.setEpubBookCompleted('book', DateTime(2026, 11, 6));
      await preferences.setPref(kBangumiAccessTokenPref, '');
      service.dispose();
      service = buildService(<TrackingProvider>[
        _FakeProvider(
          'anime-only',
          capabilities: const TrackingProviderCapabilities(
            kinds: <TrackingKind>{TrackingKind.anime},
            progressModes: <TrackingProgressMode>{TrackingProgressMode.episode},
          ),
        ),
      ]);
      expect(await homeUnlinked(), isEmpty);

      service.dispose();
      service = buildService(<TrackingProvider>[fake]);
      expect(await homeUnlinked(), <String>{'book'});
    });
  });
}
