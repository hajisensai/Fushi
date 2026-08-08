import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/metadata/video_metadata_merge.dart';
import 'package:hibiki/src/media/video/metadata/video_metadata_models.dart';

void main() {
  test('非 TMDB 主源保留展示字段并接入 TMDB 身份和季集骨架', () {
    final VideoMetadataWork primary = VideoMetadataWork(
      provider: VideoMetadataProviderKind.anilist,
      kind: VideoMetadataMediaKind.tv,
      title: '主源标题',
      plot: '主源简介',
      ids: const <VideoMetadataId>[
        VideoMetadataId(type: 'anilist', value: '1'),
      ],
    );
    final VideoMetadataWork tmdb = VideoMetadataWork(
      provider: VideoMetadataProviderKind.tmdb,
      kind: VideoMetadataMediaKind.tv,
      title: 'TMDB title',
      plot: 'TMDB plot',
      ids: const <VideoMetadataId>[
        VideoMetadataId(type: 'tmdb', value: '2'),
        VideoMetadataId(type: 'tvdb', value: '3'),
      ],
      seasons: <VideoMetadataSeason>[
        VideoMetadataSeason(seasonNumber: 1, title: 'Season 1'),
      ],
    );

    final VideoMetadataWork merged =
        supplementVideoMetadataWithTmdb(primary, tmdb);
    expect(merged.provider, VideoMetadataProviderKind.anilist);
    expect(merged.title, '主源标题');
    expect(merged.plot, '主源简介');
    expect(merged.ids.map((VideoMetadataId id) => id.type),
        <String>['anilist', 'tmdb', 'tvdb']);
    expect(merged.seasons, hasLength(1));
  });

  test('Fanart 先占图种并按语言和 likes 选择', () {
    final List<VideoMetadataImage> selected = selectVideoMetadataImages(
      primary: const <VideoMetadataImage>[
        VideoMetadataImage(
          kind: VideoMetadataImageKind.cover,
          url: 'tmdb',
          provider: VideoMetadataProviderKind.tmdb,
          voteAverage: 10,
        ),
        VideoMetadataImage(
          kind: VideoMetadataImageKind.logo,
          url: 'logo',
          provider: VideoMetadataProviderKind.tmdb,
        ),
      ],
      fanart: const <VideoMetadataImage>[
        VideoMetadataImage(
          kind: VideoMetadataImageKind.cover,
          url: 'fanart-en',
          provider: VideoMetadataProviderKind.fanart,
          language: 'en',
          likes: 50,
        ),
        VideoMetadataImage(
          kind: VideoMetadataImageKind.cover,
          url: 'fanart-zh',
          provider: VideoMetadataProviderKind.fanart,
          language: 'zh',
          likes: 1,
        ),
      ],
    );
    expect(
      selected
          .singleWhere(
              (VideoMetadataImage i) => i.kind == VideoMetadataImageKind.cover)
          .url,
      'fanart-zh',
    );
    expect(selected.any((VideoMetadataImage i) => i.url == 'logo'), isTrue);
  });

  test('TMDB 图片先按评分票数排序且语言只作同分兜底', () {
    final List<VideoMetadataImage> selected = selectVideoMetadataImages(
      primary: const <VideoMetadataImage>[
        VideoMetadataImage(
          kind: VideoMetadataImageKind.cover,
          url: 'low-zh',
          provider: VideoMetadataProviderKind.tmdb,
          language: 'zh',
          voteAverage: 5,
          voteCount: 100,
        ),
        VideoMetadataImage(
          kind: VideoMetadataImageKind.cover,
          url: 'high-neutral',
          provider: VideoMetadataProviderKind.tmdb,
          voteAverage: 9,
          voteCount: 10,
        ),
      ],
    );

    expect(selected.single.url, 'high-neutral');
  });

  test('续季单主源先重映射到本地季号再与 TMDB 全剧骨架合并', () {
    final VideoMetadataWork primary = VideoMetadataWork(
      provider: VideoMetadataProviderKind.bangumi,
      kind: VideoMetadataMediaKind.tv,
      title: '作品 第二季',
      seasons: <VideoMetadataSeason>[
        VideoMetadataSeason(
          seasonNumber: 1,
          title: '主源当前季',
          episodes: <VideoMetadataEpisode>[
            VideoMetadataEpisode(
              seasonNumber: 1,
              episodeNumber: 1,
              title: '主源续季第一集',
            ),
          ],
        ),
      ],
    );
    final VideoMetadataWork tmdb = VideoMetadataWork(
      provider: VideoMetadataProviderKind.tmdb,
      kind: VideoMetadataMediaKind.tv,
      title: 'Show',
      seasons: <VideoMetadataSeason>[
        VideoMetadataSeason(
          seasonNumber: 1,
          title: 'TMDB Season 1',
          episodes: <VideoMetadataEpisode>[
            VideoMetadataEpisode(
              seasonNumber: 1,
              episodeNumber: 1,
              title: 'TMDB S01E01',
            ),
          ],
        ),
        VideoMetadataSeason(
          seasonNumber: 2,
          title: 'TMDB Season 2',
          episodes: <VideoMetadataEpisode>[
            VideoMetadataEpisode(
              seasonNumber: 2,
              episodeNumber: 1,
              title: 'TMDB S02E01',
            ),
          ],
        ),
      ],
    );

    final VideoMetadataWork merged = supplementVideoMetadataWithTmdb(
      remapStandaloneVideoMetadataSeason(primary, 2),
      tmdb,
    );

    expect(merged.seasons, hasLength(2));
    expect(merged.seasons.first.episodes.single.title, 'TMDB S01E01');
    expect(merged.seasons.last.seasonNumber, 2);
    expect(merged.seasons.last.episodes.single.title, '主源续季第一集');
  });

  test('TMDB 按季集号深合并且主源标题、简介、声优和图片优先', () {
    final VideoMetadataCredit primaryVoice = VideoMetadataCredit(
      kind: VideoMetadataCreditKind.voiceActor,
      person: VideoMetadataPerson(
        name: '声优',
        profileUrl: 'primary-profile',
        ids: const <VideoMetadataId>[
          VideoMetadataId(type: 'bangumi', value: 'person-1'),
        ],
      ),
      character: VideoMetadataCharacter(
        name: '角色',
        imageUrl: 'primary-character',
        ids: const <VideoMetadataId>[
          VideoMetadataId(type: 'bangumi', value: 'character-1'),
        ],
      ),
      language: 'ja',
    );
    final VideoMetadataWork primary = VideoMetadataWork(
      provider: VideoMetadataProviderKind.bangumi,
      kind: VideoMetadataMediaKind.tv,
      title: '主源作品名',
      plot: '主源作品简介',
      ids: const <VideoMetadataId>[
        VideoMetadataId(type: 'bangumi', value: 'work-1'),
      ],
      credits: <VideoMetadataCredit>[primaryVoice],
      images: const <VideoMetadataImage>[
        VideoMetadataImage(
          kind: VideoMetadataImageKind.cover,
          url: 'primary-cover',
          provider: VideoMetadataProviderKind.bangumi,
        ),
      ],
      seasons: <VideoMetadataSeason>[
        VideoMetadataSeason(
          seasonNumber: 1,
          title: '主源第一季',
          plot: '主源季简介',
          ids: const <VideoMetadataId>[
            VideoMetadataId(type: 'bangumi', value: 'season-1'),
          ],
          images: const <VideoMetadataImage>[
            VideoMetadataImage(
              kind: VideoMetadataImageKind.cover,
              url: 'primary-season-cover',
              provider: VideoMetadataProviderKind.bangumi,
              seasonNumber: 1,
            ),
          ],
          episodes: <VideoMetadataEpisode>[
            VideoMetadataEpisode(
              seasonNumber: 1,
              episodeNumber: 1,
              title: '主源第一集',
              plot: '主源分集简介',
              ids: const <VideoMetadataId>[
                VideoMetadataId(type: 'bangumi', value: 'episode-1'),
              ],
              credits: <VideoMetadataCredit>[primaryVoice],
              images: const <VideoMetadataImage>[
                VideoMetadataImage(
                  kind: VideoMetadataImageKind.thumb,
                  url: 'primary-still',
                  provider: VideoMetadataProviderKind.bangumi,
                  seasonNumber: 1,
                  episodeNumber: 1,
                ),
              ],
            ),
          ],
        ),
      ],
    );
    final VideoMetadataWork tmdb = VideoMetadataWork(
      provider: VideoMetadataProviderKind.tmdb,
      kind: VideoMetadataMediaKind.tv,
      title: 'TMDB title',
      plot: 'TMDB work plot',
      ids: const <VideoMetadataId>[
        VideoMetadataId(type: 'tmdb', value: '100'),
      ],
      credits: <VideoMetadataCredit>[
        VideoMetadataCredit(
          kind: VideoMetadataCreditKind.voiceActor,
          person: VideoMetadataPerson(
            name: '声优',
            profileUrl: 'tmdb-profile',
            ids: const <VideoMetadataId>[
              VideoMetadataId(type: 'tmdb', value: 'person-100'),
            ],
          ),
          character: VideoMetadataCharacter(
            name: '角色',
            imageUrl: 'tmdb-character',
            ids: const <VideoMetadataId>[
              VideoMetadataId(type: 'tmdb', value: 'character-100'),
            ],
          ),
          language: 'ja',
        ),
      ],
      images: const <VideoMetadataImage>[
        VideoMetadataImage(
          kind: VideoMetadataImageKind.cover,
          url: 'tmdb-cover',
          provider: VideoMetadataProviderKind.tmdb,
        ),
        VideoMetadataImage(
          kind: VideoMetadataImageKind.logo,
          url: 'tmdb-logo',
          provider: VideoMetadataProviderKind.tmdb,
        ),
      ],
      seasons: <VideoMetadataSeason>[
        VideoMetadataSeason(
          seasonNumber: 1,
          title: 'TMDB Season 1',
          plot: 'TMDB season plot',
          ids: const <VideoMetadataId>[
            VideoMetadataId(type: 'tmdb', value: 'season-100'),
          ],
          images: const <VideoMetadataImage>[
            VideoMetadataImage(
              kind: VideoMetadataImageKind.cover,
              url: 'tmdb-season-cover',
              provider: VideoMetadataProviderKind.tmdb,
              seasonNumber: 1,
            ),
            VideoMetadataImage(
              kind: VideoMetadataImageKind.logo,
              url: 'tmdb-season-logo',
              provider: VideoMetadataProviderKind.tmdb,
              seasonNumber: 1,
            ),
          ],
          episodes: <VideoMetadataEpisode>[
            VideoMetadataEpisode(
              seasonNumber: 1,
              episodeNumber: 1,
              title: 'TMDB Episode 1',
              plot: 'TMDB episode plot',
              ids: const <VideoMetadataId>[
                VideoMetadataId(type: 'tmdb', value: 'episode-100'),
              ],
              credits: <VideoMetadataCredit>[
                VideoMetadataCredit(
                  kind: VideoMetadataCreditKind.voiceActor,
                  person: VideoMetadataPerson(
                    name: '声优',
                    profileUrl: 'tmdb-profile',
                    ids: const <VideoMetadataId>[
                      VideoMetadataId(type: 'tmdb', value: 'person-100'),
                    ],
                  ),
                  character: VideoMetadataCharacter(
                    name: '角色',
                    imageUrl: 'tmdb-character',
                    ids: const <VideoMetadataId>[
                      VideoMetadataId(type: 'tmdb', value: 'character-100'),
                    ],
                  ),
                  language: 'ja',
                ),
              ],
              images: const <VideoMetadataImage>[
                VideoMetadataImage(
                  kind: VideoMetadataImageKind.thumb,
                  url: 'tmdb-still',
                  provider: VideoMetadataProviderKind.tmdb,
                  seasonNumber: 1,
                  episodeNumber: 1,
                ),
                VideoMetadataImage(
                  kind: VideoMetadataImageKind.landscape,
                  url: 'tmdb-landscape',
                  provider: VideoMetadataProviderKind.tmdb,
                  seasonNumber: 1,
                  episodeNumber: 1,
                ),
              ],
            ),
            VideoMetadataEpisode(
              seasonNumber: 1,
              episodeNumber: 2,
              title: 'TMDB Episode 2',
            ),
          ],
        ),
        VideoMetadataSeason(
          seasonNumber: 2,
          title: 'TMDB Season 2',
        ),
      ],
    );

    final VideoMetadataWork merged =
        supplementVideoMetadataWithTmdb(primary, tmdb);
    expect(merged.title, '主源作品名');
    expect(merged.plot, '主源作品简介');
    expect(
      merged.images.map((VideoMetadataImage image) => image.url),
      <String>['primary-cover', 'tmdb-logo'],
    );
    expect(merged.credits, hasLength(1));
    expect(merged.credits.single.person.profileUrl, 'primary-profile');
    expect(
      merged.credits.single.person.ids.map((VideoMetadataId id) => id.type),
      <String>['bangumi', 'tmdb'],
    );

    expect(
      merged.seasons.map((VideoMetadataSeason season) => season.seasonNumber),
      <int>[1, 2],
    );
    final VideoMetadataSeason firstSeason = merged.seasons.first;
    expect(firstSeason.title, '主源第一季');
    expect(firstSeason.plot, '主源季简介');
    expect(
      firstSeason.images.map((VideoMetadataImage image) => image.url),
      <String>['primary-season-cover', 'tmdb-season-logo'],
    );
    expect(
      firstSeason.episodes
          .map((VideoMetadataEpisode episode) => episode.episodeNumber),
      <int>[1, 2],
    );
    final VideoMetadataEpisode firstEpisode = firstSeason.episodes.first;
    expect(firstEpisode.title, '主源第一集');
    expect(firstEpisode.plot, '主源分集简介');
    expect(
      firstEpisode.ids.map((VideoMetadataId id) => id.type),
      <String>['bangumi', 'tmdb'],
    );
    expect(firstEpisode.credits, hasLength(1));
    expect(
        firstEpisode.credits.single.character?.imageUrl, 'primary-character');
    expect(
      firstEpisode.images.map((VideoMetadataImage image) => image.url),
      <String>['primary-still', 'tmdb-landscape'],
    );
    expect(firstSeason.episodes.last.title, 'TMDB Episode 2');
    expect(merged.seasons.last.title, 'TMDB Season 2');
  });

  test('主源字段缺失时由 TMDB 补齐但不替换 provider 和标题', () {
    final VideoMetadataWork primary = VideoMetadataWork(
      provider: VideoMetadataProviderKind.anilist,
      kind: VideoMetadataMediaKind.tv,
      title: 'Primary title',
      seasons: <VideoMetadataSeason>[
        VideoMetadataSeason(
          seasonNumber: 1,
          title: 'Primary season',
          episodes: <VideoMetadataEpisode>[
            VideoMetadataEpisode(
              seasonNumber: 1,
              episodeNumber: 1,
              title: 'Primary episode',
            ),
          ],
        ),
      ],
    );
    final VideoMetadataWork tmdb = VideoMetadataWork(
      provider: VideoMetadataProviderKind.tmdb,
      kind: VideoMetadataMediaKind.tv,
      title: 'TMDB title',
      originalTitle: 'Original',
      year: 2025,
      plot: 'TMDB plot',
      runtimeMinutes: 24,
      genres: const <String>['Animation'],
      seasons: <VideoMetadataSeason>[
        VideoMetadataSeason(
          seasonNumber: 1,
          title: 'TMDB season',
          plot: 'TMDB season plot',
          episodes: <VideoMetadataEpisode>[
            VideoMetadataEpisode(
              seasonNumber: 1,
              episodeNumber: 1,
              title: 'TMDB episode',
              plot: 'TMDB episode plot',
              runtimeMinutes: 24,
            ),
          ],
        ),
      ],
    );

    final VideoMetadataWork merged =
        supplementVideoMetadataWithTmdb(primary, tmdb);
    expect(merged.provider, VideoMetadataProviderKind.anilist);
    expect(merged.title, 'Primary title');
    expect(merged.originalTitle, 'Original');
    expect(merged.year, 2025);
    expect(merged.plot, 'TMDB plot');
    expect(merged.runtimeMinutes, 24);
    expect(merged.genres, <String>['Animation']);
    expect(merged.seasons.single.title, 'Primary season');
    expect(merged.seasons.single.plot, 'TMDB season plot');
    expect(merged.seasons.single.episodes.single.title, 'Primary episode');
    expect(
      merged.seasons.single.episodes.single.plot,
      'TMDB episode plot',
    );
  });
}
