import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/tracking/media_tracking_repository.dart';
import 'package:fushi_engine/media/tracking/media_tracking_service.dart';
import 'package:fushi_engine/media/tracking/tracking_provider.dart';

final class _Session implements TrackingProviderSession {
  @override
  void close() {}
}

/// A signed-in anime site whose sends succeed unless [failWith] is set.
final class _Site implements TrackingProvider {
  Exception? failWith;

  @override
  String get id => 'site';

  @override
  String get displayName => 'Site';

  @override
  String get siteHost => '';

  @override
  TrackingProviderCapabilities get capabilities =>
      const TrackingProviderCapabilities(
        kinds: <TrackingKind>{TrackingKind.anime},
        progressModes: <TrackingProgressMode>{TrackingProgressMode.episode},
      );

  @override
  bool get isConfigured => true;

  @override
  Future<TrackingProviderSession> openSession() async => _Session();

  @override
  Future<void> push(
    TrackingProviderSession session,
    PendingTrackingUpdate update,
  ) async {
    final Exception? error = failWith;
    if (error != null) throw error;
  }

  @override
  TrackingFailureKind classify(Object error) => TrackingFailureKind.transient;
}

void main() {
  late FushiDatabase db;
  late PreferencesRepository prefs;
  late MediaTrackingRepository repository;
  late _Site site;
  late MediaTrackingService service;

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    repository = MediaTrackingRepository(db);
    site = _Site();
    service = MediaTrackingService(
      repository: repository,
      preferences: prefs,
      userAgent: 'test',
      extraProviders: <TrackingProvider>[site],
    );
  });

  tearDown(() async {
    service.dispose();
    prefs.dispose();
    await db.close();
  });

  Future<void> queue(String key, String title, {int offset = 1}) async {
    await repository.saveMapping(
      mediaType: TrackingMediaType.video,
      mediaKey: key,
      mediaTitle: title,
      kind: TrackingKind.anime,
      subjectId: 7,
      subjectName: 'Remote',
      progressMode: TrackingProgressMode.episode,
      progressOffset: offset,
      provider: site.id,
    );
    await repository.enqueueProgress(
      mediaType: TrackingMediaType.video,
      mediaKey: key,
      localProgress: 0,
      completed: true,
      provider: site.id,
    );
  }

  test('a send writes an ok row: site, title, progress, time', () async {
    await queue('v1', 'Frieren 05', offset: 5);
    final int before = DateTime.now().millisecondsSinceEpoch;
    await service.syncNow(force: true);

    final MediaTrackingActivityRow row = (await service.loadActivity()).single;
    expect(row.ok, isTrue);
    expect(row.error, isNull);
    expect(row.provider, 'site');
    expect(row.mediaTitle, 'Frieren 05');
    expect(row.kind, TrackingKind.anime.value);
    expect(row.progressMode, TrackingProgressMode.episode.value);
    expect(row.progress, 5);
    expect(row.completed, isTrue);
    expect(row.createdAt, greaterThanOrEqualTo(before));
  });

  test('a failed send writes an error row and stays queued', () async {
    site.failWith = Exception('HTTP 500 boom');
    await queue('v1', 'Frieren 01');
    await service.syncNow(force: true);

    final MediaTrackingActivityRow row = (await service.loadActivity()).single;
    expect(row.ok, isFalse);
    expect(row.error, contains('HTTP 500 boom'));
    expect(await repository.pendingCount(), 1);

    site.failWith = null;
    await service.syncNow(force: true);
    final List<MediaTrackingActivityRow> rows = await service.loadActivity();
    expect(rows.map((MediaTrackingActivityRow r) => r.ok), <bool>[
      true,
      false,
    ], reason: 'newest first');
  });

  test('the log keeps only the newest 500 rows', () async {
    await queue('v1', 'Frieren 01');
    final PendingTrackingUpdate update = (await repository.allPending()).single;
    for (int i = 0; i < MediaTrackingRepository.activityLimit + 5; i++) {
      await repository.logActivity(update, nowMs: i);
    }
    final List<MediaTrackingActivityRow> rows = await service.loadActivity();
    expect(rows, hasLength(MediaTrackingRepository.activityLimit));
    expect(rows.first.createdAt, MediaTrackingRepository.activityLimit + 4);
    expect(rows.last.createdAt, 5, reason: 'the 5 oldest were trimmed');
    final int stored = (await db.select(db.mediaTrackingActivity).get()).length;
    expect(stored, MediaTrackingRepository.activityLimit);
  });
}
