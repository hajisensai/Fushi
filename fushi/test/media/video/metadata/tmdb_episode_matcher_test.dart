import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/video/metadata/tmdb_episode_matcher.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_merge.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';

/// Shoko `MatchAnidbToTmdbEpisodes` 移植（BUG-2593 的 Shoko 主路径）。TMDB 假剧：S1 三集
/// （2024-01）、S2 四集（2025-07 起每周）。
VideoMetadataEpisode _tmdb(int season, int number, String title, String date) =>
    VideoMetadataEpisode(
      seasonNumber: season,
      episodeNumber: number,
      title: title,
      airDate: date,
      ids: <VideoMetadataId>[
        VideoMetadataId(type: 'tmdb', value: '${season * 1000 + number}'),
      ],
    );

final List<VideoMetadataEpisode> _show = <VideoMetadataEpisode>[
  _tmdb(0, 1, 'Recap Special', '2024-06-01'),
  _tmdb(1, 1, 'The Beginning', '2024-01-07'),
  _tmdb(1, 2, 'Second Steps', '2024-01-14'),
  _tmdb(1, 3, 'Farewell', '2024-01-21'),
  _tmdb(2, 1, 'Return', '2025-07-06'),
  _tmdb(2, 2, 'The Calamity', '2025-07-13'),
  _tmdb(2, 3, 'Ashes', '2025-07-20'),
  _tmdb(2, 4, 'Dawn', '2025-07-27'),
];

TmdbEpisodeMatchSource _src(int n, List<String> titles, [String? date]) =>
    TmdbEpisodeMatchSource(number: n, titles: titles, airDate: date);

