import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/tracking/media_tracking_repository.dart';
import 'package:fushi_engine/media/tracking/media_tracking_service.dart';
import 'package:fushi_engine/media/tracking/remote_anime_link.dart';
import 'package:fushi_engine/media/tracking/tracking_provider.dart';

final class _Session implements TrackingProviderSession {
  @override
  void close() {}
}

/// A signed-in anime site that links media server episodes by its own id.
/// [failSends]: every send fails (rows stay queued).
final class _Site implements TrackingProvider, TrackingAnimeLinker {
  bool failSends = false;
  final List<PendingTrackingUpdate> pushed = <PendingTrackingUpdate>[];

  @override
  String get id => RemoteAnimeIdType.anilist;

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
    if (failSends) throw StateError('offline');
    pushed.add(update);
  }

  @override
  TrackingFailureKind classify(Object error) => TrackingFailureKind.transient;

  @override
  Future<TrackingLinkedSubject?> animeById(int subjectId) async =>
      TrackingLinkedSubject(subjectId: subjectId, name: 'Show $subjectId');

  @override
  Future<TrackingLinkedSubject?> animeForMalId(int malAnimeId) async => null;
}

RemoteAnimeEpisode _episode(int number) => RemoteAnimeEpisode(
  mediaKey: 'jellyfin|srv|u|frieren-e$number',
  title: 'Frieren S1E$number',
  episodeNumber: number,
  seasonNumber: 1,
  seriesId: 'frieren',
  seriesTitle: 'Frieren',
  seriesIds: const <String, String>{'anilist': '11'},
  serverName: 'Home server',
);

const String _season = 'jellyfin|srv|u|series:frieren|season:1';

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

  test('ignoring a season pauses the queued rows of its episodes linked from '
      'the server ids; "Track again" releases them', () async {
    site.failSends = true;
    await service.recordRemoteVideoCompleted(_episode(3));
    await service.syncNow(force: true);
    expect(site.pushed, isEmpty);
    expect(await repository.pendingCount(), 1, reason: 'linked, not sent');
    expect(
      await repository.listUnlinkedHistory(),
      isEmpty,
      reason: 'a linked episode needs no link',
    );

    await service.ignoreItem(
      mediaType: TrackingMediaType.remoteSeries,
      mediaKey: _season,
      mediaTitle: 'Frieren S1',
      kind: TrackingKind.anime,
    );
    expect(
      (await service.loadIgnoreIndex()).covers(
        TrackingMediaType.remoteVideo.value,
        _episode(3).mediaKey,
      ),
      isTrue,
    );
    site.failSends = false;
    await service.syncNow(force: true);
    expect(site.pushed, isEmpty, reason: 'nothing of an ignored season');
    expect(await repository.pendingCount(), 1, reason: 'still waits');

    // Watched while ignored: no send either.
    await service.recordRemoteVideoCompleted(_episode(4));
    await service.syncNow(force: true);
    expect(site.pushed, isEmpty);

    await service.trackAgain(
      mediaType: TrackingMediaType.remoteSeries.value,
      mediaKey: _season,
    );
    await service.syncNow(force: true);
    expect(
      site.pushed.map((PendingTrackingUpdate u) => u.mapping.mediaKey),
      contains(_episode(3).mediaKey),
    );
    expect(await repository.pendingCount(), 0);
  });

  test('series index: a book series, a video collection, a media server '
      'season; a chapter companion follows its book', () async {
    await db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: 'Ajin 01',
        title: 'Ajin 01',
        epubPath: '/books/ajin01.cbz',
        extractDir: '/books/ajin01',
        chapterCount: 1,
        chaptersJson: '[]',
        importedAt: 1,
      ),
    );
    final int books = await db.createMediaCollection('Ajin');
    await db.addToCollection(books, MediaKind.epub, 'Ajin 01');
    final int videos = await db.createMediaCollection(
      'Frieren',
      collectionType: 'playlist',
    );
    await db.addToCollection(videos, MediaKind.video, 'v1');
    await repository.rememberRemoteEpisode(_episode(1));
    await repository.rememberRemoteEpisode(
      const RemoteAnimeEpisode(
        mediaKey: 'jellyfin|srv|u|lone',
        title: 'Lone episode',
        episodeNumber: 2,
      ),
    );

    final TrackingSeriesIndex index = await service.loadSeriesIndex();
    final TrackingSeriesRef? book = index.seriesOf(
      TrackingMediaType.book.value,
      'Ajin 01',
    );
    expect(book?.type, TrackingMediaType.bookCollection);
    expect(book?.key, '$books');
    expect(book?.title, 'Ajin');
    expect(
      index.seriesOf(TrackingMediaType.bookChapter.value, 'Ajin 01'),
      book,
    );
    final TrackingSeriesRef? video = index.seriesOf(
      TrackingMediaType.video.value,
      'v1',
    );
    expect(video?.type, TrackingMediaType.videoCollection);
    expect(video?.key, '$videos');
    final TrackingSeriesRef? season = index.seriesOf(
      TrackingMediaType.remoteVideo.value,
      _episode(1).mediaKey,
    );
    expect(season?.type, TrackingMediaType.remoteSeries);
    expect(season?.key, _season);
    expect(season?.title, 'Frieren S1');
    expect(
      index.seriesOf(
        TrackingMediaType.remoteVideo.value,
        'jellyfin|srv|u|lone',
      ),
      isNull,
      reason: 'no season known',
    );
  });
}
