import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/source_library/source_library_row.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_database_store.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_provider.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_wire.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_work_loader.dart';
import 'package:fushi_engine/media/video/metadata/video_source_work_planner.dart';

/// 互联刮削元数据 wire（spec 2026-09-12 §1.2）三段往返：
/// (a) encode/decode 纯编解码互逆；(b) apply → load 反向装载；(c) lookupOfWork。
void main() {
  group('encode / decode', () {
    test('字段填满的作品 decode(encode(w)) 逐字段相等，rawPayload 不上 wire', () {
      final VideoMetadataWork work =
          _fullWork(rawPayload: const <String, Object?>{'raw': 1});
      final Map<String, Object?> json = encodeVideoMetadataWork(work);
      expect(json.containsKey('rawPayload'), isFalse);
      expect(json['provider'], 'tmdb');
      expect(json['kind'], 'tv');

      final VideoMetadataWork decoded = decodeVideoMetadataWork(json);
      expect(decoded.rawPayload, isNull);
      // 标量逐字段。
      expect(decoded.provider, work.provider);
      expect(decoded.kind, work.kind);
      expect(decoded.title, work.title);
      expect(decoded.originalTitle, work.originalTitle);
      expect(decoded.tagline, work.tagline);
      expect(decoded.year, work.year);
      expect(decoded.premiered, work.premiered);
      expect(decoded.endDate, work.endDate);
      expect(decoded.plot, work.plot);
      expect(decoded.rating, work.rating);
      expect(decoded.ratingVotes, work.ratingVotes);
      expect(decoded.runtimeMinutes, work.runtimeMinutes);
      expect(decoded.contentRating, work.contentRating);
      expect(decoded.status, work.status);
      expect(decoded.originalLanguage, work.originalLanguage);
      expect(decoded.homepage, work.homepage);
      expect(decoded.episodeGroupId, work.episodeGroupId);
      expect(decoded.seasonCount, work.seasonCount);
      expect(decoded.episodeCount, work.episodeCount);
      // 列表逐个（模型自带值相等）。
      expect(decoded.aliases, work.aliases);
      expect(decoded.genres, work.genres);
      expect(decoded.studios, work.studios);
      expect(decoded.countries, work.countries);
      expect(decoded.keywords, work.keywords);
      expect(decoded.ids, work.ids);
      expect(decoded.credits, work.credits);
      expect(decoded.images, work.images);
      expect(decoded.extras, work.extras);
      expect(decoded.seasons.length, 2);
      expect(decoded.seasons, work.seasons);
      expect(decoded.seasons[0].episodes.length, 2);
      expect(decoded.seasons[1].episodes.length, 1);
      // 整体相等（copyWith 无法把 rawPayload 置回 null，重造一份不带的原件）。
      expect(decoded, _fullWork());
      expect(decoded, isNot(equals(work)), reason: '原件带 rawPayload');
    });

    test('缺 provider 抛 FormatException；类型错的可选字段容错为 null', () {
      expect(
        () => decodeVideoMetadataWork(<String, Object?>{
          'kind': 'movie',
          'title': 'x',
        }),
        throwsFormatException,
      );
      expect(
        () => decodeVideoMetadataWork(<String, Object?>{
          'provider': 'not-a-provider',
          'kind': 'movie',
        }),
        throwsFormatException,
      );
      final VideoMetadataWork lenient =
          decodeVideoMetadataWork(<String, Object?>{
        'provider': 'mal',
        'kind': 'movie',
        'title': 'x',
        'year': 'abc',
        'rating': <int>[1],
        'genres': <Object?>['a', null, 2, ' b '],
        'ids': <Object?>[
          <String, Object?>{'type': 'mal', 'value': '1'},
          <String, Object?>{'type': 'imdb'},
          'junk',
        ],
        'images': <Object?>[
          <String, Object?>{'kind': 'nope', 'url': 'u', 'provider': 'mal'},
        ],
        'seasons': 'not-a-list',
      });
      expect(lenient.year, isNull);
      expect(lenient.rating, isNull);
      expect(lenient.genres, <String>['a', 'b']);
      expect(lenient.ids, const <VideoMetadataId>[
        VideoMetadataId(type: 'mal', value: '1'),
      ]);
      expect(lenient.images, isEmpty);
      expect(lenient.seasons, isEmpty);
    });

    test('lookup 编解码互逆；缺必需字段返回 null', () {
      const VideoMetadataLookup lookup = VideoMetadataLookup(
        provider: VideoMetadataProviderKind.tmdb,
        externalId: '1234',
        mediaKind: VideoMetadataMediaKind.tv,
        episodeGroupId: 'grp',
      );
      final VideoMetadataLookup? decoded =
          decodeVideoMetadataLookup(encodeVideoMetadataLookup(lookup));
      expect(decoded, isNotNull);
      expect(decoded!.provider, lookup.provider);
      expect(decoded.externalId, lookup.externalId);
      expect(decoded.mediaKind, lookup.mediaKind);
      expect(decoded.episodeGroupId, lookup.episodeGroupId);
      expect(decodeVideoMetadataLookup(null), isNull);
      expect(decodeVideoMetadataLookup('x'), isNull);
      expect(
        decodeVideoMetadataLookup(<String, Object?>{
          'provider': 'tmdb',
          'mediaKind': 'tv',
        }),
        isNull,
      );
    });
  });

  group('apply → load', () {
    late FushiDatabase db;
    late VideoMetadataDatabaseStore store;
    late VideoSourceScrapeWork localWork;

    setUp(() async {
      db = FushiDatabase.forTesting(NativeDatabase.memory());
      store = VideoMetadataDatabaseStore(db);
      final int sourceId = await db.insertMediaSource(
        MediaSourcesCompanion.insert(
          label: 'Shows',
          mediaKind: 'video',
          rootPath: 'D:/Shows',
          createdAt: 1,
        ),
      );
      final List<VideoBookRow> members = <VideoBookRow>[];
      for (final String stem in <String>[
        'Show S01E01',
        'Show S01E02',
        'Show S02E01',
      ]) {
        await db.upsertVideoBook(
          VideoBooksCompanion(
            bookUid: Value<String>(stem),
            title: Value<String>(stem),
            videoPath: Value<String>('D:/Shows/Show/$stem.mkv'),
            sourceId: Value<int?>(sourceId),
          ),
        );
        members.add((await db.getVideoBookByBookUid(stem))!);
      }
      final int collectionId =
          await db.createMediaCollection('Show', collectionType: 'playlist');
      for (final VideoBookRow member in members) {
        await db.addToCollection(collectionId, MediaKind.video, member.bookUid);
      }
      final SourceLibraryRow source = (await db.getMediaSourceById(sourceId))!;
      final MediaCollectionRow collection =
          (await db.getMediaCollectionById(collectionId))!;
      localWork = VideoSourceScrapeWork(
        source: source,
        collection: collection,
        title: collection.name,
        members: members,
      );
    });

    tearDown(() => db.close());

    test('可持久化字段读回与原件一致', () async {
      final VideoMetadataWork work = _fullWork();
      final PersistedVideoMetadata persisted =
          await store.apply(localWork, work);
      final VideoMetadataWorkRow row =
          (await db.getVideoMetadataWorkById(persisted.workId))!;
      final VideoMetadataWork loaded = await loadVideoMetadataWork(db, row);

      expect(loaded.provider, work.provider, reason: '主身份 provider');
      expect(loaded.kind, work.kind);
      expect(loaded.title, work.title);
      expect(loaded.originalTitle, work.originalTitle);
      expect(loaded.tagline, work.tagline);
      expect(loaded.plot, work.plot);
      expect(loaded.year, work.year);
      expect(loaded.premiered, work.premiered);
      expect(loaded.endDate, work.endDate);
      expect(loaded.rating, work.rating);
      expect(loaded.ratingVotes, work.ratingVotes);
      expect(loaded.runtimeMinutes, work.runtimeMinutes);
      expect(loaded.contentRating, work.contentRating);
      expect(loaded.status, work.status);
      expect(loaded.originalLanguage, work.originalLanguage);
      expect(loaded.homepage, work.homepage);
      expect(loaded.episodeGroupId, work.episodeGroupId);
      expect(loaded.genres, work.genres);
      expect(loaded.studios, work.studios);
      expect(loaded.countries, work.countries);
      expect(loaded.keywords, work.keywords);
      // 不比 aliases / seasonCount / episodeCount：works 表没这三列。
      expect(loaded.aliases, isEmpty);
      expect(loaded.seasonCount, isNull);
      expect(loaded.episodeCount, isNull);
      expect(loaded.rawPayload, isNull);

      // ids：apply 把 type 小写、按「type == provider」重算 isDefault；原件里
      // 故意把 IMDB 写成大写且标 isDefault，读回必须是归一化后的形态。
      expect(loaded.ids, const <VideoMetadataId>[
        VideoMetadataId(type: 'tmdb', value: '31911', isDefault: true),
        VideoMetadataId(type: 'imdb', value: 'tt1234567'),
      ]);

      // seasons / episodes：编号与标题、标量。
      expect(loaded.seasons.length, 2);
      for (int i = 0; i < 2; i++) {
        final VideoMetadataSeason expected = work.seasons[i];
        final VideoMetadataSeason actual = loaded.seasons[i];
        expect(actual.seasonNumber, expected.seasonNumber);
        expect(actual.title, expected.title);
        expect(actual.plot, expected.plot);
        expect(actual.airDate, expected.airDate);
        expect(actual.year, expected.year);
        expect(actual.episodeCount, expected.episodeCount);
        expect(actual.rating, expected.rating);
        expect(actual.ids, expected.ids, reason: '季 id 原件已是小写');
        expect(actual.episodes.length, expected.episodes.length);
        for (int j = 0; j < expected.episodes.length; j++) {
          final VideoMetadataEpisode e = expected.episodes[j];
          final VideoMetadataEpisode a = actual.episodes[j];
          expect(a.seasonNumber, e.seasonNumber);
          expect(a.episodeNumber, e.episodeNumber);
          expect(a.title, e.title);
          expect(a.plot, e.plot);
          expect(a.airDate, e.airDate);
          expect(a.absoluteNumber, e.absoluteNumber);
          expect(a.rating, e.rating);
          expect(a.ratingVotes, e.ratingVotes);
          expect(a.runtimeMinutes, e.runtimeMinutes);
          expect(a.ids, e.ids);
        }
      }
      // 季图 / 集图。
      expect(
        loaded.seasons[0].images.map((VideoMetadataImage i) => i.url),
        <String>['https://img.example/s1-poster.jpg'],
      );
      expect(
        loaded.seasons[0].episodes[0].images
            .map((VideoMetadataImage i) => i.url),
        <String>['https://img.example/s1e1-thumb.jpg'],
      );

      // images：remoteUrl + kind + language。DB 按 (kind, position) 排，跨图种
      // 顺序不保证，所以按 kind 取再比。likes 没列，不比。
      VideoMetadataImage imageOf(VideoMetadataImageKind kind) =>
          loaded.images.singleWhere((VideoMetadataImage i) => i.kind == kind);
      final VideoMetadataImage cover = imageOf(VideoMetadataImageKind.cover);
      expect(cover.url, 'https://img.example/poster-ja.jpg');
      expect(cover.language, 'ja');
      expect(cover.provider, VideoMetadataProviderKind.tmdb);
      expect(cover.voteAverage, 5.5);
      expect(cover.voteCount, 12);
      final VideoMetadataImage backdrop =
          imageOf(VideoMetadataImageKind.backdrop);
      expect(backdrop.url, 'https://img.example/backdrop.jpg');
      expect(backdrop.language, isNull);
      expect(backdrop.provider, VideoMetadataProviderKind.fanart);

      // credits：roleName 原件为 null，apply 用角色名回填；person/character 的
      // id 没列，读回 null；character.originalName 没列，读回 null。
      expect(loaded.credits.length, 1);
      final VideoMetadataCredit credit = loaded.credits.single;
      final VideoMetadataCredit original = work.credits.single;
      expect(credit.kind, original.kind);
      expect(credit.roleName, original.character!.name);
      expect(credit.language, original.language);
      expect(credit.department, original.department);
      expect(credit.job, original.job);
      expect(credit.providerCreditId, original.providerCreditId);
      expect(credit.order, original.order);
      // person：除 id 外全列持久化；ids 的 type 小写、isPrimary ← isDefault。
      expect(credit.person.id, isNull);
      expect(credit.person.name, original.person.name);
      expect(credit.person.originalName, original.person.originalName);
      expect(credit.person.biography, original.person.biography);
      expect(credit.person.birthday, original.person.birthday);
      expect(credit.person.deathday, original.person.deathday);
      expect(credit.person.gender, original.person.gender);
      expect(credit.person.placeOfBirth, original.person.placeOfBirth);
      expect(credit.person.profileUrl, original.person.profileUrl);
      expect(credit.person.ids, const <VideoMetadataId>[
        VideoMetadataId(type: 'tmdb', value: '99', isDefault: true),
      ]);
      expect(credit.character, isNotNull);
      expect(credit.character!.name, original.character!.name);
      expect(credit.character!.description, original.character!.description);
      expect(credit.character!.imageUrl, original.character!.imageUrl);
      expect(credit.character!.originalName, isNull);
      expect(credit.character!.ids, original.character!.ids);

      // extras：原件两条，其中一条没 remoteUrl，apply 只落在线附件。
      expect(loaded.extras.length, 1);
      final VideoMetadataExtra extra = loaded.extras.single;
      expect(extra.kind, VideoMetadataExtraKind.behindTheScenes,
          reason: 'snake_case 列值映回枚举');
      expect(extra.title, 'Making of');
      expect(extra.provider, VideoMetadataProviderKind.tmdb);
      expect(extra.providerVideoId, 'yt-1');
      expect(extra.site, 'YouTube');
      expect(extra.remoteUrl, 'https://youtu.be/yt-1');
      expect(extra.thumbnailUrl, 'https://img.example/yt-1.jpg');
      expect(extra.durationMs, 90000);
      expect(extra.official, isTrue);
      expect(extra.language, 'en');
      expect(extra.publishedAt, '2024-01-02');
      expect(extra.order, 3);
    });

    test('apply → load → encode → decode → apply → load 稳定（幂等）', () async {
      final PersistedVideoMetadata first =
          await store.apply(localWork, _fullWork());
      final VideoMetadataWork loaded1 = await loadVideoMetadataWork(
        db,
        (await db.getVideoMetadataWorkById(first.workId))!,
      );
      final VideoMetadataWork wired =
          decodeVideoMetadataWork(encodeVideoMetadataWork(loaded1));
      expect(wired, loaded1, reason: 'load 结果本身应能无损上 wire');
      final PersistedVideoMetadata second = await store.apply(localWork, wired);
      final VideoMetadataWork loaded2 = await loadVideoMetadataWork(
        db,
        (await db.getVideoMetadataWorkById(second.workId))!,
      );
      expect(loaded2, loaded1);
    });

    test('lookupOfWork 返回主身份；没主身份 / 不存在返回 null', () async {
      final PersistedVideoMetadata persisted =
          await store.apply(localWork, _fullWork());
      final VideoMetadataLookup? lookup =
          await lookupOfWork(db, persisted.workId);
      expect(lookup, isNotNull);
      expect(lookup!.provider, VideoMetadataProviderKind.tmdb);
      expect(lookup.externalId, '31911');
      expect(lookup.mediaKind, VideoMetadataMediaKind.tv);
      expect(lookup.episodeGroupId, 'grp-1');
      expect(await lookupOfWork(db, persisted.workId + 1000), isNull);

      // 主身份被删后 lookup 为 null；load 退回第一条身份。
      await db.replaceVideoMetadataProviderIdentities(
        workId: persisted.workId,
        identities: <VideoMetadataProviderIdentitiesCompanion>[
          VideoMetadataProviderIdentitiesCompanion.insert(
            identityKey: 'work:${persisted.workId}:imdb',
            provider: 'imdb',
            externalId: 'tt1234567',
            updatedAt: 1,
          ),
        ],
      );
      expect(await lookupOfWork(db, persisted.workId), isNull);
      final VideoMetadataWorkRow row =
          (await db.getVideoMetadataWorkById(persisted.workId))!;
      expect(
        () => loadVideoMetadataWork(db, row),
        throwsStateError,
        reason: 'imdb 不是 VideoMetadataProviderKind，没有可用 provider',
      );
    });

    test('一条身份都没有的作品（local 骨架）load 抛 StateError', () async {
      final PersistedVideoMetadata persisted = await store.apply(
        localWork,
        VideoMetadataWork(
          provider: VideoMetadataProviderKind.local,
          kind: VideoMetadataMediaKind.tv,
          title: 'Show',
        ),
      );
      final VideoMetadataWorkRow row =
          (await db.getVideoMetadataWorkById(persisted.workId))!;
      expect(() => loadVideoMetadataWork(db, row), throwsStateError);
      expect(await lookupOfWork(db, persisted.workId), isNull);
    });
  });
}