void main() {
  test('exact title + air date wins and locks the season for weaker rounds',
      () {
    final Map<int, TmdbEpisodeMatch> matches = matchEpisodesToTmdb(
      <TmdbEpisodeMatchSource>[
        _src(1, <String>['Return'], '2025-07-06'),
        // 标题没对上、日期对上 → date；季已被第 1 集锁到 S2。
        _src(2, <String>['災厄'], '2025-07-14'),
        // 什么都没对上但有锚：顺序兜底到前一条链接之后的下一集。
        _src(3, <String>['???']),
      ],
      _show,
    );
    expect(matches[1]?.episode.episodeNumber, 1);
    expect(matches[1]?.rating, TmdbEpisodeMatchRating.dateAndTitle);
    expect(matches[2]?.episode.episodeNumber, 2);
    expect(matches[2]?.rating, TmdbEpisodeMatchRating.date);
    expect(matches[3]?.episode.seasonNumber, 2);
    expect(matches[3]?.episode.episodeNumber, 3);
    expect(matches[3]?.rating, TmdbEpisodeMatchRating.firstAvailable);
  });

  test(
      'title-only sources (AniDB file identities) match across seasons and '
      'never fall back to first-available without an anchor', () {
    final Map<int, TmdbEpisodeMatch> matches = matchEpisodesToTmdb(
      <TmdbEpisodeMatchSource>[
        _src(1, <String>['Episode 1', 'The Calamity', '禍進譚']),
        _src(2, <String>['Ashen']), // 近似标题（编辑距离 1）
        _src(3, <String>['Nothing Like It']),
      ],
      _show,
    );
    expect(matches[1]?.episode.seasonNumber, 2);
    expect(matches[1]?.episode.episodeNumber, 2);
    expect(matches[1]?.rating, TmdbEpisodeMatchRating.title);
    expect(matches[2]?.episode.episodeNumber, 3);
    expect(matches[2]?.rating, TmdbEpisodeMatchRating.titleKinda);
    // 有锚（S2）→ 顺序兜底到 S2E4。
    expect(matches[3]?.episode.episodeNumber, 4);
    expect(matches[3]?.rating, TmdbEpisodeMatchRating.firstAvailable);
    // 没有任何一集对上 → 一条都不填（Shoko 会从 S1E1 顺序填）。
    expect(
      matchEpisodesToTmdb(<TmdbEpisodeMatchSource>[
        _src(1, <String>['Nope'])
      ], _show),
      isEmpty,
    );
  });

  test(
      'nearest air date within 120 days stays inside the anchor season and '
      'weak links are re-ordered to follow source order', () {
    final Map<int, TmdbEpisodeMatch> matches = matchEpisodesToTmdb(
      <TmdbEpisodeMatchSource>[
        _src(1, <String>['The Beginning'], '2024-01-07'),
        // 30 天外无 ±2 天候选 → 最近日期（锚定 S1）。
        _src(2, <String>['x'], '2024-02-20'),
        _src(3, <String>['y'], '2024-02-10'),
      ],
      _show,
    );
    expect(matches[1]?.rating, TmdbEpisodeMatchRating.dateAndTitle);
    expect(matches[2]?.episode.seasonNumber, 1);
    expect(matches[3]?.episode.seasonNumber, 1);
    expect(matches[2]!.episode.episodeNumber,
        lessThan(matches[3]!.episode.episodeNumber),
        reason: '弱评级相邻冒泡后 TMDB 顺序跟随来源集号');
  });

  test(
      'specials never enter the pool and generic "Episode N" titles are '
      'ignored', () {
    final Map<int, TmdbEpisodeMatch> matches = matchEpisodesToTmdb(
      <TmdbEpisodeMatchSource>[
        _src(1, <String>['Recap Special'], '2024-06-01'),
        _src(2, <String>['Episode 2']),
      ],
      _show,
    );
    expect(matches, isEmpty);
  });

  group('merge helpers', () {
    VideoMetadataWork tmdbWork() => VideoMetadataWork(
          provider: VideoMetadataProviderKind.tmdb,
          kind: VideoMetadataMediaKind.tv,
          title: 'Show',
          seasons: <VideoMetadataSeason>[
            VideoMetadataSeason(
                seasonNumber: 1,
                title: 'S1',
                episodes: _show.where((e) => e.seasonNumber == 1).toList()),
            VideoMetadataSeason(
                seasonNumber: 2,
                title: 'S2',
                episodes: _show.where((e) => e.seasonNumber == 2).toList()),
          ],
        );

    test(
        'enrichSeasonsByTmdbEpisodeMatch fills MAL episodes by date/title '
        'and skips sliced seasons and already-linked episodes', () {
      final VideoMetadataWork mal = VideoMetadataWork(
        provider: VideoMetadataProviderKind.mal,
        kind: VideoMetadataMediaKind.tv,
        title: 'Show 2nd',
        seasons: <VideoMetadataSeason>[
          VideoMetadataSeason(
            seasonNumber: 3,
            title: 'cour',
            episodes: <VideoMetadataEpisode>[
              VideoMetadataEpisode(
                  seasonNumber: 3,
                  episodeNumber: 1,
                  title: 'Return',
                  airDate: '2025-07-06'),
              VideoMetadataEpisode(
                  seasonNumber: 3,
                  episodeNumber: 2,
                  title: '災厄',
                  airDate: '2025-07-13'),
            ],
          ),
          VideoMetadataSeason(
            seasonNumber: 4,
            title: 'sliced',
            episodes: <VideoMetadataEpisode>[
              VideoMetadataEpisode(
                  seasonNumber: 4,
                  episodeNumber: 1,
                  title: 'Dawn',
                  airDate: '2025-07-27'),
            ],
          ),
        ],
      );
      final TmdbEpisodeMatchOutcome outcome = enrichSeasonsByTmdbEpisodeMatch(
        mal,
        tmdbWork(),
        skipSeasons: <int>{4},
      );
      final VideoMetadataSeason cour = outcome.work.seasons.first;
      expect(cour.episodes[0].ids.map((id) => id.value), contains('2001'));
      expect(cour.episodes[1].ids.map((id) => id.value), contains('2002'));
      expect(cour.episodes[1].title, '災厄', reason: 'MAL 标题独占，TMDB 只补空');
      expect(outcome.ratings[(3, 1)], TmdbEpisodeMatchRating.dateAndTitle);
      expect(outcome.ratings[(3, 2)], TmdbEpisodeMatchRating.date);
      expect(outcome.work.seasons[1].episodes.single.ids, isEmpty,
          reason: '切片季不参与');
      // 再跑一遍：已带 TMDB id 的集不再匹配，结果不变。
      expect(
        enrichSeasonsByTmdbEpisodeMatch(outcome.work, tmdbWork(),
            skipSeasons: <int>{4}).ratings,
        isEmpty,
      );
    });

    test(
        'fillEmptySeasonsFromEpisodeTitles lands verified episodes under the '
        'AniDB episode number and leaves unverified ones out', () {
      final VideoMetadataWork mal = VideoMetadataWork(
        provider: VideoMetadataProviderKind.mal,
        kind: VideoMetadataMediaKind.tv,
        title: 'Show 2nd',
        seasons: <VideoMetadataSeason>[
          VideoMetadataSeason(seasonNumber: 3, title: 'cour'),
        ],
      );
      final TmdbEpisodeMatchOutcome outcome = fillEmptySeasonsFromEpisodeTitles(
        mal,
        tmdbWork(),
        <int, List<TmdbEpisodeMatchSource>>{
          3: <TmdbEpisodeMatchSource>[
            _src(1, <String>['Return', 'Kikan', '帰還']),
            _src(2, <String>['The Calamity']),
            _src(7, <String>['Unknown Title Here']),
          ],
        },
      );
      final List<VideoMetadataEpisode> episodes =
          outcome.work.seasons.single.episodes;
      expect(episodes.map((e) => e.episodeNumber), <int>[1, 2, 7]);
      expect(episodes[0].seasonNumber, 3);
      expect(episodes[0].title, 'Return');
      expect(episodes[2].title, 'Ashes', reason: '第 7 集在 S2 锚内顺序兜底到 S2E3');
      expect(outcome.ratings[(3, 7)], TmdbEpisodeMatchRating.firstAvailable);
    });
  });
}
