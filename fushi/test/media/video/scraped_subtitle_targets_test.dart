import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';

import 'package:fushi/src/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_models.dart';
import 'package:fushi/src/media/video/subtitle/scraped_subtitle_targets.dart';
import 'package:fushi/src/media/video/subtitle/video_subtitle_backfill.dart';
import 'package:fushi/src/media/video/video_sidecar.dart'
    show isSidecarSubtitleSuffix;

VideoBookRow _book(String uid, String path) => VideoBookRow(
      bookUid: uid,
      title: uid,
      videoPath: path,
      lastPositionMs: 0,
      delayMs: 0,
      currentEpisode: 0,
    );

VideoMetadataWork _work({
  List<VideoMetadataId> ids = const <VideoMetadataId>[],
  VideoMetadataMediaKind kind = VideoMetadataMediaKind.tv,
  String title = '葬送的芙莉莲',
  String? originalTitle = '葬送のフリーレン',
  int? runtimeMinutes = 24,
  List<VideoMetadataSeason> seasons = const <VideoMetadataSeason>[],
}) =>
    VideoMetadataWork(
      provider: VideoMetadataProviderKind.tmdb,
      kind: kind,
      title: title,
      originalTitle: originalTitle,
      runtimeMinutes: runtimeMinutes,
      ids: ids,
      seasons: seasons,
    );

