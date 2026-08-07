/// Bangumi adapter 解析与错误分支测试。**全程 MockClient，零真实网络**。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/mining/metadata/adapters/bangumi_adapter.dart';
import 'package:fushi/src/mining/metadata/galgame_metadata_adapter.dart';
import 'package:fushi/src/mining/metadata/galgame_metadata_draft.dart';
import 'package:fushi/src/mining/metadata/galgame_metadata_rate_limit.dart';
import 'package:fushi/src/mining/metadata/galgame_metadata_source.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 测试用限流器：容量大、回充快，不让限流拖慢单测。
GalgameRateLimiter _fastLimiter() => GalgameRateLimiter(
      capacity: 1000,
      refillInterval: const Duration(microseconds: 1),
    );

BangumiMetadataAdapter _adapter(MockClient client, {String? token}) =>
    BangumiMetadataAdapter(
      client: client,
      rateLimiter: _fastLimiter(),
      accessToken: token,
    );

/// `GET /v0/subjects/8` 的真实形状（字段裁剪但结构照抄官方响应）。
const Map<String, Object?> _subjectFixture = <String, Object?>{
  'id': 8,
  'type': 4,
  'name': 'Fate/stay night',
  'name_cn': '命运之夜',
  'summary': '「私は、正義の味方になりたかった。」',
  'nsfw': true,
  'date': '2004-01-30',
  'platform': 'PC',
  'images': <String, Object?>{
    'large': 'https://lain.bgm.tv/pic/cover/l/fsn.jpg',
    'common': 'https://lain.bgm.tv/pic/cover/c/fsn.jpg',
    'medium': 'https://lain.bgm.tv/pic/cover/m/fsn.jpg',
  },
  'infobox': <Object?>[
    <String, Object?>{'key': '中文名', 'value': '命运之夜'},
    <String, Object?>{
      'key': '别名',
      'value': <Object?>[
        <String, Object?>{'v': 'フェイト/ステイナイト'},
        <String, Object?>{'v': 'FSN'},
      ],
    },
    <String, Object?>{'key': '开发', 'value': 'TYPE-MOON'},
    <String, Object?>{'key': '发行日期', 'value': '2004-01-30'},
  ],
  'rating': <String, Object?>{'rank': 12, 'total': 3000, 'score': 8.6},
  'tags': <Object?>[
    <String, Object?>{'name': 'Galgame', 'count': 300},
    <String, Object?>{'name': 'TYPE-MOON', 'count': 900},
    <String, Object?>{'name': '奈须きのこ', 'count': 500},
  ],
};

