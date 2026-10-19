import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/netflix_metadata.dart';
import 'package:fushi/src/media/video/video_player_controller.dart'
    show VideoChapter;
import 'package:fushi/src/media/video/web_video_bridge.dart';

const NetflixChapterLabels _labels = NetflixChapterLabels(
  recap: 'Recap',
  intro: 'Intro',
  main: 'Episode',
  credits: 'Credits',
);

String _showJson() => jsonEncode(<String, Object?>{
  'version': '2.1',
  'video': <String, Object?>{
    'type': 'show',
    'id': 80057281,
    'title': 'Stranger Things',
    'currentEpisode': 80077210,
    'boxart': <Object?>[
      <String, Object?>{'url': 'https://img/box-s.jpg', 'w': 100, 'h': 140},
      <String, Object?>{'url': 'https://img/box-l.jpg', 'w': 500, 'h': 700},
    ],
    'seasons': <Object?>[
      // 季倒序给出：解析后要按季序、集序排好。
      <String, Object?>{
        'seq': 2,
        'title': 'Season 2',
        'episodes': <Object?>[
          <String, Object?>{
            'episodeId': 80083977,
            'seq': 1,
            'title': 'MADMAX',
            'runtime': 2900,
          },
        ],
      },
      <String, Object?>{
        'seq': 1,
        'title': 'Season 1',
        'episodes': <Object?>[
          <String, Object?>{
            'episodeId': 80077210,
            'seq': 2,
            'title': 'The Weirdo on Maple Street',
            'runtime': 3300,
            'creditsOffset': 3200,
            'stills': <Object?>[
              <String, Object?>{
                'url': 'https://img/e2.jpg',
                'w': 1280,
                'h': 720,
              },
            ],
            'skipMarkers': <String, Object?>{
              'credit': <String, Object?>{'start': 60000, 'end': 120000},
              'recap': <String, Object?>{'start': 5000, 'end': 50000},
            },
          },
          <String, Object?>{
            'episodeId': 80077209,
            'seq': 1,
            'title': 'The Vanishing of Will Byers',
            'thumbs': <Object?>[
              <String, Object?>{
                'url': 'https://img/e1-thumb.jpg',
                'w': 320,
                'h': 180,
              },
            ],
            'skipMarkers': <String, Object?>{
              'credit': <String, Object?>{'start': 0, 'end': 0},
            },
          },
        ],
      },
    ],
  },
});