void main() {
  group('scrapedMediaReference（准确率的分水岭：身份从刮削来，不从文件名猜）', () {
    test('外部 id 全量带过去——Jimaku 按 anilist_id 直查、OpenSubtitles 按 imdb', () {
      final VideoMediaReference ref = scrapedMediaReference(
        _work(ids: const <VideoMetadataId>[
          VideoMetadataId(type: 'anilist', value: '154587'),
          VideoMetadataId(type: 'tmdb', value: '209867'),
          VideoMetadataId(type: 'imdb', value: 'tt22248376'),
          VideoMetadataId(type: 'bangumi', value: '400602'),
          VideoMetadataId(type: 'tvdb', value: '424536'),
        ]),
        season: 1,
        episode: 5,
      );
      expect(ref.anilistId, 154587);
      expect(ref.tmdbId, 209867);
      expect(ref.imdbId, 'tt22248376');
      expect(ref.bangumiId, 400602);
      expect(ref.tvdbId, 424536);
      expect(ref.season, 1);
      expect(ref.episode, 5);
    });

    test('originalTitle 必须带上：id 没命中时的回退查询词不能是中文译名', () {
      final VideoMediaReference ref = scrapedMediaReference(_work());
      expect(ref.originalTitle, '葬送のフリーレン');
      expect(
        ref.title,
        '葬送的芙莉莲',
        reason: '中文译名仍要留着（UI 显示），但它不该是唯一的查询词',
      );
    });

    test('id 缺失/非数字不炸，只是那一项为 null', () {
      final VideoMediaReference ref = scrapedMediaReference(
        _work(ids: const <VideoMetadataId>[
          VideoMetadataId(type: 'anilist', value: 'not-a-number'),
          VideoMetadataId(type: 'tmdb', value: '  '),
        ]),
      );
      expect(ref.anilistId, isNull);
      expect(ref.tmdbId, isNull);
    });
  });

  group('scrapedDiscoveryCategory（决定 Jimaku 的 anime 硬过滤走哪一档）', () {
    test('有 AniList id → anime', () {
      expect(
        scrapedDiscoveryCategory(_work(ids: const <VideoMetadataId>[
          VideoMetadataId(type: 'anilist', value: '154587'),
        ])),
        VideoDiscoveryCategory.anime,
      );
    });

    test('无 AniList id → 按 movie/tv 分', () {
      expect(scrapedDiscoveryCategory(_work()), VideoDiscoveryCategory.tv);
      expect(
        scrapedDiscoveryCategory(_work(kind: VideoMetadataMediaKind.movie)),
        VideoDiscoveryCategory.movie,
      );
    });
  });

  group('scrapedSubtitleTargets', () {
    test('季集号取本地文件名解析，不是刮削里的顺序', () {
      final List<SubtitleBackfillTarget> targets = scrapedSubtitleTargets(
        members: <VideoBookRow>[
          // 故意让磁盘顺序与集号不一致：合集可能缺集/含特典/被拖拽重排过。
          _book('b3', '/v/Frieren S01E12.mkv'),
          _book('b1', '/v/Frieren S01E03.mkv'),
        ],
        metadata: _work(),
        hasExistingSubtitle: (_) => false,
      );
      expect(targets.map((SubtitleBackfillTarget t) => t.media.episode),
          <int>[12, 3]);
      expect(targets.every((SubtitleBackfillTarget t) => t.media.season == 1),
          isTrue);
    });

    test('已有字幕的成员直接标记，不生成新的下载意图', () {
      final List<SubtitleBackfillTarget> targets = scrapedSubtitleTargets(
        members: <VideoBookRow>[
          _book('has', '/v/Frieren S01E01.mkv'),
          _book('none', '/v/Frieren S01E02.mkv'),
        ],
        metadata: _work(),
        hasExistingSubtitle: (String uid) => uid == 'has',
      );
      expect(targets, hasLength(2));
      expect(
        targets
            .firstWhere((SubtitleBackfillTarget t) => t.bookUid == 'has')
            .hasExistingSubtitle,
        isTrue,
      );
      expect(
        targets
            .firstWhere((SubtitleBackfillTarget t) => t.bookUid == 'none')
            .hasExistingSubtitle,
        isFalse,
      );
    });

    test('多集里认不出集号的成员**不生成目标**（配上去只能是碰运气）', () {
      final List<SubtitleBackfillTarget> targets = scrapedSubtitleTargets(
        members: <VideoBookRow>[
          _book('ok', '/v/Frieren S01E01.mkv'),
          _book('opaque', '/v/opaque-name.mkv'),
        ],
        metadata: _work(),
        hasExistingSubtitle: (_) => false,
      );
      expect(targets.map((SubtitleBackfillTarget t) => t.bookUid), <String>[
        'ok',
      ]);
    });

    test('整部作品只有一个文件（电影/剧场版）时，认不出集号也照样生成目标', () {
      final List<SubtitleBackfillTarget> targets = scrapedSubtitleTargets(
        members: <VideoBookRow>[_book('movie', '/v/Frieren Movie.mkv')],
        metadata: _work(kind: VideoMetadataMediaKind.movie),
        hasExistingSubtitle: (_) => false,
      );
      expect(targets.single.media.episode, isNull);
      expect(targets.single.media.season, isNull);
    });

    test('runtime 取该集的，缺则回落作品级（时长校验的兜底来源）', () {
      final VideoMetadataWork work = _work(
        runtimeMinutes: 24,
        seasons: <VideoMetadataSeason>[
          VideoMetadataSeason(
            seasonNumber: 1,
            title: 'S1',
            episodes: <VideoMetadataEpisode>[
              VideoMetadataEpisode(
                seasonNumber: 1,
                episodeNumber: 1,
                title: 'ep1',
                runtimeMinutes: 48,
              ),
              VideoMetadataEpisode(
                seasonNumber: 1,
                episodeNumber: 2,
                title: 'ep2',
              ),
            ],
          ),
        ],
      );
      final List<SubtitleBackfillTarget> targets = scrapedSubtitleTargets(
        members: <VideoBookRow>[
          _book('a', '/v/Frieren S01E01.mkv'),
          _book('b', '/v/Frieren S01E02.mkv'),
        ],
        metadata: work,
        hasExistingSubtitle: (_) => false,
      );
      expect(targets[0].scrapedRuntimeMinutes, 48, reason: '首播双集时长翻倍');
      expect(targets[1].scrapedRuntimeMinutes, 24, reason: '该集没给就回落作品级');
    });

    test('空成员 / 空路径 → 空结果，不生成半截目标', () {
      expect(
        scrapedSubtitleTargets(
          members: const <VideoBookRow>[],
          metadata: _work(),
          hasExistingSubtitle: (_) => false,
        ),
        isEmpty,
      );
      expect(
        scrapedSubtitleTargets(
          members: <VideoBookRow>[_book('blank', '   ')],
          metadata: _work(),
          hasExistingSubtitle: (_) => false,
        ),
        isEmpty,
      );
    });
  });

  group('sidecar 命名必须与 isSidecarSubtitleSuffix 白名单成对', () {
    // 这两个函数与白名单是一个契约的两半：写出去的名字不匹配白名单，播放页就
    // 永远发现不了那条字幕，而下一轮「已有 sidecar？」检查同样看不见它 →
    // 每刮一次多一个孤儿文件。所以判据不是「看着像」，而是**真拿白名单验**。
    test('各种脏语言标签归一后仍落在白名单里', () {
      for (final String raw in <String>[
        'ja',
        'JA',
        'pt-BR',
        'ja[cc]',
        'en(sdh)',
        '  zh-Hans  ',
        '日本語',
        '',
        '---',
        'x' * 64,
      ]) {
        final String tag = sidecarLanguageTag(raw);
        expect(tag, isNotEmpty, reason: '空标签会写成 <base>..srt');
        expect(
          isSidecarSubtitleSuffix('.$tag.srt'),
          isTrue,
          reason: '"$raw" → "$tag" 写出的 sidecar 不被白名单认可',
        );
      }
    });

    test('非文本字幕扩展名一律落成 .srt（否则菜单里根本不出现）', () {
      expect(sidecarSubtitleExtension('a.srt'), '.srt');
      expect(sidecarSubtitleExtension('a.ASS'), '.ass');
      expect(sidecarSubtitleExtension('a.vtt'), '.vtt');
      expect(sidecarSubtitleExtension('a.zip'), '.srt');
      expect(sidecarSubtitleExtension('noext'), '.srt');
    });

    test('扩展名同样必须过白名单', () {
      for (final String name in <String>['a.srt', 'a.ASS', 'a.zip', 'noext']) {
        expect(
          isSidecarSubtitleSuffix('.ja${sidecarSubtitleExtension(name)}'),
          isTrue,
        );
      }
    });
  });
}