/// `POST /v0/search/subjects` 的真实形状。
const Map<String, Object?> _searchFixture = <String, Object?>{
  'total': 2,
  'limit': 10,
  'offset': 0,
  'data': <Object?>[
    <String, Object?>{
      'id': 8,
      'name': 'Fate/stay night',
      'name_cn': '命运之夜',
      'date': '2004-01-30',
      'summary': '简介一',
      'images': <String, Object?>{
        'large': 'https://lain.bgm.tv/pic/cover/l/fsn.jpg',
      },
    },
    <String, Object?>{
      'id': 15,
      'name': 'Fate/hollow ataraxia',
      'name_cn': '',
      'date': '2005',
      'image': 'https://lain.bgm.tv/r/400/pic/cover/l/fha.jpg',
    },
  ],
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
    final BangumiMetadataAdapter adapter =
        _adapter(MockClient((http.Request _) async => _json(null)));

    test('source 是 bgm', () {
      expect(adapter.source, GalgameMetadataSource.bgm);
    });

    test('只认纯数字 ID', () {
      expect(adapter.validateId('8'), isTrue);
      expect(adapter.validateId(' 123456 '), isTrue);
      expect(adapter.validateId('v17'), isFalse);
      expect(adapter.validateId('8a'), isFalse);
      expect(adapter.validateId(''), isFalse);
    });

    test('外链指向 bgm.tv/subject/{id}', () {
      expect(adapter.externalUrl('8'), 'https://bgm.tv/subject/8');
    });
  });

  group('fetchById', () {
    test('完整条目逐字段映射', () async {
      late Uri seen;
      final BangumiMetadataAdapter adapter = _adapter(
        MockClient((http.Request req) async {
          seen = req.url;
          return _json(_subjectFixture);
        }),
      );

      final GalgameMetadataDraft? draft = await adapter.fetchById('8');
      expect(seen.path, endsWith('/subjects/8'));
      expect(draft, isNotNull);
      expect(draft!.name, 'Fate/stay night');
      expect(draft.nameCn, '命运之夜');
      expect(draft.aliases, <String>['フェイト/ステイナイト', 'FSN']);
      expect(
        draft.allTitles,
        <String>['Fate/stay night', '命运之夜', 'フェイト/ステイナイト', 'FSN'],
      );
      expect(draft.summary, '「私は、正義の味方になりたかった。」');
      expect(draft.developer, 'TYPE-MOON');
      expect(draft.releaseDate, '2004-01-30');
      expect(draft.score, 8.6);
      expect(draft.rank, 12);
      expect(draft.nsfw, isTrue);
      expect(draft.coverUrl, 'https://lain.bgm.tv/pic/cover/l/fsn.jpg');
      expect(draft.externalId, '8');
      // tags 按 count 降序。
      expect(draft.tags, <String>['TYPE-MOON', '奈须きのこ', 'Galgame']);
      // bgm 不提供通关时长。
      expect(draft.averageHours, isNull);
    });

    test('带 token 时发 Authorization 头，不带则没有', () async {
      Map<String, String> headers = <String, String>{};
      final MockClient client = MockClient((http.Request req) async {
        headers = req.headers;
        return _json(_subjectFixture);
      });

      await _adapter(client, token: 'secret-token').fetchById('8');
      expect(headers['Authorization'], 'Bearer secret-token');

      await _adapter(client).fetchById('8');
      expect(headers.containsKey('Authorization'), isFalse);
      expect(headers['User-Agent'], isNotNull);
    });

    test('404 → null（条目不存在不是异常）', () async {
      final BangumiMetadataAdapter adapter = _adapter(
        MockClient((http.Request _) async => _json(
              <String, Object?>{'title': 'Not Found'},
              status: 404,
            )),
      );
      expect(await adapter.fetchById('99999999'), isNull);
    });

    test('500 → 抛 GalgameMetadataException 且带状态码', () async {
      final BangumiMetadataAdapter adapter = _adapter(
        MockClient((http.Request _) async => http.Response('boom', 500)),
      );
      await expectLater(
        adapter.fetchById('8'),
        throwsA(
          isA<GalgameMetadataException>()
              .having((GalgameMetadataException e) => e.statusCode,
                  'statusCode', 500)
              .having((GalgameMetadataException e) => e.source, 'source',
                  GalgameMetadataSource.bgm),
        ),
      );
    });

    test('畸形 JSON → 抛异常且消息可读', () async {
      final BangumiMetadataAdapter adapter = _adapter(
        MockClient((http.Request _) async => http.Response('{not json', 200)),
      );
      await expectLater(
        adapter.fetchById('8'),
        throwsA(
          isA<GalgameMetadataException>().having(
            (GalgameMetadataException e) => e.message,
            'message',
            contains('malformed JSON'),
          ),
        ),
      );
    });

    test('JSON 是数组而非对象 → 抛异常', () async {
      final BangumiMetadataAdapter adapter = _adapter(
        MockClient((http.Request _) async => _json(<Object?>[])),
      );
      await expectLater(
        adapter.fetchById('8'),
        throwsA(isA<GalgameMetadataException>()),
      );
    });

    test('非法 ID 直接抛，不发请求', () async {
      bool called = false;
      final BangumiMetadataAdapter adapter = _adapter(
        MockClient((http.Request _) async {
          called = true;
          return _json(_subjectFixture);
        }),
      );
      await expectLater(
        adapter.fetchById('v17'),
        throwsA(isA<GalgameMetadataException>()),
      );
      expect(called, isFalse);
    });

    test('网络异常包成 GalgameMetadataException，不吞', () async {
      final BangumiMetadataAdapter adapter = _adapter(
        MockClient((http.Request _) async => throw const _FakeSocketError()),
      );
      await expectLater(
        adapter.fetchById('8'),
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
    test('请求体限定游戏类型，响应映射成候选', () async {
      late String body;
      late Uri url;
      final BangumiMetadataAdapter adapter = _adapter(
        MockClient((http.Request req) async {
          body = req.body;
          url = req.url;
          return _json(_searchFixture);
        }),
      );

      final List<SourceCandidate> candidates =
          await adapter.searchByName('fate', limit: 10);

      final Map<String, Object?> sent =
          jsonDecode(body) as Map<String, Object?>;
      expect(sent['keyword'], 'fate');
      expect(
        (sent['filter']! as Map<String, Object?>)['type'],
        <int>[kBangumiSubjectTypeGame],
      );
      expect(url.path, endsWith('/search/subjects'));
      expect(url.queryParameters['limit'], '10');

      expect(candidates, hasLength(2));
      expect(candidates.first.source, GalgameMetadataSource.bgm);
      expect(candidates.first.externalId, '8');
      expect(candidates.first.nameCn, '命运之夜');
      expect(candidates.first.displayName, '命运之夜');
      expect(
          candidates.first.coverUrl, 'https://lain.bgm.tv/pic/cover/l/fsn.jpg');
      expect(candidates.first.releaseDate, '2004-01-30');
      expect(candidates.first.summary, '简介一');
      // 第二条：空 name_cn 降级为 null，退化的 `image` 字符串也认，半截日期不落。
      expect(candidates[1].nameCn, isNull);
      expect(candidates[1].displayName, 'Fate/hollow ataraxia');
      expect(candidates[1].coverUrl, 'https://lain.bgm.tv/pic/cover/l/fha.jpg');
      expect(candidates[1].releaseDate, isNull);
      expect(candidates[1].summary, isNull);
    });

    test('limit 截断多余结果', () async {
      final BangumiMetadataAdapter adapter = _adapter(
        MockClient((http.Request _) async => _json(_searchFixture)),
      );
      expect(await adapter.searchByName('fate', limit: 1), hasLength(1));
    });

    test('空结果 / 无 data 字段 / 404 → 空表（搜不到不是异常）', () async {
      final BangumiMetadataAdapter empty = _adapter(
        MockClient((http.Request _) async =>
            _json(<String, Object?>{'total': 0, 'data': <Object?>[]})),
      );
      expect(await empty.searchByName('无此游戏'), isEmpty);

      final BangumiMetadataAdapter noData = _adapter(
        MockClient((http.Request _) async =>
            _json(<String, Object?>{'title': 'Bad Request'})),
      );
      expect(await noData.searchByName('无此游戏'), isEmpty);

      final BangumiMetadataAdapter notFound = _adapter(
        MockClient((http.Request _) async =>
            _json(<String, Object?>{'title': 'Not Found'}, status: 404)),
      );
      expect(await notFound.searchByName('无此游戏'), isEmpty);
    });

    test('空关键词不发请求', () async {
      bool called = false;
      final BangumiMetadataAdapter adapter = _adapter(
        MockClient((http.Request _) async {
          called = true;
          return _json(_searchFixture);
        }),
      );
      expect(await adapter.searchByName('   '), isEmpty);
      expect(called, isFalse);
    });

    test('畸形 JSON → 抛异常', () async {
      final BangumiMetadataAdapter adapter = _adapter(
        MockClient((http.Request _) async => http.Response('<html>', 200)),
      );
      await expectLater(
        adapter.searchByName('fate'),
        throwsA(isA<GalgameMetadataException>()),
      );
    });
  });

  group('parseBangumiSubject 容错', () {
    test('infobox 别名给纯字符串也认；未知 key 忽略', () {
      final GalgameMetadataDraft draft = parseBangumiSubject(<Object?, Object?>{
        'id': 1,
        'name': 'X',
        'infobox': <Object?>[
          <String, Object?>{'key': '别名', 'value': '单个别名'},
          <String, Object?>{'key': '发行日期', 'value': '2004-01-30'},
          <String, Object?>{'key': '開發', 'value': 'Nitroplus'},
        ],
      });
      expect(draft.aliases, <String>['单个别名']);
      expect(draft.developer, 'Nitroplus');
    });

    test('infobox 是脏数据（非数组 / 元素非对象 / 缺 key）→ 不崩', () {
      expect(
        parseBangumiSubject(<Object?, Object?>{
          'id': 1,
          'infobox': 'garbage',
        }).aliases,
        isEmpty,
      );
      expect(
        parseBangumiSubject(<Object?, Object?>{
          'id': 1,
          'infobox': <Object?>[
            42,
            null,
            <String, Object?>{'value': 'x'}
          ],
        }).developer,
        isNull,
      );
    });

    test('多值开发商用逗号连接', () {
      final GalgameMetadataDraft draft = parseBangumiSubject(<Object?, Object?>{
        'id': 1,
        'infobox': <Object?>[
          <String, Object?>{
            'key': '开发',
            'value': <Object?>[
              <String, Object?>{'v': 'A社'},
              <String, Object?>{'v': 'B社'},
            ],
          },
        ],
      });
      expect(draft.developer, 'A社, B社');
    });

    test('score/rank 为 0 视作未评分', () {
      final GalgameMetadataDraft draft = parseBangumiSubject(<Object?, Object?>{
        'id': 1,
        'rating': <String, Object?>{'score': 0, 'rank': 0},
      });
      expect(draft.score, isNull);
      expect(draft.rank, isNull);
    });

    test('rank 落在顶层时也能取到；tags 为字符串数组也认', () {
      final GalgameMetadataDraft draft = parseBangumiSubject(<Object?, Object?>{
        'id': 1,
        'rank': 7,
        'tags': <Object?>['A', 'B', 'A'],
      });
      expect(draft.rank, 7);
      expect(draft.tags, <String>['A', 'B']);
    });

    test('tags 超过上限被截断', () {
      final GalgameMetadataDraft draft = parseBangumiSubject(<Object?, Object?>{
        'id': 1,
        'tags': <Object?>[
          for (int i = 0; i < 60; i++)
            <String, Object?>{'name': 'tag$i', 'count': 60 - i},
        ],
      });
      expect(draft.tags, hasLength(kBangumiMaxTags));
      expect(draft.tags.first, 'tag0');
    });

    test('封面按 large → common → medium 回退并还原原图', () {
      expect(
        bangumiCoverUrl(<Object?, Object?>{
          'images': <String, Object?>{
            'medium': 'https://lain.bgm.tv/r/800/pic/cover/l/a/b/m.jpg',
          },
        }),
        'https://lain.bgm.tv/pic/cover/l/a/b/m.jpg',
      );
      expect(bangumiCoverUrl(<Object?, Object?>{'images': 'x'}), isNull);
      expect(bangumiCoverUrl(const <Object?, Object?>{}), isNull);
    });
  });
}

/// 模拟底层网络异常（不引 dart:io，保持测试跨平台）。
class _FakeSocketError implements Exception {
  const _FakeSocketError();
  @override
  String toString() => 'SocketException: connection refused';
}
