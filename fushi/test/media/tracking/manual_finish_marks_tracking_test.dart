import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/library_finish_marks.dart';
import 'package:fushi/src/media/video/video_watched_marks.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/tracking/media_tracking_repository.dart';
import 'package:fushi_engine/media/tracking/media_tracking_service.dart';
import 'package:fushi_engine/media/tracking/tracking_provider.dart';

/// BUG-4402: a finished / watched mark set by hand (shelf menu, batch
/// action, CLI) reaches media tracking like the reader's end of book does.

final class _Session implements TrackingProviderSession {
  @override
  void close() {}
}

/// A signed-in site that tracks books and anime; records what it receives.
final class _Site implements TrackingProvider {
  final List<PendingTrackingUpdate> pushed = <PendingTrackingUpdate>[];

  @override
  String get id => _siteId;

  @override
  String get displayName => _siteId;

  @override
  String get siteHost => '';

  @override
  TrackingProviderCapabilities get capabilities =>
      const TrackingProviderCapabilities(
        kinds: <TrackingKind>{
          TrackingKind.novel,
          TrackingKind.manga,
          TrackingKind.anime,
        },
        progressModes: <TrackingProgressMode>{
          TrackingProgressMode.chapter,
          TrackingProgressMode.volume,
          TrackingProgressMode.episode,
        },
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

final class _Timer implements Timer {
  @override
  void cancel() {}

  @override
  bool get isActive => false;

  @override
  int get tick => 0;
}

const String _siteId = 'site';

void main() {
  late FushiDatabase db;
  late PreferencesRepository preferences;
  late MediaTrackingRepository repository;
  late _Site site;
  late MediaTrackingService service;
  late LibraryFinishTracking tracking;

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    preferences = PreferencesRepository(db);
    await preferences.loadFromDb();
    repository = MediaTrackingRepository(db);
    site = _Site();
    service = MediaTrackingService(
      repository: repository,
      preferences: preferences,
      userAgent: 'test-agent',
      retryTimerFactory: (Duration delay, void Function() callback) => _Timer(),
      extraProviders: <TrackingProvider>[site],
    );
    // The same calls AppModel.libraryFinishTracking makes, awaited.
    tracking = LibraryFinishTracking(
      onBooksFinished: (List<String> bookKeys) async {
        for (final String bookKey in bookKeys) {
          await service.recordPagedBookProgress(bookKey);
        }
        await service.whenBookLinksSettled();
      },
      onVideosWatched: (List<String> _) async {
        await service.syncNow();
      },
    );
  });

  tearDown(() async {
    service.dispose();
    preferences.dispose();
    await db.close();
  });

  Future<void> insertManga(String bookKey) => db.insertEpubBook(
    EpubBooksCompanion.insert(
      bookKey: bookKey,
      title: bookKey,
      epubPath: '/tmp/$bookKey',
      extractDir: '/tmp/$bookKey',
      chapterCount: 0,
      chaptersJson: '[]',
      importedAt: 1,
      format: const Value<String>('manga'),
    ),
  );

  Future<void> linkVolume(String bookKey, int volume) => repository
      .saveMapping(
        mediaType: TrackingMediaType.book,
        mediaKey: bookKey,
        mediaTitle: bookKey,
        kind: TrackingKind.manga,
        subjectId: 7,
        subjectName: 'Ajin',
        progressMode: TrackingProgressMode.volume,
        progressOffset: volume,
        provider: _siteId,
      )
      .then((_) {});

  /// Lets the sync started by the mark finish, then returns what was sent.
  Future<List<PendingTrackingUpdate>> sent() async {
    await service.syncNow();
    return site.pushed;
  }

  test('marking a linked volume finished sends that volume once', () async {
    await insertManga('ajin-01');
    await linkVolume('ajin-01', 1);
    await service.syncNow();
    expect(site.pushed, isEmpty);

    await setBooksFinished(
      db: db,
      tracking: tracking,
      bookKeys: <String>['ajin-01'],
      finished: true,
    );

    final List<PendingTrackingUpdate> updates = await sent();
    expect(updates, hasLength(1));
    expect(updates.single.mapping.mediaKey, 'ajin-01');
    expect(updates.single.outbox.progress, 1);
    expect(updates.single.outbox.completed, isTrue);
    expect((await db.getEpubBook('ajin-01'))!.completedAt, isNotNull);
  });

  test('marking an unlinked book finished sends nothing', () async {
    await insertManga('loose');

    await setBooksFinished(
      db: db,
      tracking: tracking,
      bookKeys: <String>['loose'],
      finished: true,
    );

    expect(await sent(), isEmpty);
    expect(await repository.allPending(), isEmpty);
    expect((await db.getEpubBook('loose'))!.completedAt, isNotNull);
  });

  test('un-marking never sends a lower progress', () async {
    await insertManga('ajin-02');
    await linkVolume('ajin-02', 2);
    await setBooksFinished(
      db: db,
      tracking: tracking,
      bookKeys: <String>['ajin-02'],
      finished: true,
    );
    expect((await sent()).single.outbox.progress, 2);

    await setBooksFinished(
      db: db,
      tracking: tracking,
      bookKeys: <String>['ajin-02'],
      finished: false,
    );

    expect((await db.getEpubBook('ajin-02'))!.completedAt, isNull);
    final List<PendingTrackingUpdate> updates = await sent();
    expect(updates, hasLength(1), reason: 'nothing new after the un-mark');
    expect(await repository.allPending(), isEmpty);
  });

  test('marking a linked video watched by hand sends the episode', () async {
    await db.upsertVideoBook(
      VideoBooksCompanion.insert(
        bookUid: 'ep-03',
        title: 'Ajin 03',
        videoPath: '/anime/Ajin/03.mkv',
      ),
    );
    await repository.saveMapping(
      mediaType: TrackingMediaType.video,
      mediaKey: 'ep-03',
      mediaTitle: 'Ajin 03',
      kind: TrackingKind.anime,
      subjectId: 9,
      subjectName: 'Ajin',
      progressMode: TrackingProgressMode.episode,
      progressOffset: 3,
      provider: _siteId,
    );
    // A first sync moves the catch-up watermark past the link itself.
    await service.syncNow();
    expect(site.pushed, isEmpty);

    await setVideosWatched(
      db: db,
      tracking: tracking,
      watched: true,
      localUids: <String>['ep-03'],
      now: DateTime.now().add(const Duration(seconds: 1)),
    );

    final List<PendingTrackingUpdate> updates = await sent();
    expect(updates, hasLength(1));
    expect(updates.single.mapping.mediaKey, 'ep-03');
    expect(updates.single.outbox.completed, isTrue);
  });

  test('every hand-set finished mark goes through setBooksFinished', () {
    // Source guard: a direct write would skip tracking again.
    final List<String> offenders = <String>[
      for (final FileSystemEntity entity in Directory(
        'lib',
      ).listSync(recursive: true))
        if (entity is File &&
            entity.path.endsWith('.dart') &&
            !entity.path
                .replaceAll(r'\', '/')
                .endsWith('lib/src/media/library_finish_marks.dart') &&
            entity.readAsStringSync().contains('.setEpubBookCompleted('))
          entity.path,
    ];
    expect(offenders, isEmpty);
  });
}