/// 字段尽量填满：2 季 3 集、2 个 id、2 张图（一张带 language）、1 个 credit
/// 带 person + character、2 个 extra（一个无 remoteUrl 供 DB 往返验证过滤）。
VideoMetadataWork _fullWork({Map<String, Object?>? rawPayload}) =>
    VideoMetadataWork(
      provider: VideoMetadataProviderKind.tmdb,
      kind: VideoMetadataMediaKind.tv,
      title: 'Show',
      originalTitle: 'ショー',
      tagline: 'A tagline',
      aliases: const <String>['Alias A', 'Alias B'],
      year: 2024,
      premiered: '2024-01-01',
      endDate: '2024-06-30',
      plot: 'Plot text',
      rating: 8.25,
      ratingVotes: 1234,
      runtimeMinutes: 24,
      contentRating: 'TV-14',
      status: 'Ended',
      originalLanguage: 'ja',
      homepage: 'https://example.com/show',
      episodeGroupId: 'grp-1',
      seasonCount: 2,
      episodeCount: 3,
      genres: const <String>['Action', 'Drama'],
      studios: const <String>['Studio X'],
      countries: const <String>['JP'],
      keywords: const <String>['kw1', 'kw2'],
      ids: const <VideoMetadataId>[
        VideoMetadataId(type: 'tmdb', value: '31911'),
        VideoMetadataId(type: 'IMDB', value: 'tt1234567', isDefault: true),
      ],
      credits: <VideoMetadataCredit>[
        VideoMetadataCredit(
          kind: VideoMetadataCreditKind.voiceActor,
          person: VideoMetadataPerson(
            id: 'p-99',
            name: 'Voice Person',
            originalName: '声の人',
            biography: 'bio',
            birthday: '1990-01-01',
            deathday: null,
            gender: 2,
            placeOfBirth: 'Tokyo',
            profileUrl: 'https://img.example/p99.jpg',
            ids: const <VideoMetadataId>[
              VideoMetadataId(type: 'TMDB', value: '99', isDefault: true),
            ],
          ),
          character: VideoMetadataCharacter(
            id: 'c-7',
            name: 'Hero',
            originalName: '主人公',
            description: 'the hero',
            imageUrl: 'https://img.example/c7.jpg',
            ids: const <VideoMetadataId>[
              VideoMetadataId(type: 'mal', value: '7'),
            ],
          ),
          language: 'ja',
          department: 'Voice',
          job: 'Voice Actor',
          providerCreditId: 'cr-1',
          order: 2,
        ),
      ],
      images: const <VideoMetadataImage>[
        VideoMetadataImage(
          kind: VideoMetadataImageKind.cover,
          url: 'https://img.example/poster-ja.jpg',
          provider: VideoMetadataProviderKind.tmdb,
          language: 'ja',
          likes: 3,
          voteAverage: 5.5,
          voteCount: 12,
        ),
        VideoMetadataImage(
          kind: VideoMetadataImageKind.backdrop,
          url: 'https://img.example/backdrop.jpg',
          provider: VideoMetadataProviderKind.fanart,
        ),
      ],
      seasons: <VideoMetadataSeason>[
        VideoMetadataSeason(
          seasonNumber: 1,
          title: 'Season 1',
          plot: 'S1 plot',
          airDate: '2024-01-01',
          year: 2024,
          episodeCount: 2,
          rating: 7.5,
          ids: const <VideoMetadataId>[
            VideoMetadataId(type: 'tmdb', value: 's1', isDefault: true),
          ],
          images: const <VideoMetadataImage>[
            VideoMetadataImage(
              kind: VideoMetadataImageKind.cover,
              url: 'https://img.example/s1-poster.jpg',
              provider: VideoMetadataProviderKind.tmdb,
              language: 'en',
            ),
          ],
          episodes: <VideoMetadataEpisode>[
            VideoMetadataEpisode(
              seasonNumber: 1,
              episodeNumber: 1,
              title: 'Pilot',
              plot: 'E1 plot',
              airDate: '2024-01-01',
              year: 2024,
              absoluteNumber: 1,
              rating: 8.0,
              ratingVotes: 10,
              runtimeMinutes: 24,
              ids: const <VideoMetadataId>[
                VideoMetadataId(type: 'tmdb', value: 'e1', isDefault: true),
              ],
              images: const <VideoMetadataImage>[
                VideoMetadataImage(
                  kind: VideoMetadataImageKind.thumb,
                  url: 'https://img.example/s1e1-thumb.jpg',
                  provider: VideoMetadataProviderKind.tmdb,
                ),
              ],
            ),
            VideoMetadataEpisode(
              seasonNumber: 1,
              episodeNumber: 2,
              title: 'Second',
              absoluteNumber: 2,
            ),
          ],
        ),
        VideoMetadataSeason(
          seasonNumber: 2,
          title: 'Season 2',
          episodeCount: 1,
          episodes: <VideoMetadataEpisode>[
            VideoMetadataEpisode(
              seasonNumber: 2,
              episodeNumber: 1,
              title: 'Return',
              absoluteNumber: 3,
            ),
          ],
        ),
      ],
      extras: const <VideoMetadataExtra>[
        VideoMetadataExtra(
          kind: VideoMetadataExtraKind.behindTheScenes,
          title: 'Making of',
          provider: VideoMetadataProviderKind.tmdb,
          providerVideoId: 'yt-1',
          site: 'YouTube',
          remoteUrl: 'https://youtu.be/yt-1',
          thumbnailUrl: 'https://img.example/yt-1.jpg',
          durationMs: 90000,
          official: true,
          language: 'en',
          publishedAt: '2024-01-02',
          order: 3,
        ),
        VideoMetadataExtra(
          kind: VideoMetadataExtraKind.trailer,
          title: 'No url trailer',
        ),
      ],
      rawPayload: rawPayload,
    );
