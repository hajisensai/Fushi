import 'package:drift/drift.dart' show Value;
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

/// A signed-in anime site that records every send.
final class _Site implements TrackingProvider {
  final List<PendingTrackingUpdate> pushed = <PendingTrackingUpdate>[];

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
  ) async => pushed.add(update);

  @override
  TrackingFailureKind classify(Object error) => TrackingFailureKind.transient;
}

/// Audit gap 2: the catch-up used to send only evidence newer than a time
/// watermark, so progress arriving late with an older timestamp (adopted
/// from Kavita, synced from another device, restored) was skipped forever.
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

  String watermarkKey() =>
      TrackingProviderPrefKeys.forProvider(site.id).videoWatermark;

  Future<void> seedVideo(String uid, {int? watchedAtMs}) => db.upsertVideoBook(
    VideoBooksCompanion.insert(
      bookUid: uid,
      title: uid,
      videoPath: '/anime/$uid.mkv',
      completedAt: Value<DateTime?>(
        watchedAtMs == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(watchedAtMs),
      ),
    ),
  );

  Future<int> link(String uid, {int subjectId = 7}) => repository.saveMapping(
    mediaType: TrackingMediaType.video,
    mediaKey: uid,
    mediaTitle: uid,
    kind: TrackingKind.anime,
    subjectId: subjectId,
    subjectName: 'Remote',
    progressMode: TrackingProgressMode.episode,
    progressOffset: 3,
    provider: site.id,
  );

  Future<MediaTrackingMappingRow> mappingOf(String uid) async =>
      (await repository.findMapping(
        mediaType: TrackingMediaType.video,
        mediaKey: uid,
        provider: site.id,
      ))!;

  List<String> sentKeys() => <String>[
    for (final PendingTrackingUpdate update in site.pushed)
      update.mapping.mediaKey,
  ];

  test('progress with an old timestamp that arrives after the watermark is '
      'sent once; nothing goes again when nothing changed', () async {
    await seedVideo('v1');
    await link('v1');
    await service.syncNow(force: true);
    expect(site.pushed, isEmpty, reason: 'not watched yet');
    expect(
      prefs.getPref(watermarkKey(), defaultValue: 0),
      greaterThan(1000),
      reason: 'the watermark moved past the old timestamp',
    );

    // Adopted from a server / another device: watched long ago.
    await seedVideo('v1', watchedAtMs: 1000);
    await service.syncNow(force: true);
    expect(sentKeys(), <String>['v1']);
    expect(site.pushed.single.outbox.progress, 3);
    final MediaTrackingMappingRow sent = await mappingOf('v1');
    expect(sent.sentProgress, 3);
    expect(sent.sentCompleted, isTrue);

    await service.syncNow(force: true);
    await service.syncNow(force: true);
    expect(sentKeys(), <String>['v1'], reason: 'sent once');
    expect(await repository.pendingCount(), 0);
  });

  test('a new link sends the existing progress, also with an old '
      'timestamp; a changed link sends it again', () async {
    await seedVideo('v1', watchedAtMs: 1000);
    await prefs.setPref(
      watermarkKey(),
      DateTime.now().millisecondsSinceEpoch + 60000,
    );
    await link('v1');
    await service.syncNow(force: true);
    expect(sentKeys(), <String>['v1']);

    // The same link again (same entry, unit and number) is not a change:
    // what it sent still stands (T2 G13).
    await link('v1');
    expect((await mappingOf('v1')).sentProgress, 3);
    await service.syncNow(force: true);
    expect(sentKeys(), <String>['v1']);

    await link('v1', subjectId: 8);
    expect((await mappingOf('v1')).sentProgress, isNull);
    await service.syncNow(force: true);
    expect(sentKeys(), <String>['v1', 'v1']);
  });

  test('a link made before v152 under the old watermark takes its progress '
      'as sent; one with newer progress is sent', () async {
    await seedVideo('old', watchedAtMs: 1000);
    await seedVideo('newer', watchedAtMs: 9000);
    await link('old');
    await link('newer');
    await db.customStatement(
      'UPDATE media_tracking_mappings SET sent_progress = -1, updated_at = 1',
    );
    await prefs.setPref(watermarkKey(), 5000);

    await service.syncNow(force: true);
    expect(sentKeys(), <String>['newer']);
    expect((await mappingOf('old')).sentProgress, 3, reason: 'adopted');
    await service.syncNow(force: true);
    expect(sentKeys(), <String>['newer']);
  });

  test('watermark 0 (a new account) sends everything again', () async {
    await seedVideo('v1', watchedAtMs: 1000);
    await link('v1');
    await service.syncNow(force: true);
    expect(sentKeys(), <String>['v1']);

    await prefs.setPref(watermarkKey(), 0);
    await service.syncNow(force: true);
    expect(sentKeys(), <String>['v1', 'v1']);
  });

  test('never a decrease: lower local progress queues nothing', () async {
    await seedVideo('v1', watchedAtMs: 1000);
    await link('v1');
    await db.customStatement(
      'UPDATE media_tracking_mappings SET sent_progress = 10, '
      'sent_completed = 1',
    );
    await prefs.setPref(watermarkKey(), 1);
    await service.syncNow(force: true);
    expect(site.pushed, isEmpty);
    expect(await repository.pendingCount(), 0);
  });
}
