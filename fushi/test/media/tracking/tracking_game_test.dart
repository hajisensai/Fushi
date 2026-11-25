// Games on a site other than built-in Bangumi (T1 F3 item 1d): a played game
// is offered for linking only while a signed-in site tracks games, and its
// play status goes out through that site. Real tracking service, in-memory
// database, a stand-in site declaring kind game / mode status (as the bundled
// Bangumi plugin does).
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/tracking/media_tracking_repository.dart';
import 'package:fushi_engine/media/tracking/media_tracking_service.dart';
import 'package:fushi_engine/media/tracking/tracking_provider.dart';
import 'package:fushi_engine/media/tracking/tracking_subject_search.dart';

final class _Session implements TrackingProviderSession {
  @override
  void close() {}
}

/// A searchable site of [kinds]; signed in while [configured].
final class _Site implements TrackingProvider, TrackingSubjectSearch {
  _Site(this.id, this.kinds, this.modes);

  @override
  final String id;
  final Set<TrackingKind> kinds;
  final Set<TrackingProgressMode> modes;
  bool configured = true;
  final List<PendingTrackingUpdate> pushed = <PendingTrackingUpdate>[];

  @override
  String get displayName => 'Site $id';

  @override
  String get siteHost => '$id.example';

  @override
  TrackingProviderCapabilities get capabilities =>
      TrackingProviderCapabilities(kinds: kinds, progressModes: modes);

  @override
  bool get isConfigured => configured;

  @override
  Future<TrackingProviderSession> openSession() async => _Session();

  @override
  Future<void> push(
    TrackingProviderSession session,
    PendingTrackingUpdate update,
  ) async => pushed.add(update);

  @override
  TrackingFailureKind classify(Object error) => TrackingFailureKind.transient;

  @override
  Future<List<TrackingSearchHit>> searchSubjects(
    String query,
    TrackingKind kind,
  ) async => <TrackingSearchHit>[
    if (kind == TrackingKind.game)
      const TrackingSearchHit(
        subjectId: 55,
        name: 'Some game',
        kind: TrackingKind.game,
      ),
  ];

  @override
  Future<TrackingSearchHit?> subjectById(int subjectId, TrackingKind kind) =>
      throw UnimplementedError();

  @override
  Uri? subjectPageUrl(int subjectId, TrackingKind kind) => null;
}

void main() {
  late FushiDatabase db;
  late PreferencesRepository prefs;
  late MediaTrackingRepository repository;
  late MediaTrackingService service;
  late _Site games;
  late _Site anime;

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    // Built-in Bangumi is not signed in: only the stand-in tracks games.
    await prefs.setPref(kBangumiAccessTokenPref, '');
    repository = MediaTrackingRepository(db);
    games = _Site(
      'games',
      <TrackingKind>{TrackingKind.game},
      <TrackingProgressMode>{TrackingProgressMode.status},
    );
    anime = _Site(
      'anime',
      <TrackingKind>{TrackingKind.anime},
      <TrackingProgressMode>{TrackingProgressMode.episode},
    );
    service = MediaTrackingService(
      repository: repository,
      preferences: prefs,
      userAgent: 'test-agent',
      extraProviders: <TrackingProvider>[anime, games],
      retryTimerFactory: (Duration delay, void Function() callback) =>
          throw StateError('no retry expected'),
    );
    await db.upsertGalgame(
      GalgamesCompanion.insert(
        id: 'game',
        name: 'Some game',
        exePath: '/games/game.exe',
        workdir: '/games',
        addedAt: 1000,
        playStatus: const Value<int>(1),
      ),
    );
  });

  tearDown(() async {
    service.dispose();
    prefs.dispose();
    await db.close();
  });

  Future<Set<String>> offered() async => <String>{
    for (final MediaTrackingUnlinkedItem item
        in (await service.loadHomeSnapshot()).unlinked)
      item.mediaKey,
  };

  /// The game page sets the status (stored), then tells tracking.
  Future<void> setStatus(int status) async {
    await db.upsertGalgame(
      GalgamesCompanion.insert(
        id: 'game',
        name: 'Some game',
        exePath: '/games/game.exe',
        workdir: '/games',
        addedAt: 1000,
        playStatus: Value<int>(status),
      ),
    );
    await service.recordGameStatus(gameId: 'game', status: status);
  }

  test('offered only while a signed-in site tracks games', () async {
    expect(await offered(), contains('game'));
    expect(service.manualLinkSitesFor(TrackingKind.game), <TrackingProvider>[
      games,
    ]);

    games.configured = false;
    expect(await offered(), isNot(contains('game')));
    expect(service.manualLinkSitesFor(TrackingKind.game), isEmpty);

    games.configured = true;
    await service.setKindEnabled(games.id, TrackingKind.game, false);
    expect(
      await offered(),
      isNot(contains('game')),
      reason: 'the game kind switched off on the only game site',
    );
  });

  test('linked by hand, the play status is sent, then each change once, '
      'backwards too', () async {
    final TrackingSearchHit hit = (await service.searchSiteSubjects(
      providerId: games.id,
      query: 'Some game',
      kind: TrackingKind.game,
    )).single;
    await service.linkItemToSubject(
      mediaType: TrackingMediaType.game,
      mediaKey: 'game',
      mediaTitle: 'Some game',
      kind: TrackingKind.game,
      providerId: games.id,
      hit: hit,
      progressMode: TrackingProgressMode.status,
      progressOffset: 0,
    );
    await service.syncNow();
    expect(games.pushed.single.mapping.kind, TrackingKind.game.value);
    expect(
      games.pushed.single.mapping.progressMode,
      TrackingProgressMode.status.value,
    );
    expect(games.pushed.single.outbox.progress, 1, reason: 'wish to play');
    expect(anime.pushed, isEmpty);

    await setStatus(2);
    await service.syncNow();
    expect(games.pushed.last.outbox.progress, 2);
    expect(games.pushed.last.outbox.completed, isTrue, reason: 'played');

    await setStatus(2);
    await service.syncNow();
    expect(games.pushed, hasLength(2), reason: 'the same status once');

    await setStatus(3);
    await service.syncNow();
    expect(games.pushed, hasLength(3));
    expect(games.pushed.last.outbox.progress, 3, reason: 'back to playing');
    expect(await repository.allPending(provider: games.id), isEmpty);
  });
}
