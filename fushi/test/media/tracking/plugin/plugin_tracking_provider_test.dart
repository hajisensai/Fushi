import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/tracking/plugin/plugin_tracking_provider.dart';
import 'package:fushi/src/media/tracking/plugin/tracking_plugin_manager.dart';
import 'package:fushi/src/media/tracking/plugin/tracking_plugin_models.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/tracking/book_tracking_link.dart';
import 'package:fushi_engine/media/tracking/media_tracking_repository.dart';
import 'package:fushi_engine/media/tracking/media_tracking_service.dart';
import 'package:fushi_engine/media/tracking/tracking_provider.dart';
import 'package:fushi_engine/media/tracking/tracking_rate_gate.dart';

import 'tracking_plugin_test_support.dart';

/// [PluginTrackingProvider] on the real sandbox engine with the fake-site
/// plugin, and end to end through [MediaTrackingService].
void main() {
  late Directory root;
  late RecordingEngine engine;
  late TrackingPluginManager manager;
  late FushiDatabase db;
  late MediaTrackingRepository repository;
  late int accountChanges;
  late int gateClock;
  late List<int> gateBudgets;
  int itemCount = 0;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('fushi-tracking-provider-');
    engine = RecordingEngine.real();
    gateClock = 0;
    gateBudgets = <int>[];
    manager = TrackingPluginManager(
      rootDir: root,
      engine: engine,
      rateGateFactory: (int perMinute) {
        gateBudgets.add(perMinute);
        return TrackingRateGate(
          maxRequests: perMinute,
          now: () {
            gateClock++;
            return DateTime.now();
          },
        );
      },
    );
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    repository = MediaTrackingRepository(db);
    accountChanges = 0;
  });

  tearDown(() async {
    await manager.dispose();
    await db.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Future<PluginTrackingProvider> installProvider({
    List<String> kinds = const <String>['anime', 'manga', 'novel'],
    List<String>? capabilities,
  }) async {
    final Uint8List zip = buildPluginZip(
      capabilities == null
          ? fakeManifest(kinds: kinds)
          : fakeManifest(kinds: kinds, capabilities: capabilities),
    );
    await manager.install(zip, (await manager.inspect(zip)).digest);
    return createPluginTrackingProvider(
      manager: manager,
      info: manager.registered.single.info!,
      onAccountChanged: () => accountChanges++,
    );
  }

  Future<void> signIn(PluginTrackingProvider provider) async {
    final TrackingPluginLoginChallenge step = await provider.beginLogin(
      'token',
    );
    final TrackingPluginLoginChallenge done = await provider.submitLogin(
      'token',
      session: step.session,
      action: 'ok',
      inputs: <String, String>{'token': 't1'},
    );
    expect(done.state, TrackingPluginLoginState.done);
  }

  Future<PendingTrackingUpdate> pending({
    required TrackingMediaType mediaType,
    required TrackingKind kind,
    required TrackingProgressMode mode,
    required int subjectId,
    required int progress,
    bool completed = false,
    String? key,
  }) async {
    final String mediaKey = key ?? 'item${++itemCount}';
    await repository.saveMapping(
      mediaType: mediaType,
      mediaKey: mediaKey,
      mediaTitle: 'Item',
      kind: kind,
      subjectId: subjectId,
      subjectName: 'Subject',
      progressMode: mode,
      progressOffset: 0,
      provider: fakeSiteId,
    );
    await repository.enqueueProgress(
      mediaType: mediaType,
      mediaKey: mediaKey,
      localProgress: progress,
      completed: completed,
      monotonic: false,
      provider: fakeSiteId,
    );
    final List<PendingTrackingUpdate> rows = await repository.allPending(
      provider: fakeSiteId,
    );
    return rows.singleWhere(
      (PendingTrackingUpdate r) => r.mapping.mediaKey == mediaKey,
    );
  }

  Future<void> push(
    PluginTrackingProvider provider,
    PendingTrackingUpdate update,
  ) async {
    final TrackingProviderSession session = await provider.openSession();
    try {
      await provider.push(session, update);
    } finally {
      session.close();
    }
  }

  List<Map<String, Object?>> sets() =>
      engine.argsOf('trackingEntry', op: 'set');

  group('identity and sign-in', () {
    test('site facts come from the manifest; interfaces follow the '
        'kinds', () async {
      final PluginTrackingProvider provider = await installProvider();
      expect(provider.id, fakeSiteId);
      expect(provider.displayName, 'Fake Site');
      expect(provider.siteHost, 'example.org');
      expect(
        provider.capabilities.accepts(
          TrackingKind.manga,
          TrackingProgressMode.volume,
        ),
        isTrue,
      );
      expect(provider.capabilities.isOnByDefault(TrackingKind.anime), isTrue);
      expect(provider, isA<TrackingAnimeLinker>());
      expect(provider, isA<TrackingBookLinker>());
      expect(gateBudgets, isEmpty, reason: 'nothing opened yet');
    });

    test('anime-only and book-only sites implement only their '
        'linker', () async {
      final PluginTrackingProvider animeOnly = await installProvider(
        kinds: const <String>['anime'],
      );
      expect(animeOnly, isA<TrackingAnimeLinker>());
      expect(animeOnly, isNot(isA<TrackingBookLinker>()));
      await manager.uninstall(fakePluginId);
      final PluginTrackingProvider booksOnly = await installProvider(
        kinds: const <String>['manga'],
      );
      expect(booksOnly, isA<TrackingBookLinker>());
      expect(booksOnly, isNot(isA<TrackingAnimeLinker>()));
    });

    test('not signed in: not configured and the session is '
        'unauthorized', () async {
      final PluginTrackingProvider provider = await installProvider();
      expect(provider.isConfigured, isFalse);
      Object? error;
      try {
        await provider.openSession();
      } catch (e) {
        error = e;
      }
      expect(provider.classify(error!), TrackingFailureKind.unauthorized);
    });

    test('form sign-in stores the account, a signed-out plugin clears '
        'it', () async {
      final PluginTrackingProvider provider = await installProvider();
      final List<TrackingPluginLoginMethod> methods = await provider
          .loginMethods();
      expect(methods.map((TrackingPluginLoginMethod m) => m.id), <String>[
        'token',
      ], reason: 'only form methods are offered');
      final TrackingPluginLoginChallenge step = await provider.beginLogin(
        'token',
      );
      expect(step.state, TrackingPluginLoginState.pending);
      expect(step.session, 's1');
      expect(step.appUrl, 'https://api.example.org/settings/token');
      expect(step.fields.single.id, 'token');
      expect(step.fields.single.secret, isTrue);
      expect(step.actions.single.primary, isTrue);
      expect(engine.argsOf('login').last['platform'], isA<String>());

      final TrackingPluginLoginChallenge failed = await provider.submitLogin(
        'token',
        session: 's1',
        action: 'ok',
        inputs: <String, String>{'token': ''},
      );
      expect(failed.state, TrackingPluginLoginState.failed);
      expect(failed.message, 'Empty token');
      expect(provider.isConfigured, isFalse);

      await signIn(provider);
      expect(provider.isConfigured, isTrue);
      expect(manager.accountOf(fakePluginId).name, 'user-t1');
      expect(accountChanges, 1);
      expect(await provider.openSession(), isNotNull);

      await provider.logout();
      expect(provider.isConfigured, isFalse);
      expect(accountChanges, 2);

      // Signed out inside the plugin while the host still thinks it is
      // signed in: the session fails and the state is cleared.
      await signIn(provider);
      final runtime = await manager.runtime(fakePluginId);
      await runtime.invoke('login', <String, Object?>{'op': 'logout'});
      expect(provider.isConfigured, isTrue);
      await expectLater(
        provider.openSession(),
        throwsA(isA<TrackingPluginException>()),
      );
      expect(provider.isConfigured, isFalse);
    });
  });

  group('push', () {
    test('creates the entry, raises progress, never lowers it, writes only '
        'the tracked unit', () async {
      final PluginTrackingProvider provider = await installProvider();
      await signIn(provider);

      await push(
        provider,
        await pending(
          mediaType: TrackingMediaType.book,
          kind: TrackingKind.manga,
          mode: TrackingProgressMode.chapter,
          subjectId: 2,
          progress: 3,
        ),
      );
      expect(engine.argsOf('trackingSubject').last, <String, Object?>{
        'id': 2,
        'kind': 'manga',
      });
      expect(engine.argsOf('trackingEntry', op: 'get').last, <String, Object?>{
        'op': 'get',
        'id': 2,
        'kind': 'manga',
      });
      expect(sets().last, <String, Object?>{
        'op': 'set',
        'id': 2,
        'kind': 'manga',
        'create': true,
        'status': 'current',
        'progress': 3,
      });

      await push(
        provider,
        await pending(
          mediaType: TrackingMediaType.book,
          kind: TrackingKind.manga,
          mode: TrackingProgressMode.chapter,
          subjectId: 2,
          progress: 10,
        ),
      );
      expect(sets().last, <String, Object?>{
        'op': 'set',
        'id': 2,
        'kind': 'manga',
        'create': false,
        'status': 'current',
        'progress': 10,
      });

      final int before = sets().length;
      await push(
        provider,
        await pending(
          mediaType: TrackingMediaType.book,
          kind: TrackingKind.manga,
          mode: TrackingProgressMode.chapter,
          subjectId: 2,
          progress: 5,
        ),
      );
      expect(sets().length, before, reason: 'never lowered: no write');

      // Volume mode on the same entry: only the volume is sent.
      await push(
        provider,
        await pending(
          mediaType: TrackingMediaType.book,
          kind: TrackingKind.manga,
          mode: TrackingProgressMode.volume,
          subjectId: 2,
          progress: 2,
        ),
      );
      expect(sets().last, <String, Object?>{
        'op': 'set',
        'id': 2,
        'kind': 'manga',
        'create': false,
        'status': 'current',
        'progressVolume': 2,
      });
    });

    test('a chapter companion never completes; a finished book does and '
        'keeps completed', () async {
      final PluginTrackingProvider provider = await installProvider();
      await signIn(provider);
      await push(
        provider,
        await pending(
          mediaType: TrackingMediaType.bookChapter,
          kind: TrackingKind.manga,
          mode: TrackingProgressMode.chapter,
          subjectId: 2,
          progress: 50,
          completed: true,
        ),
      );
      expect(sets().last['status'], 'current');
      expect(sets().last['progress'], 50);

      await push(
        provider,
        await pending(
          mediaType: TrackingMediaType.book,
          kind: TrackingKind.manga,
          mode: TrackingProgressMode.chapter,
          subjectId: 2,
          progress: 60,
          completed: true,
        ),
      );
      expect(sets().last, <String, Object?>{
        'op': 'set',
        'id': 2,
        'kind': 'manga',
        'create': false,
        'status': 'completed',
        'progress': 50,
      }, reason: 'capped at the finished total, status completed');

      final int before = sets().length;
      await push(
        provider,
        await pending(
          mediaType: TrackingMediaType.book,
          kind: TrackingKind.manga,
          mode: TrackingProgressMode.chapter,
          subjectId: 2,
          progress: 20,
        ),
      );
      expect(sets().length, before, reason: 'completed is kept');
    });

    test('a merged subject: get and set use the returned id, the link is '
        'not rewritten', () async {
      final PluginTrackingProvider provider = await installProvider();
      await signIn(provider);
      final PendingTrackingUpdate update = await pending(
        mediaType: TrackingMediaType.book,
        kind: TrackingKind.manga,
        mode: TrackingProgressMode.chapter,
        subjectId: 5,
        progress: 4,
      );
      await push(provider, update);
      expect(engine.argsOf('trackingSubject').last, <String, Object?>{
        'id': 5,
        'kind': 'manga',
      });
      expect(engine.argsOf('trackingEntry', op: 'get').last, <String, Object?>{
        'op': 'get',
        'id': 6,
        'kind': 'manga',
      });
      expect(sets().last, <String, Object?>{
        'op': 'set',
        'id': 6,
        'kind': 'manga',
        'create': true,
        'status': 'current',
        'progress': 4,
      });
      final MediaTrackingMappingRow? mapping = await repository.findMapping(
        mediaType: TrackingMediaType.book,
        mediaKey: update.mapping.mediaKey,
        provider: fakeSiteId,
      );
      expect(mapping!.subjectId, 5);
    });

    test('anime: reaching the episode count completes', () async {
      final PluginTrackingProvider provider = await installProvider();
      await signIn(provider);
      await push(
        provider,
        await pending(
          mediaType: TrackingMediaType.video,
          kind: TrackingKind.anime,
          mode: TrackingProgressMode.episode,
          subjectId: 1,
          progress: 12,
        ),
      );
      expect(sets().last, <String, Object?>{
        'op': 'set',
        'id': 1,
        'kind': 'anime',
        'create': true,
        'status': 'completed',
        'progress': 12,
      });
    });

    test('kind mismatch is permanent and writes nothing', () async {
      final PluginTrackingProvider provider = await installProvider();
      await signIn(provider);
      Object? error;
      try {
        await push(
          provider,
          await pending(
            mediaType: TrackingMediaType.book,
            kind: TrackingKind.manga,
            mode: TrackingProgressMode.chapter,
            subjectId: 1,
            progress: 3,
          ),
        );
      } catch (e) {
        error = e;
      }
      expect(
        (error! as TrackingPluginException).code,
        TrackingPluginErrorCode.kindMismatch,
      );
      expect(provider.classify(error), TrackingFailureKind.permanent);
      expect(sets(), isEmpty);
      expect(engine.argsOf('trackingEntry'), isEmpty);
    });

    test('error prefixes are classified', () async {
      final PluginTrackingProvider provider = await installProvider();
      await signIn(provider);
      Future<Object> failure(int subjectId) async {
        try {
          await push(
            provider,
            await pending(
              mediaType: TrackingMediaType.book,
              kind: TrackingKind.manga,
              mode: TrackingProgressMode.chapter,
              subjectId: subjectId,
              progress: 3,
              key: 'item$subjectId',
            ),
          );
        } catch (e) {
          return e;
        }
        fail('push of $subjectId did not fail');
      }

      final Object unauthorized = await failure(401);
      expect(provider.classify(unauthorized), TrackingFailureKind.unauthorized);
      expect(
        (unauthorized as TrackingPluginException).message,
        'token expired',
      );
      expect(
        provider.classify(await failure(429)),
        TrackingFailureKind.rateLimited,
      );
      expect(
        provider.classify(await failure(404)),
        TrackingFailureKind.permanent,
      );
      expect(
        provider.classify(await failure(500)),
        TrackingFailureKind.transient,
      );
      expect(
        provider.classify(await failure(9999)),
        TrackingFailureKind.permanent,
        reason: 'a null subject is not found',
      );
      expect(sets(), isEmpty);

      // A stopped runtime is temporary.
      final runtime = await manager.runtime(fakePluginId);
      final TrackingProviderSession session = await provider.openSession();
      await runtime.close();
      Object? dead;
      try {
        await provider.push(
          session,
          await pending(
            mediaType: TrackingMediaType.book,
            kind: TrackingKind.manga,
            mode: TrackingProgressMode.chapter,
            subjectId: 2,
            progress: 3,
            key: 'dead',
          ),
        );
      } catch (e) {
        dead = e;
      }
      expect(
        (dead! as TrackingPluginException).code,
        TrackingPluginErrorCode.runtimeStopped,
      );
      expect(provider.classify(dead), TrackingFailureKind.transient);
      expect(provider.classify(StateError('x')), TrackingFailureKind.transient);
    });
  });

  group('linkers', () {
    test('MAL lookup and anime by id', () async {
      final PluginTrackingProvider provider = await installProvider();
      final TrackingAnimeLinker anime = provider as TrackingAnimeLinker;
      final TrackingLinkedSubject? byMal = await anime.animeForMalId(100);
      expect(byMal!.subjectId, 1);
      expect(byMal.episodeCount, 12);
      expect(engine.argsOf('trackingLookup').last, <String, Object?>{
        'idType': 'mal',
        'id': 100,
        'kind': 'anime',
      });
      expect(await anime.animeForMalId(101), isNull);
      expect((await anime.animeById(1))!.name, 'Anime One');
      expect(engine.argsOf('trackingSubject').last, <String, Object?>{
        'id': 1,
        'kind': 'anime',
      });
      expect(await anime.animeById(2), isNull, reason: 'not an anime');
    });

    test('book by id, search with untrusted results dropped, '
        'bookForLinkedId needs exactly one result', () async {
      final PluginTrackingProvider provider = await installProvider();
      final TrackingBookLinker books = provider as TrackingBookLinker;
      final TrackingBookSubject? two = await books.bookById(2);
      expect(two!.kind, TrackingKind.manga);
      expect(two.titles, <String>['Manga Two', 'Zwei']);
      expect(two.isFinished, isTrue);
      expect(engine.argsOf('trackingSubject').last, <String, Object?>{'id': 2});
      expect(await books.bookById(4), isNull, reason: 'no name: dropped');
      expect(await books.bookById(8), isNull, reason: 'bad id: dropped');

      final List<TrackingBookSubject> found = await books.searchBooks(
        ' two ',
        TrackingKind.manga,
      );
      expect(found.map((TrackingBookSubject b) => b.subjectId), <int>[2, 6]);
      expect(engine.argsOf('trackingSearch').last, <String, Object?>{
        'query': 'two',
        'kind': 'manga',
      });
      expect(
        await books.searchBooks('   ', TrackingKind.manga),
        isEmpty,
        reason: 'empty query: no call',
      );
      expect(engine.argsOf('trackingSearch'), hasLength(1));

      expect((await books.bookForLinkedId('other', 9))!.subjectId, 3);
      expect(await books.bookForLinkedId('other', 10), isNull, reason: 'two');
      expect(await books.bookForLinkedId('other', 11), isNull, reason: 'none');
      expect(engine.argsOf('trackingLookup').last, <String, Object?>{
        'idType': 'other',
        'id': 11,
      });
    });

    test('missing optional capabilities give empty results without a '
        'call', () async {
      final PluginTrackingProvider provider = await installProvider(
        capabilities: const <String>[
          'login',
          'account',
          'trackingEntry',
          'trackingSubject',
        ],
      );
      expect(
        await (provider as TrackingBookLinker).searchBooks(
          'two',
          TrackingKind.manga,
        ),
        isEmpty,
      );
      expect(
        await (provider as TrackingBookLinker).bookForLinkedId('other', 9),
        isNull,
      );
      expect(
        await (provider as TrackingAnimeLinker).animeForMalId(100),
        isNull,
      );
      expect(engine.calls, isEmpty);
    });

    test('the rate gate is consulted once per HTTP request, with the '
        'manifest budget', () async {
      final PluginTrackingProvider provider = await installProvider();
      final TrackingBookLinker books = provider as TrackingBookLinker;
      await books.bookById(2);
      expect(gateClock, 0, reason: 'no HTTP request, no reservation');
      await books.searchBooks('a', TrackingKind.manga);
      await books.searchBooks('b', TrackingKind.novel);
      expect(engine.httpRequests, hasLength(2));
      expect(gateClock, 2);
      expect(gateBudgets, <int>[30]);
    });
  });

  group('with MediaTrackingService', () {
    late PreferencesRepository preferences;
    late MediaTrackingService service;
    late PluginTrackingProviders providers;

    setUp(() async {
      preferences = PreferencesRepository(db);
      await preferences.loadFromDb();
      service = MediaTrackingService(
        repository: repository,
        preferences: preferences,
        userAgent: 'test-agent',
        retryTimerFactory: (Duration delay, void Function() callback) =>
            Timer(const Duration(days: 1), () {}),
      );
      providers = PluginTrackingProviders(
        manager: manager,
        onAccountChanged: service.notifyStatusChanged,
      );
    });

    tearDown(() {
      service.dispose();
      preferences.dispose();
    });

    Future<void> mapAndQueue(int progress) async {
      await repository.saveMapping(
        mediaType: TrackingMediaType.book,
        mediaKey: 'book',
        mediaTitle: 'Novel',
        kind: TrackingKind.novel,
        subjectId: 3,
        subjectName: 'Novel Three',
        progressMode: TrackingProgressMode.chapter,
        progressOffset: 0,
        provider: fakeSiteId,
      );
      await repository.enqueueProgress(
        mediaType: TrackingMediaType.book,
        mediaKey: 'book',
        localProgress: progress,
        completed: false,
        provider: fakeSiteId,
      );
    }

    void apply() => service.setExtraProviders(providers.current());

    test('a registered plugin receives a queued update; disabling it stops '
        'sending and keeps the link', () async {
      await installProvider();
      final PluginTrackingProvider provider = providers.current().single;
      await signIn(provider);
      await mapAndQueue(4);
      apply();
      expect(service.providers.byId(fakeSiteId), same(provider));
      expect(identical(providers.current().single, provider), isTrue);

      // The plugin's arrival already started a sync; this joins it.
      await service.syncNow();
      expect(sets().single, <String, Object?>{
        'op': 'set',
        'id': 3,
        'kind': 'novel',
        'create': true,
        'status': 'current',
        'progress': 4,
      });
      expect(await repository.allPending(provider: fakeSiteId), isEmpty);

      await manager.setEnabled(fakePluginId, false);
      apply();
      expect(service.providers.byId(fakeSiteId), isNull);
      await repository.enqueueProgress(
        mediaType: TrackingMediaType.book,
        mediaKey: 'book',
        localProgress: 8,
        completed: false,
        provider: fakeSiteId,
      );
      await service.syncNow();
      expect(sets(), hasLength(1), reason: 'nothing sent while disabled');
      expect(
        await repository.findMapping(
          mediaType: TrackingMediaType.book,
          mediaKey: 'book',
          provider: fakeSiteId,
        ),
        isNotNull,
      );
      expect(await repository.allPending(provider: fakeSiteId), hasLength(1));
    });
  });
}
