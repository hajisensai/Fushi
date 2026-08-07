/// VNDB adapter 解析与错误分支测试。**全程 MockClient，零真实网络**。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/mining/metadata/adapters/vndb_adapter.dart';
import 'package:fushi/src/mining/metadata/galgame_metadata_adapter.dart';
import 'package:fushi/src/mining/metadata/galgame_metadata_draft.dart';
import 'package:fushi/src/mining/metadata/galgame_metadata_rate_limit.dart';
import 'package:fushi/src/mining/metadata/galgame_metadata_source.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

GalgameRateLimiter _fastLimiter() => GalgameRateLimiter(
      capacity: 1000,
      refillInterval: const Duration(microseconds: 1),
    );

VndbMetadataAdapter _adapter(MockClient client) => VndbMetadataAdapter(
      client: client,
      rateLimiter: _fastLimiter(),
    );

/// `POST /kana/vn` 单条结果的真实形状（字段裁剪但结构照抄官方响应）。
const Map<String, Object?> _vnFixture = <String, Object?>{
  'id': 'v17',
  'titles': <Object?>[
    <String, Object?>{'lang': 'ja', 'title': '月姫', 'main': true},
    <String, Object?>{'lang': 'en', 'title': 'Tsukihime', 'main': false},
    <String, Object?>{'lang': 'zh-Hant', 'title': '月姬（繁）', 'main': false},
    <String, Object?>{'lang': 'zh-Hans', 'title': '月姬', 'main': false},
  ],
  'aliases': <Object?>['Moon Princess'],
  'image': <String, Object?>{'url': 'https://t.vndb.org/cv/tsukihime.jpg'},
  'released': '2000-12-29',
  'rating': 86.4,
  'tags': <Object?>[
    <String, Object?>{'name': 'Vampires', 'rating': 2.4, 'spoiler': 0},
    <String, Object?>{'name': 'Protagonist Dies', 'rating': 2.9, 'spoiler': 2},
    <String, Object?>{'name': 'Nakige', 'rating': 1.8, 'spoiler': 0},
    <String, Object?>{'name': 'Mild Spoiler', 'rating': 2.8, 'spoiler': 1},
  ],
  'description': '「ものを壊す線が視える。」',
  'developers': <Object?>[
    <String, Object?>{'name': 'TYPE-MOON'},
  ],
  'length_minutes': 1800,
};

Map<String, Object?> _results(List<Object?> results) => <String, Object?>{
      'results': results,
      'more': false,
    };

http.Response _json(Object? body, {int status = 200}) => http.Response(
      jsonEncode(body),
      status,
      headers: const <String, String>{
        'content-type': 'application/json; charset=utf-8',
      },
    );