void main() {
  group('parseNetflixMetadata', () {
    test('剧集：按季序 / 集序排平，集名 / 剧照 / 标记齐全', () {
      final NetflixTitleMetadata meta = parseNetflixMetadata(_showJson())!;
      expect(meta.isShow, isTrue);
      expect(meta.id, '80057281');
      expect(meta.coverUrl, 'https://img/box-l.jpg', reason: '取最大的 boxart');
      expect(meta.episodes.map((NetflixEpisode e) => e.id), <String>[
        '80077209',
        '80077210',
        '80083977',
      ]);
      final NetflixEpisode e2 = meta.episodes[1];
      expect(e2.seasonSeq, 1);
      expect(e2.seq, 2);
      expect(e2.stillUrl, 'https://img/e2.jpg');
      expect(meta.episodes[0].stillUrl, 'https://img/e1-thumb.jpg');
      expect(e2.markers.introStartMs, 60000);
      expect(e2.markers.introEndMs, 120000);
      expect(e2.markers.recapEndMs, 50000);
      expect(e2.markers.creditsStartMs, 3200000);
      expect(
        meta.episodes[0].markers.isEmpty,
        isTrue,
        reason: 'start==end 的标记等于没有',
      );
      expect(meta.indexOfEpisode('80077210'), 1);
      expect(e2.watchUrl, 'https://www.netflix.com/watch/80077210');
      expect(
        meta.displayTitleFor('80077210'),
        'Stranger Things · S1E2 The Weirdo on Maple Street',
      );
      expect(meta.coverFor('80077210'), 'https://img/e2.jpg');
      expect(meta.coverFor('99'), 'https://img/box-l.jpg');
    });

    test('describes：只认原文里真有的那一集 / 作品（页面伪造回执的判据）', () {
      final NetflixTitleMetadata meta = parseNetflixMetadata(_showJson())!;
      expect(meta.describes('80077210'), isTrue);
      expect(meta.describes(meta.id), isTrue);
      expect(meta.describes('99999999'), isFalse);
    });

    test('电影：没有剧集，标记在作品上', () {
      final NetflixTitleMetadata meta = parseNetflixMetadata(
        jsonEncode(<String, Object?>{
          'video': <String, Object?>{
            'type': 'movie',
            'id': 70131314,
            'title': 'Inception',
            'runtime': 8880,
            'creditsOffset': 8500,
            'skipMarkers': <String, Object?>{
              'credit': <String, Object?>{'start': 0, 'end': 0},
            },
          },
        }),
      )!;
      expect(meta.isShow, isFalse);
      expect(meta.episodes, isEmpty);
      expect(meta.markersFor('70131314').creditsStartMs, 8500000);
      expect(meta.displayTitleFor('70131314'), 'Inception');
    });

    test('坏形状回 null，不抛', () {
      expect(parseNetflixMetadata('not json'), isNull);
      expect(parseNetflixMetadata('[]'), isNull);
      expect(parseNetflixMetadata('{"video":{}}'), isNull);
      expect(
        parseNetflixMetadata('{"video":{"id":1,"type":"show"}}'),
        isNotNull,
      );
    });
  });

  group('netflixChaptersFromMarkers', () {
    test('前情回顾 / 片头 / 正片 / 片尾按时间排好', () {
      final NetflixTitleMetadata meta = parseNetflixMetadata(_showJson())!;
      final List<VideoChapter> chapters = netflixChaptersFromMarkers(
        meta.markersFor('80077210'),
        _labels,
        durationMs: 3300000,
      );
      expect(
        chapters.map((VideoChapter c) => (c.title, c.start.inMilliseconds)),
        <(String, int)>[
          ('Episode', 0),
          ('Recap', 5000),
          ('Episode', 50000),
          ('Intro', 60000),
          ('Episode', 120000),
          ('Credits', 3200000),
        ],
      );
      expect(chapters.map((VideoChapter c) => c.index), <int>[
        0,
        1,
        2,
        3,
        4,
        5,
      ]);
    });

    test('片头从 0 开始时不留空的「正片」头章；没有标记 = 没有章节', () {
      final List<VideoChapter> chapters = netflixChaptersFromMarkers(
        const NetflixSkipMarkers(introStartMs: 0, introEndMs: 90000),
        _labels,
      );
      expect(chapters.map((VideoChapter c) => c.title), <String>[
        'Intro',
        'Episode',
      ]);
      expect(
        netflixChaptersFromMarkers(const NetflixSkipMarkers(), _labels),
        isEmpty,
      );
    });

    test('越过片长的标记丢掉', () {
      expect(
        netflixChaptersFromMarkers(
          const NetflixSkipMarkers(creditsStartMs: 5000000),
          _labels,
          durationMs: 3000000,
        ),
        isEmpty,
      );
    });
  });

  group('pickWebVideoSiteTrackForLanguage（每集默认音轨 / 字幕）', () {
    const List<WebVideoSiteTrack> tracks = <WebVideoSiteTrack>[
      WebVideoSiteTrack(id: 'en', lang: 'en', name: 'English'),
      WebVideoSiteTrack(
        id: 'ja-cc',
        lang: 'ja',
        name: '日本語 [CC]',
        type: 'ASSISTIVE',
      ),
      WebVideoSiteTrack(
        id: 'ja-img',
        lang: 'ja',
        name: '日本語',
        imageBased: true,
      ),
      WebVideoSiteTrack(id: 'ja', lang: 'ja', name: '日本語'),
      WebVideoSiteTrack(id: 'zh', lang: 'zh-Hans', name: '简体中文'),
    ];

    test('同语言里普通文字轨优先于 CC、文字轨优先于图片轨', () {
      expect(pickWebVideoSiteTrackForLanguage(tracks, 'ja')?.id, 'ja');
      expect(pickWebVideoSiteTrackForLanguage(tracks, 'JA')?.id, 'ja');
    });

    test('语言码前缀匹配；没有偏好 / 没有匹配回 null', () {
      expect(pickWebVideoSiteTrackForLanguage(tracks, 'zh')?.id, 'zh');
      expect(pickWebVideoSiteTrackForLanguage(tracks, null), isNull);
      expect(pickWebVideoSiteTrackForLanguage(tracks, ''), isNull);
      expect(pickWebVideoSiteTrackForLanguage(tracks, 'ko'), isNull);
    });
  });

  test('glue 轨清单的新列（类型 / 图片轨）解析，旧三列格式照旧', () {
    final List<WebVideoSiteTrack> parsed = parseWebVideoSiteTracks(
      'T:1\tja\t日本語\tPRIMARY\t0\nT:2\tja\t画像\tPRIMARY\t1\nT:3\ten\tEnglish\n#T:1',
    );
    expect(parsed.map((WebVideoSiteTrack t) => t.imageBased), <bool>[
      false,
      true,
      false,
    ]);
    expect(parsed[0].type, 'PRIMARY');
    expect(parsed[2].type, '');
    expect(parseWebVideoSiteTrackCurrent('T:1\tja\tx\n#T:1'), 'T:1');
  });
}
