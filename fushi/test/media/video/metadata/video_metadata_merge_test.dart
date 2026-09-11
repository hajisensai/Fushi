import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_languages.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_merge.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';

void main() {
  test('TMDB supplement cannot replace the AniDB media kind', () {
    final VideoMetadataWork merged = supplementVideoMetadataWithTmdb(
      VideoMetadataWork(
        provider: VideoMetadataProviderKind.anidb,
        kind: VideoMetadataMediaKind.tv,
        title: 'AniDB TV identity',
        ids: const <VideoMetadataId>[
          VideoMetadataId(type: 'anidb', value: '1'),
        ],
      ),
      VideoMetadataWork(
        provider: VideoMetadataProviderKind.tmdb,
        kind: VideoMetadataMediaKind.movie,
        title: 'TMDB movie match',
        ids: const <VideoMetadataId>[
          VideoMetadataId(type: 'tmdb', value: '2'),
        ],
      ),
    );

    expect(merged.kind, VideoMetadataMediaKind.tv);
    expect(merged.provider, VideoMetadataProviderKind.anidb);
    expect(merged.ids.map((VideoMetadataId id) => id.type),
        containsAll(<String>['anidb', 'tmdb']));
  });

  test('非 TMDB 主源保留展示字段并接入 TMDB 身份和季集骨架', () {
    final VideoMetadataWork primary = VideoMetadataWork(
      provider: VideoMetadataProviderKind.anidb,
      kind: VideoMetadataMediaKind.tv,
      title: '主源标题',
      plot: '主源简介',
      ids: const <VideoMetadataId>[VideoMetadataId(type: 'anidb', value: '1')],
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

    final VideoMetadataWork merged = supplementVideoMetadataWithTmdb(
      primary,
      tmdb,
    );
    expect(merged.provider, VideoMetadataProviderKind.anidb);
    expect(merged.title, '主源标题');
    expect(merged.plot, '主源简介');
    expect(merged.ids.map((VideoMetadataId id) => id.type), <String>[
      'anidb',
      'tmdb',
      'tvdb',
    ]);
    expect(merged.seasons, hasLength(1));
  });

  test('海报按资料语言优先，高分外语海报压不住本语言海报', () {
    // 用户报告的原始路径：资料语言 ja，TMDB 回来一张 8 分中文海报和一张低分
    // 日文海报——评分先于语言时中文永远赢，「资料语言」对海报形同虚设。
    const List<VideoMetadataImage> covers = <VideoMetadataImage>[
      VideoMetadataImage(
        kind: VideoMetadataImageKind.cover,
        url: 'high-zh',
        provider: VideoMetadataProviderKind.tmdb,
        language: 'zh',
        voteAverage: 8,
        voteCount: 100,
      ),
      VideoMetadataImage(
        kind: VideoMetadataImageKind.cover,
        url: 'low-ja',
        provider: VideoMetadataProviderKind.tmdb,
        language: 'ja',
        voteAverage: 5,
        voteCount: 3,
      ),
      VideoMetadataImage(
        kind: VideoMetadataImageKind.cover,
        url: 'mid-neutral',
        provider: VideoMetadataProviderKind.tmdb,
        voteAverage: 6,
        voteCount: 10,
      ),
    ];
    expect(
      selectVideoMetadataImages(
        primary: covers,
        languageOrder: const VideoMetadataLanguages('ja').imageLanguages,
      ).single.url,
      'low-ja',
    );
    // 同一批候选换成中文用户，选出来的就是中文那张：语言序真的在起作用，
    // 不是恰好 ja 那张排前面。
    expect(
      selectVideoMetadataImages(
        primary: covers,
        languageOrder: const VideoMetadataLanguages('zh-CN').imageLanguages,
      ).single.url,
      'high-zh',
    );
    // 本语言没有海报时回落 en → 无语言纯图，而不是随便拿一张外语的。
    expect(
      selectVideoMetadataImages(
        primary: covers,
        languageOrder: const VideoMetadataLanguages('de-DE').imageLanguages,
      ).single.url,
      'mid-neutral',
    );
  });

  test('同一语言内海报仍按评分票数排序', () {
    final List<VideoMetadataImage> selected = selectVideoMetadataImages(
      primary: const <VideoMetadataImage>[
        VideoMetadataImage(
          kind: VideoMetadataImageKind.cover,
          url: 'low-ja',
          provider: VideoMetadataProviderKind.tmdb,
          language: 'ja',
          voteAverage: 5,
          voteCount: 100,
        ),
        VideoMetadataImage(
          kind: VideoMetadataImageKind.cover,
          url: 'high-ja',
          provider: VideoMetadataProviderKind.tmdb,
          language: 'ja',
          voteAverage: 9,
          voteCount: 10,
        ),
      ],
      languageOrder: const VideoMetadataLanguages('ja').imageLanguages,
    );
    expect(selected.single.url, 'high-ja');
  });

  test('分集剧照是画面不是文字：0 票的 en 剧照压不住高分无标签剧照', () {
    // TMDB 给剧照打的语言标签不代表上面印了字；按语言优先会选错。
    final List<VideoMetadataImage> selected = selectVideoMetadataImages(
      primary: const <VideoMetadataImage>[
        VideoMetadataImage(
          kind: VideoMetadataImageKind.thumb,
          url: 'still-en-zero-votes',
          provider: VideoMetadataProviderKind.tmdb,
          language: 'en',
          seasonNumber: 1,
          episodeNumber: 1,
          voteAverage: 0,
          voteCount: 0,
        ),
        VideoMetadataImage(
          kind: VideoMetadataImageKind.thumb,
          url: 'still-untagged-high',
          provider: VideoMetadataProviderKind.tmdb,
          seasonNumber: 1,
          episodeNumber: 1,
          voteAverage: 8.5,
          voteCount: 40,
        ),
      ],
      languageOrder: const VideoMetadataLanguages('ja').imageLanguages,
    );
    expect(selected.single.url, 'still-untagged-high');
  });

  test('背景图是画面不是文字：评分优先，语言只作同分兜底（与修复前一致）', () {
    final List<VideoMetadataImage> selected = selectVideoMetadataImages(
      primary: const <VideoMetadataImage>[
        VideoMetadataImage(
          kind: VideoMetadataImageKind.backdrop,
          url: 'low-ja-backdrop',
          provider: VideoMetadataProviderKind.tmdb,
          language: 'ja',
          voteAverage: 5,
          voteCount: 100,
        ),
        VideoMetadataImage(
          kind: VideoMetadataImageKind.backdrop,
          url: 'high-neutral-backdrop',
          provider: VideoMetadataProviderKind.tmdb,
          voteAverage: 9,
          voteCount: 10,
        ),
      ],
      languageOrder: const VideoMetadataLanguages('ja').imageLanguages,
      maxBackdrops: 1,
    );
    expect(selected.single.url, 'high-neutral-backdrop');
  });

  test('续季单主源先重映射到本地季号再与 TMDB 全剧骨架合并', () {
    final VideoMetadataWork primary = VideoMetadataWork(
      provider: VideoMetadataProviderKind.anidb,
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

  test('specials season zero never remaps AniDB regular episodes', () {
    final VideoMetadataWork primary = VideoMetadataWork(
      provider: VideoMetadataProviderKind.anidb,
      kind: VideoMetadataMediaKind.tv,
      title: 'Anime',
      seasons: <VideoMetadataSeason>[
        VideoMetadataSeason(
          seasonNumber: 1,
          title: 'Regular episodes',
          episodes: <VideoMetadataEpisode>[
            VideoMetadataEpisode(
              seasonNumber: 1,
              episodeNumber: 1,
              title: 'Regular episode 1',
            ),
          ],
        ),
      ],
    );

    final VideoMetadataWork result = remapStandaloneVideoMetadataSeason(
      primary,
      0,
    );

    expect(result, same(primary));
    expect(result.seasons.single.seasonNumber, 1);
    expect(result.seasons.single.episodes.single.seasonNumber, 1);
  });

  test('TMDB 按季集号深合并且主源标题、简介、声优和图片优先', () {
    final VideoMetadataCredit primaryVoice = VideoMetadataCredit(
      kind: VideoMetadataCreditKind.voiceActor,
      person: VideoMetadataPerson(
        name: '声优',
        profileUrl: 'primary-profile',
        ids: const <VideoMetadataId>[
          VideoMetadataId(type: 'anidb', value: 'person-1'),
        ],
      ),
      character: VideoMetadataCharacter(
        name: '角色',
        imageUrl: 'primary-character',
        ids: const <VideoMetadataId>[
          VideoMetadataId(type: 'anidb', value: 'character-1'),
        ],
      ),
      language: 'ja',
    );
    final VideoMetadataWork primary = VideoMetadataWork(
      provider: VideoMetadataProviderKind.anidb,
      kind: VideoMetadataMediaKind.tv,
      title: '主源作品名',
      plot: '主源作品简介',
      ids: const <VideoMetadataId>[
        VideoMetadataId(type: 'anidb', value: 'work-1'),
      ],
      credits: <VideoMetadataCredit>[primaryVoice],
      images: const <VideoMetadataImage>[
        VideoMetadataImage(
          kind: VideoMetadataImageKind.cover,
          url: 'primary-cover',
          provider: VideoMetadataProviderKind.anidb,
        ),
      ],
      seasons: <VideoMetadataSeason>[
        VideoMetadataSeason(
          seasonNumber: 1,
          title: '主源第一季',
          plot: '主源季简介',
          ids: const <VideoMetadataId>[
            VideoMetadataId(type: 'anidb', value: 'season-1'),
          ],
          images: const <VideoMetadataImage>[
            VideoMetadataImage(
              kind: VideoMetadataImageKind.cover,
              url: 'primary-season-cover',
              provider: VideoMetadataProviderKind.anidb,
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
                VideoMetadataId(type: 'anidb', value: 'episode-1'),
              ],
              credits: <VideoMetadataCredit>[primaryVoice],
              images: const <VideoMetadataImage>[
                VideoMetadataImage(
                  kind: VideoMetadataImageKind.thumb,
                  url: 'primary-still',
                  provider: VideoMetadataProviderKind.anidb,
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
      ids: const <VideoMetadataId>[VideoMetadataId(type: 'tmdb', value: '100')],
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
        VideoMetadataSeason(seasonNumber: 2, title: 'TMDB Season 2'),
      ],
    );

    final VideoMetadataWork merged = supplementVideoMetadataWithTmdb(
      primary,
      tmdb,
    );
    expect(merged.title, '主源作品名');
    expect(merged.plot, '主源作品简介');
    expect(merged.images.map((VideoMetadataImage image) => image.url), <String>[
      'primary-cover',
      'tmdb-logo',
    ]);
    expect(merged.credits, hasLength(1));
    expect(merged.credits.single.person.profileUrl, 'primary-profile');
    expect(
      merged.credits.single.person.ids.map((VideoMetadataId id) => id.type),
      <String>['anidb', 'tmdb'],
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
      firstSeason.episodes.map(
        (VideoMetadataEpisode episode) => episode.episodeNumber,
      ),
      <int>[1, 2],
    );
    final VideoMetadataEpisode firstEpisode = firstSeason.episodes.first;
    expect(firstEpisode.title, '主源第一集');
    expect(firstEpisode.plot, '主源分集简介');
    expect(firstEpisode.ids.map((VideoMetadataId id) => id.type), <String>[
      'anidb',
      'tmdb',
    ]);
    expect(firstEpisode.credits, hasLength(1));
    expect(
      firstEpisode.credits.single.character?.imageUrl,
      'primary-character',
    );
    expect(
      firstEpisode.images.map((VideoMetadataImage image) => image.url),
      <String>['primary-still', 'tmdb-landscape'],
    );
    expect(firstSeason.episodes.last.title, 'TMDB Episode 2');
    expect(merged.seasons.last.title, 'TMDB Season 2');
  });

  group('supplementVideoMetadata 有序合并', () {
    VideoMetadataWork mal({
      String? plot,
      String? tagline,
      List<String> genres = const <String>[],
      List<String> aliases = const <String>[],
      double? rating,
    }) =>
        VideoMetadataWork(
          provider: VideoMetadataProviderKind.mal,
          kind: VideoMetadataMediaKind.tv,
          title: 'MAL title',
          originalTitle: '日本語原題',
          plot: plot,
          tagline: tagline,
          genres: genres,
          aliases: aliases,
          rating: rating,
          ratingVotes: rating == null ? null : 1000,
          studios: const <String>['MAPPA'],
          ids: const <VideoMetadataId>[
            VideoMetadataId(type: 'mal', value: '1')
          ],
        );
    VideoMetadataWork tmdb({
      String? plot,
      String? tagline,
      List<String> genres = const <String>[],
      List<String> aliases = const <String>[],
    }) =>
        VideoMetadataWork(
          provider: VideoMetadataProviderKind.tmdb,
          kind: VideoMetadataMediaKind.tv,
          title: 'TMDB title',
          plot: plot,
          tagline: tagline,
          genres: genres,
          aliases: aliases,
          studios: const <String>['mappa', 'Studio B'],
          ids: const <VideoMetadataId>[
            VideoMetadataId(type: 'tmdb', value: '2')
          ],
        );

    test('对称：TMDB 主源时 MAL 补评分、日文原名、别名', () {
      final VideoMetadataWork merged = supplementVideoMetadata(
        tmdb(plot: 'TMDB plot'),
        mal(
            plot: 'MAL synopsis',
            rating: 8.7,
            aliases: const <String>['Alias']),
      );

      expect(merged.provider, VideoMetadataProviderKind.tmdb);
      expect(merged.title, 'TMDB title');
      expect(merged.plot, 'TMDB plot', reason: '无首选语言 → 先到者独占');
      expect(merged.rating, 8.7);
      expect(merged.ratingVotes, 1000);
      expect(merged.originalTitle, '日本語原題');
      expect(merged.aliases, <String>['Alias']);
      expect(merged.ids.map((VideoMetadataId id) => id.type),
          <String>['tmdb', 'mal']);
    });

    test('集合并集去重：primary 在前，supplement 只追加归一化后不重复的项', () {
      final VideoMetadataWork merged = supplementVideoMetadata(
        mal(
          genres: const <String>['Action', 'Sci-Fi', '動作'],
          aliases: const <String>['Ａlias One'],
        ),
        tmdb(
          genres: const <String>['action', 'Sci Fi', 'Drama', '动作', ' '],
          aliases: const <String>['alias one', 'Alias Two'],
        ),
      );

      expect(merged.genres, <String>['Action', 'Sci-Fi', '動作', 'Drama']);
      expect(merged.studios, <String>['MAPPA', 'Studio B']);
      expect(merged.aliases, <String>['Ａlias One', 'Alias Two']);
    });

    test('plot 语言感知：zh-CN 首选下 MAL 英文简介被 TMDB 中文简介覆盖', () {
      final VideoMetadataWork merged = supplementVideoMetadata(
        mal(plot: 'English synopsis', tagline: 'English tagline'),
        tmdb(plot: '中文简介', tagline: '中文标语'),
        preferredLanguage: 'zh-CN',
      );

      expect(merged.plot, '中文简介');
      expect(merged.tagline, '中文标语');
      expect(merged.title, 'MAL title', reason: '只覆盖简介/标语，标题仍先到者');
    });

    test('plot 语言感知：supplement 首选但为空时回落 primary', () {
      final VideoMetadataWork merged = supplementVideoMetadata(
        mal(plot: 'English synopsis'),
        tmdb(plot: '   '),
        preferredLanguage: 'zh',
      );

      expect(merged.plot, 'English synopsis');
    });

    test('plot 语言感知：en 首选下 MAL 简介保留', () {
      final VideoMetadataWork merged = supplementVideoMetadata(
        mal(plot: 'English synopsis'),
        tmdb(plot: 'English overview from TMDB'),
        preferredLanguage: 'en-US',
      );

      expect(merged.plot, 'English synopsis');
    });

    test('plot 语言感知：TMDB 主源 zh 首选时 MAL 英文不覆盖', () {
      final VideoMetadataWork merged = supplementVideoMetadata(
        tmdb(plot: '中文简介'),
        mal(plot: 'English synopsis'),
        preferredLanguage: 'zh-Hans',
      );

      expect(merged.plot, '中文简介');
    });

    test('preferredLanguage 为 null 时退化成「空才补」', () {
      expect(
        supplementVideoMetadata(
          mal(plot: 'English synopsis'),
          tmdb(plot: '中文简介'),
        ).plot,
        'English synopsis',
      );
      expect(
        supplementVideoMetadata(mal(), tmdb(plot: '中文简介')).plot,
        '中文简介',
      );
    });

    test('同 provider 原样返回', () {
      final VideoMetadataWork primary = mal(plot: 'a');
      expect(
        supplementVideoMetadata(primary, mal(plot: 'b'),
            preferredLanguage: 'zh'),
        same(primary),
      );
      expect(supplementVideoMetadata(primary, null), same(primary));
    });

    test('旧别名 supplementVideoMetadataWithTmdb 行为不变', () {
      final VideoMetadataWork tmdbPrimary = tmdb(plot: 'TMDB plot');
      expect(
        supplementVideoMetadataWithTmdb(tmdbPrimary, tmdb(plot: 'other')),
        same(tmdbPrimary),
        reason: 'primary 已是 TMDB → 原样返回',
      );
      final VideoMetadataWork merged = supplementVideoMetadataWithTmdb(
        mal(plot: 'English synopsis'),
        tmdb(plot: '中文简介', genres: const <String>['Drama']),
      );
      expect(merged.plot, 'English synopsis', reason: '不做语言感知');
      expect(merged.genres, <String>['Drama']);
      expect(merged.provider, VideoMetadataProviderKind.mal);
    });
  });

  test('主源字段缺失时由 TMDB 补齐但不替换 provider 和标题', () {
    final VideoMetadataWork primary = VideoMetadataWork(
      provider: VideoMetadataProviderKind.anidb,
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

    final VideoMetadataWork merged = supplementVideoMetadataWithTmdb(
      primary,
      tmdb,
    );
    expect(merged.provider, VideoMetadataProviderKind.anidb);
    expect(merged.title, 'Primary title');
    expect(merged.originalTitle, 'Original');
    expect(merged.year, 2025);
    expect(merged.plot, 'TMDB plot');
    expect(merged.runtimeMinutes, 24);
    expect(merged.genres, <String>['Animation']);
    expect(merged.seasons.single.title, 'Primary season');
    expect(merged.seasons.single.plot, 'TMDB season plot');
    expect(merged.seasons.single.episodes.single.title, 'Primary episode');
    expect(merged.seasons.single.episodes.single.plot, 'TMDB episode plot');
  });
}
