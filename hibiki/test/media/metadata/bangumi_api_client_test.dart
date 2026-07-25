import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/metadata/bangumi_api_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 共享传输层 [BangumiApiClient] 的契约测试。
///
/// 只验证「传输层职责」：URL / 请求头 / POST 体 / subjectType 过滤 / utf8 解码 /
/// 传输异常边界 / 限流 gate 注入 / token。领域映射（ScrapeCandidate / GalgameDraft）
/// 由各调用方自己的测试覆盖，不在此重复。
void main() {
  group('BangumiApiClient.searchSubjects', () {
    test('POST /search/subjects：UA/Content-Type 头、body 含 keyword+filter.type、limit query',
        () async {
      Map<String, String>? headers;
      Object? body;
      Uri? uri;
      final MockClient client = MockClient((http.Request req) async {
        headers = req.headers;
        body = jsonDecode(req.body);
        uri = req.url;
        return http.Response.bytes(utf8.encode('{"data":[]}'), 200);
      });
      final BangumiApiClient api =
          BangumiApiClient(client: client, userAgent: 'ua/test');

      final BangumiRawResponse res = await api.searchSubjects(
        '鬼滅',
        subjectType: kBangumiSubjectTypeGame,
        limit: 5,
      );

      expect(res.statusCode, 200);
      expect(res.isOk, isTrue);
      expect(uri?.path, '/v0/search/subjects');
      expect(uri?.queryParameters['limit'], '5');
      expect(headers?['user-agent'], 'ua/test');
      expect(headers?['content-type'], contains('application/json'));
      final Map<String, Object?> decoded =
          (body as Map).cast<String, Object?>();
      expect(decoded['keyword'], '鬼滅');
      expect((decoded['filter'] as Map)['type'], <int>[4]);
    });

    test('limit 超 50 被 clamp 到 50', () async {
      Uri? uri;
      final MockClient client = MockClient((http.Request req) async {
        uri = req.url;
        return http.Response.bytes(utf8.encode('{}'), 200);
      });
      await BangumiApiClient(client: client, userAgent: 'ua')
          .searchSubjects('x', subjectType: kBangumiSubjectTypeAnime, limit: 999);
      expect(uri?.queryParameters['limit'], '50');
    });

    test('subjectType 透传：书籍=1', () async {
      Object? body;
      final MockClient client = MockClient((http.Request req) async {
        body = jsonDecode(req.body);
        return http.Response.bytes(utf8.encode('{}'), 200);
      });
      await BangumiApiClient(client: client, userAgent: 'ua')
          .searchSubjects('x', subjectType: kBangumiSubjectTypeBook);
      expect(((body as Map)['filter'] as Map)['type'], <int>[1]);
    });
  });

  group('BangumiApiClient.fetchSubject', () {
    test('GET /subjects/{id}：带 UA/Accept、不带 Content-Type', () async {
      Map<String, String>? headers;
      Uri? uri;
      final MockClient client = MockClient((http.Request req) async {
        headers = req.headers;
        uri = req.url;
        return http.Response.bytes(utf8.encode('{"id":123}'), 200);
      });
      final BangumiRawResponse res =
          await BangumiApiClient(client: client, userAgent: 'ua/x')
              .fetchSubject('123');

      expect(uri?.path, '/v0/subjects/123');
      expect(headers?['user-agent'], 'ua/x');
      expect(headers?['accept'], 'application/json');
      expect(headers?.containsKey('content-type'), isFalse);
      expect(res.body, contains('123'));
    });

    test('utf8 解码：中日文 body 不被 latin1 毁坏', () async {
      final MockClient client = MockClient(
        (http.Request req) async =>
            http.Response.bytes(utf8.encode('{"name_cn":"鬼滅の刃"}'), 200),
      );
      final BangumiRawResponse res =
          await BangumiApiClient(client: client, userAgent: 'ua')
              .fetchSubject('1');
      expect(res.body, contains('鬼滅の刃'));
    });
  });

  group('BangumiApiClient 状态码 / 异常边界', () {
    test('非 2xx（含 404）不抛：返回 BangumiRawResponse 由调用方定策略', () async {
      for (final int code in <int>[404, 500, 429]) {
        final MockClient client = MockClient(
          (http.Request req) async => http.Response('err', code),
        );
        final BangumiRawResponse res =
            await BangumiApiClient(client: client, userAgent: 'ua')
                .fetchSubject('1');
        expect(res.statusCode, code);
        expect(res.isOk, isFalse);
      }
    });

    test('传输失败 → BangumiTransportException（不吞异常）', () async {
      final MockClient client =
          MockClient((http.Request req) async => throw Exception('boom'));
      await expectLater(
        BangumiApiClient(client: client, userAgent: 'ua').fetchSubject('1'),
        throwsA(isA<BangumiTransportException>()),
      );
    });
  });

  group('BangumiApiClient 注入点', () {
    test('accessToken → Authorization: Bearer 头', () async {
      Map<String, String>? headers;
      final MockClient client = MockClient((http.Request req) async {
        headers = req.headers;
        return http.Response.bytes(utf8.encode('{}'), 200);
      });
      await BangumiApiClient(
        client: client,
        userAgent: 'ua',
        accessToken: 'tok123',
      ).fetchSubject('1');
      expect(headers?['authorization'], 'Bearer tok123');
    });

    test('gate 被调用且能观察响应（限流注入点）', () async {
      int gateCalls = 0;
      int? seenStatus;
      final MockClient client = MockClient(
        (http.Request req) async => http.Response.bytes(utf8.encode('{}'), 200),
      );
      final BangumiApiClient api = BangumiApiClient(
        client: client,
        userAgent: 'ua',
        gate: (Future<http.Response> Function() send) async {
          gateCalls++;
          final http.Response r = await send();
          seenStatus = r.statusCode;
          return r;
        },
      );
      await api.fetchSubject('1');
      expect(gateCalls, 1);
      expect(seenStatus, 200);
    });

    test('自定义 baseUrl 生效', () async {
      Uri? uri;
      final MockClient client = MockClient((http.Request req) async {
        uri = req.url;
        return http.Response.bytes(utf8.encode('{}'), 200);
      });
      await BangumiApiClient(
        client: client,
        userAgent: 'ua',
        baseUrl: 'https://mirror.example/v0',
      ).fetchSubject('9');
      expect(uri.toString(), 'https://mirror.example/v0/subjects/9');
    });
  });
}
