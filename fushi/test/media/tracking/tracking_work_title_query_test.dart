import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:test/test.dart';
import 'package:fushi/src/media/tracking/page/tracking_local_targets.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/tracking/media_tracking_repository.dart';
import 'package:fushi_engine/media/tracking/remote_anime_link.dart';

/// T1 F2 (left over): a video's search starts from the work's name (scraped
/// title, its series card, the media server's series), the cleaned file
/// name only when nothing names the work.
void main() {
  late FushiDatabase db;

  setUp(() => db = FushiDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  Future<void> addVideo(String uid, String title) => db.upsertVideoBook(
    VideoBooksCompanion.insert(
      bookUid: uid,
      title: title,
      videoPath: 'C:/anime/$title.mkv',
    ),
  );

  test('a scraped work title comes first; an episode-level one is not the '
      "work's name", () async {
    await addVideo('v1', '[FSP] Beyond Time\'s Gaze Episode 46 [4K HEVC AAC]');
    await db.upsertVideoScrapeMeta(
      VideoScrapeMetaCompanion.insert(
        bookUid: 'v1',
        source: 'tmdb',
        subjectId: '1',
        title: "Beyond Time's Gaze",
        scrapedAt: DateTime(2026, 11),
      ),
    );
    final List<String> works = await trackingWorkTitlesFor(
      db,
      TrackingMediaType.video,
      'v1',
    );
    expect(works, <String>["Beyond Time's Gaze"]);
    expect(
      trackingInitialQuery(
        '[FSP] Beyond Time\'s Gaze Episode 46 [4K HEVC AAC]',
        workTitles: works,
      ),
      "Beyond Time's Gaze",
    );

    await addVideo('v2', 'Show - S01E03 - Some episode');
    await db.upsertVideoScrapeMeta(
      VideoScrapeMetaCompanion.insert(
        bookUid: 'v2',
        source: 'tmdb',
        subjectId: '2',
        title: 'Some episode',
        episodeNumber: const Value<int?>(3),
        scrapedAt: DateTime(2026, 11),
      ),
    );
    expect(
      await trackingWorkTitlesFor(db, TrackingMediaType.video, 'v2'),
      isEmpty,
    );
  });

  test("the video's series card names it, then the file name", () async {
    await addVideo('v3', 'How Dare You!! (2026) - S01E01 - Episode 1');
    final int id = await db.createMediaCollection(
      'How Dare You!!',
      collectionType: 'playlist',
    );
    await db.addToCollection(id, MediaKind.video, 'v3');
    expect(
      await trackingWorkTitlesFor(db, TrackingMediaType.video, 'v3'),
      <String>['How Dare You!!'],
    );
    expect(
      await trackingWorkTitlesFor(db, TrackingMediaType.videoCollection, '$id'),
      <String>['How Dare You!!'],
    );
    await addVideo('v4', 'Frieren 01');
    expect(
      trackingInitialQuery(
        'Frieren 01',
        workTitles: await trackingWorkTitlesFor(
          db,
          TrackingMediaType.video,
          'v4',
        ),
      ),
      trackingInitialQuery('Frieren 01'),
    );
  });

  test("a media server season searches the server's series title", () async {
    const RemoteAnimeEpisode episode = RemoteAnimeEpisode(
      mediaKey: 'jellyfin|srv|u|e20',
      title: 'As Promised S1E20',
      episodeNumber: 20,
      seasonNumber: 1,
      seriesId: 'show',
      seriesTitle: 'As Promised',
    );
    await MediaTrackingRepository(db).rememberRemoteEpisode(episode);
    expect(
      await trackingWorkTitlesFor(
        db,
        TrackingMediaType.remoteSeries,
        remoteAnimeGroupKey(episode),
      ),
      <String>['As Promised'],
    );
  });
}
