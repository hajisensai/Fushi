import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/source_library/source_library_row.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_database_store.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_models.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_provider.dart';
import 'package:fushi/src/media/video/metadata/video_source_work_planner.dart';
import 'package:fushi_core/fushi_core.dart';

void main() {
  late FushiDatabase database;
  late VideoMetadataDatabaseStore store;
  late VideoSourceScrapeWork localWork;

  setUp(() async {
    database = FushiDatabase.forTesting(NativeDatabase.memory());
    store = VideoMetadataDatabaseStore(database);
    final int sourceId = await database.insertMediaSource(
      MediaSourcesCompanion.insert(
        label: 'Movies',
        mediaKind: 'video',
        rootPath: 'D:/Movies',
        createdAt: 1,
      ),
    );
    await database.upsertVideoBook(
      VideoBooksCompanion(
        bookUid: const Value<String>('movie-1'),
        title: const Value<String>('Example Movie'),
        videoPath: const Value<String>('D:/Movies/Example Movie (2025).mkv'),
        sourceId: Value<int?>(sourceId),
      ),
    );
    final SourceLibraryRow source =
        (await database.getMediaSourceById(sourceId))!;
    final VideoBookRow book =
        (await database.getVideoBookByBookUid('movie-1'))!;
    localWork = VideoSourceScrapeWork(
      source: source,
      title: book.title,
      members: <VideoBookRow>[book],
    );
  });

  tearDown(() => database.close());

  test('重刮整体替换图片候选时保留同一远端图片的本地路径', () async {
    final VideoMetadataWork metadata = _tmdbMetadata(
      images: const <VideoMetadataImage>[
        VideoMetadataImage(
          kind: VideoMetadataImageKind.cover,
          url: 'https://image.example/poster.jpg',
          provider: VideoMetadataProviderKind.tmdb,
        ),
        VideoMetadataImage(
          kind: VideoMetadataImageKind.backdrop,
          url: 'https://image.example/backdrop.jpg',
          provider: VideoMetadataProviderKind.tmdb,
        ),
      ],
    );

    final PersistedVideoMetadata first = await store.apply(localWork, metadata);
    await store.updateCanonicalImagePaths(
      persisted: first,
      metadata: metadata,
      localPathByRemoteUrl: const <String, String>{
        'https://image.example/poster.jpg':
            'D:/Movies/Example Movie (2025)-poster.jpg',
      },
    );

    final PersistedVideoMetadata second =
        await store.apply(localWork, metadata);
    await store.updateCanonicalImagePaths(
      persisted: second,
      metadata: metadata,
      localPathByRemoteUrl: const <String, String>{},
    );

    final List<VideoMetadataImageRow> images =
        await database.getVideoMetadataImages(workId: second.workId);
    expect(
      images
          .singleWhere(
            (VideoMetadataImageRow row) => row.kind == 'cover',
          )
          .localPath,
      'D:/Movies/Example Movie (2025)-poster.jpg',
    );
    expect(
      images
          .singleWhere(
            (VideoMetadataImageRow row) => row.kind == 'backdrop',
          )
          .localPath,
      isNull,
    );

    final PersistedVideoMetadata changedProvider = await store.apply(
      localWork,
      _tmdbMetadata(
        images: const <VideoMetadataImage>[
          VideoMetadataImage(
            kind: VideoMetadataImageKind.cover,
            url: 'https://image.example/poster.jpg',
            provider: VideoMetadataProviderKind.fanart,
          ),
        ],
      ),
    );
    expect(
      (await database.getVideoMetadataImages(
        workId: changedProvider.workId,
      ))
          .single
          .localPath,
      isNull,
      reason: '相同 URL 但不同 provider 的图片不能继承旧资产路径',
    );
  });

  test('混来源合集交替刮削时保留另一来源已绑定的分集', () async {
    final (SourceLibraryRow sourceA, VideoBookRow episode1) =
        await _addSourceEpisode(
      database,
      sourceLabel: 'Source A',
      sourceRoot: 'D:/A',
      bookUid: 'show-a-e1',
      videoPath: 'D:/A/Show/Show S01E01.mkv',
    );
    final (SourceLibraryRow sourceB, VideoBookRow episode2) =
        await _addSourceEpisode(
      database,
      sourceLabel: 'Source B',
      sourceRoot: 'D:/B',
      bookUid: 'show-b-e2',
      videoPath: 'D:/B/Show/Show S01E02.mkv',
    );
    final int collectionId = await database.createMediaCollection(
      'Show',
      collectionType: 'playlist',
    );
    await database.addToCollection(
      collectionId,
      MediaKind.video,
      episode1.bookUid,
    );
    await database.addToCollection(
      collectionId,
      MediaKind.video,
      episode2.bookUid,
    );
    final MediaCollectionRow collection =
        (await database.getMediaCollectionById(collectionId))!;
    final VideoSourceScrapeWork workA = VideoSourceScrapeWork(
      source: sourceA,
      collection: collection,
      title: collection.name,
      members: <VideoBookRow>[episode1],
    );
    final VideoSourceScrapeWork workB = VideoSourceScrapeWork(
      source: sourceB,
      collection: collection,
      title: collection.name,
      members: <VideoBookRow>[episode2],
    );
    final VideoMetadataWork metadata = VideoMetadataWork(
      provider: VideoMetadataProviderKind.tmdb,
      kind: VideoMetadataMediaKind.tv,
      title: 'Show',
      ids: const <VideoMetadataId>[
        VideoMetadataId(type: 'tmdb', value: '100'),
      ],
      seasons: <VideoMetadataSeason>[
        VideoMetadataSeason(
          seasonNumber: 1,
          title: 'Season 1',
          episodes: <VideoMetadataEpisode>[
            VideoMetadataEpisode(
              seasonNumber: 1,
              episodeNumber: 1,
              title: 'Episode 1',
            ),
            VideoMetadataEpisode(
              seasonNumber: 1,
              episodeNumber: 2,
              title: 'Episode 2',
            ),
          ],
        ),
      ],
    );

    await store.apply(workA, metadata);
    await store.apply(workB, metadata);
    await _expectEpisodeBindings(
      database,
      collectionId,
      const <int, String?>{1: 'show-a-e1', 2: 'show-b-e2'},
    );

    await store.apply(workA, metadata);
    await _expectEpisodeBindings(
      database,
      collectionId,
      const <int, String?>{1: 'show-a-e1', 2: 'show-b-e2'},
    );
  });

  test('同一 bookUid 重链到新季集前解除旧绑定且保留另一来源成员', () async {
    final (SourceLibraryRow sourceA, VideoBookRow movingEpisode) =
        await _addSourceEpisode(
      database,
      sourceLabel: 'Source A',
      sourceRoot: 'D:/A',
      bookUid: 'moving-episode',
      videoPath: 'D:/A/Show/Show S01E01.mkv',
    );
    final (SourceLibraryRow sourceB, VideoBookRow otherEpisode) =
        await _addSourceEpisode(
      database,
      sourceLabel: 'Source B',
      sourceRoot: 'D:/B',
      bookUid: 'other-episode',
      videoPath: 'D:/B/Show/Show S01E02.mkv',
    );
    final int collectionId = await database.createMediaCollection(
      'Show',
      collectionType: 'playlist',
    );
    await database.addToCollection(
      collectionId,
      MediaKind.video,
      movingEpisode.bookUid,
    );
    await database.addToCollection(
      collectionId,
      MediaKind.video,
      otherEpisode.bookUid,
    );
    final MediaCollectionRow collection =
        (await database.getMediaCollectionById(collectionId))!;
    final VideoMetadataWork metadata = _tvMetadata(
      seasons: <VideoMetadataSeason>[
        VideoMetadataSeason(
          seasonNumber: 1,
          title: 'Season 1',
          episodes: <VideoMetadataEpisode>[
            VideoMetadataEpisode(
              seasonNumber: 1,
              episodeNumber: 1,
              title: 'Episode 1',
            ),
            VideoMetadataEpisode(
              seasonNumber: 1,
              episodeNumber: 2,
              title: 'Episode 2',
            ),
          ],
        ),
        VideoMetadataSeason(
          seasonNumber: 2,
          title: 'Season 2',
          episodes: <VideoMetadataEpisode>[
            VideoMetadataEpisode(
              seasonNumber: 2,
              episodeNumber: 3,
              title: 'Episode 3',
            ),
          ],
        ),
      ],
    );
    VideoSourceScrapeWork workA = VideoSourceScrapeWork(
      source: sourceA,
      collection: collection,
      title: collection.name,
      members: <VideoBookRow>[movingEpisode],
    );
    final VideoSourceScrapeWork workB = VideoSourceScrapeWork(
      source: sourceB,
      collection: collection,
      title: collection.name,
      members: <VideoBookRow>[otherEpisode],
    );
    await store.apply(workA, metadata);
    await store.apply(workB, metadata);

    await database.upsertVideoBook(VideoBooksCompanion(
      bookUid: const Value<String>('moving-episode'),
      title: const Value<String>('moving-episode'),
      videoPath: const Value<String>('D:/A/Show/Show S02E03.mkv'),
    ));
    workA = VideoSourceScrapeWork(
      source: sourceA,
      collection: collection,
      title: collection.name,
      members: <VideoBookRow>[
        (await database.getVideoBookByBookUid('moving-episode'))!,
      ],
    );

    await store.apply(workA, metadata);

    await _expectSeasonEpisodeBindings(
      database,
      collectionId,
      const <(int, int), String?>{
        (1, 1): null,
        (1, 2): 'other-episode',
        (2, 3): 'moving-episode',
      },
    );
  });

  test('合集刮削会迁移成员遗留的单视频规范 work', () async {
    final (SourceLibraryRow source, VideoBookRow episode1) =
        await _addSourceEpisode(
      database,
      sourceLabel: 'Series source',
      sourceRoot: 'D:/Series',
      bookUid: 'series-e1',
      videoPath: 'D:/Series/Show/Show S01E01.mkv',
    );
    await store.apply(
      VideoSourceScrapeWork(
        source: source,
        title: episode1.title,
        members: <VideoBookRow>[episode1],
      ),
      _tvMetadata(
        seasons: <VideoMetadataSeason>[
          VideoMetadataSeason(
            seasonNumber: 1,
            title: 'Season 1',
            episodes: <VideoMetadataEpisode>[
              VideoMetadataEpisode(
                seasonNumber: 1,
                episodeNumber: 1,
                title: 'Episode 1',
              ),
            ],
          ),
        ],
      ),
    );
    expect(await database.getVideoMetadataWorkByBook('series-e1'), isNotNull);

    final (_, VideoBookRow episode2) = await _addSourceEpisode(
      database,
      sourceLabel: 'Series source 2',
      sourceRoot: 'D:/Series2',
      bookUid: 'series-e2',
      videoPath: 'D:/Series2/Show/Show S01E02.mkv',
    );
    final int collectionId = await database.createMediaCollection(
      'Show',
      collectionType: 'playlist',
    );
    await database.addToCollection(
        collectionId, MediaKind.video, episode1.bookUid);
    await database.addToCollection(
        collectionId, MediaKind.video, episode2.bookUid);
    final MediaCollectionRow collection =
        (await database.getMediaCollectionById(collectionId))!;

    await store.apply(
      VideoSourceScrapeWork(
        source: source,
        collection: collection,
        title: collection.name,
        members: <VideoBookRow>[episode1],
      ),
      _tvMetadata(
        seasons: <VideoMetadataSeason>[
          VideoMetadataSeason(
            seasonNumber: 1,
            title: 'Season 1',
            episodes: <VideoMetadataEpisode>[
              VideoMetadataEpisode(
                seasonNumber: 1,
                episodeNumber: 1,
                title: 'Episode 1',
              ),
              VideoMetadataEpisode(
                seasonNumber: 1,
                episodeNumber: 2,
                title: 'Episode 2',
              ),
            ],
          ),
        ],
      ),
    );

    expect(await database.getVideoMetadataWorkByBook('series-e1'), isNull);
    expect(
      await database.getVideoMetadataWorkByCollection(collectionId),
      isNotNull,
    );
    expect(await database.getAllVideoMetadataWorks(), hasLength(1));
  });

  test('非权威季集响应只补写且不删除旧完整季集', () async {
    final (SourceLibraryRow source, VideoBookRow episode1) =
        await _addSourceEpisode(
      database,
      sourceLabel: 'Series source',
      sourceRoot: 'D:/Series',
      bookUid: 'series-e1',
      videoPath: 'D:/Series/Show/Show S01E01.mkv',
    );
    final (_, VideoBookRow episode2) = await _addSourceEpisode(
      database,
      sourceLabel: 'Series source 2',
      sourceRoot: 'D:/Series2',
      bookUid: 'series-e2',
      videoPath: 'D:/Series2/Show/Show S01E02.mkv',
    );
    final int collectionId = await database.createMediaCollection(
      'Show',
      collectionType: 'playlist',
    );
    await database.addToCollection(
        collectionId, MediaKind.video, episode1.bookUid);
    await database.addToCollection(
        collectionId, MediaKind.video, episode2.bookUid);
    final MediaCollectionRow collection =
        (await database.getMediaCollectionById(collectionId))!;
    final VideoSourceScrapeWork work = VideoSourceScrapeWork(
      source: source,
      collection: collection,
      title: collection.name,
      members: <VideoBookRow>[episode1, episode2],
    );
    await store.apply(
      work,
      _tvMetadata(
        seasons: <VideoMetadataSeason>[
          VideoMetadataSeason(
            seasonNumber: 1,
            title: 'Season 1',
            plot: '完整季简介',
            episodes: <VideoMetadataEpisode>[
              VideoMetadataEpisode(
                seasonNumber: 1,
                episodeNumber: 1,
                title: 'Episode 1',
                plot: '完整第一集简介',
                ids: const <VideoMetadataId>[
                  VideoMetadataId(type: 'tmdb', value: '101'),
                ],
              ),
              VideoMetadataEpisode(
                seasonNumber: 1,
                episodeNumber: 2,
                title: 'Episode 2',
              ),
            ],
          ),
          VideoMetadataSeason(
            seasonNumber: 2,
            title: 'Season 2',
            episodes: <VideoMetadataEpisode>[
              VideoMetadataEpisode(
                seasonNumber: 2,
                episodeNumber: 1,
                title: 'Season 2 Episode 1',
              ),
            ],
          ),
        ],
      ),
    );

    await store.apply(
      work,
      VideoMetadataWork(
        provider: VideoMetadataProviderKind.bangumi,
        kind: VideoMetadataMediaKind.tv,
        title: '主源标题',
        ids: const <VideoMetadataId>[
          VideoMetadataId(type: 'bangumi', value: '200'),
        ],
        seasons: <VideoMetadataSeason>[
          VideoMetadataSeason(
            seasonNumber: 1,
            title: '主源第一季',
            episodes: <VideoMetadataEpisode>[
              VideoMetadataEpisode(
                seasonNumber: 1,
                episodeNumber: 1,
                title: '主源第一集',
              ),
            ],
          ),
        ],
      ),
      seasonEpisodesAuthoritative: false,
    );

    final VideoMetadataWorkRow stored =
        (await database.getVideoMetadataWorkByCollection(collectionId))!;
    final List<VideoMetadataSeasonRow> seasons =
        await database.getVideoMetadataSeasons(stored.id);
    expect(seasons.map((VideoMetadataSeasonRow row) => row.seasonNumber),
        <int>[1, 2]);
    expect(seasons.first.overview, '完整季简介');
    final List<VideoMetadataEpisodeRow> season1 =
        await database.getVideoMetadataEpisodes(seasons.first.id);
    expect(
      season1.map((VideoMetadataEpisodeRow row) => row.episodeNumber),
      <int>[1, 2],
    );
    expect(season1.first.overview, '完整第一集简介');
    expect(
      await database.getVideoMetadataProviderIdentities(
        episodeId: season1.first.id,
      ),
      hasLength(1),
    );
  });

  test('作品季集人物角色和职员扩展字段完整落库', () async {
    final PersistedVideoMetadata persisted = await store.apply(
      localWork,
      VideoMetadataWork(
        provider: VideoMetadataProviderKind.tmdb,
        kind: VideoMetadataMediaKind.tv,
        title: 'Extended Show',
        tagline: 'Tagline',
        endDate: '2026-12-31',
        status: 'Ended',
        originalLanguage: 'ja',
        homepage: 'https://example.test/show',
        episodeGroupId: 'group-1',
        seasons: <VideoMetadataSeason>[
          VideoMetadataSeason(
            seasonNumber: 1,
            title: 'Season 1',
            rating: 8.4,
            episodes: <VideoMetadataEpisode>[
              VideoMetadataEpisode(
                seasonNumber: 1,
                episodeNumber: 1,
                absoluteNumber: 13,
                title: 'Episode 1',
                rating: 9.1,
                ratingVotes: 321,
                credits: <VideoMetadataCredit>[
                  VideoMetadataCredit(
                    kind: VideoMetadataCreditKind.voiceActor,
                    person: VideoMetadataPerson(
                      name: 'Actor',
                      originalName: '俳優',
                      biography: 'Biography',
                      birthday: '1990-01-01',
                      deathday: '2050-01-01',
                      gender: 2,
                      placeOfBirth: 'Tokyo',
                      ids: const <VideoMetadataId>[
                        VideoMetadataId(type: 'tmdb', value: 'person-1'),
                      ],
                    ),
                    character: VideoMetadataCharacter(
                      name: 'Hero',
                      description: 'Character description',
                      ids: const <VideoMetadataId>[
                        VideoMetadataId(type: 'tmdb', value: 'character-1'),
                      ],
                    ),
                    roleName: 'Lead Hero',
                    department: 'Acting',
                    job: 'Voice',
                    providerCreditId: 'credit-1',
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );

    final VideoMetadataWorkRow work =
        (await database.getVideoMetadataWorkById(persisted.workId))!;
    expect(work.tagline, 'Tagline');
    expect(work.endDate, '2026-12-31');
    expect(work.status, 'Ended');
    expect(work.originalLanguage, 'ja');
    expect(work.homepage, 'https://example.test/show');
    expect(work.episodeGroupId, 'group-1');
    final VideoMetadataSeasonRow season =
        (await database.getVideoMetadataSeasons(work.id)).single;
    expect(season.rating, 8.4);
    final VideoMetadataEpisodeRow episode =
        (await database.getVideoMetadataEpisodes(season.id)).single;
    expect(episode.absoluteNumber, 13);
    expect(episode.ratingCount, 321);
    final VideoMetadataCreditRow credit =
        (await database.getVideoMetadataCredits(episodeId: episode.id)).single;
    expect(credit.roleName, 'Lead Hero');
    expect(credit.department, 'Acting');
    expect(credit.job, 'Voice');
    expect(credit.providerCreditId, 'credit-1');
    final VideoMetadataPersonRow person =
        (await database.getVideoMetadataPerson(credit.personKey))!;
    expect(person.biography, 'Biography');
    expect(person.birthday, '1990-01-01');
    expect(person.deathday, '2050-01-01');
    expect(person.gender, 2);
    expect(person.placeOfBirth, 'Tokyo');
    final VideoMetadataCharacterRow character =
        (await database.getVideoMetadataCharacter(credit.characterKey!))!;
    expect(character.description, 'Character description');
  });

  test('TMDB 的 IMDb default 仅影响 NFO 默认 ID，不污染数据库主绑定', () async {
    final VideoMetadataWork metadata = _tmdbMetadata(
      episodeGroupId: 'group-42',
      ids: const <VideoMetadataId>[
        VideoMetadataId(
          type: 'imdb',
          value: 'tt1234567',
          isDefault: true,
        ),
        VideoMetadataId(type: 'tmdb', value: '42'),
      ],
    );

    final PersistedVideoMetadata persisted =
        await store.apply(localWork, metadata);
    final List<VideoMetadataProviderIdentityRow> identities = await database
        .getVideoMetadataProviderIdentities(workId: persisted.workId);

    expect(
      identities
          .where((VideoMetadataProviderIdentityRow row) => row.isPrimary)
          .map((VideoMetadataProviderIdentityRow row) => row.provider),
      <String>['tmdb'],
    );
    final VideoMetadataLookup lookup =
        (await store.confirmedLookup(localWork))!;
    expect(lookup.provider, VideoMetadataProviderKind.tmdb);
    expect(lookup.externalId, '42');
    expect(lookup.mediaKind, VideoMetadataMediaKind.movie);
    expect(lookup.episodeGroupId, 'group-42');
    final VideoScrapeMetaRow legacy =
        (await database.getVideoScrapeMeta('movie-1'))!;
    expect(legacy.subjectId, '42');
    expect(legacy.detailUrl, 'https://www.themoviedb.org/movie/42');
  });
}

Future<(SourceLibraryRow, VideoBookRow)> _addSourceEpisode(
  FushiDatabase database, {
  required String sourceLabel,
  required String sourceRoot,
  required String bookUid,
  required String videoPath,
}) async {
  final int sourceId = await database.insertMediaSource(
    MediaSourcesCompanion.insert(
      label: sourceLabel,
      mediaKind: 'video',
      rootPath: sourceRoot,
      createdAt: 1,
    ),
  );
  await database.upsertVideoBook(
    VideoBooksCompanion(
      bookUid: Value<String>(bookUid),
      title: Value<String>(bookUid),
      videoPath: Value<String>(videoPath),
      sourceId: Value<int?>(sourceId),
    ),
  );
  return (
    (await database.getMediaSourceById(sourceId))!,
    (await database.getVideoBookByBookUid(bookUid))!,
  );
}

Future<void> _expectEpisodeBindings(
  FushiDatabase database,
  int collectionId,
  Map<int, String?> expected,
) async {
  final VideoMetadataWorkRow work =
      (await database.getVideoMetadataWorkByCollection(collectionId))!;
  final VideoMetadataSeasonRow season =
      (await database.getVideoMetadataSeasons(work.id)).single;
  final List<VideoMetadataEpisodeRow> episodes =
      await database.getVideoMetadataEpisodes(season.id);
  expect(
    <int, String?>{
      for (final VideoMetadataEpisodeRow row in episodes)
        row.episodeNumber: row.bookUid,
    },
    expected,
  );
}

Future<void> _expectSeasonEpisodeBindings(
  FushiDatabase database,
  int collectionId,
  Map<(int, int), String?> expected,
) async {
  final VideoMetadataWorkRow work =
      (await database.getVideoMetadataWorkByCollection(collectionId))!;
  final Map<(int, int), String?> actual = <(int, int), String?>{};
  for (final VideoMetadataSeasonRow season
      in await database.getVideoMetadataSeasons(work.id)) {
    for (final VideoMetadataEpisodeRow episode
        in await database.getVideoMetadataEpisodes(season.id)) {
      actual[(season.seasonNumber, episode.episodeNumber)] = episode.bookUid;
    }
  }
  expect(actual, expected);
}

VideoMetadataWork _tvMetadata({
  required List<VideoMetadataSeason> seasons,
}) =>
    VideoMetadataWork(
      provider: VideoMetadataProviderKind.tmdb,
      kind: VideoMetadataMediaKind.tv,
      title: 'Show',
      ids: const <VideoMetadataId>[
        VideoMetadataId(type: 'tmdb', value: '100'),
      ],
      seasons: seasons,
    );

VideoMetadataWork _tmdbMetadata({
  List<VideoMetadataId> ids = const <VideoMetadataId>[
    VideoMetadataId(type: 'tmdb', value: '42'),
  ],
  List<VideoMetadataImage> images = const <VideoMetadataImage>[],
  String? episodeGroupId,
}) =>
    VideoMetadataWork(
      provider: VideoMetadataProviderKind.tmdb,
      kind: VideoMetadataMediaKind.movie,
      title: 'Example Movie',
      year: 2025,
      episodeGroupId: episodeGroupId,
      ids: ids,
      images: images,
    );
