import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/scraper/anilist_client.dart';
import 'package:hibiki/src/media/video/scraper/bangumi_client.dart'
    show ScrapeNetworkException;
import 'package:hibiki/src/media/video/scraper/jikan_client.dart';
import 'package:hibiki/src/media/video/scraper/scraper_types.dart';
import 'package:hibiki/src/media/video/scraper/tmdb_default_key.dart';

/// AniList / Jikan 解析层 + TMDB key 取值链的纯函数测试。
///
/// 打在解析函数而非 client 上：网络那层没有分支可言（发请求、判状态码、解码），真正
/// 会错的是字段映射——标题语言优先级、评分量纲换算、GraphQL 的「200 + errors」。
void main() {
  group('AniList 解析', () {
    String bodyWith(List<Object?> media) => jsonEncode(<String, Object?>{
          'data': <String, Object?>{
            'Page': <String, Object?>{'media': media},
          },
        });

    test('日文原题优先作标题，其余标题与 synonyms 全进别名', () {
      final List<ScrapeCandidate> result = parseAniListResponse(bodyWith(
        <Object?>[
          <String, Object?>{
            'id': 21,
            'title': <String, Object?>{
              'romaji': 'Mai Anime',
              'english': 'My Anime',
              'native': 'マイアニメ',
            },
            'synonyms': <Object?>['MA', 'まいあにめ'],
            'startDate': <String, Object?>{'year': 2021},
            'format': 'TV',
            'episodes': 12,
            'averageScore': 85,
            'coverImage': <String, Object?>{
              'extraLarge': 'https://img/xl.png',
              'large': 'https://img/l.png',
            },
            'bannerImage': 'https://img/banner.png',
            'siteUrl': 'https://anilist.co/anime/21',
          },
        ],
      ));

      expect(result, hasLength(1));
      final ScrapeCandidate c = result.single;
      expect(c.source, ScrapeSource.anilist);
      expect(c.entryId, '21');
      // 日语学习 app：主标题取 native，不是 romaji/english。
      expect(c.title, 'マイアニメ');
      expect(c.aliases,
          containsAll(<String>['Mai Anime', 'My Anime', 'MA', 'まいあにめ']));
      // 主标题自身不重复进别名。
      expect(c.aliases.where((String a) => a == 'マイアニメ'), isEmpty);
      expect(c.year, 2021);
      expect(c.type, ScrapeEntryType.tv);
      expect(c.episodeCount, 12);
      // extraLarge 优先于 large。
      expect(c.posterUrl, 'https://img/xl.png');
      expect(c.backdropUrl, 'https://img/banner.png');
    });

    test('averageScore 0~100 换算成 0~10（与其余源同量纲）', () {
      final ScrapeCandidate c = parseAniListResponse(bodyWith(<Object?>[
        <String, Object?>{
          'id': 1,
          'title': <String, Object?>{'native': 'X'},
          'averageScore': 85,
          'coverImage': <String, Object?>{'large': 'https://img/x.png'},
        },
      ])).single;
      expect(c.rating, 8.5);
      expect(c.ratingText, 'AniList 8.5');
    });

    test('简介剥离 HTML 标签与实体（asHtml:false 仍会留 <br> / <i>）', () {
      final ScrapeCandidate c = parseAniListResponse(bodyWith(<Object?>[
        <String, Object?>{
          'id': 1,
          'title': <String, Object?>{'native': 'X'},
          'description': '第一行<br>第二行 <i>斜体</i> &amp; 收尾',
          'coverImage': <String, Object?>{'large': 'https://img/x.png'},
        },
      ])).single;
      expect(c.summary, '第一行\n第二行 斜体 & 收尾');
    });

    test('缺封面的条目跳过（对封面刮削无用）', () {
      expect(
        parseAniListResponse(bodyWith(<Object?>[
          <String, Object?>{
            'id': 1,
            'title': <String, Object?>{'native': 'X'},
          },
        ])),
        isEmpty,
      );
    });

    test('ONA / MUSIC 归 unknown 而非硬塞类型（错误分类会主动扣分）', () {
      for (final String format in <String>['ONA', 'MUSIC', 'WHATEVER']) {
        final ScrapeCandidate c = parseAniListResponse(bodyWith(<Object?>[
          <String, Object?>{
            'id': 1,
            'title': <String, Object?>{'native': 'X'},
            'format': format,
            'coverImage': <String, Object?>{'large': 'https://img/x.png'},
          },
        ])).single;
        expect(c.type, ScrapeEntryType.unknown, reason: 'format=$format');
      }
    });

    test('GraphQL 错误是 200 + body.errors —— 必须抛，不得当成零结果', () {
      // 这条是本客户端最容易写错的地方：只看 statusCode 会把「查询被拒」静默变成
      // 「这部片不存在」，用户永远查不出为什么 AniList 一条都不出。
      expect(
        () => parseAniListResponse(jsonEncode(<String, Object?>{
          'errors': <Object?>[
            <String, Object?>{'message': 'Too Many Requests'},
          ],
        })),
        throwsA(isA<ScrapeNetworkException>()),
      );
    });

    test('结构缺失（无 data/Page/media）返回空表而非抛', () {
      expect(parseAniListResponse(jsonEncode(<String, Object?>{})), isEmpty);
      expect(
        parseAniListResponse(
            jsonEncode(<String, Object?>{'data': <String, Object?>{}})),
        isEmpty,
      );
    });
  });

  group('Jikan 解析', () {
    String bodyWith(List<Object?> data) =>
        jsonEncode(<String, Object?>{'data': data});

    test('日文原题优先，titles[] 全量进别名，aired.from 取年份', () {
      final ScrapeCandidate c = parseJikanResponse(bodyWith(<Object?>[
        <String, Object?>{
          'mal_id': 5114,
          'title': 'Mai Anime',
          'title_japanese': 'マイアニメ',
          'title_english': 'My Anime',
          'titles': <Object?>[
            <String, Object?>{'type': 'Synonym', 'title': 'MA'},
            <String, Object?>{'type': 'Default', 'title': 'Mai Anime'},
          ],
          'type': 'TV',
          'episodes': 64,
          'score': 9.1,
          'scored_by': 2000,
          'aired': <String, Object?>{'from': '2009-04-05T00:00:00+00:00'},
          'images': <String, Object?>{
            'jpg': <String, Object?>{
              'large_image_url': 'https://img/large.jpg',
              'image_url': 'https://img/small.jpg',
            },
          },
          'url': 'https://myanimelist.net/anime/5114',
          'synopsis': '简介文本',
        },
      ])).single;

      expect(c.source, ScrapeSource.jikan);
      expect(c.entryId, '5114');
      expect(c.title, 'マイアニメ');
      expect(c.aliases, containsAll(<String>['Mai Anime', 'My Anime', 'MA']));
      expect(c.year, 2009);
      expect(c.type, ScrapeEntryType.tv);
      expect(c.episodeCount, 64);
      expect(c.rating, 9.1);
      expect(c.ratingCount, 2000);
      expect(c.ratingText, 'MAL 9.1');
      // large_image_url 优先于 image_url。
      expect(c.posterUrl, 'https://img/large.jpg');
      // MAL 无横版图，恒 null（不编造一张不存在的图去填 hero 宽槽）。
      expect(c.backdropUrl, isNull);
      expect(c.summary, '简介文本');
    });

    test('缺封面 / 缺 mal_id 的条目跳过', () {
      expect(
        parseJikanResponse(bodyWith(<Object?>[
          <String, Object?>{'mal_id': 1, 'title': 'X'},
        ])),
        isEmpty,
      );
      expect(
        parseJikanResponse(bodyWith(<Object?>[
          <String, Object?>{
            'title': 'X',
            'images': <String, Object?>{
              'jpg': <String, Object?>{'image_url': 'https://img/x.jpg'},
            },
          },
        ])),
        isEmpty,
      );
    });

    test('jpg 缺失时回落 webp', () {
      final ScrapeCandidate c = parseJikanResponse(bodyWith(<Object?>[
        <String, Object?>{
          'mal_id': 7,
          'title': 'X',
          'images': <String, Object?>{
            'webp': <String, Object?>{'large_image_url': 'https://img/x.webp'},
          },
        },
      ])).single;
      expect(c.posterUrl, 'https://img/x.webp');
    });

    test('data 缺失返回空表而非抛', () {
      expect(parseJikanResponse(jsonEncode(<String, Object?>{})), isEmpty);
    });
  });

  group('TMDB key 取值链', () {
    test('用户自填优先于内置', () {
      expect(resolveTmdbApiKey('user-key'), 'user-key');
      expect(resolveTmdbApiKey('  user-key  '), 'user-key');
    });

    test('用户留空 → 回落内置（入库占位为空串，即「TMDB 未配置」的正常降级）', () {
      // 断言的是**取值规则**而非具体 key 值：内置值在 CI 由 secret 注入、本机由
      // skip-worktree 真值覆盖，把字面量写进断言会让这条测试随构建环境变红。
      expect(resolveTmdbApiKey(''), kBuiltinTmdbApiKey.trim());
      expect(resolveTmdbApiKey('   '), kBuiltinTmdbApiKey.trim());
    });
  });
}