void main() {
  group('validateId / externalUrl', () {
    final VndbMetadataAdapter adapter = _adapter(
        MockClient((http.Request _) async => _json(_results(<Object?>[]))));

    test('source 是 vndb', () {
      expect(adapter.source, GalgameMetadataSource.vndb);
    });

    test('只认 v + 数字', () {
      expect(adapter.validateId('v17'), isTrue);
      expect(adapter.validateId(' v12345 '), isTrue);
      expect(adapter.validateId('17'), isFalse);
      expect(adapter.validateId('V17'), isFalse);
      expect(adapter.validateId('v'), isFalse);
      expect(adapter.validateId('r17'), isFalse);
    });

    test('外链指向 vndb.org/{id}', () {
      expect(adapter.externalUrl('v17'), 'https://vndb.org/v17');
    });
  });

  group('fetchById', () {
    test('完整条目逐字段映射（含 rating / length_minutes 归一）', () async {
      late String body;
      late Uri url;
      final VndbMetadataAdapter adapter = _adapter(
        MockClient((http.Request req) async {
          body = req.body;
          url = req.url;
          return _json(_results(<Object?>[_vnFixture]));
        }),
      );

      final GalgameMetadataDraft? draft = await adapter.fetchById('v17');

      expect(url.path, endsWith('/vn'));
      final Map<String, Object?> sent =
          jsonDecode(body) as Map<String, Object?>;
      expect(sent['filters'], <Object?>['id', '=', 'v17']);
      expect(sent['fields'], kVndbDetailFields);

      expect(draft, isNotNull);
      expect(draft!.name, '月姫'); // main == true
      expect(draft.nameCn, '月姬'); // zh-Hans 优先于 zh-Hant
      expect(draft.aliases, <String>['Moon Princess']);
      expect(
        draft.allTitles,
        <String>['月姫', 'Tsukihime', '月姬（繁）', '月姬', 'Moon Princess'],
      );
      expect(draft.summary, '「ものを壊す線が視える。」');
      expect(draft.developer, 'TYPE-MOON');
      expect(draft.releaseDate, '2000-12-29');
      // 86.4 / 10 = 8.64（源侧 0-100 必须归一到 0-10）。
      expect(draft.score, 8.64);
      // 1800 分钟 = 30 小时。
      expect(draft.averageHours, 30.0);
      expect(draft.coverUrl, 'https://t.vndb.org/cv/tsukihime.jpg');
      expect(draft.externalId, 'v17');
      // spoiler > 0 全被过滤，剩下的按 rating 降序。
      expect(draft.tags, <String>['Vampires', 'Nakige']);
      // vndb 不提供 rank / nsfw。
      expect(draft.rank, isNull);
      expect(draft.nsfw, isNull);
    });

    test('空 results → null（ID 不存在不是异常）', () async {
      final VndbMetadataAdapter adapter = _adapter(
        MockClient((http.Request _) async => _json(_results(<Object?>[]))),
      );
      expect(await adapter.fetchById('v99999999'), isNull);
    });

    test('404 → null', () async {
      final VndbMetadataAdapter adapter = _adapter(
        MockClient((http.Request _) async => http.Response('nope', 404)),
      );
      expect(await adapter.fetchById('v17'), isNull);
    });

    test('400 / 500 → 抛 GalgameMetadataException 且带状态码', () async {
      for (final int status in <int>[400, 500]) {
        final VndbMetadataAdapter adapter = _adapter(
          MockClient((http.Request _) async =>
              http.Response('Invalid filter', status)),
        );
        await expectLater(
          adapter.fetchById('v17'),
          throwsA(
            isA<GalgameMetadataException>()
                .having((GalgameMetadataException e) => e.statusCode,
                    'statusCode', status)
                .having((GalgameMetadataException e) => e.source, 'source',
                    GalgameMetadataSource.vndb),
          ),
        );
      }
    });

    test('畸形 JSON → 抛异常且消息可读', () async {
      final VndbMetadataAdapter adapter = _adapter(
        MockClient((http.Request _) async => http.Response('{oops', 200)),
      );
      await expectLater(
        adapter.fetchById('v17'),
        throwsA(
          isA<GalgameMetadataException>().having(
            (GalgameMetadataException e) => e.message,
            'message',
            contains('malformed JSON'),
          ),
        ),
      );
    });

    test('响应不是对象 → 抛异常', () async {
      final VndbMetadataAdapter adapter = _adapter(
        MockClient((http.Request _) async => _json(<Object?>[])),
      );
      await expectLater(
        adapter.fetchById('v17'),
        throwsA(isA<GalgameMetadataException>()),
      );
    });

    test('results 缺失 / 元素非对象 → null，不崩', () async {
      final VndbMetadataAdapter noResults = _adapter(
        MockClient((http.Request _) async => _json(<String, Object?>{})),
      );
      expect(await noResults.fetchById('v17'), isNull);

      final VndbMetadataAdapter junk = _adapter(
        MockClient((http.Request _) async => _json(_results(<Object?>['x']))),
      );
      expect(await junk.fetchById('v17'), isNull);
    });

    test('非法 ID 直接抛，不发请求', () async {
      bool called = false;
      final VndbMetadataAdapter adapter = _adapter(
        MockClient((http.Request _) async {
          called = true;
          return _json(_results(<Object?>[_vnFixture]));
        }),
      );
      await expectLater(
        adapter.fetchById('17'),
        throwsA(isA<GalgameMetadataException>()),
      );
      expect(called, isFalse);
    });

    test('网络异常包成 GalgameMetadataException', () async {
      final VndbMetadataAdapter adapter = _adapter(
        MockClient((http.Request _) async => throw const _FakeSocketError()),
      );
      await expectLater(
        adapter.fetchById('v17'),
        throwsA(
          isA<GalgameMetadataException>().having(
            (GalgameMetadataException e) => e.message,
            'message',
            contains('request failed'),
          ),
        ),
      );
    });
  });

  group('searchByName', () {
    test('用 search 过滤器 + searchrank 排序，响应映射成候选', () async {
      late String body;
      final VndbMetadataAdapter adapter = _adapter(
        MockClient((http.Request req) async {
          body = req.body;
          return _json(_results(<Object?>[_vnFixture]));
        }),
      );

      final List<SourceCandidate> candidates =
          await adapter.searchByName('tsukihime', limit: 5);

      final Map<String, Object?> sent =
          jsonDecode(body) as Map<String, Object?>;
      expect(sent['filters'], <Object?>['search', '=', 'tsukihime']);
      expect(sent['sort'], 'searchrank');
      expect(sent['results'], 5);
      expect(sent['fields'], kVndbSearchFields);

      expect(candidates, hasLength(1));
      expect(candidates.single.source, GalgameMetadataSource.vndb);
      expect(candidates.single.externalId, 'v17');
      expect(candidates.single.name, '月姫');
      expect(candidates.single.nameCn, '月姬');
      expect(candidates.single.displayName, '月姬');
      expect(candidates.single.coverUrl, 'https://t.vndb.org/cv/tsukihime.jpg');
      expect(candidates.single.releaseDate, '2000-12-29');
      expect(candidates.single.summary, '「ものを壊す線が視える。」');
    });

    test('空结果 → 空表；空关键词不发请求', () async {
      final VndbMetadataAdapter empty = _adapter(
        MockClient((http.Request _) async => _json(_results(<Object?>[]))),
      );
      expect(await empty.searchByName('无此游戏'), isEmpty);

      bool called = false;
      final VndbMetadataAdapter blank = _adapter(
        MockClient((http.Request _) async {
          called = true;
          return _json(_results(<Object?>[]));
        }),
      );
      expect(await blank.searchByName('  '), isEmpty);
      expect(called, isFalse);
    });

    test('缺 id 的结果被跳过', () {
      final List<SourceCandidate> candidates = parseVndbSearchResults(<Object?>[
        <String, Object?>{'titles': <Object?>[]},
        <String, Object?>{'id': 'v1'},
      ]);
      expect(candidates, hasLength(1));
      expect(candidates.single.externalId, 'v1');
    });
  });

  group('归一与解析纯函数', () {
    test('vndbRatingToScore：0-100 → 0-10，越界与非正值处理', () {
      expect(vndbRatingToScore(86.4), 8.64);
      expect(vndbRatingToScore(100), 10.0);
      expect(vndbRatingToScore(0), isNull);
      expect(vndbRatingToScore(-1), isNull);
      expect(vndbRatingToScore(120), 10.0);
      expect(vndbRatingToScore('75'), 7.5);
      expect(vndbRatingToScore(null), isNull);
      expect(vndbRatingToScore('n/a'), isNull);
    });

    test('vndbMinutesToHours：分钟 → 小时（一位小数）', () {
      expect(vndbMinutesToHours(1800), 30.0);
      expect(vndbMinutesToHours(90), 1.5);
      expect(vndbMinutesToHours(100), 1.7);
      expect(vndbMinutesToHours(0), isNull);
      expect(vndbMinutesToHours(null), isNull);
      expect(vndbMinutesToHours('abc'), isNull);
    });

    test('parseVndbTags：过滤 spoiler、按 rating 降序、截断', () {
      final List<String> tags = parseVndbTags(<Object?>[
        for (int i = 0; i < 40; i++)
          <String, Object?>{
            'name': 'tag$i',
            'rating': 3.0 - i * 0.05,
            'spoiler': 0
          },
        <String, Object?>{'name': 'spoilered', 'rating': 3.0, 'spoiler': 1},
      ]);
      expect(tags, hasLength(kVndbMaxTags));
      expect(tags.first, 'tag0');
      expect(tags.contains('spoilered'), isFalse);
    });

    test('parseVndbTags：非数组 / 元素非对象 / 缺 name → 空表或跳过', () {
      expect(parseVndbTags('garbage'), isEmpty);
      expect(parseVndbTags(<Object?>[42, null]), isEmpty);
      expect(
        parseVndbTags(<Object?>[
          <String, Object?>{'rating': 3.0},
          <String, Object?>{'name': 'ok'},
        ]),
        <String>['ok'],
      );
    });

    test('titles 无 main 标记时退回第一条；无 titles 时全为 null', () {
      final GalgameMetadataDraft draft =
          parseVndbVisualNovel(<Object?, Object?>{
        'id': 'v1',
        'titles': <Object?>[
          <String, Object?>{'lang': 'en', 'title': 'Only One'},
        ],
      });
      expect(draft.name, 'Only One');
      expect(draft.nameCn, isNull);

      final GalgameMetadataDraft bare =
          parseVndbVisualNovel(<Object?, Object?>{'id': 'v2'});
      expect(bare.name, isNull);
      expect(bare.allTitles, isEmpty);
      expect(bare.externalId, 'v2');
    });

    test('多开发商用逗号连接；developers 脏数据 → null', () {
      expect(
        parseVndbVisualNovel(<Object?, Object?>{
          'developers': <Object?>[
            <String, Object?>{'name': 'A'},
            <String, Object?>{'name': 'B'},
            <String, Object?>{'name': 'A'},
          ],
        }).developer,
        'A, B',
      );
      expect(
        parseVndbVisualNovel(<Object?, Object?>{'developers': 'A'}).developer,
        isNull,
      );
    });

    test('image 给字符串也认；released 是 TBA 时不落日期', () {
      final GalgameMetadataDraft draft =
          parseVndbVisualNovel(<Object?, Object?>{
        'id': 'v3',
        'image': 'https://t.vndb.org/cv/x.jpg',
        'released': 'TBA',
      });
      expect(draft.coverUrl, 'https://t.vndb.org/cv/x.jpg');
      expect(draft.releaseDate, isNull);
    });
  });
}

/// 模拟底层网络异常（不引 dart:io，保持测试跨平台）。
class _FakeSocketError implements Exception {
  const _FakeSocketError();
  @override
  String toString() => 'SocketException: connection refused';
}
